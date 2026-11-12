local T = require('testlib'); local boot = require('vt_boot')
local function last(X) local l = X.W.lines(); return l[#l] end
-- Controller ruling: the addon saves only tokens in the relay's format (22
-- base64url characters, a dot, 43 more), so the brief's 'tokNEW' and 'new'
-- are replaced by tok('tokNEW') and tok('new').
local function tok(tag) return (tag .. ('A'):rep(22)):sub(1, 22) .. '.' .. (tag .. ('b'):rep(43)):sub(1, 43) end
local function reply(id, token) return '{"accountId":"' .. id .. '","addonToken":"' .. token .. '"}' end
T.test('pair uses the built-in relay and needs an 8-character code', function()
  local X = boot{}; X.cmd('pair', 'ABCD2345'); T.eq(#X.F.requests, 1)
  T.eq(X.F.requests[1].opts.url, 'https://vanatell.rob-shelnutt.workers.dev/v1/pair')
  X = boot{stored = {url = 'wss://relay.example.com'}}
  for _, code in ipairs({'abc', 'ABCD-234', 'ABCD23456'}) do X.cmd('pair', code); T.eq(last(X), 'vanatell: pairing code must be 8 letters or digits') end
  X.cmd('pair'); T.eq(last(X), 'vanatell: pairing code must be 8 letters or digits'); T.eq(#X.F.requests, 0)
end)
T.test('successful pairing saves credentials and connects', function()
  local X = boot{stored = {url = 'wss://relay.example.com', enabled = true}}; X.cmd('pair', 'ABCD2345')
  local r = X.F.requests[1]; T.eq(r.opts.url, 'https://relay.example.com/v1/pair'); T.eq(r.opts.body, '{"code":"ABCD2345"}')
  T.eq(r.opts.cafile, windower.addon_path .. 'cacert.pem'); T.eq(last(X), 'vanatell: pairing...')
  X.tick(0.016); T.eq(r.pump_calls, 1)
  X.cmd('pair', 'ABCD2345'); T.eq(last(X), 'vanatell: pairing already in progress')
  X.F.respond(r, 200, '{"accountId":"acc1","addonToken":"' .. tok('tokNEW') .. '"}')
  T.eq(X.config._stored.token, tok('tokNEW')); T.eq(X.config._stored.account_id, 'acc1'); T.eq(X.config._saves[#X.config._saves], 'all')
  T.eq(X.app.pairing, nil); T.eq(X.F.last().opts.headers, {{'Authorization', 'Bearer ' .. tok('tokNEW')}}); T.eq(X.app.state, 'connecting')
  T.ok(table.concat(X.W.lines(), '\n'):find('vanatell: paired (account acc1)', 1, true))
end)
T.test('re-pairing from unauthorized replaces the token and reconnects; ws:// maps to http://', function()
  local X = boot{stored = {url = 'ws://localhost:8787', token = tok('old'), account_id = 'acc1', enabled = true}}
  local old = X.F.clients[1]; X.F.reject(old, 401); T.eq(X.app.state, 'unauthorized')
  X.cmd('pair', 'K7M2Q9XA'); T.eq(X.F.requests[1].opts.url, 'http://localhost:8787/v1/pair')
  X.F.respond(X.F.requests[1], 201, '{"accountId":"acc1","addonToken":"' .. tok('new') .. '"}'); T.eq(#X.F.clients, 2); T.eq(X.app.state, 'connecting')
end)
T.test('pairing failures leave the token unchanged', function()
  local X = boot{stored = {url = 'wss://relay.example.com', token = tok('keep'), enabled = true}}
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.requests[1], 404, '{"error":"invalid or expired code"}')
  T.eq(last(X), 'vanatell: pairing failed: invalid or expired code')
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.requests[2], 500, 'oops'); T.eq(last(X), 'vanatell: pairing failed: http 500')
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.requests[3], 200, 'not json'); T.eq(last(X), 'vanatell: pairing failed: bad response from relay')
  X.cmd('pair', 'ABCD2345'); X.F.fail(X.F.requests[4], 'timeout'); T.eq(last(X), 'vanatell: pairing failed: timeout')
  T.eq(X.config._stored.token, tok('keep'))
end)
-- Controller rulings and brief rules the brief's tests leave out.
T.test('a token not in the relay format, or CR/LF in the reply, is never saved', function()
  local X = boot{stored = {url = 'wss://relay.example.com', token = tok('keep'), account_id = 'acc0', enabled = true}}
  local good = tok('ok')
  local bodies = {
    reply('acc1', 'tokNEW'), reply('acc1', good:sub(2)), reply('acc1', good .. 'b'), reply('acc1', 'x' .. good),
    reply('acc1', good:sub(1, 22) .. '.' .. good:sub(25)), reply('acc1', good:sub(1, 21) .. '..' .. good:sub(24)),
    reply('acc1', '+' .. good:sub(2)), reply('acc1', '/' .. good:sub(2)), reply('acc1', good:sub(1, -2) .. '='),
    reply('acc1', good:sub(1, 22) .. ':' .. good:sub(24)), reply('acc1', good:sub(1, 22) .. '.' .. good:sub(24, 64) .. ' b'),
    reply('acc1', good .. '\\r\\n'), reply('acc1', good .. '\\n'), reply('acc1', good:sub(1, 22) .. '\\r\\nX-Evil: 1'),
    reply('acc1', good:sub(1, 20) .. '\\r\\n.' .. good:sub(24)), reply('acc1\\r\\nX: 1', good), reply('acc1\\n', good), reply('', good),
    '{"accountId":1,"addonToken":"' .. good .. '"}', '{"accountId":"acc1","addonToken":5}', '{"accountId":"acc1"}',
    '{"addonToken":"' .. good .. '"}', '[]', '"x"', '',
  }
  for i, body in ipairs(bodies) do
    X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.requests[i], 200, body)
    T.eq(last(X), 'vanatell: pairing failed: bad response from relay', body)
  end
  T.eq(X.config._stored.token, tok('keep')); T.eq(X.config._stored.account_id, 'acc0'); T.eq(#X.F.clients, 1); T.eq(#X.config._saves, 0)
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.last_request(), 200, reply('acc1', tok('_-'))); T.eq(X.config._stored.token, tok('_-'))
end)
T.test('re-pairing while connected closes the old client; backoff restarts at 1 s', function()
  local X = boot{stored = {url = 'wss://relay.example.com', token = tok('old'), account_id = 'acc1', enabled = true}}
  local old = X.F.clients[1]; X.F.open(old); X.cmd('pair', 'k7m2q9xa'); T.eq(X.F.requests[1].opts.body, '{"code":"k7m2q9xa"}')
  X.F.respond(X.F.requests[1], 200, reply('acc2', tok('new')))
  T.eq(old.closed, {1000, 're-paired'}); T.eq(old.aborted, true); T.eq(#X.F.clients, 2); T.eq(X.app.client, X.F.clients[2])
  T.eq(X.F.clients[2].opts.headers, {{'Authorization', 'Bearer ' .. tok('new')}}); T.eq(X.config._stored.account_id, 'acc2')
  X.F.drop(old, 1006, 'late'); T.eq(X.app.state, 'connecting'); T.eq(last(X), 'vanatell: paired (account acc2)')
  for _ = 1, 3 do X.F.drop(X.F.last(), 1006, 'connection lost'); X.tick(X.app.next_attempt - X.clock.t) end
  X.F.drop(X.F.last(), 1006, 'connection lost'); T.eq(X.app.state, 'waiting'); T.eq(X.app.backoff, 16)
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.requests[2], 200, reply('acc2', tok('newer')))
  T.eq(#X.F.clients, 6); T.eq(X.app.state, 'connecting'); X.F.drop(X.F.last(), 1006, 'connection lost'); T.eq(X.app.next_attempt - X.clock.t, 1)
end)
T.test('pairing while off saves the token and stays off', function()
  local X = boot{stored = {url = 'wss://relay.example.com', enabled = false}}
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.requests[1], 200, reply('acc1', tok('t')))
  T.eq(X.config._stored.token, tok('t')); T.eq(X.app.state, 'disabled'); T.eq(#X.F.clients, 0)
  local l = X.W.lines(); T.eq({l[#l - 1], l[#l]}, {'vanatell: paired (account acc1)', 'vanatell: relay is off; //vt on to start'})
  X.cmd('on'); T.eq(#X.F.clients, 1); T.eq(X.app.state, 'connecting')
end)
-- Final polish: the relay-off hint appears only when pairing left relaying off.
T.test('pairing while on does not print the relay-off hint', function()
  local X = boot{stored = {url = 'wss://relay.example.com', enabled = true}}
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.requests[1], 200, reply('acc1', tok('t')))
  T.eq(last(X), 'vanatell: paired (account acc1)'); T.eq(X.app.state, 'connecting')
  T.ok(not table.concat(X.W.lines(), '\n'):find('relay is off', 1, true))
end)
T.test('unpair and unload cancel a pairing in flight', function()
  local X = boot{stored = {url = 'wss://relay.example.com', token = tok('keep'), enabled = true}}
  X.cmd('pair', 'ABCD2345'); local r = X.F.requests[1]; X.cmd('unpair')
  T.eq(r.cancelled, true); T.eq(X.app.pairing, nil); T.eq(last(X), 'vanatell: unpaired')
  X.tick(0.016); T.eq(r.pump_calls, 0)
  X.F.respond(r, 200, reply('acc1', tok('late'))); T.eq(X.config._stored.token, ''); T.eq(#X.F.clients, 1); T.eq(X.app.state, 'unpaired')
  T.eq(last(X), 'vanatell: unpaired')
  X.cmd('pair', 'ABCD2345'); T.eq(last(X), 'vanatell: pairing...'); r = X.F.requests[2]
  X.W.fire('unload'); T.eq(r.cancelled, true); T.eq(X.app.pairing, nil)
  X.F.fail(r, 'closed'); T.eq(last(X), 'vanatell: pairing...')
  X = boot{stored = {url = 'wss://relay.example.com'}}; X.cmd('unpair'); X.W.fire('unload'); T.eq(last(X), 'vanatell: unpaired')
end)
T.test('synchronous failures, error fields and non-ASCII replies', function()
  local X = boot{stored = {url = 'wss://relay.example.com', enabled = true}}
  X.F.post_error = 'resolve: host not found'; X.cmd('pair', 'ABCD2345')
  T.eq(last(X), 'vanatell: pairing failed: resolve: host not found'); T.eq(X.app.pairing, nil); T.eq(#X.F.requests, 0)
  X.F.post_error = nil; X.cmd('pair', 'ABCD2345'); T.eq(last(X), 'vanatell: pairing...')
  local cases = {
    {429, '{"error":"rate_limited","message":"Too many requests; retry later"}', 'Too many requests; retry later'},
    {400, '{"error":"invalid_code","message":"Pairing code is invalid, expired or already used"}', 'Pairing code is invalid, expired or already used'},
    {400, '{"error":5}', 'http 400'}, {400, '{"error":""}', 'http 400'}, {502, '', 'http 502'}, {503, '[1]', 'http 503'},
    {400, '{"error":"caf\\u00e9\\n"}', 'caf???'},
  }
  for i, c in ipairs(cases) do
    if i > 1 then X.cmd('pair', 'ABCD2345') end
    X.F.respond(X.F.last_request(), c[1], c[2]); T.eq(last(X), 'vanatell: pairing failed: ' .. c[3])
  end
  X.cmd('pair', 'ABCD2345'); X.F.fail(X.F.last_request(), 'tls: certificate verify failed\r\n'); T.eq(last(X), 'vanatell: pairing failed: tls: certificate verify failed??')
  for _, code in ipairs({'ABCD234\233', 'ABCD 234', 'ABCD_234', ''}) do
    X.cmd('pair', code); T.eq(last(X), 'vanatell: pairing code must be 8 letters or digits')
  end
  T.eq(#X.F.requests, 8)
end)
-- Controller rulings for Task 10: the relay's message text, and //vt url cancels a pairing.
T.test('pairing failure shows the relay message cut to 120 characters, else its error code', function()
  local X = boot{stored = {url = 'wss://relay.example.com', enabled = true}}
  local long = ('m'):rep(130)
  local cases = {
    {400, '{"error":"invalid_code","message":"' .. long .. '"}', ('m'):rep(120)},
    {400, '{"error":"invalid_code","message":"' .. ('a'):rep(119) .. 'caf\\u00e9"}', ('a'):rep(119) .. 'c'},
    {400, '{"error":"invalid_code","message":"' .. ('a'):rep(118) .. '\\u00e9!"}', ('a'):rep(118) .. '??'},
    {400, '{"error":"invalid_code","message":"caf\\u00e9\\n"}', 'caf???'},
    {503, '{"message":"Relay is down for maintenance"}', 'Relay is down for maintenance'},
    {400, '{"error":"invalid_code","message":""}', 'invalid_code'}, {400, '{"error":"invalid_code","message":7}', 'invalid_code'},
    {400, '{"error":"invalid_code","message":null}', 'invalid_code'}, {400, '{"message":["x"]}', 'http 400'},
  }
  for _, c in ipairs(cases) do
    X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.last_request(), c[1], c[2]); T.eq(last(X), 'vanatell: pairing failed: ' .. c[3], c[2])
  end
end)
T.test('//vt url cancels a pairing in flight; an invalid url does not', function()
  local X = boot{stored = {url = 'wss://relay.example.com', token = tok('keep'), enabled = true}}
  X.cmd('pair', 'ABCD2345'); local r = X.F.requests[1]
  X.cmd('url', 'https://relay.example.com'); T.eq(r.cancelled, false); T.eq(X.app.pairing, r)
  X.cmd('url', 'wss://other.example.com'); T.eq(r.cancelled, true); T.eq(X.app.pairing, nil)
  T.eq(last(X), 'vanatell: relay url set to wss://other.example.com'); X.tick(0.016); T.eq(r.pump_calls, 0)
  X.F.respond(r, 200, reply('acc1', tok('late'))); T.eq(X.config._stored.token, tok('keep')); T.eq(X.app.pairing, nil)
  X.cmd('pair', 'ABCD2345'); T.eq(last(X), 'vanatell: pairing...'); T.eq(X.F.requests[2].opts.url, 'https://other.example.com/v1/pair')
end)
-- Fix round 1: accountId is at most 64 characters, and the error code fallback is cut to 120.
T.test('accountId over 64 characters is a bad response; a long error code is cut to 120', function()
  local X = boot{stored = {url = 'wss://relay.example.com', enabled = true}}
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.last_request(), 200, reply(('a'):rep(65), tok('t')))
  T.eq(last(X), 'vanatell: pairing failed: bad response from relay'); T.eq(#X.config._saves, 0); T.eq(#X.F.clients, 0)
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.last_request(), 200, reply(('a'):rep(64), tok('t')))
  T.eq(X.config._stored.account_id, ('a'):rep(64)); T.eq(X.config._stored.token, tok('t')); T.eq(#X.F.clients, 1)
  X.cmd('pair', 'ABCD2345'); X.F.respond(X.F.last_request(), 400, '{"error":"' .. ('e'):rep(130) .. '"}')
  T.eq(last(X), 'vanatell: pairing failed: ' .. ('e'):rep(120))
end)
T.done()
