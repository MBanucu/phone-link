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
      "settings get global network_avoid_bad_wifi") cat "$LOG/avoid" ;;
      "settings get global wifi_always_requested") cat "$LOG/always" ;;
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
  "dev wlp110s0 info") cat "$LOG/iw_info" 2>/dev/null ;;
  "dev wlp110s0 link") cat "$LOG/iw_link" 2>/dev/null ;;
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
  "merge-base --is-ancestor "*) [ "$(cat "$LOG/ancestor")" = yes ] ;;
  "ls-remote "*)
    # A queued ref list stands in for the network; the older single-HEAD file
    # is enough for the path-input cases.
    if [ -s "$LOG/remote_refs" ]; then
      cat "$LOG/remote_refs"
    elif [ -n "$(cat "$LOG/remote_head")" ]; then
      printf '%s\tHEAD\n' "$(cat "$LOG/remote_head")"
    else
      exit 128
    fi
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
# The module's /etc/phone-link/env; absent means "no module", and the tests
# that need a value write it here instead of relying on the host's file.
export PHONE_CONFIG_FILE=$TMP/phone-link-env
export PHONE_NIXOS_DIR=$TMP/nixos PHONE_FLAKE_SRC=$TMP/no-src
printf 'PHONE_SOCKS_PASS=pass\nPHONE_PIN=1234\nPHONE_AP_PASS=pass\n' >"$PHONE_SECRETS"
chmod 600 "$PHONE_SECRETS"

