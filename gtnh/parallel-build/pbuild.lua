-- pbuild.lua — A worker robot for the parallel builder.
-- Usage: pbuild <plan> [--new]
--
-- Needs the same plan as the admin computer (pbadmin), and: a wireless network
-- card, an Inventory Controller, generators, an Angel upgrade, a Hover upgrade
-- (the travel layer can be far above the ground once tiles are dug), an
-- unbreakable pickaxe, and the ender chest on the shared frequency.
--
-- Place the robot on the start pad: on the ground one block west of the box's
-- NW corner (cell -1, 0, 0), facing east. It asks the admin for a tile, climbs
-- the column above the pad to the travel layer (one block above the box),
-- flies there, digs or builds the tile, reports back, and asks for the next.
-- Everything is dug first (round 1), then everything is built (round 2).
--
--   --new  forget this robot's saved progress. Use it when putting a robot
--          back on the pad, for example after its tile was released.
--
-- Rules that keep robots from breaking each other:
--   * Never break a block that is an inventory. A robot is one, stone is not.
--     A robot in the way is waited for (and stepped around in the travel
--     layer), never dug.
--   * Below the travel layer, only dig inside this robot's own tile.
--   * Only place the ender chest inside this robot's own tile.
--
-- Coordinates are plan cells: forward from the pad = +X, right = +Z, up = +Y.

local component = require("component")
local computer = require("computer")
local robot = require("robot")
local sides = require("sides")
local serialization = require("serialization")
local filesystem = require("filesystem")
local event = require("event")

local plan = require("plan")
local tiles = require("pbtiles")

local args = {...}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local config = {
  stateFile = "/home/pbuild_state.txt",
  manualFile = "/home/manual.txt",

  fuelReserve = 16,          -- fuel items to keep aboard
  fuelItems = { ["minecraft:coal"] = 1280 },  -- "name" or "name@damage" -> energy per item
  restBelow = 0.30,          -- rest when energy falls below this fraction
  resumeAbove = 0.90,        -- resume once energy is back above this fraction
  shutdownBelow = 0.05,      -- save and power off below this fraction

  restockRetrySeconds = 60,  -- how often to re-check the chest while waiting
  stacksPerRestock = 4,      -- stacks of the needed item to pull per trip
  minFreeSlots = 2,          -- void junk when fewer free slots than this
  voidCheckInterval = 16,    -- while digging, check for junk every N cells
  chestPattern = "ender",    -- substring identifying the ender chest item
  moveRetries = 64,          -- attempts before giving up on a block

  port = 65657,
  requestTimeout = 4,        -- seconds to wait for the admin before resending
  contactWarnAfter = 60,     -- seconds without an answer before saying so
  statusInterval = 10,       -- seconds between status messages
  blockedReportAfter = 60,   -- seconds behind a robot before reporting it
}

