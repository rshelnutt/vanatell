local T = require('testlib'); local boot = require('vt_boot')
-- Fix round 1: a stored token must be in the relay's format to count as paired,
-- so the brief's 'tok123' is padded out to one.
local PAIRED = {url = 'wss://relay.example.com', token = 'tok123' .. ('A'):rep(16) .. '.' .. ('b'):rep(43), account_id = 'acc1', enabled = true}
local function last(X) local l = X.W.lines(); return l[#l] end
T.test('unpaired load explains pairing and opens nothing', function()
  local X = boot{}; T.eq(X.app.state, 'unpaired'); T.eq(#X.F.clients, 0); T.eq(_addon.command, 'vt')
  T.eq(X.W.lines(), {'vanatell: not paired: run //vt pair <code> with the code from the VanaTell app'})
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
  local l = X.W.lines(); T.eq({l[#l - 5], l[#l - 4], l[#l - 3], l[#l - 2], l[#l - 1], l[#l]}, {'vanatell: relay url: wss://relay.example.com',
    'vanatell: paired: yes (account acc1)', 'vanatell: enabled: yes', 'vanatell: connection: connected', 'vanatell: queued: 0',
    'vanatell: linkshells: unknown'})
  T.eq(table.concat(l, '\n'):find('tok123', 1, true), nil)
  X.F.drop(X.F.clients[1], 1006, 'connect: connection refused'); X.cmd('status')
  T.eq(X.W.lines()[#X.W.lines() - 2], 'vanatell: connection: retrying in 1s (connect: connection refused)')
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
    X.cmd('status'); T.eq(X.W.lines()[#X.W.lines() - 2], 'vanatell: connection: token rejected, pair again')
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
  X.cmd('status'); T.eq(X.W.lines()[#X.W.lines() - 2], 'vanatell: connection: retrying in 2s (resolve: host not found)')
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
    T.eq(last(X), 'vanatell: not paired: run //vt pair <code> with the code from the VanaTell app')
    X.cmd('on'); X.cmd('url', 'wss://other.example.com'); X.tick(60); T.eq(#X.F.clients, 0); T.eq(X.app.state, 'unpaired')
    X.cmd('status'); local l = X.W.lines(); T.eq({l[#l - 4], l[#l - 2]}, {'vanatell: paired: no', 'vanatell: connection: not paired'})
  end
  local X = boot{stored = PAIRED}; T.eq(X.app.state, 'connecting'); T.eq(#X.F.clients, 1)
end)
-- Final polish: ws.lua's one-time notices (a TLS options fallback) reach the game log.
T.test('ws.log writes to the game log', function()
  local X = boot{stored = PAIRED}; T.ok(X.F.log)
  X.F.log('tls: invalid option (no_tlsv1_1); connecting without turning off TLS 1.0/1.1')
  T.eq(last(X), 'vanatell: tls: invalid option (no_tlsv1_1); connecting without turning off TLS 1.0/1.1')
end)
-- Linkshell detection: the game data the stub hands out, and the linkshells frames sent.
local json = T.addon('json'); local P = require('xr_packets')
local function shell(name, r, g, b) return {id = 513, status = 19, decoded = {type = 'Linkshell', name = name, r = r, g = g, b = b}} end
local function kupo() return shell('KupoKnights', 168, 230, 161) end
local function mog() return shell('MogPost', 0x11, 0x22, 0x33) end
local KUPO, MOG = {name = 'KupoKnights', color = '#A8E6A1'}, {name = 'MogPost', color = '#112233'}
local function wear(X, primary, items) X.W.player.linkshell = primary; X.W.items = {[0] = items} end
local function ls_sent(c) local out = {}; for _, s in ipairs(c.sent) do if s:find('^{"type":"linkshells"') then out[#out + 1] = s end end; return out end
local function last_ls(c) local f = ls_sent(c); return json.decode(f[#f]) end
local function pong(X, c) X.F.message(c, '{"type":"pong"}') end
local function equip(X, number, slot, bag) return X.W.fire('incoming chunk', 0x0E0, P.linkshell_equip(number, slot, bag or 0)) end
T.test('linkshells go out right after open, after the held chat, with null for an empty slot; again on each new socket', function()
  local X = boot{stored = PAIRED}; wear(X, 'KupoKnights', {[1] = kupo()})
  X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'held')); local c = X.F.clients[1]; X.F.open(c)
  T.eq(#c.sent, 2); T.ok(c.sent[1]:find('"text":"held"', 1, true))
  T.ok(c.sent[2]:find('^{"type":"linkshells","ls1":{[^}]*},"ls2":null}$'), c.sent[2])
  T.eq(json.decode(c.sent[2]), {type = 'linkshells', ls1 = KUPO})
  X.F.drop(c, 1006, 'connection lost'); X.tick(1); local c2 = X.F.last(); X.F.open(c2); T.eq(c2.sent, {c.sent[2]})
  X.W.items = {[0] = {[1] = {id = 4096, count = 1, status = 0}}}; X.F.drop(c2, 1006, 'connection lost'); X.tick(2); local c3 = X.F.last(); X.F.open(c3)
  T.eq(c3.sent, {'{"type":"linkshells","ls1":null,"ls2":null}'})
end)
T.test('0x0E0 is never blocked; the read a second later is sent only when it changed', function()
  local X = boot{stored = PAIRED}; wear(X, 'KupoKnights', {[1] = kupo()}); local c = X.F.clients[1]; X.F.open(c)
  T.eq(equip(X, 1, 1), nil); X.tick(1); X.tick(5); T.eq(#ls_sent(c), 1)
  X.W.items[0][2] = mog(); equip(X, 2, 2); X.tick(0.5); T.eq(#ls_sent(c), 1); X.tick(0.5); T.eq(#ls_sent(c), 2)
  T.eq(last_ls(c), {type = 'linkshells', ls1 = KUPO, ls2 = MOG})
  -- The equips map outranks the name match: the packet puts the Kupo shell in slot 2, so MogPost is slot 1.
  X.tick(5); equip(X, 2, 1); X.tick(1); T.eq(#ls_sent(c), 3); T.eq(last_ls(c), {type = 'linkshells', ls1 = MOG, ls2 = KUPO})
  -- Junk 0x0E0 packets change nothing and ask for no read.
  X.W.items[0][2] = nil; X.tick(5); X.W.fire('incoming chunk', 0x0E0, 'short'); X.tick(1); T.eq(#ls_sent(c), 3)
end)
T.test('at most one linkshells frame per 2 s: a change inside the gap goes when it ends; a change undone in it sends nothing', function()
  local X = boot{stored = PAIRED}; wear(X, 'KupoKnights', {[1] = kupo()}); local c = X.F.clients[1]; X.F.open(c)
  X.W.items[0][2] = mog(); equip(X, 2, 2); X.tick(1); T.eq(#ls_sent(c), 1)
  X.tick(0.5); T.eq(#ls_sent(c), 1); X.tick(0.5); T.eq(#ls_sent(c), 2); T.eq(last_ls(c).ls2, MOG)
  X.W.items[0][2] = nil; equip(X, 2, 0); X.tick(1); T.eq(#ls_sent(c), 2)
  X.W.items[0][2] = mog(); equip(X, 2, 2); X.tick(1); X.tick(5); T.eq(#ls_sent(c), 2)
  -- A held change is not sent on a socket that closed; the next socket sends what is equipped then.
  X.W.items[0][2] = nil; equip(X, 2, 0); X.tick(1); T.eq(#ls_sent(c), 3)
  X.W.items[0][2] = mog(); equip(X, 2, 2); X.tick(1); T.eq(#ls_sent(c), 3); X.F.drop(c, 1006, 'connection lost')
  X.tick(0.5); X.tick(0.5); T.eq(#ls_sent(c), 3)
  local c2 = X.F.last(); T.ok(c2 ~= c); X.F.open(c2); T.eq(#c2.sent, 1); T.eq(json.decode(c2.sent[1]), {type = 'linkshells', ls1 = KUPO, ls2 = MOG})
end)
T.test('the linkshells are read every 60 s, 5 s after zone-in and 5 s after login', function()
  local X = boot{stored = PAIRED}; wear(X, 'KupoKnights', {[1] = kupo()}); local c = X.F.clients[1]; X.F.open(c)
  X.W.items[0][2] = mog(); X.tick(59.5); T.eq(#ls_sent(c), 1); X.tick(0.5); T.eq(#ls_sent(c), 2); pong(X, c)
  T.eq(X.W.fire('incoming chunk', 0x00A, P.zone_in()), nil); X.W.items[0][2] = nil
  X.tick(4.5); T.eq(#ls_sent(c), 2); X.tick(0.5); T.eq(#ls_sent(c), 3); T.eq(last_ls(c).ls2, nil)
  X.W.fire('login', 'Me'); X.W.items[0][2] = mog(); X.tick(4.5); T.eq(#ls_sent(c), 3); X.tick(0.5); T.eq(#ls_sent(c), 4)
  -- A zone-in during the 60 s wait holds the read until 5 s after it, then the 60 s count starts again.
  X.tick(57); pong(X, c); X.W.fire('incoming chunk', 0x00A, P.zone_in()); X.W.items[0][2] = nil; X.tick(3); T.eq(#ls_sent(c), 4)
  X.tick(2); T.eq(#ls_sent(c), 5); X.W.items[0][2] = mog(); X.tick(59.5); T.eq(#ls_sent(c), 5); X.tick(0.5); T.eq(#ls_sent(c), 6)
  T.eq(X.F.last(), c); T.eq(X.app.state, 'open')
end)
T.test('not logged in: nothing is read or sent; the character that logs in has its linkshells sent', function()
  local X = boot{stored = PAIRED}; X.W.player = nil; X.W.items = {[0] = {[1] = kupo()}}; local c = X.F.clients[1]; X.F.open(c)
  X.tick(30); X.tick(30.5); T.eq(ls_sent(c), {})
  X.W.player = {name = 'Me', linkshell = 'KupoKnights'}; X.W.fire('login', 'Me'); X.tick(5); T.eq(#ls_sent(c), 1); T.eq(last_ls(c).ls1, KUPO)
end)
T.test('logout forgets the equips map, so the next login places shells by name again', function()
  local X = boot{stored = PAIRED}; wear(X, 'KupoKnights', {[1] = kupo(), [2] = mog()}); local c = X.F.clients[1]; X.F.open(c)
  T.eq(last_ls(c), {type = 'linkshells', ls1 = KUPO, ls2 = MOG}); X.tick(5)
  equip(X, 2, 1); X.tick(1); T.eq(last_ls(c), {type = 'linkshells', ls1 = MOG, ls2 = KUPO}); X.tick(5)
  X.W.fire('logout', 'Me'); X.W.fire('login', 'Me'); X.tick(5); T.eq(last_ls(c), {type = 'linkshells', ls1 = KUPO, ls2 = MOG})
end)
T.test('status shows the linkshells equipped now, read on the spot', function()
  local X = boot{stored = PAIRED}; X.cmd('status'); T.eq(last(X), 'vanatell: linkshells: unknown')
  wear(X, 'KupoKnights', {[1] = kupo()}); X.cmd('status'); T.eq(last(X), 'vanatell: linkshells: 1=KupoKnights 2=(none)')
  X.W.items[0][2] = mog(); X.cmd('status'); T.eq(last(X), 'vanatell: linkshells: 1=KupoKnights 2=MogPost')
  X.W.player.linkshell = ''; X.W.items[0][2] = nil; X.cmd('status'); T.eq(last(X), 'vanatell: linkshells: 1=(none) 2=KupoKnights')
  X.W.player = nil; X.cmd('status'); T.eq(last(X), 'vanatell: linkshells: unknown'); T.eq(X.F.clients[1].sent, {})
end)
T.test('extdata that will not load: linkshells stay unknown, one log line says so, nothing is sent', function()
  local saved = package.loaded.extdata; package.loaded.extdata = nil
  package.preload.extdata = function() error('module not found') end
  local X = boot{stored = PAIRED}; wear(X, 'KupoKnights', {[1] = kupo()}); local c = X.F.clients[1]; X.F.open(c)
  X.tick(60); X.cmd('status')
  package.preload.extdata = nil; package.loaded.extdata = saved
  T.eq(ls_sent(c), {}); T.eq(last(X), 'vanatell: linkshells: unknown')
  local n = 0; for _, l in ipairs(X.W.lines()) do if l == 'vanatell: linkshell names unavailable: extdata did not load' then n = n + 1 end end; T.eq(n, 1)
end)
T.test('an inventory that has not finished loading is unreadable: nothing is sent, status says unknown, the last state stays', function()
  local X = boot{stored = PAIRED}; wear(X, 'KupoKnights', {[1] = kupo()}); local c = X.F.clients[1]; X.F.open(c); T.eq(#ls_sent(c), 1)
  X.W.fire('incoming chunk', 0x00A, P.zone_in()); X.W.items = {[0] = {max = 80, count = 0, enabled = true}}; X.tick(5)
  T.eq(#ls_sent(c), 1); X.cmd('status'); T.eq(last(X), 'vanatell: linkshells: unknown')
  X.W.fire('incoming chunk', 0x017, P.incoming_chat(5, 'Kupo', 'still')); T.ok(c.sent[#c.sent]:find('"linkshell":"KupoKnights"', 1, true))
  for _, items in ipairs({{[0] = {max = 80, count = 3, enabled = false, [1] = kupo()}}, {[8] = {[1] = kupo()}}, {}}) do
    X.W.items = items; X.cmd('status'); T.eq(last(X), 'vanatell: linkshells: unknown')
  end
  X.W.items = {[0] = {max = 80, count = 2, enabled = true, [1] = kupo(), [2] = mog()}}; X.tick(60)
  T.eq(#ls_sent(c), 2); T.eq(last_ls(c), {type = 'linkshells', ls1 = KUPO, ls2 = MOG})
end)
T.test('0x01D (inventory finished loading) is never blocked and asks for a read 0.5 s later, besides the zone-in read', function()
  local X = boot{stored = PAIRED}; wear(X, 'KupoKnights', {[1] = kupo()}); local c = X.F.clients[1]; X.F.open(c)
  X.W.fire('incoming chunk', 0x00A, P.zone_in()); X.W.items = {[0] = {max = 80, count = 0, enabled = true}}; X.tick(2)
  X.W.items = {[0] = {max = 80, count = 2, enabled = true, [1] = kupo(), [2] = mog()}}
  T.eq(X.W.fire('incoming chunk', 0x01D, P.inventory_finished()), nil)
  X.tick(0.25); T.eq(#ls_sent(c), 1); X.tick(0.25); T.eq(#ls_sent(c), 2); T.eq(last_ls(c), {type = 'linkshells', ls1 = KUPO, ls2 = MOG})
  X.W.items[0][2] = nil; X.tick(2); T.eq(#ls_sent(c), 2); X.tick(0.5); T.eq(#ls_sent(c), 3); T.eq(last_ls(c).ls2, nil)
  X.W.fire('incoming chunk', 0x01D, P.inventory_finished()); X.tick(0.5); X.tick(5); T.eq(#ls_sent(c), 3)
  -- A repeated 0x01D pushes its read back rather than forward.
  X.W.fire('incoming chunk', 0x01D, P.inventory_finished()); X.tick(0.25); X.W.items[0][2] = mog()
  X.W.fire('incoming chunk', 0x01D, P.inventory_finished()); X.tick(0.25); T.eq(#ls_sent(c), 3); X.tick(0.25); T.eq(#ls_sent(c), 4)
end)
T.done()
