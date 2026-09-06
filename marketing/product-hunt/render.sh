#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BROWSERS=(
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
  "/Applications/Chromium.app/Contents/MacOS/Chromium"
)

render() {
  local html="$1"
  local out="$2"
  for browser in "${BROWSERS[@]}"; do
    if [[ -x "$browser" ]]; then
      "$browser" \
        --headless=new \
        --disable-gpu \
        --hide-scrollbars \
        --window-size=1270,760 \
        --screenshot="$out" \
        "file://$html"
      return 0
    fi
  done
  echo "No headless browser found. Open each HTML at 1270×760 and screenshot manually:" >&2
  echo "  $html" >&2
  return 1
}

render "$ROOT/01-overview.html" "$ROOT/01-overview.png"
render "$ROOT/02-native-app.html" "$ROOT/02-native-app.png"
render "$ROOT/03-local-first.html" "$ROOT/03-local-first.png"

magick "$ROOT/app-icon.png" -resize 240x240^ -gravity center -extent 240x240 "$ROOT/thumbnail-240.png"

echo "Rendered:"
ls -la "$ROOT"/*.png
