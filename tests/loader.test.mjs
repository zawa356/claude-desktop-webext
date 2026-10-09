// Behaviour tests for both loader implementations (webext.ps1 on Windows, webext.py anywhere).
// Every case runs against each implementation that is available on this machine; when both
// are available the generated manifests are also compared byte for byte.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SLOT_ID = 'fmkadmapgofadopljbjfkapdkoienihi';

function findPython() {
  for (const c of ['python3', 'python']) {
    const r = spawnSync(c, ['-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)']);
    if (r.status === 0) return c;
  }
  return null;
}
const python = findPython();
const hasPowerShell = process.platform === 'win32';

const impls = [];
if (hasPowerShell) {
  impls.push({
    name: 'ps1',
    init(sb) { mkdirSync(join(sb, 'AppData', 'Roaming', 'Claude'), { recursive: true }); },
    slot: sb => join(sb, 'AppData', 'Roaming', 'Claude', 'extensions', SLOT_ID),
    home: sb => join(sb, 'AppData', 'Local', 'ClaudeDesktopWebExt'),
    envValue(sb) { const f = join(sb, 'env-User.json'); return existsSync(f) ? JSON.parse(readFileSync(f, 'utf8')).Value : null; },
    setForeignEnv(sb, v) { writeFileSync(join(sb, 'env-User.json'), JSON.stringify({ Value: v, Kind: 'String' })); },
    run(sb, o) {
      const a = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(root, 'bin', 'webext.ps1'), '-Action', o.action, '-Yes', '-Sandbox', sb];
      if (o.id) a.push('-Id', o.id);
      if (o.source) a.push('-Source', o.source);
      if (o.order !== undefined) a.push('-Order', String(o.order));
      if (o.config) a.push('-Config', o.config);
      if (o.adoptEnv) a.push('-AdoptEnv');
      if (o.takeOver) a.push('-TakeOver');
      if (o.failAt) a.push('-FailAt', o.failAt);
      return spawnSync('powershell', a, { encoding: 'utf8' });
    }
  });
}
if (python) {
  impls.push({
    name: 'py',
    init(sb) { mkdirSync(join(sb, '.config', 'Claude'), { recursive: true }); },
    slot: sb => join(sb, '.config', 'Claude', 'extensions', SLOT_ID),
    home: sb => join(sb, '.local', 'share', 'claude-desktop-webext'),
    envValue(sb) {
      const f = join(sb, '.config', 'environment.d', '90-claude-desktop-webext.conf');
      return existsSync(f) ? /REACT_PROFILE=(\S+)/.exec(readFileSync(f, 'utf8'))[1] : null;
    },
    setForeignEnv(sb, v) { writeFileSync(join(sb, '.profile'), `export REACT_PROFILE=${v}\n`); },
    run(sb, o) {
      const a = [join(root, 'bin', 'webext.py'), o.action, '--yes', '--sandbox', sb];
      if (o.id) a.push('--id', o.id);
      if (o.source) a.push('--source', o.source);
      if (o.order !== undefined) a.push('--order', String(o.order));
      if (o.config) a.push('--config', o.config);
      if (o.adoptEnv) a.push('--adopt-env');
      if (o.takeOver) a.push('--take-over');
      if (o.failAt) a.push('--fail-at', o.failAt);
      return spawnSync(python, a, { encoding: 'utf8' });
    }
  });
}
if (impls.length === 0) test('no loader implementation available', { skip: true }, () => {});

