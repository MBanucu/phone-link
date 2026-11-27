#!/usr/bin/env bash
# Hermetic tests for tests/live/hairpin-measure.sh: its self-test, the dry-run
# plan, the read-only check with no phone or root, and the before/after table.
# No adb, no nft, no network; the live script is never run in measurement mode.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/tests/live/hairpin-measure.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$*"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$*"
}

run() { # output file, args...
  local out=$1
  shift
  if "$BASH_BIN" "$SCRIPT" "$@" >"$out" 2>&1; then
    return 0
  fi
  return 1
}

# 1. The parsers, URL guard and rule detection, with no phone and no root.
if run "$TMP/self" --self-test; then
  ok "self-test exits 0"
else
  bad "self-test exits 0"
fi
grep -q '^PASS ' "$TMP/self" && ok "self-test makes assertions" \
  || bad "self-test makes assertions"
grep -q '0 failed' "$TMP/self" && ok "self-test passes every assertion" \
  || bad "self-test passes every assertion"
grep -Fq 'mbps_from_ns 600751000 ns = 111.71 Mbps' "$TMP/self" &&
  ok "self-test covers the nanosecond-to-Mbit/s helper" ||
  bad "self-test covers the nanosecond-to-Mbit/s helper"

# 2. The plan names every required measurement and every blocked number.
evidence_before=$(compgen -G "$ROOT/result-live/hairpin-*" 2>/dev/null | sort)
if run "$TMP/dry" --dry-run; then
  ok "dry-run exits 0"
else
  bad "dry-run exits 0"
fi
for needle in \
  '500 sequential' \
  '200 at concurrency 40' \
  '5 x 8 MB' \
  '30 minutes' \
  'needs #43/#44' \
  'needs #46' \
  'nothing is executed'; do
  grep -Fq "$needle" "$TMP/dry" && ok "dry-run says: $needle" \
    || bad "dry-run says: $needle"
done
evidence_after=$(compgen -G "$ROOT/result-live/hairpin-*" 2>/dev/null | sort)
[ "$evidence_before" = "$evidence_after" ] && ok "dry-run creates no evidence directory" ||
  bad "dry-run creates no evidence directory"

# 2b. PHONE_MEASURE_OUT is the default evidence directory; --out still wins.
export PHONE_MEASURE_OUT=$TMP/env-out
if run "$TMP/dry-env" --dry-run; then
  ok "dry-run with PHONE_MEASURE_OUT exits 0"
else
  bad "dry-run with PHONE_MEASURE_OUT exits 0"
fi
grep -Fq "evidence: $PHONE_MEASURE_OUT" "$TMP/dry-env" &&
  ok "PHONE_MEASURE_OUT is the default evidence directory" ||
  bad "PHONE_MEASURE_OUT is the default evidence directory"
if run "$TMP/dry-out" --dry-run --out "$TMP/cli-out"; then
  ok "dry-run with --out and PHONE_MEASURE_OUT exits 0"
else
  bad "dry-run with --out and PHONE_MEASURE_OUT exits 0"
fi
grep -Fq "evidence: $TMP/cli-out" "$TMP/dry-out" &&
  ok "--out wins over PHONE_MEASURE_OUT" ||
  bad "--out wins over PHONE_MEASURE_OUT"
unset PHONE_MEASURE_OUT

# 3. --check with every live tool absent: still read-only, still honest.
export PHONE_MEASURE_ADB=$TMP/missing-adb
export PHONE_MEASURE_CURL=$TMP/missing-curl
export PHONE_MEASURE_IW=$TMP/missing-iw
export PHONE_MEASURE_NFT=$TMP/missing-nft
export PHONE_MEASURE_SYSTEMCTL=$TMP/missing-systemctl
export PHONE_MEASURE_TIMEOUT=$TMP/missing-timeout
if run "$TMP/check" --check; then
  ok "check exits 0 without a phone or root"
else
  bad "check exits 0 without a phone or root"
fi
grep -q 'phone: none' "$TMP/check" && ok "check reports no phone" \
  || bad "check reports no phone"
grep -Fq 'UNAVAILABLE (needs #43/#44' "$TMP/check" && ok "check names #43/#44" \
  || bad "check names #43/#44"
grep -Fq 'UNAVAILABLE (needs #46)' "$TMP/check" && ok "check names #46" \
  || bad "check names #46"
grep -Fq 'phone HTTPS request: only with a TLS client' "$TMP/check" &&
  ok "check says HTTPS latency needs a client" ||
  bad "check says HTTPS latency needs a client"

# 4. The compare table puts the same metric side by side and keeps the missing
#    after number visible instead of inventing one.
mkdir -p "$TMP/before" "$TMP/after"
cat >"$TMP/before/results.csv" <<'EOF'
metric,value,state,evidence
phone_icmp_median_ms,18.0,measured,-
laptop_seq_failures,0,measured,-
fallback_seconds,n/a,UNAVAILABLE (needs #46),-
EOF
cat >"$TMP/after/results.csv" <<'EOF'
metric,value,state,evidence
phone_icmp_median_ms,31.0,measured,-
laptop_seq_failures,0,measured,-
fallback_seconds,n/a,UNAVAILABLE (needs #46),-
EOF
if run "$TMP/compare" --compare "$TMP/before" "$TMP/after"; then
  ok "compare exits 0"
else
  bad "compare exits 0"
fi
grep -q '| measurement | before | after |' "$TMP/compare" \
  && ok "compare prints a before/after header" \
  || bad "compare prints a before/after header"
grep -q '| phone_icmp_median_ms | 18.0 | 31.0 |' "$TMP/compare" \
  && ok "compare puts the before and after numbers side by side" \
  || bad "compare puts the before and after numbers side by side"
grep -q 'fallback_seconds | UNAVAILABLE (needs #46) | UNAVAILABLE (needs #46)' "$TMP/compare" \
  && ok "compare keeps an unavailable number unavailable" \
  || bad "compare keeps an unavailable number unavailable"

# 5. No arguments must print usage, not start a measurement.
if run "$TMP/noargs"; then
  bad "no arguments exits non-zero"
else
  ok "no arguments exits non-zero"
fi
grep -q '^usage:' "$TMP/noargs" && ok "no arguments prints usage" \
  || bad "no arguments prints usage"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
