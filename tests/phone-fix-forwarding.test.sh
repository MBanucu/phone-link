#!/usr/bin/env bash
# Hermetic tests for bin/phone-fix-forwarding: stub sysctl and sudo.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-fix-forwarding
. "$ROOT/tests/lib/harness.sh"
suite


stub sysctl
answer sysctl <<'EOF'
case "${1:-}" in
  -n) cat "$LOG/forward" ;;
  -w)
    printf 'sysctl %s\n' "$*" >>"$LOG/actions"
    printf '1\n' >"$LOG/forward"
    ;;
esac
EOF

stub sudo
answer sudo <<'EOF'
exec "$@"
EOF


run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Off: enables it through sudo.
printf '0\n' >"$LOG/forward"
rm -f "$LOG/actions"
if run; then ok "enables forwarding"; else bad "enables forwarding" "$(cat "$LOG/out")"; fi
grep -qx 'sysctl -w net.ipv4.ip_forward=1' "$LOG/actions" && ok "runs sysctl -w" \
  || bad "runs sysctl -w" "$(cat "$LOG/actions" 2>/dev/null)"
[ "$(cat "$LOG/forward")" = 1 ] && ok "forwarding is on afterwards" || bad "forwarding is on afterwards"

# 2. Already on: no change.
printf '1\n' >"$LOG/forward"
rm -f "$LOG/actions"
if run; then ok "already-on exits 0"; else bad "already-on exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/actions" ] && bad "already-on changes nothing" || ok "already-on changes nothing"

# 3. --check is read-only and reports the state.
printf '0\n' >"$LOG/forward"
rm -f "$LOG/actions"
if run --check; then bad "--check off exits 1"; else ok "--check off exits 1"; fi
[ -s "$LOG/actions" ] && bad "--check changes nothing when off" || ok "--check changes nothing when off"
printf '1\n' >"$LOG/forward"
if run --check; then ok "--check on exits 0"; else bad "--check on exits 0"; fi

# 4. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

finish
