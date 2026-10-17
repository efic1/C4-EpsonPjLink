-- Test runner. Usage (from the project root):  lua5.1 tests/run.lua [pattern]
package.path = "./?.lua;" .. package.path

local t = require "tests.lib_test"

local files = {
  "tests.test_codec",
  "tests.test_client",
  "tests.test_projector",
  "tests.test_driver",
  "tests.test_manifest",
  "tests.test_http_codec",
  "tests.test_http_client",
}

local filter = arg and arg[1]
for _, name in ipairs(files) do
  require(name)
end

if filter then
  local kept = {}
  for _, test in ipairs(t.tests) do
    if (test.group .. " " .. test.name):lower():find(filter:lower(), 1, true) then
      kept[#kept + 1] = test
    end
  end
  t.tests = kept
end

local passed, failed = t.run()
local mode = os.getenv("C4_SYNC")
if mode == nil or mode == "" then mode = "async" end
print(string.format("\n%d passed, %d failed, %d skipped  [network events: %s]",
  passed, failed, t.skipped or 0, mode))
os.exit(failed == 0 and 0 or 1)
