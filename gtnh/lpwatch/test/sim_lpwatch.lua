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

-- The simulated items: name -> { item ID, data, display name from LP }.
ITEMS = {
  iron = { 5, 0, "Iron" },
  copper = { 5, 1, "Copper" },
  gold = { 300, 7, "Gold" },
  tin = { 12, 0, "Tin" },
  odd = { 4000, -1, "item.oddThing.name" },  -- untranslated on the server
}
for i = 1, 10 do ITEMS["bulk" .. i] = { 900, i, "Bulk " .. i } end

--- A fresh world: in-memory files and a clock (seconds of real time).
local function newWorld()
  return { files = {}, time = 1700000000, screen = "" }
end

--- Run lpwatch once in `world` for `cycles` snapshots, then press q.
--- `stockAt(n)` returns { [name] = count } for the n-th snapshot of this run
--- (1-based), or the string "error" to make the listing fail.
local function run(world, cycles, stockAt, opts)
  opts = opts or {}
  local files = world.files
  local snapshots = 0

  -- PipeItemsRequestLogistics.getAvailableItemsPage: a listing sorted by
  -- (id, data), taken when afterId < 0 and paged from after the cursor.
  local listing = {}
  local function key(id, data) return id * 4294967296.0 + data % 4294967296.0 end
  local pipe = {
    getAvailableItemsPage = function(afterId, afterData, count)
      world.pageCalls = (world.pageCalls or 0) + 1
      if afterId < 0 then
        snapshots = snapshots + 1
        local stock = stockAt(snapshots)
        if stock == "error" then error("logisticspipes.security.PermissionException", 0) end
        listing = {}
        for name, n in pairs(stock) do
          local item = assert(ITEMS[name], "unknown item " .. name)
          listing[#listing + 1] = { id = item[1], data = item[2], count = n }
        end
        table.sort(listing, function(a, b) return key(a.id, a.data) < key(b.id, b.data) end)
      end
      local lines = {}
      for _, e in ipairs(listing) do
        if #lines >= count then break end
        if afterId < 0 or key(e.id, e.data) > key(afterId, afterData) then
          lines[#lines + 1] = string.format("%d %d %d\n", e.id, e.data, e.count)
        end
      end
      return table.concat(lines)
    end,
    getLP = function()
      return { getItemIdentifierBuilder = function()
        local b = {}
        return {
          setItemID = function(id) assert(math.type(id) == "integer") b.id = id end,
          setItemData = function(data) assert(math.type(data) == "integer") b.data = data end,
          build = function()
            for name, item in pairs(ITEMS) do
              if item[1] == b.id and item[2] == b.data then
                return {
                  getName = function() return item[3] end,
                  getIdName = function() return "mod:" .. name end,
                }
              end
            end
            error("Not a valid ItemIdentifier")
          end,
        }
      end }
    end,
  }
  if opts.oldLP then pipe = { getAvailableItems = function() return {} end } end

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

test("drops and gains are ranked, gone and new items marked", function()
  local stocks = {
    { iron = 1000, copper = 50, gold = 10, tin = 500 },
    { iron = 400, gold = 20, tin = 450, odd = 300 },
  }
  local w = run(newWorld(), 2, function(n) return stocks[n] end)
  local r = report(w)
  assert_has(r, "Changes over 5m: 4 item types, 3 dropped, 2 gained")
  local gainsAt = r:find("Biggest gains", 1, true)
  assert(gainsAt, r)
  local iron = r:find("Iron", 1, true)
  local copper = r:find("Copper (gone)", 1, true)
  local tin = r:find("Tin", 1, true)
  assert(iron and copper and tin, r)
  assert(iron < copper and copper < tin and tin < gainsAt, "drop order: " .. r)
  assert_has(r, "-600")
  -- Gains: the new item (+300) before gold (+10), both after the heading.
  local odd = r:find("mod:odd@-1 (new)", 1, true)
  local gold = r:find("Gold", 1, true)
  assert(odd and gold and gainsAt < odd and odd < gold, "gain order: " .. r)
  assert_has(r, "+300")
  assert_has(r, "+10")
  -- On screen the two lists sit side by side on the same rows.
  local row
  for line in w.screen:gmatch("[^\n]+") do
    if line:find("Iron", 1, true) then row = line end
  end
  assert(row and row:find(" | ", 1, true) and row:find("mod:odd", 1, true), "screen row: " .. tostring(row))
end)

test("report covers only the last 24 hours", function()
  -- 300 snapshots 5 minutes apart (about 25 hours); iron drops 10 each time.
  local w = run(newWorld(), 300, function(n) return { iron = 10000 - 10 * n } end)
  local r = report(w)
  -- The window starts at the newest snapshot a full 24 h old: 288 steps back.
  assert_has(r, "Changes over 24h 00m")
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
  assert_has(r, "Changes over 50m")
  assert(not r:find("Copper", 1, true), r)
end)

test("ring wraps without growing the file count", function()
  local cfg = { window = 1200, interval = 300 }  -- 4 + 12 = 16 slots
  local w = run(newWorld(), 60, function(n) return { iron = 10000 - n } end, { config = cfg })
  local r = report(w)
  assert_has(r, "Changes over 20m")
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
  assert_has(r, "Changes over 5m")
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

test("stock is read across several pages", function()
  local function stock(n)
    local s = {}
    for i = 1, 10 do s["bulk" .. i] = 1000 - (n - 1) * i end
    return s
  end
  local w = run(newWorld(), 2, stock, { config = { pageSize = 3 } })
  local r = report(w)
  assert_has(r, "10 item types, 10 dropped, 0 gained")
  assert_has(r, "Bulk 10")
  assert(r:find("Bulk 10", 1, true) < r:find("Bulk 9", 1, true), "order: " .. r)
  -- 10 items in pages of 3: 4 calls per snapshot, the last one short.
  assert_eq(w.pageCalls, 8, "page calls")
end)

test("untranslated names fall back to the registry name", function()
  local stocks = { { odd = 10, iron = 5 }, { odd = 4, iron = 5 } }
  local w = run(newWorld(), 2, function(n) return stocks[n] end)
  assert_has(report(w), "mod:odd@-1")
  -- Names are saved, keyed by the numeric item key.
  assert_has(w.files["/home/lpwatch/names"], "\tmod:odd@-1\n")
end)

test("an LP build without getAvailableItemsPage says so", function()
  local w = run(newWorld(), 0, function() return {} end, { oldLP = true })
  assert_has(w.screen, "no getAvailableItemsPage")
end)

print(string.format("%d passed, %d failed", passed, failed))
