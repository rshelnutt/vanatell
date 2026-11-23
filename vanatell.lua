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
-- said), the yells it shares while the account has Yells on (yells.lua),
-- the character's blacklist for the app's Yells tab (the game's list, sent
-- whole, and /blacklist add for a name the app blacklists), and the update
-- check and //vt update (update.lua). All network work is pumped from
-- prerender and never blocks.
_addon.name = 'vanatell'
_addon.command = 'vt'
_addon.version = '0.6.3'

local config = require('config')

-- Tests set __vanatell_test to swap in modules and a clock. Sibling files load
-- with dofile, because Windower ships its own json and chat libraries.
local hooks = rawget(_G, '__vanatell_test') or {}
local function load_local(name) return hooks[name] or dofile(windower.addon_path .. name .. '.lua') end
local json, chat, ws = load_local('json'), load_local('chat'), load_local('ws')
local linkshells, update = load_local('linkshells'), load_local('update')
local e2e, random, sha256 = load_local('e2e'), load_local('random'), load_local('sha256')
local yells = load_local('yells')
yells.chat = chat
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
local LS_RECHECK = 2      -- seconds between reads while a slot waits for its name or its shell's colour
local LS_GAP = 2          -- shortest time between two linkshells frames
local LS_EQUIP_SETTLE = 1 -- wait after a linkshell equip packet before reading
local LS_INVENTORY_SETTLE = 0.5 -- wait after the inventory finished loading (0x01D)
-- The game says which slot a shell is in with a 0x0E0 packet (on equipping,
-- and for both slots on zone-in, by bag slot) and with the linkshell message
-- (0x0CC), which names the linkshell in a slot and says which slot, whatever
-- bag the shell is worn from: the game sends one when a shell is equipped
-- (the client asks for it) and as the reply to /lsmes (slot 1) and /ls2mes
-- (slot 2). The name it gives a slot, or a read finds at the bag slot the
-- game named for it, stands until a 0x0E0 empties that slot or puts another
-- item in it, or a logout; a zone-in changes nothing. The items are read only
-- to name a slot that has an item and no name yet, and a slot's shell counts
-- as gone only once the bag it is in has loaded. Right after a load (the
-- reload at login, //vt
-- reload or an update), each slot with a shell and no name from a 0x0CC is
-- asked once with those commands, so the game's reply names it; the name a
-- read gives is kept when no reply comes. A linkshell line is only ever
-- named by what the game said: until it has, the addon asks with those
-- commands, and keeps their replies out of the chat log.
local LS_LOOKUP_HOLD = 1.5  -- seconds linkshell lines wait for the first reply
local LS_LOOKUP_WAIT = 5    -- seconds a command's reply is waited for before the next command
local LS_HELD_MAX = 200     -- linkshell lines held while they wait
local LS_LOOKUP = {'input /lsmes', 'input /ls2mes'}

local PING = '{"type":"ping"}'
local CA_FILE = windower.addon_path .. 'relay-roots.txt'
-- The shared folder: data/ on Windower, config/addons/vanatell/ on Ashita.
-- Each character has its own folder in it, holding that character's
-- settings, key file, queue and entropy seed, so several game instances can
-- share one addon folder.
local BASE_DIR = rawget(windower, 'data_dir') or (windower.addon_path .. 'data/')

local function reload() windower.send_command('lua reload ' .. _addon.name) end

-- The character logged in when the addon loaded. Loaded before login (the
-- title screen), the addon opens no socket, writes nothing and runs no
-- command; at login it reloads, for that character.
local CHAR = (windower.ffxi.get_player() or {}).name
if type(CHAR) ~= 'string' or not CHAR:find('^[A-Za-z]+$') then CHAR = nil end
if not CHAR then
  windower.register_event('login', reload)
  windower.register_event('addon command', function()
    windower.add_to_chat(207, 'VanaTell: log in to a character first.')
  end)
  return
end
local CHAR_DIR = BASE_DIR .. CHAR .. '/'
-- As Windower's config library takes it: relative to the addon folder.
local SETTINGS_PATH = 'data/' .. CHAR .. '/settings.xml'
local QUEUE_FILE = CHAR_DIR .. 'queue.json' -- the queue, only across an update's or a rollback's reload, or a character change
local QUEUE_SINCE = '0.3.9' -- the first version that reads queue.json back
-- This pairing's encryption keys, and the exchange in progress (the key file).
local KEY_FILE = CHAR_DIR .. 'e2e.json'
-- The shared folder, then this character's, when missing.
local function ensure_data_dir()
  if not windower.dir_exists(BASE_DIR) then pcall(windower.create_dir, BASE_DIR) end
  if not windower.dir_exists(CHAR_DIR) then pcall(windower.create_dir, CHAR_DIR) end
end
-- In the shared folder: an account on this PC has switched to encryption
-- (rollbacks below encryption are refused for every character).
local E2E_ON = BASE_DIR .. 'e2e.on'

local function mark_e2e()
  local f = io.open(E2E_ON, 'rb')
  if f then return f:close() end
  f = io.open(E2E_ON, 'wb')
  if f then f:close() end
end

-- The pairing this PC had before characters had folders: the settings,
-- e2e.json, queue.json and entropy.seed in the shared folder itself. It
-- moves to a character its ls_slots name ('Name/bag:slot=n,...;Name/...'),
-- or, when they name none, to the first character to load. The settings
-- file goes first, by a rename, which fails once another box has moved it;
-- that box then has the pairing, and this one stays unpaired and moves
-- nothing else. -> true when this character took it
local SETTINGS_NAME = rawget(windower, 'platform') == 'ashita' and 'settings.json' or 'settings.xml'
local LEGACY_FILES = {'e2e.json', 'queue.json', 'entropy.seed'}