fresh_state() {
  # Two transports are normal on this host: name the one the destructive
  # commands should use, exactly as the operator must.
  export PHONE_SERIAL=XPLO2EEA0001541
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
  printf 'ssid PhoneLink\n' >"$LOG/iw_info"
  printf 'Connected to aa:bb:cc:dd:ee:ff (on wlp110s0)\n\tSSID: PhoneLink\n' >"$LOG/iw_link"
  printf '0\n' >"$LOG/avoid"
  printf '1\n' >"$LOG/always"
  printf '1\n' >"$LOG/forward"
  printf 'active\n' >"$LOG/tunnel"
  printf '2022: from all fwmark 0x7e6 lookup 2022\n' >"$LOG/rules"
  printf '200' >"$LOG/proxy_code"
  printf '200' >"$LOG/internet_code"
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >"$LOG/resolv.conf"
  printf '    versionCode=1 minSdk=26 targetSdk=34\n    versionName=0.1.0\n    flags=[ HAS_CODE ]\n    privateFlags=[ PARTIALLY_DIRECT_BOOT_AWARE ]\n    android.permission.ACCESS_FINE_LOCATION: granted=true\n    android.permission.ACCESS_COARSE_LOCATION: granted=true\n    android.permission.ACCESS_BACKGROUND_LOCATION: granted=true\n    android.permission.POST_NOTIFICATIONS: granted=true\n    android.permission.RECEIVE_BOOT_COMPLETED: granted=true\nReceiver Resolver Table:\n  Non-Data Actions:\n      android.intent.action.LOCKED_BOOT_COMPLETED:\n        38b0d9 org.phonelink.proxy/.BootReceiver filter edb9a9e\n' >"$LOG/dumpsys"
  printf '      running     port 1080 · 0 clients\n      auto-start  true\n' >"$LOG/service_dump"
  printf 'auto_start true\nadb_wifi true\nport 1080\nssid PhoneLink\nany_network false\nin_use \noem_autostart unreadable\n' \
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
  printf 'no\n' >"$LOG/ancestor"
  rm -f "$LOG/remote_refs"
  printf '200\n' >"$LOG/head_time"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Everything adb can check is in place. The DokeOS gate still cannot be
# read, so the verdict is "required conditions met, one open", not the whole
# setup ready — a battery-clear phone is not an OEM all-clear.
fresh_state
if run; then ok "ready setup exits 0"; else bad "ready setup exits 0" "$(cat "$LOG/out")"; fi
grep -q 'verdict: required conditions are met; 1 optional condition(s) open' "$LOG/out" \
  && ok "reports the one open OEM gate" \
  || bad "reports the one open OEM gate" "$(cat "$LOG/out")"
grep -q 'warn  OEM autostart.*unknown: the DokeOS list is unreadable' "$LOG/out" \
  && ok "says the OEM gate is unreadable" \
  || bad "says the OEM gate is unreadable" "$(cat "$LOG/out")"
grep -q '^FAIL' "$LOG/out" && bad "no failures" || ok "no failures"
grep -q 'ok    adb device' "$LOG/out" && ok "reports the adb device" || bad "reports the adb device"
grep -q 'proxy request.*192.168.77.232:1080 -> 200' "$LOG/out" && ok "reports the proxy request" \
  || bad "reports the proxy request" "$(cat "$LOG/out")"
grep -q 'ok    proxy port.*laptop 1080, phone 1080' "$LOG/out" \
  && ok "matches the laptop's port with the phone's" \
  || bad "matches the laptop's port with the phone's" "$(cat "$LOG/out")"
grep -q 'network transport' "$LOG/out" && ok "reports adb over Wi-Fi" || bad "reports adb over Wi-Fi"
grep -q 'ok    wifi reconnect.*network_avoid_bad_wifi=0, wifi_always_requested=1 (recommended)' "$LOG/out" \
  && ok "reports the Wi-Fi reconnect globals" || bad "reports the Wi-Fi reconnect globals" "$(cat "$LOG/out")"
grep -q 'ok    ap role.*local (this laptop owns the AP)' "$LOG/out" \
  && ok "reports the local AP role" || bad "reports the local AP role" "$(cat "$LOG/out")"
grep -q 'ok    ap dhcp' "$LOG/out" && ok "checks the AP DHCP unit" || bad "checks the AP DHCP unit"
grep -q 'ok    ap noforward' "$LOG/out" && ok "checks the AP no-forward unit" \
  || bad "checks the AP no-forward unit" "$(cat "$LOG/out")"
grep -q 'ok    ap forward drop' "$LOG/out" && ok "checks the nft forward drop" \
  || bad "checks the nft forward drop" "$(cat "$LOG/out")"
grep -q 'ok    ap station.*1 on wlp110s0' "$LOG/out" && ok "checks the phone association" \
  || bad "checks the phone association" "$(cat "$LOG/out")"
grep -q 'ok    secrets mode.*600' "$LOG/out" && ok "checks the secrets mode" \
  || bad "checks the secrets mode" "$(cat "$LOG/out")"

# 1b. Stock Wi-Fi reconnect globals are informational, not a failure.
fresh_state
printf '1\n' >"$LOG/avoid"
if run; then ok "stock Wi-Fi globals still exit 0"; else bad "stock Wi-Fi globals still exit 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  wifi reconnect.*network_avoid_bad_wifi=1, wifi_always_requested=1' "$LOG/out" \
  && ok "reports the stock value as a warning" \
  || bad "reports the stock value as a warning" "$(cat "$LOG/out")"
grep -q 'run phone-wifi-reconnect' "$LOG/out" && ok "names the explicit fix" \
  || bad "names the explicit fix" "$(cat "$LOG/out")"

# 2. No phone: required failure, phone checks skipped, rest still checked.
fresh_state
unset PHONE_SERIAL
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

# 10c2. The module's no-forward unit runs nft from the store, which is not on
#       PATH: PHONE_NFT from /etc/phone-link/env runs the same binary.
fresh_state
cat >"$TMP/module-nft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/module_nft"
case "$*" in
  "list table inet phone_link_ap") cat "$LOG/nft" ;;
  *) exit 1 ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$TMP/module-nft"
chmod +x "$TMP/module-nft"
printf "PHONE_NFT='%s'\n" "$TMP/module-nft" >"$PHONE_CONFIG_FILE"
mv "$STUBS/nft" "$TMP/nft.path"
if run; then ok "the module's nft path checks the forward drop"; else bad "the module's nft path checks the forward drop" "$(cat "$LOG/out")"; fi
grep -q 'ok    ap forward drop.*wlp110s0 dropped' "$LOG/out" \
  && ok "reports the drop from the module's nft" \
  || bad "reports the drop from the module's nft" "$(cat "$LOG/out")"
[ "$(cat "$LOG/module_nft" 2>/dev/null)" = "list table inet phone_link_ap" ] \
  && ok "ran the absolute nft path, not PATH" \
  || bad "ran the absolute nft path, not PATH" "$(cat "$LOG/module_nft" 2>/dev/null)"
# A query that fails through that binary is still a failure, not a skip.
rm -f "$LOG/nft"
if run; then bad "a failing module nft query exits 1"; else ok "a failing module nft query exits 1"; fi
grep -q 'FAIL  ap forward drop.*table inet phone_link_ap missing' "$LOG/out" \
  && ok "keeps a failing query a failure" || bad "keeps a failing query a failure" "$(cat "$LOG/out")"
