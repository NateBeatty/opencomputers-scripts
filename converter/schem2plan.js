#!/usr/bin/env node
'use strict';
// schem2plan.js — convert a 1.7.10 .schematic to an OC .plan file.
//
// Usage:
//   node schem2plan.js <input.schematic> [options]
//
// Options:
//   --out <path>              Output .plan path (default: <input base>.plan)
//   --name <name>             Human-readable name stored in the plan (default: input basename)
//   --version <u32>           planVersion (default: unix time of conversion)
//   --rotate <0|90|180|270>    Rotate around Y axis (clockwise, in degrees)
//   --ignore <name[,name]>    Force-skip these blocks (by unlocalized name)
//   --clear <name[,name]>     Force-clear (dig out) these blocks
//   --itempanel <csv>         Path to itempanel.csv for block→item lookup
//   --itemmap <json>          JSON override map: {"<name>:<meta>": {"item": "...", "damage": N}}
//   --paste                   Write a paste-pack directory (<name>.paste/part-NNN.txt)
//   --quiet                   Suppress progress output
//
// Outputs:
//   <name>.plan               The compiled plan file
//   <name>.manifest.txt       Machine-readable material manifest
//   <name>.report.txt         Human-readable build report

const fs = require('fs');
const path = require('path');
const { parseSchematic } = require('./lib/schematic.js');
const { encode, buildPalette, parseHeader, PALETTE_AIR, PALETTE_SKIP, PALETTE_BASE } = require('./lib/plan.js');
const { crc32 } = require('./lib/crc32.js');
const blockitem = require('./lib/blockitem.js');
const varint = require('./lib/varint.js');

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = {
    out: null, name: null, version: 0, rotate: 0,
    ignore: [], clear: [], itempanel: defaultItempanel(), itemmap: null,
    paste: false, quiet: false,
  };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case '--out': opts.out = next(); break;
      case '--name': opts.name = next(); break;
      case '--version': opts.version = parseInt(next(), 10) || 0; break;
      case '--rotate': {
        const r = parseInt(next(), 10);
        if (![0, 90, 180, 270].includes(r)) { console.error('Error: --rotate must be 0, 90, 180, or 270'); process.exit(1); }
        opts.rotate = r; break;
      }
      case '--ignore': opts.ignore = (next() || '').split(',').filter(Boolean); break;
      case '--clear': opts.clear = (next() || '').split(',').filter(Boolean); break;
      case '--itempanel': opts.itempanel = next(); break;
      case '--itemmap': opts.itemmap = next(); break;
      case '--paste': opts.paste = true; break;
      case '--quiet': opts.quiet = true; break;
      case '--help': case '-h':
        printHelp(); process.exit(0); break;
      default:
        if (a.startsWith('-')) { console.error(`Unknown option: ${a}`); process.exit(1); }
        positional.push(a);
    }
  }
  if (positional.length !== 1) {
    console.error('Usage: node schem2plan.js <input.schematic> [options]');
    printHelp();
    process.exit(1);
  }
  opts.input = positional[0];
  return opts;
}

function printHelp() {
  console.log(`
Options:
  --out <path>              Output .plan path
  --name <name>             Human-readable name in the plan
  --version <u32>           planVersion timestamp
  --rotate <0|90|180|270>    Rotate around Y axis
  --ignore <names>          Force-skip blocks (comma-separated unlocalized names)
  --clear <names>           Force-clear (dig out) blocks
  --itempanel <csv>         itempanel.csv for block→item lookup
  --itemmap <json>          JSON override map
  --paste                   Write a paste-pack directory
  --quiet                   Suppress progress output
`);
}

// ---------------------------------------------------------------------------
// Itempanel CSV loading
// ---------------------------------------------------------------------------

/**
 * Parse itempanel.csv into a lookup: "itemId,meta" -> {itemName, damage}
 * itemName is the OC item name (namespace stripped).
 */
function loadItempanel(csvPath) {
  const text = fs.readFileSync(csvPath, 'utf8');
  const lines = text.split(/\r?\n/);
  const byName = new Map(); // "name,meta" -> {itemName, damage}
  const names = new Set();  // every item name present in the dump
  for (let i = 1; i < lines.length; i++) { // skip header
    const line = lines[i].trim();
    if (!line) continue;
    const parts = line.split(',');
    if (parts.length < 3) continue;
    // Keep the name FULLY NAMESPACED: OpenComputers reports a stack's `name`
    // as Item.itemRegistry.getNameForObject (ConverterItemStack.scala), i.e.
    // "minecraft:stone_slab". Stripping the namespace here would make every
    // plan item fail to match the ender chest's contents.
    const itemName = parts[0].trim();
    const itemMeta = parseInt(parts[2], 10);
    if (!itemName || Number.isNaN(itemMeta)) continue;
    names.add(itemName);
    byName.set(itemName + ',' + itemMeta, { itemName, damage: itemMeta });
  }
  return { byName, names, size: byName.size };
}

