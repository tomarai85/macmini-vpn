#!/bin/bash
# uninstall.sh — remove Mac mini VPN from this Mac: routing off, agents stopped and removed, app and
# scripts deleted. Your config folder is kept unless you pass --all.
set -uo pipefail
CONF_DIR="${MMVPN_CONFIG_DIR:-$HOME/.config/macmini-vpn}"
# shellcheck source=/dev/null
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"
ID="${MMVPN_ID:-com.macminivpn}"
BIN_DIR="${MMVPN_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${MMVPN_APP_DIR:-$HOME/Applications}"
AGENTS="${MMVPN_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL="${LAUNCHCTL_BIN:-launchctl}"
NETWORKSETUP="${NETWORKSETUP_BIN:-networksetup}"
PAC="http://127.0.0.1:${PAC_PORT:-1081}/jp.pac"

# Routing off, but only where it points at our PAC: another proxy setting is not ours to clear.
"$NETWORKSETUP" -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' | while read -r svc; do
  [ -z "$svc" ] && continue
  if "$NETWORKSETUP" -getautoproxyurl "$svc" 2>/dev/null | grep -q "^URL: $PAC$"; then
    "$NETWORKSETUP" -setautoproxystate "$svc" off >/dev/null 2>&1
  fi
done
for s in app tunnel kcp pac; do
  "$LAUNCHCTL" bootout "gui/$(id -u)/$ID.$s" >/dev/null 2>&1
  rm -f "$AGENTS/$ID.$s.plist"
done
rm -f "$BIN_DIR/mmvpn" "$BIN_DIR/mmvpn-tunnel"
rm -rf "$APP_DIR/Mac mini VPN.app"
if [ "${1:-}" = "--all" ]; then rm -rf "$CONF_DIR"; echo "removed, including $CONF_DIR"
else echo "removed (kept your settings in $CONF_DIR; --all removes them too)"; fi
