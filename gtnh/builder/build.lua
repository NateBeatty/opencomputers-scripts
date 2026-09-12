-- build.lua — The OpenComputers builder for GTNH 1.7.10.
--
-- Builds a .plan layer by layer. For layer y the robot travels at height y+1
-- and works the cell directly below it, so every footprint cell is excavated
-- once as a travel cell and filled once as a build cell.
--
-- Usage: build <plan> [--resume | --restart] [--dry-run] [--yes]
--                     [--resync <x> <y> <z> <facing>]
--
-- Setup (AGENT_PROMPT.md section 3): the robot starts standing IN schematic
-- cell (0,0,0) facing the direction that becomes +X. forward = +X, right = +Z,
-- up = +Y. There is no charger: the Generator Upgrade burning fuel from the
-- ender chest is the only power source.

local component = require("component")
local computer = require("computer")
local robot = require("robot")
local sides = require("sides")
local serialization = require("serialization")
local filesystem = require("filesystem")
local event = require("event")

local plan = require("plan")

local args = {...}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local config = {
  stateFile = "/home/builder_state.txt",
  manualFile = "/home/manual.txt",

  fuelReserve = 16,          -- fuel items to keep aboard
  fuelItems = { ["minecraft:coal"] = 1280 },  -- item name -> energy per item
  restBelow = 0.30,          -- rest when energy falls below this fraction
  resumeAbove = 0.90,        -- resume once energy is back above this fraction
  shutdownBelow = 0.05,      -- save and power off below this fraction

  restockRetrySeconds = 60,  -- how often to re-check the chest while waiting
  stacksPerRestock = 4,      -- stacks of the needed item to pull per trip
  minFreeSlots = 2,          -- void junk when fewer free slots than this

  chestPattern = "ender",    -- substring identifying the ender chest item
  broadcastPort = 65656,
  broadcastInterval = 10,    -- seconds
  controlAddress = nil,      -- only this modem address may send commands

  moveRetries = 16,          -- attempts before giving up on a blocked move
}

do -- optional /etc/builder.cfg overrides
  local f = loadfile("/etc/builder.cfg")
  if f then
    local ok, user = pcall(f)
    if ok and type(user) == "table" then
      for k, v in pairs(user) do config[k] = v end
    end
  end
end

-- ---------------------------------------------------------------------------
-- State (persisted after every cell)
-- ---------------------------------------------------------------------------

local state = {
  planName = nil, planVersion = nil, planCRC = nil,
  layer = 0, cellIndex = 0,
  pos = { x = 0, y = 0, z = 0 },
  facing = 0,                -- 0=+X, 1=+Z, 2=-X, 3=-Z
  phase = "idle",
  deferred = {},             -- cells to retry at the end of the layer
  stock = {},                -- "name@damage" -> true, snapshotted at start
  chestPlaced = false,
  chestPos = nil,
  counters = { placed = 0, cleared = 0, skipped = 0, deferred = 0 },
}

local lastBroadcast = 0

local function log(msg) print(msg) end

local function itemKey(name, damage) return name .. "@" .. tostring(damage or 0) end

local function stackKey(stack)
  if not stack or not stack.name then return nil end
  return itemKey(stack.name, stack.damage or 0)
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
local chunkloader = optionalComponent("chunkloader")
local hasAngel = component.isAvailable("angel")

local generators = {}
for address in component.list("generator") do
  generators[#generators + 1] = component.proxy(address)
end

-- ---------------------------------------------------------------------------
-- Inventory helpers
-- ---------------------------------------------------------------------------

local slotCache = {}  -- "name@damage" -> slot

local function stackAt(slot)
  return ic.getStackInInternalSlot(slot)
end

--- Find an inventory slot holding the given item, or nil.
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

local function fuelEnergy(name) return config.fuelItems[name] end

local function findFuelSlot()
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 then
      local stack = stackAt(slot)
      if stack and fuelEnergy(stack.name) then return slot, stack end
    end
  end
  return nil
end

local function countItem(key)
  local total = 0
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 and stackKey(stackAt(slot)) == key then
      total = total + robot.count(slot)
    end
  end
  return total
end

local function fuelCount()
  local total = 0
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 then
      local stack = stackAt(slot)
      if stack and fuelEnergy(stack.name) then total = total + robot.count(slot) end
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

--- Feed each generator a single item, and only when the energy it releases
--- actually fits: queued fuel burns even when the buffer is full.
local function feedGenerators()
  local headroom = computer.maxEnergy() - computer.energy()
  for _, gen in ipairs(generators) do
    if (gen.count() or 0) == 0 then
      local slot, stack = findFuelSlot()
      if slot then
        local per = fuelEnergy(stack.name) or 1280
        if headroom >= per then
          robot.select(slot)
          gen.insert(1)
          headroom = headroom - per
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Movement
-- ---------------------------------------------------------------------------

local DX = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
local DZ = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }

