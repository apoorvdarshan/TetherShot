#!/usr/bin/env node
'use strict';

// `tethershot` CLI — install / launch / update the menu-bar app.

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PKG = 'tethershot';
const APP = path.join(os.homedir(), 'Applications', 'TetherShot.app');
const scripts = path.join(__dirname, '..', 'scripts');

function run(file, args) { execFileSync(file, args, { stdio: 'inherit' }); }
function quiet(file, args) { try { execFileSync(file, args, { stdio: 'ignore' }); } catch (_) {} }

const cmd = (process.argv[2] || 'launch').toLowerCase();

switch (cmd) {
  case 'launch':
  case 'open':
    if (!fs.existsSync(APP)) {
      console.error('TetherShot.app not found in ~/Applications. Run:  tethershot install');
      process.exit(1);
    }
    run('/usr/bin/open', [APP]);
    break;

  case 'install':
  case 'build':
    run('node', [path.join(scripts, 'npm-postinstall.js')]);
    break;

  case 'update':
    console.log('Updating ' + PKG + ' to the latest version…');
    run('npm', ['install', '-g', PKG + '@latest']);
    console.log('Relaunching…');
    quiet('/usr/bin/pkill', ['-x', 'TetherShot']);
    run('/usr/bin/open', ['-n', APP]);
    break;

  case 'setup-wifi':
    run('/bin/bash', [path.join(scripts, 'install-tunneld.sh')]);
    break;

  case 'uninstall':
    quiet('/usr/bin/pkill', ['-x', 'TetherShot']);
    quiet('/bin/rm', ['-rf', APP]);
    console.log('Removed ' + APP);
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
