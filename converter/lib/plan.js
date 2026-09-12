'use strict';
// Plan format encoder (and reader for the inspector). See the brief section 5.
//
// Layout (little-endian):
//   off  size  field
//   0    4     magic "OCBP"
//   4    1     formatVersion = 1
//   5    1     flags = 0
//   6    2     W
//   8    2     H
//   10   2     L
//   12   4     planVersion (u32)
//   16   4     fileLength
//   20   4     crc32 of bytes [24, fileLength)
//   24   1+n   name (u8 len + UTF-8)
//          2   paletteCount P (indices 2..P+1)
//          ... P palette entries (each: u8 flags, u8+n itemName, u16 damage,
//                 u8+n blockName, u8 blockMeta)
//          4*H  layer byte offsets
//          ...  layer RLE data: (varint runLen, varint paletteIdx)*

const varint = require('./varint');
const { crc32, writeCrc32 } = require('./crc32');

const MAGIC = Buffer.from('OCBP', 'ascii');
const FORMAT_VERSION = 1;

// Reserved palette indices.
const PALETTE_AIR = 0;
const PALETTE_SKIP = 1;
const PALETTE_BASE = 2;

// Palette flags bits.
const FLAG_ORIENT = 0x01;  // bit0: orientation-bearing (use fuzzy compare)
const FLAG_TILEENTITY = 0x02; // bit1: had tile-entity data (report only)

/**
 * Encode a plan from schematic cells.
 *
 * @param {object} opts
 * @param {number} opts.width  W
 * @param {number} opts.height H
 * @param {number} opts.length L
 * @param {string} opts.name - human-readable name
 * @param {number} opts.planVersion - u32 timestamp/version
 * @param {number[][]} opts.layers - layers[y] is an array of length W*L of
 *        palette indices (0 = AIR, 1 = SKIP, >=2 = palette entry). x fastest, then z.
 * @param {Array<{itemName:string, damage:number, blockName:string, meta:number,
 *        flags:number}>} opts.palette - palette entries in order (indices 2..P+1)
 * @returns {Uint8Array} the full plan file bytes
 */
function encode({ width, height, length, name, planVersion, layers, palette }) {
  // --- Step 1: encode each layer's RLE data. ---
  const layerData = [];
  for (let y = 0; y < height; y++) {
    const cells = layers[y];
    const buf = [];
    let i = 0;
    while (i < cells.length) {
      const idx = cells[i];
      let run = 1;
      while (i + run < cells.length && cells[i + run] === idx && run < 0x7fffffff) {
        run++;
      }
      varint.append(buf, run);
      varint.append(buf, idx);
      i += run;
    }
    layerData.push(Buffer.from(buf));
  }

  // --- Step 2: compute palette entries and layer offsets. ---
  // Header is 24 bytes, then name, then palette count, then palette entries,
  // then 4*H layer offsets, then layer data.
  const nameBuf = Buffer.from(name, 'utf8');
  const paletteCount = palette.length;

  // Size of the fixed part before layer data.
  const headStart = 24;
  const nameSection = 1 + nameBuf.length;               // u8 len + bytes
  const paletteCountSize = 2;                            // u16
  let paletteBytes = 0;
  for (const p of palette) {
    paletteBytes += 1;                                   // flags
    paletteBytes += 1 + Buffer.byteLength(p.itemName, 'utf8');  // itemName
    paletteBytes += 2;                                  // damage u16
    paletteBytes += 1 + Buffer.byteLength(p.blockName, 'utf8'); // blockName
    paletteBytes += 1;                                  // blockMeta u8
  }
  const layerOffsetsSize = 4 * height;

  // Build the body starting at offset 24.
  const bodyStart = headStart;
  const layerDataStart = bodyStart + nameSection + paletteCountSize + paletteBytes + layerOffsetsSize;
  const offsets = [];
  let pos = layerDataStart;
  for (let y = 0; y < height; y++) {
    offsets.push(pos);
    pos += layerData[y].length;
  }
  const fileLength = pos;

  // --- Step 3: assemble. ---
  const out = Buffer.alloc(fileLength);
  let o = 0;
  MAGIC.copy(out, 0); o += 4;
  out.writeUInt8(FORMAT_VERSION, o); o += 1;
  out.writeUInt8(0, o); o += 1;  // flags
  out.writeUInt16LE(width, o); o += 2;
  out.writeUInt16LE(height, o); o += 2;
  out.writeUInt16LE(length, o); o += 2;
  out.writeUInt32LE(planVersion >>> 0, o); o += 4;
  out.writeUInt32LE(fileLength >>> 0, o); o += 4;
  // crc32 placeholder (filled below)
  const crcOffset = o; o += 4;

  // name
  out.writeUInt8(Math.min(nameBuf.length, 255), o); o += 1;
  nameBuf.copy(out, o); o += nameBuf.length;

  // palette count
  out.writeUInt16LE(paletteCount, o); o += 2;

  // palette entries
  for (const p of palette) {
    out.writeUInt8(p.flags, o); o += 1;
    const inB = Buffer.from(p.itemName, 'utf8');
    out.writeUInt8(Math.min(inB.length, 255), o); o += 1;
    inB.copy(out, o); o += inB.length;
    out.writeUInt16LE(p.damage & 0xFFFF, o); o += 2;
    const bnB = Buffer.from(p.blockName, 'utf8');
    out.writeUInt8(Math.min(bnB.length, 255), o); o += 1;
    bnB.copy(out, o); o += bnB.length;
    out.writeUInt8(p.meta & 0xFF, o); o += 1;
  }

  // layer offsets
  for (let y = 0; y < height; y++) {
    out.writeUInt32LE(offsets[y], o); o += 4;
  }

  // layer data
  for (let y = 0; y < height; y++) {
    layerData[y].copy(out, o);
    o += layerData[y].length;
  }

  if (o !== fileLength) throw new Error('Encoding length mismatch: wrote ' + o + ' expected ' + fileLength);

  // --- Step 4: compute CRC32 over bytes [24, fileLength). ---
  const crc = crc32(out, 24, fileLength);
  writeCrc32(out, crcOffset, crc);

  return out;
}

