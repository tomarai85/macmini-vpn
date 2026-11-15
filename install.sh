#!/bin/bash
# install.sh — set up Mac mini VPN on the Mac you travel with. Safe to run again after a change.
#
#   ./install.sh            install, start the background parts and the menu-bar app
#   ./install.sh --no-app   everything except the menu-bar app (terminal use: mmvpn up / down)
#
# Installs, all under your own user (no sudo):
#   ~/.config/macmini-vpn/       config (you write it), pac/jp.pac, kcp-client.json, logs/
#   ~/.local/bin/mmvpn           on/off from a terminal
#   ~/.local/bin/mmvpn-tunnel    keeps the tunnel open
#   ~/Applications/Mac mini VPN.app
#   ~/Library/LaunchAgents/com.macminivpn.{pac,kcp,tunnel,app}.plist
# Routing stays off until you turn it on.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WITH_APP=1
[ "${1:-}" = "--no-app" ] && WITH_APP=0

CONF_DIR="${MMVPN_CONFIG_DIR:-$HOME/.config/macmini-vpn}"
LAUNCHCTL="${LAUNCHCTL_BIN:-launchctl}"
CONF="$CONF_DIR/config"

die() { echo "install: $*" >&2; exit 1; }

if [ ! -f "$CONF" ]; then
  mkdir -p "$CONF_DIR"
  cp "$HERE/config.example" "$CONF"
  die "wrote $CONF — set HOME_MAC (and the rest if needed), then run ./install.sh again."
fi
# shellcheck source=/dev/null
. "$CONF"
# These four can be changed in the config too (the tests install a second copy side by side).
ID="${MMVPN_ID:-com.macminivpn}"
BIN_DIR="${MMVPN_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${MMVPN_APP_DIR:-$HOME/Applications}"
AGENTS="${MMVPN_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
[ -n "${HOME_MAC:-}" ] && [ "$HOME_MAC" != "user@100.64.0.1" ] || die "set HOME_MAC in $CONF"
case "$HOME_MAC" in *@*) ;; *) die "HOME_MAC must look like user@address" ;; esac
SOCKS_PORT="${SOCKS_PORT:-1082}"; PAC_PORT="${PAC_PORT:-1081}"
KCP_LOCAL_PORT="${KCP_LOCAL_PORT:-2222}"; KCP_PORT="${KCP_PORT:-4000}"; USE_KCP="${USE_KCP:-yes}"
HOME_ADDR="${HOME_MAC#*@}"

[ -x /usr/bin/python3 ] && /usr/bin/python3 -c '' 2>/dev/null \
  || die "python3 is missing: install the Xcode Command Line Tools (xcode-select --install)"
KCPTUN_CLIENT=""
if [ "$USE_KCP" = yes ]; then
  KCPTUN_CLIENT="${KCPTUN_CLIENT:-$(command -v kcptun_client || true)}"
  for c in /opt/homebrew/bin/kcptun_client /usr/local/bin/kcptun_client; do
    [ -z "$KCPTUN_CLIENT" ] && [ -x "$c" ] && KCPTUN_CLIENT="$c"
  done
  [ -n "$KCPTUN_CLIENT" ] || die "kcptun_client not found: brew install kcptun (or set USE_KCP=no)"
fi

mkdir -p "$CONF_DIR/pac" "$CONF_DIR/logs" "$BIN_DIR" "$AGENTS"

# 1. scripts
install -m 755 "$HERE/bin/mmvpn" "$HERE/bin/mmvpn-tunnel" "$BIN_DIR/"

# 2. PAC, pointed at this SOCKS port (only that file is served, not the config folder)
sed "s/SOCKS5 127\.0\.0\.1:1082/SOCKS5 127.0.0.1:$SOCKS_PORT/" "$HERE/pac/jp.pac" > "$CONF_DIR/pac/jp.pac"
grep -q "SOCKS5 127.0.0.1:$SOCKS_PORT\"" "$CONF_DIR/pac/jp.pac" || die "could not set the port in jp.pac"

