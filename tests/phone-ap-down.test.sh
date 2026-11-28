#!/usr/bin/env bash
# Hermetic tests for bin/phone-ap-down: stub id/nmcli, no phone, no network, no
# root. The default path still joins the phone's hotspot; --client stops the AP
# and leaves the radio free by never asking for the hotspot. The AP-state parser
# the Status page's switch uses is covered here too, without GTK.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-ap-down

. "$ROOT/tests/lib/harness.sh"
suite

export PHONE_HOTSPOT_CON=PhoneHotspot
export PHONE_AP_CON=phonelink

stub_cmd id "$STUBS" <<'EOF'
printf '0\n'
EOF

# Every nmcli call is logged. FAIL_DOWN makes the AP stop fail, so the command
# has to report it instead of going on to the hotspot or claiming success.
stub_cmd nmcli "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/nmcli"
case "$*" in
  "connection down phonelink")
    [ "${FAIL_DOWN:-0}" = 1 ] && exit 1
    ;;
  "-t -f NAME,DEVICE con show --active") printf 'phonelink:wlp110s0\n' ;;
esac
exit 0
EOF

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Default: stop the AP, then join the phone's own hotspot, as before.
rm -f "$LOG/nmcli"
if run; then ok "the default run exits 0"; else
  bad "the default run exits 0" "$(cat "$LOG/out")"
fi
grep -qx 'connection down phonelink' "$LOG/nmcli" \
  && ok "the default run stops the AP" \
  || bad "the default run stops the AP" "$(cat "$LOG/nmcli" 2>/dev/null)"
grep -qx 'connection up PhoneHotspot' "$LOG/nmcli" \
  && ok "the default run joins the phone hotspot" \
  || bad "the default run joins the phone hotspot" "$(cat "$LOG/nmcli" 2>/dev/null)"
grep -q 'joined the phone hotspot PhoneHotspot' "$LOG/out" \
  && ok "the default run reports the hotspot" \
  || bad "the default run reports the hotspot" "$(cat "$LOG/out")"

# 2. --client: stop the AP and never join the hotspot.
rm -f "$LOG/nmcli"
if run --client; then ok "--client exits 0"; else
  bad "--client exits 0" "$(cat "$LOG/out")"
fi
grep -qx 'connection down phonelink' "$LOG/nmcli" \
  && ok "--client stops the AP" \
  || bad "--client stops the AP" "$(cat "$LOG/nmcli" 2>/dev/null)"
if grep -q '^connection up ' "$LOG/nmcli"; then
  bad "--client never joins a network" "$(cat "$LOG/nmcli")"
else
  ok "--client never joins a network"
fi
grep -q 'Wi-Fi is free for NetworkManager to scan and join' "$LOG/out" \
  && ok "--client reports the free radio" \
  || bad "--client reports the free radio" "$(cat "$LOG/out")"

# 3. A failed AP stop is reported and exits non-zero; nothing else runs.
rm -f "$LOG/nmcli"
if FAIL_DOWN=1 run --client; then bad "a failed AP stop exits non-zero"; else
  ok "a failed AP stop exits non-zero"
fi
grep -q 'could not stop phonelink' "$LOG/out" \
  && ok "a failed AP stop is reported" \
  || bad "a failed AP stop is reported" "$(cat "$LOG/out")"
if grep -q '^connection up ' "$LOG/nmcli"; then
  bad "a failed AP stop still joins nothing" "$(cat "$LOG/nmcli")"
else
  ok "a failed AP stop still joins nothing"
fi

# 4b. External role: the AP belongs to another host, so no profile is stopped
#     and nothing is joined; the default and --client are both no-ops.
rm -f "$LOG/nmcli"
if PHONE_AP_ROLE=external run; then ok "external role exits 0"; else
  bad "external role exits 0" "$(cat "$LOG/out")"
fi
grep -q 'AP is external (phoneLink.ap.role = "external")' "$LOG/out" \
  && ok "explains that the AP is external" \
  || bad "explains that the AP is external" "$(cat "$LOG/out")"
grep -q 'phone-ap-down does not stop it' "$LOG/out" \
  && ok "says the local command leaves it alone" \
  || bad "says the local command leaves it alone" "$(cat "$LOG/out")"
[ -e "$LOG/nmcli" ] && bad "external role never calls nmcli" \
  || ok "external role never calls nmcli"
rm -f "$LOG/nmcli"
if PHONE_AP_ROLE=external run --client; then ok "external --client exits 0"; else
  bad "external --client exits 0" "$(cat "$LOG/out")"
fi
[ -e "$LOG/nmcli" ] && bad "external --client never calls nmcli" \
  || ok "external --client never calls nmcli"

# 5. --help prints the flag without touching the radio.
rm -f "$LOG/nmcli"
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi
grep -q -- '--client' "$LOG/out" && ok "--help documents --client" \
  || bad "--help documents --client" "$(cat "$LOG/out")"
[ -e "$LOG/nmcli" ] && bad "--help changes nothing" || ok "--help changes nothing"

# 5. An unknown flag is refused before anything is stopped.
rm -f "$LOG/nmcli"
if run --bogus; then bad "an unknown flag exits non-zero"; else
  ok "an unknown flag exits non-zero"
fi
grep -q 'unknown argument: --bogus' "$LOG/out" \
  && ok "an unknown flag is named" \
  || bad "an unknown flag is named" "$(cat "$LOG/out")"
[ -e "$LOG/nmcli" ] && bad "an unknown flag changes nothing" \
  || ok "an unknown flag changes nothing"

# 6. The pure AP-state parser the Status page uses.
if PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
from phone_link.ap_state import ap_is_on

assert ap_is_on("phonelink:wlp110s0\n", "", "phonelink")
assert ap_is_on("", "Interface wlp110s0\n\ttype AP\n", "phonelink")
assert not ap_is_on("Wired connection 1:eth0\n", "", "phonelink")
assert not ap_is_on("", "Interface wlp110s0\n\ttype managed\n", "phonelink")
assert not ap_is_on("", "", "phonelink")
PY
then ok "the AP-state parser reads the profile and iw"; else
  bad "the AP-state parser reads the profile and iw"
fi

finish
