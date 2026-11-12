--[[
Copyright (c) 2026, Rob Shelnutt
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of VanaTell nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]

-- WebSocket client for vanatell (RFC 6455), in plain Lua 5.1.
-- Codec: URL parsing, a byte XOR lookup table, SHA-1 (FIPS 180-4) for the
-- upgrade accept key, frame encoding and decoding, and the certificate
-- hostname check. Lua 5.1 has no bit library, so every bitwise operation is
-- built from the XOR table and arithmetic on integral doubles.
-- Transport: a non-blocking Stream (TCP connect, incremental TLS handshake,
-- buffered I/O) over an injectable `net` table, and the client's connect and
-- upgrade handshake, then the open connection: frames from the server, ping
-- replies, masked sends and the close handshake. http_post: one HTTP POST
-- over the same Stream, for pairing. Nothing blocks on the socket; each pump
-- does bounded work.
-- LuaSec ('ssl') is never required here at load time.
local socket = require('socket')
local mime = require('mime')

local floor = math.floor
local byte, char, concat = string.byte, string.char, table.concat

local ws = {}

local WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
local TWO32 = 4294967296

---------------------------------------------------------------------------
-- XOR lookup table: XOR8[a * 256 + b + 1] == a XOR b for bytes a and b.
-- Built once at load, bit by bit with arithmetic (65,536 entries).
---------------------------------------------------------------------------
local XOR8 = {}
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

-- One-character strings by byte value, so masking does no string.char calls.
local CHR = {}
for i = 0, 255 do CHR[i] = char(i) end

function ws._xor(a, b)
  return XOR8[a * 256 + b + 1]
end

---------------------------------------------------------------------------
-- 32-bit operations on integral doubles in [0, 2^32).
---------------------------------------------------------------------------
local function bxor(a, b)
  local a0, b0 = a % 256, b % 256
  a, b = (a - a0) / 256, (b - b0) / 256
  local a1, b1 = a % 256, b % 256
  a, b = (a - a1) / 256, (b - b1) / 256
  local a2, b2 = a % 256, b % 256
  local a3, b3 = (a - a2) / 256, (b - b2) / 256
  return XOR8[a0 * 256 + b0 + 1]
    + XOR8[a1 * 256 + b1 + 1] * 256
    + XOR8[a2 * 256 + b2 + 1] * 65536
    + XOR8[a3 * 256 + b3 + 1] * 16777216
end

local function band(a, b) return (a + b - bxor(a, b)) / 2 end
local function bnot(a) return 4294967295 - a end
local function rotl(x, n) return (x * 2 ^ n) % 2 ^ 32 + floor(x / 2 ^ (32 - n)) end

local function word_bytes(w)
  return char(floor(w / 16777216), floor(w / 65536) % 256, floor(w / 256) % 256, w % 256)
end

---------------------------------------------------------------------------
-- SHA-1 (FIPS 180-4). Returns the 20-byte raw digest.
---------------------------------------------------------------------------
function ws._sha1(s)
  local bits = #s * 8
  -- Pad: 0x80, zeros to 56 mod 64, then the 64-bit big-endian bit length.
  local zeros = (55 - #s) % 64
  s = s .. '\128' .. ('\0'):rep(zeros)
    .. word_bytes(floor(bits / TWO32)) .. word_bytes(bits % TWO32)

  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local w = {}
  for block = 1, #s, 64 do
    for t = 0, 15 do
      local b1, b2, b3, b4 = byte(s, block + t * 4, block + t * 4 + 3)
      w[t] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    end
    for t = 16, 79 do
      w[t] = rotl(bxor(bxor(w[t - 3], w[t - 8]), bxor(w[t - 14], w[t - 16])), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for t = 0, 79 do
      local f, k
      if t < 20 then
        f, k = bxor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif t < 40 then
        f, k = bxor(bxor(b, c), d), 0x6ED9EBA1
      elseif t < 60 then
        f, k = bxor(bxor(band(b, c), band(b, d)), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(bxor(b, c), d), 0xCA62C1D6
      end
      local temp = (rotl(a, 5) + f + e + k + w[t]) % TWO32
      a, b, c, d, e = temp, a, rotl(b, 30), c, d
    end

    h0 = (h0 + a) % TWO32
    h1 = (h1 + b) % TWO32
    h2 = (h2 + c) % TWO32
    h3 = (h3 + d) % TWO32
    h4 = (h4 + e) % TWO32
  end
  return word_bytes(h0) .. word_bytes(h1) .. word_bytes(h2) .. word_bytes(h3) .. word_bytes(h4)
end

-- mime.b64 returns nil for an empty input, and a second value; keep one string.
function ws._b64(s)
  return (mime.b64(s)) or ''
end

function ws._accept_key(key)
  return ws._b64(ws._sha1(key .. WS_GUID))
end

---------------------------------------------------------------------------
-- URL parsing.
---------------------------------------------------------------------------
local SCHEMES = {ws = {secure = false, port = 80}, http = {secure = false, port = 80},
                 wss = {secure = true, port = 443}, https = {secure = true, port = 443}}
local LOCAL_HOSTS = {localhost = true, ['127.0.0.1'] = true}

-- url -> {scheme, host, port, path, secure} | nil, err
function ws.parse_url(url)
  if type(url) ~= 'string' then return nil, 'unsupported scheme' end
  local scheme, rest = url:match('^([%a][%w%+%.%-]*)://(.*)$')
  if not scheme then return nil, 'unsupported scheme' end
  scheme = scheme:lower()
  local info = SCHEMES[scheme]
  if not info then return nil, 'unsupported scheme' end

  local authority, path = rest:match('^([^/?#]*)(.*)$')
  path = path:gsub('#.*$', '')
  if path == '' then
    path = '/'
  elseif path:sub(1, 1) == '?' then
    path = '/' .. path
  end

  if authority == '' then return nil, 'missing host' end
  if authority:find('@', 1, true) then return nil, 'invalid host' end
  local host, port_str = authority:match('^([^:]*):(.*)$')
  if not host then host = authority end
  if host == '' then return nil, 'missing host' end
  if not host:find('^[%w%.%-]+$') then return nil, 'invalid host' end
  host = host:lower()

  local port = info.port
  if port_str then
    if not port_str:find('^%d+$') then return nil, 'invalid port' end
    port = tonumber(port_str)
    if port < 1 or port > 65535 then return nil, 'invalid port' end
  end

  if not info.secure and not LOCAL_HOSTS[host] then
    return nil, 'plain ws:// and http:// are only allowed for localhost'
  end
  return {scheme = scheme, host = host, port = port, path = path, secure = info.secure}
end

---------------------------------------------------------------------------
-- Frames.
---------------------------------------------------------------------------

-- XORs payload with the 4-byte key, cycling the key from its first byte.
local function apply_mask(payload, key)
  local k = {byte(key, 1, 4)}
  local out = {}
  for i = 1, #payload do
    out[i] = CHR[XOR8[byte(payload, i) * 256 + k[(i - 1) % 4 + 1] + 1]]
  end
  return concat(out)
end

-- One frame with FIN set; masked when mask_key is a 4-byte string.
function ws._encode_frame(opcode, payload, mask_key)
  local masked = type(mask_key) == 'string' and #mask_key == 4
  local mask_bit = masked and 128 or 0
  local len = #payload
  local header
  if len < 126 then
    header = char(128 + opcode, mask_bit + len)
  elseif len <= 65535 then
    header = char(128 + opcode, mask_bit + 126, floor(len / 256), len % 256)
  else
    header = char(128 + opcode, mask_bit + 127)
      .. word_bytes(floor(len / TWO32)) .. word_bytes(len % TWO32)
  end
  if masked then
    return header .. mask_key .. apply_mask(payload, mask_key)
  end
  return header .. payload
end

-- buf -> frame, consumed | nil (need more bytes) | false, 'frame too large'
function ws._decode_frame(buf, max_len)
  local n = #buf
  if n < 2 then return nil end
  local b1, b2 = byte(buf, 1, 2)
  local masked = b2 >= 128
  local len = b2 % 128
  local pos = 3
  if len == 126 then
    if n < 4 then return nil end
    local x1, x2 = byte(buf, 3, 4)
    len, pos = x1 * 256 + x2, 5
  elseif len == 127 then
    if n < 10 then return nil end
    local h1, h2, h3, h4, l1, l2, l3, l4 = byte(buf, 3, 10)
    if h1 + h2 + h3 + h4 ~= 0 then return false, 'frame too large' end
    len, pos = ((l1 * 256 + l2) * 256 + l3) * 256 + l4, 11
  end
  if len > max_len then return false, 'frame too large' end

  local key
  if masked then
    if n < pos + 3 then return nil end
    key, pos = buf:sub(pos, pos + 3), pos + 4
  end
  local last = pos + len - 1
  if n < last then return nil end

  local payload = buf:sub(pos, last)
  if masked then payload = apply_mask(payload, key) end
  return {fin = b1 >= 128, opcode = b1 % 16, masked = masked, payload = payload}, last
end

---------------------------------------------------------------------------
-- Certificate hostname check (RFC 6125 style).
---------------------------------------------------------------------------
local function is_ipv4(host)
  return host:find('^%d+%.%d+%.%d+%.%d+$') ~= nil
end

-- pattern is a certificate name; '*.' covers exactly one left-most label.
local function dns_name_matches(pattern, host)
  if type(pattern) ~= 'string' then return false end
  pattern = pattern:lower()
  if pattern == host then return true end
  if pattern:sub(1, 2) ~= '*.' then return false end
  local dot = host:find('.', 1, true)
  return dot ~= nil and dot > 1 and host:sub(dot) == pattern:sub(2)
end

local function any_matches(list, host, match)
  if type(list) ~= 'table' then return false end
  for _, name in ipairs(list) do
    if match(name, host) then return true end
  end
  return false
end

local function exact_matches(name, host)
  return name == host
end

-- cert is a LuaSec x509 object -> true | nil, 'certificate hostname mismatch'
function ws._verify_hostname(cert, host)
  local MISMATCH = 'certificate hostname mismatch'
  if not cert or type(host) ~= 'string' then return nil, MISMATCH end
  host = host:lower()
  local ip = is_ipv4(host)

  local san = (cert:extensions() or {})['2.5.29.17']
  if san then
    local ok
    if ip then
      ok = any_matches(san.iPAddress, host, exact_matches)
    else
      ok = any_matches(san.dNSName, host, dns_name_matches)
    end
    if ok then return true end
    return nil, MISMATCH
  end

  -- No subjectAltName extension: fall back to the subject CN.
  for _, entry in ipairs(cert:subject() or {}) do
    if entry.oid == '2.5.4.3' then
      local cn = entry.value
      if ip then
        if cn == host then return true end
      elseif dns_name_matches(cn, host) then
        return true
      end
    end
  end
  return nil, MISMATCH
end

---------------------------------------------------------------------------
-- Transport: the `net` table every socket call goes through, so tests can
-- inject fakes. ws.default_net() is the real one.
---------------------------------------------------------------------------
math.randomseed(floor(socket.gettime() * 1000) % 2147483647)

local function random_bytes(n)
  local out = {}
  for i = 1, n do out[i] = CHR[math.random(0, 255)] end
  return concat(out)
end

-- ws.log(line), when set, receives the module's one-time notices.
ws.log = nil

-- TLS contexts, one per CA file: ssl.newcontext parses the whole CA bundle
-- (about 200 KB), so it runs once and every later connect reuses its
-- context. The other params never change. Stream:advance asks for SSLv3,
-- TLS 1.0 and TLS 1.1 to be turned off by option name; if the installed
-- LuaSec or OpenSSL rejects one of those names, contexts are built with
-- 'all' alone from then on, and that is logged once through ws.log.
local LEGACY_TLS_OPTIONS = {'all'}
local tls_contexts = {} -- cafile (false for none) -> LuaSec context
local legacy_tls = false

-- -> context | nil, err. A newcontext that raises is a failure too.
local function new_context(ssl, params)
  local ok, ctx, err = pcall(ssl.newcontext, params)
  if not ok then return nil, ctx end
  return ctx, err
end

local function with_legacy_options(params)
  local copy = {}
  for k, v in pairs(params) do copy[k] = v end
  copy.options = LEGACY_TLS_OPTIONS
  return copy
end

-- -> context | nil, err. A failure is not cached; the next connect tries again.
local function tls_context(ssl, params)
  local key = params.cafile or false
  if tls_contexts[key] then return tls_contexts[key] end
  local ctx, err
  if not legacy_tls then ctx, err = new_context(ssl, params) end
  if not ctx then
    local rejected = err
    ctx, err = new_context(ssl, with_legacy_options(params))
    if not ctx then return nil, err end
    if not legacy_tls then
      legacy_tls = true
      if ws.log then ws.log('tls: ' .. tostring(rejected) .. '; connecting without turning off TLS 1.0/1.1') end
    end
  end
  tls_contexts[key] = ctx
  return ctx
end

function ws.default_net()
  return {
    tcp = socket.tcp,
    select = socket.select,
    resolve = socket.dns.toip,
    -- LuaSec is loaded on first use, so plain ws:// works without it.
    wrap = function(sock, params)
      local ok, ssl = pcall(require, 'ssl')
      if not ok then return nil, 'LuaSec not available' end
      local ctx, err = tls_context(ssl, params)
      if not ctx then return nil, err end
      return ssl.wrap(sock, ctx)
    end,
    now = socket.gettime,
    random_bytes = random_bytes,
  }
end

---------------------------------------------------------------------------
-- Stream: one non-blocking TCP connection, upgraded to TLS for secure URLs,
-- with byte buffers. Each method makes at most one socket call.
--   phase 'tcp'  -> waiting for the connect to finish
--   phase 'wrap' -> connected, TLS not started yet
--   phase 'tls'  -> TLS handshake in progress
--   phase 'ready'
---------------------------------------------------------------------------
local Stream = {}
Stream.__index = Stream

local WOULD_BLOCK = {timeout = true, wantread = true, wantwrite = true}
local READ_SIZE = 16384
-- TLS 1.2 or later only (see tls_context for the fallback).
local TLS_OPTIONS = {'all', 'no_sslv3', 'no_tlsv1', 'no_tlsv1_1'}

-- DNS cache. The lookup (net.resolve, socket.dns.toip by default) is still
-- synchronous and blocks the game until it answers, so its answer is kept
-- per host for the life of the module and reused for every reconnect and
-- pairing request. A host is looked up again only when it has no entry, or
-- after MAX_CONNECT_FAILURES TCP connects in a row to the cached address
-- failed: so a cached host is looked up at most once per 3 failed attempts.
-- If that lookup fails, the cached address is used and the count restarts.
-- A host with no address yet whose lookup fails gets a negative entry: the
-- failed lookup counts as the first failure, the next two attempts fail at
-- once with the same error, and the third looks the host up again.
local MAX_CONNECT_FAILURES = 3
-- host -> {ip = address, failures = failed TCP connects in a row}
--       | {err = lookup error, failures = attempts since that lookup}
local resolved = {}

local function resolve(net, host)
  local entry = resolved[host]
  if entry and entry.failures < MAX_CONNECT_FAILURES then
    if entry.ip then return entry.ip end
    entry.failures = entry.failures + 1
    return nil, entry.err
  end
  local ip, err = net.resolve(host)
  if not ip then
    if not (entry and entry.ip) then
      resolved[host] = {err = err, failures = 1}
      return nil, err
    end
    ip = entry.ip
  end
  resolved[host] = {ip = ip, failures = 0}
  return ip
end

local function connect_failed(host)
  local entry = resolved[host]
  if entry then entry.failures = entry.failures + 1 end
end

local function connect_succeeded(host)
  local entry = resolved[host]
  if entry then entry.failures = 0 end
end

-- parsed is a ws.parse_url result -> stream | nil, err
function Stream.new(parsed, cafile, net)
  local ip, err = resolve(net, parsed.host)
  if not ip then return nil, 'resolve: ' .. tostring(err) end
  local sock
  sock, err = net.tcp()
  if not sock then return nil, 'connect: ' .. tostring(err) end
  sock:settimeout(0)
  -- 'timeout' means the connect is in progress; advance() waits for it.
  local ok
  ok, err = sock:connect(ip, parsed.port)
  if not ok and err ~= 'timeout' then
    sock:close()
    connect_failed(parsed.host)
    return nil, 'connect: ' .. tostring(err)
  end
  return setmetatable({sock = sock, host = parsed.host, secure = parsed.secure, cafile = cafile,
                       net = net, phase = 'tcp', rx = '', tx = '', eof = false}, Stream)
end

-- -> 'ready' | 'pending' | nil, err. At most one select and one dohandshake.
function Stream:advance()
  if self.phase == 'tcp' then
    local _, writable = self.net.select(nil, {self.sock}, 0)
    if not (writable and writable[self.sock]) then return 'pending' end
    if not self.sock:getpeername() then
      connect_failed(self.host)
      return nil, 'connect: connection refused'
    end
    connect_succeeded(self.host)
    self.phase = self.secure and 'wrap' or 'ready'
  end

  if self.phase == 'wrap' then
    local conn, err = self.net.wrap(self.sock, {mode = 'client', protocol = 'any', verify = 'peer',
                                                options = TLS_OPTIONS, cafile = self.cafile})
    if not conn then return nil, 'tls: ' .. tostring(err) end
    -- ssl.wrap takes over the socket's fd: from here on, only conn is used.
    self.sock = conn
    conn:settimeout(0)
    if not is_ipv4(self.host) then conn:sni(self.host) end
    self.phase = 'tls'
  end

  if self.phase == 'tls' then
    local ok, err = self.sock:dohandshake()
    if not ok then
      if err == 'wantread' or err == 'wantwrite' then return 'pending' end
      return nil, 'tls: ' .. tostring(err)
    end
    local verified, verr = ws._verify_hostname(self.sock:getpeercertificate(), self.host)
    if not verified then return nil, 'tls: ' .. verr end
    self.phase = 'ready'
  end

  return 'ready'
end

-- One send of the pending bytes; the unsent tail stays in tx.
function Stream:flush()
  if self.tx == '' then return true end
  local last, err, partial = self.sock:send(self.tx, 1)
  local sent = last or partial or 0
  if sent > 0 then self.tx = self.tx:sub(sent + 1) end
  if last or WOULD_BLOCK[err] then return true end
  return nil, err
end

-- One receive into rx; a peer close sets eof.
function Stream:read()
  local data, err, partial = self.sock:receive(READ_SIZE)
  local got = data or partial
  if got and got ~= '' then self.rx = self.rx .. got end
  if data or WOULD_BLOCK[err] then return true end
  if err == 'closed' then
    self.eof = true
    return true
  end
  return nil, err
end

-- A deadline passed. If the TCP connect never finished (on Windows a refused
-- connect looks like this too), it counts as a failed connect.
function Stream:timed_out()
  if self.phase == 'tcp' then connect_failed(self.host) end
end

function Stream:close()
  if self.closed then return end
  self.closed = true
  self.sock:close()
end

---------------------------------------------------------------------------
-- HTTP helpers shared by the upgrade and the pairing request.
---------------------------------------------------------------------------
local MAX_HEAD = 8192

-- Host header value: the port only when it is not the scheme's default.
local function host_header(parsed)
  local default_port = parsed.secure and 443 or 80
  if parsed.port == default_port then return parsed.host end
  return parsed.host .. ':' .. parsed.port
end

-- Splits the response head off buf.
-- -> head, rest | false (need more bytes) | nil, 'response headers too large'
local function split_head(buf)
  local stop = buf:find('\r\n\r\n', 1, true)
  if not stop then
    if #buf >= MAX_HEAD then return nil, 'response headers too large' end
    return false
  end
  if stop + 3 > MAX_HEAD then return nil, 'response headers too large' end
  return buf:sub(1, stop - 1), buf:sub(stop + 4)
end

-- head (status line and header lines, no final blank line)
-- -> status (number or nil), fields (lowercase names; repeats joined by ', ')
local function parse_head(head)
  local status = tonumber(head:match('^HTTP/1%.[01] (%d%d%d)'))
  local fields, first = {}, true
  for line in (head .. '\r\n'):gmatch('(.-)\r\n') do
    if first then
      first = false
    else
      local name, value = line:match('^([^:%s]+):[ \t]*(.-)[ \t]*$')
      if name then
        name = name:lower()
        fields[name] = fields[name] and (fields[name] .. ', ' .. value) or value
      end
    end
  end
  return status, fields
end

local function has_token(list, token)
  for item in (list or ''):gmatch('[^,]+') do
    if item:match('^%s*(.-)%s*$'):lower() == token then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- WebSocket client.
--   state: idle -> connecting -> open -> closing -> closed
---------------------------------------------------------------------------
local Client = {}
Client.__index = Client

local DEFAULT_CONNECT_TIMEOUT = 10
local DEFAULT_MAX_MESSAGE = 1048576
local DEFAULT_MAX_FRAMES = 20

-- Never raises; URL errors surface from connect().
function ws.new(opts)
  opts = opts or {}
  return setmetatable({
    url = opts.url,
    headers = opts.headers or {},
    cafile = opts.cafile,
    connect_timeout = opts.connect_timeout or DEFAULT_CONNECT_TIMEOUT,
    max_message = opts.max_message or DEFAULT_MAX_MESSAGE,
    net = opts.net or ws.default_net(),
    on_open = opts.on_open,
    on_message = opts.on_message,
    on_error = opts.on_error,
    on_close = opts.on_close,
    state = 'idle',
    http_status = nil,
  }, Client)
end

local function emit(self, name, ...)
  local fn = self[name]
  if fn then fn(self, ...) end
end

local function is_live(self)
  return self.state == 'open' or self.state == 'closing'
end

-- Closes the socket, if there is one, without a close frame. The client is spent.
local function close_now(self)
  if self.stream then self.stream:close() end
  self.used, self.state = true, 'closed'
end

-- A failure before open, or a dropped connection: close the socket, then
-- on_error(err) and on_close(1006, err) (1006: closed without a close frame).
local function close_abnormally(self, err)
  close_now(self)
  emit(self, 'on_error', err)
  emit(self, 'on_close', 1006, err)
end

-- -> true | nil, err. Single use; synchronous errors fire no callbacks.
function Client:connect()
  if self.used then return nil, 'already used' end
  self.used = true
  local parsed, err = ws.parse_url(self.url)
  if not parsed then
    self.state = 'closed'
    return nil, err
  end
  local stream
  stream, err = Stream.new(parsed, self.cafile, self.net)
  if not stream then
    self.state = 'closed'
    return nil, err
  end
  self.parsed, self.stream = parsed, stream
  self.deadline = self.net.now() + self.connect_timeout
  self.state = 'connecting'
  return true
end

local function upgrade_request(self)
  local lines = {
    'GET ' .. self.parsed.path .. ' HTTP/1.1',
    'Host: ' .. host_header(self.parsed),
    'Upgrade: websocket',
    'Connection: Upgrade',
    'Sec-WebSocket-Key: ' .. self.key,
    'Sec-WebSocket-Version: 13',
  }
  for _, h in ipairs(self.headers) do lines[#lines + 1] = h[1] .. ': ' .. h[2] end
  return concat(lines, '\r\n') .. '\r\n\r\n'
end

-- -> true (upgraded) | false (need more bytes) | nil, err
local function check_upgrade(self)
  local stream = self.stream
  local head, rest = split_head(stream.rx)
  if head == nil then return nil, 'handshake: ' .. rest end
  if not head then return false end
  stream.rx = rest

  local status, fields = parse_head(head)
  if not status then return nil, 'handshake: bad status line' end
  if status ~= 101 then
    self.http_status = status
    return nil, 'handshake: http ' .. status
  end
  if (fields.upgrade or ''):lower() ~= 'websocket' or not has_token(fields.connection, 'upgrade') then
    return nil, 'handshake: missing upgrade headers'
  end
  if fields['sec-websocket-accept'] ~= ws._accept_key(self.key) then
    return nil, 'handshake: bad Sec-WebSocket-Accept'
  end
  return true
end

local function io_error(err)
  if err == 'closed' then return 'connection lost' end
  return err
end

---------------------------------------------------------------------------
-- Open connection: frames from the server, replies, and the close handshake.
---------------------------------------------------------------------------
local CLOSE_TIMEOUT = 2
local MAX_CONTROL_PAYLOAD = 125

-- Every frame the client sends is masked with fresh random bytes.
local function queue_frame(self, opcode, payload)
  local stream = self.stream
  stream.tx = stream.tx .. ws._encode_frame(opcode, payload, self.net.random_bytes(4))
end

-- Close frame body: the 2-byte code, then the reason cut to fit a control frame.
local function close_body(code, reason)
  return char(floor(code / 256), code % 256) .. (reason or ''):sub(1, MAX_CONTROL_PAYLOAD - 2)
end

-- Ends a live connection: one attempt to send a close frame with body (only
-- while open; once closing, ours is already queued), then close the socket.
local function shut_down(self, body)
  if self.state == 'open' then queue_frame(self, 8, body) end
  self.stream:flush()
  close_now(self)
end

-- Protocol failure: close with code, then on_error(msg) and on_close(code, msg).
local function fail(self, code, msg)
  shut_down(self, close_body(code))
  emit(self, 'on_error', msg)
  emit(self, 'on_close', code, msg)
end

-- The server's close frame. While open, echo its code (an empty payload is
-- 1005 and is echoed empty). While closing, it answers ours, and on_close
-- reports the client's own code and reason.
local function close_received(self, payload)
  local code, reason, echo = 1005, '', ''
  if #payload >= 2 then
    code, reason, echo = byte(payload, 1) * 256 + byte(payload, 2), payload:sub(3), payload:sub(1, 2)
  end
  if self.state == 'closing' then code, reason = self.close_code, self.close_reason end
  shut_down(self, echo)
  emit(self, 'on_close', code, reason)
end

-- Acts on one decoded frame. Text goes to on_message, a ping gets a pong with
-- the same payload, binary and pong frames are ignored.
local function dispatch(self, frame)
  local op, payload = frame.opcode, frame.payload
  if frame.masked then return fail(self, 1002, 'masked frame from server') end
  if not frame.fin or op == 0 then return fail(self, 1003, 'fragmented frames not supported') end
  if (op >= 3 and op <= 7) or op >= 11 then return fail(self, 1002, 'unknown opcode') end
  if op >= 8 and #payload > MAX_CONTROL_PAYLOAD then return fail(self, 1002, 'invalid control frame') end
  if op == 1 then
    emit(self, 'on_message', payload)
  elseif op == 9 then
    queue_frame(self, 10, payload)
  elseif op == 8 then
    close_received(self, payload)
  end
end

-- Decodes and dispatches up to max_frames frames from rx, stopping once the
-- connection ends. -> count, drained (true when rx holds no complete frame)
local function process_frames(self, max_frames)
  local stream, count = self.stream, 0
  while count < max_frames and is_live(self) do
    local frame, consumed = ws._decode_frame(stream.rx, self.max_message)
    if frame == nil then return count, true end
    if not frame then
      fail(self, 1009, 'frame too large')
      break
    end
    stream.rx = stream.rx:sub(consumed + 1)
    count = count + 1
    dispatch(self, frame)
  end
  return count, false
end

-- Open or closing: one read, up to max_frames frames, one flush.
local function pump_open(self, max_frames)
  local stream = self.stream
  local read_ok, read_err = stream:read()
  local count, drained = process_frames(self, max_frames)
  if not is_live(self) then return count end
  if not read_ok then
    close_abnormally(self, io_error(read_err))
  elseif stream.eof and drained then
    close_abnormally(self, 'connection lost')
  else
    local ok, err = stream:flush()
    if not ok then
      close_abnormally(self, io_error(err))
    elseif self.state == 'closing' and self.net.now() >= self.close_deadline then
      close_now(self)
      emit(self, 'on_close', self.close_code, self.close_reason)
    end
  end
  return count
end

-- -> true | nil, 'not open' | nil, 'too large'. The next pump sends it.
function Client:send_text(str)
  if self.state ~= 'open' then return nil, 'not open' end
  if #str > self.max_message then return nil, 'too large' end
  queue_frame(self, 1, str)
  return true
end

-- Open: queue a close frame; on_close(code, reason) fires when the server's
-- close frame arrives, or after 2 s. Not open: close the socket now and fire
-- on_close(1006, 'closed by client'). Does nothing once closed.
function Client:close(code, reason)
  code, reason = code or 1000, reason or ''
  if self.state == 'open' then
    self.close_code, self.close_reason = code, reason
    self.close_deadline = self.net.now() + CLOSE_TIMEOUT
    queue_frame(self, 8, close_body(code, reason))
    self.state = 'closing'
  elseif self.state ~= 'closed' then
    close_now(self)
    emit(self, 'on_close', 1006, 'closed by client')
  end
end

-- For unload and the idle timeout: one attempt to send a close frame with
-- 1001 (going away), then close the socket. Fires no callbacks.
function Client:abort()
  if is_live(self) then
    shut_down(self, close_body(1001))
  else
    close_now(self)
  end
end

local function pump_connecting(self, max_frames)
  local stream = self.stream
  if not self.key then
    local status, err = stream:advance()
    if not status then
      close_abnormally(self, err)
      return 0
    end
    if status == 'ready' then
      self.key = ws._b64(self.net.random_bytes(16))
      stream.tx = stream.tx .. upgrade_request(self)
    end
  end

  if self.key then
    local ok, err = stream:flush()
    if ok then ok, err = stream:read() end
    if not ok then
      close_abnormally(self, io_error(err))
      return 0
    end
    local upgraded, uerr = check_upgrade(self)
    if upgraded == nil then
      close_abnormally(self, uerr)
      return 0
    end
    if upgraded then
      self.state = 'open'
      emit(self, 'on_open')
      return (process_frames(self, max_frames))
    end
    if stream.eof then
      close_abnormally(self, 'connection lost')
      return 0
    end
  end

  if self.net.now() >= self.deadline then
    stream:timed_out()
    close_abnormally(self, 'timeout')
  end
  return 0
end

-- Bounded work per call -> number of frames decoded.
function Client:pump(max_frames)
  max_frames = max_frames or DEFAULT_MAX_FRAMES
  if self.state == 'connecting' then return pump_connecting(self, max_frames) end
  if is_live(self) then return pump_open(self, max_frames) end
  return 0
end

---------------------------------------------------------------------------
-- HTTP POST: one request per connection (Connection: close), with the same
-- URL rules, Stream and TLS checks as the WebSocket client.
---------------------------------------------------------------------------
local Request = {}
Request.__index = Request

local DEFAULT_HTTP_TIMEOUT = 15
local MAX_BODY = 65536
local MAX_CHUNK_LINE = 4096
local BAD_CHUNKED = 'bad chunked encoding'

-- opts: url (http:// or https://), body, headers ({name, value} pairs),
-- cafile, timeout (seconds, default 15), net, on_done(status, body) and
-- on_error(err). -> request | nil, err. A synchronous failure (URL, resolve
-- or connect) fires no callbacks; otherwise exactly one callback fires,
-- unless cancel() comes first.
function ws.http_post(opts)
  local parsed, err = ws.parse_url(opts.url)
  if not parsed then return nil, err end
  if parsed.scheme ~= 'http' and parsed.scheme ~= 'https' then return nil, 'unsupported scheme' end
  local net = opts.net or ws.default_net()
  local stream
  stream, err = Stream.new(parsed, opts.cafile, net)
  if not stream then return nil, err end
  return setmetatable({
    parsed = parsed,
    body = opts.body or '',
    headers = opts.headers or {},
    net = net,
    stream = stream,
    deadline = net.now() + (opts.timeout or DEFAULT_HTTP_TIMEOUT),
    on_done = opts.on_done,
    on_error = opts.on_error,
    done = false,
  }, Request)
end

local function post_request(self)
  local lines = {
    'POST ' .. self.parsed.path .. ' HTTP/1.1',
    'Host: ' .. host_header(self.parsed),
    'Content-Type: application/json',
    'Content-Length: ' .. #self.body,
    'Connection: close',
  }
  for _, h in ipairs(self.headers) do lines[#lines + 1] = h[1] .. ': ' .. h[2] end
  return concat(lines, '\r\n') .. '\r\n\r\n' .. self.body
end

-- Reads the status line and headers off rx and picks the body framing:
-- Content-Length, else chunked, else until EOF.
-- -> true | false (need more bytes) | nil, err
local function read_head(self)
  local stream = self.stream
  local head, rest = split_head(stream.rx)
  if head == nil then return nil, rest end
  if not head then return false end
  stream.rx = rest

  local status, fields = parse_head(head)
  if not status then return nil, 'bad status line' end
  local length = fields['content-length']
  if length then
    if not length:find('^%d+$') then return nil, 'bad Content-Length' end
    length = tonumber(length)
    if length > MAX_BODY then return nil, 'response too large' end
    self.framing, self.length = 'length', length
  elseif has_token(fields['transfer-encoding'], 'chunked') then
    self.framing, self.chunk_phase, self.chunks, self.received = 'chunked', 'size', {}, 0
  else
    self.framing = 'eof'
  end
  self.status = status
  return true
end

-- One step of the chunked decoder at position pos of rx: a size line, one
-- chunk's data and its CRLF, or a trailer line.
-- -> next position | false (need more bytes) | nil, err
local function chunk_step(self, rx, pos)
  if self.chunk_phase == 'data' then
    local stop = pos + self.chunk_left
    if #rx < stop + 1 then return false end
    if rx:sub(stop, stop + 1) ~= '\r\n' then return nil, BAD_CHUNKED end
    self.chunks[#self.chunks + 1] = rx:sub(pos, stop - 1)
    self.chunk_phase = 'size'
    return stop + 2
  end

  local eol = rx:find('\r\n', pos, true)
  if (eol or #rx + 1) - pos > MAX_CHUNK_LINE then return nil, BAD_CHUNKED end
  if not eol then return false end
  local line = rx:sub(pos, eol - 1)
  if self.chunk_phase == 'trailer' then
    if line == '' then self.chunk_phase = 'done' end
  else
    local hex = line:match('^(%x+)[ \t]*;') or line:match('^(%x+)[ \t]*$')
    if not hex then return nil, BAD_CHUNKED end
    local size = tonumber(hex, 16)
    if size == 0 then
      self.chunk_phase = 'trailer'
    elseif self.received + size > MAX_BODY then
      return nil, 'response too large'
    else
      self.chunk_phase, self.chunk_left, self.received = 'data', size, self.received + size
    end
  end
  return eol + 2
end

-- Decodes the complete chunks in rx and drops the bytes it used.
-- -> true (last chunk and trailer read) | false (need more bytes) | nil, err
local function read_chunks(self)
  local stream, pos = self.stream, 1
  while self.chunk_phase ~= 'done' do
    local next_pos, err = chunk_step(self, stream.rx, pos)
    if next_pos == nil then return nil, err end
    if not next_pos then break end
    pos = next_pos
  end
  stream.rx = stream.rx:sub(pos)
  return self.chunk_phase == 'done'
end

-- -> body (the response is complete) | false (need more bytes) | nil, err
local function read_response(self)
  if not self.status then
    local ok, err = read_head(self)
    if not ok then return ok, err end
  end
  local stream = self.stream
  if self.framing == 'length' then
    if #stream.rx >= self.length then return stream.rx:sub(1, self.length) end
    return false
  end
  if self.framing == 'chunked' then
    local ok, err = read_chunks(self)
    if ok then return concat(self.chunks) end
    return ok, err
  end
  if #stream.rx > MAX_BODY then return nil, 'response too large' end
  if stream.eof then return stream.rx end
  return false
end

-- Marks the request done, closes the socket and fires the named callback.
local function finish(self, name, ...)
  self.done = true
  self.stream:close()
  local fn = self[name]
  if fn then fn(...) end
  return true
end

-- Bounded work per call: at most one connect check or TLS step, one send and
-- one receive. -> true once finished; later calls do nothing.
function Request:pump()
  if self.done then return true end
  local stream = self.stream
  if not self.queued then
    local status, err = stream:advance()
    if not status then return finish(self, 'on_error', err) end
    if status == 'ready' then
      stream.tx = post_request(self)
      self.queued = true
    end
  end

  if self.queued then
    local ok, err = stream:flush()
    if ok then ok, err = stream:read() end
    if not ok then return finish(self, 'on_error', io_error(err)) end
    local body
    body, err = read_response(self)
    if body then return finish(self, 'on_done', self.status, body) end
    if body == nil then return finish(self, 'on_error', err) end
    if stream.eof then return finish(self, 'on_error', 'connection lost') end
  end

  if self.net.now() >= self.deadline then
    stream:timed_out()
    return finish(self, 'on_error', 'timeout')
  end
  return false
end

-- Abandons the request: closes the socket now and fires no callback. Does
-- nothing once the request has finished.
function Request:cancel()
  if self.done then return end
  self.done = true
  self.stream:close()
end

return ws
