#!/usr/bin/env bash
# Hermetic tests for bin/phone-ap-create: stub nmcli/sudo, temporary secrets.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-ap-create
. "$ROOT/tests/lib/harness.sh"
suite
export PHONE_SECRETS=$TMP/secrets
export PHONE_AP_DECLARATIVE=$TMP/ap-profile


stub nmcli
answer nmcli <<'EOF'
case "$*" in
  "-t -f NAME con show") cat "$LOG/names" ;;
  "connection add "*)
    printf '%s\n' "$*" >>"$LOG/actions"
    printf 'phonelink\n' >"$LOG/names"
    ;;
  "connection modify "*) printf '%s\n' "$*" >>"$LOG/actions" ;;
  "-g 802-11-wireless.mode connection show phonelink") printf 'ap\n' ;;
  "-g ipv4.method connection show phonelink") cat "$LOG/method" 2>/dev/null ;;
esac
EOF

stub id
answer id <<'EOF'
printf '0\n'
EOF

stub sudo
answer sudo <<'EOF'
exec "$@"
EOF

stub systemctl
answer systemctl <<'EOF'
case "$*" in
  # The module's DHCP-only dnsmasq and nft forward drop.
  "cat phone-link-ap-dhcp.service phone-link-ap-noforward.service")
    [ -f "$LOG/units" ] ;;
  *)
    printf '%s\n' "$*" >>"$LOG/actions"
    if [ -f "$LOG/recreate" ]; then printf 'phonelink\n' >"$LOG/names"; fi
    ;;
esac
EOF

printf 'PHONE_SOCKS_PASS=pass\nPHONE_PIN=1234\nPHONE_AP_PASS=ap-secret\n' >"$PHONE_SECRETS"
chmod 600 "$PHONE_SECRETS"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Missing profile: created with the secret PSK and AP settings.
: >"$LOG/names"
: >"$LOG/units"
printf 'manual\n' >"$LOG/method"
rm -f "$LOG/actions"
if run; then ok "create exits 0"; else bad "create exits 0" "$(cat "$LOG/out")"; fi
grep -q '^connection add type wifi ifname wlp110s0 con-name phonelink' "$LOG/actions" \
  && ok "adds the AP profile" || bad "adds the AP profile" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'ssid PhoneLink' "$LOG/actions" && ok "uses the AP SSID" || bad "uses the AP SSID"
grep -q '802-11-wireless.mode ap' "$LOG/actions" && ok "sets AP mode" \
  || bad "sets AP mode"
grep -q '802-11-wireless.band a' "$LOG/actions" && ok "uses the 5 GHz band" \
  || bad "uses the 5 GHz band" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q '802-11-wireless.channel 149' "$LOG/actions" && ok "uses channel 149" \
  || bad "uses channel 149" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q '802-11-wireless.channel-width 80' "$LOG/actions" && ok "uses 80 MHz" \
  || bad "uses 80 MHz" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'wifi-sec.psk ap-secret' "$LOG/actions" && ok "reads the PSK from secrets" \
  || bad "reads the PSK from secrets" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'ipv4.method manual' "$LOG/actions" && ok "uses the manual (no NAT) method" \
  || bad "uses the manual (no NAT) method" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'ipv4.method shared' "$LOG/actions" \
  && bad "does not use the shared method" || ok "does not use the shared method"
grep -q 'ipv4.addresses 192.168.77.1/24' "$LOG/actions" && ok "sets the AP address" \
  || bad "sets the AP address"
grep -q 'ipv4.gateway' "$LOG/actions" && bad "sets no gateway" || ok "sets no gateway"
grep -q 'ipv4.dns' "$LOG/actions" && bad "sets no DNS" || ok "sets no DNS"
[ -s "$LOG/names" ] && ok "profile exists afterwards" || bad "profile exists afterwards"

# 2. Existing profile: no change without --refresh.
printf 'phonelink\n' >"$LOG/names"
rm -f "$LOG/actions"
if run; then ok "existing exits 0"; else bad "existing exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/actions" ] && bad "existing changes nothing" || ok "existing changes nothing"
grep -q 'already exists' "$LOG/out" && ok "says it already exists" \
  || bad "says it already exists" "$(cat "$LOG/out")"

