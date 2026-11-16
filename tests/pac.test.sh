#!/bin/bash
# pac.test.sh — only what is switched on goes to Japan; look-alikes, shared CDNs and this Mac's own
# networks don't. The PAC template is filled the way mmvpn-proxy fills it (routes, the site list from
# sites.example, the SOCKS port) and evaluated by two engines: a browser-style one (macOS's jsc) and
# Apple's own (Safari and every Mac app), which reads "SOCKS" but drops "SOCKS5".
# Every "goes DIRECT" check sits next to a planted positive, so a PAC that sends nothing anywhere
# cannot pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  NG   $1${2:+ — $2}"; }
[ -x "$JSC" ] || { echo "jsc not found at $JSC"; exit 2; }
D="$(mktemp -d "${TMPDIR:-/tmp}/mmvpn-pac.XXXXXX")"; trap 'rm -rf "$D"' EXIT

# fill <routes> > file: the PAC as mmvpn-proxy serves it, from the real server code.
mkdir -p "$D/conf/pac"
cp "$ROOT/pac/jp.pac" "$D/conf/pac/jp.pac"; cp "$ROOT/sites.example" "$D/conf/sites"
printf 'SOCKS_PORT=1192\n' > "$D/conf/config"
fill() {
  MMVPN_CONFIG_DIR="$D/conf" /usr/bin/python3 - "$ROOT/bin/mmvpn-proxy" "$1" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("mmvpn_proxy", sys.argv[1])
spec = importlib.util.spec_from_loader("mmvpn_proxy", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
sys.stdout.write(m.pac(sys.argv[2]))
PY
}
for r in sites rest sites,rest none bare; do
  case $r in none) q="routes=" ;; bare) q="" ;; *) q="routes=$r" ;; esac
  fill "$q" > "$D/$r.pac"
done
cp "$ROOT/pac/jp.pac" "$D/unfilled.pac"

T="SOCKS5 127.0.0.1:1192; SOCKS 127.0.0.1:1192"
SITES="abema.tv api.abema.io tver.jp radiko.jp www.nhk.or.jp nhk.jp
  www.netflix.com netflix.com id.netflix.com login.netflix.com assets.nflxext.com
  ipv4-c001-tyo001-ix.1.oca.nflxvideo.net occ-0-1.1.nflxso.net art-s.nflximg.net
  ds-linear-abematv.akamaized.net ds-vod-abematv.akamaized.net linear-abematv.akamaized.net
  si-f-radiko.smartstream.ne.jp tf-f-rpaa-radiko.smartstream.ne.jp dr-wowza.radiko-cf.com
  simul.drdi.st.nhk simul2.drdi.st.nhk login.abema.tv abema.tv. ABEMA.TV"
LOOKALIKE="netflix.com.evil.example notnetflix.com nflxvideo.net.evil.example abema.tv.evil.example
  notabema.tv myabematvthing.akamaized.net xabematv.akamaized.net notradiko.smartstream.ne.jp
  www.akamaized.net images.akamaized.net other.smartstream.ne.jp"
OTHER="api.anthropic.com github.com google.com my.bank.example 10.example.com 100.200.1.1"
LOCAL="localhost homemac 192.168.11.1 10.1.2.3 172.16.0.1 172.31.255.1 169.254.1.1 100.100.1.1
  127.0.0.1 printer.local homemac.tail1234.ts.net app.localhost nas.lan router.home.arpa db.internal"

eval_pac() {  # eval_pac <file> <hosts...>: "host verdict" lines
  local f="$1"; shift
  "$JSC" "$HERE/pac-eval.js" -- "$f" "$@" 2>&1
}
expect() {  # expect <routes> <want> <label> <hosts...>
  local r="$1" want="$2" label="$3" out h got; shift 3
  # shellcheck disable=SC2068
  out="$(eval_pac "$D/$r.pac" $@)"
  [ -n "$out" ] || { bad "the PAC could not be evaluated [$r]"; return; }
  for h in "$@"; do
    got="$(printf '%s\n' "$out" | awk -v h="$h" '$1==h { $1=""; sub(/^ /,""); print }')"
    [ "$got" = "$want" ] && ok "[$r] $h $label" || bad "[$r] $h should $label" "$got"
  done
}

