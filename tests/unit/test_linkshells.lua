local T = require('testlib'); local L = T.addon('linkshells'); local P = require('xr_packets')
-- Game data the way the addon gets it: bags by number (or by get_items() name), items with a status, and a
-- decode that stands in for Windower's extdata.decode by returning the table the test put on the item.
local function shell(name, r, g, b, status) return {id = 513, status = status or 19, decoded = {type = 'Linkshell', name = name, r = r or 0, g = g or 0, b = b or 0}} end
local function decode(item) if item.boom then error(item.boom) end; return item.decoded end
local KUPO, MOG = {name = 'KupoKnights', color = '#A8E6A1'}, {name = 'MogPost', color = '#112233'}
local function bag(items) local t = {max = 80, count = 0, enabled = true}; for slot, item in pairs(items) do t[slot] = item end; return t end
T.test('both equipped: the shell named in player.linkshell is ls1, the other ls2', function()
  local bags = {[0] = bag{[3] = shell('MogPost', 0x11, 0x22, 0x33), [7] = shell('KupoKnights', 168, 230, 161), [9] = shell('Unworn', 1, 2, 3, 0)}}
  T.eq(L.detect({name = 'Me', linkshell = 'KupoKnights'}, bags, decode, {}), {ls1 = KUPO, ls2 = MOG})
  T.eq(L.detect({name = 'Me', linkshell = 'MogPost'}, bags, decode, {}), {ls1 = MOG, ls2 = KUPO})
end)
T.test('the equips map wins over the name match; the other shell takes the slot left over', function()
  local bags = {[0] = bag{[3] = shell('MogPost', 0x11, 0x22, 0x33), [7] = shell('KupoKnights', 168, 230, 161)}}
  T.eq(L.detect({linkshell = 'KupoKnights'}, bags, decode, {['0:7'] = 2}), {ls1 = MOG, ls2 = KUPO})
  T.eq(L.detect({linkshell = ''}, bags, decode, {['0:7'] = 2}), {ls1 = MOG, ls2 = KUPO})
  T.eq(L.detect({linkshell = 'KupoKnights'}, bags, decode, {['0:3'] = 1}), {ls1 = MOG, ls2 = KUPO})
  T.eq(L.detect({linkshell = 'KupoKnights'}, bags, decode, {['0:3'] = 1, ['0:7'] = 2}), {ls1 = MOG, ls2 = KUPO})
  -- A mapping to an item that is not equipped any more is ignored.
  T.eq(L.detect({linkshell = 'KupoKnights'}, {[0] = bag{[7] = shell('KupoKnights', 168, 230, 161)}}, decode, {['0:3'] = 1}), {ls1 = KUPO})
end)
T.test('with no player.linkshell, one equipped shell is ls2; two unmapped others keep only the first', function()
  local one = {[0] = bag{[4] = shell('KupoKnights', 168, 230, 161)}}
  T.eq(L.detect({linkshell = ''}, one, decode, {}), {ls2 = KUPO})
  T.eq(L.detect({name = 'Me'}, one, decode, {}), {ls2 = KUPO})
  T.eq(L.detect(nil, one, decode, nil), {ls2 = KUPO})
  T.eq(L.detect({linkshell = 'Gone'}, one, decode, {}), {ls2 = KUPO})
  local two = {[0] = bag{[4] = shell('KupoKnights', 168, 230, 161), [5] = shell('MogPost', 0x11, 0x22, 0x33)}}
  T.eq(L.detect({linkshell = ''}, two, decode, {}), {ls2 = KUPO})
  T.eq(L.detect({linkshell = ''}, {}, decode, {}), {}); T.eq(L.detect({linkshell = ''}, nil, decode, {}), {})
end)
T.test('colour is #RRGGBB in uppercase hex, each part a whole number from 0 to 255', function()
  T.eq(L.color(168, 230, 161), '#A8E6A1'); T.eq(L.color(0, 15, 255), '#000FFF'); T.eq(L.color(17, 34, 51), '#112233')
  T.eq(L.color(300, -5, 12.9), '#FF000C'); T.eq(L.color(nil, 'x', '16'), '#000010')
  T.eq(L.detect({linkshell = 'A'}, {[0] = bag{[1] = shell('A', 0xAB, 0xCD, 0xEF)}}, decode, {}).ls1.color, '#ABCDEF')
end)
T.test('wardrobes 1 to 8 are scanned; other bags are not', function()
  local bags = {[1] = bag{[1] = shell('Safe')}, [8] = bag{[2] = shell('KupoKnights', 168, 230, 161)}, [9] = bag{[1] = shell('Safetwo')},
                [16] = bag{[80] = shell('MogPost', 0x11, 0x22, 0x33)}}
  T.eq(L.detect({linkshell = 'KupoKnights'}, bags, decode, {}), {ls1 = KUPO, ls2 = MOG})
  for _, id in ipairs({10, 11, 12, 13, 14, 15}) do
    T.eq(L.detect({linkshell = 'X'}, {[id] = bag{[1] = shell('X')}}, decode, {}), {ls1 = {name = 'X', color = '#000000'}}, 'bag ' .. id)
  end
  -- windower.ffxi.get_items() keys its bags by name; the equips map still uses the bag number.
  local named = {inventory = bag{[2] = shell('MogPost', 0x11, 0x22, 0x33)}, wardrobe8 = bag{[5] = shell('KupoKnights', 168, 230, 161)},
                 safe = bag{[1] = shell('Safe')}, gil = 100}
  T.eq(L.detect({linkshell = 'MogPost'}, named, decode, {}), {ls1 = MOG, ls2 = KUPO})
  T.eq(L.detect({linkshell = 'MogPost'}, named, decode, {['16:5'] = 1}), {ls1 = KUPO, ls2 = MOG})
end)
T.test('a decode that fails, is not a linkshell or has no usable name is ignored', function()
  local bad = {{boom = 'bad extdata'}, {decoded = nil}, {decoded = 'Linkshell'}, {decoded = {type = 'General', name = 'X'}},
    {decoded = {type = 'Linkshell'}}, {decoded = {type = 'Linkshell', name = ''}}, {decoded = {type = 'Linkshell', name = 42}},
    {decoded = {type = 'Linkshell', name = 'Kupo Knights'}}, {decoded = {type = 'Linkshell', name = ('A'):rep(21)}},
    {decoded = {type = 'Linkshell', name = 'Kup\0'}}}
  local items = {}
  for i, item in ipairs(bad) do item.status = 19; items[i] = item end
  items[20] = shell("Kupo'Knights", 168, 230, 161); items[21] = 'junk'
  T.eq(L.detect({linkshell = "Kupo'Knights"}, {[0] = bag(items)}, decode, {}), {ls1 = {name = "Kupo'Knights", color = '#A8E6A1'}})
  T.eq(L.detect({linkshell = 'X'}, {[0] = bag{[1] = shell(('A'):rep(20))}}, decode, {}).ls2.name, ('A'):rep(20))
end)
T.test('0x0E0 builds the equips map: one item per number, slot 0 clears it, junk is ignored', function()
  local equips = {}
  T.eq(L.note_equip(equips, P.linkshell_equip(1, 5, 0)), true); T.eq(equips, {['0:5'] = 1})
  L.note_equip(equips, P.linkshell_equip(2, 12, 8)); T.eq(equips, {['0:5'] = 1, ['8:12'] = 2})
  L.note_equip(equips, P.linkshell_equip(1, 7, 0)); T.eq(equips, {['0:7'] = 1, ['8:12'] = 2})
  L.note_equip(equips, P.linkshell_equip(1, 12, 8)); T.eq(equips, {['8:12'] = 1})
  L.note_equip(equips, P.linkshell_equip(2, 0, 0)); T.eq(equips, {['8:12'] = 1})
  L.note_equip(equips, P.linkshell_equip(1, 0, 0)); T.eq(equips, {})
  for _, data in ipairs({P.linkshell_equip(0, 5, 0), P.linkshell_equip(3, 5, 0), string.char(0xE0, 0, 0, 0, 1, 5), 42}) do
    T.eq(L.note_equip(equips, data), false); T.eq(equips, {})
  end
end)
T.test('same compares name and colour in each slot', function()
  T.ok(L.same({}, {})); T.ok(L.same({ls1 = KUPO}, {ls1 = {name = 'KupoKnights', color = '#A8E6A1'}}))
  T.eq(L.same({ls1 = KUPO}, {ls2 = KUPO}), false); T.eq(L.same({ls1 = KUPO}, {ls1 = {name = 'KupoKnights', color = '#A8E6A2'}}), false)
  T.eq(L.same({ls1 = KUPO, ls2 = MOG}, {ls1 = KUPO}), false); T.eq(L.same({ls2 = MOG}, {ls2 = {name = 'Mogpost', color = '#112233'}}), false)
end)
T.done()