/**
 * Read/parse a plan file (for the inspector and tests).
 * @param {Buffer|Uint8Array} raw
 * @returns {object} header + palette + layer offsets (raw layer data not decoded)
 */
function parseHeader(raw) {
  const buf = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
  if (buf.length < 24) throw new Error('File too small');
  if (buf.toString('ascii', 0, 4) !== 'OCBP') throw new Error('Bad magic');
  const formatVersion = buf.readUInt8(4);
  const flags = buf.readUInt8(5);
  const width = buf.readUInt16LE(6);
  const height = buf.readUInt16LE(8);
  const length = buf.readUInt16LE(10);
  const planVersion = buf.readUInt32LE(12);
  const fileLength = buf.readUInt32LE(16);
  const crcStored = buf.readUInt32LE(20);
  return { formatVersion, flags, width, height, length, planVersion, fileLength, crcStored, buf };
}

/**
 * Decode the full plan.
 * @param {Buffer|Uint8Array} raw
 * @returns {{header:object, name:string, palette:Array, layerOffsets:number[],
 *            layers:number[][]}}
 */
function decode(raw) {
  const { buf, ...header } = parseHeader(raw);
  if (buf.length < header.fileLength) throw new Error('File truncated');
  // Verify CRC.
  const crcCalc = crc32(buf, 24, header.fileLength);
  if (crcCalc !== header.crcStored) {
    throw new Error(`CRC mismatch: stored 0x${header.crcStored.toString(16)}, computed 0x${crcCalc.toString(16)}`);
  }
  let o = 24;
  // name
  const nameLen = buf.readUInt8(o); o += 1;
  const name = buf.toString('utf8', o, o + nameLen); o += nameLen;
  // palette count
  const paletteCount = buf.readUInt16LE(o); o += 2;
  const palette = [];
  for (let i = 0; i < paletteCount; i++) {
    const flags = buf.readUInt8(o); o += 1;
    const inLen = buf.readUInt8(o); o += 1;
    const itemName = buf.toString('utf8', o, o + inLen); o += inLen;
    const damage = buf.readUInt16LE(o); o += 2;
    const bnLen = buf.readUInt8(o); o += 1;
    const blockName = buf.toString('utf8', o, o + bnLen); o += bnLen;
    const meta = buf.readUInt8(o); o += 1;
    palette.push({ flags, itemName, damage, blockName, meta });
  }
  const layerOffsets = [];
  for (let y = 0; y < header.height; y++) {
    layerOffsets.push(buf.readUInt32LE(o)); o += 4;
  }
  // Decode each layer's RLE.
  const W = header.width, L = header.length;
  const layers = [];
  for (let y = 0; y < header.height; y++) {
    const start = layerOffsets[y];
    const end = (y + 1 < header.height) ? layerOffsets[y + 1] : header.fileLength;
    const cells = [];
    let p = start;
    while (p < end && cells.length < W * L) {
      const r1 = varint.decode(buf, p); p += r1.length;
      const r2 = varint.decode(buf, p); p += r2.length;
      for (let k = 0; k < r1.value; k++) cells.push(r2.value);
    }
    if (cells.length !== W * L) throw new Error(`Layer ${y}: decoded ${cells.length} cells, expected ${W * L}`);
    layers.push(cells);
  }
  return { header, name, palette, layerOffsets, layers };
}

/**
 * Helper: map (itemName, damage) to a palette index.
 * @returns {{palette:Array, indexFor:(item:string,damage:number)=>number}}
 */
function buildPalette(items) {
  // items: iterable of {itemName, damage, blockName, meta, flags}
  const palette = [];
  const index = new Map();
  for (const it of items) {
    const key = it.itemName + ' ' + it.damage;
    if (!index.has(key)) {
      index.set(key, palette.length + PALETTE_BASE);
      palette.push(it);
    }
  }
  return {
    palette,
    indexFor(itemName, damage) {
      const key = itemName + ' ' + damage;
      const idx = index.get(key);
      if (!idx) throw new Error('Palette index missing for ' + itemName + ' ' + damage);
      return idx;
    },
  };
}

module.exports = {
  encode, decode, parseHeader, buildPalette,
  MAGIC, FORMAT_VERSION,
  PALETTE_AIR, PALETTE_SKIP, PALETTE_BASE,
  FLAG_ORIENT, FLAG_TILEENTITY,
};
