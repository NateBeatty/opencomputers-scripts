-- sim_fill.lua — Runs the real fill.lua against a simulated world.
-- Run from converter/: node test/run_lua_tests.js ../gtnh/fill/test/sim_fill.lua

local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/")
local fillPath = here .. "/../fill.lua"

passed, failed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("  PASS: " .. name)
    passed = passed + 1
  else
    print("  FAIL: " .. name .. " — " .. tostring(err))
    failed = failed + 1
  end
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("%s: expected %s, got %s", msg or "assert_eq", tostring(b), tostring(a)), 2)
  end
end

local DIRT = "minecraft:dirt"
local CHEST = "EnderStorage:enderChest"
local COAL = "minecraft:coal"

-- ---------------------------------------------------------------------------
-- World: blocks[key] = "solid" | "passable" | "replaceable" | "liquid"
--                      | "dirt" | "chest"
-- ---------------------------------------------------------------------------

local function key(x, y, z) return x .. "," .. y .. "," .. z end

--- Build a world, set up the OC modules and run fill.lua with `argv`.
--- `ground[z][x]` is the height of the solid top at column (x, z), relative
--- to the start cell (0 means the start cell's own level is solid).
--- `chest` lists the ender chest's contents as { name, size } pairs.
local function run(opts)
  local blocks = {}
  local files = {}
  local out = {}
  local W, L = opts.forward, opts.right
  for z = 0, L - 1 do
    for x = 0, W - 1 do
      local top = opts.ground[z + 1][x + 1]
      for y = -80, top do blocks[key(x, y, z)] = "solid" end
    end
  end
  for k, v in pairs(opts.extra or {}) do blocks[k] = v end
  blocks[key(0, 0, 0)] = nil  -- the robot stands there

  local bot = { x = 0, y = 0, z = 0, facing = 0, sel = 1, energy = 10000 }
  local inv = {}
  inv[1] = { name = CHEST, damage = 0, size = 1, maxSize = 64 }
  if opts.dirt then inv[2] = { name = DIRT, damage = 0, size = opts.dirt, maxSize = 64 } end

  local chestInv = {}
  for _, e in ipairs(opts.chest or {}) do  -- split into real 64-item stacks
    local left = e[2]
    while left > 0 do
      chestInv[#chestInv + 1] = { name = e[1], damage = 0, size = math.min(64, left), maxSize = 64 }
      left = left - 64
    end
  end
  local stats = { chestPlacements = 0, liquidEntered = 0 }

  local DX = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
  local DZ = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
  local function offset(dir)
    if dir == "up" then return bot.x, bot.y + 1, bot.z end
    if dir == "down" then return bot.x, bot.y - 1, bot.z end
    return bot.x + DX[bot.facing], bot.y, bot.z + DZ[bot.facing]
  end
  local function content(dir)
    local b = blocks[key(offset(dir))]
    if b == nil then return false, "air" end
    if b == "liquid" then return false, "liquid" end
    if b == "replaceable" then return false, "replaceable" end
    if b == "passable" then return true, "passable" end
    return true, "solid"
  end
  local function addItem(name, n)
    for i = 1, 16 do
      local s = inv[i]
      if s and s.name == name and s.size < 64 then
        local take = math.min(n, 64 - s.size)
        s.size, n = s.size + take, n - take
      end
      if n == 0 then return true end
    end
    for i = 1, 16 do
      if not inv[i] then
        inv[i] = { name = name, damage = 0, size = n, maxSize = 64 }
        return true
      end
    end
    return false
  end
  local function move(dir)
    local something, what = content(dir)
    if something then return nil, what end
    local x, y, z = offset(dir)
    if blocks[key(x, y, z)] == "liquid" then stats.liquidEntered = stats.liquidEntered + 1 end
    blocks[key(x, y, z)] = nil
    bot.x, bot.y, bot.z = x, y, z
    return true
  end
  local function swing(dir)
    local k = key(offset(dir))
    local b = blocks[k]
    if b == "chest" then
      blocks[k] = nil
      assert(addItem(CHEST, 1), "no room for the chest")
      return true
    end
    if b == "solid" or b == "passable" or b == "dirt" then
      blocks[k] = nil
      if b == "passable" then addItem("minecraft:red_flower", 1) end
      if b == "solid" then addItem("minecraft:cobblestone", 1) end
      if b == "dirt" then addItem(DIRT, 1) end
      return true
    end
    return false
  end
  local function place(dir)
    local k = key(offset(dir))
    local b = blocks[k]
    if b and b ~= "replaceable" and b ~= "liquid" then return false end
    local s = inv[bot.sel]
    if not s then return false end
    blocks[k] = (s.name == CHEST) and "chest" or "dirt"
    if s.name == CHEST then stats.chestPlacements = stats.chestPlacements + 1 end
    s.size = s.size - 1
    if s.size == 0 then inv[bot.sel] = nil end
    return true
  end

  local robot = {
    detect = function() return content("fwd") end,
    detectUp = function() return content("up") end,
    detectDown = function() return content("down") end,
    forward = function() return move("fwd") end,
    up = function() return move("up") end,
    down = function() return move("down") end,
    swing = function() return swing("fwd") end,
    swingUp = function() return swing("up") end,
    swingDown = function() return swing("down") end,
    placeUp = function() return place("up") end,
    placeDown = function() return place("down") end,
    turnRight = function() bot.facing = (bot.facing + 1) % 4 end,
    turnLeft = function() bot.facing = (bot.facing + 3) % 4 end,
    turnAround = function() bot.facing = (bot.facing + 2) % 4 end,
    select = function(s) if s then bot.sel = s end return bot.sel end,
    count = function(s) return inv[s] and inv[s].size or 0 end,
    space = function(s) return inv[s] and (64 - inv[s].size) or 64 end,
    inventorySize = function() return 16 end,
    durability = function() return nil, "tool cannot be damaged" end,
    dropDown = function() inv[bot.sel] = nil return true end,
  }
  local UP = 1
  local function chestAbove(side)
    return side == UP and blocks[key(bot.x, bot.y + 1, bot.z)] == "chest"
  end
  local ic = {
    getStackInInternalSlot = function(s) return inv[s] end,
    getInventorySize = function(side) return chestAbove(side) and 27 or nil end,
    getStackInSlot = function(side, s) return chestAbove(side) and chestInv[s] or nil end,
    suckFromSlot = function(side, s, n)
      assert(chestAbove(side), "sucking with no chest above")
      local st = chestInv[s]
      if not st then return false end
      local target = inv[bot.sel]
      if target and target.name ~= st.name then return false end
      n = math.min(n, st.size, target and (64 - target.size) or 64)
      if target then target.size = target.size + n
      else inv[bot.sel] = { name = st.name, damage = 0, size = n, maxSize = 64 } end
      st.size = st.size - n
      if st.size == 0 then chestInv[s] = nil end
      return true
    end,
  }
  local generator = { count = function() return 1 end, insert = function() return true end }

  local uptime, waits = 0, 0
  local os_sleep = function(seconds)
    uptime = uptime + (seconds or 0)
    if (seconds or 0) == 0 then return end  -- just a yield
    waits = waits + 1
    if opts.onWait then opts.onWait(chestInv, waits) end
    if waits > 50 then error("stuck waiting") end
  end

  package.loaded.component = {
    isAvailable = function(k) return k == "inventory_controller" or k == "angel" end,
    inventory_controller = ic,
    list = function(kind)
      local done = kind ~= "generator"
      return function()
        if done then return nil end
        done = true
        return "gen0"
      end
    end,
    proxy = function() return generator end,
  }
  package.loaded.computer = {
    energy = function() return bot.energy end, maxEnergy = function() return 10000 end,
    beep = function() end,
    uptime = function() return uptime end,
    shutdown = function() error("shutdown") end,
  }
  package.loaded.robot = robot
  package.loaded.sides = { down = 0, up = UP }
  package.loaded.serialization = {
    serialize = function(t) return t end, unserialize = function(t) return t end,
  }
  package.loaded.filesystem = {
    remove = function(p) files[p] = nil end,
    rename = function(a, b) files[b] = files[a]; files[a] = nil end,
  }
  local realIo, realOs, realPrint = io, os, print
  io = { open = function(p, mode)
    if mode == "w" then
      return { write = function(_, d) files[p] = d end, close = function() end }
    end
    if files[p] == nil then return nil end
    return { read = function() return files[p] end, close = function() end }
  end }
  os = setmetatable({ sleep = os_sleep }, { __index = realOs })
  print = function(s) out[#out + 1] = s end
  local chunk = assert(loadfile(fillPath))
  local ok, err = pcall(chunk, table.unpack(opts.argv))
  io, os, print = realIo, realOs, realPrint
  if not ok then error(err) end

  local function count(name, where)
    local n = 0
    for _, s in pairs(where) do if s.name == name then n = n + s.size end end
    return n
  end
  return {
    blocks = blocks, bot = bot, out = table.concat(out, "\n"), files = files, stats = stats,
    robotCount = function(name) return count(name, inv) end,
    chestCount = function(name) return count(name, chestInv) end,
  }
end

local function isFilled(w, x, z) return w.blocks[key(x, 0, z)] ~= nil end

local function assertDoneAtHome(w)
  assert(w.out:find("%[DONE%]"), w.out)
  assert_eq(w.bot.x, 0, "home x") assert_eq(w.bot.y, 1, "home y") assert_eq(w.bot.z, 0, "home z")
  assert_eq(w.robotCount(CHEST), 1, "ender chest aboard")
  for k, b in pairs(w.blocks) do assert(b ~= "chest", "chest left placed at " .. k) end
end

print("sim_fill")

test("fills an uneven 3x2 area from the ender chest", function()
  local w = run({ forward = 3, right = 2, argv = { "3", "2" },
    ground = { { -1, -3, 0 }, { -2, -1, -4 } },
    chest = { { DIRT, 640 }, { COAL, 64 } } })
  for z = 0, 1 do for x = 0, 2 do
    assert(isFilled(w, x, z), "column " .. x .. "," .. z .. " not filled")
    assert(w.blocks[key(x, 1, z)] == nil, "filled above the top at " .. x .. "," .. z)
  end end
  -- 1 + 3 + 0 + 2 + 1 + 4 = 11 blocks, from one restock of 4 stacks
  assert_eq(w.chestCount(DIRT), 640 - 256, "dirt left in the chest")
  assert_eq(w.robotCount(DIRT), 256 - 11, "dirt left aboard")
  assert_eq(w.robotCount(COAL), 16, "fuel reserve aboard")
  assertDoneAtHome(w)
end)

test("walks through tall grass and breaks passable plants", function()
  local extra = {
    [key(1, -1, 0)] = "replaceable",
    [key(1, -2, 0)] = "replaceable",
    [key(2, -1, 0)] = "passable",
  }
  local w = run({ forward = 3, right = 1, argv = { "3", "1" }, dirt = 64,
    ground = { { -1, -3, -2 } }, extra = extra, chest = { { COAL, 64 } } })
  assert_eq(w.blocks[key(1, -2, 0)], "dirt", "grass cell refilled with dirt")
  assert_eq(w.blocks[key(2, -1, 0)], "dirt", "flower cell refilled with dirt")
  assertDoneAtHome(w)
end)

test("fills through water by default", function()
  local extra = { [key(1, -2, 0)] = "liquid", [key(1, -1, 0)] = "liquid" }
  local w = run({ forward = 3, right = 1, argv = { "3", "1" }, dirt = 64,
    ground = { { -1, -3, -2 } }, extra = extra, chest = { { COAL, 64 } } })
  assert_eq(w.blocks[key(1, -2, 0)], "dirt", "water cell filled")
  assert(w.stats.liquidEntered > 0, "never went into the water")
  assertDoneAtHome(w)
end)

test("--stop-at-liquid stops without entering, goes home, keeps state", function()
  local extra = { [key(1, -2, 0)] = "liquid" }
  local w = run({ forward = 3, right = 1, argv = { "3", "1", "--stop-at-liquid" }, dirt = 64,
    ground = { { -1, -3, -2 } }, extra = extra, chest = { { COAL, 64 } } })
  assert(w.out:find("Liquid at 1 forward, 0 right, 2 below"), w.out)
  assert_eq(w.stats.liquidEntered, 0, "entered liquid")
  assert_eq(w.bot.x, 0, "home x") assert_eq(w.bot.y, 1, "home y")
  assert(w.blocks[key(2, 0, 0)] == nil, "went past the water")
  assert(w.files["/home/fill_state.txt"], "state kept for resume")
end)

test("waits at an empty chest until it is refilled", function()
  local w = run({ forward = 2, right = 1, argv = { "2", "1" }, dirt = 3,
    ground = { { -2, -3 } }, chest = { { COAL, 64 } },
    onWait = function(chestInv, n)
      if n == 2 then chestInv[5] = { name = DIRT, damage = 0, size = 64, maxSize = 64 } end
    end })
  assert(w.out:find("%[WAIT%] Out of minecraft:dirt@0"), w.out)
  assert(w.out:find("%[WAIT%] Got 64"), w.out)
  assert(isFilled(w, 0, 0) and isFilled(w, 1, 0), "both columns filled")
  assertDoneAtHome(w)
end)

test("restocks mid-column with the chest in the column above", function()
  local w = run({ forward = 1, right = 1, argv = { "1", "1" }, dirt = 2,
    ground = { { -6 } }, chest = { { DIRT, 64 }, { COAL, 64 } } })
  for y = -5, 0 do assert_eq(w.blocks[key(0, y, 0)], "dirt", "cell " .. y) end
  assertDoneAtHome(w)
end)

test("digs through a hill in the travel layer", function()
  local w = run({ forward = 3, right = 1, argv = { "3", "1" }, dirt = 64,
    ground = { { -1, 2, -1 } }, chest = { { COAL, 64 } } })
  assert(w.blocks[key(1, 1, 0)] == nil, "travel layer cleared")
  assert_eq(w.blocks[key(1, 2, 0)], "solid", "hill above the travel layer left")
  assert(isFilled(w, 2, 0), "column past the hill filled")
end)

print(string.format("%d passed, %d failed", passed, failed))
