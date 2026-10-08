local t = require "tests.lib_test"
local H = require "tests.helpers"
local md5 = require "lib.pjl_md5"
local Client = require "lib.pjl_client"

t.suite("client: request/response")

local function new_client(sim_opts, client_opts)
  local clock = H.new_clock()
  local sim = H.new_sim(clock, sim_opts)
  client_opts = client_opts or {}
  client_opts.host = client_opts.host or "10.0.0.5"
  local client = Client.new(sim:env(), client_opts)
  sim:attach(client)
  return clock, sim, client
end

local function capture()
  local box = { calls = 0 }
  box.cb = function(res) box.calls = box.calls + 1; box.res = res end
  return box
end

t.test("query without authentication returns the value", function()
  local clock, sim, client = new_client({ power = "1" })
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(1000)
  t.eq(r.calls, 1)
  t.truthy(r.res.ok)
  t.eq(r.res.value, "1")
  t.eq(sim.sent[1], "%1POWR ?\r")
end)

t.test("authentication prefixes the first request with md5(salt..password)", function()
  local clock, sim, client = new_client({ password = "secret" }, { password = "secret" })
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(1000)
  t.truthy(r.res.ok)
  t.eq(sim.sent[1], md5.hex("498e4a67secret") .. "%1POWR ?\r")
  t.eq(sim.auth_failures, 0)
end)

t.test("password may be supplied as a function (read at use time)", function()
  local pw = "wrong"
  local clock, sim, client = new_client({ password = "secret" }, { password = function() return pw end })
  local bad = capture()
  client:request("POWR", "?", bad.cb)
  clock:advance(1000)
  t.eq(bad.res.err, "ERRA")
  pw = "secret"
  clock:advance(1000)
  local good = capture()
  client:request("POWR", "?", good.cb)
  clock:advance(1000)
  t.truthy(good.res.ok)
end)

t.test("wrong password reports ERRA", function()
  local clock, sim, client = new_client({ password = "secret" }, { password = "nope" })
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(1000)
  t.falsy(r.res.ok)
  t.eq(r.res.err, "ERRA")
  t.eq(sim.auth_failures, 1)
end)

