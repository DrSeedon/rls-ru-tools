#!/usr/bin/env bash
# Runs every test from this directory; exits non-zero on any failure.
cd "$(dirname "$0")" || exit 1
fail=0
luajit -b lua/ge/extensions/rlsRuFixes.lua /dev/null && echo "bytecode rlsRuFixes.lua OK" || { echo "BYTECODE FAIL rlsRuFixes.lua"; fail=1; }
luajit -b scripts/rls_ru_fixes/modScript.lua /dev/null && echo "bytecode modScript.lua OK" || { echo "BYTECODE FAIL modScript.lua"; fail=1; }
expect() { # file pattern
  out=$(luajit "$1" 2>&1); rc=$?
  if [ $rc -ne 0 ] || ! grep -qF -- "$2" <<<"$out" || grep -q "FAIL" <<<"$out"; then
    echo "FAIL $1"; echo "$out" | tail -15; fail=1
  else echo "ok   $1"; fi
}
expect test.lua            "after reload unknown ->	nil"
expect test_route.lua      "stops left:	s3,s4"
expect test_autoadd.lua    "AUTOADD OK"
expect test_parked.lua     "PARKED OK"
expect test_optimize.lua   "checks, 0 failed"
expect test_v7_org.lua    "ORG OK"
for t in test_v6_*.lua; do
  [ "$t" = test_v6_common.lua ] && continue
  expect "$t" "checks, 0 failed"
done
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $fail
