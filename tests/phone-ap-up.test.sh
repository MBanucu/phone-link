#!/usr/bin/env bash
# Hermetic tests for bin/phone-ap-up: stub iw/nmcli/ip/systemctl, and a sysctl
# that would say forwarding is off. The link-only AP does not forward, so the
# command must not consult it. No phone, no network, no root.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-ap-up

. "$ROOT/tests/lib/harness.sh"
suite

stub_cmd id "$STUBS" <<'EOF'
printf '0\n'
EOF

stub_cmd iw "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/iw"
case "$*" in
  list) printf '\t* AP\n\t* managed\n' ;;
  "dev wlp110s0 station dump") : ;;
  "reg get") cat "$LOG/iw_reg" 2>/dev/null ;;
  "dev wlp110s0 info") cat "$LOG/iw_info" 2>/dev/null ;;
  "phy "*) cat "$LOG/iw_phy" 2>/dev/null ;;
esac
EOF

stub_cmd nmcli "$STUBS" <<'EOF'
case "$*" in
  "-g wifi.backend") printf 'wpa_supplicant\n' ;;
  "-t -f NAME con show") printf 'phonelink\n' ;;
  "connection up "*)
    printf '%s\n' "$*" >>"$LOG/actions"
    if [ -f "$LOG/nmcli_fail" ]; then
      if [ "$(cat "$LOG/nmcli_fail")" = start-ap ]; then
        printf 'Error: Connection activation failed: Failed to start AP functionality\n' >&2
      else
        printf 'Error: Connection activation failed: 802.1X supplicant took too long to authenticate\n' >&2
      fi
      exit 4
    fi
    ;;
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

# 4. External role: nothing on this host is the AP, so the command explains
#    that and only asks for the USB rejoin; it never touches iw/nmcli.
stub_cmd iw "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/iw"
printf '\t* AP\n'
EOF
stub_cmd systemctl "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/systemctl"
EOF
rm -f "$LOG/actions" "$LOG/iw" "$LOG/systemctl"
printf '1700000000\n' >"$PHONE_AP_REJOIN_STATE"
if PHONE_AP_ROLE=external run; then ok "external role exits 0"; else
  bad "external role exits 0" "$(cat "$LOG/out")"
fi
grep -q 'AP is external (phoneLink.ap.role = "external")' "$LOG/out" \
  && ok "explains that the AP is external" \
  || bad "explains that the AP is external" "$(cat "$LOG/out")"
grep -q 'nothing to activate' "$LOG/out" \
  && ok "says there is nothing to activate" \
  || bad "says there is nothing to activate" "$(cat "$LOG/out")"
[ -e "$LOG/actions" ] && bad "external role does not run nmcli" \
  || ok "external role does not run nmcli"
[ -e "$LOG/iw" ] && bad "external role does not preflight the radio" \
  || ok "external role does not preflight the radio"
grep -qx 'start --no-block phone-link-ap-rejoin.service' "$LOG/systemctl" \
  && ok "external role still nudges the phone back" \
  || bad "external role still nudges the phone back" "$(cat "$LOG/systemctl" 2>/dev/null)"
[ -e "$PHONE_AP_REJOIN_STATE" ] && bad "external role clears the rejoin throttle" \
  || ok "external role clears the rejoin throttle"

# 5. The regulatory preflight: channel 149 in country 00 is passive-only, so
#    the command fails before NetworkManager tries and before the ~25 s
#    supplicant timeout, naming the country, channel and the fixes.
stub_cmd iw "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/iw"
case "$*" in
  list) printf '\t* AP\n\t* managed\n' ;;
  "dev wlp110s0 station dump") : ;;
  "reg get") cat "$LOG/iw_reg" 2>/dev/null ;;
  "dev wlp110s0 info") cat "$LOG/iw_info" 2>/dev/null ;;
  "phy "*) cat "$LOG/iw_phy" 2>/dev/null ;;
esac
EOF
rm -f "$LOG/iw_reg"
cp "$ROOT/tests/fixtures/iw-reg-country-00.txt" "$LOG/iw_reg"
rm -f "$LOG/iw_info" "$LOG/iw_phy"
rm -f "$LOG/actions"
if run; then bad "a passive-only channel exits non-zero"; else
  ok "a passive-only channel exits non-zero"
fi
[ -e "$LOG/actions" ] && bad "passive-only never activates the profile" \
  || ok "passive-only never activates the profile"
grep -q 'channel 149 (5 GHz, band a) is passive-only' "$LOG/out" \
  && ok "names the channel, band and state" \
  || bad "names the channel, band and state" "$(cat "$LOG/out")"
grep -q 'regulatory domain 00' "$LOG/out" \
  && ok "names the country" || bad "names the country" "$(cat "$LOG/out")"
grep -q 'phoneLink.ap.country = "DE"' "$LOG/out" \
  && ok "names the declarative fix" \
  || bad "names the declarative fix" "$(cat "$LOG/out")"
grep -q 'iw reg set DE' "$LOG/out" \
  && ok "names the runtime fix" || bad "names the runtime fix" "$(cat "$LOG/out")"
grep -q '2.4 GHz' "$LOG/out" \
  && ok "names the 2.4 GHz alternative" \
  || bad "names the 2.4 GHz alternative" "$(cat "$LOG/out")"
grep -q 'Not waiting for the supplicant timeout' "$LOG/out" \
  && ok "says it did not wait for the timeout" \
  || bad "says it did not wait for the timeout" "$(cat "$LOG/out")"

# 6. A country that allows 149 proceeds; a failing activation with the
#    observed supplicant message then hints at the stale supplicant and the
#    NetworkManager restart, and preserves the non-zero exit.
rm -f "$LOG/iw_reg"
cp "$ROOT/tests/fixtures/iw-reg-country-de.txt" "$LOG/iw_reg"
rm -f "$LOG/actions" "$LOG/nmcli_fail"
if run; then ok "an allowed channel activates the profile"; else
  bad "an allowed channel activates the profile" "$(cat "$LOG/out")"
fi
grep -qx 'connection up phonelink' "$LOG/actions" \
  && ok "the allowed channel reaches nmcli" \
  || bad "the allowed channel reaches nmcli" "$(cat "$LOG/actions" 2>/dev/null)"
printf '802.1x\n' >"$LOG/nmcli_fail"
if run; then bad "a failing activation stays non-zero"; else
  ok "a failing activation stays non-zero"
fi
grep -q 'hint:.*channel 149.*allowed.*regulatory domain DE' "$LOG/out" \
  && ok "the hint says the domain allows the channel" \
  || bad "the hint says the domain allows the channel" "$(cat "$LOG/out")"
grep -q 'wpa_supplicant' "$LOG/out" \
  && ok "the hint names the stale supplicant" \
  || bad "the hint names the stale supplicant" "$(cat "$LOG/out")"
grep -q 'systemctl restart NetworkManager' "$LOG/out" \
  && ok "the hint names the recovery" \
  || bad "the hint names the recovery" "$(cat "$LOG/out")"
printf 'start-ap\n' >"$LOG/nmcli_fail"
if run; then bad "Failed to start AP functionality stays non-zero"; else
  ok "Failed to start AP functionality stays non-zero"
fi
grep -q 'hint:' "$LOG/out" \
  && ok "the second observed message gets the hint" \
  || bad "the second observed message gets the hint" "$(cat "$LOG/out")"
rm -f "$LOG/nmcli_fail"

# 7. --help.
stub_cmd iw "$STUBS" <<'EOF'
printf '\t* AP\n'
EOF
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

finish