t.test("auth required but no password configured: ERRA and nothing is sent", function()
  local clock, sim, client = new_client({ password = "secret" }, { password = "" })
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(1000)
  t.eq(r.res.err, "ERRA")
  t.eq(r.res.detail, "password required")
  t.eq(#sim.sent, 0)
end)

t.test("projector error replies surface as err codes", function()
  local clock, sim, client = new_client({ power = "0" })
  local r = capture()
  client:request("INPT", "?", r.cb) -- ERR3 while in standby
  clock:advance(1000)
  t.falsy(r.res.ok)
  t.eq(r.res.err, "ERR3")
end)

t.test("empty host fails immediately with NOHOST", function()
  local clock, sim, client = new_client({}, { host = "" })
  local r = capture()
  client:request("POWR", "?", r.cb)
  t.eq(r.calls, 1)
  t.eq(r.res.err, "NOHOST")
  t.eq(sim.connects, 0)
end)

t.suite("client: failures and timeouts")

t.test("refused connection fails fast with CONNECT", function()
  local clock, sim, client = new_client({ reachable = false })
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(200)
  t.eq(r.res.err, "CONNECT")
end)

t.test("silent network: CONNECT after the connect timeout", function()
  local clock, sim, client = new_client({ blackhole = true }, { connect_timeout = 3000 })
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(2900)
  t.eq(r.calls, 0, "must still be waiting")
  clock:advance(200)
  t.eq(r.res.err, "CONNECT")
end)

t.test("projector that never answers: TIMEOUT after the response timeout", function()
  local clock, sim, client = new_client({ mute = true }, { response_timeout = 2000 })
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(1500)
  t.eq(r.calls, 0)
  clock:advance(1000)
  t.eq(r.res.err, "TIMEOUT")
end)

t.test("client recovers and serves the next request after a failure", function()
  local clock, sim, client = new_client({ reachable = false })
  local bad = capture()
  client:request("POWR", "?", bad.cb)
  clock:advance(1000)
  t.eq(bad.res.err, "CONNECT")
  sim.reachable = true
  local good = capture()
  client:request("POWR", "?", good.cb)
  clock:advance(1000)
  t.truthy(good.res.ok)
end)

t.test("set_timeouts changes timeout behaviour", function()
  local clock, sim, client = new_client({ mute = true })
  client:set_timeouts(1000, 1000)
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(1500)
  t.eq(r.res.err, "TIMEOUT")
end)

t.suite("client: queueing")

t.test("requests run strictly one at a time, in order", function()
  local clock, sim, client = new_client({ power = "1" })
  local order = {}
  for i, body in ipairs({ "POWR", "INPT", "ERST" }) do
    client:request(body, "?", function() order[#order + 1] = body end)
  end
  clock:advance(5000)
  t.deep_eq(order, { "POWR", "INPT", "ERST" })
  t.eq(sim.connects, 3)
  t.eq(sim.max_open, 1, "never more than one connection open")
end)

t.test("a gap separates consecutive connections", function()
  local clock, sim, client = new_client({ power = "1" }, { gap = 300 })
  client:request("POWR", "?")
  client:request("INPT", "?")
  clock:advance(5000)
  local dt = sim.connect_times[2] - sim.connect_times[1]
  t.truthy(dt >= 300, "second connect came " .. dt .. "ms after the first")
end)

t.test("identical queued requests share one connection and all callbacks fire", function()
  local clock, sim, client = new_client({ power = "1" })
  local a, b, c = capture(), capture(), capture()
  client:request("POWR", "?", a.cb) -- starts immediately
  client:request("INPT", "?", b.cb) -- queued
  client:request("INPT", "?", c.cb) -- merges with b
  clock:advance(5000)
  t.eq(sim.connects, 2)
  t.eq(b.calls, 1)
  t.eq(c.calls, 1)
  t.eq(b.res.value, "31")
  t.eq(c.res.value, "31")
end)

t.test("priority requests jump ahead of queued work but not the active one", function()
  local clock, sim, client = new_client({ power = "1" })
  local order = {}
  local function track(name) return function() order[#order + 1] = name end end
  client:request("POWR", "?", track("POWR"))        -- active
  client:request("INST", "?", track("INST"))
  client:request("ERST", "?", track("ERST"))
  client:request("INPT", "31", track("INPT"), { priority = true })
  clock:advance(8000)
  t.deep_eq(order, { "POWR", "INPT", "INST", "ERST" })
end)

t.test("multiple priority requests keep their relative order", function()
  local clock, sim, client = new_client({ power = "1" })
  local order = {}
  local function track(name) return function() order[#order + 1] = name end end
  client:request("POWR", "?", track("POWR"))
  client:request("ERST", "?", track("ERST"))
  client:request("INPT", "31", track("P1"), { priority = true })
  client:request("INPT", "32", track("P2"), { priority = true })
  clock:advance(8000)
  t.deep_eq(order, { "POWR", "P1", "P2", "ERST" })
end)

t.test("queue limit rejects with QUEUE_FULL", function()
  local clock, sim, client = new_client({ power = "1" }, { max_queue = 2 })
  client:request("POWR", "?")
  client:request("INPT", "?")
  local r = capture()
  client:request("ERST", "?", r.cb)
  t.eq(r.res.err, "QUEUE_FULL")
end)

t.test("callbacks may enqueue follow-up requests", function()
  local clock, sim, client = new_client({ power = "1" })
  local values = {}
  client:request("POWR", "?", function(res)
    values[#values + 1] = res.value
    client:request("INPT", "?", function(res2) values[#values + 1] = res2.value end)
  end)
  clock:advance(5000)
  t.deep_eq(values, { "1", "31" })
end)

t.test("an error inside a callback does not wedge the client", function()
  local clock, sim, client = new_client({ power = "1" })
  client:request("POWR", "?", function() error("boom") end)
  local r = capture()
  client:request("INPT", "?", r.cb)
  clock:advance(5000)
  t.truthy(r.res.ok)
end)

t.test("reset() fails queued callbacks with CANCELLED and the client keeps working", function()
  local clock, sim, client = new_client({ power = "1" })
  local a, b = capture(), capture()
  client:request("POWR", "?", a.cb)
  client:request("INPT", "?", b.cb)
  client:reset("CANCELLED")
  t.eq(a.res.err, "CANCELLED")
  t.eq(b.res.err, "CANCELLED")
  t.eq(client:pending(), 0)
  clock:advance(1000) -- let stale sim events drain
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(3000)
  t.truthy(r.res.ok)
end)

t.test("set_host with a new address cancels pending work", function()
  local clock, sim, client = new_client({ power = "1" })
  local a = capture()
  client:request("POWR", "?", a.cb)
  client:set_host("10.0.0.99")
  t.eq(a.res.err, "CANCELLED")
  t.eq(client.host, "10.0.0.99")
end)

t.suite("client: wire handling")

t.test("greeting and reply split across several packets are reassembled", function()
  local sent, handle = {}, {}
  local timers = {}
  local env = {
    connect = function() end,
    disconnect = function() end,
    send = function(d) sent[#sent + 1] = d end,
    set_timer = function(ms, fn)
      local tm = { fn = fn }
      function tm:Cancel() self.cancelled = true end
      timers[#timers + 1] = tm
      return tm
    end,
    md5 = md5.hex,
  }
  local client = Client.new(env, { host = "x" })
  local got
  client:request("POWR", "?", function(res) got = res end)
  client:on_status("ONLINE")
  client:on_data("PJLI")
  t.eq(#sent, 0)
  client:on_data("NK 0")
  t.eq(#sent, 0, "must wait for the CR")
  client:on_data("\r")
  t.eq(#sent, 1)
  client:on_data("%1POW")
  client:on_data("R=3")
  t.eq(got, nil)
  client:on_data("\r")
  t.truthy(got.ok)
  t.eq(got.value, "3")
end)

t.test("a stray line for a different command is ignored", function()
  local sim_clock = H.new_clock()
  local sent = {}
  local env = {
    connect = function() end, disconnect = function() end,
    send = function(d) sent[#sent + 1] = d end,
    set_timer = function(ms, fn) return sim_clock:set_timer(ms, fn) end,
    md5 = md5.hex,
  }
  local client = Client.new(env, { host = "x" })
  local got
  client:request("POWR", "?", function(res) got = res end)
  client:on_status("ONLINE")
  client:on_data("PJLINK 0\r")
  client:on_data("%1LAMP=100 1\r")
  t.eq(got, nil, "stray reply must not complete the request")
  client:on_data("%1POWR=1\r")
  t.eq(got.value, "1")
end)

t.test("garbage greeting is a PROTOCOL error", function()
  local clock = H.new_clock()
  local env = {
    connect = function() end, disconnect = function() end, send = function() end,
    set_timer = function(ms, fn) return clock:set_timer(ms, fn) end, md5 = md5.hex,
  }
  local client = Client.new(env, { host = "x" })
  local got
  client:request("POWR", "?", function(res) got = res end)
  client:on_status("ONLINE")
  client:on_data("220 FTP server ready\r")
  t.eq(got.err, "PROTOCOL")
end)

t.test("connection dropped mid-request reports CLOSED", function()
  local clock = H.new_clock()
  local env = {
    connect = function() end, disconnect = function() end, send = function() end,
    set_timer = function(ms, fn) return clock:set_timer(ms, fn) end, md5 = md5.hex,
  }
  local client = Client.new(env, { host = "x" })
  local got
  client:request("POWR", "?", function(res) got = res end)
  client:on_status("ONLINE")
  client:on_data("PJLINK 0\r")
  client:on_status("OFFLINE")
  t.eq(got.err, "CLOSED")
end)

t.test("repeated PJLINK ERRA greeting (lockout) is reported as ERRA", function()
  local clock = H.new_clock()
  local env = {
    connect = function() end, disconnect = function() end, send = function() end,
    set_timer = function(ms, fn) return clock:set_timer(ms, fn) end, md5 = md5.hex,
  }
  local client = Client.new(env, { host = "x" })
  local got
  client:request("POWR", "?", function(res) got = res end)
  client:on_status("ONLINE")
  client:on_data("PJLINK ERRA\r")
  t.eq(got.err, "ERRA")
end)

t.suite("client: review fixes")

t.test("reset() with an open connection: the old socket's OFFLINE does not fail the next request", function()
  local clock, sim, client = new_client({ power = "1" })
  local a = capture()
  client:request("POWR", "?", a.cb)
  clock:advance(30) -- connected, request on the wire
  client:reset("CANCELLED")
  t.eq(a.res.err, "CANCELLED")
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(5000)
  t.eq(r.calls, 1)
  t.truthy(r.res.ok, "got " .. tostring(r.res.err))
  t.eq(sim.open_count, 0, "no socket left open")
end)

t.test("a connect that completes after the connect timeout is closed again", function()
  local clock, sim, client = new_client({ power = "1", latency = 6000 })
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(5100)
  t.eq(r.res.err, "CONNECT")
  clock:advance(10000) -- the late ONLINE arrives at ~6000 ms
  t.eq(sim.open_count, 0, "late socket must not stay open")
  t.eq(client.state, "idle")
end)

t.test("reset() while a connect is pending cancels it and the next request still works", function()
  local clock, sim, client = new_client({ power = "1", latency = 200 })
  local a = capture()
  client:request("POWR", "?", a.cb)
  clock:advance(50)
  client:reset("CANCELLED")
  local r = capture()
  client:request("POWR", "?", r.cb)
  clock:advance(8000)
  t.truthy(r.res.ok, "got " .. tostring(r.res.err))
  t.eq(sim.open_count, 0)
end)
