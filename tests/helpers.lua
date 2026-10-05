-- Shared test helpers: a fake clock and a behavioural PJLink projector simulator.

local md5 = require "lib.pjl_md5"
local Client = require "lib.pjl_client"
local Projector = require "lib.pjl_projector"

local H = {}

-- Fake clock --------------------------------------------------------------------

local Clock = {}
Clock.__index = Clock

function H.new_clock()
  return setmetatable({ t = 0, epoch = 1000000, timers = {}, seq = 0 }, Clock)
end

--- Whole seconds, like os.time().
function Clock:now()
  return self.epoch + math.floor(self.t / 1000)
end

function Clock:set_timer(ms, fn)
  self.seq = self.seq + 1
  local timer = { at = self.t + ms, fn = fn, seq = self.seq, cancelled = false }
  function timer:Cancel() self.cancelled = true end
  self.timers[#self.timers + 1] = timer
  return timer
end

function Clock:advance(ms)
  local target = self.t + ms
  while true do
    local best, best_index
    for i = #self.timers, 1, -1 do
      local tm = self.timers[i]
      if tm.cancelled then
        table.remove(self.timers, i)
      end
    end
    for i, tm in ipairs(self.timers) do
      if tm.at <= target and (not best or tm.at < best.at
          or (tm.at == best.at and tm.seq < best.seq)) then
        best, best_index = tm, i
      end
    end
    if not best then break end
    table.remove(self.timers, best_index)
    if best.at > self.t then self.t = best.at end
    best.fn(best)
  end
  self.t = target
end

-- Projector simulator ----------------------------------------------------------------

local Sim = {}
Sim.__index = Sim

--- opts: password, power ("0" standby|"1" on|"2" cooling|"3" warming), input,
--  inputs, erst, lamp, model, reachable, blackhole, mute, latency,
--  warm_ms, cool_ms, stale_ms
function H.new_sim(clock, opts)
  opts = opts or {}
  local sim = setmetatable({
    clock = clock,
    password = opts.password,
    power = opts.power or "0",
    input = opts.input or "31",
    inputs = opts.inputs or { "31", "32", "33", "51" },
    blank = "10",
    erst = opts.erst or "000000",
    lamp = opts.lamp or "1500 1",
    model = opts.model or "TEST-PROJECTOR",
    reachable = opts.reachable ~= false,
    blackhole = opts.blackhole or false,
    mute = opts.mute or false,
    latency = opts.latency or 20,
    warm_ms = opts.warm_ms or 30000,
    cool_ms = opts.cool_ms or 60000,
    stale_ms = opts.stale_ms,
    salt = "498e4a67",
    sent = {},
    commands = {},
    connect_times = {},
    connects = 0,
    open_count = 0,
    max_open = 0,
    auth_failures = 0,
    log = {},
  }, Sim)

  -- A projector that starts mid-transition finishes that transition on its own.
  if sim.power == "2" then
    clock:set_timer(sim.cool_ms, function() if sim.power == "2" then sim.power = "0" end end)
  elseif sim.power == "3" then
    clock:set_timer(sim.warm_ms, function() if sim.power == "3" then sim.power = "1" end end)
  end
  return sim
end

--- target must provide :on_status(s) and :on_data(s)
function Sim:attach(target)
  self.target = target
end

--- Commands received (bodies+param), e.g. {"POWR ?", "POWR 1"}
function Sim:count(command)
  local n = 0
  for _, c in ipairs(self.commands) do
    if c == command then n = n + 1 end
  end
  return n
end

function Sim:env()
  local sim = self
  return {
    connect = function()
      sim.connects = sim.connects + 1
      sim.connect_times[#sim.connect_times + 1] = sim.clock.t
      if sim.blackhole then return end
      sim.clock:set_timer(sim.latency, function()
        if not sim.reachable then
          sim.target:on_status("OFFLINE")
          return
        end
        sim.open_count = sim.open_count + 1
        if sim.open_count > sim.max_open then sim.max_open = sim.open_count end
        sim.target:on_status("ONLINE")
        sim.target:on_data(sim.password and ("PJLINK 1 " .. sim.salt .. "\r") or "PJLINK 0\r")
      end)
    end,
    disconnect = function()
      sim.clock:set_timer(sim.latency, function()
        if sim.open_count > 0 then sim.open_count = sim.open_count - 1 end
        sim.target:on_status("OFFLINE")
      end)
    end,
    send = function(data)
      sim.clock:set_timer(sim.latency, function() sim:_receive(data) end)
    end,
    set_timer = function(ms, fn) return sim.clock:set_timer(ms, fn) end,
    md5 = md5.hex,
    log = function(level, msg) sim.log[#sim.log + 1] = level .. ": " .. msg end,
  }
end

function Sim:_receive(data)
  self.sent[#self.sent + 1] = data
  if self.mute then return end
  local cmd = data
  if self.password then
    local prefix = data:sub(1, 32)
    cmd = data:sub(33)
    if prefix ~= md5.hex(self.salt .. self.password) then
      self.auth_failures = self.auth_failures + 1
      self.target:on_data("PJLINK ERRA\r")
      return
    end
  end
  local body, param = cmd:match("^%%1(%w%w%w%w) (.-)\r$")
  if not body then
    self.target:on_data("%1ERR=ERR1\r")
    return
  end
  self.commands[#self.commands + 1] = body .. " " .. param
  local reply = self:_handle(body, param)
  self.target:on_data("%1" .. body .. "=" .. reply .. "\r")
end

function Sim:_after(ms, fn)
  self.clock:set_timer(ms, fn)
end

function Sim:_handle(body, param)
  if body == "POWR" then
    if param == "?" then return self.power end
    if param == "1" then
      if self.power == "0" then
        if self.stale_ms then
          self:_after(self.stale_ms, function()
            if self.power == "0" then self.power = "3" end
          end)
        else
          self.power = "3"
        end
        self:_after((self.stale_ms or 0) + self.warm_ms, function()
          if self.power == "3" then self.power = "1" end
        end)
        return "OK"
      elseif self.power == "1" then
        return "OK"
      end
      return "ERR3"
    elseif param == "0" then
      if self.power == "1" then
        if self.stale_ms then
          self:_after(self.stale_ms, function()
            if self.power == "1" then self.power = "2" end
          end)
        else
          self.power = "2"
        end
        self:_after((self.stale_ms or 0) + self.cool_ms, function()
          if self.power == "2" then self.power = "0" end
        end)
        return "OK"
      elseif self.power == "0" then
        return "OK"
      end
      return "ERR3"
    end
    return "ERR2"
  elseif body == "INPT" then
    if self.power ~= "1" then return "ERR3" end
    if param == "?" then return self.input end
    for _, code in ipairs(self.inputs) do
      if code == param then
        self.input = param
        return "OK"
      end
    end
    return "ERR2"
  elseif body == "INST" then
    return table.concat(self.inputs, " ")
  elseif body == "AVMT" then
    if self.power ~= "1" then return "ERR3" end
    if param == "?" then return self.blank end
    if param == "10" or param == "11" then
      self.blank = param
      return "OK"
    end
    return "ERR2"
  elseif body == "ERST" then
    return self.erst
  elseif body == "LAMP" then
    if self.power ~= "1" then return "ERR3" end
    return self.lamp
  elseif body == "INF2" then
    return self.model
  end
  return "ERR1"
end

-- Full stack (sim + client + projector) -------------------------------------------------

local EVENTS = { "state", "input", "blank", "fault", "link", "lamp", "lamp_alert",
  "status", "info", "inputs" }

--- opts: sim (sim options), password (client), config (projector:configure), host
function H.new_stack(opts)
  opts = opts or {}
  local clock = H.new_clock()
  local sim = H.new_sim(clock, opts.sim)
  local client = Client.new(sim:env(), {
    host = opts.host or "10.0.0.5",
    password = opts.password or "",
  })
  sim:attach(client)

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

  local stack = { clock = clock, sim = sim, client = client, projector = projector, events = events }

  --- All events with this name, in order.
  function stack.of(name)
    local out = {}
    for _, e in ipairs(events) do
      if e.name == name then out[#out + 1] = e end
    end
    return out
  end

  --- Sequence of state names, e.g. {"STANDBY","WARMING","ON"}
  function stack.states()
    local out = {}
    for _, e in ipairs(stack.of("state")) do out[#out + 1] = e[1] end
    return out
  end

  return stack
end

-- driver.xml helpers --------------------------------------------------------------------

function H.read_file(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

--- Returns { [name] = default } for every <property> in driver.xml
function H.xml_property_defaults()
  local xml = H.read_file("driver.xml")
  local out, names = {}, {}
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    out[name] = default
    names[#names + 1] = name
  end
  return out, names
end

return H
