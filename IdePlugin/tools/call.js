// Drives the RadAiBridge RPC socket directly, bypassing MCP.
// Usage: node call.js <toolName> [paramsJsonFile]
const fs = require('fs');
const net = require('net');
const path = require('path');

const cfgPath = path.join(process.env.APPDATA, 'RadAiBridge', 'bridge.json');
// bridge.json is written with a UTF-8 BOM, which JSON.parse rejects.
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8').replace(/^﻿/, ''));

// Params come as key=value pairs so Windows paths never have to survive a trip
// through hand-written JSON, where bash eats the backslashes. A value is parsed
// as JSON when that succeeds (numbers, booleans, objects) and kept as a plain
// string otherwise - which is what a path wants. @file reads a JSON file.
const tool = process.argv[2];
let params = {};
for (const arg of process.argv.slice(3)) {
  if (arg.startsWith('@')) {
    params = { ...params, ...JSON.parse(fs.readFileSync(arg.slice(1), 'utf8')) };
    continue;
  }
  const eq = arg.indexOf('=');
  if (eq < 0) throw new Error(`Expected key=value or @file, got: ${arg}`);
  const key = arg.slice(0, eq);
  const raw = arg.slice(eq + 1);
  try {
    params[key] = JSON.parse(raw);
  } catch {
    params[key] = raw;
  }
}

const req = { id: 1, method: tool, params };
const sock = net.createConnection(cfg.port, '127.0.0.1', () => {
  sock.write(JSON.stringify(req) + '\n');
});

let buf = '';
let replied = false;
sock.setTimeout(140000, () => {
  console.error('TIMEOUT - the IDE main thread is probably blocked by a modal.');
  sock.destroy();
  process.exit(2);
});
sock.on('data', (d) => {
  buf += d.toString();
  const nl = buf.indexOf('\n');
  if (nl >= 0) {
    console.log(buf.slice(0, nl));
    replied = true;
    sock.end();
  }
});
sock.on('error', (e) => {
  // A reset arriving after a complete reply says nothing about the call, which
  // already succeeded. Only treat it as a failure if we never got an answer.
  if (replied) return;
  console.error('SOCKET ERROR:', e.message);
  process.exit(1);
});
