-- pblogic.lua — The parallel builder admin's decisions: which robot gets which
-- tile, recording progress, releasing robots, and moving from the dig round to
-- the build round.
--
-- Pure Lua with no OpenComputers APIs, so it can be tested off the game.
-- admin.lua owns the radio, the screen and the state file, and passes every
-- robot message through pblogic.handle.
--
-- Messages from a robot carry `sid` (random per program start) and `seq`
-- (counts up). Replies carry `re = seq`. A repeated message (same sid and seq,
-- because the reply got lost) gets the same reply again without being
-- processed twice.
--
--   hello    {plan, version, crc, tile?, round?, pos}
--              -> welcome {id, tileSize, round, action, lane, stock}
--                 action "new":       no saved tile
--                 action "continue":  keep working the saved tile
--                 action "released":  forget the saved tile, ask for work
--              -> reject {reason}
--   claim    {at, pos}
--              -> assign {tile, round, p, i, lane, stock, needStock}
--              -> wait {reason, retry} | finished | unknown
--   progress {tile, round, p, i, pos, phase, manual}  -> ok | released
--   done     {tile, round}                            -> ok | released
--   stock    {stock}                                  -> stock {stock}
--   status   {phase, note, tile, round, p, i, pos, energy, fuel}  (no reply)
--
-- `p` is the pass (dig round, 0 = the travel layer) or the layer (build
-- round); `i` is the cell index inside the tile.

local tiles = require("pbtiles")

local logic = {}

--- A fresh admin state for a plan. info: name, version, crc, width, height, length.
function logic.newState(info, tileSize)
  local s = {
    plan = {
      name = info.name, version = info.version, crc = info.crc,
      width = info.width, height = info.height, length = info.length,
    },
    tileSize = tileSize,
    round = "excavate",      -- "excavate" -> "build" -> "done"
    tiles = {},              -- [id] = { status = "free"|"claimed"|"done", owner, p, i }
    lane = {},               -- [id] = true once the travel layer above the tile is dug
    robots = {},             -- [address] = { id, tile, pos, phase, lastSeen, missing, released, ... }
    nextId = 1,
    stock = nil,             -- "name@damage" -> true, shared by every robot in the build round
    stockBy = nil,           -- address of the robot taking the stock snapshot
    holdBuild = false,       -- --excavate-only: do not start the build round
  }
  local g = logic.grid(s)
  for id = 0, g.count - 1 do
    s.tiles[id] = { status = "free", p = 0, i = 0 }
  end
  return s
end

function logic.grid(s)
  return tiles.grid(s.plan.width, s.plan.height, s.plan.length, s.tileSize)
end

