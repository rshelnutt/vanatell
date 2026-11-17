--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- Randomness for the addon's private keys. Windower's Lua has no system
-- random source, so this pool gathers what only this PC sees: the timing of
-- its own frames against the clock, and the timing and values of mouse and
-- keyboard input and of the game's own packets, none of which reaches the
-- relay. On Ashita, Windows' generator is asked first (32 bytes from
-- BCryptGenRandom), and the pool only backs it up.
--   The pool is 32 bytes; input is buffered and hashed into it
--   (P = SHA-256(P || input)) once a second, and while the pool has fewer
--   than 256 credits also whenever the buffer holds 1 KB or brings the pool
--   to 256, at most 256 bytes a frame (about 0.12 ms on Lua 5.1 on a fast
--   PC). A packet adds its id, its first 8 bytes after the header and the
--   clock.
--   Frame timing: while the pool gathers and has fewer than 256 credits,
--   each prerender spins reading the finest clock it found at start
--   (os.clock or socket.gettime, read in whole milliseconds when it is finer
--   than that; none coarser than 20 ms) until it steps, counting the reads:
--   the count says where in the clock step the frame began, which nothing
--   off this PC can see. Then it spins once more until the next step: that
--   count is how fast the PC ran the loop just then. At most 1.8 ms of
--   spinning a prerender, by the count of reads one clock step took. A key
--   is not taken in a prerender that spun.
--   Credits: each count earns 4 (about half its measured min-entropy), only
--   when it differs from the one before it and the clock stepped forward; a
--   mouse or keyboard event unlike the one before it earns 1, an incoming packet
--   1/8, nothing else any. Input and packets earn at most 2 credits a
--   prerender, and none while the clock is below the highest value already
--   credited (a clock set back earns nothing more). Input past 8 KB before
--   a mix is dropped and earns nothing.
--   A key comes out once the pool holds 256 credits and has harvested for 1
--   second, or at once from a ready seed or 32 system bytes, and no mix is
--   being hashed (one under way goes on at 256 bytes a frame first). Each
--   key is SHA-256(P || "out" || counter), and the pool then moves on
--   (P = SHA-256(P || "next")), so a key cannot be worked out from a later pool.
--   The seed, SHA-256(P || "seed"), is kept in entropy.seed with a ready flag
--   (set once a pool it came from was ready, and kept) and the credits and
--   seconds gathered so far, written through a temporary file and a rename
--   two prerenders after the pool turns ready (when no key was taken in
--   between), every 5 minutes while harvesting, after
--   each key and at unload. It is mixed in when harvesting starts, so a later
--   pairing begins with what earlier sessions gathered, and a reload goes on
--   from the credits and seconds it holds; only hashes are ever written.
--   Harvesting runs only while the addon has no keys: stop() removes every
--   listener and the spinning stops.
local random = {}

local BUFFER_MAX = 8192  -- bytes of input held between mixes
local MIX_EVERY = 1      -- seconds between mixes
local MIX_BUDGET = 256   -- bytes hashed a frame
local MIX_AT = 1024      -- bytes in the buffer that start a mix while the pool gathers
local NEEDED = 256       -- credits before a key
local FLOOR = 1          -- seconds of harvesting before a key, without a ready seed
local SEED_EVERY = 300   -- seconds between seed writes while harvesting
local PACKET_CREDIT = 1 / 8
local INPUT_CAP = 2      -- credits from input and packets a prerender
local SPIN = 0.0018      -- seconds of spinning on the clock a prerender
local PHASE_CREDIT = 4   -- a frame's start within the clock step
local STEP_CREDIT = 4    -- the reads one whole clock step took
local FINE = 0.0005      -- a clock that steps finer than this is read in whole milliseconds
local COARSE = 0.02      -- a clock that steps coarser than this is not spun on
local floor, min, max = math.floor, math.min, math.max

local Pool = {}
Pool.__index = Pool

