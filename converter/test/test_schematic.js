#!/usr/bin/env node
'use strict';
// test_schematic.js — tests for the schematic parser's AddBlocks variants.

const assert = require('assert');
const zlib = require('zlib');
const nbt = require('../lib/nbt.js');
const { parseSchematic } = require('../lib/schematic.js');

let passed = 0;
let failed = 0;
function test(name, fn) {
  try { fn(); console.log(`  ✓ ${name}`); passed++; }
  catch (e) { console.error(`  ✗ ${name}: ${e.message}`); failed++; }
}

// Helper: build a minimal .schematic NBT.
function buildSchematic({ width, height, length, blocks, data, addBlocks, add, mapping }) {
  const sch = {
    Width: { type: 'short', value: width },
    Height: { type: 'short', value: height },
    Length: { type: 'short', value: length },
    Blocks: { type: 'byteArray', value: blocks },
    Data: { type: 'byteArray', value: data },
  };
  if (addBlocks !== undefined) sch.AddBlocks = { type: 'byteArray', value: addBlocks };
  if (add !== undefined) sch.Add = { type: 'byteArray', value: add };
  if (mapping) {
    const m = {};
    for (const [k, v] of Object.entries(mapping)) m[k] = { type: 'short', value: v };
    sch.SchematicaMapping = { type: 'compound', value: m };
  }
  const writer = new nbt.Writer();
  writer.byte(10); // compound type
  writer.string('Schematic'); // top-level name
  writer.compound({ Schematic: { type: 'compound', value: sch } });
  const raw = writer.getData();
  return zlib.gzipSync(Buffer.from(raw));
}

console.log('=== Schematic Variant Tests ===\n');

test('classic format (Blocks/Data only)', () => {
  const raw = buildSchematic({
    width: 2, height: 1, length: 1,
    blocks: [17, 18], data: [1, 2],
  });
  const s = parseSchematic(raw);
  assert.strictEqual(s.width, 2);
  assert.strictEqual(s.height, 1);
  assert.strictEqual(s.addBlocksVariant, 'none');
  assert.strictEqual(s.cells[0].id, 17);
  assert.strictEqual(s.cells[0].meta, 1);
});

test('AddBlocks nibble (MCEdit)', () => {
  // Nibble packing: high nibble = cell 2k, low nibble = cell 2k+1.
  // To get cells: [1, 2, 0, 3], bytes are: byte0=0x12 (high=1,low=2), byte1=0x03 (high=0,low=3).
  const raw = buildSchematic({
    width: 2, height: 1, length: 2,
    blocks: [0, 0, 0, 0], data: [0, 0, 0, 0],
    addBlocks: [0x12, 0x03],
  });
  const s = parseSchematic(raw);
  assert.strictEqual(s.addBlocksVariant, 'nibble');
  assert.strictEqual(s.cells[0].id, 0 | (1 << 8)); // high nibble of 0x12 = 1
  assert.strictEqual(s.cells[1].id, 0 | (2 << 8)); // low nibble of 0x12 = 2
  assert.strictEqual(s.cells[2].id, 0);            // high nibble of 0x03 = 0
  assert.strictEqual(s.cells[3].id, 0 | (3 << 8)); // low nibble of 0x03 = 3
});

test('AddBlocks schematicplus', () => {
  const raw = buildSchematic({
    width: 2, height: 1, length: 2,
    blocks: [0, 0, 0, 0], data: [0, 0, 0, 0],
    addBlocks: [5, 6, 7, 8],
  });
  const s = parseSchematic(raw);
  assert.strictEqual(s.addBlocksVariant, 'schematicplus');
  assert.strictEqual(s.cells[0].id, 0 | (5 * 256));
});

test('Add (Schematica)', () => {
  const raw = buildSchematic({
    width: 2, height: 1, length: 2,
    blocks: [0, 0, 0, 0], data: [0, 0, 0, 0],
    add: [10, 11, 12, 13],
  });
  const s = parseSchematic(raw);
  assert.strictEqual(s.addBlocksVariant, 'schematica');
  assert.strictEqual(s.cells[0].id, 0 | (10 << 8));
});

test('real file SchematicaMapping', () => {
  const fs = require('fs');
  const raw = fs.readFileSync(require('path').join(__dirname, 'tree5_out.schematic'));
  const s = parseSchematic(raw);
  assert.strictEqual(s.mapping['log'], 17);
  assert.strictEqual(s.idToName['17'], 'log');
});

test('synthetic SchematicaMapping', () => {
  const raw = buildSchematic({
    width: 2, height: 1, length: 1,
    blocks: [17, 18], data: [1, 2],
    mapping: { log: 17, leaves: 18 },
  });
  const s = parseSchematic(raw);
  assert.strictEqual(s.mapping['log'], 17);
  assert.strictEqual(s.cells[0].name, 'log');
});

console.log(`\n=== ${passed} passed, ${failed} failed ===`);
process.exit(failed > 0 ? 1 : 0);