local function turnTo(dir)
  local diff = (dir - state.facing) % 4
  if diff == 1 then robot.turnRight()
  elseif diff == 3 then robot.turnLeft()
  elseif diff == 2 then robot.turnAround() end
  state.facing = dir
end

--- Move one cell in the current facing, digging or waiting as needed.
local function stepForward()
  for _ = 1, config.moveRetries do
    if robot.forward() then
      state.pos.x = state.pos.x + DX[state.facing]
      state.pos.z = state.pos.z + DZ[state.facing]
      return true
    end
    if robot.detect() then
      robot.swing()          -- a block is in the way (gravel refills, so retry)
    else
      os.sleep(0.5)          -- an entity is in the way; give it a moment
    end
  end
  return false
end

local function stepUp()
  for _ = 1, config.moveRetries do
    if robot.up() then state.pos.y = state.pos.y + 1; return true end
    if robot.detectUp() then robot.swingUp() else os.sleep(0.5) end
  end
  return false
end

local function stepDown()
  for _ = 1, config.moveRetries do
    if robot.down() then state.pos.y = state.pos.y - 1; return true end
    if robot.detectDown() then robot.swingDown() else os.sleep(0.5) end
  end
  return false
end

--- Travel to a cell, digging through the travel layer as needed. Those cells
--- get excavated on this pass anyway, so clearing them early is harmless.
local function gotoCell(tx, ty, tz)
  while state.pos.y < ty do if not stepUp() then return false end end
  while state.pos.x ~= tx do
    turnTo(tx > state.pos.x and 0 or 2)
    if not stepForward() then return false end
  end
  while state.pos.z ~= tz do
    turnTo(tz > state.pos.z and 1 or 3)
    if not stepForward() then return false end
  end
  while state.pos.y > ty do if not stepDown() then return false end end
  return true
end

local function clearBelow()
  for _ = 1, config.moveRetries do
    if not robot.detectDown() then return true end
    local ok = robot.swingDown()
    if not ok then return false end   -- unbreakable or not harvestable
    state.counters.cleared = state.counters.cleared + 1
  end
  return not robot.detectDown()
end

-- ---------------------------------------------------------------------------
-- State, logging, status
-- ---------------------------------------------------------------------------

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
  local f = io.open(config.manualFile, "a")
  if not f then return end
  f:write(string.format("%s at (%d,%d,%d): %s\n", reason, x, y, z, tostring(what)))
  f:close()
end

local function broadcast(force)
  if not modem then return end
  local now = computer.uptime()
  if not force and (now - lastBroadcast) < config.broadcastInterval then return end
  lastBroadcast = now
  local payload = {
    plan = state.planName, version = state.planVersion,
    layer = state.layer, layers = state.totalLayers,
    cell = state.cellIndex, cells = state.cellsPerLayer,
    phase = state.phase,
    energy = math.floor(energyFraction() * 100),
    fuel = fuelCount(),
    placed = state.counters.placed,
    skipped = state.counters.skipped,
    deferred = #state.deferred,
    note = state.note,
  }
  pcall(modem.broadcast, config.broadcastPort, serialization.serialize(payload))
end

local function setPhase(phase, note)
  state.phase = phase
  state.note = note
  broadcast(true)
end

--- Handle a pause/resume/stop/status command from the control station.
--- Modem messages are unauthenticated, so only the configured address is obeyed.
--- Returns "stop" when the build should end.
local function checkCommands()
  if not modem then return end
  while true do
    local _, _, from, port, _, message = event.pull(0, "modem_message")
    if not from then return end
    if port == config.broadcastPort and
       (config.controlAddress == nil or from == config.controlAddress) then
      local command = tostring(message)
      if command == "pause" then
        setPhase("paused")
        log("[CMD] Paused. Send 'resume' to continue.")
        while true do
          local _, _, f2, p2, _, m2 = event.pull(1, "modem_message")
          if f2 and p2 == config.broadcastPort and
             (config.controlAddress == nil or f2 == config.controlAddress) then
            if tostring(m2) == "resume" then
              setPhase("building")
              log("[CMD] Resumed.")
              break
            elseif tostring(m2) == "stop" then
              return "stop"
            end
          end
          feedGenerators()
          broadcast()
        end
      elseif command == "stop" then
        return "stop"
      elseif command == "status" then
        broadcast(true)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Ender chest
