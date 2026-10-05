local t = require "tests.lib_test"
local S = require "tests.http_helpers"

local SEC = 1000

local function capture()
  local box = { calls = 0 }
  box.cb = function(res) box.calls = box.calls + 1; box.res = res end
  return box
end

local function query(s, q)
  local r = capture()
  s.client:request("RAWQ", q, r.cb)
  s.clock:advance(5 * SEC)
  return r
end

t.suite("http client: authentication")

t.test("no password configured: a plain request just works (one round trip)", function()
  local s = S.new_stack({ sim = { power = "01" } })
  local r = capture()
  s.client:request("POWR", "?", r.cb)
  s.clock:advance(2 * SEC)
  t.truthy(r.res.ok)
  t.eq(r.res.value, "1")
  t.eq(#s.sim.requests, 1)
  t.eq(s.sim.unauthorised, 0)
end)

t.test("password set: 401 challenge, then an authorised retry", function()
  local s = S.new_stack({ sim = { power = "01", web_password = "secret" }, web_password = "secret" })
  local r = capture()
  s.client:request("POWR", "?", r.cb)
  s.clock:advance(2 * SEC)
  t.truthy(r.res.ok)
  t.eq(#s.sim.requests, 2)
  t.eq(s.sim.unauthorised, 1)
  t.falsy(s.sim.requests[1].headers["Authorization"])
  t.contains(s.sim.requests[2].headers["Authorization"], 'username="EPSONWEB"')
end)

t.test("the Digest challenge is cached: later requests need one round trip and a rising nc", function()
  local s = S.new_stack({ sim = { power = "01", web_password = "secret" }, web_password = "secret" })
  query(s, "PWR?")
  local before = #s.sim.requests
  query(s, "SOURCE?")
  query(s, "ERR?")
  t.eq(#s.sim.requests - before, 2, "two requests, no new 401s")
  t.eq(s.sim.unauthorised, 1)
  t.contains(s.sim.requests[#s.sim.requests].headers["Authorization"], "nc=00000003")
end)

t.test("a wrong password is ERRA after one retry, and the cache is dropped", function()
  local s = S.new_stack({ sim = { web_password = "secret" }, web_password = "wrong" })
  local r = query(s, "PWR?")
  t.falsy(r.res.ok)
  t.eq(r.res.err, "ERRA")
  t.eq(#s.sim.requests, 2, "challenge + one authorised attempt, no loop")
  t.eq(s.client.challenges["EPSONWEB"], nil)
end)

t.test("password required but none configured: ERRA without a second request", function()
  local s = S.new_stack({ sim = { web_password = "secret" }, web_password = "" })
  local r = query(s, "PWR?")
  t.eq(r.res.err, "ERRA")
  t.eq(#s.sim.requests, 1)
end)

t.test("an expired nonce (stale=true) is renewed transparently", function()
  local s = S.new_stack({ sim = { power = "01", web_password = "secret", nonce_ttl_ms = 30 * SEC }, web_password = "secret" })
  query(s, "PWR?")
  s.clock:advance(60 * SEC)
  local r = query(s, "PWR?")
  t.truthy(r.res.ok)
  t.eq(r.res.value, "01", "raw queries return the reply verbatim")
  t.eq(s.sim.unauthorised, 2, "one fresh challenge at the start, one after the nonce expired")
end)

t.test("changing the password later recovers after clear_auth()", function()
  local s = S.new_stack({ sim = { power = "01", web_password = "one" }, web_password = "one" })
  query(s, "PWR?")
  s.sim.web_password = "two"
  local stale = query(s, "PWR?")
  t.eq(stale.res.err, "ERRA")
  local pw = "two"
  s.client.credentials = function(user) return user, pw end
  s.client:clear_auth()
  local ok = query(s, "PWR?")
  t.truthy(ok.res.ok)
end)

t.test("status queries use EPSONWEB; Basic Control commands use EPSONREMOTE with its own password", function()
  local s = S.new_stack({
    sim = { power = "04", web_password = "web", remote_password = "remote" },
    web_password = "web", remote_password = "remote",
  })
  local q = capture()
  s.client:request("POWR", "?", q.cb)
  s.clock:advance(3 * SEC)
  t.truthy(q.res.ok)
  local c = capture()
  s.client:request("POWR", "1", c.cb)
  s.clock:advance(3 * SEC)
  t.truthy(c.res.ok, tostring(c.res.err))
  local last = s.sim.requests[#s.sim.requests]
  t.contains(last.headers["Authorization"], 'username="EPSONREMOTE"')
  t.eq(s.sim.power, "02")
end)

t.test("a wrong Remote Password does not break status polling", function()
  local s = S.new_stack({
    sim = { power = "04", web_password = "web", remote_password = "remote" },
    web_password = "web", remote_password = "nope",
  })
  local q = capture()
  s.client:request("POWR", "?", q.cb)
  local c = capture()
  s.client:request("POWR", "1", c.cb)
  s.clock:advance(5 * SEC)
  t.truthy(q.res.ok)
  t.eq(c.res.err, "ERRA")
  t.eq(s.sim.power, "04")
end)

t.suite("http client: requests and errors")

t.test("every request carries a Referer, Connection: close and an encoded query", function()
  local s = S.new_stack({ sim = { power = "01" } })
  query(s, "PWR?")
  local req = s.sim.requests[1]
  t.contains(req.headers["Referer"], "/cgi-bin/webconf")
  t.eq(req.headers["Connection"], "close")
  t.contains(req.url, "/cgi-bin/json_query?jsoncallback=PWR%3F")
  s.client:request("POWR", "0", function() end)
  s.clock:advance(3 * SEC)
  local cmd = s.sim.requests[#s.sim.requests]
  t.contains(cmd.headers["Referer"], "/cgi-bin/Remote/Basic_Control")
  t.contains(cmd.url, "/cgi-bin/Remote/directsend?KEY=6C")
end)

t.test("a rejected Referer (the 403 page) is a PROTOCOL error, never a fake success", function()
  local s = S.new_stack({ sim = { power = "01", require_referer = true } })
  s.client.env.get = (function(real)
    return function(url, headers, timeout, cb)
      headers["Referer"] = nil
      return real(url, headers, timeout, cb)
    end
  end)(s.client.env.get)
  local q = capture()
  s.client:request("POWR", "?", q.cb)
  local c = capture()
  s.client:request("POWR", "0", c.cb)
  s.clock:advance(5 * SEC)
  t.eq(q.res.err, "PROTOCOL")
  t.eq(c.res.err, "PROTOCOL")
  t.eq(s.sim.power, "01", "nothing was executed")
end)

t.test("unreachable projector: CONNECT; no answer: TIMEOUT after the configured time", function()
  local s = S.new_stack({ sim = { reachable = false } })
  t.eq(query(s, "PWR?").res.err, "CONNECT")

  local b = S.new_stack({ sim = { blackhole = true }, timeout = 3 })
  local r = capture()
  b.client:request("POWR", "?", r.cb)
  b.clock:advance(2500)
  t.eq(r.calls, 0)
  b.clock:advance(1000)
  t.eq(r.res.err, "TIMEOUT")
end)

t.test("set_timeouts converts milliseconds to the per-exchange timeout", function()
  local b = S.new_stack({ sim = { blackhole = true } })
  b.client:set_timeouts(2000, 2000)
  local r = capture()
  b.client:request("POWR", "?", r.cb)
  b.clock:advance(2500)
  t.eq(r.res.err, "TIMEOUT")
end)

t.test("json 'error: true' (projector busy) is ERR3, not a link failure", function()
  local s = S.new_stack({ sim = { power = "04" } })
  local r = query(s, "SOURCE?") -- the simulator refuses SOURCE? unless the projector is on
  t.eq(r.res.err, "ERR3")
  t.eq(s.sim.unauthorised, 0)
end)

t.test("an HTML page where JSON was expected is a PROTOCOL error", function()
  local s = S.new_stack({ sim = { power = "01" } })
  s.client.env.get = function(url, headers, timeout, cb)
    s.clock:set_timer(10, function() cb({ code = 200, headers = {}, body = "<html>maintenance</html>" }) end)
  end
  t.eq(query(s, "PWR?").res.err, "PROTOCOL")
end)

t.test("unexpected HTTP status is a PROTOCOL error", function()
  local s = S.new_stack({ sim = { power = "01" } })
  s.client.env.get = function(url, headers, timeout, cb)
    s.clock:set_timer(10, function() cb({ code = 500, headers = {}, body = "oops" }) end)
  end
  t.eq(query(s, "PWR?").res.err, "PROTOCOL")
end)

t.test("empty host fails immediately with NOHOST", function()
  local s = S.new_stack({ host = "" })
  local r = capture()
  s.client:request("POWR", "?", r.cb)
  t.eq(r.res.err, "NOHOST")
  t.eq(#s.sim.requests, 0)
end)

t.test("unsupported inputs and unknown requests are ERR2 / ERR1 without touching the network", function()
  local s = S.new_stack({ sim = { power = "01" } })
  local a, b = capture(), capture()
  s.client:request("INPT", "99", a.cb)
  s.client:request("WHAT", "?", b.cb)
  s.clock:advance(2 * SEC)
  t.eq(a.res.err, "ERR2")
  t.eq(b.res.err, "ERR1")
  t.eq(#s.sim.requests, 0)
end)

t.test("INST and INF2 are answered locally", function()
  local s = S.new_stack({ sim = { power = "01" } })
  local a, b = capture(), capture()
  s.client:request("INST", "?", a.cb)
  s.client:request("INF2", "?", b.cb)
  s.clock:advance(3 * SEC)
  t.eq(a.res.value, "30 A0")
  t.eq(b.res.value, "TEST-HTTP")
  t.eq(#s.sim.requests, 0)
end)

t.suite("http client: power commands")

t.test("power on / power off drive the simulated projector", function()
  local s = S.new_stack({ sim = { power = "04", warm_ms = 5 * SEC, cool_ms = 5 * SEC } })
  s.client:request("POWR", "1", function() end)
  s.clock:advance(2 * SEC)
  t.eq(s.sim.power, "02")
  s.clock:advance(10 * SEC)
  t.eq(s.sim.power, "01")
  s.client:request("POWR", "0", function() end)
  s.clock:advance(2 * SEC)
  t.eq(s.sim.power, "03")
end)

t.test("a projector that needs a confirm press gets two key presses about a second apart", function()
  local s = S.new_stack({ sim = { power = "01", off_presses = 2 }, cfg = { power_off_presses = 2 } })
  local r = capture()
  s.client:request("POWR", "0", r.cb)
  s.clock:advance(5 * SEC)
  t.truthy(r.res.ok)
  t.eq(s.sim:count("KEY=6C"), 2)
  t.eq(s.sim.power, "03")
end)

t.test("with one configured press, a projector that wants two stays on (the setting matters)", function()
  local s = S.new_stack({ sim = { power = "01", off_presses = 2 }, cfg = { power_off_presses = 1 } })
  s.client:request("POWR", "0", function() end)
  s.clock:advance(5 * SEC)
  t.eq(s.sim.power, "01")
end)

t.test("input selection sends the configured key command", function()
  local s = S.new_stack({ sim = { power = "01", source = "30" } })
  s.client:request("INPT", "A0", function() end)
  s.clock:advance(3 * SEC)
  t.eq(s.sim.source, "A0")
  t.eq(s.sim:count("KEY=40"), 1)
end)

t.test("raw commands are URL-encoded and reach directsend", function()
  local s = S.new_stack({ sim = { power = "01" } })
  local r = capture()
  s.client:request("RAWC", "KEY=4D", r.cb)
  s.clock:advance(3 * SEC)
  t.truthy(r.res.ok)
  t.eq(s.sim.source, "30")
end)

t.test("the command path is configurable (older models use /cgi-bin/directsend)", function()
  local s = S.new_stack({ sim = { power = "04" } })
  s.client:set_command_path("/cgi-bin/directsend")
  s.client:request("POWR", "1", function() end)
  s.clock:advance(3 * SEC)
  t.eq(s.sim.power, "02")
  t.contains(s.sim.requests[#s.sim.requests].url, "/cgi-bin/directsend?IMPWR=ON")
end)

t.suite("http client: queueing")

t.test("one HTTP exchange in flight at a time, in order, with a gap", function()
  local s = S.new_stack({ sim = { power = "01" }, gap = 500 })
  local order = {}
  for _, q in ipairs({ "PWR?", "SOURCE?", "ERR?" }) do
    s.client:request("RAWQ", q, function() order[#order + 1] = q end)
  end
  s.clock:advance(10 * SEC)
  t.deep_eq(order, { "PWR?", "SOURCE?", "ERR?" })
  t.eq(s.sim.max_in_flight, 1)
end)

t.test("identical queued requests are merged", function()
  local s = S.new_stack({ sim = { power = "01" } })
  local a, b, c = capture(), capture(), capture()
  s.client:request("RAWQ", "PWR?", a.cb)
  s.client:request("RAWQ", "SOURCE?", b.cb)
  s.client:request("RAWQ", "SOURCE?", c.cb)
  s.clock:advance(10 * SEC)
  t.eq(s.sim:count_queries("SOURCE?"), 1)
  t.eq(b.res.value, c.res.value)
end)

t.test("priority requests jump the queue but not the active request", function()
  local s = S.new_stack({ sim = { power = "01" } })
  local order = {}
  local function track(n) return function() order[#order + 1] = n end end
  s.client:request("RAWQ", "PWR?", track("A"))
  s.client:request("RAWQ", "SOURCE?", track("B"))
  s.client:request("RAWQ", "ERR?", track("C"), { priority = true })
  s.clock:advance(10 * SEC)
  t.deep_eq(order, { "A", "C", "B" })
end)

t.test("reset() fails queued work with CANCELLED and ignores the in-flight reply", function()
  local s = S.new_stack({ sim = { power = "01" } })
  local a, b = capture(), capture()
  s.client:request("RAWQ", "PWR?", a.cb)
  s.client:request("RAWQ", "SOURCE?", b.cb)
  s.client:reset("CANCELLED")
  t.eq(a.res.err, "CANCELLED")
  t.eq(b.res.err, "CANCELLED")
  s.clock:advance(2 * SEC)
  t.eq(a.calls, 1, "the late reply must not call back again")
  local c = capture()
  s.client:request("RAWQ", "PWR?", c.cb)
  s.clock:advance(3 * SEC)
  t.truthy(c.res.ok)
end)

t.test("an error inside a callback does not wedge the queue", function()
  local s = S.new_stack({ sim = { power = "01" } })
  s.client:request("RAWQ", "PWR?", function() error("boom") end)
  local r = capture()
  s.client:request("RAWQ", "SOURCE?", r.cb)
  s.clock:advance(5 * SEC)
  t.truthy(r.res.ok)
end)

t.suite("http projector: end to end through the shared state machine")

t.test("standby -> power_on -> warming -> on, using the real command sequence", function()
  local s = S.new_stack({ sim = { power = "04", warm_ms = 15 * SEC } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  s.projector:power_on()
  s.clock:advance(60 * SEC)
  t.deep_eq(s.states(), { "STANDBY", "WARMING", "ON" })
  t.eq(s.sim:count("IMPWR=ON"), 1)
end)

t.test("on -> power_off -> cooling -> standby with a single standby key press", function()
  local s = S.new_stack({ sim = { power = "01", cool_ms = 20 * SEC } })
  s.projector:start()
  s.clock:advance(10 * SEC)
  s.projector:power_off()
  s.clock:advance(60 * SEC)
  t.deep_eq(s.states(), { "ON", "COOLING", "STANDBY" })
  t.eq(s.sim:count("KEY=6C"), 1)
end)

t.test("the standby key is never sent unless the projector is confirmed on", function()
  for _, power in ipairs({ "04", "02", "03" }) do
    local s = S.new_stack({ sim = { power = power, warm_ms = 8 * SEC, cool_ms = 8 * SEC } })
    s.projector:start()
    s.clock:advance(3 * SEC)
    s.projector:power_off()
    s.clock:advance(2 * SEC)
    if power == "02" then
      t.eq(s.sim:count("KEY=6C"), 0, "must wait for warm-up to finish")
    else
      t.eq(s.sim:count("KEY=6C"), 0)
    end
  end
end)

t.test("Navigator pattern: on + HDMI 2 together applies the input only after warm-up", function()
  local s = S.new_stack({ sim = { power = "04", warm_ms = 20 * SEC } })
  s.projector:start()
  s.clock:advance(5 * SEC)
  s.projector:power_on()
  s.projector:select_input("A0")
  s.clock:advance(15 * SEC)
  t.eq(s.sim:count("KEY=40"), 0)
  s.clock:advance(60 * SEC)
  t.eq(s.sim.source, "A0")
  t.eq(s.sim:count("KEY=40"), 1)
end)

t.test("input, faults and light source hours are read while the projector is on", function()
  local s = S.new_stack({ sim = { power = "01", source = "A0", err = "04", lamp = "1500" } })
  s.projector:start()
  s.clock:advance(15 * SEC)
  t.eq(s.of("input")[1][1], "A0")
  local fault = s.of("fault")[1]
  t.eq(fault[1], true)
  t.eq(s.of("lamp")[1][1], 1500)
  t.eq(s.of("info")[1][1], "TEST-HTTP")
end)

t.test("a wrong password shows up as an authentication failure and backs off", function()
  local s = S.new_stack({ sim = { web_password = "secret" }, web_password = "nope" })
  s.projector:start()
  s.clock:advance(10 * SEC)
  t.truthy(s.projector.auth_failed)
  local requests = #s.sim.requests
  s.clock:advance(250 * SEC)
  t.eq(#s.sim.requests, requests, "no hammering inside the lockout interval")
end)

t.test("the whole flow works with both passwords set", function()
  local s = S.new_stack({
    sim = { power = "04", warm_ms = 10 * SEC, web_password = "w", remote_password = "r" },
    web_password = "w", remote_password = "r",
  })
  s.projector:start()
  s.clock:advance(5 * SEC)
  s.projector:power_on()
  s.clock:advance(60 * SEC)
  t.deep_eq(s.states(), { "STANDBY", "WARMING", "ON" })
  t.falsy(s.projector.auth_failed)
end)
