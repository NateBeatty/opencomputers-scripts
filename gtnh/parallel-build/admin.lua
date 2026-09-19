-- admin.lua — The coordinator for the parallel builder. Installed as pbadmin.
-- Usage: pbadmin <plan> [--tile <size>] [--new] [--excavate-only] [--rebuild]
--
-- Runs on a computer with a wireless network card, placed above the middle of
-- the build site. It cuts the plan into tiles (16x16 by default), hands tiles
-- to robots running pbuild, and saves who has what to /home/pbuild_admin.txt,
-- so restarting it carries on where it left off.
--
--   --tile <size>  tile size for a new build (default 16)
--   --new          discard the saved admin state and start the plan over
--   --excavate-only  stop the robots once every tile is dug, so the site can
--                  be checked. Restart without it to start building.
--   --rebuild      the site is already dug: start the build round over from
--                  layer 0, keeping nothing of the old build progress. Works
--                  with a changed plan too (those robots need --new and the
--                  start pad). Only needed once; later restarts carry on.
--
-- Type a command and press Enter:
--   release <id>      free robot <id>'s tile. Only once that robot is stopped
--                     and picked up: the next robot resumes the tile from the
--                     last row it reported.
--   release missing   the same for every robot marked MISSING
--   pause | resume    pause or resume every robot
--   stop              every robot saves and ends its program
--   map               show the tile map (any key goes back)
--   help              list the commands
--   quit              close the admin; robots wait until it is back
--
-- Files it writes:
--   /home/pbuild_manual.txt  cells robots could not dig or place (do by hand)
--   /home/pbuild_stock.txt   which plan items are stocked and which are skipped
--   /home/pbuild_log.txt     everything shown in the log lines

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local term = require("term")

local plan = require("plan")
local tiles = require("pbtiles")
local logic = require("pblogic")

local args = {...}

local config = {
  port = 5657,         -- 1..65535; the robots must use the same one
  stateFile = "/home/pbuild_admin.txt",
  manualFile = "/home/pbuild_manual.txt",
  stockFile = "/home/pbuild_stock.txt",
  logFile = "/home/pbuild_log.txt",
  missingAfter = 300,  -- seconds without a message before a robot is MISSING
  saveInterval = 10,   -- seconds between saves of routine progress
}

do -- optional /etc/pbuild.cfg overrides, shared with the robots
  local f = loadfile("/etc/pbuild.cfg")
  if f then
    local ok, user = pcall(f)
    if ok and type(user) == "table" then
      for k, v in pairs(user) do
        if config[k] ~= nil then config[k] = v end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

local function saveTable(path, value)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(serialization.serialize(value))
  f:close()
  filesystem.remove(path)
  filesystem.rename(tmp, path)
  return true
end

