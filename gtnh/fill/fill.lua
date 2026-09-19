-- fill.lua — Fill an area with dirt (or any block) up to the robot's level.
--
-- Usage: fill <forward> <right> [--stop-at-liquid] [--restart]
--
-- The robot starts standing in a corner cell of the area, facing along it.
-- The area runs <forward> cells ahead and <right> cells to the right, both
-- counting the starting cell. The starting cell is the top layer that gets
-- filled; the robot travels one block above it and digs through anything in
-- that travel layer.
--
-- For each column the robot goes down until the block below it is solid,
-- then climbs back up placing a block under itself at every step. On the
-- way down:
--   * air and replaceable blocks (vanilla tall grass, snow layers) are just
--     moved into; OpenComputers deletes them when the robot enters the cell
--   * passable blocks (flowers, modded grass, torches) are broken first
--   * liquids (water, lava) are moved through and filled like air. With
--     --stop-at-liquid the robot instead flies back to the start and says
--     where the liquid was; run the same command again to resume.
--
-- Supplies come from an ender chest carried in the inventory. When the robot
-- runs out of the fill block it places the chest above itself, takes a few
-- stacks, breaks the chest again and carries on. If the chest is empty it
-- waits there until it is refilled. Fuel for the generators comes from the
-- same chest.
--
-- Needs: Inventory Controller, Generator, Angel upgrades, an ender chest, and
-- a tool that breaks the chest and gives it back (an unbreakable pickaxe).

local component = require("component")
local computer = require("computer")
local robot = require("robot")
local sides = require("sides")
local serialization = require("serialization")
local filesystem = require("filesystem")

local args = {...}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local config = {
  stateFile = "/home/fill_state.txt",
  fillItem = "minecraft:dirt@0",  -- "name@damage" of the block to fill with
  stacksPerRestock = 4,           -- stacks of the fill block to take per trip
  restockRetrySeconds = 30,       -- how often to re-check an empty chest
  chestPattern = "ender",         -- substring identifying the ender chest item
  fuelReserve = 16,               -- fuel items to keep aboard
  fuelItems = { ["minecraft:coal"] = 1280 },  -- "name" or "name@damage" -> energy per item
  restBelow = 0.30,     -- stop and let the generators catch up below this fraction
  resumeAbove = 0.90,   -- ... until energy is back above this fraction
  shutdownBelow = 0.05, -- save and power off below this fraction
  maxDepth = 64,        -- stop if a column goes this far below the top layer
  minFreeSlots = 2,     -- drop junk when fewer free slots than this
  moveRetries = 16,
}

do -- optional /etc/fill.cfg overrides
  local f = loadfile("/etc/fill.cfg")
  if f then
    local ok, user = pcall(f)
    if ok and type(user) == "table" then
      for k, v in pairs(user) do config[k] = v end
    end
  end
end

local stopAtLiquid = false  -- --stop-at-liquid

-- ---------------------------------------------------------------------------
-- State (saved after every move, so a restart resumes where it stopped)
-- ---------------------------------------------------------------------------

-- Coordinates: x = cells forward, z = cells right, y = 0 is the top fill
-- layer (the starting cell) and the robot travels at y = 1.
local state = {
  forward = 0, right = 0,
  index = 0,                      -- next column to fill, in serpentine order
  pos = { x = 0, y = 0, z = 0 },
  facing = 0,                     -- 0=+X (forward), 1=+Z (right), 2=-X, 3=-Z
  chestPlaced = false,            -- the ender chest is in the cell above the robot
  placed = 0,
  failed = 0,
}

local function log(msg) print(msg) end

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

-- ---------------------------------------------------------------------------
-- Components and inventory
-- ---------------------------------------------------------------------------

local ic = component.isAvailable("inventory_controller") and component.inventory_controller or nil

local generators = {}
for address in component.list("generator") do
  generators[#generators + 1] = component.proxy(address)
end

local function stackKey(stack)
  if not stack or not stack.name then return nil end
  return stack.name .. "@" .. tostring(stack.damage or 0)
end

local function stackAt(slot)
  if robot.count(slot) == 0 then return nil end
  return ic.getStackInInternalSlot(slot)
end

local function findSlot(match)
  for slot = 1, robot.inventorySize() do
    local stack = stackAt(slot)
    if stack and match(stack) then return slot, stack end
  end
  return nil
end

local function countItems(match)
  local total = 0
  for slot = 1, robot.inventorySize() do
    local stack = stackAt(slot)
    if stack and match(stack) then total = total + robot.count(slot) end
  end
  return total
end

local function isFill(stack) return stackKey(stack) == config.fillItem end

local function isChest(stack)
  return stack.name:lower():find(config.chestPattern, 1, true) ~= nil
end

local function fuelEnergy(stack)
  return config.fuelItems[stackKey(stack)] or config.fuelItems[stack.name]
end

local function isFuel(stack) return fuelEnergy(stack) ~= nil end

local function findFillSlot()
  local selected = robot.select()
  local stack = stackAt(selected)
  if stack and isFill(stack) then return selected end
  return findSlot(isFill)
end

local function freeSlotCount()
  local n = 0
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) == 0 then n = n + 1 end
  end
  return n
