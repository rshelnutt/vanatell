-- Builds raw FFXI chat packets for the addon's unit tests. Each packet has a
-- 4-byte header (id low byte, then 3 zero bytes) and is NUL-padded to a
-- multiple of 4 bytes, so Lua byte 1 is packet offset 0x00.
--   local P = require('xr_packets')
--   P.incoming_chat(3, 'Kupo', 'hey')   -- 0x017
--   P.outgoing_ls(5, 'hi all')          -- 0x0B5
--   P.outgoing_tell('Kupo', 'yo')       -- 0x0B6
--   P.linkshell_equip(1, 5, 0)          -- 0x0E0
--   P.zone_in()                         -- 0x00A
local P = {}

local function name_field(name)
  return name .. ('\0'):rep(15 - #name)
end

local function packet(id, body)
  local data = string.char(id % 256, 0, 0, 0) .. body
  return data .. ('\0'):rep((4 - #data % 4) % 4)
end

-- mode, GM flag 0, 2 pad bytes, sender NUL-padded to 15, text, NUL
function P.incoming_chat(mode, sender, text)
  return packet(0x017, string.char(mode, 0, 0, 0) .. name_field(sender) .. text .. '\0')
end

-- mode, GM flag 0, text, NUL
function P.outgoing_ls(mode, text)
  return packet(0x0B5, string.char(mode, 0) .. text .. '\0')
end

-- bytes 3, 0, target NUL-padded to 15, text, NUL
function P.outgoing_tell(target, text)
  return packet(0x0B6, string.char(3, 0) .. name_field(target) .. text .. '\0')
end

-- linkshell number (1 or 2), inventory slot, bag, 1 pad byte
function P.linkshell_equip(number, slot, bag)
  return packet(0x0E0, string.char(number, slot, bag, 0))
end

-- Only the header matters to the addon: the body is zeros.
function P.zone_in()
  return packet(0x00A, ('\0'):rep(16))
end

return P