# 3. --refresh rewrites the settings and PSK.
printf 'phonelink\n' >"$LOG/names"
rm -f "$LOG/actions"
if run --refresh; then ok "--refresh exits 0"; else bad "--refresh exits 0" "$(cat "$LOG/out")"; fi
grep -q '^connection modify phonelink' "$LOG/actions" && ok "modifies the profile" \
  || bad "modifies the profile" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q '802-11-wireless.band a' "$LOG/actions" && ok "--refresh keeps the 5 GHz band" \
  || bad "--refresh keeps the 5 GHz band"
grep -q '802-11-wireless.channel 149' "$LOG/actions" && ok "--refresh keeps channel 149" \
  || bad "--refresh keeps channel 149"
grep -q '802-11-wireless.channel-width 80' "$LOG/actions" && ok "--refresh keeps 80 MHz" \
  || bad "--refresh keeps 80 MHz"
grep -q 'wifi-sec.psk ap-secret' "$LOG/actions" && ok "--refresh updates the PSK" \
  || bad "--refresh updates the PSK"

# 4. --check is read-only and reports a missing profile.
: >"$LOG/names"
rm -f "$LOG/actions"
if run --check; then bad "missing --check exits 1"; else ok "missing --check exits 1"; fi
[ -s "$LOG/actions" ] && bad "--check changes nothing" || ok "--check changes nothing"
grep -q 'phonelink is missing' "$LOG/out" && ok "reports the missing profile" \
  || bad "reports the missing profile"

# 4b. --check names a shared profile and the missing link-only units.
printf 'phonelink\n' >"$LOG/names"
printf 'shared\n' >"$LOG/method"
rm -f "$LOG/units" "$LOG/actions"
if run --check; then ok "shared --check still exits 0"; else bad "shared --check still exits 0"; fi
grep -q 'ipv4.method shared (NAT)' "$LOG/out" && ok "reports the shared method" \
  || bad "reports the shared method" "$(cat "$LOG/out")"
grep -q 'link-only units: missing' "$LOG/out" && ok "reports the missing units" \
  || bad "reports the missing units" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "--check changes nothing" || ok "--check changes nothing"
printf 'manual\n' >"$LOG/method"
: >"$LOG/units"

# 5. A missing secret is refused before any nmcli change.
: >"$LOG/names"
rm -f "$LOG/actions"
if PHONE_SECRETS=$TMP/missing run; then bad "missing secret exits 1"; else ok "missing secret exits 1"; fi
[ -s "$LOG/actions" ] && bad "missing secret changes nothing" || ok "missing secret changes nothing"

# 5b. An old shared profile is rewritten as link-only, even without --refresh.
printf 'phonelink\n' >"$LOG/names"
printf 'shared\n' >"$LOG/method"
: >"$LOG/units"
rm -f "$LOG/actions"
if run; then ok "a shared profile is rewritten"; else bad "a shared profile is rewritten" "$(cat "$LOG/out")"; fi
grep -q '^connection modify phonelink' "$LOG/actions" && ok "modifies the shared profile" \
  || bad "modifies the shared profile" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'ipv4.method manual' "$LOG/actions" && ok "rewrites it with the manual method" \
  || bad "rewrites it with the manual method"
grep -q 'ipv4.method shared' "$LOG/actions" && bad "never writes shared again" || ok "never writes shared again"
grep -q 'rewriting phonelink as a link-only profile' "$LOG/out" && ok "says it is rewriting" \
  || bad "says it is rewriting" "$(cat "$LOG/out")"

# 5c. Without the module's DHCP/drop units, creation is refused: the profile
#     would otherwise be unreachable or bring the shared NAT loop back.
: >"$LOG/names"
rm -f "$LOG/units" "$LOG/actions"
if run; then bad "no link-only units exits 1"; else ok "no link-only units exits 1"; fi
grep -q 'phoneLink.ap.enable' "$LOG/out" && ok "points at the module setting" \
  || bad "points at the module setting" "$(cat "$LOG/out")"
grep -q 'link-only access point needs the NixOS module' "$LOG/out" \
  && ok "explains why it is refused" || bad "explains why it is refused" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "the refusal changes nothing" || ok "the refusal changes nothing"
