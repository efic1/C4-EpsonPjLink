-- Simulated Epson Web Control server (Digest auth, Referer check, json_query,
-- directsend) driven by the same fake clock as the PJLink tests.
--
-- The simulator verifies Digest responses with its OWN implementation of the formula,
-- so a bug in lib/http_digest.lua cannot hide behind a matching bug here.

local H = require "tests.helpers"
local md5 = require "lib.pjl_md5"
local EpsonHttp = require "lib.epson_http"
local Projector = require "lib.pjl_projector"

local S = {}

local function urldecode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parse_auth(value)
  if type(value) ~= "string" or not value:match("^Digest ") then return nil end
  local f = {}
  for k, v in value:gmatch('(%w+)="([^"]*)"') do f[k] = v end
  for k, v in value:gmatch('(%w+)=([^%s,"]+)') do f[k] = f[k] or v end
  return f
end

--- opts: web_password, remote_password (nil = no auth for that user), power ("04" standby
--  "01" on "02" warm-up "03" cooling), source, err, lamp, reachable, blackhole, mute,
--  latency, warm_ms, cool_ms, off_presses (2 = needs a confirm press), nonce_ttl_ms,
--  require_referer (default true)
function S.new_sim(clock, opts)
  opts = opts or {}
  local sim = setmetatable({
    clock = clock,
    web_password = opts.web_password,
    remote_password = opts.remote_password,
    power = opts.power or "04",
    source = opts.source or "30",
    err = opts.err or "00",
    lamp = opts.lamp or "1500",
    reachable = opts.reachable ~= false,
    blackhole = opts.blackhole or false,
    latency = opts.latency or 20,
    warm_ms = opts.warm_ms or 30000,
    cool_ms = opts.cool_ms or 60000,
    off_presses = opts.off_presses or 1,
    nonce_ttl_ms = opts.nonce_ttl_ms,
    require_referer = opts.require_referer ~= false,
    nonce_seq = 0,
    nonces = {},       -- nonce -> { issued_at, last_nc }
    log = {},          -- "METHOD target" of every request that reached the server
    requests = {},     -- full request records
    unauthorised = 0,
    commands = {},     -- directsend parameters that were accepted
    queries = {},      -- json_query parameters that were accepted
    pending_confirm_at = nil,
    in_flight = 0,
    max_in_flight = 0,
  }, { __index = S })

  if sim.power == "02" then
    clock:set_timer(sim.warm_ms, function() if sim.power == "02" then sim.power = "01" end end)
  elseif sim.power == "03" then
    clock:set_timer(sim.cool_ms, function() if sim.power == "03" then sim.power = "04" end end)
  end
  return sim
end

function S:count(command)
  local n = 0
  for _, c in ipairs(self.commands) do if c == command then n = n + 1 end end
  return n
end

function S:count_queries(q)
  local n = 0
  for _, c in ipairs(self.queries) do if c == q then n = n + 1 end end
  return n
end

function S:_new_nonce()
  self.nonce_seq = self.nonce_seq + 1
  local nonce = string.format("%04x:%s", self.nonce_seq, md5.hex("nonce" .. self.nonce_seq))
  self.nonces[nonce] = { issued_at = self.clock.t, last_nc = 0 }
  return nonce
end

function S:_challenge(stale)
  self.unauthorised = self.unauthorised + 1
  local nonce = self:_new_nonce()
  local www = 'Digest realm="Web Control", nonce="' .. nonce .. '", qop="auth"'
  if stale then www = www .. ", stale=true" end
  return { code = 401, headers = { ["WWW-Authenticate"] = www, ["Content-Type"] = "text/html" },
    body = "<h1>401 Unauthorized</h1>" }
end

--- returns nil when authorised, or a 401 response
function S:_check_auth(user, password, method, uri, headers)
  if not password then return nil end
  local auth = parse_auth(headers["Authorization"])
  if not auth then return self:_challenge(false) end

  if auth.username ~= user or auth.uri ~= uri then return self:_challenge(false) end

  local info = self.nonces[auth.nonce]
  if not info then return self:_challenge(false) end
  if self.nonce_ttl_ms and self.clock.t - info.issued_at > self.nonce_ttl_ms then
    self.nonces[auth.nonce] = nil
    return self:_challenge(true)
  end

  local nc = tonumber(auth.nc or "", 16)
  if not nc or nc <= info.last_nc then return self:_challenge(false) end

  local ha1 = md5.hex(user .. ":Web Control:" .. password)
  local ha2 = md5.hex(method .. ":" .. uri)
  local expected = md5.hex(table.concat({ ha1, auth.nonce, auth.nc, auth.cnonce or "", auth.qop or "", ha2 }, ":"))
  if auth.response ~= expected then return self:_challenge(false) end

  info.last_nc = nc
  return nil
end

function S:_set_power(code, after_ms, final)
  self.power = code
  self.clock:set_timer(after_ms, function() if self.power == code then self.power = final end end)
end

