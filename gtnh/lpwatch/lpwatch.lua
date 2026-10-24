-- lpwatch.lua — Watch the stock of a Logistics Pipes network and show which
-- items dropped and gained the most over the last 24 hours.
--
-- Usage: lpwatch [--reset]
--
-- Every 5 minutes the program reads every item the network can provide and
-- saves what changed since the last snapshot. The screen shows the biggest
-- drops (left) and gains (right) between the oldest snapshot in the window
-- (24 hours, or since the program started if that is shorter) and the newest
-- one. Items new since then count as gains. The same report is
-- written to /home/lpwatch/report.txt. Press q to quit. History survives
-- restarts; --reset starts it again from the next snapshot.
--
-- Needs: a computer touching a Logistics Request Table or Request Pipe, or
-- connected to one by OC cable, and an LP build with getAvailableItemsPage
-- (the NateBeatty/LogisticsPipes-GTNH fork). If the LP network has a Security
-- Station, turn on computer access in it, or every call fails.
--
-- Memory: LP's getAvailableItems returns one OC object per item type, which
-- fills a computer on a large network. getAvailableItemsPage returns plain
-- "id data count" lines a page at a time instead, and each snapshot is kept as
-- two sorted arrays: keys (item ID << 32 | data) and counts. Display names are
-- looked up only for the items the report shows.
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
  pageSize = 2000,        -- items per getAvailableItemsPage call
  reportFileLines = 100,  -- drops listed in report.txt
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
-- State. A stock list is two arrays sorted by key: keys[i] and counts[i].
-- Lists are never changed in place, so they can be shared.
-- ---------------------------------------------------------------------------

-- base: counts at the start of the window, as of snapshot `seq` taken at `time`.
local base = { stamp = 0, seq = 0, time = 0, keys = {}, counts = {} }
local current = { keys = {}, counts = {} }  -- the newest snapshot
local currentTime = nil
local nextSeq = 1
local ring = {}        -- unfolded slots, oldest first: { seq, time, file }
local names = {}       -- key -> display name, for items the report has shown

-- Keys are id * 2^32 + data (data taken mod 2^32), the same order as LP's
-- listing. They stay below 2^53, so they are exact as floats too and need no
-- 64-bit integers.
local TWO32 = 4294967296.0
local function makeKey(id, data) return id * TWO32 + data % TWO32 end
local function itemId(key) return math.tointeger(math.floor(key / TWO32)) end
local function itemData(key)
  local data = key % TWO32
  if data >= 2147483648 then data = data - TWO32 end
  return math.tointeger(data)
end

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
-- Files: a header line, "key count" lines in key order, then "end".
-- ---------------------------------------------------------------------------

local function writeList(file, header, list)
  local f = assert(io.open(file, "w"))
  f:write(header, "\n")
  local keys, counts = list.keys, list.counts
  for i = 1, #keys do f:write(string.format("%.0f %.0f\n", keys[i], counts[i])) end
  f:write("end\n")
  f:close()
end

