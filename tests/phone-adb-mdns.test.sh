#!/usr/bin/env bash
# Hermetic tests for lib/python/phone_link/adb.py: a phone whose adbd was pinned
# to a fixed port is asked there first, and the wireless-debugging port is
# otherwise rediscovered from the phone's mDNS record when the serial in use
# went away. Stub adb and avahi-browse, no phone, no network.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib/harness.sh"
suite


stub adb
answer adb <<'EOF'
printf '%s\n' "$*" >>"$LOG/calls"
args=("$@")
serial=""
if [ "${args[0]:-}" = "-s" ]; then serial=${args[1]}; args=("${args[@]:2}"); fi
attached() {
  awk -v s="$serial" '$1 == s && $2 == "device" {found=1} END {exit !found}' \
    "$LOG/devices"
}
case "${args[0]:-}" in
  devices) cat "$LOG/devices" ;;
  connect)
    printf '%s\n' "${args[1]:-}" >>"$LOG/connect.log"
    # $LOG/deny lists addresses adbd does not answer on: a phone that never
    # pinned its adbd, so the mDNS fallback is what the test is about.
    denied=0
    if [ -f "$LOG/deny" ] && grep -qx "${args[1]:-}" "$LOG/deny"; then
      denied=1
    fi
    if [ "$denied" = 0 ] && [ -f "$LOG/connect_ok" ]; then
      printf '%s\tdevice\n' "${args[1]:-}" >>"$LOG/devices"
    fi
    ;;
  shell)
    printf '%s|%s\n' "$serial" "${args[*]:1}" >>"$LOG/shell.log"
    # $LOG/drop names the serial whose transport disappears mid-run: the phone
    # rebooted between the resolution and the command.
    if [ -f "$LOG/drop" ] && [ "$(cat "$LOG/drop")" = "$serial" ]; then
      awk -v s="$serial" '$1 != s' "$LOG/devices" >"$LOG/devices.new"
      mv "$LOG/devices.new" "$LOG/devices"
      printf "error: device '%s' not found\n" "$serial" >&2
      exit 1
    fi
    if attached; then
      printf 'ok %s\n' "$serial"
    else
      printf "error: device '%s' not found\n" "$serial" >&2
      exit 1
    fi
    ;;
esac
EOF

stub avahi-browse
answer avahi-browse <<'EOF'
printf '%s\n' "$*" >>"$LOG/avahi_calls"
cat "$LOG/avahi"
EOF

# The suites run offline in the sandbox; a checkout machine may have a real
# phone on the network and a real avahi, which must not be consulted here.
export PHONE_ADB_MDNS=1

py() {
  PYTHONPATH="$ROOT/lib/python" python3 -c "$1"
}

fresh() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  : >"$LOG/avahi"
  : >"$LOG/avahi_calls"
  : >"$LOG/calls"
  : >"$LOG/connect.log"
  : >"$LOG/shell.log"
  rm -f "$LOG/connect_ok" "$LOG/drop" "$LOG/deny"
}

# A phone that does not pin adbd: the fixed port answers nothing.
unpinned() {
  printf '192.168.77.232:5555\n10.244.108.165:5555\n' >"$LOG/deny"
}

advertise() { # advertise HOST PORT...
  : >"$LOG/avahi"
  while [ "$#" -ge 2 ]; do
    printf '=;wlp110s0;IPv4;adb-XPLO2EEA0001541-D1gkYk;_adb-tls-connect._tcp;local;Android.local;%s;%s;"v=ADB_SECURE_SERVICE_VERSION"\n' \
      "$1" "$2" >>"$LOG/avahi"
    shift 2
  done
}

# 1. A stale network serial is retargeted at the advertised port.
fresh
unpinned
advertise 192.168.77.232 44895
: >"$LOG/connect_ok"
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "-s", "192.168.77.232:1111", "shell", "pm", "path", "x"])))')
[ "$out" = "adb -s 192.168.77.232:44895 shell pm path x" ] \
  && ok "a rotated port is rewritten" || bad "a rotated port is rewritten" "$out"
