-- tests/integration/fake_relay.lua: a throwaway stand-in for the relay
-- on 127.0.0.1, for tests/integration/run.sh. It speaks only the subset
-- of the protocol that test_live.lua uses, with the relay's field names. All
-- state (one account, the message records, the outbox and an id counter) is
-- in memory and is gone when the process exits, by design.
--   lua5.1 fake_relay.lua <port> <relay key>
local socket = require('socket')

local USAGE = 'usage: lua5.1 fake_relay.lua <port> <relay key>'
local ADDON_DIR = assert(os.getenv('XR_ADDON_DIR'), 'XR_ADDON_DIR is not set; source tests/env.sh')
local json = dofile(ADDON_DIR .. 'json.lua')
local ws = dofile(ADDON_DIR .. 'ws.lua')

local PORT = assert(tonumber(arg[1]), USAGE)
local RELAY_KEY = assert(arg[2], USAGE)

local ACCOUNT = {
  id = 'acct-1',
  phone_token = 'phone-tok',
  -- vanatell.lua keeps only a token of the relay's shape (22 base64url
  -- characters, a dot, then 43 more), so this one has that shape.
  addon_token = 'addon-tok-' .. ('0'):rep(12) .. '.' .. ('0'):rep(43),
  pair_code = 'K7M2Q9XA',
}
local PAIR_TTL_MS = 600000
local TICK = 0.05         -- seconds per select
local READ_SIZE = 16384
local MAX_FRAME = 65536

local REASONS = {[200] = 'OK', [401] = 'Unauthorized', [404] = 'Not Found'}

local records = {}  -- id -> message record
local outbox = {}   -- ids of phone sends with no ack yet, oldest first
local next_id = 1
local conns = {}    -- every open connection: {sock, rx, tx, kind = 'http' | 'ws', role}
local phone, addon  -- the open WebSocket connection for each role

local function now_ms()
  return math.floor(socket.gettime() * 1000)
end

---------------------------------------------------------------------------
-- Connections.
---------------------------------------------------------------------------
local function send_json(conn, value)
  conn.tx = conn.tx .. ws._encode_frame(1, json.encode(value))
end

-- One attempt to send what is queued, then the socket closes. A dropped
-- addon takes the addon offline for the phone.
local function drop(conn)
  if conn.dropped then return end
  conn.dropped = true
  if conn.tx ~= '' then conn.sock:send(conn.tx) end
  conn.sock:close()
  for i, c in ipairs(conns) do
    if c == conn then
      table.remove(conns, i)
      break
    end
  end
  if conn == phone then phone = nil end
  if conn == addon then
    addon = nil
    if phone then send_json(phone, {type = 'addon_status', online = false}) end
  end
end

