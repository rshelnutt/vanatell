--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- vanatell: relays FFXI tells, party and linkshell chat to a phone through the relay.
-- This file holds the Windower events, the //vt commands (pairing among
-- them), the settings, the connection lifecycle (connect, ping, idle timeout
-- and reconnect with backoff), chat capture with its offline queue, the
-- phone's send frames, the linkshells frame (which shell is equipped in
-- slots 1 and 2, asked of the game with /lsmes and /ls2mes when it has not
-- said), and the update check and //vt update (update.lua). All network work
-- is pumped from prerender and never blocks.
_addon.name = 'vanatell'
_addon.command = 'vt'
_addon.version = '0.3.9'

local config = require('config')

-- Tests set __vanatell_test to swap in modules and a clock. Sibling files load
-- with dofile, because Windower ships its own json and chat libraries.
local hooks = rawget(_G, '__vanatell_test') or {}
local function load_local(name) return hooks[name] or dofile(windower.addon_path .. name .. '.lua') end
local json, chat, ws = load_local('json'), load_local('chat'), load_local('ws')
local linkshells, update = load_local('linkshells'), load_local('update')
local e2e, random, sha256 = load_local('e2e'), load_local('random'), load_local('sha256')
local now = hooks.now or require('socket').gettime

local BACKOFF_MIN = 1      -- seconds before the first retry
local BACKOFF_MAX = 60     -- longest wait between retries
local STABLE_AFTER = 10    -- a connection open this long resets the backoff
local QUIET_DROP = 10      -- seconds a lost connection may take to come back before the game log says so
local PING_INTERVAL = 30   -- seconds between keepalive pings
local IDLE_TIMEOUT = 90    -- silence from the relay this long means the link is dead
local AUTO_UPDATE_GAP = 600 -- seconds between two updates started by the relay's refusal (close 4004)
local MAX_FRAMES = 20      -- frames decoded per prerender
local OPENS_MAX = 1        -- sealed sends opened per prerender; a burst (the relay's outbox after a reconnect) waits in the socket for the next frames

local QUEUE_MAX = 500         -- chat frames held while disconnected
local ECHO_WINDOW = 30        -- seconds a phone send waits for the game's copy of it (the relay's window)
local SEAL_BUDGET = 0.002     -- seconds of sealing a prerender, past the first line
local EXECUTED_IDS_MAX = 200  -- send ids remembered, so a replayed id runs once
local RELAY_MESSAGE_MAX = 120 -- characters of a relay error message shown in game
local ACCOUNT_ID_MAX = 64     -- longest accountId accepted from the relay

local LS_PERIOD = 60      -- seconds between linkshell reads
local LS_GAP = 2          -- shortest time between two linkshells frames
local LS_EQUIP_SETTLE = 1 -- wait after a linkshell equip packet before reading
local LS_ZONE_SETTLE = 5  -- wait after zone-in or login, while the inventory loads
local LS_INVENTORY_SETTLE = 0.5 -- wait after the inventory finished loading (0x01D)
-- After login or zone-in the game can show a shell in the wrong slot for a
-- while, as its items load over time. For LS_WATCH seconds the linkshells are
-- read every LS_RECHECK, and a read counts only once it has stayed the same
-- for LS_SETTLE; until then the last settled one stands.
local LS_WATCH = 120
local LS_RECHECK = 2
local LS_SETTLE = 10
-- The game gives no slot number for an equipped shell except in a 0x0E0
-- packet (on equipping, and for both slots on zone-in) and in the reply to
-- /lsmes (slot 1) and /ls2mes (slot 2), which names the linkshell in that
-- slot. A linkshell line is only ever named by what the game said: until it
-- has, the addon asks with those commands, and keeps their replies out of
-- the chat log.
local LS_LOOKUP_HOLD = 1.5  -- seconds linkshell lines wait for the first reply
local LS_LOOKUP_WAIT = 5    -- seconds a command's reply is waited for before the next command
local LS_HELD_MAX = 200     -- linkshell lines held while they wait
local LS_LOOKUP = {'input /lsmes', 'input /ls2mes'}

local PING = '{"type":"ping"}'
local CA_FILE = windower.addon_path .. 'relay-roots.txt'
-- The folder of the settings: data/ on Windower, config/addons/vanatell/ on Ashita.
local DATA_DIR = rawget(windower, 'data_dir') or (windower.addon_path .. 'data/')
local QUEUE_FILE = DATA_DIR .. 'queue.json' -- the queue, only across an update's or a rollback's reload
local QUEUE_SINCE = '0.3.9' -- the first version that reads queue.json back
-- This pairing's encryption keys, and the exchange in progress (the key file).
local KEY_FILE = DATA_DIR .. 'e2e.json'
-- What the newest version is and which files it holds (update.lua).
local UPDATE_URL = 'https://vanatell.com/addon/latest.json'

-- Saved with 'all': the default per-character save does nothing while the
-- player is not logged in.
-- Every install talks to the one VanaTell relay; it cannot be changed. A relay address saved by an older version is
-- dropped. (Tests put a stand-in relay in __vanatell_test.)
local RELAY_URL = hooks.relay_url or 'wss://relay.vanatell.com'
-- recover_key and recover_key_id: the recovery key of this pairing's keys
-- and their key id, kept beside the token so a lost key file is recovered
-- by itself. e2e_account: the account this PC knows has switched to
-- encryption (rollbacks below encryption are refused for it).
local settings = config.load({token = '', account_id = '', enabled = true, ls_slots = '', recover_key = '',
                              recover_key_id = '', e2e_account = ''})
for _, key in ipairs({'ls_slots', 'recover_key', 'recover_key_id', 'e2e_account'}) do
  if type(settings[key]) ~= 'string' then settings[key] = '' end
end
settings.url = nil

-- state: unpaired | disabled | waiting | connecting | open | unauthorized | stopped
local app = {
  state = 'unpaired',
  client = nil,        -- the live ws client; callbacks from any other are ignored
  backoff = BACKOFF_MIN,
  next_attempt = 0,    -- when waiting: the time of the next connect
  queue = {},          -- encoded chat frames held while disconnected
  sealing = {},        -- lines captured with keys, waiting for the next prerender to seal them
  opened = 0,          -- sealed sends opened this prerender
  queue_full = false,  -- the queue full line was logged since the last flush
  executed = {},       -- send id -> true, for the ids in executed_order
  executed_order = {}, -- the last EXECUTED_IDS_MAX executed send ids, oldest first
  echoes = {},         -- phone sends whose game copy is not mirrored back
  pairing = nil,       -- the pairing request in flight
  settings = settings,
  last_error = nil,    -- why the last connection ended
  outage = false,      -- a connection was lost and none has opened since
  outage_since = nil,  -- when the outage began
  outage_said = false, -- the connection lost line was logged for this outage
  announced = false,   -- connected to relay was logged since the last deliberate start
  e2e = {              -- encryption (e2e.lua), from the key file
    keys = nil,        -- this pairing's keys once an exchange completed
    kx = nil,          -- the exchange in progress: {kxId =, id =, h =, recover =, a =}
    sent = {},         -- opened phone sends, typed or refused: {clientId =, id =, typedAt =, ts =, error =}
    job = nil,         -- the X25519 job in prerender: {stage = 'A' | 's', kx =, data =, job =}
    reveal = nil,      -- a reveal waiting for A to be worked out again after a reload
    completed = 0,     -- reveals that matched their commit, this load
    waited = {},       -- kxId -> true: answered with wait
    seq = 0,           -- lines sealed since load
  },
  auto_update_at = nil, -- when the relay's refusal last started an update
  forced_said = false, -- the refusal's updating line was logged since load
  no_bit_said = false, -- the refusal's no bit library line was logged since load
  no_newer_said = false, -- the refusal's no newer version line was logged since load
  opened_at = nil, last_rx = nil, last_ping = nil,
  ls = {               -- linkshell detection
    equips = {},       -- 'bag:slot' -> 1 or 2, from 0x0E0 packets, /lsmes replies and the saved settings
    said = {},         -- slot number -> true: the game said since load or login what is in it
    known = false,     -- the game said which slot current's shells are in
    found = nil,       -- the equipped shells current was read from (linkshells.equipped)
    lookup = nil,      -- the /lsmes lookup in flight: {slot =, hold_until =, deadline =, found =, sig =}
    looked = nil,      -- what was equipped at the last lookup that got no answer
    swallow_until = 0, -- a linkshell message arriving before this time answers a command of ours: kept out of the log
    held = {},         -- linkshell lines waiting for the lookup's first reply
    held_sends = {},   -- the phone's linkshell sends waiting for the lookup to end
    unnamed_from = nil, -- ms time of the first linkshell line sent with no name while the slots were not known
    refile = nil,      -- ms time the next linkshells frame tells the relay to name lines from
    current = nil,     -- the last settled read, {ls1 =, ls2 =}; nil until one is
    seen = nil,        -- {state =, since =}: the last read, and when it was first read so
    watch_until = 0,   -- reads settle (LS_SETTLE) until this time, after login or zone-in
    sent = nil,        -- what the last linkshells frame on this socket said
    sent_at = nil,     -- when it went
    pending = nil,     -- a change waiting for LS_GAP to pass
    due = {},          -- event kind -> when the read it asked for happens
    next_read = 0,     -- when the periodic read happens
  },
}
hooks.app = app