end

--- Drop whatever digging and broken plants have left in the inventory. Only
--- called with the robot on top of a finished column, and never into an
--- inventory below.
local function dropJunk()
  if freeSlotCount() >= config.minFreeSlots then return end
  if ic.getInventorySize(sides.down) then return end
  local selected = robot.select()
  for slot = 1, robot.inventorySize() do
    local stack = stackAt(slot)
    if stack and not (isFill(stack) or isFuel(stack) or isChest(stack)) then
      robot.select(slot)
      robot.dropDown()
    end
  end
  robot.select(selected)
end

-- ---------------------------------------------------------------------------
-- Ender chest
-- ---------------------------------------------------------------------------

--- Place the ender chest in the cell above, clearing it first. The Angel
--- upgrade lets it go there even with nothing around it.
local function placeChest()
  local slot = findSlot(isChest)
  if not slot then return false, "no ender chest in the inventory" end
  for _ = 1, config.moveRetries do
    local something = robot.detectUp()
    if not something then break end
    robot.swingUp()
  end
  robot.select(slot)
  if not robot.placeUp() then return false, "could not place the ender chest" end
  state.chestPlaced = true
  saveState()
  return true
end

--- Break the placed chest and confirm it came back. Halts if it did not:
--- without the chest the robot cannot restock.
local function recoverChest()
  if not state.chestPlaced then return true end
  robot.swingUp()
  if not findSlot(isChest) then
    log("[FATAL] The ender chest did not come back after breaking it. State saved.")
    saveState()
    computer.shutdown()
    return false
  end
  state.chestPlaced = false
  saveState()
  return true
end

--- Pull up to `wanted` items matching `match` out of the placed chest.
--- Always leaves one slot empty: breaking the chest needs it.
local function suckItems(match, wanted)
  local size = ic.getInventorySize(sides.up)
  if not size then return 0 end
  local got = 0
  for slot = 1, size do
    if got >= wanted then break end
    local stack = ic.getStackInSlot(sides.up, slot)
    if stack and match(stack) then
      local key = stackKey(stack)
      -- Top up a matching stack with room, else start one in an empty slot
      -- as long as another empty slot remains.
      local target = findSlot(function(s) return stackKey(s) == key end)
      if target and robot.space(target) == 0 then target = nil end
      if not target and freeSlotCount() >= 2 then
        for s = 1, robot.inventorySize() do
          if robot.count(s) == 0 then target = s break end
        end
      end
      if not target then break end
      robot.select(target)
      local before = robot.count(target)
      ic.suckFromSlot(sides.up, slot, math.min(wanted - got, robot.space(target)))
      got = got + (robot.count(target) - before)
    end
  end
  return got
end

local function topUpFuel()
  local have = countItems(isFuel)
  if have < config.fuelReserve then suckItems(isFuel, config.fuelReserve - have) end
end

-- ---------------------------------------------------------------------------
-- Energy
-- ---------------------------------------------------------------------------

local function energyFraction()
  local max = computer.maxEnergy()
  if max == 0 then return 1 end
  return computer.energy() / max
end

--- Give each empty generator one fuel item while the battery has room.
local function feedGenerators()
  if energyFraction() >= config.resumeAbove then return end
  for _, gen in ipairs(generators) do
    if (gen.count() or 0) == 0 then
      local slot = findSlot(isFuel)
      if not slot then return end
      local selected = robot.select()
      robot.select(slot)
      gen.insert(1)
      robot.select(selected)
    end
  end
end

local function shutdownIfCritical()
  if energyFraction() < config.shutdownBelow then
    log("[FATAL] Energy critical. Saving and shutting down.")
    log("        Put fuel in the ender chest, turn the robot on, and run the same command.")
    saveState()
    computer.shutdown()
  end
end

