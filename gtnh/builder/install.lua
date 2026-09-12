-- install.lua — Fetch or update the robot's programs from a base URL.
-- Usage: install <baseUrl>
--
-- Programs go to /home/bin, libraries to /home/lib. Both are writable, and
-- /home/lib is already on OpenOS' package.path, so require("plan") works.

local component = require("component")
local fs = require("filesystem")

local args = {...}

local function fail(msg)
  print("[ERROR] " .. msg)
  os.exit(1)
end

local baseUrl = args[1]
if not baseUrl then
  print("Usage: install <baseUrl>")
  print("Example: install https://raw.githubusercontent.com/you/repo/main/robot")
  return
end
if baseUrl:sub(-1) ~= "/" then baseUrl = baseUrl .. "/" end

if not component.isAvailable("internet") then
  fail("No Internet Card installed")
end
local internet = require("internet")

local files = {
  { "build.lua",        "/home/bin/build.lua" },
  { "getplan.lua",      "/home/bin/getplan.lua" },
  { "recv.lua",         "/home/bin/recv.lua" },
  { "selftest.lua",     "/home/bin/selftest.lua" },
  { "install.lua",      "/home/bin/install.lua" },
  { "lib/plan.lua",     "/home/lib/plan.lua" },
  { "lib/crc32.lua",    "/home/lib/crc32.lua" },
  { "lib/base64.lua",   "/home/lib/base64.lua" },
  { "lib/varint.lua",   "/home/lib/varint.lua" },
  { "etc/builder.cfg",  "/etc/builder.cfg" },
}

for _, dir in ipairs({ "/home/bin", "/home/lib" }) do
  if not fs.exists(dir) then fs.makeDirectory(dir) end
end

print("[INSTALL] From " .. baseUrl)

local downloaded, failedCount = 0, 0
for _, entry in ipairs(files) do
  local src, dst = entry[1], entry[2]
  local url = baseUrl .. src

  local body = {}
  local ok, err = pcall(function()
    for chunk in internet.request(url) do body[#body + 1] = chunk end
  end)

  if ok and #body > 0 then
    local data = table.concat(body)
    -- Write to a temporary file first so a failed download cannot leave a
    -- half-written program behind.
    local tmp = dst .. ".part"
    local out = io.open(tmp, "wb")
    if out then
      out:write(data)
      out:close()
      if fs.exists(dst) then fs.remove(dst) end
      fs.rename(tmp, dst)
      print(string.format("[OK]   %s (%d bytes)", dst, #data))
      downloaded = downloaded + 1
    else
      print("[FAIL] Cannot write " .. dst)
      failedCount = failedCount + 1
    end
  else
    print("[FAIL] " .. src .. ": " .. tostring(err))
    failedCount = failedCount + 1
  end
end

print("")
print(string.format("Installed %d file(s), %d failed", downloaded, failedCount))
if failedCount > 0 then
  print("[RESULT] Installation INCOMPLETE")
  os.exit(1)
end
print("[RESULT] Installation complete")
print("[NEXT] Run: /home/bin/selftest.lua")
