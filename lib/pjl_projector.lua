-- Projector logic: state tracking, intent reconciliation and adaptive polling.
-- Control4-agnostic. The owner injects:
--   deps.client       a pjl_client instance (request(body, param, cb, opts))
--   deps.set_timer    function(ms, fn) -> object with :Cancel()
--   deps.now          function() -> seconds (monotonic enough for TTLs)
--   deps.log          function(level, message)           (optional)
--   deps.on           table of notification callbacks     (all optional):
--       state(new, prev_real)       "STANDBY"|"WARMING"|"ON"|"COOLING"|"OFFLINE"
--       input(code, prev)           PJLink input code, e.g. "31"
--       fault(active, text, prev)   ERST? summary
--       link(online, was)           connectivity changes (was = true|false|nil)
--       lamp(hours)                 light source hours
--       lamp_alert(hours)           threshold reached (once until reset)
--       status(text)                short text for a status property
--       info(model)                 projector model string
--       inputs(list)                result of read_inputs()

local codec = require "lib.pjl_codec"

local Projector = {}
Projector.__index = Projector

Projector.STATE = {
  OFFLINE = "OFFLINE", STANDBY = "STANDBY", WARMING = "WARMING",
  ON = "ON", COOLING = "COOLING",
}

local POWER_TO_STATE = {
  standby = "STANDBY", on = "ON", cooling = "COOLING", warming = "WARMING",
}

local DEFAULTS = {
  idle_interval = 30,    -- seconds between polls while stable
  fast_interval = 3,     -- seconds between polls while something is changing
  offline_interval = 60, -- seconds between polls while unreachable
  locked_interval = 300, -- seconds between polls after an auth failure
  intent_ttl = 180,      -- seconds an unmet power/input request stays alive
  expect_window = 8,     -- seconds to ignore stale readings after a command
  lamp_interval = 1800,  -- seconds between light source hour reads
  fail_threshold = 2,    -- consecutive failures before OFFLINE
  lamp_alert = 0,        -- hours; 0 disables
}

function Projector.new(deps)
  local self = setmetatable({}, Projector)
  self.deps = deps
  self.client = deps.client
  self.on = deps.on or {}
  self.cfg = {}
  for k, v in pairs(DEFAULTS) do self.cfg[k] = v end

  self.state = nil       -- nil until the first successful poll
  self.last_real = nil   -- last non-OFFLINE state
  self.input = nil
  self.fault_active = nil
  self.fault_text = nil
  self.lamp_hours = nil
  self.lamp_alerted = false
  self.lamp_checked_at = nil
  self.model = nil
  self.model_asked = false  -- INF2 is asked once per connection, not on every poll
  self.input_expect = nil   -- { code, expires }: ignore stale input readbacks after a switch

  self.link = nil        -- nil unknown, true up, false down
  self.fail_count = 0
  self.auth_failed = false

  self.want = {}         -- { power = "on"|"off", input = "31", deadline = t }
  self.expect = nil      -- { state = "COOLING"|"WARMING", expires = t }
  self.cmd_inflight = false
  self.cmd_at = nil
  self.polling = false
  self.running = false
  self.timer = nil
  return self
end

function Projector:configure(opts)
  for k, v in pairs(opts or {}) do
    if DEFAULTS[k] ~= nil and type(v) == "number" then self.cfg[k] = v end
  end
end

function Projector:_log(level, msg)
  if self.deps.log then self.deps.log(level, msg) end
end

function Projector:_emit(name, ...)
  local fn = self.on[name]
  if fn then
    local ok, err = pcall(fn, ...)
    if not ok then self:_log("error", "handler '" .. name .. "' failed: " .. tostring(err)) end
  end
end

-- Lifecycle -------------------------------------------------------------------

function Projector:start()
  self:_log("info", "starting to poll the projector")
  self.running = true
  self:poll()
end

