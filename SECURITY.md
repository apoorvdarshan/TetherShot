# Security Policy

## Supported versions

TetherShot is distributed through npm, and only the **latest published version** receives security updates. Please update before reporting an issue:

```bash
tethershot update     # or: npm install -g tethershot@latest
```

| Version | Supported |
|---------|-----------|
| latest (`npm`) | ✅ |
| older releases | ❌ |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub's **[private vulnerability reporting](https://github.com/apoorvdarshan/TetherShot/security/advisories/new)** (Security ▸ "Report a vulnerability"). If that's unavailable to you, reach out via DM to [@apoorvdarshan](https://x.com/apoorvdarshan) and we'll arrange a private channel.

When reporting, please include:

- A description of the issue and its impact
- Steps to reproduce (or a proof of concept)
- Affected version, macOS version, and iOS version
- Any suggested remediation, if you have one

You can expect an initial acknowledgement within a few days. Once a fix is released, we're happy to credit you (unless you prefer to remain anonymous).

## Security model & scope

TetherShot is a **local-first** desktop tool. Things worth knowing:

- **No servers, no telemetry.** Screenshots are written to your local folder and clipboard and are never transmitted by TetherShot. Update checks only read the public npm registry.
- **Camera permission** is used solely to read a USB-connected iPhone's mirrored screen via AVFoundation — never your Mac's camera.
- **Wi-Fi capture** relies on a root `LaunchDaemon` (`tunneld`, from [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3)) that maintains a RemoteXPC tunnel to a device you've paired and trusted. It listens only on `127.0.0.1`. You can remove it any time with `bash scripts/uninstall-tunneld.sh`.
- **Build-from-source install.** The npm package compiles on your machine and is ad-hoc signed; it is not notarized.

**In scope:** the TetherShot app and CLI, its build/install scripts, and the tunnel daemon configuration in this repository.

**Out of scope:** vulnerabilities in third-party dependencies (report those upstream — e.g. `pymobiledevice3`, `libimobiledevice`), Apple frameworks/OS, and npm itself.

## Good practices for users

- Only pair and capture devices you own or are authorized to access.
- Install from the official [`tethershot`](https://www.npmjs.com/package/tethershot) npm package or this repository.
- Keep macOS, your iPhone, and TetherShot up to date.