-- Fuel and restock settings are shared with build.lua through builder.cfg
-- (except its stateFile, which is build.lua's). Anything can be overridden in
-- /etc/pbuild.cfg.
for _, path in ipairs({ "/etc/builder.cfg", "/etc/pbuild.cfg" }) do
  local f = loadfile(path)
  if f then
    local ok, user = pcall(f)
    if ok and type(user) == "table" then
      for k, v in pairs(user) do
        if path == "/etc/pbuild.cfg" or k ~= "stateFile" then config[k] = v end
      end
    end
  end
end

do
  local validFuel = type(config.fuelItems) == "table" and next(config.fuelItems) ~= nil
  if validFuel then
    for name, energy in pairs(config.fuelItems) do
      if type(name) ~= "string" or type(energy) ~= "number" then
        validFuel = false
        break
      end
    end
  end
  if not validFuel then
    print("[WARN] fuelItems in the config is in an old format; using minecraft:coal.")
    config.fuelItems = { ["minecraft:coal"] = 1280 }
  end
end

-- ---------------------------------------------------------------------------
-- State (saved after every move)
-- ---------------------------------------------------------------------------

local state = {
  plan = nil,                -- { name, version, crc }
  id = nil,                  -- robot number given by the admin
  tileSize = nil,
  tile = nil,                -- tile being worked, or nil
  round = nil,               -- "excavate" | "build"
  p = 0, i = 0,              -- pass (dig) or layer (build), and cell in the tile
  needStock = false,         -- this robot takes the build round's stock snapshot
  pos = { x = -1, y = 0, z = 0 },
  facing = 0,                -- 0=+X, 1=+Z, 2=-X, 3=-Z
  phase = "starting", note = nil,
  stock = {},                -- "name@damage" -> true, from the admin
  chestPlaced = false,
  deferred = {},             -- cells to retry at the end of a layer
  manualQueue = {},          -- manual.txt lines not yet sent to the admin
  counters = { placed = 0, cleared = 0, skipped = 0, deferred = 0 },
}

local adminAddress = nil     -- found fresh each start, never saved
local g, H                   -- tile grid and plan height
local lane = {}              -- [tile id] = true where the travel layer is dug

local function log(msg) print(msg) end

local function itemKey(name, damage) return name .. "@" .. tostring(damage or 0) end

local function stackKey(stack)
  if not stack or not stack.name then return nil end
  return itemKey(stack.name, stack.damage or 0)
end

local function saveState()
  local tmp = config.stateFile .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(serialization.serialize(state))
  f:close()
  filesystem.remove(config.stateFile)
  filesystem.rename(tmp, config.stateFile)
end

local function loadState()
  local f = io.open(config.stateFile, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(serialization.unserialize, content)
  if ok and type(data) == "table" then return data end
  return nil
end

local function logManual(reason, x, y, z, what)
  local line = string.format("%s at (%d,%d,%d): %s", reason, x, y, z, tostring(what))
  local f = io.open(config.manualFile, "a")
  if f then
    f:write(line, "\n")
    f:close()
  end
  state.manualQueue[#state.manualQueue + 1] = "robot " .. tostring(state.id) .. ": " .. line
end

-- ---------------------------------------------------------------------------
-- Components
-- ---------------------------------------------------------------------------

local function optionalComponent(kind)
  if component.isAvailable(kind) then return component.getPrimary(kind) end
  return nil
end

local ic = optionalComponent("inventory_controller")
local modem = optionalComponent("modem")
local hasAngel = component.isAvailable("angel")

local generators = {}
for address in component.list("generator") do
  generators[#generators + 1] = component.proxy(address)
end

-- ---------------------------------------------------------------------------
-- Inventory helpers
-- ---------------------------------------------------------------------------

local slotCache = {}

local function stackAt(slot)
  return ic.getStackInInternalSlot(slot)
end

local function findSlot(key)
  local cached = slotCache[key]
  if cached and robot.count(cached) > 0 and stackKey(stackAt(cached)) == key then
    return cached
  end
  slotCache[key] = nil
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 and stackKey(stackAt(slot)) == key then
      slotCache[key] = slot
      return slot
    end
  end
  return nil
end

local function findEmptySlot()
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) == 0 then return slot end
  end
  return nil
end

local function freeSlotCount()
  local n = 0
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) == 0 then n = n + 1 end
  end
  return n
end

local function isChestStack(stack)
  return stack and stack.name and stack.name:lower():find(config.chestPattern, 1, true) ~= nil
end

local function findChestSlot()
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 and isChestStack(stackAt(slot)) then return slot end
  end
  return nil
end

--- Energy per item for a stack, or nil if it isn't fuel. "name@damage" entries
--- match one damage value, plain "name" entries all of them (see build.lua).
local function fuelEnergy(stack)
  return config.fuelItems[stackKey(stack)] or config.fuelItems[stack.name]
end

local function findFuelSlot()
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 then
      local stack = stackAt(slot)
      if stack and fuelEnergy(stack) then return slot, stack end
    end
  end
  return nil
end

local function fuelCount()
  local total = 0
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 then
      local stack = stackAt(slot)
      if stack and fuelEnergy(stack) then total = total + robot.count(slot) end
    end
  end
  return total
end

-- ---------------------------------------------------------------------------
-- Energy
-- ---------------------------------------------------------------------------

local function energyFraction()
  local max = computer.maxEnergy()
  if max == 0 then return 1 end
  return computer.energy() / max
end

--- Feed each empty generator a single fuel item. See build.lua for why
--- `allowOverflow` is only used while working.
local function feedGenerators(allowOverflow)
  local max = computer.maxEnergy()
  local energy = computer.energy()
  local headroom = max - energy
  local overflowOk = allowOverflow and energy < max * config.resumeAbove
  for _, gen in ipairs(generators) do
    if (gen.count() or 0) == 0 then
      local slot, stack = findFuelSlot()
      if slot then
        local per = fuelEnergy(stack) or 1280
        if overflowOk or headroom >= per then
          robot.select(slot)
          gen.insert(1)
          headroom = headroom - per
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Radio
-- ---------------------------------------------------------------------------

local session = string.format("%x-%x", math.random(0, 0x3fffffff),
  math.floor(computer.uptime() * 1000))
local seq = 0
local lastStatus = -math.huge
local paused, stopping = false, false

local function setPhase(phase, note)
  state.phase, state.note = phase, note
end

local function send(msg)
  msg.sid = session
  local data = serialization.serialize(msg)
  if adminAddress then
    modem.send(adminAddress, config.port, data)
  else
    modem.broadcast(config.port, data)
  end
end

--- Look at one modem message. Commands from the admin set flags; any other
--- message from the admin is returned to the caller.
local function receive(from, port, raw)
  if port ~= config.port or type(raw) ~= "string" then return nil end
  if adminAddress and from ~= adminAddress then return nil end
  local ok, msg = pcall(serialization.unserialize, raw)
  if not ok or type(msg) ~= "table" then return nil end
  if msg.type == "cmd" then
    if adminAddress then
      if msg.cmd == "pause" then paused = true
      elseif msg.cmd == "resume" then paused = false
      elseif msg.cmd == "stop" then stopping = true end
    end
    return nil
  end
  return msg, from
end

local function sendStatus(force)
  if not adminAddress then return end
  local t = computer.uptime()
  if not force and t - lastStatus < config.statusInterval then return end
  lastStatus = t
  pcall(send, {
    type = "status", phase = state.phase, note = state.note,
    tile = state.tile, round = state.round, p = state.p, i = state.i, pos = state.pos,
    energy = math.floor(energyFraction() * 100), fuel = fuelCount(),
  })
end

--- Send a message to the admin and wait for its reply, resending until one
--- comes. A robot that cannot reach the admin does no work: it waits here.
local function request(msg)
  seq = seq + 1
  msg.seq = seq
  local started = computer.uptime()
  local warned = false
  local prevPhase, prevNote = state.phase, state.note
  while true do
    pcall(send, msg)
    local deadline = computer.uptime() + config.requestTimeout
    repeat
      local _, _, from, port, _, raw = event.pull(math.max(0.05, deadline - computer.uptime()),
        "modem_message")
      if from then
        local reply, sender = receive(from, port, raw)
        if reply and reply.re == seq then
          if not adminAddress then adminAddress = sender end
          if warned then
            log("[NET] The admin answered again.")
            setPhase(prevPhase, prevNote)
          end
          lastStatus = computer.uptime()
          return reply
        end
      end
    until computer.uptime() >= deadline
    if not warned and computer.uptime() - started > config.contactWarnAfter then
      warned = true
      setPhase("no-contact", "waiting for the admin")
      log("[NET] No answer from the admin. Nothing moves until it answers.")
    end
    feedGenerators(false)
  end
end

local function pollRadio()
  while true do
    local _, _, from, port, _, raw = event.pull(0, "modem_message")
    if not from then return end
    receive(from, port, raw)
  end
end

--- Sleep while keeping the radio, the generators and the status going.
local function wait(seconds)
  local deadline = computer.uptime() + seconds
  repeat
    local _, _, from, port, _, raw = event.pull(
      math.max(0, math.min(1, deadline - computer.uptime())), "modem_message")
    if from then receive(from, port, raw) end
    feedGenerators(false)
    sendStatus()
  until computer.uptime() >= deadline
end

--- Handle pause and stop from the admin. Returns "stop" when the program should end.
local function checkCommands()
  pollRadio()
  if paused and not stopping then
    local prevPhase, prevNote = state.phase, state.note
    setPhase("paused")
    sendStatus(true)
    log("[CMD] Paused by the admin.")
    while paused and not stopping do
      wait(2)
    end
    setPhase(prevPhase, prevNote)
    if not stopping then log("[CMD] Resumed.") end
  end
  if stopping then return "stop" end
  return nil
end

-- ---------------------------------------------------------------------------
-- Where this robot may dig
-- ---------------------------------------------------------------------------

local DX = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
local DZ = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }

--- May this robot break a block (that is not an inventory) in cell (x, y, z)?
local function canDig(x, y, z)
  if y < 0 then return false end
  if x == -1 and z == 0 then return y <= H end   -- the column above the pad
  local id = tiles.tileOf(g, x, z)
  if id == nil or id == tiles.COLUMN then return false end
  if y == H then return true end                 -- the travel layer is kept clear
  return y < H and id == state.tile
end

--- Is the ender chest allowed in the cell below? Only inside this robot's own tile.
local function chestAllowedHere()
  local p = state.pos
  return state.tile ~= nil and p.y >= 1 and p.y <= H and tiles.tileOf(g, p.x, p.z) == state.tile
end

--- Is the block on this side an inventory: another robot, or a chest?
local function inventoryAt(side)
  return ic.getInventorySize(side) ~= nil
end

-- ---------------------------------------------------------------------------
-- Movement
-- ---------------------------------------------------------------------------

local function turnTo(dir)
  local diff = (dir - state.facing) % 4
  if diff == 1 then robot.turnRight()
  elseif diff == 3 then robot.turnLeft()
  elseif diff == 2 then robot.turnAround() end
  state.facing = dir
end

local SIDE = { forward = sides.front, up = sides.up, down = sides.down }
local ACTIONS = {
  forward = { detect = robot.detect, swing = robot.swing, move = robot.forward },
  up = { detect = robot.detectUp, swing = robot.swingUp, move = robot.up },
  down = { detect = robot.detectDown, swing = robot.swingDown, move = robot.down },
}
local digging = { forward = false, up = false, down = false }

local function cellToward(kind)
  local p = state.pos
  if kind == "forward" then return p.x + DX[state.facing], p.y, p.z + DZ[state.facing] end
  if kind == "up" then return p.x, p.y + 1, p.z end
  return p.x, p.y - 1, p.z
end

--- Try to move one cell, digging where allowed.
--- @return "moved", "robot" (an inventory is in the way), "forbidden" (a block
---   this robot may not break here), or "stuck" (a block that will not break)
local function tryMove(kind)
  local a = ACTIONS[kind]
  local x, y, z = cellToward(kind)
  local dug = false

  local function clearWay()
    if inventoryAt(SIDE[kind]) then return "robot" end
    if not canDig(x, y, z) then return "forbidden" end
    a.swing()
    dug = true
    return nil
  end

  for _ = 1, config.moveRetries do
    -- A move into a block fails only after a 0.4 s penalty, while detect()
    -- costs one tick: look first while digging, just move while it is clear.
    if digging[kind] and a.detect() then
      local blocked = clearWay()
      if blocked then return blocked end
    end
    if a.move() then
      digging[kind] = dug
      state.pos.x, state.pos.y, state.pos.z = x, y, z
      saveState()
      return "moved"
    end
    if a.detect() then
      local blocked = clearWay()   -- gravel refills the gap, so this can repeat
      if blocked then return blocked end
    else
      os.sleep(0.5)                -- a mob in the way; give it a moment
    end
  end
  return "stuck"
end

--- Move one cell, waiting for robots in the way to leave.
--- @return true, or false plus "forbidden", "stuck" or "stop"
local function step(kind)
  local blockedSince, prevPhase, prevNote = nil, nil, nil
  while true do
    local result = tryMove(kind)
    if result == "moved" then
      if blockedSince then setPhase(prevPhase, prevNote) end
      return true
    end
    if result ~= "robot" then return false, result end
    if not blockedSince then
      blockedSince = computer.uptime()
      prevPhase, prevNote = state.phase, state.note
    elseif computer.uptime() - blockedSince > config.blockedReportAfter
       and state.phase ~= "blocked" then
      local x, y, z = cellToward(kind)
      setPhase("blocked", string.format("robot or inventory at %d,%d,%d", x, y, z))
      log("[WAIT] Blocked by a " .. state.note)
      sendStatus(true)
    end
    if checkCommands() == "stop" then return false, "stop" end
    wait(1 + math.random() * 2)
  end
end

--- Go to a cell: rise first, then X, then Z, then sink (like build.lua).
local function gotoCell(tx, ty, tz)
  while state.pos.y < ty do
    local ok, why = step("up")
    if not ok then return false, why end
  end
  while state.pos.x ~= tx do
    turnTo(tx > state.pos.x and 0 or 2)
    local ok, why = step("forward")
    if not ok then return false, why end
  end
  while state.pos.z ~= tz do
    turnTo(tz > state.pos.z and 1 or 3)
    local ok, why = step("forward")
    if not ok then return false, why end
  end
  while state.pos.y > ty do
    local ok, why = step("down")
    if not ok then return false, why end
  end
  return true
end

local function clearBelow()
  local p = state.pos
  for _ = 1, config.moveRetries do
    if not robot.detectDown() then return true end
    if inventoryAt(sides.down) or not canDig(p.x, p.y - 1, p.z) then return false end
    if not robot.swingDown() then return false end   -- unbreakable or not harvestable
    state.counters.cleared = state.counters.cleared + 1
  end
  return not robot.detectDown()
end

-- ---------------------------------------------------------------------------
-- Travel between tiles
-- ---------------------------------------------------------------------------

local function laneAllowed(x, z, target)
  local id = tiles.tileOf(g, x, z)
  if id == nil or id == tiles.COLUMN then return false end
  return lane[id] == true or id == target
end

--- One cell along the travel layer. When a robot is in the way, wait a moment;
--- if it stays there, step to the side (right first) and let the caller re-plan.
local function laneStep(dir, target)
  local tries, blockedSince = 0, nil
  while true do
    turnTo(dir)
    local result = tryMove("forward")
    if result == "moved" then return true end
    if result ~= "robot" then return false, result end

    tries = tries + 1
    if tries >= 3 then
      tries = 0
      for _, side in ipairs({ (dir + 1) % 4, (dir + 3) % 4 }) do
        if laneAllowed(state.pos.x + DX[side], state.pos.z + DZ[side], target) then
          turnTo(side)
          if tryMove("forward") == "moved" then
            -- Pass the robot before re-planning: otherwise the new route can
            -- lead straight back to the cell this robot was waiting in.
            if laneAllowed(state.pos.x + DX[dir], state.pos.z + DZ[dir], target) then
              turnTo(dir)
              tryMove("forward")
            end
            return true
          end
        end
      end
    end

    blockedSince = blockedSince or computer.uptime()
    if computer.uptime() - blockedSince > config.blockedReportAfter and state.phase ~= "blocked" then
      setPhase("blocked", string.format("robot in the travel layer at %d,%d",
        state.pos.x + DX[dir], state.pos.z + DZ[dir]))
      log("[WAIT] Blocked by a " .. state.note)
      sendStatus(true)
    end
    if checkCommands() == "stop" then return false, "stop" end
    wait(1 + math.random() * 2)
  end
end

--- Fly to a tile: up to the travel layer, then over tiles whose travel layer
--- is dug. Returns once the robot is above (or inside) the tile.
local function travelToTile(target)
  -- A robot that waited above the travel layer comes back down into it first.
  while state.pos.y > H do
    local ok, why = step("down")
    if not ok then return false, why end
  end
  if tiles.tileOf(g, state.pos.x, state.pos.z) == target then return true end
  while state.pos.y < H do
    setPhase("travelling", "to tile " .. target)
    local ok, why = step("up")
    if not ok then return false, why end
  end
  while true do
    local here = tiles.tileOf(g, state.pos.x, state.pos.z)
    if here == target then return true end
    if here == nil then return false, "outside the build area" end
    local route = tiles.path(g, here, target, function(id) return lane[id] == true end)
    if not route then return false, "no dug route to the tile" end
    local nx, nz = tiles.clampInto(g, route[2], state.pos.x, state.pos.z)
    local dir
    if nx ~= state.pos.x then
      dir = (nx > state.pos.x) and 0 or 2
    else
      dir = (nz > state.pos.z) and 1 or 3
    end
    setPhase("travelling", "to tile " .. target)
    local ok, why = laneStep(dir, target)
    if not ok then return false, why end
    feedGenerators(true)   -- never the chest while travelling: not our tile
    sendStatus()
  end
end

-- ---------------------------------------------------------------------------
-- Ender chest
-- ---------------------------------------------------------------------------

local function placeChest()
  if not chestAllowedHere() then return false, "not inside this robot's tile" end
  local slot = findChestSlot()
  if not slot then return false, "no ender chest in inventory" end
  if not clearBelow() then return false, "cannot clear a cell for the chest" end
  robot.select(slot)
  if not robot.placeDown() then return false, "could not place the ender chest" end
  state.chestPlaced = true
  saveState()
  return true
end

--- Break the placed chest and confirm it came back. Stops the program if it
--- did not: without the chest nothing can be built.
local function recoverChest()
  if not state.chestPlaced then return true end
  robot.swingDown()
  state.chestPlaced = false
  saveState()
  if not findChestSlot() then
    error("the ender chest did not come back after breaking it (does it need silk touch?)", 0)
  end
  return true
end

local function scanChest()
  local found = {}
  local size = ic.getInventorySize(sides.down)
  if not size then return found end
  for slot = 1, size do
    local stack = ic.getStackInSlot(sides.down, slot)
    local key = stackKey(stack)
    if key then
      local entry = found[key]
      if entry then
        entry.count = entry.count + (stack.size or 0)
      else
        found[key] = { slot = slot, count = stack.size or 0, name = stack.name, damage = stack.damage or 0 }
      end
    end
  end
  return found
end

--- Pull up to `wanted` of one item out of the placed chest, always leaving one
--- empty slot for the chest itself (see build.lua).
local function suckItem(key, wanted)
  local size = ic.getInventorySize(sides.down)
  if not size then return 0 end
  local got = 0
  for slot = 1, size do
    if got >= wanted then break end
    local stack = ic.getStackInSlot(sides.down, slot)
    if stackKey(stack) == key then
      local target = findSlot(key)
      if target and robot.space(target) == 0 then target = nil end
      if not target then
        if freeSlotCount() < 2 then break end
        target = findEmptySlot()
      end
      if not target then break end
      robot.select(target)
      local before = robot.count(target)
      ic.suckFromSlot(sides.down, slot, math.min(wanted - got, robot.space(target)))
      got = got + (robot.count(target) - before)
    end
  end
  if got > 0 then slotCache[key] = nil end
  return got
end

--- Fetches every chest item fuelEnergy accepts, so charcoal (minecraft:coal@1)
--- counts too.
local function topUpFuel()
  local have = fuelCount()
  if have >= config.fuelReserve then return end
  for key, info in pairs(scanChest()) do
    if fuelEnergy(info) then
      have = have + suckItem(key, config.fuelReserve - have)
      if have >= config.fuelReserve then return end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Junk disposal
-- ---------------------------------------------------------------------------

--- Drop everything that is not the chest, fuel, or a stocked material, toward
--- an open side. Never toward a block: if it is a robot or chest, drop() would
--- put the junk inside it.
local function voidJunk()
  if freeSlotCount() >= config.minFreeSlots then return end
  local open = false
  for _ = 1, 4 do
    if not robot.detect() then open = true break end
    robot.turnRight()
    state.facing = (state.facing + 1) % 4
  end
  if not open then return end
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 then
      local stack = stackAt(slot)
      local key = stackKey(stack)
      local keep = isChestStack(stack)
        or (stack and fuelEnergy(stack) ~= nil)
        or (key and state.stock[key])
      if not keep then
        robot.select(slot)
        robot.drop()
      end
    end
  end
  saveState()
end

-- ---------------------------------------------------------------------------
-- Energy: rest and fuel
-- ---------------------------------------------------------------------------

local function restockFuelFromChest()
  local hadChest = state.chestPlaced
  if not hadChest and not placeChest() then return end
  topUpFuel()
  if not hadChest then recoverChest() end
end

local function restIfNeeded()
  if energyFraction() >= config.restBelow then return end
  local prevPhase, prevNote = state.phase, state.note
  setPhase("resting")
  log(string.format("[REST] Energy %d%%, resting.", math.floor(energyFraction() * 100)))
  local warnedNoFuel = false
  while energyFraction() < config.resumeAbove do
    feedGenerators(true)
    local waitSeconds = 5
    if fuelCount() == 0 then
      restockFuelFromChest()
      if fuelCount() == 0 then
        setPhase("waiting-fuel", "out of fuel")
        if not warnedNoFuel then
          log("[WAIT] No fuel aboard or in the ender chest.")
          warnedNoFuel = true
        end
        if energyFraction() < config.shutdownBelow then
          log("[FATAL] Out of fuel and nearly out of energy. Saving and shutting down.")
          sendStatus(true)
          saveState()
          computer.shutdown()
          return
        end
        waitSeconds = config.restockRetrySeconds
      end
    end
    wait(waitSeconds)
  end
  setPhase(prevPhase, prevNote)
  log("[REST] Energy restored, resuming.")
end

local lastFuelFetchFailed = nil

--- Keep the generators burning; fetch fuel from the chest when none is aboard.
--- Runs before the cell below gets its block, because fetching places the
--- ender chest into that cell.
local function keepGeneratorsFed()
  local anyEmpty = false
  for _, gen in ipairs(generators) do
    if (gen.count() or 0) == 0 then anyEmpty = true break end
  end
  if not anyEmpty then return end

  if not findFuelSlot() then
    local t = computer.uptime()
    if lastFuelFetchFailed and t - lastFuelFetchFailed < config.restockRetrySeconds then return end
    restockFuelFromChest()
    if not findFuelSlot() then
      lastFuelFetchFailed = t
      return
    end
    lastFuelFetchFailed = nil
  end
  feedGenerators(true)
end

-- ---------------------------------------------------------------------------
-- Materials and cells
-- ---------------------------------------------------------------------------

--- Get a slot holding `key`, restocking from the chest and waiting if needed.
--- `need` is how many this robot still needs in the current layer of its tile:
--- it pulls no more than that, so it does not sit on stacks another robot is
--- waiting for.
local function acquireMaterial(key, need)
  local slot = findSlot(key)
  if slot then return slot end

  voidJunk()

  local prevPhase, prevNote = state.phase, state.note
  setPhase("restocking", key)
  local placed = state.chestPlaced or placeChest()
  if not placed then
    setPhase(prevPhase, prevNote)
    return nil
  end

  local wanted = config.stacksPerRestock * 64
  if need then wanted = math.max(1, math.min(wanted, need)) end
  local got = suckItem(key, wanted)
  topUpFuel()

  if got == 0 then
    -- Stocked but currently empty: wait for a refill, however long it takes.
    setPhase("waiting-materials", key)
    sendStatus(true)
    log("[WAIT] Out of " .. key .. ". Waiting for a restock.")
    while got == 0 do
      if fuelCount() == 0 then topUpFuel() end
      if checkCommands() == "stop" then break end
      wait(config.restockRetrySeconds)
      got = suckItem(key, wanted)
    end
    if got > 0 then log("[WAIT] Got " .. got .. " of " .. key .. ", resuming.") end
  end

  recoverChest()
  setPhase(prevPhase, prevNote)
  return findSlot(key)
end

--- `needFor(key)` counts the cells still to do that need `key` (for restocking).
local function processCell(cellValue, palette, x, y, z, needFor)
  if cellValue == plan.PALETTE_AIR then
    if robot.detectDown() then clearBelow() end
    return
  end
  if cellValue == plan.PALETTE_SKIP then return end

  local entry = plan.paletteEntry(palette, cellValue)
  if not entry then
    log("[WARN] Unknown palette index " .. cellValue)
    return
  end

  local key = itemKey(entry.itemName, entry.damage)
  if not state.stock[key] then
    if robot.detectDown() then clearBelow() end
    logManual("not stocked", x, y, z, key)
    state.counters.skipped = state.counters.skipped + 1
    return
  end

  local slot = acquireMaterial(key, needFor and needFor(key))
  if not slot then
    state.deferred[#state.deferred + 1] = { x = x, z = z, v = cellValue }
    return
  end
  robot.select(slot)

  local fuzzy = (entry.flags & plan.FLAG_ORIENT) ~= 0
  if robot.compareDown(fuzzy) then return end   -- the right block is already there

  if robot.detectDown() then clearBelow() end
  if robot.placeDown() then
    state.counters.placed = state.counters.placed + 1
  else
    state.deferred[#state.deferred + 1] = { x = x, z = z, v = cellValue }
    state.counters.deferred = state.counters.deferred + 1
  end
end

--- The item types in the chest, for the whole build round. Chest contents
--- only, so every robot works from the same list.
local function takeStockSnapshot()
  setPhase("stock-check")
  local ok, err = placeChest()
  if not ok then return nil, err end
  local stock = {}
  for key in pairs(scanChest()) do stock[key] = true end
  topUpFuel()
  recoverChest()
  return stock
end

-- ---------------------------------------------------------------------------
-- Tile work
-- ---------------------------------------------------------------------------

--- Tell the admin how far the tile has got. False if the tile was released.
local function reportProgress()
  local reply = request({
    type = "progress", tile = state.tile, round = state.round, p = state.p, i = state.i,
    pos = state.pos, phase = state.phase, manual = state.manualQueue,
  })
  state.manualQueue = {}
  saveState()
  return reply.type == "ok"
end

local function failReach(why, x, y, z)
  if why == "stop" then return "stopped" end
  return "error", string.format("could not reach %d,%d,%d (%s)", x, y, z, tostring(why))
end

--- Round 1: dig the tile empty from the travel layer (pass 0, y = H) down to
--- layer 0. Top-down, so falling sand and gravel always land on a layer that
--- still gets dug (see build.lua). Layer 0 is dug from above.
local function excavateTile()
  local x0, z0, w, l = tiles.bounds(g, state.tile)
  local cells = w * l
  for pass = state.p, H do
    state.p = pass
    local y = H - pass
    local travelY = (y == 0) and 1 or y
    for index = state.i, cells - 1 do
      state.i = index
      setPhase("digging", string.format("tile %d, y %d", state.tile, y))
      if index % w == 0 and not reportProgress() then return "released" end

      local lx, lz = tiles.cellPosition(pass, index, w, l)
      local x, z = x0 + lx, z0 + lz
      local ok, why = gotoCell(x, travelY, z)
      if not ok then return failReach(why, x, travelY, z) end

      if y == 0 and robot.detectDown() and not clearBelow() then
        logManual("could not dig", x, 0, z, "unbreakable block")
      end

      saveState()
      sendStatus()
      restIfNeeded()
      keepGeneratorsFed()
      if (index + 1) % config.voidCheckInterval == 0 then voidJunk() end
      if checkCommands() == "stop" then return "stopped" end
      os.sleep(0)
    end
    state.i = 0
    saveState()
  end
  return "done"
end

--- Round 2: fill the tile layer by layer. For layer y the robot travels at
--- y+1 and places the block below it.
local function buildTile(handle)
  local x0, z0, w, l = tiles.bounds(g, state.tile)
  local cells = w * l
  local W = handle.header.width

  if state.needStock then
    local lx, lz = tiles.cellPosition(state.p, state.i, w, l)
    local ok, why = gotoCell(x0 + lx, state.p + 1, z0 + lz)
    if not ok then return failReach(why, x0 + lx, state.p + 1, z0 + lz) end
    local stock, err = takeStockSnapshot()
    if not stock then return "error", "the stock check failed: " .. tostring(err) end
    local reply = request({ type = "stock", stock = stock })
    state.stock = reply.stock or stock
    state.needStock = false
    saveState()
    local n = 0
    for _ in pairs(state.stock) do n = n + 1 end
    log(string.format("[STOCK] Sent the admin %d item types found in the chest.", n))
  end

  for layer = state.p, H - 1 do
    state.p = layer
    local layerData = plan.layer(handle, layer)

    local function needFor(key)
      local n = 0
      for j = state.i, cells - 1 do
        local jx, jz = tiles.cellPosition(layer, j, w, l)
        local entry = plan.paletteEntry(handle.palette,
          string.byte(layerData, (x0 + jx) + (z0 + jz) * W + 1))
        if entry and itemKey(entry.itemName, entry.damage) == key then n = n + 1 end
      end
      return n
    end

    for index = state.i, cells - 1 do
      state.i = index
      setPhase("building", string.format("tile %d, y %d", state.tile, layer))
      if index % w == 0 and not reportProgress() then return "released" end

      local lx, lz = tiles.cellPosition(layer, index, w, l)
      local x, z = x0 + lx, z0 + lz
      local ok, why = gotoCell(x, layer + 1, z)
      if not ok then return failReach(why, x, layer + 1, z) end

      -- Energy and fuel BEFORE the cell below is filled: fetching fuel places
      -- the ender chest into that cell.
      restIfNeeded()
      keepGeneratorsFed()
      processCell(string.byte(layerData, x + z * W + 1), handle.palette, x, layer, z, needFor)

      saveState()
      sendStatus()
      if checkCommands() == "stop" then return "stopped" end
      os.sleep(0)
    end

    -- Retry the cells that would not place, now that their neighbours exist.
    if #state.deferred > 0 then
      local retry = state.deferred
      state.deferred = {}
      for _, cell in ipairs(retry) do
        if gotoCell(cell.x, layer + 1, cell.z) then
          processCell(cell.v, handle.palette, cell.x, layer, cell.z, function() return #retry end)
        end
        saveState()
      end
      for _, cell in ipairs(state.deferred) do
        local entry = plan.paletteEntry(handle.palette, cell.v)
        logManual("could not place", cell.x, layer, cell.z,
          entry and entry.itemName or ("index " .. cell.v))
      end
      state.deferred = {}
    end

    state.i = 0
    saveState()
  end
  return "done"
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function applyAssignment(reply)
  state.tile, state.round = reply.tile, reply.round
  state.p, state.i = reply.p or 0, reply.i or 0
  state.needStock = reply.needStock == true
  if reply.stock then state.stock = reply.stock end
  state.deferred = {}
  lane = tiles.decodeFlags(reply.lane)
  saveState()
end

local function claim()
  return request({
    type = "claim", at = tiles.tileOf(g, state.pos.x, state.pos.z), pos = state.pos,
  })
end

--- Ask for tiles and work them until the build is finished or the admin stops us.
--- @return "finished", "stopped", "rehello", or "error" plus a message
local function work(handle)
  if state.chestPlaced then recoverChest() end

  while true do
    if checkCommands() == "stop" then return "stopped" end

    if state.tile == nil then
      setPhase("asking", "for a tile")
      local reply = claim()
      if reply.type == "finished" then
        return "finished"
      elseif reply.type == "wait" then
        setPhase("waiting", reply.reason)
        -- Never wait in the travel layer, where other robots need to pass:
        -- move up out of it when the cell above is open.
        if state.pos.y == H then tryMove("up") end
        sendStatus(true)
        wait(reply.retry or 15)
      elseif reply.type == "assign" then
        applyAssignment(reply)
        log(string.format("[TILE] Tile %d (%s), starting at %s %d, cell %d.", state.tile,
          state.round, state.round == "build" and "layer" or "pass", state.p, state.i))
      else
        return "rehello"   -- the admin does not know this robot any more
      end
    else
      local ok, why = travelToTile(state.tile)
      if not ok then
        if why == "stop" then return "stopped" end
        setPhase("blocked", "cannot reach tile " .. state.tile .. ": " .. tostring(why))
        log("[WAIT] " .. state.note .. ". Trying again in 30 s.")
        sendStatus(true)
        wait(30)
        -- Ask again: the admin hands back the same tile with a fresh travel map.
        state.tile = nil
      else
        local result, detail
        if state.round == "excavate" then
          result, detail = excavateTile()
        else
          result, detail = buildTile(handle)
        end

        if result == "done" then
          request({ type = "done", tile = state.tile, round = state.round, pos = state.pos })
          log(string.format("[TILE] Finished tile %d (%s).", state.tile, state.round))
          state.tile, state.p, state.i = nil, 0, 0
          saveState()
        elseif result == "released" then
          log("[TILE] The admin released tile " .. tostring(state.tile) .. "; asking for another.")
          state.tile, state.p, state.i = nil, 0, 0
          saveState()
        elseif result == "stopped" then
          return "stopped"
        else
          return "error", detail
        end
      end
    end
  end
end

local function checkHardware()
  local ok = true
  if not ic then
    log("[FATAL] No Inventory Controller upgrade. It is required.")
    ok = false
  end
  if #generators == 0 then
    log("[FATAL] No Generator Upgrade. There is no charger, so it is required.")
    ok = false
  end
  if not modem or not modem.isWireless() then
    log("[FATAL] No wireless network card. It is required to talk to the admin.")
    ok = false
  end
  if robot.inventorySize() < 16 then
    log("[FATAL] Inventory too small (" .. robot.inventorySize() .. "); add an Inventory Upgrade.")
    ok = false
  end
  local durability, reason = robot.durability()
  if durability == nil and reason == "no tool equipped" then
    log("[FATAL] No tool equipped.")
    ok = false
  end
  if not hasAngel then
    log("[WARN] No Angel upgrade: the ender chest cannot be placed over open air.")
  end
  if ok then
    log(string.format("[OK] %d generator(s), %d inventory slots. A Hover upgrade is also needed.",
      #generators, robot.inventorySize()))
  end
  return ok
end

local function main()
  local planPath, forget = nil, false
  for _, a in ipairs(args) do
    if a == "--new" then
      forget = true
    elseif a:sub(1, 2) == "--" then
      log("[FATAL] Unknown option " .. a)
      return
    elseif not planPath then
      planPath = a
    end
  end
  if not planPath then
    log("Usage: pbuild <plan> [--new]")
    return
  end

  local handle, err = plan.open(planPath)
  if not handle then
    log("[FATAL] Cannot open plan: " .. tostring(err))
    return
  end
  local ok, verr = plan.verify(handle)
  if not ok then
    log("[FATAL] " .. tostring(verr))
    plan.close(handle)
    return
  end
  if not checkHardware() then
    plan.close(handle)
    return
  end

  local h = handle.header
  H = h.height
  local info = { name = handle.name, version = h.planVersion, crc = h.crcStored }

  local saved = (not forget) and loadState() or nil
  if saved and saved.plan and saved.plan.name == info.name and saved.plan.version == info.version
     and saved.plan.crc == info.crc then
    for k, v in pairs(saved) do state[k] = v end
    log(string.format("[RESUME] At (%d,%d,%d) facing %d, tile %s.", state.pos.x, state.pos.y,
      state.pos.z, state.facing, tostring(state.tile)))
  elseif saved then
    log("[FATAL] This robot's saved progress is for another plan.")
    log("[FATAL] Put it on the start pad and run with --new.")
    plan.close(handle)
    return
  else
    state.plan = info
    log("[SETUP] Fresh start: standing on the start pad (-1,0,0), facing east.")
    saveState()
  end

  modem.open(config.port)
  pcall(modem.setStrength, 1e9)

  while true do
    setPhase("connecting")
    adminAddress = nil
    log("[NET] Looking for the admin on port " .. config.port .. "...")
    local reply = request({
      type = "hello", plan = info.name, version = info.version, crc = info.crc,
      tile = state.tile, round = state.round, pos = state.pos,
    })
    if reply.type == "reject" then
      log("[FATAL] The admin refused this robot: " .. tostring(reply.reason))
      break
    end

    state.id, state.tileSize = reply.id, reply.tileSize
    g = tiles.grid(h.width, H, h.length, state.tileSize)
    lane = tiles.decodeFlags(reply.lane)
    if reply.stock then state.stock = reply.stock end
    if reply.action ~= "continue" and state.tile ~= nil then
      log("[NET] The admin released tile " .. state.tile .. "; this robot will ask for another.")
      state.tile, state.p, state.i = nil, 0, 0
    end
    saveState()
    log(string.format("[NET] Connected as robot %d.", state.id))

    local okWork, result, detail = pcall(work, handle)
    if not okWork then
      detail = tostring(result)
      result = detail:find("interrupted") and "stopped" or "error"
    end

    if result == "finished" then
      setPhase("finished")
      sendStatus(true)
      log("[DONE] The admin says the build is finished.")
      break
    elseif result == "stopped" then
      setPhase("stopped")
      sendStatus(true)
      log("[STOP] Stopped. Progress saved; run the same command to continue.")
      break
    elseif result ~= "rehello" then
      setPhase("error", detail)
      sendStatus(true)
      log("[FATAL] " .. tostring(detail))
      log("[FATAL] Progress saved. Fix the problem, then run the same command.")
      break
    end
  end

  saveState()
  modem.close(config.port)
  plan.close(handle)
end

main()
