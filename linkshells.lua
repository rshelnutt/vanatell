--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- Linkshells for vanatell: which linkshell is equipped in slot 1 and slot 2,
-- worked out from game data passed in (so it runs outside the game too),
-- and the linkshell equip packet (0x0E0) that says which item went where.
-- Packet strings are 1-indexed, so Lua byte N is packet offset N - 1.
local M = {}

M.EQUIPPED = 19  -- item status of an equipped linkshell
M.NAME_MAX = 20  -- longest linkshell name
local BAG_SLOTS = 80

-- Inventory and the eight wardrobes, the bags a linkshell is equipped from:
-- {bag number, the bag's key in windower.ffxi.get_items()}.
M.BAGS = {{0, 'inventory'}, {8, 'wardrobe'}, {10, 'wardrobe2'}, {11, 'wardrobe3'}, {12, 'wardrobe4'},
          {13, 'wardrobe5'}, {14, 'wardrobe6'}, {15, 'wardrobe7'}, {16, 'wardrobe8'}}

-- A colour part as a whole number from 0 to 255; anything not a number is 0.
local function part(v)
  v = math.floor(tonumber(v) or 0)
  if v < 0 then return 0 end
  if v > 255 then return 255 end
  return v
end

-- -> '#RRGGBB', uppercase
function M.color(r, g, b)
  return string.format('#%02X%02X%02X', part(r), part(g), part(b))
end

-- The game's linkshell alphabet is A-Z, a-z and the apostrophe.
local function is_name(v)
  return type(v) == 'string' and #v >= 1 and #v <= M.NAME_MAX and not v:find("[^A-Za-z']")
end

-- An equipped item as {name =, color =}, or nil when its extdata does not
-- decode to a linkshell with a usable name.
local function read_shell(decode, item)
  local ok, d = pcall(decode, item)
  if not (ok and type(d) == 'table' and d.type == 'Linkshell' and is_name(d.name)) then return nil end
  return {name = d.name, color = M.color(d.r, d.g, d.b)}
end

local OTHER = {ls1 = 'ls2', ls2 = 'ls1'}
local SLOT = {[1] = 'ls1', [2] = 'ls2'}

-- player = windower.ffxi.get_player(): player.linkshell names the shell in
--   slot 1 ('' or nil when none), and player.linkshell_slot is that shell's
--   inventory slot.
-- bags = windower.ffxi.get_items(), bags keyed by number or by name.
-- decode = extdata.decode.
-- equips = {['bag:slot'] = 1 or 2}, from the 0x0E0 packets seen.
-- -> {ls1 = {name =, color =} | nil, ls2 = ...}
-- An item counts as an equipped shell when the game flags it so (status 19),
-- when a 0x0E0 named its bag and slot, or when it is the inventory item at
-- player.linkshell_slot and carries player.linkshell's name. The game does
-- not flag every equipped shell 19 (a leader's Linkshell in slot 1 and a
-- pearl in slot 2 have been seen with another status), so the packet and the
-- player's own slot are trusted over the status. Any other status, a shell
-- set for sale in the bazaar (25) among them, is not equipped.
-- A shell the equips map places goes to that slot. Otherwise the shell named
-- in player.linkshell is ls1 and any other is ls2. Two shells never share a
-- slot: when the slot a shell would take holds a shell the equips map placed,
-- it takes the other slot; when it holds one placed by name, it is left out.
function M.detect(player, bags, decode, equips)
  equips = type(equips) == 'table' and equips or {}
  local primary = type(player) == 'table' and player.linkshell or nil
  local primary_slot = type(player) == 'table' and tonumber(player.linkshell_slot) or nil
  local found = {}
  if type(bags) == 'table' then
    for _, b in ipairs(M.BAGS) do
      local id, key = b[1], b[2]
      local items = bags[id] or bags[key]
      if type(items) == 'table' then
        for slot = 1, BAG_SLOTS do
          local item = items[slot]
          local where = id .. ':' .. slot
          local at_primary = id == 0 and slot == primary_slot
          if type(item) == 'table' and (item.status == M.EQUIPPED or SLOT[equips[where]] or at_primary) then
            local shell = read_shell(decode, item)
            -- The item at player.linkshell_slot counts only if it is the shell player.linkshell names.
            if shell and at_primary and item.status ~= M.EQUIPPED and not SLOT[equips[where]] and shell.name ~= primary then
              shell = nil
            end
            if shell then found[#found + 1] = {key = where, shell = shell} end
          end
        end
      end
    end
  end

  local result, mapped, placed = {}, {}, {}
  for i, f in ipairs(found) do
    local slot = SLOT[equips[f.key]]
    if slot and not result[slot] then
      result[slot], mapped[slot], placed[i] = f.shell, true, true
    end
  end
  for i, f in ipairs(found) do
    if not placed[i] then
      local slot = (is_name(primary) and f.shell.name == primary) and 'ls1' or 'ls2'
      if not result[slot] then
        result[slot] = f.shell
      elseif mapped[slot] and not result[OTHER[slot]] then
        result[OTHER[slot]] = f.shell
      end
    end
  end
  return result
end

-- True when get_items() shows the inventory loaded: the bag is there, not
-- disabled, and holds an item (by its count or by an item in a slot). While
-- the game is still loading it, after login or zoning, the bag reads empty,
-- and empty slots read from it would be wrong.
function M.inventory_loaded(bags)
  if type(bags) ~= 'table' then return false end
  local inventory = bags[0] or bags.inventory
  if type(inventory) ~= 'table' or inventory.enabled == false then return false end
  if type(inventory.count) == 'number' and inventory.count > 0 then return true end
  for slot = 1, BAG_SLOTS do
    local item = inventory[slot]
    if type(item) == 'table' and type(item.id) == 'number' and item.id ~= 0 then return true end
  end
  return false
end

-- 0x0E0, Linkshell Equip: offset 4 the linkshell number (1 or 2), 5 the
-- inventory slot, 6 the bag. -> number, slot, bag | nil
function M.parse_equip(data)
  if type(data) ~= 'string' or #data < 7 then return nil end
  local number, slot, bag = data:byte(5, 7)
  if number ~= 1 and number ~= 2 then return nil end
  return number, slot, bag
end

-- Records a 0x0E0 in equips: the number now belongs to that item alone, and
-- slot 0 leaves it with none. -> true when the packet was understood.
function M.note_equip(equips, data)
  local number, slot, bag = M.parse_equip(data)
  if not number then return false end
  for key, n in pairs(equips) do
    if n == number then equips[key] = nil end
  end
  if slot ~= 0 then equips[bag .. ':' .. slot] = number end
  return true
end

local function same_shell(a, b)
  if a == nil or b == nil then return a == b end
  return a.name == b.name and a.color == b.color
end

-- True when two detect results have the same name and colour in each slot.
function M.same(a, b)
  return same_shell(a.ls1, b.ls1) and same_shell(a.ls2, b.ls2)
end

return M