// ---------------------------------------------------------------- fixtures
function tmp(prefix) { return mkdtempSync(join(tmpdir(), prefix)); }
function writeExt(dir, manifest, files = {}) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest, null, 2));
  for (const [rel, body] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, rel)), { recursive: true });
    writeFileSync(join(dir, rel), body);
  }
  return dir;
}
const mainScript = (js, extra = {}) => ({ matches: ['https://claude.ai/*'], js: [js], run_at: 'document_start', world: 'MAIN', all_frames: false, ...extra });
function extA(base) {
  return writeExt(join(base, 'extA'), { manifest_version: 3, name: 'Ext A', version: '1.0.0', content_scripts: [mainScript('content-scripts/a.js')] }, { 'content-scripts/a.js': 'void 0;' });
}
function extB(base) {
  return writeExt(join(base, 'extB'), { manifest_version: 3, name: 'Ext B', version: '2.1.0', permissions: ['storage'],
    content_scripts: [mainScript('keys.js'), { matches: ['https://claude.ai/*'], js: ['ui.js'], run_at: 'document_start' }] }, { 'keys.js': '1;', 'ui.js': '2;' });
}
function snapshot(dir) {
  const out = {};
  if (!existsSync(dir)) return out;
  (function walk(d) {
    for (const name of readdirSync(d)) {
      const p = join(d, name);
      if (statSync(p).isDirectory()) walk(p);
      else out[relative(dir, p).replaceAll('\\', '/')] = createHash('sha256').update(readFileSync(p)).digest('hex');
    }
  })(dir);
  return out;
}
function setup(impl) {
  const sb = tmp(`webext-${impl.name}-`);
  impl.init(sb);
  const src = tmp('webext-src-');
  return { sb, src, cleanup() { rmSync(sb, { recursive: true, force: true }); rmSync(src, { recursive: true, force: true }); } };
}
const manifestOf = (impl, sb) => JSON.parse(readFileSync(join(impl.slot(sb), 'manifest.json'), 'utf8'));
const stateOf = (impl, sb) => JSON.parse(readFileSync(join(impl.home(sb), 'state.json'), 'utf8'));
function ok(r) { assert.equal(r.status, 0, `exit ${r.status}\n${r.stdout}\n${r.stderr}`); }
function refused(r) { assert.equal(r.status, 1, `expected exit 1, got ${r.status}\n${r.stdout}\n${r.stderr}`); }

