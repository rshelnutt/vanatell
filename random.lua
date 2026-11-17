--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- Randomness for the addon's private keys. Windower's Lua has no system
-- random source, so this pool gathers what only this PC sees: the timing and
-- values of mouse and keyboard input and of the game's own packets, none of
-- which reaches the relay. On Ashita, Windows' generator is asked first
-- (32 bytes from BCryptGenRandom), and the pool only backs it up.
--   The pool is 32 bytes; input is buffered and hashed into it
--   (P = SHA-256(P || input)) at most once a second, at most 1 KB a frame
--   (about 0.5 ms on Lua 5.1 on a fast PC), so a mix of a full buffer spans
--   about 9 frames. A packet adds its id, its first 8 bytes after the header
--   and the clock.
--   Credits: a mouse or keyboard event unlike the one before it earns 1, an
--   incoming packet 1/8, nothing else any; at most one event earns credit
--   per clock value, and none while the clock is below the highest value
--   already credited (a clock set back earns nothing more). Input past 8 KB
--   before a mix is dropped and earns nothing.
--   A key comes out once the pool holds 256 credits and has harvested for 60
--   seconds, or at once from a ready seed or 32 system bytes, and no mix is
--   being hashed (one under way goes on at 1 KB a frame first). Each key is
--   SHA-256(P || "out" || counter), and the pool then moves on
--   (P = SHA-256(P || "next")), so a key cannot be worked out from a later pool.
--   The seed, SHA-256(P || "seed"), is kept in entropy.seed with a ready flag
--   (set once a pool it came from was ready, and kept), written through a
--   temporary file and a rename every 5 minutes while harvesting, after each
--   key and at unload. It is mixed in when harvesting starts, so a later
--   pairing begins with what earlier sessions gathered; only hashes are ever
--   written. Harvesting runs only while the addon has no keys: stop() removes
--   every listener.
local random = {}

local BUFFER_MAX = 8192  -- bytes of input held between mixes
local MIX_EVERY = 1      -- seconds between mixes
local MIX_BUDGET = 1024  -- bytes hashed a frame
local NEEDED = 256       -- credits before a key
local FLOOR = 60         -- seconds of harvesting before a key, without a ready seed
local SEED_EVERY = 300   -- seconds between seed writes while harvesting
local PACKET_CREDIT = 1 / 8

local Pool = {}
Pool.__index = Pool

-- opts: now() -> seconds, events = {register(name, fn) -> id, unregister(id)},
-- system(n) -> n random bytes | nil, seed_path, sha256 (sha256.lua),
-- start_values() -> a string of what is at hand when harvesting starts.
function random.new(opts)
  local sha = opts.sha256
  return setmetatable({
    now = opts.now, events = opts.events, system = opts.system, seed_path = opts.seed_path,
    sha = sha, impl = sha.impl(), start_values = opts.start_values,
    P = ('\0'):rep(32), credits = 0, counter = 0, dropped = 0,
    buf = {}, buf_bytes = 0, buf_credits = 0, mixing = nil,
    started = false, harvesting = false, ids = {}, floor_lifted = false, seed_ready = false,
    elapsed = 0, last_t = nil, last_mix = -math.huge, last_seed_write = nil,
    high = -math.huge, last_key = {},
  }, Pool)
end

function Pool:hash(data)
  return self.sha.digest(data, self.impl)
end

