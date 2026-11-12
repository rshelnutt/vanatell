local T = require('testlib'); local boot = require('vt_boot'); local P = require('xr_packets')
-- Fix round 1: a stored token must be in the relay's format to count as paired,
-- so the brief's 'tok123' is padded out to one.
local PAIRED = {url = 'wss://relay.example.com', token = 'tok123' .. ('A'):rep(16) .. '.' .. ('b'):rep(43), account_id = 'acc1', enabled = true}
local function opened() local X = boot{stored = PAIRED}; X.F.open(X.F.clients[1]); return X, X.F.clients[1] end
local function send(X, c, frame) X.F.message(c, frame) end
T.test('incoming and outgoing chat become exact chat frames; packets are never blocked', function()
  local X, c = opened()
  T.eq(X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'hey')), nil)
  T.eq(c.sent[1], '{"type":"chat","channel":"tell","direction":"in","sender":"Kupo","target":null,"text":"hey","ts":1762800000000}')
  X.W.fire('incoming chunk', 0x017, P.incoming_chat(27, 'Kupo', 'ls2 hi')); T.ok(c.sent[2]:find('"channel":"ls2"', 1, true))
  X.W.fire('incoming chunk', 0x017, P.incoming_chat(0, 'Kupo', 'say')); X.W.fire('incoming chunk', 0x017, P.incoming_chat(5, 'me', 'own'))
  X.W.fire('incoming chunk', 0x028, 'other'); T.eq(#c.sent, 2)
  T.eq(X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, 'hi all')), nil)
  T.eq(c.sent[3], '{"type":"chat","channel":"ls1","direction":"out","sender":"Me","target":null,"text":"hi all","ts":1762800000000}')
  X.W.fire('outgoing chunk', 0x0B6, P.outgoing_tell('Kupo', 'yo'))
  T.eq(c.sent[4], '{"type":"chat","channel":"tell","direction":"out","sender":"Me","target":"Kupo","text":"yo","ts":1762800000000}')
  X.W.fire('outgoing chunk', 0x0B6, P.outgoing_tell('Kupo', 'blocked'), nil, false, true); T.eq(#c.sent, 4)
end)
T.test('offline queue: kept while reconnecting, flushed in order, capped, dropped when off', function()
  local X = boot{stored = PAIRED}
  X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'one')); X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'two'))
  T.eq(#X.app.queue, 2); local c = X.F.clients[1]; X.F.open(c)
  T.ok(c.sent[1]:find('"text":"one"', 1, true)); T.ok(c.sent[2]:find('"text":"two"', 1, true)); T.eq(#X.app.queue, 0)
  X.F.drop(c, 1006, 'connection lost')
  for i = 1, 501 do X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'm' .. i)) end
  T.eq(#X.app.queue, 500); T.ok(X.app.queue[1]:find('"text":"m2"', 1, true))
  local full = 0; for _, l in ipairs(X.W.lines()) do if l == 'vanatell: offline queue full, dropping oldest messages' then full = full + 1 end end; T.eq(full, 1)
  X.cmd('off'); X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'dropped')); T.eq(#X.app.queue, 500)
  X.cmd('unpair'); T.eq(#X.app.queue, 0)
end)
T.test('send frames issue exactly one of the three commands and ack', function()
  local X, c = opened()
  send(X, c, '{"type":"send","id":123,"channel":"tell","target":"Kupo","text":"on my way"}')
  T.eq(X.W.commands, {'input /tell Kupo on my way'}); T.eq(c.sent[#c.sent], '{"type":"ack","id":123,"ok":true}')
  send(X, c, '{"type":"send","id":124,"channel":"ls1","text":"hi"}'); send(X, c, '{"type":"send","id":125,"channel":"ls2","target":null,"text":"hi"}')
  T.eq(X.W.commands, {'input /tell Kupo on my way', 'input /l hi', 'input /l2 hi'})
  send(X, c, '{"type":"send","id":126,"channel":"tell","target":"Ku","text":"x"}')
  T.eq(c.sent[#c.sent], '{"type":"ack","id":126,"ok":false,"error":"invalid target"}')
  send(X, c, '{"type":"send","id":127,"channel":"ls1","text":"/shout hi"}')
  T.eq(c.sent[#c.sent], '{"type":"ack","id":127,"ok":false,"error":"text must not start with /"}')
  X.W.player = nil; send(X, c, '{"type":"send","id":128,"channel":"ls1","text":"hi"}')
  T.eq(c.sent[#c.sent], '{"type":"ack","id":128,"ok":false,"error":"not logged in"}'); T.eq(#X.W.commands, 3)
  local n = #c.sent
  for _, f in ipairs({'{"type":"hello","role":"addon"}', '{"type":"pong"}', '{"type":"msg","msg":{}}', '{"type":"zzz"}', 'not json', '{"type":"send","id":"x"}'}) do send(X, c, f) end
  T.eq(#c.sent, n); T.eq(#X.W.commands, 3); T.eq(X.frames[1], {type = 'send', id = 123, channel = 'tell', target = 'Kupo', text = 'on my way'})
end)
T.test('test_replayed_send_id_is_not_executed_twice', function()
  local X, c = opened(); local f = '{"type":"send","id":123,"channel":"tell","target":"Kupo","text":"on my way"}'
  send(X, c, f); X.F.drop(c, 1006, 'connection lost'); X.tick(1); local c2 = X.F.last(); X.F.open(c2); send(X, c2, f)
  T.eq(#X.W.commands, 1); T.eq(c2.sent[#c2.sent], '{"type":"ack","id":123,"ok":true}')
end)
T.test('test_phone_send_echo_is_not_mirrored', function()
  local X, c = opened()
  send(X, c, '{"type":"send","id":123,"channel":"tell","target":"Kupo","text":"on my way"}'); local n = #c.sent
  X.W.fire('outgoing chunk', 0x0B6, P.outgoing_tell('kupo', 'on my way')); T.eq(#c.sent, n)
  X.W.fire('outgoing chunk', 0x0B6, P.outgoing_tell('Kupo', 'on my way')); T.eq(#c.sent, n + 1)
  send(X, c, '{"type":"send","id":124,"channel":"ls1","text":"brb"}'); n = #c.sent; X.tick(10.1)
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, 'brb')); T.eq(#c.sent, n + 1)
end)
-- Controller rulings and brief rules the brief's tests leave out.
T.test('own lines are dropped by name, ignoring case; with no player the sender is null', function()
  local X, c = opened(); X.W.player = {name = 'Kupo'}
  X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'KUPO', 'own')); X.W.fire('incoming chunk', 0x017, P.incoming_chat(5, 'kupo', 'own'))
  T.eq(#c.sent, 0)
  X.W.fire('incoming chunk', 0x017, P.incoming_chat(5, 'Mog', 'not own')); T.ok(c.sent[1]:find('"sender":"Mog"', 1, true))
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(27, 'mine'))
  T.eq(c.sent[2], '{"type":"chat","channel":"ls2","direction":"out","sender":"Kupo","target":null,"text":"mine","ts":1762800000000}')
  X.W.player = nil
  X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'hi')); T.ok(c.sent[3]:find('"sender":"Kupo"', 1, true))
  X.W.fire('outgoing chunk', 0x0B6, P.outgoing_tell('Kupo', 'yo'))
  T.eq(c.sent[4], '{"type":"chat","channel":"tell","direction":"out","sender":null,"target":"Kupo","text":"yo","ts":1762800000000}')
  X.clock.t = X.clock.t + 0.0129; X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'later'))
  T.ok(c.sent[5]:find('"ts":1762800000012}', 1, true))
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, 'x'), nil, true, false); T.eq(#c.sent, 6)
end)
T.test('queue: unauthorized holds, unpaired drops, full is logged again in a later outage', function()
  local X = boot{stored = PAIRED}; X.F.reject(X.F.clients[1], 401); T.eq(X.app.state, 'unauthorized')
  X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'held')); T.eq(#X.app.queue, 1)
  X = boot{}; T.eq(X.app.state, 'unpaired'); X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'gone')); T.eq(#X.app.queue, 0)
  local function full_lines() local n = 0; for _, l in ipairs(X.W.lines()) do if l:find('queue full', 1, true) then n = n + 1 end end; return n end
  X = boot{stored = PAIRED}
  for i = 1, 502 do X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'a' .. i)) end
  T.eq(full_lines(), 1); local c = X.F.clients[1]; X.F.open(c); T.eq(#c.sent, 500); T.ok(c.sent[1]:find('"text":"a3"', 1, true))
  T.ok(c.sent[500]:find('"text":"a502"', 1, true))
  send(X, c, '{"type":"send","id":1,"channel":"ls1","text":"hi"}'); T.eq(c.sent[501], '{"type":"ack","id":1,"ok":true}')
  X.F.drop(c, 1006, 'connection lost'); for i = 1, 501 do X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'b' .. i)) end
  T.eq(full_lines(), 2)
  X = boot{stored = PAIRED}; for i = 1, 501 do X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'c' .. i)) end
  X.cmd('unpair'); T.eq(#X.app.queue, 0); X.cmd('pair', 'ABCD2345')
  X.F.respond(X.F.last_request(), 200, '{"accountId":"acc1","addonToken":"' .. ('A'):rep(22) .. '.' .. ('b'):rep(43) .. '"}')
  T.eq(X.app.state, 'connecting'); for i = 1, 501 do X.W.fire('incoming chunk', 0x017, P.incoming_chat(3, 'Kupo', 'd' .. i)) end
  T.eq(full_lines(), 2)
end)
T.test('ids: not logged in and failed sends are not remembered; the last 200 executed ids are', function()
  local X, c = opened()
  X.W.player = nil; send(X, c, '{"type":"send","id":5,"channel":"ls1","text":"hi"}'); T.eq(#X.W.commands, 0)
  X.W.player = {name = 'Me'}; send(X, c, '{"type":"send","id":5,"channel":"ls1","text":"hi"}')
  T.eq(X.W.commands, {'input /l hi'}); T.eq(c.sent[#c.sent], '{"type":"ack","id":5,"ok":true}')
  X.W.player = nil; send(X, c, '{"type":"send","id":5,"channel":"ls1","text":"hi"}'); T.eq(c.sent[#c.sent], '{"type":"ack","id":5,"ok":true}')
  X.W.player = {name = 'Me'}; T.eq(#X.W.commands, 1)
  send(X, c, '{"type":"send","id":6,"channel":"ls1","text":""}'); T.eq(c.sent[#c.sent], '{"type":"ack","id":6,"ok":false,"error":"empty text"}')
  send(X, c, '{"type":"send","id":6,"channel":"ls1","text":"ok now"}'); T.eq(X.W.commands[2], 'input /l ok now')
  for id = 1001, 1199 do send(X, c, '{"type":"send","id":' .. id .. ',"channel":"ls1","text":"n"}') end
  T.eq(#X.W.commands, 201)
  send(X, c, '{"type":"send","id":6,"channel":"ls1","text":"ok now"}'); T.eq(#X.W.commands, 201)
  send(X, c, '{"type":"send","id":1200,"channel":"ls1","text":"n"}'); T.eq(#X.W.commands, 202)
  send(X, c, '{"type":"send","id":5,"channel":"ls1","text":"hi"}'); T.eq(#X.W.commands, 203); T.eq(c.sent[#c.sent], '{"type":"ack","id":5,"ok":true}')
  send(X, c, '{"type":"send","id":1002,"channel":"ls1","text":"n"}'); T.eq(#X.W.commands, 203)
  send(X, c, '{"type":"send","id":7,"channel":"tell","target":"Kupo","text":"a;b"}')
  T.eq(X.W.commands[204], 'input /tell Kupo a,b'); T.eq(c.sent[#c.sent], '{"type":"ack","id":7,"ok":true}')
  for _, f in ipairs({'{"type":"send","channel":"ls1","text":"hi"}', '{"type":"send","id":null,"channel":"ls1","text":"hi"}',
      '{"type":"send","id":true,"channel":"ls1","text":"hi"}', '{"type":"send","id":[1],"channel":"ls1","text":"hi"}', '[1]', '"send"'}) do
    local n = #c.sent; send(X, c, f); T.eq(#c.sent, n)
  end
  T.eq(#X.W.commands, 204)
end)
T.test('echo: one entry per executed send, matched on channel, text and target (any case), nothing more', function()
  local X, c = opened()
  send(X, c, '{"type":"send","id":1,"channel":"ls2","target":"Kupo","text":"brb"}'); local n = #c.sent
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, 'brb')); T.eq(#c.sent, n + 1)
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(27, 'brb')); T.eq(#c.sent, n + 1)
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(27, 'brb')); T.eq(#c.sent, n + 2)
  send(X, c, '{"type":"send","id":2,"channel":"tell","target":"KUPO","text":"  a;b  "}'); send(X, c, '{"type":"send","id":2,"channel":"tell","target":"KUPO","text":"a;b"}')
  n = #c.sent; T.eq(X.W.commands[2], 'input /tell KUPO a,b'); T.eq(#X.W.commands, 2)
  X.W.fire('outgoing chunk', 0x0B6, P.outgoing_tell('Mog', 'a,b')); T.eq(#c.sent, n + 1)
  X.W.fire('outgoing chunk', 0x0B6, P.outgoing_tell('Kupo', 'a,b')); T.eq(#c.sent, n + 1)
  X.W.fire('outgoing chunk', 0x0B6, P.outgoing_tell('Kupo', 'a,b')); T.eq(#c.sent, n + 2)
  send(X, c, '{"type":"send","id":3,"channel":"ls1","text":"x"}'); send(X, c, '{"type":"send","id":4,"channel":"ls1","text":"x"}')
  n = #c.sent; X.tick(9.9)
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, 'x'), nil, false, true); T.eq(#c.sent, n)
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, 'x')); X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, 'x')); T.eq(#c.sent, n)
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, 'x')); T.eq(#c.sent, n + 1)
  send(X, c, '{"type":"send","id":5,"channel":"ls1","text":"/x"}'); n = #c.sent
  X.W.fire('outgoing chunk', 0x0B5, P.outgoing_ls(5, '/x')); T.eq(#c.sent, n + 1)
  X.cmd('off'); send(X, c, '{"type":"send","id":6,"channel":"ls1","text":"late"}'); T.eq(#X.W.commands, 4)
end)
-- Fix round 1: json.encode cannot write inf or nan, so only positive integer ids are handled.
T.test('send ids that are not positive integers run nothing, get no ack and raise nothing', function()
  local X, c = opened()
  for _, id in ipairs({'1e999', '1e999', '-1e999', '-nan', '0', '-5', '7.5', '1e-3', '"7"'}) do
    send(X, c, '{"type":"send","id":' .. id .. ',"channel":"ls1","text":"hi"}')
  end
  T.eq(#X.W.commands, 0); T.eq(#c.sent, 0)
  send(X, c, '{"type":"send","id":1e3,"channel":"ls1","text":"hi"}'); T.eq(c.sent, {'{"type":"ack","id":1000,"ok":true}'})
  T.eq(X.W.commands, {'input /l hi'})
end)
T.done()