function Projector:stop()
  self.running = false
  self:_cancel_timer()
end

--- Forget what we knew about the connection (the address changed): the next successful
-- poll announces "Connected" again instead of staying silent because the old link was up.
function Projector:reset_link()
  self.link = nil
  self.fail_count = 0
  self.auth_failed = false
  self.model_asked = false
end

--- Forget auth lockout (call after the password changes) and poll now.
function Projector:reset_auth()
  self.auth_failed = false
  self.fail_count = 0
  if self.running then self:poll() end
end

-- State handling ----------------------------------------------------------------

function Projector:_set_state(new)
  if new == self.state then return end
  self:_log("debug", "state " .. tostring(self.state) .. " -> " .. tostring(new))
  local prev_real = self.last_real
  self.state = new
  if new ~= "OFFLINE" then self.last_real = new end
  if new == "STANDBY" or new == "COOLING" then
    -- The picture path is gone: forget the input so the next power-on
    -- re-reads and re-announces it (without raising a Changed event).
    self.input = nil
    self.input_expect = nil
  end
  self:_emit("state", new, prev_real)
end

function Projector:_link_up()
  self.fail_count = 0
  self.auth_failed = false
  if self.link ~= true then
    local was = self.link
    self.link = true
    self.model_asked = false
    self:_emit("status", "Connected")
    self:_emit("link", true, was)
  end
end

function Projector:_failure(res)
  self:_log(self.fail_count == 0 and "warn" or "debug", "request failed: " .. tostring(res.err)
    .. (res.detail and (" (" .. tostring(res.detail) .. ")") or "")
    .. " [failure " .. (self.fail_count + 1) .. " of " .. self.cfg.fail_threshold
    .. " before the projector is marked offline]")
  if res.err == "ERRA" then
    self.auth_failed = true
    local was = self.link
    self.link = false
    self:_set_state("OFFLINE")
    self:_emit("status", "Authentication failed - check PJLink password")
    self:_emit("link", false, was)
    return
  end
  self.fail_count = self.fail_count + 1
  if self.fail_count >= self.cfg.fail_threshold and self.link ~= false then
    local was = self.link
    self.link = false
    self:_log("warn", "projector offline: " .. self.fail_count .. " failed request(s) in a row (last error "
      .. tostring(res.err) .. ")")
    self:_set_state("OFFLINE")
    self:_emit("status", "Offline - projector not responding")
    self:_emit("link", false, was)
  end
end

local function is_link_error(err)
  return err == "CONNECT" or err == "TIMEOUT" or err == "CLOSED"
      or err == "PROTOCOL" or err == "ERRA" or err == "NOHOST"
end

-- Polling ---------------------------------------------------------------------

function Projector:_cancel_timer()
  if self.timer then
    self.timer:Cancel()
    self.timer = nil
  end
end

function Projector:_interval()
  local now = self.deps.now()
  if self.auth_failed then return self.cfg.locked_interval end
  if self.state == "OFFLINE" then return self.cfg.offline_interval end
  if self.state == "WARMING" or self.state == "COOLING"
      or self.want.power or self.want.input
      or (self.cmd_at and now - self.cmd_at < 20) then
    return self.cfg.fast_interval
  end
  return self.cfg.idle_interval
end

function Projector:_schedule()
  self:_cancel_timer()
  if not self.running then return end
  self.timer = self.deps.set_timer(self:_interval() * 1000, function()
    self.timer = nil
    self:poll()
  end)
end

