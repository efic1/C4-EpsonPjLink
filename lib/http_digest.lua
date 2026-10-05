-- HTTP Digest authentication (RFC 2617, MD5, qop=auth). Pure functions.
--
-- Epson's web server answers unauthenticated requests with
--   401  WWW-Authenticate: Digest realm="Web Control", nonce="...", qop="auth"
-- and expects the request to be repeated with an Authorization header.

local M = {}

--- Case-insensitive header lookup in a table of response headers.
function M.header(headers, name)
  if type(headers) ~= "table" then return nil end
  local want = name:lower()
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == want then
      if type(v) == "table" then return v[#v] end
      return v
    end
  end
  return nil
end

--- Parse a WWW-Authenticate header value.
-- @return table {realm, nonce, qop, opaque, algorithm, stale} or nil if not Digest
function M.parse_challenge(value)
  if type(value) ~= "string" then return nil end
  local scheme, rest = value:match("^%s*(%a+)%s+(.*)$")
  if not scheme or scheme:lower() ~= "digest" then return nil end

  local ch = {}
  -- quoted values first, then blank them out so the bare-token pass cannot re-read them
  rest = rest:gsub('([%w_%-]+)%s*=%s*"([^"]*)"', function(k, v)
    ch[k:lower()] = v
    return " "
  end)
  for k, v in rest:gmatch("([%w_%-]+)%s*=%s*([^%s,\"]+)") do
    ch[k:lower()] = v
  end

  if not ch.realm or not ch.nonce then return nil end
  ch.stale = (tostring(ch.stale or ""):lower() == "true")
  return ch
end

local function quote(s)
  return (tostring(s):gsub('(["\\])', "\\%1"))
end

--- Build an Authorization header value.
-- @param ch      parsed challenge
-- @param nc      request counter for this nonce (number, starts at 1)
-- @param cnonce  client nonce (string)
-- @param md5     function(str) -> lowercase hex
-- @return string, or nil + reason when the challenge is unsupported
function M.authorization(ch, user, pass, method, uri, nc, cnonce, md5)
  local algorithm = (ch.algorithm or "MD5"):upper()
  if algorithm ~= "MD5" then
    return nil, "unsupported digest algorithm " .. algorithm
  end

  local qop
  if ch.qop then
    for token in ch.qop:gmatch("[^,%s]+") do
      if token:lower() == "auth" then qop = "auth" end
    end
    if not qop then return nil, "unsupported qop " .. ch.qop end
  end

  local ha1 = md5(user .. ":" .. ch.realm .. ":" .. (pass or ""))
  local ha2 = md5(method .. ":" .. uri)
  local ncs = string.format("%08x", nc)

  local response
  if qop then
    response = md5(ha1 .. ":" .. ch.nonce .. ":" .. ncs .. ":" .. cnonce .. ":" .. qop .. ":" .. ha2)
  else
    response = md5(ha1 .. ":" .. ch.nonce .. ":" .. ha2)
  end

  local parts = {
    'username="' .. quote(user) .. '"',
    'realm="' .. quote(ch.realm) .. '"',
    'nonce="' .. quote(ch.nonce) .. '"',
    'uri="' .. quote(uri) .. '"',
    'response="' .. response .. '"',
  }
  if ch.opaque then parts[#parts + 1] = 'opaque="' .. quote(ch.opaque) .. '"' end
  if ch.algorithm then parts[#parts + 1] = "algorithm=MD5" end
  if qop then
    parts[#parts + 1] = "qop=auth"
    parts[#parts + 1] = "nc=" .. ncs
    parts[#parts + 1] = 'cnonce="' .. quote(cnonce) .. '"'
  end
  return "Digest " .. table.concat(parts, ", ")
end

return M
