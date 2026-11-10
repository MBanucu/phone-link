#!/usr/bin/env bash
# Hermetic tests for bin/phone-wifi-concurrency: stub adb serving recorded
# dumpsys wifi/status/ip output. No phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-wifi-concurrency
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
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  devices) cat "$LOG/devices" ;;
  shell)
    args=("${args[@]:1}")
    case "${args[0]:-}" in
      getprop)
        case "${args[1]:-}" in
          ro.product.model) printf '%s\n' "$(cat "$LOG/model")" ;;
          ro.build.version.release) printf '%s\n' "$(cat "$LOG/release")" ;;
          ro.build.version.sdk) printf '%s\n' "$(cat "$LOG/sdk")" ;;
        esac
        ;;
      dumpsys) cat "$LOG/wifi" ;;
      cmd)
        [ "${args[1]:-}" = wifi ] && cat "$LOG/status"
        ;;
      ip) cat "$LOG/ip" ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
export PATH="$STUBS:$PATH"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

set_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf 'XPLORE 2\n' >"$LOG/model"
  printf '15\n' >"$LOG/release"
  printf '35\n' >"$LOG/sdk"
  cat >"$LOG/wifi" <<'XML'
SupportedFeatures: [WIFI_FEATURE_INFRA, WIFI_FEATURE_P2P, WIFI_FEATURE_MOBILE_HOTSPOT, WIFI_FEATURE_AP_STA, WIFI_FEATURE_DUAL_BAND_SIMULTANEOUS]
CMD_UPDATE_AP_CAPABILITY 1 0 num ClientModeManagers:1 num SoftApManagers:1 SupportedFeatures=255
STA + STA Concurrency Supported: true
STA + AP Concurrency Supported: true
XML
  cat >"$LOG/status" <<'STATUS'
Wifi is enabled
Wifi is connected to "HomeNet", frequency: 5180
STATUS
  cat >"$LOG/ip" <<'IP'
15: wlan0    inet 192.168.1.50/24 brd 192.168.1.255 scope global wlan0
48: ap0    inet 10.244.108.165/24 brd 10.244.108.255 scope global ap0
IP
}

# 1. Supported: framework flag, driver feature and both managers.
set_state
if run; then
  ok "supported phone exits 0"
else
  bad "supported phone exits 0" "$(cat "$LOG/out")"
fi
grep -q 'framework: STA + AP concurrency = true' "$LOG/out" && ok "reports the framework flag" \
  || bad "reports the framework flag" "$(cat "$LOG/out")"
grep -q 'AP_STA feature = true' "$LOG/out" && ok "reports the driver feature" \
  || bad "reports the driver feature" "$(cat "$LOG/out")"
grep -q 'connected to "HomeNet"' "$LOG/out" && ok "reports the connected SSID" \
  || bad "reports the connected SSID" "$(cat "$LOG/out")"
grep -q 'hotspot active on ap0 (10.244.108.165)' "$LOG/out" && ok "reports the hotspot address" \
  || bad "reports the hotspot address" "$(cat "$LOG/out")"
grep -q 'managers client=1 softap=1' "$LOG/out" && ok "reports both managers" \
  || bad "reports both managers" "$(cat "$LOG/out")"
grep -q 'verdict:   Wi-Fi client and hotspot can run at the same time' "$LOG/out" \
  && ok "verdict says supported" || bad "verdict says supported" "$(cat "$LOG/out")"

# 2. Not supported: flag false, no AP_STA, hotspot off.
set_state
sed -i 's/STA + AP Concurrency Supported: true/STA + AP Concurrency Supported: false/' "$LOG/wifi"
sed -i 's/, WIFI_FEATURE_AP_STA//; s/, WIFI_FEATURE_DUAL_BAND_SIMULTANEOUS//' "$LOG/wifi"
sed -i 's/num SoftApManagers:1/num SoftApManagers:0/' "$LOG/wifi"
sed -i '/ap0/d' "$LOG/ip"
if run; then
  bad "unsupported phone exits 1"
else
  ok "unsupported phone exits 1"
fi
grep -q 'verdict:   Wi-Fi client and hotspot cannot run at the same time' "$LOG/out" \
  && ok "verdict says unsupported" || bad "verdict says unsupported" "$(cat "$LOG/out")"
grep -q 'hotspot not active' "$LOG/out" && ok "reports the hotspot as inactive" \
  || bad "reports the hotspot as inactive" "$(cat "$LOG/out")"

# 3. Inconclusive: no framework line but the driver advertises AP_STA.
set_state
sed -i '/STA + AP Concurrency Supported/d' "$LOG/wifi"
sed -i 's/num ClientModeManagers:1 num SoftApManagers:1/num ClientModeManagers:1 num SoftApManagers:0/' "$LOG/wifi"
if run; then
  bad "inconclusive phone exits 2"
else
  code=$?
  [ "$code" -eq 2 ] && ok "inconclusive phone exits 2" || bad "inconclusive phone exits 2" "exit $code"
fi
grep -q 'driver advertises STA+AP' "$LOG/out" && ok "explains the inconclusive verdict" \
  || bad "explains the inconclusive verdict" "$(cat "$LOG/out")"

# 4. Observed concurrency without a framework line: both managers up.
set_state
sed -i '/STA + AP Concurrency Supported/d' "$LOG/wifi"
if run; then
  ok "observed managers exit 0"
else
  bad "observed managers exit 0" "$(cat "$LOG/out")"
fi
grep -q 'both managers are up' "$LOG/out" && ok "explains observed concurrency" \
  || bad "explains observed concurrency" "$(cat "$LOG/out")"

# 5. Disconnected client still reports the capability.
set_state
printf 'Wifi is enabled\nWifi is not connected\n' >"$LOG/status"
if run; then
  ok "disconnected phone still exits 0"
else
  bad "disconnected phone still exits 0" "$(cat "$LOG/out")"
fi
grep -q 'enabled, not connected' "$LOG/out" && ok "reports not connected" \
  || bad "reports not connected" "$(cat "$LOG/out")"

# 6. No phone attached.
printf 'List of devices attached\n' >"$LOG/devices"
if run; then
  bad "no phone exits 1"
else
  ok "no phone exits 1"
fi
grep -q 'no phone attached' "$LOG/out" && ok "no phone message" \
  || bad "no phone message" "$(cat "$LOG/out")"

# 7. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
