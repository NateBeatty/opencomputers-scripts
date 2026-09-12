-- test_base64.lua — Unit tests for Base64 encoding/decoding.
-- Run with: node test_runner.js test_base64.lua

local base64 = require("base64")

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
    error(string.format("%s: expected %q, got %q", msg or "assert_eq", b, a))
  end
end

print("=== Base64 Tests ===")

test("encode known values", function()
  assert_eq(base64.encode(""), "")
  assert_eq(base64.encode("f"), "Zg==")
  assert_eq(base64.encode("fo"), "Zm8=")
  assert_eq(base64.encode("foo"), "Zm9v")
  assert_eq(base64.encode("foob"), "Zm9vYg==")
  assert_eq(base64.encode("fooba"), "Zm9vYmE=")
  assert_eq(base64.encode("foobar"), "Zm9vYmFy")
end)

test("decode known values", function()
  assert_eq(base64.decode(""), "")
  assert_eq(base64.decode("Zg=="), "f")
  assert_eq(base64.decode("Zm8="), "fo")
  assert_eq(base64.decode("Zm9v"), "foo")
  assert_eq(base64.decode("Zm9vYg=="), "foob")
  assert_eq(base64.decode("Zm9vYmE="), "fooba")
  assert_eq(base64.decode("Zm9vYmFy"), "foobar")
end)

test("round-trip", function()
  local data = "The quick brown fox jumps over the lazy dog"
  local encoded = base64.encode(data)
  local decoded = base64.decode(encoded)
  assert_eq(decoded, data)
end)

test("binary round-trip", function()
  local data = string.char(0, 1, 2, 254, 255, 128, 129)
  local encoded = base64.encode(data)
  local decoded = base64.decode(encoded)
  assert_eq(decoded, data)
end)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed > 0 and 1 or 0)
