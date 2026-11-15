#!/bin/bash
# install.test.sh — install.sh and uninstall.sh into a throwaway folder, with launchctl and
# networksetup as stubs. Checks what a user would otherwise find out only when it fails to start.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  NG   $1${2:+ — $2}"; }

D="$(mktemp -d "${TMPDIR:-/tmp}/mmvpn-install.XXXXXX")"; trap 'rm -rf "$D"' EXIT
mkdir -p "$D/stub"
# `launchctl print` fails like the real one does for a service that is not loaded.
printf '#!/bin/bash\necho "$@" >> "%s/launchctl.calls"\n[ "$1" = print ] && exit 113\nexit 0\n' "$D" > "$D/stub/launchctl"
printf '#!/bin/bash\n[ "$1" = "-listallnetworkservices" ] && printf "x\\nWi-Fi\\n"\n[ "$1" = "-getautoproxyurl" ] && printf "URL: http://127.0.0.1:1191/jp.pac\\nEnabled: Yes\\n"\necho "$@" >> "%s/ns.calls"\nexit 0\n' "$D" > "$D/stub/networksetup"
printf '#!/bin/bash\necho fake-kcptun\n' > "$D/stub/kcptun_client"
chmod +x "$D/stub/"*
C="$D/conf"
env_() { MMVPN_CONFIG_DIR="$C" LAUNCHCTL_BIN="$D/stub/launchctl" NETWORKSETUP_BIN="$D/stub/networksetup" \
         KCPTUN_CLIENT="$D/stub/kcptun_client" "$@"; }
config() {  # config <USE_KCP>
  mkdir -p "$C"
  cat > "$C/config" <<CONF
HOME_MAC="me@100.64.0.9"
USE_KCP="$1"
KCP_PORT=4100
RELAY=""
SOCKS_PORT=1192
PAC_PORT=1191
KCP_LOCAL_PORT=2292
MMVPN_ID=test.mmvpn
MMVPN_BIN_DIR="$D/bin"
MMVPN_APP_DIR="$D/Applications"
MMVPN_AGENTS_DIR="$D/agents"
CONF
}

echo "── install / uninstall (into a temp folder) ──"
out="$(env_ bash "$ROOT/install.sh" --no-app 2>&1)"; rc=$?
[ $rc -ne 0 ] && [ -f "$C/config" ] && grep -q 'HOME_MAC' <<<"$out" \
  && ok "no config yet: writes the example and stops" || bad "first run" "rc=$rc $out"
out="$(env_ bash "$ROOT/install.sh" --no-app 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "refuses to install with the example HOME_MAC" || bad "installed with the placeholder"

config yes
out="$(env_ bash "$ROOT/install.sh" --no-app 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "installs" || bad "install failed" "$out"
for s in pac kcp tunnel; do
  f="$D/agents/test.mmvpn.$s.plist"
  plutil -lint "$f" >/dev/null 2>&1 && ok "$s agent is a valid plist" || bad "$s agent plist" "$f"
done
[ ! -f "$D/agents/test.mmvpn.app.plist" ] && ok "--no-app: no app agent" || bad "--no-app wrote an app agent"
grep -q "<string>$D/conf/pac</string>" "$D/agents/test.mmvpn.pac.plist" \
  && ok "only the pac folder is served, not the config folder" || bad "served folder"
grep -q '<string>1191</string>' "$D/agents/test.mmvpn.pac.plist" && ok "PAC served on PAC_PORT" || bad "PAC port"
grep -q 'SOCKS5 127.0.0.1:1192"' "$C/pac/jp.pac" && ! grep -q '127.0.0.1:1082' "$C/pac/jp.pac" \
  && ok "installed PAC points at SOCKS_PORT" || bad "PAC SOCKS port"
python3 -c "
import json,sys; d=json.load(open('$C/kcp-client.json'))
sys.exit(0 if d['localaddr']=='127.0.0.1:2292' and d['remoteaddr']=='100.64.0.9:4100' and d['mtu']==1200 else 1)" \
  && ok "kcptun client: local port, home address and KCP_PORT from the config" || bad "kcp-client.json"
[ -x "$D/bin/mmvpn" ] && [ -x "$D/bin/mmvpn-tunnel" ] && ok "scripts installed" || bad "scripts"
grep -q "bootstrap gui/$(id -u) $D/agents/test.mmvpn.pac.plist" "$D/launchctl.calls" \
  && grep -q "bootstrap gui/$(id -u) $D/agents/test.mmvpn.kcp.plist" "$D/launchctl.calls" \
  && ok "pac and kcp agents started" || bad "agents started" "$(tr '\n' ' ' < "$D/launchctl.calls")"
grep -q "bootstrap gui/$(id -u) $D/agents/test.mmvpn.tunnel.plist" "$D/launchctl.calls" \
  && bad "the tunnel started at install (it should wait for mmvpn up)" || ok "the tunnel waits for mmvpn up"

config no
: > "$D/launchctl.calls"
out="$(env_ bash "$ROOT/install.sh" --no-app 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ ! -f "$D/agents/test.mmvpn.kcp.plist" ] && ok "USE_KCP=no: no kcptun agent" || bad "USE_KCP=no" "$out"

out="$(env_ bash "$ROOT/uninstall.sh" 2>&1)"
left="$(find "$D/agents" "$D/bin" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = 0 ] && [ -f "$C/config" ] && ok "uninstall removes agents and scripts, keeps the config" \
  || bad "uninstall left $left files" "$out"
grep -q -- '-setautoproxystate Wi-Fi off' "$D/ns.calls" 2>/dev/null \
  && ok "uninstall turns routing off where it points at our PAC" || bad "uninstall routing off"

echo
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
