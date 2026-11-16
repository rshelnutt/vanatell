--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- SHA-256 (FIPS 180-4), shared by updates (update.lua: each file's hash) and
-- encryption (e2e.lua and random.lua). With a bit library when there is one,
-- else on integral doubles the way ws.lua's SHA-1 is. A hasher works through
-- its data in steps, so long inputs are hashed a budget at a time from
-- prerender and the game never waits on them.
local sha256 = {}

local floor = math.floor
local byte, char, concat = string.byte, string.char, table.concat

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local H0 = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}
local TWO32 = 4294967296

local function word_bytes(w)
  return char(floor(w / 16777216), floor(w / 65536) % 256, floor(w / 256) % 256, w % 256)
end

-- An implementation: {init = fn() -> state, compress = fn(state, s, pos)
-- for the 64-byte block of s at pos, hex = fn(state) -> digest, raw = fn(state)
-- -> the digest's 32 bytes, name =}.
local function bit_impl(bit)
  local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
  local lshift, rshift, ror, tobit, tohex = bit.lshift, bit.rshift, bit.ror, bit.tobit, bit.tohex
  local k = {}
  for i = 1, 64 do k[i] = tobit(K[i]) end
  local w = {}
  local impl = {name = 'bit'}
  function impl.init()
    local h = {}
    for i = 1, 8 do h[i] = tobit(H0[i]) end
    return h
  end
  function impl.compress(h, s, pos)
    for t = 1, 16 do
      local i = pos + (t - 1) * 4
      local b1, b2, b3, b4 = byte(s, i, i + 3)
      w[t] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
    end
    for t = 17, 64 do
      local x, y = w[t - 15], w[t - 2]
      local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
      local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
      w[t] = tobit(w[t - 16] + s0 + w[t - 7] + s1)
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for t = 1, 64 do
      local t1 = hh + bxor(ror(e, 6), ror(e, 11), ror(e, 25)) + bxor(band(e, f), band(bnot(e), g)) + k[t] + w[t]
      local t2 = bxor(ror(a, 2), ror(a, 13), ror(a, 22)) + bxor(band(a, b), band(a, c), band(b, c))
      hh, g, f = g, f, e
      e = tobit(d + t1)
      d, c, b = c, b, a
      a = tobit(t1 + t2)
    end
    h[1], h[2], h[3], h[4] = tobit(h[1] + a), tobit(h[2] + b), tobit(h[3] + c), tobit(h[4] + d)
    h[5], h[6], h[7], h[8] = tobit(h[5] + e), tobit(h[6] + f), tobit(h[7] + g), tobit(h[8] + hh)
  end
  function impl.hex(h)
    local out = {}
    for i = 1, 8 do out[i] = tohex(h[i], 8) end
    return concat(out)
  end
  function impl.raw(h)
    local out = {}
    for i = 1, 8 do out[i] = word_bytes(h[i] % TWO32) end
    return concat(out)
  end
  return impl
end

-- Without a bit library: XOR from a byte table, built the first time it is
-- needed (it is never needed where a bit library loads).
local XOR8
local function xor8()
  if XOR8 then return XOR8 end
  XOR8 = {}
  for a = 0, 255 do
    for b = 0, 255 do
      local x, y, r, place = a, b, 0, 1
      for _ = 1, 8 do
        if x % 2 ~= y % 2 then r = r + place end
        x, y, place = floor(x / 2), floor(y / 2), place * 2
      end
      XOR8[a * 256 + b + 1] = r
    end
  end
  return XOR8
end

local function pure_impl()
  local X = xor8()
  local function bxor(a, b)
    local a0, b0 = a % 256, b % 256
    a, b = (a - a0) / 256, (b - b0) / 256
    local a1, b1 = a % 256, b % 256
    a, b = (a - a1) / 256, (b - b1) / 256
    local a2, b2 = a % 256, b % 256
    local a3, b3 = (a - a2) / 256, (b - b2) / 256
    return X[a0 * 256 + b0 + 1] + X[a1 * 256 + b1 + 1] * 256 + X[a2 * 256 + b2 + 1] * 65536
      + X[a3 * 256 + b3 + 1] * 16777216
  end
  local function band(a, b) return (a + b - bxor(a, b)) / 2 end
  local function bnot(a) return 4294967295 - a end
  local function ror(x, n)
    local p = 2 ^ n
    local lo = x % p
    return (x - lo) / p + lo * (TWO32 / p)
  end
  local function shr(x, n) return floor(x / 2 ^ n) end
  local w = {}
  local impl = {name = 'pure'}
  function impl.init()
    local h = {}
    for i = 1, 8 do h[i] = H0[i] end
    return h
  end
  function impl.compress(h, s, pos)
    for t = 1, 16 do
      local i = pos + (t - 1) * 4
      local b1, b2, b3, b4 = byte(s, i, i + 3)
      w[t] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    end
    for t = 17, 64 do
      local x, y = w[t - 15], w[t - 2]
      local s0 = bxor(bxor(ror(x, 7), ror(x, 18)), shr(x, 3))
      local s1 = bxor(bxor(ror(y, 17), ror(y, 19)), shr(y, 10))
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) % TWO32
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for t = 1, 64 do
      local S1 = bxor(bxor(ror(e, 6), ror(e, 11)), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = hh + S1 + ch + K[t] + w[t]
      local S0 = bxor(bxor(ror(a, 2), ror(a, 13)), ror(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      hh, g, f = g, f, e
      e = (d + t1) % TWO32
      d, c, b = c, b, a
      a = (t1 + S0 + maj) % TWO32
    end
    h[1], h[2], h[3], h[4] = (h[1] + a) % TWO32, (h[2] + b) % TWO32, (h[3] + c) % TWO32, (h[4] + d) % TWO32
    h[5], h[6], h[7], h[8] = (h[5] + e) % TWO32, (h[6] + f) % TWO32, (h[7] + g) % TWO32, (h[8] + hh) % TWO32
  end
  function impl.hex(h)
    local out = {}
    for i = 1, 8 do out[i] = string.format('%08x', h[i]) end
    return concat(out)
  end
  function impl.raw(h)
    local out = {}
    for i = 1, 8 do out[i] = word_bytes(h[i]) end
    return concat(out)
  end
  return impl
end

-- The bit library this Lua has: require('bit') (LuaBitOp on Windower, built
-- into LuaJIT on Ashita), else a global bit; nil when there is none.
function sha256.find_bit()
  local function usable(lib)
    return type(lib) == 'table' and type(lib.bxor) == 'function' and type(lib.ror) == 'function'
      and type(lib.tobit) == 'function' and type(lib.tohex) == 'function'
  end
  local ok, lib = pcall(require, 'bit')
  if ok and usable(lib) then return lib end
  lib = rawget(_G, 'bit')
  if usable(lib) then return lib end
  return nil
end

-- bit: a bit library, or false for none -> an implementation. nil picks the
-- one this Lua has.
function sha256.impl(bit)
  if bit == nil then bit = sha256.find_bit() or false end
  if bit then return bit_impl(bit) end
  return pure_impl()
end

-- A SHA-256 of data, worked through in steps. hasher:step(n) hashes about n
-- more bytes (whole 64-byte blocks) and returns the hex digest once data is
-- done, else nil; hasher.raw then holds its 32 bytes. hasher.hashed counts
-- the bytes hashed so far.
local Hasher = {}
Hasher.__index = Hasher

function sha256.hasher(data, impl)
  local len = #data
  local whole = len - len % 64
  local bits = len * 8
  local tail = data:sub(whole + 1) .. '\128' .. ('\0'):rep((55 - len) % 64)
    .. word_bytes(floor(bits / TWO32)) .. word_bytes(bits % TWO32)
  return setmetatable({data = data, whole = whole, tail = tail, pos = 1, hashed = 0, impl = impl,
                       state = impl.init()}, Hasher)
end

function Hasher:step(budget)
  if self.digest then return self.digest end
  local compress, data, state = self.impl.compress, self.data, self.state
  local blocks = math.max(1, math.ceil(budget / 64))
  while blocks > 0 and self.pos <= self.whole do
    compress(state, data, self.pos)
    self.pos, self.hashed, blocks = self.pos + 64, self.hashed + 64, blocks - 1
  end
  if self.pos > self.whole and blocks > 0 then
    for i = 1, #self.tail, 64 do compress(state, self.tail, i) end
    self.hashed = self.hashed + #self.tail
    self.digest = self.impl.hex(state)
    self.raw = self.impl.raw(state)
  end
  return self.digest
end

-- The whole digest at once, for small inputs: 64 hex characters, or its 32
-- bytes. impl: nil picks the one this Lua has.
local default
local function whole(data, impl)
  if not impl then
    default = default or sha256.impl()
    impl = default
  end
  local h = sha256.hasher(data, impl)
  h:step(math.huge)
  return h
end

function sha256.hex(data, impl) return whole(data, impl).digest end
function sha256.digest(data, impl) return whole(data, impl).raw end

return sha256
