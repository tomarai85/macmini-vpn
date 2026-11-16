#!/bin/bash
# ctl.test.sh — `mmvpn set` changes routes only when the exit answers from Japan and the local server
# answers; otherwise nothing changes.
# networksetup, scutil and launchctl are stubs, and so is the exit's answer: a test that can change
# the real proxy setting of the Mac it runs on is a trap, not a test. The local server is a real
# mmvpn-proxy on a spare port.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
V="${1:-$HERE/../bin/mmvpn}"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  NG   $1${2:+ — $2}"; }

D="$(mktemp -d "${TMPDIR:-/tmp}/mmvpn-ctl.XXXXXX")"
PID=""
trap '[ -n "$PID" ] && kill $PID 2>/dev/null; rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/conf/pac"
SPARE=$(/usr/bin/python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
printf 'HOME_MAC="me@100.64.0.9"\nSOCKS_PORT=1099\nPAC_PORT=%s\nMMVPN_ID=test.mmvpn\n' "$SPARE" > "$D/conf/config"
cp "$HERE/../pac/jp.pac" "$D/conf/pac/jp.pac"; cp "$HERE/../sites.example" "$D/conf/sites"
MMVPN_CONFIG_DIR="$D/conf" /usr/bin/python3 "$HERE/../bin/mmvpn-proxy" 2>/dev/null & PID=$!
for _ in $(seq 1 30); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$SPARE/status" && break; sleep 0.1; done

# networksetup remembers what it was given, and scutil reports it, as the real pair does.
cat > "$D/bin/networksetup" <<EOF
#!/bin/bash
echo "\$@" >> "$D/ns.calls"
case "\$1" in
  -listallnetworkservices) printf 'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nUSB 10/100/1000 LAN\n' ;;
  -setautoproxyurl) [ "\$2" = Wi-Fi ] && echo "\$3" > "$D/pac.url" ;;
  -setautoproxystate) [ "\$2" = Wi-Fi ] && rm -f "$D/pac.url" ;;
esac
exit 0
EOF
cat > "$D/bin/scutil" <<EOF
#!/bin/bash
echo '<dictionary> {'
if [ -f "$D/pac.url" ]; then echo '  ProxyAutoConfigEnable : 1'; echo "  ProxyAutoConfigURLString : \$(cat "$D/pac.url")"; fi
echo '}'
EOF
printf '#!/bin/bash\necho "$@" >> "%s/lc.calls"\nexit 0\n' "$D" > "$D/bin/launchctl"
# curl: the exit check (through the SOCKS port) is faked; everything else is the real curl.
cat > "$D/bin/curl" <<EOF
#!/bin/bash
case " \$* " in
  *" socks5h://"*) echo "\$*" >> "$D/curl.calls"; c="\$(cat "$D/country" 2>/dev/null)"
                   [ -n "\$c" ] && printf '{"country":"%s"}' "\$c"; exit 0 ;;
esac
exec /usr/bin/curl "\$@"
EOF
chmod +x "$D/bin/"*
before="$(scutil --proxy 2>/dev/null)"

run() {  # run <country> <args...>   (SERVER= overrides where mmvpn-proxy is asked)
  local c="$1"; shift
  : > "$D/ns.calls"; : > "$D/lc.calls"
  if [ -n "$c" ]; then echo "$c" > "$D/country"; else rm -f "$D/country"; fi
  out="$(NETWORKSETUP_BIN="$D/bin/networksetup" SCUTIL_BIN="$D/bin/scutil" LAUNCHCTL_BIN="$D/bin/launchctl" \
         CURL_BIN="$D/bin/curl" MMVPN_CONFIG_DIR="$D/conf" MMVPN_WAIT="${WAIT_:-2}" \
         ${SERVER:+MMVPN_SERVER="$SERVER"} bash "$V" "$@" 2>&1)"; rc=$?
}
url() { sed 's/&v=.*//' "$D/pac.url" 2>/dev/null; }
tools() { [ -f "$D/conf/tools-via-japan" ] && echo on || echo off; }
PAC="http://127.0.0.1:$SPARE/jp.pac"

echo "── mmvpn (hermetic) ──"
run "" set sites tools
grep -q "bootstrap gui/$(id -u) .*test.mmvpn.tunnel.plist" "$D/lc.calls" \
  && ok "starts the tunnel agent named by the config" || bad "tunnel agent" "$(cat "$D/lc.calls")"
grep -q 'socks5h://127.0.0.1:1099' "$D/curl.calls" && ok "asks through the configured SOCKS port" \
  || bad "SOCKS port" "$(head -1 "$D/curl.calls")"
if [ $rc -ne 0 ] && ! grep -q -- -setautoproxy "$D/ns.calls" && [ "$(tools)" = off ]; then
  ok "no answer from the exit: nothing is turned on"
else bad "something turned on with no exit" "rc=$rc tools=$(tools)"; fi

