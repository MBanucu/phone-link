#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-boot: stub adb, no phone, no root.
#
# The stub keeps the phone's state in files under $LOG, so a fix is visible to
# the next read exactly as it would be on a device: a grant writes `true`, the
# service intent writes auto_start, the whitelist command creates the entry.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-proxy-boot
. "$ROOT/tests/lib/harness.sh"
tmpdir TMP
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
export PHONE_SERIAL=TESTPHONE
mkdir -p "$LOG/grants" "$STUBS"

# State file answers, when the service is silent or absent.
stub_cmd shell "$TMP" <<'EOF'
#!/usr/bin/env bash
line="$*"

case "$line" in
  "pm path "*)
    [ -f "$LOG/installed" ] && printf 'package:/data/app/x/base.apk\r\n'
    ;;
  "pm grant "*" android.permission."*)
    perm=${line##*android.permission.}
    printf 'true\n' >"$LOG/grants/$perm"
    printf '%s\n' "$line" >>"$LOG/actions"
    ;;
  "dumpsys package "*)
    printf '    versionCode=1302 minSdk=29 targetSdk=%s\n' "$(cat "$LOG/target")"
    printf '    versionName=0.13.2\n'
    printf '    flags=[ HAS_CODE ]\n'
    if [ -s "$LOG/direct" ]; then
      printf '    privateFlags=[ %s ]\n' "$(cat "$LOG/direct")"
    fi
    for perm in ACCESS_COARSE_LOCATION ACCESS_FINE_LOCATION \
      ACCESS_BACKGROUND_LOCATION POST_NOTIFICATIONS RECEIVE_BOOT_COMPLETED
    do
      [ -f "$LOG/grants/$perm" ] || continue
      printf '    android.permission.%s: granted=%s\n' "$perm" "$(cat "$LOG/grants/$perm")"
    done
    if [ -s "$LOG/receiver" ]; then
      printf 'Receiver Resolver Table:\n'
      printf '  Non-Data Actions:\n'
      printf '      android.intent.action.LOCKED_BOOT_COMPLETED:\n'
      printf '        38b0d9 org.phonelink.proxy/.BootReceiver filter edb9a9e\n'
    fi
    ;;
  "dumpsys deviceidle whitelist")
    if [ -f "$LOG/whitelisted" ]; then
      printf 'user,org.phonelink.proxy,10332\n'
    else
      printf 'user,com.example.other,10100\n'
    fi
    ;;
  "cmd deviceidle whitelist +"*)
    : >"$LOG/whitelisted"
    printf '%s\n' "$line" >>"$LOG/actions"
    ;;
  "dumpsys activity service "*)
    [ -f "$LOG/service_silent" ] || printf '      auto-start  %s\n' "$(cat "$LOG/auto_start")"
    ;;
  "cat /sdcard/Android/data/"*)
    if [ ! -f "$LOG/state_silent" ]; then
      printf 'auto_start %s\n' "$(cat "$LOG/auto_start")"
      cat "$LOG/state_extra" 2>/dev/null
    fi
    ;;
  "am start-foreground-service "*)
    printf 'true\n' >"$LOG/auto_start"
    printf '%s\n' "$line" >>"$LOG/actions"
    ;;
  "getprop ro.build.version.sdk")
    printf '35\n'
    ;;
esac
EOF
export ADB_STUB_SHELL=$TMP/shell
stub_adb "$STUBS"
export PATH="$STUBS:$PATH"

