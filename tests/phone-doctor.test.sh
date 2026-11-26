#!/usr/bin/env bash
# Hermetic tests for bin/phone-doctor: stub adb, ip, nmcli, sysctl, systemctl
# and curl. No phone, no network, no root.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-doctor
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
# The doctor caches the newest release under the cache directory for a day,
# so the suite keeps that inside its sandbox too.
export XDG_CACHE_HOME=$TMP/cache
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

cat >"$STUBS/adb" <<'EOF'
#!/usr/bin/env bash
target=""
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then target=${args[1]}; args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  devices) cat "$LOG/devices" ;;
  connect)
    printf '%s\n' "${args[1]:-}" >>"$LOG/connected"
    printf 'connected to %s\n' "${args[1]:-}"
    # $LOG/deny lists addresses adbd does not answer on: a phone that never
    # pinned its adbd, so the mDNS fallback is what the test is about.
    denied=0
    if [ -f "$LOG/deny" ] && grep -qx "${args[1]:-}" "$LOG/deny"; then
      denied=1
    fi
    if [ "$denied" = 0 ] && [ -f "$LOG/connect_ok" ]; then
      printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n%s\tdevice\n' \
        "${args[1]:-}" >"$LOG/devices"
    fi
    ;;
  shell)
    args=("${args[@]:1}")
    case "${args[*]}" in
      "dumpsys window policy") printf '  showing=%s\n' "$(cat "$LOG/keyguard")" ;;
      "ip -4 -o addr show rndis0") cat "$LOG/rndis" ;;
      "ip -4 -o addr show"*) cat "$LOG/ips" ;;
      "ip route show default") cat "$LOG/default_route" ;;
      "pm path "*) cat "$LOG/pm" ;;
      "dumpsys package "*) cat "$LOG/dumpsys" ;;
      "dumpsys deviceidle whitelist") cat "$LOG/whitelist" ;;
      "dumpsys activity service "*) cat "$LOG/service_dump" ;;
      # The app's own facts, for a service that is not running: the doctor
      # reads them from the file under the app's external directory.
      "cat /sdcard/Android/data/"*)
        cat "$LOG/app_state" 2>/dev/null ;;
      "getprop ro.build.version.sdk") cat "$LOG/sdk" ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"

cat >"$STUBS/avahi-browse" <<'EOF'
#!/usr/bin/env bash
cat "$LOG/avahi"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/avahi-browse"

cat >"$STUBS/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-4 -br addr show "*) cat "$LOG/ap_addr" ;;
  "rule show") cat "$LOG/rules" ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/ip"

cat >"$STUBS/nmcli" <<'EOF'
#!/usr/bin/env bash
cat "$LOG/nmcli_cons"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/nmcli"

cat >"$STUBS/sysctl" <<'EOF'
#!/usr/bin/env bash
cat "$LOG/forward"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/sysctl"

cat >"$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active phone-tun.service")
    cat "$LOG/tunnel"
    [ "$(cat "$LOG/tunnel")" = active ] ;;
  "is-active phone-link-ap-dhcp.service")
    cat "$LOG/ap_dhcp"
    [ "$(cat "$LOG/ap_dhcp")" = active ] ;;
  "is-active phone-link-ap-noforward.service")
    cat "$LOG/ap_noforward"
    [ "$(cat "$LOG/ap_noforward")" = active ] ;;
  *)
    cat "$LOG/tunnel"
    [ "$(cat "$LOG/tunnel")" = active ] ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/systemctl"

cat >"$STUBS/nft" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "list table inet phone_link_ap")
    [ -f "$LOG/nft" ] && cat "$LOG/nft" ;;
  *) exit 1 ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/nft"

cat >"$STUBS/iw" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "dev wlp110s0 station dump") cat "$LOG/iw_station" 2>/dev/null ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/iw"

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--socks5-hostname*) printf '%s' "$(cat "$LOG/proxy_code")" ;;
  # The release check: no file queued means "could not ask", which is what an
  # offline host sees and what keeps this suite off the network.
  *api.github.com*) cat "$LOG/release_json" 2>/dev/null ;;
  *) printf '%s' "$(cat "$LOG/internet_code")" ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/curl"

