-- base64.lua — Pure-Lua Base64 encoding/decoding (no Data Card needed).

local base64 = {}

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Encode a byte string to Base64.
-- @param data a byte string
-- @return a Base64-encoded string
function base64.encode(data)
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local b0 = string.byte(data, i)
    local b1 = string.byte(data, i + 1)
    local b2 = string.byte(data, i + 2)

    if b1 then
      if b2 then
        out[#out + 1] = b64chars:sub(((b0 >> 2) & 0x3f) + 1, ((b0 >> 2) & 0x3f) + 1)
        out[#out + 1] = b64chars:sub((((b0 << 4) & 0x3f) | (b1 >> 4)) + 1, (((b0 << 4) & 0x3f) | (b1 >> 4)) + 1)
        out[#out + 1] = b64chars:sub((((b1 << 2) & 0x3f) | (b2 >> 6)) + 1, (((b1 << 2) & 0x3f) | (b2 >> 6)) + 1)
        out[#out + 1] = b64chars:sub((b2 & 0x3f) + 1, (b2 & 0x3f) + 1)
      else
        out[#out + 1] = b64chars:sub(((b0 >> 2) & 0x3f) + 1, ((b0 >> 2) & 0x3f) + 1)
        out[#out + 1] = b64chars:sub((((b0 << 4) & 0x3f) | (b1 >> 4)) + 1, (((b0 << 4) & 0x3f) | (b1 >> 4)) + 1)
        out[#out + 1] = b64chars:sub(((b1 << 2) & 0x3f) + 1, ((b1 << 2) & 0x3f) + 1)
        out[#out + 1] = "="
      end
    else
      out[#out + 1] = b64chars:sub(((b0 >> 2) & 0x3f) + 1, ((b0 >> 2) & 0x3f) + 1)
      out[#out + 1] = b64chars:sub(((b0 << 4) & 0x3f) + 1, ((b0 << 4) & 0x3f) + 1)
      out[#out + 1] = "=="
    end
    i = i + 3
  end
  return table.concat(out)
end

--- Decode a Base64-encoded string.
-- @param s a Base64-encoded string
-- @return the decoded byte string
function base64.decode(s)
  -- Build reverse lookup table.
  local lookup = {}
  for i = 1, #b64chars do
    lookup[b64chars:sub(i, i)] = i - 1
  end

  local out = {}
  local i = 1
  local len = #s
  while i <= len do
    local c1 = lookup[s:sub(i, i)]
    if c1 == nil then
      -- Skip whitespace/padding that comes after the data.
      if i > len or s:sub(i, i) == "=" then break end
      i = i + 1
    else
      local c2 = lookup[s:sub(i + 1, i + 1)]
      if c2 == nil then break end
      local b0 = (c1 << 2) | (c2 >> 4)
      out[#out + 1] = string.char(b0)

      local c3 = lookup[s:sub(i + 2, i + 2)]
      if c3 ~= nil and s:sub(i + 2, i + 2) ~= "=" then
        local b1 = ((c2 & 0xF) << 4) | (c3 >> 2)
        out[#out + 1] = string.char(b1)
      end

      local c4 = lookup[s:sub(i + 3, i + 3)]
      if c4 ~= nil and s:sub(i + 3, i + 3) ~= "=" then
        local b2 = ((c3 & 0x3) << 6) | c4
        out[#out + 1] = string.char(b2)
      end
      i = i + 4
    end
  end
  return table.concat(out)
end

return base64
