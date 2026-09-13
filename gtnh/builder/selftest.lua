-- selftest.lua — Hardware, fuel and ender-chest checks.
--
-- Run this on the robot before the first build. It verifies the components the
-- builder needs and, most importantly, proves that breaking the Advanced Ender
-- Chest gives the chest back: a vanilla ender chest drops obsidian without silk
-- touch, and a builder that loses its chest cannot fetch any materials.

local component = require("component")
local computer = require("computer")
local robot = require("robot")
local sides = require("sides")

local passed, failed, warnings = 0, 0, 0

local function pass(msg) print("[PASS] " .. msg); passed = passed + 1 end
local function fail(msg) print("[FAIL] " .. msg); failed = failed + 1 end
local function warn(msg) print("[WARN] " .. msg); warnings = warnings + 1 end

local function available(kind)
  return component.isAvailable(kind)
end

print("=== OpenComputers Builder Self-Test ===")
print("")
print("--- Required components ---")

local ic = nil
if available("inventory_controller") then
  ic = component.getPrimary("inventory_controller")
  pass("Inventory Controller")
else
  fail("Inventory Controller upgrade missing (required)")
end

local generators = {}
for address in component.list("generator") do
  generators[#generators + 1] = component.proxy(address)
end
if #generators > 0 then
  pass(#generators .. " Generator Upgrade(s)")
else
  fail("No Generator Upgrade (required: there is no charger)")
end

local slots = robot.inventorySize()
if slots >= 16 then
  pass("Inventory size " .. slots)
else
  fail("Inventory size " .. slots .. " (need at least 16; add an Inventory Upgrade)")
end

do
  local durability, reason = robot.durability()
  if durability == nil and reason == "no tool equipped" then
    fail("No tool equipped")
  elseif durability == nil then
    pass("Tool equipped and cannot be damaged")
  else
    pass(string.format("Tool equipped, durability %.1f%%", durability * 100))
  end
end

print("")
print("--- Optional components ---")
for _, kind in ipairs({ "angel", "chunkloader", "modem", "internet" }) do
  if available(kind) then
    pass(kind)
  else
    warn(kind .. " not installed")
  end
end

print("")
print("--- Energy ---")
local energy, maxEnergy = computer.energy(), computer.maxEnergy()
-- Energy values are floats; Lua 5.3's %d throws on a fractional number, so
-- format them with %.0f instead.
print(string.format("       %.0f / %.0f (%.0f%%)", energy, maxEnergy, energy / maxEnergy * 100))
if energy > 0 then pass("Energy buffer") else fail("No energy") end

if not ic then
  print("")
  print("Cannot run the inventory and chest checks without the Inventory Controller.")
  print(string.format("=== %d passed, %d failed, %d warnings ===", passed, failed, warnings))
  return
end

-- ---------------------------------------------------------------------------
-- Ender chest
-- ---------------------------------------------------------------------------

print("")
print("--- Ender chest ---")

local chestSlot, chestName
for slot = 1, slots do
  if robot.count(slot) > 0 then
    local stack = ic.getStackInInternalSlot(slot)
    if stack and stack.name and stack.name:lower():find("ender", 1, true) then
      chestSlot, chestName = slot, stack.name
      break
    end
  end
end

if not chestSlot then
  warn("No ender chest in the robot's inventory; the chest test was skipped")
else
  print("       Found " .. chestName .. " in slot " .. chestSlot)

  -- The cell below must be clear before the chest can go down.
  if robot.detectDown() then robot.swingDown() end

  robot.select(chestSlot)
  if not robot.placeDown() then
    fail("Could not place the ender chest below the robot")
  else
    pass("Chest placed")

    local size = ic.getInventorySize(sides.down)
    if size and size > 0 then
      pass("Chest is readable (" .. size .. " slots)")

      local kinds, total = 0, 0
      for slot = 1, size do
        local stack = ic.getStackInSlot(sides.down, slot)
        if stack and stack.name then
          kinds = kinds + 1
          total = total + (stack.size or 0)
        end
      end
      print(string.format("       %d stacks, %d items", kinds, total))

      local fuel = false
      for slot = 1, size do
        local stack = ic.getStackInSlot(sides.down, slot)
        if stack and stack.name == "minecraft:coal" then fuel = true break end
      end
      if fuel then pass("Coal found in the chest") else warn("No coal in the chest; the robot needs fuel") end
    else
      fail("Cannot read the chest. Use a global (non-personal) frequency.")
    end

    -- The important one: does breaking it give the chest back?
    robot.swingDown()
    local recovered = false
    for slot = 1, slots do
      if robot.count(slot) > 0 then
        local stack = ic.getStackInInternalSlot(slot)
        if stack and stack.name and stack.name:lower():find("ender", 1, true) then
          recovered = true
          break
        end
      end
    end
    if recovered then
      pass("Chest recovered after breaking it")
    else
      fail("Chest NOT recovered. Check silk touch, or the tool's harvest level.")
      print("       The builder halts rather than continue without its chest.")
    end
  end
end

-- ---------------------------------------------------------------------------
-- Generator
-- ---------------------------------------------------------------------------

print("")
print("--- Generator ---")
if #generators > 0 then
  local gen = generators[1]
  local queued = gen.count() or 0
  if queued > 0 then
    pass("Generator already has " .. queued .. " fuel item(s) queued")
  else
    local fuelSlot
    for slot = 1, slots do
      if robot.count(slot) > 0 then
        local stack = ic.getStackInInternalSlot(slot)
        if stack and stack.name == "minecraft:coal" then fuelSlot = slot break end
      end
    end
    if fuelSlot then
      robot.select(fuelSlot)
      local before = computer.energy()
      if gen.insert(1) then
        pass("Generator accepted one coal")
        os.sleep(2)
        if computer.energy() > before then
          pass("Energy is rising")
        else
          warn("Energy did not rise yet (it may already be full)")
        end
      else
        fail("Generator refused the fuel")
      end
    else
      warn("No coal aboard, so the generator was not tested")
    end
  end
end

print("")
print(string.format("=== %d passed, %d failed, %d warnings ===", passed, failed, warnings))
if failed > 0 then
  print("[RESULT] Self-test FAILED")
else
  print("[RESULT] Self-test PASSED")
end
