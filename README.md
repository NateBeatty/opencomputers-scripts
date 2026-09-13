# OpenComputers Builder for GTNH 1.7.10

A system for building structures from `.schematic` files using an OpenComputers robot on GregTech: New Horizons (Minecraft 1.7.10).

## Overview

This project provides:
1. **Converter** (Node.js): Converts `.schematic` files to compact `.plan` files
2. **Robot programs** (Lua): `build.lua` runs the build loop on your OC robot
3. **Utilities**: `getplan.lua` (download), `recv.lua` (paste), `selftest.lua` (hardware check), `install.lua` (auto-update)

## Requirements

### Robot Components (Tier 3)

| Component | Required |
|-----------|----------|
| CPU T3 | Yes |
| RAM T3.5 x2 | Yes |
| HDD T3 + T2 | Yes |
| Inventory Controller | Yes |
| Generator T2+ | Yes |
| Wireless Network Card T2 | Optional (status monitoring) |
| Internet Card T2 | Optional (downloading plans) |
| Angel Upgrade T2 | Recommended |
| Chunkloader T3 | Recommended |
| Battery Upgrades T3 x3 | Recommended |

### Tool
- Any pickaxe with sufficient harvest level
- **Unbreakable** is preferred (reports "tool cannot be damaged")

### Ender Chest
- **Advanced Ender Chest** (EnderStorage) on a **global** frequency
- Must contain all build materials **and** fuel (coal)
- Must be in the robot's inventory before building

## Installation

### 1. Robot Assembly
1. Build a Tier 3 robot with the components above
2. Install a pickaxe in the tool slot
3. Place an Advanced Ender Chest in the inventory
4. Ensure the robot has enough fuel (coal) in the ender chest

### 2. Software Installation
The robot needs OpenOS and the builder software. There are two ways:

**Option A: Manual Installation**
1. Transfer the files from the `gtnh/builder/` folder to the robot's HDD
2. Place programs in `/home/bin`:
   - `build.lua`
   - `getplan.lua`
   - `recv.lua`
   - `selftest.lua`
   - `install.lua`
3. Place libraries in `/home/lib`:
   - `plan.lua`
   - `crc32.lua`
   - `base64.lua`
   - `varint.lua`

`/home/lib` is already on OpenOS' `package.path`, so `require("plan")` finds them
there. Use `/home/...` rather than `/bin` and `/lib`: those belong to OpenOS and
may be read-only depending on how it was installed.

Run the programs by path, for example `/home/bin/selftest.lua`.

**Option B: Auto-Install**
If you have an Internet Card and access to a URL serving the files:
```
/home/bin/install.lua https://raw.githubusercontent.com/NateBeatty/opencomputers-scripts/main/gtnh/builder
```

### 3. Verify Setup
Run the self-test to verify your robot is configured correctly:
```
selftest
```

The test checks:
- Required components (Inventory Controller, Generator, inventory size, tool)
- Optional components (Angel, Chunkloader, Modem, Internet)
- Tool durability (unbreakable preferred)
- Ender chest functionality (place, scan, break, recover)
- Fuel availability

## Workflow

### 1. Create the Plan
On your PC, convert the schematic:
```bash
node converter/schem2plan.js tree5.schematic
```

This creates:
- `tree5.plan` - The plan file
- `tree5.manifest.txt` - Material list for the ender chest
- `tree5.report.txt` - Build estimates and warnings

### 2. Upload the Plan
**Option A: Internet Download** (requires Internet Card)
```
/home/bin/getplan.lua https://raw.githubusercontent.com/NateBeatty/opencomputers-scripts/main/gtnh/plans/layer1.plan layer1
```

**Option B: Paste** (no Internet Card needed)

Convert with `--paste` to get `tree5.paste/part-001.txt`, `part-002.txt`, and so
on. On the robot:
```
recv tree5
```
Then, for each part in order: open it on your PC, copy the whole file, focus the
robot's screen, and press the OpenComputers paste key.

- Bind that key first: Controls → OpenComputers. **It is unbound by default.**
- Wait a few seconds between parts. The game enforces a cooldown of roughly one
  second per 10 KB pasted.
- Each part carries its own checksum, so a paste that drops lines is rejected and
  you can simply paste it again.

### 3. Start the Build

The builder runs in two stages, and saves progress through both:

1. **Excavate** — dig the whole box empty, from the top layer down to layer 0.
   Digging top-down means sand or gravel released by a dig always lands on a
   layer that still gets dug, so nothing ends up in finished work.
2. **Build** — fill the box layer by layer from the bottom.

To dig first, inspect the site, then build:
```
build /plans/tree5.plan --excavate-only
build /plans/tree5.plan
```
The first command digs the box and parks the robot back in its starting cell,
facing the same way. The second sees that excavation is done and goes straight
to the stock report and building. Leave the robot where it parked in between.

