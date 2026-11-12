local T = require('testlib'); local FN = require('fake_net'); local ws = T.addon('ws')
local function new_req(url, extra)
  local net, ev = FN.new(), {}
  local opts = {url = url, body = '{"code":"ABCD2345"}', cafile = '/x/cacert.pem', net = net,
    on_done = function(st, b) ev[#ev + 1] = {st, b} end, on_error = function(e) ev[#ev + 1] = e end}
  for k, v in pairs(extra or {}) do opts[k] = v end
  local r = ws.http_post(opts); net.sockets[1].writable = true; return r, net, ev, net.sockets[1]
end
T.test('request bytes and Content-Length response', function()
  local r, net, ev, s = new_req('http://localhost:8787/v1/pair', {headers = {{'X-Relay-Key', 'k'}}})
  T.eq(r:pump(), false)
  T.eq(s.written, 'POST /v1/pair HTTP/1.1\r\nHost: localhost:8787\r\nContent-Type: application/json\r\n'
    .. 'Content-Length: 19\r\nConnection: close\r\nX-Relay-Key: k\r\n\r\n{"code":"ABCD2345"}')
  s:feed('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloEXTRA'); T.eq(r:pump(), true); T.eq(ev, {{200, 'hello'}})
  T.eq(r:pump(), true); T.eq(#ev, 1)
end)
T.test('chunked body and read-until-EOF body; 4xx goes to on_done', function()
  local r, net, ev, s = new_req('http://localhost:8787/v1/pair'); r:pump()
  s:feed('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n'); r:pump()
  T.eq(ev, {{200, 'hello world'}})
  r, net, ev, s = new_req('http://localhost:8787/v1/pair'); r:pump()
  s:feed('HTTP/1.1 404 Not Found\r\n\r\n{"error":"invalid or expired code"}'); r:pump(); T.eq(ev, {})
  s.eof = true; r:pump(); T.eq(ev, {{404, '{"error":"invalid or expired code"}'}})
end)
T.test('https uses the same TLS path', function()
  local r, net = new_req('https://relay.example.com/v1/pair'); r:pump()
  T.eq(net.wraps[1].params.verify, 'peer'); T.ok(net.sockets[1].written:find('Host: relay.example.com\r\n', 1, true))
end)
T.test('errors: sync, timeout, connection lost, too large', function()
  T.eq({ws.http_post{url = 'http://example.com/v1/pair', body = '', net = FN.new()}}, {nil, 'plain ws:// and http:// are only allowed for localhost'})
  local r, net, ev, s = new_req('http://localhost:8787/v1/pair'); r:pump(); net.clock = net.clock + 15; T.eq(r:pump(), true); T.eq(ev, {'timeout'})
  r, net, ev, s = new_req('http://localhost:8787/v1/pair'); r:pump(); s:feed('HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc'); s.eof = true
  r:pump(); r:pump(); T.eq(ev, {'connection lost'})
  r, net, ev, s = new_req('http://localhost:8787/v1/pair'); r:pump(); s:feed('HTTP/1.1 200 OK\r\n\r\n' .. ('x'):rep(65537))
  for _ = 1, 6 do r:pump() end; T.eq(ev, {'response too large'})
end)
-- Controller ruling: unload and //vt unpair cancel a pairing in flight.
T.test('cancel closes the socket at once and fires no callback', function()
  local r, net, ev, s = new_req('http://localhost:8787/v1/pair'); r:pump(); T.ok(s.written ~= '')
  local receives = s.receive_calls; r:cancel(); T.eq(s.closed, true)
  s:feed('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}'); T.eq(r:pump(), true); net.clock = net.clock + 15; T.eq(r:pump(), true)
  T.eq(s.receive_calls, receives); T.eq(ev, {}); r:cancel(); T.eq(ev, {})
  r, net, ev, s = new_req('https://relay.example.com/v1/pair'); r:cancel(); T.eq(s.closed, true); T.eq(r:pump(), true)
  T.eq(#net.wraps, 0); T.eq(s.written, ''); T.eq(ev, {})
  r, net, ev, s = new_req('http://localhost:8787/v1/pair'); r:pump(); s:feed('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}'); r:pump()
  T.eq(ev, {{200, '{}'}}); r:cancel(); T.eq(r:pump(), true); T.eq(ev, {{200, '{}'}})
end)
T.done()
