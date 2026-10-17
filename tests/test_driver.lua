local t = require "tests.lib_test"
local H = require "tests.helpers"
local md5 = require "lib.pjl_md5"
local WebSim = require "tests.http_helpers"

local SEC = 1000

-- Load the real driver.lua against a mocked Control4 environment ------------------------

local function load_driver(opts)
  opts = opts or {}
  local clock = H.new_clock()
  local sim = H.new_sim(clock, opts.sim)
  local web = opts.web_sim and WebSim.new_sim(clock, opts.web_sim)
  local rec = {
    proxy = {}, events = {}, props = {}, vars = {}, vars_added = {},
    created = {}, debug = {}, printed = {}, hash_calls = 0,
  }

  local Properties = {}
  for k, v in pairs((H.xml_property_defaults())) do Properties[k] = v end
  for k, v in pairs(opts.props or {}) do Properties[k] = v end

  local C4 = {}
  function C4:AddVariable(name, value, typ) rec.vars_added[name] = typ end
  function C4:SetVariable(name, value) rec.vars[name] = value end
  function C4:UpdateProperty(name, value) rec.props[name] = value; Properties[name] = value end
  function C4:FireEvent(name) rec.events[#rec.events + 1] = name end
  function C4:SendToProxy(id, cmd, params, msg)
    rec.proxy[#rec.proxy + 1] = { id = id, cmd = cmd, params = params, msg = msg }
  end
  function C4:CreateNetworkConnection(id, ip, typ)
    rec.created[#rec.created + 1] = { id = id, ip = ip, type = typ }
  end
  function C4:DebugLog(line) rec.debug[#rec.debug + 1] = line end
  function C4:SetTimer(ms, fn)
    return clock:set_timer(ms, function(timer) fn(timer, 0) end)
  end
  function C4:url()
    local obj, on_done, options = {}, nil, {}
    function obj:OnDone(fn) on_done = fn; return self end
    function obj:SetOptions(t) options = t; return self end
    function obj:Get(url, headers)
      assert(web, "driver made an HTTP request but the test has no web simulator")
      rec.http_options = options
      web:env().get(url, headers, options.timeout or 5, function(r)
        if r.err then
          on_done(nil, {}, (r.err == "TIMEOUT") and 28 or 7, r.err)
        else
          on_done(nil, { { code = r.code, headers = r.headers, body = r.body } }, 0, "")
        end
      end)
      return self
    end
    return obj
  end
  local sim_env = sim:env()
  function C4:NetConnect(id, port) sim_env.connect(nil, port) end
  function C4:NetDisconnect(id, port) sim_env.disconnect() end
  function C4:SendToNetwork(id, port, data) sim_env.send(data) end
  function C4:Hash(digest, data, options)
    if opts.hash == "real" then
      assert(digest == "MD5", "expected MD5 digest")
      assert(options and options.return_encoding == "HEX", "expected HEX output")
      rec.hash_calls = rec.hash_calls + 1
      return md5.hex(data)
    elseif opts.hash == "broken" then
      return nil, "unsupported digest"
    end
    error("C4:Hash not available")
  end

  local env = setmetatable({
    C4 = C4,
    Properties = Properties,
    print = function(...) rec.printed[#rec.printed + 1] = table.concat({ ... }, " ") end,
    os = setmetatable({ time = function() return clock:now() end }, { __index = os }),
  }, { __index = _G })

  local chunk = assert(loadfile("driver.lua"))
  setfenv(chunk, env)
  chunk()

  sim:attach({
    on_status = function(_, s) env.OnConnectionStatusChanged(6001, 4352, s) end,
    on_data = function(_, d) env.ReceivedFromNetwork(6001, 4352, d) end,
  })

  local d = { env = env, clock = clock, sim = sim, web = web, rec = rec, props = Properties }

  function d:boot()
    env.OnDriverInit()
    env.OnDriverLateInit()
  end

  --- Set a property the way Composer does: change it, then call OnPropertyChanged.
  function d:set(name, value)
    Properties[name] = value
    env.OnPropertyChanged(name)
  end

  function d:connect(ip)
    self:boot()
    self:set("IP Address", ip or "192.168.1.50")
  end

  function d:action(name, params)
    local p = { ACTION = name }
    for k, v in pairs(params or {}) do p[k] = v end
    env.ExecuteCommand("LUA_ACTION", p)
  end

  function d:proxy_cmds()
    local out = {}
    for _, p in ipairs(rec.proxy) do out[#out + 1] = p.cmd end
    return out
  end

  --- Only the ON/OFF power notifications sent to the proxy.
  function d:power_notifications()
    local out = {}
    for _, p in ipairs(rec.proxy) do
      if p.cmd == "ON" or p.cmd == "OFF" then out[#out + 1] = p.cmd end
    end
    return out
  end

  function d:count_event(name)
    local n = 0
    for _, e in ipairs(rec.events) do if e == name then n = n + 1 end end
    return n
  end

  return d
end

t.suite("driver: initialisation")

t.test("registers variables, sets the version and waits for an IP address", function()
  local d = load_driver()
  d:boot()
  t.eq(d.rec.vars_added.POWER_STATE, "STRING")
  t.eq(d.rec.vars_added.CURRENT_INPUT, "STRING")
    t.eq(d.rec.vars_added.FAULT_STATUS, "STRING")
  t.eq(d.rec.vars_added.LIGHT_SOURCE_HOURS, "NUMBER")
  t.eq(d.rec.vars_added.CONNECTED, "BOOL")
  t.eq(d.rec.props["Driver Version"], d.env.DRIVER_VERSION)
  t.eq(d.rec.props["Connection Status"], "Set the IP Address property")
  t.eq(#d.rec.created, 0)
  d.clock:advance(60 * SEC)
  t.eq(d.sim.connects, 0, "must not try to connect without an address")
end)

t.test("entering an IP creates the TCP network binding and starts polling", function()
  local d = load_driver({ sim = { power = "0" } })
  d:boot()
  d:set("IP Address", "  192.168.1.50 ")
  t.deep_eq(d.rec.created, { { id = 6001, ip = "192.168.1.50", type = "TCP" } })
  t.eq(d.rec.props["Connection Status"], "Connecting...")
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Connection Status"], "Connected")
  t.eq(d.rec.props["Power State"], "Standby")
  t.eq(d.rec.vars.POWER_STATE, "Standby")
  t.eq(d.rec.vars.CONNECTED, "1")
end)

t.test("changing the IP re-creates the connection; clearing it stops activity", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect("192.168.1.50")
  d.clock:advance(5 * SEC)
  d:set("IP Address", "192.168.1.51")
  t.eq(#d.rec.created, 2)
  t.eq(d.rec.created[2].ip, "192.168.1.51")
  d.clock:advance(5 * SEC)
  d:set("IP Address", "")
  t.eq(d.rec.props["Connection Status"], "Set the IP Address property")
  d.clock:advance(2 * SEC)
  local before = d.sim.connects
  d.clock:advance(120 * SEC)
  t.eq(d.sim.connects, before)
end)

t.test("OnDriverDestroyed stops all activity", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect()
  d.clock:advance(5 * SEC)
  d.env.OnDriverDestroyed()
  d.clock:advance(2 * SEC)
  local before = d.sim.connects
  d.clock:advance(300 * SEC)
  t.eq(d.sim.connects, before)
end)

t.test("network events for other bindings are ignored", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect()
  d.env.OnConnectionStatusChanged(6002, 4352, "ONLINE")
  d.env.ReceivedFromNetwork(6002, 4352, "PJLINK 0\r")
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Power State"], "Standby")
end)

t.suite("driver: Projector proxy")

t.test("ON powers the projector on and notifies Navigator once per transition", function()
  local d = load_driver({ sim = { power = "0", warm_ms = 20 * SEC } })
  d:connect()
  d.clock:advance(5 * SEC)
  d.env.ReceivedFromProxy(5001, "ON", {})
  d.clock:advance(60 * SEC)
  t.deep_eq(d:power_notifications(), { "OFF", "ON" })
  for _, p in ipairs(d.rec.proxy) do
    t.eq(p.id, 5001)
    if p.cmd == "ON" or p.cmd == "OFF" then
      t.eq(p.msg, "NOTIFY", "power changes are NOTIFY messages, like Control4's certified Epson driver")
    end
  end
  t.eq(d.sim.power, "1")
  t.eq(d.rec.props["Power State"], "On")
end)

t.test("OFF powers off; cooling already reads as off for Navigator", function()
  local d = load_driver({ sim = { power = "1", cool_ms = 30 * SEC } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.clock:advance(90 * SEC)
  t.deep_eq(d:power_notifications(), { "ON", "OFF" })
  t.eq(d.sim.power, "0")
end)

t.test("SET_INPUT maps the input binding to the configured PJLink code", function()
  local d = load_driver({ sim = { power = "1", input = "32" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 1022 })
  d.clock:advance(10 * SEC)
  t.eq(d.sim.input, "33")
  t.eq(d.rec.props["Current Input"], "HDMI 2")
end)

t.test("an input change is announced for BOTH the audio twin and the video binding", function()
  local d = load_driver({ sim = { power = "1", input = "32" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.rec.proxy = {}
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 1022 })
  d.clock:advance(10 * SEC)
  local sent = {}
  for _, p in ipairs(d.rec.proxy) do
    if p.cmd == "INPUT_CHANGED" then
      sent[#sent + 1] = p.params.INPUT
      t.eq(p.msg, "NOTIFY")
    end
  end
  t.deep_eq(sent, { 3022, 1022 })
end)

t.test("powering off resets the proxy's input to -1 (twice), and power-on re-announces the input", function()
  local d = load_driver({ sim = { power = "1", input = "33", cool_ms = 10 * SEC, warm_ms = 10 * SEC } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.rec.proxy = {}
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.clock:advance(60 * SEC)
  local resets = 0
  for _, p in ipairs(d.rec.proxy) do
    if p.cmd == "INPUT_CHANGED" and p.params.INPUT == -1 then resets = resets + 1 end
  end
  t.eq(resets, 2)
  d.rec.proxy = {}
  d.env.ReceivedFromProxy(5001, "ON", {})
  d.clock:advance(60 * SEC)
  local back = {}
  for _, p in ipairs(d.rec.proxy) do
    if p.cmd == "INPUT_CHANGED" and p.params.INPUT > 0 then back[#back + 1] = p.params.INPUT end
  end
  t.deep_eq(back, { 3022, 1022 }, "the input is announced again after power-on")
  t.eq(d:count_event("Input Changed"), 0, "re-announcing is not an input change event")
end)

t.test("the current input is reported to the proxy at startup without firing an event", function()
  local d = load_driver({ sim = { power = "1", input = "32" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.eq(d.rec.props["Current Input"], "HDMI 1")
  t.eq(d:count_event("Input Changed"), 0)
  local found
  for _, p in ipairs(d.rec.proxy) do
    if p.cmd == "INPUT_CHANGED" and p.params.INPUT == 1021 then found = true end
  end
  t.truthy(found)
end)

t.test("SET_INPUT accepts the audio-range twin binding (3022) as well as the video one (1021/1022)", function()
  local d = load_driver({ sim = { power = "1", input = "32" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 3022 })
  d.clock:advance(10 * SEC)
  t.eq(d.sim.input, "33")
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1021" })
  d.clock:advance(10 * SEC)
  t.eq(d.sim.input, "32")
end)

t.test("custom input codes from properties are honoured", function()
  local d = load_driver({
    sim = { power = "1", input = "32", inputs = { "32", "35" } },
    props = { ["HDMI 2 Input Code"] = "35" },
  })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 1022 })
  d.clock:advance(10 * SEC)
  t.eq(d.sim.input, "35")
end)

t.test("an invalid input-code property falls back to the default", function()
  local d = load_driver({
    sim = { power = "1", input = "32" },
    props = { ["HDMI 2 Input Code"] = "not a code", ["Log Level"] = "Debug", ["Log Output"] = "Print" },
  })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 1022 })
  d.clock:advance(10 * SEC)
  t.eq(d.sim.input, "33")
end)

t.test("SET_INPUT for an unknown binding is ignored safely", function()
  local d = load_driver({ sim = { power = "1" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 1234 })
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "abc" })
  d.env.ReceivedFromProxy(5001, "SET_INPUT", nil)
  d.clock:advance(10 * SEC)
  for _, c in ipairs(d.sim.commands) do
    t.falsy(c:match("^INPT %d"), "unexpected input command: " .. c)
  end
end)

t.test("commands for other bindings and unknown proxy commands are ignored", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect()
  d.clock:advance(5 * SEC)
  d.env.ReceivedFromProxy(5999, "ON", {})
  d.env.ReceivedFromProxy(5001, "SOMETHING_ELSE", {})
  d.clock:advance(30 * SEC)
  t.eq(d.sim:count("POWR 1"), 0)
end)

t.suite("driver: events")

t.test("power transitions fire the matching events; startup fires none", function()
  local d = load_driver({ sim = { power = "0", warm_ms = 20 * SEC, cool_ms = 20 * SEC } })
  d:connect()
  d.clock:advance(5 * SEC)
  t.deep_eq(d.rec.events, {}, "no events just from discovering the initial state")
  d.env.ReceivedFromProxy(5001, "ON", {})
  d.clock:advance(60 * SEC)
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.clock:advance(90 * SEC)
  t.deep_eq(d.rec.events, {
    "Projector Warming Up", "Projector Powered On",
    "Projector Cooling Down", "Projector Powered Off",
  })
end)

t.test("Input Changed fires on a real change only", function()
  local d = load_driver({ sim = { power = "1", input = "32" }, props = { ["Idle Polling Interval (seconds)"] = "10" } })
  d:connect()
  d.clock:advance(20 * SEC)
  t.eq(d:count_event("Input Changed"), 0)
  d.sim.input = "33" -- changed with the remote
  d.clock:advance(30 * SEC)
  t.eq(d:count_event("Input Changed"), 1)
  d.clock:advance(60 * SEC)
  t.eq(d:count_event("Input Changed"), 1, "no repeats while the input is unchanged")
end)

t.test("Connection Lost / Restored fire once each, with no spurious power events", function()
  local d = load_driver({ sim = { power = "1" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.sim.reachable = false
  d.clock:advance(200 * SEC)
  t.eq(d:count_event("Connection Lost"), 1)
  t.eq(d.rec.vars.CONNECTED, "0")
  t.eq(d.rec.props["Power State"], "Offline")
  d.sim.reachable = true
  d.clock:advance(200 * SEC)
  t.eq(d:count_event("Connection Restored"), 1)
  t.eq(d.rec.vars.CONNECTED, "1")
  t.eq(d:count_event("Projector Powered On"), 0)
  t.eq(d:count_event("Projector Powered Off"), 0)
  t.eq(d.rec.props["Power State"], "On")
end)

t.test("an unreachable projector at startup does not fire Connection Lost", function()
  local d = load_driver({ sim = { reachable = false } })
  d:connect()
  d.clock:advance(120 * SEC)
  t.eq(d:count_event("Connection Lost"), 0)
  t.eq(d.rec.props["Connection Status"], "Offline - projector not responding")
end)

t.test("Projector Fault and Fault Cleared", function()
  local d = load_driver({ sim = { power = "1", erst = "200000" }, props = { ["Idle Polling Interval (seconds)"] = "10" } })
  d:connect()
  d.clock:advance(20 * SEC)
  t.eq(d:count_event("Projector Fault"), 1)
  t.eq(d.rec.props["Fault Status"], "Error: fan")
  t.eq(d.rec.vars.FAULT_STATUS, "Error: fan")
  d.clock:advance(60 * SEC)
  t.eq(d:count_event("Projector Fault"), 1, "not re-fired while the fault persists")
  d.sim.erst = "000000"
  d.clock:advance(30 * SEC)
  t.eq(d:count_event("Projector Fault Cleared"), 1)
  t.eq(d.rec.props["Fault Status"], "OK")
end)

t.test("Light Source Hours Alert fires once and updates the variable and property", function()
  local d = load_driver({ sim = { power = "1", lamp = "1500 1" } })
  d:connect()
  d:set("Light Source Hours Alert", "1000")
  d.clock:advance(10 * 60 * SEC)
  t.eq(d:count_event("Light Source Hours Alert"), 1)
  t.eq(d.rec.props["Light Source Hours"], "1500")
  t.eq(d.rec.vars.LIGHT_SOURCE_HOURS, "1500")
end)

t.suite("driver: Actions tab and Programming commands")

t.test("Power On / Power Off actions", function()
  local d = load_driver({ sim = { power = "0", warm_ms = 10 * SEC, cool_ms = 10 * SEC } })
  d:connect()
  d.clock:advance(5 * SEC)
  d:action("PowerOn")
  d.clock:advance(60 * SEC)
  t.eq(d.sim.power, "1")
  d:action("PowerOff")
  d.clock:advance(90 * SEC)
  t.eq(d.sim.power, "0")
end)

t.test("Select Input action uses the input name", function()
  local d = load_driver({ sim = { power = "1", input = "32" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d:action("SelectInput", { Input = "HDMI 2" })
  d.clock:advance(10 * SEC)
  t.eq(d.sim.input, "33")
  d:action("SelectInput", { Input = "Nonexistent" }) -- ignored
  d:action("SelectInput", {})
end)

t.test("Poll Now triggers an immediate poll", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect()
  d.clock:advance(5 * SEC)
  local before = d.sim:count("POWR ?")
  d:action("PollNow")
  d.clock:advance(3 * SEC)
  t.eq(d.sim:count("POWR ?"), before + 1)
end)

t.test("Read Input List fills the Available Inputs property", function()
  local d = load_driver({ sim = { power = "0", inputs = { "32", "33", "51" } } })
  d:connect()
  d.clock:advance(5 * SEC)
  d:action("ReadInputList")
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Available Inputs"], "32 (HDMI 1), 33 (HDMI 2), 51 (Network 1)")
end)

t.test("Read Input List reports failure", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect()
  d.clock:advance(5 * SEC)
  d.sim.reachable = false
  d:action("ReadInputList")
  d.clock:advance(10 * SEC)
  t.contains(d.rec.props["Available Inputs"], "Read failed")
end)

t.test("Test Connection reports success and failure", function()
  local d = load_driver({ sim = { power = "1" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d:action("TestConnection")
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Last Test Result"], "OK - projector reports 1")
  d.sim.reachable = false
  d:action("TestConnection")
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Last Test Result"], "Failed - CONNECT")
end)

t.test("Request Timeout property controls how long Test Connection waits", function()
  local d = load_driver({ sim = { power = "1" }, props = { ["Request Timeout (seconds)"] = "2" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.sim.mute = true
  d:action("TestConnection")
  d.clock:advance(1500)
  t.eq(d.props["Last Test Result"], "Not run", "still waiting for the projector")
  d.clock:advance(3 * SEC)
  t.eq(d.rec.props["Last Test Result"], "Failed - TIMEOUT")
end)

t.test("Reset Connection clears a pending lockout", function()
  local d = load_driver({ sim = { power = "0", password = "secret" }, props = { ["PJLink Password"] = "wrong" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.contains(d.rec.props["Connection Status"], "Authentication failed")
  d.props["PJLink Password"] = "secret"
  d:action("ResetConnection")
  d.clock:advance(10 * SEC)
  t.eq(d.rec.props["Connection Status"], "Connected")
end)

t.test("Select Input Code validates the code", function()
  local d = load_driver({ sim = { power = "1", input = "32", inputs = { "32", "33", "51" } } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ExecuteCommand("Select Input Code", { Code = " 51 " })
  d.clock:advance(10 * SEC)
  t.eq(d.sim.input, "51")
  d.env.ExecuteCommand("Select Input Code", { Code = "ABC" })
  d.env.ExecuteCommand("Select Input Code", {})
  d.clock:advance(10 * SEC)
  t.eq(d.sim:count("INPT ABC"), 0)
  t.eq(d.sim.input, "51")
end)

t.test("unknown commands and actions do not raise", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect()
  d.env.ExecuteCommand("NoSuchCommand", {})
  d.env.ExecuteCommand("LUA_ACTION", { ACTION = "NoSuchAction" })
  d.env.ExecuteCommand("LUA_ACTION", nil)
  d.env.ExecuteCommand(nil, nil)
end)

t.test("commands before initialisation are ignored safely", function()
  local d = load_driver()
  d.env.ExecuteCommand("Video Blank On", {})
  d.env.ReceivedFromProxy(5001, "ON", {})
  d.env.OnPropertyChanged("IP Address")
  d.env.OnConnectionStatusChanged(6001, 4352, "ONLINE")
  d.env.ReceivedFromNetwork(6001, 4352, "PJLINK 0\r")
end)

t.suite("driver: conditionals")

local function cond(d, name, logic, value)
  return d.env.TestCondition(name, { LOGIC = logic, VALUE = value })
end

t.test("POWER_STATE compares against the readable state names", function()
  local d = load_driver({ sim = { power = "1" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.truthy(cond(d, "POWER_STATE", "EQUAL", "On"))
  t.falsy(cond(d, "POWER_STATE", "EQUAL", "Standby"))
  t.falsy(cond(d, "POWER_STATE", "NOT_EQUAL", "On"))
  t.truthy(cond(d, "POWER_STATE", "NOT_EQUAL", "Standby"))
end)

t.test("POWER_STATE reflects warming, cooling and offline", function()
  local d = load_driver({ sim = { power = "0", warm_ms = 30 * SEC, cool_ms = 30 * SEC } })
  d:connect()
  d.clock:advance(5 * SEC)
  t.truthy(cond(d, "POWER_STATE", "EQUAL", "Standby"))
  d.env.ReceivedFromProxy(5001, "ON", {})
  d.clock:advance(8 * SEC)
  t.truthy(cond(d, "POWER_STATE", "EQUAL", "Warming Up"))
  d.clock:advance(60 * SEC)
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.clock:advance(8 * SEC)
  t.truthy(cond(d, "POWER_STATE", "EQUAL", "Cooling Down"))
  d.clock:advance(120 * SEC)
  d.sim.reachable = false
  d.clock:advance(200 * SEC)
  t.truthy(cond(d, "POWER_STATE", "EQUAL", "Offline"))
end)

t.test("CURRENT_INPUT: HDMI 1, HDMI 2 and Other", function()
  local d = load_driver({ sim = { power = "1", input = "32", inputs = { "32", "33", "51" } } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.truthy(cond(d, "CURRENT_INPUT", "EQUAL", "HDMI 1"))
  d:action("SelectInput", { Input = "HDMI 2" })
  d.clock:advance(10 * SEC)
  t.truthy(cond(d, "CURRENT_INPUT", "EQUAL", "HDMI 2"))
  d.env.ExecuteCommand("Select Input Code", { Code = "51" })
  d.clock:advance(10 * SEC)
  t.truthy(cond(d, "CURRENT_INPUT", "EQUAL", "Other"))
  t.truthy(cond(d, "CURRENT_INPUT", "NOT_EQUAL", "HDMI 1"))
end)

t.test("FAULT_ACTIVE (boolean conditional)", function()
  local d = load_driver({ sim = { power = "1", erst = "200000" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.truthy(cond(d, "FAULT_ACTIVE", nil, "Active"))
  t.falsy(cond(d, "FAULT_ACTIVE", nil, "None"))
  d.sim.erst = "000000"
  d:action("PollNow")
  d.clock:advance(10 * SEC)
  t.truthy(cond(d, "FAULT_ACTIVE", nil, "None"))
end)

t.test("LIGHT_SOURCE_HOURS supports all numeric comparisons", function()
  local d = load_driver({ sim = { power = "1", lamp = "1500 1" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.truthy(cond(d, "LIGHT_SOURCE_HOURS", "EQUAL", "1500"))
  t.truthy(cond(d, "LIGHT_SOURCE_HOURS", "NOT_EQUAL", "1000"))
  t.truthy(cond(d, "LIGHT_SOURCE_HOURS", "GREATER_THAN", "1000"))
  t.truthy(cond(d, "LIGHT_SOURCE_HOURS", "GREATER_THAN_OR_EQUAL", "1500"))
  t.falsy(cond(d, "LIGHT_SOURCE_HOURS", "LESS_THAN", "1500"))
  t.truthy(cond(d, "LIGHT_SOURCE_HOURS", "LESS_THAN_OR_EQUAL", "1500"))
end)

t.test("unknown conditionals and missing params evaluate to false without raising", function()
  local d = load_driver()
  d:boot()
  t.falsy(d.env.TestCondition("NOPE", {}))
  t.falsy(d.env.TestCondition("POWER_STATE", nil))
  t.falsy(cond(d, "POWER_STATE", "EQUAL", "On"))
end)

t.suite("driver: Web (HTTP) control method")

local WEB = "Web (HTTP)"

local function web_driver(opts)
  opts = opts or {}
  local props = { ["Control Method"] = WEB }
  for k, v in pairs(opts.props or {}) do props[k] = v end
  return load_driver({ web_sim = opts.sim or {}, props = props })
end

t.test("the web method polls over HTTP and never opens the PJLink network binding", function()
  local d = web_driver({ sim = { power = "04" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.eq(#d.rec.created, 0)
  t.eq(d.sim.connects, 0)
  t.eq(d.rec.props["Connection Status"], "Connected")
  t.eq(d.rec.props["Power State"], "Standby")
  t.truthy(d.web:count_queries("PWR?") >= 1)
end)

t.test("web: power on and off through the proxy", function()
  local d = web_driver({ sim = { power = "04", warm_ms = 10 * SEC, cool_ms = 10 * SEC } })
  d:connect()
  d.clock:advance(5 * SEC)
  d.env.ReceivedFromProxy(5001, "ON", {})
  d.clock:advance(60 * SEC)
  t.eq(d.web.power, "01")
  t.eq(d.web:count("IMPWR=ON"), 1)
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.clock:advance(60 * SEC)
  t.eq(d.web.power, "04")
  t.eq(d.web:count("IMPWR=OFF"), 1, "one discrete off request by default")
  t.eq(d.web:count("KEY=6C"), 0, "the toggling power key is not used by default")
  t.deep_eq(d:power_notifications(), { "OFF", "ON", "OFF" })
  t.eq(d:count_event("Projector Powered On"), 1)
  t.eq(d:count_event("Projector Powered Off"), 1)
end)

t.test("web: Power Off Request empty falls back to the key; Presses and Key are honoured", function()
  local d = web_driver({
    sim = { power = "01", off_presses = 2, cool_ms = 10 * SEC },
    props = { ["Power Off Request"] = "", ["Power Off Key Presses"] = "2", ["Power Off Key"] = "6C" },
  })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.clock:advance(60 * SEC)
  t.eq(d.web:count("KEY=6C"), 2)
  t.eq(d.web.power, "04")
end)

t.test("web: pressing Off again, even straight after, never switches the projector back on", function()
  local d = web_driver({ sim = { power = "01", cool_ms = 10 * SEC } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.clock:advance(2 * SEC)
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.clock:advance(60 * SEC)
  t.eq(d.web.power, "04")
  d.env.ReceivedFromProxy(5001, "OFF", {})
  d.clock:advance(30 * SEC)
  t.eq(d.web.power, "04", "still in standby")
  t.eq(d.web:count("IMPWR=ON"), 0)
  t.truthy(d.web:count("IMPWR=OFF") <= 1, "off sent " .. d.web:count("IMPWR=OFF") .. " times")
end)

t.test("web: input readback uses ESC/VP21 codes and announces both bindings", function()
  local d = web_driver({ sim = { power = "01", source = "30" }, props = { ["Idle Polling Interval (seconds)"] = "10" } })
  d:connect()
  d.clock:advance(20 * SEC)
  t.eq(d.rec.props["Current Input"], "HDMI 1")
  d.rec.proxy = {}
  d.web.source = "A0"
  d.clock:advance(30 * SEC)
  t.eq(d.rec.props["Current Input"], "HDMI 2")
  t.eq(d:count_event("Input Changed"), 1)
  local sent = {}
  for _, p in ipairs(d.rec.proxy) do
    if p.cmd == "INPUT_CHANGED" then sent[#sent + 1] = p.params.INPUT end
  end
  t.deep_eq(sent, { 3022, 1022 })
end)

t.test("web: SET_INPUT sends the configured select request", function()
  local d = web_driver({
    sim = { power = "01", source = "30" },
    props = { ["HDMI 2 Select Request"] = "KEY=40", ["HDMI 1 Select Request"] = "KEY=4D" },
  })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 1022 })
  d.clock:advance(15 * SEC)
  t.eq(d.web.source, "A0")
  t.eq(d.web:count("KEY=40"), 1)
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 1021 })
  d.clock:advance(15 * SEC)
  t.eq(d.web.source, "30")
end)

t.test("web: with no select request configured, an input change is dropped safely", function()
  local d = web_driver({ sim = { power = "01", source = "30" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 1022 })
  d.clock:advance(60 * SEC)
  t.eq(d.web.source, "30")
  for _, c in ipairs(d.web.commands) do t.falsy(c:match("^KEY=4"), "unexpected key " .. c) end
  t.eq(d.rec.props["Connection Status"], "Connected")
end)

t.test("web: no select request is sent when the wanted input is already active", function()
  -- The LS12000B remote has one [HDMI1]/[HDMI2] key that toggles, so both inputs may share a
  -- request. The reconciler is state-aware: it only presses when the input differs.
  local d = web_driver({
    sim = { power = "01", source = "30" },
    props = { ["HDMI 1 Select Request"] = "KEY=4D", ["HDMI 2 Select Request"] = "KEY=4D" },
  })
  d:connect()
  d.clock:advance(10 * SEC)
  d.env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = 1021 }) -- already on HDMI 1
  d.clock:advance(15 * SEC)
  t.eq(d.web:count("KEY=4D"), 0, "no press when the input is already selected")
end)

t.test("web: Web Control and Remote passwords are used as set", function()
  local d = web_driver({
    sim = { power = "04", web_password = "webpw", remote_password = "remotepw", warm_ms = 5 * SEC },
    props = { ["Web Control Password"] = "webpw", ["Remote Password"] = "remotepw" },
  })
  d:connect()
  d.clock:advance(10 * SEC)
  t.eq(d.rec.props["Connection Status"], "Connected")
  d.env.ReceivedFromProxy(5001, "ON", {})
  d.clock:advance(30 * SEC)
  t.eq(d.web.power, "01", "the Basic Control (remote) password was accepted")
end)

t.test("web: wrong Web Control password is reported; fixing it recovers", function()
  local d = web_driver({
    sim = { power = "04", web_password = "webpw" },
    props = { ["Web Control Password"] = "wrong" },
  })
  d:connect()
  d.clock:advance(10 * SEC)
  t.contains(d.rec.props["Connection Status"], "Authentication failed")
  d:set("Web Control Password", "webpw")
  d.clock:advance(10 * SEC)
  t.eq(d.rec.props["Connection Status"], "Connected")
end)

t.test("web: Test Connection and Read Input List", function()
  local d = web_driver({ sim = { power = "01" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d:action("TestConnection")
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Last Test Result"], "OK - projector reports 1")
  d:action("ReadInputList")
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Available Inputs"], "30 (HDMI 1), A0 (HDMI 2)")
end)

t.test("web: Query Web Value and Send Web Request report what the projector said", function()
  local d = web_driver({ sim = { power = "01", source = "30" } })
  d:connect()
  d.clock:advance(10 * SEC)
  d:action("QueryWebValue", { Query = "SOURCE?" })
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Last Test Result"], "SOURCE? -> 30")
  d:action("SendWebRequest", { Request = "KEY=40" })
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Last Test Result"], "Sent KEY=40 - OK")
  t.eq(d.web:count("KEY=40"), 1)
  d:action("SendWebRequest", { Request = "" }) -- ignored
end)

t.test("the web installer tools tell you to switch method when PJLink is selected", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect()
  d.clock:advance(5 * SEC)
  d:action("SendWebRequest", { Request = "KEY=40" })
  t.contains(d.rec.props["Last Test Result"], "Control Method")
  d:action("QueryWebValue", { Query = "SOURCE?" })
  t.contains(d.rec.props["Last Test Result"], "Control Method")
end)

t.test("web: an unreachable projector goes Offline, as with PJLink", function()
  local d = web_driver({ sim = { power = "01", reachable = false } })
  d:connect()
  d.clock:advance(200 * SEC)
  t.eq(d.rec.props["Power State"], "Offline")
  t.eq(d:count_event("Connection Lost"), 0, "never connected, so nothing was lost")
end)

t.test("switching Control Method at runtime rebuilds the stack and polls the new transport", function()
  local d = load_driver({ sim = { power = "0" }, web_sim = { power = "04" } })
  d:connect()
  d.clock:advance(5 * SEC)
  t.eq(d.rec.props["Power State"], "Standby")
  local pjlink_connects = d.sim.connects
  t.truthy(pjlink_connects > 0)
  d:set("Control Method", WEB)
  d.clock:advance(10 * SEC)
  t.truthy(d.web:count_queries("PWR?") >= 1, "now polling over HTTP")
  d.clock:advance(100 * SEC)
  t.eq(d.sim.connects, pjlink_connects, "PJLink is no longer used")
  d:set("Control Method", "PJLink")
  d.clock:advance(10 * SEC)
  t.truthy(d.sim.connects > pjlink_connects, "and back again")
end)

t.test("web: the request timeout property reaches C4:url", function()
  local d = web_driver({ sim = { power = "04" }, props = { ["Request Timeout (seconds)"] = "7" } })
  d:connect()
  d.clock:advance(5 * SEC)
  t.eq(d.rec.http_options.timeout, 7)
  t.eq(d.rec.http_options.fail_on_error, false, "a 401 must come back as a response, not an error")
end)

t.suite("driver: authentication and hashing")

t.test("authentication works with C4:Hash available", function()
  local d = load_driver({ sim = { power = "0", password = "secret" }, props = { ["PJLink Password"] = "secret" }, hash = "real" })
  d:connect()
  d.clock:advance(10 * SEC)
  t.eq(d.rec.props["Connection Status"], "Connected")
  t.truthy(d.rec.hash_calls > 0, "C4:Hash should have been used")
end)

t.test("authentication falls back to the pure-Lua MD5 when C4:Hash is missing", function()
  local d = load_driver({ sim = { power = "0", password = "secret" }, props = { ["PJLink Password"] = "secret" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.eq(d.rec.props["Connection Status"], "Connected")
end)

t.test("authentication falls back when C4:Hash returns an error", function()
  local d = load_driver({ sim = { power = "0", password = "secret" }, props = { ["PJLink Password"] = "secret" }, hash = "broken" })
  d:connect()
  d.clock:advance(10 * SEC)
  t.eq(d.rec.props["Connection Status"], "Connected")
end)

t.test("a wrong password is reported; fixing it in Properties recovers", function()
  local d = load_driver({ sim = { power = "0", password = "secret" }, props = { ["PJLink Password"] = "wrong" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.contains(d.rec.props["Connection Status"], "Authentication failed")
  d:set("PJLink Password", "secret")
  d.clock:advance(10 * SEC)
  t.eq(d.rec.props["Connection Status"], "Connected")
  t.eq(d.rec.props["Power State"], "Standby")
end)

t.suite("driver: configuration properties")

t.test("Idle Polling Interval property is applied", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect()
  d:set("Idle Polling Interval (seconds)", "10")
  d.clock:advance(100 * SEC)
  t.truthy(d.sim:count("POWR ?") >= 8, "polls: " .. d.sim:count("POWR ?"))
end)

t.test("Log Level Off is silent; Log Output picks print, C4:DebugLog or both", function()
  local off = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = "Off" } })
  off:connect()
  off.clock:advance(10 * SEC)
  t.eq(#off.rec.printed, 0)
  t.eq(#off.rec.debug, 0)

  local pr = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = "Debug", ["Log Output"] = "Print" } })
  pr:connect()
  pr.clock:advance(10 * SEC)
  t.truthy(#pr.rec.printed > 0)
  t.contains(pr.rec.printed[1], "[Epson")
  t.eq(#pr.rec.debug, 0)

  local lg = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = "Debug", ["Log Output"] = "Log" } })
  lg:connect()
  lg.clock:advance(10 * SEC)
  t.truthy(#lg.rec.debug > 0)
  t.eq(#lg.rec.printed, 0)

  local both = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = "Debug" } })
  both:connect()
  both.clock:advance(10 * SEC)
  t.truthy(#both.rec.printed > 0)
  t.truthy(#both.rec.debug > 0)
end)

local function joined(lines) return table.concat(lines, "\n") end

t.test("the defaults are Info and Print and Log, so something is visible out of the box", function()
  local d = load_driver({ sim = { power = "0" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.truthy(#d.rec.printed > 0)
  t.truthy(#d.rec.debug > 0)
  local text = joined(d.rec.printed)
  t.contains(text, "[Epson INFO]")
  t.contains(text, "driver v" .. d.env.DRIVER_VERSION)
  t.contains(text, "192.168.1.50")
end)

t.test("Log Level filters: Info hides the wire traffic, Debug shows it, Trace shows raw data", function()
  local function run(level)
    local d = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = level, ["Log Output"] = "Print" } })
    d:connect()
    d.clock:advance(10 * SEC)
    return joined(d.rec.printed)
  end
  local info, debug, trace = run("Info"), run("Debug"), run("Trace")
  t.eq(info:find("POWR ?", 1, true), nil)
  t.contains(debug, "-> %1POWR ?")
  t.eq(debug:find("network data:", 1, true), nil)
  t.contains(trace, "network data:")
  t.contains(trace, "PJLINK 0\\r")
end)

t.test("Error level hides warnings and info", function()
  local d = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = "Error", ["Log Output"] = "Print" } })
  d:connect()
  d.clock:advance(10 * SEC)
  t.eq(#d.rec.printed, 0)
end)

t.test("warnings land in the Last Error property even with logging Off", function()
  local d = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = "Off" } })
  d:connect()
  d.clock:advance(5 * SEC)
  d.env.ReceivedFromNetwork(9999, 4352, "x")
  t.contains(d.rec.props["Last Error"], "unexpected binding 9999")
  t.eq(#d.rec.printed, 0)
end)

t.test("passwords are never written to the log", function()
  local d = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = "Trace", ["Log Output"] = "Print" } })
  d:connect()
  d:set("PJLink Password", "hunter2secret")
  d:set("Web Control Password", "hunter2secret")
  d.clock:advance(10 * SEC)
  t.eq(joined(d.rec.printed):find("hunter2secret", 1, true), nil)
  t.contains(joined(d.rec.printed), "'PJLink Password' changed")
end)

t.test("changing Log Level announces itself, unless it was set to Off", function()
  local d = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = "Error", ["Log Output"] = "Print" } })
  d:connect()
  d:set("Log Level", "Debug")
  t.contains(joined(d.rec.printed), "logging: level=Debug")
  local before = #d.rec.printed
  d:set("Log Level", "Off")
  t.eq(#d.rec.printed, before)
end)

t.test("a failing C4:DebugLog cannot break the driver", function()
  local d = load_driver({ sim = { power = "0" }, props = { ["Log Level"] = "Debug", ["Log Output"] = "Log" } })
  d.env.C4.DebugLog = function() error("boom") end
  local ok, err = pcall(function()
    d:connect()
    d.clock:advance(10 * SEC)
  end)
  t.truthy(ok, tostring(err))
  t.eq(d.rec.props["Connection Status"], "Connected")
end)

t.test("an unreachable PJLink host explains itself in the log", function()
  local d = load_driver({ sim = { power = "0", reachable = false }, props = { ["Log Level"] = "Info", ["Log Output"] = "Print" } })
  d:connect()
  d.clock:advance(30 * SEC)
  local text = joined(d.rec.printed)
  t.contains(text, "request failed: CONNECT")
  t.truthy(d.rec.props["Last Error"] ~= nil and d.rec.props["Last Error"] ~= "")
end)

t.suite("driver: review fixes")

t.test("web mode: stray network events from the PJLink binding are ignored, not errors", function()
  local d = web_driver({ sim = { power = "04" } })
  d:connect()
  d.clock:advance(5 * SEC)
  local ok, err = pcall(function()
    d.env.OnConnectionStatusChanged(6001, 4352, "OFFLINE")
    d.env.OnConnectionStatusChanged(6001, 4352, "ONLINE")
    d.env.ReceivedFromNetwork(6001, 4352, "PJLINK 0\r")
  end)
  t.truthy(ok, tostring(err))
  d.clock:advance(40 * SEC)
  t.eq(d.rec.props["Connection Status"], "Connected")
end)
