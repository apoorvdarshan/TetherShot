#!/usr/bin/env node
'use strict';

// Runs on `npm install`. Builds TetherShot from source and installs the .app
// into ~/Applications. Building locally (vs. shipping a prebuilt binary) means
// the bundle never gets a com.apple.quarantine attribute, so Gatekeeper does
// not block it — no notarization needed.

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

if (process.platform !== 'darwin') {
  console.error('[TetherShot] macOS only — skipping install on ' + process.platform + '.');
  process.exit(0);
}

const pkgRoot = path.resolve(__dirname, '..');

// Resolve the invoking user's real home, even if run under `sudo npm install`.
function realHome() {
  if (process.env.SUDO_USER) {
    try {
      const out = execFileSync('/usr/bin/dscl', ['.', '-read', '/Users/' + process.env.SUDO_USER, 'NFSHomeDirectory'], { encoding: 'utf8' });
      const home = out.split(':').pop().trim();
      if (home) return home;
    } catch (_) { /* fall through */ }
  }
  return process.env.HOME || os.homedir();
}

function has(cmd) {
  try { execFileSync('/usr/bin/which', [cmd], { stdio: 'ignore' }); return true; }
  catch (_) { return false; }
}

if (!has('swift')) {
  console.error('\n[TetherShot] The Swift toolchain is required to build the app.');
  console.error('  Install the Xcode Command Line Tools:  xcode-select --install');
  console.error('  Then re-run:  npm install -g tethershot\n');
  process.exit(1);
}

console.log('[TetherShot] Building from source (this compiles a native app, ~30-60s)…');
try {
  execFileSync('/bin/bash', [path.join(pkgRoot, 'build.sh'), 'release'], { cwd: pkgRoot, stdio: 'inherit' });
} catch (_) {
  console.error('[TetherShot] Build failed. See the output above.');
  process.exit(1);
}

const builtApp = path.join(pkgRoot, 'TetherShot.app');
if (!fs.existsSync(builtApp)) {
  console.error('[TetherShot] Build did not produce TetherShot.app.');
  process.exit(1);
}

const appsDir = path.join(realHome(), 'Applications');
const destApp = path.join(appsDir, 'TetherShot.app');
fs.mkdirSync(appsDir, { recursive: true });
execFileSync('/bin/rm', ['-rf', destApp]);
execFileSync('/bin/cp', ['-R', builtApp, destApp]);
// Re-sign at the final path so the ad-hoc identity is stable there.
try { execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', destApp], { stdio: 'ignore' }); } catch (_) {}

console.log('\n[TetherShot] Installed to ' + destApp);
console.log('[TetherShot] Launch it:  tethershot     (or open it from ~/Applications)');
console.log('[TetherShot] Wi-Fi capture (optional):  tethershot setup-wifi\n');
