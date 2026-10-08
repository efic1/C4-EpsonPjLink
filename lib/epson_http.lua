-- Epson Web Control client with the same interface as lib/pjl_client.lua, so the
-- projector module runs unchanged on top of it.
--
-- Every request is its own short HTTP exchange (Connection: close), one at a time,
-- in a FIFO queue with priority, de-duplication and a settle gap between requests.
-- Digest authentication is done here (RFC 2617) and the challenge is cached per
-- user name, so most requests take a single round trip.
--
-- The owner injects `env`:
--   env.get(url, headers, timeout_s, callback)
--        callback({ err = "CONNECT"|"TIMEOUT"|"CLOSED" })  or
--        callback({ code = 200, headers = {...}, body = "..." })
--   env.set_timer(ms, fn)   one-shot timer returning an object with :Cancel()
--   env.md5(str)            lowercase hex digest
--   env.cnonce()            optional; random client nonce
--   env.log(level, msg)     optional
--
-- request(body, param, callback, opts) -> callback(res):
--   res = { ok = true,  value = "..." }
--       | { ok = false, err = "ERR1".."ERR4" | "ERRA" | "CONNECT" | "TIMEOUT" | "CLOSED"
--                             | "PROTOCOL" | "NOHOST" | "QUEUE_FULL" | "CANCELLED" }

local cmds = require "lib.epson_cmds"
local digest = require "lib.http_digest"

local Client = {}
Client.__index = Client

local USER_WEB = "EPSONWEB"
local USER_REMOTE = "EPSONREMOTE"

function Client.new(env, opts)
  opts = opts or {}
  local self = setmetatable({}, Client)
  self.env = env
  self.host = opts.host
  self.port = opts.port or 80
  self.command_path = opts.command_path or "/cgi-bin/Remote/directsend"
  self.credentials = opts.credentials or function() return "", "" end
  self.cfg = opts.cfg or function() return {} end
  self.timeout = opts.timeout or 8      -- seconds, per HTTP exchange
  self.gap = opts.gap or 500            -- ms between requests
  self.max_queue = opts.max_queue or 25
  self.queue = {}
  self.state = "idle" -- idle | running | settling
  self.timer = nil
  self.token = 0
  self.challenges = {}
  self.cnonce_counter = 0
  return self
end

function Client:_log(level, msg)
  if self.env.log then self.env.log(level, msg) end
end

-- Timers ------------------------------------------------------------------------

function Client:_disarm()
  self.token = self.token + 1
  if self.timer then
    self.timer:Cancel()
    self.timer = nil
  end
end

function Client:_arm(ms, fn)
  self:_disarm()
  local token = self.token
  self.timer = self.env.set_timer(ms, function()
    if token ~= self.token then return end
    self.timer = nil
    fn()
  end)
end

-- Public API ----------------------------------------------------------------------

function Client:set_host(host)
  if host ~= self.host then
    self.host = host
    self.challenges = {}
    self:reset("CANCELLED")
  end
end

function Client:set_command_path(path)
  if path and path ~= "" then self.command_path = path end
end

--- Both arguments are milliseconds (kept for interface parity with the PJLink client).
function Client:set_timeouts(connect_ms, response_ms)
  local ms = response_ms or connect_ms
  if ms then self.timeout = ms / 1000 end
end

--- Forget cached Digest challenges (call when a password changes).
function Client:clear_auth()
  self.challenges = {}
end

function Client:pending()
  return #self.queue
end

