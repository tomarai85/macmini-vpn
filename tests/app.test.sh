#!/bin/bash
# app.test.sh — build the menu-bar app into a temp folder and run its own checks. Never touches the
# installed app or the menu bar.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  NG   $1${2:+ — $2}"; }
D="$(mktemp -d "${TMPDIR:-/tmp}/mmvpn-app.XXXXXX")"; trap 'rm -rf "$D"' EXIT
APP="$D/Mac mini VPN.app"
# The checks run a copy of the binary OUTSIDE the bundle: running it inside a temp .app registers
# that bundle with Launch Services, where it would linger next to the installed app.
BIN="$D/MacminiVPN"

echo "── menu-bar app ──"
if "$HERE/../app/build.sh" "$APP" test.mmvpn.app >/dev/null 2>"$D/err"; then ok "builds"
else bad "build failed" "$(head -5 "$D/err")"; echo; printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"; exit 1; fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null && [ "$(defaults read "$APP/Contents/Info" CFBundleDisplayName)" = "Mac mini VPN" ] \
  && ok "bundle named Mac mini VPN" || bad "Info.plist"
[ "$(defaults read "$APP/Contents/Info" LSUIElement)" = 1 ] && ok "menu-bar only (no Dock icon)" || bad "LSUIElement"
codesign -v "$APP" 2>/dev/null && ok "signed (ad hoc)" || bad "codesign"
[ "$(defaults read "$APP/Contents/Info" CFBundleIconFile)" = AppIcon ] && [ -s "$APP/Contents/Resources/AppIcon.icns" ] \
  && ok "has its icon" || bad "icon missing"
cp "$APP/Contents/MacOS/MacminiVPN" "$BIN"

out="$("$BIN" --selftest 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "selftest: $(echo "$out" | grep -c PASS) checks" || bad "selftest" "$(echo "$out" | grep FAIL | head -3)"

mkdir -p "$D/conf"
printf 'HOME_MAC="me@x"\nSOCKS_PORT=1192   # a comment\nPAC_PORT="1191"\n' > "$D/conf/config"
cfg="$(MMVPN_CONFIG_DIR="$D/conf" MMVPN_CTL=/x/mmvpn "$BIN" --print-config)"
[ "$cfg" = "$(printf 'pac http://127.0.0.1:1191/jp.pac\nsocks 1192\nctl /x/mmvpn\nflag %s/conf/tools-via-japan' "$D")" ] \
  && ok "reads ports from the config (quotes and comments allowed)" || bad "config" "$cfg"
cfg="$(MMVPN_CONFIG_DIR="$D/none" "$BIN" --print-config)"
grep -q 'pac http://127.0.0.1:1081/jp.pac' <<<"$cfg" && grep -q 'socks 1082' <<<"$cfg" \
  && ok "defaults without a config: 1081 and 1082" || bad "defaults" "$cfg"

echo
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
