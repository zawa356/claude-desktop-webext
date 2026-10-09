#!/usr/bin/env node
// Assemble a ready-to-ship Claude Desktop package for one extension.
//
//   node tools/package.mjs --config desktop-webext.json --extension <built MV3 folder> --out <dir> [--no-verify]
//
// Output (<dir>):
//   install.bat uninstall.bat diagnose.bat repair.bat   (Windows, CRLF)
//   install.sh  uninstall.sh  diagnose.sh  repair.sh    (Linux, LF)
//   desktop-webext.json                                 (copy of --config, "source" set to "extension")
//   extension/                                          (copy of --extension)
//   claude-desktop-webext/{bin/webext.ps1, bin/webext.py, bin/webext.sh, LICENSE, README.md}
//
// --verify (default) installs the result into a throw-away sandbox with webext.py (python3)
// or webext.ps1 (Windows PowerShell) to prove the extension is mergeable.
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const loaderRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = Object.create(null);
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--no-verify') args.verify = false;
  else if (a.startsWith('--')) args[a.slice(2)] = process.argv[++i];
}
for (const k of ['config', 'extension', 'out']) {
  if (!args[k]) { console.error(`missing --${k}`); process.exit(2); }
}
const config = JSON.parse(readFileSync(args.config, 'utf8'));
if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(config.id ?? '')) { console.error('config.id is missing or invalid'); process.exit(2); }
if (!existsSync(join(args.extension, 'manifest.json'))) { console.error(`no manifest.json in ${args.extension}`); process.exit(2); }

const out = resolve(args.out);
rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, 'claude-desktop-webext', 'bin'), { recursive: true });
cpSync(args.extension, join(out, 'extension'), { recursive: true });
writeFileSync(join(out, 'desktop-webext.json'), JSON.stringify({ ...config, source: 'extension' }, null, 2) + '\n');
for (const f of ['bin/webext.ps1', 'bin/webext.py', 'bin/webext.sh', 'LICENSE', 'README.md']) {
  cpSync(join(loaderRoot, f), join(out, 'claude-desktop-webext', f));
}

const actions = { install: 'install', uninstall: 'uninstall', diagnose: 'diagnose', repair: 'rebuild' };
for (const [file, action] of Object.entries(actions)) {
  const cfg = action === 'rebuild' ? '' : ' -Config "%~dp0desktop-webext.json"';
  const bat = [
    '@echo off',
    'setlocal',
    `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-desktop-webext\\bin\\webext.ps1" -Action ${action}${cfg} %*`,
    'set "rc=%errorlevel%"',
    'echo.',
    'pause',
    'exit /b %rc%',
    ''
  ].join('\r\n');
  writeFileSync(join(out, `${file}.bat`), bat);
  const shCfg = action === 'rebuild' ? '' : ' --config "$here/desktop-webext.json"';
  const sh = [
    '#!/usr/bin/env bash',
    'set -eu',
    'here="$(cd "$(dirname "$0")" && pwd)"',
    `exec bash "$here/claude-desktop-webext/bin/webext.sh" ${action}${shCfg} "$@"`,
    ''
  ].join('\n');
  writeFileSync(join(out, `${file}.sh`), sh);
  try { chmodSync(join(out, `${file}.sh`), 0o755); } catch { /* Windows */ }
}

if (args.verify !== false) {
  const sandbox = mkdtempSync(join(tmpdir(), 'webext-verify-'));
  try {
    const py = ['python3', 'python'].find(c => spawnSync(c, ['-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)']).status === 0);
    let r;
    if (py) {
      mkdirSync(join(sandbox, '.config', 'Claude'), { recursive: true });
      r = spawnSync(py, [join(out, 'claude-desktop-webext', 'bin', 'webext.py'), 'install', '--config', join(out, 'desktop-webext.json'), '--yes', '--sandbox', sandbox], { encoding: 'utf8' });
    } else if (process.platform === 'win32') {
      mkdirSync(join(sandbox, 'AppData', 'Roaming', 'Claude'), { recursive: true });
      r = spawnSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(out, 'claude-desktop-webext', 'bin', 'webext.ps1'), '-Action', 'install', '-Config', join(out, 'desktop-webext.json'), '-Yes', '-Sandbox', sandbox], { encoding: 'utf8' });
    } else {
      console.error('verify: neither python3 nor Windows PowerShell is available (use --no-verify to skip)');
      process.exit(1);
    }
    if (r.status !== 0) {
      console.error(r.stdout, r.stderr);
      console.error('verify: the extension could not be installed into a sandbox');
      process.exit(1);
    }
    console.log('verify: sandbox install OK');
  } finally {
    rmSync(sandbox, { recursive: true, force: true });
  }
}
console.log(`packaged ${config.id} -> ${out}`);