-- ---------------------------------------------------------------------------

--- Place the carried ender chest into the (already cleared) cell below.
local function placeChest()
  local slot = findChestSlot()
  if not slot then return false, "no ender chest in inventory" end
  if not clearBelow() then return false, "cannot clear a cell for the chest" end
  robot.select(slot)
  if not robot.placeDown() then return false, "could not place the ender chest" end
  state.chestPlaced = true
  state.chestPos = { x = state.pos.x, y = state.pos.y - 1, z = state.pos.z }
  saveState()
  return true
end

--- Break the placed chest and confirm it came back. Halts if it did not:
--- continuing without the chest would build nothing for hours.
local function recoverChest()
  if not state.chestPlaced then return true end
  robot.swingDown()
  local slot = findChestSlot()
  if not slot then
    setPhase("error", "ender chest was not recovered after breaking it")
    log("[FATAL] The ender chest did not come back. It may need silk touch.")
    log("[FATAL] State saved; fix the tool or the chest and run with --resume.")
    state.chestPlaced = false
    saveState()
    computer.shutdown()
    return false
  end
  state.chestPlaced = false
  state.chestPos = nil
  saveState()
  return true
end

--- Scan the placed chest: returns a map of "name@damage" -> {slot, count}.
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

--- Pull up to `wanted` of one item out of the placed chest.
local function suckItem(key, wanted)
  local size = ic.getInventorySize(sides.down)
  if not size then return 0 end
  local got = 0
  for slot = 1, size do
    if got >= wanted then break end
    local stack = ic.getStackInSlot(sides.down, slot)
    if stackKey(stack) == key then
      local target = findSlot(key) or findEmptySlot()
      if not target then break end
      robot.select(target)
      local before = robot.count(target)
      ic.suckFromSlot(sides.down, slot, wanted - got)
      got = got + (robot.count(target) - before)
    end
  end
  if got > 0 then slotCache[key] = nil end
  return got
end

local function topUpFuel()
  local have = fuelCount()
  if have >= config.fuelReserve then return end
  for name in pairs(config.fuelItems) do
    local pulled = suckItem(itemKey(name, 0), config.fuelReserve - have)
    have = have + pulled
    if have >= config.fuelReserve then return end
  end
end

-- ---------------------------------------------------------------------------
-- Junk disposal
-- ---------------------------------------------------------------------------

--- Drop everything that is not the chest, fuel, or a stocked material.
--- Dropped behind the robot, into the cell it just came from, which is clear.
--- Never drop toward an inventory: drop() inserts into one if it is there.
local function voidJunk()
  if freeSlotCount() >= config.minFreeSlots then return end
  setPhase("voiding")
  robot.turnAround()
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 then
      local stack = stackAt(slot)
      local key = stackKey(stack)
      local keep = isChestStack(stack)
        or (stack and fuelEnergy(stack.name) ~= nil)
        or (key and state.stock[key])
      if not keep then
        robot.select(slot)
        robot.drop()
      end
    end
  end
  robot.turnAround()
  setPhase("building")
end

-- ---------------------------------------------------------------------------
-- Energy: rest and fuel starvation
-- ---------------------------------------------------------------------------

local restockFuelFromChest  -- forward declaration

local function restIfNeeded()
  if energyFraction() >= config.restBelow then return end
  setPhase("resting")
  log(string.format("[REST] Energy %d%%, resting.", math.floor(energyFraction() * 100)))
  while energyFraction() < config.resumeAbove do
    feedGenerators()
    if fuelCount() == 0 then
      restockFuelFromChest()
      if fuelCount() == 0 then
        setPhase("waiting-fuel", "out of fuel")
        if energyFraction() < config.shutdownBelow then
          log("[FATAL] Out of fuel and nearly out of energy. Saving and shutting down.")
          log("[FATAL] Put coal in the ender chest, turn the robot on, and run with --resume.")
          saveState()
          computer.shutdown()
          return
        end
      end
    end
    broadcast()
    os.sleep(5)
  end
  setPhase("building")
  log("[REST] Energy restored, resuming.")
end