---------------------------------------------------------------------------
-- Settings and log.
---------------------------------------------------------------------------
local function is_set(v)
  return type(v) == 'string' and v ~= ''
end

-- The relay's token: 22 base64url characters, a dot, then 43 more. It goes
-- into the Authorization header line, so it is checked before it is saved
-- and again when it is read back; the pattern admits no CR or LF.
local function is_token(v)
  if type(v) ~= 'string' then return false end
  local id, secret = v:match('^([A-Za-z0-9_%-]+)%.([A-Za-z0-9_%-]+)$')
  return id ~= nil and #id == 22 and #secret == 43
end

local function is_account_id(v)
  return is_set(v) and #v <= ACCOUNT_ID_MAX and not v:find('[\r\n]')
end

-- A stored token that is not in the relay's format (a hand-edited settings
-- file, say) counts as no token.
local function has_credentials()
  return is_token(settings.token)
end

local function is_enabled()
  return settings.enabled == true
end

local function save()
  config.save(settings, 'all')
end

-- The game's chat log is Shift-JIS, so anything outside printable ASCII
-- (an error from the network, say) is shown as '?'.
local function log(line)
  windower.add_to_chat(207, 'VanaTell: ' .. (line:gsub('[^ -~]', '?')))
end
ws.log = log -- ws.lua's one-time notices, such as a TLS options fallback

-- Windower's console window (print), or what the Ashita stand-in gives as
-- windower.console.
local console = rawget(windower, 'console') or print

-- The update check on load, //vt update and //vt rollback. Settings are
-- never among the files it writes.
local updater = update.new{
  ws = ws,
  json = json,
  version = _addon.version,
  platform = rawget(windower, 'platform') == 'ashita' and 'ashita' or 'windower',
  addon_path = windower.addon_path,
  manifest_url = (hooks.update_url == nil) and UPDATE_URL or hooks.update_url,
  cafile = CA_FILE,
  command = '//' .. _addon.command,
  log = log,
  chat = function(text) windower.add_to_chat(207, (text:gsub('[^ -~]', '?'))) end,
  console = console,
  reload = function() windower.send_command('lua reload ' .. _addon.name) end,
  fs = {dir_exists = windower.dir_exists, create_dir = windower.create_dir},
  sha256 = hooks.sha256,
  budget = hooks.hash_budget,
  -- Keys held, or the relay said so (e2e_account): no rollback below encryption.
  switched = function()
    return app.e2e.keys ~= nil or (is_set(settings.e2e_account) and settings.e2e_account == settings.account_id)
  end,
}
hooks.updater = updater

local NOT_PAIRED = 'not paired: run //vt pair <code> with the code from the VanaTell app'
local REJECTED = 'relay rejected the addon token; pair again with //vt pair <code>'
local ACCOUNT_DELETED = 'account deleted on the phone; set up the app again, then //vt pair <code>'

---------------------------------------------------------------------------
-- Chat: frames for the relay, the offline queue and the phone's sends.
---------------------------------------------------------------------------
local NULL = {} -- encode_fields writes it as null

