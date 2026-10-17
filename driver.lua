-- Epson Projector driver for Control4 (DriverWorks, OS 3.x+)
--
-- Two control methods share one projector state machine (lib/pjl_projector.lua):
--   PJLink       Class 1 over TCP 4352, one short-lived connection per request
--   Web (HTTP)   Epson Web Control CGI (json_query / directsend), one short HTTP
--                request at a time, Digest authentication
-- Protocol, connection handling and projector logic live in lib/; this file is only
-- the Control4 glue: properties, proxy, events, actions, variables and conditionals.

local codec = require "lib.pjl_codec"
local md5_fallback = require "lib.pjl_md5"
local Client = require "lib.pjl_client"
local EpsonHttp = require "lib.epson_http"
local Projector = require "lib.pjl_projector"

DRIVER_VERSION = "1.0.6"

local PROXY_ID = 5001
local NET_ID = 6001

-- Projector-proxy video input bindings <-> property holding the PJLink code.
-- IDs match Control4's own Epson LS12000B driver (HDMI 1 = 1021, HDMI 2 = 1022) so that
-- swapping drivers in Composer keeps existing bindings. Director may send either the
-- video binding or its audio twin (3000 + n) in SET_INPUT, so inputs are matched on
-- `binding % 1000`.
-- PJLink mode uses `prop` (Epson: HDMI1 = 32, HDMI2 = 33). Web mode uses the ESC/VP21
-- SOURCE codes in `web_prop` (HDMI1 = 30, HDMI2 = A0) and the request in `select_prop`.
local INPUTS = {
  { binding = 1021, name = "HDMI 1", prop = "HDMI 1 Input Code", default = "32",
    web_prop = "HDMI 1 Web Source Code", web_default = "30", select_prop = "HDMI 1 Select Request" },
  { binding = 1022, name = "HDMI 2", prop = "HDMI 2 Input Code", default = "33",
    web_prop = "HDMI 2 Web Source Code", web_default = "A0", select_prop = "HDMI 2 Select Request" },
}
local WEB_METHOD = "Web (HTTP)"

-- Event names must match <events> in driver.xml exactly.
local EVENT = {
  POWERED_ON = "Projector Powered On",
  POWERED_OFF = "Projector Powered Off",
  WARMING_UP = "Projector Warming Up",
  COOLING_DOWN = "Projector Cooling Down",
  INPUT_CHANGED = "Input Changed",
  FAULT = "Projector Fault",
  FAULT_CLEARED = "Projector Fault Cleared",
  CONNECTION_LOST = "Connection Lost",
  CONNECTION_RESTORED = "Connection Restored",
  LAMP_ALERT = "Light Source Hours Alert",
}

local STATE_LABEL = {
  ON = "On", STANDBY = "Standby", WARMING = "Warming Up",
  COOLING = "Cooling Down", OFFLINE = "Offline",
}

local gClient, gProjector
local gMethod = "pjlink"
local gReady = false
local gHost = nil
local gProxyPower = nil
local gState = nil
local gInputCode = nil
local gFaultActive = nil
local gLampHours = nil
local gLink = nil

-- Helpers -----------------------------------------------------------------------

