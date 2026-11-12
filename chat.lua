-- Chat for vanatell: parses the 0x017 (incoming chat), 0x0B5 (outgoing
-- linkshell) and 0x0B6 (outgoing tell) packets, sanitises game text for the
-- relay, and validates phone text before it becomes a game command.
-- Packet strings are 1-indexed, so Lua byte N is packet offset N - 1.
local chat = {}

chat.MAX_TEXT = 150

local INCOMING_CHANNELS = {[3] = 'tell', [5] = 'ls1', [27] = 'ls2'}
local OUTGOING_LS_CHANNELS = {[5] = 'ls1', [27] = 'ls2'}
local SEND_PREFIXES = {tell = 'input /tell ', ls1 = 'input /l ', ls2 = 'input /l2 '}

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

-- Game chat text to printable ASCII, or nil if nothing printable is left.
function chat.sanitize(raw)
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
    elseif ((b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xFC)) and i < n then
      out[#out + 1] = '?'; step = 2 -- Shift-JIS lead and trail byte
    else
      out[#out + 1] = '?'
    end
    i = i + step
  end
  local text = trim(table.concat(out))
  if text == '' then return nil end
  return text
end

-- Raw 0x017 packet -> {channel, sender, text}, or nil if it is not a tell or
-- linkshell line the relay carries.
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
    local channel = OUTGOING_LS_CHANNELS[data:byte(5)]
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

-- Phone text -> (game command, clean text), or (nil, err). The command is the
-- only string that reaches windower.send_command, so the clean text holds
-- only printable ASCII, no ';' (Windower splits commands on it), and never
-- starts with '/' or a space.
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
  text = text:gsub('[\192-\247][\128-\191]*', '?')
  text = text:gsub('[\128-\255]', '?')
  text = text:gsub(';', ',')
  text = trim(text)
  if text == '' then return nil, 'empty text' end
  if text:sub(1, 1) == '/' then return nil, 'text must not start with /' end
  text = trim(text:sub(1, chat.MAX_TEXT))
  return command .. text, text
end

return chat