cat >"$STUBS/git" <<'EOF'
#!/usr/bin/env bash
while [ "${1:-}" = "-C" ]; do shift 2; done
case "$*" in
  "rev-parse HEAD") cat "$LOG/local_head" ;;
  "log -1 --format=%ct") cat "$LOG/head_time" ;;
  "ls-remote "*)
    head=$(cat "$LOG/remote_head")
    if [ -n "$head" ]; then printf '%s\tHEAD\n' "$head"; else exit 128; fi
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/git"

chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
export PHONE_SECRETS=$TMP/secrets
export PHONE_DOCTOR_RESOLV=$LOG/resolv.conf
# phoneLink.ap's marker: absent means hotspot mode, so the AP checks are skipped
# unless a case turns the module-owned AP on.
export PHONE_AP_DECLARATIVE=$LOG/ap-profile
export PHONE_APK_CACHE=$TMP/cache
export PHONE_PROXY_APK=$TMP/app.apk
# The port in use normally comes from /run/phone-link/proxy-port; the suite
# keeps that inside its sandbox so a machine that has switched is not a
# different test run.
export PHONE_RUNTIME_PORT_FILE=$TMP/runtime-port
export PHONE_NIXOS_DIR=$TMP/nixos PHONE_FLAKE_SRC=$TMP/no-src
printf 'PHONE_SOCKS_PASS=pass\nPHONE_PIN=1234\nPHONE_AP_PASS=pass\n' >"$PHONE_SECRETS"
chmod 600 "$PHONE_SECRETS"

fresh_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n192.168.77.232:5555\tdevice\n' >"$LOG/devices"
  printf 'false\n' >"$LOG/keyguard"
  printf '2: wlan0    inet 192.168.77.232/24 brd 192.168.77.255 scope global wlan0\n3: rndis0    inet 10.9.9.9/24 brd 10.9.9.255 scope global rndis0\n' >"$LOG/ips"
  printf 'default via 10.0.0.1 dev wlan0\n' >"$LOG/default_route"
  printf '3: rndis0    inet 10.9.9.9/24 brd 10.9.9.255 scope global rndis0\n' >"$LOG/rndis"
  printf 'package:/data/app/base.apk\n' >"$LOG/pm"
  printf 'wlp110s0 UP 192.168.77.1/24\n' >"$LOG/ap_addr"
  printf 'phonelink\n' >"$LOG/nmcli_cons"
  # The module owns the AP: both units, the nft drop and the phone's station.
  printf 'phonelink\n' >"$LOG/ap-profile"
  printf 'active\n' >"$LOG/ap_dhcp"
  printf 'active\n' >"$LOG/ap_noforward"
  printf 'table inet phone_link_ap {\n\tchain forward {\n\t\tiifname "wlp110s0" drop\n\t}\n}\n' \
    >"$LOG/nft"
  printf 'Station aa:bb:cc:dd:ee:ff (on wlp110s0)\n' >"$LOG/iw_station"
  printf '1\n' >"$LOG/forward"
  printf 'active\n' >"$LOG/tunnel"
  printf '2022: from all fwmark 0x7e6 lookup 2022\n' >"$LOG/rules"
  printf '200' >"$LOG/proxy_code"
  printf '200' >"$LOG/internet_code"
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >"$LOG/resolv.conf"
  printf '    versionCode=1 minSdk=26 targetSdk=34\n    versionName=0.1.0\n    ACCESS_BACKGROUND_LOCATION: granted=true\n' >"$LOG/dumpsys"
  printf '      running     port 1080 · 0 clients\n      auto-start  true\n' >"$LOG/service_dump"
  printf 'auto_start true\nadb_wifi true\nport 1080\nssid PhoneLink\nany_network false\nin_use \n' \
    >"$LOG/app_state"
  printf 'user,org.phonelink.proxy,10332\n' >"$LOG/whitelist"
  printf '35\n' >"$LOG/sdk"
  # The APK a repair would use is a file here, so the check reports what it was
  # given and nothing else; the version is whatever the phone says.
  : >"$TMP/app.apk"
  : >"$LOG/avahi"
  : >"$LOG/connected"
  : >"$LOG/connect_ok"
  # By default the phone has not pinned adbd: the pinned probe is a connect
  # that fails, and the case that wants a pinned phone removes this file.
  printf '192.168.77.232:5555\n10.244.108.165:5555\n' >"$LOG/deny"
  printf 'abc\n' >"$LOG/local_head"
  printf 'abc\n' >"$LOG/remote_head"
  printf '200\n' >"$LOG/head_time"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Everything in place.
