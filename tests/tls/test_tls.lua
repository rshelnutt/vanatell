-- tests/tls/test_tls.lua: ws.lua over real LuaSec against openssl s_server
-- on localhost:18443. Run through tests/tls/run.sh, which passes the
-- server's self-signed certificate as arg[1].
local T = require('testlib'); local ws = T.addon('ws'); local ssl = require('ssl')
local socket = require('socket')
local CERT, BUNDLE = arg[1], os.getenv('XR_ADDON_DIR') .. 'cacert.pem'

-- Connects with the real default_net and pumps until the client is closed
-- (5 s cap). mod is the ws module to use, ws by default.
-- -> client, first error reported
local function run(url, cafile, mod)
  local first_error
  local c = (mod or ws).new{url = url, cafile = cafile,
    on_error = function(_, e) first_error = first_error or e end}
  local ok, err = c:connect()
  if not ok then return c, err end
  local stop = socket.gettime() + 5
  while c.state ~= 'closed' and socket.gettime() < stop do
    c:pump()
    socket.sleep(0.01)
  end
  if c.state ~= 'closed' then
    first_error = first_error or ('still ' .. c.state .. ' after 5 s')
    c:abort()
  end
  return c, first_error
end

T.test('trusted self-signed cert: TLS + hostname check pass, s_server answers HTTP 200', function()
  local c, err = run('wss://localhost:18443/v1/ws?role=addon', CERT)
  T.eq(c.http_status, 200); T.eq(err, 'handshake: http 200')
end)
T.test('the Mozilla bundle does not trust the self-signed cert', function()
  local c, err = run('wss://localhost:18443/v1/ws?role=addon', BUNDLE)
  T.ok(err:find('^tls: '), err); T.eq(c.http_status, nil)
end)
T.test('trusted chain but wrong name fails the hostname check', function()
  local c, err = run('wss://127.0.0.1:18443/v1/ws?role=addon', CERT); T.eq(err, 'tls: certificate hostname mismatch')
end)
T.test('cacert.pem loads into an OpenSSL context', function()
  T.ok(ssl.newcontext{mode = 'client', protocol = 'any', verify = 'peer', options = {'all', 'no_sslv3', 'no_tlsv1', 'no_tlsv1_1'},
    cafile = BUNDLE})
  T.ok(io.open(BUNDLE):read('*a'):find('Certificate data from Mozilla', 1, true))
end)
-- Final polish: one context per CA file, built with SSLv3, TLS 1.0 and 1.1
-- off (this LuaSec accepts those names, so no fallback), reused by every connect.
T.test('one TLS context per CA file, with old versions off, reused across connects', function()
  local fresh, made, logs, real = T.addon('ws'), {}, {}, ssl.newcontext
  fresh.log = function(l) logs[#logs + 1] = l end
  ssl.newcontext = function(p) made[#made + 1] = p; return real(p) end
  local c1, e1 = run('wss://localhost:18443/v1/ws?role=addon', CERT, fresh)
  local c2, e2 = run('wss://localhost:18443/v1/ws?role=addon', CERT, fresh)
  ssl.newcontext = real
  T.eq({c1.http_status, e1, c2.http_status, e2}, {200, 'handshake: http 200', 200, 'handshake: http 200'})
  T.eq(#made, 1); T.eq(made[1].options, {'all', 'no_sslv3', 'no_tlsv1', 'no_tlsv1_1'}); T.eq(logs, {})
end)
T.done()
