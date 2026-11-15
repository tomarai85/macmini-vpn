#!/bin/bash
# install-home.sh — run once on the Mac in Japan. Starts kcptun_server at every boot, so the
# travelling Mac's tunnel can use KCP. Not needed if you set USE_KCP=no.
#
#   ./install-home.sh                 asks for your password (sudo) once
#   KCP_PORT=4000 ./install-home.sh   a different UDP port (must match KCP_PORT in the config)
#
# What it does:
#   * copies kcptun_server to /Library/Application Support/MacminiVPN/ (a fixed path, so the
#     firewall exception below survives Homebrew upgrades)
#   * writes server.json: listen on UDP KCP_PORT, forward to this Mac's ssh (127.0.0.1:22)
#   * a LaunchDaemon, so it runs even when nobody is logged in (a family Mac often sits at the
#     login window). It runs as your user, not as root.
#   * if the macOS firewall is on, allows that one binary in
#
# It listens only on the Tailscale address when Tailscale is found (else on all addresses; anyone
# who reaches the port still has to get past ssh, which needs your key).
set -euo pipefail
if [ "$(id -u)" != 0 ]; then exec sudo /usr/bin/env RUN_USER="$(id -un)" KCP_PORT="${KCP_PORT:-}" LISTEN="${LISTEN:-}" \
  KCPTUN_SERVER="${KCPTUN_SERVER:-}" MMVPN_ID="${MMVPN_ID:-}" MMVPN_HOME_DIR="${MMVPN_HOME_DIR:-}" \
  bash "$0" "$@"; fi
RUN_USER="${RUN_USER:-${SUDO_USER:-}}"
[ -n "$RUN_USER" ] && [ "$RUN_USER" != root ] || { echo "run as your normal user, not root"; exit 1; }
ID="${MMVPN_ID:-com.macminivpn}"
PORT="${KCP_PORT:-4000}"
DIR="${MMVPN_HOME_DIR:-/Library/Application Support/MacminiVPN}"
LABEL="$ID.kcp-server"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

SRC="${KCPTUN_SERVER:-}"
for c in /opt/homebrew/bin/kcptun_server /usr/local/bin/kcptun_server; do
  [ -z "$SRC" ] && [ -x "$c" ] && SRC="$c"
done
[ -n "$SRC" ] && [ -x "$SRC" ] || { echo "kcptun_server not found: brew install kcptun"; exit 1; }

LISTEN="${LISTEN:-}"
if [ -z "$LISTEN" ]; then
  for t in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [ -x "$t" ] && LISTEN="$("$t" ip -4 2>/dev/null | head -1)" && [ -n "$LISTEN" ] && break
  done
fi
LISTEN="${LISTEN:-0.0.0.0}"

/usr/sbin/systemsetup -getremotelogin 2>/dev/null | grep -qi ': on' \
  || echo "note: Remote Login looks off. Turn it on: System Settings > General > Sharing > Remote Login."

mkdir -p "$DIR"
install -m 755 "$SRC" "$DIR/kcptun_server"
cat > "$DIR/server.json" <<JSON
{
  "listen": "$LISTEN:$PORT",
  "target": "127.0.0.1:22",
  "crypt": "none",
  "mode": "fast3",
  "mtu": 1200,
  "sndwnd": 2048,
  "rcvwnd": 512,
  "datashard": 10,
  "parityshard": 3,
  "nocomp": true,
  "sockbuf": 8388608,
  "keepalive": 10
}
JSON
touch "$DIR/server.log"; chown "$RUN_USER" "$DIR/server.log"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>UserName</key><string>$RUN_USER</string>
  <key>ProgramArguments</key><array>
    <string>$DIR/kcptun_server</string><string>-c</string><string>$DIR/server.json</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$DIR/server.log</string>
  <key>StandardErrorPath</key><string>$DIR/server.log</string>
</dict></plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap system "$PLIST"

if "$FW" --getglobalstate 2>/dev/null | grep -q enabled; then
  "$FW" --add "$DIR/kcptun_server" >/dev/null
  "$FW" --unblockapp "$DIR/kcptun_server" >/dev/null
fi
sleep 2
if launchctl print "system/$LABEL" 2>/dev/null | grep -q 'state = running'; then
  echo "kcptun_server is running on $LISTEN:$PORT/udp -> ssh. Use KCP_PORT=$PORT in the travelling Mac's config."
else
  echo "kcptun_server did not start; see $DIR/server.log"; exit 1
fi
