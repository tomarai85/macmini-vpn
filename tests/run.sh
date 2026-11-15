#!/bin/bash
# run.sh — every test. Nothing here changes this Mac's proxy setting, starts a real tunnel or
# touches an installed copy: the scripts run against stubs and the app is built into a temp folder.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
total=0; failed=0
for t in pac ctl tunnel install app; do
  out="$(bash "$HERE/$t.test.sh" 2>&1)"; rc=$?
  echo "$out" | grep -E '──|NG'
  echo "  $(echo "$out" | tail -1)"
  total=$((total+1)); [ $rc -eq 0 ] || failed=$((failed+1))
done
for f in "$HERE"/../bin/* "$HERE"/../*.sh "$HERE"/../home/*.sh "$HERE"/../app/build.sh; do
  bash -n "$f" || { echo "  syntax error: $f"; failed=$((failed+1)); }
done
echo
[ $failed -eq 0 ] && echo "all $total suites passed" || echo "$failed of $total suites failed"
[ $failed -eq 0 ]
