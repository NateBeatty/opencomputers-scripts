-- lpwatch.lua — Watch the stock of a Logistics Pipes network and show which
-- items dropped the most over the last 24 hours.
--
-- Usage: lpwatch [--reset]
--
-- Every 5 minutes the program reads every item the network can provide
-- (Request Pipe getAvailableItems) and saves what changed since the last
-- snapshot. The screen shows the biggest drops between the oldest snapshot
-- in the window (24 hours, or since the program started if that is shorter)
-- and the newest one. The same report is written to /home/lpwatch/report.txt.
-- Press q to quit. History survives restarts; --reset starts it again from
-- the next snapshot.
--
-- Needs: a computer touching a Logistics Request Pipe, or connected to one by
-- OC cable. If the LP network has a Security Station, turn on computer access
-- in it, or every call fails with a permission error.
--
-- Storage: the counts at the start of the window are kept in base.a/base.b
-- (written in turn, the newer complete one wins), and each snapshot's changes
-- in a ring of slot files. Files are only ever overwritten, never created
-- and deleted while running, so world backups do not trip over them.

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local term = require("term")
local unicode = require("unicode")

local args = {...}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local config = {
  interval = 300,         -- seconds between snapshots
  window = 24 * 3600,     -- seconds the report looks back
  dataDir = "/home/lpwatch",
  pipeAddress = nil,      -- request pipe component address (prefix ok); nil = find one
  reportFileLines = 100,  -- drops listed in report.txt
  yieldEvery = 200,       -- items read between yields (OC kills programs that
                          -- run 5 s without yielding)
}

do -- optional /etc/lpwatch.cfg overrides
  local f = loadfile("/etc/lpwatch.cfg")
  if f then
    local ok, user = pcall(f)
    if ok and type(user) == "table" then
      for k, v in pairs(user) do config[k] = v end
    end
  end
end

-- One hour of spare slots, so the ring never has to fold a snapshot that is
-- still inside the window.
local ringSize = math.ceil(config.window / config.interval) + math.ceil(3600 / config.interval)

local function path(name) return config.dataDir .. "/" .. name end
local baseFiles = { path("base.a"), path("base.b") }
local reportFile = path("report.txt")

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- base: counts at the start of the window, as of snapshot `seq` taken at `time`.
local base = { stamp = 0, seq = 0, time = 0, counts = {} }
local current = {}     -- counts at the newest snapshot
local currentTime = nil
local nextSeq = 1
local ring = {}        -- unfolded slots, oldest first: { seq, time, file }
local names = {}       -- key -> display name

-- ---------------------------------------------------------------------------
-- Clock: OC has no wall clock, but files in /tmp get real modification times.
-- ---------------------------------------------------------------------------

local function now()
  local f = assert(io.open("/tmp/.lpwatch-clock", "w"))
  f:write("t")
  f:close()
  return math.floor(filesystem.lastModified("/tmp/.lpwatch-clock") / 1000)
end

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

--- Write `header`, then "key\tcount" for each key of `keys` (count from
--- `counts`, 0 when absent), then "end". Line by line: one big string can
--- fail to allocate on a full computer.
local function writeCounts(file, header, keys, counts)
  local f = assert(io.open(file, "w"))
  f:write(header, "\n")
  for _, k in ipairs(keys) do
    f:write(k, "\t", tostring(counts[k] or 0), "\n")
  end
  f:write("end\n")
  f:close()
end

