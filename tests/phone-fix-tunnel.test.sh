#!/usr/bin/env bash
# Hermetic tests for bin/phone-fix-tunnel: stub systemctl, ip and sudo.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-fix-tunnel
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

cat >"$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  is-active) cat "$LOG/state" ;;
  start | restart)
    printf 'systemctl %s\n' "$*" >>"$LOG/actions"
    printf 'active\n' >"$LOG/state"
    printf '2022: from all fwmark 0x7e6 lookup 2022\n' >"$LOG/rules"
    ;;
esac
EOF

cat >"$STUBS/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "rule show") cat "$LOG/rules" ;;
esac
EOF

cat >"$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

sed -i "1s|.*|#!$BASH_BIN|" "$STUBS"/*
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Inactive: starts the unit.
printf 'inactive\n' >"$LOG/state"
: >"$LOG/rules"
rm -f "$LOG/actions"
if run; then ok "starts an inactive tunnel"; else bad "starts an inactive tunnel" "$(cat "$LOG/out")"; fi
grep -qx 'systemctl start phone-tun.service' "$LOG/actions" && ok "runs systemctl start" \
  || bad "runs systemctl start" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'phone-tun is active with its route' "$LOG/out" && ok "waits for the route" \
  || bad "waits for the route" "$(cat "$LOG/out")"

# 2. Active without the route: restarts it.
printf 'active\n' >"$LOG/state"
: >"$LOG/rules"
rm -f "$LOG/actions"
if run; then ok "restarts a tunnel without a route"; else bad "restarts a tunnel without a route" "$(cat "$LOG/out")"; fi
grep -qx 'systemctl restart phone-tun.service' "$LOG/actions" && ok "runs systemctl restart" \
  || bad "runs systemctl restart" "$(cat "$LOG/actions" 2>/dev/null)"

# 3. Active with the route: no change.
printf 'active\n' >"$LOG/state"
printf '2022: from all fwmark 0x7e6 lookup 2022\n' >"$LOG/rules"
rm -f "$LOG/actions"
if run; then ok "a working tunnel exits 0"; else bad "a working tunnel exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/actions" ] && bad "a working tunnel changes nothing" || ok "a working tunnel changes nothing"

# 4. --check is read-only.
printf 'inactive\n' >"$LOG/state"
: >"$LOG/rules"
rm -f "$LOG/actions"
if run --check; then bad "--check on an inactive tunnel exits 1"; else ok "--check on an inactive tunnel exits 1"; fi
[ -s "$LOG/actions" ] && bad "--check changes nothing" || ok "--check changes nothing"
printf 'active\n' >"$LOG/state"
printf '2022: from all fwmark 0x7e6 lookup 2022\n' >"$LOG/rules"
if run --check; then ok "--check on a working tunnel exits 0"; else bad "--check on a working tunnel exits 0"; fi

# 5. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