local function loadTable(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(serialization.unserialize, content)
  if ok and type(data) == "table" then return data end
  return nil
end

local function appendLines(path, lines)
  local f = io.open(path, "a")
  if not f then return end
  for _, line in ipairs(lines) do f:write(line, "\n") end
  f:close()
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local planPath, tileSize, fresh, excavateOnly, rebuild = nil, 16, false, false, false
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--tile" then
      tileSize = tonumber(args[i + 1])
      i = i + 1
    elseif a == "--new" then
      fresh = true
    elseif a == "--excavate-only" then
      excavateOnly = true
    elseif a == "--rebuild" then
      rebuild = true
    elseif a:sub(1, 2) == "--" then
      print("[FATAL] Unknown option " .. a)
      return
    elseif not planPath then
      planPath = a
    end
    i = i + 1
  end
end

if not planPath or not tileSize or tileSize < 1 then
  print("Usage: pbadmin <plan> [--tile <size>] [--new] [--excavate-only] [--rebuild]")
  return
end
if rebuild and (fresh or excavateOnly) then
  print("[FATAL] --rebuild skips digging; it cannot go with --new or --excavate-only.")
  return
end

if not component.isAvailable("modem") or not component.modem.isWireless() then
  print("[FATAL] This computer needs a wireless network card.")
  return
end
local modem = component.modem

local handle, openErr = plan.open(planPath)
if not handle then
  print("[FATAL] Cannot open plan: " .. tostring(openErr))
  return
end
local verified, verifyErr = plan.verify(handle)
if not verified then
  print("[FATAL] " .. tostring(verifyErr))
  plan.close(handle)
  return
end
local header = handle.header
local palette = handle.palette
local info = {
  name = handle.name, version = header.planVersion, crc = header.crcStored,
  width = header.width, height = header.height, length = header.length,
}
plan.close(handle)

local state = nil
if not fresh then
  local saved = loadTable(config.stateFile)
  if saved and saved.plan then
    if saved.plan.name == info.name and saved.plan.version == info.version
       and saved.plan.crc == info.crc then
      state = saved
      if state.tileSize ~= tileSize and tileSize ~= 16 then
        print(string.format("[NOTE] Keeping the saved tile size %d; use --new to change it.",
          state.tileSize))
      end
    elseif rebuild then
      print("[NOTE] The saved admin state is for another plan; building this one on the dug site.")
    else
      print("[FATAL] The saved admin state is for " .. tostring(saved.plan.name) ..
        " version " .. tostring(saved.plan.version) .. ".")
      print("[FATAL] Run with --new to start this plan instead.")
      return
    end
  end
end
if not state then
  state = logic.newState(info, tileSize)
end
if rebuild then
  logic.restartBuild(state)
  print("[REBUILD] The build round starts over from layer 0; digging is skipped.")
end
-- Applies to this run only: restart without the flag to go on to building.
state.holdBuild = excavateOnly
saveTable(config.stateFile, state)

-- Uptime restarts with the computer, so every robot counts as just seen.
local now = computer.uptime()
for _, r in pairs(state.robots) do
  r.lastSeen = now
  r.missing = false
end

modem.open(config.port)
pcall(modem.setStrength, 1e9)

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

local gpu = component.gpu
local screenW, screenH = gpu.getResolution()
local input = ""
local recent = {}
local mapMode = false

local function put(row, text)
  text = tostring(text or "")
  if #text > screenW then text = text:sub(1, screenW) end
  gpu.set(1, row, text .. string.rep(" ", screenW - #text))
end

local function addLog(text)
  recent[#recent + 1] = text
  if #recent > 20 then table.remove(recent, 1) end
  appendLines(config.logFile, { os.date("%H:%M:%S ") .. text })
end

local function seenText(r, t)
  if not r.lastSeen then return "-" end
  local s = math.floor(t - r.lastSeen)
  if s < 120 then return s .. "s" end
  return math.floor(s / 60) .. "m"
end

local function drawMap()
  local g = logic.grid(state)
  put(1, "Tiles: D done  # working  o free  . not reachable yet")
  local row = 2
  for tz = 0, g.tilesZ - 1 do
    if row > screenH - 1 then break end
    local chars = {}
    for tx = 0, math.min(g.tilesX, screenW) - 1 do
      local id = tiles.id(g, tx, tz)
      local t = state.tiles[id]
      local ch
      if t.status == "done" then ch = "D"
      elseif t.status == "claimed" then ch = "#"
      elseif state.round ~= "excavate" or state.lane[id] or id == 0 then ch = "o"
      else ch = "." end
      chars[#chars + 1] = ch
    end
    put(row, table.concat(chars))
    row = row + 1
  end
  while row < screenH do put(row, ""); row = row + 1 end
  put(screenH, "Press any key to go back.")
end

local function draw()
  if mapMode then return drawMap() end
  local t = computer.uptime()
  local sum = logic.summary(state)
  put(1, string.format("Parallel build: %s v%s  round: %s",
    tostring(state.plan.name), tostring(state.plan.version), state.round))
  put(2, string.format("Tiles %d: done %d, working %d, free %d. Travel layer dug: %d",
    sum.total, sum.done, sum.claimed, sum.free, sum.lanes))
  if state.holdBuild and state.round == "excavate" then
    if sum.done == sum.total then
      put(3, "Digging done. Restart without --excavate-only to build.")
    else
      put(3, "--excavate-only: robots stop once every tile is dug")
    end
  elseif state.stock then
    put(3, "Stock list received (see " .. config.stockFile .. ")")
  elseif state.round == "build" then
    put(3, "Waiting for the first robot to check the chest")
  else
    put(3, "The chest is checked when building starts")
  end
  put(4, "ID  STATE        TILE  AT        E%  FUEL SEEN")

  local list = {}
  for _, r in pairs(state.robots) do list[#list + 1] = r end
  table.sort(list, function(a, b) return a.id < b.id end)

  local g = logic.grid(state)
  local row = 5
  local lastRow = screenH - 3
  for _, r in ipairs(list) do
    if row > lastRow then break end
    local st
    if r.released then st = "released"
    elseif r.missing then st = "MISSING"
    else st = tostring(r.phase or "?") end
    local at = "-"
    if r.tile ~= nil then
      local tile = state.tiles[r.tile]
      local _, _, w = tiles.bounds(g, r.tile)
      local y = (state.round == "excavate") and (state.plan.height - tile.p) or tile.p
      at = string.format("y%d r%d", y, tile.i // w)
    elseif r.pos then
      at = string.format("%d,%d,%d", r.pos.x, r.pos.y, r.pos.z)
    end
    put(row, string.format("%-3d %-12s %-5s %-9s %3s %4s %4s",
      r.id, st:sub(1, 12), r.tile ~= nil and tostring(r.tile) or "-", at:sub(1, 9),
      tostring(r.energy or "?"), tostring(r.fuel or "?"), seenText(r, t)))
    row = row + 1
  end
  while row <= lastRow do put(row, ""); row = row + 1 end
  put(screenH - 2, recent[#recent - 1] or "")
  put(screenH - 1, recent[#recent] or "Type help and press Enter for commands.")
  put(screenH, "> " .. input)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

local dirty = false
local lastSave = computer.uptime()

local function saveNow()
  saveTable(config.stateFile, state)
  dirty = false
  lastSave = computer.uptime()
end

local function writeStockReport()
  local f = io.open(config.stockFile, "w")
  if not f then return end
  local seen, skipped = {}, 0
  f:write("Plan items and whether the robots will place them:\n")
  for _, entry in ipairs(palette) do
    local key = entry.itemName .. "@" .. tostring(entry.damage)
    if not seen[key] then
      seen[key] = true
      if state.stock and state.stock[key] then
        f:write("  stocked  ", key, "\n")
      else
        f:write("  SKIP     ", key, "\n")
        skipped = skipped + 1
      end
    end
  end
  f:close()
  addLog(string.format("Stock: %d item types will be skipped (listed in %s).", skipped,
    config.stockFile))
end

local function onMessage(from, port, raw)
  if port ~= config.port or type(raw) ~= "string" then return end
  local ok, msg = pcall(serialization.unserialize, raw)
  if not ok or type(msg) ~= "table" or msg.type == "cmd" then return end

  local reply, ev = logic.handle(state, from, msg, computer.uptime())
  if reply then
    pcall(modem.send, from, config.port, serialization.serialize(reply))
  end
  for _, line in ipairs(ev.log) do addLog(line) end
  if #ev.manual > 0 then appendLines(config.manualFile, ev.manual) end
  if ev.stock then writeStockReport() end
  -- Claims and finished tiles are saved at once, so an admin restart can never
  -- hand one tile to two robots. Row progress can wait a few seconds.
  if ev.important then saveNow() elseif reply or msg.type == "status" then dirty = true end
end

local function execute(line)
  local words = {}
  for word in line:gmatch("%S+") do words[#words + 1] = word:lower() end
  local cmd = words[1]
  if not cmd then return end

  if cmd == "release" then
    local target = words[2]
    if target == "all" and words[3] == "missing" then target = "missing" end
    local which = (target == "missing") and "missing" or tonumber(target)
    if not which then
      addLog("Usage: release <id>  or  release missing")
      return
    end
    local count, ev = logic.release(state, which)
    for _, l in ipairs(ev.log) do addLog(l) end
    if count == 0 then addLog("Nothing to release.") end
    saveNow()
  elseif cmd == "pause" or cmd == "resume" or cmd == "stop" then
    modem.broadcast(config.port, serialization.serialize({ type = "cmd", cmd = cmd }))
    addLog("Sent " .. cmd .. " to every robot.")
  elseif cmd == "map" then
    mapMode = true
  elseif cmd == "help" then
    addLog("release <id> | release missing | pause | resume")
    addLog("stop | map | quit")
  elseif cmd == "quit" then
    return "quit"
  else
    addLog("Unknown command: " .. cmd .. " (type help)")
  end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

term.clear()
addLog(string.format("Admin ready for %s: %d tiles of %d. Port %d.", state.plan.name,
  logic.summary(state).total, state.tileSize, config.port))
if state.stock then writeStockReport() end

local function loop()
  local lastDraw = 0
  while true do
    local signal = { event.pull(0.5) }
    local name = signal[1]
    local redraw = false

    if name == "modem_message" then
      onMessage(signal[3], signal[4], signal[6])
    elseif name == "key_down" then
      local char, code = signal[3], signal[4]
      redraw = true
      if mapMode then
        mapMode = false
      elseif code == 28 then            -- Enter
        local result = execute(input)
        input = ""
        if result == "quit" then return end
      elseif code == 14 then            -- Backspace
        input = input:sub(1, -2)
      elseif type(char) == "number" and char >= 32 and char < 127 then
        input = input .. string.char(char)
      end
    end

    local t = computer.uptime()
    for _, id in ipairs(logic.markMissing(state, t, config.missingAfter)) do
      addLog(string.format("Robot %d is MISSING (nothing heard for %d s).", id, config.missingAfter))
      dirty = true
    end
    if dirty and t - lastSave >= config.saveInterval then saveNow() end
    if redraw or t - lastDraw >= 1 then
      draw()
      lastDraw = t
    end
  end
end

local ok, err = pcall(loop)
saveNow()
modem.close(config.port)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  print("[ERROR] " .. tostring(err))
end
print("Admin closed. State saved to " .. config.stateFile .. ". Robots wait until it is back.")