--- Read a file written by writeCounts. Returns the header fields and a
--- key -> count table, or nil if the file is missing or was cut short.
local function readCounts(file, wantCounts)
  local f = io.open(file, "r")
  if not f then return nil end
  local header, counts, complete = nil, {}, false
  for line in f:lines() do
    if not header then
      header = line
      if not wantCounts then break end
    elseif line == "end" then
      complete = true
      break
    else
      local k, v = line:match("^(.-)\t(%d+)$")
      if k then counts[k] = tonumber(v) end
    end
  end
  f:close()
  if not header or (wantCounts and not complete) then return nil end
  local fields = {}
  for w in header:gmatch("%S+") do fields[#fields + 1] = w end
  return fields, counts
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function saveBase()
  base.stamp = base.stamp + 1
  local nonZero = {}
  for k, v in pairs(base.counts) do if v > 0 then nonZero[#nonZero + 1] = k end end
  table.sort(nonZero)
  writeCounts(baseFiles[base.stamp % 2 + 1],
    string.format("lpwatch-base %d %d %d", base.stamp, base.seq, base.time),
    nonZero, base.counts)
end

local function loadBase()
  local best
  for _, file in ipairs(baseFiles) do
    local fields, counts = readCounts(file, true)
    if fields and fields[1] == "lpwatch-base" then
      local b = { stamp = tonumber(fields[2]), seq = tonumber(fields[3]),
                  time = tonumber(fields[4]), counts = counts }
      if not best or b.stamp > best.stamp then best = b end
    end
  end
  return best
end

local function applyCounts(target, changes)
  for k, v in pairs(changes) do
    if v > 0 then target[k] = v else target[k] = nil end
  end
end

local function loadNames()
  local f = io.open(path("names"), "r")
  if not f then return end
  for line in f:lines() do
    local k, name = line:match("^(.-)\t(.*)$")
    if k then names[k] = name end
  end
  f:close()
end

local function saveNewNames(newNames)
  if next(newNames) == nil then return end
  local f = assert(io.open(path("names"), "a"))
  for _, k in ipairs(sortedKeys(newNames)) do
    f:write(k, "\t", (newNames[k]:gsub("[\t\n\r]", " ")), "\n")
    names[k] = newNames[k]
  end
  f:close()
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

--- Move the oldest `n` ring slots into base and save it.
local function fold(n)
  if n <= 0 then return end
  for _ = 1, n do
    local slot = table.remove(ring, 1)
    local _, changes = readCounts(slot.file, true)
    -- A slot that was cut short is skipped; the next snapshot after a
    -- restart re-lists every item that differs, so the error stays small.
    if changes then applyCounts(base.counts, changes) end
    base.seq, base.time = slot.seq, slot.time
  end
  saveBase()
end

--- Fold every slot that is at least `config.window` older than `t`, keeping
--- base at the newest snapshot that is still a full window old.
local function foldOld(t)
  local n = 0
  while ring[n + 1] and ring[n + 1].time <= t - config.window do n = n + 1 end
  fold(n)
end

local function loadHistory()
  filesystem.makeDirectory(config.dataDir)
  loadNames()
  local b = loadBase()
  if not b then return false end
  base = b
  local slots = {}
  for name in filesystem.list(config.dataDir) do
    if name:match("^slot%d+$") then
      local fields = readCounts(path(name), false)
      if fields and fields[1] == "lpwatch-slot" then
        slots[#slots + 1] = { seq = tonumber(fields[2]), time = tonumber(fields[3]), file = path(name) }
      end
    end
  end
  table.sort(slots, function(a, b) return a.seq < b.seq end)
  for k, v in pairs(base.counts) do current[k] = v end
  currentTime = base.time
  nextSeq = base.seq + 1
  for _, slot in ipairs(slots) do
    if slot.seq > base.seq then
      local _, changes = readCounts(slot.file, true)
      if changes then
        applyCounts(current, changes)
        ring[#ring + 1] = slot
        currentTime = slot.time
      end
      nextSeq = slot.seq + 1
    end
  end
  return true
end

--- Record a snapshot taken at time `t`.
local function record(snap, t)
  local file = path("slot" .. (nextSeq % ringSize))
  -- The file about to be overwritten may still hold an unfolded slot.
  for i, slot in ipairs(ring) do
    if slot.file == file then fold(i) break end
  end
  local changed = {}
  for k, v in pairs(snap) do
    if current[k] ~= v then changed[#changed + 1] = k end
  end
  for k in pairs(current) do
    if snap[k] == nil then changed[#changed + 1] = k end
  end
  table.sort(changed)
  writeCounts(file, string.format("lpwatch-slot %d %d", nextSeq, t), changed, snap)
  ring[#ring + 1] = { seq = nextSeq, time = t, file = file }
  nextSeq = nextSeq + 1
  current, currentTime = snap, t
end

--- Start the window afresh at snapshot `snap` taken at `t`.
local function reset(snap, t)
  ring = {}
  base.counts, base.seq, base.time = {}, nextSeq - 1, t
  for k, v in pairs(snap) do base.counts[k] = v end
  saveBase()
  current, currentTime = snap, t
end

-- ---------------------------------------------------------------------------
-- Logistics Pipes
-- ---------------------------------------------------------------------------

local function findPipe()
  local addresses = {}
  if config.pipeAddress then
    addresses[1] = assert(component.get(config.pipeAddress), "no component " .. config.pipeAddress)
  else
    for address in component.list("logisticspipe") do addresses[#addresses + 1] = address end
  end
  for _, address in ipairs(addresses) do
    local ok, pipe = pcall(component.invoke, address, "getPipe")
    if ok and pipe and pipe.getAvailableItems then return pipe end
  end
  error("no Logistics Request Pipe found (the computer, or an OC cable from it, must touch one)", 0)
end

--- Read the network's stock: key -> count, plus display names not seen before.
local function snapshot()
  local items = findPipe().getAvailableItems()
  local snap, newNames, n = {}, {}, 0
  for _, pair in pairs(items) do
    local id, count = pair.getValue1(), pair.getValue2()
    if id and count and count > 0 then
      -- Items that differ only by NBT are added together.
      local key = (id.getIdName() or ("id" .. id.getId())) .. "@" .. id.getData()
      snap[key] = (snap[key] or 0) + math.floor(count)
      if not names[key] and not newNames[key] then newNames[key] = id.getName() or key end
    end
    n = n + 1
    if n % config.yieldEvery == 0 then os.sleep(0) end
  end
  return snap, newNames
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------

local function commas(n)
  local s = tostring(math.floor(math.abs(n)))
  s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (n < 0 and "-" or "") .. s
end

local function duration(seconds)
  seconds = math.max(0, math.floor(seconds))
  local h, m = seconds // 3600, seconds % 3600 // 60
  if h > 0 then return string.format("%dh %02dm", h, m) end
  return string.format("%dm", m)
end

local function fit(s, width)
  if unicode.wlen(s) <= width then return s end
  return unicode.sub(s, 1, width - 3) .. "..."
end

--- The report as a list of lines `width` wide with at most `maxDrops` drops.
local function report(width, maxDrops)
  local span = (currentTime or base.time) - base.time
  local hours = math.max(span, config.interval) / 3600
  local drops = {}
  for k, was in pairs(base.counts) do
    local change = (current[k] or 0) - was
    if change < 0 then drops[#drops + 1] = { key = k, now = current[k] or 0, change = change } end
  end
  table.sort(drops, function(a, b)
    if a.change ~= b.change then return a.change < b.change end
    return a.key < b.key
  end)

  local types = 0
  for _ in pairs(current) do types = types + 1 end
  local lines = {
    fit(string.format("Biggest drops over %s (%d item types, %d dropped)",
      span > 0 and duration(span) or "no time yet", types, #drops), width),
    fit(string.format("%12s %10s %13s  %s", "Change", "Per hour", "Now", "Item"), width),
  }
  for i = 1, math.min(#drops, maxDrops) do
    local d = drops[i]
    local name = (names[d.key] or d.key):gsub("\194\167.", "")  -- drop § colour codes
    if d.now == 0 then name = name .. " (gone)" end
    lines[#lines + 1] = fit(string.format("%12s %10s %13s  %s",
      commas(d.change), commas(d.change / hours), commas(d.now), name), width)
  end
  if #drops == 0 then
    lines[#lines + 1] = span > 0 and "Nothing has dropped." or "Waiting for the second snapshot."
  end
  return lines
end

local function writeReport()
  local f = io.open(reportFile, "w")
  if not f then return end
  for _, line in ipairs(report(200, config.reportFileLines)) do f:write(line, "\n") end
  f:close()
end

local function draw(status)
  local width, height = 80, 25
  if component.isAvailable("gpu") then width, height = component.gpu.getResolution() end
  term.clear()
  -- Title, status, column headings, then the drops. The bottom row stays
  -- empty: drawing on it came out garbled in game.
  local lines = report(width - 1, height - 4)
  table.insert(lines, 2, fit(status, width - 1))
  for _, line in ipairs(lines) do term.write(line .. "\n") end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

local resetRequested = false
for _, a in ipairs(args) do
  if a == "--reset" then resetRequested = true
  else
    print("Usage: lpwatch [--reset]")
    return
  end
end

local haveHistory = loadHistory()
local status

local function step()
  local ok, snap, newNames = pcall(snapshot)
  if not ok then
    if tostring(snap):find("ermission") then
      status = "LP denied access: turn on computer access in the Security Station."
    else
      status = "Read failed: " .. tostring(snap)
    end
    return
  end
  local t = now()
  saveNewNames(newNames)
  if not haveHistory or resetRequested then
    reset(snap, t)
    haveHistory, resetRequested = true, false
  else
    record(snap, t)
    foldOld(t)
  end
  writeReport()
  status = string.format("Updated %s (server time), next in %s. q quits.", os.date("%H:%M", t), duration(config.interval))
end

while true do
  step()
  draw(status)
  local wakeAt = computer.uptime() + config.interval
  repeat
    local ev, _, char = event.pull(math.max(0, wakeAt - computer.uptime()), "key_down")
    if ev == "key_down" and (char == string.byte("q") or char == string.byte("Q")) then
      term.clear()
      return
    end
  until computer.uptime() >= wakeAt
end