grep -qx '192.168.77.232:44895' "$LOG/connect.log" \
  && ok "connects before retargeting" || bad "connects before retargeting" \
  "$(cat "$LOG/connect.log" 2>/dev/null)"

# 2. A serial that is still attached is left alone, without a lookup.
fresh
printf 'List of devices attached\n192.168.77.232:44895\tdevice\n' >"$LOG/devices"
advertise 192.168.77.232 5555
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "-s", "192.168.77.232:44895", "shell", "true"])))')
[ "$out" = "adb -s 192.168.77.232:44895 shell true" ] \
  && ok "an attached serial is kept" || bad "an attached serial is kept" "$out"
[ ! -s "$LOG/avahi_calls" ] && ok "no lookup when attached" \
  || bad "no lookup when attached" "$(cat "$LOG/avahi_calls")"

# 3. A USB serial cannot rotate: no adb call, no lookup.
fresh
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "-s", "XPLO2EEA0001541", "shell", "true"])))')
[ "$out" = "adb -s XPLO2EEA0001541 shell true" ] \
  && ok "a USB serial is kept" || bad "a USB serial is kept" "$out"
[ ! -s "$LOG/calls" ] && [ ! -s "$LOG/avahi_calls" ] \
  && ok "a USB serial costs nothing" || bad "a USB serial costs nothing" \
  "$(cat "$LOG/calls")"

# 4. No advertised record leaves the command as it was, after the pinned port
#    has been asked and found closed.
fresh
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "-s", "192.168.77.232:1111", "shell", "true"])))')
[ "$out" = "adb -s 192.168.77.232:1111 shell true" ] \
  && ok "an unadvertised port is not guessed" || bad "an unadvertised port is not guessed" "$out"
grep -qx '192.168.77.232:5555' "$LOG/connect.log" \
  && ok "the pinned port is tried first" \
  || bad "the pinned port is tried first" "$(cat "$LOG/connect.log")"

# 5. A command that fails on a transport that vanished is run again on the new
#    one, through the shell vocabulary every command uses.
fresh
unpinned
printf 'List of devices attached\n192.168.77.232:1111\tdevice\n' >"$LOG/devices"
printf '192.168.77.232:1111' >"$LOG/drop"
advertise 192.168.77.232 44895
: >"$LOG/connect_ok"
out=$(py 'from phone_link.shell import capture
print(capture(["adb", "-s", "192.168.77.232:1111", "shell", "getprop", "sys.boot_completed"]))')
[ "$out" = "ok 192.168.77.232:44895" ] \
  && ok "a failed command is retried on the new port" \
  || bad "a failed command is retried on the new port" "$out"
grep -q '^192.168.77.232:44895|' "$LOG/shell.log" \
  && ok "the retry used the new serial" || bad "the retry used the new serial" \
  "$(cat "$LOG/shell.log")"

# 6. With nothing attached, the serial is resolved from the record.
fresh
unpinned
printf 'List of devices attached\n' >"$LOG/devices"
advertise 192.168.77.232 44895
: >"$LOG/connect_ok"
out=$(py 'from phone_link import phone
print(phone.phone_serial() or "none")')
[ "$out" = "192.168.77.232:44895" ] \
  && ok "an empty adb devices is recovered" || bad "an empty adb devices is recovered" "$out"

# 7. The doctor resolves its serial the same way.
fresh
unpinned
printf 'List of devices attached\n' >"$LOG/devices"
advertise 192.168.77.232 44895
: >"$LOG/connect_ok"
out=$(py 'from phone_doctor.context import Context
print(Context().serial or "none")')
[ "$out" = "192.168.77.232:44895" ] \
  && ok "the doctor recovers the serial" || bad "the doctor recovers the serial" "$out"

# 8. Two phones advertised: the one on the wanted address wins.
fresh
unpinned
printf 'List of devices attached\n' >"$LOG/devices"
advertise 192.168.77.99 5555 192.168.77.232 44895
: >"$LOG/connect_ok"
out=$(py 'from phone_link import adb
print(adb.discover("192.168.77.232:1111") or "none")')
[ "$out" = "192.168.77.232:44895" ] \
  && ok "the hinted address is preferred" || bad "the hinted address is preferred" "$out"

# 9. An advertised port adb refuses is not used.
fresh
printf 'List of devices attached\n' >"$LOG/devices"
advertise 192.168.77.232 44895
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "-s", "192.168.77.232:1111", "shell", "true"])))')
[ "$out" = "adb -s 192.168.77.232:1111 shell true" ] \
  && ok "a refused connect keeps the serial" || bad "a refused connect keeps the serial" "$out"

