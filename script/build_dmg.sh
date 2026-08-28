#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(node -p "require('$ROOT_DIR/package.json').version")"
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$DIST_DIR/dmg-work"
ARM_BUILD_DIR="$DIST_DIR/swift-build-arm64"
X64_BUILD_DIR="$DIST_DIR/swift-build-x86_64"
APP="$WORK_DIR/TetherShot.app"
CONTENTS="$APP/Contents"
DMG="$DIST_DIR/TetherShot-${VERSION}-universal.dmg"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
ENTITLEMENTS="$ROOT_DIR/Resources/TetherShot.entitlements"

cd "$ROOT_DIR"
rm -rf "$ARM_BUILD_DIR" "$X64_BUILD_DIR"
swift build -c release --arch arm64 --scratch-path "$ARM_BUILD_DIR"
swift build -c release --arch x86_64 --scratch-path "$X64_BUILD_DIR"
ARM_BIN="$(swift build -c release --arch arm64 --scratch-path "$ARM_BUILD_DIR" --show-bin-path)/TetherShot"
X64_BIN="$(swift build -c release --arch x86_64 --scratch-path "$X64_BUILD_DIR" --show-bin-path)/TetherShot"

rm -rf "$WORK_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$WORK_DIR/volume"
lipo -create "$ARM_BIN" "$X64_BIN" -output "$CONTENTS/MacOS/TetherShot"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp \
  scripts/install-tunneld.sh \
  scripts/uninstall-tunneld.sh \
  scripts/wireless-preview.py \
  "$CONTENTS/Resources/"
chmod +x \
  "$CONTENTS/MacOS/TetherShot" \
  "$CONTENTS/Resources/"*.sh \
  "$CONTENTS/Resources/"*.py

# Wi-Fi live preview depends on this bundled helper. Fail the release build
# here instead of producing a signed app that can discover phones but cannot
# display them.
[[ -x "$CONTENTS/Resources/wireless-preview.py" ]] || {
  echo "error: packaged app is missing the Wi-Fi live-preview helper" >&2
  exit 1
}

ICON_TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICON_TMP"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICON_TMP/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" Resources/AppIcon.png --out "$ICON_TMP/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_TMP" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICON_TMP")"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
  echo "warning: DEVELOPER_ID_APPLICATION is unset; creating an ad-hoc local-test DMG" >&2
  codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
entitlements_dump="$(mktemp)"
cleanup_entitlements_dump() {
  [[ ! -e "$entitlements_dump" ]] || unlink "$entitlements_dump"
}
trap cleanup_entitlements_dump EXIT
codesign -d --entitlements :- "$APP" > "$entitlements_dump" 2>/dev/null
camera_entitlement="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.camera' "$entitlements_dump" 2>/dev/null || true)"
cleanup_entitlements_dump
[[ "$camera_entitlement" == "true" ]] || {
  echo "error: packaged app is missing the Camera entitlement" >&2
  exit 1
}
cp -R "$APP" "$WORK_DIR/volume/TetherShot.app"
ln -s /Applications "$WORK_DIR/volume/Applications"
rm -f "$DMG"
hdiutil create -volname "TetherShot" -srcfolder "$WORK_DIR/volume" -ov -format UDZO "$DMG"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

if [[ "${NOTARIZE:-0}" == "1" ]]; then
  if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    : "${ASC_KEY_ID:?ASC_KEY_ID is required for ASC notarization}"
    notary_args=(
      --key "$ASC_KEY_PATH"
      --key-id "$ASC_KEY_ID"
    )
    if [[ -n "${ASC_ISSUER_ID:-}" ]]; then
      notary_args+=(--issuer "$ASC_ISSUER_ID")
    fi
    xcrun notarytool submit "$DMG" "${notary_args[@]}" --wait
  else
    : "${APPLE_ID:?APPLE_ID is required for Apple ID notarization}"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for Apple ID notarization}"
    : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required for Apple ID notarization}"
    xcrun notarytool submit "$DMG" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --wait
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

file "$CONTENTS/MacOS/TetherShot"
rm -rf "$WORK_DIR" "$ARM_BUILD_DIR" "$X64_BUILD_DIR"
echo "$DMG"