restockFuelFromChest = function()
  local hadChest = state.chestPlaced
  if not hadChest then
    local ok = placeChest()
    if not ok then return end
  end
  topUpFuel()
  if not hadChest then recoverChest() end
end

-- ---------------------------------------------------------------------------
-- Materials
-- ---------------------------------------------------------------------------

--- Get a slot holding `key`, restocking from the chest and waiting if needed.
--- Only called for items in the stock snapshot, which are always restocked.
local function acquireMaterial(key)
  local slot = findSlot(key)
  if slot then return slot end

  voidJunk()

  setPhase("restocking", key)
  local placed = state.chestPlaced or placeChest()
  if not placed then
    setPhase("error", "cannot place the ender chest")
    return nil
  end

  local wanted = config.stacksPerRestock * 64
  local got = suckItem(key, wanted)
  topUpFuel()

  if got == 0 then
    -- Stocked but currently empty: wait for the user to refill, however long
    -- it takes. The chest stays placed so this costs one scan per interval.
    setPhase("waiting-materials", key)
    log("[WAIT] Out of " .. key .. ". Waiting for a restock.")
    while got == 0 do
      feedGenerators()
      if fuelCount() == 0 then topUpFuel() end
      if energyFraction() < config.shutdownBelow then
        log("[FATAL] Energy critical while waiting. Saving and shutting down.")
        saveState()
        computer.shutdown()
        return nil
      end
      broadcast()
      os.sleep(config.restockRetrySeconds)
      got = suckItem(key, wanted)
    end
    log("[WAIT] Got " .. got .. " of " .. key .. ", resuming.")
  end

  recoverChest()
  setPhase("building")
  return findSlot(key)
end

-- ---------------------------------------------------------------------------
-- Cell processing
-- ---------------------------------------------------------------------------

