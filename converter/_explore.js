const zlib = require('zlib');
const nbt = require('/d/Coding/LitematicaSchematicaConverter/LitematicaToSchematic/nbt.js');
const fs = require('fs');

function inspect(path) {
  console.log('\n========== ' + path + ' ==========');
  let data = fs.readFileSync(path);
  if (data[0]===0x1f && data[1]===0x8b) data = zlib.gunzipSync(data);
  const root = nbt.parseUncompressed(data);
  console.log('root name:', root.name);
  const top = root.value;
  console.log('top-level keys:', Object.keys(top));
  const sch = (top.Schematic && top.Schematic.value) || top;
  console.log('schematic keys:', Object.keys(sch));
  for (const k of Object.keys(sch)) {
    const v = sch[k];
    if (v.type === 'byteArray') {
      console.log(`  ${k} [byteArray] len=${v.value.length} first16=${v.value.slice(0,16).map(b=>b.toString(16)).join(',')}`);
    } else if (v.type === 'compound') {
      console.log(`  ${k} [compound] keys=${Object.keys(v.value).slice(0,8).join(',')}${Object.keys(v.value).length>8?'...':''}`);
    } else if (v.type === 'short') {
      console.log(`  ${k} = ${v.value}`);
    } else if (v.type === 'list') {
      console.log(`  ${k} [list] type=${v.value.type} len=${v.value.value.length}`);
    } else {
      console.log(`  ${k} = (${v.type}) ${JSON.stringify(v.value)}`);
    }
  }
  if (sch.SchematicaMapping) {
    const m = sch.SchematicaMapping.value;
    const entries = Object.entries(m).slice(0,12);
    console.log('  SchematicaMapping sample:', entries.map(([n,id])=>`${n}=${id.value}`).join(', '));
    console.log('  total mapped:', Object.keys(m).length);
  }
}
inspect('/d/Coding/LitematicaSchematicaConverter/LitematicaToSchematic/tree5.schematic');
inspect('/d/Coding/LitematicaSchematicaConverter/LitematicaToSchematic/tree5_out.schematic');
