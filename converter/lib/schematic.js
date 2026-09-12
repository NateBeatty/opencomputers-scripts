'use strict';
// Reads 1.7.10 `.schematic` files (Schematica/SchematicaPlus/GT-Horizons NBT).
// Returns the decoded block cells, metadata, dimensions, and the SchematicaMapping.
// Mirrors SchematicaAlpha.readFromNBT() from the Schematica source.

const zlib = require('zlib');
const nbt = require('./nbt');

/**
 * Parse a `.schematic` file from a Buffer.
 *
 * @param {Buffer|Uint8Array} raw - raw file bytes
 * @returns {object} {
 *   width, height, length,
 *   cells: Array<{id, meta, name}>,  // index = x + (y*L + z)*W
 *   mapping: Object<string, number>, // name -> id (from SchematicaMapping)
 *   idToName: Object<number, string>, // id -> name (inverted mapping)
 *   addBlocksVariant: string,         // 'nibble' | 'schematicplus' | 'schematica' | 'none'
 *   tileEntities: number,
 *   entities: number,
 *   materialsFormat: string|null
 * }
 */
function parseSchematic(raw) {
  let data = raw;
  if (data.length >= 2 && data[0] === 0x1f && data[1] === 0x8b) {
    data = zlib.gunzipSync(data);
  }
  const root = nbt.parseUncompressed(data);
  // SchematicAlpha wraps in a "Schematic" compound; older files have it at top level.
  const sch = (root.value.Schematic && root.value.Schematic.value) || root.value;

  const width = sch.Width ? sch.Width.value : 0;
  const height = sch.Height ? sch.Height.value : 0;
  const length = sch.Length ? sch.Length.value : 0;
  const V = width * height * length;

  const blocks = sch.Blocks ? sch.Blocks.value : [];
  const metaArr = sch.Data ? sch.Data.value : [];

  // Determine the AddBlocks variant by array length, exactly like the Java reader:
  //  - 'AddBlocks' nibble:  length = ceil(V/2)  (MCEdit nibble packing)
  //  - 'AddBlocks' schematicplus: length = V    (one byte per cell, extra*256)
  //  - 'Add':  length = V   (one byte per cell, extra<<8)
  let extraBlocks = null;
  let addBlocksVariant = 'none';
  let extraShift = 8;        // how to combine: (extra & 0xFF) * 256  or  <<8
  let extraScale = 1;        // schematicplus uses *256, schematica uses <<8 (same value for 0xFF)

  if (sch.AddBlocks && sch.AddBlocks.value) {
    const ab = sch.AddBlocks.value;
    if (ab.length === Math.ceil(V / 2)) {
      // MCEdit nibble packing: high nibble = cell 2k, low nibble = cell 2k+1
      extraBlocks = new Array(V);
      for (let i = 0; i < ab.length; i++) {
        extraBlocks[i * 2 + 0] = (ab[i] >> 4) & 0xF;
        extraBlocks[i * 2 + 1] = ab[i] & 0xF;
      }
      addBlocksVariant = 'nibble';
    } else if (ab.length === V) {
      // schematicplus: one byte per cell, id = blocks | (extra * 256)
      extraBlocks = ab.slice(0, V);
      addBlocksVariant = 'schematicplus';
    } else {
      throw new Error(`AddBlocks length ${ab.length} matches neither nibble (${Math.ceil(V / 2)}) nor full (${V})`);
    }
  } else if (sch.Add && sch.Add.value) {
    extraBlocks = sch.Add.value.slice(0, V);
    addBlocksVariant = 'schematica';
  }

  // Decode cells.
  const cells = new Array(V);
  for (let i = 0; i < V; i++) {
    let id = blocks[i] & 0xFF;
    if (extraBlocks) {
      // Both nibble/schematicplus/schematica store (extra & 0xFF) << 8
      // (schematicplus' *256 is numerically identical to <<8 for values 0..255).
      id |= (extraBlocks[i] & 0xFF) << 8;
    }
    const meta = metaArr[i] & 0xFF;
    cells[i] = { id, meta };
  }

  // SchematicaMapping: name -> id.
  const mapping = {};
  const idToName = {};
  if (sch.SchematicaMapping && sch.SchematicaMapping.value) {
    const m = sch.SchematicaMapping.value;
    for (const name of Object.keys(m)) {
      const id = m[name].value;
      mapping[name] = id;
      idToName[id] = name;
    }
  }

  // Annotate cells with their block name (when available in the mapping).
  for (const c of cells) {
    c.name = idToName[c.id] || null;
  }

  const tileEntities = (sch.TileEntities && sch.TileEntities.value && sch.TileEntities.value.value) ? sch.TileEntities.value.value.length : 0;
  const entities = (sch.Entities && sch.Entities.value && sch.Entities.value.value) ? sch.Entities.value.value.length : 0;
  const materialsFormat = sch.Materials ? sch.Materials.value : null;

  return {
    width, height, length,
    cells,
    mapping,
    idToName,
    addBlocksVariant,
    tileEntities,
    entities,
    materialsFormat,
  };
}

module.exports = { parseSchematic };
