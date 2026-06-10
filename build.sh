#!/usr/bin/env bash
#
# Builds TetherShot and packages it into a launchable TetherShot.app bundle.
# The .app wrapper is required so macOS reads Info.plist (LSUIElement +
# NSCameraUsageDescription) -- running the bare binary would crash on the
# first camera request.
#
# Usage:  ./build.sh [debug|release]   (default: release)
#         open TetherShot.app          to run it.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="TetherShot.app"

echo "[1/3] Compiling (${CONFIG})..."
swift build -c "${CONFIG}"
BIN="$(swift build -c "${CONFIG}" --show-bin-path)/TetherShot"

echo "[2/3] Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/TetherShot"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

# Ad-hoc sign so TCC (Camera) can attribute permission to a stable bundle id.
echo "[3/3] Ad-hoc signing..."
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || \
    echo "      (codesign skipped -- app still runs, camera prompt may repeat)"

echo "Done. Built ${APP}"
echo "Run it with:  open ${APP}"