fresh_state
if run; then ok "ready setup exits 0"; else bad "ready setup exits 0" "$(cat "$LOG/out")"; fi
grep -q 'verdict: the whole setup is ready' "$LOG/out" && ok "reports the whole setup ready" \
  || bad "reports the whole setup ready" "$(cat "$LOG/out")"
grep -q '^FAIL' "$LOG/out" && bad "no failures" || ok "no failures"
grep -q 'ok    adb device' "$LOG/out" && ok "reports the adb device" || bad "reports the adb device"
grep -q 'proxy request.*192.168.77.232:1080 -> 200' "$LOG/out" && ok "reports the proxy request" \
  || bad "reports the proxy request" "$(cat "$LOG/out")"
grep -q 'ok    proxy port.*laptop 1080, phone 1080' "$LOG/out" \
  && ok "matches the laptop's port with the phone's" \
  || bad "matches the laptop's port with the phone's" "$(cat "$LOG/out")"
grep -q 'network transport' "$LOG/out" && ok "reports adb over Wi-Fi" || bad "reports adb over Wi-Fi"
grep -q 'ok    ap dhcp' "$LOG/out" && ok "checks the AP DHCP unit" || bad "checks the AP DHCP unit"
grep -q 'ok    ap noforward' "$LOG/out" && ok "checks the AP no-forward unit" \
  || bad "checks the AP no-forward unit" "$(cat "$LOG/out")"
grep -q 'ok    ap forward drop' "$LOG/out" && ok "checks the nft forward drop" \
  || bad "checks the nft forward drop" "$(cat "$LOG/out")"
grep -q 'ok    ap station.*1 on wlp110s0' "$LOG/out" && ok "checks the phone association" \
  || bad "checks the phone association" "$(cat "$LOG/out")"
grep -q 'ok    secrets mode.*600' "$LOG/out" && ok "checks the secrets mode" \
  || bad "checks the secrets mode" "$(cat "$LOG/out")"

# 2. No phone: required failure, phone checks skipped, rest still checked.
fresh_state
printf 'List of devices attached\n' >"$LOG/devices"
if run; then bad "missing phone exits 1"; else ok "missing phone exits 1"; fi
grep -q 'FAIL  adb device' "$LOG/out" && ok "fails the adb condition" || bad "fails the adb condition"
grep -q 'skip  phone address' "$LOG/out" && ok "skips phone checks" || bad "skips phone checks"
grep -q 'ok    https' "$LOG/out" && ok "still checks the internet" || bad "still checks the internet"
grep -q 'setup is not ready' "$LOG/out" && ok "verdict is not ready" || bad "verdict is not ready"

# 3. Locked phone is optional for the proxy but reported.
fresh_state
printf 'true\n' >"$LOG/keyguard"
if run; then ok "locked phone still exits 0"; else bad "locked phone still exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  phone unlocked' "$LOG/out" && ok "warns about the keyguard" || bad "warns about the keyguard"
grep -q 'optional condition(s) open' "$LOG/out" && ok "counts the warning" || bad "counts the warning"

# 4. Forwarding off is only a warning: the link-only AP does not forward.
fresh_state
printf '0\n' >"$LOG/forward"
if run; then ok "forwarding off still exits 0"; else bad "forwarding off still exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  ip_forward' "$LOG/out" && ok "warns about ip_forward" || bad "warns about ip_forward"
grep -q 'the link-only AP does not forward' "$LOG/out" \
  && ok "says forwarding is not needed" || bad "says forwarding is not needed" "$(cat "$LOG/out")"
