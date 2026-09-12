const fs = require('fs');
const { decode } = require('./lib/plan.js');
const buf = fs.readFileSync('test/tree5.plan');
const p = decode(buf);
console.log('=== tree5.plan ===');
console.log('magic/format:', p.header.formatVersion);
console.log('dims:', p.header.width, 'x', p.header.height, 'x', p.header.length);
console.log('name:', JSON.stringify(p.name));
console.log('planVersion:', p.header.planVersion);
console.log('fileLength:', p.header.fileLength, 'bytes:', buf.length);
console.log('paletteCount:', p.palette.length);
p.palette.forEach((e, i) => {
  console.log(`  [${i+2}] flags=0x${e.flags.toString(16)} item=${e.itemName} dmg=${e.damage} block=${e.blockName} meta=${e.meta}`);
});
// Count palette usage per layer
const idxCount = {};
for (let y = 0; y < p.header.height; y++) {
  for (const idx of p.layers[y]) {
    idxCount[idx] = (idxCount[idx] || 0) + 1;
  }
}
console.log('palette usage:', JSON.stringify(idxCount));
// Cross-check against known: log:1 (69 cells) + leaves (id18: 1497 cells) = 1566 placed + 100 extra?
console.log('total placed cells:', Object.entries(idxCount).filter(([k]) => parseInt(k) >= 2).reduce((s,[k,v]) => s+v, 0));
