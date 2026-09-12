-- getplan.lua — Download a plan with the Internet Card.
-- Usage: getplan <url> [name]
--
-- Downloads to /plans/.partial, validates magic, format version, length and
-- CRC, then renames to /plans/<name>.plan. A truncated or corrupted download
-- never reaches the final name.

local component = require("component")
local fs = require("filesystem")
local plan = require("plan")

local args = {...}

local function fail(msg)
  print("[ERROR] " .. msg)
  os.exit(1)
end

local url = args[1]
if not url then
  print("Usage: getplan <url> [name]")
  print("Example: getplan https://raw.githubusercontent.com/you/repo/main/base.plan base")
  return
end

local name = args[2] or url:match("([^/]+)%.plan$") or "plan"
if not name:find("%.plan$") then name = name .. ".plan" end

if not component.isAvailable("internet") then
  fail("No Internet Card installed")
end
local internet = require("internet")

if not fs.exists("/plans") then fs.makeDirectory("/plans") end

local partialPath = "/plans/.partial"
local targetPath = "/plans/" .. name

print("[GETPLAN] " .. url)
print("[GETPLAN] -> " .. targetPath)

local out, openErr = io.open(partialPath, "wb")
if not out then fail("Cannot write " .. partialPath .. ": " .. tostring(openErr)) end

local bytes = 0
local ok, err = pcall(function()
  for chunk in internet.request(url) do
    out:write(chunk)
    bytes = bytes + #chunk
  end
end)
out:close()

if not ok then
  fs.remove(partialPath)
  fail("Download failed: " .. tostring(err))
end
if bytes == 0 then
  fs.remove(partialPath)
  fail("Download was empty")
end
print(string.format("[GETPLAN] Downloaded %d bytes", bytes))

-- Validate by opening it exactly the way the builder will.
local handle, openPlanErr = plan.open(partialPath)
if not handle then
  fs.remove(partialPath)
  fail("Not a valid plan: " .. tostring(openPlanErr))
end

local verified, verifyErr = plan.verify(handle)
if not verified then
  plan.close(handle)
  fs.remove(partialPath)
  fail(tostring(verifyErr))
end

local h = handle.header
print("[VALIDATE] Name:       " .. handle.name)
print("[VALIDATE] Version:    " .. h.planVersion)
print("[VALIDATE] Size:       " .. h.width .. " x " .. h.height .. " x " .. h.length)
print("[VALIDATE] Palette:    " .. #handle.palette .. " entries")
print("[VALIDATE] CRC OK")
plan.close(handle)

if fs.exists(targetPath) then fs.remove(targetPath) end
local renamed, renameErr = fs.rename(partialPath, targetPath)
if not renamed then
  fail("Could not move the file into place: " .. tostring(renameErr))
end

print("[DONE] Saved " .. targetPath)
print("[DONE] Run: build " .. targetPath)

if url:find("raw.githubusercontent.com", 1, true) then
  print("")
  print("[NOTE] raw.githubusercontent.com caches for about 5 minutes, so a fresh")
  print("[NOTE] push can still serve the old file. The plan version above is how")
  print("[NOTE] you tell. Use a commit-SHA URL when you need certainty.")
end