--- Get a slot holding the fill block, restocking from the ender chest and
--- waiting for it to be refilled if it is empty. Returns nil only if the
--- chest could not be placed.
local function acquireFill()
  local slot = findFillSlot()
  if slot then return slot end

  dropJunk()
  local ok, why = placeChest()
  if not ok then return nil, why end

  local wanted = config.stacksPerRestock * 64
  local got = suckItems(isFill, wanted)
  topUpFuel()
  if got == 0 then
    log("[WAIT] Out of " .. config.fillItem .. ". Waiting for the ender chest to be refilled.")
    computer.beep(1000, 0.3)
    while got == 0 do
      feedGenerators()
      if countItems(isFuel) == 0 then topUpFuel() end
      shutdownIfCritical()
      os.sleep(config.restockRetrySeconds)
      got = suckItems(isFill, wanted)
    end
    log("[WAIT] Got " .. got .. ", carrying on.")
  end

  if not recoverChest() then return nil, "ender chest lost" end
  return findFillSlot()
end

--- Before each column: keep fuel aboard and rest if energy is low.
local lastFuelFetch = nil  -- computer.uptime() of the last fetch that found none
local function checkEnergy()
  if countItems(isFuel) == 0 then
    local now = computer.uptime()
    if not lastFuelFetch or now - lastFuelFetch >= config.restockRetrySeconds then
      local ok, why = placeChest()
      if not ok then return false, why end
      topUpFuel()
      if not recoverChest() then return false, "ender chest lost" end
      lastFuelFetch = (countItems(isFuel) == 0) and now or nil
    end
  end
  feedGenerators()

  if energyFraction() >= config.restBelow then return true end
  log(string.format("[REST] Energy %d%%, resting.", math.floor(energyFraction() * 100)))
  local warned = false
  while energyFraction() < config.resumeAbove do
    feedGenerators()
    if countItems(isFuel) == 0 then
      local ok, why = placeChest()
      if not ok then return false, why end
      topUpFuel()
      if not recoverChest() then return false, "ender chest lost" end
      if countItems(isFuel) == 0 then
        if not warned then
          log("[WAIT] No fuel aboard or in the ender chest.")
          warned = true
        end
        shutdownIfCritical()
        os.sleep(config.restockRetrySeconds)
      end
    end
    os.sleep(5)
  end
  log("[REST] Energy restored.")
  return true
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

--- Move one cell, breaking any block in the way and waiting out mobs. A move
--- into a liquid succeeds, so with --stop-at-liquid it is checked first.
--- Returns true, or false and a reason.
local function step(detect, swing, move)
  for _ = 1, config.moveRetries do
    local _, what = detect()
    if what == "liquid" and stopAtLiquid then return false, "liquid" end
    if what == "solid" or what == "passable" then swing() end
    if what == "entity" then os.sleep(1) end
    local ok, reason = move()
    if ok then return true end
    if reason == "impossible move" then
      return false, "cannot move there (impossible move)"
    elseif reason == "not enough energy" then
      return false, reason
    end
  end
  return false, "blocked"
end

local function forward()
  local ok, why = step(robot.detect, robot.swing, robot.forward)
  if ok then
    state.pos.x = state.pos.x + DX[state.facing]
    state.pos.z = state.pos.z + DZ[state.facing]
    saveState()
  end
  return ok, why
end

local function up()
  local ok, why = step(robot.detectUp, robot.swingUp, robot.up)
  if ok then
    state.pos.y = state.pos.y + 1
    saveState()
  end
  return ok, why
end

--- Fly to column (x, z) at travel height.
local function travelTo(x, z)
  while state.pos.y < 1 do
    local ok, why = up()
    if not ok then return false, why end
  end
  while state.pos.x ~= x do
    turnTo(x > state.pos.x and 0 or 2)
    local ok, why = forward()
    if not ok then return false, why end
  end
  while state.pos.z ~= z do
    turnTo(z > state.pos.z and 1 or 3)
    local ok, why = forward()
    if not ok then return false, why end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------

--- Columns run in rows along +X, stepping along +Z, alternating direction
--- so consecutive columns are next to each other.
local function columnPosition(index)
  local row = index // state.forward
  local col = index % state.forward
  local x = (row % 2 == 0) and col or (state.forward - 1 - col)
  return x, row
end

--- Go down to the first solid block. Returns true, or false and a reason.
local function descend()
  local tries = 0
  while true do
    local _, what = robot.detectDown()
    if what == "solid" then return true end
    if what == "liquid" and stopAtLiquid then return false, "liquid" end
    if state.pos.y <= -config.maxDepth then
      return false, "deeper than maxDepth (" .. config.maxDepth .. ")"
    end
    tries = tries + 1
    if tries > config.moveRetries then
      return false, "cannot get past a " .. tostring(what) .. " block"
    end
    if what == "passable" then
      robot.swingDown()
    elseif what == "entity" then
      os.sleep(1)
    else -- air, replaceable or liquid: moving in removes the block
      local ok, reason = robot.down()
      if ok then
        state.pos.y = state.pos.y - 1
        saveState()
        tries = 0
      elseif reason == "not enough energy" then
        return false, reason
      end
    end
  end