// ---------------------------------------------------------------- cases
for (const impl of impls) {
  test(`${impl.name}: install merges extensions in (order, id) order and sets REACT_PROFILE`, () => {
    const t = setup(impl);
    try {
      ok(impl.run(t.sb, { action: 'install', id: 'ext-b', source: extB(t.src), order: 50 }));
      ok(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src), order: 10 }));
      const m = manifestOf(impl, t.sb);
      assert.equal(m.manifest_version, 3);
      assert.equal(m.version, '1.0.2');
      assert.deepEqual(m.permissions, ['storage']);
      assert.deepEqual(m.content_scripts.map(c => c.js[0]), ['ext/ext-a/content-scripts/a.js', 'ext/ext-b/keys.js', 'ext/ext-b/ui.js']);
      assert.equal(m.content_scripts[0].world, 'MAIN');
      assert.ok(existsSync(join(impl.slot(t.sb), 'ext', 'ext-a', 'content-scripts', 'a.js')));
      assert.ok(existsSync(join(impl.slot(t.sb), '.claude-desktop-webext.json')));
      assert.equal(impl.envValue(t.sb), '1');
      const s = stateOf(impl, t.sb);
      assert.equal(s.envSetByUs, true);
      assert.equal(s.extensions['ext-a'].order, 10);
      assert.equal(s.extensions['ext-b'].version, '2.1.0');
      const raw = readFileSync(join(impl.slot(t.sb), 'manifest.json'), 'utf8');
      assert.ok(raw.endsWith('}\n') && !raw.includes('\r') && raw.charCodeAt(0) === 0x7b, 'canonical JSON (LF, no BOM)');
    } finally { t.cleanup(); }
  });

  test(`${impl.name}: an invalid extension in the store is skipped, the manifest stays valid`, () => {
    const t = setup(impl);
    try {
      ok(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src) }));
      writeExt(join(impl.home(t.sb), 'web-extensions', 'broken'), { manifest_version: 3, name: 'Broken', version: '1', background: { service_worker: 'x.js' }, content_scripts: [mainScript('x.js')] }, { 'x.js': '' });
      writeExt(join(impl.home(t.sb), 'web-extensions', 'missing'), { manifest_version: 3, name: 'Missing', version: '1', content_scripts: [mainScript('nope.js')] });
      ok(impl.run(t.sb, { action: 'rebuild' }));
      const m = manifestOf(impl, t.sb);
      assert.deepEqual(m.content_scripts.map(c => c.js[0]), ['ext/ext-a/content-scripts/a.js']);
      const marker = JSON.parse(readFileSync(join(impl.slot(t.sb), '.claude-desktop-webext.json'), 'utf8'));
      assert.deepEqual(marker.skipped.map(s => s.id), ['broken', 'missing']);
    } finally { t.cleanup(); }
  });

  test(`${impl.name}: install refuses an unmergeable source and changes nothing`, () => {
    const t = setup(impl);
    try {
      const bad = [
        writeExt(join(t.src, 'bg'), { manifest_version: 3, name: 'X', version: '1', background: { service_worker: 'a.js' }, content_scripts: [mainScript('a.js')] }, { 'a.js': '' }),
        writeExt(join(t.src, 'trav'), { manifest_version: 3, name: 'X', version: '1', content_scripts: [mainScript('../a.js')] }),
        writeExt(join(t.src, 'perm'), { manifest_version: 3, name: 'X', version: '1', permissions: ['tabs'], content_scripts: [mainScript('a.js')] }, { 'a.js': '' }),
        writeExt(join(t.src, 'mv2'), { manifest_version: 2, name: 'X', version: '1', content_scripts: [mainScript('a.js')] }, { 'a.js': '' })
      ];
      for (const src of bad) refused(impl.run(t.sb, { action: 'install', id: 'bad', source: src }));
      assert.equal(existsSync(impl.slot(t.sb)), false);
      assert.equal(existsSync(impl.home(t.sb)), false);
      assert.equal(impl.envValue(t.sb), null);
    } finally { t.cleanup(); }
  });

  test(`${impl.name}: a foreign or React DevTools slot is never overwritten`, () => {
    for (const name of ['Some Other Tool', 'React Developer Tools']) {
      const t = setup(impl);
      try {
        writeExt(impl.slot(t.sb), { manifest_version: 3, name, version: '1' });
        const before = snapshot(impl.slot(t.sb));
        refused(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src) }));
        assert.deepEqual(snapshot(impl.slot(t.sb)), before);
        assert.equal(impl.envValue(t.sb), null);
      } finally { t.cleanup(); }
    }
  });

  test(`${impl.name}: a standalone install named in config.adopt is taken over and backed up`, () => {
    const t = setup(impl);
    try {
      writeExt(impl.slot(t.sb), { manifest_version: 3, name: 'Old Standalone', version: '0.3.0' }, { 'claude-keys.owner.json': '{}' });
      const cfgDir = join(t.src, 'pkg');
      cpExt(extB(t.src), join(cfgDir, 'extension'));
      writeFileSync(join(cfgDir, 'desktop-webext.json'), JSON.stringify({ id: 'claude-ctrl-enter', displayName: 'Ctrl+Enter', source: 'extension', order: 50, adopt: { markers: ['claude-keys.owner.json'], manifestNames: [] } }));
      impl.setForeignEnv(t.sb, '1');
      ok(impl.run(t.sb, { action: 'install', config: join(cfgDir, 'desktop-webext.json'), adoptEnv: true }));
      assert.equal(manifestOf(impl, t.sb).name, 'Claude Desktop WebExt');
      const backups = readdirSync(join(impl.home(t.sb), 'backups'));
      assert.ok(backups.some(b => existsSync(join(impl.home(t.sb), 'backups', b, 'slot-previous', 'claude-keys.owner.json'))));
      assert.equal(stateOf(impl, t.sb).envSetByUs, true);
    } finally { t.cleanup(); }
  });

  test(`${impl.name}: uninstall rebuilds, and the last uninstall removes the slot and REACT_PROFILE`, () => {
    const t = setup(impl);
    try {
      ok(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src) }));
      ok(impl.run(t.sb, { action: 'install', id: 'ext-b', source: extB(t.src) }));
      ok(impl.run(t.sb, { action: 'uninstall', id: 'ext-a' }));
      assert.deepEqual(manifestOf(impl, t.sb).content_scripts.map(c => c.js[0]), ['ext/ext-b/keys.js', 'ext/ext-b/ui.js']);
      assert.equal(impl.envValue(t.sb), '1');
      ok(impl.run(t.sb, { action: 'uninstall', id: 'ext-b' }));
      assert.equal(existsSync(impl.slot(t.sb)), false);
      assert.equal(impl.envValue(t.sb), null);
      assert.equal(stateOf(impl, t.sb).envSetByUs, false);
      assert.deepEqual(Object.keys(stateOf(impl, t.sb).extensions), []);
      const backups = join(impl.home(t.sb), 'backups');
      assert.ok(readdirSync(backups).some(b => existsSync(join(backups, b, 'store-removed-ext-b', 'manifest.json'))), 'removed files are kept in backups');
    } finally { t.cleanup(); }
  });

  test(`${impl.name}: REACT_PROFILE set to another value blocks install; an existing 1 is reused and kept`, () => {
    let t = setup(impl);
    try {
      impl.setForeignEnv(t.sb, '0');
      refused(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src) }));
      assert.equal(existsSync(impl.slot(t.sb)), false);
    } finally { t.cleanup(); }
    t = setup(impl);
    try {
      impl.setForeignEnv(t.sb, '1');
      ok(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src) }));
      assert.equal(stateOf(impl, t.sb).envSetByUs, false);
      ok(impl.run(t.sb, { action: 'uninstall', id: 'ext-a' }));
      if (impl.name === 'ps1') assert.equal(impl.envValue(t.sb), '1', 'foreign value is left alone');
      else assert.ok(readFileSync(join(t.sb, '.profile'), 'utf8').includes('REACT_PROFILE=1'));
    } finally { t.cleanup(); }
  });

  for (const failAt of ['copy', 'slot-stage', 'slot-swap', 'env', 'state']) {
    test(`${impl.name}: failure at ${failAt} rolls everything back`, () => {
      const t = setup(impl);
      try {
        ok(impl.run(t.sb, { action: 'install', id: 'ext-b', source: extB(t.src) }));
        const slotBefore = snapshot(impl.slot(t.sb));
        const stateBefore = readFileSync(join(impl.home(t.sb), 'state.json'), 'utf8');
        const storeBefore = snapshot(join(impl.home(t.sb), 'web-extensions'));
        const r = impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src), failAt });
        refused(r);
        assert.deepEqual(snapshot(impl.slot(t.sb)), slotBefore);
        assert.equal(readFileSync(join(impl.home(t.sb), 'state.json'), 'utf8'), stateBefore);
        assert.deepEqual(snapshot(join(impl.home(t.sb), 'web-extensions')), storeBefore);
        assert.equal(existsSync(join(impl.home(t.sb), '.lock')), false);
        assert.equal(impl.envValue(t.sb), '1');
      } finally { t.cleanup(); }
    });
  }

  test(`${impl.name}: a fresh install that fails at env leaves no REACT_PROFILE behind`, () => {
    const t = setup(impl);
    try {
      refused(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src), failAt: 'state' }));
      assert.equal(impl.envValue(t.sb), null);
      assert.equal(existsSync(impl.slot(t.sb)), false);
    } finally { t.cleanup(); }
  });

  test(`${impl.name}: lock file and newer schema block changes`, () => {
    const t = setup(impl);
    try {
      mkdirSync(impl.home(t.sb), { recursive: true });
      writeFileSync(join(impl.home(t.sb), '.lock'), '{}');
      refused(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src) }));
      rmSync(join(impl.home(t.sb), '.lock'));
      writeFileSync(join(impl.home(t.sb), 'state.json'), JSON.stringify({ schema: 99, generation: 5, envSetByUs: false, extensions: {} }));
      refused(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src) }));
      assert.equal(existsSync(impl.slot(t.sb)), false);
    } finally { t.cleanup(); }
  });

  test(`${impl.name}: rebuild repairs a deleted slot; --take-over replaces an unknown slot`, () => {
    const t = setup(impl);
    try {
      ok(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src) }));
      const scripts = manifestOf(impl, t.sb).content_scripts;
      rmSync(impl.slot(t.sb), { recursive: true });
      ok(impl.run(t.sb, { action: 'rebuild' }));
      assert.deepEqual(manifestOf(impl, t.sb).content_scripts, scripts);
      rmSync(impl.slot(t.sb), { recursive: true });
      writeExt(impl.slot(t.sb), { manifest_version: 3, name: 'Intruder', version: '1' });
      refused(impl.run(t.sb, { action: 'rebuild' }));
      ok(impl.run(t.sb, { action: 'rebuild', takeOver: true }));
      assert.deepEqual(manifestOf(impl, t.sb).content_scripts, scripts);
    } finally { t.cleanup(); }
  });
}