function Client:request(body, param, callback, opts)
  opts = opts or {}
  if not self.host or self.host == "" then
    if callback then callback({ ok = false, err = "NOHOST" }) end
    return
  end

  local line = tostring(body) .. " " .. tostring(param or "?")

  for _, job in ipairs(self.queue) do
    if not job.started and job.line == line then
      if callback then job.cbs[#job.cbs + 1] = callback end
      return
    end
  end

  if #self.queue >= self.max_queue then
    if callback then callback({ ok = false, err = "QUEUE_FULL" }) end
    return
  end

  local job = {
    line = line,
    body = body,
    param = param or "?",
    cbs = {},
    priority = opts.priority and true or false,
    started = false,
  }
  if callback then job.cbs[1] = callback end

  local pos = #self.queue + 1
  if job.priority then
    pos = (self.queue[1] and self.queue[1].started) and 2 or 1
    while self.queue[pos] and self.queue[pos].priority do pos = pos + 1 end
  end
  table.insert(self.queue, pos, job)

  self:_pump()
end

function Client:reset(reason)
  self:_disarm()
  local dropped = self.queue
  self.queue = {}
  self.state = "idle"
  self.generation = (self.generation or 0) + 1
  for _, job in ipairs(dropped) do
    for _, cb in ipairs(job.cbs) do
      local ok, err = pcall(cb, { ok = false, err = reason or "CANCELLED" })
      if not ok then self:_log("error", "callback error: " .. tostring(err)) end
    end
  end
end

-- Internals --------------------------------------------------------------------------

function Client:_pump()
  if self.state ~= "idle" then return end
  local job = self.queue[1]
  if not job then return end

  job.started = true
  self.state = "running"
  local generation = self.generation or 0
  self:_execute(job, function(res)
    if (self.generation or 0) ~= generation then return end -- reset while in flight
    self:_finish(res)
  end)
end

function Client:_finish(res)
  if self.state ~= "running" then return end
  local job = table.remove(self.queue, 1)
  self.state = "settling"

  if job then
    for _, cb in ipairs(job.cbs) do
      local ok, err = pcall(cb, res)
      if not ok then self:_log("error", "callback error: " .. tostring(err)) end
    end
  end

  local function settled()
    self.state = "idle"
    self:_pump()
  end
  if self.gap > 0 then self:_arm(self.gap, settled) else settled() end
end

--- Which credentials does this path need?
function Client:_auth_for(path)
  if path:find("/cgi-bin/Remote/", 1, true) == 1 then return USER_REMOTE end
  return USER_WEB
end

function Client:_next_cnonce()
  if self.env.cnonce then return self.env.cnonce() end
  self.cnonce_counter = self.cnonce_counter + 1
  return self.env.md5(tostring(self.cnonce_counter) .. ":" .. tostring(os.time())):sub(1, 16)
end

--- One authenticated GET. cb receives { err } or { code, headers, body }.
function Client:_fetch(path, query, cb, attempt)
  attempt = attempt or 0
  local user = self:_auth_for(path)
  local u, pass = self.credentials(user)
  pass = pass or ""
  local target = path .. "?" .. query
  local referer
  if path:find("/cgi-bin/Remote/", 1, true) == 1 then
    referer = "http://" .. self.host .. "/cgi-bin/Remote/Basic_Control"
  else
    referer = "http://" .. self.host .. "/cgi-bin/webconf"
  end

  local headers = {
    ["Referer"] = referer,
    ["Accept"] = "application/json, text/javascript, */*; q=0.01",
    ["Connection"] = "close",
  }

  local ch = self.challenges[user]
  if ch and pass ~= "" then
    ch.nc = (ch.nc or 0) + 1
    local value, why = digest.authorization(ch, user, pass, "GET", target, ch.nc,
      self:_next_cnonce(), self.env.md5)
    if value then
      headers["Authorization"] = value
    else
      self:_log("error", "digest: " .. tostring(why))
    end
  end

  local port = (self.port ~= 80) and (":" .. self.port) or ""
  local url = "http://" .. self.host .. port .. target
  local timeout = self.timeout
  local generation = self.generation or 0

  self.env.get(url, headers, timeout, function(r)
    -- reset() while this was in flight: nothing may follow (no retry, no next key press)
    if (self.generation or 0) ~= generation then return end
    if r.err then return cb(r) end

    if r.code == 401 then
      local fresh = digest.parse_challenge(digest.header(r.headers, "www-authenticate"))
      if not fresh or pass == "" or attempt >= 1 then
        self.challenges[user] = nil
        return cb({ err = "ERRA", code = 401 })
      end
      fresh.nc = 0
      self.challenges[user] = fresh
      return self:_fetch(path, query, cb, attempt + 1)
    end

    cb(r)
  end)
end

local function http_error(r)
  if r.code == 401 or r.code == 403 and tostring(r.body):find("password", 1, true) then
    return "ERRA"
  end
  return "PROTOCOL"
end

function Client:_execute(job, done)
  local plan = cmds.plan(job.body, job.param, self.cfg())

  if plan.kind == "local" then
    return done({ ok = true, value = plan.value })
  elseif plan.kind == "error" then
    return done({ ok = false, err = plan.err })
  end

  if plan.kind == "query" then
    local query = "jsoncallback=" .. cmds.urlenc(plan.query)
    return self:_fetch(cmds.QUERY_PATH, query, function(r)
      if r.err then return done({ ok = false, err = r.err }) end
      if r.code ~= 200 then return done({ ok = false, err = http_error(r) }) end
      local reply, is_error = cmds.parse_json_reply(r.body)
      if reply == nil and not is_error then
        -- an HTML error page (for example the missing-Referer 403 page) is not a JSON reply
        return done({ ok = false, err = "PROTOCOL" })
      end
      if is_error or reply == nil then return done({ ok = false, err = "ERR3" }) end
      if job.body == "ERST" and reply ~= "00" then
        self:_log("warn", "ERR? reported code " .. reply)
      end
      local value, err = plan.convert(reply)
      if value == nil then return done({ ok = false, err = err or "ERR3" }) end
      done({ ok = true, value = value })
    end)
  end

  -- kind == "send": one or more directsend calls in sequence
  local commands = plan.commands
  local index = 0
  local function step()
    index = index + 1
    local param = cmds.encode_param(commands[index])
    self:_fetch(self.command_path, param, function(r)
      if r.err then return done({ ok = false, err = r.err }) end
      if r.code ~= 200 then return done({ ok = false, err = http_error(r) }) end
      if tostring(r.body):find("403 Forbidden", 1, true) then
        return done({ ok = false, err = "PROTOCOL", detail = "rejected: missing Referer or wrong path" })
      end
      if index >= #commands then return done({ ok = true, value = "OK" }) end
      self:_arm(plan.gap_ms or 500, step)
    end)
  end
  step()
end

return Client
