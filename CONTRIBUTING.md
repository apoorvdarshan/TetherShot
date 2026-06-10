# Contributing to TetherShot

Thanks for your interest in improving TetherShot! This is a small, focused macOS utility, and contributions of all sizes are welcome — bug reports, fixes, docs, and features.

## Ways to contribute

- 🐛 **Report a bug** — open an [issue](https://github.com/apoorvdarshan/TetherShot/issues) with your macOS + iOS versions, steps to reproduce, and what you expected.
- 💡 **Suggest a feature** — open an issue describing the use case before sending a large PR, so we can agree on scope.
- 🔧 **Send a pull request** — see the workflow below.
- 📖 **Improve the docs** — the README and the site in [`/web`](web).

## Project layout

```
Sources/TetherShot/
  TetherShotApp.swift     SwiftUI MenuBarExtra entry point (LSUIElement agent)
  MenuContent.swift       the menu UI
  AppModel.swift          main-actor state + orchestration
  Capture/
    CaptureBackend.swift  protocol shared by both backends
    USBCapture.swift      AVFoundation + CoreMediaIO (.muxed) capture
    WirelessCapture.swift pymobiledevice3 / tunneld capture
  System/                 HotKey, LaunchAtLogin, Notifier, Pasteboard, Updater
  Storage/                FolderStore, Filename
  Diagnostics/            Log, Proc
scripts/                  tunneld install/uninstall, npm postinstall
web/                      marketing + docs site (deploys to Vercel)
build.sh                  compiles + packages TetherShot.app (+ icon, version stamp)
```

## Development setup

You need macOS 14+ and the Xcode Command Line Tools.

```bash
git clone https://github.com/apoorvdarshan/TetherShot.git
cd TetherShot

swift build            # quick compile check
./build.sh             # compile + package TetherShot.app (debug: ./build.sh debug)
open TetherShot.app    # run it
```

For wireless work you'll also need `pip3 install -U pymobiledevice3` and a paired iPhone with Developer Mode enabled (see the README's Wireless setup).

### Editing the website

The site is static HTML/CSS/JS in [`/web`](web). Preview it locally:

```bash
python3 -m http.server 3001 --directory web
# open http://localhost:3001
```

Only changes under `/web` trigger a Vercel deploy.

## Pull request workflow

1. Fork and create a branch: `git checkout -b fix/short-description`.
2. Make your change. Keep it focused — one logical change per PR.
3. Make sure it builds cleanly: `swift build` (no errors **or** warnings) and `./build.sh`.
4. Open a PR describing **what** changed and **why**, with before/after notes or screenshots where useful.

## Code style

- Match the surrounding code — naming, comment density, and idioms.
- Keep capture backends behind the `CaptureBackend` protocol so USB and Wi-Fi stay symmetric.
- Don't swallow errors silently — surface them via `lastStatus` and `Log.shared.log(...)`.
- All UI state mutation happens on the main actor (`AppModel` is `@MainActor`).
- Do background/blocking work off the main thread (see `Proc.run`).

## Versioning

`package.json` is the single source of truth for the version; `build.sh` stamps it into the bundle. Bumps go through `npm version <patch|minor|major>`.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
