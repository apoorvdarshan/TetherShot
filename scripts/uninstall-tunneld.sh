#!/usr/bin/env bash
#
# Removes the TetherShot tunneld LaunchDaemon installed by install-tunneld.sh.
set -euo pipefail

LABEL="com.apoorvdarshan.tethershot.tunneld"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

ROOT_SCRIPT="$(mktemp /tmp/tethershot-root.XXXXXX)"
cat > "$ROOT_SCRIPT" <<ROOT
#!/bin/bash
launchctl bootout system "${PLIST}" 2>/dev/null || true
rm -f "${PLIST}"
ROOT
chmod +x "$ROOT_SCRIPT"

echo "Removing ${LABEL} (admin password prompt incoming)..."
osascript -e "do shell script \"/bin/bash '${ROOT_SCRIPT}'\" with administrator privileges with prompt \"TetherShot: remove the iPhone Wi-Fi tunnel service.\""
rm -f "$ROOT_SCRIPT"
echo "Removed."
