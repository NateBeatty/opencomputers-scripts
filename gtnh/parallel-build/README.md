# Parallel build

Several robots digging and building one plan at the same time, coordinated by
an admin computer. For a single robot, `gtnh/builder` (`build.lua`) still works
on its own.

The box is cut into **16x16 tiles** (full height). Robots ask the admin for a
tile, dig it, report it done, and ask for the next. **Round 1 digs every tile,
round 2 builds every tile.** You can add robots at any time; they just ask for
work.

## How robots get around

```
   travel layer (one block above the box)  <- robots fly here between tiles
 +-------------------------------------+
 | tile | tile | tile | ...            |    the box, cut into 16x16 tiles
 +-------------------------------------+
P
^ start pad: on the ground, one block west of the NW corner. Robots start
  here facing east, and climb the column above it to the travel layer.
```

- A robot clears the travel layer above **its own tile** as the first step of
  digging it. The admin only hands out a tile next to one whose travel layer
  is already dug, so work spreads outward from the NW corner.
- **A robot never breaks a block that is an inventory.** Robots are
  inventories, so a robot in the way is waited for, never dug. In the travel
  layer it steps around. (A chest buried in the terrain also stops a robot;
  it reports being blocked.)
- Below the travel layer, a robot only digs inside its own tile, and only
  places its ender chest there.

## Hardware

**Every robot:** as for `build.lua` (Inventory Controller, generators,
unbreakable pickaxe, Advanced Ender Chest on the shared frequency, Angel), plus
a **Hover upgrade** (tiles get dug deeper than the 8-block flight limit) and a
**wireless network card** (Tier 2).

**Admin:** a computer with a screen, keyboard, a **Tier 2 wireless network
card** and an Internet Card. Put it **above the middle of the site**: wireless
range is 400 blocks, and solid blocks between the admin and a robot shorten it.

## Install

Type commands without leading spaces. `<ref>` is `main`, or a commit SHA to skip
GitHub's 5-minute cache.

```
mkdir /home/bin
wget -f https://raw.githubusercontent.com/NateBeatty/opencomputers-scripts/<ref>/gtnh/parallel-build/install.lua /home/bin/pbinstall.lua
```

On the admin:
```
/home/bin/pbinstall.lua https://raw.githubusercontent.com/NateBeatty/opencomputers-scripts/<ref>/gtnh admin
```

On each robot:
```
/home/bin/pbinstall.lua https://raw.githubusercontent.com/NateBeatty/opencomputers-scripts/<ref>/gtnh robot
```

Then download the plan on the admin and every robot:
```
/home/bin/getplan.lua https://raw.githubusercontent.com/NateBeatty/opencomputers-scripts/<ref>/gtnh/plans/layer1.plan layer1
```

## Run

1. On the admin: `/home/bin/pbadmin.lua /plans/layer1.plan`
   (add `--tile 8` for smaller tiles on a test plan).
2. Place a robot on the start pad facing east and run
   `/home/bin/pbuild.lua /plans/layer1.plan`.
3. Wait until it has climbed away from the pad, then place the next robot the
   same way. Early on, extra robots wait on the pad until a tile next to a dug
   one is free.

Restarting either program continues where it left off; no flag is needed.

## Admin commands

| Command | What it does |
|---|---|
| `release <id>` | Free robot `<id>`'s tile. The next robot resumes it from the last row reported. |
| `release missing` | The same for every robot shown as `MISSING`. |
| `pause` / `resume` | Pause or resume every robot. |
| `stop` | Every robot saves and ends its program. |
| `map` | Tile map: `D` done, `#` being worked, `o` free, `.` not reachable yet. |
| `quit` | Close the admin. Robots wait for it (they do nothing without it). |

## When a robot stops

A robot that sends nothing for 5 minutes is shown as **MISSING**. The admin
does nothing on its own, because the robot is still standing in its tile.

1. Find it: the admin shows its tile and last position.
2. Pick it up (and its ender chest, if it is sitting on one).
3. Type `release missing` (or `release <id>`).
4. To use it again, put it on the start pad and run
   `/home/bin/pbuild.lua /plans/layer1.plan --new`.

If a robot is released without being picked up, the next robot in that tile
waits beside it and reports `blocked` instead of digging it out.

## Files

| Where | File | Contents |
|---|---|---|
| Admin | `/home/pbuild_admin.txt` | Tiles, owners, progress (resume state) |
| Admin | `/home/pbuild_manual.txt` | Cells robots could not dig or place |
| Admin | `/home/pbuild_stock.txt` | Plan items that are stocked or skipped |
| Admin | `/home/pbuild_log.txt` | The admin's log lines |
| Robot | `/home/pbuild_state.txt` | The robot's own progress, saved every move |

Fuel and restock settings come from `/etc/builder.cfg`, as for `build.lua`.
`/etc/pbuild.cfg` can override anything, e.g. `return { port = 65657 }`.

## Tests

```
cd converter
node test/run_lua_tests.js ../gtnh/parallel-build/test/test_pbtiles.lua
node test/run_lua_tests.js ../gtnh/parallel-build/test/test_pblogic.lua
node test/run_lua_tests.js ../gtnh/parallel-build/test/sim_world.lua
```

`sim_world.lua` runs several copies of `pbuild.lua` against a simulated world
and admin, and checks the result cell by cell. It has no gravity or flight
limit, so it does not replace a first test on a small plan in game.