run --analyze || true
grep -q '^warn ip_forward ' "$LOG/out" && ok "--analyze reports it as a warning" \
  || bad "--analyze reports it as a warning" "$(cat "$LOG/out")"

# 5. Hotspot mode: no AP interface, missing AP profile only warns, and the
#    module-only AP pieces are skipped.
fresh_state
: >"$LOG/ap_addr"
: >"$LOG/nmcli_cons"
rm -f "$LOG/ap-profile"
printf '2: wlan0    inet 10.244.108.165/24 brd 10.244.108.255 scope global wlan0\n' >"$LOG/ips"
if run; then ok "hotspot mode exits 0"; else bad "hotspot mode exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  ap profile' "$LOG/out" && ok "warns about the AP profile" || bad "warns about the AP profile"
grep -q 'warn  ap address' "$LOG/out" && ok "warns about the AP address" || bad "warns about the AP address"
grep -q 'skip  ap units.*phoneLink.ap is off' "$LOG/out" \
  && ok "skips the module-only AP checks" || bad "skips the module-only AP checks" "$(cat "$LOG/out")"
grep -q 'proxy request.*10.244.108.165:1080 -> 200' "$LOG/out" && ok "checks the hotspot address" \
  || bad "checks the hotspot address" "$(cat "$LOG/out")"

# 6. A dead proxy is a required failure.
fresh_state
printf '000' >"$LOG/proxy_code"
if run; then bad "dead proxy exits 1"; else ok "dead proxy exits 1"; fi
grep -q 'FAIL  proxy request.*-> 000' "$LOG/out" && ok "fails the proxy request" \
  || bad "fails the proxy request" "$(cat "$LOG/out")"

# 6b. A port the phone is not listening on is named, with the command that
#     moves the laptop.
fresh_state
printf '1081\n' >"$PHONE_RUNTIME_PORT_FILE"
if run; then ok "a port mismatch still exits 0"; else bad "a port mismatch still exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  proxy port.*laptop 1081, phone listens on 1080' "$LOG/out" \
  && ok "warns about the mismatch" || bad "warns about the mismatch" "$(cat "$LOG/out")"
grep -q 'run phone-proxy-switch' "$LOG/out" && ok "says how to switch" \
  || bad "says how to switch" "$(cat "$LOG/out")"
rm -f "$PHONE_RUNTIME_PORT_FILE"

# 7. Missing secrets: no proxy check, required failures.
fresh_state
if PHONE_SECRETS=$TMP/missing run; then bad "missing secrets exits 1"; else ok "missing secrets exits 1"; fi
grep -q 'FAIL  secrets' "$LOG/out" && ok "fails the secrets condition" || bad "fails the secrets condition"
grep -q 'FAIL  proxy request.*PHONE_SOCKS_PASS' "$LOG/out" && ok "explains the missing password" \
  || bad "explains the missing password" "$(cat "$LOG/out")"

# 7b. A secrets file readable by others is a warning, not a failed setup.
fresh_state
chmod 644 "$PHONE_SECRETS"
if run; then ok "an open secrets file still exits 0"; else bad "an open secrets file still exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  secrets mode.*644 (should be 600)' "$LOG/out" \
  && ok "warns about the secrets mode" || bad "warns about the secrets mode" "$(cat "$LOG/out")"
chmod 600 "$PHONE_SECRETS"

# 8. An inactive tunnel is optional, but its route is not checked then.
fresh_state
printf 'inactive\n' >"$LOG/tunnel"
if run; then ok "inactive tunnel exits 0"; else bad "inactive tunnel exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  phone-tun' "$LOG/out" && ok "warns about the tunnel" || bad "warns about the tunnel"
grep -q 'tunnel route' "$LOG/out" && bad "skips the tunnel route" || ok "skips the tunnel route"

# 9. USB tether off only warns.
fresh_state
: >"$LOG/rndis"
if run; then ok "tether off exits 0"; else bad "tether off exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  rndis0' "$LOG/out" && ok "warns about the tether" || bad "warns about the tether"

