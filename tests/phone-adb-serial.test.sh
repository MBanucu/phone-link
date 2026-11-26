#!/usr/bin/env bash
# Hermetic tests for the one adb target serial: PHONE_SERIAL wins, one attached
# device is used, two are an error naming both, and a command without -s gets
# the resolved serial inserted. Stub adb, no phone, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
# Never consult a real phone or avahi in the sandbox.
export PHONE_ADB_MDNS=0
unset PHONE_SERIAL PHONE_PROXY_HOST PHONE_AP_IP
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
printf '%s\n' "$*" >>"$LOG/calls"
case "${1:-}" in
  devices) cat "$LOG/devices" ;;
  -s)
    # `adb -s SERIAL shell getprop ro.serialno`, answered from a map file so a
    # test can give the same phone one identity on both transports.
    if [ "${3:-}" = "shell" ] && [ "${4:-}" = "getprop" ] \
      && [ "${5:-}" = "ro.serialno" ]; then
      [ -f "$LOG/serialno" ] \
        && awk -v serial="$2" -F'\t' '$1 == serial { print $2 }' "$LOG/serialno"
    fi
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
export PATH="$STUBS:$PATH"

py() {
  PYTHONPATH="$ROOT/lib/python" python3 -c "$1"
}

fresh() {
  printf 'List of devices attached\n' >"$LOG/devices"
  rm -f "$LOG/serialno"
  : >"$LOG/calls"
}

listed() {
  printf 'List of devices attached\n%s\n' "$1" >"$LOG/devices"
}

same_phone() {
  listed 'USB123 device usb:4-2 product:XPLORE2_EEA model:XPLORE_2 device:XPLORE2 transport_id:53
192.0.2.10:5555 device product:XPLORE2_EEA model:XPLORE_2 device:XPLORE2 transport_id:55'
}

two() {
  printf 'List of devices attached\nUSB123\tdevice\n192.0.2.10:5555\tdevice\n' \
    >"$LOG/devices"
}

# 1. PHONE_SERIAL wins even when two transports are attached.
fresh
two
out=$(PHONE_SERIAL=192.0.2.10:5555 py 'from phone_link import adb
print(adb.resolve_serial() or "none")')
[ "$out" = "192.0.2.10:5555" ] && ok "PHONE_SERIAL wins over two transports" \
  || bad "PHONE_SERIAL wins over two transports" "$out"

# 2. One attached device is chosen without any environment.
fresh
printf 'List of devices attached\nUSB123\tdevice\n' >"$LOG/devices"
out=$(py 'from phone_link import adb
print(adb.resolve_serial() or "none")')
[ "$out" = "USB123" ] && ok "the only attached device is used" \
  || bad "the only attached device is used" "$out"

# 3. Two transports with no identity at all are still an error that lists both:
#    merging unknown devices would be the old "wrong phone" guess.
fresh
two
out=$(py 'from phone_link import adb
try:
    adb.resolve_serial()
except adb.SerialError as exc:
    print(exc)
else:
    print("no error")')
case "$out" in
  *"more than one adb device"*USB123*192.0.2.10:5555*"PHONE_SERIAL"*)
    ok "two unidentified transports are an error that lists both" ;;
  *) bad "two unidentified transports are an error that lists both" "$out" ;;
esac

# 4. USB and Wi-Fi are the same phone: one ro.serialno groups them and the
#    USB transport wins because it survives a reboot.
fresh
same_phone
printf 'USB123\tHW123\n192.0.2.10:5555\tHW123\n' >"$LOG/serialno"
out=$(py 'from phone_link import adb
print(adb.resolve_serial() or "none")')
[ "$out" = "USB123" ] \
  && ok "USB and network transports of one phone resolve to the USB serial" \
  || bad "USB and network transports of one phone resolve to the USB serial" "$out"

# 5. Two network transports of the same phone: the configured host wins.
fresh
listed '192.0.2.10:5555 device product:XPLORE2_EEA model:XPLORE_2 device:XPLORE2 transport_id:53
198.51.100.20:5555 device product:XPLORE2_EEA model:XPLORE_2 device:XPLORE2 transport_id:55'
printf '192.0.2.10:5555\tHW123\n198.51.100.20:5555\tHW123\n' >"$LOG/serialno"
out=$(PHONE_PROXY_HOST=198.51.100.20 py 'from phone_link import adb
print(adb.resolve_serial() or "none")')
[ "$out" = "198.51.100.20:5555" ] \
  && ok "the configured host wins between network transports" \
  || bad "the configured host wins between network transports" "$out"

# 6. Two genuinely different phones still stop and list both transports,
#    even when their model/device/product descriptors are identical.
fresh
same_phone
printf 'USB123\tHW123\n192.0.2.10:5555\tHW456\n' >"$LOG/serialno"
out=$(py 'from phone_link import adb
try:
    adb.resolve_serial()
except adb.SerialError as exc:
    print(exc)
else:
    print("no error")')
case "$out" in
  *"more than one adb device"*USB123*192.0.2.10:5555*"PHONE_SERIAL"*)
    ok "two different phones are an error that lists both" ;;
  *) bad "two different phones are an error that lists both" "$out" ;;
esac

# 7. An empty ro.serialno falls back to the adb devices -l descriptor, which
#    still groups the two transports of one phone.
fresh
same_phone
out=$(py 'from phone_link import adb
print(adb.resolve_serial() or "none")')
[ "$out" = "USB123" ] \
  && ok "the descriptor fallback groups transports when ro.serialno is empty" \
  || bad "the descriptor fallback groups transports when ro.serialno is empty" "$out"

# 8. network_only still means the network transport of that one phone.
fresh
same_phone
printf 'USB123\tHW123\n192.0.2.10:5555\tHW123\n' >"$LOG/serialno"
out=$(py 'from phone_link import adb
print(adb.resolve_serial(network_only=True) or "none")')
[ "$out" = "192.0.2.10:5555" ] \
  && ok "network_only keeps the network transport of the same phone" \
  || bad "network_only keeps the network transport of the same phone" "$out"

# 9. No attached device resolves to nothing (not to a built-in serial).
fresh
out=$(py 'from phone_link import adb
print(adb.resolve_serial() or "none")')
[ "$out" = "none" ] && ok "no attached device resolves to none" \
  || bad "no attached device resolves to none" "$out"

# 10. A bare adb command is pinned to the resolved serial.
fresh
printf 'List of devices attached\nUSB123\tdevice\n' >"$LOG/devices"
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "shell", "getprop", "ro.product.model"])))')
[ "$out" = "adb -s USB123 shell getprop ro.product.model" ] \
  && ok "a bare adb shell is pinned" || bad "a bare adb shell is pinned" "$out"

# 11. A bare adb tcpip (the --prepare path) is pinned too.
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "tcpip", "5555"])))')
[ "$out" = "adb -s USB123 tcpip 5555" ] \
  && ok "a bare adb tcpip is pinned" || bad "a bare adb tcpip is pinned" "$out"

# 12. An explicit serial is left exactly as given.
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "-s", "OTHER", "shell", "true"])))')
[ "$out" = "adb -s OTHER shell true" ] \
  && ok "an explicit serial is unchanged" || bad "an explicit serial is unchanged" "$out"

# 13. Server commands are not given a device serial.
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "devices"])))')
[ "$out" = "adb devices" ] && ok "adb devices stays a server command" \
  || bad "adb devices stays a server command" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
