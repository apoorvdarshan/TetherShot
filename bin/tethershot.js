#!/usr/bin/env node
'use strict';

// `tethershot` CLI — install / launch / update the menu-bar app.

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PKG = 'tethershot';
const SYSTEM_APP = '/Applications/TetherShot.app';
const USER_APP = path.join(os.homedir(), 'Applications', 'TetherShot.app');
const scripts = path.join(__dirname, '..', 'scripts');

function isTetherShot(candidate) {
  const info = path.join(candidate, 'Contents', 'Info.plist');
  if (!fs.existsSync(info)) return false;
  try {
    return execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', info], { encoding: 'utf8' }).trim()
      === 'com.apoorvdarshan.tethershot';
  } catch (_) {
    return false;
  }
}

function appPath() {
  return isTetherShot(SYSTEM_APP) ? SYSTEM_APP : USER_APP;
}

function run(file, args) { execFileSync(file, args, { stdio: 'inherit' }); }
function quiet(file, args) { try { execFileSync(file, args, { stdio: 'ignore' }); } catch (_) {} }

const cmd = (process.argv[2] || 'launch').toLowerCase();

switch (cmd) {
  case 'launch':
  case 'open':
    {
    const APP = appPath();
    if (!fs.existsSync(APP)) {
      console.error('TetherShot.app not found in Applications. Run:  tethershot install');
      process.exit(1);
    }
    run('/usr/bin/open', [APP]);
    break;
    }

  case 'install':
  case 'build':
    run('node', [path.join(scripts, 'npm-postinstall.js')]);
    break;

  case 'update':
    console.log('Updating ' + PKG + ' to the latest version…');
    run('npm', ['install', '-g', PKG + '@latest']);
    if (isTetherShot(SYSTEM_APP)) {
      console.log('The signed /Applications copy is preserved. Use Check for Updates in TetherShot to update the app.');
    }
    console.log('Relaunching the canonical installation…');
    quiet('/usr/bin/pkill', ['-x', 'TetherShot']);
    run('/usr/bin/open', ['-n', appPath()]);
    break;

  case 'setup-wifi':
    run('/bin/bash', [path.join(scripts, 'install-tunneld.sh')]);
    break;

  case 'uninstall':
    quiet('/usr/bin/pkill', ['-x', 'TetherShot']);
    quiet('/bin/rm', ['-rf', USER_APP]);
    console.log('Removed ' + USER_APP);
    if (isTetherShot(SYSTEM_APP)) {
      console.log('The signed copy remains at ' + SYSTEM_APP + '; move it to Trash in Finder to remove it.');
    }
    console.log('To remove the Wi-Fi tunnel service:  bash ' + path.join(scripts, 'uninstall-tunneld.sh'));
    break;

  case 'version':
  case '-v':
  case '--version':
    console.log(require('../package.json').version);
    break;

  case 'where':
    console.log(APP);
    break;

  default:
    console.log([
      'tethershot — iPhone screenshots from your Mac menu bar',
      '',
      'Usage:',
      '  tethershot [launch]    Open the app (default)',
      '  tethershot install     Build from source & install to ~/Applications',
      '  tethershot update      Update to the latest published version & relaunch',
      '  tethershot setup-wifi  Install the Wi-Fi tunnel service (one-time)',
      '  tethershot uninstall   Remove the app',
      '  tethershot version     Print the installed version',
    ].join('\n'));
}
