<div align="center">

<img src="https://raw.githubusercontent.com/apoorvdarshan/TetherShot/main/web/assets/logo.png" width="168" alt="TetherShot logo" />

<h1>TetherShot</h1>

<strong>Screenshot your iPhone, straight from the Mac menu bar.</strong>

<p>USB or Wi-Fi · pixel-perfect captures · saved to a folder you choose · copied to your clipboard.</p>

<p>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white" alt="Swift 6" />
  <img src="https://img.shields.io/badge/UI-SwiftUI-1575F9?logo=swift&logoColor=white" alt="SwiftUI" />
  <img src="https://img.shields.io/badge/iPhone-USB%20%2B%20Wi--Fi-5856D6?logo=apple&logoColor=white" alt="iPhone USB + Wi-Fi" />
  <img src="https://img.shields.io/npm/v/tethershot?logo=npm&label=npm&color=CB3837" alt="npm version" />
  <img src="https://img.shields.io/github/stars/apoorvdarshan/TetherShot?logo=github&color=FFCA28" alt="GitHub stars" />
  <img src="https://img.shields.io/badge/license-MIT-3DA639" alt="MIT License" />
  <a href="https://www.producthunt.com/products/tethershot"><img src="https://img.shields.io/badge/Product_Hunt-Vote-DA552F?logo=producthunt&logoColor=white" alt="Vote on Product Hunt" /></a>
</p>

<p>
  <a href="https://tethershot.apoorvdarshan.com"><b>Website</b></a> ·
  <a href="https://www.npmjs.com/package/tethershot">npm</a> ·
  <a href="#installation">Install</a> ·
  <a href="https://tethershot.apoorvdarshan.com/docs.html">Docs</a> ·
  <a href="#support">Support</a>
</p>

<p><code>npm install -g tethershot</code></p>

<br />

<img src="https://raw.githubusercontent.com/apoorvdarshan/TetherShot/main/web/assets/og.jpg" width="760" alt="TetherShot preview" />

</div>

---

> **Status — shipping.** USB + Wi-Fi capture, clipboard, global hotkey, per-device folders, npm install, and in-app self-update are all working. Built and tested on macOS 26 (Tahoe) with iOS 26.

## Why TetherShot

macOS already lets QuickTime/OBS mirror a tethered iPhone's *screen* (it appears as an `AVCaptureDevice` of media type `.muxed`). TetherShot wraps that into a one-click menu-bar capture that writes straight to disk and your clipboard — and adds **cable-free Wi-Fi capture** through Apple's developer-services tunnel. It's the iPhone screenshot tool Apple never shipped.

## Features

