local T = require('testlib'); local H = require('xr_wshelp'); local open_client, new_client = H.open_client, H.new_client
T.test('send_text writes one masked frame (RFC 6455 5.7)', function()
  local c, net, ev, s = open_client(); T.eq(c:send_text('Hello'), true); c:pump()
  T.eq(s.written, '\129\133\55\250\33\61\127\159\77\81\88')
end)
T.test('send_text length forms and limits', function()
  local c, net, ev, s = open_client{max_message = 70000}
  c:send_text(('a'):rep(200)); c:pump(); T.eq(s.written:sub(1, 8), '\129\254\0\200\55\250\33\61')
  s.written = ''; c:send_text(('a'):rep(65536)); c:pump(); T.eq(s.written:sub(1, 10), '\129\255\0\0\0\0\0\1\0\0')
  T.eq({c:send_text(('a'):rep(70001))}, {nil, 'too large'})
  T.eq({new_client('ws://localhost:8787/x'):send_text('x')}, {nil, 'not open'})
end)
T.test('frames in order, all length forms, partial frames wait', function()
  local c, net, ev, s = open_client{max_message = 100000}
  s:feed('\129\1a\129\1b'); T.eq(c:pump(), 2); T.eq(ev, {'msg:a', 'msg:b'})
  s:feed('\129\126\1\44' .. ('x'):rep(300)); c:pump(); T.eq(#ev[3], 4 + 300)
  s:feed('\129\127\0\0\0\0\0\1\17\112' .. ('y'):rep(70000)); for _ = 1, 10 do c:pump() end; T.eq(#ev[4], 4 + 70000)
  s:feed('\129\5Hel'); T.eq(c:pump(), 0); s:feed('lo'); T.eq(c:pump(), 1); T.eq(ev[5], 'msg:Hello')
end)
T.test('ping answered with masked pong, binary ignored', function()
  local c, net, ev, s = open_client()
  s:feed('\137\3abc'); c:pump(); T.eq(s.written, '\138\131\55\250\33\61\86\152\66'); T.eq(ev, {})
  s:feed('\130\1z\129\1a'); c:pump(); T.eq(ev, {'msg:a'})
end)
T.test('server close is echoed; client close waits for reply or 2 s', function()
  local c, net, ev, s = open_client()
  s:feed('\136\5\3\232bye'); c:pump()
  T.eq(s.written, '\136\130\55\250\33\61\52\18'); T.eq(ev, {'close:1000:bye'}); T.eq(c.state, 'closed'); T.ok(s.closed)
  c, net, ev, s = open_client(); c:close(1000, 'bye'); T.eq(c.state, 'closing'); c:pump()
  T.eq(s.written, '\136\133\55\250\33\61\52\18\67\68\82'); s:feed('\136\2\3\232'); c:pump(); T.eq(ev, {'close:1000:bye'})
  c, net, ev, s = open_client(); c:close(); c:pump(); net.clock = net.clock + 2; c:pump()
  T.eq(ev, {'close:1000:'}); T.ok(s.closed)
end)
T.test('protocol violations fail with the right close code', function()
  local cases = {
    {'\129\129\1\2\3\4\96', 1002, 'masked frame from server', '\52\16'},
    {'\1\1a', 1003, 'fragmented frames not supported', '\52\17'},
    {'\128\1a', 1003, 'fragmented frames not supported', '\52\17'},
    {'\131\0', 1002, 'unknown opcode', '\52\16'},
    {'\137\126\0\126' .. ('p'):rep(126), 1002, 'invalid control frame', '\52\16'},
    {'\129\126\0\201' .. ('z'):rep(201), 1009, 'frame too large', '\52\11'},
  }
  for _, k in ipairs(cases) do
    local c, net, ev, s = open_client{max_message = 200}; s:feed(k[1]); c:pump()
    T.eq(ev, {'error:' .. k[3], 'close:' .. k[2] .. ':' .. k[3]}, k[3]); T.eq(s.written, '\136\130\55\250\33\61' .. k[4]); T.ok(s.closed)
  end
end)
T.test('EOF while open', function()
  local c, net, ev, s = open_client(); s.eof = true; c:pump()
  T.eq(ev, {'error:connection lost', 'close:1006:connection lost'})
end)
T.test('pump work is bounded: one receive, max_frames frames, one send', function()
  local c, net, ev, s = open_client(); s:feed(('\129\1a'):rep(50))
  local r = s.receive_calls; T.eq(c:pump(20), 20); T.eq(s.receive_calls - r, 1)
  T.eq(c:pump(20), 20); T.eq(c:pump(), 10)
  s.send_limit = 3; local before = s.sends; c:send_text('Hello')
  for _ = 1, 4 do c:pump() end; T.eq(s.sends - before, 4); T.eq(s.written, '\129\133\55\250\33\61\127\159\77\81\88')
end)
T.test('abort sends 1001 once, closes, fires nothing', function()
  local c, net, ev, s = open_client(); c:abort()
  T.eq(s.written, '\136\130\55\250\33\61\52\19'); T.ok(s.closed); T.eq(c.state, 'closed'); T.eq(ev, {})
end)
T.done()
