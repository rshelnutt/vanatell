--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- Linkshells for vanatell: which linkshell is equipped in slot 1 and slot 2,
-- worked out from game data passed in (so it runs outside the game too), the
-- linkshell equip packet (0x0E0) that says which item went where, and the
-- linkshell message packet (0x0CC), the reply to /lsmes and /ls2mes, which
-- names the linkshell in the slot that was asked.
-- Packet strings are 1-indexed, so Lua byte N is packet offset N - 1.
local M = {}

M.EQUIPPED = 19  -- item status of an equipped linkshell
M.NAME_MAX = 20  -- longest linkshell name
local BAG_SLOTS = 80

-- The bags a linkshell is equipped from: the inventory and the Mog Satchel,
-- Sack and Case (a pearl equipped from the satchel is seen in game: 0x0E0
-- names bag 5). Wardrobes never hold linkshells. {bag number, the bag's key in
-- windower.ffxi.get_items()}.
M.BAGS = {{0, 'inventory'}, {5, 'satchel'}, {6, 'sack'}, {7, 'case'}}

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

-- The equipped shells, in bag and slot order.
-- player = windower.ffxi.get_player(): player.linkshell names a shell the
--   game has equipped ('' or nil when none), and player.linkshell_slot is
--   that shell's inventory slot.
-- bags = windower.ffxi.get_items(), bags keyed by number or by name.
-- decode = extdata.decode.
-- equips = {['bag:slot'] = 1 or 2}: the slot number the game gave an item, in
--   a 0x0E0 packet or a linkshell message.
-- -> {{key = 'bag:slot', shell = {name =, color =}}, ...}
-- An item counts as an equipped shell when the game flags it so (status 19),
-- when the equips map names its bag and slot, or when it is the inventory
-- item at player.linkshell_slot and carries player.linkshell's name. Any
-- other status, a shell set for sale in the bazaar (25) among them, is not
-- equipped. Whether the item is a linkshell, a pearlsack or a linkpearl says
-- nothing about which slot it is in.
function M.equipped(player, bags, decode, equips)
  equips = type(equips) == 'table' and equips or {}
  local primary = type(player) == 'table' and player.linkshell or nil
  local primary_slot = type(player) == 'table' and tonumber(player.linkshell_slot) or nil
  local found = {}
  if type(bags) ~= 'table' then return found end
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
  return found
end

-- found = M.equipped(...) -> {ls1 = {name =, color =} | nil, ls2 = ...}
-- A shell the equips map places goes to that slot. For the rest the game
-- gives no slot number, so the shell named in player.linkshell is ls1 and
-- any other ls2, until the game says otherwise.
-- Two shells never share a slot: when the slot a shell would take holds a
-- shell the equips map placed, it takes the other slot; when it holds one
-- placed by name, it is left out.
function M.assign(found, player, equips)
  equips = type(equips) == 'table' and equips or {}
  local primary = type(player) == 'table' and player.linkshell or nil
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

-- -> {ls1 = {name =, color =} | nil, ls2 = ...}
function M.detect(player, bags, decode, equips)
  return M.assign(M.equipped(player, bags, decode, equips), player, equips)
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

-- Gives a slot number to the item at key ('bag:slot'): the number now
-- belongs to that item alone.
function M.place(equips, key, number)
  for k, n in pairs(equips) do
    if n == number then equips[k] = nil end
  end
  equips[key] = number
end

-- A name without the apostrophes that end it: the padding after a short name
-- in a linkshell message can read as apostrophes.
local function bare(name)
  return (name:gsub("'+$", ''))
end

