#!/usr/bin/env bash
#
# Installs a LaunchDaemon that keeps `pymobiledevice3 remote tunneld` running as
# root. tunneld maintains RemoteXPC tunnels to every reachable iPhone (USB and
# Wi-Fi) and exposes them on a local HTTP API, so TetherShot's normal-user
# screenshot command can reach iOS 17+/26 developer services without sudo.
#
# Run once:  ./scripts/install-tunneld.sh   (prompts for your admin password)
set -euo pipefail

LABEL="com.apoorvdarshan.tethershot.tunneld"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG="/tmp/tethershot-tunneld.log"
PMD3="$(command -v pymobiledevice3 || echo /opt/homebrew/bin/pymobiledevice3)"

if [ ! -x "$PMD3" ]; then
    echo "error: pymobiledevice3 not found. Install it first:  pip3 install -U pymobiledevice3" >&2
    exit 1
fi

# Generate the daemon plist for THIS user (HOME lets root find ~/.pymobiledevice3
# pairing records; PATH lets tunneld spawn its helper subprocesses).
TMP_PLIST="$(mktemp /tmp/tethershot-plist.XXXXXX)"
cat > "$TMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PMD3}</string>
        <string>remote</string>
        <string>tunneld</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${LOG}</string>
    <key>StandardErrorPath</key><string>${LOG}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>${HOME}</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST

# All privileged steps in one script so the admin prompt appears exactly once.
ROOT_SCRIPT="$(mktemp /tmp/tethershot-root.XXXXXX)"
cat > "$ROOT_SCRIPT" <<ROOT
#!/bin/bash
set -e
launchctl bootout system "${PLIST}" 2>/dev/null || true
cp "${TMP_PLIST}" "${PLIST}"
chown root:wheel "${PLIST}"
chmod 644 "${PLIST}"
launchctl bootstrap system "${PLIST}" 2>/dev/null || launchctl load -w "${PLIST}"
launchctl enable "system/${LABEL}" 2>/dev/null || true
launchctl kickstart -k "system/${LABEL}" 2>/dev/null || true
ROOT
chmod +x "$ROOT_SCRIPT"

echo "Installing ${LABEL} (admin password prompt incoming)..."
osascript -e "do shell script \"/bin/bash '${ROOT_SCRIPT}'\" with administrator privileges with prompt \"TetherShot needs admin access to install the iPhone Wi-Fi tunnel service.\""

rm -f "$TMP_PLIST" "$ROOT_SCRIPT"
echo "Installed. tunneld is running as root and will start at boot."
echo "Log: ${LOG}"
