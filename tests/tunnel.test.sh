#!/bin/bash
# tunnel.test.sh — hermetic tests for mmvpn-tunnel (route choice and switching).
#
# ssh, nettop, launchctl and nc are stubs on PATH, so nothing real is dialled and no real port is
# used. Each stub ssh records which route it was asked for; a route "fails" by exiting at once and
# "works" by staying up, which is all mmvpn-tunnel can see of a real tunnel.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
V="${1:-$HERE/../bin/mmvpn-tunnel}"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  NG   $1${2:+ — $2}"; }

D="$(mktemp -d "${TMPDIR:-/tmp}/mmvpn-tunnel.XXXXXX")"
JP=""
cleanup() { [ -n "$JP" ] && { pkill -P "$JP" 2>/dev/null; kill "$JP" 2>/dev/null; }; rm -rf "$D"; }
trap cleanup EXIT
mkdir -p "$D/bin" "$D/behavior" "$D/conf"

# ssh: classify the route from its arguments, record it, then fail or stay up as told.
cat > "$D/bin/ssh" <<STUB
#!/bin/bash
a=" \$* "
r=ssh
[[ "\$a" == *" -p 2299 "* ]] && r=kcp
[[ "\$a" == *" -J "* ]] && r=relay
echo "\$r" >> "$D/calls"
if [ "\$(cat "$D/behavior/\$r" 2>/dev/null || echo ok)" = ok ]; then exec sleep 1000; fi
sleep 0.3; exit 255
STUB
cat > "$D/bin/nettop" <<STUB
#!/bin/bash
printf ',bytes_in,\nssh.1,%s,\n' "\$(cat "$D/bytes" 2>/dev/null || echo 0)"
STUB
cat > "$D/bin/launchctl" <<STUB
#!/bin/bash
echo "kick \$*" >> "$D/calls"
STUB
cat > "$D/bin/nc" <<STUB
#!/bin/bash
[ -f "$D/port_taken" ] && exit 0
exit 1
STUB
chmod +x "$D/bin/"*

config() {  # config [USE_KCP] [RELAY]
  printf 'HOME_MAC="me@100.64.0.9"\nUSE_KCP="%s"\nRELAY="%s"\nSOCKS_PORT=1099\nKCP_LOCAL_PORT=2299\nMMVPN_ID=test.mmvpn\n' \
    "${1:-yes}" "${2-relay@100.64.0.8}" > "$D/conf/config"
}
start() {  # start mmvpn-tunnel against the stubs with short timings
  : > "$D/calls"
  PATH="$D/bin:$PATH" MMVPN_CONFIG_DIR="$D/conf" \
    MMVPN_TICK=1 MMVPN_FASTFAIL=2 MMVPN_SKIP=4 MMVPN_HOLD="${HOLD:-3}" \
    bash "$V" > "$D/log" 2>&1 &
  JP=$!
}
stop() { pkill -P "$JP" 2>/dev/null; kill "$JP" 2>/dev/null; wait "$JP" 2>/dev/null; JP=""; }
tunnels() { grep -v kick "$D/calls" | tr '\n' ' ' | sed 's/ $//'; }
reset() { rm -f "$D/bytes" "$D/port_taken" "$D/behavior/"*; config; }

echo "── mmvpn-tunnel (hermetic) ──"

# 1 — the first route works: one kcp tunnel, nothing else
reset
start; sleep 3; stop
[ "$(tunnels)" = "kcp" ] && ok "kcp works: one kcp tunnel" || bad "kcp works" "$(tunnels)"
grep -q -- "-o HostKeyAlias=100.64.0.9 me@127.0.0.1" "$D/log" 2>/dev/null; true

# 2 — kcp fails: plain ssh next, at once; relay only if ssh fails too
reset; echo fail > "$D/behavior/kcp"
start; sleep 3; stop
[ "$(tunnels)" = "kcp ssh" ] && ok "kcp dead: falls through to ssh at once" || bad "kcp dead" "$(tunnels)"
reset; echo fail > "$D/behavior/kcp"; echo fail > "$D/behavior/ssh"
start; sleep 3; stop
[ "$(tunnels)" = "kcp ssh relay" ] && ok "kcp and ssh dead: relay" || bad "relay" "$(tunnels)"

# 3 — positive control: back on kcp once it has been fine for HOLD, while idle
reset; echo fail > "$D/behavior/kcp"
start; sleep 1; rm -f "$D/behavior/kcp"; sleep 8; stop
[ "$(tunnels)" = "kcp ssh kcp" ] && ok "kcp recovered: switched back while idle" || bad "switch back" "$(tunnels)"

# 4 — never while video flows
reset; echo fail > "$D/behavior/kcp"; echo 5000000 > "$D/bytes"
start; sleep 1; rm -f "$D/behavior/kcp"; sleep 8; stop
[ "$(tunnels)" = "kcp ssh" ] && ok "video flowing: no switch" || bad "video flowing" "$(tunnels)"

# 5 — a working fallback is not swapped for a route that failed within HOLD
reset; echo fail > "$D/behavior/kcp"
HOLD=600 start; sleep 1; rm -f "$D/behavior/kcp"; sleep 6; stop
[ "$(tunnels)" = "kcp ssh" ] && ok "recently failed kcp: stays on the working fallback" || bad "HOLD" "$(tunnels)"

# 6 — never moves from a working earlier route to a later one. Shape: kcp fails, ssh runs for a
# while and then drops, kcp is retried and works. kcp failed recently and ssh never did, so a rule
# of "the first route that has not failed lately" would point at ssh and keep dropping the working
# kcp tunnel; only earlier routes count.
reset; echo fail > "$D/behavior/kcp"
HOLD=600 start; sleep 1; rm -f "$D/behavior/kcp"; sleep 5
pkill -P "$JP" -f 'sleep 1000'; sleep 10; stop
[ "$(tunnels)" = "kcp ssh kcp" ] && ok "on kcp: never moves to a later route" || bad "moved to a later route" "$(tunnels)"

# 7 — offline, then back: kcp returns, the kcptun client was restarted, at most once per 5 min
reset; for r in kcp ssh relay; do echo fail > "$D/behavior/$r"; done
start; sleep 5; rm -f "$D/behavior/"*; sleep 8; stop
last=$(tunnels | awk '{print $NF}')
[ "$last" = kcp ] && ok "after an outage: back on kcp" || bad "after an outage" "$(tunnels)"
grep -q "kick kickstart -k gui/$(id -u)/test.mmvpn.kcp" "$D/calls" && ok "failed kcp: kcptun client restarted" \
  || bad "no kcptun restart" "$(tr '\n' ' ' < "$D/calls")"
n=$(grep -c kick "$D/calls")
[ "$n" -le 1 ] && ok "kcptun restart rate-limited ($n in 13 s)" || bad "kcptun restarted $n times in 13 s"

# 8 — USE_KCP=no and no relay: only plain ssh is ever tried
reset; config no ""; echo fail > "$D/behavior/ssh"
start; sleep 3; stop
t="$(tunnels | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
[ "$t" = "ssh" ] && ok "USE_KCP=no, no relay: ssh only" || bad "USE_KCP=no" "$(tunnels)"

# 9 — something else already listens on the port: wait, start nothing
reset; touch "$D/port_taken"
start; sleep 3; stop
[ -z "$(tunnels)" ] && ok "port already taken: starts no tunnel" || bad "port taken" "$(tunnels)"

echo
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