end

--- Fill the column under the robot, which is at travel height above it.
--- Returns true, or false and a reason.
local function fillColumn()
  local ok, why = descend()
  if not ok then return false, why end
  while state.pos.y < 1 do
    local slot
    slot, why = acquireFill()
    if not slot then return false, why end
    ok, why = up()
    if not ok then return false, why end
    robot.select(slot)
    if robot.placeDown() then
      state.placed = state.placed + 1
    else
      state.failed = state.failed + 1
      log(string.format("[WARN] Could not place at %d forward, %d right, %d below the top",
        state.pos.x, state.pos.z, 1 - state.pos.y))
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

--- End the run: fly back to the start and keep the state for a resume.
local function stop(msg)
  log("[STOP] " .. msg)
  local ok = travelTo(0, 0)
  if ok then turnTo(0) end
  saveState()
  if ok then
    log("Back at the start. Fix it, then run the same command to resume.")
  else
    log("Could not fly back; the robot stayed where it stopped.")
  end
end

local function checkHardware(resuming)
  if not ic then
    log("[FATAL] No Inventory Controller upgrade. It is required.")
    return false
  end
  if #generators == 0 then
    log("[FATAL] No Generator upgrade. It is the only power source, so it is required.")
    return false
  end
  local durability, reason = robot.durability()
  if durability == nil and reason == "no tool equipped" then
    log("[FATAL] No tool equipped. It needs a pickaxe to break the ender chest.")
    return false
  end
  if not (resuming and state.chestPlaced) and not findSlot(isChest) then
    log("[FATAL] No ender chest in the inventory.")
    return false
  end
  if not component.isAvailable("angel") then
    log("[WARN] No Angel upgrade: placing the ender chest in mid-air will fail.")
  end
  return true
end

local function main()
  local restart = false
  local numbers = {}
  for _, a in ipairs(args) do
    if a == "--restart" then restart = true
    elseif a == "--stop-at-liquid" then stopAtLiquid = true
    else numbers[#numbers + 1] = tonumber(a) end
  end
  local F, R = numbers[1], numbers[2]
  if not (F and R and F >= 1 and R >= 1 and F % 1 == 0 and R % 1 == 0) then
    log("Usage: fill <forward> <right> [--stop-at-liquid] [--restart]")
    return
  end

  local saved = (not restart) and loadState() or nil
  local resuming = saved and saved.forward == F and saved.right == R
  if saved and not resuming then
    log(string.format("[FATAL] A %dx%d fill is unfinished. Run `fill %d %d` to resume it,",
      saved.forward, saved.right, saved.forward, saved.right))
    log("        or add --restart to start this one from the robot's current cell.")
    return
  end
  if resuming then state = saved end
  if not checkHardware(resuming) then return end

  if resuming then
    log(string.format("[RESUME] Column %d of %d, at %d forward, %d right, height %d.",
      state.index + 1, F * R, state.pos.x, state.pos.z, state.pos.y))
    if state.chestPlaced then
      log("[RESUME] The ender chest was left placed; recovering it.")
      if not recoverChest() then return end
    end
  else
    state.forward, state.right = F, R
    saveState()
  end

  log(string.format("[FILL] %d x %d with %s (%d aboard)%s",
    F, R, config.fillItem, countItems(isFill), stopAtLiquid and ", stopping at liquids" or ""))

  local total = F * R
  while state.index < total do
    local ok, why = checkEnergy()
    if not ok then return stop(why) end

    local x, z = columnPosition(state.index)
    ok, why = travelTo(x, z)
    if not ok then
      if why == "liquid" then why = "liquid in the travel layer" end
      return stop(string.format("%s, moving to %d forward, %d right", why, x, z))
    end

    ok, why = fillColumn()
    if not ok then
      if why == "liquid" then
        return stop(string.format("Liquid at %d forward, %d right, %d below the start cell",
          x, z, 1 - state.pos.y))
      end
      return stop(string.format("%s, at %d forward, %d right", why, x, z))
    end
    state.index = state.index + 1
    saveState()
    dropJunk()
    os.sleep(0)
  end

  travelTo(0, 0)
  turnTo(0)
  filesystem.remove(config.stateFile)
  log(string.format("[DONE] Placed %d, failed %d. The robot is above its starting cell.",
    state.placed, state.failed))
end

main()