# 10. An AP profile with the AP down is a required failure.
fresh_state
: >"$LOG/ap_addr"
if run; then bad "AP down exits 1"; else ok "AP down exits 1"; fi
grep -q 'FAIL  ap address' "$LOG/out" && ok "fails the AP address" || bad "fails the AP address"
run --analyze || true
grep -q '^fail ap_address ' "$LOG/out" && ok "--analyze names ap_address" \
  || bad "--analyze names ap_address" "$(cat "$LOG/out")"

# 10b. A stopped AP DHCP or no-forward unit is a required failure.
fresh_state
printf 'inactive\n' >"$LOG/ap_dhcp"
if run; then bad "a stopped AP DHCP unit exits 1"; else ok "a stopped AP DHCP unit exits 1"; fi
grep -q 'FAIL  ap dhcp.*inactive (phone-link-ap-dhcp.service)' "$LOG/out" \
  && ok "names the stopped DHCP unit" || bad "names the stopped DHCP unit" "$(cat "$LOG/out")"
fresh_state
printf 'failed\n' >"$LOG/ap_noforward"
if run; then bad "a failed no-forward unit exits 1"; else ok "a failed no-forward unit exits 1"; fi
grep -q 'FAIL  ap noforward.*failed (phone-link-ap-noforward.service)' "$LOG/out" \
  && ok "names the failed no-forward unit" || bad "names the failed no-forward unit" "$(cat "$LOG/out")"

# 10c. A missing nft table or forward drop is a required failure.
fresh_state
rm -f "$LOG/nft"
if run; then bad "a missing nft table exits 1"; else ok "a missing nft table exits 1"; fi
grep -q 'FAIL  ap forward drop.*table inet phone_link_ap missing' "$LOG/out" \
  && ok "names the missing nft table" || bad "names the missing nft table" "$(cat "$LOG/out")"
fresh_state
printf 'table inet phone_link_ap {\n\tchain forward {\n\t\tpolicy accept\n\t}\n}\n' >"$LOG/nft"
if run; then bad "a table without the drop exits 1"; else ok "a table without the drop exits 1"; fi
grep -q 'FAIL  ap forward drop.*no drop for wlp110s0' "$LOG/out" \
  && ok "names the missing drop" || bad "names the missing drop" "$(cat "$LOG/out")"

# 10d. An AP with no associated station is a required failure.
fresh_state
: >"$LOG/iw_station"
if run; then bad "no station exits 1"; else ok "no station exits 1"; fi
grep -q 'FAIL  ap station.*no phone associated on wlp110s0' "$LOG/out" \
  && ok "names the missing station" || bad "names the missing station" "$(cat "$LOG/out")"
run --analyze || true
grep -q '^fail ap_station ' "$LOG/out" && ok "--analyze names ap_station" \
  || bad "--analyze names ap_station" "$(cat "$LOG/out")"

# 10e. Missing tools are skips, not crashes: the checks run with no PATH.
marker=$LOG/ap-profile
printf 'phonelink\n' >"$marker"
if PYTHONPATH="$ROOT/lib/python" python3 - "$marker" >"$LOG/ap_skip" 2>&1 <<'PY'
import sys

from phone_doctor.checks import ap
from phone_doctor.context import Context

ctx = Context({"PATH": "/nonexistent", "PHONE_AP_DECLARATIVE": sys.argv[1]})
results = ap.check(ctx)
assert len(results) == 4, results
assert all(r.status.value == "skip" for r in results), results
print("skipped: " + " ".join(r.cid for r in results))
PY
then ok "missing tools only skip"; else bad "missing tools only skip" "$(cat "$LOG/ap_skip")"; fi

# 11. The app off the Doze allowlist cannot come back at boot.
fresh_state
: >"$LOG/whitelist"
if run; then bad "app off the allowlist exits 1"; else ok "app off the allowlist exits 1"; fi
grep -q 'FAIL  restarts at boot.*battery allowlist' "$LOG/out" && ok "fails app_boot" \
  || bad "fails app_boot" "$(cat "$LOG/out")"
