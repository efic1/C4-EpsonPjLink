-- Tiny test framework: no dependencies, runs on plain Lua 5.1.

local T = { tests = {}, group = "?" }

function T.suite(name) T.group = name end

function T.test(name, fn)
  T.tests[#T.tests + 1] = { group = T.group, name = name, fn = fn }
end

--- A test that builds an in-flight situation (a request still queued, a connect still
-- pending). Those cannot exist when every network event arrives inside the call that
-- caused it, so they are skipped (and counted) in the C4_SYNC=all run.
function T.test_async(name, fn)
  T.tests[#T.tests + 1] = { group = T.group, name = name, fn = fn, async_only = true }
end

local function fmt(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function T.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
  end
end

function T.truthy(v, msg)
  if not v then error((msg or "expected truthy value") .. " (got " .. fmt(v) .. ")", 2) end
end

function T.falsy(v, msg)
  if v then error((msg or "expected falsy value") .. " (got " .. fmt(v) .. ")", 2) end
end

function T.contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error((msg or "expected string to contain") .. " " .. fmt(needle) .. " in " .. fmt(haystack), 2)
  end
end

local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function dump(v)
  if type(v) ~= "table" then return fmt(v) end
  local parts = {}
  for i, x in ipairs(v) do parts[#parts + 1] = dump(x) end
  local keys = {}
  for k in pairs(v) do if type(k) ~= "number" then keys[#keys + 1] = tostring(k) end end
  table.sort(keys)
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. dump(v[k]) end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function T.deep_eq(actual, expected, msg)
  if not deep_eq(actual, expected) then
    error((msg and (msg .. ": ") or "") .. "expected " .. dump(expected) .. ", got " .. dump(actual), 2)
  end
end

--- Run every registered test; returns (passed, failed).
function T.run()
  local passed, failed = 0, 0
  local last_group
  for _, t in ipairs(T.tests) do
    if t.group ~= last_group then
      print("\n" .. t.group)
      last_group = t.group
    end
    local skip = t.async_only and os.getenv("C4_SYNC") == "all"
    local ok, err
    if skip then ok = true else ok, err = pcall(t.fn) end
    if skip then
      T.skipped = (T.skipped or 0) + 1
      print("  SKIP  " .. t.name .. "  (needs a request in flight; not possible with C4_SYNC=all)")
    elseif ok then
      passed = passed + 1
      print("  PASS  " .. t.name)
    else
      failed = failed + 1
      print("  FAIL  " .. t.name)
      print("        " .. tostring(err))
    end
  end
  return passed, failed
end

return T