To do both in one go, run `build /plans/tree5.plan` on its own.

Options:
- `--excavate-only`: Dig the box, park in the starting cell, and stop
- `--skip-excavate`: The site is already clear; go straight to building
- `--restart`: Discard saved progress and start fresh (the robot must be back in its starting cell)
- `--dry-run`: Show what would be built, with time and fuel estimates, without moving
- `--yes`: Skip the confirmation prompt after the stock report

A restart after a crash or shutdown resumes automatically in whichever stage it
was in; no flag is needed.

### 4. Monitoring
While building, the robot broadcasts status every 10 seconds on port 65656:
- Plan name and version
- Current layer and cell
- Progress percentage
- Energy level
- Fuel remaining

## Start small

The robot visits **every cell of every layer**, so build time scales with the
whole bounding box, not with the number of blocks placed. At roughly 1.2 s per
cell with one generator:

| Build | Cells | Rough time | Rough fuel |
|-------|-------|-----------|-----------|
| 16 x 5 x 16 | 1,280 | ~25 min | ~20 coal |
| 32 x 9 x 32 | 9,216 | ~3 h | ~145 coal |
| 271 x 9 x 271 (`layer1.schematic`) | 660,969 | **~220 h** | **~10,300 coal** |

`<name>.report.txt` prints this estimate for any plan. Prove the setup on a small
plan in a throwaway area before committing to a large one.

## Site Setup

### Location
- Build on a **flat, cleared area**
- The robot stands at the **bottom-left corner** of the build footprint (cell 0,0,0)
- The robot never leaves the build volume

### Coordinates
```
Schematic axes: X = Width, Y = Height, Z = Length
Robot starts at (0,0,0) facing +X (East)

forward = +X, right = +Z, up = +Y
```

### Terrain
- The robot excavates everything in the build volume (y=0 to y=H)
- Terrain below layer 0 is untouched
- Liquids should be drained beforehand

## In-Game Checklist

Before starting a build:

- [ ] Robot is Tier 3 with required components
- [ ] Inventory Controller upgrade installed
- [ ] At least one Generator installed
- [ ] Unbreakable pickaxe equipped (or durability checked)
- [ ] Advanced Ender Chest in inventory (global frequency)
- [ ] Ender chest contains all materials from manifest
- [ ] Ender chest contains fuel (coal)
- [ ] `selftest` passes
- [ ] Build area is cleared and flat
- [ ] Plan file is on the robot (`getplan` or `recv`)

## Server Configuration

Recommended settings for `config/opencomputers/settings.conf`:

```conf
# Internet timeout (prevents hanging downloads)
internet.requestTimeout = 30

# Keep buffered filesystem (state persists correctly)
filesystem.bufferChanges = true

# Optional: Allow higher flight for sparse builds
# robot.limitFlightHeight = -1

# Optional: Raise signal queue (not needed with 250-line paste parts)
# computer.maxSignalQueueSize = 512
```

## Troubleshooting

### Energy Issues
- **Robot crashes at zero energy**: The robot cannot restart itself. Add fuel to the generator and turn it back on.
- **Running out of fuel**: Ensure the ender chest has coal. The robot feeds the generator automatically.

### Material Issues
- **Robot stuck waiting for materials**: Add materials to the ender chest. The robot rescans every 60 seconds.
- **Items skipped**: If an item is not in the stock snapshot at build start, cells are skipped. Run `selftest` to verify chest contents.

### Placement Issues
- **Blocks not placing**: Ensure the robot has the material. The robot waits for restocked items but skips unstocked ones.
- **Orientation wrong**: Metadata is not controlled in v1. Accept whatever orientation placement produces.

## Files Reference

| File | Location | Description |
|------|----------|-------------|
| `build.lua` | `/home/bin/build.lua` | Main builder program |
| `getplan.lua` | `/home/bin/getplan.lua` | Download plan from URL |
| `recv.lua` | `/home/bin/recv.lua` | Receive plan via paste |
| `selftest.lua` | `/home/bin/selftest.lua` | Hardware verification |
| `install.lua` | `/home/bin/install.lua` | Auto-install/update |
| `plan.lua` | `/home/lib/plan.lua` | Plan file reader |
| `crc32.lua` | `/home/lib/crc32.lua` | CRC-32 checksum |
| `base64.lua` | `/home/lib/base64.lua` | Base64 encode/decode |
| `varint.lua` | `/home/lib/varint.lua` | LEB128 varint encoding |

## Safety Notes

1. **Never let energy reach zero**: The robot crashes and cannot restart itself.
2. **Fuel queued in generator is dropped** if the robot is broken or fuel is removed.
3. **Resuming from state**: If the robot crashes, use `build plan --resume` to continue.
4. **Paste keybind**: The paste key is unbound by default. Bind it in Controls → OpenComputers.
