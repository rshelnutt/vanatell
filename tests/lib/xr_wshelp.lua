-- tests/lib/xr_wshelp.lua
local FN = require('fake_net'); local ws = dofile(os.getenv('XR_ADDON_DIR') .. 'ws.lua'); local H = {}
H.REQUEST = 'GET /v1/ws?role=addon HTTP/1.1\r\nHost: localhost:8787\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
  .. 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer tok\r\n\r\n'
H.ACCEPT_OK = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
  .. 'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n'
function H.new_client(url, extra)
  local net, ev = FN.new(), {}
  local opts = {url = url, headers = {{'Authorization', 'Bearer tok'}}, cafile = '/x/cacert.pem', net = net,
    on_open = function() ev[#ev + 1] = 'open' end, on_message = function(_, t) ev[#ev + 1] = 'msg:' .. t end,
    on_error = function(_, e) ev[#ev + 1] = 'error:' .. e end,
    on_close = function(_, code, r) ev[#ev + 1] = 'close:' .. code .. ':' .. r end}
  for k, v in pairs(extra or {}) do opts[k] = v end
  return ws.new(opts), net, ev
end
function H.upgraded(url, extra) -- connect, finish TCP, request written
  local c, net, ev = H.new_client(url, extra); c:connect(); net.sockets[1].writable = true; c:pump()
  return c, net, ev, net.sockets[1]
end
function H.open_client(extra) -- open on ws://localhost:8787, with ev and written cleared
  local c, net, ev, s = H.upgraded('ws://localhost:8787/v1/ws?role=addon', extra); s:feed(H.ACCEPT_OK); c:pump()
  for k in pairs(ev) do ev[k] = nil end; s.written = ''; return c, net, ev, s
end
return H
