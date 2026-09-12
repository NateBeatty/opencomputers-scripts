-- mock_world.lua — Simulates the OpenComputers robot environment for testing.
-- Provides fake robot, component, and world APIs that the build loop can use.

local mock = {}

-- Block constants
mock.AIR = 0
mock.SKIP = 1
mock.BEDROCK = 0x01
mock.STONE = 0x02
mock.DIRT = 0x03
mock.GRASS = 0x04
mock.SAND = 0x05
mock.GRAVEL = 0x06
mock.LOG = 0x07
mock.LEAVES = 0x08
mock.COAL_BLOCK = 0x09
mock.CHEST = 0x0A

-- Energy constants (from AGENT_PROMPT.md section 4)
mock.ENERGY_MOVE = 15
mock.ENERGY_TURN = 2.5
mock.ENERGY_SWING = 5
mock.ENERGY_PLACE = 5
mock.ENERGY_DROP = 5
mock.ENERGY_COST_PER_TICK = 0.25
mock.SLEEP_FACTOR = 0.1
mock.GENERATOR_RATE = 0.8 -- per tick
mock.COAL_ENERGY = 1280

-- World dimensions
mock.WORLD_WIDTH = 32
mock.WORLD_HEIGHT = 16
mock.WORLD_LENGTH = 32

-- Robot initial state
mock.BASE_ENERGY = 20000
mock.BUFFER_SIZE = 60000 -- With 3 battery upgrades T3

--- Create a new mock world.
function mock.newWorld()
  local world = {
    -- Voxel data: world[x][y][z] = block id
    blocks = {},
    -- Item entities on the ground
    items = {},
    -- Robot state
    robot = {
      x = 0, y = 0, z = 0,
      facing = 1, -- 1 = +X, 2 = +Z, 3 = -X, 4 = -Z
      energy = mock.BASE_ENERGY,
      maxEnergy = mock.BUFFER_SIZE,
      inventory = {}, -- Array of {name, damage, count}
      inventorySize = 78, -- From section 3
      selectedSlot = 1,
      tool = {
        name = "pickaxe",
        durability = nil, -- nil means unbreakable
        maxDurability = nil,
      },
      state = "idle", -- idle, building, resting, waiting
    },
    -- Generator state
    generators = {
      { fuel = nil, fuelCount = 0, burning = false, queued = 0 },
    },
    -- Ender chest state (when placed)
    enderChest = {
      placed = false,
      x = 0, y = 0, z = 0,
      inventory = {}, -- Array of {name, damage, count}
    },
    -- Energy tracking
    energyTicks = 0,
    sleeping = false,
    -- Statistics
    stats = {
      moves = 0,
      turns = 0,
      swings = 0,
      places = 0,
      drops = 0,
      fuelConsumed = 0,
      errors = 0,
    },
  }

  -- Initialize world to air
  for x = 1, mock.WORLD_WIDTH do
    world.blocks[x] = {}
    for y = 1, mock.WORLD_HEIGHT do
      world.blocks[x][y] = {}
      for z = 1, mock.WORLD_LENGTH do
        world.blocks[x][y][z] = mock.AIR
      end
    end
  end

  return world
end

--- Set a block in the world (1-based coordinates).
function mock.setBlock(world, x, y, z, blockId)
  world.blocks[x][y][z] = blockId
end

--- Get a block from the world.
function mock.getBlock(world, x, y, z)
  if world.blocks[x] and world.blocks[x][y] then
    return world.blocks[x][y][z] or mock.AIR
  end
  return mock.AIR
end

--- Check if a cell is air.
function mock.isAir(world, x, y, z)
  return mock.getBlock(world, x, y, z) == mock.AIR
end