# 10. PHONE_ADB_MDNS=0 turns the lookup off.
fresh
printf 'List of devices attached\n' >"$LOG/devices"
advertise 192.168.77.232 44895
: >"$LOG/connect_ok"
out=$(PHONE_ADB_MDNS=0 py 'from phone_link import phone
print(phone.phone_serial() or "none")')
[ "$out" = "none" ] && ok "the lookup can be switched off" \
  || bad "the lookup can be switched off" "$out"
[ ! -s "$LOG/avahi_calls" ] && [ ! -s "$LOG/connect.log" ] \
  && ok "nothing is looked up when off" || bad "nothing is looked up when off"

# 11. Commands that address the adb server itself are never rewritten.
fresh
advertise 192.168.77.232 44895
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "connect", "192.168.77.232:1111"])))
print(" ".join(adb.prepare(["adb", "devices"])))')
[ "$out" = "adb connect 192.168.77.232:1111
adb devices" ] && ok "server commands are left alone" \
  || bad "server commands are left alone" "$out"
[ ! -s "$LOG/calls" ] && ok "server commands run no extra adb" \
  || bad "server commands run no extra adb" "$(cat "$LOG/calls")"

# 12. A phone that pinned adbd is used on that port, and mDNS is not browsed.
fresh
advertise 192.168.77.232 44895
: >"$LOG/connect_ok"
out=$(py 'from phone_link import adb
print(" ".join(adb.prepare(["adb", "-s", "192.168.77.232:1111", "shell", "true"])))')
[ "$out" = "adb -s 192.168.77.232:5555 shell true" ] \
  && ok "the pinned port wins over mDNS" || bad "the pinned port wins over mDNS" "$out"
[ ! -s "$LOG/avahi_calls" ] && ok "a pinned phone costs no browse" \
  || bad "a pinned phone costs no browse" "$(cat "$LOG/avahi_calls")"

# 13. Nothing attached: the pinned port is found without any record.
fresh
printf 'List of devices attached\n' >"$LOG/devices"
: >"$LOG/connect_ok"
out=$(py 'from phone_link import phone
print(phone.phone_serial() or "none")')
[ "$out" = "192.168.77.232:5555" ] \
  && ok "an empty adb devices is recovered from the pinned port" \
  || bad "an empty adb devices is recovered from the pinned port" "$out"
[ ! -s "$LOG/avahi_calls" ] && ok "the pinned port needs no browse" \
  || bad "the pinned port needs no browse" "$(cat "$LOG/avahi_calls")"

# 14. The doctor resolves the pinned port the same way.
fresh
printf 'List of devices attached\n' >"$LOG/devices"
: >"$LOG/connect_ok"
out=$(py 'from phone_doctor.context import Context
print(Context().serial or "none")')
[ "$out" = "192.168.77.232:5555" ] \
  && ok "the doctor recovers the pinned port" \
  || bad "the doctor recovers the pinned port" "$out"

# 15. PHONE_ADB_MDNS=0 switches the pinned probe off too: it is the same switch
#     a test or an untrusted network uses to make adb calls stay as given.
fresh
printf 'List of devices attached\n' >"$LOG/devices"
: >"$LOG/connect_ok"
out=$(PHONE_ADB_MDNS=0 py 'from phone_link import phone
print(phone.phone_serial() or "none")')
[ "$out" = "none" ] && ok "the pinned probe follows the off switch" \
  || bad "the pinned probe follows the off switch" "$out"
[ ! -s "$LOG/connect.log" ] && ok "nothing is connected to when off" \
  || bad "nothing is connected to when off" "$(cat "$LOG/connect.log")"

finish