--- Read a file written by writeList (or a slot). Returns the header fields
--- and the list, or nil if the file is missing or was cut short.
local function readList(file, wantList)
  local f = io.open(file, "r")
  if not f then return nil end
  local header, keys, counts, n, complete = nil, {}, {}, 0, false
  for line in f:lines() do
    if not header then
      header = line
      if not wantList then break end
    elseif line == "end" then
      complete = true
      break
    else
      local k, v = line:match("^(%d+) (%d+)$")
      if k then
        n = n + 1
        keys[n], counts[n] = tonumber(k), tonumber(v)
      end
    end
  end
  f:close()
  if not header or (wantList and not complete) then return nil end
  local fields = {}
  for w in header:gmatch("%S+") do fields[#fields + 1] = w end
  return fields, { keys = keys, counts = counts }
end

local function saveBase()
  base.stamp = base.stamp + 1
  writeList(baseFiles[base.stamp % 2 + 1],
    string.format("lpwatch-base2 %d %d %d", base.stamp, base.seq, base.time), base)
end

local function loadBase()
  local best
  for _, file in ipairs(baseFiles) do
    local fields, list = readList(file, true)
    if fields and fields[1] == "lpwatch-base2" then
      local b = { stamp = tonumber(fields[2]), seq = tonumber(fields[3]),
                  time = tonumber(fields[4]), keys = list.keys, counts = list.counts }
      if not best or b.stamp > best.stamp then best = b end
    end
  end
  return best
end

local function loadNames()
  local f = io.open(path("names"), "r")
  if not f then return end
  for line in f:lines() do
    local k, name = line:match("^(%d+)\t(.*)$")
    if k then names[tonumber(k)] = name end
  end
  f:close()
end

-- ---------------------------------------------------------------------------
-- Stock lists
-- ---------------------------------------------------------------------------

--- `list` with `changes` applied (a list whose count 0 means "gone").
local function applyChanges(list, changes)
  local k, c, xk, xc = list.keys, list.counts, changes.keys, changes.counts
  local nk, nc, n, i, j = {}, {}, 0, 1, 1
  while k[i] or xk[j] do
    if xk[j] == nil or (k[i] ~= nil and k[i] < xk[j]) then
      n = n + 1
      nk[n], nc[n] = k[i], c[i]
      i = i + 1
    else
      if k[i] == xk[j] then i = i + 1 end
      if xc[j] > 0 then
        n = n + 1
        nk[n], nc[n] = xk[j], xc[j]
      end
      j = j + 1
    end
  end
  return { keys = nk, counts = nc }
end

--- Write the lines that turn `old` into `new` to the open file `f`.
local function writeChanges(f, old, new)
  local ok, oc, nk, nc = old.keys, old.counts, new.keys, new.counts
  local i, j = 1, 1
  while ok[i] or nk[j] do
    if nk[j] == nil or (ok[i] ~= nil and ok[i] < nk[j]) then
      f:write(string.format("%.0f 0\n", ok[i]))
      i = i + 1
    elseif ok[i] == nil or nk[j] < ok[i] then
      f:write(string.format("%.0f %.0f\n", nk[j], nc[j]))
      j = j + 1
    else
      if oc[i] ~= nc[j] then f:write(string.format("%.0f %.0f\n", nk[j], nc[j])) end
      i, j = i + 1, j + 1
    end
  end
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

--- Move the oldest `n` ring slots into base and save it.
local function fold(n)
  if n <= 0 then return end
  for _ = 1, n do
    local slot = table.remove(ring, 1)
    local _, changes = readList(slot.file, true)
    -- A slot that was cut short is skipped; the next snapshot after a
    -- restart re-lists every item that differs, so the error stays small.
    if changes then
      local folded = applyChanges(base, changes)
      base.keys, base.counts = folded.keys, folded.counts
    end
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
      local fields = readList(path(name), false)
      if fields and fields[1] == "lpwatch-slot2" then
        slots[#slots + 1] = { seq = tonumber(fields[2]), time = tonumber(fields[3]), file = path(name) }
      end
    end
  end
  table.sort(slots, function(a, b) return a.seq < b.seq end)
  current, currentTime = { keys = base.keys, counts = base.counts }, base.time
  nextSeq = base.seq + 1
  for _, slot in ipairs(slots) do
    if slot.seq > base.seq then
      local _, changes = readList(slot.file, true)
      if changes then
        current = applyChanges(current, changes)
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
  local f = assert(io.open(file, "w"))
  f:write(string.format("lpwatch-slot2 %d %d\n", nextSeq, t))
  writeChanges(f, current, snap)
  f:write("end\n")
  f:close()
  ring[#ring + 1] = { seq = nextSeq, time = t, file = file }
  nextSeq = nextSeq + 1
  current, currentTime = snap, t
end

--- Start the window afresh at snapshot `snap` taken at `t`.
local function reset(snap, t)
  ring = {}
  base.keys, base.counts, base.seq, base.time = snap.keys, snap.counts, nextSeq - 1, t
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
  local old
  for _, address in ipairs(addresses) do
    local ok, pipe = pcall(component.invoke, address, "getPipe")
    if ok and pipe then
      if pipe.getAvailableItemsPage then return pipe end
      if pipe.getAvailableItems then old = true end
    end
  end
  if old then
    error("this LP build has no getAvailableItemsPage; install the LP fork with it", 0)
  end
  error("no Logistics Request Table or Pipe found (the computer, or an OC cable from it, must touch one)", 0)
end

--- Read the network's stock, a page at a time.
local function snapshot(pipe)
  local keys, counts, n = {}, {}, 0
  local afterId, afterData = -1, 0
  repeat
    local page = pipe.getAvailableItemsPage(afterId, afterData, config.pageSize)
    local lines = 0
    for id, data, count in page:gmatch("(%d+) (%-?%d+) (%d+)\n") do
      lines = lines + 1
      id, data, count = tonumber(id), tonumber(data), tonumber(count)
      afterId, afterData = id, data
      if count > 0 then
        local key = makeKey(id, data)
        if n > 0 and keys[n] == key then
          counts[n] = counts[n] + count
        elseif n == 0 or keys[n] < key then
          n = n + 1
          keys[n], counts[n] = key, count
        end
      end
    end
    page = nil
  until lines < config.pageSize
  return { keys = keys, counts = counts }
end

--- Look up display names for `keys` that have none yet, and save them.
local function resolveNames(pipe, keys)
  local found = {}
  for _, key in ipairs(keys) do
    if not names[key] then
      local ok, name = pcall(function()
        local builder = pipe.getLP().getItemIdentifierBuilder()
        builder.setItemID(itemId(key))
        builder.setItemData(itemData(key))
        local ident = builder.build()
        local name = ident.getName()
        -- Fall back to the registry name when the server could not translate it.
        if not name or name == "" or name:match("^[%w_.:]+%.name$") then
          name = ident.getIdName() .. "@" .. itemData(key)
        end
        return name
      end)
      if not ok then name = "item " .. itemId(key) .. "@" .. itemData(key) end
      name = name:gsub("\194\167.", ""):gsub("[\t\n\r]", " ")  -- drop § colour codes
      names[key] = name
      found[#found + 1] = key
    end
  end
  if #found > 0 then
    local f = io.open(path("names"), "a")
    if f then
      for _, key in ipairs(found) do f:write(string.format("%.0f\t%s\n", key, names[key])) end
      f:close()
    end
  end
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
  local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
  if h > 0 then return string.format("%dh %02dm", h, m) end
  return string.format("%dm", m)
end

local function fit(s, width)
  if unicode.wlen(s) <= width then return s end
  return unicode.sub(s, 1, width - 3) .. "..."
end

local function signed(n) return (n > 0 and "+" or "") .. commas(n) end

--- Add `entry` to `top` (biggest change first) if it is among the `limit`
--- biggest. Ties keep key order.
local function keepTop(top, limit, entry)
  local size = math.abs(entry.change)
  if #top >= limit and size <= math.abs(top[#top].change) then return end
  local pos = #top + 1
  while pos > 1 and math.abs(top[pos - 1].change) < size do pos = pos - 1 end
  table.insert(top, pos, entry)
  if #top > limit then top[#top] = nil end
end

--- The `limit` biggest drops and gains from base to current, and how many
--- items dropped and gained in all. Items new since base count as gains.
local function biggestChanges(limit)
  local result = { drops = {}, gains = {}, dropped = 0, gained = 0 }
  local bk, bc, ck, cc = base.keys, base.counts, current.keys, current.counts
  local i, j = 1, 1
  while bk[i] or ck[j] do
    local key, was, now
    if ck[j] == nil or (bk[i] ~= nil and bk[i] < ck[j]) then
      key, was, now = bk[i], bc[i], 0
      i = i + 1
    elseif bk[i] == nil or ck[j] < bk[i] then
      key, was, now = ck[j], 0, cc[j]
      j = j + 1
    else
      key, was, now = bk[i], bc[i], cc[j]
      i, j = i + 1, j + 1
    end
    local change = now - was
    if change < 0 then
      result.dropped = result.dropped + 1
      keepTop(result.drops, limit, { key = key, now = now, change = change })
    elseif change > 0 then
      result.gained = result.gained + 1
      keepTop(result.gains, limit, { key = key, now = now, change = change, new = was == 0 })
    end
  end
  return result
end

local function pad(s, width) return s .. string.rep(" ", width - unicode.wlen(s)) end

--- One list (drops or gains) as lines `width` wide: title, headings, then up
--- to `rows` items. Narrow columns leave out the per-hour rate.
local function column(list, title, empty, width, rows, hours)
  local wide = width >= 60
  local lines = { fit(title, width) }
  if wide then
    lines[2] = fit(string.format("%12s %10s %13s  %s", "Change", "Per hour", "Now", "Item"), width)
  else
    lines[2] = fit(string.format("%10s %10s  %s", "Change", "Now", "Item"), width)
  end
  for i = 1, math.min(#list, rows) do
    local d = list[i]
    local name = names[d.key] or ("item " .. itemId(d.key) .. "@" .. itemData(d.key))
    if d.now == 0 then name = name .. " (gone)" elseif d.new then name = name .. " (new)" end
    if wide then
      lines[#lines + 1] = fit(string.format("%12s %10s %13s  %s",
        signed(d.change), signed(d.change / hours), commas(d.now), name), width)
    else
      lines[#lines + 1] = fit(string.format("%10s %10s  %s", signed(d.change), commas(d.now), name), width)
    end
  end
  if #list == 0 then lines[#lines + 1] = fit(empty, width) end
  return lines
end

local function summary(changes)
  local span = (currentTime or base.time) - base.time
  return string.format("Changes over %s: %d item types, %d dropped, %d gained",
    span > 0 and duration(span) or "no time yet", #current.keys, changes.dropped, changes.gained), span
end

--- The two lists for `changes`, each `width` wide with at most `rows` items.
local function columns(changes, width, rows)
  local _, span = summary(changes)
  local hours = math.max(span, config.interval) / 3600
  local waiting = "Waiting for the second snapshot."
  return column(changes.drops, "Biggest drops", span > 0 and "Nothing has dropped." or waiting, width, rows, hours),
    column(changes.gains, "Biggest gains", span > 0 and "Nothing has gone up." or waiting, width, rows, hours)
end

local function screenSize()
  if component.isAvailable("gpu") then return component.gpu.getResolution() end
  return 80, 25
end

local function writeReport(changes)
  local f = io.open(reportFile, "w")
  if not f then return end
  local drops, gains = columns(changes, 200, config.reportFileLines)
  f:write((summary(changes)), "\n\n")
  for _, line in ipairs(drops) do f:write(line, "\n") end
  f:write("\n")
  for _, line in ipairs(gains) do f:write(line, "\n") end
  f:close()
end

local function draw(changes, status)
  local width, height = screenSize()
  term.clear()
  -- Summary, status, then drops on the left and gains on the right. The
  -- bottom row stays empty: drawing on it came out garbled in game.
  -- A long status (an error) wraps onto up to three lines.
  local w = width - 1
  local lines = { fit((summary(changes)), w) }
  for i = 1, math.min(3, math.ceil(unicode.wlen(status) / w)) do
    lines[#lines + 1] = unicode.sub(status, (i - 1) * w + 1, i * w)
  end
  local half = math.floor((w - 3) / 2)
  local drops, gains = columns(changes, half, height - 3 - #lines)
  for i = 1, math.max(#drops, #gains) do
    lines[#lines + 1] = pad(drops[i] or "", half) .. " | " .. (gains[i] or "")
  end
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
local status = "Starting."
local changes = { drops = {}, gains = {}, dropped = 0, gained = 0 }

local function step()
  local ok, err = pcall(function()
    local pipe = findPipe()
    local snap = snapshot(pipe)
    local t = now()
    if not haveHistory or resetRequested then
      reset(snap, t)
      haveHistory, resetRequested = true, false
    else
      record(snap, t)
      foldOld(t)
    end
    local _, height = screenSize()
    changes = biggestChanges(math.max(height, config.reportFileLines))
    local shown = {}
    for _, d in ipairs(changes.drops) do shown[#shown + 1] = d.key end
    for _, d in ipairs(changes.gains) do shown[#shown + 1] = d.key end
    resolveNames(pipe, shown)
    writeReport(changes)
    status = string.format("Updated %s (server time), next in %s. q quits.", os.date("%H:%M", t), duration(config.interval))
  end)
  if not ok then
    if tostring(err):find("ermission") then
      status = "LP denied access: turn on computer access in the Security Station."
    else
      status = "Read failed: " .. tostring(err)
    end
  end
end

while true do
  step()
  draw(changes, status)
  local wakeAt = computer.uptime() + config.interval
  repeat
    local ev, _, char = event.pull(math.max(0, wakeAt - computer.uptime()), "key_down")
    if ev == "key_down" and (char == string.byte("q") or char == string.byte("Q")) then
      term.clear()
      return
    end
  until computer.uptime() >= wakeAt
end
