local t = require "tests.lib_test"
local H = require "tests.helpers"

local SEC = 1000

t.suite("projector: polling and state")

t.test("first poll reports standby with no previous state and marks the link up", function()
  local s = H.new_stack({ sim = { power = "0" } })
  s.projector:start()
  s.clock:advance(3 * SEC)
  t.deep_eq(s.states(), { "STANDBY" })
  t.eq(s.of("state")[1][2], nil, "no previous state at startup")
  t.eq(s.of("status")[1][1], "Connected")
  local link = s.of("link")[1]
  t.eq(link[1], true)
  t.eq(link[2], nil, "was = nil on first connect")
end)

t.test("an already-on projector reports ON, its input, lamp hours, model and no fault", function()
  local s = H.new_stack({ sim = { power = "1", input = "32", lamp = "1500 1", model = "TEST-PROJECTOR" } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  t.deep_eq(s.states(), { "ON" })
  t.eq(s.of("input")[1][1], "32")
  t.eq(s.of("lamp")[1][1], 1500)
  t.eq(s.of("info")[1][1], "TEST-PROJECTOR")
  local fault = s.of("fault")[1]
  t.eq(fault[1], false)
  t.eq(fault[2], "OK")
end)

t.test("standby is polled at the idle interval, not the fast one", function()
  local s = H.new_stack({ sim = { power = "0" }, config = { idle_interval = 30 } })
  s.projector:start()
  s.clock:advance(100 * SEC)
  local polls = s.sim:count("POWR ?")
  t.truthy(polls >= 3 and polls <= 5, "expected ~4 power polls in 100s, got " .. polls)
end)

t.test("idle interval is configurable", function()
  local s = H.new_stack({ sim = { power = "0" }, config = { idle_interval = 10 } })
  s.projector:start()
  s.clock:advance(100 * SEC)
  local polls = s.sim:count("POWR ?")
  t.truthy(polls >= 8, "expected ~10 power polls, got " .. polls)
end)

t.test("stop() ends polling", function()
  local s = H.new_stack({ sim = { power = "0" }, config = { idle_interval = 10 } })
  s.projector:start()
  s.clock:advance(15 * SEC)
  s.projector:stop()
  local before = s.sim.connects
  s.clock:advance(120 * SEC)
  t.eq(s.sim.connects, before)
end)

t.suite("projector: power control")

t.test("power_on from standby goes STANDBY -> WARMING -> ON", function()
  local s = H.new_stack({ sim = { power = "0", warm_ms = 20 * SEC } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  s.projector:power_on()
  s.clock:advance(60 * SEC)
  t.deep_eq(s.states(), { "STANDBY", "WARMING", "ON" })
  t.eq(s.sim.power, "1")
  t.eq(s.sim:count("POWR 1"), 1, "exactly one power-on command")
end)

t.test("power_off from on goes ON -> COOLING -> STANDBY", function()
  local s = H.new_stack({ sim = { power = "1", cool_ms = 30 * SEC } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:power_off()
  s.clock:advance(90 * SEC)
  t.deep_eq(s.states(), { "ON", "COOLING", "STANDBY" })
  t.eq(s.sim:count("POWR 0"), 1)
end)

t.test("power_on when already on sends nothing", function()
  local s = H.new_stack({ sim = { power = "1" } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:power_on()
  s.clock:advance(30 * SEC)
  t.eq(s.sim:count("POWR 1"), 0)
  t.eq(s.projector.want.power, nil)
end)

t.test("power_off when already in standby sends nothing", function()
  local s = H.new_stack({ sim = { power = "0" } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:power_off()
  s.clock:advance(30 * SEC)
  t.eq(s.sim:count("POWR 0"), 0)
end)

t.test("power_on during cooldown waits for standby, then powers on", function()
  local s = H.new_stack({ sim = { power = "2", cool_ms = 20 * SEC, warm_ms = 10 * SEC } })
  s.projector:start()
  s.clock:advance(2 * SEC)
  s.projector:power_on()
  s.clock:advance(10 * SEC)
  t.eq(s.sim:count("POWR 1"), 0, "must not fire while cooling (the projector would ignore it)")
  s.clock:advance(60 * SEC)
  t.eq(s.sim:count("POWR 1"), 1)
  t.eq(s.sim.power, "1")
  local states = s.states()
  t.eq(states[#states], "ON")
end)

t.test("power_off during warm-up waits until the projector is on", function()
  local s = H.new_stack({ sim = { power = "3", warm_ms = 15 * SEC, cool_ms = 10 * SEC } })
  s.projector:start()
  s.clock:advance(2 * SEC)
  s.projector:power_off()
  s.clock:advance(8 * SEC)
  t.eq(s.sim:count("POWR 0"), 0, "refused during warm-up, so not sent")
  s.clock:advance(120 * SEC)
  t.eq(s.sim:count("POWR 0"), 1)
  t.eq(s.sim.power, "0")
end)

t.test("a refused command (ERR3) is retried until it is accepted", function()
  local s = H.new_stack({ sim = { power = "1", cool_ms = 5 * SEC } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  -- Force the sim to refuse once, as if the projector were momentarily busy.
  local real = s.sim._handle
  local refused = false
  s.sim._handle = function(self, body, param)
    if body == "POWR" and param == "0" and not refused then
      refused = true
      return "ERR3"
    end
    return real(self, body, param)
  end
  s.projector:power_off()
  s.clock:advance(60 * SEC)
  t.truthy(refused)
  t.eq(s.sim.power, "0")
end)

t.suite("projector: stale readings right after a command")

t.test("a stale ON reading after a power-off does not flip the state back", function()
  -- The projector keeps answering "on" for 4s after accepting POWR 0.
  local s = H.new_stack({ sim = { power = "1", stale_ms = 4 * SEC, cool_ms = 20 * SEC } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:power_off()
  s.clock:advance(40 * SEC)
  t.deep_eq(s.states(), { "ON", "COOLING", "STANDBY" })
end)

t.test("a stale STANDBY reading after a power-on does not flip the state back", function()
  local s = H.new_stack({ sim = { power = "0", stale_ms = 4 * SEC, warm_ms = 15 * SEC } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  s.projector:power_on()
  s.clock:advance(40 * SEC)
  t.deep_eq(s.states(), { "STANDBY", "WARMING", "ON" })
end)

t.test("a genuine standby after the expectation window is honoured", function()
  -- Projector accepts POWR 1 but then really returns to standby (e.g. lamp failure).
  local s = H.new_stack({ sim = { power = "0", warm_ms = 60 * SEC } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  s.projector:power_on()
  s.clock:advance(2 * SEC)
  s.sim.power = "0"
  s.clock:advance(30 * SEC)
  local states = s.states()
  t.eq(states[#states], "STANDBY")
end)

t.suite("projector: input selection")

t.test("select_input applies immediately when the projector is on", function()
  local s = H.new_stack({ sim = { power = "1", input = "31" } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:select_input("32")
  s.clock:advance(10 * SEC)
  t.eq(s.sim.input, "32")
  local inputs = s.of("input")
  t.eq(inputs[#inputs][1], "32")
  t.eq(inputs[#inputs][2], "31", "previous input is reported")
end)

t.test("Navigator pattern: ON then SET_INPUT right away applies the input after warm-up", function()
  local s = H.new_stack({ sim = { power = "0", input = "31", warm_ms = 20 * SEC } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  s.projector:power_on()
  s.projector:select_input("32")
  s.clock:advance(15 * SEC)
  t.eq(s.sim:count("INPT 32"), 0, "input must not be sent during warm-up")
  s.clock:advance(60 * SEC)
  t.eq(s.sim.power, "1")
  t.eq(s.sim.input, "32")
  t.eq(s.sim:count("INPT 32"), 1)
end)

t.test("select_input of the current input sends nothing", function()
  local s = H.new_stack({ sim = { power = "1", input = "31" } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:select_input("31")
  s.clock:advance(10 * SEC)
  t.eq(s.sim:count("INPT 31"), 0)
end)

t.test("an unsupported input (ERR2) is dropped, not retried forever", function()
  local s = H.new_stack({ sim = { power = "1", inputs = { "31", "32" } } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:select_input("99")
  s.clock:advance(60 * SEC)
  t.eq(s.sim:count("INPT 99"), 1)
  t.eq(s.projector.want.input, nil)
end)

t.suite("projector: intent lifetime")

t.test("an unmet request expires, so a late reconnect does not surprise-power-on the room", function()
  local s = H.new_stack({ sim = { power = "0", reachable = false } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  s.projector:power_on()
  s.clock:advance(200 * SEC) -- longer than the 180s TTL
  s.sim.reachable = true
  s.clock:advance(120 * SEC)
  t.eq(s.sim:count("POWR 1"), 0)
  t.eq(s.sim.power, "0")
  t.eq(s.projector.want.power, nil)
end)

t.test("a request made while offline is honoured if the projector comes back within the TTL", function()
  local s = H.new_stack({ sim = { power = "0", reachable = false } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  s.projector:power_on()
  s.clock:advance(20 * SEC)
  s.sim.reachable = true
  s.clock:advance(120 * SEC)
  t.eq(s.sim:count("POWR 1"), 1)
end)

t.suite("projector: connectivity")

t.test("an unreachable projector goes OFFLINE after the failure threshold", function()
  local s = H.new_stack({ sim = { reachable = false } })
  s.projector:start()
  s.clock:advance(3 * SEC)
  t.eq(s.projector.state, nil, "one failure is not enough")
  s.clock:advance(70 * SEC)
  t.eq(s.projector.state, "OFFLINE")
  local status = s.of("status")
  t.contains(status[#status][1], "Offline")
end)

t.test("a startup failure does not claim the link was 'lost'", function()
  local s = H.new_stack({ sim = { reachable = false } })
  s.projector:start()
  s.clock:advance(120 * SEC)
  local link = s.of("link")
  t.eq(#link, 1)
  t.eq(link[1][1], false)
  t.eq(link[1][2], nil, "was = nil => glue must not fire Connection Lost")
end)

t.test("losing a working link reports was=true, and recovery reports was=false", function()
  local s = H.new_stack({ sim = { power = "1" } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.sim.reachable = false
  s.clock:advance(200 * SEC)
  t.eq(s.projector.state, "OFFLINE")
  s.sim.reachable = true
  s.clock:advance(200 * SEC)
  t.eq(s.projector.state, "ON")

  local link = s.of("link")
  t.eq(#link, 3)
  t.eq(link[1][1], true)
  t.eq(link[2][1], false); t.eq(link[2][2], true)
  t.eq(link[3][1], true); t.eq(link[3][2], false)
end)

t.test("state events after an outage carry the last real state as 'prev'", function()
  local s = H.new_stack({ sim = { power = "1" } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.sim.reachable = false
  s.clock:advance(200 * SEC)
  s.sim.reachable = true
  s.clock:advance(200 * SEC)
  local st = s.of("state")
  -- ON(prev nil), OFFLINE(prev ON), ON(prev ON): glue sees new == prev and fires no event
  t.eq(st[#st][1], "ON")
  t.eq(st[#st][2], "ON")
end)

t.test("while offline the poll interval backs off", function()
  local s = H.new_stack({ sim = { reachable = false }, config = { idle_interval = 10, offline_interval = 60 } })
  s.projector:start()
  s.clock:advance(600 * SEC)
  t.truthy(s.sim.connects <= 14, "too many connection attempts while offline: " .. s.sim.connects)
end)

t.test("authentication failure is reported and polling backs off to avoid a lockout", function()
  local s = H.new_stack({ sim = { password = "secret" }, password = "wrong" })
  s.projector:start()
  s.clock:advance(10 * SEC)
  t.truthy(s.projector.auth_failed)
  local status = s.of("status")
  t.contains(status[#status][1], "Authentication failed")
  local attempts = s.sim.auth_failures
  s.clock:advance(250 * SEC) -- still inside the 300s locked interval
  t.eq(s.sim.auth_failures, attempts, "must not hammer the projector with bad passwords")
end)

t.test("reset_auth after fixing the password reconnects immediately", function()
  local s = H.new_stack({ sim = { password = "secret", power = "0" }, password = "wrong" })
  s.projector:start()
  s.clock:advance(10 * SEC)
  t.truthy(s.projector.auth_failed)
  s.client:set_password("secret")
  s.projector:reset_auth()
  s.clock:advance(10 * SEC)
  t.falsy(s.projector.auth_failed)
  t.eq(s.projector.state, "STANDBY")
end)

t.suite("projector: faults and light source")

t.test("a fault raises fault(true) once and clearing raises fault(false)", function()
  local s = H.new_stack({ sim = { power = "1", erst = "000000" }, config = { idle_interval = 10 } })
  s.projector:start()
  s.clock:advance(15 * SEC)
  s.sim.erst = "200000"
  s.clock:advance(40 * SEC)
  s.sim.erst = "000000"
  s.clock:advance(40 * SEC)
  local f = s.of("fault")
  t.eq(#f, 3, "initial OK, fault, cleared")
  t.eq(f[1][1], false)
  t.eq(f[2][1], true); t.eq(f[2][2], "Error: fan"); t.eq(f[2][3], false)
  t.eq(f[3][1], false); t.eq(f[3][3], true)
end)

t.test("fault text changes are reported without re-arming the 'fault' transition", function()
  local s = H.new_stack({ sim = { power = "1", erst = "200000" }, config = { idle_interval = 10 } })
  s.projector:start()
  s.clock:advance(15 * SEC)
  s.sim.erst = "220000"
  s.clock:advance(30 * SEC)
  local f = s.of("fault")
  t.eq(f[#f][1], true)
  t.eq(f[#f][3], true, "prev was already active")
end)

t.test("light source alert fires once at the threshold", function()
  local s = H.new_stack({
    sim = { power = "1", lamp = "1500 1" },
    config = { lamp_alert = 1000, idle_interval = 30, lamp_interval = 60 },
  })
  s.projector:start()
  s.clock:advance(600 * SEC)
  t.eq(#s.of("lamp_alert"), 1)
  t.eq(s.of("lamp_alert")[1][1], 1500)
end)

t.test("light source alert re-arms after hours drop below the threshold", function()
  local s = H.new_stack({
    sim = { power = "1", lamp = "1500 1" },
    config = { lamp_alert = 1000, idle_interval = 30, lamp_interval = 60 },
  })
  s.projector:start()
  s.clock:advance(200 * SEC)
  s.sim.lamp = "10 1" -- lamp replaced
  s.clock:advance(200 * SEC)
  s.sim.lamp = "1200 1"
  s.clock:advance(200 * SEC)
  t.eq(#s.of("lamp_alert"), 2)
end)

t.test("no alert when the threshold is 0 (disabled)", function()
  local s = H.new_stack({ sim = { power = "1", lamp = "99999 1" }, config = { lamp_alert = 0 } })
  s.projector:start()
  s.clock:advance(300 * SEC)
  t.eq(#s.of("lamp_alert"), 0)
end)

t.suite("projector: diagnostics")

t.test("read_inputs parses the INST? reply and notifies", function()
  local s = H.new_stack({ sim = { power = "0", inputs = { "31", "32", "53" } } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  local got
  s.projector:read_inputs(function(res, list) got = list end)
  s.clock:advance(5 * SEC)
  t.eq(#got, 3)
  t.eq(got[1].name, "Digital 1")
  t.eq(got[3].code, "53")
  t.eq(#s.of("inputs"), 1)
end)

t.test("test() reports success and failure", function()
  local s = H.new_stack({ sim = { power = "1" } })
  local res
  s.projector:test(function(r) res = r end)
  s.clock:advance(5 * SEC)
  t.truthy(res.ok)
  t.eq(res.value, "1")

  s.sim.reachable = false
  s.projector:test(function(r) res = r end)
  s.clock:advance(5 * SEC)
  t.falsy(res.ok)
  t.eq(res.err, "CONNECT")
end)

t.test("configure ignores unknown keys and non-numbers", function()
  local s = H.new_stack({})
  s.projector:configure({ idle_interval = 45, bogus = 1, fast_interval = "x", lamp_alert = nil })
  t.eq(s.projector.cfg.idle_interval, 45)
  t.eq(s.projector.cfg.fast_interval, 3)
  t.eq(s.projector.cfg.bogus, nil)
end)

t.suite("projector: review fixes")

t.test("a projector that rejects INF2 is asked once, not on every poll", function()
  local s = H.new_stack({ sim = { power = "0" }, config = { idle_interval = 30 } })
  local orig = getmetatable(s.sim)._handle
  s.sim._handle = function(self, body, param)
    if body == "INF2" then return "ERR2" end
    return orig(self, body, param)
  end
  s.projector:start()
  s.clock:advance(300 * SEC)
  t.truthy(s.sim:count("POWR ?") >= 8)
  t.eq(s.sim:count("INF2 ?"), 1)
end)

t.test("a slow input switch does not flicker back to the old input", function()
  local s = H.new_stack({ sim = { power = "1", input = "32" } })
  local orig = getmetatable(s.sim)._handle
  s.sim._handle = function(self, body, param)
    if body == "INPT" and param ~= "?" and self.power == "1" then
      self:_after(5 * SEC, function() self.input = param end) -- applied late
      return "OK"
    end
    return orig(self, body, param)
  end
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:select_input("33")
  s.clock:advance(30 * SEC)
  local seen = {}
  for _, e in ipairs(s.of("input")) do seen[#seen + 1] = e[1] end
  t.deep_eq(seen, { "32", "33" })
  t.eq(s.projector.input, "33")
end)

t.test("if the switch really failed, the real input is reported after the window", function()
  local s = H.new_stack({ sim = { power = "1", input = "32" } })
  local orig = getmetatable(s.sim)._handle
  s.sim._handle = function(self, body, param)
    if body == "INPT" and param ~= "?" and self.power == "1" then return "OK" end -- never applied
    return orig(self, body, param)
  end
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:select_input("33")
  s.clock:advance(30 * SEC)
  t.eq(s.projector.input, "32")
end)
