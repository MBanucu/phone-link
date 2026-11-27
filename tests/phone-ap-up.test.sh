#!/usr/bin/env bash
# Hermetic tests for bin/phone-ap-up: stub iw/nmcli/ip, and a sysctl that would
# say forwarding is off. The link-only AP does not forward, so the command must
# not consult it. No phone, no network, no root.
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

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Forwarding off: the AP still comes up.
rm -f "$LOG/actions" "$LOG/sysctl"
if run; then ok "forwarding off still brings the AP up"; else
  bad "forwarding off still brings the AP up" "$(cat "$LOG/out")"
fi
grep -qx 'connection up phonelink' "$LOG/actions" && ok "activates the profile" \
  || bad "activates the profile" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'AP up' "$LOG/out" && ok "reports the AP up" || bad "reports the AP up" "$(cat "$LOG/out")"
[ -e "$LOG/sysctl" ] && bad "never reads ip_forward" || ok "never reads ip_forward"

# 2. A driver without AP mode still fails.
stub_cmd iw "$STUBS" <<'EOF'
printf 'no AP here\n'
EOF
if run; then bad "a driver without AP mode exits 1"; else ok "a driver without AP mode exits 1"; fi
grep -q 'no AP mode' "$LOG/out" && ok "names the missing AP mode" \
  || bad "names the missing AP mode" "$(cat "$LOG/out")"

# 3. --help.
stub_cmd iw "$STUBS" <<'EOF'
printf '\t* AP\n'
EOF
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

finish
