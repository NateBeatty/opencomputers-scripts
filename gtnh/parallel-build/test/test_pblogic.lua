-- test_pblogic.lua — Unit tests for the parallel builder admin's decisions.
-- Run with: node converter/test/run_lua_tests.js gtnh/parallel-build/test/test_pblogic.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../lib/?.lua;" .. package.path

local tiles = require("pbtiles")
local logic = require("pblogic")

passed = 0
failed = 0

local function test(name, fn)
  logic.resetCache()
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

-- A 48 x 5 x 48 plan in 16x16 tiles: 3 x 3 tiles, ids
--   0 1 2
--   3 4 5
--   6 7 8
local INFO = { name = "test", version = 3, crc = 1234, width = 48, height = 5, length = 48 }

local function newState() return logic.newState(INFO, 16) end

-- A fake robot: sends messages with its own sid/seq, like pbuild.lua does.
local function robotClient(s, address)
  local c = { address = address, seq = 0, now = 0 }
  function c.send(msg, sameSeq)
    if not sameSeq then c.seq = c.seq + 1 end
    msg.sid, msg.seq = "sid-" .. address, c.seq
    c.now = c.now + 1
    return logic.handle(s, address, msg, c.now)
  end
  function c.hello(extra)
    local msg = { type = "hello", plan = INFO.name, version = INFO.version, crc = INFO.crc,
                  pos = { x = -1, y = 0, z = 0 } }
    for k, v in pairs(extra or {}) do msg[k] = v end
    return c.send(msg)
  end
  function c.claim(at, pos)
    return c.send({ type = "claim", at = at, pos = pos or { x = -1, y = 0, z = 0 } })
  end
  return c
end

print("=== Admin Logic Tests ===")

test("a plan mismatch is rejected", function()
  local s = newState()
  local reply = logic.handle(s, "r1", { type = "hello", plan = "other", version = 3, crc = 1234, seq = 1 }, 1)
  assert_eq(reply.type, "reject")
  assert_eq(reply.re, 1, "reply carries re")
end)

test("the first robot gets tile 0; the next waits until its travel layer is dug", function()
  local s = newState()
  local a, b = robotClient(s, "a"), robotClient(s, "b")
  local w = a.hello()
  assert_eq(w.type, "welcome"); assert_eq(w.id, 1); assert_eq(w.action, "new")
  assert_eq(w.lane, "000000000", "no lanes yet")

  local got = a.claim(tiles.COLUMN)
  assert_eq(got.type, "assign"); assert_eq(got.tile, 0); assert_eq(got.round, "excavate")

  b.hello()
  assert_eq(b.claim(tiles.COLUMN).type, "wait", "nothing reachable yet")

  -- Row progress on the travel layer (pass 0) does not open the lane...
  assert_eq(a.send({ type = "progress", tile = 0, round = "excavate", p = 0, i = 32 }).type, "ok")
  assert_eq(s.lane[0], nil, "lane still closed")
  -- ...finishing pass 0 does.
  a.send({ type = "progress", tile = 0, round = "excavate", p = 1, i = 0 })
  assert_eq(s.lane[0], true, "lane open")

  local gb = b.claim(tiles.COLUMN)
  assert_eq(gb.type, "assign")
  assert_eq(gb.tile, 1, "nearest reachable tile")
  assert_eq(gb.lane:sub(1, 1), "1", "lane map sent")
end)

test("claims are idempotent: a repeat and a new request return the same tile", function()
  local s = newState()
  local a = robotClient(s, "a")
  a.hello()
  local first = a.claim(tiles.COLUMN)
  local again = a.send({ type = "claim", at = tiles.COLUMN }, true)  -- same seq: lost reply
  assert_eq(again, first, "cached reply")
  local renewed = a.claim(tiles.COLUMN)
  assert_eq(renewed.tile, first.tile, "same tile on a new request")
  local claimed = 0
  for _, t in pairs(s.tiles) do if t.status == "claimed" then claimed = claimed + 1 end end
  assert_eq(claimed, 1, "only one tile claimed")
end)

test("progress never goes backwards, and is refused for a tile not owned", function()
  local s = newState()
  local a, b = robotClient(s, "a"), robotClient(s, "b")
  a.hello(); b.hello()
  a.claim(tiles.COLUMN)
  a.send({ type = "progress", tile = 0, round = "excavate", p = 2, i = 16 })
  a.send({ type = "progress", tile = 0, round = "excavate", p = 1, i = 200 })
  assert_eq(s.tiles[0].p, 2, "p kept"); assert_eq(s.tiles[0].i, 16, "i kept")
  assert_eq(b.send({ type = "progress", tile = 0, round = "excavate", p = 3, i = 0 }).type,
    "released", "not b's tile")
end)

