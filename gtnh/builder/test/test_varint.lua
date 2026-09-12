-- test_varint.lua — Unit tests for varint (LEB128) encoding/decoding.
-- Run with: node test_runner.js test_varint.lua

local varint = require("varint")

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

print("=== Varint Tests ===")

test("encode/decode small values", function()
  for _, v in ipairs({0, 1, 127, 128, 255, 256, 16383, 16384, 1000000}) do
    local encoded = varint.encode(v)
    local decoded, len = varint.decode(encoded)
    assert_eq(decoded, v, "value " .. v)
    assert_eq(len, #encoded, "length " .. v)
  end
end)

test("varint round-trip with append", function()
  local buf = {}
  for _, v in ipairs({42, 0, 65535, 123456}) do
    varint.append(buf, v)
  end
  local data = table.concat(buf)
  local pos = 1
  for _, v in ipairs({42, 0, 65535, 123456}) do
    local decoded, len = varint.decode(data, pos)
    assert_eq(decoded, v)
    pos = pos + len
  end
end)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed > 0 and 1 or 0)
