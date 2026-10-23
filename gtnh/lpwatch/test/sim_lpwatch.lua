-- sim_lpwatch.lua — Runs the real lpwatch.lua against a simulated LP network.
-- Run from converter/: node test/run_lua_tests.js ../gtnh/lpwatch/test/sim_lpwatch.lua

local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/")
local programPath = here .. "/../lpwatch.lua"

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

local function assert_has(s, pattern, msg)
  if not s:find(pattern, 1, true) then
    error(string.format("%s: %q not found in:\n%s", msg or "assert_has", pattern, s), 2)
  end
end

-- ---------------------------------------------------------------------------
-- Simulation
-- ---------------------------------------------------------------------------

--- A fresh world: in-memory files and a clock (seconds of real time).
local function newWorld()
  return { files = {}, time = 1700000000, screen = "" }
end

--- Run lpwatch once in `world` for `cycles` snapshots, then press q.
--- `stockAt(n)` returns { [name] = count } for the n-th snapshot of this run
--- (1-based), or the string "error" to make getAvailableItems fail.
local function run(world, cycles, stockAt, opts)
  opts = opts or {}
  local files = world.files
  local snapshots = 0

  local function makePair(name, count)
    local id = {
      getIdName = function() return "mod:" .. name end,
      getId = function() return 1 end,
      getData = function() return 0 end,
      getName = function() return name:gsub("^%l", string.upper) end,
    }
    return { getValue1 = function() return id end, getValue2 = function() return count end }
  end

  local pipe = {
    getAvailableItems = function()
      snapshots = snapshots + 1
      local stock = stockAt(snapshots)
      if stock == "error" then error("logisticspipes.security.PermissionException", 0) end
      local list, names = {}, {}
      for name in pairs(stock) do names[#names + 1] = name end
      table.sort(names)
      for i, name in ipairs(names) do list[i] = makePair(name, stock[name]) end
      return list
    end,
  }

  package.loaded.component = {
    list = function(kind)
      local done = kind ~= "logisticspipe"
      return function()
        if done then return nil end
        done = true
        return "lp-1"
      end
    end,
    invoke = function(address, method)
      assert(address == "lp-1" and method == "getPipe")
      return pipe
    end,
    get = function(a) return a end,
    isAvailable = function() return false end,
  }
  local startTime = world.time
  package.loaded.computer = { uptime = function() return world.time - startTime end }
  package.loaded.event = {
    pull = function(timeout)
      world.time = world.time + timeout
      if snapshots >= cycles then return "key_down", "kb", string.byte("q") end
      return nil
    end,
  }
  package.loaded.filesystem = {
    makeDirectory = function() return true end,
    lastModified = function(p)
      assert(p == "/tmp/.lpwatch-clock")
      return world.time * 1000
    end,
    list = function(dir)
      local names = {}
      for p in pairs(files) do
        local name = p:match("^" .. dir:gsub("%-", "%%-") .. "/([^/]+)$")
        if name then names[#names + 1] = name end
      end
      table.sort(names)
      local i = 0
      return function() i = i + 1 return names[i] end
    end,
  }
  package.loaded.term = {
    clear = function() end,  -- keep everything drawn; q clears on exit
    write = function(s) world.screen = world.screen .. s end,
    setCursor = function() end,
  }
  package.loaded.unicode = {
    wlen = function(s) return utf8.len(s) or #s end,
    sub = function(s, i, j) return s:sub(i, j) end,
  }

  local realIo, realOs, realLoadfile = io, os, loadfile
  io = { open = function(p, mode)
    if mode == "w" or mode == "a" then
      if mode == "w" or files[p] == nil then files[p] = "" end
      return {
        write = function(_, ...)
          for _, s in ipairs({...}) do files[p] = files[p] .. s end
        end,
        close = function() end,
      }
    end
    if files[p] == nil then return nil end
    local content = files[p]
    return {
      lines = function() return content:gmatch("([^\n]*)\n") end,
      close = function() end,
    }
  end }
  os = setmetatable({ sleep = function() end, date = function() return "12:00" end },
    { __index = realOs })
  local chunk = assert(realLoadfile(programPath))
  loadfile = function(p)
    if p == "/etc/lpwatch.cfg" and opts.config then
      return function() return opts.config end
    end
    return nil
  end
  local ok, err = pcall(chunk, table.unpack(opts.argv or {}))
  io, os, loadfile = realIo, realOs, realLoadfile
  if not ok then error(err, 0) end
  return world
end

local function report(world) return world.files["/home/lpwatch/report.txt"] or "" end

local function countFiles(world)
  local n = 0
  for _ in pairs(world.files) do n = n + 1 end
  return n
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

print("sim_lpwatch")

test("first snapshot waits for a second one", function()
  local w = run(newWorld(), 1, function() return { iron = 100 } end)
  assert_has(report(w), "Waiting for the second snapshot")
end)

test("drops are ranked, gone items marked, rises ignored", function()
  local stocks = {
    { iron = 1000, copper = 50, gold = 10, tin = 500 },
    { iron = 400, gold = 20, tin = 450 },
  }
  local w = run(newWorld(), 2, function(n) return stocks[n] end)
  local r = report(w)
  assert_has(r, "Biggest drops over 5m (3 item types, 3 dropped)")
  local iron = r:find("Iron", 1, true)
  local copper = r:find("Copper (gone)", 1, true)
  local tin = r:find("Tin", 1, true)
  assert(iron and copper and tin, r)
  assert(iron < copper and copper < tin, "order: " .. r)
  assert_has(r, "-600")
  assert(not r:find("Gold", 1, true), "rise listed: " .. r)
  assert_has(w.screen, "Iron")
end)

test("report covers only the last 24 hours", function()
  -- 300 snapshots 5 minutes apart (about 25 hours); iron drops 10 each time.
  local w = run(newWorld(), 300, function(n) return { iron = 10000 - 10 * n } end)
  local r = report(w)
  -- The window starts at the newest snapshot a full 24 h old: 288 steps back.
  assert_has(r, "Biggest drops over 24h 00m")
  assert_has(r, "-2,880")
  assert_has(r, "-120")  -- per hour
end)

test("history survives a restart", function()
  local w = newWorld()
  run(w, 10, function(n) return { iron = 1000 - 10 * n, copper = 5 } end)
  run(w, 1, function() return { iron = 500, copper = 5 } end)
  local r = report(w)
  -- From the first snapshot (990) to the restarted program's first one (500):
  -- the first run took 10 snapshots and waited one interval after the last.
  assert_has(r, "-490")
  assert_has(r, "Biggest drops over 50m")
  assert(not r:find("Copper", 1, true), r)
end)

test("ring wraps without growing the file count", function()
  local cfg = { window = 1200, interval = 300 }  -- 4 + 12 = 16 slots
  local w = run(newWorld(), 60, function(n) return { iron = 10000 - n } end, { config = cfg })
  local r = report(w)
  assert_has(r, "Biggest drops over 20m")
  assert_has(r, "-4 ")
  -- 16 slots, base.a, base.b, names, report.txt, /tmp/.lpwatch-clock
  assert(countFiles(w) <= 21, "files: " .. countFiles(w))
  -- A restart after the wrap reconstructs the state. Its snapshot comes one
  -- interval after the last with no change, so the 20 minutes back now
  -- reach snapshot 57 (9,943): a drop of 3.
  run(w, 1, function() return { iron = 10000 - 60 } end, { config = cfg })
  assert_has(report(w), "-3 ")
end)

test("--reset starts the window again", function()
  local w = newWorld()
  run(w, 5, function(n) return { iron = 1000 - 100 * n } end)
  run(w, 2, function(n) return { iron = 400 - n } end, { argv = { "--reset" } })
  local r = report(w)
  assert_has(r, "Biggest drops over 5m")
  assert_has(r, "-1 ")
  -- The reset survives a restart too.
  run(w, 1, function() return { iron = 390 } end)
  assert_has(report(w), "-9 ")
end)

test("a torn slot file is skipped, not fatal", function()
  local w = newWorld()
  run(w, 3, function(n) return { iron = 1000 - 100 * n } end)
  -- Cut the newest slot short (no "end" line).
  local newest = w.files["/home/lpwatch/slot2"]
  w.files["/home/lpwatch/slot2"] = newest:gsub("end\n$", "")
  run(w, 1, function() return { iron = 650 } end)
  assert_has(report(w), "-250")
end)

test("read errors are shown and retried", function()
  local w = run(newWorld(), 3, function(n)
    if n == 2 then return "error" end
    return { iron = 100 * (4 - n) }
  end)
  assert_has(report(w), "-200")
  -- The error status was drawn at some point; the final screen is the
  -- successful third read.
  assert_has(w.screen, "Iron")
end)

test("permission errors explain the Security Station", function()
  local w = run(newWorld(), 1, function() return "error" end)
  assert_has(w.screen, "Security Station")
end)

print(string.format("%d passed, %d failed", passed, failed))
