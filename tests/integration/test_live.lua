-- tests/integration/test_live.lua: the real vanatell.lua under the stub
-- Windower, with the real ws.lua and the real clock, plus a phone client,
-- both talking to a relay on localhost. Run through
-- tests/integration/run.sh, which sets RELAY_URL and RELAY_KEY.
local socket = require('socket')
local W = require('windower_stub')
local config = require('config')
local P = require('xr_packets')

local ADDON_DIR = assert(os.getenv('XR_ADDON_DIR'), 'XR_ADDON_DIR is not set; source tests/env.sh')
local json = dofile(ADDON_DIR .. 'json.lua')
local ws = dofile(ADDON_DIR .. 'ws.lua')
local CA_FILE = ADDON_DIR .. 'cacert.pem'

local RELAY_URL = os.getenv('RELAY_URL') or 'http://localhost:8787'
local RELAY_KEY = os.getenv('RELAY_KEY')
local WS_URL = (RELAY_URL:gsub('^http', 'ws')) -- http -> ws, https -> wss

local phone             -- the phone's ws client, from step 4
local phone_texts = {}  -- every text frame the phone received, in order
local phone_frames = {} -- the same frames decoded ({} when not JSON)
local addon_frames = {} -- every frame vanatell received, decoded

local function check(cond, msg)
  if not cond then error(msg, 0) end
end

-- One loop iteration: the game's prerender (which pumps the addon), the
-- phone, then a short sleep.
local function step()
  W.fire('prerender')
  if phone then phone:pump() end
  socket.sleep(0.01)
end

-- Runs the loop until pred() returns a truthy value, which it returns.
-- Fails with label after `seconds` (default 10).
local function wait_until(pred, seconds, label)
  local deadline = socket.gettime() + (seconds or 10)
  while true do
    local value = pred()
    if value then return value end
    if socket.gettime() >= deadline then error('timed out waiting for ' .. label, 0) end
    step()
  end
end

local function run_for(seconds)
  local deadline = socket.gettime() + seconds
  while socket.gettime() < deadline do step() end
end

local function has_fields(t, want)
  if type(t) ~= 'table' then return false end
  for k, v in pairs(want) do
    if t[k] ~= v then return false end
  end
  return true
end

-- The first phone frame after index `after` (default 0) with want's fields.
local function phone_frame(want, after)
  for i = (after or 0) + 1, #phone_frames do
    if has_fields(phone_frames[i], want) then return phone_frames[i] end
  end
end

-- The record of the first phone `msg` frame after `after` with want's fields.
local function phone_msg(want, after)
  for i = (after or 0) + 1, #phone_frames do
    local f = phone_frames[i]
    if f.type == 'msg' and has_fields(f.msg, want) then return f.msg end
  end
end

local function has_command(command)
  for _, c in ipairs(W.commands or {}) do
    if c == command then return true end
  end
  return false
end

