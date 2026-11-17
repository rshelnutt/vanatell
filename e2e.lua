--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- End-to-end encryption of chat text, in plain Lua: X25519 (RFC 7748) for
-- the key exchange with the phone, ChaCha20-Poly1305 (RFC 8439) for each
-- line and each phone send, HMAC-SHA256 and HKDF (RFC 5869) over the
-- SHA-256 in sha256.lua. Everything here needs a bit library (LuaBitOp on
-- Windower, LuaJIT's bit on Ashita); without one, e2e.available() is false
-- and the addon stays plaintext. X25519 keeps TweetNaCl's field layout (16
-- limbs of 16 bits, held in doubles), and Poly1305 uses 10 limbs of 13 bits,
-- so every sum of products stays exact in a double. Nothing here is
-- constant-time, and in Lua it cannot be: the relay sees no timing on this
-- PC, and anything on the PC that could measure it can read the key file
-- anyway. The slow part, a scalar multiplication, runs as a job a few
-- ladder steps at a time from prerender, so the game never hitches.
local e2e = {}

local floor, byte, char, concat = math.floor, string.byte, string.char, table.concat

local here = debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or ''
local sha256 = dofile(here .. 'sha256.lua')

local bit = sha256.find_bit()
if bit and not (bit.rol and bit.band and bit.bor and bit.lshift and bit.rshift) then bit = nil end

-- True when this Lua has the bit library encryption needs.
function e2e.available()
  return bit ~= nil
end

-- Ladder steps per prerender for a scalar multiplication: 64 on LuaJIT with
-- its compiler on, else 8 (Lua 5.1, and LuaJIT with the compiler off, which
-- runs this about as fast as Lua 5.1): about 0.2 ms a frame on a fast PC.
local jit = rawget(_G, 'jit')
e2e.STEPS = (jit and jit.status and jit.status()) and 64 or 8

---------------------------------------------------------------------------
-- Base64url without padding (RFC 4648, section 5).
---------------------------------------------------------------------------
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
local B64_INDEX = {}
for i = 1, 64 do B64_INDEX[B64:byte(i)] = i - 1 end

