#!/usr/bin/env node
'use strict';

// Runs on `npm install`. Builds TetherShot from source and installs the .app
// into ~/Applications. A signed DMG copy in /Applications is canonical and is
// deliberately never overwritten with this local ad-hoc build.

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

if (process.platform !== 'darwin') {
  console.error('[TetherShot] macOS only — skipping install on ' + process.platform + '.');
  process.exit(0);
}

const pkgRoot = path.resolve(__dirname, '..');
const systemApp = '/Applications/TetherShot.app';
const entitlements = path.join(pkgRoot, 'Resources', 'TetherShot.entitlements');

function isTetherShot(appPath) {
  const info = path.join(appPath, 'Contents', 'Info.plist');
  if (!fs.existsSync(info)) return false;
  try {
    return execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', info], { encoding: 'utf8' }).trim()
      === 'com.apoorvdarshan.tethershot';
  } catch (_) {
    return false;
  }
}

if (isTetherShot(systemApp)) {
  console.log('\n[TetherShot] Preserving the signed installation at ' + systemApp);
  console.log('[TetherShot] Use Check for Updates in the app to install signed releases.\n');
  process.exit(0);
}

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

const builtApp = path.join(pkgRoot, '.build', 'TetherShot.app');
if (!fs.existsSync(builtApp)) {
  console.error('[TetherShot] Build did not produce .build/TetherShot.app.');
  process.exit(1);
}

const appsDir = path.join(realHome(), 'Applications');
const destApp = path.join(appsDir, 'TetherShot.app');
fs.mkdirSync(appsDir, { recursive: true });
execFileSync('/bin/rm', ['-rf', destApp]);
execFileSync('/bin/cp', ['-R', builtApp, destApp]);
// Re-sign at the final path so the ad-hoc identity is stable there.
try {
  execFileSync('/usr/bin/codesign', ['--force', '--deep', '--entitlements', entitlements, '--sign', '-', destApp], { stdio: 'ignore' });
} catch (_) {}
// Keep ~/Applications as the only discoverable copy. The build bundle is just
// staging and otherwise appears as a duplicate in Spotlight/Launch Services.
execFileSync('/bin/rm', ['-rf', builtApp]);

console.log('\n[TetherShot] Installed to ' + destApp);
console.log('[TetherShot] Launch it:  tethershot     (or open it from ~/Applications)');
console.log('[TetherShot] Wi-Fi capture (optional):  tethershot setup-wifi\n');
