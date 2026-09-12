-- test_crc32.lua — Unit tests for CRC-32.
-- Run with: node test_runner.js test_crc32.lua

local crc32 = require("crc32")

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
    error(string.format("%s: expected 0x%08x, got 0x%08x", msg or "assert_eq", b, a))
  end
end

print("=== CRC32 Tests ===")

test("CRC32 known value", function()
  -- "123456789" -> 0xCBF43926 (standard CRC-32 test vector)
  local data = "123456789"
  assert_eq(crc32.calc(data), 0xCBF43926)
end)

test("CRC32 empty string", function()
  assert_eq(crc32.calc(""), 0x00000000)
end)

test("CRC32 readLE/writeLE round-trip", function()
  local crc = 0xDEADBEEF
  local bytes = crc32.writeLE(crc)
  assert_eq(#bytes, 4)
  local read = crc32.readLE(bytes, 1)
  assert_eq(read, crc)
end)

test("CRC32 range-limited", function()
  local data = "hello world, this is a test of CRC"
  local full = crc32.calc(data)
  local partial = crc32.calc(data, 1, 5) -- just "hello"
  -- "hello" CRC32 is a known value
  assert_eq(partial, 0x3610A686)
end)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed > 0 and 1 or 0)