local function run()
  check(RELAY_KEY, 'RELAY_KEY is not set; run through tests/integration/run.sh')

  -- 1. Create an account, as the phone's setup screen does.
  local reply
  local req, err = ws.http_post{
    url = RELAY_URL .. '/v1/accounts',
    headers = {{'X-Relay-Key', RELAY_KEY}},
    body = '{}',
    cafile = CA_FILE,
    on_done = function(status, body) reply = {status = status, body = body} end,
    on_error = function(e) reply = {error = e} end,
  }
  check(req, 'POST /v1/accounts: ' .. tostring(err))
  wait_until(function() return req:pump() end, nil, 'POST /v1/accounts')
  check(not reply.error, 'POST /v1/accounts: ' .. tostring(reply.error))
  -- Only an error body is shown: a 2xx body holds the phone token.
  check(reply.status >= 200 and reply.status < 300,
    'POST /v1/accounts: http ' .. tostring(reply.status) .. ' ' .. tostring(reply.body))
  local ok, account = pcall(json.decode, reply.body)
  check(ok and type(account) == 'table', 'POST /v1/accounts: reply is not a JSON object')
  local phone_token, pair_code = account.phoneToken, account.pairCode
  check(type(phone_token) == 'string' and type(pair_code) == 'string',
    'POST /v1/accounts: reply has no phoneToken or pairCode')

  -- 2. Load the addon with no saved settings.
  W.install()
  config._reset()
  __vanatell_test = {on_frame = function(frame) addon_frames[#addon_frames + 1] = frame end}
  dofile(windower.addon_path .. 'vanatell.lua')
  W.fire('load')
  local app = __vanatell_test.app

  -- 3. //vt url, then //vt pair, as the owner types them.
  W.fire('addon command', 'url', WS_URL)
  W.fire('addon command', 'pair', pair_code)
  wait_until(function() return app.state == 'open' end, nil, 'the addon to connect (state open)')

  -- 4. The phone connects.
  phone = ws.new{
    url = WS_URL .. '/v1/ws?role=phone',
    headers = {{'Authorization', 'Bearer ' .. phone_token}},
    cafile = CA_FILE,
    on_message = function(_, text)
      phone_texts[#phone_texts + 1] = text
      local decoded, frame = pcall(json.decode, text)
      phone_frames[#phone_frames + 1] = (decoded and type(frame) == 'table') and frame or {}
    end,
  }
  local connected, cerr = phone:connect()
  check(connected, 'phone connect: ' .. tostring(cerr))
  wait_until(function() return phone_frame{type = 'hello', role = 'phone'} end, nil, 'the phone hello')

  -- 5. A tell arrives in game.
  local mark = #phone_frames
  W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'hello from stub'))
  wait_until(function()
    return phone_msg({channel = 'tell', direction = 'in', sender = 'Kupo', text = 'hello from stub'}, mark)
  end, nil, 'the phone to get the incoming tell')

  -- 6. The phone replies; the addon types it and acks.
  mark = #phone_frames
  phone:send_text('{"type":"send","clientId":"c-1","channel":"tell","target":"Kupo","text":"reply from phone"}')
  wait_until(function() return has_command('input /tell Kupo reply from phone') end, nil,
    'the command input /tell Kupo reply from phone')
  local reply_msg = wait_until(function() return phone_msg({clientId = 'c-1'}, mark) end, nil,
    'the phone echo of send c-1')
  wait_until(function() return phone_frame({type = 'status', id = reply_msg.id, status = 'sent'}, mark) end, nil,
    'status sent for send c-1')

  -- 7. The game's own copy of that tell is not relayed a second time.
  W.fire('outgoing chunk', 0x0B6, P.outgoing_tell('Kupo', 'reply from phone'))
  run_for(1.5)
  local copies = 0
  for _, f in ipairs(phone_frames) do
    if f.type == 'msg' and has_fields(f.msg, {text = 'reply from phone'}) then copies = copies + 1 end
  end
  check(copies == 1, 'expected exactly one msg with text reply from phone, got ' .. copies)

  -- 8. Linkshell chat typed at the keyboard.
  mark = #phone_frames
  W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, 'ls from keyboard'))
  wait_until(function()
    return phone_msg({channel = 'ls1', direction = 'out', sender = 'Me', text = 'ls from keyboard'}, mark)
  end, nil, 'the phone to get the outgoing ls1 line')

  -- 9. Outbox replay: a send made while the addon is off runs once it is back.
  mark = #phone_frames
  W.fire('addon command', 'off')
  wait_until(function() return phone_frame({type = 'addon_status', online = false}, mark) end, nil,
    'addon_status online=false after //vt off')
  mark = #phone_frames
  phone:send_text('{"type":"send","clientId":"c-2","channel":"ls1","text":"while you were away"}')
  -- The echo means the relay holds the send in its outbox before the addon returns.
  local away_msg = wait_until(function() return phone_msg({clientId = 'c-2'}, mark) end, nil,
    'the phone echo of send c-2')
  W.fire('addon command', 'on')
  wait_until(function() return has_command('input /l while you were away') end, nil,
    'the command input /l while you were away')
  wait_until(function() return phone_frame({type = 'status', id = away_msg.id, status = 'sent'}, mark) end, nil,
    'status sent for send c-2')

  -- 10. Unload takes the addon offline.
  mark = #phone_frames
  W.fire('unload')
  wait_until(function() return phone_frame({type = 'addon_status', online = false}, mark) end, nil,
    'addon_status online=false after unload')
  phone:abort()
end

local ok, err = xpcall(run, debug.traceback)
if ok then
  print('integration: ok')
  os.exit(0)
end
print('integration: FAIL ' .. tostring(err))
print('addon log:')
for _, line in ipairs(W.lines and W.chat and W.lines() or {}) do print('  ' .. line) end
print('addon commands:')
for _, command in ipairs(W.commands or {}) do print('  ' .. command) end
print('frames the addon received: ' .. #addon_frames)
print('frames the phone received:')
for _, text in ipairs(phone_texts) do print('  ' .. text) end
os.exit(1)
