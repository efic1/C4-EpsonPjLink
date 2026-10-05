-- Pure-Lua MD5 (no bit library, Lua 5.1 / LuaJIT compatible).
-- Used only as a fallback when C4:Hash("MD5", ...) is unavailable.
-- All math stays below 2^53 so it is exact in double precision.

local M = {}

local floor = math.floor
local MOD = 4294967296 -- 2^32

local function band(a, b)
  local r, m = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x == 1 and y == 1 then r = r + m end
    a = (a - x) / 2
    b = (b - y) / 2
    m = m * 2
  end
  return r
end

local function bor(a, b)
  local r, m = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x == 1 or y == 1 then r = r + m end
    a = (a - x) / 2
    b = (b - y) / 2
    m = m * 2
  end
  return r
end

local function bxor(a, b)
  local r, m = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + m end
    a = (a - x) / 2
    b = (b - y) / 2
    m = m * 2
  end
  return r
end

local function bnot(a) return MOD - 1 - a end

local function rol(x, n)
  return ((x * 2 ^ n) % MOD) + floor(x / 2 ^ (32 - n))
end

local K = {}
for i = 0, 63 do
  K[i] = floor(math.abs(math.sin(i + 1)) * MOD)
end

local S = {
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local function le32(n)
  return string.char(
    n % 256,
    floor(n / 256) % 256,
    floor(n / 65536) % 256,
    floor(n / 16777216) % 256
  )
end

--- Returns the lowercase hex MD5 digest of `msg`.
function M.hex(msg)
  msg = tostring(msg)
  local len = #msg
  local bits = len * 8
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
  msg = msg .. le32(bits % MOD) .. le32(floor(bits / MOD))

  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  local w = {}

  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local b1, b2, b3, b4 = string.byte(msg, chunk + i * 4, chunk + i * 4 + 3)
      w[i] = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end

    local a, b, c, d = a0, b0, c0, d0
    for i = 0, 63 do
      local f, g
      if i < 16 then
        f = bor(band(b, c), band(bnot(b), d))
        g = i
      elseif i < 32 then
        f = bor(band(d, b), band(bnot(d), c))
        g = (5 * i + 1) % 16
      elseif i < 48 then
        f = bxor(bxor(b, c), d)
        g = (3 * i + 5) % 16
      else
        f = bxor(c, bor(b, bnot(d)))
        g = (7 * i) % 16
      end
      f = (f + a + K[i] + w[g]) % MOD
      a = d
      d = c
      c = b
      b = (b + rol(f, S[i + 1])) % MOD
    end

    a0 = (a0 + a) % MOD
    b0 = (b0 + b) % MOD
    c0 = (c0 + c) % MOD
    d0 = (d0 + d) % MOD
  end

  local out = le32(a0) .. le32(b0) .. le32(c0) .. le32(d0)
  return (out:gsub(".", function(ch) return string.format("%02x", string.byte(ch)) end))
end

return M
