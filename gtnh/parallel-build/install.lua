-- install.lua — Install or update the parallel builder. Installed as pbinstall.
-- Usage: pbinstall <gtnhUrl> robot|admin
--
-- <gtnhUrl> is the repo's gtnh folder, for example
--   https://raw.githubusercontent.com/NateBeatty/opencomputers-scripts/main/gtnh
-- Put a commit SHA in place of "main" to skip GitHub's ~5 minute cache.
--
-- Programs go to /home/bin and libraries to /home/lib (already on OpenOS'
-- package.path). The plan reader and getplan come from the builder folder.

local component = require("component")
local fs = require("filesystem")

local args = {...}

local baseUrl, role = args[1], args[2]
if not baseUrl or (role ~= "robot" and role ~= "admin") then
  print("Usage: pbinstall <gtnhUrl> robot|admin")
  print("Example: pbinstall https://raw.githubusercontent.com/you/repo/main/gtnh robot")
  return
end
if baseUrl:sub(-1) ~= "/" then baseUrl = baseUrl .. "/" end

if not component.isAvailable("internet") then
  print("[ERROR] No Internet Card installed")
  os.exit(1)
end
local internet = require("internet")

local files = {
  { "builder/lib/plan.lua",           "/home/lib/plan.lua" },
  { "builder/lib/crc32.lua",          "/home/lib/crc32.lua" },
  { "builder/lib/varint.lua",         "/home/lib/varint.lua" },
  { "builder/getplan.lua",            "/home/bin/getplan.lua" },
  { "parallel-build/lib/pbtiles.lua", "/home/lib/pbtiles.lua" },
  { "parallel-build/install.lua",     "/home/bin/pbinstall.lua" },
}
if role == "robot" then
  files[#files + 1] = { "parallel-build/pbuild.lua", "/home/bin/pbuild.lua" }
  files[#files + 1] = { "builder/etc/builder.cfg",   "/etc/builder.cfg" }
else
  files[#files + 1] = { "parallel-build/admin.lua",       "/home/bin/pbadmin.lua" }
  files[#files + 1] = { "parallel-build/lib/pblogic.lua", "/home/lib/pblogic.lua" }
end

for _, dir in ipairs({ "/home/bin", "/home/lib" }) do
  if not fs.exists(dir) then fs.makeDirectory(dir) end
end

print("[INSTALL] " .. role .. " from " .. baseUrl)

local downloaded, failedCount = 0, 0
for _, entry in ipairs(files) do
  local src, dst = entry[1], entry[2]
  local body = {}
  local ok, err = pcall(function()
    for chunk in internet.request(baseUrl .. src) do body[#body + 1] = chunk end
  end)

  if ok and #body > 0 then
    -- Write to a temporary file first so a failed download cannot leave a
    -- half-written program behind.
    local tmp = dst .. ".part"
    local out = io.open(tmp, "wb")
    if out then
      out:write(table.concat(body))
      out:close()
      if fs.exists(dst) then fs.remove(dst) end
      fs.rename(tmp, dst)
      print("[OK]   " .. dst)
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
if role == "robot" then
  print("[NEXT] getplan <plan url> <name>, then: /home/bin/pbuild.lua /plans/<name>.plan")
else
  print("[NEXT] getplan <plan url> <name>, then: /home/bin/pbadmin.lua /plans/<name>.plan")
end