run "United States" set sites
[ $rc -ne 0 ] && ! grep -q -- -setautoproxyurl "$D/ns.calls" && ok "exit answers from another country: nothing is turned on" \
  || bad "routing turned on for a non-Japan exit" "rc=$rc"

run Japan set sites
[ $rc -eq 0 ] && [ "$(url)" = "$PAC?routes=sites" ] && [ "$(tools)" = off ] \
  && ok "positive control: sites → PAC routes=sites, tools off" || bad "sites" "rc=$rc url=$(url) $out"
grep -q -- "-setautoproxyurl USB 10/100/1000 LAN $PAC?routes=sites&v=" "$D/ns.calls" \
  && ok "every network service gets the URL, not only Wi-Fi" || bad "a service was skipped" "$(cat "$D/ns.calls")"

run "" set sites tools
[ $rc -ne 0 ] && [ "$(url)" = "$PAC?routes=sites" ] && [ "$(tools)" = off ] && ! grep -q -- -setautoproxy "$D/ns.calls" \
  && ok "adding tools with the exit down leaves the running sites untouched" \
  || bad "a failed add changed the running routes" "rc=$rc url=$(url) tools=$(tools)"

run Japan set tools sites
[ "$(url)" = "$PAC?routes=sites" ] && [ "$(tools)" = on ] && ok "sites + tools: PAC sites, tools flag on" \
  || bad "sites + tools" "url=$(url) tools=$(tools)"
run Japan status
printf '%s' "$out" | grep -q "through Japan  : sites tools" && ok "status reads back sites tools" || bad "status" "$out"

run Japan set rest
[ "$(url)" = "$PAC?routes=rest" ] && [ "$(tools)" = off ] && ok "rest alone: PAC rest, tools off" \
  || bad "rest" "url=$(url) tools=$(tools)"
run Japan set rest sites tools
[ "$(url)" = "$PAC?routes=sites,rest" ] && [ "$(tools)" = on ] \
  && ok "all three: PAC sites,rest in a fixed order, tools on" || bad "all three" "url=$(url) tools=$(tools)"

run Japan set tools
grep -q -- "-setautoproxystate Wi-Fi off" "$D/ns.calls" && [ "$(tools)" = on ] \
  && ok "tools alone: PAC cleared, tools on" || bad "tools alone" "url=$(url) tools=$(tools)"
grep -q bootout "$D/lc.calls" && bad "tools alone stopped the tunnel" || ok "tools alone keeps the tunnel"

run "" set
grep -q -- "-setautoproxystate Wi-Fi off" "$D/ns.calls" && [ "$(tools)" = off ] \
  && grep -q 'bootout gui/.*/test.mmvpn.tunnel' "$D/lc.calls" \
  && ok "empty set: PAC cleared, tools off, tunnel stopped (even with the exit down)" \
  || bad "empty set" "tools=$(tools) $(cat "$D/lc.calls")"
run Japan up
[ "$(url)" = "$PAC?routes=sites" ] && ok "up = sites only" || bad "up" "url=$(url)"
run Japan down
[ ! -f "$D/pac.url" ] && [ "$(tools)" = off ] && ok "down = all off" || bad "down"

echo "${PAC}" > "$D/pac.url"
run Japan status
printf '%s' "$out" | grep -q "through Japan  : sites$" && ok "the old bare URL reads back as sites" || bad "bare URL" "$out"

run Japan set sites
SERVER="http://127.0.0.1:1" run Japan set sites tools rest
[ $rc -ne 0 ] && [ "$(url)" = "$PAC?routes=sites" ] && [ "$(tools)" = off ] && ! grep -q -- -setautoproxy "$D/ns.calls" \
  && ok "local server not answering: nothing changes (no route that would silently go direct)" \
  || bad "server down, yet routes changed" "rc=$rc url=$(url) tools=$(tools)"

t0=$SECONDS; WAIT_=3 run "" set sites; dt=$((SECONDS - t0))
[ $dt -le 9 ] && ok "a dead exit gives up by the deadline (${dt}s for 3s)" || bad "the wait overran its deadline" "${dt}s"

run Japan set sites; v1="$(cat "$D/pac.url")"
run Japan set sites; v2="$(cat "$D/pac.url")"
echo "example.jp" >> "$D/conf/sites"
run Japan set sites; v3="$(cat "$D/pac.url")"
case "$v1" in *"&v="????????) ok "the URL carries the version of the PAC served";; *) bad "no version in the URL" "$v1";; esac
[ "$v1" = "$v2" ] && ok "the same PAC keeps the same URL" || bad "the URL changed with nothing edited" "$v1 $v2"
[ "$v1" != "$v3" ] && ok "an edited site list gets a new URL, so browsers fetch it again" || bad "same URL after an edit" "$v1"

run Japan set other
[ $rc -eq 2 ] && ok "an unknown route is refused" || bad "unknown route accepted" "rc=$rc"

[ "$before" = "$(scutil --proxy 2>/dev/null)" ] && ok "this Mac's real proxy setting is unchanged" \
  || bad "the real proxy setting changed during the test"

echo
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