local function processCell(cellValue, palette, x, y, z)
  if cellValue == plan.PALETTE_AIR then
    if robot.detectDown() then clearBelow() end
    return
  end
  if cellValue == plan.PALETTE_SKIP then
    return
  end

  local entry = plan.paletteEntry(palette, cellValue)
  if not entry then
    log("[WARN] Unknown palette index " .. cellValue)
    return
  end

  local key = itemKey(entry.itemName, entry.damage)

  -- Not in the stock snapshot: skip for the whole build, clear the cell so the
  -- block can be placed by hand later, and log it.
  if not state.stock[key] then
    if robot.detectDown() then clearBelow() end
    logManual("not stocked", x, y, z, key)
    state.counters.skipped = state.counters.skipped + 1
    return
  end

  local slot = acquireMaterial(key)
  if not slot then
    state.deferred[#state.deferred + 1] = { x = x, z = z, v = cellValue }
    return
  end
  robot.select(slot)

  local fuzzy = (entry.flags & plan.FLAG_ORIENT) ~= 0
  if robot.compareDown(fuzzy) then
    return  -- the right block is already there
  end

  if robot.detectDown() then clearBelow() end
  if robot.placeDown() then
    state.counters.placed = state.counters.placed + 1
  else
    state.deferred[#state.deferred + 1] = { x = x, z = z, v = cellValue }
    state.counters.deferred = state.counters.deferred + 1
  end
end

-- ---------------------------------------------------------------------------
-- Serpentine path
-- ---------------------------------------------------------------------------

--- Cell `index` of `layer` maps to (x, z). Rows run along X and step along Z,
--- with the X direction alternating per row so consecutive cells are adjacent,
--- and the Z direction alternating per layer so each layer starts where the
--- previous one finished. Pure, so resume can rebuild the position.
local function cellPosition(layer, index, W, L)
  local row = index // W
  local col = index % W
  local z = (layer % 2 == 0) and row or (L - 1 - row)
  local x = (row % 2 == 0) and col or (W - 1 - col)
  return x, z
end

-- ---------------------------------------------------------------------------
-- Stock snapshot
-- ---------------------------------------------------------------------------

--- Snapshot every item type in the chest and the robot's own inventory.
--- Types present now get waited for; everything else is skipped all build.
local function takeStockSnapshot()
  setPhase("stock-scan")
  local ok, err = placeChest()
  if not ok then
    log("[FATAL] " .. tostring(err))
    return false
  end

  local stock = {}
  local chestCounts = {}
  for key, info in pairs(scanChest()) do
    stock[key] = true
    chestCounts[key] = info.count
  end

  local robotOnly = {}
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 then
      local stack = stackAt(slot)
      if not isChestStack(stack) then
        local key = stackKey(stack)
        if key then
          if not stock[key] then robotOnly[key] = true end
          stock[key] = true
        end
      end
    end
  end

  topUpFuel()
  recoverChest()

  state.stock = stock
  return true, chestCounts, robotOnly
end

--- Print what will be built and what will be skipped, and ask to continue.
local function stockReport(handle, chestCounts, robotOnly, assumeYes)
  local palette = handle.palette
  local needed = {}
  for _, entry in ipairs(palette) do
    needed[itemKey(entry.itemName, entry.damage)] = true
  end

  log("")
  log("=== Stock report ===")
  local skippedTypes = 0
  for key in pairs(needed) do
    if state.stock[key] then
      local inChest = chestCounts[key]
      if inChest then
        log(string.format("  stocked  %-44s %d in chest", key, inChest))
      else
        log(string.format("  stocked  %-44s (robot only)", key))
      end
    else
      log(string.format("  SKIP     %s", key))
      skippedTypes = skippedTypes + 1
    end
  end

  local warned = false
  for key in pairs(robotOnly) do
    if needed[key] then
      if not warned then
        log("")
        log("  Note: these are in the robot but not the chest. The robot will")
        log("  still wait for them to be restocked when they run out:")
        warned = true
      end
      log("    " .. key)
    end
  end

  local haveFuel = false
  for name in pairs(config.fuelItems) do
    if state.stock[itemKey(name, 0)] then haveFuel = true end
  end
  if not haveFuel then
    log("")
    log("[FATAL] No fuel in the chest or inventory. The robot cannot run.")
    return false
  end

  log("")
  log(string.format("%d block types will be skipped for the whole build.", skippedTypes))
  if assumeYes then return true end
  io.write("Continue? [y/N] ")
  local answer = io.read()
  return answer and answer:lower():sub(1, 1) == "y"
end

-- ---------------------------------------------------------------------------
-- Dry run
-- ---------------------------------------------------------------------------

local function dryRun(handle)
  local h = handle.header
  local cells = h.width * h.height * h.length
  local counts = {}
  local place, air, skip = 0, 0, 0

  for y = 0, h.height - 1 do
    local layer = plan.layer(handle, y)
    for i = 1, #layer do
      local v = string.byte(layer, i)
      if v == plan.PALETTE_AIR then air = air + 1
      elseif v == plan.PALETTE_SKIP then skip = skip + 1
      else
        place = place + 1
        local entry = plan.paletteEntry(handle.palette, v)
        if entry then
          local key = itemKey(entry.itemName, entry.damage)
          counts[key] = (counts[key] or 0) + 1
        end
      end
    end
    os.sleep(0)
  end

  log(string.format("Plan: %s (version %d)", handle.name, h.planVersion))
  log(string.format("Size: %d x %d x %d", h.width, h.height, h.length))
  log(string.format("Cells: %d  place %d  air %d  skip %d", cells, place, air, skip))
  log("")
  log("Materials:")
  for key, n in pairs(counts) do
    log(string.format("  %-44s %d", key, n))
  end
  log("")
  local seconds = cells * 1.2
  log(string.format("Estimated time: %.1f hours", seconds / 3600))
  log(string.format("Estimated fuel: ~%d coal", math.ceil(cells * 20 / 1280)))
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function parseArgs()
  local opts = { resume = false, restart = false, dryRun = false, yes = false }
  local planPath = nil
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--resume" then opts.resume = true
    elseif a == "--restart" then opts.restart = true
    elseif a == "--dry-run" then opts.dryRun = true
    elseif a == "--yes" then opts.yes = true
    elseif a == "--resync" then
      opts.resync = {
        x = tonumber(args[i + 1]), y = tonumber(args[i + 2]),
        z = tonumber(args[i + 3]), facing = tonumber(args[i + 4]),
      }
      i = i + 4
    elseif not planPath then planPath = a end
    i = i + 1
  end
  return planPath, opts
end

local function checkHardware()
  if not ic then
    log("[FATAL] No Inventory Controller upgrade. It is required.")
    return false
  end
  if #generators == 0 then
    log("[FATAL] No Generator Upgrade. There is no charger, so it is required.")
    return false
  end
  if robot.inventorySize() < 16 then
    log("[FATAL] Inventory too small (" .. robot.inventorySize() .. "); add an Inventory Upgrade.")
    return false
  end
  local durability, reason = robot.durability()
  if durability == nil and reason == "no tool equipped" then
    log("[FATAL] No tool equipped.")
    return false
  end
  if durability == nil then
    log("[OK] Tool cannot be damaged.")
  else
    log(string.format("[OK] Tool durability %.1f%%", durability * 100))
  end
  log(string.format("[OK] %d generator(s), %d inventory slots, angel=%s, chunkloader=%s, modem=%s",
    #generators, robot.inventorySize(), tostring(hasAngel),
    tostring(chunkloader ~= nil), tostring(modem ~= nil)))
  return true
end

local function main()
  local planPath, opts = parseArgs()
  if not planPath then
    log("Usage: build <plan> [--resume | --restart] [--dry-run] [--yes]")
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

  if opts.dryRun then
    dryRun(handle)
    plan.close(handle)
    return
  end

  if not checkHardware() then plan.close(handle) return end

  local h = handle.header
  local W, H, L = h.width, h.height, h.length
  state.planName = handle.name
  state.planVersion = h.planVersion
  state.planCRC = h.crcStored
  state.totalLayers = H
  state.cellsPerLayer = W * L

  -- Resume or start fresh.
  local saved = (not opts.restart) and loadState() or nil
  if saved and saved.planName == handle.name and saved.planVersion == h.planVersion
     and saved.planCRC == h.crcStored then
    for k, v in pairs(saved) do state[k] = v end
    log(string.format("[RESUME] Layer %d, cell %d, at (%d,%d,%d) facing %d",
      state.layer, state.cellIndex, state.pos.x, state.pos.y, state.pos.z, state.facing))
    if state.chestPlaced then
      log("[RESUME] The chest was left placed; recovering it.")
      recoverChest()
    end
  elseif saved and not opts.restart then
    log("[FATAL] The saved state is for a different plan. Use --restart to start over.")
    plan.close(handle)
    return
  else
    -- Fresh build: step up out of cell (0,0,0), then snapshot the stock.
    log("[SETUP] Starting a fresh build.")
    if not stepUp() then
      log("[FATAL] Cannot move up out of the starting cell.")
      plan.close(handle)
      return
    end
    local okSnap, chestCounts, robotOnly = takeStockSnapshot()
    if not okSnap then plan.close(handle) return end
    if not stockReport(handle, chestCounts or {}, robotOnly or {}, opts.yes) then
      log("Aborted.")
      plan.close(handle)
      return
    end
  end

  if opts.resync then
    state.pos.x, state.pos.y, state.pos.z = opts.resync.x, opts.resync.y, opts.resync.z
    state.facing = opts.resync.facing
    log("[RESYNC] Position set by hand.")
  end

  if chunkloader then chunkloader.setActive(true) end
  setPhase("building")

  for layer = state.layer, H - 1 do
    state.layer = layer
    local layerData = plan.layer(handle, layer)
    log(string.format("[BUILD] Layer %d of %d", layer, H - 1))

    for index = state.cellIndex, (W * L) - 1 do
      state.cellIndex = index
      local x, z = cellPosition(layer, index, W, L)

      if not gotoCell(x, layer + 1, z) then
        setPhase("error", "blocked while moving")
        log(string.format("[FATAL] Could not reach (%d,%d,%d). State saved.", x, layer + 1, z))
        saveState()
        plan.close(handle)
        return
      end

      processCell(string.byte(layerData, index + 1), handle.palette, x, layer, z)

      saveState()
      broadcast()
      restIfNeeded()
      if checkCommands() == "stop" then
        setPhase("stopped")
        log("[CMD] Stopped by the control station. State saved.")
        saveState()
        plan.close(handle)
        return
      end
      os.sleep(0)
    end

    -- Retry the cells that would not place, now that their neighbours exist.
    if #state.deferred > 0 then
      log(string.format("[BUILD] Retrying %d deferred cells", #state.deferred))
      local retry = state.deferred
      state.deferred = {}
      for _, cell in ipairs(retry) do
        if gotoCell(cell.x, layer + 1, cell.z) then
          processCell(cell.v, handle.palette, cell.x, layer, cell.z)
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

    state.cellIndex = 0
    saveState()
  end

  setPhase("done")
  log("[DONE] Build complete.")
  log(string.format("  placed %d, cleared %d, skipped %d",
    state.counters.placed, state.counters.cleared, state.counters.skipped))
  log("  See " .. config.manualFile .. " for anything left to do by hand.")
  saveState()
  plan.close(handle)
end

main()