mv "$TMP/nft.path" "$STUBS/nft"
rm -f "$PHONE_CONFIG_FILE"

# 10d. An AP on air with no associated station is a warning with the 3 s
#      recovery path, not a required failure.
fresh_state
: >"$LOG/iw_station"
if run; then ok "no station is a warning"; else bad "no station is a warning" "$(cat "$LOG/out")"; fi
grep -q 'warn  ap station.*no phone associated on wlp110s0; run phone-wifi-connect PhoneLink' "$LOG/out" \
  && ok "names the missing station and the recovery command" \
  || bad "names the missing station and the recovery command" "$(cat "$LOG/out")"
run --analyze || true
grep -q '^warn ap_station .*phone-wifi-connect PhoneLink' "$LOG/out" \
  && ok "--analyze reports ap_station as a warning with the command" \
  || bad "--analyze reports ap_station as a warning with the command" "$(cat "$LOG/out")"

# 10d2. The hint is only for an AP that is actually on air with the SSID.
fresh_state
: >"$LOG/iw_station"
: >"$LOG/iw_info"
if run; then bad "AP down with no station exits 1"; else ok "AP down with no station exits 1"; fi
grep -q 'FAIL  ap station.*no phone associated on wlp110s0' "$LOG/out" \
  && ok "keeps the plain failure when the SSID is not up" \
  || bad "keeps the plain failure when the SSID is not up" "$(cat "$LOG/out")"
grep -q 'phone-wifi-connect PhoneLink' "$LOG/out" \
  && bad "does not print the hint when the AP is down" \
  || ok "does not print the hint when the AP is down"

# 10d3. External role: no local profile or units are required, the laptop's
#       client link is reported, and the phone association is read over adb.
fresh_state
rm -f "$LOG/ap-profile"
: >"$LOG/nmcli_cons"
printf 'wlp110s0 UP 192.168.50.20/24\n' >"$LOG/ap_addr"
printf 'Connected to aa:bb:cc:dd:ee:ff (on wlp110s0)\n\tSSID: PhoneLink\n' >"$LOG/iw_link"
printf '2: wlan0    inet 192.168.50.20/24 brd 192.168.50.255 scope global wlan0\n' >"$LOG/ips"
if PHONE_AP_ROLE=external PHONE_PROXY_HOST=192.168.50.20 run; then
  ok "external role exits 0 without a local AP profile"
else
  bad "external role exits 0 without a local AP profile" "$(cat "$LOG/out")"
fi
grep -q 'ok    ap role.*external (another host owns the AP; the laptop is a client)' "$LOG/out" \
  && ok "reports the external role" || bad "reports the external role" "$(cat "$LOG/out")"
grep -q 'ok    external ap link.*client of PhoneLink on wlp110s0' "$LOG/out" \
  && ok "reports the laptop's external AP link" \
  || bad "reports the laptop's external AP link" "$(cat "$LOG/out")"
grep -q 'ok    ap station.*phone 192.168.50.20 on PhoneLink' "$LOG/out" \
  && ok "reports the phone on the external AP" \
  || bad "reports the phone on the external AP" "$(cat "$LOG/out")"
grep -q 'FAIL  ap address\|FAIL  ap profile\|phoneLink.ap is off' "$LOG/out" \
  && bad "does not require the local AP in external role" \
  || ok "does not require the local AP in external role"
grep -q 'proxy request.*192.168.50.20:1080 -> 200' "$LOG/out" \
  && ok "probes the reservation instead of the hotspot" \
  || bad "probes the reservation instead of the hotspot" "$(cat "$LOG/out")"

# 10d4. External role with the phone away is a warning with the recovery
#       command, not a dead-AP failure.
fresh_state
rm -f "$LOG/ap-profile"
: >"$LOG/nmcli_cons"
printf 'wlp110s0 UP 192.168.50.20/24\n' >"$LOG/ap_addr"
printf 'Connected to aa:bb:cc:dd:ee:ff (on wlp110s0)\n\tSSID: PhoneLink\n' >"$LOG/iw_link"
printf '3: rndis0    inet 10.9.9.9/24 brd 10.9.9.255 scope global rndis0\n' >"$LOG/ips"
if PHONE_AP_ROLE=external PHONE_PROXY_HOST=192.168.50.20 run; then
  bad "a missing external association is a required failure"
else
  ok "a missing external association is a required failure"
