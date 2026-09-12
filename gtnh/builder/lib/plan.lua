-- plan.lua — Reader for the OC plan format (.plan files).
-- See AGENT_PROMPT.md section 5 for the format specification.
--
-- Layout (little-endian):
--   off  size  field
--   0    4     magic "OCBP"
--   4    1     formatVersion = 1
--   5    1     flags = 0
--   6    2     W
--   8    2     H
--   10   2     L
--   12   4     planVersion (u32)
--   16   4     fileLength
--   20   4     crc32 of bytes [24, fileLength)
--   24   1+n   name (u8 len + UTF-8)
--          2   paletteCount P (indices 2..P+1)
--          ... P palette entries (each: u8 flags, u8+n itemName, u16 damage,
--                 u8+n blockName, u8 blockMeta)
--          4*H  layer byte offsets
--          ...  layer RLE data: (varint runLen, varint paletteIdx)*
--
-- Two ways to read a plan:
--   plan.decode(raw)   -- everything at once; fine for tests and small plans
--   plan.open(path)    -- streaming: header now, one layer at a time through
--                         plan.layer(h, y). Use this on the robot: a 271x271
--                         plan is ~73 KB per layer and holding all of them at
--                         once does not fit in a robot's RAM.

local varint = require("varint")
local crc32 = require("crc32")

local plan = {}

plan.MAGIC = "OCBP"
plan.FORMAT_VERSION = 1

-- Reserved palette indices.
plan.PALETTE_AIR = 0
plan.PALETTE_SKIP = 1
plan.PALETTE_BASE = 2

-- Palette flags bits.
plan.FLAG_ORIENT = 0x01     -- bit0: orientation-bearing (use fuzzy compare)
plan.FLAG_TILEENTITY = 0x02 -- bit1: had tile-entity data (report only)

-- Layers decode to one byte per cell, so the palette cannot exceed the byte
-- range (indices 0..255, of which 0 and 1 are reserved).
plan.MAX_PALETTE = 254

--- Read a little-endian u16 from a byte string (1-based offset).
local function readU16(data, offset)
  return string.byte(data, offset) | (string.byte(data, offset + 1) << 8)
end

--- Read a little-endian u32 from a byte string (1-based offset).
local function readU32(data, offset)
  return string.byte(data, offset)
       | (string.byte(data, offset + 1) << 8)
       | (string.byte(data, offset + 2) << 16)
       | (string.byte(data, offset + 3) << 24)
end

--- Parse the plan header. Does not verify the CRC or decode layers.
-- @param raw a byte string holding at least the first 24 bytes
function plan.parseHeader(raw)
  if #raw < 24 then error("File too small for a plan") end
  if raw:sub(1, 4) ~= plan.MAGIC then error("Bad magic: not a plan file") end

  return {
    formatVersion = string.byte(raw, 5),
    flags = string.byte(raw, 6),
    width = readU16(raw, 7),
    height = readU16(raw, 9),
    length = readU16(raw, 11),
    planVersion = readU32(raw, 13),
    fileLength = readU32(raw, 17),
    crcStored = readU32(raw, 21),
  }
end

--- Parse the variable-length prefix: name, palette, layer offsets.
-- @param raw a byte string starting at file offset 0
-- @param height the plan's H
-- @return name, palette, layerOffsets (0-based file offsets)
local function parsePrefix(raw, height)
  local o = 25 -- 1-based; byte 25 is file offset 24

  local nameLen = string.byte(raw, o); o = o + 1
  local name = raw:sub(o, o + nameLen - 1); o = o + nameLen

  local paletteCount = readU16(raw, o); o = o + 2
  if paletteCount > plan.MAX_PALETTE then
    error(string.format(
      "palette too large: %d entries (max %d). Layers are stored one byte per cell, so "
      .. "re-export with fewer distinct blocks or extend the format to 2-byte cells.",
      paletteCount, plan.MAX_PALETTE))
  end

  local palette = {}
  for i = 1, paletteCount do
    local flags = string.byte(raw, o); o = o + 1
    local inLen = string.byte(raw, o); o = o + 1
    local itemName = raw:sub(o, o + inLen - 1); o = o + inLen
    local damage = readU16(raw, o); o = o + 2
    local bnLen = string.byte(raw, o); o = o + 1
    local blockName = raw:sub(o, o + bnLen - 1); o = o + bnLen
    local meta = string.byte(raw, o); o = o + 1
    palette[i] = {
      flags = flags,
      itemName = itemName,
      damage = damage,
      blockName = blockName,
      meta = meta,
    }
  end

  local layerOffsets = {}
  for y = 1, height do
    layerOffsets[y] = readU32(raw, o) -- 0-based file offsets
    o = o + 4
  end

  return name, palette, layerOffsets
end

