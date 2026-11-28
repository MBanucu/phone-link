#!/usr/bin/env bash
# Hermetic tests for bin/phone-fix-mobile-data: stub adb.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-fix-mobile-data
. "$ROOT/tests/lib/harness.sh"
suite


stub adb
answer adb <<'EOF'
case "$*" in
  devices)
    if [ -f "$LOG/devices" ]; then
      cat "$LOG/devices"
    else
      printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n'
    fi
    ;;
  *"shell svc data enable")
    printf 'svc data enable\n' >>"$LOG/actions"
    printf 'default via 10.0.0.1 dev ccmni1\n' >"$LOG/route"
    ;;
  *"shell ip route show default") cat "$LOG/route" ;;
esac
EOF


run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. No route: enables mobile data and waits for the route.
: >"$LOG/route"
rm -f "$LOG/actions"
if run; then ok "enables mobile data"; else bad "enables mobile data" "$(cat "$LOG/out")"; fi
grep -qx 'svc data enable' "$LOG/actions" && ok "runs svc data enable" \
  || bad "runs svc data enable" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'mobile data is up' "$LOG/out" && ok "reports the new route" || bad "reports the new route"

# 2. Route present: no change.
printf 'default via 10.0.0.1 dev ccmni1\n' >"$LOG/route"
rm -f "$LOG/actions"
if run; then ok "existing route exits 0"; else bad "existing route exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/actions" ] && bad "existing route changes nothing" || ok "existing route changes nothing"

# 3. --check reports without changing anything.
: >"$LOG/route"
rm -f "$LOG/actions"
if run --check; then bad "--check without route exits 1"; else ok "--check without route exits 1"; fi
[ -s "$LOG/actions" ] && bad "--check changes nothing" || ok "--check changes nothing"
printf 'default via 10.0.0.1 dev ccmni1\n' >"$LOG/route"
if run --check; then ok "--check with route exits 0"; else bad "--check with route exits 0"; fi

# 4. No phone attached.
printf 'List of devices attached\n' >"$LOG/devices"
if run; then bad "no phone exits 1"; else ok "no phone exits 1"; fi

# 5. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

finish