fi
grep -q 'warn  ap station.*phone 192.168.50.20 is not on PhoneLink.*phone-wifi-connect PhoneLink' "$LOG/out" \
  && ok "names the missing external association and the command" \
  || bad "names the missing external association and the command" "$(cat "$LOG/out")"
grep -q 'FAIL  phone address.*192.168.50.20 not on the phone' "$LOG/out" \
  && ok "the phone address check agrees the reservation is absent" \
  || bad "the phone address check agrees the reservation is absent" "$(cat "$LOG/out")"
grep -q 'FAIL  ap station\|AP down' "$LOG/out" \
  && bad "does not blame the external AP" \
  || ok "does not blame the external AP"

# 10d5. External role with no client link/address still reports the role and
#       warns; a missing interface is not "AP is down".
fresh_state
rm -f "$LOG/ap-profile"
: >"$LOG/nmcli_cons"
: >"$LOG/ap_addr"
printf 'Not connected.\n' >"$LOG/iw_link"
printf '2: wlan0    inet 192.168.50.20/24 brd 192.168.50.255 scope global wlan0\n' >"$LOG/ips"
if PHONE_AP_ROLE=external PHONE_PROXY_HOST=192.168.50.20 run; then
  ok "a missing external AP link is not a required failure"
else
  bad "a missing external AP link is not a required failure" "$(cat "$LOG/out")"
fi
grep -q 'ok    ap role.*external' "$LOG/out" \
  && ok "still reports the external role" || bad "still reports the external role" "$(cat "$LOG/out")"
grep -q 'warn  ap address.*no IPv4 (not joined to the external AP)' "$LOG/out" \
  && ok "warns about the missing client address" \
  || bad "warns about the missing client address" "$(cat "$LOG/out")"
grep -q 'warn  external ap link.*not a client of PhoneLink' "$LOG/out" \
  && ok "warns about the missing client link" \
  || bad "warns about the missing client link" "$(cat "$LOG/out")"
grep -q 'FAIL  ap address\|AP down' "$LOG/out" \
  && bad "does not call the external AP down" \
  || ok "does not call the external AP down"

# 10e. Missing tools are skips, not crashes: the checks run with no PATH.
marker=$LOG/ap-profile
printf 'phonelink\n' >"$marker"
if PYTHONPATH="$ROOT/lib/python" python3 - "$marker" "$LOG/no-env" >"$LOG/ap_skip" 2>&1 <<'PY'
import sys

from phone_doctor.checks import ap
from phone_doctor.context import Context

ctx = Context(
    {
        "PATH": "/nonexistent",
        "PHONE_AP_DECLARATIVE": sys.argv[1],
        "PHONE_CONFIG_FILE": sys.argv[2],
    }
)
results = ap.check(ctx)
assert len(results) == 6, results
assert results[0].cid == "ap_role" and results[0].status.value == "ok", results
assert all(r.status.value == "skip" for r in results[1:]), results
channel = next(r for r in results if r.cid == "ap_channel")
assert channel.detail == "iw not installed", channel
forward = next(r for r in results if r.cid == "ap_noforward_rules")
assert forward.detail == "nft not installed", forward
assert ctx.nft is None, ctx.nft
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

# 12c. The ok names every input a pre-unlock boot needs, not just three.
fresh_state
if run; then ok "the full boot set passes"; else bad "the full boot set passes" "$(cat "$LOG/out")"; fi
grep -q 'ok    restarts at boot.*auto_start on, allowlisted, fine+coarse location granted, background location granted, notifications granted, boot_completed granted, direct boot aware' "$LOG/out" \
  && ok "names the whole pre-unlock boot set" \
  || bad "names the whole pre-unlock boot set" "$(cat "$LOG/out")"

# 12c-2. Battery exempt and the vendor gate unknown are two different lines:
# the first may be ok while the second is never ok.
fresh_state
if run; then ok "a battery-clear phone exits 0"; else bad "a battery-clear phone exits 0" "$(cat "$LOG/out")"; fi
grep -q 'ok    restarts at boot.*allowlisted' "$LOG/out" \
  && ok "still reports the battery gate clear" \
  || bad "still reports the battery gate clear" "$(cat "$LOG/out")"
grep -q 'warn  OEM autostart.*unknown: the DokeOS list is unreadable.*separate gate' "$LOG/out" \
  && ok "does not turn the battery clear into an OEM clear" \
  || bad "does not turn the battery clear into an OEM clear" "$(cat "$LOG/out")"
grep -q '^ok *.*OEM autostart' "$LOG/out" \
  && bad "the OEM gate is never reported ok" || ok "the OEM gate is never reported ok"

