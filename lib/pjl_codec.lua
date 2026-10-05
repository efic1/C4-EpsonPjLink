-- PJLink (Class 1) protocol codec. Pure functions, no Control4 dependencies.
--
-- Wire format (all lines end with CR):
--   greeting   "PJLINK 0"            no authentication
--              "PJLINK 1 <salt>"     authentication required
--              "PJLINK ERRA"         authentication failed / locked out
--   request    [<md5hex>]"%1POWR ?"  hash prefixes the FIRST request only
--   response   "%1POWR=1"  /  "%1POWR=ERR3"

local M = {}

M.PORT = 4352

-- POWR? reply -> state name
M.POWER = { ["0"] = "standby", ["1"] = "on", ["2"] = "cooling", ["3"] = "warming" }

M.ERROR_TEXT = {
  ERR1 = "Undefined command",
  ERR2 = "Out-of-parameter",
  ERR3 = "Unavailable time",
  ERR4 = "Projector failure",
  ERRA = "Authentication error",
}

M.INPUT_TYPES = {
  ["1"] = "RGB", ["2"] = "Video", ["3"] = "Digital",
  ["4"] = "Storage", ["5"] = "Network", ["6"] = "Internal",
}

-- ERST? reply positions
local ERST_FIELDS = { "fan", "light source", "temperature", "cover", "filter", "other" }

--- Build a request line, e.g. build("POWR", "1") -> "%1POWR 1\r"
function M.build(body, param, class)
  return "%" .. (class or "1") .. body .. " " .. (param or "?") .. "\r"
end

--- Parse the greeting line (without CR).
-- @return table {auth=false} | {auth=true, salt=...} | {err="ERRA"} | nil
function M.parse_greeting(line)
  if type(line) ~= "string" then return nil end
  local up = line:upper()
  if up == "PJLINK ERRA" then return { err = "ERRA" } end
  if up == "PJLINK 0" then return { auth = false } end
  local salt = line:match("^[Pp][Jj][Ll][Ii][Nn][Kk] 1 (%S+)$")
  if salt then return { auth = true, salt = salt } end
  return nil
end

--- Parse a response line (without CR).
-- @return table {class, body, value} or {class, body, err}; nil if malformed
function M.parse_response(line)
  if type(line) ~= "string" then return nil end
  local class, body, value = line:match("^%%(%d)(%w%w%w%w)=(.*)$")
  if not class then return nil end
  local res = { class = class, body = body:upper(), value = value }
  if value:match("^ERR[%dA]$") then
    res.err = value
    res.value = nil
  end
  return res
end

--- Hex digest placed in front of the first request when auth is enabled.
function M.auth_prefix(salt, password, md5)
  return (md5(salt .. (password or ""))):lower()
end

--- POWR? value -> "standby" | "on" | "cooling" | "warming" | nil
function M.parse_power(value)
  return M.POWER[value]
end

--- "31" -> "Digital 1"
function M.input_name(code)
  if type(code) ~= "string" or #code ~= 2 then return tostring(code) end
  local t, n = code:sub(1, 1), code:sub(2, 2)
  return (M.INPUT_TYPES[t] or ("Type " .. t)) .. " " .. n
end

--- INST? value ("31 32 51") -> list of {code, type, number, name}
function M.parse_inputs(value)
  local list = {}
  for tok in tostring(value or ""):gmatch("%S+") do
    local t, n = tok:match("^(%w)(%w)$")
    if t then
      list[#list + 1] = { code = tok, type = t, number = n, name = M.input_name(tok) }
    end
  end
  return list
end

--- ERST? value ("000000") -> {ok, warnings, errors, text}; nil if malformed
function M.parse_errors(value)
  if type(value) ~= "string" or #value < 6 then return nil end
  local warnings, errors = {}, {}
  for i, name in ipairs(ERST_FIELDS) do
    local c = value:sub(i, i)
    if c == "1" then
      warnings[#warnings + 1] = name
    elseif c == "2" then
      errors[#errors + 1] = name
    end
  end
  local parts = {}
  if #errors > 0 then parts[#parts + 1] = "Error: " .. table.concat(errors, ", ") end
  if #warnings > 0 then parts[#parts + 1] = "Warning: " .. table.concat(warnings, ", ") end
  return {
    ok = (#errors == 0 and #warnings == 0),
    warnings = warnings,
    errors = errors,
    text = (#parts == 0) and "OK" or table.concat(parts, "; "),
  }
end

--- LAMP? value ("1234 1 99 0") -> hours of first light source, list of {hours, on}
function M.parse_lamp(value)
  local nums = {}
  for tok in tostring(value or ""):gmatch("%S+") do nums[#nums + 1] = tonumber(tok) end
  if #nums < 2 then return nil end
  local list = {}
  for i = 1, #nums - 1, 2 do
    list[#list + 1] = { hours = nums[i], on = (nums[i + 1] == 1) }
  end
  return { hours = list[1].hours, lamps = list }
end

return M