-- The game said the linkshell called one of names is in slot number (1 or
-- 2): places that shell in the equips map and, when it is one of exactly two
-- equipped shells, the other one in the other slot. found = M.equipped(...).
-- -> true when exactly one equipped shell has one of the names.
function M.confirm(equips, found, names, number)
  if type(names) == 'string' then names = {names} end
  if type(names) ~= 'table' or (number ~= 1 and number ~= 2) then return false end
  local wanted = {}
  for _, name in ipairs(names) do if type(name) == 'string' then wanted[bare(name)] = true end end
  local match, other
  for _, f in ipairs(found) do
    if wanted[bare(f.shell.name)] then
      if match then return false end
      match = f
    else
      other = f
    end
  end
  if not match then return false end
  M.place(equips, match.key, number)
  if #found == 2 then M.place(equips, other.key, 3 - number) end
  return true
end

-- What is equipped, as one string: it changes when a shell or its bag slot does.
function M.signature(found)
  local parts = {}
  for i, f in ipairs(found) do parts[i] = f.key .. '=' .. f.shell.name end
  table.sort(parts)
  return table.concat(parts, ',')
end

-- 0x0CC, Linkshell Message, the reply to /lsmes and /ls2mes: its last field
-- is the linkshell's name, 15 bytes packed as an item's linkshell name is: 6
-- bits a character, most significant bit first, 0 the apostrophe, 1 to 26 a
-- to z, 27 to 52 A to Z, and any other value ends the name. Windower's packet
-- notes put the field at 0x9C, its field sizes at 0xA0; both put it last, so
-- it is read at all three places: 16 bytes before the end, 0x9C and 0xA0.
-- -> the distinct names read, as a list (empty when none reads as a name)
local NAME_BYTES = 15
local NAME_CHARS = "'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

local function name_at(data, at)
  local out, bit = {}, 0
  while #out < M.NAME_MAX and bit + 6 <= NAME_BYTES * 8 do
    local v = 0
    for i = bit, bit + 5 do
      local b = data:byte(at + 1 + math.floor(i / 8)) or 0
      v = v * 2 + math.floor(b / 2 ^ (7 - i % 8)) % 2
    end
    if v > 52 then break end
    out[#out + 1] = NAME_CHARS:sub(v + 1, v + 1)
    bit = bit + 6
  end
  local name = bare(table.concat(out))
  if is_name(name) then return name end
  return nil
end

function M.message_names(data)
  local names, seen = {}, {}
  if type(data) ~= 'string' or #data < 0x9C + NAME_BYTES then return names end
  for _, at in ipairs({#data - 16, 0x9C, 0xA0}) do
    local name = at >= 0 and at + NAME_BYTES <= #data and name_at(data, at)
    if name and not seen[name] then seen[name], names[#names + 1] = true, name end
  end
  return names
end

-- The equips map kept per character in the settings, so a reload starts with
-- the slots the game last sent: "Name/bag:slot=n,bag:slot=n;Name/...".
-- -> the map for name ({} when none), and the string with name's map replaced.
local function valid_key(k) return type(k) == 'string' and k:match('^%d+:%d+$') ~= nil end

function M.load_equips(saved, name)
  local map = {}
  if type(saved) ~= 'string' or type(name) ~= 'string' or name == '' then return map end
  for entry in saved:gmatch('[^;]+') do
    local who, pairs_ = entry:match('^([^/]+)/(.*)$')
    if who == name then
      for key, n in pairs_:gmatch('([^,=]+)=(%d)') do
        n = tonumber(n)
        if valid_key(key) and (n == 1 or n == 2) then map[key] = n end
      end
    end
  end
  return map
end

function M.save_equips(saved, name, equips)
  if type(name) ~= 'string' or name == '' or name:find('[/;]') then return saved end
  local kept = {}
  if type(saved) == 'string' then
    for entry in saved:gmatch('[^;]+') do
      if entry:match('^([^/]+)/') ~= name then kept[#kept + 1] = entry end
    end
  end
  local keys = {}
  for key, n in pairs(type(equips) == 'table' and equips or {}) do
    if valid_key(key) and (n == 1 or n == 2) then keys[#keys + 1] = key .. '=' .. n end
  end
  table.sort(keys)
  if #keys > 0 then kept[#kept + 1] = name .. '/' .. table.concat(keys, ',') end
  return table.concat(kept, ';')
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
