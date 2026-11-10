#!/usr/bin/env bash
# Hermetic tests for bin/phone-doctor-fix: stub phone-doctor and the fix
# scripts, so no phone, no systemd, no network, no root.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-doctor-fix
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
mkdir -p "$LOG" "$STUBS"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$*"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s%s\n' "$*" "${2:+ ($2)}"
}

# The doctor stub prints the queued problems once, then reports clean.
cat >"$STUBS/phone-doctor" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--analyze" ] || exit 2
if [ -s "$LOG/problems" ]; then
  cat "$LOG/problems"
  rm -f "$LOG/problems"
  exit 1
fi
exit 0
EOF

make_stub() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s >>"$LOG/actions"\n' "$1" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}
make_stub phone-fix-forwarding
make_stub phone-adb-wifi
make_stub phone-unlock
make_stub phone-proxy-start

sed -i "1s|.*|#!$BASH_BIN|" "$STUBS"/*
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Nothing reported: nothing to do.
: >"$LOG/problems"
if run; then ok "clean setup exits 0"; else bad "clean setup exits 0" "$(cat "$LOG/out")"; fi
grep -q 'nothing to fix' "$LOG/out" && ok "says there is nothing to fix" || bad "says there is nothing to fix"

# 2. Dry run lists the fixes and changes nothing.
printf 'fail ip_forward 0\nwarn network_transport USB only\n' >"$LOG/problems"
rm -f "$LOG/actions"
if run --dry-run; then ok "dry run exits 0"; else bad "dry run exits 0" "$(cat "$LOG/out")"; fi
grep -q 'phone-fix-forwarding' "$LOG/out" && ok "lists the forwarding fix" || bad "lists the forwarding fix"
grep -q 'phone-adb-wifi' "$LOG/out" && ok "lists the adb over wi-fi fix" || bad "lists the adb over wi-fi fix"
[ -s "$LOG/actions" ] && bad "dry run runs nothing" || ok "dry run runs nothing"
grep -q 'dry run: nothing applied' "$LOG/out" && ok "says nothing was applied" || bad "says nothing was applied"

# 3. --yes runs each fix script in dependency order, then re-checks.
printf 'fail ip_forward 0\nwarn network_transport USB only\n' >"$LOG/problems"
rm -f "$LOG/actions"
if run --yes; then ok "applying fixes exits 0"; else bad "applying fixes exits 0" "$(cat "$LOG/out")"; fi
[ "$(cat "$LOG/actions")" = "$(printf 'phone-fix-forwarding\nphone-adb-wifi')" ] \
  && ok "runs the fixes in order" || bad "runs the fixes in order" "$(cat "$LOG/actions")"
grep -q 'all reported problems are fixed' "$LOG/out" && ok "re-checks and reports clean" \
  || bad "re-checks and reports clean" "$(cat "$LOG/out")"

# 4. A problem without a fix script prints the manual step and exits 1.
printf 'fail secrets /etc/phone-socks-secrets not readable (run with sudo)\n' >"$LOG/problems"
rm -f "$LOG/actions"
if run --yes; then bad "manual-only problem exits 1"; else ok "manual-only problem exits 1"; fi
grep -q 'manual:' "$LOG/out" && ok "shows the manual section" || bad "shows the manual section"
grep -q 'PHONE_SOCKS_PASS' "$LOG/out" && ok "explains the secrets step" || bad "explains the secrets step"
[ -s "$LOG/actions" ] && bad "manual-only runs no fix" || ok "manual-only runs no fix"

# 5. A failed fix is reported but the run continues.
printf 'fail ip_forward 0\nwarn network_transport USB only\n' >"$LOG/problems"
printf '#!/usr/bin/env bash\nexit 1\n' >"$STUBS/phone-fix-forwarding"
chmod +x "$STUBS/phone-fix-forwarding"
rm -f "$LOG/actions"
if run --yes; then ok "continues after a failed fix"; else bad "continues after a failed fix"; fi
grep -q 'warning: the ip_forward fix failed' "$LOG/out" && ok "warns about the failed fix" \
  || bad "warns about the failed fix" "$(cat "$LOG/out")"
grep -qx 'phone-adb-wifi' "$LOG/actions" && ok "still runs the next fix" || bad "still runs the next fix"

# 6. --help and unknown arguments.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi
if run --bogus; then bad "unknown argument exits 1"; else ok "unknown argument exits 1"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
