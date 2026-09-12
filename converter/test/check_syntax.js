#!/usr/bin/env node
'use strict';
// check_syntax.js — Compile every robot-side Lua file with Lua 5.3 (via fengari)
// to catch syntax errors before anything is copied onto a robot.
//
// This only compiles; it does not run the files, since they require OpenComputers
// APIs (component, robot, computer) that do not exist off the robot.
//
// Usage: node check_syntax.js [file.lua ...]   (defaults to all robot/station Lua)

const fs = require('fs');
const path = require('path');
const { lauxlib, lualib, lua, to_luastring } = require('fengari');

function compile(file) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const src = fs.readFileSync(file);
  const status = lauxlib.luaL_loadbuffer(L, src, src.length, to_luastring('@' + file));
  if (status !== lua.LUA_OK) {
    const msg = lua.lua_tojsstring(L, -1);
    return msg || 'unknown error';
  }
  return null;
}

function collect(dir, out) {
  if (!fs.existsSync(dir)) return out;
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const stat = fs.statSync(full);
    if (stat.isDirectory()) collect(full, out);
    else if (name.endsWith('.lua')) out.push(full);
  }
  return out;
}

function main() {
  let files = process.argv.slice(2);
  if (files.length === 0) {
    const root = path.join(__dirname, '..', '..');
    files = [];
    collect(path.join(root, 'gtnh'), files);
    
  }

  let failed = 0;
  for (const file of files) {
    const err = compile(file);
    const rel = path.relative(path.join(__dirname, '..', '..'), file);
    if (err) {
      console.log(`  FAIL ${rel}\n       ${err}`);
      failed++;
    } else {
      console.log(`  ok   ${rel}`);
    }
  }
  console.log(`\n=== ${files.length - failed} compiled, ${failed} failed ===`);
  process.exit(failed > 0 ? 1 : 0);
}

main();