-- opts: now() -> seconds, events = {register(name, fn) -> id, unregister(id)},
-- system(n) -> n random bytes | nil, seed_path, sha256 (sha256.lua),
-- start_values() -> a string of what is at hand when harvesting starts,
-- clocks = {clock() -> seconds, ...}, the clocks the spin may read, the
-- one to prefer first.
function random.new(opts)
  local sha = opts.sha256
  return setmetatable({
    now = opts.now, events = opts.events, system = opts.system, seed_path = opts.seed_path, clocks = opts.clocks or {},
    sha = sha, impl = sha.impl(), start_values = opts.start_values,
    P = ('\0'):rep(32), credits = 0, counter = 0, dropped = 0,
    buf = {}, buf_bytes = 0, buf_credits = 0, mixing = nil,
    started = false, harvesting = false, ids = {}, floor_lifted = false, seed_ready = false,
    elapsed = 0, last_t = nil, last_mix = -math.huge, last_seed_write = nil,
    high = -math.huge, last_key = {}, frame_credits = 0, spinner = nil, ready_written = false, spun = false,
    ready_pumps = 0,
  }, Pool)
end

function Pool:hash(data)
  return self.sha.digest(data, self.impl)
end

-- One piece into the buffer, with its credit; false when the buffer is full.
function Pool:put(piece, credit, t)
  if self.buf_bytes + #piece + 24 > BUFFER_MAX then
    self.dropped = self.dropped + 1
    return false
  end
  self.buf_credits = self.buf_credits + credit
  local entry = piece .. '@' .. string.format('%.17g', t) .. ';'
  self.buf[#self.buf + 1] = entry
  self.buf_bytes = self.buf_bytes + #entry
  return true
end

-- One input event's bytes into the buffer; credit when it earns some, at
-- most INPUT_CAP a prerender.
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
  if credit > 0 then
    if t < self.high or self.frame_credits >= INPUT_CAP then
      credit = 0
    else
      credit = min(credit, INPUT_CAP - self.frame_credits)
      self.high, self.frame_credits = t, self.frame_credits + credit
    end
  end
  self:put(piece, credit, t)
end

-- Reads clock() until its value changes, at most limit times, from t0.
-- -> the reads, and the new value (nil when it did not change)
local function spin(clock, limit, t0)
  local n = 0
  while n < limit do
    n = n + 1
    local t = clock()
    if t ~= t0 then return n, t end
  end
  return n, nil
end

-- One step of the clock, at most cap reads to each change.
-- -> its length in seconds and the reads it took, or nil
local function measure(clock, cap)
  local _, t1 = spin(clock, cap, clock())
  if not t1 then return nil end
  local n, t2 = spin(clock, cap, t1)
  if not t2 or t2 <= t1 then return nil end
  return t2 - t1, n
end

-- The clock to spin on: the first of the clocks whose step is at most 2 ms
-- (one finer than FINE read in whole milliseconds), else the finest no
-- coarser than COARSE, else none. Each clock after the first is given at
-- most 2.5 ms of reads, by the first one's speed.
function Pool:find_clock()
  local best, cap = nil, 1000000
  for _, c in ipairs(self.clocks) do
    local step, n = measure(c, cap)
    if step and step < FINE then
      local fine = c
      c = function() return floor(fine() * 1000) * 0.001 end
      step, n = measure(c, cap)
    end
    if step and step <= COARSE and (not best or step < best.step) then
      best = {clock = c, step = step, limit = max(16, floor(n * SPIN / step))}
    end
    if best and best.step <= SPIN then break end
    if step and n then cap = max(16, floor(n * 0.0025 / step)) end
  end
  return best
end

-- This prerender's spin: where the frame began within the clock step,
-- then one whole step, at most SPIN seconds of reads in all.
function Pool:spin_once()
  local s = self.spinner
  local clock, t = s.clock, self.now()
  local t0 = clock()
  local n, t1 = spin(clock, s.limit, t0)
  if not t1 then return end
  self:put('j' .. n .. ',' .. string.format('%.17g', t1), (n ~= s.phase and t1 > t0) and PHASE_CREDIT or 0, t)
  s.phase = n
  local m, t2 = spin(clock, s.limit - n, t1)
  if not t2 then return end
  self:put('J' .. m .. ',' .. string.format('%.17g', t2), (m ~= s.whole and t2 > t1) and STEP_CREDIT or 0, t)
  s.whole = m
  s.limit = max(16, floor(m * SPIN / s.step)) -- the loop's speed just now
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
  local hex, ready, rest = seed:match('^{"v":1,"seed":"(%x+)","ready":(%a+)(.-)}%s*$')
  if hex and #hex == 64 and ready == 'true' then
    self.credits = max(self.credits, NEEDED)
    self.floor_lifted, self.seed_ready, self.ready_written = true, true, true
  elseif hex and #hex == 64 and ready == 'false' and rest then
    -- What an earlier load gathered goes on counting.
    local credits, elapsed = rest:match('^,"credits":(%d+%.?%d*),"elapsed":(%d+%.?%d*)$')
    credits, elapsed = tonumber(credits), tonumber(elapsed)
    if credits and elapsed then
      self.credits = max(self.credits, min(credits, NEEDED))
      self.elapsed = max(self.elapsed, min(elapsed, FLOOR))
    end
  end
  local ok, bytes = pcall(self.system, 32)
  if ok and type(bytes) == 'string' and #bytes == 32 then
    self.P = self:hash(self.P .. 'system' .. bytes)
    self.credits = math.max(self.credits, NEEDED)
    self.floor_lifted = true
  end
  self.started, self.harvesting = true, true
  self.last_t, self.last_seed_write = t, t
  if not self:ready() and not self.spinner then self.spinner = self:find_clock() end
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

-- Credits in the pool, the mix under way and the buffer.
function Pool:gathered()
  return self.credits + self.buf_credits + (self.mixing and self.mixing.credits or 0)
end

-- Every prerender: the seed two prerenders after the pool turned ready
-- (unless a key, which writes it, came first), the spin while the pool
-- gathers, one bounded step of mixing, and the seed every 5 minutes while
-- harvesting.
function Pool:pump(t)
  if self.last_t and t > self.last_t then self.elapsed = self.elapsed + (t - self.last_t) end
  self.last_t = t
  self.frame_credits, self.spun = 0, false
  if self.ready_pumps >= 2 and not self.ready_written and self.harvesting then
    self.ready_written, self.seed_ready, self.last_seed_write = true, true, t
    self:write_seed()
  end
  if self.harvesting and self.spinner and self:gathered() < NEEDED then
    self.spun = true
    self:spin_once()
  end
  if self.mixing then
    local m = self.mixing
    if m.hasher:step(MIX_BUDGET) then self.P, self.credits, self.mixing = m.hasher.raw, self.credits + m.credits, nil end
  elseif self.buf_bytes > 0 and (t - self.last_mix >= MIX_EVERY or t < self.last_mix
                                 or (self.credits < NEEDED and (self.buf_bytes >= MIX_AT
                                                                or self.credits + self.buf_credits >= NEEDED))) then
    self.mixing = {hasher = self.sha.hasher(self.P .. table.concat(self.buf), self.impl), credits = self.buf_credits}
    self.buf, self.buf_bytes, self.buf_credits, self.last_mix = {}, 0, 0, t
    local m = self.mixing
    if m.hasher:step(MIX_BUDGET) then self.P, self.credits, self.mixing = m.hasher.raw, self.credits + m.credits, nil end
  end
  if self:ready() then
    self.seed_ready, self.ready_pumps = true, self.ready_pumps + 1
  end
  if self.harvesting and t - self.last_seed_write >= SEED_EVERY then
    self.last_seed_write = t
    self:write_seed()
  end
end

-- A 32-byte key, or nil while the pool is not ready, a mix is being hashed
-- (pump goes on with it, 256 bytes a frame; take again then) or the pool
-- spun this prerender (take again in the next). The pool moves on and the
-- seed is written again.
function Pool:take()
  if not self:ready() or self.mixing or self.spun then return nil end
  self.counter = self.counter + 1
  local out = self:hash(self.P .. 'out' .. tostring(self.counter))
  self.P = self:hash(self.P .. 'next')
  self.seed_ready, self.ready_written = true, true
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
  local text = '{"v":1,"seed":"' .. seed .. '","ready":' .. tostring(self.seed_ready)
    .. string.format(',"credits":%.3f,"elapsed":%.3f}', floor(min(self.credits, NEEDED) * 8) / 8,
                     floor(min(self.elapsed, FLOOR) * 1000) / 1000)
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
-- holds nothing worth keeping, and must not replace a good seed), with the
-- buffer mixed in, so the next load goes on from every credit gathered.
function Pool:on_unload()
  if not self.started then return end
  self:finish_mix()
  if self.buf_bytes > 0 then
    self.P, self.credits = self:hash(self.P .. table.concat(self.buf)), self.credits + self.buf_credits
    self.buf, self.buf_bytes, self.buf_credits = {}, 0, 0
  end
  if self:ready() then self.seed_ready = true end
  self:write_seed()
end

return random
