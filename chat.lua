--[[
Copyright (c) 2026, Rob Shelnutt
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of VanaTell nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]

-- Chat for vanatell: parses the 0x017 (incoming chat), 0x0B5 (outgoing
-- party and linkshell) and 0x0B6 (outgoing tell) packets, sanitises game text
-- for the relay, and validates phone text before it becomes a game command.
-- Packet strings are 1-indexed, so Lua byte N is packet offset N - 1.
-- Chat modes are the game's (Windower's res.chat ids): 3 tell, 4 party,
-- 5 linkshell, 27 linkshell 2. Say, shout, yell, emotes, alliance and the
-- rest are not carried. Game text is Shift-JIS (cp932) and relay text is
-- UTF-8; sjis.lua converts between them.
local chat = {}

-- A sibling file, loaded with dofile like the others in vanatell.lua.
local sjis = dofile(windower.addon_path .. 'sjis.lua')

chat.MAX_TEXT = 150

local INCOMING_CHANNELS = {[3] = 'tell', [4] = 'party', [5] = 'ls1', [27] = 'ls2'}
local OUTGOING_GROUP_CHANNELS = {[4] = 'party', [5] = 'ls1', [27] = 'ls2'}
local SEND_PREFIXES = {tell = 'input /tell ', party = 'input /p ', ls1 = 'input /l ', ls2 = 'input /l2 '}

local function is_name(s)
  return type(s) == 'string' and #s >= 3 and #s <= 15 and s:find('^[A-Za-z]+$') ~= nil
end

-- A fixed-width name field cut at its first NUL, or nil if it is not a name.
local function name_from_field(field)
  local name = field:match('^[^%z]*')
  if is_name(name) then return name end
  return nil
end

-- Removes spaces from both ends, in linear time.
local function trim(s)
  local first = s:find('[^ ]')
  if not first then return '' end
  local last = #s
  while s:byte(last) == 32 do last = last - 1 end
  return s:sub(first, last)
end

-- Game chat text (cp932) to UTF-8, or nil if nothing printable is left.
function chat.sanitize(raw)
  -- Windower can expand auto-translate blocks into the phrase text for the
  -- game's language; a block it leaves behind still becomes [AT] below.
  local w = rawget(_G, 'windower')
  if w and type(w.convert_auto_trans) == 'function' then
    local ok, converted = pcall(w.convert_auto_trans, raw)
    if ok and type(converted) == 'string' then raw = converted end
  end
  local out, i, n = {}, 1, #raw
  while i <= n do
    local b = raw:byte(i)
    local step = 1
    if b == 0x00 then
      break
    elseif b == 0xFD then
      -- Auto-translate phrase: 0xFD, a few id bytes (NULs included), 0xFD.
      local close
      for j = i + 1, math.min(i + 7, n) do
        if raw:byte(j) == 0xFD then close = j; break end
      end
      if close then
        out[#out + 1] = '[AT]'; step = close - i + 1
      else
        out[#out + 1] = '?'
      end
    elseif b == 0x1E or b == 0x1F or b == 0x7F then
      step = 2 -- colour/format code and its argument byte
    elseif b == 0x0D or b == 0x0A or b == 0x09 then
      out[#out + 1] = ' '
    elseif b < 0x20 then
      -- any other control byte is dropped
    elseif b <= 0x7E then
      out[#out + 1] = string.char(b)
    elseif b == 0xEF and (raw:byte(i + 1) == 0x27 or raw:byte(i + 1) == 0x28) then
      -- The game's auto-translate open and close marks, not cp932: shown as
      -- { and }, as the game log shows them
      out[#out + 1] = raw:byte(i + 1) == 0x27 and '{' or '}'; step = 2
    else
      -- Shift-JIS: a lead and trail byte, or halfwidth katakana; '?' if it
      -- has no character
      out[#out + 1], step = sjis.decode_char(raw, i)
    end
    i = i + step
  end
  local text = trim(table.concat(out))
  if text == '' then return nil end
  return text
end

-- Raw 0x017 packet -> {channel, sender, text}, or nil if it is not a tell,
-- party or linkshell line the relay carries.
function chat.parse_incoming(data)
  if type(data) ~= 'string' or #data < 24 then return nil end
  local channel = INCOMING_CHANNELS[data:byte(5)]
  if not channel then return nil end
  local sender = name_from_field(data:sub(9, 23))
  if not sender then return nil end
  local text = chat.sanitize(data:sub(24))
  if not text then return nil end
  return {channel = channel, sender = sender, text = text}
end

-- Raw 0x0B5 or 0x0B6 packet -> {channel, target, text}, or nil.
function chat.parse_outgoing(id, data)
  if type(data) ~= 'string' then return nil end
  if id == 0x0B5 then
    if #data < 7 then return nil end
    local channel = OUTGOING_GROUP_CHANNELS[data:byte(5)]
    if not channel then return nil end
    local text = chat.sanitize(data:sub(7))
    if not text then return nil end
    return {channel = channel, text = text}
  elseif id == 0x0B6 then
    if #data < 22 then return nil end
    local target = name_from_field(data:sub(7, 21))
    if not target then return nil end
    local text = chat.sanitize(data:sub(22))
    if not text then return nil end
    return {channel = 'tell', target = target, text = text}
  end
  return nil
end

-- Phone text -> (game command, clean text), or (nil, err). Only a tell has a
-- target; party and linkshell sends ignore it. The command is the
-- only string that reaches windower.send_command, so its text holds no
-- control bytes and no ';' (Windower splits commands on it), never starts
-- with '/' or a space, and is cp932, the game's own text. The clean text is
-- that same text in UTF-8, as the game's copy of it will read: a character
-- cp932 lacks (an emoji, say) is '?' in both.
function chat.validate_send(channel, target, text)
  local command = SEND_PREFIXES[channel]
  if not command then return nil, 'invalid channel' end
  if channel == 'tell' then
    if not is_name(target) then return nil, 'invalid target' end
    command = command .. target .. ' '
  end
  if type(text) ~= 'string' then return nil, 'invalid text' end
  text = text:gsub('[\r\n\t]+', ' ')
  text = text:gsub('[%z\1-\31\127]', '')
  text = text:gsub(';', ',')
  text = trim(text)
  if text == '' then return nil, 'empty text' end
  if text:sub(1, 1) == '/' then return nil, 'text must not start with /' end
  -- Cut at MAX_TEXT bytes, dropping a UTF-8 character the cut would split.
  local cut = text:sub(1, chat.MAX_TEXT)
  local next_byte = text:byte(chat.MAX_TEXT + 1)
  if next_byte and next_byte >= 0x80 and next_byte <= 0xBF then cut = cut:gsub('[\192-\255][\128-\191]*$', '') end
  local game = sjis.encode(trim(cut))
  return command .. game, sjis.decode(game)
end

return chat
