-- Fake transport for the ws.lua tests: stands in for the `net` table that
-- ws.default_net() builds from LuaSocket and LuaSec. Fake sockets follow
-- LuaSocket's non-blocking return values; a fake TLS conn shares its
-- socket's buffers and counters, so `written` and `feed` work through TLS.
--   local FN = require('fake_net'); local net = FN.new()
--   net.sockets[1].writable = true; net.sockets[1]:feed('HTTP/1.1 101 ...')
local FN = {}

-- A certificate with the two methods ws._verify_hostname reads.
--   FN.cert{dns = {'relay.example.com'}, ip = {'127.0.0.1'}, cn = 'x'}
function FN.cert(o)
  o = o or {}
  local san
  if o.dns or o.ip then san = {dNSName = o.dns, iPAddress = o.ip} end
  return {
    extensions = function() return san and {['2.5.29.17'] = san} or {} end,
    subject = function() return o.cn and {{oid = '2.5.4.3', value = o.cn}} or {} end,
  }
end

---------------------------------------------------------------------------
-- Fake socket (LuaSocket tcp object).
---------------------------------------------------------------------------
local Socket = {}
Socket.__index = Socket

local function new_socket()
  return setmetatable({
    connect_result = {nil, 'timeout'}, -- what connect() returns
    writable = false,                  -- reported writable by select
    refused = false,                   -- getpeername fails, as after a refused connect
    eof = false,                       -- peer closed once the inbox is drained
    send_limit = nil,                  -- max bytes accepted per send call
    inbox = '',                        -- bytes waiting to be received
    written = '', sends = 0, receive_calls = 0, closed = false, timeout = nil,
  }, Socket)
end

function Socket:settimeout(t)
  self.timeout = t
  return 1
end

function Socket:connect(ip, port)
  self.connected_to = {ip, port}
  return self.connect_result[1], self.connect_result[2]
end

function Socket:getpeername()
  if self.refused or not self.connected_to then return nil, 'not connected' end
  return self.connected_to[1], self.connected_to[2]
end

function Socket:feed(s)
  self.inbox = self.inbox .. s
end

-- receive(n): n bytes, or nil, 'timeout', partial when fewer are buffered,
-- or nil, 'closed' when the inbox is empty and the peer has closed.
function Socket:receive(n)
  self.receive_calls = self.receive_calls + 1
  if self.closed then return nil, 'closed' end
  if #self.inbox >= n then
    local data = self.inbox:sub(1, n)
    self.inbox = self.inbox:sub(n + 1)
    return data
  end
  if self.inbox == '' and self.eof then return nil, 'closed' end
  local partial = self.inbox
  self.inbox = ''
  return nil, 'timeout', partial
end

-- send(data, i, j): the index of the last byte sent, or nil, 'timeout',
-- last when send_limit cuts the write short.
function Socket:send(data, i, j)
  self.sends = self.sends + 1
  i, j = i or 1, j or #data
  if self.closed then return nil, 'closed', i - 1 end
  local chunk = data:sub(i, j)
  if self.send_limit and #chunk > self.send_limit then chunk = chunk:sub(1, self.send_limit) end
  self.written = self.written .. chunk
  local last = i + #chunk - 1
  if last < j then return nil, 'timeout', last end
  return last
end

function Socket:close()
  self.closed = true
  return 1
end

---------------------------------------------------------------------------
-- Fake TLS conn (LuaSec ssl object) over a fake socket.
---------------------------------------------------------------------------
local Conn = {}
Conn.__index = Conn

local function new_conn(net, sock)
  return setmetatable({net = net, sock = sock, handshake_calls = 0, sni_name = nil, timeout = nil}, Conn)
end

function Conn:settimeout(t)
  self.timeout = t
  return true
end

function Conn:sni(name)
  self.sni_name = name
  return true
end

-- Plays net.handshake_script one entry per call; true once it runs out.
function Conn:dohandshake()
  self.handshake_calls = self.handshake_calls + 1
  local step = self.net.handshake_script[self.handshake_calls] or {true}
  return step[1], step[2]
end

function Conn:getpeercertificate()
  return self.net.cert
end

function Conn:receive(n) return self.sock:receive(n) end
function Conn:send(data, i, j) return self.sock:send(data, i, j) end
function Conn:close() return self.sock:close() end

---------------------------------------------------------------------------
-- The net.
---------------------------------------------------------------------------
function FN.new()
  local net = {
    clock = 1000,
    resolve_error = nil,
    wrap_error = nil,
    handshake_script = {{true}},
    cert = FN.cert{dns = {'relay.example.com', 'localhost'}},
    sockets = {},
    wraps = {},
  }

  function net.now()
    return net.clock
  end

  function net.tcp()
    local s = new_socket()
    net.sockets[#net.sockets + 1] = s
    return s
  end

  function net.resolve(host)
    if net.resolve_error then return nil, net.resolve_error end
    if host == 'localhost' then return '127.0.0.1' end
    if host:find('^%d+%.%d+%.%d+%.%d+$') then return host end
    return '192.0.2.1'
  end

  -- Like socket.select with a zero timeout: the ready lists are keyed both
  -- by position and by socket.
  function net.select(recvt, sendt)
    local readable, writable = {}, {}
    for _, s in ipairs(sendt or {}) do
      if s.writable then
        writable[#writable + 1] = s
        writable[s] = true
      end
    end
    if #writable == 0 then return readable, writable, 'timeout' end
    return readable, writable
  end

  function net.wrap(sock, params)
    if net.wrap_error then return nil, net.wrap_error end
    local conn = new_conn(net, sock)
    net.wraps[#net.wraps + 1] = {params = params, conn = conn}
    return conn
  end

  function net.random_bytes(n)
    if n == 16 then return 'the sample nonce' end
    if n == 4 then return '\55\250\33\61' end
    return ('\0'):rep(n)
  end

  return net
end

return FN
