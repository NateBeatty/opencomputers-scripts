const fs = require('fs');
const { parseSchematic } = require('./lib/schematic.js');
for (const f of ['test/tree5.schematic','test/tree5_out.schematic']) {
  const raw = fs.readFileSync(f);
  const s = parseSchematic(raw);
  console.log('\n===', f, '===');
  console.log('WxHxL:', s.width, s.height, s.length, 'cells:', s.cells.length);
  console.log('addBlocksVariant:', s.addBlocksVariant);
  console.log('mapping:', JSON.stringify(s.mapping));
  console.log('idToName:', JSON.stringify(s.idToName));
  const counts = {};
  for (const c of s.cells) {
    const k = (c.name||('id'+c.id)) + ':' + c.meta;
    counts[k] = (counts[k]||0)+1;
  }
  console.log('block counts:', JSON.stringify(counts));
  console.log('tileEntities:', s.tileEntities, 'entities:', s.entities);
}