echo "── PAC (browser engine) ──"
# shellcheck disable=SC2086
{
expect sites "$T" "→ Japan, no fallback" $SITES
expect sites DIRECT "→ direct" $LOOKALIKE $OTHER
expect rest "$T; DIRECT" "→ Japan, then direct" $OTHER
expect rest DIRECT "→ direct (sites are off)" www.netflix.com abema.tv ds-vod-abematv.akamaized.net
expect rest DIRECT "→ direct (this Mac's own network)" $LOCAL
expect sites,rest "$T" "→ Japan, no fallback" www.netflix.com abema.tv
expect sites,rest "$T; DIRECT" "→ Japan, then direct" google.com
expect none DIRECT "→ direct (nothing on)" www.netflix.com google.com
expect bare "$T" "→ Japan (the old bare URL means sites)" www.netflix.com
expect bare DIRECT "→ direct" google.com
expect unfilled DIRECT "→ direct (an unfilled template sends nothing to Japan)" www.netflix.com google.com
}

echo "── the site list ──"
printf 'example.jp\n  *-video.cdn.example   # a pattern\n.lead.example\nbad"; return "SOCKS evil\nno_dot\nEXAMPLE.JP\n' > "$D/conf/sites"
fill routes=sites > "$D/custom.pac" 2>/dev/null
out="$(eval_pac "$D/custom.pac" example.jp www.example.jp a-video.cdn.example lead.example x.lead.example \
       netflix.com video.cdn.example evil 2>&1)"
v() { printf '%s\n' "$out" | awk -v h="$1" '$1==h { $1=""; sub(/^ /,""); print }'; }
[ "$(v www.example.jp)" = "$T" ] && [ "$(v example.jp)" = "$T" ] && ok "a domain covers itself and its subdomains" \
  || bad "domain entry" "$(v www.example.jp)"
[ "$(v a-video.cdn.example)" = "$T" ] && [ "$(v video.cdn.example)" = DIRECT ] && ok "a * pattern matches the whole host" \
  || bad "pattern entry" "$(v a-video.cdn.example) / $(v video.cdn.example)"
[ "$(v x.lead.example)" = "$T" ] && ok "a leading dot is allowed" || bad "leading dot" "$(v x.lead.example)"
[ "$(v netflix.com)" = DIRECT ] && ok "only your list is routed (netflix.com is not on it here)" || bad "list replaced" "$(v netflix.com)"
grep -q 'evil' "$D/custom.pac" && bad "a line that is not a host name reached the PAC" || ok "a line that is not a host name is skipped"
[ "$(grep -o '"example.jp"' "$D/custom.pac" | wc -l | tr -d ' ')" = 1 ] && ok "duplicates (any case) appear once" || bad "duplicates"

echo "── PAC (Apple's engine: Safari and Mac apps) ──"
if swiftc -O "$HERE/paceval.swift" -o "$D/paceval" >/dev/null 2>&1; then
  ap() { "$D/paceval" "$D/$1.pac" "$2" | sed 's/^ *[^:]*: //'; }
  A="SOCKS 127.0.0.1:1192"
  [ "$(ap sites www.netflix.com)" = "$A" ] && ok "Apple: sites → Japan" || bad "Apple: sites" "$(ap sites www.netflix.com)"
  [ "$(ap sites google.com)" = DIRECT ] && ok "Apple: other sites → direct [sites]" || bad "Apple: other" "$(ap sites google.com)"
  [ "$(ap rest google.com)" = "$A; DIRECT" ] && ok "Apple: everything else → Japan, then direct [rest]" \
    || bad "Apple: rest" "$(ap rest google.com)"
  [ "$(ap rest www.netflix.com)" = DIRECT ] && ok "Apple: sites → direct [rest]" || bad "Apple: sites with rest" "$(ap rest www.netflix.com)"
else
  bad "Apple's PAC engine check could not be built (swiftc)"
fi

echo
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
