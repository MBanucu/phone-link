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
unset PHONE_SERIAL
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
  : >"$LOG/calls"
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

# 3. Two attached devices without PHONE_SERIAL fail and list both.
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
    ok "two transports are an error that lists both" ;;
  *) bad "two transports are an error that lists both" "$out" ;;
esac

# 4. No attached device resolves to nothing (not to a built-in serial).
fresh
out=$(py 'from phone_link import adb
print(adb.resolve_serial() or "none")')
[ "$out" = "none" ] && ok "no attached device resolves to none" \
  || bad "no attached device resolves to none" "$out"

# 5. A bare adb command is pinned to the resolved serial.
fresh
printf 'List of devices attached\nUSB123\tdevice\n' >"$LOG/devices"
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "shell", "getprop", "ro.product.model"])))')
[ "$out" = "adb -s USB123 shell getprop ro.product.model" ] \
  && ok "a bare adb shell is pinned" || bad "a bare adb shell is pinned" "$out"

# 6. A bare adb tcpip (the --prepare path) is pinned too.
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "tcpip", "5555"])))')
[ "$out" = "adb -s USB123 tcpip 5555" ] \
  && ok "a bare adb tcpip is pinned" || bad "a bare adb tcpip is pinned" "$out"

# 7. An explicit serial is left exactly as given.
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "-s", "OTHER", "shell", "true"])))')
[ "$out" = "adb -s OTHER shell true" ] \
  && ok "an explicit serial is unchanged" || bad "an explicit serial is unchanged" "$out"

# 8. Server commands are not given a device serial.
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "devices"])))')
[ "$out" = "adb devices" ] && ok "adb devices stays a server command" \
  || bad "adb devices stays a server command" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
