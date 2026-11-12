-- Boots a fresh vanatell.lua against the windower stub, the config stub and
-- fake_ws, with a test clock, and fires `load`.
--   local boot = require('vt_boot')
--   local X = boot{stored = {url = 'wss://relay.example.com', token = 't', enabled = true}}
--   X.tick(1); X.cmd('status'); X.F.open(X.F.last()); X.app.state; X.frames
local W = require('windower_stub')
local config = require('config')
local F = require('fake_ws')

local function copy(v)
  if type(v) ~= 'table' then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end

return function(opts)
  opts = opts or {}
  W.install()
  F.reset()
  config._reset()
  config._stored = copy(opts.stored or {})

  local X = {W = W, F = F, config = config, clock = {t = 1762800000}, frames = {}}
  local hooks = {
    ws = F,
    now = function() return X.clock.t end,
    on_frame = function(frame) X.frames[#X.frames + 1] = frame end,
  }
  __vanatell_test = hooks
  dofile(windower.addon_path .. 'vanatell.lua')
  X.app = hooks.app
  W.fire('load')

  -- Advances the clock by dt seconds, then fires one prerender.
  function X.tick(dt)
    X.clock.t = X.clock.t + dt
    W.fire('prerender')
  end

  -- //vt <args...>
  function X.cmd(...)
    return W.fire('addon command', ...)
  end

  return X
end