function S:_directsend(query)
  local name, value = query:match("^([^=]+)=?(.*)$")
  name, value = urldecode(name or ""), urldecode(value or "")
  local param = value ~= "" and (name .. "=" .. value) or name
  local accepted = true

  if param == "IMPWR=ON" then
    if self.power == "04" then self:_set_power("02", self.warm_ms, "01") end
  elseif param == "IMPWR=OFF" then
    -- discrete off: only acts when the projector is on, never wakes a standby projector
    if self.power == "01" then self:_set_power("03", self.cool_ms, "04") end
  elseif param == "KEY=6C" then
    if self.power == "01" then
      if self.off_presses >= 2 then
        if self.pending_confirm_at and self.clock.t - self.pending_confirm_at <= 5000 then
          self.pending_confirm_at = nil
          self:_set_power("03", self.cool_ms, "04")
        else
          self.pending_confirm_at = self.clock.t
        end
      else
        self:_set_power("03", self.cool_ms, "04")
      end
    end
  elseif param == "KEY=4D" then
    if self.power == "01" then self.source = "30" end
  elseif param == "KEY=40" then
    if self.power == "01" then self.source = "A0" end
  elseif param:match("^KEY=%x%x$") then
    -- any other key is accepted and ignored
  else
    accepted = false
  end

  if accepted then self.commands[#self.commands + 1] = param end
  return { code = 200, headers = { ["Content-Type"] = "text/html" }, body = "" }
end

function S:_json_query(query)
  local callback = urldecode(query:match("jsoncallback=([^&]*)") or "")
  self.queries[#self.queries + 1] = callback
  local reply, error_flag = "", true
  if callback == "PWR?" then
    reply, error_flag = self.power, false
  elseif callback == "SOURCE?" and self.power == "01" then
    reply, error_flag = self.source, false
  elseif callback == "ERR?" then
    reply, error_flag = self.err, false
  elseif callback == "LAMP?" and self.power == "01" then
    reply, error_flag = self.lamp, false
  end
  local body = string.format(
    '{\n"projector": {\n"feature": {\n"name": "esc/vp21",\n"query": "%s",\n"reply": "%s",\n"error": %s\n}\n}\n}',
    callback, reply, tostring(error_flag))
  return { code = 200, headers = { ["Content-Type"] = "application/json" }, body = body }
end

function S:_handle(url, headers)
  local path, query = url:match("^http://[^/]+(/[^?]*)%??(.*)$")
  local target = path .. (query ~= "" and ("?" .. query) or "")
  self.requests[#self.requests + 1] = { url = url, headers = headers, target = target }
  self.log[#self.log + 1] = "GET " .. target

  local is_remote = path:find("/cgi-bin/Remote/", 1, true) == 1
  local user = is_remote and "EPSONREMOTE" or "EPSONWEB"
  local password = is_remote and self.remote_password or self.web_password
  local denied = self:_check_auth(user, password, "GET", target, headers)
  if denied then return denied end

  if self.require_referer then
    local ref = headers["Referer"]
    if not ref or not ref:find("/cgi-bin/", 1, true) then
      return { code = 200, headers = { ["Content-Type"] = "text/html" },
        body = "<html><body><H2>403 Forbidden</H2><blockquote>Could not get return location.</blockquote></body></html>" }
    end
  end

  if path == "/cgi-bin/json_query" then return self:_json_query(query) end
  if path == "/cgi-bin/Remote/directsend" or path == "/cgi-bin/directsend" then
    return self:_directsend(query)
  end
  return { code = 404, headers = {}, body = "not found" }
end

function S:env()
  local sim = self
  return {
    get = function(url, headers, timeout_s, cb)
      sim.in_flight = sim.in_flight + 1
      if sim.in_flight > sim.max_in_flight then sim.max_in_flight = sim.in_flight end
      local function finish(r)
        sim.in_flight = sim.in_flight - 1
        cb(r)
      end
      if sim.blackhole then
        sim.clock:set_timer(timeout_s * 1000, function() finish({ err = "TIMEOUT" }) end)
        return
      end
      sim.clock:set_timer(sim.latency, function()
        if not sim.reachable then return finish({ err = "CONNECT" }) end
        finish(sim:_handle(url, headers))
      end)
    end,
    set_timer = function(ms, fn) return sim.clock:set_timer(ms, fn) end,
    md5 = md5.hex,
    cnonce = (function()
      local n = 0
      return function() n = n + 1; return string.format("cn%014d", n) end
    end)(),
    log = function(level, msg) sim.log[#sim.log + 1] = level .. ": " .. msg end,
  }
end

-- Full stack ---------------------------------------------------------------------------

local EVENTS = { "state", "input", "fault", "link", "lamp", "lamp_alert", "status", "info", "inputs" }

--- opts: sim, web_password, remote_password (client side), config, cfg (command table)
function S.new_stack(opts)
  opts = opts or {}
  local clock = H.new_clock()
  local sim = S.new_sim(clock, opts.sim)

  local cfg = {
    power_on = "IMPWR=ON",
    power_off_key = "6C",
    power_off_presses = 1,
    inputs = { ["30"] = "KEY=4D", ["A0"] = "KEY=40" },
    source_codes = { "30", "A0" },
    model = "TEST-HTTP",
  }
  for k, v in pairs(opts.cfg or {}) do cfg[k] = v end

  local client = EpsonHttp.new(sim:env(), {
    host = opts.host or "10.0.0.5",
    credentials = function(user)
      if user == "EPSONREMOTE" then return user, opts.remote_password or "" end
      return user, opts.web_password or ""
    end,
    cfg = function() return cfg end,
    gap = opts.gap,
    timeout = opts.timeout,
  })

  local events = {}
  local on = {}
  for _, name in ipairs(EVENTS) do
    on[name] = function(...) events[#events + 1] = { name = name, ... } end
  end

  local projector = Projector.new({
    client = client,
    set_timer = function(ms, fn) return clock:set_timer(ms, fn) end,
    now = function() return clock:now() end,
    log = function(level, msg) sim.log[#sim.log + 1] = level .. ": " .. msg end,
    on = on,
  })
  if opts.config then projector:configure(opts.config) end

  local stack = { clock = clock, sim = sim, client = client, projector = projector,
    events = events, cfg = cfg }

  function stack.of(name)
    local out = {}
    for _, e in ipairs(events) do if e.name == name then out[#out + 1] = e end end
    return out
  end

  function stack.states()
    local out = {}
    for _, e in ipairs(stack.of("state")) do out[#out + 1] = e[1] end
    return out
  end

  return stack
end

return S
