# Agent brief: OpenComputers schematic builder for GTNH 1.7.10

## 0. Your job

Build a system that lets an OpenComputers (OC) robot on the user's GregTech: New Horizons (Minecraft 1.7.10) server build a structure from a `.schematic` file. The robot excavates the build volume and places the schematic's blocks layer by layer, pulling materials and fuel from an ender chest it carries. You will write:

- an **offline converter** (Node.js, runs on the user's PC) that turns a `.schematic` into a compact, streamable `.plan`, and
- the **robot-side programs** (Lua 5.3 on OpenOS).

This brief comes out of a long design discussion with the user. The decisions below are settled. Don't reopen them without a concrete reason; if you find one, stop and ask the user. Facts marked with a source were verified in the local source trees. Re-check any fact you depend on critically, and verify anything unmarked before relying on it. The server's live config (`config/opencomputers/settings.conf`) may differ from the defaults cited here, so measure or detect at runtime where you can.

This is not a git repo; ask the user before running `git init` or committing.

## 1. Deliverables

```
converter/            Node CLI: .schematic -> .plan (+ manifest, report, optional paste pack)
robot/                OpenOS programs and libraries
  build.lua           the builder
  getplan.lua         download + validate a plan with the Internet Card
  recv.lua            receive a plan pasted into the robot as text
  selftest.lua        hardware, fuel and ender-chest checks
  install.lua         fetch/update all robot files from a base URL
  lib/                plan reader, crc32, base64, varint, path, inventory, energy, state, status
  etc/builder.cfg     default config (Lua table)
station/monitor.lua   base-computer status monitor + remote pause/resume/stop over wireless
tests/                converter tests, Lua unit tests, mock-world simulation
README.md             setup guide for the user: robot assembly, site layout, workflow, in-game checklist
```

Milestones. **Stop and report to the user after M1 and after M3.**

1. Converter, plan format, JS decoder/inspector, tested on real schematics.
2. Lua core libraries, tested against golden plans produced in M1.
3. Mock-world simulator and the build loop, tested end to end.
4. Robot I/O layer, `getplan`/`recv`/`selftest`/`install`, config, README.
5. Station monitor.

## 2. Local sources you can read

- **`D:\Coding\Greg Tech\GTNH-OpenComputers`**: the exact OC fork the server runs. Scala under `src/main/scala/li/cil/oc/`, defaults in `src/main/resources/application.conf`, OpenOS under `src/main/resources/assets/opencomputers/loot/openos/`. Reference program worth reading: `loot/builder/usr/bin/build.lua` (state file, resume, restock loop).
- **`D:\Coding\Greg Tech\Schematica`**: GTNH Schematica fork. Format reader/writer: `src/main/java/com/github/lunatrius/schematica/world/schematic/SchematicAlpha.java`; NBT tag names: `reference/Names.java:223-244`; block-to-item and placement references: `client/util/BlockToItemStack.java`, `client/printer/SchematicPrinter.java` (see `isBlacklisted`), `client/printer/registry/PlacementRegistry.java`.
- **`D:\Coding\LitematicaSchematicaConverter\LitematicaToSchematic`**: the user's own Node converter (Litematica -> 1.7.10 `.schematic`). Reuse its `nbt.js`. `itempanel.csv` is an NEI item-panel dump from the user's GTNH instance (`Item Name,Item ID,Item meta,Has NBT,Display Name`). `mytable.json` / `fallbacks.json` are its mapping tables. `tree5.schematic` and `tree5_out.schematic` are usable test inputs. The sibling folders (Lite2Edit, SchemToSchematic, Schematica-master, NotEnoughItems-master) are reference material only.

Paths below are relative to the OC fork as `oc/` = `GTNH-OpenComputers/src/main/scala/li/cil/oc/` and `conf` = `GTNH-OpenComputers/src/main/resources/application.conf`.

## 3. Hardware and site (settled)

### Robot: Tier 3

| Group | Contents |
|---|---|
| Upgrade slots, tier 3 (x3) | Chunkloader, Battery Upgrade T3, Battery Upgrade T3 |
| Upgrade slots, tier 2 (x3) | Inventory Controller, Angel, Generator |
| Upgrade slots, tier 1 (x3) | Inventory, Inventory, and one free slot (the user may add a third Inventory Upgrade) |
| Card slots (T3, T2, T2) | Graphics Card (the robot's built-in screen needs it; required for pasting), Wireless Network Card T2, Internet Card T2 |
| Container slots (T3, T2, T2) | Upgrade Containers, left empty for runtime swaps |
| Core | CPU T3, 2x RAM T3.5, HDD T3 + HDD T2, Lua BIOS EEPROM, OpenOS installed |
| Tool slot | The user's pickaxe, which **cannot be damaged**, with enough harvest level for the site |
| Inventory | One **Advanced Ender Chest** (EnderStorage) on a **global** (non-personal) frequency, holding the build materials **and fuel (coal)**. Every item type present in the chest or the robot's inventory when the build starts will keep being restocked by hand, sometimes slowly; no other types will appear during the build (7.4). |

**Power: there is no charger.** The Generator Upgrade, burning fuel pulled from the ender chest, is the only power source. A newly assembled robot starts with its 20,000 base buffer full (`oc/common/template/RobotTemplate.scala:34`). Support **any number** of Generator Upgrades (`component.list("generator")`); the user may add a second.

The program must **detect capabilities rather than assume them**:
- Required: `inventory_controller`, at least one `generator`, `robot.inventorySize() >= 16`, and a tool. Detect the tool with `robot.durability()`: it returns a number for a damageable tool, `nil, "tool cannot be damaged"` for an unbreakable one (**the user's case, and valid**), and `nil, "no tool equipped"` when there is none (`oc/server/component/Robot.scala:71-80`).
- Optional: `angel`, `chunkloader`, `modem`, `internet`. Adapt behaviour and report what's missing at startup.

### Coordinates and site layout

```
Schematic axes: X = Width, Y = Height, Z = Length.   cell (x,y,z) = index x + (y*L + z)*W
Robot start: stands IN cell (0,0,0), the bottom layer's origin corner, facing the direction that becomes +X.
             forward = +X, right = +Z, up = +Y.
             (Facing east (+X), your right is south (+Z), so facing east reproduces the schematic's own
              orientation. Everything is relative to the start pose; there is no compass/nav upgrade.)
Layer 0 is at the robot's starting height; the terrain under it (y = -1) is untouched and supports layer 0.
No charger, no dock, no home position. The robot never leaves the build footprint.
Excavated: every footprint cell from y = 0 to y = H (one layer above the schematic's top). Nothing else
           is touched.
```

## 4. Verified engine facts

| Fact | Source |
|---|---|
| T3 robot: 3 container slots (tiers 3,2,2), **9 upgrade slots** (tiers 3,3,3,2,2,2,1,1,1), card slots (3,2,2) | `oc/common/template/RobotTemplate.scala:112-135`; `GTNH-OpenComputers/src/main/java/li/cil/oc/api/IMC.java:109-110` |
| Upgrade tiers: Inventory 1, Geolyzer 1, Inventory Controller 2, Angel 2, Generator 2, Navigation 2, Chunkloader 3, Battery/Hover by variant | `oc/integration/opencomputers/Driver*.scala` (`override def tier`) |
| Inventory Upgrade = 16 slots; max main inventory = 100 - equipment - components (about 78 on T3) | `DriverUpgradeInventory.scala:20`; `oc/common/tileentity/Robot.scala:83-85` |
| `robot.durability()`: number for a damageable tool; `nil, "tool cannot be damaged"` for an unbreakable one; `nil, "no tool equipped"` for none | `oc/server/component/Robot.scala:71-80` |
| `place(side)` with no face tries `side` first, then the 4 perpendicular directions (not the opposite); placing into empty air requires the Angel Upgrade (`canPlaceInAir`) | `oc/server/component/Agent.scala:247-280`, `:60-64`; `oc/common/event/AngelUpgradeHandler.scala` |
| Angel Upgrade registers a component named `angel` (detectable) | `oc/server/component/UpgradeAngel.scala` |
| `compare(side, fuzzy)`: true if the block matches the ItemBlock in the selected slot; exact subtype unless `fuzzy`; always false for non-block items | `oc/server/component/traits/InventoryWorldControl.scala:19-33` |
| `drop(side)`: inserts into an inventory on that side if there is one, otherwise spawns an item entity (despawns after 5 min) | same file, `drop` |
| Mining auto-collects only item entities that **appeared during that action** within 2 blocks; items already on the ground are not re-collected. If the inventory is full, drops stay on the ground. There is no "don't collect" option. | `oc/server/agent/Player.scala:183-195` |
| `suckFromItemInventory` only works for items with a registered `InventoryProvider` (only the Database upgrade and the Server). EnderStorage's OC integration is a **tile-entity** driver (component `ender_storage`: `getFrequency`/`setFrequency`/`getOwner`). So the carried ender chest **cannot** be read from inventory; it must be placed. | `oc/server/component/traits/ItemInventoryControl.scala`; `oc/integration/opencomputers/ModOpenComputers.scala:212-213`; `oc/integration/enderstorage/DriverFrequencyOwner.java` |
| GTNH extras on `inventory_controller`: `equip()` swaps the selected slot with the tool; `installUpgrade([slot])`; `getUpgradeContainerType/Tier(slot)` | `oc/server/component/UpgradeInventoryController.scala:83-125` |
| Energy: robot buffer 20000; Battery Upgrade +10000/15000/20000 (this robot: 60000 total); move 15; turn 2.5; running cost 0.25/tick (5/s); **sleeping cost x0.1 (0.5/s)** while sleeping with no pending signals | `conf` `power.buffer.robot`, `batteryUpgrades`, `robotMove`, `robotTurn`, `power.cost.robot`, `power.cost.sleepFactor`; `oc/server/machine/Machine.scala:522-537` |
| Generator: 0.8/tick (16/s) per generator while burning; coal = 1600 ticks = about 1280 energy. `insert([count])` moves fuel from the selected slot into a one-item-type queue; `count()`, `remove([count])`. **Queued fuel burns one item after another even when the buffer is full** (excess is wasted), and **keeps burning while the robot is off** (components update regardless of running state). Queued fuel is dropped on the ground if the upgrade is removed or the robot is broken. | `oc/server/component/UpgradeGenerator.scala:48-103, 177-197, 207-222`; `oc/common/tileentity/traits/Computer.scala:105-123`; `conf` `generatorEfficiency` |
| **At zero energy the machine crashes ("no energy") and stays off.** Nothing restarts it; a player must turn it back on. | `oc/server/machine/Machine.scala:208-211, 530-535` |
| Action delays: move/turn/swing/place 0.4 s, drop 0.5 s; swing also waits the block's break time | `conf` `robot.delays` (about lines 442-474) |
| `limitFlightHeight: 8`: a robot may be at most 8 above a block, unless next to a solid face ("climbing"); moving down is always allowed; a move is allowed if the start **or** target is valid | `conf` about lines 308-323 |
| Lua 5.3 is the default architecture: 64-bit integers, native bitwise operators | `conf` `enableLua53`, `defaultLua53` (about line 228) |
| RAM levels 192/256/384/512/768/1024 KB; a program is killed after **5 s without yielding**; filesystem reads return at most **2048 bytes** per call; `/tmp` is only **64 KB** | `conf` `ramSizes`, `computer.timeout`, `maxReadBuffer`, `tmpSize` |
| Internet: HTTP enabled by default. Filter rules are checked top to bottom, **first match wins**, and no match = denied. Defaults: `deny private`, `deny bogon`, `allow default`. `requestTimeout: 0` = never times out. | `conf` `internet` section; `oc/server/component/InternetCard.scala:373-391` |
| Wireless: packets at most 8192 bytes; T2 card range up to 400 | `conf` `maxNetworkPacketSize`, `maxWirelessRange` |
| Clipboard paste: client refuses pastes over **64 KB** and adds a cooldown of `length/10` ms; the server turns **each line into one `clipboard` signal**; the signal queue holds **256** and silently drops overflow. `maxClipboard` in the config is **not read** by this fork. The paste keybind defaults to **unbound**. | `oc/client/PacketSender.scala:73-90`; `oc/server/component/Keyboard.scala:90-99`; `oc/server/machine/Machine.scala:334`; `oc/client/KeyBindings.scala:47` |
| `filesystem.bufferChanges: true`: disk contents are held in memory and written out when the world saves, so disks and world state stay consistent after a crash | `conf` about lines 887-895; `oc/server/fs/Buffered.scala` |
| Chunkloader API: `isActive()`, `setActive(bool)` | `oc/server/component/UpgradeChunkloader.scala` |
| OpenOS ships `wget` (writes files in `"wb"` mode) and `pastebin` | `.../loot/openos/bin/wget.lua` |
| `.schematic` format: gzip NBT, index `x + (y*L + z)*W`; `AddBlocks`/`Add` variants; `SchematicaMapping` = block name -> id (block IDs are instance-specific in GTNH) | `Schematica/.../SchematicAlpha.java:35-139`; `Names.java:223-244` |

## 5. Plan format

A proposed layout. You may refine it, but keep: magic + format version, `planVersion`, dimensions, a CRC over the body, per-layer offsets (for seeking and resume), item name + damage in the palette. Bump `formatVersion` on any change, and keep the JS and Lua readers in lockstep with golden-file tests.

```
All integers little-endian.
off  size  field
0    4     magic "OCBP"
4    1     formatVersion = 1
5    1     flags = 0 (reserved)
6    2     W (x)
8    2     H (y)
10   2     L (z)
12   4     planVersion (u32; default = unix seconds at conversion; shown to the user so a stale
           download is obvious)
16   4     fileLength (total bytes)
20   4     crc32 (IEEE) of bytes [24, fileLength)
24   1+n   name (u8 length + UTF-8 bytes)
     2     paletteCount P (not counting the two reserved indices)
     ...   P entries for palette indices 2 .. P+1:
             u8   flags       bit0 = orientation-bearing (use fuzzy compare)
                              bit1 = had tile-entity data (report only)
             u8+n itemName    (what to pull from the ender chest)
             u16  itemDamage
             u8+n blockName   (reports/debugging)
             u8   blockMeta
     4*H   absolute file offset of each layer's data
     ...   layer data: run-length encoding of the layer's W*L cells in order x fastest, then z;
           a sequence of (varint runLength, varint paletteIndex) pairs, unsigned LEB128.
           A layer ends at the next layer's offset (or fileLength).
Reserved palette indices: 0 = AIR (the cell must end up empty), 1 = SKIP (never broken as a build
cell, never placed).
```

## 6. Converter (Node)

`node converter/schem2plan.js <input.schematic> [options]` and `node converter/schem2plan.js inspect <file.plan> [--layer n]`.

Options:
- `--out <dir>` (default: next to the input), `--name <name>` (default: input basename), `--version <n>` (default: unix time).
- `--rotate 0|90|180|270`: rotate about Y. Geometry only; metadata is not rotated in v1 (say so in the report).
- `--ignore <block>[,...]`: those blocks become SKIP.
- `--clear <block>[,...]`: those blocks become AIR (dig out, never place). For terrain the user doesn't want to stock.
- `--itempanel <csv>`: default `D:\Coding\LitematicaSchematicaConverter\LitematicaToSchematic\itempanel.csv`.
- `--itemmap <json>`: overrides keyed by `block` or `block@meta` -> `{ "item": ..., "damage": ... }` | `"skip"` | `"air"`.
- `--paste`: also write a paste pack (section 8).

**Parsing.** Gzip NBT, root compound `Schematic`. `Width`/`Height`/`Length` shorts; `Blocks`/`Data` byte arrays. High bits of the block ID, mirroring Schematica's reader exactly (`SchematicAlpha.java:89-139` and `:39-72`):
- `AddBlocks` with length `ceil(V/2)`: MCEdit nibble packing. Cell `2k` takes the high nibble of byte `k`, cell `2k+1` the low nibble; `id = blocks | extra << 8`.
- `AddBlocks` with length `V`: GTNH "schematicplus" variant, one byte per cell; `id = blocks | extra * 256`.
- `Add`: Schematica variant, one byte per cell; `id = blocks | extra << 8`.
- Choose the variant by array length, not by guessing.

`SchematicaMapping` (name -> short ID) is how names are recovered; invert it. The user's own converter writes it, so it is the normal case. If it's missing, either fall back to `itempanel.csv` `Item ID` -> name with a loud warning (IDs are per-instance), or fail with a clear message. Never guess silently. `TileEntities`: list id and coordinates in the report (their contents are not restored). `Entities`: count them in the report and ignore them.

**Block -> item mapping**, first match wins:
1. `--itemmap` override.
2. A built-in table for blocks whose item differs or which can't be placed: fluids, fire, portals, crops, piston heads, sign blocks, the upper halves of doors and heads of beds (skip those; place only the lower/foot half), `redstone_wire` -> `redstone`, lit furnace -> furnace, lit lamp -> lamp, lit/unlit redstone torch -> redstone torch, double slabs (skip + report in v1), and so on. Build it from Schematica's `BlockToItemStack.java` and `SchematicPrinter.isBlacklisted`.
3. `(blockName, meta)` exists in `itempanel.csv` -> use it.
4. Otherwise the first of `(blockName, meta & 7)`, `(blockName, meta & 3)`, `(blockName, 0)` that exists. When the chosen damage differs from the meta, set the orientation-bearing flag.
5. Otherwise: unmapped -> SKIP, listed in the report.

Air -> AIR.

**Outputs.**
- `<name>.plan`.
- `<name>.manifest.txt`: for each item, display name (from `itempanel.csv`), item name, damage, count, and stacks. Also an estimated **fuel** line (coal count). This is what the user loads into the ender chest.
- `<name>.report.txt`: dimensions; cell counts; unmapped/skipped blocks with counts and sample coordinates; orientation-bearing blocks with counts; tile entities with coordinates; estimated moves, energy, **fuel** and **build time** using the numbers in section 4 and 7.6 (with one generator, roughly 1.1-1.4 s per cell on average including pauses to regenerate; a 32x32x16 build is about 5-6 hours). Tell the user how long it will take.
- With `--paste`: `<name>.paste/part-NNN.txt`.

**Constraints.** Node >= 14, no npm dependencies (built-in `zlib`). Implement CRC32 in JS (Node's `zlib.crc32` is too new). Structure the encoder and decoder as importable modules for tests.

## 7. Robot builder

### 7.1 Startup

`build <plan> [--resume | --restart] [--dry-run] [--yes]`.
- Load config; validate the plan (magic, format version, CRC).
- Print a capability report; refuse to run without the required components (section 3). An unbreakable tool counts as a tool.
- `chunkloader.setActive(true)` if present. Open the modem port if a modem is present.
- If a state file exists for the same plan name + `planVersion` + CRC, resume. If it's for a different plan, refuse unless `--restart`.
- On a fresh start (not a resume), take the **stock snapshot** (7.4) at the first cell, print the stock report, and ask for confirmation before building anything. `--yes` skips the prompt; an automatic resume never prompts.
- `--dry-run`: print the header, a manifest decoded from the plan, and estimates (time, energy, fuel); do not move. It can't see inside the ender chest, so it compares only the robot's own inventory against the manifest.

### 7.2 Cell order

- Layers `y = 0 .. H-1`. For layer `y` the robot travels at height `y+1` and works the cell directly below it.
- Serpentine within a layer: rows run along X and step along Z, alternating row direction. Alternate the Z direction and the starting corner between layers so the robot never flies back empty.
- This must be a **pure function** `(layer, index) -> (x, z, facing)`, so resume can rebuild the robot's pose from state.
- First moves: from `(0,0,0)`, clear above, move up to `(0,1,0)`, facing +X, and begin layer 0 with cell `(0,0,0)` below.

### 7.3 Per cell

The robot is at `(x, y+1, z)`; the target is `T = (x, y, z)` with palette entry `p`.

- **Before any forward or up move:** clear the destination (swing until `detect` reports it clear, with bounded retries, because sand and gravel refill). Move. If the move fails because of an entity, wait and retry, then pause and alert.
- `p == SKIP`: do nothing.
- `p == AIR`: if something solid is below, `swingDown` (bounded retries). Liquids can't be swung; log them and continue.
- `p` is a block:
  - If the item is **not in the stock snapshot** (7.4), skip the cell: clear whatever is there (leave air, so the user can place the block by hand later), log it to `manual.txt` with the reason "not stocked", and move on.
  - Otherwise select its material slot (restock first if there is none, 7.4). If `compareDown` (with `fuzzy` = the orientation-bearing flag) matches, keep the existing block. Otherwise clear anything below, then `placeDown`. If placing fails, add `T` to the deferred list.
- **End of layer:** revisit the deferred cells (shortest path through the travel layer) and retry once or twice. Whatever still fails goes to `manual.txt` with coordinates relative to the start, the block name, and the reason ("could not place"). Cells can't be revisited after the robot moves up: the next layer buries them, and travel is always from above.
- **Metadata is not controlled (user decision).** Accept whatever orientation placement produces. Don't verify it.

### 7.4 Restock from the ender chest

It has to be placed because it can't be read from inventory (section 4).

- **When:** when the next needed material isn't in inventory, when the fuel reserve is low (7.6), and proactively at the start of each layer. Look ahead along the path, accumulating item -> count for upcoming cells until the distinct items would exceed the free material slots or the counts exceed their capacity (stack size from `getStackInSlot(...).maxSize`).
- **Where:** at a cell whose target `T` has already been cleared.
- **Procedure:**
  1. Select the chest's slot, `placeDown`.
  2. `getInventorySize(down)`; scan with `getStackInSlot(down, i)` to map (name, damage) -> chest slots.
  3. For each need: select an empty or matching material slot, then `suckFromSlot(down, chestSlot, count)`.
  4. Top the robot's fuel reserve up to the configured amount (7.6).
  5. `swingDown` to recover the chest.
  6. Find the chest in inventory **by name**; never assume which slot it returned to. **If it isn't there, halt**: save state, broadcast the error, stop. Never continue without the chest.
- Keep a free slot for the chest to come back into. Collection uses normal inventory insertion; if the inventory is full, the chest lands on the ground.
- Record in the state file that the chest is placed at `T`, so a crash mid-cycle recovers it on resume.

**Stock snapshot: what gets waited for vs. skipped (user decision).** The user fills the chest before the build. Every item type present at the start will keep being restocked, and no other types will show up. So:
- At the start of a fresh build, after moving up to `(0,1,0)`, place the chest into the cell just vacated, `(0,0,0)`, scan it, and scan the robot's inventory. The union of item types (name + damage, so white and red wool are different types) is the **stock snapshot**. Save it in the state file.
- **Item in the snapshot:** it will be restocked. Use what's there; when it runs out, **wait** for more, however long it takes (below).
- **Item not in the snapshot:** its cells are **skipped for the whole build** and never waited for, even if the item turns up later (7.3).
- Before building, print the stock report: for each schematic item, either "stocked" (with counts in the chest and in the robot) or "will be skipped" (with its cell count), then ask for confirmation (7.1). Call out types found **only in the robot's inventory** and not in the chest: the robot will wait for those to be restocked too, and stray leftovers in the robot are the likely cause.
- **Never re-take the snapshot on resume.** A stocked item that happens to be empty when the robot resumes must still be waited for. Only `--restart` takes a new snapshot.
- The fuel item must be in the snapshot; refuse to start otherwise. If the fuel item is also a building material, fill the fuel reserve (7.6) before counting the rest as material.
- Voiding (7.5) keeps every snapshot type.

**Waiting (user decision: no time limit).** The user restocks by hand and it can take a while:
- While waiting, **leave the chest placed** instead of placing and breaking it repeatedly. Rescan it every `restockRetrySeconds` (default 60), sleeping in between, and print and broadcast the shortfall (state `waiting-materials`). Keep feeding the generator from the chest's fuel while waiting (7.6). When the stock arrives, pull it, recover the chest, and continue.
- Sleeping is cheap (0.5/s), so long waits are affordable: a full 60,000 buffer lasts about 33 hours of waiting with no fuel at all, and indefinitely if the chest has coal.

### 7.5 Voiding junk (user decision)

- **Keep:** the ender chest, current materials, fuel, tools (configured names), and `keepItems` (config, default empty). **Drop everything else.**
- **When:** when free slots drop below a threshold (default 2) and before each restock. Not after every block: each `drop` costs 0.5 s.
- **Where:** toward the cell the robot just came from (`back`), which is known to be air. **Never toward an inventory**, because `drop` inserts into inventories and would dump junk into the placed ender chest.
- Mined items identical to a current material (same name and damage) may stack into it. That's fine.
- If a sweep is missed, the inventory fills and further drops stay on the ground and despawn. Safe, just wasteful.

### 7.6 Energy (generator only, no charger)

The only energy source is the Generator Upgrade(s) burning fuel from the ender chest. Numbers from section 4: each generator makes 16/s while burning; the robot costs 5/s awake and 0.5/s asleep; a move costs 15.

- **Feed one fuel item at a time.** Queued fuel burns even when the buffer is full, so only `insert` when the generator's queue is empty **and** the headroom (`computer.maxEnergy() - computer.energy()`) is at least that item's energy. Learn each fuel item's energy by measuring (or config: `fuelItems` with priorities; coal = 1280). With several generators, feed each one.
- **Fuel reserve:** keep `fuelReserve` items (config, default 16 coal) in the robot's inventory, topped up at every restock, so it can keep feeding the generator between restocks.
- **Work/rest cycle:** one generator can't keep up with continuous work (a move-heavy stretch of empty cells drains about 20/s net). When energy falls below `restBelow` (default 30%), stop and sleep with the generator fed until energy reaches `resumeAbove` (default 90%). Sleep in long intervals so the sleeping rate applies. Measure the real cost per cell from `computer.energy()` deltas; don't hardcode it. Expect about 1.1-1.4 s per cell on average with one generator; a second generator removes most of the resting.
- **Never reach zero.** At zero energy the robot crashes and stays off until a player turns it on. If no fuel is available anywhere (inventory reserve, generator queue, chest), place the chest (if not already placed), save state, broadcast `waiting-fuel`, and sleep, rescanning the chest for fuel every `restockRetrySeconds`. If energy still falls below `shutdownBelow` (default 5%), save state, broadcast a final message telling the user to add fuel and restart the robot, and `computer.shutdown()` cleanly. The state file lets `build --resume` continue.
- Without docking, the robot stays within 1-2 blocks of the layer below, so the 8-block flight limit shouldn't bind. Sparse builds (isolated pillars) can still strand it over a gap; detect failed moves and report them.

### 7.7 Tools

The user's pickaxe cannot be damaged: `robot.durability()` returns `nil, "tool cannot be damaged"`, so **skip all durability handling** in that case. Keep a simple path for damageable tools anyway: check every N cells, and below a threshold equip a spare from inventory (`inventory_controller.equip()` swaps the selected slot with the tool slot); pause and alert if there's none. Swings can still fail because the tool can't harvest a block (obsidian, some GT blocks): log it, and if it blocks travel, pause and alert.

### 7.8 Failures

- Bedrock, unbreakable, or protected blocks: as a build cell, log and skip; as a travel cell, pause and alert (no pathfinding around obstacles in v1).
- Entities in the way: retry, then pause and alert.
- Every pause broadcasts its state and reason, and resumes on command or a retry timer.

### 7.9 State and resume

- One state file, rewritten atomically (write a temp file, then rename) after every cell and every phase change. Contents: plan name/version/CRC, layer, cell index, position, facing, phase (building / restocking / waiting-materials / waiting-fuel / resting / voiding / deferred pass), the deferred list with reasons, the stock snapshot, whether the chest is placed and where, the material slot map, counters.
- **Keep `bufferChanges = true`** (the default). Disks are saved together with the world, so after a crash the state file and the robot's position roll back to the same save point. It also makes frequent writes cheap: they stay in memory until the world saves.
- OC may persist the running Lua state across restarts. If the robot cold-boots instead (including after a player restarts it following an out-of-fuel shutdown), the program must start automatically and resume. Check how OpenOS auto-starts programs in `loot/openos` (for example `/home/.shrc` or `rc.d`) and document it.
- On resume: rebuild the pose from state; if the chest was placed, recover it first (or keep using it if the robot was waiting). Also provide `build --resync x y z facing` so the user can correct the pose by hand.

### 7.10 Status and control over wireless

- Broadcast on a configured port every N seconds and on state changes. The payload is a serialized table under 8 KB: plan, version, layer/H, cell/total, percent, state (building / restocking / resting / waiting-materials / waiting-fuel / done / error), energy percent, fuel in reserve, shortfall list, skipped-item list, last error, deferred count. While sleeping, broadcast less often; each wake-up costs the awake rate.
- Commands: `pause`, `resume`, `stop` (finish the current cell, save state, halt), `status`. Accept them only from the configured `controlAddress`: modem messages are unauthenticated, so anyone on the port could send them.
- Set the modem strength only as high as needed (config; up to 400 for T2).

### 7.11 Config and resources

- `/etc/builder.cfg` (a Lua table) holds every tunable above, with sensible defaults.
- Stream the plan: seek to layer offsets, never load the whole file. Decode one layer into a **compact byte string** (1 byte per cell if there are at most 254 palette entries, else 2), not a Lua table of numbers; a 256x256 layer as a table would be about 1 MB.
- Loop reads (at most 2048 bytes per call). Yield (`os.sleep(0)`) during long decoding to stay under the 5 s timeout.
- Support W and L up to 256 and H up to 256.

## 8. Plan delivery (settled: Internet Card + wget, with paste as the fallback)

Getting the file onto the robot with the Internet Card needs **nothing set up on the server host**: the robot downloads it from a public URL (usually GitHub raw or a gist), which the default filter rules allow.

**`getplan <url> [name]`**
- Use `component.internet` with its own deadline (the server default `requestTimeout` is 0 = never).
- Download to `/plans/.partial` (**not** `/tmp`, which is only 64 KB), validate magic/version/length/CRC, then rename to `/plans/<name>.plan`.
- Print name, `planVersion` (also as a date), dimensions, palette size, and "CRC OK".
- Warn that `raw.githubusercontent.com` caches files for about 5 minutes, so right after a push you can get the old version; recommend commit-SHA URLs. `planVersion` is how the user spots a stale download.
- Private repos don't work (raw URLs need an auth token); a secret gist does.

**`recv <name>`: paste receiver**
- Paste pack format (written by the converter): the plan base64-encoded, 240 characters per line, split into parts of **at most 250 lines** (about 60 KB, under both the 64 KB client cap and the 256-signal queue, which also holds the key events from pressing paste). Each part starts with a header line: `#OCBP-PART <i>/<n> lines=<k> crc=<crc32 of this part's decoded bytes, hex> ver=<planVersion>`.
- The receiver pulls `clipboard` signals (`"clipboard", keyboardAddress, text, [playerName]`), strips line endings, and collects `k` data lines after each header. It decodes base64 in pure Lua (no Data Card needed), checks the part CRC, appends to a partial file, and prints `part i/n OK - paste the next part`. Reject duplicate or out-of-order parts with a clear message. After part `n`, validate the whole file using the plan header's CRC, then move it into `/plans/`.
- The README must tell the user to bind the paste key (Controls -> OpenComputers; unbound by default in this fork) and to wait out the cooldown (about 6 s after a full part) between parts.

**`install <baseUrl>`**: fetch a file list and every robot file from a base URL (the same GitHub repo), with the same validation. Used for first install and for updates.

## 9. Server config recommendations (the user owns the server)

- `internet.requestTimeout = 30`, so a dead URL fails instead of hanging.
- Keep `filesystem.bufferChanges = true` (see 7.9).
- Optional: `robot.limitFlightHeight = -1` if the robot strands over gaps in sparse builds.
- Optional: raise `computer.maxSignalQueueSize`. Not needed with 250-line parts.
- OC's chunkloader must be allowed on the server.

## 10. Testing and acceptance

- **Converter:** decode `tree5.schematic` and `tree5_out.schematic`; verify decoded cells against an independent read of the NBT; produce golden `.plan` files. Test each `AddBlocks`/`Add` variant with synthetic inputs, plus rotation and `--ignore`/`--clear`.
- **Lua libraries:** run under Lua 5.3 on the PC. Check whether `lua5.3`/`lua` is installed; if not, use `fengari` from npm **in tests only**. Test the plan reader, varint, CRC32 and base64 against golden outputs from the JS side.
- **Mock world:** implement fake `robot`/`component` APIs with an inventory (slots, stack sizes), an unbreakable tool (and a damageable one), a voxel world with terrain (including falling gravel), an ender-chest inventory that can be restocked on a timer mid-run, the generator model from section 4 (queued fuel burns regardless of buffer; 0.8/tick per generator), awake/sleeping costs, the zero-energy crash, the flight-limit rule, and the drop/collect semantics. Run the real build loop against it and assert:
  - the final world equals the schematic (ignoring metadata), and SKIP cells are untouched;
  - inventory never exceeds capacity; the chest is recovered every cycle; junk gets voided;
  - items in the stock snapshot are waited for through a long restock delay and the build then finishes; items not in the snapshot are skipped (cells cleared and logged) even if they appear later; resuming while a stocked item is empty still waits for it;
  - energy never reaches zero while fuel is available, and a long wait with no materials doesn't exhaust it;
  - resuming from state at random interruption points (including while the chest is placed or the robot is waiting) gives the same result.
- **Paste:** split a plan into parts and feed them as simulated clipboard signals; assert reassembly. Corrupt a line and assert the CRC rejects it.
- **Acceptance:** all of the above pass, and the README takes the user from assembling the robot to finishing a first small build.

## 11. Things only the user can check in game

Put these in the README as a checklist; `selftest` should cover what it can.

1. Breaking the Advanced Ender Chest with the robot's tool returns the chest itself (a vanilla ender chest drops obsidian without silk touch). Also: its slot count, and that the robot's fake player can open it on a global frequency. `selftest` does place -> scan -> break -> verify.
2. The generator accepts the stocked fuel: `selftest` pulls one fuel item from the chest, inserts it, and confirms energy rises.
3. `robot.durability()` on the user's pickaxe reports "tool cannot be damaged".
4. The paste key is bound.
5. Item entities on the ground don't block robot movement.
6. The server can reach the internet: `wget` a small file.

The README should also warn: breaking or picking up the robot drops any fuel still queued in the generator.

## 12. Out of scope (future phases; document only)

- A geolyzer survey that skips terrain which is already correct. Designed in discussion: 64-tall column scans with `geolyzer.scan(x, z)`; air reads exactly 0.0; reachability via bit-packed raster sweeps; identity checks only on air-exposed cells. Not in v1.
- Orientation/metadata control (Schematica's `PlacementRegistry`).
- Sending plans over wireless.
- Multiple robots; pathfinding around obstacles.
- Restoring tile-entity contents.

## 13. Don'ts

- Don't parse `.schematic` on the robot: it's gzip, the Data Card's `inflate` is zlib-wrapped, and RAM is tight.
- Don't use `suckFromItemInventory` on the ender chest.
- Don't source placement materials from mined drops.
- Don't drop items toward an inventory.
- Don't load more than one fuel item into a generator at a time; queued fuel burns even at a full buffer.
- Don't let energy reach zero; the robot can't restart itself.
- Don't treat `nil` from `robot.durability()` as "no tool"; check the message.
- Don't hardcode energy or delay numbers you can measure; the server's config may differ from the defaults.
- Don't assume which slot an item landed in after auto-collection; find it by name.
- Don't initialize git or commit without asking the user.
