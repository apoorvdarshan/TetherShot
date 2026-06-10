# TetherShot

A tiny macOS **menu-bar app that screenshots your iPhone** and drops the PNGs into a folder you choose.

Click the menu-bar icon → pick your phone → a pixel-perfect screenshot lands in your designated folder, timestamped. No QuickTime dance, no fiddling.

> **Status: Phase 1 (USB) + Phase 2 (Wi-Fi) — working.** Capture a tethered iPhone instantly over USB, or cable-free over Wi-Fi after a one-time setup. See the roadmap.

---

## Why this exists

macOS already lets QuickTime/OBS mirror a tethered iPhone's *screen* (it shows up as an `AVCaptureDevice` of media type `.muxed`). TetherShot wraps that into a one-click menu-bar capture that writes straight to disk — the screenshot tool Apple never shipped.

## Requirements

- macOS 14 (Sonoma) or later — built and tested on macOS 26 (Tahoe)
- Xcode / Swift toolchain (Swift 6.x)
- An iPhone connected by **USB** and set to **Trust This Computer**

## Install

### Via npm (recommended)

```bash
npm install -g tethershot     # installs the CLI (+ builds the app)
tethershot install            # ensure the app is built & in ~/Applications
tethershot                    # launch it
```

It **builds from source on your machine** (needs Xcode Command Line Tools — `xcode-select --install`). Because the app is compiled locally, it gets **no Gatekeeper quarantine** — it just runs, no "unidentified developer" dialog, no notarization. The app lands in `~/Applications` (no sudo).

> npm 11+ blocks postinstall scripts by default, so if the app isn't built after `npm install`, the explicit `tethershot install` step always does it. Update any time with **`tethershot update`** or the in-app **Check for Updates**.

### From source

```bash
git clone https://github.com/apoorvdarshan/TetherShot.git
cd TetherShot
./build.sh             # compiles + packages TetherShot.app
open TetherShot.app     # launches the menu-bar agent
```

On first capture macOS asks for **Camera** permission — that's expected: the iPhone screen is delivered through the camera (AVFoundation) privacy bucket. Grant it.

Screenshots default to `~/Pictures/TetherShot`; change it any time with **Choose Folder…** in the menu.

**Shortcuts & options**
- **⌘⇧7** anywhere captures every connected iPhone without opening the menu.
- **Copy to Clipboard** (on by default) puts each capture on the clipboard, ready to paste.
- **Organize by Device** saves into a per-device subfolder.
- **Launch at Login** keeps TetherShot in your menu bar across reboots.

## How it works (Phase 1)

| Piece | Role |
|------|------|
| `USBCapture` | Flips the CoreMediaIO `AllowScreenCaptureDevices` flag, finds the iPhone as a `.muxed` device, grabs one frame, encodes PNG |
| `AppModel` | Main-actor state: device list, destination folder, status |
| `FolderStore` | Persists the chosen folder via a bookmark |
| `MenuContent` / `TetherShotApp` | SwiftUI `MenuBarExtra` UI, runs as an `LSUIElement` agent (no Dock icon) |

Capture backends sit behind a `CaptureBackend` protocol, so the wireless backend slots in without touching the UI.

## Wireless (Wi-Fi) setup — one time

Wi-Fi capture uses Apple's developer services via [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3) over a RemoteXPC tunnel. A small root LaunchDaemon (`tunneld`) keeps the tunnel alive so captures need no sudo.

```bash
pip3 install -U pymobiledevice3           # the engine
./scripts/install-tunneld.sh               # installs the tunnel daemon (asks for admin password once)
```

Then, with the iPhone connected by USB once:
- Enable **Developer Mode** (Settings ▸ Privacy & Security ▸ Developer Mode) — TetherShot needs it on.
- Enable Wi-Fi reachability: `pymobiledevice3 lockdown wifi-connections --state on`

After that you can unplug. As long as the iPhone and Mac are on the same Wi-Fi, the menu shows it as **(Wi-Fi)** and captures are pixel-perfect — `tunneld` discovers it automatically. Remove the daemon any time with `./scripts/uninstall-tunneld.sh`.

## Roadmap

- **Phase 1 — USB capture** ✅ native AVFoundation, pixel-perfect, zero setup beyond Trust.
- **Phase 2 — Wireless (Wi-Fi)** ✅ `pymobiledevice3` + a root `tunneld` LaunchDaemon; `developer dvt screenshot` over the Wi-Fi tunnel. Cable-free and pixel-perfect.
- **Phase 3 — Polish** ✅ global quick-capture hotkey (**⌘⇧7**, works anywhere), launch-at-login, capture notifications, and optional per-device subfolders.
- **Distribution** ✅ published to npm as [`tethershot`](https://www.npmjs.com/package/tethershot) (builds from source, no Gatekeeper quarantine); in-app **Check for Updates** that updates via npm and relaunches.

> **Note on wireless:** the "let the iPhone AirPlay-mirror to the Mac and screenshot that window" trick is intentionally **not** used — on macOS Tahoe the mirrored window blacks out whenever a capture context is active. We use the developer-services path instead, which captures the device's own framebuffer regardless of transport.

## License

MIT © 2026 Apoorv Darshan