- 🔌 **USB capture** — a trusted, cabled iPhone is grabbed at full resolution via native AVFoundation. Instant, zero setup.
- 📶 **Wi-Fi capture** — cable-free over your local network via a RemoteXPC tunnel ([`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3)). Pixel-perfect, even when the phone is locked.
- 📋 **Clipboard** — every capture is copied, ready to paste (toggle on by default).
- ⌨️ **Global hotkey** — press <kbd>⌘⇧7</kbd> anywhere to capture every connected device.
- 🗂️ **Your folder, your rules** — any destination, timestamped filenames, optional per-device subfolders.
- ⬆️ **Self-updating** — in-app **Check for Updates** pulls the latest from npm, rebuilds, and relaunches.
- 🚀 **Launch at login**, runs as a background menu-bar agent (no Dock icon).
- 🔒 **Local-first** — no account, no analytics, no servers. Screenshots never leave your Mac.

## Requirements

- **macOS 14 (Sonoma)+** — developed/tested on macOS 26 (Tahoe)
- **Xcode Command Line Tools** — `xcode-select --install` (needed to build from source)
- **Node.js 18+** — to install via npm
- An **iPhone** you can set to *Trust This Computer*
- For Wi-Fi: iPhone + Mac on the same network, plus [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3)

## Installation

### Via npm (recommended)

```bash
npm install -g tethershot     # installs the CLI (and builds the app)
tethershot install            # ensure the app is built into ~/Applications
tethershot                    # launch it
```

It **builds from source on your machine**, so the app gets **no Gatekeeper quarantine** — it just runs, no "unidentified developer" wall, no notarization. It lands in `~/Applications` (no sudo).

> npm 11+ blocks `postinstall` scripts by default, so if the app isn't built after `npm install`, the explicit `tethershot install` step always does it.

### From source

```bash
git clone https://github.com/apoorvdarshan/TetherShot.git
cd TetherShot
./build.sh             # compiles + packages TetherShot.app
open TetherShot.app     # launches the menu-bar agent
```

On first USB capture, macOS asks for **Camera** permission — expected: the iPhone screen is delivered through the AVFoundation (camera) privacy bucket. TetherShot never uses your Mac's camera.

## Usage

Click the menu-bar icon → pick your phone → the PNG saves to your folder (default `~/Pictures/TetherShot`) and copies to your clipboard. Or just press the hotkey.

| Option | What it does |
|---|---|
| <kbd>⌘⇧7</kbd> | Quick-capture every connected device, from anywhere |
| **Copy to Clipboard** | Also place each capture on the clipboard (default on) |
| **Organize by Device** | Save into a per-device subfolder |
| **Choose Folder…** | Pick any destination; remembered across launches |
| **Launch at Login** | Keep TetherShot in your menu bar across reboots |
| **Check for Updates** | Update via npm and relaunch |

## Wireless (Wi-Fi) setup — one time

Wi-Fi capture uses a root LaunchDaemon (`tunneld`) that keeps a RemoteXPC tunnel alive so captures need no sudo.

```bash
pip3 install -U pymobiledevice3            # the engine
tethershot setup-wifi                       # installs the tunnel daemon (admin password once)
```

Then, with the iPhone connected by USB once:

- Enable **Developer Mode** — Settings ▸ Privacy & Security ▸ Developer Mode
- Enable Wi-Fi reachability — `pymobiledevice3 lockdown wifi-connections --state on`

After that you can unplug. While the iPhone and Mac share a Wi-Fi network, the menu shows it as **(Wi-Fi)** and `tunneld` discovers it automatically. Remove the daemon with `bash scripts/uninstall-tunneld.sh`.

> **Why not AirPlay mirroring?** On macOS Tahoe, a mirrored iPhone window blacks out whenever a capture context is active — so TetherShot uses the developer-services path instead, capturing the device's own framebuffer regardless of transport.

## CLI

```bash
tethershot            # launch the app
tethershot install    # build & install to ~/Applications
tethershot update     # update to the latest published version
tethershot setup-wifi # install the Wi-Fi tunnel service
tethershot uninstall  # remove the app
tethershot version    # print the installed version
```

## How it works

| Component | Role |
|---|---|
| `USBCapture` | Flips the CoreMediaIO screen-capture flag, finds the iPhone as a `.muxed` device, grabs one frame → PNG |
| `WirelessCapture` | Talks to the `tunneld` HTTP API, runs `pymobiledevice3 developer dvt screenshot` over the Wi-Fi tunnel |
| `Updater` | Checks the npm registry, runs `npm install -g tethershot@latest`, relaunches via a detached helper |
| `AppModel` | Main-actor state: device list, destination folder, options, status |
| `MenuContent` / `TetherShotApp` | SwiftUI `MenuBarExtra` UI, runs as an `LSUIElement` agent |

Capture backends sit behind a `CaptureBackend` protocol, so USB and Wi-Fi share one code path. The marketing/docs site lives in [`/web`](web) and deploys to [tethershot.apoorvdarshan.com](https://tethershot.apoorvdarshan.com).

## Contributing

Contributions are welcome — see **[CONTRIBUTING.md](CONTRIBUTING.md)** for how to build, the project layout, and the PR flow.

## Security

Found a vulnerability? Please report it privately — see **[SECURITY.md](SECURITY.md)**.

## Support

If TetherShot is useful to you:

- 🚀 **[Vote on Product Hunt](https://www.producthunt.com/products/tethershot)**
- ⭐ **Star** the repo
- ☕ **[Support on Ko-fi](https://ko-fi.com/apoorvdarshan)**
- 🐦 **Follow [@apoorvdarshan](https://x.com/apoorvdarshan)** on X

## License

[MIT](LICENSE) © 2026 [Apoorv Darshan](https://github.com/apoorvdarshan)

<sub>Not affiliated with Apple Inc. iPhone, macOS, and Apple are trademarks of Apple Inc.</sub>