# 12c-3. An app too old to write the fact is unknown, not clear.
fresh_state
printf 'auto_start true\nadb_wifi true\nport 1080\nssid PhoneLink\nany_network false\nin_use \n' \
  >"$LOG/app_state"
if run; then ok "an old app with no OEM fact exits 0"; else bad "an old app with no OEM fact exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  OEM autostart.*unknown: this app does not report the DokeOS gate' "$LOG/out" \
  && ok "a missing fact is unknown" \
  || bad "a missing fact is unknown" "$(cat "$LOG/out")"

# 12c-4. The app's dated observation is turned into the conservative wording,
# with the screen and both drivers, and never into a read of the vendor list.
fresh_state
printf 'auto_start true\nadb_wifi true\nport 1080\nssid PhoneLink\nany_network false\nin_use \noem_autostart unreadable\nlast_boot no_broadcast 1700000000\n' \
  >"$LOG/app_state"
if run; then ok "a likely-blocked boot still exits 0"; else bad "a likely-blocked boot still exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  OEM autostart.*likely blocked this boot (noticed 2023-11-14 22:13 UTC)' "$LOG/out" \
  && ok "dates the likely-blocked boot" \
  || bad "dates the likely-blocked boot" "$(cat "$LOG/out")"
grep -q 'System Manager → App Management → Auto Start Management' "$LOG/out" \
  && ok "names the DokeOS screen" \
  || bad "names the DokeOS screen" "$(cat "$LOG/out")"
grep -q 'wireless-adb-keeper/autostart-allow.sh' "$LOG/out" \
  && ok "names the adb driver" \
  || bad "names the adb driver" "$(cat "$LOG/out")"
grep -q 'phone-link-tools/autotoggle' "$LOG/out" \
  && ok "names the accessibility driver" \
  || bad "names the accessibility driver" "$(cat "$LOG/out")"
run --analyze || true
grep -q '^warn app_oem_autostart .*likely blocked' "$LOG/out" \
  && ok "--analyze names the OEM check" \
  || bad "--analyze names the OEM check" "$(cat "$LOG/out")"

# 12c-5. An old-style `last_boot blocked` line is the conclusion, not the
# observation: it is not served as proof, and the check stays unknown.
fresh_state
printf 'auto_start true\nadb_wifi true\nport 1080\nssid PhoneLink\nany_network false\nin_use \noem_autostart unreadable\nlast_boot blocked 1700000000\n' \
  >"$LOG/app_state"
if run; then ok "an old-style blocked line still exits 0"; else bad "an old-style blocked line still exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  OEM autostart.*unknown: the DokeOS list is unreadable' "$LOG/out" \
  && ok "an old blocked line is treated as unknown" \
  || bad "an old blocked line is treated as unknown" "$(cat "$LOG/out")"
grep -q 'likely blocked this boot' "$LOG/out" \
  && bad "an old blocked line is not proof" \
  || ok "an old blocked line is not proof"

# 12d. A declared-but-denied grant is named on its own and points at the fixer.
for entry in \
  'ACCESS_COARSE_LOCATION|coarse location is not granted' \
  'ACCESS_FINE_LOCATION|fine location is not granted' \
  'ACCESS_BACKGROUND_LOCATION|background location is not granted' \
  'POST_NOTIFICATIONS|notifications are not granted'