-- One event's bytes into the buffer; credit when it earns some.
function Pool:add(piece, kind, credit)
  local t = self.now()
  if self.buf_bytes + #piece + 24 > BUFFER_MAX then
    self.dropped = self.dropped + 1
    return
  end
  if kind then
    if self.last_key[kind] == piece then credit = 0 end
    self.last_key[kind] = piece
  end
  if credit > 0 and t > self.high then
    self.high = t
    self.buf_credits = self.buf_credits + credit
  end
  local entry = piece .. '@' .. string.format('%.17g', t) .. ';'
  self.buf[#self.buf + 1] = entry
  self.buf_bytes = self.buf_bytes + #entry
end

-- The seed file, or when there is none, the .tmp a failed rename left (put
-- in place if it can be).
local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then
    local tmp = path .. '.tmp'
    f = io.open(tmp, 'rb')
    if f then
      f:close()
      if os.rename(tmp, path) then f = io.open(path, 'rb') else f = io.open(tmp, 'rb') end
    end
  end
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

-- Starts harvesting (at load, or once the keys are deleted): the start
-- values and the seed are mixed in, Windows' generator is asked, and the
-- listeners go on. A second start while harvesting does nothing.
function Pool:start()
  if self.harvesting then return end
  local t = self.now()
  local seed = read_file(self.seed_path) or ''
  local values = ''
  pcall(function() values = tostring(self.start_values()) end)
  self.P = self:hash(self.P .. 'start' .. values .. seed)
  local hex, ready = seed:match('^{"v":1,"seed":"(%x+)","ready":(%a+)}%s*$')
  if hex and #hex == 64 and ready == 'true' then
    self.credits = math.max(self.credits, NEEDED)
    self.floor_lifted, self.seed_ready = true, true
  end
  local ok, bytes = pcall(self.system, 32)
  if ok and type(bytes) == 'string' and #bytes == 32 then
    self.P = self:hash(self.P .. 'system' .. bytes)
    self.credits = math.max(self.credits, NEEDED)
    self.floor_lifted = true
  end
  self.started, self.harvesting = true, true
  self.last_t, self.last_seed_write = t, t
  local ev = self.events
  local function on(name, fn) self.ids[#self.ids + 1] = ev.register(name, fn) end
  on('mouse', function(kind, x, y, delta)
    self:add('m' .. tostring(kind) .. ',' .. tostring(x) .. ',' .. tostring(y) .. ',' .. tostring(delta), 'mouse', 1)
  end)
  on('keyboard', function(key, pressed, flags)
    self:add('k' .. tostring(key) .. ',' .. tostring(pressed) .. ',' .. tostring(flags), 'keyboard', 1)
  end)
  on('incoming chunk', function(id, data)
    self:add('i' .. tostring(id) .. ':' .. (type(data) == 'string' and data:sub(5, 12) or ''), nil, PACKET_CREDIT)
  end)
  on('outgoing chunk', function(id, data)
    self:add('o' .. tostring(id) .. ':' .. (type(data) == 'string' and data:sub(5, 12) or ''), nil, 0)
  end)
end

-- Stops harvesting: every listener goes.
function Pool:stop()
  for _, id in ipairs(self.ids) do pcall(self.events.unregister, id) end
  self.ids, self.harvesting = {}, false
end

function Pool:ready()
  return self.credits >= NEEDED and (self.floor_lifted or self.elapsed >= FLOOR)
end

-- The mix under way, all at once: only at unload.
function Pool:finish_mix()
  local m = self.mixing
  if not m then return end
  m.hasher:step(math.huge)
  self.P, self.credits, self.mixing = m.hasher.raw, self.credits + m.credits, nil
end

-- Every prerender: one bounded step of mixing, and the seed every 5
-- minutes while harvesting.
function Pool:pump(t)
  if self.last_t and t > self.last_t then self.elapsed = self.elapsed + (t - self.last_t) end
  self.last_t = t
  if self.mixing then
    local m = self.mixing
    if m.hasher:step(MIX_BUDGET) then self.P, self.credits, self.mixing = m.hasher.raw, self.credits + m.credits, nil end
  elseif self.buf_bytes > 0 and (t - self.last_mix >= MIX_EVERY or t < self.last_mix) then
    self.mixing = {hasher = self.sha.hasher(self.P .. table.concat(self.buf), self.impl), credits = self.buf_credits}
    self.buf, self.buf_bytes, self.buf_credits, self.last_mix = {}, 0, 0, t
    local m = self.mixing
    if m.hasher:step(MIX_BUDGET) then self.P, self.credits, self.mixing = m.hasher.raw, self.credits + m.credits, nil end
  end
  if self:ready() then self.seed_ready = true end
  if self.harvesting and t - self.last_seed_write >= SEED_EVERY then
    self.last_seed_write = t
    self:write_seed()
  end
end

-- A 32-byte key, or nil while the pool is not ready or a mix is being
-- hashed (pump goes on with it, 1 KB a frame; take again then). The pool
-- moves on and the seed is written again.
function Pool:take()
  if not self:ready() or self.mixing then return nil end
  self.counter = self.counter + 1
  local out = self:hash(self.P .. 'out' .. tostring(self.counter))
  self.P = self:hash(self.P .. 'next')
  self.seed_ready = true
  self:write_seed()
  return out
end

-- Before path.tmp is opened for a write, which empties it: a path.tmp that
-- a failed rename left as the only copy is put in place. -> false while it
-- cannot be (it is then left as it is)
local function tmp_in_place(path, tmp)
  local f = io.open(path, 'rb')
  if f then
    f:close()
    return true
  end
  f = io.open(tmp, 'rb')
  if not f then return true end
  f:close()
  return os.rename(tmp, path) and true or false
end

-- entropy.seed, through entropy.seed.tmp and a rename. A failed write leaves
-- the seed as it was; a failed rename leaves entropy.seed.tmp, which the
-- next start reads and the next write puts in place first (while it cannot,
-- nothing is written, so that copy is never emptied).
function Pool:write_seed()
  local seed = self:hash(self.P .. 'seed'):gsub('.', function(c) return string.format('%02x', c:byte()) end)
  local text = '{"v":1,"seed":"' .. seed .. '","ready":' .. tostring(self.seed_ready) .. '}'
  local tmp = self.seed_path .. '.tmp'
  if not tmp_in_place(self.seed_path, tmp) then return end
  local f = io.open(tmp, 'wb')
  if not f then return end
  local ok = f:write(text)
  f:close()
  if not ok then
    os.remove(tmp)
    return
  end
  os.remove(self.seed_path) -- Windows will not rename onto an existing file
  os.rename(tmp, self.seed_path)
end

-- At unload: the seed, if this load's pool ever started (one that never did
-- holds nothing worth keeping, and must not replace a good seed).
function Pool:on_unload()
  if not self.started then return end
  self:finish_mix()
  if self:ready() then self.seed_ready = true end
  self:write_seed()
end

return random