test("manual entries are passed on once, even when the message repeats", function()
  local s = newState()
  local a = robotClient(s, "a")
  a.hello(); a.claim(tiles.COLUMN)
  local msg = { type = "progress", tile = 0, round = "excavate", p = 0, i = 16,
                manual = { "could not dig at (1,0,1)" } }
  local _, ev1 = a.send(msg)
  local _, ev2 = a.send(msg, true)
  assert_eq(#ev1.manual, 1, "first time"); assert_eq(#ev2.manual, 0, "repeat")
end)

test("releasing a missing robot frees its tile, keeping the progress", function()
  local s = newState()
  local a = robotClient(s, "a")
  a.hello(); a.claim(tiles.COLUMN)
  a.send({ type = "progress", tile = 0, round = "excavate", p = 3, i = 48,
           pos = { x = 5, y = 2, z = 3 } })

  local changed = logic.markMissing(s, a.now + 1000, 300)
  assert_eq(#changed, 1, "a went missing")
  local count = logic.release(s, "missing")
  assert_eq(count, 1, "released one")
  assert_eq(s.tiles[0].status, "free"); assert_eq(s.tiles[0].p, 3, "progress kept")

  -- Another robot resumes tile 0 from the saved progress. The released robot's
  -- last position does not block the tile.
  local b = robotClient(s, "b")
  b.hello()
  local got = b.claim(tiles.COLUMN)
  assert_eq(got.tile, 0); assert_eq(got.p, 3); assert_eq(got.i, 48)

  -- When the released robot comes back, it is told to drop its saved tile.
  local w = a.hello({ tile = 0, round = "excavate" })
  assert_eq(w.action, "released")
  assert_eq(s.robots["a"].released, nil, "no longer released")
  assert_eq(s.tiles[0].owner, "b", "b keeps the tile")
end)

test("a restarted robot keeps its tile; one that lost its drive frees it", function()
  local s = newState()
  local a = robotClient(s, "a")
  a.hello(); a.claim(tiles.COLUMN)
  assert_eq(a.hello({ tile = 0, round = "excavate" }).action, "continue")
  assert_eq(a.hello().action, "new", "no saved tile")
  assert_eq(s.tiles[0].status, "free", "tile freed")
end)

test("a robot waiting inside a tile keeps others out of it", function()
  local s = newState()
  local a, b = robotClient(s, "a"), robotClient(s, "b")
  a.hello(); b.hello()
  s.lane[0] = true
  -- a sits in tile 1 (below the travel layer); b must not be given tile 1.
  a.send({ type = "status", pos = { x = 20, y = 1, z = 2 } })
  s.tiles[0].status = "done"
  local got = b.claim(0, { x = 5, y = 5, z = 5 })
  assert_eq(got.type, "assign")
  assert_eq(got.tile, 3, "tile 1 is occupied, 3 is next nearest")
end)

test("the build round starts once every tile is dug, with one stock check", function()
  local s = newState()
  local a, b = robotClient(s, "a"), robotClient(s, "b")
  a.hello(); b.hello()
  for id = 0, 8 do
    s.tiles[id].status = "done"
    s.lane[id] = true
  end

  local ga = a.claim(4, { x = 20, y = 5, z = 20 })
  assert_eq(s.round, "build")
  assert_eq(ga.type, "assign"); assert_eq(ga.round, "build")
  assert_eq(ga.needStock, true, "first robot checks the chest")

  assert_eq(b.claim(4, { x = 20, y = 5, z = 20 }).type, "wait", "waits for the stock list")

  local sr = a.send({ type = "stock", stock = { ["minecraft:dirt@0"] = true } })
  assert_eq(sr.stock["minecraft:dirt@0"], true)

  local gb = b.claim(4, { x = 20, y = 5, z = 20 })
  assert_eq(gb.type, "assign")
  assert_eq(gb.needStock, false)
  assert_eq(gb.stock["minecraft:dirt@0"], true, "stock handed out")
end)

test("--excavate-only stops after digging; without it the build round starts", function()
  local s = newState()
  local a = robotClient(s, "a")
  a.hello()
  s.holdBuild = true
  for id = 0, 8 do s.tiles[id].status = "done"; s.lane[id] = true end

  local stopped = a.claim(4, { x = 20, y = 1, z = 20 })
  assert_eq(stopped.type, "finished", "robots are told to stop")
  assert_eq(type(stopped.reason), "string", "with a reason")
  assert_eq(s.round, "excavate", "the build round has not started")

  s.holdBuild = false   -- the admin restarted without the flag
  local got = a.claim(4, { x = 20, y = 1, z = 20 })
  assert_eq(got.type, "assign"); assert_eq(got.round, "build")
end)

test("finishing the last build tile ends the build", function()
  local s = newState()
  local a = robotClient(s, "a")
  a.hello()
  s.round = "build"
  s.stock = {}
  for id = 0, 8 do s.tiles[id].status = "done"; s.lane[id] = true end
  s.tiles[8].status = "free"
  local got = a.claim(8, { x = 40, y = 5, z = 40 })
  assert_eq(got.tile, 8)
  assert_eq(a.send({ type = "done", tile = 8, round = "build" }).type, "ok")
  assert_eq(a.claim(8, { x = 40, y = 5, z = 40 }).type, "finished")
  assert_eq(s.round, "done")
end)

test("a released stock checker hands the job to the next robot", function()
  local s = newState()
  local a, b = robotClient(s, "a"), robotClient(s, "b")
  a.hello(); b.hello()
  s.round = "build"
  for id = 0, 8 do s.lane[id] = true end
  assert_eq(a.claim(0).needStock, true)
  assert_eq(b.claim(0).type, "wait")
  logic.release(s, s.robots["a"].id)
  local gb = b.claim(0)
  assert_eq(gb.type, "assign"); assert_eq(gb.needStock, true)
end)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