/** The NEI dump bundled with the converter, used unless --itempanel overrides it. */
function defaultItempanel() {
  const bundled = path.join(__dirname, 'test', 'itempanel.csv');
  return fs.existsSync(bundled) ? bundled : null;
}

// ---------------------------------------------------------------------------
// Block → plan cell resolver
// ---------------------------------------------------------------------------

/**
 * Resolve a single schematic cell to a plan action.
 *
 * @returns {{action:'place'|'air'|'skip', item?:string, damage?:number,
 *            blockName?:string, blockMeta?:number, fuzzy?:boolean, reason?:string}}
 */
function makeResolver({ itempanel, itemmap, ignore, clear }) {
  const ignoreSet = new Set(ignore);
  const clearSet = new Set(clear);

  return function resolveCell(name, id, meta) {
    // 1. --ignore / --clear overrides
    const key = name || ('id' + id);
    if (ignoreSet.has(key) || ignoreSet.has(id)) {
      return { action: 'skip', reason: '--ignore' };
    }
    if (clearSet.has(key) || clearSet.has(id)) {
      return { action: 'air', reason: '--clear' };
    }

    // 2. --itemmap override (exact meta match)
    if (itemmap) {
      const mapKey = (name || 'id' + id) + ':' + meta;
      const override = itemmap[mapKey];
      if (override && override.item) {
        return {
          action: 'place',
          item: override.item,
          damage: override.damage || 0,
          blockName: name || ('id' + id),
          blockMeta: meta,
          fuzzy: false,
          reason: '--itemmap',
        };
      }
    }

    // 3. Built-in blockitem.js resolution
    const built = blockitem.resolve(name, id);
    if (built.action === blockitem.ACTIONS.SKIP) {
      return { action: 'skip', reason: built.reason };
    }
    if (built.action === blockitem.ACTIONS.AIR) {
      return { action: 'air', reason: built.reason };
    }
    // Only use built-in PLACE for special mappings (redstone_wire→redstone, lit→unlit, etc.).
    // For the default case (reason='default'), fall through to itempanel for correct damage.
    if (built.action === blockitem.ACTIONS.PLACE && built.reason === 'builtin') {
      return {
        action: 'place',
        item: built.item,
        damage: built.damage,
        blockName: name || ('id' + id),
        blockMeta: meta,
        fuzzy: built.fuzzy,
        upper: built.upper,
        reason: built.reason,
      };
    }

    // 4. Item panel lookup by NAME + meta.
    //
    // Names are authoritative; block IDs are per-instance and collide across
    // mods (in this dump, ForgeMultipart's block id 474 is a Thaumcraft block),
    // so IDs are deliberately never used for this lookup.
    if (name) {
      // The dump lists only a subset of each item's variants (chisel:glass has
      // one row, minecraft:wool one), so a generic meta&7 / meta&3 / 0 chain
      // would silently map red wool to white. Only two lookups are trustworthy:
      // an exact (name, meta) row, and a family rule that knows the meta is
      // orientation rather than a variant selector.
      const family = blockitem.familyDamage(name, meta);

      if (itempanel) {
        const exact = itempanel.byName.get(name + ',' + meta);
        if (exact) {
          return {
            action: 'place', item: exact.itemName, damage: exact.damage,
            blockName: name, blockMeta: meta, fuzzy: false, reason: 'itempanel-exact',
          };
        }
        if (family !== null) {
          const fam = itempanel.byName.get(name + ',' + family);
          if (fam) {
            return {
              action: 'place', item: fam.itemName, damage: fam.damage,
              blockName: name, blockMeta: meta, fuzzy: true,
              reason: 'itempanel-family(' + family + ')',
            };
          }
        }
      }

      // Otherwise: the family rule if we have one, else the raw meta, which is
      // the right damage for variant blocks (chisel, Ztones, GT stones, wool).
      const damage = family !== null ? family : meta;
      return {
        action: 'place',
        item: name,
        damage,
        blockName: name,
        blockMeta: meta,
        fuzzy: damage !== meta,
        reason: family !== null ? 'family-rule' : (itempanel ? 'unverified' : 'no-itempanel'),
      };
    }

    // 5. No name (the block ID is missing from SchematicaMapping) → cannot place.
    return { action: 'skip', reason: 'unmapped' };
  };
}

