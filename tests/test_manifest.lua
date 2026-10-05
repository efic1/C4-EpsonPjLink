-- Static checks that driver.xml and the Lua sources agree with each other.
-- These catch the classic Control4 mistakes: an event renamed in one place only,
-- an action in XML with no handler, a property read in Lua that does not exist.

local t = require "tests.lib_test"
local H = require "tests.helpers"

local xml = H.read_file("driver.xml")
local lua = H.read_file("driver.lua")

local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

local function all(pattern, text)
  local out = {}
  for m in text:gmatch(pattern) do out[#out + 1] = m end
  return out
end

local function normalize(name)
  return (tostring(name):upper():gsub("[%s_]", ""))
end

t.suite("manifest: driver.xml <-> driver.lua")

t.test("every Lua source file compiles", function()
  for _, path in ipairs({ "driver.lua", "lib/pjl_md5.lua", "lib/pjl_codec.lua",
    "lib/pjl_client.lua", "lib/pjl_projector.lua" }) do
    local fn, err = loadfile(path)
    t.truthy(fn, path .. ": " .. tostring(err))
  end
end)

t.test("sources avoid syntax/library features missing from Lua 5.1 / LuaJIT", function()
  for _, path in ipairs({ "driver.lua", "lib/pjl_md5.lua", "lib/pjl_codec.lua",
    "lib/pjl_client.lua", "lib/pjl_projector.lua" }) do
    local src = H.read_file(path)
    -- strip comments and string literals roughly before scanning
    local code = src:gsub("%-%-[^\n]*", ""):gsub('"[^"\n]*"', '""')
    t.falsy(code:find("goto%s"), path .. " uses goto")
    t.falsy(code:find("table%.unpack"), path .. " uses table.unpack")
    t.falsy(code:find("string%.pack"), path .. " uses string.pack")
    t.falsy(code:find("bit32"), path .. " uses bit32")
    t.falsy(code:find("utf8%."), path .. " uses utf8")
    t.falsy(code:find("%f[%w_]load%s*%("), path .. " uses 5.2+ load()")
  end
end)

t.test("event names fired by driver.lua match <events> exactly", function()
  local block = lua:match("local EVENT = {(.-)\n}")
  t.truthy(block, "EVENT table not found")
  local lua_events = all('= "(.-)"', block)
  local xml_events = all("<event>.-<name>(.-)</name>", xml)
  t.truthy(#lua_events > 0)
  t.deep_eq(set_of(lua_events), set_of(xml_events))
end)

t.test("event ids are unique, start at 1 and are contiguous", function()
  local ids = all("<event>%s*<id>(%d+)</id>", xml)
  for i, id in ipairs(ids) do t.eq(tonumber(id), i, "event id order") end
end)

t.test("every event and conditional description uses the NAME macro", function()
  for _, d in ipairs(all("<event>.-<description>(.-)</description>", xml)) do
    t.contains(d, "NAME", "event description")
  end
  for _, d in ipairs(all("<conditional>.-<description>(.-)</description>", xml)) do
    t.contains(d, "NAME", "conditional description")
  end
end)

t.test("every Actions-tab command has a handler", function()
  local actions = xml:match("<actions>(.-)</actions>")
  local handlers = all("\n  (%u+) = function", lua)
  local have = set_of(handlers)
  local cmds = all("<command>(.-)</command>", actions)
  t.truthy(#cmds >= 5)
  for _, cmd in ipairs(cmds) do
    t.truthy(have[normalize(cmd)], "no handler for action '" .. cmd .. "'")
  end
end)

t.test("every Programming command has a handler", function()
  local commands = xml:match("<commands>(.-)</commands>")
  local have = set_of(all("\n  (%u+) = function", lua))
  local names = all("<command>%s*<name>(.-)</name>", commands)
  t.truthy(#names >= 1)
  for _, name in ipairs(names) do
    t.truthy(have[normalize(name)], "no handler for command '" .. name .. "'")
  end
end)

t.test("command sort orders are unique (Composer drops duplicates)", function()
  local commands = xml:match("<commands>(.-)</commands>")
  local seen = {}
  for _, n in ipairs(all("<sort_order>(%d+)</sort_order>", commands)) do
    t.falsy(seen[n], "duplicate sort_order " .. n)
    seen[n] = true
  end
end)

t.test("every conditional is evaluated by TestCondition", function()
  local names = all("<conditional>.-<name>(.-)</name>", xml)
  t.truthy(#names >= 4)
  for _, name in ipairs(names) do
    t.truthy(lua:find('strName == "' .. name .. '"', 1, true), "TestCondition has no branch for " .. name)
  end
end)

t.test("conditional ids are unique", function()
  local seen = {}
  for _, id in ipairs(all("<conditional>%s*<id>(%d+)</id>", xml)) do
    t.falsy(seen[id], "duplicate conditional id " .. id)
    seen[id] = true
  end
end)

t.test("LIST conditional items match the labels the Lua code produces", function()
  local power = xml:match("<name>POWER_STATE</name>.-<items>(.-)</items>")
  local items = set_of(all("<item>(.-)</item>", power))
  for label in lua:match("local STATE_LABEL = {(.-)}"):gmatch('"(.-)"') do
    t.truthy(items[label], "POWER_STATE conditional lacks '" .. label .. "'")
  end
  local input = xml:match("<name>CURRENT_INPUT</name>.-<items>(.-)</items>")
  local labels = set_of(all("<item>(.-)</item>", input))
  t.truthy(labels["HDMI 1"] and labels["HDMI 2"] and labels["Other"])
end)

t.test("every property the Lua code reads or writes is declared in driver.xml", function()
  local _, declared_list = H.xml_property_defaults()
  local declared = set_of(declared_list)
  local used = {}
  for _, p in ipairs(all('Properties%["(.-)"%]', lua)) do used[p] = true end
  for _, p in ipairs(all('set_prop%("(.-)"', lua)) do used[p] = true end
  for _, p in ipairs(all('prop = "(.-)"', lua)) do used[p] = true end
  t.truthy(next(used))
  for p in pairs(used) do
    t.truthy(declared[p], "property '" .. p .. "' is used in driver.lua but not declared")
  end
end)

t.test("property defaults are valid and ranged integers have sane bounds", function()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    if block:find("<type>RANGED_INTEGER</type>", 1, true) then
      local min = tonumber(block:match("<minimum>(.-)</minimum>"))
      local max = tonumber(block:match("<maximum>(.-)</maximum>"))
      local def = tonumber(block:match("<default>(.-)</default>"))
      t.truthy(min and max and def, name .. ": missing min/max/default")
      t.truthy(def >= min and def <= max, name .. ": default outside range")
    end
    if block:find("<type>LIST</type>", 1, true) then
      local def = block:match("<default>(.-)</default>")
      local items = set_of(all("<item>(.-)</item>", block))
      t.truthy(items[def], name .. ": default is not one of the items")
    end
  end
end)

t.test("the PJLink password property is masked", function()
  local block = xml:match("<name>PJLink Password</name>(.-)</property>")
  t.contains(block, "<password>true</password>")
end)

t.test("every set_var() variable is registered in OnDriverInit", function()
  local init = lua:match("function OnDriverInit%(%)(.-)\nend")
  local registered = set_of(all('C4:AddVariable%("(.-)"', init))
  for _, v in ipairs(all('set_var%("(.-)"', lua)) do
    t.truthy(registered[v], "variable " .. v .. " is not added in OnDriverInit")
  end
end)

t.test("input bindings and the proxy binding are declared in <connections>", function()
  local ids = set_of(all("<connection[^>]*>%s*<id>(%d+)</id>", xml))
  for _, b in ipairs(all("binding = (%d+)", lua)) do
    t.truthy(ids[b], "binding " .. b .. " missing from driver.xml")
  end
  t.truthy(ids["5001"])
  t.truthy(xml:find('proxybindingid="5001"', 1, true))
  t.truthy(lua:find("local PROXY_ID = 5001", 1, true))
end)

t.test("input bindings are in the video-input range and typed as video", function()
  local found = 0
  for id, body in xml:gmatch("<connection[^>]*>%s*<id>(%d+)</id>(.-)</connection>") do
    local n = tonumber(id)
    if n >= 1000 and n <= 1099 then
      found = found + 1
      t.contains(body, "<type>5</type>", "binding " .. id)
      t.contains(body, "<classname>HDMI</classname>")
      t.contains(body, "<consumer>True</consumer>")
    end
  end
  t.eq(found, 2, "expected the two HDMI input bindings")
end)

t.test("proxy connection matches Control4's shipped projector drivers (class TV, type 2)", function()
  local block = xml:match("<id>5001</id>(.-)</connection>")
  t.contains(block, "<type>2</type>")
  t.contains(block, "<classname>TV</classname>")
end)

t.test("projector exposes the room-selection binding (video only)", function()
  local room = xml:match("<id>7000</id>(.-)</connection>")
  t.contains(room, "<type>7</type>")
  t.contains(room, "VIDEO_SELECTION")
  t.falsy(room:find("AUDIO_SELECTION", 1, true))
end)

t.test("binding ids match Control4's Epson LS12000B driver so swapping keeps bindings", function()
  local ids = set_of(all("<connection[^>]*>%s*<id>(%d+)</id>", xml))
  for _, id in ipairs({ "5001", "7000", "1021", "1022" }) do
    t.truthy(ids[id], "missing binding " .. id)
  end
  t.falsy(lua:find("tonumber(tParams.INPUT)", 1, true), "SET_INPUT must use the % 1000 mapping")
end)

t.test("capabilities advertise discrete input select and the real input count", function()
  local caps = xml:match("<capabilities>(.-)</capabilities>")
  t.contains(caps, "<has_discrete_input_select>True</has_discrete_input_select>")
  local n = select(2, xml:gsub("<id>10%d%d</id>", ""))
  t.contains(caps, "<video_consumer_count>" .. n .. "</video_consumer_count>")
end)

t.test("power_command_needed and power_delay are declared", function()
  t.contains(xml, "<power_command_needed>True</power_command_needed>")
  t.truthy(tonumber(xml:match("<power_delay>(%d+)</power_delay>")))
end)

t.test("driver.xml declares the lua script and proxy type", function()
  t.truthy(xml:find('file="driver.lua"', 1, true))
  t.truthy(xml:find(">projector</proxy>", 1, true))
  t.truthy(xml:find("<driver>DriverWorks</driver>", 1, true))
end)

t.test("default input codes match Epson's PJLink table for the EH-LS12000B (HDMI1 = 32, HDMI2 = 33)", function()
  local defaults = H.xml_property_defaults()
  t.eq(defaults["HDMI 1 Input Code"], "32")
  t.eq(defaults["HDMI 2 Input Code"], "33")
  t.truthy(lua:find('prop = "HDMI 1 Input Code", default = "32"', 1, true))
  t.truthy(lua:find('prop = "HDMI 2 Input Code", default = "33"', 1, true))
end)

t.test("the video blank feature stays out (Epson lists AVMT 11 as non-compatible)", function()
  t.falsy(lua:lower():find("blank", 1, true))
  t.falsy(xml:lower():find("blank", 1, true))
  t.falsy(H.read_file("lib/pjl_projector.lua"):find("AVMT", 1, true))
end)