--- Query power state, then the stable-state details, then reconcile intent.
function Projector:poll()
  if self.polling then return end
  self:_log("debug", "polling power state")
  self.polling = true
  self:_cancel_timer()

  self.client:request("POWR", "?", function(res)
    if not res.ok then
      self.polling = false
      if is_link_error(res.err) then self:_failure(res) end
      self:_schedule()
      return
    end

    self:_link_up()
    self:_log("debug", "POWR? -> " .. tostring(res.value))
    local name = codec.parse_power(res.value)
    local new = name and POWER_TO_STATE[name]
    if not new then
      self:_log("warn", "unexpected POWR value: " .. tostring(res.value))
      self.polling = false
      self:_schedule()
      return
    end

    -- Ignore a stale reading right after a command was accepted.
    local e = self.expect
    if e then
      if self.deps.now() >= e.expires or new == e.state then
        self.expect = nil
      elseif (e.state == "COOLING" and new == "ON")
          or (e.state == "WARMING" and new == "STANDBY") then
        new = e.state -- stale reading: the projector has not caught up yet
      else
        self.expect = nil
      end
    end
    self:_set_state(new)

    self:_followups(function()
      self.polling = false
      self:reconcile()
      -- reconcile may have started a command which schedules its own poll
      if not self.cmd_inflight then self:_schedule() end
    end)
  end)
end

function Projector:_lamp_due()
  local now = self.deps.now()
  return self.lamp_checked_at == nil or now - self.lamp_checked_at >= self.cfg.lamp_interval
end