// ---------------------------------------------------------------------------
// Rotation
// ---------------------------------------------------------------------------

/**
 * Rotate schematic cells around Y axis.
 * rotate = number of 90° clockwise turns (0, 1, 2, 3).
 *
 * For a cell at (x, y, z) in a W×H×L volume:
 *   90°:  (x,z) -> (z, W-1-x)
 *   180°: (x,z) -> (W-1-x, L-1-z)
 *   270°: (x,z) -> (L-1-z, x)
 */
function rotateCells(cells, W, H, L, rotate) {
  if (rotate === 0) return { cells, W, H, L };
  const turns = (rotate / 90) % 4;
  const newW = turns % 2 === 0 ? W : L;
  const newL = turns % 2 === 0 ? L : W;
  const newCells = new Array(W * H * L);

  for (let y = 0; y < H; y++) {
    for (let z = 0; z < L; z++) {
      for (let x = 0; x < W; x++) {
        const srcIdx = x + (y * L + z) * W;
        let nx = x, nz = z;
        switch (turns) {
          case 1: // 90°: (x,z) -> (L-1-z, x)  [z axis becomes x, x axis becomes z]
            nx = L - 1 - z; nz = x; break;
          case 2: // 180°: (x,z) -> (W-1-x, L-1-z)
            nx = W - 1 - x; nz = L - 1 - z; break;
          case 3: // 270°: (x,z) -> (z, W-1-x)
            nx = z; nz = W - 1 - x; break;
        }
        const dstIdx = nx + (y * newL + nz) * newW;
        newCells[dstIdx] = cells[srcIdx];
      }
    }
  }
  return { cells: newCells, W: newW, H, L: newL };
}

// ---------------------------------------------------------------------------
// Schematic → plan conversion
// ---------------------------------------------------------------------------

/**
 * Convert a parsed schematic + options into a plan file.
 * @returns {{plan:Uint8Array, palette:Array, manifest:Array, stats:object}}
 */
function convertSchematic(schematic, opts) {
  const resolve = makeResolver({
    itempanel: opts.itempanel,
    itemmap: opts.itemmap,
    ignore: opts.ignore,
    clear: opts.clear,
  });

  // Rotate if needed.
  let { cells, width: W, height: H, length: L } = schematic;
  if (opts.rotate !== 0) {
    const rotated = rotateCells(cells, W, H, L, opts.rotate);
    cells = rotated.cells; W = rotated.W; H = rotated.H; L = rotated.L;
  }

  // Determine addBlocks mapping (id → name) for cells that lack a name.
  const idToName = schematic.idToName || {};

  // Process all cells → determine actions and build the palette.
  const paletteItems = []; // {itemName, damage, blockName, meta, flags}
  const paletteIndex = new Map(); // "item|damage" -> index
  const stats = {
    total: cells.length, air: 0, skip: 0, place: 0,
    byBlock: {}, // "blockName:meta" -> {count, action, reason, id, name, meta}
  };

  // First pass: resolve each cell and build the palette.
  const cellActions = new Array(cells.length); // {paletteIdx, action, blockName, blockMeta}
  let paletteIdx = PALETTE_BASE;

  for (let i = 0; i < cells.length; i++) {
    const cell = cells[i];
    const name = cell.name || idToName[cell.id] || null;
    const res = resolve(name, cell.id, cell.meta);

    // Track stats.
    const blockKey = (name || 'id' + cell.id) + ':' + cell.meta;
    if (!stats.byBlock[blockKey]) {
      stats.byBlock[blockKey] = { count: 0, action: res.action, reason: res.reason, id: cell.id, name: name, meta: cell.meta };
    }
    stats.byBlock[blockKey].count++;

    if (res.action === 'air') {
      cellActions[i] = { paletteIdx: PALETTE_AIR };
      stats.air++;
    } else if (res.action === 'skip') {
      cellActions[i] = { paletteIdx: PALETTE_SKIP };
      stats.skip++;
    } else {
      // place
      const pKey = res.item + '|' + res.damage;
      if (!paletteIndex.has(pKey)) {
        const flags = res.fuzzy ? 0x01 : 0x00;
        paletteItems.push({
          itemName: res.item,
          damage: res.damage,
          blockName: res.blockName || (name || 'id' + cell.id),
          meta: res.blockMeta || cell.meta,
          flags,
        });
        paletteIndex.set(pKey, paletteIdx++);
      }
      cellActions[i] = { paletteIdx: paletteIndex.get(pKey) };
      stats.place++;
    }
  }

  // Build layers (x fastest, then z).
  const layers = [];
  for (let y = 0; y < H; y++) {
    const layer = new Array(W * L);
    for (let z = 0; z < L; z++) {
      for (let x = 0; x < W; x++) {
        const srcIdx = x + (y * L + z) * W;
        layer[z * W + x] = cellActions[srcIdx].paletteIdx;
      }
    }
    layers.push(layer);
  }

  // Compute manifest (sum of placed blocks by item).
  const manifest = {};
  for (const p of paletteItems) {
    const key = p.itemName + '|' + p.damage;
    if (!manifest[key]) {
      manifest[key] = { item: p.itemName, damage: p.damage, count: 0, blockName: p.blockName, meta: p.meta };
    }
  }
  // Count placed cells per palette item.
  for (let i = 0; i < cells.length; i++) {
    const act = cellActions[i];
    if (act.paletteIdx >= PALETTE_BASE) {
      const idx = act.paletteIdx - PALETTE_BASE;
      if (manifest[paletteItems[idx].itemName + '|' + paletteItems[idx].damage]) {
        manifest[paletteItems[idx].itemName + '|' + paletteItems[idx].damage].count++;
      }
    }
  }

  const planBytes = encode({
    width: W, height: H, length: L,
    name: opts.name || path.basename(opts.input, '.schematic'),
    planVersion: opts.version || Math.floor(Date.now() / 1000),
    layers, palette: paletteItems,
  });

  return { planBytes, palette: paletteItems, manifest, stats };
}

