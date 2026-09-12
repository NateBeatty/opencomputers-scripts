'use strict';
// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) — the same polynomial as
// zlib.crc32 and OpenComputers' Data Card. Table-driven for speed.
const TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    t[n] = c >>> 0;
  }
  return t;
})();

/**
 * Compute CRC-32 of a Uint8Array.
 * @param {Uint8Array} data
 * @param {number} [start=0]
 * @param {number} [end=data.length]
 * @returns {number} unsigned 32-bit CRC
 */
function crc32(data, start = 0, end = data.length) {
  let crc = 0xFFFFFFFF;
  for (let i = start; i < end; i++) {
    crc = TABLE[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

/**
 * Read a CRC-32 from a little-endian byte array.
 * @param {Uint8Array} data
 * @param {number} offset
 * @returns {number}
 */
function readCrc32(data, offset) {
  return (data[offset] | (data[offset + 1] << 8) |
          (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
}

/**
 * Append a CRC-32 as little-endian bytes to a Uint8Array (mutates in place).
 * @param {Uint8Array} data
 * @param {number} offset
 * @param {number} crc
 */
function writeCrc32(data, offset, crc) {
  data[offset] = crc & 0xFF;
  data[offset + 1] = (crc >>> 8) & 0xFF;
  data[offset + 2] = (crc >>> 16) & 0xFF;
  data[offset + 3] = (crc >>> 24) & 0xFF;
}

module.exports = { crc32, readCrc32, writeCrc32 };
