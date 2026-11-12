local T = require('testlib'); local boot = require('vt_boot')
-- Fix round 1: a stored token must be in the relay's format to count as paired,
-- so the brief's 'tok123' is padded out to one.
local PAIRED = {url = 'wss://relay.example.com', token = 'tok123' .. ('A'):rep(16) .. '.' .. ('b'):rep(43), account_id = 'acc1', enabled = true}
local function last(X) local l = X.W.lines(); return l[#l] end
T.test('unpaired load explains pairing and opens nothing', function()
  local X = boot{}; T.eq(X.app.state, 'unpaired'); T.eq(#X.F.clients, 0); T.eq(_addon.command, 'vt')
  T.eq(X.W.lines(), {'vanatell: not paired: set the relay with //vt url wss://<host>, then //vt pair <code>'})
  T.eq(boot{stored = {url = {}, token = 'x', enabled = true}}.app.state, 'unpaired')
end)
T.test('paired load connects with bearer header and bundled CA; prerender pumps', function()
  local X = boot{stored = PAIRED}; local c = X.F.clients[1]
  T.eq(c.opts.url, 'wss://relay.example.com/v1/ws?role=addon'); T.eq(c.opts.headers, {{'Authorization', 'Bearer ' .. PAIRED.token}})
  T.eq(c.opts.cafile, windower.addon_path .. 'cacert.pem'); T.eq(c.connect_calls, 1); T.eq(X.app.state, 'connecting')
  X.tick(0.016); T.eq(c.pump_calls, 1); T.eq(c.last_pump_max, 20)
  X.F.open(c); T.eq(X.app.state, 'open'); T.eq(last(X), 'vanatell: connected to relay')
end)
T.test('test_ping_and_idle_timeout', function()
  local X = boot{stored = PAIRED}; local c = X.F.clients[1]; X.F.open(c)
  X.tick(29.5); T.eq(c.sent, {}); X.tick(0.5); T.eq(c.sent, {'{"type":"ping"}'})
  X.tick(30); X.tick(29.5); T.eq(c.aborted, false); X.tick(0.5)
  T.eq(c.aborted, true); T.eq(X.app.state, 'waiting'); T.eq(last(X), 'vanatell: connection lost (idle timeout), retrying')
  X.tick(1); c = X.F.last(); X.F.open(c); X.tick(80); X.F.message(c, '{"type":"pong"}'); X.tick(80); T.eq(c.aborted, false)
end)
T.test('backoff 1 -> 60 s, reset after a stable connection, one log line per outage', function()
  local X = boot{stored = PAIRED}; local delays = {}
  for i = 1, 8 do
    X.F.drop(X.F.last(), 1006, 'connect: connection refused'); delays[i] = X.app.next_attempt - X.clock.t
    X.tick(delays[i]); T.eq(#X.F.clients, i + 1)
  end
  T.eq(delays, {1, 2, 4, 8, 16, 32, 60, 60})
  local lost = 0; for _, l in ipairs(X.W.lines()) do if l:find('connection lost', 1, true) then lost = lost + 1 end end; T.eq(lost, 1)
  local c = X.F.last(); X.F.open(c); T.eq(last(X), 'vanatell: reconnected to relay')
  X.tick(10); X.F.drop(c, 1006, 'connection lost'); T.eq(X.app.next_attempt - X.clock.t, 1)
  X.tick(1); c = X.F.last(); X.F.open(c); X.tick(5); X.F.drop(c, 1006, 'connection lost'); T.eq(X.app.next_attempt - X.clock.t, 2)
end)
T.test('test_rejected_token_stops_retrying', function()
  for _, status in ipairs({401, 403}) do
    local X = boot{stored = PAIRED}; X.F.reject(X.F.clients[1], status); T.eq(X.app.state, 'unauthorized')
    T.eq(last(X), 'vanatell: relay rejected the addon token; pair again with //vt pair <code>')
    for _ = 1, 10 do X.tick(60) end; T.eq(#X.F.clients, 1)
  end
end)
T.test('off/on persist with the all-characters save; stale callbacks ignored', function()
  local X = boot{stored = PAIRED}; local old = X.F.clients[1]; X.cmd('off')
  T.eq(old.closed, {1000, 'relay off'}); T.eq(X.config._stored.enabled, false); T.eq(X.config._saves[#X.config._saves], 'all')
  T.eq(last(X), 'vanatell: relay off'); X.F.drop(old, 1006, 'late'); X.tick(120); T.eq(#X.F.clients, 1); T.eq(X.app.state, 'disabled')
  X.cmd('on'); T.eq(X.config._stored.enabled, true); T.eq(#X.F.clients, 2); T.eq(X.app.state, 'connecting')
end)
T.test('url command validates, normalises, saves, reconnects', function()
  local X = boot{stored = PAIRED}
  X.cmd('url', 'ws://example.com'); T.eq(last(X), 'vanatell: invalid url: plain ws:// and http:// are only allowed for localhost')
  X.cmd('url', 'wss://relay.example.com/x'); T.eq(last(X), 'vanatell: invalid url: url must not include a path')
  X.cmd('url', 'https://relay.example.com'); T.eq(last(X), 'vanatell: invalid url: use wss:// (or ws://localhost for development)')
  T.eq(X.config._stored.url, 'wss://relay.example.com')
  X.cmd('url', 'wss://New.Example.com/'); T.eq(X.config._stored.url, 'wss://new.example.com')
  T.eq(last(X), 'vanatell: relay url set to wss://new.example.com'); T.eq(X.F.clients[1].closed, {1000, 'url changed'})
  T.eq(X.F.last().opts.url, 'wss://new.example.com/v1/ws?role=addon')
  X.cmd('url', 'ws://localhost:8787'); T.eq(X.config._stored.url, 'ws://localhost:8787')
end)
T.test('status never shows the token', function()
  local X = boot{stored = PAIRED}; X.F.open(X.F.clients[1]); X.cmd('status')
  local l = X.W.lines(); T.eq({l[#l - 4], l[#l - 3], l[#l - 2], l[#l - 1], l[#l]}, {'vanatell: relay url: wss://relay.example.com',
    'vanatell: paired: yes (account acc1)', 'vanatell: enabled: yes', 'vanatell: connection: connected', 'vanatell: queued: 0'})
  T.eq(table.concat(l, '\n'):find('tok123', 1, true), nil)
  X.F.drop(X.F.clients[1], 1006, 'connect: connection refused'); X.cmd('status')
  T.eq(X.W.lines()[#X.W.lines() - 1], 'vanatell: connection: retrying in 1s (connect: connection refused)')
end)
T.test('unpair clears credentials; help; unload aborts', function()
  local X = boot{stored = PAIRED}; local c = X.F.clients[1]; X.cmd('unpair')
  T.eq(X.config._stored.token, ''); T.eq(X.config._stored.account_id, ''); T.eq(c.closed, {1000, 'unpaired'})
  T.eq(X.app.state, 'unpaired'); T.eq(last(X), 'vanatell: unpaired')
  for _, args in ipairs({{'help'}, {'bogus'}, {}}) do
    local n = #X.W.lines(); X.cmd(unpack(args)); T.eq(#X.W.lines() - n, 7); T.eq(last(X), 'vanatell: //vt help - show this list')
  end
  X = boot{stored = PAIRED}; X.W.fire('unload'); T.eq(X.F.clients[1].aborted, true)
end)
-- Controller rulings: the url byte check, abort on replace, and the relay's close codes.
T.test('url rejects spaces, control and non-ASCII bytes; default ports are dropped', function()
  local X = boot{stored = PAIRED}
  for _, args in ipairs({{'wss://relay.example.com\r\nX-Evil: 1'}, {'wss://a.example.com', 'b'}, {'wss://relay.example.com/#a b'},
      {'wss://caf\195\169.example.com'}, {'wss://relay.example.com\0'}, {'wss://relay.example.com\127'}}) do
    X.cmd('url', unpack(args)); T.eq(last(X), 'vanatell: invalid url: url must be printable ASCII with no spaces')
  end
  T.eq(X.config._stored.url, 'wss://relay.example.com'); T.eq(#X.F.clients, 1)
  X.cmd('url', 'WSS://Relay.Example.com:443'); T.eq(X.config._stored.url, 'wss://relay.example.com')
  X.cmd('url', 'wss://relay.example.com:8443'); T.eq(X.config._stored.url, 'wss://relay.example.com:8443')
end)
T.test('replacing a client closes then aborts it, so nothing is left unpumped', function()
  local X = boot{stored = PAIRED}; local c1 = X.F.clients[1]; X.F.open(c1)
  X.cmd('url', 'wss://other.example.com'); T.eq(c1.closed, {1000, 'url changed'}); T.eq(c1.aborted, true); T.eq(c1.state, 'closed')
  local c2 = X.F.last(); X.cmd('off'); T.eq(c2.aborted, true)
  X.cmd('on'); local c3 = X.F.last(); X.cmd('unpair'); T.eq(c3.aborted, true); T.eq(#X.F.clients, 3)
end)
T.test('close codes 4000 and 4001 stop retrying; other codes retry; reasons are logged as ASCII', function()
  local said = {[4000] = 'vanatell: account deleted on the phone; set up the app again, then //vt pair <code>',
                [4001] = 'vanatell: relay rejected the addon token; pair again with //vt pair <code>'}
  for _, code in ipairs({4000, 4001}) do
    local X = boot{stored = PAIRED}; local c = X.F.clients[1]; X.F.open(c); X.F.drop(c, code, 'token revoked')
    T.eq(X.app.state, 'unauthorized'); T.eq(last(X), said[code])
    for _ = 1, 10 do X.tick(60) end; T.eq(#X.F.clients, 1)
    X.cmd('status'); T.eq(X.W.lines()[#X.W.lines() - 1], 'vanatell: connection: token rejected, pair again')
  end
  local X = boot{stored = PAIRED}; X.F.open(X.F.clients[1]); X.F.drop(X.F.clients[1], 4002, '')
  T.eq(X.app.state, 'waiting'); T.eq(last(X), 'vanatell: connection lost (code 4002), retrying')
  X.tick(1); T.eq(#X.F.clients, 2); X.F.open(X.F.clients[2]); X.F.drop(X.F.clients[2], 4003, 'r\195\169placed\n')
  T.eq(X.app.state, 'waiting'); T.eq(last(X), 'vanatell: connection lost (r??placed?), retrying')
end)
T.test('a synchronous connect failure counts as a disconnect', function()
  local X = boot{stored = PAIRED}; X.F.drop(X.F.clients[1], 1006, 'connect: connection refused')
  X.F.connect_error = 'resolve: host not found'; X.tick(1)
  T.eq(#X.F.clients, 2); T.eq(X.app.client, nil); T.eq(X.app.state, 'waiting'); T.eq(X.app.next_attempt - X.clock.t, 2)
  X.cmd('status'); T.eq(X.W.lines()[#X.W.lines() - 1], 'vanatell: connection: retrying in 2s (resolve: host not found)')
  X.F.connect_error = nil; X.tick(2); T.eq(X.app.state, 'connecting'); T.eq(X.app.client, X.F.last())
end)
T.test('on while connecting, open or waiting keeps the one client', function()
  local X = boot{stored = PAIRED}; X.cmd('on'); T.eq(#X.F.clients, 1); T.eq(last(X), 'vanatell: relay on')
  X.F.open(X.F.clients[1]); X.cmd('on'); T.eq(#X.F.clients, 1); T.eq(X.app.state, 'open')
  X.F.drop(X.F.clients[1], 1006, 'connection lost'); X.cmd('on'); T.eq(#X.F.clients, 1); T.eq(X.app.state, 'waiting')
end)
-- Fix round 1: a hand-edited settings file cannot put CR/LF into the Authorization header.
T.test('a stored token not in the relay format counts as not paired', function()
  local good = PAIRED.token
  for _, token in ipairs({'tok123', good .. '\r\nX-Evil: 1', good:sub(1, 22) .. '\r\n' .. good:sub(25), ' ' .. good:sub(2), good .. 'b'}) do
    local X = boot{stored = {url = 'wss://relay.example.com', token = token, account_id = 'acc1', enabled = true}}
    T.eq(X.app.state, 'unpaired'); T.eq(#X.F.clients, 0)
    T.eq(last(X), 'vanatell: not paired: set the relay with //vt url wss://<host>, then //vt pair <code>')
    X.cmd('on'); X.cmd('url', 'wss://other.example.com'); X.tick(60); T.eq(#X.F.clients, 0); T.eq(X.app.state, 'unpaired')
    X.cmd('status'); local l = X.W.lines(); T.eq({l[#l - 3], l[#l - 1]}, {'vanatell: paired: no', 'vanatell: connection: not paired'})
  end
  local X = boot{stored = PAIRED}; T.eq(X.app.state, 'connecting'); T.eq(#X.F.clients, 1)
end)
-- Final polish: ws.lua's one-time notices (a TLS options fallback) reach the game log.
T.test('ws.log writes to the game log', function()
  local X = boot{stored = PAIRED}; T.ok(X.F.log)
  X.F.log('tls: invalid option (no_tlsv1_1); connecting without turning off TLS 1.0/1.1')
  T.eq(last(X), 'vanatell: tls: invalid option (no_tlsv1_1); connecting without turning off TLS 1.0/1.1')
end)
T.done()
