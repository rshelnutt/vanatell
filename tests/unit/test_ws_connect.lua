-- tests/unit/test_ws_connect.lua
local T = require('testlib'); local FN = require('fake_net'); local H = require('xr_wshelp')
local new_client, upgraded, REQUEST, ACCEPT_OK = H.new_client, H.upgraded, H.REQUEST, H.ACCEPT_OK
T.test('plain ws to localhost opens and delivers a frame that arrived with the 101', function()
  local c, net, ev = new_client('ws://localhost:8787/v1/ws?role=addon')
  T.eq(c.state, 'idle'); T.eq(c:connect(), true); T.eq(c.state, 'connecting')
  local s = net.sockets[1]; T.eq(s.timeout, 0); T.eq(s.connected_to, {'127.0.0.1', 8787})
  c:pump(); T.eq(s.written, '')
  s.writable = true; c:pump(); T.eq(s.written, REQUEST); T.eq(#net.wraps, 0)
  s:feed(ACCEPT_OK .. '\129\31{"type":"hello","role":"addon"}')
  T.eq(c:pump(), 1); T.eq(c.state, 'open'); T.eq(ev, {'open', 'msg:{"type":"hello","role":"addon"}'})
end)
T.test('connect refused and connect timeout', function()
  local c, net, ev = new_client('ws://localhost:8787/v1/ws?role=addon'); c:connect()
  net.sockets[1].writable = true; net.sockets[1].refused = true; c:pump()
  T.eq(ev, {'error:connect: connection refused', 'close:1006:connect: connection refused'}); T.eq(c.state, 'closed'); T.ok(net.sockets[1].closed)
  c, net, ev = new_client('ws://localhost:8787/v1/ws?role=addon'); c:connect()
  net.clock = net.clock + 9.5; c:pump(); T.eq(ev, {})
  net.clock = net.clock + 0.5; c:pump(); T.eq(ev, {'error:timeout', 'close:1006:timeout'})
end)
T.test('synchronous failures return nil, err and fire no callbacks', function()
  local c, net, ev = new_client('ws://example.com/v1/ws')
  T.eq({c:connect()}, {nil, 'plain ws:// and http:// are only allowed for localhost'})
  c, net, ev = new_client('wss://nowhere.invalid/v1/ws'); net.resolve_error = 'host not found'
  T.eq({c:connect()}, {nil, 'resolve: host not found'}); T.eq(ev, {}); T.eq({c:connect()}, {nil, 'already used'})
end)
T.test('wss: TLS params, SNI, one dohandshake per pump, Host without default port', function()
  local c, net = new_client('wss://relay.example.com/v1/ws?role=addon')
  net.handshake_script = {{false, 'wantread'}, {false, 'wantwrite'}, {true}}
  c:connect(); local s = net.sockets[1]; s.writable = true; c:pump()
  T.eq(net.wraps[1].params, {mode = 'client', protocol = 'any', verify = 'peer', options = {'all', 'no_sslv3', 'no_tlsv1', 'no_tlsv1_1'},
    cafile = '/x/cacert.pem'})
  local conn = net.wraps[1].conn; T.eq(conn.sni_name, 'relay.example.com'); T.eq(conn.timeout, 0); T.eq(conn.handshake_calls, 1)
  c:pump(); T.eq(conn.handshake_calls, 2); T.eq(s.written, '')
  c:pump(); T.eq(conn.handshake_calls, 3); T.ok(s.written:find('Host: relay.example.com\r\n', 1, true))
end)
T.test('TLS failures: hostname mismatch, verify failure, missing LuaSec, no SNI for IP literals', function()
  local c, net, ev = new_client('wss://relay.example.com/v1/ws?role=addon'); net.cert = FN.cert{dns = {'other.example.com'}}
  c:connect(); net.sockets[1].writable = true; c:pump(); T.eq(ev[1], 'error:tls: certificate hostname mismatch'); T.eq(c.state, 'closed')
  c, net, ev = new_client('wss://relay.example.com/v1/ws?role=addon'); net.handshake_script = {{false, 'certificate verify failed'}}
  c:connect(); net.sockets[1].writable = true; c:pump()
  T.eq(ev, {'error:tls: certificate verify failed', 'close:1006:tls: certificate verify failed'})
  c, net, ev = new_client('wss://relay.example.com/v1/ws?role=addon'); net.wrap_error = 'LuaSec not available'
  c:connect(); net.sockets[1].writable = true; c:pump(); T.eq(ev[1], 'error:tls: LuaSec not available')
  c, net, ev = new_client('wss://127.0.0.1:8443/v1/ws'); net.cert = FN.cert{ip = {'127.0.0.1'}}
  c:connect(); net.sockets[1].writable = true; c:pump(); T.eq(net.wraps[1].conn.sni_name, nil); T.eq(ev, {})
end)
T.test('upgrade rejected with 401 exposes http_status', function()
  local c, net, ev, s = upgraded('ws://localhost:8787/v1/ws?role=addon')
  s:feed('HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n'); c:pump()
  T.eq(c.http_status, 401); T.eq(ev, {'error:handshake: http 401', 'close:1006:handshake: http 401'})
end)
T.test('bad accept, missing headers, oversized headers, split response, upgrade timeout', function()
  local c, net, ev, s = upgraded('ws://localhost:8787/v1/ws?role=addon')
  s:feed((ACCEPT_OK:gsub('s3pP', 'XXXX'))); c:pump(); T.eq(ev[1], 'error:handshake: bad Sec-WebSocket-Accept')
  c, net, ev, s = upgraded('ws://localhost:8787/v1/ws?role=addon')
  s:feed((ACCEPT_OK:gsub('Upgrade: websocket\r\n', ''))); c:pump(); T.eq(ev[1], 'error:handshake: missing upgrade headers')
  c, net, ev, s = upgraded('ws://localhost:8787/v1/ws?role=addon')
  s:feed(('x'):rep(8193)); c:pump(); T.eq(ev[1], 'error:handshake: response headers too large')
  c, net, ev, s = upgraded('ws://localhost:8787/v1/ws?role=addon')
  s:feed(ACCEPT_OK:sub(1, 20)); c:pump(); s:feed(ACCEPT_OK:sub(21, 60)); c:pump(); T.eq(c.state, 'connecting')
  s:feed(ACCEPT_OK:sub(61)); c:pump(); T.eq(c.state, 'open')
  c, net, ev, s = upgraded('ws://localhost:8787/v1/ws?role=addon'); net.clock = net.clock + 10; c:pump()
  T.eq(ev, {'error:timeout', 'close:1006:timeout'})
end)
-- Fix round 1: the blocking DNS lookup is cached per host and repeated only after 3 failed connects in a row.
T.test('DNS: one lookup per host, again only after 3 failed TCP connects in a row', function()
  local ws = T.addon('ws') -- a fresh module, so an empty cache
  local net = FN.new(); local lookups, addr, dns_down, refuse_now = 0, '192.0.2.1', false, false
  net.resolve = function() lookups = lookups + 1; if dns_down then return nil, 'host not found' end; return addr end
  local tcp = net.tcp
  net.tcp = function() local s = tcp(); if refuse_now then s.connect_result = {nil, 'connection refused'} end; return s end
  local URL = 'wss://relay.example.com/v1/ws'
  local function sock() return net.sockets[#net.sockets] end
  local function ok() local c = ws.new{url = URL, net = net}; T.eq(c:connect(), true); sock().writable = true; c:pump(); T.eq(c.state, 'connecting'); c:abort() end
  local function refused() local c = ws.new{url = URL, net = net}; c:connect(); sock().writable = true; sock().refused = true; c:pump(); T.eq(c.state, 'closed') end
  local function timed_out() local c = ws.new{url = URL, net = net}; c:connect(); net.clock = net.clock + 10; c:pump(); T.eq(c.state, 'closed') end
  local function refused_now()
    refuse_now = true; T.eq({ws.new{url = URL, net = net}:connect()}, {nil, 'connect: connection refused'}); refuse_now = false
  end
  ok(); ok(); T.eq(lookups, 1); T.eq(sock().connected_to, {'192.0.2.1', 443})
  refused(); timed_out(); ok(); refused(); timed_out(); T.eq(lookups, 1) -- a TCP connect in between resets the count
  addr = '192.0.2.2'; refused_now(); T.eq(lookups, 1); T.eq(sock().connected_to, {'192.0.2.1', 443})
  ok(); T.eq(lookups, 2); T.eq(sock().connected_to, {'192.0.2.2', 443}) -- 3 in a row: looked up again
  ok(); T.eq(lookups, 2)
  -- A failed lookup keeps the cached address and starts the count again.
  refused(); refused(); refused(); dns_down = true
  refused(); T.eq(lookups, 3); T.eq(sock().connected_to, {'192.0.2.2', 443}); refused(); refused(); T.eq(lookups, 3)
  dns_down = false; addr = '192.0.2.3'; ok(); T.eq(lookups, 4); T.eq(sock().connected_to, {'192.0.2.3', 443})
  -- TLS failing after the TCP connect is not a connect failure.
  net.handshake_script = {{false, 'certificate verify failed'}}
  for _ = 1, 4 do local c = ws.new{url = URL, net = net}; c:connect(); sock().writable = true; c:pump(); T.eq(c.state, 'closed') end
  net.handshake_script = {{true}}; ok(); T.eq(lookups, 4)
  -- Nor is a timeout after the TCP connect (a stalled TLS handshake).
  net.handshake_script = {{false, 'wantread'}, {false, 'wantread'}}
  local c = ws.new{url = URL, net = net}; c:connect(); sock().writable = true; c:pump(); net.clock = net.clock + 10; c:pump()
  T.eq(c.state, 'closed'); net.handshake_script = {{true}}
  refused(); refused(); ok(); T.eq(lookups, 4)
  -- The pairing request shares the cache, and its timeouts before TCP connects count.
  for _ = 1, 3 do
    local r = ws.http_post{url = 'https://relay.example.com/v1/pair', body = '{}', net = net}; T.eq(lookups, 4)
    net.clock = net.clock + 15; T.eq(r:pump(), true)
  end
  ok(); T.eq(lookups, 5)
  -- Each host has its own entry; with no entry, a failed lookup is still an error.
  local c = ws.new{url = 'ws://localhost:8787/v1/ws', net = net}; c:connect(); c:abort(); T.eq(lookups, 6)
  dns_down = true; T.eq({ws.new{url = 'wss://other.example.com/v1/ws', net = net}:connect()}, {nil, 'resolve: host not found'})
  T.eq({ws.new{url = 'wss://other.example.com/v1/ws', net = net}:connect()}, {nil, 'resolve: host not found'}); T.eq(lookups, 7)
end)
-- Final polish: a failed first lookup is cached, so the next two attempts fail fast and the third looks up again.
T.test('DNS: a failed first lookup fails the next two attempts fast, then is looked up again', function()
  local ws = T.addon('ws') -- a fresh module, so an empty cache
  local net = FN.new(); local lookups, err = 0, 'host not found'
  net.resolve = function() lookups = lookups + 1; if err then return nil, err end; return '192.0.2.7' end
  local URL = 'wss://relay.example.com/v1/ws'
  local function attempt() return {ws.new{url = URL, net = net}:connect()} end
  local FAILED = {nil, 'resolve: host not found'}
  T.eq(attempt(), FAILED); T.eq(lookups, 1)
  T.eq(attempt(), FAILED); T.eq(attempt(), FAILED); T.eq(lookups, 1); T.eq(#net.sockets, 0) -- no lookup, no socket
  T.eq(attempt(), FAILED); T.eq(lookups, 2) -- the third looks up again, fails, and starts a new count
  T.eq(attempt(), FAILED); T.eq(attempt(), FAILED); T.eq(lookups, 2)
  err = 'temporary failure'; T.eq(attempt(), {nil, 'resolve: temporary failure'}); T.eq(lookups, 3)
  T.eq(attempt(), {nil, 'resolve: temporary failure'}); T.eq(lookups, 3) -- the cached error is the latest one
  -- The pairing request shares the negative entry.
  T.eq({ws.http_post{url = 'https://relay.example.com/v1/pair', body = '{}', net = net}}, {nil, 'resolve: temporary failure'})
  T.eq(lookups, 3)
  -- Once the lookup answers, the address is cached as usual.
  err = nil; T.eq(attempt(), {true}); T.eq(lookups, 4); T.eq(net.sockets[1].connected_to, {'192.0.2.7', 443})
  T.eq(attempt(), {true}); T.eq(lookups, 4)
  -- Other hosts are not held back by this one's entry.
  err = 'host not found'; T.eq({ws.new{url = 'wss://other.example.com/v1/ws', net = net}:connect()}, FAILED); T.eq(lookups, 5)
end)
-- Final polish: default_net builds one TLS context per CA file and turns off
-- SSLv3, TLS 1.0 and 1.1, falling back to 'all' alone if LuaSec rejects those names.
local STRICT = {'all', 'no_sslv3', 'no_tlsv1', 'no_tlsv1_1'}
local function tls_params(cafile) return {mode = 'client', protocol = 'any', verify = 'peer', options = STRICT, cafile = cafile} end
-- Installs a fake LuaSec; newcontext(params) -> reply(params) or a new context. -> made params, wrap calls
local function fake_ssl(reply)
  local made, wrapped = {}, {}
  package.loaded.ssl = {
    newcontext = function(p)
      made[#made + 1] = p
      if reply then return reply(p) end
      return {id = #made, cafile = p.cafile, options = p.options}
    end,
    wrap = function(sock, ctx) wrapped[#wrapped + 1] = {sock = sock, ctx = ctx}; return {conn_for = sock} end,
  }
  return made, wrapped
end
T.test('default_net wrap: one TLS context per CA file, passed to ssl.wrap on every connect', function()
  local ws = T.addon('ws'); local made, wrapped = fake_ssl()
  T.eq(ws.default_net().wrap('s1', tls_params('/a.pem')), {conn_for = 's1'}); T.eq(#made, 1); T.eq(made[1], tls_params('/a.pem'))
  T.eq(ws.default_net().wrap('s2', tls_params('/a.pem')), {conn_for = 's2'}); T.eq(#made, 1)
  T.ok(wrapped[1].ctx == wrapped[2].ctx); T.eq(wrapped[2], {sock = 's2', ctx = {id = 1, cafile = '/a.pem', options = STRICT}})
  ws.default_net().wrap('s3', tls_params('/b.pem')); T.eq(#made, 2); T.eq(wrapped[3].ctx.id, 2)
  ws.default_net().wrap('s4', tls_params(nil)); ws.default_net().wrap('s5', tls_params(nil)); T.eq(#made, 3) -- no CA file has its own entry
  package.loaded.ssl = nil
end)
T.test('default_net wrap: TLS version options rejected -> built with all alone, logged once', function()
  local ws = T.addon('ws'); local logs = {}; ws.log = function(l) logs[#logs + 1] = l end
  local made, wrapped = fake_ssl(function(p)
    for _, o in ipairs(p.options) do if o == 'no_tlsv1_1' then return nil, 'invalid option (no_tlsv1_1)' end end
    return {cafile = p.cafile, options = p.options}
  end)
  T.eq(ws.default_net().wrap('s1', tls_params('/a.pem')), {conn_for = 's1'})
  T.eq(#made, 2); T.eq(made[1].options, STRICT); T.eq(made[2], {mode = 'client', protocol = 'any', verify = 'peer', options = {'all'}, cafile = '/a.pem'})
  T.eq(wrapped[1].ctx, {cafile = '/a.pem', options = {'all'}})
  T.eq(logs, {'tls: invalid option (no_tlsv1_1); connecting without turning off TLS 1.0/1.1'})
  ws.default_net().wrap('s2', tls_params('/a.pem')); T.eq(#made, 2); T.ok(wrapped[2].ctx == wrapped[1].ctx)
  -- Another CA file goes straight to 'all', with no second log line.
  ws.default_net().wrap('s3', tls_params('/b.pem')); T.eq(#made, 3); T.eq(made[3].options, {'all'}); T.eq(#logs, 1)
  T.eq(tls_params('/c.pem').options, STRICT) -- the caller's params are not changed
  package.loaded.ssl = nil
end)
T.test('default_net wrap: a newcontext that raises falls back; a failure on both is not cached', function()
  local ws = T.addon('ws'); local logs = {}; ws.log = function(l) logs[#logs + 1] = l end
  local made = fake_ssl(function(p) if #p.options > 1 then error('options must be strings') end; return {ok = true} end)
  T.eq(ws.default_net().wrap('s1', tls_params('/a.pem')), {conn_for = 's1'}); T.eq(#made, 2); T.eq(#logs, 1)
  T.ok(logs[1]:find('options must be strings; connecting without turning off TLS 1.0/1.1', 1, true), logs[1])
  ws = T.addon('ws'); logs = {}; ws.log = function(l) logs[#logs + 1] = l end
  local fail_ca = true
  made = fake_ssl(function() if fail_ca then return nil, 'error loading CA locations' end; return {ok = true} end)
  T.eq({ws.default_net().wrap('s1', tls_params('/missing.pem'))}, {nil, 'error loading CA locations'}); T.eq(#made, 2)
  T.eq({ws.default_net().wrap('s2', tls_params('/missing.pem'))}, {nil, 'error loading CA locations'}); T.eq(#made, 4)
  T.eq(logs, {}) -- both failed, so the options were not the cause
  fail_ca = false; T.eq(ws.default_net().wrap('s3', tls_params('/missing.pem')), {conn_for = 's3'}); T.eq(#made, 5); T.eq(made[5].options, STRICT)
  -- Without LuaSec, nothing changes.
  package.loaded.ssl = nil; package.preload.ssl = function() error('module not found') end
  T.eq({ws.default_net().wrap('s4', tls_params('/a.pem'))}, {nil, 'LuaSec not available'})
  package.preload.ssl = nil
end)
T.done()