--- Move the robot. Returns success, errorMessage.
function mock.move(world, direction)
  local r = world.robot
  local dx, dy, dz = 0, 0, 0

  -- Direction depends on facing
  if direction == "up" then
    dy = 1
  elseif direction == "down" then
    dy = -1
  elseif direction == "forward" then
    if r.facing == 1 then dx = 1
    elseif r.facing == 2 then dz = 1
    elseif r.facing == 3 then dx = -1
    else dz = -1 end
  elseif direction == "back" then
    if r.facing == 1 then dx = -1
    elseif r.facing == 2 then dz = -1
    elseif r.facing == 3 then dx = 1
    else dz = 1 end
  elseif direction == "left" then
    if r.facing == 1 then dz = -1
    elseif r.facing == 2 then dx = -1
    elseif r.facing == 3 then dz = 1
    else dx = 1 end
  elseif direction == "right" then
    if r.facing == 1 then dz = 1
    elseif r.facing == 2 then dx = 1
    elseif r.facing == 3 then dz = -1
    else dx = -1 end
  end

  local newX, newY, newZ = r.x + dx, r.y + dy, r.z + dz

  -- Check bounds
  if newX < 1 or newX > mock.WORLD_WIDTH or
     newY < 1 or newY > mock.WORLD_HEIGHT or
     newZ < 1 or newZ > mock.WORLD_LENGTH then
    return false, "Out of bounds"
  end

  -- Check if target is air
  if not mock.isAir(world, newX, newY, newZ) then
    return false, "Target not air"
  end

  -- Check flight height limit (8 blocks above ground)
  if dy > 0 then
    local belowY = newY - 1
    local hasBlock = false
    for checkX = newX - 1, newX + 1 do
      for checkZ = newZ - 1, newZ + 1 do
        if mock.getBlock(world, checkX, belowY, checkZ) ~= mock.AIR then
          hasBlock = true
        end
      end
    end
    -- Check how high above the ground we'd be
    local groundY = 1
    for checkY = 1, newY - 1 do
      if mock.getBlock(world, newX, checkY, newZ) ~= mock.AIR then
        groundY = checkY + 1
      end
    end
    local heightAbove = newY - groundY
    if heightAbove > 8 and not hasBlock then
      return false, "Flight height limit"
    end
  end

  -- Consume energy
  local cost = mock.ENERGY_MOVE
  if r.energy < cost then
    return false, "Insufficient energy"
  end
  r.energy = r.energy - cost
  world.stats.moves = world.stats.moves + 1

  -- Move the robot
  r.x, r.y, r.z = newX, newY, newZ
  return true
end

--- Turn the robot.
function mock.turn(world, direction)
  local r = world.robot
  if direction == "left" then
    r.facing = ((r.facing + 2) % 4) + 1
  else -- right
    r.facing = ((r.facing % 4) + 1)
  end
  r.energy = r.energy - mock.ENERGY_TURN
  world.stats.turns = world.stats.turns + 1
  return true
end

--- Swing at a block (break it).
function mock.swing(world, side)
  local r = world.robot
  local tx, ty, tz = r.x, r.y, r.z

  if side == "down" then
    ty = r.y - 1
  elseif side == "up" then
    ty = r.y + 1
  elseif side == "forward" then
    if r.facing == 1 then tx = r.x + 1
    elseif r.facing == 2 then tz = r.z + 1
    elseif r.facing == 3 then tx = r.x - 1
    else tz = r.z - 1 end
  elseif side == "back" then
    if r.facing == 1 then tx = r.x - 1
    elseif r.facing == 2 then tz = r.z - 1
    elseif r.facing == 3 then tx = r.x + 1
    else tz = r.z + 1 end
  elseif side == "left" then
    if r.facing == 1 then tz = r.z - 1
    elseif r.facing == 2 then tx = r.x - 1
    elseif r.facing == 3 then tz = r.z + 1
    else tx = r.x + 1 end
  elseif side == "right" then
    if r.facing == 1 then tz = r.z + 1
    elseif r.facing == 2 then tx = r.x + 1
    elseif r.facing == 3 then tz = r.z - 1
    else tx = r.x - 1 end
  end

  -- Check if there's a block there
  local block = mock.getBlock(world, tx, ty, tz)
  if block == mock.AIR then
    return false
  end

  -- Break the block
  mock.setBlock(world, tx, ty, tz, mock.AIR)
  r.energy = r.energy - mock.ENERGY_SWING
  world.stats.swings = world.stats.swings + 1

  -- Collect item if applicable
  if block ~= mock.BEDROCK then
    local item = {name = "block_" .. block, damage = 0, count = 1}
    mock.addToInventory(world, item)
  end

  return true
