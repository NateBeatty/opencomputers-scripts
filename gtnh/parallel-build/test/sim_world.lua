-- sim_world.lua — Runs several copies of the real pbuild.lua against a
-- simulated world and admin (the real pblogic), end to end:
--   * every cell of the box ends up dug and built as the plan says
--   * no robot breaks another robot, or digs or places outside its own tile
--   * a stopped robot can be released and its tile finished by another robot,
--     which waits (instead of digging) while the stopped robot is in the way
--
-- The world is simplified: no gravity, no flight limit (robots carry Hover),
-- unlimited energy. Timings roughly follow OpenComputers (a move 0.4 s).
--
-- Run with: node converter/test/run_lua_tests.js gtnh/parallel-build/test/sim_world.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../lib/?.lua;" .. package.path

local tiles = require("pbtiles")
local logic = require("pblogic")
local realPlan = require("plan")

-- A test can set PBUILD_SOURCE to run a modified pbuild.lua, e.g. to check that
-- the simulation notices a broken rule.
local PBUILD = PBUILD_SOURCE or assert(readFile(here .. "../pbuild.lua"), "cannot read pbuild.lua")

passed = 0
failed = 0

local function check(name, ok, detail)
  if ok then
    print("  PASS: " .. name)
    passed = passed + 1
  else
    print("  FAIL: " .. name .. (detail and (" — " .. detail) or ""))
    failed = failed + 1
  end
end

