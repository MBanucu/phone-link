#!/usr/bin/env bash
# Hermetic tests for lib/phone-ap-fallback.sh: stub nmcli/sleep/date, keep the
# active connection and the state file in a temporary directory. No radio, no
# NetworkManager, no root.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/lib/phone-ap-fallback.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin
mkdir -p "$LOG" "$STUBS" "$TMP/run/phone-link"

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

CON=phonelink
STATE=$TMP/run/phone-link/ap-fallback

run() {
    PHONE_AP_CON=$CON \
        PHONE_AP_FALLBACK_STATE=$STATE \
        PHONE_AP_FALLBACK_CHANNEL=${CHANNEL:-1} \
        PHONE_AP_FALLBACK_WIDTH=${WIDTH:-20} \
        PHONE_AP_FALLBACK_DELAY=${DELAY:-3} \
        PATH=$STUBS:$PATH \
        "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

reset() {
    rm -rf "$LOG" "$STATE"
    mkdir -p "$LOG"
}

# nmcli: the active list is a file so a test can make the AP appear at a chosen
# moment; modify and up are logged and can be made to fail.
cat >"$STUBS/nmcli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/nmcli"
case "$*" in
  "-t -f NAME connection show --active")
    [ -f "$LOG/active" ] && cat "$LOG/active"
    ;;
  "connection modify "*)
    [ -f "$LOG/modify_fail" ] && exit 1
    ;;
  "connection up "*)
    [ -f "$LOG/up_fail" ] && exit 1
    printf '%s\n' "${!#}" >>"$LOG/active"
    ;;
esac
exit 0
EOF

cat >"$STUBS/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/sleep"
n=$(( $(cat "$LOG/sleep_count" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" >"$LOG/sleep_count"
if [ -f "$LOG/become_active_after" ] &&
  [ "$n" -ge "$(cat "$LOG/become_active_after")" ]; then
  cat "$LOG/becomes_active_connection" >"$LOG/active"
fi
EOF
chmod +x "$STUBS/sleep"

cat >"$STUBS/date" <<'EOF'
#!/usr/bin/env bash
printf '2026-11-28T12:00:00Z\n'
EOF
chmod +x "$STUBS/date" "$STUBS/nmcli" "$STUBS/sleep"
# Nix builds have no /usr/bin/env; use the bash this suite runs under.
sed -i "1s|^#!.*|#!$BASH_BIN|" "$STUBS/nmcli" "$STUBS/sleep" "$STUBS/date"

# 1. The AP is already active: no fallback, no state.
reset
printf '%s\n' "$CON" >"$LOG/active"
if run; then ok "an active AP exits 0"; else bad "an active AP exits 0"; fi
if [ ! -s "$LOG/nmcli" ] || ! grep -q 'connection modify' "$LOG/nmcli"; then
    ok "an active AP is left alone"
else
    bad "an active AP is left alone"
fi
if [ ! -e "$STATE" ]; then ok "an active AP writes no state"; else bad "an active AP writes no state"; fi

# 2. 5 GHz failed: modify to the fallback band/channel/width and bring it up.
reset
if run --now --reason "5 GHz blocked"; then
    ok "a failed 5 GHz AP falls back"
else
    bad "a failed 5 GHz AP falls back: $(cat "$LOG/out")"
fi
if grep -q 'connection modify phonelink 802-11-wireless.band bg 802-11-wireless.channel 1 802-11-wireless.channel-width 20' "$LOG/nmcli"; then
    ok "the fallback changes only band, channel and width"
else
    bad "the fallback changes only band, channel and width: $(cat "$LOG/nmcli")"
fi
if grep -q 'connection up phonelink' "$LOG/nmcli"; then
    ok "the fallback activates the profile"
else
    bad "the fallback activates the profile"
fi
if [ -s "$STATE" ] && grep -q 'reason=5 GHz blocked' "$STATE"; then
    ok "the state file records the reason"
else
    bad "the state file records the reason: $(cat "$STATE" 2>/dev/null)"
fi
if [ ! -s "$LOG/sleep" ]; then ok "--now does not sleep"; else bad "--now does not sleep"; fi

# 3. One attempt per boot: a second run in the same boot refuses.
reset
run --now >/dev/null 2>&1
# The 5 GHz retry failing again must not get a second 2.4 GHz attempt: make
# the AP look down as it would after a failed re-activation.
rm -f "$LOG/active"
if run --now; then
    bad "a second attempt must refuse"
else
    ok "a second attempt refuses"
fi
if [ "$(grep -c 'connection modify' "$LOG/nmcli")" -eq 1 ]; then
    ok "the second attempt does not touch the profile"
else
    bad "the second attempt does not touch the profile"
fi

# 4. The boot path waits, and returns early when the 5 GHz AP appears.
reset
printf '1\n' >"$LOG/become_active_after"
printf '%s\n' "$CON" >"$LOG/becomes_active_connection"
if run; then ok "the boot path exits 0 when 5 GHz comes up"; else bad "the boot path exits 0 when 5 GHz comes up"; fi
if [ "$(cat "$LOG/sleep_count")" = 1 ]; then
    ok "the boot path returns as soon as the AP is active"
else
    bad "the boot path returns as soon as the AP is active (slept $(cat "$LOG/sleep_count"))"
fi
if ! grep -q 'connection modify' "$LOG/nmcli"; then
    ok "the boot path changes nothing when 5 GHz comes up"
else
    bad "the boot path changes nothing when 5 GHz comes up"
fi

# 5. The boot path falls back after the delay when 5 GHz never appears.
reset
DELAY=2
if run; then ok "the boot path falls back after the delay"; else bad "the boot path falls back after the delay"; fi
if [ "$(cat "$LOG/sleep_count")" = 2 ]; then
    ok "the boot path waits the configured delay"
else
    bad "the boot path waits the configured delay (slept $(cat "$LOG/sleep_count"))"
fi
unset DELAY

# 6. Bad settings are refused before touching the profile.
reset
if CHANNEL=0 run --now; then bad "channel 0 must be refused"; else ok "channel 0 is refused"; fi
if CHANNEL=12 run --now; then bad "channel 12 must be refused"; else ok "channel 12 is refused"; fi
if WIDTH=80 run --now; then bad "80 MHz must be refused"; else ok "80 MHz is refused"; fi
if ! grep -q 'connection modify' "$LOG/nmcli" 2>/dev/null; then
    ok "bad settings leave the profile alone"
else
    bad "bad settings leave the profile alone"
fi

# 7. A failed modify leaves the state behind so the boot does not loop.
reset
touch "$LOG/modify_fail"
if run --now; then bad "a failed modify must fail"; else ok "a failed modify fails"; fi
if [ -s "$STATE" ]; then ok "a failed modify still records the attempt"; else bad "a failed modify still records the attempt"; fi

# 8. A failed activation fails and records the attempt.
reset
touch "$LOG/up_fail"
if run --now; then bad "a failed activation must fail"; else ok "a failed activation fails"; fi
if [ -s "$STATE" ]; then ok "a failed activation records the attempt"; else bad "a failed activation records the attempt"; fi

# 9. Unknown arguments are rejected.
reset
if run --bogus; then bad "an unknown argument must fail"; else ok "an unknown argument fails"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