end

--- Place a block.
function mock.place(world, side, item)
  local r = world.robot
  local tx, ty, tz = r.x, r.y, r.z

  if side == "down" then
    ty = r.y - 1
  elseif side == "up" then
    ty = r.y + 1
  elseif side == "forward" then
    if r.facing == 1 then tx = r.x + 1
    elseif r.facing == 2 then tz = r.z + 1
    elseif r.facing == 3 then tx = r.x - 1
    else tz = r.z - 1 end
  elseif side == "back" then
    if r.facing == 1 then tx = r.x - 1
    elseif r.facing == 2 then tz = r.z - 1
    elseif r.facing == 3 then tx = r.x + 1
    else tz = r.z + 1 end
  end

  -- Check if target is air
  if not mock.isAir(world, tx, ty, tz) then
    return false, "Target not air"
  end

  -- Check inventory
  local slot = r.selectedSlot
  if not r.inventory[slot] then
    return false, "No item in selected slot"
  end

  -- Place the block
  local blockId = string.sub(r.inventory[slot].name, 6) -- Remove "block_" prefix
  mock.setBlock(world, tx, ty, tz, blockId)
  r.energy = r.energy - mock.ENERGY_PLACE
  world.stats.places = world.stats.places + 1

  -- Decrement inventory
  r.inventory[slot].count = r.inventory[slot].count - 1
  if r.inventory[slot].count <= 0 then
    r.inventory[slot] = nil
  end

  return true
end

