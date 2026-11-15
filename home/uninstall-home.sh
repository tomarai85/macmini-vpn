#!/bin/bash
# uninstall-home.sh — remove what install-home.sh set up on the Mac in Japan.
set -uo pipefail
if [ "$(id -u)" != 0 ]; then exec sudo /usr/bin/env MMVPN_ID="${MMVPN_ID:-}" MMVPN_HOME_DIR="${MMVPN_HOME_DIR:-}" bash "$0" "$@"; fi
ID="${MMVPN_ID:-com.macminivpn}"
DIR="${MMVPN_HOME_DIR:-/Library/Application Support/MacminiVPN}"
LABEL="$ID.kcp-server"
launchctl bootout "system/$LABEL" >/dev/null 2>&1
rm -f "/Library/LaunchDaemons/$LABEL.plist"
/usr/libexec/ApplicationFirewall/socketfilterfw --remove "$DIR/kcptun_server" >/dev/null 2>&1
rm -rf "$DIR"
echo "removed $LABEL and $DIR"
