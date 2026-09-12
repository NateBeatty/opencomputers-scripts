'use strict';
// Built-in block -> item mapping for blocks whose item differs from the block,
// or which cannot be placed by the robot (v1 skips them). Matched by the
// 1.7.10 registry name from the schematic's SchematicaMapping.
//
// IMPORTANT: item names here are FULLY NAMESPACED ("minecraft:redstone"),
// because that is what OpenComputers reports as a stack's `name` field
// (ConverterItemStack.scala: Item.itemRegistry.getNameForObject). The robot
// matches ender-chest contents on (name, damage), so a bare "redstone" would
// never match.
//
// `action` is:
//   'place'  -> placeable, item + damage given
//   'air'    -> dig out (cell must end up empty)
//   'skip'   -> never touch (upper halves, piston heads, double slabs, ...)

const ACTIONS = { PLACE: 'place', AIR: 'air', SKIP: 'skip' };

/** Strip the vanilla namespace so rules can be written once. */
function shortName(name) {
  return String(name || '').replace(/^minecraft:/, '');
}

/** Add the vanilla namespace back to a bare vanilla name. */
function vanilla(n) {
  return n.includes(':') ? n : 'minecraft:' + n;
}

// Blocks whose placed item differs from the block itself.
const NAME_MAP = {
  'redstone_wire': { item: 'minecraft:redstone', damage: 0 },
  'lit_furnace': { item: 'minecraft:furnace', damage: 0 },
  'lit_redstone_lamp': { item: 'minecraft:redstone_lamp', damage: 0 },
  'lit_redstone_ore': { item: 'minecraft:redstone_ore', damage: 0 },
  'unlit_redstone_torch': { item: 'minecraft:redstone_torch', damage: 0 },
  'powered_repeater': { item: 'minecraft:repeater', damage: 0 },
  'unpowered_repeater': { item: 'minecraft:repeater', damage: 0 },
  'powered_comparator': { item: 'minecraft:comparator', damage: 0 },
  'unpowered_comparator': { item: 'minecraft:comparator', damage: 0 },
  'cake': { item: 'minecraft:cake', damage: 0 },
  'reeds': { item: 'minecraft:reeds', damage: 0 },
  'melon_stem': { item: 'minecraft:melon_seeds', damage: 0 },
  'pumpkin_stem': { item: 'minecraft:pumpkin_seeds', damage: 0 },
  'carrots': { item: 'minecraft:carrot', damage: 0 },
  'potatoes': { item: 'minecraft:potato', damage: 0 },
  'wheat': { item: 'minecraft:wheat_seeds', damage: 0 },
  'nether_wart': { item: 'minecraft:nether_wart', damage: 0 },
  'flower_pot': { item: 'minecraft:flower_pot', damage: 0 },
  'cauldron': { item: 'minecraft:cauldron', damage: 0 },
  'brewing_stand': { item: 'minecraft:brewing_stand', damage: 0 },
};

// Blocks that must be dug out (the cell ends up empty).
const AIR_BLOCKS = new Set([
  'air', 'water', 'flowing_water', 'lava', 'flowing_lava',
  'fire', 'portal', 'end_portal', 'snow_layer',
]);

// Blocks that cannot be placed in v1 -> skip (leave the cell empty and log).
const SKIP_BLOCKS = new Set([
  // Upper/second halves created by placing the other half.
  'wooden_door', 'iron_door', 'bed',
  // Double slabs are two slabs; v1 does not place them.
  'double_stone_slab', 'double_wooden_slab', 'double_stone_slab2',
  // Blocks with no item form of their own.
  'piston_head', 'piston_extension', 'mob_spawner',
  'standing_sign', 'wall_sign', 'skull',
  // Microblock/multipart containers: the block carries its parts in NBT, so
  // placing the "block" item would produce something else entirely.
  'ForgeMultipart:block', 'ForgeMultipart:multipart',
]);

// Metadata families: how to derive the ITEM damage from the BLOCK meta when the
// item panel has no exact row. Mirrors the knowledge in Schematica's
// PlacementRegistry: these metas encode orientation/state, not item variant.
//
//   0        -> meta is pure orientation/state, item damage is always 0
//   meta & 7 -> slab family (bit 3 is the top-half flag)
//   meta & 3 -> log/leaves family (upper bits are axis/decay)
const ORIENT_ONLY = new Set([
  'chest', 'trapped_chest', 'ender_chest', 'furnace', 'dispenser', 'dropper',
  'hopper', 'ladder', 'torch', 'redstone_torch', 'lever', 'vine',
  'pumpkin', 'lit_pumpkin', 'fence_gate', 'trapdoor', 'iron_trapdoor',
  'piston', 'sticky_piston', 'tripwire_hook', 'stone_button', 'wooden_button',
  'wall_banner', 'standing_banner', 'end_rod', 'cocoa', 'rail',
  'golden_rail', 'detector_rail', 'activator_rail', 'redstone_lamp',
]);
const SLAB_FAMILY = new Set(['stone_slab', 'wooden_slab', 'stone_slab2']);
const LOG_FAMILY = new Set(['log', 'log2', 'leaves', 'leaves2']);

/**
 * Derive the item damage for a block whose meta is not a variant selector.
 * @returns {number|null} the damage, or null when no rule applies
 */
function familyDamage(name, meta) {
  const n = shortName(name);
  if (/_stairs$/.test(n)) return 0;
  if (SLAB_FAMILY.has(n)) return meta & 7;
  if (LOG_FAMILY.has(n)) return meta & 3;
  if (ORIENT_ONLY.has(n)) return 0;
  return null;
}

/**
 * Resolve a block to its placement action using the built-in tables only.
 *
 * @param {string|null} name - 1.7.10 registry name (may be null)
 * @param {number} id - block ID (only used to recognise air)
 * @returns {{action:string, item:string|null, damage:number, reason:string}}
 */
function resolve(name, id) {
  const n = shortName(name);
  if (name && NAME_MAP[n]) {
    const m = NAME_MAP[n];
    return { action: ACTIONS.PLACE, item: m.item, damage: m.damage, reason: 'builtin' };
  }
  if (id === 0 || (name && AIR_BLOCKS.has(n))) {
    return { action: ACTIONS.AIR, item: null, damage: 0, reason: 'builtin-air' };
  }
  // SKIP matches either the bare vanilla name or the full modded name.
  if (name && (SKIP_BLOCKS.has(n) || SKIP_BLOCKS.has(name))) {
    return { action: ACTIONS.SKIP, item: null, damage: 0, reason: 'builtin-skip' };
  }
  return { action: ACTIONS.PLACE, item: name, damage: 0, reason: 'default' };
}

module.exports = {
  resolve, familyDamage, shortName, vanilla,
  ACTIONS, NAME_MAP, AIR_BLOCKS, SKIP_BLOCKS,
};