-- An HTTP response with a JSON body; the connection closes once it is sent.
local function respond(conn, status, value)
  local body = json.encode(value)
  conn.tx = conn.tx .. ('HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n'
    .. 'Connection: close\r\n\r\n'):format(status, REASONS[status], #body) .. body
  conn.close_after_send = true
end

---------------------------------------------------------------------------
-- Messages.
---------------------------------------------------------------------------
local function new_record(fields)
  fields.id = next_id
  fields.ts = fields.ts or now_ms()
  next_id = next_id + 1
  records[fields.id] = fields
  return fields
end

local function send_frame(record)
  return {type = 'send', id = record.id, channel = record.channel, target = record.target, text = record.text}
end

local function phone_send(conn, f)
  local record = new_record{channel = f.channel, direction = 'out', target = f.target, text = f.text,
                            status = 'pending', clientId = f.clientId}
  send_json(conn, {type = 'msg', msg = record})
  outbox[#outbox + 1] = record.id
  if addon then send_json(addon, send_frame(record)) end
end

-- An id that is not in the outbox (already acked) is ignored.
local function addon_ack(f)
  for i, id in ipairs(outbox) do
    if id == f.id then
      table.remove(outbox, i)
      local record = records[id]
      record.status = f.ok and 'sent' or 'failed'
      if phone then
        send_json(phone, {type = 'status', id = id, status = record.status, error = (not f.ok) and f.error or nil})
      end
      return
    end
  end
end

local function addon_chat(f)
  local record = new_record{ts = f.ts, channel = f.channel, direction = f.direction, sender = f.sender,
                            target = f.target, text = f.text, status = 'delivered'}
  if phone then send_json(phone, {type = 'msg', msg = record}) end
  if addon then send_json(addon, {type = 'msg', msg = record}) end
end

local function on_text(conn, text)
  local ok, f = pcall(json.decode, text)
  if not (ok and type(f) == 'table') then return end
  if f.type == 'ping' then
    send_json(conn, {type = 'pong'})
  elseif conn.role == 'phone' and f.type == 'send' then
    phone_send(conn, f)
  elseif conn.role == 'addon' and f.type == 'ack' then
    addon_ack(f)
  elseif conn.role == 'addon' and f.type == 'chat' then
    addon_chat(f)
  end
end

---------------------------------------------------------------------------
-- HTTP routes and the WebSocket upgrade.
---------------------------------------------------------------------------
local function upgrade(conn, query, headers)
  local role = query:match('role=(%a+)')
  local expected = (role == 'phone' and ACCOUNT.phone_token) or (role == 'addon' and ACCOUNT.addon_token)
  local token = (headers['authorization'] or ''):match('^Bearer (.+)$')
  local key = headers['sec-websocket-key']
  if not (expected and token == expected and key) then
    return respond(conn, 401, {error = 'unauthorized'})
  end
  conn.tx = conn.tx .. 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
    .. 'Sec-WebSocket-Accept: ' .. ws._accept_key(key) .. '\r\n\r\n'
  conn.kind, conn.role = 'ws', role
  if role == 'addon' then
    addon = conn
    send_json(conn, {type = 'hello', role = 'addon'})
    for _, id in ipairs(outbox) do send_json(conn, send_frame(records[id])) end
    if phone then send_json(phone, {type = 'addon_status', online = true}) end
  else
    phone = conn
    send_json(conn, {type = 'hello', role = 'phone', addonOnline = addon ~= nil})
  end
end

local function route(conn, method, target, headers, body)
  local path, query = target:match('^([^?]*)%??(.*)$')
  if method == 'POST' and path == '/v1/accounts' then
    if headers['x-relay-key'] ~= RELAY_KEY then return respond(conn, 401, {error = 'bad relay key'}) end
    respond(conn, 200, {accountId = ACCOUNT.id, phoneToken = ACCOUNT.phone_token, pairCode = ACCOUNT.pair_code,
                        pairExpiresAt = now_ms() + PAIR_TTL_MS})
  elseif method == 'POST' and path == '/v1/pair' then
    local ok, req = pcall(json.decode, body)
    if not (ok and type(req) == 'table' and req.code == ACCOUNT.pair_code) then
      return respond(conn, 404, {error = 'invalid or expired code'})
    end
    respond(conn, 200, {accountId = ACCOUNT.id, addonToken = ACCOUNT.addon_token})
  elseif method == 'GET' and path == '/v1/ws' then
    upgrade(conn, query, headers)
  else
    respond(conn, 404, {error = 'not found'})
  end
end

-- Handles one complete request (head and Content-Length body) from rx.
-- -> true when it handled one
local function read_request(conn)
  local stop = conn.rx:find('\r\n\r\n', 1, true)
  if not stop then return false end
  local head = conn.rx:sub(1, stop - 1)
  local headers = {}
  for line in head:gmatch('\r\n([^\r\n]*)') do
    local name, value = line:match('^([^:]+):%s*(.-)%s*$')
    if name then headers[name:lower()] = value end
  end
  local length = tonumber(headers['content-length'] or '0') or 0
  local body_start = stop + 4
  if #conn.rx < body_start + length - 1 then return false end
  local body = conn.rx:sub(body_start, body_start + length - 1)
  conn.rx = conn.rx:sub(body_start + length)
  local method, target = head:match('^(%u+) (%S+) HTTP/1%.[01]')
  if not method then
    respond(conn, 404, {error = 'not found'})
  else
    route(conn, method, target, headers, body)
  end
  return true
end

-- Text frames go to on_text. A close frame is echoed and drops the client.
local function read_frames(conn)
  while not conn.dropped do
    local frame, consumed = ws._decode_frame(conn.rx, MAX_FRAME)
    if frame == false then return drop(conn) end
    if not frame then return end
    conn.rx = conn.rx:sub(consumed + 1)
    if frame.opcode == 8 then
      conn.tx = conn.tx .. ws._encode_frame(8, frame.payload:sub(1, 2))
      return drop(conn)
    elseif frame.opcode == 1 then
      on_text(conn, frame.payload)
    end
  end
end

-- One receive, then whatever it completed. EOF drops the client.
local function receive(conn)
  local data, err, partial = conn.sock:receive(READ_SIZE)
  local got = data or partial
  if got and got ~= '' then conn.rx = conn.rx .. got end
  if conn.kind == 'http' and not conn.close_after_send then read_request(conn) end
  if conn.kind == 'ws' then read_frames(conn) end
  if err and err ~= 'timeout' then drop(conn) end
end

local function send_pending(conn)
  if conn.tx ~= '' then
    local last, err, partial = conn.sock:send(conn.tx)
    local sent = last or partial or 0
    conn.tx = conn.tx:sub(sent + 1)
    if err and err ~= 'timeout' then return drop(conn) end
  end
  if conn.close_after_send and conn.tx == '' then drop(conn) end
end

---------------------------------------------------------------------------
-- Main loop.
---------------------------------------------------------------------------
local server = assert(socket.bind('127.0.0.1', PORT))
server:settimeout(0)
print(('fake relay listening on 127.0.0.1:%d'):format(PORT))
io.stdout:flush()

while true do
  local watch = {server}
  for _, conn in ipairs(conns) do watch[#watch + 1] = conn.sock end
  local readable = socket.select(watch, nil, TICK)
  if readable[server] then
    while true do
      local sock = server:accept()
      if not sock then break end
      sock:settimeout(0)
      conns[#conns + 1] = {sock = sock, rx = '', tx = '', kind = 'http'}
    end
  end
  for _, conn in ipairs({unpack(conns)}) do
    if readable[conn.sock] and not conn.dropped then receive(conn) end
  end
  for _, conn in ipairs({unpack(conns)}) do
    if not conn.dropped then send_pending(conn) end
  end
end
