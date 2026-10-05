-- PJLink client: one short-lived TCP connection per request, FIFO queue.
--
-- Nothing in here touches Control4 directly. The owner injects an `env`:
--   env.connect(host, port)   start an async connect; owner later calls client:on_status()
--   env.disconnect()          close the connection
--   env.send(data)            write to the open connection
--   env.set_timer(ms, fn)     one-shot timer, returns an object with :Cancel()
--   env.md5(str)              hex digest (lowercase) used for PJLink authentication
--   env.log(level, message)   optional
--
-- The owner forwards network events with client:on_status("ONLINE"|"OFFLINE")
-- and client:on_data(str).
--
-- request(body, param, callback, opts) results in callback(res) where
--   res = { ok = true,  value = "..." }
--       | { ok = false, err = "ERR1".."ERR4" | "ERRA" | "CONNECT" | "TIMEOUT"
--                             | "CLOSED" | "PROTOCOL" | "NOHOST" | "QUEUE_FULL"
--                             | "CANCELLED" }

local codec = require "lib.pjl_codec"

local Client = {}
Client.__index = Client

function Client.new(env, opts)
  opts = opts or {}
  local self = setmetatable({}, Client)
  self.env = env
  self.host = opts.host
  self.port = opts.port or codec.PORT
  self.password = opts.password or ""
  self.connect_timeout = opts.connect_timeout or 5000
  self.response_timeout = opts.response_timeout or 5000
  self.close_timeout = opts.close_timeout or 1500
  self.gap = opts.gap or 300
  self.max_queue = opts.max_queue or 25
  self.queue = {}
  self.state = "idle" -- idle | connecting | greeting | awaiting | closing | settling
  self.online = false
  self.buffer = ""
  self.token = 0
  self.timer = nil
  return self
end

function Client:_log(level, msg)
  if self.env.log then self.env.log(level, msg) end
end

function Client:_password()
  local p = self.password
  if type(p) == "function" then p = p() end
  return p or ""
end

-- Timers ------------------------------------------------------------------

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

-- Public API ----------------------------------------------------------------

function Client:set_host(host)
  if host ~= self.host then
    self.host = host
    self:reset("CANCELLED")
  end
end

function Client:set_password(password)
  self.password = password or ""
end

function Client:set_timeouts(connect_ms, response_ms)
  if connect_ms then self.connect_timeout = connect_ms end
  if response_ms then self.response_timeout = response_ms end
end

function Client:pending()
  return #self.queue
end

--- Queue a request. opts.priority puts it ahead of queued non-priority work.
function Client:request(body, param, callback, opts)
  opts = opts or {}
  if not self.host or self.host == "" then
    if callback then callback({ ok = false, err = "NOHOST" }) end
    return
  end

  local line = codec.build(body, param, opts.class)

  -- Share the result with an identical request that has not started yet.
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

--- Drop everything, close any open connection, fail queued callbacks.
function Client:reset(reason)
  self:_disarm()
  local dropped = self.queue
  self.queue = {}
  if self.online then self.env.disconnect() end
  self.online = false
  self.state = "idle"
  self.buffer = ""
  for _, job in ipairs(dropped) do
    for _, cb in ipairs(job.cbs) do
      local ok, err = pcall(cb, { ok = false, err = reason or "CANCELLED" })
      if not ok then self:_log("error", "callback error: " .. tostring(err)) end
    end
  end
end

-- Network events (forwarded by the owner) -------------------------------------

function Client:on_status(status)
  if status == "ONLINE" then
    self.online = true
    if self.state == "connecting" then
      self.state = "greeting"
      self:_arm(self.response_timeout, function()
        self:_finish({ ok = false, err = "TIMEOUT" })
      end)
    elseif self.state == "closing" or self.state == "settling" then
      -- A late connect completed after we gave up on it: close it again.
      self.env.disconnect()
    end
  else
    self.online = false
    if self.state == "connecting" then
      self:_finish({ ok = false, err = "CONNECT" })
    elseif self.state == "greeting" or self.state == "awaiting" then
      self:_finish({ ok = false, err = "CLOSED" })
    elseif self.state == "closing" then
      self:_closed()
    end
  end
end

function Client:on_data(data)
  if self.state ~= "greeting" and self.state ~= "awaiting" then return end
  self.buffer = self.buffer .. data
  while true do
    local line, rest = self.buffer:match("^(.-)\r(.*)$")
    if not line then break end
    self.buffer = rest
    if line ~= "" then self:_on_line(line) end
    if self.state ~= "greeting" and self.state ~= "awaiting" then break end
  end
end

-- Internals ------------------------------------------------------------------

function Client:_pump()
  if self.state ~= "idle" then return end
  local job = self.queue[1]
  if not job then return end

  job.started = true
  self.state = "connecting"
  self.buffer = ""
  self.online = false
  self:_arm(self.connect_timeout, function()
    self:_finish({ ok = false, err = "CONNECT" })
  end)
  self.env.connect(self.host, self.port)
end

function Client:_on_line(line)
  local job = self.queue[1]
  if not job then return end

  if self.state == "greeting" then
    local greeting = codec.parse_greeting(line)
    if not greeting then
      return self:_finish({ ok = false, err = "PROTOCOL" })
    end
    if greeting.err then
      return self:_finish({ ok = false, err = greeting.err })
    end
    local prefix = ""
    if greeting.auth then
      local password = self:_password()
      if password == "" then
        return self:_finish({ ok = false, err = "ERRA", detail = "password required" })
      end
      prefix = codec.auth_prefix(greeting.salt, password, self.env.md5)
    end
    self.state = "awaiting"
    self:_arm(self.response_timeout, function()
      self:_finish({ ok = false, err = "TIMEOUT" })
    end)
    self:_log("debug", "-> " .. job.line:gsub("\r", ""))
    self.env.send(prefix .. job.line)
  elseif self.state == "awaiting" then
    self:_log("debug", "<- " .. line)
    if line:upper() == "PJLINK ERRA" then
      return self:_finish({ ok = false, err = "ERRA" })
    end
    local res = codec.parse_response(line)
    if not res then
      return self:_finish({ ok = false, err = "PROTOCOL" })
    end
    if res.body ~= job.body then return end -- stray line, keep waiting
    if res.err then
      return self:_finish({ ok = false, err = res.err })
    end
    self:_finish({ ok = true, value = res.value })
  end
end

function Client:_finish(res)
  if self.state == "idle" or self.state == "closing" or self.state == "settling" then
    return
  end
  local job = table.remove(self.queue, 1)
  self:_disarm()
  self.state = "closing"

  if self.online then
    self.env.disconnect()
    self:_arm(self.close_timeout, function() self:_closed() end)
  else
    self:_closed()
  end

  if job then
    for _, cb in ipairs(job.cbs) do
      local ok, err = pcall(cb, res)
      if not ok then self:_log("error", "callback error: " .. tostring(err)) end
    end
  end
end

function Client:_closed()
  if self.state ~= "closing" then return end
  self:_disarm()
  self.online = false
  self.state = "settling"
  if self.gap > 0 then
    self:_arm(self.gap, function()
      self.state = "idle"
      self:_pump()
    end)
  else
    self.state = "idle"
    self:_pump()
  end
end

return Client
