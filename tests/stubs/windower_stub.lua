-- Stand-in for Windower 4's `windower` global. It records what the addon
-- does (commands, chat lines) and lets tests fire events at its handlers.
--   local W = require('windower_stub').install()
local W = {}

local handlers = {}

function W.install(opts)
  opts = opts or {}
  W.player = {name = 'Me'}
  W.commands = {}
  W.chat = {}
  handlers = {}
  _addon = {}
  windower = {
    addon_path = opts.addon_path or os.getenv('XR_ADDON_DIR'),
    register_event = function(...)
      local n = select('#', ...)
      local fn = select(n, ...)
      assert(n >= 2 and type(fn) == 'function',
        'register_event(name1, [name2, ...], fn): expected event names then a function')
      local events = {}
      for i = 1, n - 1 do events[select(i, ...)] = true end
      handlers[#handlers + 1] = {events = events, fn = fn}
      return #handlers
    end,
    send_command = function(s)
      W.commands[#W.commands + 1] = s
    end,
    add_to_chat = function(mode, text)
      W.chat[#W.chat + 1] = {mode = mode, text = text}
    end,
    ffxi = {
      get_player = function() return W.player end,
      get_info = function() return {logged_in = W.player ~= nil} end,
    },
  }
  return W
end

-- The text of every chat line, in order.
function W.lines()
  local out = {}
  for i, line in ipairs(W.chat) do out[i] = line.text end
  return out
end

-- Calls every handler registered for `event`, in registration order, and
-- returns the first non-nil value a handler returned.
function W.fire(event, ...)
  local result
  for _, h in ipairs(handlers) do
    if h.events[event] then
      local r = h.fn(...)
      if result == nil then result = r end
    end
  end
  return result
end

return W
