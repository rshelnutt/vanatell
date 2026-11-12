-- Shim for Windower's libs/config.lua, not a copy: the real one pulls in
-- tables, sets, lists, strings, xml and files, and the addon only uses
-- load and save. The "settings file" lives in config._stored, and every
-- save records its `char` argument in config._saves.
local config = {}

local function copy(v)
  if type(v) ~= 'table' then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end

function config._reset()
  config._stored = {}
  config._saves = {}
end

-- config.load([path,] defaults)
function config.load(path, defaults)
  if type(path) ~= 'string' then defaults = path end
  local settings = copy(defaults or {})
  for k, v in pairs(config._stored) do settings[k] = copy(v) end
  return settings
end

function config.save(settings, char)
  config._stored = copy(settings)
  config._saves[#config._saves + 1] = char
end

config._reset()
return config