run --analyze || true
grep -q '^fail app_boot ' "$LOG/out" && ok "--analyze names app_boot" \
  || bad "--analyze names app_boot" "$(cat "$LOG/out")"

# 12. With the allowlist but no auto_start, it is the switch that is named.
fresh_state
printf '      auto-start  false\n' >"$LOG/service_dump"
if run; then bad "auto_start off exits 1"; else ok "auto_start off exits 1"; fi
grep -q 'FAIL  restarts at boot.*auto_start is off' "$LOG/out" && ok "names the switch" \
  || bad "names the switch" "$(cat "$LOG/out")"

# 12b. A stopped service prints nothing; the app's own state file answers the
# question the check needs, instead of the check degrading to "could not read".
fresh_state
: >"$LOG/service_dump"
if run; then ok "a stopped app still passes its boot check"; else bad "a stopped app still passes its boot check" "$(cat "$LOG/out")"; fi
grep -q 'ok    restarts at boot.*auto_start on' "$LOG/out" \
  && ok "reads auto_start from the state file" \
  || bad "reads auto_start from the state file" "$(cat "$LOG/out")"
# And the file's answer is the truth, not a default: off is a failure.
printf 'auto_start false\n' >"$LOG/app_state"
if run; then bad "a stopped app with auto_start off exits 1"; else ok "a stopped app with auto_start off exits 1"; fi
grep -q 'FAIL  restarts at boot.*auto_start is off' "$LOG/out" \
  && ok "and names the switch it read" || bad "and names the switch it read" "$(cat "$LOG/out")"
# Neither the service nor the file: the old warning, saying what was missing.
: >"$LOG/app_state"
if run; then ok "no answer still exits 0"; else bad "no answer still exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  restarts at boot.*state file answered' "$LOG/out" \
  && ok "says both places were asked" || bad "says both places were asked" "$(cat "$LOG/out")"

# 13. An APK that is not there is a required failure, and the one named is the
# one the repair would hand to adb.
fresh_state
export PHONE_PROXY_APK=$TMP/missing.apk
if run; then bad "missing APK exits 1"; else ok "missing APK exits 1"; fi
grep -q "FAIL  app apk.*$TMP/missing.apk is not there" "$LOG/out" && ok "fails the app apk check" \
  || bad "fails the app apk check" "$(cat "$LOG/out")"
export PHONE_PROXY_APK=$TMP/app.apk
fresh_state
if run; then ok "the named APK passes"; else bad "the named APK passes" "$(cat "$LOG/out")"; fi
grep -q "ok    app apk.*$TMP/app.apk" "$LOG/out" && ok "passes with the APK it was given" \
  || bad "passes with the APK it was given" "$(cat "$LOG/out")"

# 12. The installed proxy version is reported as what the phone says: this
#     checkout builds nothing to compare it with, so there is no warning to
#     earn and no version it could be wrong about.
fresh_state
if run; then ok "the installed app exits 0"; else bad "the installed app exits 0" "$(cat "$LOG/out")"; fi
grep -q "ok    proxy version.*0.1.0 (1)" "$LOG/out" \
  && ok "reports the installed version" || bad "reports the installed version" \
  "$(cat "$LOG/out")"
fresh_state
printf '    versionCode=24 minSdk=26 targetSdk=34\n    versionName=1.7.4\n    ACCESS_BACKGROUND_LOCATION: granted=true\n' >"$LOG/dumpsys"
if run; then ok "another version still exits 0"; else bad "another version still exits 0"; fi
grep -q "ok    proxy version.*1.7.4 (24)" "$LOG/out" \
  && ok "reports it without comparing" || bad "reports it without comparing" \
  "$(cat "$LOG/out")"
grep -q 'ok    proxy compat.*minSdk 26 <= phone SDK 35' "$LOG/out" \
  && ok "checks the SDK compatibility" || bad "checks the SDK compatibility" "$(cat "$LOG/out")"

