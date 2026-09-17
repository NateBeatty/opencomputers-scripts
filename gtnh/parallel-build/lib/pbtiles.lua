-- pbtiles.lua — Tile maths for the parallel builder.
--
-- The build box is cut into square tiles (16x16 by default), each the full
-- height of the box. Coordinates are plan cells: x in [0, W), z in [0, L),
-- with (0, 0) the NW corner. The start column sits just outside the box at
-- x = -1, z = 0; it is not a tile, and is represented by the id COLUMN.
--
-- Tile ids run 0 .. count-1, row by row: id = tx + tz * tilesX.

local tiles = {}

tiles.COLUMN = -1

--- Describe how a W x H x L box is cut into tiles of `size` cells.
function tiles.grid(W, H, L, size)
  local g = { W = W, H = H, L = L, size = size }
  g.tilesX = (W + size - 1) // size
  g.tilesZ = (L + size - 1) // size
  g.count = g.tilesX * g.tilesZ
  return g
end

--- Tile column and row of a tile id.
function tiles.coords(g, id)
  return id % g.tilesX, id // g.tilesX
end

function tiles.id(g, tx, tz)
  return tx + tz * g.tilesX
end

--- A tile's cells: x0, z0, width, length. Edge tiles can be narrower.
function tiles.bounds(g, id)
  local tx, tz = tiles.coords(g, id)
  local x0, z0 = tx * g.size, tz * g.size
  return x0, z0, math.min(g.size, g.W - x0), math.min(g.size, g.L - z0)
end

--- The tile holding cell (x, z): a tile id, COLUMN, or nil outside the box.
function tiles.tileOf(g, x, z)
  if x == -1 and z == 0 then return tiles.COLUMN end
  if x < 0 or z < 0 or x >= g.W or z >= g.L then return nil end
  return tiles.id(g, x // g.size, z // g.size)
end

--- Tiles sharing an edge with `id`. The column only leads into tile 0; robots
--- never travel back into it.
function tiles.neighbors(g, id)
  if id == tiles.COLUMN then return { 0 } end
  local tx, tz = tiles.coords(g, id)
  local out = {}
  if tx > 0 then out[#out + 1] = id - 1 end
  if tx < g.tilesX - 1 then out[#out + 1] = id + 1 end
  if tz > 0 then out[#out + 1] = id - g.tilesX end
  if tz < g.tilesZ - 1 then out[#out + 1] = id + g.tilesX end
  return out
end

--- Distance in tiles between two tiles (either may be COLUMN).
function tiles.distance(g, a, b)
  local ax, az, bx, bz
  if a == tiles.COLUMN then ax, az = -1, 0 else ax, az = tiles.coords(g, a) end
  if b == tiles.COLUMN then bx, bz = -1, 0 else bx, bz = tiles.coords(g, b) end
  return math.abs(ax - bx) + math.abs(az - bz)
end

--- The nearest cell of tile `id` to cell (x, z).
function tiles.clampInto(g, id, x, z)
  local x0, z0, w, l = tiles.bounds(g, id)
  return math.max(x0, math.min(x0 + w - 1, x)), math.max(z0, math.min(z0 + l - 1, z))
end

--- Cell `index` of `layer` inside a w x l tile, as tile-local (x, z).
--- Rows run along X and step along Z; X alternates per row and Z per layer, so
--- consecutive cells are adjacent and each layer starts where the last ended.
--- The same serpentine as build.lua, applied to one tile.
function tiles.cellPosition(layer, index, w, l)
  local row = index // w
  local col = index % w
  local z = (layer % 2 == 0) and row or (l - 1 - row)
  local x = (row % 2 == 0) and col or (w - 1 - col)
  return x, z
end

--- Shortest route of tiles from `from` to `to`, flying only over tiles for
--- which passable(id) is true (`from` and `to` themselves always count).
--- @return a list starting with `from` and ending with `to`, or nil
function tiles.path(g, from, to, passable)
  if from == to then return { from } end
  local prev = { [from] = from }
  local queue, head = { from }, 1
  while queue[head] ~= nil do
    local cur = queue[head]
    head = head + 1
    for _, n in ipairs(tiles.neighbors(g, cur)) do
      if prev[n] == nil and (n == to or passable(n)) then
        prev[n] = cur
        if n == to then
          local route = { to }
          local node = to
          while node ~= from do
            node = prev[node]
            table.insert(route, 1, node)
          end
          return route
        end
        queue[#queue + 1] = n
      end
    end
  end
  return nil
end

--- Pack a set of tile ids ({[id] = true}) into a "0101..." string for a message.
function tiles.encodeFlags(flags, count)
  local parts = {}
  for id = 0, count - 1 do
    parts[#parts + 1] = flags[id] and "1" or "0"
  end
  return table.concat(parts)
end

function tiles.decodeFlags(s)
  local flags = {}
  for i = 1, #(s or "") do
    if s:sub(i, i) == "1" then flags[i - 1] = true end
  end
  return flags
end

return tiles
