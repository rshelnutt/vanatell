-- Stand-in for Windower's libs/extdata.lua, which needs the game's resource
-- tables: decode(item) returns the table a test put on item.decoded, and
-- raises item.boom when it is set, as the real one can for data it cannot read.
local extdata = {}

function extdata.decode(item)
  if item.boom then error(item.boom) end
  return item.decoded
end

return extdata