-- {{key, value}, ...} -> a JSON object with its keys in the order given.
-- NULL is written as null; a nil value leaves its key out.
local function encode_fields(fields)
  local parts = {}
  for _, field in ipairs(fields) do
    local key, value = field[1], field[2]
    if value == NULL then
      parts[#parts + 1] = json.encode(key) .. ':null'
    elseif value ~= nil then
      parts[#parts + 1] = json.encode(key) .. ':' .. json.encode(value)
    end
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

---------------------------------------------------------------------------
-- The key file: data/e2e.json (Ashita: config/addons/vanatell/e2e.json).
---------------------------------------------------------------------------
-- It holds the account it belongs to, this pairing's keys once an exchange
-- has completed, the exchange in progress (so a reload or a closed game
-- loses nothing) and the phone sends opened in the last 12 hours, with the
-- error of each one that was refused after it was opened. It is
-- written through e2e.json.tmp and a rename. A file that does not parse, is
-- malformed, or names another account counts as no file. Only a successful
-- //vt pair and //vt unpair delete it.
local function bytes_of(v, n)
  local raw = type(v) == 'string' and e2e.unb64url(v)
  if raw and #raw == n then return raw end
  return nil
end

local function is_key_id(v)
  return type(v) == 'string' and #v == 16 and v:find('^[0-9a-f]+$') ~= nil
end

local KEY_BYTES = {'lineKey', 'lineNonce', 'sendKey', 'recoverKey', 'A', 'B'}

-- The file's keys -> in memory: the 32-byte keys raw, the rest as written.
local function parse_keys(k)
  if type(k) ~= 'table' or not is_key_id(k.keyId) or type(k.acked) ~= 'boolean'
     or type(k.code) ~= 'string' or not k.code:find('^%d%d%d%d %d%d%d%d %d%d%d%d$') then
    return nil
  end
  local keys = {keyId = k.keyId, code = k.code, kxId = k.kxId, mac = k.mac, rmac = k.rmac, doneMac = k.doneMac, acked = k.acked}
  for _, name in ipairs(KEY_BYTES) do
    keys[name] = bytes_of(k[name], 32)
    if not keys[name] then return nil end
  end
  if not (bytes_of(k.kxId, 16) and bytes_of(k.mac, 16)) then return nil end
  if k.rmac ~= nil and not bytes_of(k.rmac, 16) then return nil end
  if k.doneMac ~= nil and not bytes_of(k.doneMac, 16) then return nil end
  return keys
end

local function parse_kx(x)
  if type(x) ~= 'table' then return nil end
  local kx = {kxId = x.kxId, id = bytes_of(x.kxId, 16), h = bytes_of(x.h, 32), recover = x.recover}
  if not (kx.id and kx.h) or (x.recover ~= nil and not is_key_id(x.recover)) then return nil end
  if x.a ~= nil then
    kx.a = bytes_of(x.a, 32)
    if not kx.a then return nil end
  end
  return kx
end

local function is_time(v)
  return type(v) == 'number' and v == v and v >= 0 and v < 2 ^ 53 and v % 1 == 0
end

local function parse_sent(list)
  if list == nil then return {} end
  if type(list) ~= 'table' then return nil end
  local sent = {}
  for i, r in ipairs(list) do
    if not (type(r) == 'table' and type(r.clientId) == 'string' and is_time(r.id) and r.id >= 1
            and is_time(r.typedAt) and is_time(r.ts) and (r.error == nil or type(r.error) == 'string')) then
      return nil
    end
    sent[i] = {clientId = r.clientId, id = r.id, typedAt = r.typedAt, ts = r.ts, error = r.error}
  end
  return sent
end

-- Writes text to path through path.tmp and a rename (Windows will not
-- rename onto an existing file, so path goes first). A failed write leaves
-- path as it was; a failed rename leaves path.tmp, which read_written takes.
local function write_through(path, text)
  local tmp = path .. '.tmp'
  local f = io.open(tmp, 'wb')
  if not f then return end
  local ok = f:write(text)
  f:close()
  if not ok then
    os.remove(tmp)
    return
  end
  os.remove(path)
  os.rename(tmp, path)
end

-- A file written by write_through: path, or when there is none, the
-- path.tmp a failed rename left, put in place if it can be. -> its text | nil
local function read_written(path)
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
  local text = f:read('*a')
  f:close()
  return text
end

-- -> {keys =, kx =, sent =} | nil (no file, or one that counts as none)
local function read_keyfile()
  if not is_account_id(settings.account_id) then return nil end
  local text = read_written(KEY_FILE)
  if not text then return nil end
  local ok, t = pcall(json.decode, text)
  if not (ok and type(t) == 'table' and t.v == 1 and t.account == settings.account_id) then return nil end
  local file = {sent = parse_sent(t.sent)}
  if not file.sent then return nil end
  if t.keys ~= nil then
    file.keys = parse_keys(t.keys)
    if not file.keys then return nil end
  end
  if t.kx ~= nil then
    file.kx = parse_kx(t.kx)
    if not file.kx then return nil end
  end
  return file
end

local function ensure_data_dir()
  if not windower.dir_exists(DATA_DIR) then pcall(windower.create_dir, DATA_DIR) end
end

-- What app.e2e holds, as the key file: keys in a fixed order.
local function write_keyfile()
  local s = app.e2e
  local keys, kx, sent = NULL, NULL, {}
  if s.keys then
    local k = s.keys
    keys = encode_fields{{'keyId', k.keyId}, {'code', k.code}, {'lineKey', e2e.b64url(k.lineKey)},
      {'lineNonce', e2e.b64url(k.lineNonce)}, {'sendKey', e2e.b64url(k.sendKey)}, {'recoverKey', e2e.b64url(k.recoverKey)},
      {'A', e2e.b64url(k.A)}, {'B', e2e.b64url(k.B)}, {'kxId', k.kxId}, {'mac', k.mac}, {'rmac', k.rmac or NULL},
      {'acked', k.acked}, {'doneMac', k.doneMac}}
  end
  if s.kx then
    local x = s.kx
    kx = encode_fields{{'kxId', x.kxId}, {'h', e2e.b64url(x.h)}, {'recover', x.recover or NULL},
                       {'a', x.a and e2e.b64url(x.a) or NULL}}
  end
  for i, r in ipairs(s.sent) do
    sent[i] = encode_fields{{'clientId', r.clientId}, {'id', r.id}, {'typedAt', r.typedAt}, {'ts', r.ts}, {'error', r.error}}
  end
  local text = '{"v":1,"account":' .. json.encode(settings.account_id) .. ',"keys":' .. (keys == NULL and 'null' or keys)
    .. ',"kx":' .. (kx == NULL and 'null' or kx) .. ',"sent":[' .. table.concat(sent, ',') .. ']}'
  ensure_data_dir()
  write_through(KEY_FILE, text)
end

-- Load: the key file into app.e2e; its recovery key and key id go into the
-- settings when they differ there (a crash between the two writes).
local function load_keys()
  local file = read_keyfile() or {sent = {}}
  local s = app.e2e
  s.keys, s.kx, s.sent = file.keys, file.kx, file.sent
  local k = s.keys
  if k then
    local recover_key = e2e.b64url(k.recoverKey)
    if settings.recover_key ~= recover_key or settings.recover_key_id ~= k.keyId then
      settings.recover_key, settings.recover_key_id = recover_key, k.keyId
      save()
    end
  end
end

-- What is at hand when harvesting starts, for the pool: times, a table
-- address, the memory in use, and where the player is.
local function start_values()
  local parts = {tostring(os.time()), string.format('%.17g', now()), tostring(os.clock()), tostring({}),
                 tostring(collectgarbage('count'))}
  pcall(function()
    local player = windower.ffxi.get_player()
    if player then parts[#parts + 1] = tostring(player.status) .. ',' .. tostring(player.index) end
    local me = windower.ffxi.get_mob_by_target and windower.ffxi.get_mob_by_target('me')
    if me then parts[#parts + 1] = string.format('%.17g,%.17g,%.17g', me.x or 0, me.y or 0, me.z or 0) end
  end)
  return table.concat(parts, ';')
end

-- The entropy pool the private keys come from (random.lua), when this Lua
-- can encrypt at all. It listens to input and packets only while the addon
-- has no keys.
local pool
if e2e.available() then
  pool = random.new{
    now = now,
    events = {register = windower.register_event, unregister = windower.unregister_event},
    system = rawget(windower, 'system_random'),
    seed_path = DATA_DIR .. 'entropy.seed',
    sha256 = sha256,
    start_values = start_values,
  }
end

local function harvest()
  if pool and not app.e2e.keys then
    ensure_data_dir()
    pool:start()
  end
end

-- A new pairing or //vt unpair: the key file and the recovery key go, and
-- so does any exchange in progress; harvesting starts again.
local function delete_keys()
  local s = app.e2e
  s.keys, s.kx, s.sent, s.job, s.reveal = nil, nil, {}, nil, nil
  app.sealing = {} -- captured under keys that are gone
  os.remove(KEY_FILE)
  os.remove(KEY_FILE .. '.tmp')
  settings.recover_key, settings.recover_key_id = '', ''
  save()
  harvest()
end

---------------------------------------------------------------------------
-- The key exchange with the phone, through the relay (kx frames).
---------------------------------------------------------------------------
-- The phone commits to its key (commit), the addon answers with its own
-- (key; wait while its randomness is not ready), the phone reveals its key
-- (reveal), and the addon checks it against the commitment, works out the
-- keys and proves it holds them (confirm), which it sends again on every
-- connect until the phone proves it too (done). A commit names the recovery
-- key's key id when the addon lost its key file but kept its recovery key;
-- both sides then prove that key. Each scalar multiplication runs as a job a
-- few ladder steps per prerender. While the addon holds keys it takes no
-- commit (already set up): only //vt pair and //vt unpair remove them.
local MAX_EXCHANGES = 10 -- reveals that matched their commit, per load

local function send_kx(fields)
  if app.state ~= 'open' or not app.client then return end
  local all = {{'type', 'kx'}}
  for _, f in ipairs(fields) do all[#all + 1] = f end
  app.client:send_text(encode_fields(all))
end

local function abort(id, reason, key)
  send_kx{{'step', 'abort'}, {'id', id}, {'reason', reason}, {'key', key}}
end

local function send_key(kx)
  send_kx{{'step', 'key'}, {'id', kx.kxId}, {'a', e2e.b64url(kx.A)}}
end

local function send_confirm()
  local k = app.e2e.keys
  send_kx{{'step', 'confirm'}, {'id', k.kxId}, {'key', k.keyId}, {'mac', k.mac}, {'rmac', k.rmac}}
end

local function has_recovery_key()
  return is_key_id(settings.recover_key_id) and bytes_of(settings.recover_key, 32) ~= nil
end

-- stage 'A': a·G, the addon's public key; stage 's': a·B, the shared secret.
local function start_job(stage, kx, data)
  app.e2e.job = {stage = stage, kx = kx, data = data, job = e2e.x25519_job(kx.a, stage == 'A' and e2e.BASE or data.B)}
end

-- The exchange in progress gets its private key from the pool, or a wait
-- (once) while the pool is not ready. A ready pool still finishing a mix
-- gives the key a few frames later, with no wait.
local function make_key()
  local s = app.e2e
  local kx = s.kx
  if not kx or kx.a or s.keys or s.job then return end
  local a = pool:take()
  if a then
    kx.a = a
    write_keyfile()
    start_job('A', kx)
  elseif not pool:ready() and not s.waited[kx.kxId] then
    s.waited[kx.kxId] = true
    send_kx{{'step', 'wait'}, {'id', kx.kxId}}
  end
end

local function forget_exchange()
  local s = app.e2e
  s.kx, s.job, s.reveal = nil, nil, nil
  write_keyfile()
end

-- The reveal checked, A known: on a recovery the phone's proof, then the
-- shared secret's job.
local function begin_shared(reveal)
  local s = app.e2e
  local kx = s.kx
  s.reveal = nil
  local th = e2e.transcript(settings.account_id, kx.id, kx.A, reveal.B)
  if kx.recover then
    local rk, rmac = bytes_of(settings.recover_key, 32), bytes_of(reveal.rmac, 16)
    if not (rk and rmac and kx.recover == settings.recover_key_id and rmac == e2e.recover_mac(rk, 'phone', th)) then
      forget_exchange()
      return abort(kx.kxId, 'bad recovery')
    end
  end
  start_job('s', kx, {B = reveal.B, th = th})
end

-- The shared secret is known: the keys, the key file, the recovery key in
-- the settings, the safety code in the log, and the confirm.
local function finish_exchange(kx, data, shared)
  local s = app.e2e
  if not shared then
    forget_exchange()
    return abort(kx.kxId, 'bad key')
  end
  local th = data.th
  local k = e2e.derive(shared, th)
  local key_id, code = e2e.key_id(th), e2e.safety_code(th)
  local rmac
  if kx.recover then rmac = e2e.b64url(e2e.recover_mac(bytes_of(settings.recover_key, 32), 'addon', th)) end
  s.keys = {keyId = key_id, code = code, lineKey = k.lineKey, lineNonce = k.lineNonce, sendKey = k.sendKey,
            recoverKey = k.recoverKey, A = kx.A, B = data.B, kxId = kx.kxId, mac = e2e.b64url(e2e.confirm_mac(k.confirmKey, th)),
            rmac = rmac, acked = false, doneMac = e2e.b64url(e2e.done_mac(k.confirmKey, th))}
  s.kx, s.reveal = nil, nil
  write_keyfile()
  settings.recover_key, settings.recover_key_id = e2e.b64url(k.recoverKey), key_id
  settings.e2e_account = settings.account_id
  save()
  pool:stop()
  log('encryption on. Safety code: ' .. code .. '. The app shows the same code in Settings, under Encryption.')
  send_confirm()
end

-- Every prerender: one step of the job, or the pool asked again for a key.
local function pump_job()
  local s = app.e2e
  local j = s.job
  if not j then return make_key() end
  if s.kx ~= j.kx or s.keys then
    s.job = nil
    return
  end
  local result = j.job:step(e2e.STEPS)
  if result == nil then return end
  s.job = nil
  if j.stage == 's' then return finish_exchange(j.kx, j.data, result) end
  j.kx.A = result
  if s.reveal and s.reveal.kxId == j.kx.kxId then return begin_shared(s.reveal) end
  send_key(j.kx)
end

local function on_commit(frame)
  local s = app.e2e
  local h = bytes_of(frame.h, 32)
  if not h or (frame.recover ~= nil and not is_key_id(frame.recover)) then return end
  if s.keys then return abort(frame.id, 'already set up') end
  if has_recovery_key() and frame.recover ~= settings.recover_key_id then
    return abort(frame.id, 'recovery required', settings.recover_key_id)
  end
  if s.completed >= MAX_EXCHANGES then return abort(frame.id, 'too many') end
  local kx = s.kx
  if kx and kx.kxId == frame.id and kx.h == h then -- the same commit again
    if kx.A then send_key(kx) end
    return
  end
  s.kx, s.job, s.reveal = {kxId = frame.id, id = bytes_of(frame.id, 16), h = h, recover = frame.recover}, nil, nil
  write_keyfile()
  make_key()
end

local function on_reveal(frame)
  local s = app.e2e
  if s.keys then
    if frame.id == s.keys.kxId then return send_confirm() end
    return abort(frame.id, 'unknown exchange')
  end
  local kx = s.kx
  if not (kx and kx.kxId == frame.id and kx.a) then return abort(frame.id, 'unknown exchange') end
  if (s.job and s.job.stage == 's' and s.job.kx == kx) or s.reveal then return end -- being worked on
  local B = bytes_of(frame.b, 32)
  if not B or e2e.commit_hash(kx.id, B) ~= kx.h then
    forget_exchange()
    return abort(frame.id, 'commit mismatch')
  end
  s.completed = s.completed + 1
  local reveal = {kxId = frame.id, B = B, rmac = frame.rmac}
  if kx.A then return begin_shared(reveal) end
  s.reveal = reveal
  if not (s.job and s.job.kx == kx) then start_job('A', kx) end
end

local function on_kx(frame)
  if not pool or not bytes_of(frame.id, 16) then return end
  local s, step = app.e2e, frame.step
  if step == 'commit' then
    on_commit(frame)
  elseif step == 'reveal' then
    on_reveal(frame)
  elseif step == 'done' then
    local k = s.keys
    if k and not k.acked and frame.id == k.kxId and k.doneMac and frame.mac == k.doneMac then
      k.acked = true
      write_keyfile()
    end
  elseif step == 'abort' then
    if s.kx and frame.id == s.kx.kxId then forget_exchange() end
  end
end

-- On every connect, once the relay says hello: the confirm again until the
-- phone acknowledged it, or the key again while its reveal has not come.
local function resend_kx()
  local s = app.e2e
  if not pool then return end
  if s.keys then
    if not s.keys.acked then send_confirm() end
  elseif s.kx and s.kx.A then
    send_key(s.kx)
  end
end

-- The socket URL: whether this addon can encrypt, its key id, and the key
-- id of the recovery key it holds when it has no keys.
local function socket_url()
  local url = RELAY_URL .. '/v1/ws?role=addon'
  if not pool then return url end
  local s = app.e2e
  local recover = (not s.keys and has_recovery_key()) and settings.recover_key_id or ''
  return url .. '&e2e=1&key=' .. (s.keys and s.keys.keyId or '') .. '&recover=' .. recover
end

local function encryption_text()
  local s = app.e2e
  if not pool then return 'off (not available here)' end
  if s.keys then return 'on, safety code ' .. s.keys.code end
  if s.kx then
    if not s.kx.a and s.waited[s.kx.kxId] then return 'setting up (gathering randomness)' end
    return 'setting up'
  end
  return 'off (waiting for the app; if the app says this addon needs an update, encryption is being blocked)'
end

-- ls1 and ls2 frames name the shell the game said is in that slot, or null
-- when it has not said: a line is never named by a guess. Party lines are
-- group lines like linkshell lines (a sender, a null target) but, like
-- tells, have no linkshell key. The first line sent with no name while
-- shells are equipped is remembered by its time (ts, in ms): once the game
-- says where those shells are, the relay is told to name the lines from
-- that time on.
local function linkshell_name(channel, ts)
  if channel ~= 'ls1' and channel ~= 'ls2' then return nil end
  local ls = app.ls
  if not ls.current then return NULL end
  if not ls.known then
    if not ls.unnamed_from and ls.found and #ls.found > 0 then ls.unnamed_from = ts end
    return NULL
  end
  local shell = ls.current[channel]
  return shell and shell.name or NULL
end

-- ts: when the line was captured, in ms; now when left out.
local function chat_frame(channel, direction, sender, target, text, ts)
  ts = ts or math.floor(now() * 1000)
  return encode_fields{{'type', 'chat'}, {'channel', channel}, {'linkshell', linkshell_name(channel, ts)},
                       {'direction', direction}, {'sender', sender}, {'target', target}, {'text', text},
                       {'ts', ts}}
end

-- The same frame, sealed: no text; the time, then the envelope. The text
-- gets the relay's rules first; a line with nothing left is dropped (nil).
local function sealed_frame(line)
  local text = e2e.clean_text(line.text)
  local keys = app.e2e.keys
  if not text or not keys then return nil end
  local s = app.e2e
  s.seq = s.seq + 1
  local sender = line.sender ~= NULL and line.sender or nil
  local target = line.target ~= NULL and line.target or nil
  local meta = {key_id = keys.keyId, kind = e2e.kind(line.channel), direction = line.direction, sender = sender, target = target}
  local envelope = e2e.seal_line(keys, meta, text, line.ts, s.seq)
  local head = encode_fields{{'type', 'chat'}, {'channel', line.channel}, {'linkshell', linkshell_name(line.channel, line.ts)},
                             {'direction', line.direction}, {'sender', line.sender}, {'target', line.target}, {'ts', line.ts}}
  return head:sub(1, -2) .. ',"e2e":' .. envelope .. '}'
end

-- channel: the slot a linkshell send was typed in, when it is not the one
-- the relay asked for.
local function ack(client, id, ok, err, channel)
  client:send_text(encode_fields{{'type', 'ack'}, {'id', id}, {'ok', ok}, {'error', err}, {'channel', channel}})
end

local function player_name()
  local player = windower.ffxi.get_player()
  return player and player.name
end

-- Sends a chat frame now, holds it while the link is down, or drops it while
-- the relay is off or not paired. A full queue drops its oldest frame.
local function deliver(frame)
  local state = app.state
  if state == 'open' then
    app.client:send_text(frame)
  elseif state == 'waiting' or state == 'connecting' or state == 'unauthorized' then
    if #app.queue >= QUEUE_MAX then
      table.remove(app.queue, 1)
      if not app.queue_full then
        app.queue_full = true
        log('offline queue full, dropping oldest messages')
      end
    end
    app.queue[#app.queue + 1] = frame
  end
end

-- Just before an update's reload (//vt update, or the one the relay's
-- refusal starts), and again at the unload of any update's or rollback's
-- reload, the queue goes to queue.json, through queue.json.tmp and a rename;
-- an empty queue removes it. So the file holds the queue as it is at the
-- last moment. The next load reads it back and deletes it at once
-- (read_queue). This is the only time chat is written to disk.
local function write_queue()
  if #app.queue == 0 then
    os.remove(QUEUE_FILE)
    return
  end
  if not windower.dir_exists(DATA_DIR) then pcall(windower.create_dir, DATA_DIR) end
  local frames = {}
  for i, frame in ipairs(app.queue) do frames[i] = json.encode(frame) end
  write_through(QUEUE_FILE, '{"v":1,"frames":[' .. table.concat(frames, ',') .. ']}')
end

-- On load: the queue an update's reload left in queue.json, deleted at once.
-- At most QUEUE_MAX frames (the newest), and only chat frames; a damaged file
-- counts as none. They go out, as stored, once the relay says hello.
local function read_queue()
  local text = read_written(QUEUE_FILE)
  os.remove(QUEUE_FILE)
  os.remove(QUEUE_FILE .. '.tmp')
  if not text then return end
  local ok, saved = pcall(json.decode, text)
  if not (ok and type(saved) == 'table' and saved.v == 1 and type(saved.frames) == 'table') then return end
  local frames = {}
  for _, frame in ipairs(saved.frames) do
    if type(frame) == 'string' and frame:find('^{"type":"chat",') then frames[#frames + 1] = frame end
  end
  for i = math.max(1, #frames - QUEUE_MAX + 1), #frames do app.queue[#app.queue + 1] = frames[i] end
end

local confirm_lone -- set with the linkshell lookup, below

-- A line on its way: sealed at the start of the next prerender if it was
-- captured while the keys existed, else in plaintext now, as it was said
-- unencrypted.
local function send_line(line)
  if line.keyed then
    app.sealing[#app.sealing + 1] = line
  else
    deliver(chat_frame(line.channel, line.direction, line.sender, line.target, line.text, line.ts))
  end
end

-- At the start of each prerender, before the socket is pumped: the lines
-- waiting to be sealed, in the order they were captured, until about
-- SEAL_BUDGET of sealing (always at least one), so a burst spills into the
-- next frames instead of hitching this one. A single line goes out in the
-- frame it would have gone in plaintext.
local function seal_lines()
  local lines = app.sealing
  if #lines == 0 then return end
  local started, done = os.clock(), 0
  while done < #lines and (done == 0 or os.clock() - started < SEAL_BUDGET) do
    done = done + 1
    local frame = sealed_frame(lines[done])
    if frame then deliver(frame) end
  end
  local rest = {}
  for i = done + 1, #lines do rest[#rest + 1] = lines[i] end
  app.sealing = rest
end

-- A captured chat line on its way to the relay. A linkshell line captured
-- while the game is being asked which shell is in which slot waits up to
-- LS_LOOKUP_HOLD for the answer, so it is named by it. With one shell
-- equipped, a linkshell line itself says which slot that shell is in.
local function relay_line(channel, direction, sender, target, text)
  local ls = app.ls
  local line = {channel = channel, direction = direction, sender = sender, target = target, text = text,
                ts = math.floor(now() * 1000), keyed = app.e2e.keys ~= nil}
  if channel == 'ls1' or channel == 'ls2' then
    if not ls.known then confirm_lone(channel) end
    local look = ls.lookup
    if look and now() < look.hold_until and #ls.held < LS_HELD_MAX then
      ls.held[#ls.held + 1] = line
      return
    end
  end
  send_line(line)
end

-- Drops expired echo entries; -> the live ones.
local function live_echoes(t)
  local live = {}
  for _, echo in ipairs(app.echoes) do
    if t < echo.expires then live[#live + 1] = echo end
  end
  app.echoes = live
  return live
end

-- True when an outgoing record is the game's copy of a phone send. The
-- matching entry is used up.
local function take_echo(record)
  local target = record.target and record.target:lower()
  local echoes = live_echoes(now())
  for i, echo in ipairs(echoes) do
    if echo.channel == record.channel and echo.text == record.text and echo.target == target then
      table.remove(echoes, i)
      return true
    end
  end
  return false
end

local function remember_executed(id)
  app.executed[id] = true
  local order = app.executed_order
  order[#order + 1] = id
  if #order > EXECUTED_IDS_MAX then app.executed[table.remove(order, 1)] = nil end
end

-- The relay's send ids are positive integers. Anything else is ignored
-- with no ack: json.encode cannot write inf or nan.
local function is_send_id(id)
  return type(id) == 'number' and id == id and id ~= math.huge and id ~= -math.huge and id >= 1 and id % 1 == 0
end

local OTHER_SLOT = {ls1 = 'ls2', ls2 = 'ls1'}
local lookup_for_send -- set with the linkshell lookup, below

local function slot_name(state, channel)
  local shell = state and state[channel]
  return shell and shell.name or nil
end

local REPLAY_WINDOW = 12 * 3600 * 1000 -- ms: a send this far from the PC's clock is too old, and an opened send's record lasts this long

local function now_ms()
  return math.floor(now() * 1000)
end

-- Drops replay records 12 hours past the later of typed (or refused) time
-- and send time.
local function prune_sent(t)
  local kept = {}
  for _, r in ipairs(app.e2e.sent) do
    if t <= math.max(r.typedAt, r.ts) + REPLAY_WINDOW then kept[#kept + 1] = r end
  end
  local changed = #kept ~= #app.e2e.sent
  app.e2e.sent = kept
  return changed
end

local function sent_record(field, value)
  for _, r in ipairs(app.e2e.sent) do
    if r[field] == value then return r end
  end
  return nil
end

-- A sealed send with this clientId under another relay id, held for a
-- linkshell lookup (it has no replay record until it is typed or refused).
local function held_elsewhere(client_id, id)
  for _, send in ipairs(app.ls.held_sends) do
    if send.opened and send.frame.clientId == client_id and send.frame.id ~= id then return true end
  end
  return false
end

-- An opened send's replay record, once it is typed or refused (err): the
-- same clientId under another relay id is then already sent, and the same
-- relay id gets the same answer again, so a send refused (not logged in,
-- say) is never typed later.
local function record_send(send, err)
  if not send.opened then return end
  local t = now_ms()
  prune_sent(t)
  app.e2e.sent[#app.e2e.sent + 1] = {clientId = send.frame.clientId, id = send.frame.id, typedAt = t, ts = send.opened.ts,
                                     error = err}
  write_keyfile()
end

-- A send runs at most one game command per id and is always acked; the
-- relay may replay an id after a reconnect. send = {frame =, text =, want =,
-- opened =}: the frame, the text to type (the opened payload's, or the
-- frame's plaintext), and for a sealed send its payload and destination.
-- A linkshell send is for a linkshell, not a slot: the one a sealed send's
-- payload names (ls:<Name>), else the one the relay names (frame.linkshell),
-- else the one this addon last told the relay is in the frame's slot; a
-- send to a slot (slot:N, or one that names none) is for that slot. While
-- the game has not said which shell is in which slot, the send waits for a
-- lookup, and fails if the game still has not said: it is never typed in a
-- slot that is a guess. It is typed in the slot the game said that linkshell
-- is in, and the ack names that slot when it is not the frame's; a
-- linkshell in neither slot fails the send. want: the linkshell (false: the
-- frame's slot), worked out when the frame first arrived. looked: a lookup
-- ran for this send already.
local function type_send(client, send, looked)
  local frame = send.frame
  local id = frame.id
  if app.executed[id] then return ack(client, id, true) end
  local done = send.opened and sent_record('id', id)
  if done then return ack(client, id, done.error == nil, done.error) end
  local function refuse(err)
    record_send(send, err)
    return ack(client, id, false, err)
  end
  if not windower.ffxi.get_player() then return refuse('not logged in') end
  local channel = frame.channel
  local command, text = chat.validate_send(channel, frame.target, send.text)
  if not command then return refuse(text) end
  if channel == 'ls1' or channel == 'ls2' then
    local ls = app.ls
    if send.want == nil then send.want = is_set(frame.linkshell) and frame.linkshell or slot_name(ls.sent, channel) or false end
    local want = send.want
    -- A send that names no linkshell is for the slot it gives.
    if want then
      if ls.lookup or (not ls.known and not looked and lookup_for_send()) then
        ls.held_sends[#ls.held_sends + 1] = send
        return
      end
      if not ls.known then return refuse('linkshell slot not known') end
      if slot_name(ls.current, channel) ~= want then
        channel = OTHER_SLOT[channel]
        if slot_name(ls.current, channel) ~= want then return refuse('linkshell not equipped') end
        command, text = chat.validate_send(channel, frame.target, send.text)
      end
    end
  end
  windower.send_command(command)
  remember_executed(id)
  record_send(send)
  local t = now()
  local echoes = live_echoes(t)
  echoes[#echoes + 1] = {channel = channel, target = channel == 'tell' and frame.target:lower() or nil,
                         text = text, expires = t + ECHO_WINDOW}
  ack(client, id, true, nil, channel ~= frame.channel and channel or nil)
end

-- A sealed send's destination against its frame: '' for a tell or party;
-- ls:<Name> or slot:1 or slot:2 for a linkshell. -> the linkshell wanted
-- (false: the frame's slot) | nil, the error.
local function destination(frame, to)
  local kind = e2e.kind(frame.channel)
  if kind ~= 'ls' then
    if to ~= '' then return nil, 'bad destination' end
    return false
  end
  local name = to:match('^ls:(.+)$')
  if name then
    if is_set(frame.linkshell) and frame.linkshell ~= name then return nil, 'linkshell mismatch' end
    return name
  end
  local slot = to:match('^slot:([12])$')
  if not slot then return nil, 'bad destination' end
  if frame.channel ~= 'ls' .. slot then return nil, 'linkshell mismatch' end
  return false
end

-- A send frame as it arrives, before it may wait for a linkshell lookup:
-- with keys, it must be sealed under them, for the destination the frame
-- has, not typed before nor held under another relay id, and not more than
-- 12 hours from this PC's clock;
-- without keys, it must be plaintext. The decision stands for a send held
-- for a lookup, whatever happens to the keys meanwhile.
local function handle_send(client, frame)
  local id = frame.id
  if not is_send_id(id) then return end
  if app.executed[id] then return ack(client, id, true) end
  local done = sent_record('id', id)
  if done then return ack(client, id, done.error == nil, done.error) end
  local keys = app.e2e.keys
  local send = {frame = frame, text = frame.text}
  if keys then
    if frame.e2e == nil then return ack(client, id, false, 'not encrypted') end
    app.opened = app.opened + 1
    local opened, err = e2e.open_send(keys, frame)
    if not opened then return ack(client, id, false, err) end
    local want
    want, err = destination(frame, opened.to)
    if want == nil then return ack(client, id, false, err) end
    local t = now_ms()
    if prune_sent(t) then write_keyfile() end
    if sent_record('clientId', frame.clientId) or held_elsewhere(frame.clientId, id) then
      return ack(client, id, false, 'already sent')
    end
    if math.abs(opened.ts - t) > REPLAY_WINDOW then return ack(client, id, false, 'too old') end
    -- A send the phone sealed under these keys: it holds them, as done would say.
    if not keys.acked then
      keys.acked = true
      write_keyfile()
    end
    send.text, send.want, send.opened = opened.t, want, opened
  elseif frame.e2e ~= nil then
    return ack(client, id, false, 'could not decrypt')
  end
  type_send(client, send)
end

---------------------------------------------------------------------------
-- Linkshells: which shell is equipped in slots 1 and 2, for the relay.
---------------------------------------------------------------------------
local extdata -- Windower's libs/extdata, loaded on the first read; false if it would not load

local function load_extdata()
  if extdata == nil then
    local ok, lib = pcall(require, 'extdata')
    extdata = ok and type(lib) == 'table' and type(lib.decode) == 'function' and lib or false
    if not extdata then log('linkshell names unavailable: extdata did not load') end
  end
  return extdata
end

-- The linkshells equipped now, then the equipped items they were read from
-- (linkshells.equipped), or nil while the game data cannot be read (not
-- logged in, or the inventory not loaded yet, say).
local function read_linkshells()
  local ok, state, found = pcall(function()
    local player = windower.ffxi.get_player()
    if not player then return nil end
    local items = windower.ffxi.get_items()
    if not linkshells.inventory_loaded(items) or not load_extdata() then return nil end
    -- A reload mid-session has seen no 0x0E0 yet: start from the slots the game
    -- last sent for this character, saved in the settings.
    if app.ls.equips_for ~= player.name then
      app.ls.equips_for = player.name
      if next(app.ls.equips) == nil then app.ls.equips = linkshells.load_equips(settings.ls_slots, player.name) end
    end
    local found = linkshells.equipped(player, items, extdata.decode, app.ls.equips)
    return linkshells.assign(found, player, app.ls.equips), found
  end)
  if ok and state then return state, found end
  return nil
end

-- True when the game has said, since load or login, which slot one of these
-- shells is in (a second one is then in the other), or none is equipped: the
-- game flags every equipped shell (status 19), so no flagged shell means
-- both slots are empty.
local function game_said(found)
  local ls = app.ls
  if #found == 0 then return true end
  for _, f in ipairs(found) do
    local n = ls.equips[f.key]
    if n and ls.said[n] then return true end
  end
  return false
end

-- Keeps this character's slots in the settings, for the next load.
local function save_slots()
  local name = player_name()
  if not name then return end
  local saved = linkshells.save_equips(settings.ls_slots, name, app.ls.equips)
  if saved ~= settings.ls_slots then settings.ls_slots = saved; save() end
end

-- A slot as JSON, its keys always in this order: null, or {"name":..,"color":..}.
local function shell_json(shell)
  if not shell then return 'null' end
  return encode_fields{{'name', shell.name}, {'color', shell.color}}
end

-- refile: lines this addon named from that time (ms) on were named by a
-- guess; the relay renames each by its slot in this frame.
local function send_linkshells(state, t)
  local ls = app.ls
  local refile = ls.refile and (',"refile":' .. json.encode(ls.refile)) or ''
  app.client:send_text('{"type":"linkshells","ls1":' .. shell_json(state.ls1) .. ',"ls2":' .. shell_json(state.ls2) .. refile .. '}')
  ls.sent, ls.sent_at, ls.pending, ls.refile = state, t, nil, nil
end

-- Sends a state that differs from the one last sent on this socket, at most
-- one frame every LS_GAP seconds: a change inside the gap waits for its end,
-- and one undone inside it is never sent. A frame that tells the relay to
-- rename lines goes even when the state is the one last sent.
local function offer_linkshells(state, t)
  local ls = app.ls
  if app.state ~= 'open' then return end
  if ls.sent and linkshells.same(state, ls.sent) and not ls.refile then
    ls.pending = nil
  elseif ls.sent_at and t - ls.sent_at < LS_GAP then
    ls.pending = state
  else
    send_linkshells(state, t)
  end
end

-- The same linkshells, whichever slots they are in.
local function same_shells(a, b)
  local a1, a2, b1, b2 = slot_name(a, 'ls1'), slot_name(a, 'ls2'), slot_name(b, 'ls1'), slot_name(b, 'ls2')
  return (a1 == b1 and a2 == b2) or (a1 == b2 and a2 == b1)
end

-- A read that counts: lines are named by it from now on (only once the game
-- has said where its shells are), and once the game has said, it goes to the
-- relay. Lines sent with no name while the same shells were equipped are
-- named then too, through the frame's refile; lines from before the shells
-- changed keep no name.
local function settle_linkshells(state, found, t)
  local ls = app.ls
  local known = game_said(found)
  if ls.unnamed_from and ls.current and not same_shells(ls.current, state) then ls.unnamed_from = nil end
  if known and ls.unnamed_from then
    ls.refile = math.min(ls.refile or ls.unnamed_from, ls.unnamed_from)
    ls.unnamed_from = nil
  end
  ls.current, ls.known, ls.found = state, known, found
  if known then offer_linkshells(state, t) end
end

-- The game said where a shell is: the slots are saved and read again, and
-- that read counts at once.
local function apply_game_slots(t)
  save_slots()
  local state, found = read_linkshells()
  if state then
    app.ls.seen = {state = state, since = t}
    settle_linkshells(state, found, t)
  end
end

local function relaying()
  return app.state == 'open' or app.state == 'connecting' or app.state == 'waiting'
end

---------------------------------------------------------------------------
-- The lookup: asking the game which linkshell is in which slot.
-- /lsmes shows slot 1's linkshell message and /ls2mes slot 2's, and the
-- reply (0x0CC) carries the linkshell's name. One command is asked at a
-- time, and the next only after LS_LOOKUP_WAIT, so a reply always answers
-- the one command asked; the reply packet is blocked, so nothing shows in
-- the chat log. With two shells equipped, one answer places both. A slot
-- with no shell, or a linkshell with no message set, gives no reply (the
-- game may print its own line for that). Linkshell lines wait up to
-- LS_LOOKUP_HOLD for the first answer, then go with no name until one comes.
---------------------------------------------------------------------------
local finish_lookup

local function ask(look, slot, t)
  look.slot, look.deadline = slot, t + LS_LOOKUP_WAIT
  windower.send_command(LS_LOOKUP[slot])
end

local function start_lookup(found, t)
  local look = {found = found, sig = linkshells.signature(found), hold_until = t + LS_LOOKUP_HOLD}
  app.ls.lookup = look
  ask(look, 1, t)
end

-- The lines held for the first answer.
local function release_lines()
  local ls = app.ls
  local held = ls.held
  ls.held = {}
  for _, line in ipairs(held) do send_line(line) end
end

-- The sends that waited for the lookup.
local function release_sends()
  local ls = app.ls
  local sends = ls.held_sends
  ls.held_sends = {}
  if app.state == 'open' and app.client then
    for _, send in ipairs(sends) do type_send(app.client, send, true) end
  end
end

-- Every prerender while a lookup runs: the held lines go once their wait is
-- over, and a command whose reply did not come is followed by the next one.
local function pump_lookup(t)
  local look = app.ls.lookup
  if not look then return end
  if #app.ls.held > 0 and t >= look.hold_until then release_lines() end
  if t >= look.deadline then
    if look.slot == 1 then ask(look, 2, t) else finish_lookup(t, 'silent') end
  end
end

-- how: 'answered' (the game named a slot's shell), 'silent' (no reply to
-- either command: not asked again for the same shells, except for a phone
-- send) or 'cancelled' (an equip packet, a zone or a logout came first).
finish_lookup = function(t, how)
  local ls = app.ls
  local look = ls.lookup
  if not look then return end
  ls.lookup = nil
  if how == 'answered' then
    ls.looked = nil
    apply_game_slots(t)
  elseif how == 'silent' then
    ls.looked = look.sig
  end
  -- A reply still on its way answers a command of ours: it stays out of the log.
  if how ~= 'answered' then ls.swallow_until = t + LS_LOOKUP_WAIT end
  release_lines()
  release_sends()
end

-- A linkshell message (0x0CC). -> true when it answers a command the addon
-- typed, so the caller blocks it.
local function on_linkshell_message(data)
  local ls, t = app.ls, now()
  local look = ls.lookup
  if look then
    if not linkshells.confirm(ls.equips, look.found, linkshells.message_names(data), look.slot) then return false end
    ls.said[look.slot] = true
    if #look.found == 2 then ls.said[3 - look.slot] = true end
    finish_lookup(t, 'answered')
    return true
  end
  return t < ls.swallow_until
end

-- One shell equipped, and a linkshell line on channel: that is the slot it
-- is in. Not while an equip packet's read is pending: another shell may have
-- just been equipped, and the line may be its.
confirm_lone = function(channel)
  local ls = app.ls
  local found = ls.found
  if not (found and #found == 1) or ls.due.equip then return end
  local number = channel == 'ls1' and 1 or 2
  linkshells.place(ls.equips, found[1].key, number)
  ls.said[number] = true
  apply_game_slots(now())
  finish_lookup(now(), 'cancelled')
end

-- A linkshell send arrived while the game has not said where the equipped
-- shells are: it is asked now. -> true when a lookup was started.
lookup_for_send = function()
  local ls, t = app.ls, now()
  if ls.known or ls.lookup then return false end
  local state, found = read_linkshells()
  if not state or #found == 0 or game_said(found) then return false end
  start_lookup(found, t)
  return true
end

local function check_linkshells(t)
  local ls = app.ls
  local watching = t < ls.watch_until
  ls.next_read = t + (watching and LS_RECHECK or LS_PERIOD)
  local state, found = read_linkshells()
  if not state then
    ls.seen = nil
    return
  end
  if not (ls.seen and linkshells.same(state, ls.seen.state)) then ls.seen = {state = state, since = t} end
  if watching and t - ls.seen.since < LS_SETTLE then return end
  settle_linkshells(state, found, t)
  -- The game has not said where these shells are: ask it, once for what is equipped.
  if not ls.known and not ls.lookup and #found > 0 and relaying() and linkshells.signature(found) ~= ls.looked then
    start_lookup(found, t)
  end
end

-- Login or zone-in: the game's linkshell data may be wrong for a while.
local function watch_linkshells()
  app.ls.watch_until = now() + LS_WATCH
  app.ls.seen = nil
end

-- An event may have changed what is equipped. The game applies a packet
-- after its chunk handler runs, so the read waits. Each kind of event keeps
-- one pending read, which a repeat pushes back rather than forward.
local function check_linkshells_in(kind, delay)
  local due, at = app.ls.due, now() + delay
  if not due[kind] or due[kind] < at then due[kind] = at end
end

---------------------------------------------------------------------------
-- Connection lifecycle.
---------------------------------------------------------------------------
-- Starts the wait before the next attempt. A connection that comes back
-- within QUIET_DROP seconds says nothing; one still down then gets the
-- connection lost line, once per outage (prerender), and reconnected once
-- it opens.
local function schedule_retry(reason)
  local t = now()
  if app.opened_at and t - app.opened_at >= STABLE_AFTER then app.backoff = BACKOFF_MIN end
  app.opened_at = nil
  local delay = app.backoff
  app.backoff = math.min(app.backoff * 2, BACKOFF_MAX)
  app.state = 'waiting'
  app.next_attempt = t + delay
  app.last_error = reason
  if not app.outage then
    app.outage, app.outage_since, app.outage_said = true, t, false
  end
end

-- Detaches the client first: close() on a client that is not open yet fires
-- on_close at once, and a detached client's callbacks are ignored. Nothing
-- pumps a detached client, so abort() then sends the close frame close()
-- queued, if any, and closes the socket.
local function drop_client(code, reason)
  local client = app.client
  if not client then return end
  app.client = nil
  client:close(code, reason)
  client:abort()
end

-- The socket upgraded. It counts as open only once the relay says hello
-- (on_hello); a relay that refuses this version closes it without one. The
-- idle clock starts here, so a socket that never says hello is dropped after
-- IDLE_TIMEOUT and retried.
local function on_open(client)
  if client ~= app.client then return end
  app.last_rx = now()
end

-- The relay said hello: the connection is open. The held chat goes out
-- first, in order, then the linkshells. A second hello on the same socket
-- changes nothing.
local function on_hello(client)
  if app.state == 'open' then return end
  local queue = app.queue
  app.queue, app.queue_full = {}, false
  for _, frame in ipairs(queue) do client:send_text(frame) end
  local t = now()
  app.state = 'open'
  resend_kx()
  app.last_rx, app.last_ping, app.opened_at = t, t, t
  if app.outage_said then
    log('reconnected to relay')
  elseif not app.announced then
    log('connected to relay')
  end
  app.announced = true
  app.outage, app.outage_since, app.outage_said = false, nil, false
  local ls = app.ls
  ls.sent, ls.sent_at, ls.pending = nil, nil, nil
  -- While a read is settling, the new socket gets the last settled one, if the game had said its slots.
  if t < ls.watch_until and ls.current and ls.known then offer_linkshells(ls.current, t) end
  check_linkshells(t)
end

local function on_message(client, text)
  if client ~= app.client then return end
  app.last_rx = now()
  local ok, frame = pcall(json.decode, text)
  if not (ok and type(frame) == 'table') then return end
  if hooks.on_frame then hooks.on_frame(frame) end
  if frame.type == 'hello' then
    -- The relay says this account has switched to encryption.
    if frame.switched == 1 and is_account_id(settings.account_id) and settings.e2e_account ~= settings.account_id then
      settings.e2e_account = settings.account_id
      save()
    end
    on_hello(client)
  elseif frame.type == 'send' then
    handle_send(client, frame)
  elseif frame.type == 'kx' then
    on_kx(frame)
  end
end

-- ws.lua follows every on_error with an on_close carrying the same text,
-- so the work happens in on_close.
local function on_error()
end

-- The relay's refusal found no newer version on vanatell.com.
local function no_newer()
  if app.no_newer_said then return end
  app.no_newer_said = true
  log("encryption is on for this account and this version can't encrypt; no newer version is published yet")
end

-- Close code 4004: the relay refuses this version, as the account has
-- encryption on. It reconnects with backoff as for any close, quietly (the
-- outage counts as said, so no connection lost line), and updates itself
-- from vanatell.com as //vt update does, at most once in AUTO_UPDATE_GAP.
local function refused(reason)
  -- This version has encryption, but this Lua cannot run it: it is the
  -- newest there is and can never be let in, so it stops until //vt on or a
  -- reload.
  if not pool then
    app.state, app.opened_at, app.last_error = 'stopped', nil, reason
    app.outage, app.outage_since, app.outage_said = false, nil, false
    if not app.no_bit_said then
      app.no_bit_said = true
      log("encryption is on for this account and can't run on this PC (no bit library)")
    end
    return
  end
  schedule_retry(reason)
  app.outage_said = true
  local t = now()
  if app.auto_update_at and t - app.auto_update_at < AUTO_UPDATE_GAP then return end
  app.auto_update_at = t
  if not app.forced_said then
    app.forced_said = true
    log('encryption is on for this account; updating to the newest version')
  end
  updater:run_update{auto = true, on_none = no_newer, before_reload = write_queue}
end

-- 401/403 on the upgrade, or close code 4000 (account deleted) or 4001
-- (token revoked): the token is no good, so stop until the owner pairs again.
-- Close code 4004 updates the addon (refused). Anything else reconnects with
-- backoff.
local function on_close(client, code, reason)
  if client ~= app.client then return end
  app.client = nil
  local status = client.http_status
  if status == 401 or status == 403 or code == 4000 or code == 4001 then
    app.state = 'unauthorized'
    app.opened_at = nil
    log(code == 4000 and ACCOUNT_DELETED or REJECTED)
    return
  end
  if not is_set(reason) then reason = 'code ' .. tostring(code) end
  if code == 4004 then return refused(reason) end
  schedule_retry(reason)
end

local function connect()
  local client = ws.new{
    url = socket_url(),
    headers = {{'Authorization', 'Bearer ' .. settings.token}},
    cafile = CA_FILE,
    on_open = on_open,
    on_message = on_message,
    on_error = on_error,
    on_close = on_close,
  }
  app.client = client
  app.state = 'connecting'
  app.opened_at, app.last_rx = nil, nil
  local ok, err = client:connect()
  if not ok and app.client == client then
    app.client = nil
    schedule_retry(tostring(err))
  end
end

-- A deliberate start (load, //vt on, a new url, a new token): fresh backoff,
-- then connect if paired and enabled, or settle in the state that says why
-- not.
local function start()
  if not has_credentials() then
    app.state = 'unpaired'
    log(NOT_PAIRED)
  elseif not is_enabled() then
    app.state = 'disabled'
  else
    app.backoff = BACKOFF_MIN
    app.outage, app.outage_since, app.outage_said, app.announced = false, nil, false, false
    connect()
  end
end

---------------------------------------------------------------------------
-- Pairing: trades the code shown on the phone for this addon's token.
---------------------------------------------------------------------------
-- wss://host -> https://host/v1/pair; ws://host -> http://host/v1/pair
local function pair_url(url)
  return (url:gsub('^wss://', 'https://'):gsub('^ws://', 'http://')) .. '/v1/pair'
end

-- A 2xx reply: save the new token, then drop any client on the old one and
-- start afresh, which also leaves the unauthorized state. With relaying off,
-- start() stays in disabled, so the log says how to turn it on.
local function paired(body)
  local ok, reply = pcall(json.decode, body)
  if not (ok and type(reply) == 'table' and is_account_id(reply.accountId) and is_token(reply.addonToken)) then
    return log('pairing failed: bad response from relay')
  end
  settings.token = reply.addonToken
  settings.account_id = reply.accountId
  if settings.e2e_account ~= reply.accountId then settings.e2e_account = '' end
  save()
  -- Only now, with the new token saved: a mistyped or expired code never
  -- leaves a working pairing without its keys.
  delete_keys()
  log('paired (account ' .. reply.accountId .. ')')
  drop_client(1000, 're-paired')
  start()
  if app.state == 'disabled' then log('relay is off; //vt on to start') end
end

-- Any other status: the relay's message, else its error code, either cut to
-- RELAY_MESSAGE_MAX bytes (log shows each byte as one character), else the
-- status.
local function pairing_refused(status, body)
  local ok, reply = pcall(json.decode, body)
  if not (ok and type(reply) == 'table') then reply = {} end
  local why = 'http ' .. tostring(status)
  if is_set(reply.message) then
    why = reply.message:sub(1, RELAY_MESSAGE_MAX)
  elseif is_set(reply.error) then
    why = reply.error:sub(1, RELAY_MESSAGE_MAX)
  end
  log('pairing failed: ' .. why)
end

-- Abandons the pairing request in flight, if any. It fires no callback.
local function cancel_pairing()
  local req = app.pairing
  app.pairing = nil
  if req then req:cancel() end
end

---------------------------------------------------------------------------
-- Commands.
---------------------------------------------------------------------------

local HELP = {
  'relays tells, party, LS1 and LS2 chat to the VanaTell app',
  'commands:',
  '//vt pair <code> - pair with the code shown on your phone',
  '//vt status - show the connection state',
  '//vt on | //vt off - start or stop relaying',
  "//vt unpair - forget this addon's relay token",
  '//vt update - install the newest version, if there is one',
  '//vt rollback - go back to the version before the last update',
  '//vt help - show this list',
}

local function show_help()
  for _, line in ipairs(HELP) do log(line) end
end

local CONNECTION_TEXT = {open = 'connected', connecting = 'connecting', unpaired = 'not paired',
                         disabled = 'off', unauthorized = 'token rejected, pair again',
                         stopped = "stopped (encryption is on for this account and can't run on this PC)"}

local function connection_text()
  if app.state ~= 'waiting' then return CONNECTION_TEXT[app.state] end
  local secs = math.max(0, math.ceil(app.next_attempt - now()))
  return 'retrying in ' .. secs .. 's (' .. tostring(app.last_error) .. ')'
end

local commands = {}

-- The request is pumped from prerender. Its callbacks do nothing once it is
-- no longer app.pairing.
function commands.pair(code)
  -- Case-insensitive, and dashes or spaces from the phone's display are dropped, as the relay does.
  -- [A-Za-z0-9] is %w without the locale.
  code = type(code) == 'string' and code:upper():gsub('[%s%-]', '') or ''
  if #code ~= 8 or not code:find('^[A-Z0-9]+$') then
    return log('pairing code must be 8 letters or digits')
  end
  if app.pairing then return log('pairing already in progress') end
  local req, err
  req, err = ws.http_post{
    url = pair_url(RELAY_URL),
    body = json.encode({code = code}),
    cafile = CA_FILE,
    on_done = function(status, body)
      if req ~= app.pairing then return end
      app.pairing = nil
      if status >= 200 and status < 300 then paired(body) else pairing_refused(status, body) end
    end,
    on_error = function(e)
      if req ~= app.pairing then return end
      app.pairing = nil
      log('pairing failed: ' .. tostring(e))
    end,
  }
  if not req then return log('pairing failed: ' .. tostring(err)) end
  app.pairing = req
  log('pairing...')
end

local function shell_text(shell)
  return shell and shell.name or '(none)'
end

-- Read on the spot, so it shows what is equipped even while not connected.
-- Slots the game has not said are not shown.
local function linkshells_text()
  local state, found = read_linkshells()
  if not state then return 'unknown' end
  if not game_said(found) then
    local names = {}
    for i, f in ipairs(found) do names[i] = f.shell.name end
    table.sort(names)
    return table.concat(names, ', ') .. ' (slots not known yet)'
  end
  return '1=' .. shell_text(state.ls1) .. ' 2=' .. shell_text(state.ls2)
end

function commands.status()
  log('version: ' .. _addon.version)
  if is_token(settings.token) then
    log('paired: yes (account ' .. (is_set(settings.account_id) and settings.account_id or 'unknown') .. ')')
  else
    log('paired: no')
  end
  log('enabled: ' .. (is_enabled() and 'yes' or 'no'))
  log('connection: ' .. connection_text())
  log('queued: ' .. #app.queue)
  log('linkshells: ' .. linkshells_text())
  log('encryption: ' .. encryption_text())
end

function commands.on()
  settings.enabled = true
  save()
  log('relay on')
  if not app.client and app.state ~= 'waiting' then start() end
end

function commands.off()
  settings.enabled = false
  save()
  drop_client(1000, 'relay off')
  app.state = 'disabled'
  log('relay off')
end

function commands.unpair()
  cancel_pairing()
  settings.token = ''
  settings.account_id = ''
  settings.e2e_account = ''
  delete_keys()
  drop_client(1000, 'unpaired')
  app.queue = {}
  app.queue_full = false
  app.state = 'unpaired'
  log('unpaired')
end

function commands.update()
  updater:run_update{before_reload = write_queue}
end

function commands.rollback()
  updater:rollback()
end

commands.help = show_help

---------------------------------------------------------------------------
-- Events.
---------------------------------------------------------------------------
-- The version goes to the console, not the chat log. After an update or a
-- rollback, the version it reloaded into is said in both.
windower.register_event('load', function()
  pcall(console, 'VanaTell ' .. _addon.version .. ' loaded')
  updater:on_load()
  read_queue()
  load_keys()
  harvest()
  local s = app.e2e
  if pool and s.kx and s.kx.a and not s.keys then start_job('A', s.kx) end -- to answer the commit again
  start()
end)

-- The reload of an update or a rollback, which Windower (or Ashita) ran
-- some frames after it was asked for: the queue as it is now goes to
-- queue.json, unless the version it reloads into is older than QUEUE_SINCE,
-- which would never read it back.
windower.register_event('unload', function()
  cancel_pairing()
  if updater.reloading then
    if update.newer(QUEUE_SINCE, updater.reload_version) then os.remove(QUEUE_FILE) else write_queue() end
  end
  updater:on_unload()
  if pool then pool:on_unload() end
  local client = app.client
  app.client = nil
  if client then client:abort() end
end)

-- The socket's frames this prerender: up to MAX_FRAMES, and none past the
-- OPENS_MAX-th sealed send opened.
local function open_more()
  return app.opened < OPENS_MAX
end

windower.register_event('prerender', function()
  seal_lines()
  if app.pairing then app.pairing:pump() end
  updater:pump()
  local t = now()
  if pool then
    pool:pump(t)
    pump_job()
  end
  if app.outage and not app.outage_said and (app.state == 'waiting' or app.state == 'connecting')
      and t - app.outage_since >= QUIET_DROP then
    app.outage_said = true
    log('connection lost (' .. tostring(app.last_error) .. '), retrying')
  end
  if app.state == 'waiting' and t >= app.next_attempt then connect() end
  app.opened = 0
  if app.client then app.client:pump(MAX_FRAMES, open_more) end
  -- From the upgrade on, whether or not the relay has said hello.
  if app.client and app.last_rx then
    if t - app.last_rx >= IDLE_TIMEOUT then
      local client = app.client
      app.client = nil
      client:abort()
      schedule_retry('idle timeout')
    elseif app.state == 'open' and t - app.last_ping >= PING_INTERVAL then
      app.client:send_text(PING)
      app.last_ping = t
    end
  end
  local ls, read = app.ls, false
  pump_lookup(t)
  -- An event's read, or the periodic one while no event read is pending.
  for kind, at in pairs(ls.due) do
    if t >= at then ls.due[kind], read = nil, true end
  end
  if read or (next(ls.due) == nil and t >= ls.next_read) then check_linkshells(t) end
  if ls.pending and app.state == 'open' and t - ls.sent_at >= LS_GAP then send_linkshells(ls.pending, t) end
end)

-- The chunk handlers block one packet only: the reply to a /lsmes or
-- /ls2mes the addon typed itself (0x0CC). Every other packet goes through.
-- A chat chunk the game sends or receives again: FFXI re-sends a chunk until
-- it is acknowledged, and Windower sees each copy. A copy is byte for byte the
-- same, header sequence number included; a new line, even with the same words,
-- has its own sequence number. Copies seen within CHUNK_REPEAT seconds are
-- relayed once.
local CHUNK_REPEAT = 10
local recent_chunks = {}
local function repeated(id, data)
  local t = now()
  for key, at in pairs(recent_chunks) do
    if t - at > CHUNK_REPEAT then recent_chunks[key] = nil end
  end
  local key = id .. ':' .. data
  if recent_chunks[key] then return true end
  recent_chunks[key] = t
  return false
end

windower.register_event('incoming chunk', function(id, data)
  if id == 0x0CC then
    if on_linkshell_message(data) then return true end
    return
  end
  if id ~= 0x017 or repeated(id, data) then return end
  local record = chat.parse_incoming(data)
  if not record then return end
  local me = player_name()
  if me and record.sender:lower() == me:lower() then return end
  relay_line(record.channel, 'in', record.sender, NULL, record.text)
end)

-- Linkshell equip (0x0E0), zone-in (0x00A, after which the inventory
-- reloads) and inventory finished loading (0x01D) ask for a read once the
-- game has caught up.
windower.register_event('incoming chunk', function(id, data)
  if id == 0x0E0 then
    local player = windower.ffxi.get_player()
    -- First 0x0E0 since a reload: start from the saved slots, then apply it.
    if player and player.name and app.ls.equips_for ~= player.name and next(app.ls.equips) == nil then
      app.ls.equips = linkshells.load_equips(settings.ls_slots, player.name)
    end
    if linkshells.note_equip(app.ls.equips, data) then
      -- The game said where this slot's shell is: a lookup is not needed.
      app.ls.said[linkshells.parse_equip(data)] = true
      finish_lookup(now(), 'cancelled')
      if player and player.name then
        app.ls.equips_for = player.name
        save_slots()
      end
      check_linkshells_in('equip', LS_EQUIP_SETTLE)
    end
  elseif id == 0x00A then
    finish_lookup(now(), 'cancelled')
    watch_linkshells()
    check_linkshells_in('zone', LS_ZONE_SETTLE)
  elseif id == 0x01D then
    check_linkshells_in('inventory', LS_INVENTORY_SETTLE)
  end
end)

windower.register_event('login', function()
  watch_linkshells()
  check_linkshells_in('zone', LS_ZONE_SETTLE)
end)

-- Another character may log in next, with other shells in other bag slots.
windower.register_event('logout', function()
  finish_lookup(now(), 'cancelled')
  local ls = app.ls
  ls.equips, ls.current, ls.seen, ls.equips_for = {}, nil, nil, nil
  ls.said, ls.known, ls.found, ls.looked, ls.unnamed_from = {}, false, nil, nil, nil
end)

windower.register_event('outgoing chunk', function(id, data, modified, injected, blocked)
  if (id ~= 0x0B5 and id ~= 0x0B6) or blocked or repeated(id, data) then return end
  local record = chat.parse_outgoing(id, data)
  if not record or take_echo(record) then return end
  relay_line(record.channel, 'out', player_name() or NULL, record.target or NULL, record.text)
end)

windower.register_event('addon command', function(cmd, ...)
  local handler = commands[type(cmd) == 'string' and cmd:lower() or 'help']
  if handler then handler(...) else show_help() end
end)