function cpExt(from, to) {
  mkdirSync(to, { recursive: true });
  for (const [rel] of Object.entries(snapshot(from))) {
    mkdirSync(dirname(join(to, rel)), { recursive: true });
    writeFileSync(join(to, rel), readFileSync(join(from, rel)));
  }
}

test('ps1 and py generate byte-identical manifests', { skip: impls.length < 2 && 'needs both implementations' }, () => {
  const outputs = impls.map(impl => {
    const t = setup(impl);
    try {
      ok(impl.run(t.sb, { action: 'install', id: 'ext-b', source: extB(t.src), order: 50 }));
      ok(impl.run(t.sb, { action: 'install', id: 'ext-a', source: extA(t.src), order: 10 }));
      writeExt(join(impl.home(t.sb), 'web-extensions', 'z-broken'), { manifest_version: 3, name: 'B', version: '1', options_page: 'o.html', content_scripts: [mainScript('a.js')] }, { 'a.js': '' });
      ok(impl.run(t.sb, { action: 'rebuild' }));
      const marker = JSON.parse(readFileSync(join(impl.slot(t.sb), '.claude-desktop-webext.json'), 'utf8'));
      delete marker.generatedAt;
      return { manifest: readFileSync(join(impl.slot(t.sb), 'manifest.json'), 'utf8'), marker };
    } finally { t.cleanup(); }
  });
  assert.equal(outputs[0].manifest, outputs[1].manifest);
  assert.deepEqual(outputs[0].marker, outputs[1].marker);
});