reset() {
  : >"$LOG/installed"
  : >"$LOG/whitelisted"
  rm -f "$LOG/actions" "$LOG/service_silent" "$LOG/state_silent" "$LOG/state_extra"
  printf '35\n' >"$LOG/target"
  printf 'PARTIALLY_DIRECT_BOOT_AWARE\n' >"$LOG/direct"
  printf 'yes\n' >"$LOG/receiver"
  printf 'true\n' >"$LOG/auto_start"
  for perm in ACCESS_COARSE_LOCATION ACCESS_FINE_LOCATION \
    ACCESS_BACKGROUND_LOCATION POST_NOTIFICATIONS RECEIVE_BOOT_COMPLETED
  do
    printf 'true\n' >"$LOG/grants/$perm"
  done
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. A phone with the whole set passes, and the message says what is still not
#    proven: only a reboot without unlocking.
reset
if run --check; then ok "--check passes with the full boot set"; else bad "--check passes with the full boot set" "$(cat "$LOG/out")"; fi
grep -q 'every boot input adb can check is present' "$LOG/out" \
  && ok "says every adb input is present" || bad "says every adb input is present" "$(cat "$LOG/out")"
grep -q 'DokeOS Auto Start Management is not readable from adb' "$LOG/out" \
  && ok "names the gate adb cannot read" || bad "names the gate adb cannot read" "$(cat "$LOG/out")"
grep -q 'does not promise a restart' "$LOG/out" \
  && ok "does not promise the restart" || bad "does not promise the restart" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "--check changes nothing" || bad "--check changes nothing" "$(cat "$LOG/actions")"

# 2. A declared-but-denied grant is a check failure and names the permission.
reset
printf 'false\n' >"$LOG/grants/ACCESS_BACKGROUND_LOCATION"
if run --check; then bad "a denied grant exits 1"; else ok "a denied grant exits 1"; fi
grep -q 'background location is not granted' "$LOG/out" \
  && ok "names the denied grant" || bad "names the denied grant" "$(cat "$LOG/out")"
grep -q 'reinstall' "$LOG/out" \
  && bad "a denied grant is not called a manifest fact" \
  || ok "a denied grant is not called a manifest fact"
[ ! -f "$LOG/actions" ] && ok "the check still changes nothing" || bad "the check still changes nothing" "$(cat "$LOG/actions")"

# 3. Notifications are required at targetSdk 33+ and not before.
reset
printf 'false\n' >"$LOG/grants/POST_NOTIFICATIONS"
if run --check; then bad "denied notifications at target 35 exits 1"; else ok "denied notifications at target 35 exits 1"; fi
grep -q 'notifications are not granted' "$LOG/out" \
  && ok "names denied notifications" || bad "names denied notifications" "$(cat "$LOG/out")"
reset
printf '32\n' >"$LOG/target"
rm -f "$LOG/grants/POST_NOTIFICATIONS"
if run --check; then ok "targetSdk 32 needs no notification grant"; else bad "targetSdk 32 needs no notification grant" "$(cat "$LOG/out")"; fi

# 4. A manifest fact is not fixable and asks for a reinstall.
reset
rm -f "$LOG/grants/ACCESS_FINE_LOCATION"
if run --check; then bad "an undeclared grant exits 1"; else ok "an undeclared grant exits 1"; fi
grep -q 'the build does not declare fine location' "$LOG/out" \
  && ok "names the undeclared grant" || bad "names the undeclared grant" "$(cat "$LOG/out")"
grep -q 'reinstall the release' "$LOG/out" \
  && ok "asks for a reinstall" || bad "asks for a reinstall" "$(cat "$LOG/out")"

reset
: >"$LOG/direct"
if run --check; then bad "no direct-boot flag exits 1"; else ok "no direct-boot flag exits 1"; fi
grep -q 'this build is not direct-boot aware' "$LOG/out" \
  && ok "names the missing direct-boot flag" || bad "names the missing direct-boot flag" "$(cat "$LOG/out")"

reset
: >"$LOG/receiver"
if run --check; then bad "no locked-boot receiver exits 1"; else ok "no locked-boot receiver exits 1"; fi
grep -q 'no receiver handles LOCKED_BOOT_COMPLETED' "$LOG/out" \
  && ok "names the missing locked-boot receiver" || bad "names the missing locked-boot receiver" "$(cat "$LOG/out")"

reset
printf 'false\n' >"$LOG/grants/RECEIVE_BOOT_COMPLETED"
if run --check; then bad "denied boot permission exits 1"; else ok "denied boot permission exits 1"; fi
grep -q 'RECEIVE_BOOT_COMPLETED is not granted' "$LOG/out" \
  && ok "names the denied boot permission" || bad "names the denied boot permission" "$(cat "$LOG/out")"

# 5. An unreadable auto_start is reported, not passed over.
reset
: >"$LOG/service_silent"
: >"$LOG/state_silent"
if run --check; then bad "unreadable auto_start exits 1"; else ok "unreadable auto_start exits 1"; fi
grep -q 'auto_start could not be read' "$LOG/out" \
  && ok "names the unreadable switch" || bad "names the unreadable switch" "$(cat "$LOG/out")"

# 5b. The app's dated suspicion is repeated, with the screen, and does not
#     turn into an adb failure: the fixer cannot make the vendor list readable.
reset
printf 'oem_autostart unreadable\nlast_boot blocked 1700000000\n' >"$LOG/state_extra"
if run --check; then ok "a likely-blocked boot still exits 0"; else bad "a likely-blocked boot still exits 0" "$(cat "$LOG/out")"; fi
grep -q 'the app reports the last boot as likely blocked' "$LOG/out" \
  && ok "repeats the app's likely-blocked fact" || bad "repeats the app's likely-blocked fact" "$(cat "$LOG/out")"
grep -q 'Auto Start Management' "$LOG/out" \
  && ok "points at the DokeOS screen" || bad "points at the DokeOS screen" "$(cat "$LOG/out")"

# 6. Not installed points at the installer and touches nothing.
reset
rm -f "$LOG/installed"
if run --check; then bad "not installed exits 1"; else ok "not installed exits 1"; fi
grep -q 'phone-proxy-install' "$LOG/out" \
  && ok "points at the installer" || bad "points at the installer" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "does not act on a missing app" || bad "does not act on a missing app" "$(cat "$LOG/actions")"

# 7. The fixer grants all four, whitelists and starts the service, in that
#    order, then re-reads the phone and passes.
reset
for perm in ACCESS_COARSE_LOCATION ACCESS_FINE_LOCATION \
  ACCESS_BACKGROUND_LOCATION POST_NOTIFICATIONS
do
  printf 'false\n' >"$LOG/grants/$perm"
done
rm -f "$LOG/whitelisted"
printf 'false\n' >"$LOG/auto_start"
if run; then ok "the fixer exits 0"; else bad "the fixer exits 0" "$(cat "$LOG/out")"; fi
expected=$(cat <<'EOF'
pm grant org.phonelink.proxy android.permission.ACCESS_COARSE_LOCATION
pm grant org.phonelink.proxy android.permission.ACCESS_FINE_LOCATION
pm grant org.phonelink.proxy android.permission.ACCESS_BACKGROUND_LOCATION
pm grant org.phonelink.proxy android.permission.POST_NOTIFICATIONS
cmd deviceidle whitelist +org.phonelink.proxy
am start-foreground-service -n org.phonelink.proxy/org.phonelink.proxy.ProxyService -a org.phonelink.proxy.action.START --ez auto_start true
EOF
)
actual=$(cat "$LOG/actions")
if [ "$expected" = "$actual" ]; then
  ok "grants, whitelist and service start in order"
else
  bad "grants, whitelist and service start in order" "$actual"
fi
grep -q 'every boot input adb can change is set' "$LOG/out" \
  && ok "says the adb-side inputs are set" || bad "says the adb-side inputs are set" "$(cat "$LOG/out")"
if run --check; then ok "the fixed phone passes --check"; else bad "the fixed phone passes --check" "$(cat "$LOG/out")"; fi

# 8. A manifest fact still fails after the fixable part is repaired.
reset
printf 'false\n' >"$LOG/grants/ACCESS_BACKGROUND_LOCATION"
rm -f "$LOG/receiver"
if run; then bad "the fixer refuses an unstartable build"; else ok "the fixer refuses an unstartable build"; fi
grep -q 'this install cannot start before unlock: no receiver handles LOCKED_BOOT_COMPLETED' "$LOG/out" \
  && ok "names the fact a reinstall must fix" || bad "names the fact a reinstall must fix" "$(cat "$LOG/out")"
grep -q 'reinstall the release' "$LOG/out" \
  && ok "asks for the reinstall" || bad "asks for the reinstall" "$(cat "$LOG/out")"
grep -qx 'pm grant org.phonelink.proxy android.permission.ACCESS_BACKGROUND_LOCATION' "$LOG/actions" \
  && ok "still repaired the grant it could" || bad "still repaired the grant it could" "$(cat "$LOG/actions" 2>/dev/null)"

# 9. --help works without a phone.
if "$BASH_BIN" "$SCRIPT" --help >"$LOG/out" 2>&1; then ok "--help exits 0"; else bad "--help exits 0"; fi
grep -q 'LOCKED_BOOT_COMPLETED' "$LOG/out" \
  && ok "--help names the pre-unlock requirement" || bad "--help names the pre-unlock requirement" "$(cat "$LOG/out")"

finish
