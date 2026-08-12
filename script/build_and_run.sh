#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TetherShot"
BUNDLE_ID="com.apoorvdarshan.tethershot"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT_APP="$ROOT_DIR/.build/TetherShot.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/TetherShot.app"
APP_BINARY="$INSTALLED_APP/Contents/MacOS/TetherShot"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
./build.sh release
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
cp -R "$BUILT_APP" "$INSTALLED_APP"
/usr/bin/codesign --force --deep --sign - "$INSTALLED_APP" >/dev/null 2>&1 || true
# The installed bundle is canonical; do not leave a second app bundle for
# Spotlight or Launch Services to discover in the source checkout.
rm -rf "$BUILT_APP"

open_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