function e2e.b64url(s)
  local out, n = {}, #s
  for i = 1, n, 3 do
    local a, b, c = byte(s, i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    local chars = c and 4 or b and 3 or 2
    for j = 1, chars do
      local x = floor(v / 2 ^ (18 - 6 * (j - 1))) % 64
      out[#out + 1] = B64:sub(x + 1, x + 1)
    end
  end
  return concat(out)
end

-- The bytes of a canonical unpadded base64url string; nil for anything else
-- (padding, '+' or '/', a length of 4n + 1, or leftover bits that are not 0).
function e2e.unb64url(s)
  if type(s) ~= 'string' or #s % 4 == 1 then return nil end
  local out, acc, bits = {}, 0, 0
  for i = 1, #s do
    local x = B64_INDEX[byte(s, i)]
    if not x then return nil end
    acc, bits = acc * 64 + x, bits + 6
    if bits >= 8 then
      bits = bits - 8
      local p = 2 ^ bits
      local b = floor(acc / p)
      out[#out + 1] = char(b)
      acc = acc - b * p
    end
  end
  if acc ~= 0 then return nil end
  return concat(out)
end

if not bit then return e2e end

local band, bor, bxor, rol, rshift, tobit = bit.band, bit.bor, bit.bxor, bit.rol, bit.rshift, bit.tobit
local impl = sha256.impl(bit)

---------------------------------------------------------------------------
-- HMAC-SHA256 and HKDF.
---------------------------------------------------------------------------
local function digest(data) return sha256.digest(data, impl) end
e2e.sha256 = digest

local IPAD, OPAD = {}, {}
for b = 0, 255 do
  IPAD[char(b)] = char(bxor(b, 0x36))
  OPAD[char(b)] = char(bxor(b, 0x5c))
end

function e2e.hmac(key, msg)
  if #key > 64 then key = digest(key) end
  key = key .. ('\0'):rep(64 - #key)
  return digest(key:gsub('.', OPAD) .. digest(key:gsub('.', IPAD) .. msg))
end
local hmac = e2e.hmac

-- HKDF-SHA256 (RFC 5869): len bytes of output key material.
function e2e.hkdf(salt, ikm, info, len)
  local prk = hmac(salt, ikm)
  local out, t, i = {}, '', 1
  while 32 * (i - 1) < len do
    t = hmac(prk, t .. info .. char(i))
    out[i] = t
    i = i + 1
  end
  return concat(out):sub(1, len)
end

---------------------------------------------------------------------------
-- ChaCha20 (RFC 8439 2.4).
---------------------------------------------------------------------------
local function le32(s, i)
  local a, b, c, d = byte(s, i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

local function words(s, n)
  local w = {}
  for i = 1, n do w[i] = le32(s, 4 * i - 3) end
  return w
end

-- One ChaCha20 block (RFC 8439 2.3): 16 key-stream words into out, from the
-- 8 key words k, the block counter and the 3 nonce words n.
local function chacha_block(k, counter, n, out)
  local x0, x1, x2, x3 = 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
  local x4, x5, x6, x7, x8, x9, x10, x11 = k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8]
  local x12, x13, x14, x15 = counter, n[1], n[2], n[3]
  for _ = 1, 10 do
    x0 = tobit(x0 + x4); x12 = rol(bxor(x12, x0), 16)
    x8 = tobit(x8 + x12); x4 = rol(bxor(x4, x8), 12)
    x0 = tobit(x0 + x4); x12 = rol(bxor(x12, x0), 8)
    x8 = tobit(x8 + x12); x4 = rol(bxor(x4, x8), 7)
    x1 = tobit(x1 + x5); x13 = rol(bxor(x13, x1), 16)
    x9 = tobit(x9 + x13); x5 = rol(bxor(x5, x9), 12)
    x1 = tobit(x1 + x5); x13 = rol(bxor(x13, x1), 8)
    x9 = tobit(x9 + x13); x5 = rol(bxor(x5, x9), 7)
    x2 = tobit(x2 + x6); x14 = rol(bxor(x14, x2), 16)
    x10 = tobit(x10 + x14); x6 = rol(bxor(x6, x10), 12)
    x2 = tobit(x2 + x6); x14 = rol(bxor(x14, x2), 8)
    x10 = tobit(x10 + x14); x6 = rol(bxor(x6, x10), 7)
    x3 = tobit(x3 + x7); x15 = rol(bxor(x15, x3), 16)
    x11 = tobit(x11 + x15); x7 = rol(bxor(x7, x11), 12)
    x3 = tobit(x3 + x7); x15 = rol(bxor(x15, x3), 8)
    x11 = tobit(x11 + x15); x7 = rol(bxor(x7, x11), 7)
    x0 = tobit(x0 + x5); x15 = rol(bxor(x15, x0), 16)
    x10 = tobit(x10 + x15); x5 = rol(bxor(x5, x10), 12)
    x0 = tobit(x0 + x5); x15 = rol(bxor(x15, x0), 8)
    x10 = tobit(x10 + x15); x5 = rol(bxor(x5, x10), 7)
    x1 = tobit(x1 + x6); x12 = rol(bxor(x12, x1), 16)
    x11 = tobit(x11 + x12); x6 = rol(bxor(x6, x11), 12)
    x1 = tobit(x1 + x6); x12 = rol(bxor(x12, x1), 8)
    x11 = tobit(x11 + x12); x6 = rol(bxor(x6, x11), 7)
    x2 = tobit(x2 + x7); x13 = rol(bxor(x13, x2), 16)
    x8 = tobit(x8 + x13); x7 = rol(bxor(x7, x8), 12)
    x2 = tobit(x2 + x7); x13 = rol(bxor(x13, x2), 8)
    x8 = tobit(x8 + x13); x7 = rol(bxor(x7, x8), 7)
    x3 = tobit(x3 + x4); x14 = rol(bxor(x14, x3), 16)
    x9 = tobit(x9 + x14); x4 = rol(bxor(x4, x9), 12)
    x3 = tobit(x3 + x4); x14 = rol(bxor(x14, x3), 8)
    x9 = tobit(x9 + x14); x4 = rol(bxor(x4, x9), 7)
  end
  out[1] = tobit(x0 + 0x61707865)
  out[2] = tobit(x1 + 0x3320646e)
  out[3] = tobit(x2 + 0x79622d32)
  out[4] = tobit(x3 + 0x6b206574)
  out[5] = tobit(x4 + k[1])
  out[6] = tobit(x5 + k[2])
  out[7] = tobit(x6 + k[3])
  out[8] = tobit(x7 + k[4])
  out[9] = tobit(x8 + k[5])
  out[10] = tobit(x9 + k[6])
  out[11] = tobit(x10 + k[7])
  out[12] = tobit(x11 + k[8])
  out[13] = tobit(x12 + counter)
  out[14] = tobit(x13 + n[1])
  out[15] = tobit(x14 + n[2])
  out[16] = tobit(x15 + n[3])
end

-- data XOR the key stream from block counter on.
local function chacha20(key, counter, nonce, data)
  local k, n, ks, out = words(key, 8), words(nonce, 3), {}, {}
  local len, pos = #data, 1
  while pos <= len do
    chacha_block(k, counter, n, ks)
    counter = counter + 1
    for i = 1, 16 do
      if pos > len then break end
      local w = ks[i]
      if pos + 3 <= len then
        local c = bxor(le32(data, pos), w)
        out[#out + 1] = char(band(c, 255), band(rshift(c, 8), 255), band(rshift(c, 16), 255), rshift(c, 24))
      else
        for j = 0, len - pos do
          out[#out + 1] = char(bxor(byte(data, pos + j), band(rshift(w, 8 * j), 255)))
        end
      end
      pos = pos + 4
    end
  end
  return concat(out)
end

---------------------------------------------------------------------------
-- Poly1305 (RFC 8439 2.5), in 10 limbs of 13 bits.
---------------------------------------------------------------------------
local P2 = {}
for i = 0, 40 do P2[i] = 2 ^ i end

-- 16 bytes of s at pos, little-endian, plus 2^128 -> 10 limbs.
local function block_limbs(s, pos, t)
  local acc, nb, k = 0, 0, 1
  for i = pos, pos + 15 do
    acc = acc + byte(s, i) * P2[nb]
    nb = nb + 8
    if nb >= 13 then
      local l = acc % 8192
      t[k], k, acc, nb = l, k + 1, (acc - l) / 8192, nb - 13
    end
  end
  t[10] = acc + 2048
  return t
end

-- msg is a whole number of 16-byte blocks, as the AEAD's MAC input always is.
local function poly1305(otk, msg)
  local r = {}
  block_limbs(otk:sub(1, 3) .. char(band(byte(otk, 4), 15), band(byte(otk, 5), 252)) .. otk:sub(6, 7)
    .. char(band(byte(otk, 8), 15), band(byte(otk, 9), 252)) .. otk:sub(10, 11)
    .. char(band(byte(otk, 12), 15), band(byte(otk, 13), 252)) .. otk:sub(14, 15) .. char(band(byte(otk, 16), 15)), 1, r)
  r[10] = r[10] - 2048
  local r5 = {}
  for i = 1, 10 do r5[i] = 5 * r[i] end
  local h, m, d = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, {}, {}
  for pos = 1, #msg, 16 do
    block_limbs(msg, pos, m)
    for i = 1, 10 do h[i] = h[i] + m[i] end
    for i = 1, 10 do
      local s = 0
      for j = 1, i do s = s + h[j] * r[i - j + 1] end
      for j = i + 1, 10 do s = s + h[j] * r5[i - j + 11] end
      d[i] = s
    end
    local c = 0
    for i = 1, 10 do
      local v = d[i] + c
      local l = v % 8192
      h[i], c = l, (v - l) / 8192
    end
    h[1] = h[1] + 5 * c
    local l = h[1] % 8192
    h[2], h[1] = h[2] + (h[1] - l) / 8192, l
  end
  -- Fully carry, then take h - p when h >= p.
  for _ = 1, 2 do
    local c = 0
    for i = 1, 10 do
      local v = h[i] + c
      local l = v % 8192
      h[i], c = l, (v - l) / 8192
    end
    h[1] = h[1] + 5 * c
  end
  local g, c = {}, 5
  for i = 1, 10 do
    local v = h[i] + c
    local l = v % 8192
    g[i], c = l, (v - l) / 8192
  end
  if c > 0 then h = g end
  -- h mod 2^128, plus s, as 16 bytes.
  local out, acc, nb = {}, 0, 0
  for i = 1, 10 do
    acc, nb = acc + h[i] * P2[nb], nb + 13
    while nb >= 8 and #out < 16 do
      local b = acc % 256
      out[#out + 1], acc, nb = b, (acc - b) / 256, nb - 8
    end
  end
  c = 0
  for i = 1, 16 do
    local v = out[i] + byte(otk, 16 + i) + c
    out[i], c = char(v % 256), floor(v / 256)
  end
  return concat(out)
end

---------------------------------------------------------------------------
-- ChaCha20-Poly1305 (RFC 8439 2.8): 32-byte key, 12-byte nonce.
---------------------------------------------------------------------------
local function pad16(s)
  return ('\0'):rep((16 - #s % 16) % 16)
end

local function le64(n)
  local out = {}
  for i = 1, 8 do
    local b = n % 256
    out[i], n = char(b), (n - b) / 256
  end
  return concat(out)
end

local function tag_of(key, nonce, ct, aad)
  local otk = chacha20(key, 0, nonce, ('\0'):rep(32))
  return poly1305(otk, aad .. pad16(aad) .. ct .. pad16(ct) .. le64(#aad) .. le64(#ct))
end

-- -> ciphertext .. 16-byte tag
function e2e.seal(key, nonce, plaintext, aad)
  local ct = chacha20(key, 1, nonce, plaintext)
  return ct .. tag_of(key, nonce, ct, aad)
end

-- -> the plaintext, or nil when the tag does not match.
function e2e.open(key, nonce, sealed, aad)
  if type(sealed) ~= 'string' or #sealed < 16 or #key ~= 32 or #nonce ~= 12 then return nil end
  local ct = sealed:sub(1, -17)
  if tag_of(key, nonce, ct, aad) ~= sealed:sub(-16) then return nil end
  return chacha20(key, 1, nonce, ct)
end

---------------------------------------------------------------------------
-- X25519 (RFC 7748), in TweetNaCl's layout: a field element is 16 limbs of
-- 16 bits, least significant first, in doubles.
---------------------------------------------------------------------------
local function gf(init)
  local o = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
  if init then for i = 1, #init do o[i] = init[i] end end
  return o
end

local function A(o, a, b) for i = 1, 16 do o[i] = a[i] + b[i] end end
local function Z(o, a, b) for i = 1, 16 do o[i] = a[i] - b[i] end end
-- o = a * b mod 2^255 - 19 (o may be a or b). Unrolled: every product sum
-- stays below 2^53, so it is exact in a double; then two carry passes.
local function M(o, a, b)
  local a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16]
  local b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15 = b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16]
  local t0 = a0*b0
  local t1 = a0*b1 + a1*b0
  local t2 = a0*b2 + a1*b1 + a2*b0
  local t3 = a0*b3 + a1*b2 + a2*b1 + a3*b0
  local t4 = a0*b4 + a1*b3 + a2*b2 + a3*b1 + a4*b0
  local t5 = a0*b5 + a1*b4 + a2*b3 + a3*b2 + a4*b1 + a5*b0
  local t6 = a0*b6 + a1*b5 + a2*b4 + a3*b3 + a4*b2 + a5*b1 + a6*b0
  local t7 = a0*b7 + a1*b6 + a2*b5 + a3*b4 + a4*b3 + a5*b2 + a6*b1 + a7*b0
  local t8 = a0*b8 + a1*b7 + a2*b6 + a3*b5 + a4*b4 + a5*b3 + a6*b2 + a7*b1 + a8*b0
  local t9 = a0*b9 + a1*b8 + a2*b7 + a3*b6 + a4*b5 + a5*b4 + a6*b3 + a7*b2 + a8*b1 + a9*b0
  local t10 = a0*b10 + a1*b9 + a2*b8 + a3*b7 + a4*b6 + a5*b5 + a6*b4 + a7*b3 + a8*b2 + a9*b1 + a10*b0
  local t11 = a0*b11 + a1*b10 + a2*b9 + a3*b8 + a4*b7 + a5*b6 + a6*b5 + a7*b4 + a8*b3 + a9*b2 + a10*b1 + a11*b0
  local t12 = a0*b12 + a1*b11 + a2*b10 + a3*b9 + a4*b8 + a5*b7 + a6*b6 + a7*b5 + a8*b4 + a9*b3 + a10*b2 + a11*b1 + a12*b0
  local t13 = a0*b13 + a1*b12 + a2*b11 + a3*b10 + a4*b9 + a5*b8 + a6*b7 + a7*b6 + a8*b5 + a9*b4 + a10*b3 + a11*b2 + a12*b1 + a13*b0
  local t14 = a0*b14 + a1*b13 + a2*b12 + a3*b11 + a4*b10 + a5*b9 + a6*b8 + a7*b7 + a8*b6 + a9*b5 + a10*b4 + a11*b3 + a12*b2 + a13*b1 + a14*b0
  local t15 = a0*b15 + a1*b14 + a2*b13 + a3*b12 + a4*b11 + a5*b10 + a6*b9 + a7*b8 + a8*b7 + a9*b6 + a10*b5 + a11*b4 + a12*b3 + a13*b2 + a14*b1 + a15*b0
  local t16 = a1*b15 + a2*b14 + a3*b13 + a4*b12 + a5*b11 + a6*b10 + a7*b9 + a8*b8 + a9*b7 + a10*b6 + a11*b5 + a12*b4 + a13*b3 + a14*b2 + a15*b1
  local t17 = a2*b15 + a3*b14 + a4*b13 + a5*b12 + a6*b11 + a7*b10 + a8*b9 + a9*b8 + a10*b7 + a11*b6 + a12*b5 + a13*b4 + a14*b3 + a15*b2
  local t18 = a3*b15 + a4*b14 + a5*b13 + a6*b12 + a7*b11 + a8*b10 + a9*b9 + a10*b8 + a11*b7 + a12*b6 + a13*b5 + a14*b4 + a15*b3
  local t19 = a4*b15 + a5*b14 + a6*b13 + a7*b12 + a8*b11 + a9*b10 + a10*b9 + a11*b8 + a12*b7 + a13*b6 + a14*b5 + a15*b4
  local t20 = a5*b15 + a6*b14 + a7*b13 + a8*b12 + a9*b11 + a10*b10 + a11*b9 + a12*b8 + a13*b7 + a14*b6 + a15*b5
  local t21 = a6*b15 + a7*b14 + a8*b13 + a9*b12 + a10*b11 + a11*b10 + a12*b9 + a13*b8 + a14*b7 + a15*b6
  local t22 = a7*b15 + a8*b14 + a9*b13 + a10*b12 + a11*b11 + a12*b10 + a13*b9 + a14*b8 + a15*b7
  local t23 = a8*b15 + a9*b14 + a10*b13 + a11*b12 + a12*b11 + a13*b10 + a14*b9 + a15*b8
  local t24 = a9*b15 + a10*b14 + a11*b13 + a12*b12 + a13*b11 + a14*b10 + a15*b9
  local t25 = a10*b15 + a11*b14 + a12*b13 + a13*b12 + a14*b11 + a15*b10
  local t26 = a11*b15 + a12*b14 + a13*b13 + a14*b12 + a15*b11
  local t27 = a12*b15 + a13*b14 + a14*b13 + a15*b12
  local t28 = a13*b15 + a14*b14 + a15*b13
  local t29 = a14*b15 + a15*b14
  local t30 = a15*b15
  t0 = t0 + 38*t16
  t1 = t1 + 38*t17
  t2 = t2 + 38*t18
  t3 = t3 + 38*t19
  t4 = t4 + 38*t20
  t5 = t5 + 38*t21
  t6 = t6 + 38*t22
  t7 = t7 + 38*t23
  t8 = t8 + 38*t24
  t9 = t9 + 38*t25
  t10 = t10 + 38*t26
  t11 = t11 + 38*t27
  t12 = t12 + 38*t28
  t13 = t13 + 38*t29
  t14 = t14 + 38*t30
  local r
  r = t0 % 65536; t1 = t1 + (t0 - r) / 65536; t0 = r
  r = t1 % 65536; t2 = t2 + (t1 - r) / 65536; t1 = r
  r = t2 % 65536; t3 = t3 + (t2 - r) / 65536; t2 = r
  r = t3 % 65536; t4 = t4 + (t3 - r) / 65536; t3 = r
  r = t4 % 65536; t5 = t5 + (t4 - r) / 65536; t4 = r
  r = t5 % 65536; t6 = t6 + (t5 - r) / 65536; t5 = r
  r = t6 % 65536; t7 = t7 + (t6 - r) / 65536; t6 = r
  r = t7 % 65536; t8 = t8 + (t7 - r) / 65536; t7 = r
  r = t8 % 65536; t9 = t9 + (t8 - r) / 65536; t8 = r
  r = t9 % 65536; t10 = t10 + (t9 - r) / 65536; t9 = r
  r = t10 % 65536; t11 = t11 + (t10 - r) / 65536; t10 = r
  r = t11 % 65536; t12 = t12 + (t11 - r) / 65536; t11 = r
  r = t12 % 65536; t13 = t13 + (t12 - r) / 65536; t12 = r
  r = t13 % 65536; t14 = t14 + (t13 - r) / 65536; t13 = r
  r = t14 % 65536; t15 = t15 + (t14 - r) / 65536; t14 = r
  r = t15 % 65536; t0 = t0 + 38 * ((t15 - r) / 65536); t15 = r
  r = t0 % 65536; t1 = t1 + (t0 - r) / 65536; t0 = r
  r = t1 % 65536; t2 = t2 + (t1 - r) / 65536; t1 = r
  r = t2 % 65536; t3 = t3 + (t2 - r) / 65536; t2 = r
  r = t3 % 65536; t4 = t4 + (t3 - r) / 65536; t3 = r
  r = t4 % 65536; t5 = t5 + (t4 - r) / 65536; t4 = r
  r = t5 % 65536; t6 = t6 + (t5 - r) / 65536; t5 = r
  r = t6 % 65536; t7 = t7 + (t6 - r) / 65536; t6 = r
  r = t7 % 65536; t8 = t8 + (t7 - r) / 65536; t7 = r
  r = t8 % 65536; t9 = t9 + (t8 - r) / 65536; t8 = r
  r = t9 % 65536; t10 = t10 + (t9 - r) / 65536; t9 = r
  r = t10 % 65536; t11 = t11 + (t10 - r) / 65536; t10 = r
  r = t11 % 65536; t12 = t12 + (t11 - r) / 65536; t11 = r
  r = t12 % 65536; t13 = t13 + (t12 - r) / 65536; t12 = r
  r = t13 % 65536; t14 = t14 + (t13 - r) / 65536; t13 = r
  r = t14 % 65536; t15 = t15 + (t14 - r) / 65536; t14 = r
  r = t15 % 65536; t0 = t0 + 38 * ((t15 - r) / 65536); t15 = r
  o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10], o[11], o[12], o[13], o[14], o[15], o[16] = t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12, t13, t14, t15
end
local function S(o, a) M(o, a, a) end

local function carry(o)
  for i = 1, 16 do
    local r = o[i] % 65536
    local c = (o[i] - r) / 65536
    o[i] = r
    if i < 16 then o[i + 1] = o[i + 1] + c else o[1] = o[1] + 38 * c end
  end
end

-- 32 bytes, little-endian, with bit 255 masked (RFC 7748 section 5).
local function unpack25519(s)
  local o = {}
  for i = 1, 16 do o[i] = byte(s, 2 * i - 1) + 256 * byte(s, 2 * i) end
  o[16] = o[16] % 32768
  return o
end

-- The canonical 32 bytes of n (fully reduced below 2^255 - 19).
local function pack25519(n)
  local t = gf(n)
  carry(t); carry(t); carry(t)
  for _ = 1, 2 do
    local m, borrow = {}, 0
    m[1] = t[1] - 0xffed
    for i = 2, 15 do
      borrow = m[i - 1] < 0 and 1 or 0
      m[i - 1] = m[i - 1] % 65536
      m[i] = t[i] - 0xffff - borrow
    end
    borrow = m[15] < 0 and 1 or 0
    m[15] = m[15] % 65536
    m[16] = t[16] - 0x7fff - borrow
    if m[16] >= 0 then t = m end
  end
  local out = {}
  for i = 1, 16 do out[i] = char(t[i] % 256, floor(t[i] / 256)) end
  return concat(out)
end

local K121665 = gf({0xdb41, 1})
local BASE = char(9) .. ('\0'):rep(31)
local INV_SLICE = 32 -- squarings per step of the final inversion

local Job = {}
Job.__index = Job

-- A scalar multiplication, scalar * u, done a few ladder steps per call:
-- job:step(n) does at most n ladder steps, or one slice of the final
-- inversion, and returns the 32-byte result once it is done (false when it
-- is all zero, a low-order point), else nil. job.ladder_done counts the
-- ladder steps done (255 in all).
function e2e.x25519_job(scalar, u)
  local z = {byte(scalar, 1, 32)}
  z[32] = z[32] % 64 + 64 -- clear bit 255, set bit 254
  z[1] = z[1] - z[1] % 8 -- clear bits 0-2
  local x = unpack25519(u)
  return setmetatable({z = z, x = x, a = gf({1}), b = gf(x), c = gf(), d = gf({1}), e = gf(), f = gf(),
                       i = 254, ladder_done = 0, done = false}, Job)
end

function Job:step(n)
  if self.done then return self.result end
  if self.i >= 0 then
    local z, x, a, b, c, d, e, f = self.z, self.x, self.a, self.b, self.c, self.d, self.e, self.f
    local i, stop = self.i, math.max(self.i - n, -1)
    while i > stop do
      local r = floor(z[floor(i / 8) + 1] / P2[i % 8]) % 2
      if r == 1 then a, b, c, d = b, a, d, c end
      A(e, a, c); Z(a, a, c); A(c, b, d); Z(b, b, d)
      S(d, e); S(f, a); M(a, c, a); M(c, b, e)
      A(e, a, c); Z(a, a, c); S(b, a); Z(c, d, f)
      M(a, c, K121665); A(a, a, d); M(c, c, a); M(a, d, f); M(d, b, x)
      S(b, e)
      if r == 1 then a, b, c, d = b, a, d, c end
      i = i - 1
    end
    self.a, self.b, self.c, self.d, self.i = a, b, c, d, i
    self.ladder_done = 254 - i
    if i < 0 then self.inv, self.k = gf(c), 253 end
    return nil
  end
  -- c^(p - 2) by square-and-multiply, INV_SLICE squarings a step; then a / c.
  local inv, c, k = self.inv, self.c, self.k
  local stop = math.max(k - INV_SLICE, -1)
  while k > stop do
    S(inv, inv)
    if k ~= 2 and k ~= 4 then M(inv, inv, c) end
    k = k - 1
  end
  self.k = k
  if k >= 0 then return nil end
  local out = gf()
  M(out, self.a, inv)
  local result = pack25519(out)
  self.done = true
  self.result = result ~= ('\0'):rep(32) and result or false
  self.z, self.x, self.a, self.b, self.c, self.d, self.e, self.f, self.inv = nil, nil, nil, nil, nil, nil, nil, nil, nil
  return self.result
end

-- X25519(scalar, u) at once; nil when the shared secret is all zero.
function e2e.x25519(scalar, u)
  local job, r = e2e.x25519_job(scalar, u), nil
  repeat r = job:step(255) until r ~= nil
  return r or nil
end

-- scalar's public key: X25519(scalar, 9).
function e2e.x25519_base(scalar)
  return e2e.x25519(scalar, BASE)
end
e2e.BASE = BASE

---------------------------------------------------------------------------
-- The key schedule: what both sides derive from one exchange.
---------------------------------------------------------------------------
local LABEL = {
  commit = 'VanaTell e2e v1 commit', transcript = 'VanaTell e2e v1 transcript', keys = 'VanaTell e2e v1 keys',
  key_id = 'VanaTell e2e v1 key id', code = 'VanaTell e2e v1 safety code', confirm = 'VanaTell e2e v1 confirm',
  done = 'VanaTell e2e v1 done', phone = 'VanaTell e2e v1 recover phone', addon = 'VanaTell e2e v1 recover addon',
  line = 'VanaTell e2e v1 line', send = 'VanaTell e2e v1 send',
}
local KEY_NAMES = {'lineKey', 'lineNonce', 'sendKey', 'sendNonce', 'confirmKey', 'storeKey', 'storeNonce', 'recoverKey'}

-- One byte holding the byte length of s (at most 255), then s.
function e2e.lp(s)
  assert(#s <= 255, 'lp: more than 255 bytes')
  return char(#s) .. s
end
local lp = e2e.lp

-- h = SHA-256(lp("VanaTell e2e v1 commit") || lp(kxId) || B): the phone's
-- commitment to its key, checked against B when the phone reveals it.
function e2e.commit_hash(kx_id, B)
  return digest(lp(LABEL.commit) .. lp(kx_id) .. B)
end

-- th, the transcript hash every key and code of the exchange comes from.
function e2e.transcript(account_id, kx_id, A, B)
  return digest(lp(LABEL.transcript) .. lp(account_id) .. lp(kx_id) .. A .. B)
end

-- The eight 32-byte keys, from the shared secret and the transcript.
function e2e.derive(shared, th)
  local okm, keys = e2e.hkdf(th, shared, LABEL.keys, 256), {}
  for i, name in ipairs(KEY_NAMES) do keys[name] = okm:sub(32 * i - 31, 32 * i) end
  return keys
end

local function to_hex(s)
  return (s:gsub('.', function(c) return string.format('%02x', byte(c)) end))
end

-- The key set's id: 16 lowercase hex characters.
function e2e.key_id(th)
  return to_hex(digest(lp(LABEL.key_id) .. th):sub(1, 8))
end

-- n (below 10^12) as 12 digits in three groups: '4821 0937 5512'.
function e2e.format_code(n)
  local digits = string.format('%012.0f', n % 1e12)
  return digits:sub(1, 4) .. ' ' .. digits:sub(5, 8) .. ' ' .. digits:sub(9, 12)
end

-- The safety code: the first 48 bits of a hash of the transcript, mod 10^12.
function e2e.safety_code(th)
  local n = 0
  for _, b in ipairs({byte(digest(lp(LABEL.code) .. th), 1, 6)}) do n = n * 256 + b end
  return e2e.format_code(n % 1e12)
end

local function mac16(key, label, th)
  return hmac(key, lp(label) .. th):sub(1, 16)
end

-- The addon's proof of the keys (confirm), and the phone's (done).
function e2e.confirm_mac(ck, th) return mac16(ck, LABEL.confirm, th) end
function e2e.done_mac(ck, th) return mac16(ck, LABEL.done, th) end

-- On a recovery, each side's proof that it holds rk, the recovery key of the
-- key set being replaced: side is 'phone' or 'addon'.
function e2e.recover_mac(rk, side, th) return mac16(rk, LABEL[side], th) end

---------------------------------------------------------------------------
-- Sealing a line, opening a phone send.
---------------------------------------------------------------------------
local KINDS = {tell = 'tell', party = 'party', ls = 'ls', ls1 = 'ls', ls2 = 'ls'}
local MAX_PAYLOAD = 1216        -- a line's or a send's padded payload, at most
local MAX_STORED_PAYLOAD = 1600 -- a stored copy's (the phone's; checked by shape only here)

-- tell, party, or ls for either linkshell slot: a slot move never breaks a line.
function e2e.kind(channel)
  return KINDS[channel]
end

-- ASCII A-Z to a-z, nothing else; a missing name is ''.
function e2e.lower(name)
  if type(name) ~= 'string' then return '' end
  return (name:gsub('[A-Z]', function(c) return char(byte(c) + 32) end))
end
local lower = e2e.lower

-- What a line binds: its key id, kind, direction, sender and target.
function e2e.line_ad(key_id, kind, direction, sender, target)
  return lp(LABEL.line) .. lp(key_id) .. lp(kind) .. lp(direction) .. lp(lower(sender)) .. lp(lower(target))
end

-- What a phone send binds: its key id, client id, kind and target.
function e2e.send_ad(key_id, client_id, kind, target)
  return lp(LABEL.send) .. lp(key_id) .. lp(client_id) .. lp(kind) .. lp(lower(target))
end

-- The relay's text rules for a line, which it cannot apply to an encrypted
-- one: line breaks and tabs become spaces, control characters go, and
-- white space (the relay's, full-width spaces included) is trimmed from
-- both ends. -> the text, or nil when nothing is left.
local SPACE = {['\32'] = true, ['\9'] = true, ['\10'] = true, ['\11'] = true, ['\12'] = true, ['\13'] = true,
               ['\194\160'] = true, ['\225\154\128'] = true, ['\226\128\168'] = true, ['\226\128\169'] = true,
               ['\226\128\175'] = true, ['\226\129\159'] = true, ['\227\128\128'] = true, ['\239\187\191'] = true}
for i = 0x80, 0x8a do SPACE['\226\128' .. char(i)] = true end

function e2e.clean_text(text)
  if type(text) ~= 'string' then return nil end
  text = text:gsub('\r\n', ' '):gsub('[\r\n\t]', ' '):gsub('\226\128[\168\169]', ' ')
  text = text:gsub('[%z\1-\31\127]', ''):gsub('\194[\128-\159]', '')
  local chars = {}
  for ch in text:gmatch('[%z\1-\127\192-\255][\128-\191]*') do chars[#chars + 1] = ch end
  local first, last = 1, #chars
  while first <= last and SPACE[chars[first]] do first = first + 1 end
  while last >= first and SPACE[chars[last]] do last = last - 1 end
  if first > last then return nil end
  return concat(chars, '', first, last)
end

-- A JSON string: only '"' and '\' are escaped, and any control character
-- as \u00xx; '/' and non-ASCII are written as they are.
local function json_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == '\\' then return '\\\\' end
    local b = byte(c)
    if b < 32 then return string.format('\\u%04x', b) end
    return c
  end) .. '"'
end

-- {{key, value}, ...} as a JSON object in that order, with no spaces;
-- numbers are whole numbers.
function e2e.payload_json(fields)
  local parts = {}
  for i, f in ipairs(fields) do
    local v = f[2]
    parts[i] = json_string(f[1]) .. ':' .. (type(v) == 'number' and string.format('%.0f', v) or json_string(v))
  end
  return '{' .. concat(parts, ',') .. '}'
end

-- Spaces up to the next multiple of 32 bytes.
local function pad32(s)
  return s .. (' '):rep((32 - #s % 32) % 32)
end

-- A line's padded payload, {"t","ts","seq"}. A text too long for it is cut,
-- a character (a UTF-8 sequence) at a time from the end, until it fits.
function e2e.line_payload(text, ts, seq)
  local function make(t) return e2e.payload_json{{'t', t}, {'ts', ts}, {'seq', seq}} end
  local whole = make(text)
  if #whole <= MAX_PAYLOAD then return pad32(whole) end
  local budget, used, cut = MAX_PAYLOAD - #make(''), 0, 0
  for ch in text:gmatch('[%z\1-\127\192-\255][\128-\191]*') do
    local n = #json_string(ch) - 2
    if used + n > budget then break end
    used, cut = used + n, cut + #ch
  end
  return pad32(make(text:sub(1, cut)))
end

-- nonce = the first 12 bytes of HMAC-SHA256(nonce_key, ad || payload), so
-- per-line sealing needs no randomness; then ChaCha20-Poly1305.
-- -> nonce, sealed
function e2e.seal_payload(key, nonce_key, ad, payload)
  local nonce = hmac(nonce_key, ad .. payload):sub(1, 12)
  return nonce, e2e.seal(key, nonce, payload, ad)
end

-- keys: {lineKey =, lineNonce =} (raw bytes); meta: {key_id, kind, direction,
-- sender, target}. -> the envelope as JSON text.
function e2e.seal_line(keys, meta, text, ts, seq)
  local ad = e2e.line_ad(meta.key_id, meta.kind, meta.direction, meta.sender, meta.target)
  local nonce, sealed = e2e.seal_payload(keys.lineKey, keys.lineNonce, ad, e2e.line_payload(text, ts, seq))
  return '{"v":1,"k":"' .. meta.key_id .. '","n":"' .. e2e.b64url(nonce) .. '","c":"' .. e2e.b64url(sealed) .. '"}'
end

-- True when t is an envelope of the right shape: v 1, r 1 exactly when it is
-- a stored copy, a key id, a 12-byte nonce, and a ciphertext of 48 bytes or
-- more whose length less the tag is a multiple of 32.
function e2e.parse_envelope(t, stored)
  if type(t) ~= 'table' or t.v ~= 1 then return false end
  if stored then
    if t.r ~= 1 then return false end
  elseif t.r ~= nil then
    return false
  end
  if type(t.k) ~= 'string' or not t.k:find('^[0-9a-f]+$') or #t.k ~= 16 then return false end
  if type(t.n) ~= 'string' or #t.n ~= 16 or not e2e.unb64url(t.n) then return false end
  local c = type(t.c) == 'string' and e2e.unb64url(t.c)
  if not c then return false end
  local max = (stored and MAX_STORED_PAYLOAD or MAX_PAYLOAD) + 16
  return #c >= 48 and #c <= max and (#c - 16) % 32 == 0
end

local json
local function decode(text)
  json = json or dofile(here .. 'json.lua')
  local ok, v = pcall(json.decode, text)
  if ok then return v end
  return nil
end

local function whole_number(v)
  return type(v) == 'number' and v == v and v % 1 == 0 and v > -2 ^ 53 and v < 2 ^ 53
end

-- A phone's sealed send frame, opened with keys {keyId =, sendKey =}:
-- -> {t =, to =, ts =} | nil, 'could not decrypt' (never a guess).
function e2e.open_send(keys, frame)
  local env = frame.e2e
  local kind, client_id = e2e.kind(frame.channel), frame.clientId
  if not (e2e.parse_envelope(env, false) and env.k == keys.keyId and kind and type(client_id) == 'string'
          and #client_id <= 255 and (frame.target == nil or type(frame.target) == 'string')) then
    return nil, 'could not decrypt'
  end
  local ad = e2e.send_ad(keys.keyId, client_id, kind, frame.target)
  local payload = e2e.open(keys.sendKey, e2e.unb64url(env.n), e2e.unb64url(env.c), ad)
  local p = payload and decode(payload)
  if not (type(p) == 'table' and type(p.t) == 'string' and type(p.to) == 'string' and whole_number(p.ts)) then
    return nil, 'could not decrypt'
  end
  return {t = p.t, to = p.to, ts = p.ts}
end

return e2e