do
  permission=${entry%%|*}
  phrase=${entry#*|}
  fresh_state
  sed -i "s/android.permission.$permission: granted=true/android.permission.$permission: granted=false/" "$LOG/dumpsys"
  if run; then bad "$permission denied exits 1"; else ok "$permission denied exits 1"; fi
  grep -q "FAIL  restarts at boot.*$phrase" "$LOG/out" \
    && ok "names the denied $permission" \
    || bad "names the denied $permission" "$(cat "$LOG/out")"
  grep -q 'run phone-proxy-boot' "$LOG/out" \
    && ok "a denied $permission points at the fixer" \
    || bad "a denied $permission points at the fixer" "$(cat "$LOG/out")"
  grep -q 'reinstall the release' "$LOG/out" \
    && bad "a denied $permission is not called a manifest fact" \
    || ok "a denied $permission is not called a manifest fact"
done

# 12e. An undeclared permission is a manifest fact: only a reinstall fixes it.
fresh_state
sed -i '/android.permission.ACCESS_FINE_LOCATION: granted=true/d' "$LOG/dumpsys"
if run; then bad "an undeclared grant exits 1"; else ok "an undeclared grant exits 1"; fi
grep -q 'FAIL  restarts at boot.*the build does not declare fine location.*reinstall the release' "$LOG/out" \
  && ok "an undeclared grant asks for a reinstall" \
  || bad "an undeclared grant asks for a reinstall" "$(cat "$LOG/out")"

# 12f. The boot permission, the direct-boot flag and the locked-boot receiver
#      are each named, with the same reinstall hint.
fresh_state
sed -i '/android.permission.RECEIVE_BOOT_COMPLETED: granted=true/d' "$LOG/dumpsys"
if run; then bad "no boot permission exits 1"; else ok "no boot permission exits 1"; fi
grep -q 'FAIL  restarts at boot.*RECEIVE_BOOT_COMPLETED is not granted.*reinstall the release' "$LOG/out" \
  && ok "names the missing boot permission" \
  || bad "names the missing boot permission" "$(cat "$LOG/out")"

fresh_state
sed -i 's/ PARTIALLY_DIRECT_BOOT_AWARE//' "$LOG/dumpsys"
if run; then bad "no direct-boot flag exits 1"; else ok "no direct-boot flag exits 1"; fi
grep -q 'FAIL  restarts at boot.*this build is not direct-boot aware.*reinstall the release' "$LOG/out" \
  && ok "names the missing direct-boot flag" \
  || bad "names the missing direct-boot flag" "$(cat "$LOG/out")"

fresh_state
sed -i '/Receiver Resolver Table:/,$d' "$LOG/dumpsys"
if run; then bad "no locked-boot receiver exits 1"; else ok "no locked-boot receiver exits 1"; fi
grep -q 'FAIL  restarts at boot.*no receiver handles LOCKED_BOOT_COMPLETED.*reinstall the release' "$LOG/out" \
  && ok "names the missing locked-boot receiver" \
  || bad "names the missing locked-boot receiver" "$(cat "$LOG/out")"

# 12g. Notifications are only required when the app targets API 33+.
fresh_state
sed -i 's/targetSdk=34/targetSdk=32/' "$LOG/dumpsys"
sed -i '/android.permission.POST_NOTIFICATIONS: granted=true/d' "$LOG/dumpsys"
if run; then ok "targetSdk 32 needs no notification grant"; else bad "targetSdk 32 needs no notification grant" "$(cat "$LOG/out")"; fi
grep -q 'ok    restarts at boot.*notifications' "$LOG/out" \
  && bad "does not name notifications when not required" \
  || ok "does not name notifications when not required"


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
printf '    versionCode=24 minSdk=26 targetSdk=34\n    versionName=1.7.4\n    flags=[ HAS_CODE ]\n    privateFlags=[ PARTIALLY_DIRECT_BOOT_AWARE ]\n    android.permission.ACCESS_FINE_LOCATION: granted=true\n    android.permission.ACCESS_COARSE_LOCATION: granted=true\n    android.permission.ACCESS_BACKGROUND_LOCATION: granted=true\n    android.permission.POST_NOTIFICATIONS: granted=true\n    android.permission.RECEIVE_BOOT_COMPLETED: granted=true\nReceiver Resolver Table:\n  Non-Data Actions:\n      android.intent.action.LOCKED_BOOT_COMPLETED:\n        38b0d9 org.phonelink.proxy/.BootReceiver filter edb9a9e\n' >"$LOG/dumpsys"
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

# A GitHub input names the ref it tracks; the doctor compares the lock with
# that ref, not with whatever the local checkout happens to contain.
flake_lock() {
  local ref=$1 rev=$2 original
  if [ -n "$ref" ]; then
    original="\"original\": {\"owner\": \"MBanucu\", \"repo\": \"phone-link\", \"type\": \"github\", \"ref\": \"$ref\"},"
  else
    original="\"original\": {\"owner\": \"MBanucu\", \"repo\": \"phone-link\", \"type\": \"github\"},"
  fi
  printf '{ "nodes": { "phone-link": { %s "locked": {"lastModified": 100, "rev": "%s", "type": "github"} } } }\n' \
    "$original" "$rev" >"$TMP/nixos/flake.lock"
}

# 14b. A tag-pinned lock that matches the tag is up to date even though the
# checkout has newer commits on main: a docs-only merge after the tag changes
# nothing the lock resolves to.
fresh_state
mkdir -p "$TMP/src/.git" "$TMP/nixos"
export PHONE_FLAKE_SRC=$TMP/src PHONE_NIXOS_DIR=$TMP/nixos
printf '111111111111\n' >"$LOG/local_head"
printf '300\n' >"$LOG/head_time"
flake_lock v0.18.0 c1cc38100000
printf 'c1cc38100000\trefs/tags/v0.18.0\nc1cc38100000\trefs/tags/v0.18.0^{}\n' >"$LOG/remote_refs"
if run; then ok "a matching tag pin still exits 0"; else bad "a matching tag pin still exits 0"; fi
grep -q 'ok    flake update.*up to date (c1cc38100000)' "$LOG/out" \
  && ok "accepts a lock that matches its tag" \
  || bad "accepts a lock that matches its tag" "$(cat "$LOG/out")"
grep -q 'warn  flake update' "$LOG/out" \
  && bad "ignores a newer checkout HEAD" || ok "ignores a newer checkout HEAD"

# 14c. A tag that moved is a disagreement: re-resolving the same tag cannot
# refresh the lock, so the doctor says the tag should not move.
fresh_state
mkdir -p "$TMP/src/.git" "$TMP/nixos"
export PHONE_FLAKE_SRC=$TMP/src PHONE_NIXOS_DIR=$TMP/nixos
flake_lock v0.18.0 aaaaaaaaaaaa
printf 'bbbbbbbbbbbb\trefs/tags/v0.18.0\nbbbbbbbbbbbb\trefs/tags/v0.18.0^{}\n' >"$LOG/remote_refs"
if run; then ok "a moved tag still exits 0"; else bad "a moved tag still exits 0"; fi
grep -q 'warn  flake update.*the lock has aaaaaaaaaaaa, tag v0.18.0 is at bbbbbbbbbbbb' "$LOG/out" \
  && ok "warns when the lock and the tag disagree" \
  || bad "warns when the lock and the tag disagree" "$(cat "$LOG/out")"
grep -q 'a tag should not move' "$LOG/out" \
  && ok "says the tag should not move" || bad "says the tag should not move" "$(cat "$LOG/out")"

# 14d. A branch-tracking input follows a moving branch: a checkout behind
# origin keeps the actionable warning.
fresh_state
mkdir -p "$TMP/src/.git" "$TMP/nixos"
export PHONE_FLAKE_SRC=$TMP/src PHONE_NIXOS_DIR=$TMP/nixos
flake_lock main aaaaaaaaaaaa
printf 'aaaaaaaaaaaa\n' >"$LOG/local_head"
printf 'bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n' >"$LOG/remote_refs"
if run; then ok "a branch pin ahead of the lock still exits 0"; else bad "a branch pin ahead of the lock still exits 0"; fi
grep -q 'warn  flake update.*origin has newer commits (git pull, then rebuild)' "$LOG/out" \
  && ok "warns when the branch is ahead" \
  || bad "warns when the branch is ahead" "$(cat "$LOG/out")"

# 14e. A current checkout with a lock behind the branch is a stale system
# lock, refreshed by updating the input.
fresh_state
mkdir -p "$TMP/src/.git" "$TMP/nixos"
export PHONE_FLAKE_SRC=$TMP/src PHONE_NIXOS_DIR=$TMP/nixos
flake_lock main aaaaaaaaaaaa
printf 'bbbbbbbbbbbb\n' >"$LOG/local_head"
printf 'bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n' >"$LOG/remote_refs"
if run; then ok "a lock behind the branch still exits 0"; else bad "a lock behind the branch still exits 0"; fi
grep -q 'warn  flake update.*system lock is older than .* HEAD' "$LOG/out" \
  && ok "warns that the lock is behind the branch" \
  || bad "warns that the lock is behind the branch" "$(cat "$LOG/out")"

# 14f. A lock that matches the branch is up to date; a checkout behind origin
# is still reported.
fresh_state
mkdir -p "$TMP/src/.git" "$TMP/nixos"
export PHONE_FLAKE_SRC=$TMP/src PHONE_NIXOS_DIR=$TMP/nixos
flake_lock main bbbbbbbbbbbb
printf 'aaaaaaaaaaaa\n' >"$LOG/local_head"
printf 'bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n' >"$LOG/remote_refs"
if run; then ok "a lock matching the branch still exits 0"; else bad "a lock matching the branch still exits 0"; fi
grep -q 'warn  flake update.*origin has newer commits' "$LOG/out" \
  && ok "reports a checkout behind origin" \
  || bad "reports a checkout behind origin" "$(cat "$LOG/out")"

# 14g. A checkout ahead of origin keeps the branch lock valid: origin has no
# newer commit, only the checkout has commits the remote has not seen.
fresh_state
mkdir -p "$TMP/src/.git" "$TMP/nixos"
export PHONE_FLAKE_SRC=$TMP/src PHONE_NIXOS_DIR=$TMP/nixos
flake_lock main bbbbbbbbbbbb
printf 'cccccccccccc\n' >"$LOG/local_head"
printf 'yes\n' >"$LOG/ancestor"
printf 'bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n' >"$LOG/remote_refs"
if run; then ok "a checkout ahead of the branch still exits 0"; else bad "a checkout ahead of the branch still exits 0"; fi
grep -q 'ok    flake update.*up to date (bbbbbbbbbbbb)' "$LOG/out" \
  && ok "does not call an ahead checkout stale" \
  || bad "does not call an ahead checkout stale" "$(cat "$LOG/out")"
grep -q 'warn  flake update' "$LOG/out" \
  && bad "keeps a branch lock matching origin quiet" \
  || ok "keeps a branch lock matching origin quiet"

# 14h. An annotated tag prints its tag object first and the commit as the
# peeled ^{} line: the lock's rev is compared with the commit.
fresh_state
mkdir -p "$TMP/nixos"
export PHONE_FLAKE_SRC=$TMP/no-src PHONE_NIXOS_DIR=$TMP/nixos
flake_lock v0.19.0 bbbbbbbbbbbb
printf 'aaaaaaaaaaaa\trefs/tags/v0.19.0\nbbbbbbbbbbbb\trefs/tags/v0.19.0^{}\n' >"$LOG/remote_refs"
if run; then ok "a peeled tag still exits 0"; else bad "a peeled tag still exits 0"; fi
grep -q 'ok    flake update.*up to date (bbbbbbbbbbbb)' "$LOG/out" \
  && ok "prefers the peeled commit" || bad "prefers the peeled commit" "$(cat "$LOG/out")"

# 14i. Without a checkout the branch head on the remote is still what counts.
fresh_state
mkdir -p "$TMP/nixos"
export PHONE_FLAKE_SRC=$TMP/no-src PHONE_NIXOS_DIR=$TMP/nixos
flake_lock main aaaaaaaaaaaa
printf 'bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n' >"$LOG/remote_refs"
if run; then ok "an outdated remote lock still exits 0"; else bad "an outdated remote lock still exits 0"; fi
grep -q 'warn  flake update.*origin is at bbbbbbbbbbbb, the lock has aaaaaaaaaaaa' "$LOG/out" \
  && ok "warns when the lock is behind the remote" \
  || bad "warns when the lock is behind the remote" "$(cat "$LOG/out")"
flake_lock main bbbbbbbbbbbb
if run; then ok "a matching remote still exits 0"; else bad "a matching remote still exits 0"; fi
grep -q 'ok    flake update.*up to date (bbbbbbbbbbbb)' "$LOG/out" \
  && ok "accepts a matching remote" || bad "accepts a matching remote" "$(cat "$LOG/out")"
: >"$LOG/remote_refs"
: >"$LOG/remote_head"
if run; then ok "an unreachable remote still exits 0"; else bad "an unreachable remote still exits 0"; fi
grep -q 'skip  flake update.*unreachable' "$LOG/out" \
  && ok "skips an unreachable remote" || bad "skips an unreachable remote" "$(cat "$LOG/out")"
# Keep the fixture environment for the rest of the suite: with no lock file the
# flake check is a skip, so a live /etc/nixos (with whatever the host has
# repinned) can never turn a later ready-state case into a warning.
rm -f "$TMP/nixos/flake.lock"
export PHONE_NIXOS_DIR=$TMP/nixos PHONE_FLAKE_SRC=$TMP/no-src

# 15. --analyze prints only the problems, as stable ids. A ready setup still
# has the unreadable DokeOS gate as its one open fact.
fresh_state
if run --analyze; then ok "--analyze on a ready setup exits 0"; else bad "--analyze on a ready setup exits 0" "$(cat "$LOG/out")"; fi
grep -q '^warn app_oem_autostart ' "$LOG/out" \
  && ok "--analyze names the unreadable OEM gate" \
  || bad "--analyze names the unreadable OEM gate" "$(cat "$LOG/out")"
grep -q '^\(ok\|fail\|skip\) ' "$LOG/out" \
  && bad "--analyze has only the OEM warning" || ok "--analyze has only the OEM warning"
fresh_state
unset PHONE_SERIAL
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