--- Start the build round over on a site that is already dug (pbadmin
--- --rebuild): every tile free at layer 0, and the chest checked again.
--- Robots that come back with a saved tile are told to drop it.
function logic.restartBuild(s)
  s.round = "build"
  s.holdBuild = false
  for _, t in pairs(s.tiles) do
    t.status, t.owner, t.p, t.i = "free", nil, 0, 0
  end
  for id = 0, logic.grid(s).count - 1 do s.lane[id] = true end
  for _, r in pairs(s.robots) do r.tile = nil end
  s.stock, s.stockBy = nil, nil
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function note(ev, text)
  ev.log[#ev.log + 1] = text
end

local function seen(r, msg, now)
  r.lastSeen = now
  r.missing = false
  if type(msg.pos) == "table" then
    r.pos = { x = msg.pos.x, y = msg.pos.y, z = msg.pos.z }
  end
  if msg.phase ~= nil then r.phase = msg.phase end
end

local function planMatches(s, msg)
  return msg.plan == s.plan.name and msg.version == s.plan.version and msg.crc == s.plan.crc
end

--- In the dig round a tile can only be handed out next to a tile whose travel
--- layer is already dug (or it is tile 0, beside the start column). Otherwise
--- a robot flying to it would meet undug ground in the travel layer.
local function reachable(s, g, id)
  if s.round ~= "excavate" then return true end
  if id == 0 or s.lane[id] then return true end
  for _, n in ipairs(tiles.neighbors(g, id)) do
    if s.lane[n] then return true end
  end
  return false
end

--- Is another (not released) robot sitting inside this tile, below the travel
--- layer? A robot waiting in a finished tile must not get dug around.
local function occupied(s, g, id, from)
  for addr, r in pairs(s.robots) do
    if addr ~= from and not r.released and r.pos and r.pos.y < s.plan.height
       and tiles.tileOf(g, r.pos.x, r.pos.z) == id then
      return true
    end
  end
  return false
end

local function allDone(s)
  for _, t in pairs(s.tiles) do
    if t.status ~= "done" then return false end
  end
  return true
end

local function advanceRound(s, ev)
  if s.round == "excavate" then
    s.round = "build"
    for _, t in pairs(s.tiles) do
      t.status, t.owner, t.p, t.i = "free", nil, 0, 0
    end
    for _, r in pairs(s.robots) do r.tile = nil end
    note(ev, "Every tile is dug. Starting the build round.")
  else
    s.round = "done"
    note(ev, "Every tile is built. The build is finished.")
  end
  ev.important = true
end

local function assignReply(s, g, id)
  local t = s.tiles[id]
  return {
    type = "assign", tile = id, round = s.round, p = t.p, i = t.i,
    lane = tiles.encodeFlags(s.lane, g.count),
    stock = s.stock,
    needStock = (s.round == "build" and s.stock == nil),
  }
end

-- ---------------------------------------------------------------------------
-- Message handlers
-- ---------------------------------------------------------------------------

local handlers = {}

function handlers.hello(s, from, msg, now, ev)
  if not planMatches(s, msg) then
    return {
      type = "reject",
      reason = string.format("the admin is running %s version %s", tostring(s.plan.name),
        tostring(s.plan.version)),
    }
  end
  local g = logic.grid(s)

  local r = s.robots[from]
  if not r then
    r = { id = s.nextId }
    s.nextId = s.nextId + 1
    s.robots[from] = r
    note(ev, "Robot " .. r.id .. " joined.")
    ev.important = true
  end
  seen(r, msg, now)

  local action = "new"
  if msg.tile ~= nil then
    local t = s.tiles[msg.tile]
    if not r.released and t and t.status == "claimed" and t.owner == from
       and msg.round == s.round then
      action = "continue"
      r.tile = msg.tile
    else
      action = "released"
    end
  end

  -- The robot no longer has the tile it held here (a wiped drive, or --new).
  if action ~= "continue" and r.tile ~= nil then
    local t = s.tiles[r.tile]
    if t and t.status == "claimed" and t.owner == from then
      t.status, t.owner = "free", nil
      note(ev, string.format("Robot %d restarted without its tile; tile %d is free again.",
        r.id, r.tile))
    end
    r.tile = nil
    ev.important = true
  end

  if r.released then
    r.released = nil
    note(ev, "Robot " .. r.id .. " is back after being released.")
    ev.important = true
  end

  return {
    type = "welcome", id = r.id, tileSize = s.tileSize, round = s.round, action = action,
    lane = tiles.encodeFlags(s.lane, g.count), stock = s.stock,
  }
end

function handlers.claim(s, from, msg, now, ev)
  local r = s.robots[from]
  if not r or r.released then return { type = "unknown" } end
  seen(r, msg, now)
  if s.round == "done" then return { type = "finished" } end
  local g = logic.grid(s)

  -- Already holding a tile this round: hand the same one back.
  if r.tile ~= nil then
    local t = s.tiles[r.tile]
    if t and t.status == "claimed" and t.owner == from then
      return assignReply(s, g, r.tile)
    end
    r.tile = nil
  end

  local best, bestDist = nil, nil
  for id = 0, g.count - 1 do
    local t = s.tiles[id]
    if t.status == "free" and reachable(s, g, id) and not occupied(s, g, id, from) then
      local d = (msg.at ~= nil) and tiles.distance(g, msg.at, id) or 0
      if best == nil or d < bestDist then
        best, bestDist = id, d
      end
    end
  end

  if best == nil then
    if allDone(s) then
      -- Started with --excavate-only: stop here so the site can be checked.
      -- Restarting the admin without the flag starts the build round.
      if s.round == "excavate" and s.holdBuild then
        return { type = "finished",
                 reason = "every tile is dug, and the admin was started with --excavate-only" }
      end
      advanceRound(s, ev)
      return handlers.claim(s, from, msg, now, ev)
    end
    return { type = "wait", retry = 15, reason = "no tile is free yet" }
  end

  -- The first robot of the build round checks what the chest holds; the rest
  -- wait for that list so every robot skips the same missing items.
  if s.round == "build" and s.stock == nil then
    local other = s.stockBy and s.robots[s.stockBy]
    if s.stockBy ~= from and other and not other.released and not other.missing then
      return { type = "wait", retry = 15, reason = "another robot is checking the chest" }
    end
    s.stockBy = from
  end

  local t = s.tiles[best]
  t.status, t.owner = "claimed", from
  r.tile = best
  note(ev, string.format("Robot %d took tile %d (%s).", r.id, best, s.round))
  ev.important = true
  return assignReply(s, g, best)
end

function handlers.progress(s, from, msg, now, ev)
  if type(msg.manual) == "table" then
    for _, line in ipairs(msg.manual) do ev.manual[#ev.manual + 1] = tostring(line) end
  end
  local r = s.robots[from]
  if not r or r.released then return { type = "released" } end
  seen(r, msg, now)

  local t = msg.tile ~= nil and s.tiles[msg.tile] or nil
  if not t or t.status ~= "claimed" or t.owner ~= from or msg.round ~= s.round then
    return { type = "released" }
  end
  local p, i = tonumber(msg.p) or 0, tonumber(msg.i) or 0
  if p > t.p or (p == t.p and i > t.i) then
    t.p, t.i = p, i
  end
  if s.round == "excavate" and t.p >= 1 and not s.lane[msg.tile] then
    s.lane[msg.tile] = true
    ev.important = true
  end
  return { type = "ok" }
end

function handlers.done(s, from, msg, now, ev)
  local r = s.robots[from]
  if not r or r.released then return { type = "released" } end
  seen(r, msg, now)

  local t = msg.tile ~= nil and s.tiles[msg.tile] or nil
  if not t or t.status ~= "claimed" or t.owner ~= from or msg.round ~= s.round then
    return { type = "released" }
  end
  t.status, t.owner = "done", nil
  if s.round == "excavate" then s.lane[msg.tile] = true end
  r.tile = nil
  note(ev, string.format("Robot %d finished tile %d (%s).", r.id, msg.tile, s.round))
  ev.important = true
  return { type = "ok" }
end

function handlers.stock(s, from, msg, now, ev)
  local r = s.robots[from]
  if r then seen(r, msg, now) end
  if s.stock == nil and type(msg.stock) == "table" then
    s.stock = msg.stock
    s.stockBy = nil
    note(ev, "Got the stock list from robot " .. tostring(r and r.id or "?") .. ".")
    ev.important = true
    ev.stock = true
  end
  return { type = "stock", stock = s.stock }
end

function handlers.status(s, from, msg, now, ev)
  local r = s.robots[from]
  if not r then return nil end
  seen(r, msg, now)
  r.note = msg.note
  r.energy, r.fuel = msg.energy, msg.fuel
  r.p, r.i = msg.p, msg.i
  return nil
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

-- The last reply sent to each robot, to answer a repeated message the same way.
-- Not part of the saved state: after an admin restart a repeat is processed
-- again, and every handler is safe to repeat.
local lastReplies = {}

--- Process one message from a robot.
--- @return reply (nil for none), events { log = {...}, manual = {...}, important, stock }
function logic.handle(s, from, msg, now)
  local ev = { log = {}, manual = {}, important = false }
  local handler = type(msg) == "table" and handlers[msg.type] or nil
  if not handler then return nil, ev end

  local cached = lastReplies[from]
  if msg.seq ~= nil and cached and cached.sid == msg.sid and cached.seq == msg.seq then
    return cached.reply, ev
  end

  local reply = handler(s, from, msg, now, ev)
  if reply and msg.seq ~= nil then
    reply.re = msg.seq
    lastReplies[from] = { sid = msg.sid, seq = msg.seq, reply = reply }
  end
  return reply, ev
end

--- Release robots so their tiles can be handed out again: `which` is a robot
--- id, or "missing" for every robot marked missing. Only do this once those
--- robots are stopped; a released robot that comes back is told to drop its tile.
--- @return the number released, events
function logic.release(s, which)
  local ev = { log = {}, manual = {}, important = true }
  local count = 0
  for addr, r in pairs(s.robots) do
    local match
    if which == "missing" then match = r.missing else match = (r.id == which) end
    if match and not r.released then
      if r.tile ~= nil then
        local t = s.tiles[r.tile]
        if t and t.status == "claimed" and t.owner == addr then
          t.status, t.owner = "free", nil
        end
      end
      note(ev, string.format("Released robot %d%s.", r.id,
        r.tile ~= nil and (" (tile " .. r.tile .. " is free again)") or ""))
      r.tile = nil
      r.released = true
      r.missing = false
      if s.stockBy == addr then s.stockBy = nil end
      count = count + 1
    end
  end
  return count, ev
end

--- Mark robots missing that have been silent for more than `after` seconds.
--- @return ids of robots that just became missing
function logic.markMissing(s, now, after)
  local changed = {}
  for _, r in pairs(s.robots) do
    local missing = (not r.released) and r.lastSeen ~= nil and (now - r.lastSeen) > after
    if missing and not r.missing then changed[#changed + 1] = r.id end
    r.missing = missing
  end
  return changed
end

--- Tile counts for the status screen.
function logic.summary(s)
  local out = { free = 0, claimed = 0, done = 0, lanes = 0, total = 0 }
  for _, t in pairs(s.tiles) do
    out.total = out.total + 1
    out[t.status] = (out[t.status] or 0) + 1
  end
  for _ in pairs(s.lane) do out.lanes = out.lanes + 1 end
  return out
end

--- For tests: forget the reply cache.
function logic.resetCache()
  lastReplies = {}
end

return logic
