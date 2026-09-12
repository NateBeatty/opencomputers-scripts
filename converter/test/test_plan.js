#!/usr/bin/env node
'use strict';
// test_plan.js — unit tests for the plan format and converter.

const assert = require('assert');
const { encode, decode, PALETTE_AIR, PALETTE_SKIP, PALETTE_BASE, FLAG_ORIENT, FLAG_TILEENTITY } = require('../lib/plan.js');
const varint = require('../lib/varint.js');
const { crc32 } = require('../lib/crc32.js');

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (e) {
    console.error(`  ✗ ${name}`);
    console.error(`    ${e.message}`);
    failed++;
  }
}

console.log('=== Plan Format Tests ===\n');

// --- Varint tests ---
console.log('Varint:');
test('encode/decode small values', () => {
  for (const v of [0, 1, 127, 128, 255, 256, 16383, 16384, 1000000]) {
    const encoded = varint.encode(v);
    const decoded = varint.decode(encoded, 0);
    assert.strictEqual(decoded.value, v, `value ${v}`);
    assert.strictEqual(decoded.length, encoded.length, `length ${v}`);
  }
});

test('varint round-trip', () => {
  const buf = [];
  for (const v of [42, 0, 65535, 123456]) {
    varint.append(buf, v);
  }
  let pos = 0;
  for (const v of [42, 0, 65535, 123456]) {
    const r = varint.decode(buf, pos);
    assert.strictEqual(r.value, v);
    pos += r.length;
  }
});

// --- CRC32 tests ---
console.log('\nCRC32:');
test('CRC32 known value', () => {
  // "123456789" → 0xCBF43926
  const data = Buffer.from('123456789', 'ascii');
  assert.strictEqual(crc32(data), 0xCBF43926);
});

// --- Plan encode/decode round-trip ---
console.log('\nPlan encode/decode:');

function makeTestPlan() {
  const W = 3, H = 2, L = 2;
  const layers = [];
  // Layer 0: air (0), skip (1), log (2)
  layers.push([PALETTE_AIR, PALETTE_SKIP, 2, 2, 2, 2]);
  // Layer 1: log (2), leaves (3), air (0)
  layers.push([2, 3, 0, 0, 0, 0]);
  const palette = [
    { itemName: 'log', damage: 1, blockName: 'log', meta: 1, flags: 0 },
    { itemName: 'leaves', damage: 0, blockName: 'leaves', meta: 0, flags: FLAG_ORIENT },
  ];
  return { W, H, L, layers, palette, name: 'test', version: 12345 };
}

test('encode/decode round-trip', () => {
  const t = makeTestPlan();
  const buf = encode({ width: t.W, height: t.H, length: t.L, name: t.name, planVersion: t.version, layers: t.layers, palette: t.palette });
  const p = decode(buf);
  assert.strictEqual(p.header.width, t.W);
  assert.strictEqual(p.header.height, t.H);
  assert.strictEqual(p.header.length, t.L);
  assert.strictEqual(p.name, t.name);
  assert.strictEqual(p.header.planVersion, t.version);
  assert.strictEqual(p.palette.length, t.palette.length);
  assert.strictEqual(p.layers.length, t.H);
  // Verify cell values.
  assert.deepStrictEqual(p.layers[0], t.layers[0]);
  assert.deepStrictEqual(p.layers[1], t.layers[1]);
});

test('palette entry round-trip', () => {
  const t = makeTestPlan();
  const buf = encode({ width: t.W, height: t.H, length: t.L, name: t.name, planVersion: t.version, layers: t.layers, palette: t.palette });
  const p = decode(buf);
  assert.strictEqual(p.palette[0].itemName, 'log');
  assert.strictEqual(p.palette[0].damage, 1);
  assert.strictEqual(p.palette[0].blockName, 'log');
  assert.strictEqual(p.palette[0].meta, 1);
  assert.strictEqual(p.palette[0].flags, 0);
  assert.strictEqual(p.palette[1].itemName, 'leaves');
  assert.strictEqual(p.palette[1].flags, FLAG_ORIENT);
});

test('CRC verification', () => {
  const t = makeTestPlan();
  const buf = encode({ width: t.W, height: t.H, length: t.L, name: t.name, planVersion: t.version, layers: t.layers, palette: t.palette });
  // Decode verifies CRC automatically.
  decode(buf);
  // Corrupt a byte and verify CRC fails.
  const corrupted = Buffer.from(buf);
  corrupted[25] ^= 0xFF;
  assert.throws(() => decode(corrupted), /CRC mismatch/);
});

test('empty plan (all air)', () => {
  const W = 4, H = 3, L = 4;
  const layers = [];
  for (let y = 0; y < H; y++) {
    layers.push(new Array(W * L).fill(PALETTE_AIR));
  }
  const buf = encode({ width: W, height: H, length: L, name: 'empty', planVersion: 0, layers, palette: [] });
  const p = decode(buf);
  assert.strictEqual(p.header.width, W);
  assert.strictEqual(p.header.height, H);
  assert.strictEqual(p.header.length, L);
  assert.strictEqual(p.palette.length, 0);
  assert.strictEqual(p.layers.length, H);
});

test('large palette indices (varint multi-byte)', () => {
  const W = 2, H = 1, L = 2;
  const palette = [];
  // Create 300 palette entries to force varint multi-byte indices.
  for (let i = 0; i < 300; i++) {
    palette.push({ itemName: 'item' + i, damage: i, blockName: 'block' + i, meta: i, flags: 0 });
  }
  const layers = [new Array(W * L).fill(100 + PALETTE_BASE)]; // palette index 102
  const buf = encode({ width: W, height: H, length: L, name: 'big', planVersion: 0, layers, palette });
  const p = decode(buf);
  assert.strictEqual(p.palette.length, 300);
  assert.strictEqual(p.layers[0][0], 100 + PALETTE_BASE);
  assert.strictEqual(p.palette[100].itemName, 'item100');
});

console.log(`\n=== ${passed} passed, ${failed} failed ===`);
process.exit(failed > 0 ? 1 : 0);
