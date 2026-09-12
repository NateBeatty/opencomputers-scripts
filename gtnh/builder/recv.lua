-- recv.lua — Receive a plan pasted into the robot as text.
-- Usage: recv <name>
--
-- The converter's --paste option writes <name>.paste/part-001.txt and so on.
-- Open a part in a text editor on your PC, copy all of it, focus the robot's
-- screen and press the OpenComputers paste key (Controls -> OpenComputers; it
-- is unbound by default). Repeat for each part, in order.
--
-- Each part starts with:
--   #OCBP-PART <i>/<n> lines=<k> crc=<hex> ver=<planVersion>
-- followed by k base64 lines. The part's CRC is checked before it is kept, so
-- a paste that lost lines to the signal queue is rejected rather than built.

local event = require("event")
local fs = require("filesystem")
local base64 = require("base64")
local crc32 = require("crc32")
local plan = require("plan")

local args = {...}

local name = args[1]
if not name then
  print("Usage: recv <name>")
  return
end
if not name:find("%.plan$") then name = name .. ".plan" end

if not fs.exists("/plans") then fs.makeDirectory("/plans") end
local partialPath = "/plans/.partial"
local targetPath = "/plans/" .. name
if fs.exists(partialPath) then fs.remove(partialPath) end

local expectedPart = 1
local totalParts = nil
local planVersion = nil

-- State while a part is being received.
local collecting = false
local wantLines, gotLines, wantCrc = 0, 0, nil
local buffer = {}

local function finishPart()
  local data = base64.decode(table.concat(buffer))
  local crc = crc32.calc(data)
  if string.format("%08x", crc) ~= wantCrc then
    print(string.format("[RECV] Part %d REJECTED: checksum mismatch (got %08x, expected %s)",
      expectedPart, crc, wantCrc))
    print("[RECV] Paste the same part again.")
    collecting, buffer = false, {}
    return
  end

  local out = io.open(partialPath, "ab")
  if not out then
    print("[RECV] Cannot write " .. partialPath)
    return
  end
  out:write(data)
  out:close()

  print(string.format("[RECV] Part %d/%s OK (%d bytes)", expectedPart, tostring(totalParts), #data))
  collecting, buffer = false, {}
  expectedPart = expectedPart + 1

  if totalParts and expectedPart > totalParts then
    local handle, err = plan.open(partialPath)
    if not handle then
      print("[RECV] The assembled file is not a valid plan: " .. tostring(err))
      return
    end
    local ok, verifyErr = plan.verify(handle)
    local header = handle.header
    local planName = handle.name
    local paletteSize = #handle.palette
    plan.close(handle)
    if not ok then
      print("[RECV] " .. tostring(verifyErr))
      return
    end
    if fs.exists(targetPath) then fs.remove(targetPath) end
    fs.rename(partialPath, targetPath)
    print("")
    print("[DONE] " .. targetPath)
    print(string.format("[DONE] %s, version %d, %d x %d x %d, %d palette entries",
      planName, header.planVersion, header.width, header.height, header.length, paletteSize))
    print("[DONE] Run: build " .. targetPath)
    os.exit(0)
  else
    print("[RECV] Now paste part " .. expectedPart ..
      (totalParts and ("/" .. totalParts) or "") .. ". Wait a few seconds first.")
  end
end

local function handleLine(line)
  line = line:gsub("[\r\n]", "")
  if line == "" then return end

  local i, n, k, crc, ver = line:match("^#OCBP%-PART%s+(%d+)/(%d+)%s+lines=(%d+)%s+crc=(%x+)%s+ver=(%d+)")
  if i then
    i, n, k = tonumber(i), tonumber(n), tonumber(k)
    if totalParts and n ~= totalParts then
      print("[RECV] That part belongs to a different paste pack. Ignored.")
      return
    end
    if planVersion and tonumber(ver) ~= planVersion then
      print("[RECV] That part is from a different plan version. Ignored.")
      return
    end
    if i ~= expectedPart then
      print(string.format("[RECV] Expected part %d but got %d. Ignored.", expectedPart, i))
      return
    end
    totalParts, planVersion = n, tonumber(ver)
    wantLines, gotLines, wantCrc = k, 0, crc
    collecting, buffer = true, {}
    print(string.format("[RECV] Receiving part %d/%d (%d lines)...", i, n, k))
    return
  end

  if collecting then
    buffer[#buffer + 1] = line
    gotLines = gotLines + 1
    if gotLines >= wantLines then finishPart() end
  end
end

print("=== Plan paste receiver ===")
print("Target: " .. targetPath)
print("Paste part 1 now. Press Ctrl+C to give up.")
print("")

while true do
  -- The clipboard signal carries one line per signal:
  --   "clipboard", <keyboard address>, <text>, <player name>
  local _, _, text = event.pull("clipboard")
  if text then handleLine(text) end
end