// ---------------------------------------------------------------------------
// Manifest & report writers
// ---------------------------------------------------------------------------

function writeManifest(manifestPath, manifest) {
  const lines = [];
  lines.push('# OC Plan Material Manifest');
  lines.push('# Format: item, damage, count, block, meta');
  const items = Object.values(manifest);
  items.sort((a, b) => a.item.localeCompare(b.item));
  for (const m of items) {
    lines.push(`${m.item},${m.damage},${m.count},${m.blockName},${m.meta}`);
  }
  lines.push(`# Total items: ${items.length}, total blocks: ${items.reduce((s, m) => s + m.count, 0)}`);
  fs.writeFileSync(manifestPath, lines.join('\n') + '\n');
}

function writeReport(reportPath, schematic, stats, paletteCount, opts) {
  const lines = [];
  const now = new Date().toISOString();
  lines.push(`# OC Schematic Conversion Report`);
  lines.push(`# Generated: ${now}`);
  lines.push(`# Input: ${opts.input}`);
  lines.push(`# Plan name: ${opts.name || path.basename(opts.input, '.schematic')}`);
  lines.push(`# Dimensions: ${schematic.width} x ${schematic.height} x ${schematic.length}`);
  lines.push(`# Rotation: ${opts.rotate} degrees`);
  lines.push('');

  lines.push('## Block summary');
  lines.push(`| Block | ID | Meta | Count | Action | Reason |`);
  lines.push(`|-------|-----|------|-------|--------|--------|`);
  const blocks = Object.entries(stats.byBlock).sort((a, b) => b[1].count - a[1].count);
  for (const [key, info] of blocks) {
    lines.push(`| ${key} | ${info.id} | ${info.meta} | ${info.count} | ${info.action} | ${info.reason} |`);
  }
  lines.push('');

  lines.push('## Totals');
  lines.push(`- Total cells: ${stats.total}`);
  lines.push(`- Air (cleared): ${stats.air}`);
  lines.push(`- Skipped: ${stats.skip}`);
  lines.push(`- Placed: ${stats.place}`);
  lines.push(`- Palette entries: ${paletteCount}`);

  // Build cost estimate. The robot visits every footprint cell on every layer,
  // and with one generator it averages roughly 1.2 s and 20 energy per cell
  // (brief sections 4 and 7.6).
  const visited = schematic.width * schematic.height * schematic.length;
  const seconds = visited * 1.2;
  const energy = visited * 20;
  const coal = Math.ceil(energy / 1280);
  lines.push('');
  lines.push('## Estimates (one generator, no charger)');
  lines.push(`- Cells the robot visits: ${visited}`);
  lines.push(`- Estimated time: ${(seconds / 3600).toFixed(1)} hours`);
  lines.push(`- Estimated energy: ${energy}`);
  lines.push(`- Estimated fuel: ~${coal} coal (~${Math.ceil(coal / 64)} stacks)`);

  const skipped = blocks.filter(([_, i]) => i.action === 'skip');
  if (skipped.length > 0) {
    lines.push('');
    lines.push('## Skipped blocks (not placeable)');
    for (const [key, info] of skipped) {
      lines.push(`- ${key} (${info.count}x) — ${info.reason}`);
    }
  }

  fs.writeFileSync(reportPath, lines.join('\n') + '\n');
}

