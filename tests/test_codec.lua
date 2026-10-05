local t = require "tests.lib_test"
local md5 = require "lib.pjl_md5"
local codec = require "lib.pjl_codec"

t.suite("md5 (pure Lua fallback)")

t.test("matches RFC 1321 reference vectors", function()
  t.eq(md5.hex(""), "d41d8cd98f00b204e9800998ecf8427e")
  t.eq(md5.hex("a"), "0cc175b9c0f1b6a831c399e269772661")
  t.eq(md5.hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
  t.eq(md5.hex("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
  t.eq(md5.hex("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b")
  t.eq(md5.hex("12345678901234567890123456789012345678901234567890123456789012345678901234567890"),
    "57edf4a22be3c955ac49da2e2107b67a")
end)

t.test("is consistent across block boundaries (self-checks lengths 0..130)", function()
  -- Different lengths must give different digests and always 32 lowercase hex chars.
  local seen = {}
  for n = 0, 130 do
    local d = md5.hex(string.rep("q", n))
    t.eq(#d, 32, "digest length for n=" .. n)
    t.truthy(d:match("^%x+$") and d == d:lower(), "lowercase hex for n=" .. n)
    t.falsy(seen[d], "duplicate digest at n=" .. n)
    seen[d] = true
  end
end)

t.suite("codec: building and parsing")

t.test("build() formats requests with CR terminator", function()
  t.eq(codec.build("POWR", "1"), "%1POWR 1\r")
  t.eq(codec.build("POWR", "?"), "%1POWR ?\r")
  t.eq(codec.build("INPT", "31"), "%1INPT 31\r")
  t.eq(codec.build("INST"), "%1INST ?\r")
end)

t.test("parse_greeting: no auth, auth with salt, and lockout", function()
  t.deep_eq(codec.parse_greeting("PJLINK 0"), { auth = false })
  t.deep_eq(codec.parse_greeting("PJLINK 1 498e4a67"), { auth = true, salt = "498e4a67" })
  t.deep_eq(codec.parse_greeting("pjlink 1 498e4a67"), { auth = true, salt = "498e4a67" })
  t.deep_eq(codec.parse_greeting("PJLINK ERRA"), { err = "ERRA" })
  t.eq(codec.parse_greeting("HELLO"), nil)
  t.eq(codec.parse_greeting(nil), nil)
end)

t.test("parse_response: values and error codes", function()
  t.deep_eq(codec.parse_response("%1POWR=1"), { class = "1", body = "POWR", value = "1" })
  t.deep_eq(codec.parse_response("%1INPT=31"), { class = "1", body = "INPT", value = "31" })
  t.deep_eq(codec.parse_response("%1POWR=OK"), { class = "1", body = "POWR", value = "OK" })
  t.deep_eq(codec.parse_response("%1POWR=ERR3"), { class = "1", body = "POWR", err = "ERR3" })
  t.deep_eq(codec.parse_response("%1INPT=ERRA"), { class = "1", body = "INPT", err = "ERRA" })
  t.eq(codec.parse_response("garbage"), nil)
  t.eq(codec.parse_response("%1POW=1"), nil)
end)

t.test("auth_prefix hashes salt + password as lowercase hex", function()
  local prefix = codec.auth_prefix("498e4a67", "secret", md5.hex)
  t.eq(#prefix, 32)
  t.eq(prefix, md5.hex("498e4a67secret"))
  -- an md5 implementation returning uppercase must still produce lowercase
  t.eq(codec.auth_prefix("ab", "cd", function() return "ABCDEF" end), "abcdef")
  -- no password configured hashes the salt alone
  t.eq(codec.auth_prefix("498e4a67", nil, md5.hex), md5.hex("498e4a67"))
end)

t.suite("codec: value parsers")

t.test("parse_power maps all four PJLink states", function()
  t.eq(codec.parse_power("0"), "standby")
  t.eq(codec.parse_power("1"), "on")
  t.eq(codec.parse_power("2"), "cooling")
  t.eq(codec.parse_power("3"), "warming")
  t.eq(codec.parse_power("9"), nil)
end)

t.test("input_name and parse_inputs", function()
  t.eq(codec.input_name("31"), "Digital 1")
  t.eq(codec.input_name("12"), "RGB 2")
  t.eq(codec.input_name("51"), "Network 1")
  t.eq(codec.input_name("99"), "Type 9 9")
  local list = codec.parse_inputs("31 32 51")
  t.eq(#list, 3)
  t.deep_eq(list[1], { code = "31", type = "3", number = "1", name = "Digital 1" })
  t.eq(list[3].name, "Network 1")
  t.eq(#codec.parse_inputs(""), 0)
  t.eq(#codec.parse_inputs(nil), 0)
end)

t.test("parse_errors: ok, warnings, errors, malformed", function()
  local ok = codec.parse_errors("000000")
  t.truthy(ok.ok)
  t.eq(ok.text, "OK")

  local fan = codec.parse_errors("200000")
  t.falsy(fan.ok)
  t.eq(fan.text, "Error: fan")

  -- positions: fan, light source, temperature, cover, filter, other
  local mixed = codec.parse_errors("021010")
  t.deep_eq(mixed.errors, { "light source" })
  t.deep_eq(mixed.warnings, { "temperature", "filter" })
  t.eq(mixed.text, "Error: light source; Warning: temperature, filter")

  local tail = codec.parse_errors("000101")
  t.deep_eq(tail.warnings, { "cover", "other" })

  t.eq(codec.parse_errors("0000"), nil)
  t.eq(codec.parse_errors(nil), nil)
end)

t.test("parse_lamp: first light source hours and full list", function()
  local r = codec.parse_lamp("1500 1")
  t.eq(r.hours, 1500)
  t.eq(#r.lamps, 1)
  t.truthy(r.lamps[1].on)

  local two = codec.parse_lamp("120 0 99 1")
  t.eq(two.hours, 120)
  t.falsy(two.lamps[1].on)
  t.eq(two.lamps[2].hours, 99)

  t.eq(codec.parse_lamp("5"), nil)
  t.eq(codec.parse_lamp(""), nil)
end)

