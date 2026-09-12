-- test_plan.lua — Tests for the plan format reader against golden plans.
-- Run with: node test_runner.js test_plan.lua
-- Requires the converter's golden plan files in converter/test/.

local plan = require("plan")

local passed = 0
local failed = 0

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
    error(string.format("%s: expected %s, got %s", msg or "assert_eq", tostring(b), tostring(a)))
  end
end

-- Read a file from the converter's test directory.
-- The test runner provides a readFile function that uses Node.js fs.
local function readGoldenFile(filename)
  -- Try a few plausible paths (converter/test/, ../converter/test/, etc.)
  local paths = {
    "converter/test/" .. filename,
    "../converter/test/" .. filename,
    "test/" .. filename,
    "../../converter/test/" .. filename,
  }
  for _, p in ipairs(paths) do
    local data, err = readFile(p)
    if data then
      return data
    end
  end
  error("Could not find golden file: " .. filename)
end

print("=== Plan Reader Tests ===")

test("parse header from tree5.plan", function()
  local raw = readGoldenFile("tree5.plan")
  local p = plan.decode(raw)

  assert_eq(p.header.formatVersion, 1)
  assert_eq(p.header.width, 22, "width")
  assert_eq(p.header.height, 29, "height")
  assert_eq(p.header.length, 23, "length")
  assert_eq(p.header.planVersion, 0, "planVersion")
  assert_eq(p.name, "tree5", "name")
  assert_eq(p.palette[1].itemName, "log", "palette item")
  assert_eq(p.palette[1].damage, 1, "palette damage")
  assert_eq(p.palette[1].blockName, "log", "blockName")
  assert_eq(p.palette[1].meta, 1, "blockMeta")
  assert_eq(p.palette[1].flags, 1, "flags (orient)") -- 0x01 = FLAG_ORIENT
  assert_eq(#p.layers, 29, "layer count")
  assert_eq(#p.layerOffsets, 29, "offset count")
  -- Each layer should be W*L = 22*23 = 506 cells
  for y = 1, 29 do
    assert_eq(#p.layers[y], 506, "layer " .. y .. " size")
  end
end)

test("cellAt returns correct palette indices", function()
  local raw = readGoldenFile("tree5.plan")
  local p = plan.decode(raw)
  local W = p.header.width

  -- Layer 0: from the converter output, we know the layout.
  -- The manifest says 69 placed cells total across all layers.
  -- Let's just verify cellAt works by checking a few known cells.
  local layer0 = p.layers[1]

  -- Cell (0,0) should be palette index 0 (AIR) for tree5 (mostly air).
  local c = plan.cellAt(layer0, 0, 0, W)
  assert_eq(c, 0, "cell (0,0,0) is air")

  -- Find a non-air cell in layer 0.
  local found = false
  for x = 0, W - 1 do
    for z = 0, p.header.length - 1 do
      local c = plan.cellAt(layer0, x, z, W)
      if c > 1 then
        found = true
        assert(c <= #p.palette + 1, "palette index in range")
        break
      end
    end
    if found then break end
  end
  assert(found, "found at least one placed block")
end)

test("cellIndex math", function()
  assert_eq(plan.cellIndex(0, 0, 10), 0)
  assert_eq(plan.cellIndex(5, 0, 10), 5)
  assert_eq(plan.cellIndex(0, 1, 10), 10)
  assert_eq(plan.cellIndex(9, 3, 10), 9 + 3 * 10)
end)

test("palette constants", function()
  assert_eq(plan.PALETTE_AIR, 0)
  assert_eq(plan.PALETTE_SKIP, 1)
  assert_eq(plan.PALETTE_BASE, 2)
  assert_eq(plan.FLAG_ORIENT, 0x01)
  assert_eq(plan.FLAG_TILEENTITY, 0x02)
end)

test("bad magic rejected", function()
  local bad = "XXXX" .. string.rep("\0", 20)
  local ok, err = pcall(plan.decode, bad)
  assert(not ok, "should reject bad magic")
  assert(tostring(err):find("Bad magic"), "error should mention magic")
end)

test("CRC mismatch detected", function()
  local raw = readGoldenFile("tree5.plan")
  -- Corrupt a byte in the body.
  local corrupted = raw:sub(1, 25) .. "\xFF" .. raw:sub(27)
  local ok, err = pcall(plan.decode, corrupted)
  assert(not ok, "should reject CRC mismatch")
  assert(tostring(err):find("CRC"), "error should mention CRC")
end)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed > 0 and 1 or 0)