// ---------------------------------------------------------------------------
// Paste-pack writer
// ---------------------------------------------------------------------------

/**
 * Write a paste-pack directory. Each part file contains a list of
 * (itemName, damage, count) entries separated by newlines.
 */
function writePastePack(dir, planBytes) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  // The paste path is bounded by the game, not by us: the client refuses any
  // paste over 64 KB, and the server turns each line into one signal against a
  // 256-deep queue that silently drops the overflow. 250 lines of 240 chars is
  // ~60 KB and leaves room for the key events of the paste itself. 240 is a
  // multiple of 4, so every part decodes as base64 on its own.
  const LINE_CHARS = 240;
  const LINES_PER_PART = 250;

  const planVersion = parseHeader(planBytes).planVersion;
  const b64 = Buffer.from(planBytes).toString('base64');

  const lines = [];
  for (let i = 0; i < b64.length; i += LINE_CHARS) {
    lines.push(b64.slice(i, i + LINE_CHARS));
  }

  const parts = Math.max(1, Math.ceil(lines.length / LINES_PER_PART));
  for (let p = 0; p < parts; p++) {
    const chunk = lines.slice(p * LINES_PER_PART, (p + 1) * LINES_PER_PART);
    const decoded = Buffer.from(chunk.join(''), 'base64');
    const crc = crc32(decoded).toString(16).padStart(8, '0');
    const header = `#OCBP-PART ${p + 1}/${parts} lines=${chunk.length} crc=${crc} ver=${planVersion}`;
    const fname = path.join(dir, `part-${String(p + 1).padStart(3, '0')}.txt`);
    fs.writeFileSync(fname, header + '\n' + chunk.join('\n') + '\n');
  }
  return parts;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (!opts.quiet) console.log(`Input: ${opts.input}`);

  // Load schematic.
  const raw = fs.readFileSync(opts.input);
  const schematic = parseSchematic(raw);
  if (!opts.quiet) console.log(`Schematic: ${schematic.width}x${schematic.height}x${schematic.length} (${schematic.cells.length} cells)`);

  // Load optional resources.
  let itempanel = null;
  if (opts.itempanel) {
    itempanel = loadItempanel(opts.itempanel);
    if (!opts.quiet) console.log(`Itempanel: ${itempanel.size} items loaded from ${opts.itempanel}`);
  }
  let itemmap = null;
  if (opts.itemmap) {
    itemmap = JSON.parse(fs.readFileSync(opts.itemmap, 'utf8'));
    if (!opts.quiet) console.log(`Itemmap: ${Object.keys(itemmap).length} overrides loaded`);
  }

  // Convert.
  const result = convertSchematic(schematic, { ...opts, itempanel, itemmap });
  if (!opts.quiet) console.log(`Palette: ${result.palette.length} entries, Placed: ${result.stats.place}, Skipped: ${result.stats.skip}, Air: ${result.stats.air}`);

  // Determine output paths.
  const outPath = opts.out || path.join(path.dirname(opts.input), path.basename(opts.input, '.schematic') + '.plan');
  const outDir = path.dirname(outPath);
  // Name the side files after the OUTPUT, so two conversions into one folder
  // do not overwrite each other's manifest and report.
  const baseName = path.basename(outPath, '.plan');
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });

  fs.writeFileSync(outPath, result.planBytes);
  if (!opts.quiet) console.log(`Plan written: ${outPath} (${result.planBytes.length} bytes)`);

  // Manifest & report.
  const manifestPath = path.join(outDir, baseName + '.manifest.txt');
  writeManifest(manifestPath, result.manifest);
  if (!opts.quiet) console.log(`Manifest: ${manifestPath}`);

  const reportPath = path.join(outDir, baseName + '.report.txt');
  writeReport(reportPath, schematic, result.stats, result.palette.length, opts);
  if (!opts.quiet) console.log(`Report: ${reportPath}`);

  // Paste pack.
  if (opts.paste) {
    const pasteDir = path.join(outDir, baseName + '.paste');
    const parts = writePastePack(pasteDir, result.planBytes);
    if (!opts.quiet) console.log(`Paste pack: ${pasteDir} (${parts} parts)`);
  }

  if (!opts.quiet) console.log('Done.');
}

main();
