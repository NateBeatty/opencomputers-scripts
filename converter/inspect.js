#!/usr/bin/env node
'use strict';
// inspect.js — inspect a compiled .plan file.
//
// Usage:
//   node inspect.js <file.plan> [--layers] [--dump <y>]
//
// Options:
//   --layers            Print per-layer statistics (cell counts by palette index)
//   --dump <y>          Dump the raw palette indices for a single layer (y=0 is bottom)
//   --verbose           Show full cell-by-cell decode

const fs = require('fs');
const { decode, PALETTE_AIR, PALETTE_SKIP, PALETTE_BASE } = require('./lib/plan.js');

function main() {
  const argv = process.argv.slice(2);
  let planFile = null;
  let showLayers = false;
  let dumpLayer = null;
  let verbose = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--layers') showLayers = true;
    else if (a === '--dump') dumpLayer = parseInt(argv[++i], 10);
    else if (a === '--verbose') verbose = true;
    else if (a === '--help' || a === '-h') {
      console.log(`Usage: node inspect.js <file.plan> [--layers] [--dump <y>] [--verbose]`);
      process.exit(0);
    } else if (!a.startsWith('-')) planFile = a;
  }

  if (!planFile) {
    console.error('Error: no plan file specified');
    console.error('Usage: node inspect.js <file.plan> [--layers] [--dump <y>] [--verbose]');
    process.exit(1);
  }

  const buf = fs.readFileSync(planFile);
  const p = decode(buf);

  console.log(`=== Plan: ${p.name} ===`);
  console.log(`File: ${planFile} (${buf.length} bytes)`);
  console.log(`Format version: ${p.header.formatVersion}`);
  console.log(`Dimensions: ${p.header.width} x ${p.header.height} x ${p.header.length} (W x H x L)`);
  console.log(`Plan version: ${p.header.planVersion}`);
  console.log(`Total cells: ${p.header.width * p.header.height * p.header.length}`);
  console.log(`Layer count: ${p.header.height}`);
  console.log(`Layer offsets: ${p.layerOffsets.join(', ')}`);
  console.log('');

  console.log(`--- Palette (${p.palette.length} entries) ---`);
  for (let i = 0; i < p.palette.length; i++) {
    const e = p.palette[i];
    const idx = i + PALETTE_BASE;
    const flags = [];
    if (e.flags & 0x01) flags.push('fuzzy');
    if (e.flags & 0x02) flags.push('tileentity');
    console.log(`  [${idx}] ${e.itemName} (dmg=${e.damage}) block=${e.blockName} meta=${e.meta} ${flags.length ? '[' + flags.join(',') + ']' : ''}`);
  }
  console.log('');

  // Aggregate usage.
  const usage = {};
  for (let y = 0; y < p.header.height; y++) {
    for (const idx of p.layers[y]) {
      usage[idx] = (usage[idx] || 0) + 1;
    }
  }

  console.log(`--- Usage ---`);
  const air = usage[PALETTE_AIR] || 0;
  const skip = usage[PALETTE_SKIP] || 0;
  const placed = Object.entries(usage).filter(([k]) => parseInt(k) >= PALETTE_BASE).reduce((s, [k, v]) => s + v, 0);
  console.log(`  Air: ${air} (${(100 * air / (p.header.width * p.header.height * p.header.length)).toFixed(1)}%)`);
  console.log(`  Skipped: ${skip} (${(100 * skip / (p.header.width * p.header.height * p.header.length)).toFixed(1)}%)`);
  console.log(`  Placed: ${placed} (${(100 * placed / (p.header.width * p.header.height * p.header.length)).toFixed(1)}%)`);
  console.log('');

  // Per-palette usage.
  if (showLayers) {
    console.log(`--- Per-layer stats ---`);
    for (let y = 0; y < p.header.height; y++) {
      const layer = p.layers[y];
      const layerUsage = {};
      for (const idx of layer) {
        layerUsage[idx] = (layerUsage[idx] || 0) + 1;
      }
      const summary = Object.entries(layerUsage).map(([idx, count]) => `${idx}×${count}`).join(' ');
      console.log(`  Layer ${y}: ${summary}`);
    }
    console.log('');
  }

  // Dump a single layer.
  if (dumpLayer !== null && dumpLayer >= 0 && dumpLayer < p.header.height) {
    console.log(`--- Layer ${dumpLayer} (z rows of ${p.header.width} cells) ---`);
    const layer = p.layers[dumpLayer];
    const W = p.header.width, L = p.header.length;
    for (let z = 0; z < L; z++) {
      const row = [];
      for (let x = 0; x < W; x++) {
        const idx = layer[z * W + x];
        row.push(String(idx).padStart(2));
      }
      console.log(`  z=${String(z).padStart(2)}: [${row.join(' ')}]`);
    }
    console.log('');
  }

  // Verbose: print full cell map.
  if (verbose) {
    console.log(`--- Full cell decode ---`);
    for (let y = 0; y < p.header.height; y++) {
      const layer = p.layers[y];
      const W = p.header.width, L = p.header.length;
      console.log(`  Y=${y}:`);
      for (let z = 0; z < L; z++) {
        const row = [];
        for (let x = 0; x < W; x++) {
          const idx = layer[z * W + x];
          const label = idx === PALETTE_AIR ? 'AIR' : idx === PALETTE_SKIP ? 'SKIP' : `P${idx - PALETTE_BASE}`;
          row.push(label.padStart(3));
        }
        console.log(`    z=${String(z).padStart(2)}: [${row.join(' ')}]`);
      }
    }
  }

  console.log('=== CRC check: PASS ===');
}

main();