local function legacy_names(text)
  local slots
  if SETTINGS_NAME == 'settings.json' then
    local ok, t = pcall(json.decode, text)
    slots = ok and type(t) == 'table' and t.ls_slots
  else
    slots = text:match('<ls_slots>(.-)</ls_slots>')
    slots = slots and slots:gsub('^%s*<!%[CDATA%[(.-)%]%]>%s*$', '%1')
  end
  local names = {}
  for entry in (type(slots) == 'string' and slots or ''):gmatch('[^;]+') do
    local name = entry:match('^%s*([^/]+)/')
    if name then names[#names + 1] = name:lower() end
  end
  return names
end

local function claim_legacy()
  local old, mine = BASE_DIR .. SETTINGS_NAME, CHAR_DIR .. SETTINGS_NAME
  local f = io.open(mine, 'rb')
  if f then
    f:close()
    return false
  end
  f = io.open(old, 'rb')
  if not f then return false end
  local text = f:read('*a') or ''
  f:close()
  local names = legacy_names(text)
  if #names > 0 then
    local named = false
    for _, name in ipairs(names) do named = named or name == CHAR:lower() end
    if not named then return false end
  end
  if not os.rename(old, mine) then return false end
  for _, name in ipairs(LEGACY_FILES) do os.rename(BASE_DIR .. name, CHAR_DIR .. name) end
  return true
end

-- What the newest version is and which files it holds (update.lua).
local UPDATE_URL = 'https://vanatell.com/addon/latest.json'

-- Saved with 'all': the default per-character save does nothing while the
-- player is not logged in.
-- Every install talks to the one VanaTell relay; it cannot be changed. A relay address saved by an older version is
-- dropped. (Tests put a stand-in relay in __vanatell_test.)
local RELAY_URL = hooks.relay_url or 'wss://relay.vanatell.com'
-- recover_key: the key id of this pairing's keys and their recovery key,
-- '<key id>:<key>', kept beside the token so a lost key file is recovered by
-- itself. It is one string with a ':' because Windower's config library
-- reads back a value that looks like a number as a number, and a key id
-- alone (16 hex digits) can look like one. recover_key_id: where the key id
-- was kept on its own before; still read, and emptied whenever the recovery
-- key is written.
-- e2e_account: the account this PC knows has switched to encryption
-- (rollbacks below encryption are refused for it).
-- blacklist: the character's blacklist as the game last gave it whole and
-- edited it since: 'list:' then its names, comma-separated ('list:' alone is
-- an empty list; '' while the game has not given it). The game sends it as
-- the character zones in, which at login is before the addon has reloaded,
-- so it is kept here for the next load.
ensure_data_dir()
local claimed = claim_legacy()
local settings = config.load(SETTINGS_PATH, {token = '', account_id = '', enabled = true, ls_slots = '', recover_key = '',
                                             recover_key_id = '', e2e_account = '', blacklist = ''})
for _, key in ipairs({'ls_slots', 'recover_key', 'recover_key_id', 'e2e_account', 'blacklist'}) do
  if type(settings[key]) ~= 'string' then settings[key] = '' end
end
settings.url = nil
-- The pairing moved had switched to encryption.
if claimed and settings.e2e_account ~= '' and settings.e2e_account == settings.account_id then mark_e2e() end

-- The character's blacklist: its setting read back here, the rest after
-- the socket URL. One table, as the main chunk holds at most 200 locals.
local black = {
  WAIT = 10, -- seconds a /blacklist add the relay asked for waits for the game's add before it counts as not made
}

-- A character name as the game writes one: 3 to 15 letters.
function black.is_name(v)
  return type(v) == 'string' and #v >= 3 and #v <= 15 and v:find('^[A-Za-z]+$') ~= nil
end

-- The blacklist setting -> its names, or nil when it holds no list.
function black.kept(text)
  local rest = type(text) == 'string' and text:match('^list:(.*)$')
  if not rest then return nil end
  local names = {}
  if rest == '' then return names end
  for name in (rest .. ','):gmatch('([^,]*),') do
    if not black.is_name(name) or #names >= yells.BLACKLIST_MAX then return nil end
    names[#names + 1] = name
  end
  return names
end

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
  switching = false,   -- another character logged in: the reload for it was asked for
  auto_update_at = nil, -- when the relay's refusal last started an update
  forced_said = false, -- the refusal's updating line was logged since load
  no_bit_said = false, -- the refusal's no bit library line was logged since load
  no_newer_said = false, -- the refusal's no newer version line was logged since load
  opened_at = nil, last_rx = nil, last_ping = nil,
  world = nil,         -- the character's world, as the last socket URL named it
  yells_on = false,    -- this socket shares yells: the relay's hello or yells frame said so; false from every close
  blacklist = {        -- the character's blacklist (yells.lua reads the game's packets)
    names = black.kept(settings.blacklist), -- the list as the game last gave it whole, kept up to date by its edits; nil while not known
    building = nil,    -- the names of a list the game is sending in parts, from its first part until its last
    waiting = {},      -- lowercase name -> {name =, deadline =}: a /blacklist add typed for the relay, until the game's add
  },
  ls = {               -- linkshell detection
    equips = {},       -- 'bag:slot' -> 1 or 2, from 0x0E0 packets, /lsmes replies and the saved settings
    said = {},         -- slot number -> true: the game said since load or login what is in it
    named = {},        -- slot number -> the linkshell name kept for it: from a 0x0CC, or a read of the shell at its bag slot
    messaged = {},     -- slot number -> true: its kept name came from a 0x0CC
    after_load = true, -- the slots are still to be asked once each, after this load
    asked = {},        -- slot number -> true: asked once after this load
    colors = {},       -- linkshell name -> its colour, from the item reads
    known = false,     -- the game said which slot current's shells are in
    found = nil,       -- the equipped shells current was read from (linkshells.equipped)
    lookup = nil,      -- the /lsmes lookup in flight: {slot =, hold_until =, deadline =, found =, sig =}
    looked = nil,      -- what was equipped at the last lookup that got no answer
    swallow_until = 0, -- a linkshell message arriving before this time answers a command of ours: kept out of the log
    held = {},         -- linkshell lines waiting for the lookup's first reply
    held_sends = {},   -- the phone's linkshell sends waiting for the lookup to end
    unnamed_from = nil, -- ms time of the first linkshell line sent with no name while the slots were not known
    refile = nil,      -- ms time the next linkshells frame tells the relay to name lines from
    current = nil,     -- the last read, {ls1 =, ls2 =}; nil until one is
    loaded = {},       -- bag number -> true: the last read showed that bag loaded (an item in it); 'none': no bag
    read = {},         -- 'ls1'/'ls2' -> true: a read has seen that slot (its item's bag had loaded)
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

-- The version the addon folder's main file holds now (vanatell.lua; on
-- Ashita, main.lua): newer than this one once another box's update has put
-- its files in place. -> 'X.Y.Z' | nil
local MAIN_FILE = windower.addon_path .. (rawget(windower, 'platform') == 'ashita' and 'main.lua' or 'vanatell.lua')
local function installed_version()
  local f = io.open(MAIN_FILE, 'rb')
  if not f then return nil end
  local text = f:read('*a') or ''
  f:close()
  return text:match("_addon%.version%s*=%s*'(%d+%.%d+%.%d+)'")
end

local function file_exists(path)
  local f = io.open(path, 'rb')
  if f then f:close() end
  return f ~= nil
end

-- The update check on load, //vt update and //vt rollback. Settings are
-- never among the files it writes. One box at a time updates the shared
-- addon folder (update.lock in the shared folder).
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
  reload = reload,
  fs = {dir_exists = windower.dir_exists, create_dir = windower.create_dir},
  sha256 = hooks.sha256,
  budget = hooks.hash_budget,
  -- Keys held, or the relay said so (e2e_account), or any character's
  -- account on this PC has switched (e2e.on): no rollback below encryption.
  switched = function()
    return app.e2e.keys ~= nil or (is_set(settings.e2e_account) and settings.e2e_account == settings.account_id)
      or file_exists(E2E_ON)
  end,
  lock_path = BASE_DIR .. 'update.lock',
  holder = CHAR,
  installed_version = installed_version,
}
hooks.updater = updater

local NOT_PAIRED = 'not paired: run //vt pair <code> with the code from the VanaTell app'
local REJECTED = 'relay rejected the addon token; pair again with //vt pair <code>'
local ACCOUNT_DELETED = 'account deleted on the device; set up the app again, then //vt pair <code>'

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
-- The key file: data/<Name>/e2e.json (Ashita: config/addons/vanatell/<Name>/e2e.json).
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

-- The recovery key in the settings -> its key id, the key (b64url) | nil.
-- '<key id>:<key>' in recover_key, or the earlier form, the key id in
-- recover_key_id.
local function recovery()
  local id, key = settings.recover_key:match('^(%x+):(.+)$')
  if not id then id, key = settings.recover_key_id, settings.recover_key end
  if is_key_id(id) and bytes_of(key, 32) then return id, key end
  return nil
end

-- id, key (b64url), or nothing to clear it.
local function set_recovery(id, key)
  settings.recover_key = id and (id .. ':' .. key) or ''
  settings.recover_key_id = ''
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

-- Writes text to path through path.tmp and a rename (Windows will not
-- rename onto an existing file, so path goes first). A failed write leaves
-- path as it was; a failed rename leaves path.tmp, which read_written takes
-- and the next write puts in place first (while it cannot, nothing is
-- written, so that copy is never emptied).
local function write_through(path, text)
  local tmp = path .. '.tmp'
  if not tmp_in_place(path, tmp) then return end
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
    if settings.recover_key ~= k.keyId .. ':' .. recover_key or settings.recover_key_id ~= '' then
      set_recovery(k.keyId, recover_key)
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
    seed_path = CHAR_DIR .. 'entropy.seed',
    sha256 = sha256,
    start_values = start_values,
    clocks = {os.clock, now},
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
  set_recovery()
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

-- stage 'A': a·G, the addon's public key; stage 's': a·B, the shared secret.
local function start_job(stage, kx, data)
  app.e2e.job = {stage = stage, kx = kx, data = data, job = e2e.x25519_job(kx.a, stage == 'A' and e2e.BASE or data.B)}
end

-- A stage of the exchange that is not a scalar multiplication.
local STAGE = {ladder_done = 255}

-- The exchange in progress gets its private key from the pool, or a wait
-- (once) while the pool is not ready. A ready pool still finishing a mix
-- gives the key a few frames later, with no wait. The key file is written
-- and the job started in the next prerender (stage 'save').
local function make_key()
  local s = app.e2e
  local kx = s.kx
  if not kx or kx.a or s.keys or s.job then return end
  local a = pool:take()
  if a then
    kx.a = a
    s.job = {stage = 'save', kx = kx, job = STAGE}
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
    local id, key = recovery()
    local rk, rmac = bytes_of(key, 32), bytes_of(reveal.rmac, 16)
    if not (rk and rmac and kx.recover == id and rmac == e2e.recover_mac(rk, 'phone', th)) then
      forget_exchange()
      return abort(kx.kxId, 'bad recovery')
    end
  end
  start_job('s', kx, {B = reveal.B, th = th})
end

-- The shared secret is known: the rest of the exchange, a stage a
-- prerender so none goes past the frame budget: the keys ('keys', e2e.HMACS
-- HMACs a frame), the key id, safety code and proofs ('proofs'), the keys
-- in place, the key file, the confirm and the safety code in the log
-- ('commit'), then the recovery key in the settings ('settle').
local function finish_stage(j)
  local s = app.e2e
  local kx, data = j.kx, j.data
  if j.stage == 'keys' then
    local k = j.job:step(e2e.HMACS)
    if k then j.stage, j.k, j.job = 'proofs', k, STAGE end
  elseif j.stage == 'proofs' then
    local th, k = data.th, j.k
    local rmac
    if kx.recover then
      local _, key = recovery()
      rmac = e2e.b64url(e2e.recover_mac(bytes_of(key, 32), 'addon', th))
    end
    j.keys = {keyId = e2e.key_id(th), code = e2e.safety_code(th), lineKey = k.lineKey, lineNonce = k.lineNonce,
              sendKey = k.sendKey, recoverKey = k.recoverKey, A = kx.A, B = data.B, kxId = kx.kxId,
              mac = e2e.b64url(e2e.confirm_mac(k.confirmKey, th)), rmac = rmac, acked = false,
              doneMac = e2e.b64url(e2e.done_mac(k.confirmKey, th))}
    j.stage = 'commit'
  elseif j.stage == 'commit' then
    s.keys = j.keys
    s.kx, s.reveal = nil, nil
    write_keyfile()
    pool:stop()
    log('encryption on. Safety code: ' .. j.keys.code .. '. The app shows the same code in Settings, under Encryption.')
    send_confirm()
    j.stage = 'settle'
  else
    s.job = nil
    local k = j.keys
    set_recovery(k.keyId, e2e.b64url(k.recoverKey))
    settings.e2e_account = settings.account_id
    save()
    mark_e2e()
  end
end

local FINISH = {keys = true, proofs = true, commit = true, settle = true}

-- Every prerender: one step of the job, or the pool asked again for a key.
local function pump_job()
  local s = app.e2e
  local j = s.job
  if not j then return make_key() end
  if j.stage == 'settle' then return finish_stage(j) end
  if s.kx ~= j.kx or s.keys then
    s.job = nil
    return
  end
  if FINISH[j.stage] then return finish_stage(j) end
  if j.stage == 'save' then
    write_keyfile()
    return start_job('A', j.kx)
  end
  local result = j.job:step(e2e.STEPS)
  if result == nil then return end
  s.job = nil
  if j.stage == 's' then
    if not result then
      forget_exchange()
      return abort(j.kx.kxId, 'bad key')
    end
    s.job = {stage = 'keys', kx = j.kx, data = j.data, job = e2e.derive_job(result, j.data.th)}
    s.job.job.ladder_done = 255
    return
  end
  j.kx.A = result
  if s.reveal and s.reveal.kxId == j.kx.kxId then return begin_shared(s.reveal) end
  send_key(j.kx)
end

local function on_commit(frame)
  local s = app.e2e
  local h = bytes_of(frame.h, 32)
  if not h or (frame.recover ~= nil and not is_key_id(frame.recover)) then return end
  if s.keys then return abort(frame.id, 'already set up') end
  local recover_id = recovery()
  if recover_id and frame.recover ~= recover_id then return abort(frame.id, 'recovery required', recover_id) end
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
  if (s.job and s.job.kx == kx and (s.job.stage == 's' or FINISH[s.job.stage])) or s.reveal then return end -- being worked on
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

-- The socket URL: the character, whether this addon can encrypt, its key
-- id, and the key id of the recovery key it holds when it has no keys; then
-- that it can share yells, and the character's world when the game says a
-- retail one (asked again for each socket).
local function socket_url()
  local url = RELAY_URL .. '/v1/ws?role=addon&character=' .. CHAR
  if pool then
    local s = app.e2e
    local recover = (not s.keys and recovery()) or ''
    url = url .. '&e2e=1&key=' .. (s.keys and s.keys.keyId or '') .. '&recover=' .. recover
  end
  local info = windower.ffxi.get_info and windower.ffxi.get_info()
  app.world = yells.world_name(type(info) == 'table' and info.server or nil)
  return url .. '&blacklist=1&yells=1' .. (app.world and ('&world=' .. app.world) or '')
end

-- The blacklist frame, the character's whole list, to the relay while the
-- socket is open (after the hello, while the list is known).
function black.send()
  local names = app.blacklist.names
  if not (names and app.state == 'open' and app.client) then return end
  local quoted = {}
  for i, name in ipairs(names) do quoted[i] = json.encode(name) end
  app.client:send_text('{"type":"blacklist","names":[' .. table.concat(quoted, ',') .. ']}')
end

-- What came of the relay's blacklist_add for `name`, while the socket is open.
function black.send_result(name, ok, reason)
  if not (app.state == 'open' and app.client) then return end
  app.client:send_text(encode_fields{{'type', 'blacklist_add_result'}, {'name', name}, {'ok', ok}, {'reason', reason}})
end

-- A /blacklist add the relay asked for, answered: its name as the relay gave it.
function black.answer(key, ok)
  local ask = app.blacklist.waiting[key]
  if not ask then return end
  app.blacklist.waiting[key] = nil
  black.send_result(ask.name, ok)
end

-- The list now: kept in the settings and sent whole when it changed.
function black.set(names)
  app.blacklist.names = names
  local text = 'list:' .. table.concat(names, ',')
  if settings.blacklist == text then return end
  settings.blacklist = text
  save()
  black.send()
end

-- 0x041, one part of the game's list: the first part starts it again, the
-- last makes it the list. A part with no first part before it since this
-- load is not a list. A name typed for the relay that the list now holds is
-- answered.
function black.on_part(data)
  local part = yells.parse_blacklist(data)
  if not part then return end
  local bl = app.blacklist
  if part.first then bl.building = {} end
  if not bl.building then return end
  for _, name in ipairs(part.names) do
    if #bl.building < yells.BLACKLIST_MAX then bl.building[#bl.building + 1] = name end
  end
  if not part.last then return end
  local names = bl.building
  bl.building = nil
  black.set(names)
  for _, name in ipairs(names) do black.answer(name:lower(), true) end
end

-- 0x042, a name added to the game's list or removed from it: the list
-- changes, when it is known, and the add answers the relay's ask for it.
-- While the list is not known (no zone-in since the addon first ran), an
-- add nobody asked for still goes to the relay as a confirmed add, so the
-- name is on this character's blacklist there at once.
function black.on_edit(data)
  local edit = yells.parse_blacklist_edit(data)
  if not edit then return end
  local bl, key = app.blacklist, edit.name:lower()
  if bl.names then
    local names, found = {}, false
    for _, name in ipairs(bl.names) do
      if name:lower() == key then found = true end
      if edit.add or name:lower() ~= key then names[#names + 1] = name end
    end
    if edit.add and not found and #names < yells.BLACKLIST_MAX then names[#names + 1] = edit.name end
    black.set(names)
  end
  if not edit.add then return end
  if bl.waiting[key] then black.answer(key, true)
  elseif not bl.names then black.send_result(edit.name, true) end
end

-- The relay's blacklist_add (the app blacklisted a yell's sender): a name on
-- the list already is ok at once, and a list that holds BLACKLIST_MAX names
-- is full; neither types anything. Otherwise /blacklist add, and the game's
-- add (0x042) answers it. A name that is no name is not typed.
function black.on_add(frame)
  local name = frame.name
  if not black.is_name(name) then return end
  local bl, key = app.blacklist, name:lower()
  if bl.names then
    for _, listed in ipairs(bl.names) do
      if listed:lower() == key then return black.send_result(name, true) end
    end
    if #bl.names >= yells.BLACKLIST_MAX then return black.send_result(name, false, 'full') end
  end
  bl.waiting[key] = {name = name, deadline = now() + black.WAIT}
  windower.send_command('input /blacklist add ' .. name)
end

-- A /blacklist add the game has not made in black.WAIT is answered not ok.
function black.pump(t)
  for key, ask in pairs(app.blacklist.waiting) do
    if t >= ask.deadline then black.answer(key, false) end
  end
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

-- The bag slot ('bag:slot') of slot n's item, as the game last said it (or
-- the settings saved it), or nil.
local function slot_key(n)
  for key, m in pairs(app.ls.equips) do
    if m == n then return key end
  end
  return nil