# 14. A flake lock older than the source HEAD is reported.
fresh_state
mkdir -p "$TMP/src/.git" "$TMP/nixos"
printf '{\n  "nodes": {\n    "phone-link": {\n      "locked": {\n        "lastModified": 100\n      }\n    }\n  }\n}\n' >"$TMP/nixos/flake.lock"
export PHONE_FLAKE_SRC=$TMP/src PHONE_NIXOS_DIR=$TMP/nixos
if run; then ok "stale flake still exits 0"; else bad "stale flake still exits 0"; fi
grep -q 'warn  flake update.*older' "$LOG/out" && ok "warns about the stale lock" \
  || bad "warns about the stale lock" "$(cat "$LOG/out")"
unset PHONE_FLAKE_SRC PHONE_NIXOS_DIR

# 14b. A GitHub input has no checkout; the lock is compared with the remote.
fresh_state
mkdir -p "$TMP/nixos"
printf '{\n  "nodes": {\n    "phone-link": {\n      "original": {"owner": "MBanucu", "repo": "phone-link", "type": "github", "ref": "v0.3.6"},\n      "locked": {"lastModified": 100, "rev": "aaaaaaaaaaaa", "type": "github"}\n    }\n  }\n}\n' >"$TMP/nixos/flake.lock"
export PHONE_NIXOS_DIR=$TMP/nixos PHONE_FLAKE_SRC=$TMP/no-src
printf 'bbbbbbbbbbbb\n' >"$LOG/remote_head"
if run; then ok "an outdated remote lock still exits 0"; else bad "an outdated remote lock still exits 0"; fi
grep -q 'warn  flake update.*origin is at bbbbbbbbbbbb, the lock has aaaaaaaaaaaa' "$LOG/out" \
  && ok "warns when the lock is behind the remote" \
  || bad "warns when the lock is behind the remote" "$(cat "$LOG/out")"
printf 'aaaaaaaaaaaa\n' >"$LOG/remote_head"
if run; then ok "a matching remote still exits 0"; else bad "a matching remote still exits 0"; fi
grep -q 'ok    flake update.*up to date (aaaaaaaaaaaa)' "$LOG/out" \
  && ok "accepts a matching remote" || bad "accepts a matching remote" "$(cat "$LOG/out")"
: >"$LOG/remote_head"
if run; then ok "an unreachable remote still exits 0"; else bad "an unreachable remote still exits 0"; fi
grep -q 'skip  flake update.*unreachable' "$LOG/out" \
  && ok "skips an unreachable remote" || bad "skips an unreachable remote" "$(cat "$LOG/out")"
# Keep the fixture environment for the rest of the suite: with no lock file the
# flake check is a skip, so a live /etc/nixos (with whatever the host has
# repinned) can never turn a later ready-state case into a warning.
rm -f "$TMP/nixos/flake.lock"
export PHONE_NIXOS_DIR=$TMP/nixos PHONE_FLAKE_SRC=$TMP/no-src

# 15. --analyze prints only the problems, as stable ids.
fresh_state
if run --analyze; then ok "--analyze on a ready setup exits 0"; else bad "--analyze on a ready setup exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/out" ] && bad "--analyze on a ready setup is empty" "$(cat "$LOG/out")" \
  || ok "--analyze on a ready setup is empty"
fresh_state
printf 'List of devices attached\n' >"$LOG/devices"
if run --analyze; then bad "--analyze with problems exits 1"; else ok "--analyze with problems exits 1"; fi
grep -q '^fail adb_device ' "$LOG/out" && ok "--analyze names the problem id" \
  || bad "--analyze names the problem id" "$(cat "$LOG/out")"
grep -q '^ok ' "$LOG/out" && bad "--analyze omits ok lines" || ok "--analyze omits ok lines"
grep -q '^\[' "$LOG/out" && bad "--analyze omits section headers" || ok "--analyze omits section headers"
fresh_state
printf 'true\n' >"$LOG/keyguard"
if run --analyze; then ok "--analyze with only warnings exits 0"; else bad "--analyze with only warnings exits 0"; fi
grep -q '^warn phone_unlocked ' "$LOG/out" && ok "--analyze reports warnings" \
  || bad "--analyze reports warnings" "$(cat "$LOG/out")"

