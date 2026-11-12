-- vanatell: relays FFXI tells and linkshell chat to a phone through the relay.
-- This file holds the Windower events, the //vt commands (pairing among
-- them), the settings, the connection lifecycle (connect, ping, idle timeout
-- and reconnect with backoff), chat capture with its offline queue, and the
-- phone's send frames. All network work is pumped from prerender and never
-- blocks.
_addon.name = 'vanatell'
_addon.command = 'vt'
_addon.version = '1.0.0'

local config = require('config')

-- Tests set __vanatell_test to swap in modules and a clock. Sibling files load
-- with dofile, because Windower ships its own json and chat libraries.
local hooks = rawget(_G, '__vanatell_test') or {}
local function load_local(name) return hooks[name] or dofile(windower.addon_path .. name .. '.lua') end
local json, chat, ws = load_local('json'), load_local('chat'), load_local('ws')
local now = hooks.now or require('socket').gettime

local BACKOFF_MIN = 1      -- seconds before the first retry
local BACKOFF_MAX = 60     -- longest wait between retries
local STABLE_AFTER = 10    -- a connection open this long resets the backoff
local PING_INTERVAL = 30   -- seconds between keepalive pings
local IDLE_TIMEOUT = 90    -- silence from the relay this long means the link is dead
local MAX_FRAMES = 20      -- frames decoded per prerender

local QUEUE_MAX = 500         -- chat frames held while disconnected
local ECHO_WINDOW = 10        -- seconds a phone send waits for the game's copy of it
local EXECUTED_IDS_MAX = 200  -- send ids remembered, so a replayed id runs once
local RELAY_MESSAGE_MAX = 120 -- characters of a relay error message shown in game
local ACCOUNT_ID_MAX = 64     -- longest accountId accepted from the relay

local PING = '{"type":"ping"}'
local CA_FILE = windower.addon_path .. 'cacert.pem'

-- Saved with 'all': the default per-character save does nothing while the
-- player is not logged in.
-- Every install talks to the one VanaTell relay. //vt url overrides it for people running their own.
local DEFAULT_URL = 'wss://vanatell.rob-shelnutt.workers.dev'
local settings = config.load({url = DEFAULT_URL, token = '', account_id = '', enabled = true})
if type(settings.url) ~= 'string' or settings.url == '' then settings.url = DEFAULT_URL end