local function trim(s)
  return ((tostring(s or "")):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Logging -------------------------------------------------------------------------
-- "Log Level" decides what is written; "Log Output" decides where (Lua tab output via
-- print, the Director log via C4:DebugLog, or both). Warnings and errors are also kept in
-- the read-only "Last Error" property so a problem is visible even with no log viewer open.

local LOG_THRESHOLD = { Off = 0, Error = 1, Warning = 2, Info = 3, Debug = 4, Trace = 5 }
local LOG_RANK = { error = 1, warn = 2, info = 3, event = 3, debug = 4, trace = 5 }
local LOG_TAG = { error = "ERROR", warn = "WARN", info = "INFO", event = "EVENT",
                  debug = "DEBUG", trace = "TRACE" }
local PASSWORD_PROPS = {
  ["PJLink Password"] = true, ["Web Control Password"] = true, ["Remote Password"] = true,
}

local gLastProblem = nil

local function log_threshold()
  local t = Properties and LOG_THRESHOLD[Properties["Log Level"] or ""]
  if t == nil then return LOG_THRESHOLD.Info end
  return t
end

local function log_output()
  local m = Properties and Properties["Log Output"]
  if m == "Print" or m == "Log" then return m end
  return "Print and Log"
end

--- Printable form of wire data: control and high bytes escaped, long data cut.
local function show(s, max)
  s = tostring(s == nil and "" or s)
  max = max or 300
  local cut = ""
  if #s > max then s = s:sub(1, max); cut = "..." end
  s = s:gsub("\\", "\\\\"):gsub("\r", "\\r"):gsub("\n", "\\n")
  s = s:gsub("[%z\1-\8\11\12\14-\31\127-\255]", function(c)
    return string.format("\\x%02X", c:byte())
  end)
  return s .. cut
end

local function emit_line(line)
  local mode = log_output()
  if mode ~= "Log" then pcall(print, line) end
  if mode ~= "Print" then
    local ok = pcall(function() C4:DebugLog(line) end)
    if not ok then pcall(function() C4:ErrorLog(line) end) end
  end
end

--- HH:MM:SS, or nothing if the controller's os library cannot supply it. A missing clock
-- must never cost us the log line itself.
local function timestamp()
  local ok, text = pcall(os.date, "%H:%M:%S")
  return ok and text or "--:--:--"
end

--- Log one line. level: error | warn | info | event | debug | trace.
-- Never raises: a logging problem must not break projector control.
local function dbg(level, message)
  pcall(function()
    local rank = LOG_RANK[level] or LOG_RANK.info
    if rank <= LOG_RANK.warn and gLastProblem ~= message then
      gLastProblem = message
      C4:UpdateProperty("Last Error", tostring(message))
    end
    if rank > log_threshold() then return end
    emit_line(string.format("%s [Epson %s] %s", timestamp(),
      LOG_TAG[level] or tostring(level), tostring(message)))
  end)
end

local function set_prop(name, value)
  C4:UpdateProperty(name, tostring(value))
end

local function set_var(name, value)
  if gReady then C4:SetVariable(name, tostring(value)) end
end

local function fire(event)
  dbg("event", event)
  C4:FireEvent(event)
end

local function md5_hex(s)
  local ok, res = pcall(function()
    return C4:Hash("MD5", s, { return_encoding = "HEX", data_encoding = "NONE" })
  end)
  if ok and type(res) == "string" and #res == 32 then return res:lower() end
  return md5_fallback.hex(s)
end

local function compare(logic, a, b)
  if logic == "NOT_EQUAL" then return a ~= b end
  if logic == "LESS_THAN" then return a < b end
  if logic == "LESS_THAN_OR_EQUAL" then return a <= b end
  if logic == "GREATER_THAN" then return a > b end
  if logic == "GREATER_THAN_OR_EQUAL" then return a >= b end
  return a == b -- EQUAL (default)
end

-- Input mapping --------------------------------------------------------------------

local function normalize_code(value, default)
  local code = trim(value):upper()
  if code:match("^%w%w$") then return code end
  if code ~= "" then dbg("warn", "invalid input code '" .. code .. "', using " .. default) end
  return default
end

--- The code this input has under the active control method.
local function code_of(input)
  if gMethod == "web" then
    return normalize_code(Properties[input.web_prop], input.web_default)
  end
  return normalize_code(Properties[input.prop], input.default)
end

local function code_for_binding(binding)
  binding = tonumber(binding)
  if not binding then return nil end
  for _, input in ipairs(INPUTS) do
    if input.binding % 1000 == binding % 1000 then return code_of(input) end
  end
  return nil
end

local function code_for_name(name)
  for _, input in ipairs(INPUTS) do
    if input.name == name then return code_of(input) end
  end
  return nil
end

local function binding_for_code(code)
  for _, input in ipairs(INPUTS) do
    if code_of(input) == code then return input.binding, input.name end
  end
  return nil, nil
end

local function input_label(code)
  if not code then return "Unknown" end
  local _, name = binding_for_code(code)
  return name or codec.input_name(code)
end

-- Proxy notifications ------------------------------------------------------------------

local function notify_power(on)
  if gProxyPower == on then return end
  gProxyPower = on
  C4:SendToProxy(PROXY_ID, on and "ON" or "OFF", {}, "NOTIFY")
  if not on then
    -- Same as Control4's certified Epson driver: forget the selected input while off.
    C4:SendToProxy(PROXY_ID, "INPUT_CHANGED", { INPUT = -1 })
    C4:SendToProxy(PROXY_ID, "INPUT_CHANGED", { INPUT = -1 })
  end
end

-- Control4 TV-proxy quirk (documented in Control4's certified Epson driver): for a
-- video-only input such as HDMI, INPUT_CHANGED must be sent for BOTH the audio twin
-- (3000 + n) and the video binding (1000 + n), or Composer's "current input" is wrong.
local function notify_input(binding)
  local n = binding % 1000
  C4:SendToProxy(PROXY_ID, "INPUT_CHANGED", { INPUT = 3000 + n }, "NOTIFY")
  C4:SendToProxy(PROXY_ID, "INPUT_CHANGED", { INPUT = 1000 + n }, "NOTIFY")
end

-- Callbacks from lib/pjl_projector -----------------------------------------------------

local handlers = {}

function handlers.state(new, prev)
  dbg("info", "power state " .. tostring(prev) .. " -> " .. tostring(new))
  gState = new
  local label = STATE_LABEL[new] or tostring(new)
  set_prop("Power State", label)
  set_var("POWER_STATE", label)

  if new == "ON" or new == "WARMING" then
    notify_power(true)
  elseif new == "STANDBY" or new == "COOLING" then
    notify_power(false)
  end

  -- Events fire on real transitions only (not at startup, not after an
  -- outage that ended in the state we were already in).
  if prev ~= nil and new ~= prev and new ~= "OFFLINE" then
    if new == "ON" then
      fire(EVENT.POWERED_ON)
    elseif new == "STANDBY" then
      fire(EVENT.POWERED_OFF)
    elseif new == "WARMING" then
      fire(EVENT.WARMING_UP)
    elseif new == "COOLING" then
      fire(EVENT.COOLING_DOWN)
    end
  end
end

function handlers.input(code, prev)
  gInputCode = code
  local label = input_label(code)
  dbg("info", "input " .. tostring(code) .. " (" .. label .. ")"
    .. (prev ~= nil and (", was " .. tostring(prev)) or ""))
  set_prop("Current Input", label)
  set_var("CURRENT_INPUT", label)
  local binding = binding_for_code(code)
  if binding then notify_input(binding) end
  if prev ~= nil then fire(EVENT.INPUT_CHANGED) end
end

function handlers.fault(active, text, prev)
  dbg(active and "warn" or "info", "fault status: " .. tostring(text))
  gFaultActive = active
  set_prop("Fault Status", text)
  set_var("FAULT_STATUS", text)
  if active and prev ~= true then
    fire(EVENT.FAULT)
  elseif (not active) and prev == true then
    fire(EVENT.FAULT_CLEARED)
  end
end

function handlers.link(online, was)
  dbg("info", "link " .. (online and "up" or "DOWN")
    .. " (was " .. tostring(was) .. ")")
  gLink = online
  set_var("CONNECTED", online and "1" or "0")
  if online and was == false then
    fire(EVENT.CONNECTION_RESTORED)
  elseif (not online) and was == true then
    fire(EVENT.CONNECTION_LOST)
  end
end

function handlers.lamp(hours)
  dbg("debug", "light source hours " .. tostring(hours))
  gLampHours = hours
  set_prop("Light Source Hours", hours)
  set_var("LIGHT_SOURCE_HOURS", hours)
end

function handlers.lamp_alert(hours)
  dbg("info", "light source hours alert at " .. tostring(hours))
  fire(EVENT.LAMP_ALERT)
end

function handlers.status(text)
  dbg("info", "connection status: " .. tostring(text))
  set_prop("Connection Status", text)
end

function handlers.info(model)
  dbg("info", "projector model: " .. tostring(model))
  set_prop("Projector Model", model)
end

function handlers.inputs(list)
  local parts = {}
  for _, input in ipairs(list) do
    local _, mapped = binding_for_code(input.code)
    parts[#parts + 1] = input.code .. " (" .. (mapped or input.name) .. ")"
  end
  set_prop("Available Inputs", #parts > 0 and table.concat(parts, ", ") or "none reported")
end

-- Configuration -----------------------------------------------------------------------

-- Control methods ------------------------------------------------------------------------

local function wanted_method()
  return (Properties["Control Method"] == WEB_METHOD) and "web" or "pjlink"
end

--- Settings the web client reads at request time, so property edits apply immediately.
local function web_cfg()
  local requests, codes = {}, {}
  for _, input in ipairs(INPUTS) do
    local code = code_of(input)
    codes[#codes + 1] = code
    local request = trim(Properties[input.select_prop])
    if request ~= "" then requests[code] = request end
  end
  return {
    power_on = trim(Properties["Power On Request"]),
    power_off = trim(Properties["Power Off Request"]),
    power_off_key = trim(Properties["Power Off Key"]),
    power_off_presses = tonumber(Properties["Power Off Key Presses"]) or 1,
    inputs = requests,
    source_codes = codes,
    model = "EPSON projector (Web Control)",
  }
end

local function web_credentials(user)
  local key = (user == "EPSONREMOTE") and "Remote Password" or "Web Control Password"
  return user, Properties[key] or ""
end

local function make_timer(ms, fn)
  return C4:SetTimer(ms, function() fn() end)
end

local function web_get(url, headers, timeout_s, callback)
  dbg("debug", "HTTP GET " .. url .. " (timeout " .. tostring(timeout_s) .. "s)")
  C4:url()
    :OnDone(function(_, responses, errCode, errMsg)
      if errCode == 0 and responses and #responses > 0 then
        local r = responses[#responses]
        dbg("debug", "HTTP " .. tostring(r.code) .. " from " .. url)
        dbg("trace", "HTTP body: " .. show(r.body, 400))
        callback({ code = r.code, headers = r.headers or {}, body = r.body })
      elseif errCode == 28 then
        dbg("warn", "HTTP timeout after " .. tostring(timeout_s) .. "s: " .. url)
        callback({ err = "TIMEOUT", detail = tostring(errMsg) })
      elseif errCode == -1 then
        dbg("warn", "HTTP connection closed: " .. url)
        callback({ err = "CLOSED" })
      else
        dbg("warn", "HTTP request failed (code " .. tostring(errCode) .. ", "
          .. tostring(errMsg) .. "): " .. url)
        callback({ err = "CONNECT", detail = tostring(errMsg) })
      end
    end)
    :SetOptions({
      fail_on_error = false,
      timeout = timeout_s,
      connect_timeout = math.min(timeout_s, 5),
    })
    :Get(url, headers)
end

local function cnonce()
  return md5_hex(tostring(os.time()) .. ":" .. tostring(math.random())):sub(1, 16)
end

--- (Re)create the client and projector logic for the selected control method.
local function build_stack()
  if gProjector then gProjector:stop() end
  if gClient then gClient:reset("CANCELLED") end

  gMethod = wanted_method()
  gHost = nil -- force apply_config() to (re)connect
  dbg("info", "control method: " .. (gMethod == "web" and WEB_METHOD or "PJLink"))

  if gMethod == "web" then
    gClient = EpsonHttp.new({
      get = web_get, set_timer = make_timer, md5 = md5_hex, cnonce = cnonce, log = dbg,
    }, {
      credentials = web_credentials,
      cfg = web_cfg,
      command_path = Properties["Web Command Path"],
    })
  else
    gClient = Client.new({
      connect = function(host, port)
        dbg("debug", "NetConnect binding " .. NET_ID .. " (" .. tostring(host) .. ":" .. tostring(port) .. ")")
        C4:NetConnect(NET_ID, port)
      end,
      disconnect = function()
        dbg("debug", "NetDisconnect binding " .. NET_ID)
        C4:NetDisconnect(NET_ID, codec.PORT)
      end,
      send = function(data)
        -- length only: authenticated requests start with an MD5 of the password
        dbg("trace", "SendToNetwork " .. #data .. " bytes")
        C4:SendToNetwork(NET_ID, codec.PORT, data)
      end,
      set_timer = make_timer, md5 = md5_hex, log = dbg,
    }, {
      port = codec.PORT,
      password = function() return Properties["PJLink Password"] or "" end,
    })
  end

  gProjector = Projector.new({
    client = gClient,
    set_timer = make_timer,
    now = os.time,
    log = dbg,
    on = handlers,
  })
end

local function apply_config()
  local timeout = tonumber(Properties["Request Timeout (seconds)"]) or 5
  dbg("info", "configuration: method=" .. gMethod .. " ip=" .. tostring(trim(Properties["IP Address"]))
    .. " timeout=" .. tostring(timeout) .. "s idle poll="
    .. tostring(Properties["Idle Polling Interval (seconds)"]) .. "s")
  gClient:set_timeouts(timeout * 1000, timeout * 1000)
  if gMethod == "web" then gClient:set_command_path(Properties["Web Command Path"]) end

  gProjector:configure({
    idle_interval = tonumber(Properties["Idle Polling Interval (seconds)"]),
    lamp_alert = tonumber(Properties["Light Source Hours Alert"]),
  })

  local ip = trim(Properties["IP Address"])
  if ip ~= (gHost or "") then
    gHost = (ip ~= "") and ip or nil
    gProjector:stop()
    gProjector:reset_link()
    if gHost and gMethod == "pjlink" then
      dbg("info", "creating TCP network connection " .. NET_ID .. " to " .. gHost
        .. ":" .. tostring(codec.PORT))
      C4:CreateNetworkConnection(NET_ID, gHost, "TCP")
    end
    gClient:set_host(gHost)
    if gHost then
      set_prop("Connection Status", "Connecting...")
      gProjector:start()
    end
  end
  if not gHost then
    dbg("info", "IP Address property is empty - nothing to connect to")
    set_prop("Connection Status", "Set the IP Address property")
  end
end

-- Control4 entry points -------------------------------------------------------------------

function OnDriverInit()
  C4:AddVariable("POWER_STATE", "", "STRING")
  C4:AddVariable("CURRENT_INPUT", "", "STRING")
  C4:AddVariable("FAULT_STATUS", "", "STRING")
  C4:AddVariable("LIGHT_SOURCE_HOURS", "0", "NUMBER")
  C4:AddVariable("CONNECTED", "0", "BOOL")
end

function OnDriverLateInit()
  set_prop("Driver Version", DRIVER_VERSION)
  dbg("info", "driver v" .. DRIVER_VERSION .. " starting; Log Level=" .. tostring(Properties["Log Level"])
    .. ", Log Output=" .. tostring(Properties["Log Output"]))
  build_stack()
  gReady = true
  apply_config()
end

function OnDriverDestroyed()
  if gProjector then gProjector:stop() end
  if gClient then gClient:reset("CANCELLED") end
end

local WEB_CREDENTIAL_PROPS = { ["Web Control Password"] = true, ["Remote Password"] = true }

function OnPropertyChanged(property)
  if property == "Log Level" or property == "Log Output" then
    -- announce even when the new level would hide it, so the change is visible
    local level = Properties["Log Level"]
    if LOG_THRESHOLD[level or ""] ~= 0 then
      emit_line(timestamp() .. " [Epson INFO] logging: level=" .. tostring(level)
        .. ", output=" .. log_output())
    end
    return
  end
  if gReady then
    dbg("info", "property '" .. tostring(property) .. "' changed"
      .. (PASSWORD_PROPS[property] and "" or (" to '" .. tostring(Properties[property]) .. "'")))
  end
  if not gReady then return end
  if property == "Control Method" then
    build_stack()
    apply_config()
  elseif property == "IP Address"
      or property == "Idle Polling Interval (seconds)"
      or property == "Request Timeout (seconds)"
      or property == "Light Source Hours Alert"
      or property == "Web Command Path" then
    apply_config()
  elseif property == "PJLink Password" then
    if gMethod == "pjlink" then gProjector:reset_auth() end
  elseif WEB_CREDENTIAL_PROPS[property] then
    if gMethod == "web" then
      gClient:clear_auth()
      gProjector:reset_auth()
    end
  end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  dbg("debug", "network status: binding=" .. tostring(idBinding) .. " port=" .. tostring(nPort)
    .. " status=" .. tostring(strStatus))
  if idBinding ~= NET_ID then
    dbg("warn", "network status for unexpected binding " .. tostring(idBinding))
  elseif gMethod ~= "pjlink" then
    dbg("debug", "ignoring network status (control method is not PJLink)")
  elseif gClient and gClient.on_status then
    gClient:on_status(strStatus)
  end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
  dbg("trace", "network data: binding=" .. tostring(idBinding) .. " port=" .. tostring(nPort)
    .. " " .. #tostring(strData) .. " bytes: " .. show(strData))
  if idBinding ~= NET_ID then
    dbg("warn", "network data for unexpected binding " .. tostring(idBinding))
  elseif gMethod ~= "pjlink" then
    dbg("debug", "ignoring network data (control method is not PJLink)")
  elseif gClient and gClient.on_data then
    gClient:on_data(strData)
  end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if idBinding ~= PROXY_ID or not gProjector then return end
  tParams = tParams or {}
  dbg("info", "proxy command " .. tostring(strCommand)
    .. (tParams.INPUT and (" INPUT=" .. tostring(tParams.INPUT)) or ""))

  if strCommand == "ON" then
    gProjector:power_on()
  elseif strCommand == "OFF" then
    gProjector:power_off()
  elseif strCommand == "SET_INPUT" then
    local code = code_for_binding(tParams.INPUT)
    if code then
      dbg("info", "SET_INPUT " .. tostring(tParams.INPUT) .. " -> code " .. tostring(code))
      gProjector:select_input(code)
    else
      dbg("warn", "SET_INPUT for unknown input " .. tostring(tParams.INPUT))
    end
  else
    dbg("debug", "unhandled proxy command " .. tostring(strCommand))
  end
end

-- Actions tab (installer tools) and Programming commands ------------------------------------

local ACTIONS = {
  POWERON = function() gProjector:power_on() end,
  POWEROFF = function() gProjector:power_off() end,
  SELECTINPUT = function(p)
    local code = code_for_name(p and p.Input)
    if code then gProjector:select_input(code) end
  end,
  POLLNOW = function() gProjector:poll() end,
  READINPUTLIST = function()
    gProjector:read_inputs(function(res)
      if not res.ok then
        set_prop("Available Inputs", "Read failed: " .. tostring(res.err))
      end
    end)
  end,
  TESTCONNECTION = function()
    gProjector:test(function(res)
      if res.ok then
        dbg("info", "test connection OK, projector reports " .. tostring(res.value))
        set_prop("Last Test Result", "OK - projector reports " .. tostring(res.value))
      else
        dbg("warn", "test connection failed: " .. tostring(res.err)
          .. (res.detail and (" (" .. tostring(res.detail) .. ")") or ""))
        set_prop("Last Test Result", "Failed - " .. tostring(res.err))
      end
    end)
  end,
  RESETCONNECTION = function()
    gClient:reset("CANCELLED")
    if gMethod == "web" then gClient:clear_auth() end
    gProjector:reset_auth()
  end,
  SENDWEBREQUEST = function(p)
    -- Installer tool: send one directsend parameter such as KEY=4D and show the outcome.
    if gMethod ~= "web" then
      set_prop("Last Test Result", "Set Control Method to " .. WEB_METHOD .. " first")
      return
    end
    local param = trim(p and p.Request)
    if param == "" then return end
    gClient:request("RAWC", param, function(res)
      set_prop("Last Test Result", res.ok and ("Sent " .. param .. " - OK")
        or ("Send " .. param .. " failed - " .. tostring(res.err)))
    end, { priority = true })
  end,
  QUERYWEBVALUE = function(p)
    -- Installer tool: run any ESC/VP21 query such as SOURCE? and show the reply.
    if gMethod ~= "web" then
      set_prop("Last Test Result", "Set Control Method to " .. WEB_METHOD .. " first")
      return
    end
    local query = trim(p and p.Query)
    if query == "" then return end
    gClient:request("RAWQ", query, function(res)
      set_prop("Last Test Result", res.ok and (query .. " -> " .. tostring(res.value))
        or ("Query " .. query .. " failed - " .. tostring(res.err)))
    end, { priority = true })
  end,

  -- Programming commands (same dispatcher, keyed by normalised name)
  SELECTINPUTCODE = function(p)
    local code = trim(p and p.Code):upper()
    if code:match("^%w%w$") then
      gProjector:select_input(code)
    else
      dbg("warn", "Select Input Code needs a two-character input code, got '" .. code .. "'")
    end
  end,
}

local function normalize_command(name)
  return (tostring(name or ""):upper():gsub("[%s_]", ""))
end

function ExecuteCommand(strCommand, tParams)
  if not gProjector then return end
  local name = strCommand
  if strCommand == "LUA_ACTION" then
    name = tParams and tParams.ACTION
  end
  local fn = ACTIONS[normalize_command(name)]
  dbg("info", "command " .. tostring(name))
  if fn then
    fn(tParams)
  else
    dbg("warn", "unknown command " .. tostring(name))
  end
end

-- Programming conditionals --------------------------------------------------------------------

function TestCondition(strName, tParams)
  tParams = tParams or {}
  local logic, value = tParams.LOGIC, tParams.VALUE
  local result = false

  if strName == "POWER_STATE" then
    result = compare(logic, STATE_LABEL[gState] or "", value)
  elseif strName == "CURRENT_INPUT" then
    local label = "Other"
    if gInputCode then
      local _, name = binding_for_code(gInputCode)
      label = name or "Other"
    end
    result = compare(logic, label, value)
  elseif strName == "FAULT_ACTIVE" then
    result = ((gFaultActive and "Active" or "None") == value)
  elseif strName == "LIGHT_SOURCE_HOURS" then
    result = compare(logic, tonumber(gLampHours) or 0, tonumber(value) or 0)
  end

  dbg("debug", "TestCondition " .. tostring(strName) .. " -> " .. tostring(result))
  return result
end
