#!/bin/bash
# ctl.test.sh — `mmvpn up` turns routing on only when the exit answers from Japan.
# networksetup, launchctl and curl are all stubs: a test that can change the real proxy setting of
# the Mac it runs on is a trap, not a test.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
V="${1:-$HERE/../bin/mmvpn}"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  NG   $1${2:+ — $2}"; }

D="$(mktemp -d "${TMPDIR:-/tmp}/mmvpn-ctl.XXXXXX")"; trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/conf"
printf 'HOME_MAC="me@100.64.0.9"\nSOCKS_PORT=1099\nPAC_PORT=1098\nMMVPN_ID=test.mmvpn\n' > "$D/conf/config"
stub() {  # stub <name> <extra shell line>: records its arguments, then runs the extra line
  printf '#!/bin/bash\necho "$@" >> "%s/%s.calls"\n%s\nexit 0\n' "$D" "$1" "$2" > "$D/bin/$1"
  chmod +x "$D/bin/$1"
}
stub networksetup '[ "$1" = "-listallnetworkservices" ] && printf "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nUSB 10/100/1000 LAN\n"'
stub launchctl ''
stub curl "c=\"\$(cat '$D/country' 2>/dev/null)\"; [ -n \"\$c\" ] && printf '{\"country\":\"%s\"}' \"\$c\""
run() { NETWORKSETUP_BIN="$D/bin/networksetup" LAUNCHCTL_BIN="$D/bin/launchctl" CURL_BIN="$D/bin/curl" \
        MMVPN_CONFIG_DIR="$D/conf" MMVPN_WAIT=2 bash "$V" "$@" > "$D/out" 2>&1; }
before="$(scutil --proxy 2>/dev/null)"

echo "── mmvpn (hermetic) ──"
: > "$D/networksetup.calls"; : > "$D/launchctl.calls"; rm -f "$D/country"
run up; rc=$?
grep -q "bootstrap gui/$(id -u) .*test.mmvpn.tunnel.plist" "$D/launchctl.calls" \
  && ok "starts the tunnel agent named by the config" || bad "tunnel agent" "$(cat "$D/launchctl.calls")"
grep -q 'socks5h://127.0.0.1:1099' "$D/curl.calls" && ok "asks through the configured SOCKS port" \
  || bad "SOCKS port" "$(head -1 "$D/curl.calls")"
if [ $rc -ne 0 ] && ! grep -q -- -setautoproxyurl "$D/networksetup.calls"; then
  ok "no answer from the exit: routing stays off"
else bad "routing turned on with no exit" "rc=$rc"; fi

: > "$D/networksetup.calls"; echo "United States" > "$D/country"
run up; rc=$?
if [ $rc -ne 0 ] && ! grep -q -- -setautoproxyurl "$D/networksetup.calls"; then
  ok "exit answers from another country: routing stays off"
else bad "routing turned on for a non-Japan exit" "rc=$rc"; fi

: > "$D/networksetup.calls"; echo Japan > "$D/country"
run up; rc=$?
if [ $rc -eq 0 ] && grep -q -- '-setautoproxyurl Wi-Fi http://127.0.0.1:1098/jp.pac' "$D/networksetup.calls" \
   && grep -q -- '-setautoproxyurl USB 10/100/1000 LAN http://127.0.0.1:1098/jp.pac' "$D/networksetup.calls"; then
  ok "positive control: exit in Japan turns routing on, on every network service"
else bad "positive control" "rc=$rc $(tr '\n' ' ' < "$D/networksetup.calls")"; fi

: > "$D/networksetup.calls"; : > "$D/launchctl.calls"
run down
grep -q -- '-setautoproxystate Wi-Fi off' "$D/networksetup.calls" \
  && grep -q 'bootout gui/.*/test.mmvpn.tunnel' "$D/launchctl.calls" \
  && ok "down: routing off and the tunnel stopped" \
  || bad "down" "$(cat "$D/networksetup.calls" "$D/launchctl.calls" | tr '\n' ' ')"

[ "$before" = "$(scutil --proxy 2>/dev/null)" ] && ok "this Mac's real proxy setting is unchanged" \
  || bad "the real proxy setting changed during the test"

echo
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
