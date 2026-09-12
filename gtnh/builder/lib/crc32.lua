-- crc32.lua — CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320).
-- The same polynomial as zlib.crc32 and OpenComputers' Data Card.

local crc32 = {}

-- Precompute the CRC table.
local TABLE = {}
do
  local t = 0
  for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
      if c & 1 == 1 then
        c = (0xEDB88320) ~ (c >> 1)
      else
        c = c >> 1
      end
    end
    TABLE[n] = c
  end
end

--- Compute CRC-32 of a byte string.
-- @param data a byte string
-- @param start 1-based start position (default 1)
-- @param finish 1-based end position (default #data)
-- @return unsigned 32-bit CRC
function crc32.calc(data, start, finish)
  start = start or 1
  finish = finish or #data
  local crc = 0xFFFFFFFF
  for i = start, finish do
    local b = string.byte(data, i)
    crc = TABLE[(crc ~ b) & 0xFF] ~ (crc >> 8)
  end
  return crc ~ 0xFFFFFFFF
end

-- Incremental interface, so a large file can be checksummed in chunks without
-- ever being held in memory: start at crc32.START, feed chunks to crc32.update,
-- then call crc32.finish.
crc32.START = 0xFFFFFFFF

--- Fold more bytes into a running CRC.
-- @param crc the running value (start from crc32.START)
-- @param data a byte string
-- @return the updated running value
function crc32.update(crc, data)
  for i = 1, #data do
    crc = TABLE[(crc ~ string.byte(data, i)) & 0xFF] ~ (crc >> 8)
  end
  return crc
end

--- Finalise a running CRC into the value stored in the file.
function crc32.finish(crc)
  return crc ~ 0xFFFFFFFF
end

--- Read a little-endian CRC-32 from a byte string.
-- @param data a byte string
-- @param offset 1-based position
-- @return unsigned 32-bit CRC
function crc32.readLE(data, offset)
  local b0 = string.byte(data, offset)
  local b1 = string.byte(data, offset + 1)
  local b2 = string.byte(data, offset + 2)
  local b3 = string.byte(data, offset + 3)
  return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
end

--- Write a CRC-32 as little-endian bytes.
-- @param crc unsigned 32-bit CRC
-- @return a 4-byte string
function crc32.writeLE(crc)
  return string.char(
    crc & 0xFF,
    (crc >> 8) & 0xFF,
    (crc >> 16) & 0xFF,
    (crc >> 24) & 0xFF
  )
end

return crc32