--- Add an item to inventory. Returns success.
function mock.addToInventory(world, item)
  local r = world.robot
  -- Find existing stack
  for i, slot in ipairs(r.inventory) do
    if slot.name == item.name and slot.damage == item.damage then
      slot.count = slot.count + item.count
      return true
    end
  end
  -- New slot
  if #r.inventory >= r.inventorySize then
    return false
  end
  r.inventory[#r.inventory + 1] = {name = item.name, damage = item.damage, count = item.count}
  return true
end

--- Remove item from inventory. Returns success, remaining.
function mock.removeItem(world, name, damage, count)
  local r = world.robot
  local found = 0
  for i, slot in ipairs(r.inventory) do
    if slot.name == name and slot.damage == damage then
      local take = math.min(count, slot.count)
      slot.count = slot.count - take
      found = found + take
      count = count - take
      if slot.count <= 0 then
        r.inventory[i] = nil
      end
      if count <= 0 then break end
    end
  end
  -- Repack array
  local newInv = {}
  for _, slot in ipairs(r.inventory) do
    newInv[#newInv + 1] = slot
  end
  r.inventory = newInv
  return found > 0, found
end

--- Drop items.
function mock.drop(world, side, item)
  local r = world.robot
  -- Remove from inventory
  local ok, count = mock.removeItem(world, item.name, item.damage, item.count)
  if not ok then
    return false, "Item not found"
  end
  r.energy = r.energy - mock.ENERGY_DROP
  world.stats.drops = world.stats.drops + 1
  -- Add to world items (simplified)
  return true, count
end

--- Select inventory slot.
function mock.selectSlot(world, slot)
  world.robot.selectedSlot = slot
  return true
end

--- Get inventory slot contents.
function mock.getSlot(world, slot)
  local r = world.robot
  if r.inventory[slot] then
    return r.inventory[slot].name, r.inventory[slot].damage, r.inventory[slot].count
  end
  return nil
end

--- Get inventory size (number of used slots).
function mock.getInventorySize(world)
  return #world.robot.inventory
end

--- Get energy.
function mock.getEnergy(world)
  return world.robot.energy
end

--- Get max energy.
function mock.getMaxEnergy(world)
  return world.robot.maxEnergy
end

--- Set sleeping state.
function mock.setSleeping(world, sleeping)
  world.sleeping = sleeping
end

--- Is sleeping?
function mock.isSleeping(world)
  return world.sleeping
end

--- Simulate energy consumption over time.
function mock.tick(world)
  local r = world.robot
  world.energyTicks = world.energyTicks + 1

  -- Generator produces energy
  for _, gen in ipairs(world.generators) do
    if gen.burning then
      r.energy = math.min(r.maxEnergy, r.energy + mock.GENERATOR_RATE)
    end
  end

  -- Energy cost
  local cost = mock.ENERGY_COST_PER_TICK
  if world.sleeping then
    cost = cost * mock.SLEEP_FACTOR
  end
  r.energy = r.energy - cost

  -- Check for crash
  if r.energy <= 0 then
    return false, "no energy"
  end

  return true
end

--- Insert fuel into generator.
function mock.insertFuel(world, item)
  for _, gen in ipairs(world.generators) do
    if gen.fuel == nil then
      gen.fuel = item.name
      gen.fuelCount = item.count
      gen.burning = true
      return true
    end
  end
  return false, "No available generator"
end

--- Get generator status.
function mock.getGenerator(world, index)
  local gen = world.generators[index or 1]
  return {
    fuel = gen.fuel,
    fuelCount = gen.fuelCount,
    burning = gen.burning,
  }
end

--- Place the ender chest.
function mock.placeChest(world, x, y, z)
  world.enderChest.placed = true
  world.enderChest.x = x
  world.enderChest.y = y
  world.enderChest.z = z
  mock.setBlock(world, x, y, z, mock.CHEST)
  return true
end

--- Remove the ender chest.
function mock.removeChest(world)
  if world.enderChest.placed then
    mock.setBlock(world, world.enderChest.x, world.enderChest.y, world.enderChest.z, mock.AIR)
    world.enderChest.placed = false
    return true
  end
  return false
end

--- Get chest inventory.
function mock.getChestInventory(world)
  return world.enderChest.inventory
end

--- Set chest inventory item.
function mock.setChestItem(world, slot, name, damage, count)
  if world.enderChest.inventory[slot] then
    world.enderChest.inventory[slot] = {name = name, damage = damage, count = count}
  else
    world.enderChest.inventory[slot] = {name = name, damage = damage, count = count}
  end
end

--- Suck items from chest.
function mock.suckFromChest(world, chestSlot, item)
  local chest = world.enderChest
  if not chest.placed then return false, "Chest not placed" end
  local slotData = chest.inventory[chestSlot]
  if not slotData then return false, "Empty slot" end
  if slotData.name ~= item.name or slotData.damage ~= item.damage then
    return false, "Wrong item"
  end
  local count = math.min(item.count, slotData.count)
  chest.inventory[chestSlot].count = chest.inventory[chestSlot].count - count
  if chest.inventory[chestSlot].count <= 0 then
    chest.inventory[chestSlot] = nil
  end
  return true, count
end

--- Restock ender chest (simulates player adding items).
function mock.restockChest(world, items)
  for _, item in ipairs(items) do
    world.enderChest.inventory[#world.enderChest.inventory + 1] = item
  end
end

--- Get robot position.
function mock.getPosition(world)
  return world.robot.x, world.robot.y, world.robot.z
end

--- Get robot facing.
function mock.getFacing(world)
  return world.robot.facing
end

--- Set robot state.
function mock.setState(world, state)
  world.robot.state = state
end

--- Get robot state.
function mock.getState(world)
  return world.robot.state
end

--- Compare block at side (simplified).
function mock.compare(world, side, item, fuzzy)
  -- Simplified: just check if there's a block there
  local r = world.robot
  local tx, ty, tz = r.x, r.y, r.z

  if side == "down" then
    ty = r.y - 1
  end

  local block = mock.getBlock(world, tx, ty, tz)
  return block ~= mock.AIR
end

--- Detect block at side.
function mock.detect(world, side)
  local r = world.robot
  local tx, ty, tz = r.x, r.y, r.z

  if side == "down" then
    ty = r.y - 1
  elseif side == "up" then
    ty = r.y + 1
  elseif side == "forward" then
    if r.facing == 1 then tx = r.x + 1
    elseif r.facing == 2 then tz = r.z + 1
    elseif r.facing == 3 then tx = r.x - 1
    else tz = r.z - 1 end
  end

  local block = mock.getBlock(world, tx, ty, tz)
  return block ~= mock.AIR, block
end

return mock