# 16. A phone whose wireless port rotated is reconnected from its mDNS record.
fresh_state
printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
printf '=;wlp110s0;IPv4;adb-XPLO2EEA0001541-D1gkYk;_adb-tls-connect._tcp;local;Android.local;192.168.77.232;44895;"v=ADB_SECURE_SERVICE_VERSION"\n' >"$LOG/avahi"
: >"$LOG/connect_ok"
if run; then ok "a rotated adb port still exits 0"; else
  bad "a rotated adb port still exits 0" "$(cat "$LOG/out")"
fi
grep -q 'network transport.*192.168.77.232:44895' "$LOG/out" \
  && ok "reports the port from mDNS" || bad "reports the port from mDNS" "$(cat "$LOG/out")"
grep -q '192.168.77.232:44895' "$LOG/connected" && ok "connects with adb" \
  || bad "connects with adb" "$(cat "$LOG/connected")"

# 17. An advertised port that adb refuses is a warning with the address.
fresh_state
printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
printf '=;wlp110s0;IPv4;adb-XPLO2EEA0001541-D1gkYk;_adb-tls-connect._tcp;local;Android.local;192.168.77.232;44895;\n' >"$LOG/avahi"
if run; then ok "a refused connect still exits 0"; else
  bad "a refused connect still exits 0" "$(cat "$LOG/out")"
fi
grep -q 'is advertised but adb connect failed' "$LOG/out" \
  && ok "names the advertised address" || bad "names the advertised address" "$(cat "$LOG/out")"

# 18. A phone whose wireless debugging is off is announced, and never resolved:
# the name is on the network with nothing listening behind it, which is a fault
# on the phone and not a phone that is elsewhere.
fresh_state
printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
printf '+;wlp110s0;IPv6;adb-XPLO2EEA0001541-D1gkYk;_adb-tls-connect._tcp;local\n+;wlp110s0;IPv4;adb-XPLO2EEA0001541-D1gkYk;_adb-tls-connect._tcp;local\n' >"$LOG/avahi"
if run; then ok "an unresolved announcement still exits 0"; else
  bad "an unresolved announcement still exits 0" "$(cat "$LOG/out")"
fi
grep -q 'announced with no address: wireless debugging is off' "$LOG/out" \
  && ok "names wireless debugging as the fault" || bad "names wireless debugging as the fault" "$(cat "$LOG/out")"
grep -q 'USB only' "$LOG/out" && bad "does not fall back to USB only" \
  || ok "does not fall back to USB only"

# 19. A phone whose adbd was pinned to the fixed port is reported there, with
# no mDNS record to read and no random port to chase.
fresh_state
rm -f "$LOG/deny"
printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
: >"$LOG/connect_ok"
if run; then ok "a pinned adb port still exits 0"; else
  bad "a pinned adb port still exits 0" "$(cat "$LOG/out")"
fi
grep -q 'network transport.*192.168.77.232:5555' "$LOG/out" \
  && ok "reports the pinned port" || bad "reports the pinned port" "$(cat "$LOG/out")"
grep -q '192.168.77.232:5555' "$LOG/connected" && ok "connects to the pinned port" \
  || bad "connects to the pinned port" "$(cat "$LOG/connected")"

# 20. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

# The release check: the answer is cached for a day, per repository, so the
# case starts without one, and a queued GitHub answer stands in for the
# network.
release_cache=$XDG_CACHE_HOME/phone-link/latest-release-MBanucu-phone-link-proxy
rm -f "$release_cache"
printf '{"tag_name": "v9.9.9"}' >"$LOG/release_json"
fresh_state
run --analyze
grep -q '^warn *app_release' "$LOG/out" && ok "names a newer release" \
  || bad "names a newer release" "$(cat "$LOG/out")"
grep -q 'run phone-proxy-install --release' "$LOG/out" && ok "says how to get it" \
  || bad "says how to get it" "$(cat "$LOG/out")"
rm -f "$release_cache" "$LOG/release_json"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