--- Decode one layer's RLE bytes into a compact byte string (1 byte per cell).
-- Runs expand with string.rep, so the work is per RUN, not per cell: a table
-- with one entry per cell would be megabytes on a large plan.
local function decodeLayerBytes(data, cellsPerLayer, layerNo)
  local parts = {}
  local produced = 0
  local p = 1
  local n = #data
  while p <= n and produced < cellsPerLayer do
    local runLen, rl = varint.decode(data, p); p = p + rl
    local paletteIdx, pl = varint.decode(data, p); p = p + pl
    if paletteIdx > 255 then
      error(string.format("layer %d: palette index %d exceeds one byte", layerNo, paletteIdx))
    end
    if runLen > 0 then
      parts[#parts + 1] = string.rep(string.char(paletteIdx), runLen)
      produced = produced + runLen
    end
  end
  if produced ~= cellsPerLayer then
    error(string.format("Layer %d: decoded %d cells, expected %d", layerNo, produced, cellsPerLayer))
  end
  return table.concat(parts)
end

--- Decode a whole plan held in memory, returning every layer at once.
-- Use plan.open on the robot; this is for tests and small plans.
function plan.decode(raw)
  local h = plan.parseHeader(raw)

  if #raw < h.fileLength then
    error("File truncated: expected " .. h.fileLength .. " bytes, got " .. #raw)
  end

  local crcCalc = crc32.calc(raw, 25, h.fileLength) -- byte 25 is offset 24
  if crcCalc ~= h.crcStored then
    error(string.format("CRC mismatch: stored 0x%08x, computed 0x%08x", h.crcStored, crcCalc))
  end

  local name, palette, layerOffsets = parsePrefix(raw, h.height)

  local cellsPerLayer = h.width * h.length
  local layers = {}
  for y = 1, h.height do
    local start = layerOffsets[y] + 1 -- 1-based
    local finish = (y < h.height) and layerOffsets[y + 1] or h.fileLength
    layers[y] = decodeLayerBytes(raw:sub(start, finish), cellsPerLayer, y - 1)
  end

  return {
    header = h,
    name = name,
    palette = palette,
    layerOffsets = layerOffsets,
    layers = layers,
  }
end

--- Open a plan for streaming: reads the header, palette and layer offsets only.
-- @return handle, or nil plus an error message
function plan.open(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err or ("cannot open " .. tostring(path)) end

  local head = f:read(24)
  if not head or #head < 24 then f:close(); return nil, "file too small" end
  local okHeader, h = pcall(plan.parseHeader, head)
  if not okHeader then f:close(); return nil, h end

  -- The prefix is variable length, so grow the buffer until it parses.
  local buf = head
  local name, palette, layerOffsets
  local lastErr = "could not read plan prefix"
  for _ = 1, 16 do
    local ok, a, b, c = pcall(parsePrefix, buf, h.height)
    if ok then
      name, palette, layerOffsets = a, b, c
      break
    end
    lastErr = tostring(a)
    local more = f:read(8192)
    if not more or #more == 0 then break end
    buf = buf .. more
  end
  if not layerOffsets then f:close(); return nil, lastErr end

  return {
    file = f,
    header = h,
    name = name,
    palette = palette,
    layerOffsets = layerOffsets,
    cellsPerLayer = h.width * h.length,
  }
end

--- Verify a streamed plan's CRC without holding the file in memory.
-- @return true, or false plus a message
function plan.verify(handle)
  local h = handle.header
  handle.file:seek("set", 24)
  local crc = crc32.START
  local remaining = h.fileLength - 24
  while remaining > 0 do
    local want = remaining
    if want > 4096 then want = 4096 end
    local chunk = handle.file:read(want)
    if not chunk or #chunk == 0 then return false, "file truncated" end
    crc = crc32.update(crc, chunk)
    remaining = remaining - #chunk
  end
  crc = crc32.finish(crc)
  if crc ~= h.crcStored then
    return false, string.format("CRC mismatch: stored 0x%08x, computed 0x%08x", h.crcStored, crc)
  end
  return true
end

--- Decode a single layer from a streamed plan.
-- @param handle from plan.open
-- @param y 0-based layer index
-- @return a byte string of W*L cells, one byte per cell
function plan.layer(handle, y)
  local h = handle.header
  if y < 0 or y >= h.height then error("layer out of range: " .. y) end
  local start = handle.layerOffsets[y + 1]
  local finish = (y + 1 < h.height) and handle.layerOffsets[y + 2] or h.fileLength
  handle.file:seek("set", start)
  local data = handle.file:read(finish - start)
  if not data then error("could not read layer " .. y) end
  return decodeLayerBytes(data, handle.cellsPerLayer, y)
end

function plan.close(handle)
  if handle and handle.file then
    handle.file:close()
    handle.file = nil
  end
end

--- Read a single cell's palette index from a decoded layer.
-- @param layer a decoded layer (byte string, one byte per cell)
-- @param x, z 0-based coordinates
-- @param width the plan's W
function plan.cellAt(layer, x, z, width)
  local b = string.byte(layer, x + z * width + 1)
  if b == nil then error("cellAt: index out of range") end
  return b
end

--- The 0-based linear index of a cell within a layer.
function plan.cellIndex(x, z, width)
  return x + z * width
end

--- The palette entry for a cell value; plan index 2 maps to palette[1].
-- @return the entry table, or nil for AIR, SKIP, or an out-of-range index
function plan.paletteEntry(palette, cellValue)
  if cellValue < plan.PALETTE_BASE then return nil end
  return palette[cellValue - plan.PALETTE_BASE + 1]
end

return plan
