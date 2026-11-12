local T = require('testlib'); local src = os.getenv('XR_ADDON_DIR')
T.test('addon folder holds exactly the six shipped files', function()
  local p = io.popen('ls -p "' .. src .. '" | grep -v /'); local names = {}
  for n in p:lines() do names[#names + 1] = n end; p:close(); table.sort(names)
  T.eq(names, {'README.md', 'cacert.pem', 'chat.lua', 'json.lua', 'vanatell.lua', 'ws.lua'})
end)
T.test('a copied install loads on its own', function()
  local dir = os.tmpname(); os.remove(dir); local target = dir .. '/Windower4/addons/vanatell/'
  assert(os.execute('mkdir -p "' .. target .. '" && cp "' .. src .. '"*.lua "' .. src .. '"*.pem "' .. src .. '"*.md "' .. target .. '"') == 0)
  local W = require('windower_stub').install{addon_path = target}; require('config')._reset(); __vanatell_test = nil
  dofile(target .. 'vanatell.lua'); W.fire('load')
  T.eq(W.lines(), {'vanatell: not paired: set the relay with //vt url wss://<host>, then //vt pair <code>'})
  os.execute('rm -rf "' .. dir .. '"')
end)
T.test('README covers install, pairing and third-party sources', function()
  local r = io.open(src .. 'README.md'):read('*a')
  for _, s in ipairs({'Windower4/addons/vanatell', '//lua load vanatell', '//vt url wss://', '//vt pair', '//vt status', '//vt unpair',
      'settings.xml', 'https://raw.githubusercontent.com/rxi/json.lua/v0.1.2/json.lua', 'https://curl.se/ca/cacert.pem'}) do
    T.ok(r:find(s, 1, true), s)
  end
end)
T.done()
