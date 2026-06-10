# TetherShot

A tiny macOS **menu-bar app that screenshots your iPhone** and drops the PNGs into a folder you choose.

Click the menu-bar icon → pick your phone → a pixel-perfect screenshot lands in your designated folder, timestamped. No QuickTime dance, no fiddling.

> **Status: Phase 1 (USB) — working.** Plug an iPhone in over USB, trust the Mac, and capture. Wireless (Wi-Fi) capture is the next phase — see the roadmap.

---

## Why this exists

macOS already lets QuickTime/OBS mirror a tethered iPhone's *screen* (it shows up as an `AVCaptureDevice` of media type `.muxed`). TetherShot wraps that into a one-click menu-bar capture that writes straight to disk — the screenshot tool Apple never shipped.

## Requirements

- macOS 14 (Sonoma) or later — built and tested on macOS 26 (Tahoe)
- Xcode / Swift toolchain (Swift 6.x)
- An iPhone connected by **USB** and set to **Trust This Computer**

## Build & run

```bash
./build.sh            # compiles + packages TetherShot.app
open TetherShot.app    # launches the menu-bar agent
```

On first capture macOS asks for **Camera** permission — that's expected: the iPhone screen is delivered through the camera (AVFoundation) privacy bucket. Grant it.

Screenshots default to `~/Pictures/TetherShot`; change it any time with **Choose Folder…** in the menu.

## How it works (Phase 1)

| Piece | Role |
|------|------|
| `USBCapture` | Flips the CoreMediaIO `AllowScreenCaptureDevices` flag, finds the iPhone as a `.muxed` device, grabs one frame, encodes PNG |
| `AppModel` | Main-actor state: device list, destination folder, status |
| `FolderStore` | Persists the chosen folder via a bookmark |
| `MenuContent` / `TetherShotApp` | SwiftUI `MenuBarExtra` UI, runs as an `LSUIElement` agent (no Dock icon) |

Capture backends sit behind a `CaptureBackend` protocol, so the wireless backend slots in without touching the UI.

## Roadmap

- **Phase 1 — USB capture** ✅ native AVFoundation, pixel-perfect, zero setup beyond Trust.
- **Phase 2 — Wireless (Wi-Fi)** — drive [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3) over a RemoteXPC Wi-Fi tunnel (`developer dvt screenshot`). Needs a one-time USB pairing, Developer Mode, and a privileged tunnel helper. Cable-free and pixel-perfect once set up.
- **Phase 3 — Polish** — capture sound/notification, global hotkey, launch-at-login, per-device subfolders.

> **Note on wireless:** the "let the iPhone AirPlay-mirror to the Mac and screenshot that window" trick is intentionally **not** used — on macOS Tahoe the mirrored window blacks out whenever a capture context is active. Phase 2 uses the developer-services path instead, which captures the device's own framebuffer regardless of transport.

## License

MIT © 2026 Apoorv Darshan
