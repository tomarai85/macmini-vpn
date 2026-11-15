#!/bin/bash
# pac.test.sh — only the listed sites go to Japan; look-alikes, shared CDNs and sign-in pages don't.
# Every "goes DIRECT" check sits next to a planted positive, so a PAC that sends nothing anywhere
# cannot pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PACFILE="${1:-$HERE/../pac/jp.pac}"
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  NG   $1${2:+ — $2}"; }
[ -x "$JSC" ] || { echo "jsc not found at $JSC"; exit 2; }

JAPAN="abema.tv api.abema.io tver.jp radiko.jp www.nhk.or.jp nhk.jp
  www.netflix.com netflix.com id.netflix.com login.netflix.com
  ipv4-c001-tyo001-ix.1.oca.nflxvideo.net occ-0-1.1.nflxso.net art-s.nflximg.net
  ds-linear-abematv.akamaized.net ds-vod-abematv.akamaized.net linear-abematv.akamaized.net
  si-f-radiko.smartstream.ne.jp tf-f-rpaa-radiko.smartstream.ne.jp dr-wowza.radiko-cf.com
  simul.drdi.st.nhk simul2.drdi.st.nhk abema.tv. ABEMA.TV"
DIRECT="api.anthropic.com github.com google.com my.bank.example
  netflix.com.evil.example notnetflix.com nflxvideo.net.evil.example abema.tv.evil.example notabema.tv
  billing.abema.tv login.abema.tv payment.tver.jp id.abema.tv my.tver.jp
  foo.login.abema.tv a.b.account.tver.jp x.y.billing.abema.tv
  myabematvthing.akamaized.net xabematv.akamaized.net notradiko.smartstream.ne.jp
  www.akamaized.net images.akamaized.net other.smartstream.ne.jp"
# shellcheck disable=SC2086
out="$("$JSC" "$HERE/pac-eval.js" -- "$PACFILE" $JAPAN $DIRECT 2>&1)"
[ -n "$out" ] || { echo "the PAC could not be evaluated"; exit 2; }
verdict() { printf '%s\n' "$out" | awk -v h="$1" '$1==h {print $2}'; }

echo "── PAC ──"
for h in $JAPAN; do
  [ "$(verdict "$h")" = SOCKS5 ] && ok "$h → Japan" || bad "$h should go through Japan" "$(verdict "$h")"
done
for h in $DIRECT; do
  [ "$(verdict "$h")" = DIRECT ] && ok "$h → direct" || bad "$h should go direct" "$(verdict "$h")"
done
n="$(grep -c 'SOCKS5 127.0.0.1:' "$PACFILE")"
[ "$n" = 1 ] && ok "one proxy line, so the installer's port change reaches every listed site" \
  || bad "expected one proxy line" "$n"

echo
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
