local t = require "tests.lib_test"
local md5 = require "lib.pjl_md5"
local digest = require "lib.http_digest"
local cmds = require "lib.epson_cmds"

t.suite("http digest")

t.test("matches the RFC 2617 section 3.5 example", function()
  local ch = { realm = "testrealm@host.com", nonce = "dcd98b7102dd2f0e8b11d0f600bfb0c093",
    qop = "auth,auth-int", opaque = "5ccc069c403ebaf9f0171e9517f40e41" }
  local header = digest.authorization(ch, "Mufasa", "Circle Of Life", "GET", "/dir/index.html", 1, "0a4f113b", md5.hex)
  t.contains(header, 'response="6629fae49393a05397450978507c4ef1"')
  t.contains(header, "nc=00000001")
  t.contains(header, 'cnonce="0a4f113b"')
  t.contains(header, "qop=auth")
  t.contains(header, 'opaque="5ccc069c403ebaf9f0171e9517f40e41"')
end)

t.test("matches independently computed vectors for Epson-style challenges", function()
  local web = { realm = "Web Control", nonce = "2b6b:2da7c70a1751ac89f9a0be44adb19c67", qop = "auth" }
  local h1 = digest.authorization(web, "EPSONWEB", "12345678", "GET",
    "/cgi-bin/json_query?jsoncallback=PWR%3F", 1, "abcdef0123456789", md5.hex)
  t.contains(h1, 'response="c1dd9c0f9ff99f9881f673ef8b830f61"')

  local remote = { realm = "Web Control", nonce = "2a16:a8a115402b6b42b2bf6bd40775a4fc09", qop = "auth" }
  local h2 = digest.authorization(remote, "EPSONREMOTE", "remotepw", "GET",
    "/cgi-bin/Remote/directsend?KEY=6C", 3, "0011223344556677", md5.hex)
  t.contains(h2, 'response="9a30e0c8b7f2f9b9299df2787e6f36c2"')
  t.contains(h2, "nc=00000003")
end)

t.test("RFC 2069 style (no qop) omits nc and cnonce", function()
  local ch = { realm = "r", nonce = "nonce1" }
  local header = digest.authorization(ch, "u", "p", "GET", "/x", 1, "ignored", md5.hex)
  t.contains(header, 'response="73fcffead1c0c264914a2b18dab6452b"')
  t.falsy(header:find("nc=", 1, true))
  t.falsy(header:find("cnonce", 1, true))
end)

t.test("unsupported algorithm or qop is reported, not guessed", function()
  local a, why = digest.authorization({ realm = "r", nonce = "n", algorithm = "SHA-256", qop = "auth" },
    "u", "p", "GET", "/", 1, "c", md5.hex)
  t.eq(a, nil)
  t.contains(why, "algorithm")
  local b, why2 = digest.authorization({ realm = "r", nonce = "n", qop = "auth-int" }, "u", "p", "GET", "/", 1, "c", md5.hex)
  t.eq(b, nil)
  t.contains(why2, "qop")
end)

t.test("parse_challenge reads the header the projector sends", function()
  local ch = digest.parse_challenge('Digest realm="Web Control", nonce="2a16:a8a115402b6b42b2bf6bd40775a4fc09", qop="auth"')
  t.eq(ch.realm, "Web Control")
  t.eq(ch.nonce, "2a16:a8a115402b6b42b2bf6bd40775a4fc09")
  t.eq(ch.qop, "auth")
  t.falsy(ch.stale)
end)

t.test("parse_challenge handles stale, opaque, unquoted tokens and odd spacing", function()
  local ch = digest.parse_challenge('digest  realm="R, with comma",nonce="n1" , stale=TRUE, algorithm=MD5, opaque="op"')
  t.eq(ch.realm, "R, with comma")
  t.eq(ch.nonce, "n1")
  t.truthy(ch.stale)
  t.eq(ch.algorithm, "MD5")
  t.eq(ch.opaque, "op")
end)

t.test("parse_challenge rejects other schemes and incomplete challenges", function()
  t.eq(digest.parse_challenge('Basic realm="x"'), nil)
  t.eq(digest.parse_challenge('Digest realm="x"'), nil)
  t.eq(digest.parse_challenge(nil), nil)
end)

t.test("header lookup is case-insensitive", function()
  t.eq(digest.header({ ["www-authenticate"] = "a" }, "WWW-Authenticate"), "a")
  t.eq(digest.header({ ["WWW-AUTHENTICATE"] = "b" }, "www-authenticate"), "b")
  t.eq(digest.header({}, "x"), nil)
  t.eq(digest.header(nil, "x"), nil)
end)

t.suite("epson command translation")

local CFG = {
  power_on = "IMPWR=ON", power_off_key = "6C", power_off_presses = 1,
  inputs = { ["30"] = "KEY=4D", ["A0"] = "KEY=40" }, source_codes = { "30", "A0" }, model = "M",
}

t.test("power queries convert every ESC/VP21 code to a PJLink state", function()
  local plan = cmds.plan("POWR", "?", CFG)
  t.eq(plan.kind, "query")
  t.eq(plan.query, "PWR?")
  local expect = { ["00"] = "0", ["01"] = "1", ["02"] = "3", ["03"] = "2", ["04"] = "0", ["05"] = "0", ["09"] = "0" }
  for code, want in pairs(expect) do t.eq(plan.convert(code), want, "code " .. code) end
  local v, err = plan.convert("77")
  t.eq(v, nil)
  t.eq(err, "ERR3")
end)