# 3. kcptun client settings. mtu 1200 fits inside Tailscale's 1280-byte packets. No encryption at
# this layer: ssh inside it encrypts everything (and Tailscale does too).
if [ "$USE_KCP" = yes ]; then
  cat > "$CONF_DIR/kcp-client.json" <<EOF
{
  "localaddr": "127.0.0.1:$KCP_LOCAL_PORT",
  "remoteaddr": "$HOME_ADDR:$KCP_PORT",
  "crypt": "none",
  "mode": "fast3",
  "mtu": 1200,
  "sndwnd": 256,
  "rcvwnd": 2048,
  "datashard": 10,
  "parityshard": 3,
  "nocomp": true,
  "conn": 1,
  "autoexpire": 0,
  "sockbuf": 8388608,
  "keepalive": 10
}
EOF
fi

# 4. launch agents
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
agent() {  # agent <suffix> <keepalive true|false> <program> [args...]
  local label="$ID.$1" keep="$2" log="$CONF_DIR/logs/$1.log"; shift 2
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key><array>'
    for a in "$@"; do echo "    <string>$(xml "$a")</string>"; done
    echo '  </array>'
    echo '  <key>EnvironmentVariables</key><dict>'
    echo "    <key>MMVPN_CONFIG_DIR</key><string>$(xml "$CONF_DIR")</string>"
    echo "    <key>MMVPN_CTL</key><string>$(xml "$BIN_DIR/mmvpn")</string>"
    echo '    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>'
    echo '  </dict>'
    echo '  <key>RunAtLoad</key><true/>'
    echo "  <key>KeepAlive</key><$keep/>"
    echo '  <key>ThrottleInterval</key><integer>10</integer>'
    echo "  <key>StandardOutPath</key><string>$(xml "$log")</string>"
    echo "  <key>StandardErrorPath</key><string>$(xml "$log")</string>"
    echo '</dict></plist>'
  } > "$AGENTS/$label.plist"
  plutil -lint "$AGENTS/$label.plist" >/dev/null || die "bad plist $label"
}
reload() {  # (re)start an agent so a re-install takes effect
  "$LAUNCHCTL" bootout "gui/$(id -u)/$ID.$1" >/dev/null 2>&1 || true
  "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$AGENTS/$ID.$1.plist"
}

agent pac true /usr/bin/python3 -m http.server "$PAC_PORT" --bind 127.0.0.1 --directory "$CONF_DIR/pac"
reload pac
if [ "$USE_KCP" = yes ]; then
  agent kcp true "$KCPTUN_CLIENT" -c "$CONF_DIR/kcp-client.json"
  reload kcp
else
  "$LAUNCHCTL" bootout "gui/$(id -u)/$ID.kcp" >/dev/null 2>&1 || true
  rm -f "$AGENTS/$ID.kcp.plist"
fi
# The tunnel agent is started by `mmvpn up` and stopped by `mmvpn down`. RunAtLoad brings it back
# after a restart, so routing that was on before a restart works again after it.
agent tunnel true "$BIN_DIR/mmvpn-tunnel"
if "$LAUNCHCTL" print "gui/$(id -u)/$ID.tunnel" >/dev/null 2>&1; then reload tunnel; fi

if [ "$WITH_APP" = 1 ]; then
  APP="$APP_DIR/Mac mini VPN.app"
  mkdir -p "$APP_DIR"
  "$HERE/app/build.sh" "$APP" "$ID.app"
  agent app false "$APP/Contents/MacOS/MacminiVPN"
  reload app
fi

echo
echo "Installed. Next:"
echo "  1. Check the Mac in Japan answers:  ssh $HOME_MAC true"
echo "  2. Turn it on from the menu bar (the Mac mini icon), or: $BIN_DIR/mmvpn up"