-- state: unpaired | disabled | waiting | connecting | open | unauthorized
local app = {
  state = 'unpaired',
  client = nil,        -- the live ws client; callbacks from any other are ignored
  backoff = BACKOFF_MIN,
  next_attempt = 0,    -- when waiting: the time of the next connect
  queue = {},          -- encoded chat frames held while disconnected
  queue_full = false,  -- the queue full line was logged since the last flush
  executed = {},       -- send id -> true, for the ids in executed_order
  executed_order = {}, -- the last EXECUTED_IDS_MAX executed send ids, oldest first
  echoes = {},         -- phone sends whose game copy is not mirrored back
  pairing = nil,       -- the pairing request in flight
  settings = settings,
  last_error = nil,    -- why the last connection ended
  outage = false,      -- a connection was lost and none has opened since
  opened_at = nil, last_rx = nil, last_ping = nil,
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
  return is_set(settings.url) and is_token(settings.token)
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
  windower.add_to_chat(207, 'vanatell: ' .. (line:gsub('[^ -~]', '?')))
end
ws.log = log -- ws.lua's one-time notices, such as a TLS options fallback

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

local function chat_frame(channel, direction, sender, target, text)
  return encode_fields{{'type', 'chat'}, {'channel', channel}, {'direction', direction}, {'sender', sender},
                       {'target', target}, {'text', text}, {'ts', math.floor(now() * 1000)}}
end

local function ack(client, id, ok, err)
  client:send_text(encode_fields{{'type', 'ack'}, {'id', id}, {'ok', ok}, {'error', err}})
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

-- A send frame runs at most one game command per id and is always acked;
-- the relay may replay an id after a reconnect.
local function handle_send(client, frame)
  local id = frame.id
  if not is_send_id(id) then return end
  if app.executed[id] then return ack(client, id, true) end
  if not windower.ffxi.get_player() then return ack(client, id, false, 'not logged in') end
  local command, text = chat.validate_send(frame.channel, frame.target, frame.text)
  if not command then return ack(client, id, false, text) end
  windower.send_command(command)
  remember_executed(id)
  local t = now()
  local echoes = live_echoes(t)
  echoes[#echoes + 1] = {channel = frame.channel, target = frame.channel == 'tell' and frame.target:lower() or nil,
                         text = text, expires = t + ECHO_WINDOW}
  ack(client, id, true)
end

---------------------------------------------------------------------------
-- Connection lifecycle.
---------------------------------------------------------------------------
-- Starts the wait before the next attempt. The connection lost line is
-- logged once per outage.
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
    app.outage = true
    log('connection lost (' .. reason .. '), retrying')
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

-- The held chat goes out first, in order.
local function on_open(client)
  if client ~= app.client then return end
  local queue = app.queue
  app.queue, app.queue_full = {}, false
  for _, frame in ipairs(queue) do client:send_text(frame) end
  local t = now()
  app.state = 'open'
  app.last_rx, app.last_ping, app.opened_at = t, t, t
  log(app.outage and 'reconnected to relay' or 'connected to relay')
  app.outage = false
end

local function on_message(client, text)
  if client ~= app.client then return end
  app.last_rx = now()
  local ok, frame = pcall(json.decode, text)
  if not (ok and type(frame) == 'table') then return end
  if hooks.on_frame then hooks.on_frame(frame) end
  if frame.type == 'send' then handle_send(client, frame) end
end

-- ws.lua follows every on_error with an on_close carrying the same text,
-- so the work happens in on_close.
local function on_error()
end

-- 401/403 on the upgrade, or close code 4000 (account deleted) or 4001
-- (token revoked): the token is no good, so stop until the owner pairs again.
-- Anything else reconnects with backoff.
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
  schedule_retry(reason)
end

local function connect()
  local client = ws.new{
    url = settings.url .. '/v1/ws?role=addon',
    headers = {{'Authorization', 'Bearer ' .. settings.token}},
    cafile = CA_FILE,
    on_open = on_open,
    on_message = on_message,
    on_error = on_error,
    on_close = on_close,
  }
  app.client = client
  app.state = 'connecting'
  app.opened_at = nil
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
    app.outage = false
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
  save()
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

-- -> 'scheme://host[:port]' (lowercase, default port dropped) | nil, err
local function normalise_url(raw)
  if raw:find('[^!-~]') then return nil, 'url must be printable ASCII with no spaces' end
  local parsed, err = ws.parse_url(raw)
  if not parsed then return nil, err end
  if parsed.scheme == 'http' or parsed.scheme == 'https' then
    return nil, 'use wss:// (or ws://localhost for development)'
  end
  if parsed.path ~= '/' then return nil, 'url must not include a path' end
  local port = ''
  if parsed.port ~= (parsed.secure and 443 or 80) then port = ':' .. parsed.port end
  return parsed.scheme .. '://' .. parsed.host .. port
end

local HELP = {
  'commands:',
  '//vt url <wss://host> - set the relay address',
  '//vt pair <code> - pair with the code shown on your phone',
  '//vt status - show the connection state',
  '//vt on | //vt off - start or stop relaying',
  "//vt unpair - forget this addon's relay token",
  '//vt help - show this list',
}

local function show_help()
  for _, line in ipairs(HELP) do log(line) end
end

local CONNECTION_TEXT = {open = 'connected', connecting = 'connecting', unpaired = 'not paired',
                         disabled = 'off', unauthorized = 'token rejected, pair again'}

local function connection_text()
  if app.state ~= 'waiting' then return CONNECTION_TEXT[app.state] end
  local secs = math.max(0, math.ceil(app.next_attempt - now()))
  return 'retrying in ' .. secs .. 's (' .. tostring(app.last_error) .. ')'
end

local commands = {}

-- Windower splits arguments on spaces; they are joined back so a url with a
-- space in it is rejected rather than cut short.
function commands.url(...)
  local url, err = normalise_url(table.concat({...}, ' '))
  if not url then return log('invalid url: ' .. err) end
  cancel_pairing()
  settings.url = url
  save()
  log('relay url set to ' .. url)
  if has_credentials() and is_enabled() then
    drop_client(1000, 'url changed')
    start()
  end
end

-- The request is pumped from prerender. Its callbacks do nothing once it is
-- no longer app.pairing.
function commands.pair(code)
  if not is_set(settings.url) then return log('set the relay url first: //vt url wss://<host>') end
  -- Case-insensitive, and dashes or spaces from the phone's display are dropped, as the relay does.
  -- [A-Za-z0-9] is %w without the locale.
  code = type(code) == 'string' and code:upper():gsub('[%s%-]', '') or ''
  if #code ~= 8 or not code:find('^[A-Z0-9]+$') then
    return log('pairing code must be 8 letters or digits')
  end
  if app.pairing then return log('pairing already in progress') end
  local req, err
  req, err = ws.http_post{
    url = pair_url(settings.url),
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

function commands.status()
  log('relay url: ' .. (is_set(settings.url) and settings.url or 'not set'))
  if is_token(settings.token) then
    log('paired: yes (account ' .. (is_set(settings.account_id) and settings.account_id or 'unknown') .. ')')
  else
    log('paired: no')
  end
  log('enabled: ' .. (is_enabled() and 'yes' or 'no'))
  log('connection: ' .. connection_text())
  log('queued: ' .. #app.queue)
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
  save()
  drop_client(1000, 'unpaired')
  app.queue = {}
  app.queue_full = false
  app.state = 'unpaired'
  log('unpaired')
end

commands.help = show_help

---------------------------------------------------------------------------
-- Events.
---------------------------------------------------------------------------
windower.register_event('load', start)

windower.register_event('unload', function()
  cancel_pairing()
  local client = app.client
  app.client = nil
  if client then client:abort() end
end)

windower.register_event('prerender', function()
  if app.pairing then app.pairing:pump() end
  local t = now()
  if app.state == 'waiting' and t >= app.next_attempt then connect() end
  if app.client then app.client:pump(MAX_FRAMES) end
  if app.state == 'open' then
    if t - app.last_rx >= IDLE_TIMEOUT then
      local client = app.client
      app.client = nil
      client:abort()
      schedule_retry('idle timeout')
    elseif t - app.last_ping >= PING_INTERVAL then
      app.client:send_text(PING)
      app.last_ping = t
    end
  end
end)

-- The chunk handlers return nothing, so they never block a packet.
windower.register_event('incoming chunk', function(id, data)
  if id ~= 0x017 then return end
  local record = chat.parse_incoming(data)
  if not record then return end
  local me = player_name()
  if me and record.sender:lower() == me:lower() then return end
  deliver(chat_frame(record.channel, 'in', record.sender, NULL, record.text))
end)

windower.register_event('outgoing chunk', function(id, data, modified, injected, blocked)
  if (id ~= 0x0B5 and id ~= 0x0B6) or blocked then return end
  local record = chat.parse_outgoing(id, data)
  if not record or take_echo(record) then return end
  deliver(chat_frame(record.channel, 'out', player_name() or NULL, record.target or NULL, record.text))
end)

windower.register_event('addon command', function(cmd, ...)
  local handler = commands[type(cmd) == 'string' and cmd:lower() or 'help']
  if handler then handler(...) else show_help() end
end)
