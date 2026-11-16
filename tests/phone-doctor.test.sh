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
    if [ -f "$LOG/connect_ok" ]; then
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
cat "$LOG/tunnel"
[ "$(cat "$LOG/tunnel")" = active ]
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/systemctl"

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--socks5-hostname*) printf '%s' "$(cat "$LOG/proxy_code")" ;;
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
export PHONE_APK_CACHE=$TMP/cache
export PHONE_PROXY_MANIFEST=$TMP/manifest.xml PHONE_PROXY_APK=$TMP/app.apk
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
  printf '1\n' >"$LOG/forward"
  printf 'active\n' >"$LOG/tunnel"
  printf '2022: from all fwmark 0x7e6 lookup 2022\n' >"$LOG/rules"
  printf '200' >"$LOG/proxy_code"
  printf '200' >"$LOG/internet_code"
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >"$LOG/resolv.conf"
  printf '    versionCode=1 minSdk=26 targetSdk=34\n    versionName=0.1.0\n    ACCESS_BACKGROUND_LOCATION: granted=true\n' >"$LOG/dumpsys"
  printf '      auto-start  true\n' >"$LOG/service_dump"
  printf 'user,org.phonelink.proxy,10332\n' >"$LOG/whitelist"
  printf '35\n' >"$LOG/sdk"
  # The version the tree would build, and the APK a reinstall would use: both
  # are files here so the test says what a checkout says and nothing else.
  printf '    android:versionCode="1"\n    android:versionName="0.1.0">\n' >"$TMP/manifest.xml"
  : >"$TMP/app.apk"
  : >"$LOG/avahi"
  : >"$LOG/connected"
  : >"$LOG/connect_ok"
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
grep -q 'network transport' "$LOG/out" && ok "reports adb over Wi-Fi" || bad "reports adb over Wi-Fi"

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

# 4. Forwarding off is a required failure.
fresh_state
printf '0\n' >"$LOG/forward"
if run; then bad "forwarding off exits 1"; else ok "forwarding off exits 1"; fi
grep -q 'FAIL  ip_forward' "$LOG/out" && ok "fails ip_forward" || bad "fails ip_forward"

# 5. Hotspot mode: no AP interface, missing AP profile only warns.
fresh_state
: >"$LOG/ap_addr"
: >"$LOG/nmcli_cons"
printf '2: wlan0    inet 10.244.108.165/24 brd 10.244.108.255 scope global wlan0\n' >"$LOG/ips"
if run; then ok "hotspot mode exits 0"; else bad "hotspot mode exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  ap profile' "$LOG/out" && ok "warns about the AP profile" || bad "warns about the AP profile"
grep -q 'warn  ap address' "$LOG/out" && ok "warns about the AP address" || bad "warns about the AP address"
grep -q 'proxy request.*10.244.108.165:1080 -> 200' "$LOG/out" && ok "checks the hotspot address" \
  || bad "checks the hotspot address" "$(cat "$LOG/out")"

# 6. A dead proxy is a required failure.
fresh_state
printf '000' >"$LOG/proxy_code"
if run; then bad "dead proxy exits 1"; else ok "dead proxy exits 1"; fi
grep -q 'FAIL  proxy request.*-> 000' "$LOG/out" && ok "fails the proxy request" \
  || bad "fails the proxy request" "$(cat "$LOG/out")"

# 7. Missing secrets: no proxy check, required failures.
fresh_state
if PHONE_SECRETS=$TMP/missing run; then bad "missing secrets exits 1"; else ok "missing secrets exits 1"; fi
grep -q 'FAIL  secrets' "$LOG/out" && ok "fails the secrets condition" || bad "fails the secrets condition"
grep -q 'FAIL  proxy request.*PHONE_SOCKS_PASS' "$LOG/out" && ok "explains the missing password" \
  || bad "explains the missing password" "$(cat "$LOG/out")"

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

# 12. The installed proxy version is compared with this checkout's manifest.
fresh_state
if run; then ok "the tree's build exits 0"; else bad "the tree's build exits 0"; fi
grep -q "ok    proxy version.*0.1.0 (1), this checkout's build" "$LOG/out" \
  && ok "accepts the build this checkout makes" || bad "accepts the build this checkout makes" \
  "$(cat "$LOG/out")"
fresh_state
printf '    versionCode=24 minSdk=26 targetSdk=34\n    versionName=1.7.4\n    ACCESS_BACKGROUND_LOCATION: granted=true\n' >"$LOG/dumpsys"
if run; then ok "an older app still exits 0"; else bad "an older app still exits 0"; fi
grep -q "warn  proxy version.*1.7.4 (24) is not this checkout's 0.1.0 (1); run phone-proxy-install" \
  "$LOG/out" && ok "says which build the tree makes" || bad "says which build the tree makes" \
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
unset PHONE_NIXOS_DIR PHONE_FLAKE_SRC

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

# 19. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