end

-- What the game has said is in each slot: {ls1 =, ls2 =}, each a linkshell
-- name, false (no shell) or nil (not said). A slot with a kept name has that
-- name. A slot whose item is in a bag that has not loaded is not said. A slot
-- whose item the game named has no shell once that bag has loaded and the
-- read shows no shell there. Any other slot (one whose item only the saved
-- settings name, say) has the read's shell once the game has said where its
-- shells are, unless the game named that shell in the other slot.
local LS_SLOTS = {'ls1', 'ls2'}
local function said_names()
  local ls = app.ls
  local out = {}
  for n, channel in ipairs(LS_SLOTS) do
    local key = slot_key(n)
    if ls.named[n] then
      out[channel] = ls.named[n]
    elseif key and ls.loaded[tonumber(key:match('^(%d+)'))] ~= true then
      -- Its item's bag has not loaded: not said.
    elseif key and ls.said[n] then
      local held = false
      for _, f in ipairs(ls.found or {}) do
        if f.key == key then held = true end
      end
      if not held then out[channel] = false end
    elseif ls.current and ls.known then
      local shell = ls.current[channel]
      local name = shell and shell.name or false
      if name and name == ls.named[3 - n] then name = nil end
      out[channel] = name
    end
  end
  return out
end

-- ls1 and ls2 frames name the shell the game said is in that slot, or null
-- when it has not said: a line is never named by a guess. Party lines are
-- group lines like linkshell lines (a sender, a null target) but, like
-- tells, have no linkshell key. The first line sent with no name while
-- shells are equipped, or before the first read after load or login, is
-- remembered by its time (ts, in ms): once the game says where those shells
-- are, the relay is told to name the lines from that time on.
local function linkshell_name(channel, ts)
  if channel ~= 'ls1' and channel ~= 'ls2' then return nil end
  local ls = app.ls
  local name = said_names()[channel]
  if name then return name end
  -- A line on ls1 or ls2 means the game has a shell in that slot, so a line
  -- sent with no name is always remembered for the rename, even when a read
  -- said no shell (a slot whose saved bag slot is stale).
  if not ls.unnamed_from then ls.unnamed_from = ts end
  return NULL
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
-- an empty queue removes it, and any queue.json.tmp a failed rename left, so
-- no earlier queue is read back and sent twice. So the file holds the queue
-- as it is at the last moment. The next load reads it back and deletes it at
-- once (read_queue). This is the only time chat is written to disk.
local function write_queue()
  if #app.queue == 0 then
    os.remove(QUEUE_FILE)
    os.remove(QUEUE_FILE .. '.tmp')
    return
  end
  ensure_data_dir()
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
      local said = said_names()
      if said[channel] ~= want and said[OTHER_SLOT[channel]] ~= want then
        if ls.lookup or (not ls.known and not looked and lookup_for_send()) then
          ls.held_sends[#ls.held_sends + 1] = send
          return
        end
        if said.ls1 == nil or said.ls2 == nil then return refuse('linkshell slot not known') end
        return refuse('linkshell not equipped')
      end
      if said[channel] ~= want then
        channel = OTHER_SLOT[channel]
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
-- (linkshells.equipped), then which bags have loaded, or nil while the game
-- data cannot be read (not logged in, or the inventory not loaded yet, say).
-- Each shell's colour is kept for the slots a 0x0CC names.
local function read_linkshells()
  local ok, state, found, loaded = pcall(function()
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
    for _, f in ipairs(found) do app.ls.colors[f.shell.name] = f.shell.color end
    -- bag number -> true (loaded), false (still loading) or 'none' (not there, or turned off: it holds nothing)
    local loaded = {}
    for _, b in ipairs(linkshells.BAGS) do
      loaded[b[1]] = linkshells.bag_loaded(items, b[1]) or (linkshells.bag_absent(items, b[1]) and 'none')
    end
    return linkshells.assign(found, player, app.ls.equips), found, loaded
  end)
  if ok and state then return state, found, loaded end
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

-- b holds, in a slot an earlier read had seen, a shell a does not: the
-- shells changed. A shell missing from b is not a change, and neither is one
-- in a slot no read had seen: its bag had not loaded yet.
local function other_shells(a, b, seen)
  for _, channel in ipairs(LS_SLOTS) do
    local name = slot_name(b, channel)
    if seen[channel] and name and name ~= slot_name(a, 'ls1') and name ~= slot_name(a, 'ls2') then return true end
  end
  return false
end

-- The slots as the game has said them, with each shell's colour, or nil
-- while the game has not said what is in a slot, or a named shell's colour
-- has not been read yet.
local function said_state()
  local names, state = said_names(), {}
  for _, channel in ipairs(LS_SLOTS) do
    local name = names[channel]
    if name == nil then return nil end
    if name then
      local color = app.ls.colors[name]
      if not color then return nil end
      state[channel] = {name = name, color = color}
    end
  end
  return state
end

-- Once the game has said what is in both slots, that goes to the relay, and
-- the lines sent with no name before it are named through the frame's refile.
local function offer_said(t)
  local ls = app.ls
  local state = said_state()
  if not state then return end
  if ls.unnamed_from then
    ls.refile = math.min(ls.refile or ls.unnamed_from, ls.unnamed_from)
    ls.unnamed_from = nil
  end
  offer_linkshells(state, t)
end

-- A read of the items: it names a slot that has an item and no name yet, and
-- what the game has said goes to the relay. Lines sent with no name are
-- named then too, through the frame's refile; lines from before other shells
-- were worn keep no name.
local function settle_linkshells(state, found, loaded, t)
  local ls = app.ls
  -- A read of a bag that has not loaded is no read of a slot whose item is in
  -- it: that slot, and the shell read there before, stay as they were.
  local seen = {}
  for n, channel in ipairs(LS_SLOTS) do
    local key = slot_key(n)
    if key and loaded[tonumber(key:match('^(%d+)'))] ~= true then
      state[channel] = ls.current and ls.current[channel] or nil
      for _, f in ipairs(ls.found or {}) do
        if f.key == key then found[#found + 1] = f end
      end
      seen[channel] = ls.read[channel]
    else
      seen[channel] = true
    end
  end
  if ls.unnamed_from and ls.current and other_shells(ls.current, state, ls.read) then ls.unnamed_from = nil end
  ls.current, ls.known, ls.found, ls.loaded, ls.read = state, game_said(found), found, loaded, seen
  -- A shell read at the bag slot the game said a slot's item is in names
  -- that slot when it has no name yet, and the name is kept as a 0x0CC's is.
  for _, f in ipairs(found) do
    local n = ls.equips[f.key]
    if n and ls.said[n] and not ls.named[n] then ls.named[n] = f.shell.name end
  end
  offer_said(t)
end

-- The game said where a shell is: the slots are saved and read again.
local function apply_game_slots(t)
  save_slots()
  local state, found, loaded = read_linkshells()
  if state then settle_linkshells(state, found, loaded, t) end
end

local function relaying()
  return app.state == 'open' or app.state == 'connecting' or app.state == 'waiting'
end

---------------------------------------------------------------------------
-- The lookup: asking the game which linkshell is in which slot, when no
-- linkshell message (0x0CC) has named them.
-- /lsmes shows slot 1's linkshell message and /ls2mes slot 2's, and the
-- reply (0x0CC) carries the linkshell's name. One command is asked at a
-- time, and the next only after LS_LOOKUP_WAIT, so a reply always answers
-- the one command asked; the reply packet is blocked, so nothing shows in
-- the chat log. With two shells equipped, one answer places both. A slot
-- with no shell gives no reply that names one (the game may print its own
-- line for that); a linkshell with no message set replies with its name and
-- no message. Linkshell lines wait up to
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

-- After a load, slot n has a shell: the game named a bag slot for it, two
-- shells are read, or one is read whose slot nothing has said (slot 1 is
-- asked first, slot 2 only when slot 1's reply did not come).
local function worn(n, found)
  local ls = app.ls
  for _, m in pairs(ls.equips) do
    if m == n then return true end
  end
  if #found >= 2 then return true end
  if #found == 1 and next(ls.equips) == nil then return n == 1 or not ls.messaged[1] end
  return false
end

-- Right after a load, each slot with a shell and no name from a 0x0CC is
-- asked once, alone (/lsmes for slot 1, /ls2mes for slot 2), and the reply
-- kept out of the chat log. -> true when one was asked.
local function ask_after_load(found, t)
  local ls = app.ls
  if not ls.after_load or ls.lookup or not relaying() or not windower.ffxi.get_player() then return false end
  for n = 1, 2 do
    if not ls.messaged[n] and not ls.asked[n] and worn(n, found) then
      ls.asked[n] = true
      local look = {found = found, sig = linkshells.signature(found), hold_until = t + LS_LOOKUP_HOLD, only = n}
      ls.lookup = look
      ask(look, n, t)
      return true
    end
  end
  return false
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
-- The command asked got no answer that names a shell (its wait ran out, or
-- the game answered with an error): the next is asked, or the lookup ends.
local function unanswered(look, t)
  if look.only then
    finish_lookup(t, 'silent')
    if not ask_after_load(look.found, t) then app.ls.after_load = false end
  elseif look.slot == 1 then
    ask(look, 2, t)
  else
    finish_lookup(t, 'silent')
  end
end

local function pump_lookup(t)
  local look = app.ls.lookup
  if not look then return end
  if #app.ls.held > 0 and t >= look.hold_until then release_lines() end
  if t >= look.deadline then unanswered(look, t) end
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

-- A linkshell message (0x0CC) the addon did not ask for (the game sends one
-- when a shell is equipped) names the shell in its slot: lines on that slot
-- are named by it from then on, through zone-ins, whatever bag the shell is
-- worn from and whether that bag has loaded. When the shell can be read, its
-- bag slot is placed too, and read again.
local function note_named(number, name, t)
  local ls = app.ls
  ls.named[number], ls.messaged[number] = name, true
  -- One shell is never in both slots: the game names this shell in this slot, so a name the other slot holds for it
  -- (an earlier misplacement) is dropped, and that slot is worked out again.
  if name and ls.named[3 - number] and ls.named[3 - number]:lower() == name:lower() then
    ls.named[3 - number], ls.messaged[3 - number], ls.said[3 - number] = nil, nil, nil
    for key, n in pairs(ls.equips) do if n == 3 - number then ls.equips[key] = nil end end
  end
  local state, found = read_linkshells()
  if state and linkshells.confirm(ls.equips, found, name, number) then
    ls.said[number] = true
    if #found == 2 then ls.said[3 - number] = true end
    save_slots()
    if not ls.due.message or ls.due.message < t then ls.due.message = t end
  end
  offer_said(t)
end

-- A linkshell message (0x0CC). -> true when it answers a command the addon
-- typed, so the caller blocks it.
local function on_linkshell_message(data)
  local ls, t = app.ls, now()
  local look = ls.lookup
  local number, name = linkshells.parse_message(data)
  -- An error the game gives for the command asked (a slot with no shell, a
  -- shell taken off while the addon was not running): it names nothing, and
  -- it is the addon's own, so it stays out of the log.
  if look and linkshells.message_error(data) then
    unanswered(look, t)
    return true
  end
  -- The reply to a slot asked alone after a load: it names a shell read in that slot, or its own slot index names
  -- the slot when no read shell is in it (its bag has not loaded).
  -- A message for the other slot (its own slot index says so) is not the reply to the slot asked: it names its own
  -- slot below, and never the slot asked.
  local other = number ~= nil and look ~= nil and number ~= (look.only or look.slot)
  if look and look.only and not other then
    local n = look.only
    local placed = linkshells.confirm(ls.equips, look.found, linkshells.message_names(data), n)
    local unread = #look.found < 2
    for _, f in ipairs(look.found) do
      if ls.equips[f.key] == n then unread = false end
    end
    if placed or (number == n and unread) then
      ls.said[n] = true
      if placed and #look.found == 2 then ls.said[3 - n] = true end
      if name then ls.named[n], ls.messaged[n] = name, true end
      finish_lookup(t, 'answered')
      if not ask_after_load(ls.found or {}, t) then ls.after_load = false end
      return true
    end
  elseif look and not other and linkshells.confirm(ls.equips, look.found, linkshells.message_names(data), look.slot) then
    ls.said[look.slot] = true
    if #look.found == 2 then ls.said[3 - look.slot] = true end
    -- A reply that names the slot names it for good, as one the addon did not ask for does.
    if name then ls.named[look.slot], ls.messaged[look.slot] = name, true end
    finish_lookup(t, 'answered')
    return true
  end
  if number then note_named(number, name, t) end
  return not look and t < ls.swallow_until
end

-- One shell equipped, and a linkshell line on channel: that is the slot it
-- is in. Not while an equip packet's read is pending: another shell may have
-- just been equipped, and the line may be its.
confirm_lone = function(channel)
  local ls = app.ls
  local found = ls.found
  if not (found and #found == 1) or ls.due.equip then return end
  -- Another shell may be in a bag that has not loaded yet.
  for _, b in ipairs(linkshells.BAGS) do
    if not ls.loaded[b[1]] then return end
  end
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
  local state, found, loaded = read_linkshells()
  if not state then
    ls.next_read = t + LS_RECHECK
    -- A slot the game named with a 0x0E0 is asked after a load even before the inventory can be read.
    ask_after_load({}, t)
    return
  end
  ask_after_load(found, t)
  settle_linkshells(state, found, loaded, t)
  -- Read again soon while a slot waits for its name or its shell's colour.
  ls.next_read = t + (said_state() and LS_PERIOD or LS_RECHECK)
  -- Every slot with a shell has been asked once since the load.
  if ls.after_load and not ls.lookup and not ask_after_load(found, t) then ls.after_load = false end
  -- The game has not said where these shells are: ask it, once for what is equipped.
  if not ls.known and not ls.lookup and not ls.after_load and #found > 0 and relaying()
     and linkshells.signature(found) ~= ls.looked and not (ls.named[1] and ls.named[2]) then
    start_lookup(found, t)
  end
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
  app.client, app.yells_on = nil, false
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
-- first, in order, then the linkshells. It says "yells":1 when this socket
-- is to share yells. A second hello on the same socket changes nothing.
local function on_hello(client, frame)
  if app.state == 'open' then return end
  app.yells_on = frame.yells == 1
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
  -- The new socket gets the slots as the game has said them, then a read.
  offer_said(t)
  check_linkshells(t)
  -- Then the character's blacklist, when it is known.
  black.send()
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
      mark_e2e()
    end
    on_hello(client, frame)
  elseif frame.type == 'send' then
    handle_send(client, frame)
  elseif frame.type == 'kx' then
    on_kx(frame)
  elseif frame.type == 'yells' and (frame.on == 0 or frame.on == 1) then
    -- Yells turned on or off for the account: sharing starts or stops at once.
    app.yells_on = frame.on == 1
  elseif frame.type == 'blacklist_add' then
    black.on_add(frame)
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
  -- Another character's box is updating the folder: nothing starts, and the
  -- next refusal asks again (once it is done, this box reloads into its files).
  if updater:locked() then return end
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
  app.client, app.yells_on = nil, false
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
-- Pairing: trades the code shown on the phone for this character's token.
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
  '//vt pair <code> - pair with the code shown on your device',
  '//vt status - show the connection state',
  '//vt on | //vt off - start or stop relaying',
  "//vt unpair - forget this character's relay token",
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
    body = encode_fields{{'code', code}, {'character', CHAR}},
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
  log('character: ' .. CHAR)
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
  log('yells: ' .. ((app.yells_on and app.world) and ('sharing on ' .. app.world) or 'off'))
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
  if claimed and has_credentials() then log("this PC's pairing is now " .. CHAR .. "'s.") end
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
  elseif app.switching then
    write_queue()
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
      app.client, app.yells_on = nil, false
      client:abort()
      schedule_retry('idle timeout')
    elseif app.state == 'open' and t - app.last_ping >= PING_INTERVAL then
      app.client:send_text(PING)
      app.last_ping = t
    end
  end
  black.pump(t)
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

-- A yell goes to the relay at once while this socket shares yells (the
-- relay said so and the URL named the world, as //vt status says), and is
-- otherwise dropped: never held, never written, never sealed (the server
-- reads yells, so they are not encrypted). The player's own yells too.
local function share_yell(data)
  if not (app.yells_on and app.world and app.state == 'open' and app.client) then return end
  local y = yells.parse(data)
  if not y then return end
  local hexes, names = {}, {}
  for hex in pairs(y.names) do hexes[#hexes + 1] = hex end
  table.sort(hexes)
  for i, hex in ipairs(hexes) do names[i] = json.encode(hex) .. ':' .. json.encode(y.names[hex]) end
  local head = encode_fields{{'type', 'yell'}, {'sender', y.sender}, {'zone', y.zone}, {'text', y.text}}
  app.client:send_text(head:sub(1, -2) .. ',"names":{' .. table.concat(names, ',') .. '}}')
end

windower.register_event('incoming chunk', function(id, data)
  if id == 0x0CC then
    if on_linkshell_message(data) then return true end
    return
  end
  if id ~= 0x017 or repeated(id, data) then return end
  if data:byte(5) == yells.KIND then return share_yell(data) end
  local record = chat.parse_incoming(data)
  if not record then return end
  local me = player_name()
  if me and record.sender:lower() == me:lower() then return end
  relay_line(record.channel, 'in', record.sender, NULL, record.text)
end)

-- Linkshell equip (0x0E0) and inventory finished loading (0x01D) ask for a
-- read once the game has caught up; a zone-in (0x00A) changes no slot.
windower.register_event('incoming chunk', function(id, data)
  if id == 0x0E0 then
    local player = windower.ffxi.get_player()
    -- First 0x0E0 since a reload: start from the saved slots, then apply it.
    if player and player.name and app.ls.equips_for ~= player.name and next(app.ls.equips) == nil then
      app.ls.equips = linkshells.load_equips(settings.ls_slots, player.name)
    end
    local number = linkshells.parse_equip(data)
    local function keys()
      local out = {}
      for key, n in pairs(app.ls.equips) do out[n] = key end
      return out
    end
    local before = keys()
    if linkshells.note_equip(app.ls.equips, data) then
      -- The game said where this slot's shell is: a lookup is not needed.
      app.ls.said[number] = true
      -- A shell taken off, or another item put in a slot (this one, or the one the item came from): the name kept
      -- for that slot no longer holds.
      local after = keys()
      for n = 1, 2 do
        if before[n] and before[n] ~= after[n] then app.ls.named[n], app.ls.messaged[n] = nil, nil end
      end
      finish_lookup(now(), 'cancelled')
      if player and player.name then
        app.ls.equips_for = player.name
        save_slots()
      end
      check_linkshells_in('equip', LS_EQUIP_SETTLE)
    end
  elseif id == 0x00A then
    -- A zone-in changes no slot; a reply to a command asked before it may not come.
    finish_lookup(now(), 'cancelled')
  elseif id == 0x01D then
    check_linkshells_in('inventory', LS_INVENTORY_SETTLE)
  elseif id == yells.BLACKLIST_LIST then
    -- A copy of a chunk the game sent again is the same part.
    if not repeated(id, data) then black.on_part(data) end
  elseif id == yells.BLACKLIST_EDIT then
    if not repeated(id, data) then black.on_edit(data) end
  end
end)

-- Another character logging in on this instance: its queue goes to the old
-- character's queue.json, and the addon reloads for the new one.
windower.register_event('login', function(name)
  local who = type(name) == 'string' and name ~= '' and name or player_name()
  if who and who:lower() ~= CHAR:lower() then
    write_queue()
    app.switching = true
    return reload()
  end
end)

-- Another character may log in next, with other shells in other bag slots.
windower.register_event('logout', function()
  finish_lookup(now(), 'cancelled')
  app.blacklist.building = nil
  local ls = app.ls
  ls.equips, ls.current, ls.loaded, ls.read, ls.equips_for = {}, nil, {}, {}, nil
  ls.said, ls.known, ls.found, ls.looked, ls.unnamed_from, ls.named = {}, false, nil, nil, nil, {}
  ls.messaged, ls.after_load, ls.asked = {}, false, {}
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
