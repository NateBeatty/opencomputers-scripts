-- test_pbtiles.lua — Unit tests for the parallel builder's tile maths.
-- Run with: node converter/test/run_lua_tests.js gtnh/parallel-build/test/test_pbtiles.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../lib/?.lua;" .. package.path

local tiles = require("pbtiles")

passed = 0
failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("  PASS: " .. name)
    passed = passed + 1
  else
    print("  FAIL: " .. name .. " — " .. tostring(err))
    failed = failed + 1
  end
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("%s: expected %s, got %s", msg or "assert_eq", tostring(b), tostring(a)), 2)
  end
end

print("=== Tile Tests ===")

test("layer1 grid: 17 x 17 tiles, 15-wide edge tiles", function()
  local g = tiles.grid(271, 9, 271, 16)
  assert_eq(g.tilesX, 17, "tilesX")
  assert_eq(g.tilesZ, 17, "tilesZ")
  assert_eq(g.count, 289, "count")
  local x0, z0, w, l = tiles.bounds(g, 288)
  assert_eq(x0, 256, "x0"); assert_eq(z0, 256, "z0")
  assert_eq(w, 15, "w"); assert_eq(l, 15, "l")
end)

test("every cell is in exactly the tile whose bounds hold it", function()
  local g = tiles.grid(37, 3, 21, 8)
  local seen = {}
  for id = 0, g.count - 1 do
    local x0, z0, w, l = tiles.bounds(g, id)
    for x = x0, x0 + w - 1 do
      for z = z0, z0 + l - 1 do
        local key = x .. "," .. z
        if seen[key] then error("cell in two tiles: " .. key) end
        seen[key] = true
        assert_eq(tiles.tileOf(g, x, z), id, "tileOf " .. key)
      end
    end
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  assert_eq(n, 37 * 21, "cells covered")
  assert_eq(tiles.tileOf(g, -1, 0), tiles.COLUMN, "column")
  assert_eq(tiles.tileOf(g, -1, 1), nil, "outside")
  assert_eq(tiles.tileOf(g, 37, 0), nil, "past the east edge")
end)

test("serpentine covers a tile layer once, in adjacent steps, layers chained", function()
  for _, size in ipairs({ { 16, 16 }, { 15, 16 }, { 16, 15 }, { 1, 5 }, { 7, 1 } }) do
    local w, l = size[1], size[2]
    local lastX, lastZ
    for layer = 0, 3 do
      local seen = {}
      for index = 0, w * l - 1 do
        local x, z = tiles.cellPosition(layer, index, w, l)
        if x < 0 or x >= w or z < 0 or z >= l then error("out of tile") end
        local key = x .. "," .. z
        if seen[key] then error("visited twice: " .. key) end
        seen[key] = true
        if lastX then
          local step = math.abs(x - lastX) + math.abs(z - lastZ)
          -- Within a layer each step is one cell; between layers the robot
          -- only changes height, unless the layer ends on the other side.
          if index > 0 and step ~= 1 then
            error(string.format("jump of %d at layer %d index %d (%dx%d)", step, layer, index, w, l))
          end
        end
        lastX, lastZ = x, z
      end
    end
  end
end)

test("routes fly only over passable tiles", function()
  local g = tiles.grid(48, 5, 48, 16)   -- 3 x 3 tiles
  local open = { [0] = true, [1] = true, [4] = true }
  local route = tiles.path(g, tiles.COLUMN, 7, function(id) return open[id] end)
  -- column -> 0 -> 1 -> 4 -> 7
  assert_eq(#route, 5, "route length")
  assert_eq(route[1], tiles.COLUMN); assert_eq(route[2], 0); assert_eq(route[3], 1)
  assert_eq(route[4], 4); assert_eq(route[5], 7)
  assert_eq(tiles.path(g, 0, 8, function(id) return open[id] end), nil, "8 is unreachable")
  assert_eq(#tiles.path(g, 4, 4, function() return false end), 1, "already there")
end)

test("clamp, distance and flag packing", function()
  local g = tiles.grid(48, 5, 48, 16)
  local x, z = tiles.clampInto(g, 4, 3, 40)
  assert_eq(x, 16, "clamp x"); assert_eq(z, 31, "clamp z")
  assert_eq(tiles.distance(g, tiles.COLUMN, 0), 1, "column to 0")
  assert_eq(tiles.distance(g, 0, 8), 4, "0 to 8")
  local packed = tiles.encodeFlags({ [0] = true, [5] = true, [8] = true }, g.count)
  assert_eq(packed, "100001001", "packed")
  local flags = tiles.decodeFlags(packed)
  assert_eq(flags[0], true); assert_eq(flags[5], true); assert_eq(flags[8], true)
  assert_eq(flags[1], nil)
end)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
