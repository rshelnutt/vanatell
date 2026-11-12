-- Minimal test helpers for the addon's Lua 5.1 unit tests.
--   local T = require('testlib')
--   T.test('name', function() T.eq(actual, expected) end)
--   T.done()
local T = {}

local passed, failed = 0, 0

local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function key_order(x, y)
  local tx, ty = type(x), type(y)
  if tx ~= ty then return tx < ty end
  if tx == 'number' or tx == 'string' then return x < y end
  return tostring(x) < tostring(y)
end

local function show(v)
  if type(v) == 'string' then return string.format('%q', v) end
  if type(v) ~= 'table' then return tostring(v) end
  local parts, n = {}, #v
  for i = 1, n do parts[i] = show(v[i]) end
  local keys = {}
  for k in pairs(v) do
    if not (type(k) == 'number' and k >= 1 and k <= n and k % 1 == 0) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys, key_order)
  for _, k in ipairs(keys) do
    local key
    if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
      key = k
    else
      key = '[' .. show(k) .. ']'
    end
    parts[#parts + 1] = key .. ' = ' .. show(v[k])
  end
  return '{' .. table.concat(parts, ', ') .. '}'
end

local function fail(label, msg)
  error((label and (label .. ': ') or '') .. msg, 3)
end

function T.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print('not ok - ' .. name)
    print(tostring(err))
  end
end

function T.eq(actual, expected, label)
  if not deep_eq(actual, expected) then
    fail(label, 'expected ' .. show(expected) .. ', got ' .. show(actual))
  end
end

function T.ok(v, label)
  if not v then
    fail(label, 'expected a truthy value, got ' .. show(v))
  end
end

function T.raises(fn, substring)
  local ok, err = pcall(fn)
  if ok then
    error('expected an error containing ' .. show(substring) .. ', but none was raised', 2)
  end
  err = tostring(err)
  if not err:find(substring, 1, true) then
    error('expected an error containing ' .. show(substring) .. ', got ' .. show(err), 2)
  end
end

function T.addon(name)
  local dir = os.getenv('XR_ADDON_DIR')
  if not dir then
    error('XR_ADDON_DIR is not set; source tests/env.sh', 2)
  end
  return dofile(dir .. name .. '.lua')
end

function T.done()
  print(string.format('%d passed, %d failed', passed, failed))
  os.exit(failed == 0 and 0 or 1)
end

return T
