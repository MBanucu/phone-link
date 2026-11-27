#!/usr/bin/env bash
# Hermetic tests for bin/phone-ap-up: stub iw/nmcli/ip/systemctl, and a sysctl
# that would say forwarding is off. The link-only AP does not forward, so the
# command must not consult it. No phone, no network, no root.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-ap-up

. "$ROOT/tests/lib/harness.sh"
tmpdir TMP
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
mkdir -p "$LOG" "$STUBS"

stub_cmd id "$STUBS" <<'EOF'
printf '0\n'
EOF

stub_cmd iw "$STUBS" <<'EOF'
case "$*" in
  list) printf '\t* AP\n\t* managed\n' ;;
  "dev wlp110s0 station dump") : ;;
esac
EOF

stub_cmd nmcli "$STUBS" <<'EOF'
case "$*" in
  "-g wifi.backend") printf 'wpa_supplicant\n' ;;
  "-t -f NAME con show") printf 'phonelink\n' ;;
  "connection up "*) printf '%s\n' "$*" >>"$LOG/actions" ;;
esac
EOF

stub_cmd ip "$STUBS" <<'EOF'
case "$*" in
  "-4 -br addr show wlp110s0") printf 'wlp110s0 UP 192.168.77.1/24\n' ;;
esac
EOF

# The rejoin watchdog: the unit exists and records every start. The state file
# names the last attempt, so a switch-on has to clear it before starting it.
stub_cmd systemctl "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/systemctl"
EOF

# The regression is about not needing forwarding: a run that asks sysctl at all
# leaves a marker, and every answer here is 0.
stub_cmd sysctl "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/sysctl"
printf '0\n'
EOF

stub_cmd sudo "$STUBS" <<'EOF'
exec "$@"
EOF

export PATH="$STUBS:$PATH"
export PHONE_AP_DECLARATIVE=$TMP/ap-profile
export PHONE_AP_REJOIN_STATE=$TMP/ap-rejoin.last

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Forwarding off: the AP still comes up and the rejoin is asked for at once.
rm -f "$LOG/actions" "$LOG/sysctl" "$LOG/systemctl"
printf '1700000000\n' >"$PHONE_AP_REJOIN_STATE"
if run; then ok "forwarding off still brings the AP up"; else
  bad "forwarding off still brings the AP up" "$(cat "$LOG/out")"
fi
grep -qx 'connection up phonelink' "$LOG/actions" && ok "activates the profile" \
  || bad "activates the profile" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'AP up' "$LOG/out" && ok "reports the AP up" || bad "reports the AP up" "$(cat "$LOG/out")"
[ -e "$LOG/sysctl" ] && bad "never reads ip_forward" || ok "never reads ip_forward"
[ -e "$PHONE_AP_REJOIN_STATE" ] && bad "clears the rejoin throttle file" \
  || ok "clears the rejoin throttle file"
starts=$(grep -c '^start --no-block phone-link-ap-rejoin.service$' "$LOG/systemctl" \
  2>/dev/null || true)
[ "$starts" = 1 ] && ok "starts the rejoin unit once" \
  || bad "starts the rejoin unit once" "($starts starts)"

# 2. With phoneLink.ap.rejoin = false the unit does not exist, so systemctl
#    fails; the AP still comes up and the stale throttle is still cleared.
stub_cmd systemctl "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/systemctl"
exit 1
EOF
rm -f "$LOG/actions" "$LOG/systemctl"
printf '1700000000\n' >"$PHONE_AP_REJOIN_STATE"
if run; then ok "a missing rejoin unit does not fail the switch"; else
  bad "a missing rejoin unit does not fail the switch" "$(cat "$LOG/out")"
fi
grep -qx 'connection up phonelink' "$LOG/actions" \
  && ok "still activates the profile" \
  || bad "still activates the profile" "$(cat "$LOG/actions" 2>/dev/null)"
grep -qx 'start --no-block phone-link-ap-rejoin.service' "$LOG/systemctl" \
  && ok "still asks for the rejoin" \
  || bad "still asks for the rejoin" "$(cat "$LOG/systemctl" 2>/dev/null)"
[ -e "$PHONE_AP_REJOIN_STATE" ] && bad "clears the throttle with no unit" \
  || ok "clears the throttle with no unit"

# 3. A driver without AP mode still fails.
stub_cmd systemctl "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/systemctl"
EOF
stub_cmd iw "$STUBS" <<'EOF'
printf 'no AP here\n'
EOF
if run; then bad "a driver without AP mode exits 1"; else ok "a driver without AP mode exits 1"; fi
grep -q 'no AP mode' "$LOG/out" && ok "names the missing AP mode" \
  || bad "names the missing AP mode" "$(cat "$LOG/out")"

# 4. --help.
stub_cmd iw "$STUBS" <<'EOF'
printf '\t* AP\n'
EOF
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

finish