-- ---------------------------------------------------------------------------
-- Serialization (the subset OpenOS' serialization does)
-- ---------------------------------------------------------------------------

local function serialize(v)
  local t = type(v)
  if t == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key = type(k) == "string" and string.format("[%q]", k) or ("[" .. tostring(k) .. "]")
      parts[#parts + 1] = key .. "=" .. serialize(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "number" then
    if math.type(v) == "integer" then return tostring(v) end
    return string.format("%.17g", v)
  elseif t == "boolean" or t == "nil" then
    return tostring(v)
  end
  error("cannot serialize a " .. t)
end

local function unserialize(s)
  local f, err = load("return " .. s, "=data", "t", {})
  if not f then error(err) end
  return f()
end

local serialization = { serialize = serialize, unserialize = unserialize }

-- ---------------------------------------------------------------------------
-- Plan
-- ---------------------------------------------------------------------------

local W, H, L, TILE = 20, 3, 20, 8

local PALETTE = {
  { flags = 0, itemName = "minecraft:dirt", damage = 0, blockName = "minecraft:dirt", meta = 0 },
  { flags = 0, itemName = "minecraft:cobblestone", damage = 0, blockName = "minecraft:cobblestone", meta = 0 },
}

--- Palette index of each cell: a dirt floor, a scatter of cobblestone, air above.
local function planCell(x, y, z)
  if y == 0 then return 2 end
  if y == 1 and (x + 2 * z) % 5 == 0 then return 3 end
  return 0
end

local layers = {}
for y = 0, H - 1 do
  local parts = {}
  for z = 0, L - 1 do
    for x = 0, W - 1 do parts[#parts + 1] = string.char(planCell(x, y, z)) end
  end
  layers[y] = table.concat(parts)
end

local planHandle = {
  name = "sim", palette = PALETTE, cellsPerLayer = W * L,
  header = { width = W, height = H, length = L, planVersion = 1, crcStored = 42 },
}
local mockPlan = setmetatable({
  open = function() return planHandle end,
  verify = function() return true end,
  layer = function(_, y) return layers[y] end,
  close = function() end,
}, { __index = realPlan })

-- ---------------------------------------------------------------------------
-- World
-- ---------------------------------------------------------------------------

local DX = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
local DZ = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }

local function key(x, y, z) return x .. "," .. y .. "," .. z end

local DROPS = {
  ["minecraft:stone"] = "minecraft:cobblestone",
  ["enderchest"] = "enderstorage:enderChest",
}

local function newWorld(tileSize)
  local world = {
    now = 0, blocks = {}, robots = {}, list = {}, violations = {},
    chest = {}, adminLog = {}, manual = 0, hooks = {},
    robotsMet = 0,   -- times a robot found another robot in its way
  }
  world.s = logic.newState({ name = "sim", version = 1, crc = 42, width = W, height = H, length = L },
    tileSize or TILE)
  logic.resetCache()
  world.grid = logic.grid(world.s)

  for x = 0, W - 1 do
    for z = 0, L - 1 do
      for y = 0, H - 1 do world.blocks[key(x, y, z)] = "minecraft:stone" end
    end
  end
  -- Things in the travel layer and the column, which robots must clear.
  world.blocks[key(3, H, 2)] = "minecraft:log"
  world.blocks[key(12, H, 12)] = "minecraft:log"
  world.blocks[key(18, H, 5)] = "minecraft:log"
  world.blocks[key(-1, 2, 0)] = "minecraft:stone"

  local slot = 1
  local function stock(name, stacks)
    for _ = 1, stacks do
      world.chest[slot] = { name = name, size = 64 }
      slot = slot + 1
    end
  end
  stock("minecraft:dirt", 18)
  stock("minecraft:cobblestone", 6)
  stock("minecraft:coal", 3)
  return world
end

local function blockAt(world, x, y, z)
  if y < 0 then return "ground" end
  return world.blocks[key(x, y, z)]
end

local function violation(world, text)
  if #world.violations < 20 then
    world.violations[#world.violations + 1] = string.format("[%.1f] %s", world.now, text)
  end
end

--- Is (x, y, z) inside the box, below the travel layer, and not this robot's tile?
local function checkOwnTile(world, r, x, y, z, what)
  if y < 0 then
    violation(world, string.format("%s %s below the box at %d,%d,%d", r.name, what, x, y, z))
    return
  end
  local id = tiles.tileOf(world.grid, x, z)
  if id == nil or id == tiles.COLUMN or y >= H then return end
  local t = world.s.tiles[id]
  if t.status ~= "claimed" or t.owner ~= r.address then
    violation(world, string.format("%s %s at %d,%d,%d in tile %d (%s, owner %s)",
      r.name, what, x, y, z, id, t.status, tostring(t.owner)))
  end
end

-- ---------------------------------------------------------------------------
-- Radio and the admin
-- ---------------------------------------------------------------------------

local function deliver(world, from, to, port, data)
  if to == "admin" then
    local ok, msg = pcall(unserialize, data)
    if not ok or type(msg) ~= "table" then return end
    local reply, ev = logic.handle(world.s, from, msg, world.now)
    for _, line in ipairs(ev.log) do
      world.adminLog[#world.adminLog + 1] = string.format("[%.1f] %s", world.now, line)
    end
    world.manual = world.manual + #ev.manual
    if reply then
      local r = world.byAddress[from]
      if r then
        r.inbox[#r.inbox + 1] = { at = world.now + 0.05, from = "admin", port = port,
                                  data = serialize(reply) }
      end
    end
  else
    local r = world.byAddress[to]
    if r then
      r.inbox[#r.inbox + 1] = { at = world.now + 0.05, from = from, port = port, data = data }
    end
  end
end

-- ---------------------------------------------------------------------------
-- A robot: the OpenComputers APIs pbuild.lua uses, backed by the world
-- ---------------------------------------------------------------------------

local function addItem(r, name, count)
  for slot = 1, 32 do
    local st = r.inv[slot]
    if st and st.name == name and st.size < 64 then
      local n = math.min(64 - st.size, count)
      st.size, count = st.size + n, count - n
      if count == 0 then return end
    end
  end
  for slot = 1, 32 do
    if not r.inv[slot] then
      local n = math.min(64, count)
      r.inv[slot] = { name = name, size = n }
      count = count - n
      if count == 0 then return end
    end
  end
end

local function newRobot(world, name)
  local r = {
    name = name, address = "addr-" .. name, pos = { x = -1, y = 0, z = 0 }, facing = 0,
    inv = {}, selected = 1, inbox = {}, logs = {}, fs = {}, wake = world.now,
    alive = true, moves = 0,
  }
  addItem(r, "enderstorage:enderChest", 1)
  addItem(r, "minecraft:coal", 16)

  local function sleep(dt)
    r.wake = world.now + math.max(dt, 0.001)
    coroutine.yield()
  end

  local function cellFor(side)   -- sides: 0 down, 1 up, 3 front
    local p = r.pos
    if side == 3 then return p.x + DX[r.facing], p.y, p.z + DZ[r.facing] end
    if side == 1 then return p.x, p.y + 1, p.z end
    return p.x, p.y - 1, p.z
  end

  local function occupied(x, y, z)
    return world.robots[key(x, y, z)] ~= nil or blockAt(world, x, y, z) ~= nil
  end

  local function detect(side)
    sleep(0.05)
    return occupied(cellFor(side))
  end

  local function swing(side)
    local x, y, z = cellFor(side)
    local other = world.robots[key(x, y, z)]
    if other then
      violation(world, string.format("%s broke robot %s at %d,%d,%d", r.name, other.name, x, y, z))
      sleep(0.4)
      return true, "block"
    end
    local b = blockAt(world, x, y, z)
    if not b then sleep(0.05) return false, "air" end
    if b == "ground" then
      checkOwnTile(world, r, x, y, z, "tried to dig")
      sleep(0.05)
      return false, "block"
    end
    checkOwnTile(world, r, x, y, z, "dug")
    world.blocks[key(x, y, z)] = nil
    addItem(r, DROPS[b] or b, 1)
    sleep(0.4)
    return true, "block"
  end

  local function move(side)
    local x, y, z = cellFor(side)
    if occupied(x, y, z) then sleep(0.4) return nil, "solid" end
    world.robots[key(r.pos.x, r.pos.y, r.pos.z)] = nil
    r.pos = { x = x, y = y, z = z }
    world.robots[key(x, y, z)] = r
    r.moves = r.moves + 1
    sleep(0.4)
    return true
  end

  local robotApi = {
    inventorySize = function() return 32 end,
    select = function(slot) r.selected = slot return slot end,
    count = function(slot) local st = r.inv[slot or r.selected] return st and st.size or 0 end,
    space = function(slot) local st = r.inv[slot or r.selected] return st and (64 - st.size) or 64 end,
    detect = function() return detect(3) end,
    detectUp = function() return detect(1) end,
    detectDown = function() return detect(0) end,
    swing = function() return swing(3) end,
    swingUp = function() return swing(1) end,
    swingDown = function() return swing(0) end,
    forward = function() return move(3) end,
    up = function() return move(1) end,
    down = function() return move(0) end,
    turnRight = function() r.facing = (r.facing + 1) % 4 sleep(0.4) return true end,
    turnLeft = function() r.facing = (r.facing + 3) % 4 sleep(0.4) return true end,
    turnAround = function() r.facing = (r.facing + 2) % 4 sleep(0.8) return true end,
    drop = function() r.inv[r.selected] = nil sleep(0.05) return true end,
    durability = function() return nil, "tool cannot be damaged" end,
    compareDown = function()
      sleep(0.05)
      local st = r.inv[r.selected]
      return st ~= nil and blockAt(world, cellFor(0)) == st.name
    end,
    placeDown = function()
      local st = r.inv[r.selected]
      local x, y, z = cellFor(0)
      if not st or occupied(x, y, z) then sleep(0.05) return false end
      local placed = st.name
      if st.name == "enderstorage:enderChest" then
        placed = "enderchest"
        checkOwnTile(world, r, x, y, z, "placed the chest")
      else
        checkOwnTile(world, r, x, y, z, "placed " .. st.name)
      end
      world.blocks[key(x, y, z)] = placed
      st.size = st.size - 1
      if st.size == 0 then r.inv[r.selected] = nil end
      sleep(0.4)
      return true
    end,
  }

  local ic = {
    getStackInInternalSlot = function(slot)
      local st = r.inv[slot]
      if st then return { name = st.name, damage = 0, size = st.size } end
      return nil
    end,
    getInventorySize = function(side)
      sleep(0.05)
      local x, y, z = cellFor(side)
      if world.robots[key(x, y, z)] then
        world.robotsMet = world.robotsMet + 1
        return 27
      end
      if blockAt(world, x, y, z) == "enderchest" then return 27 end
      return nil, "no inventory"
    end,
    getStackInSlot = function(side, slot)
      if blockAt(world, cellFor(side)) ~= "enderchest" then return nil end
      local st = world.chest[slot]
      if st then return { name = st.name, damage = 0, size = st.size } end
      return nil
    end,
    suckFromSlot = function(side, slot, count)
      sleep(0.05)
      if blockAt(world, cellFor(side)) ~= "enderchest" then return false end
      local st = world.chest[slot]
      if not st then return false end
      local n = math.min(count or 64, st.size)
      local sel = r.inv[r.selected]
      if sel and sel.name ~= st.name then return false end
      if sel then n = math.min(n, 64 - sel.size) sel.size = sel.size + n
      else r.inv[r.selected] = { name = st.name, size = n } end
      st.size = st.size - n
      if st.size == 0 then world.chest[slot] = nil end
      return n > 0
    end,
  }

  local modem = {
    open = function() return true end,
    close = function() return true end,
    isWireless = function() return true end,
    setStrength = function() return 400 end,
    send = function(to, port, data) deliver(world, r.address, to, port, data) return true end,
    broadcast = function(port, data)
      deliver(world, r.address, "admin", port, data)
      for _, other in ipairs(world.list) do
        if other ~= r then deliver(world, r.address, other.address, port, data) end
      end
      return true
    end,
  }

  local generator = { count = function() return 1 end, insert = function() return true end }

  local component = {
    isAvailable = function(kind)
      return kind == "inventory_controller" or kind == "modem" or kind == "angel"
    end,
    getPrimary = function(kind)
      if kind == "inventory_controller" then return ic end
      if kind == "modem" then return modem end
      return nil
    end,
    list = function(kind)
      local given = kind ~= "generator"
      return function()
        if given then return nil end
        given = true
        return "gen-1", "generator"
      end
    end,
    proxy = function() return generator end,
  }

  local computer = {
    uptime = function() return world.now end,
    energy = function() return 100000 end,
    maxEnergy = function() return 100000 end,
    shutdown = function() error("shutdown", 0) end,
  }

  local event = {
    pull = function(timeout, _)
      local deadline = world.now + (timeout or math.huge)
      while true do
        for idx, m in ipairs(r.inbox) do
          if m.at <= world.now then
            table.remove(r.inbox, idx)
            return "modem_message", r.address, m.from, m.port, 1, m.data
          end
        end
        if world.now >= deadline then return nil end
        sleep(math.min(0.05, deadline - world.now))
      end
    end,
  }

  local filesystem = {
    remove = function(path) r.fs[path] = nil return true end,
    rename = function(a, b) r.fs[b] = r.fs[a] r.fs[a] = nil return true end,
  }

  local io = {
    open = function(path, mode)
      mode = mode or "r"
      if mode:sub(1, 1) == "r" then
        local content = r.fs[path]
        if not content then return nil, "no such file" end
        return { read = function() return content end, close = function() end }
      end
      local buffer = { mode:sub(1, 1) == "a" and (r.fs[path] or "") or "" }
      return {
        write = function(self, ...)
          for _, part in ipairs({ ... }) do buffer[#buffer + 1] = tostring(part) end
          return self
        end,
        close = function() r.fs[path] = table.concat(buffer) end,
      }
    end,
  }

  local modules = {
    component = component, computer = computer, robot = robotApi,
    sides = { bottom = 0, top = 1, back = 2, front = 3, down = 0, up = 1, forward = 3 },
    serialization = serialization, filesystem = filesystem, event = event,
    plan = mockPlan, pbtiles = tiles,
  }

  local env = setmetatable({
    require = function(name) return assert(modules[name], "no module " .. name) end,
    io = io,
    os = { sleep = sleep, date = os.date, exit = function() error("exit", 0) end },
    print = function(...)
      local parts = {}
      for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
      r.logs[#r.logs + 1] = string.format("[%7.1f] %s", world.now, table.concat(parts, " "))
      if #r.logs > 400 then table.remove(r.logs, 1) end
    end,
    loadfile = function() return nil end,
  }, { __index = _G })

  local chunk = assert(load(PBUILD, "=pbuild", "t", env))
  r.co = coroutine.create(function() chunk("/plans/sim.plan") end)
  return r
end

local function placeRobot(world, name)
  local r = newRobot(world, name)
  world.robots[key(-1, 0, 0)] = r
  world.list[#world.list + 1] = r
  world.byAddress[r.address] = r
  return r
end

-- ---------------------------------------------------------------------------
-- Scheduler
-- ---------------------------------------------------------------------------

local function addHook(world, at, fn)
  world.hooks[#world.hooks + 1] = { at = at, fn = fn }
  table.sort(world.hooks, function(a, b) return a.at < b.at end)
end

--- Place a robot on the pad once it is free (at or after `at`).
local function addRobotWhenPadFree(world, at, name)
  local function try()
    if world.robots[key(-1, 0, 0)] then
      addHook(world, world.now + 5, try)
    else
      placeRobot(world, name)
    end
  end
  addHook(world, at, try)
end

local function run(world, limit)
  world.byAddress = world.byAddress or {}
  local lastMissingCheck = 0
  while world.now < limit do
    local nextRobot = nil
    for _, r in ipairs(world.list) do
      if r.alive and coroutine.status(r.co) ~= "dead" then
        if not nextRobot or r.wake < nextRobot.wake then nextRobot = r end
      end
    end
    local nextTime = nextRobot and nextRobot.wake or math.huge
    if world.hooks[1] and world.hooks[1].at <= nextTime then
      local hook = table.remove(world.hooks, 1)
      world.now = math.max(world.now, hook.at)
      hook.fn()
    elseif nextRobot then
      world.now = math.max(world.now, nextRobot.wake)
      local ok, err = coroutine.resume(nextRobot.co)
      if not ok then
        nextRobot.error = tostring(err)
        nextRobot.alive = false
      end
    else
      break   -- nothing left to run
    end
    if world.now - lastMissingCheck >= 1 then
      lastMissingCheck = world.now
      logic.markMissing(world.s, world.now, 300)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Checks
-- ---------------------------------------------------------------------------

local function checkBuilt(world)
  local wrong, first = 0, nil
  for x = 0, W - 1 do
    for z = 0, L - 1 do
      for y = 0, H do
        local want = nil
        if y < H then
          local entry = realPlan.paletteEntry(PALETTE, planCell(x, y, z))
          want = entry and entry.itemName or nil
        end
        local got = world.blocks[key(x, y, z)]
        if got ~= want then
          wrong = wrong + 1
          first = first or string.format("%d,%d,%d is %s, plan says %s", x, y, z, tostring(got), tostring(want))
        end
      end
    end
  end
  return wrong, first
end

local function dumpRobots(world)
  for _, r in ipairs(world.list) do
    print(string.format("    %s at %d,%d,%d, %d moves, %s%s", r.name, r.pos.x, r.pos.y, r.pos.z,
      r.moves, coroutine.status(r.co), r.error and (", error: " .. r.error) or ""))
    for i = math.max(1, #r.logs - 6), #r.logs do print("      " .. r.logs[i]) end
  end
  for i = math.max(1, #world.adminLog - 8), #world.adminLog do print("    admin " .. world.adminLog[i]) end
  for _, v in ipairs(world.violations) do print("    VIOLATION " .. v) end
end

local function report(world, label)
  local wrong, first = checkBuilt(world)
  local ok = world.s.round == "done" and wrong == 0 and #world.violations == 0
  check(label .. ": build finished", world.s.round == "done", "round is " .. world.s.round)
  check(label .. ": every cell matches the plan", wrong == 0, wrong .. " wrong, e.g. " .. tostring(first))
  check(label .. ": no robot broken, nothing dug or placed outside its tile",
    #world.violations == 0, world.violations[1])
  check(label .. ": no manual entries", world.manual == 0, world.manual .. " entries")
  local errors = {}
  for _, r in ipairs(world.list) do
    if r.error then errors[#errors + 1] = r.name .. ": " .. r.error end
  end
  check(label .. ": no robot program errors", #errors == 0, errors[1])
  print(string.format("    simulated %.0f s (%.1f h); robots found another robot in the way %d times",
    world.now, world.now / 3600, world.robotsMet))
  if not ok or #errors > 0 then dumpRobots(world) end
end

-- ---------------------------------------------------------------------------
-- Scenarios
-- ---------------------------------------------------------------------------

print("=== Parallel builder simulation ===")

do
  print("Scenario A: three robots, added one after another")
  local world = newWorld()
  world.byAddress = {}
  addRobotWhenPadFree(world, 0, "r1")
  addRobotWhenPadFree(world, 30, "r2")
  addRobotWhenPadFree(world, 600, "r3")
  run(world, 40000)
  report(world, "A")
end

do
  print("Scenario B: a robot stops mid-tile, is released, another finishes its tile")
  local world = newWorld()
  world.byAddress = {}
  addRobotWhenPadFree(world, 0, "r1")
  addRobotWhenPadFree(world, 30, "r2")
  local stopped
  addHook(world, 700, function()
    stopped = world.byAddress["addr-r2"]
    stopped.alive = false   -- it stops where it is, like a crashed program
  end)
  addHook(world, 1100, function()
    logic.release(world.s, "missing")
  end)
  addRobotWhenPadFree(world, 1150, "r3")
  local blockedSeen = false
  addHook(world, 2500, function()
    -- The player collects the stopped robot (and its chest, if one was placed).
    for _, r in ipairs(world.list) do
      if r.alive and r.logs then
        for _, line in ipairs(r.logs) do
          if line:find("Blocked by a robot") then blockedSeen = true end
        end
      end
    end
    world.robots[key(stopped.pos.x, stopped.pos.y, stopped.pos.z)] = nil
    local below = key(stopped.pos.x, stopped.pos.y - 1, stopped.pos.z)
    if world.blocks[below] == "enderchest" then world.blocks[below] = nil end
  end)
  run(world, 60000)
  report(world, "B")
  check("B: the stopped robot was released while it was missing",
    world.s.robots["addr-r2"] and world.s.robots["addr-r2"].released == true, "not released")
  print("    (another robot reported being blocked by it: " .. tostring(blockedSeen) .. ")")
end

do
  print("Scenario C: six robots on small tiles, so they meet in the travel layer")
  local world = newWorld(4)
  world.byAddress = {}
  for n = 1, 6 do addRobotWhenPadFree(world, (n - 1) * 20, "r" .. n) end
  run(world, 40000)
  report(world, "C")
  check("C: robots met each other and got past", world.robotsMet > 0, "they never met")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