function Projector:_followups(done)
  local steps = {}
  local st = self.state
  if st == "ON" then
    steps[#steps + 1] = { "INPT", self._on_input }
    if self:_lamp_due() then steps[#steps + 1] = { "LAMP", self._on_lamp } end
  end
  if st == "ON" or st == "STANDBY" then
    steps[#steps + 1] = { "ERST", self._on_erst }
    if not self.model and not self.model_asked then
      self.model_asked = true
      steps[#steps + 1] = { "INF2", self._on_info }
    end
  end

  local i = 0
  local function nxt()
    i = i + 1
    local step = steps[i]
    if not step then return done() end
    self.client:request(step[1], "?", function(res)
      if res.ok then
        step[2](self, res.value)
      elseif res.err == "CONNECT" or res.err == "TIMEOUT" or res.err == "CLOSED" then
        return done()
      end
      nxt()
    end)
  end
  nxt()
end

function Projector:_on_input(value)
  if type(value) ~= "string" or value == "" then return end
  local e = self.input_expect
  if e then
    if value == e.code or self.deps.now() >= e.expires then
      self.input_expect = nil
    else
      return -- stale reading: the projector has not finished switching
    end
  end
  if value ~= self.input then
    local prev = self.input
    self.input = value
    self:_emit("input", value, prev)
  end
end

function Projector:_on_erst(value)
  local r = codec.parse_errors(value)
  if not r then return end
  local active = not r.ok
  if active ~= self.fault_active or r.text ~= self.fault_text then
    local prev = self.fault_active
    self.fault_active = active
    self.fault_text = r.text
    self:_emit("fault", active, r.text, prev)
  end
end

function Projector:_on_lamp(value)
  local r = codec.parse_lamp(value)
  if not r then return end
  self.lamp_checked_at = self.deps.now()
  if r.hours ~= self.lamp_hours then
    self.lamp_hours = r.hours
    self:_emit("lamp", r.hours)
  end
  local limit = self.cfg.lamp_alert
  if limit > 0 then
    if r.hours >= limit and not self.lamp_alerted then
      self.lamp_alerted = true
      self:_emit("lamp_alert", r.hours)
    elseif r.hours < limit then
      self.lamp_alerted = false
    end
  end
end

function Projector:_on_info(value)
  if type(value) == "string" and value ~= "" then
    self.model = value
    self:_emit("info", value)
  end
end

-- Intent -------------------------------------------------------------------------

function Projector:_touch_deadline()
  self.want.deadline = self.deps.now() + self.cfg.intent_ttl
end

function Projector:_kick()
  if not self.running then return end
  if self.state == nil or self.state == "OFFLINE" then
    self:poll()
  else
    self:reconcile()
  end
end

function Projector:power_on()
  self.want.power = "on"
  self:_touch_deadline()
  self:_kick()
end

function Projector:power_off()
  self.want.power = "off"
  self:_touch_deadline()
  self:_kick()
end

--- Select an input by PJLink code (e.g. "31"). Applied once the projector is on.
function Projector:select_input(code)
  self.want.input = code
  self:_touch_deadline()
  self:_kick()
end

--- Bring the projector in line with the pending intent, one step at a time.
function Projector:reconcile()
  if not self.running or self.cmd_inflight then return end
  local want = self.want
  local st = self.state

  if (want.power or want.input) and want.deadline and self.deps.now() > want.deadline then
    self:_log("warn", "dropping unmet request (power=" .. tostring(want.power)
      .. ", input=" .. tostring(want.input) .. ")")
    want.power, want.input, want.deadline = nil, nil, nil
    return
  end

  if want.power == "on" then
    if st == "STANDBY" then return self:_send_power(true) end
    if st == "ON" then want.power = nil end
    -- WARMING: already on its way; COOLING: wait for standby; OFFLINE: wait
  elseif want.power == "off" then
    if st == "ON" then return self:_send_power(false) end
    if st == "STANDBY" or st == "COOLING" then want.power = nil end
    -- WARMING: PJLink refuses (ERR3) until warm-up completes, so wait
  end

  if want.input and st == "ON" then
    if self.input == want.input then
      want.input = nil
    else
      return self:_send_input(want.input)
    end
  end

  if not want.power and not want.input then want.deadline = nil end
end

function Projector:_send_power(turn_on)
  self:_log("info", "sending power " .. (turn_on and "on" or "off"))
  self.cmd_inflight = true
  self.client:request("POWR", turn_on and "1" or "0", function(res)
    self.cmd_inflight = false
    local now = self.deps.now()
    if res.ok then
      self.want.power = nil
      self.cmd_at = now
      local new = turn_on and "WARMING" or "COOLING"
      self.expect = { state = new, expires = now + self.cfg.expect_window }
      self:_set_state(new)
    elseif res.err == "ERR3" then
      self:_log("info", "power command refused (unavailable time); will retry")
    else
      self:_log("warn", "power command failed: " .. tostring(res.err))
      if is_link_error(res.err) then self:_failure(res) end
    end
    self:_schedule()
  end, { priority = true })
end

function Projector:_send_input(code)
  self:_log("info", "sending input select " .. tostring(code))
  self.cmd_inflight = true
  self.client:request("INPT", code, function(res)
    self.cmd_inflight = false
    self.cmd_at = self.deps.now()
    if res.ok then
      self.want.input = nil
      self.input_expect = { code = code, expires = self.cmd_at + self.cfg.expect_window }
      if code ~= self.input then
        local prev = self.input
        self.input = code
        self:_emit("input", code, prev)
      end
    elseif res.err == "ERR2" then
      self:_log("error", "input " .. code .. " is not available on this projector")
      self.want.input = nil
    elseif res.err == "ERR3" then
      self:_log("info", "input change refused (unavailable time); will retry")
    else
      self:_log("warn", "input command failed: " .. tostring(res.err))
      if is_link_error(res.err) then self:_failure(res) end
    end
    self:_schedule()
  end, { priority = true })
end

-- Diagnostics -----------------------------------------------------------------------

--- Ask the projector for its input list (INST?).
function Projector:read_inputs(callback)
  self.client:request("INST", "?", function(res)
    local list = res.ok and codec.parse_inputs(res.value) or nil
    if list then self:_emit("inputs", list) end
    if callback then callback(res, list) end
  end, { priority = true })
end

--- One-off connectivity test; also refreshes link status.
function Projector:test(callback)
  self.client:request("POWR", "?", function(res)
    if res.ok then
      self:_link_up()
    elseif is_link_error(res.err) then
      self:_failure(res)
    end
    if callback then callback(res) end
  end, { priority = true })
end

return Projector
