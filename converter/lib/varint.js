'use strict';
// Unsigned LEB128 (variable-length) integers, little-endian bit order.
// Matches the plan format's run-length encoding and OpenOS' Data Card varint.

/**
 * Encode an unsigned integer as LEB128.
 * @param {number} v - a non-negative integer
 * @returns {number[]} array of bytes
 */
function encode(v) {
  if (v < 0) throw new Error('varint requires a non-negative integer');
  const out = [];
  do {
    let b = v & 0x7f;
    v >>>= 7;
    if (v > 0) b |= 0x80;
    out.push(b);
  } while (v > 0);
  return out;
}

/**
 * Append LEB128 bytes for v into an output array (returns new array or mutates).
 * @param {number} v
 * @param {number[]} out - array to push into
 */
function append(out, v) {
  if (v < 0) throw new Error('varint requires a non-negative integer');
  do {
    let b = v & 0x7f;
    v >>>= 7;
    if (v > 0) b |= 0x80;
    out.push(b);
  } while (v > 0);
}

/**
 * Decode a LEB128 from a byte sequence.
 * @param {Uint8Array|number[]} data
 * @param {number} [offset=0]
 * @returns {{value:number, length:number}} the decoded value and bytes consumed
 */
function decode(data, offset = 0) {
  let result = 0;
  let shift = 0;
  let pos = offset;
  while (true) {
    const b = data[pos];
    result |= (b & 0x7f) << shift;
    pos++;
    if ((b & 0x80) === 0) break;
    shift += 7;
    if (shift > 31) throw new Error('varint too long');
  }
  return { value: result, length: pos - offset };
}

module.exports = { encode, append, decode };
