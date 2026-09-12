-- varint.lua — Unsigned LEB128 (variable-length) integers.
-- Matches the plan format's run-length encoding and OpenOS' Data Card varint.

local varint = {}

--- Encode an unsigned integer as LEB128.
-- @param v a non-negative integer
-- @return a string of bytes
function varint.encode(v)
  if v < 0 then error("varint requires a non-negative integer") end
  local out = {}
  while true do
    local b = v & 0x7f
    v = v >> 7
    if v == 0 then
      out[#out + 1] = string.char(b)
      break
    else
      out[#out + 1] = string.char(b | 0x80)
    end
  end
  return table.concat(out)
end

--- Decode a LEB128 from a byte sequence.
-- @param data a byte string
-- @param offset 1-based position to start reading (default 1)
-- @return value (number), length (number of bytes consumed)
function varint.decode(data, offset)
  offset = offset or 1
  local result = 0
  local shift = 0
  local pos = offset
  while true do
    local b = string.byte(data, pos)
    if b == nil then error("varint: unexpected end of data") end
    result = result | ((b & 0x7f) << shift)
    pos = pos + 1
    if (b & 0x80) == 0 then break end
    shift = shift + 7
    if shift > 31 then error("varint too long") end
  end
  return result, pos - offset
end

--- Append LEB128 bytes for v to a table of byte strings.
-- @param out table to append to
-- @param v non-negative integer
function varint.append(out, v)
  if v < 0 then error("varint requires a non-negative integer") end
  while true do
    local b = v & 0x7f
    v = v >> 7
    if v == 0 then
      out[#out + 1] = string.char(b)
      break
    else
      out[#out + 1] = string.char(b | 0x80)
    end
  end
end

return varint
