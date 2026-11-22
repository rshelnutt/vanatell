--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- Yells for vanatell: the FFXI worlds, and the yell packet (0x017, Kind
-- 0x1A) read for the server. Packet strings are 1-indexed, so Lua byte N is
-- packet offset N - 1. The layout is Windower's packets library (fields.lua,
-- the incoming 0x017 yell): the sender's zone at 0x06 (little-endian), the
-- sender's name in 15 bytes at 0x08, the message at 0x17; XiPackets
-- (0x0017): Attr at 0x05, 0x01 a GM and 0x08 a message in a special format,
-- and the name and the message are not always NUL-ended.
local yells = {}

-- The retail worlds by the id Windower gives (windower.ffxi.get_info().server),
-- as Windower Resources' servers list names them.
yells.WORLDS = {
  [2] = 'Undine', [4] = 'Bahamut', [5] = 'Shiva', [8] = 'Phoenix', [9] = 'Carbuncle', [10] = 'Fenrir',
  [11] = 'Sylph', [12] = 'Valefor', [14] = 'Leviathan', [15] = 'Odin', [19] = 'Quetzalcoatl', [20] = 'Siren',
  [23] = 'Ragnarok', [26] = 'Cerberus', [28] = 'Bismarck', [30] = 'Lakshmi', [31] = 'Asura',
}
yells.WORLD_IDS = {}
for id, name in pairs(yells.WORLDS) do yells.WORLD_IDS[name] = id end

yells.KIND = 0x1A        -- the yell's chat kind
local SPECIAL = 0x08     -- Attr: a formatted system message, not a player's text
local MAX_BLOCKS = 8     -- auto-translate blocks in one yell, as the server takes them

-- A world id -> its name, or nil when it is not a retail world.
function yells.world_name(id)
  return yells.WORLDS[id]
end

-- chat.lua, for the game's text. vanatell.lua hands over the one it loaded
-- (yells.chat); on its own this file loads it at the first yell.
local function chat()
  if not yells.chat then yells.chat = dofile(windower.addon_path .. 'chat.lua') end
  return yells.chat
end

-- Raw 0x017 packet -> {sender =, zone =, text =, names =}, or nil if it is no
-- player's yell. The text is decoded as chat.lua decodes a tell, except each
-- auto-translate block is its bytes, {#tthhhhhh}, the same on every client;
-- names holds the client's own name for each item and key item block (any
-- type but 0x02, a phrase), by its hex, when the client can name it.
function yells.parse(data)
  if type(data) ~= 'string' or #data < 24 or data:byte(5) ~= yells.KIND then return nil end
  if math.floor(data:byte(6) / SPECIAL) % 2 == 1 then return nil end
  local sender = data:sub(9, 23):match('^[^%z]*')
  if #sender < 3 or #sender > 15 or not sender:find('^[A-Za-z]+$') then return nil end
  local c = chat()
  local text, blocks = c.sanitize_neutral(data:sub(24))
  if not text or #blocks > MAX_BLOCKS then return nil end
  local names = {}
  for _, block in ipairs(blocks) do
    if block.hex:sub(1, 2) ~= '02' and not names[block.hex] then names[block.hex] = c.phrase(block.raw) end
  end
  return {sender = sender, zone = data:byte(7) + data:byte(8) * 256, text = text, names = names}
end

return yells
