--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- vanatell for Ashita v4. Ashita loads this file. It runs main.lua, the same
-- addon Windower runs, through `windower`: a stand-in for the few Windower
-- calls that addon makes, built on Ashita's API.
--   events     load, unload, d3d_present (Windower's prerender), packet_in
--              and packet_out (incoming and outgoing chunk), command (the
--              /vt commands), and login and logout read from the zone
--              packets the way Ashita's settings library reads them
--   chat       AddChatMessage for the log; QueueCommand types what the phone
--              sends, as if the player typed it
--   game data  the player from party and player memory, the bags from
--              inventory memory, linkshell names and colours from item data
--   settings   one file for this install: config/addons/vanatell/settings.json
--              under the Ashita folder, so every character shares one pairing
--   TLS        Ashita ships LuaSec as socket.ssl; the addon asks for ssl
-- Everything else (the relay connection, pairing, chat, the offline queue,
-- linkshell detection) is the shared code, unchanged. In the release folder
-- main.lua is the Windower addon's vanatell.lua.
addon.name    = 'vanatell'
addon.author  = 'Rob Shelnutt'
addon.version = '0.2.0'
addon.desc    = 'Relays tells, party and linkshell chat to the VanaTell app.'
addon.link    = 'https://github.com/rshelnutt/vanatell'

local floor, unpack = math.floor, unpack or table.unpack

-- A folder path ending in its own separator (Windows paths use \).
local function folder(path)
  path = tostring(path or '')
  if path:find('[\\/]$') then return path end
  return path .. (path:find('\\', 1, true) and '\\' or '/')
end

local ADDON_PATH = folder(addon.path)

local function memory() return AshitaCore:GetMemoryManager() end

---------------------------------------------------------------------------
-- Chat log and game input.
---------------------------------------------------------------------------
-- Windower addon commands are typed with two slashes, Ashita's with one.
local function add_to_chat(mode, text)
  AshitaCore:GetChatManager():AddChatMessage(mode, false, (tostring(text):gsub('//vt', '/vt')))
end

-- The addon only ever types chat into the game, as 'input /tell ...',
-- 'input /p ...', 'input /l ...' or 'input /l2 ...'; nothing else is passed on.
local function send_command(command)
  local text = type(command) == 'string' and command:match('^input (/.+)$')
  if text then AshitaCore:GetChatManager():QueueCommand(1, text) end
end

-- ParseAutoTranslate takes a C string, so it would stop at a NUL inside a
-- phrase's id bytes. A line like that is passed back as it is, and chat.lua
-- shows each of its phrases as [AT]. Text after the line's first NUL is never
-- read, so only the part before it is converted.
local function convert_auto_trans(s)
  local head = s:match('^[^%z]*')
  local _, marks = head:gsub('\253', '')
  if marks % 2 == 1 then return s end
  return AshitaCore:GetChatManager():ParseAutoTranslate(head, true)
end

---------------------------------------------------------------------------
-- Linkshell item data, decoded as Windower's extdata library does it.
---------------------------------------------------------------------------
local LINKSHELL_TYPE = 6 -- ItemType::Linkshell in Ashita's resources
local NAME_CHARS = "'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local NAME_MAX = 20

local function is_linkshell_item(id)
  local ok, item = pcall(function() return AshitaCore:GetResourceManager():GetItemById(id) end)
  return ok and item ~= nil and item.Type == LINKSHELL_TYPE
end

-- The name: 6-bit characters, most significant bit first, from byte 10 of the
-- item data. 0 is the apostrophe, 1 to 26 a to z, 27 to 52 A to Z, and any
-- other value ends the name. At most 20 characters are read.
local function decode_name(data)
  local out, bit = {}, 0
  while #out < NAME_MAX do
    local v = 0
    for i = bit, bit + 5 do
      local b = data:byte(10 + floor(i / 8)) or 0
      v = v * 2 + floor(b / 2 ^ (7 - i % 8)) % 2
    end
    if v > 52 then break end
    out[#out + 1] = NAME_CHARS:sub(v + 1, v + 1)
    bit = bit + 6
  end
  return table.concat(out)
end

-- item = {id =, extdata = the 24 bytes} -> {type = 'Linkshell', name =, r =,
-- g =, b =, status_id =} for a linkshell, pearlsack or linkpearl, else
-- {type = 'Unknown'}. The colour is 4 bits a part, each scaled to 0-255.
-- An unopened shell (status 0) has no name.
local function decode(item)
  local data = type(item) == 'table' and item.extdata
  if type(data) ~= 'string' or #data ~= 24 then error('invalid extdata') end
  if not is_linkshell_item(item.id) then return {type = 'Unknown'} end
  local c1, c2, status = data:byte(7, 9)
  local d = {type = 'Linkshell', r = 17 * (c1 % 16), g = 17 * floor(c1 / 16), b = 17 * (c2 % 16), status_id = status}
  if status ~= 0 then d.name = decode_name(data) end
  return d
end

---------------------------------------------------------------------------
-- Game data in the shapes Windower hands out.
---------------------------------------------------------------------------
-- The bags a linkshell is equipped from (inventory and wardrobes 1 to 8),
-- and the item status of an equipped linkshell, as linkshells.lua has them.
local BAGS = {0, 8, 10, 11, 12, 13, 14, 15, 16}
local BAG_SLOTS = 80
local EQUIPPED = 19

-- windower.ffxi.get_items() for those bags: bag number -> {count = items
-- held, [slot] = {id =, count =, status =, extdata =}}.
local function get_items()
  local inventory = memory():GetInventory()
  local bags = {}
  for _, bag in ipairs(BAGS) do
    local items, held = {}, 0
    for slot = 1, BAG_SLOTS do
      local item = inventory:GetContainerItem(bag, slot)
      if item ~= nil then
        local extra = item.Extra
        items[slot] = {id = item.Id or 0, count = item.Count or 0, status = item.Flags or 0,
                       extdata = type(extra) == 'string' and extra:sub(1, 24) or ''}
        if items[slot].id ~= 0 then held = held + 1 end
      end
    end
    items.count = held
    bags[bag] = items
  end
  return bags
end

-- Windower's player.linkshell names the shell in slot 1. Ashita has no such
-- field, but the game gives the player its slot 1 shell's colour
-- (IEntity:GetLinkshellColor, 0xBBGGRR), so the slot 1 shell is the one
-- equipped shell of that colour. Two equipped shells of that colour, or none,
-- leave it unknown.
local function slot1_name(index)
  local ok, color = pcall(function() return memory():GetEntity():GetLinkshellColor(index) end)
  if not ok or type(color) ~= 'number' then return nil end
  local r, g, b = floor(color % 256 / 16), floor(floor(color / 256) % 256 / 16), floor(floor(color / 65536) % 256 / 16)
  local found
  for _, items in pairs(get_items()) do
    for slot = 1, BAG_SLOTS do
      local item = items[slot]
      if item and item.status == EQUIPPED then
        local decoded, d = pcall(decode, item)
        if decoded and d.type == 'Linkshell' and type(d.name) == 'string' and d.r / 17 == r and d.g / 17 == g and d.b / 17 == b then
          if found and found ~= d.name then return nil end
          found = d.name
        end
      end
    end
  end
  return found
end

-- windower.ffxi.get_player(): nil unless logged in; otherwise {name =,
-- linkshell =}, where linkshell is worked out when it is first read.
local function get_player()
  local mm = memory()
  if mm:GetPlayer():GetLoginStatus() ~= 2 then return nil end
  local party = mm:GetParty()
  local name = party:GetMemberName(0)
  if type(name) ~= 'string' or name == '' then return nil end
  local index = party:GetMemberTargetIndex(0)
  return setmetatable({name = name}, {__index = function(t, key)
    if key ~= 'linkshell' then return nil end
    local shell = slot1_name(index) or ''
    rawset(t, key, shell)
    return shell
  end})
end

---------------------------------------------------------------------------
-- Settings: Windower's config library, kept in one JSON file.
---------------------------------------------------------------------------
local json = dofile(ADDON_PATH .. 'json.lua')

local function settings_dir()
  local root = tostring(AshitaCore:GetInstallPath() or ''):gsub('[\\/]+$', '')
  local sep = root:find('\\', 1, true) and '\\' or '/'
  return root .. sep .. 'config' .. sep .. 'addons' .. sep .. addon.name .. sep
end

local SETTINGS_DIR = settings_dir()
local SETTINGS_FILE = SETTINGS_DIR .. 'settings.json'

local config = {}

-- config.load([path,] defaults): the defaults, with the value saved for each
-- of their keys. A missing or unreadable file gives the defaults.
function config.load(path, defaults)
  if type(path) ~= 'string' then defaults = path end
  local settings = {}
  for k, v in pairs(defaults or {}) do settings[k] = v end
  local f = io.open(SETTINGS_FILE, 'rb')
  if f then
    local text = f:read('*a')
    f:close()
    local ok, saved = pcall(json.decode, text or '')
    if ok and type(saved) == 'table' then
      for k in pairs(settings) do
        if saved[k] ~= nil then settings[k] = saved[k] end
      end
    end
  end
  return settings
end

-- Every save is for all characters: there is one file per Ashita folder.
function config.save(settings)
  local keys = {}
  for k, v in pairs(settings) do
    local t = type(v)
    if type(k) == 'string' and (t == 'string' or t == 'boolean' or t == 'number') then keys[#keys + 1] = k end
  end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do parts[i] = json.encode(k) .. ':' .. json.encode(settings[k]) end
  local mkdir = ashita.fs.create_directory or ashita.fs.create_dir
  if not ashita.fs.exists(SETTINGS_DIR) then mkdir(SETTINGS_DIR) end
  local f = io.open(SETTINGS_FILE, 'wb')
  if not f then
    add_to_chat(207, 'VanaTell: could not save settings to config/addons/vanatell/settings.json')
    return false
  end
  f:write('{' .. table.concat(parts, ',') .. '}\n')
  f:close()
  return true
end

---------------------------------------------------------------------------
-- Events.
---------------------------------------------------------------------------
local handlers = {login = {}, logout = {}}
local aliases = 0

local function on(event, fn)
  aliases = aliases + 1
  ashita.events.register(event, 'vanatell_' .. aliases, fn)
end

-- /vt <args...>: the command is Ashita's to block, so the game never sees it.
local function command_handler(fn)
  return function(e)
    local words = {}
    for word in tostring(e.command):gmatch('%S+') do words[#words + 1] = word end
    if #words == 0 or words[1]:lower() ~= '/' .. tostring(_addon.command):lower() then return end
    e.blocked = true
    fn(unpack(words, 2))
  end
end

local ASHITA_EVENTS = {
  load = function(fn) on('load', function() fn() end) end,
  unload = function(fn) on('unload', function() fn() end) end,
  prerender = function(fn) on('d3d_present', function() fn() end) end,
  ['incoming chunk'] = function(fn)
    on('packet_in', function(e) fn(e.id, e.data, e.data_modified, e.injected, e.blocked) end)
  end,
  ['outgoing chunk'] = function(fn)
    on('packet_out', function(e) fn(e.id, e.data, e.data_modified, e.injected, e.blocked) end)
  end,
  ['addon command'] = function(fn) on('command', command_handler(fn)) end,
  login = function(fn) table.insert(handlers.login, fn) end,
  logout = function(fn) table.insert(handlers.logout, fn) end,
}

-- windower.register_event(name, [name2, ...], fn)
local function register_event(...)
  local n = select('#', ...)
  local fn = select(n, ...)
  for i = 1, n - 1 do
    local name = select(i, ...)
    local register = ASHITA_EVENTS[name]
    if not register then error('vanatell: no Ashita event for ' .. tostring(name)) end
    register(fn)
  end
end

-- Login: the first zone-in (0x00A) after load while not logged in, or after a
-- logout. Logout: a zone-out (0x00B) whose type, at offset 4, is 1.
local logged_in = memory():GetPlayer():GetLoginStatus() == 2

on('packet_in', function(e)
  if e.id == 0x00A and not logged_in then
    logged_in = true
    local player = get_player()
    for _, fn in ipairs(handlers.login) do fn(player and player.name) end
  elseif e.id == 0x00B and logged_in and type(e.data) == 'string' and e.data:byte(5) == 1 then
    logged_in = false
    for _, fn in ipairs(handlers.logout) do fn() end
  end
end)

---------------------------------------------------------------------------
-- The stand-in, then the shared addon.
---------------------------------------------------------------------------
-- package.loaded is cleared first, so a load in a Lua state that already
-- holds these modules (a test run, say) gets this load's.
package.loaded.config, package.loaded.extdata, package.loaded.ssl = nil, nil, nil
package.preload.config = function() return config end
package.preload.extdata = function() return {decode = decode} end
package.preload.ssl = function() return require('socket.ssl') end

windower = {
  addon_path = ADDON_PATH,
  register_event = register_event,
  add_to_chat = add_to_chat,
  send_command = send_command,
  convert_auto_trans = convert_auto_trans,
  ffxi = {get_player = get_player, get_items = get_items},
}
_addon = {}

dofile(ADDON_PATH .. 'main.lua')