[ -s "$LOG/names" ] && bad "the refusal creates no profile" || ok "the refusal creates no profile"

# 5d. An existing shared profile is not left alone when the units are missing:
#     the run refuses and says the profile must be deleted.
printf 'phonelink\n' >"$LOG/names"
printf 'shared\n' >"$LOG/method"
rm -f "$LOG/actions"
if run; then bad "an unfixable shared profile exits 1"; else ok "an unfixable shared profile exits 1"; fi
grep -q 'phone-ap-delete' "$LOG/out" || grep -q 'phoneLink.ap.enable' "$LOG/out" \
  && ok "names the way out" || bad "names the way out" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "the refusal leaves NM alone" || ok "the refusal leaves NM alone"
printf 'manual\n' >"$LOG/method"
: >"$LOG/units"

# 5e. --refresh without the module units refuses too, rather than silently
#     leaving the old PSK (or the old profile) in place.
printf 'phonelink\n' >"$LOG/names"
rm -f "$LOG/units" "$LOG/actions"
if run --refresh; then bad "refresh without units exits 1"; else ok "refresh without units exits 1"; fi
grep -q 'phoneLink.ap.enable' "$LOG/out" && ok "refresh points at the module" \
  || bad "refresh points at the module" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "refresh without units changes nothing" \
  || ok "refresh without units changes nothing"
: >"$LOG/units"

# 6. Declarative: --refresh restarts the ensure unit, never edits NM.
printf 'phonelink\n' >"$PHONE_AP_DECLARATIVE"
printf 'phonelink\n' >"$LOG/names"
rm -f "$LOG/actions"
if run --refresh; then ok "declarative --refresh exits 0"; else bad "declarative --refresh exits 0" "$(cat "$LOG/out")"; fi
grep -qx 'restart NetworkManager-ensure-profiles.service' "$LOG/actions" \
  && ok "restarts the ensure unit" || bad "restarts the ensure unit" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q '^connection modify' "$LOG/actions" \
  && bad "declarative --refresh leaves NM alone" || ok "declarative --refresh leaves NM alone"

# 7. Declarative: a missing profile is recreated by the ensure unit.
printf 'phonelink\n' >"$PHONE_AP_DECLARATIVE"
: >"$LOG/names"
: >"$LOG/recreate"
rm -f "$LOG/actions"
if run; then ok "declarative create exits 0"; else bad "declarative create exits 0" "$(cat "$LOG/out")"; fi
grep -qx 'restart NetworkManager-ensure-profiles.service' "$LOG/actions" \
  && ok "recreates through the ensure unit" || bad "recreates through the ensure unit"
[ -s "$LOG/names" ] && ok "declarative profile exists afterwards" \
  || bad "declarative profile exists afterwards"
rm -f "$LOG/recreate"

# 8. Declarative --check is read-only and names the owner.
printf 'phonelink\n' >"$PHONE_AP_DECLARATIVE"
printf 'phonelink\n' >"$LOG/names"
rm -f "$LOG/actions"
if run --check; then ok "declarative --check exits 0"; else bad "declarative --check exits 0"; fi
grep -q 'declared by phoneLink.ap' "$LOG/out" \
  && ok "reports the declarative owner" || bad "reports the declarative owner" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "declarative --check changes nothing" \
  || ok "declarative --check changes nothing"

# 9. External role: there is no local profile to create or refresh.
rm -f "$PHONE_AP_DECLARATIVE"
: >"$LOG/names"
rm -f "$LOG/actions"
if PHONE_AP_ROLE=external run --check; then ok "external --check exits 0"; else
  bad "external --check exits 0" "$(cat "$LOG/out")"
fi
grep -q 'AP is external (phoneLink.ap.role = "external")' "$LOG/out" \
  && ok "explains that the AP is external" || bad "explains that the AP is external"
grep -q 'no local profile to create or refresh' "$LOG/out" \
  && ok "says there is no profile to create" || bad "says there is no profile to create"
[ -s "$LOG/actions" ] && bad "external role changes nothing" \
  || ok "external role changes nothing"

# 10. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

finish