t.test("power on uses the configured command, defaulting to IMPWR=ON", function()
  t.deep_eq(cmds.plan("POWR", "1", CFG).commands, { "IMPWR=ON" })
  t.deep_eq(cmds.plan("POWR", "1", { power_on = "  KEY=3B " }).commands, { "KEY=3B" })
  t.deep_eq(cmds.plan("POWR", "1", {}).commands, { "IMPWR=ON" })
end)

t.test("power off sends the standby key once, or as many times as configured (1-3)", function()
  t.deep_eq(cmds.plan("POWR", "0", CFG).commands, { "KEY=6C" })
  t.deep_eq(cmds.plan("POWR", "0", { power_off_key = "3B", power_off_presses = 2 }).commands, { "KEY=3B", "KEY=3B" })
  t.eq(#cmds.plan("POWR", "0", { power_off_presses = 9 }).commands, 3)
  t.eq(#cmds.plan("POWR", "0", { power_off_presses = 0 }).commands, 1)
  t.deep_eq(cmds.plan("POWR", "0", {}).commands, { "KEY=6C" })
end)

t.test("a configured Power Off Request wins over the key press and is sent once", function()
  t.deep_eq(cmds.plan("POWR", "0", { power_off = "IMPWR=OFF", power_off_key = "6C", power_off_presses = 3 }).commands,
    { "IMPWR=OFF" })
  t.deep_eq(cmds.plan("POWR", "0", { power_off = "  IMPWR=OFF " }).commands, { "IMPWR=OFF" })
  t.deep_eq(cmds.plan("POWR", "0", { power_off = "" }).commands, { "KEY=6C" })
end)

t.test("input query returns the upper-cased source code; select looks up the configured command", function()
  local q = cmds.plan("INPT", "?", CFG)
  t.eq(q.query, "SOURCE?")
  t.eq(q.convert("a0"), "A0")
  t.eq(select(2, q.convert("")), "ERR3")
  t.deep_eq(cmds.plan("INPT", "A0", CFG).commands, { "KEY=40" })
  t.eq(cmds.plan("INPT", "99", CFG).err, "ERR2")
  t.eq(cmds.plan("INPT", "30", { inputs = { ["30"] = "  " } }).err, "ERR2")
end)

t.test("error, lamp, source list and model conversions", function()
  local e = cmds.plan("ERST", "?", CFG)
  t.eq(e.query, "ERR?")
  t.eq(e.convert("00"), "000000")
  t.eq(e.convert("04"), "000002")
  t.eq(select(2, e.convert("")), "ERR3")

  local l = cmds.plan("LAMP", "?", CFG)
  t.eq(l.query, "LAMP?")
  t.eq(l.convert("1500"), "1500 1")
  t.eq(l.convert("0007"), "7 1")
  t.eq(select(2, l.convert("n/a")), "ERR3")

  t.eq(cmds.plan("INST", "?", CFG).value, "30 A0")
  t.eq(cmds.plan("INF2", "?", CFG).value, "M")
  t.truthy(cmds.plan("INF2", "?", {}).value:find("EPSON", 1, true))
end)

t.test("raw installer requests pass straight through", function()
  local q = cmds.plan("RAWQ", "SOURCE?", CFG)
  t.eq(q.query, "SOURCE?")
  t.eq(q.convert("A0"), "A0")
  t.deep_eq(cmds.plan("RAWC", "KEY=40", CFG).commands, { "KEY=40" })
end)

t.test("unknown requests are ERR1; bad power parameters are ERR2", function()
  t.eq(cmds.plan("FOO", "?", CFG).err, "ERR1")
  t.eq(cmds.plan("POWR", "7", CFG).err, "ERR2")
end)

t.test("percent-encoding: query text and NAME=value pairs", function()
  t.eq(cmds.urlenc("PWR?"), "PWR%3F")
  t.eq(cmds.urlenc("a b&c"), "a%20b%26c")
  t.eq(cmds.urlenc("safe-_.~"), "safe-_.~")
  t.eq(cmds.encode_param("KEY=6C"), "KEY=6C")
  t.eq(cmds.encode_param("POPMEM=02 01"), "POPMEM=02%2001")
  t.eq(cmds.encode_param("BARE TOKEN"), "BARE%20TOKEN")
end)

t.test("json reply extraction", function()
  local body = '{\n"projector": {\n"feature": {\n"name": "esc/vp21",\n"query": "PWR?",\n"reply": "01",\n"error": false\n}\n}\n}'
  local reply, is_error = cmds.parse_json_reply(body)
  t.eq(reply, "01")
  t.eq(is_error, false)
  local _, bad = cmds.parse_json_reply('{"projector":{"feature":{"reply":"","error":true}}}')
  t.eq(bad, true)
  local none, flag = cmds.parse_json_reply("<html>403 Forbidden</html>")
  t.eq(none, nil)
  t.eq(flag, false)
  t.eq(select(1, cmds.parse_json_reply(nil)), nil)
end)
