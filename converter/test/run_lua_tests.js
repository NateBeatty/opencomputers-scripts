#!/usr/bin/env node
'use strict';
// run_lua_tests.js — Runs Lua unit tests using fengari (Lua 5.3).
//
// Usage: node run_lua_tests.js <test.lua>

const path = require('path');
const fs = require('fs');
const { lauxlib, lualib, lua } = require('fengari');

function main() {
  const testFile = process.argv[2];
  if (!testFile) {
    console.error('Usage: node run_lua_tests.js <test.lua>');
    process.exit(1);
  }

  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  // Bridge Lua's print to Node's console.log.
  const printFn = function() {
    const nargs = lua.lua_gettop(L);
    const parts = [];
    for (let i = 1; i <= nargs; i++) {
      const val = lua.lua_tostring(L, i);
      if (val) parts.push(Buffer.from(val).toString('utf8'));
    }
    console.log(parts.join('\t'));
    return 0;
  };
  lua.lua_pushcfunction(L, printFn);
  lua.lua_setglobal(L, 'print');

  // Provide a readFile function for reading binary files.
  const readFileFn = function() {
    const pathStr = Buffer.from(lua.lua_tostring(L, 1)).toString('utf8');
    try {
      const data = fs.readFileSync(pathStr);
      const out = Buffer.from(data);
      lua.lua_pushstring(L, out);
      return 1;
    } catch (e) {
      lua.lua_pushnil(L);
      lua.lua_pushstring(L, Buffer.from('Error: ' + e.message));
      return 2;
    }
  };
  lua.lua_pushcfunction(L, readFileFn);
  lua.lua_setglobal(L, 'readFile');

  // Helper to run Lua code (fengari expects Uint8Array, not string).
  function runLua(code) {
    const bytes = new TextEncoder().encode(code);
    return lauxlib.luaL_dostring(L, bytes);
  }

  // Set package.path so require() finds the Lua modules.
  const libDir = path.resolve(__dirname, '..', '..', 'gtnh', 'builder', 'lib').replace(/\\/g, '/');
  const status = runLua('package.path = "' + libDir + '/?.lua;" .. package.path');
  if (status !== 0) {
    const msg = lua.lua_tostring(L, -1);
    console.error('Failed to set package.path:', msg ? Buffer.from(msg).toString('utf8') : 'unknown');
    lua.lua_pop(L, 1);
    process.exit(1);
  }

  // Run the test file.
  const testPath = path.resolve(testFile);
  const fileStatus = lauxlib.luaL_dofile(L, testPath);
  if (fileStatus !== 0) {
    const msg = lua.lua_tostring(L, -1);
    if (msg) console.error('Error:', Buffer.from(msg).toString('utf8'));
    lua.lua_pop(L, 1);
    process.exit(1);
  }

  // Read the failure count from the test file.
  lua.lua_getglobal(L, 'failed');
  const failed = lua.lua_tointeger(L, -1);
  lua.lua_pop(L, 1);

  lua.lua_close(L);
  process.exit(failed > 0 ? 1 : 0);
}

main();
