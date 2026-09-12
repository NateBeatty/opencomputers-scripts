const zlib = require('zlib');
const nbt = require('./lib/nbt.js');
const T = nbt.tagTypes;

const writer = new nbt.Writer();
writer.byte(10);
writer.string('Schematic');
writer.compound({ Schematic: { type: T.compound, value: {
  Width: { type: T.short, value: 2 },
  Height: { type: T.short, value: 1 },
  Length: { type: T.short, value: 1 },
  Blocks: { type: T.byteArray, value: [17, 18] },
  Data: { type: T.byteArray, value: [1, 2] },
}}});
const raw = zlib.gzipSync(Buffer.from(writer.getData()));
// Parse it
const { parseSchematic } = require('./lib/schematic.js');
const s = parseSchematic(raw);
console.log('W,H,L:', s.width, s.height, s.length);
console.log('cells:', JSON.stringify(s.cells));
// Also parse the raw NBT to see structure
const root = nbt.parseUncompressed(zlib.gunzipSync(raw));
console.log('root.name:', root.name);
console.log('root.value keys:', Object.keys(root.value));
console.log('root.value.Schematic:', root.value.Schematic ? 'exists' : 'missing');
