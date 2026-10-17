-- Maps the projector module's PJLink-style requests (POWR, INPT, ERST, LAMP, INST,
-- INF2) onto Epson Web Control HTTP calls, and converts the replies back.
--
--   status  GET /cgi-bin/json_query?jsoncallback=<ESC/VP21 query>
--           -> {"projector":{"feature":{"name":"esc/vp21","query":"PWR?","reply":"01","error":false}}}
--   control GET <command path>?<NAME=value>      (e.g. IMPWR=ON, KEY=6C), empty 200 reply
--
-- Everything model-specific (key codes, source codes) comes in through `cfg`.
-- Pure functions, no Control4 dependencies.

local M = {}

M.QUERY_PATH = "/cgi-bin/json_query"

-- ESC/VP21 PWR? reply -> PJLink POWR? value understood by the projector module
--   00/04 standby (network off/on), 01 on, 02 warm-up, 03 cooling,
--   05 abnormality standby, 09 A/V standby
M.POWER = {
  ["00"] = "0", ["01"] = "1", ["02"] = "3", ["03"] = "2",
  ["04"] = "0", ["05"] = "0", ["09"] = "0",
}

--- RFC 3986 percent-encoding of one query component.
function M.urlenc(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- "NAME=value" -> "NAME=value" with both sides encoded; a bare token is encoded whole.
function M.encode_param(p)
  local name, value = tostring(p):match("^([^=]+)=(.*)$")
  if name then return M.urlenc(name) .. "=" .. M.urlenc(value) end
  return M.urlenc(p)
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- reply converters ---------------------------------------------------------------

local function conv_power(reply)
  local v = M.POWER[reply]
  if v then return v end
  return nil, "ERR3"
end

local function conv_source(reply)
  reply = trim(reply):upper()
  if reply == "" then return nil, "ERR3" end
  return reply
end

local function conv_error(reply)
  reply = trim(reply)
  if reply == "" then return nil, "ERR3" end
  if reply == "00" then return "000000" end
  -- The ESC/VP21 ERR? codes differ by model, so report any non-zero code as an
  -- "other" error; the raw code is logged by the client.
  return "000002"
end

local function conv_lamp(reply)
  local hours = trim(reply):match("(%d+)")
  if not hours then return nil, "ERR3" end
  return tostring(tonumber(hours)) .. " 1"
end

local function conv_raw(reply)
  return tostring(reply or "")
end

--- Decide what to do for a request.
-- @param cfg { power_on, power_off, power_off_key, power_off_presses, inputs = {[code]=cmd},
--              source_codes = {code,...}, model }
-- @return plan:
--   { kind="query", query="PWR?", convert=fn }
--   { kind="send", commands={ "NAME=value", ... } }
--   { kind="local", value="..." }
--   { kind="error", err="ERR1"|"ERR2" }
function M.plan(body, param, cfg)
  cfg = cfg or {}
  param = tostring(param or "?")

  if body == "POWR" then
    if param == "?" then
      return { kind = "query", query = "PWR?", convert = conv_power }
    elseif param == "1" then
      return { kind = "send", commands = { trim(cfg.power_on) ~= "" and trim(cfg.power_on) or "IMPWR=ON" } }
    elseif param == "0" then
      -- A discrete off request (IMPWR=OFF) is not a toggle, so it is safe to repeat.
      -- Only when it is empty do we fall back to the remote's power key, which toggles.
      local off = trim(cfg.power_off)
      if off ~= "" then
        return { kind = "send", commands = { off } }
      end
      local key = trim(cfg.power_off_key)
      if key == "" then key = "6C" end
      local presses = tonumber(cfg.power_off_presses) or 1
      if presses < 1 then presses = 1 elseif presses > 3 then presses = 3 end
      local cmds = {}
      for i = 1, presses do cmds[i] = "KEY=" .. key end
      return { kind = "send", commands = cmds, gap_ms = 1000 }
    end
    return { kind = "error", err = "ERR2" }

  elseif body == "INPT" then
    if param == "?" then
      return { kind = "query", query = "SOURCE?", convert = conv_source }
    end
    local cmd = cfg.inputs and cfg.inputs[param]
    if not cmd or trim(cmd) == "" then return { kind = "error", err = "ERR2" } end
    return { kind = "send", commands = { trim(cmd) } }

  elseif body == "ERST" then
    return { kind = "query", query = "ERR?", convert = conv_error }

  elseif body == "LAMP" then
    return { kind = "query", query = "LAMP?", convert = conv_lamp }

  elseif body == "INST" then
    return { kind = "local", value = table.concat(cfg.source_codes or {}, " ") }

  elseif body == "INF2" then
    return { kind = "local", value = cfg.model or "EPSON projector (Web Control)" }

  elseif body == "RAWQ" then
    -- installer tool: any ESC/VP21 query, reply returned verbatim
    return { kind = "query", query = param, convert = conv_raw }

  elseif body == "RAWC" then
    -- installer tool: any directsend parameter, e.g. KEY=6C
    return { kind = "send", commands = { param } }
  end

  return { kind = "error", err = "ERR1" }
end

--- Extract (reply, is_error) from a json_query body without needing a JSON library.
-- @return reply string or nil, error_flag boolean
function M.parse_json_reply(body)
  if type(body) ~= "string" then return nil, true end
  local err = body:match('"error"%s*:%s*(%a+)')
  local reply = body:match('"reply"%s*:%s*"(.-)"')
  return reply, (err == "true")
end

return M
