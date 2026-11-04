#!/usr/bin/env bash
# Install or repair the isolated Wi-Fi engine, pairing records, and root tunnel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BREW="$(command -v brew || true)"
if [[ -z "$BREW" ]]; then
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ ! -x "$candidate" ]] || BREW="$candidate"
    done
fi
if [[ -z "$BREW" ]]; then
    echo "Homebrew is required for Wi-Fi setup. Install it from https://brew.sh, then retry." >&2
    exit 1
fi
if [[ "$(id -u)" == 0 ]]; then
    echo "Run this installer as your normal Mac user, without sudo." >&2
    exit 1
fi

BREW_PREFIX="$("$BREW" --prefix)"
[[ -x "$BREW_PREFIX/bin/uv" ]] || "$BREW" install uv
PYTHON="$BREW_PREFIX/opt/python@3.14/bin/python3.14"
[[ -x "$PYTHON" ]] || "$BREW" install python@3.14
UV="$BREW_PREFIX/bin/uv"
SETUP="$SCRIPT_DIR/wireless-setup.py"
REQUIREMENT="$("$PYTHON" "$SETUP" requirement)"
WORK="$(mktemp -d /tmp/tethershot-setup.XXXXXX)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Quote every path as shell data. Install packages as the invoking user, never
# root, and restore the previous daemon if installation or pairing fails.
{
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    printf 'TARGET_UID=%q\n' "$(id -u)"
    printf 'TARGET_USER=%q\n' "$(id -un)"
    printf 'TARGET_HOME=%q\n' "$HOME"
    printf 'PYTHON=%q\n' "$PYTHON"
    printf 'UV=%q\n' "$UV"
    printf 'SETUP=%q\n' "$SETUP"
    printf 'REQUIREMENT=%q\n' "$REQUIREMENT"
    printf 'WORK=%q\n' "$WORK"
    cat <<'ROOT'
LABEL="com.apoorvdarshan.tethershot.tunneld"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
ENVIRONMENT="$TARGET_HOME/.local/share/tethershot/wireless"
if [[ -e "$PLIST" ]]; then cp "$PLIST" "$WORK/previous.plist"; fi
restore_daemon() {
    status=$?
    if [[ $status != 0 && -e "$WORK/previous.plist" ]]; then
        launchctl bootout system "$PLIST" 2>/dev/null || true
        cp "$WORK/previous.plist" "$PLIST"
        chown root:wheel "$PLIST"
        chmod 644 "$PLIST"
        launchctl bootstrap system "$PLIST" 2>/dev/null || true
    fi
    exit "$status"
}
trap restore_daemon EXIT
launchctl bootout system "$PLIST" 2>/dev/null || true
"$PYTHON" "$SETUP" ownership --uid "$TARGET_UID"
as_user() { /usr/bin/sudo -H -u "$TARGET_USER" "$@"; }
if [[ ! -x "$ENVIRONMENT/bin/python" ]]; then
    as_user "$UV" venv --python "$PYTHON" "$ENVIRONMENT"
fi
as_user "$UV" pip install --python "$ENVIRONMENT/bin/python" "$REQUIREMENT"
PAIRING_STATUS="$(as_user "$ENVIRONMENT/bin/python" "$SETUP" pairings)"
as_user "$ENVIRONMENT/bin/python" "$SETUP" plist --output "$WORK/tunneld.plist"
cp "$WORK/tunneld.plist" "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl enable "system/$LABEL"
launchctl bootstrap system "$PLIST"
printf '%s\n' "$PAIRING_STATUS"
ROOT
} > "$WORK/install.sh"
chmod 700 "$WORK/install.sh"

echo "Installing the current Wi-Fi engine and repairing legacy pairing (admin approval required)…"
osascript - "$WORK/install.sh" <<'APPLESCRIPT'
on run argv
    do shell script "/bin/bash " & quoted form of (item 1 of argv) with administrator privileges with prompt "TetherShot needs admin access to repair its iPhone Wi-Fi tunnel service."
end run
APPLESCRIPT
