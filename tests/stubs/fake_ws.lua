-- Stand-in for the whole ws module in the vanatell tests. Fake clients record
-- what vanatell does to them, and tests fire their callbacks the way ws.lua
-- does: client callbacks get the client first, request callbacks do not.
--   local F = require('fake_ws'); F.reset()
--   local c = F.new(opts); c:connect(); F.open(c); F.message(c, '{"type":"pong"}')
local F = {}

F.parse_url = dofile(os.getenv('XR_ADDON_DIR') .. 'ws.lua').parse_url

function F.reset()
  F.clients = {}
  F.requests = {}
  F.connect_error = nil -- when set, connect() fails with it
  F.post_error = nil    -- when set, http_post fails with it and records nothing
end

function F.last()
  return F.clients[#F.clients]
end

function F.last_request()
  return F.requests[#F.requests]
end

---------------------------------------------------------------------------
-- Fake client.
---------------------------------------------------------------------------
local Client = {}
Client.__index = Client

function F.new(opts)
  local c = setmetatable({opts = opts, state = 'idle', sent = {}, connect_calls = 0, pump_calls = 0,
                          last_pump_max = nil, closed = nil, aborted = false, http_status = nil}, Client)
  F.clients[#F.clients + 1] = c
  return c
end

function Client:connect()
  self.connect_calls = self.connect_calls + 1
  if F.connect_error then
    self.state = 'closed'
    return nil, F.connect_error
  end
  self.state = 'connecting'
  return true
end

function Client:pump(max_frames)
  self.pump_calls = self.pump_calls + 1
  self.last_pump_max = max_frames
  return 0
end

function Client:send_text(s)
  if self.state ~= 'open' then return nil, 'not open' end
  self.sent[#self.sent + 1] = s
  return true
end

function Client:close(code, reason)
  self.closed = {code, reason}
  self.state = 'closing'
end

function Client:abort()
  self.aborted = true
  self.state = 'closed'
end

local function emit(c, name, ...)
  local fn = c.opts[name]
  if fn then fn(c, ...) end
end

function F.open(c)
  c.state = 'open'
  emit(c, 'on_open')
end

function F.message(c, text)
  emit(c, 'on_message', text)
end

function F.drop(c, code, reason)
  c.state = 'closed'
  emit(c, 'on_error', reason)
  emit(c, 'on_close', code, reason)
end

function F.reject(c, status)
  local err = 'handshake: http ' .. status
  c.http_status = status
  c.state = 'closed'
  emit(c, 'on_error', err)
  emit(c, 'on_close', 1006, err)
end

---------------------------------------------------------------------------
-- Fake http_post: the test resolves each request with respond or fail.
-- Unlike ws.lua, respond and fail still fire after cancel(), so tests can
-- check that vanatell ignores a request it has let go.
---------------------------------------------------------------------------
local Request = {}
Request.__index = Request

function F.http_post(opts)
  if F.post_error then return nil, F.post_error end
  local req = setmetatable({opts = opts, pump_calls = 0, done = false, cancelled = false}, Request)
  F.requests[#F.requests + 1] = req
  return req
end

function Request:pump()
  self.pump_calls = self.pump_calls + 1
  return self.done
end

function Request:cancel()
  self.cancelled = true
  self.done = true
end

local function finish(req, name, ...)
  req.done = true
  local fn = req.opts[name]
  if fn then fn(...) end
end

function F.respond(req, status, body)
  finish(req, 'on_done', status, body)
end

function F.fail(req, err)
  finish(req, 'on_error', err)
end

F.reset()
return F
