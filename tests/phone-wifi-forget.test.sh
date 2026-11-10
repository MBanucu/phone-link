#!/usr/bin/env bash
# Hermetic tests for bin/phone-wifi-forget: stub adb with a saved-network table.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-wifi-forget
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
    case "${args[2]:-}" in
      list-networks) cat "$LOG/networks" ;;
      forget-network)
        printf 'forget-network %s\n' "${args[3]:-}" >>"$LOG/actions"
        awk -v id="${args[3]:-}" '$1 != id' "$LOG/networks" >"$LOG/networks.new"
        mv "$LOG/networks.new" "$LOG/networks"
        ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
export PATH="$STUBS:$PATH"

fresh_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  cat >"$LOG/networks" <<'TABLE'
Network Id      SSID                         Security type
0            FRITZ!Box 7530 XJ                wpa2-psk
0            FRITZ!Box 7530 XJ                wpa3-sae^
4            PhoneLink                        wpa2-psk
4            PhoneLink                        wpa3-sae^
TABLE
  rm -f "$LOG/actions"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check reports a saved SSID and changes nothing.
fresh_state
if run --check; then
  bad "--check exits 1 when saved"
else
  ok "--check exits 1 when saved"
fi
grep -q 'PhoneLink is saved (network id 4)' "$LOG/out" && ok "reports the id" \
  || bad "reports the id" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "--check changes nothing" || bad "--check changes nothing" "$(cat "$LOG/actions")"

# 2. --yes forgets the network and leaves the others alone.
if run --yes; then
  ok "forget exits 0"
else
  bad "forget exits 0" "$(cat "$LOG/out")"
fi
grep -q 'forget-network 4' "$LOG/actions" && ok "forgets the right id" \
  || bad "forgets the right id" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'PhoneLink' "$LOG/networks" && bad "PhoneLink is gone" || ok "PhoneLink is gone"
grep -q 'FRITZ' "$LOG/networks" && ok "other networks survive" || bad "other networks survive"
grep -q 'PhoneLink forgotten' "$LOG/out" && ok "reports success" || bad "reports success" "$(cat "$LOG/out")"

# 3. Forgetting an unsaved SSID is a no-op that exits 0.
if run --yes; then ok "second forget exits 0"; else bad "second forget exits 0" "$(cat "$LOG/out")"; fi
grep -q 'PhoneLink is not saved' "$LOG/out" && ok "says it is not saved" \
  || bad "says it is not saved" "$(cat "$LOG/out")"
[ "$(grep -c 'forget-network' "$LOG/actions")" = 1 ] && ok "second forget runs no command" \
  || bad "second forget runs no command" "$(cat "$LOG/actions")"

# 4. --check now exits 0.
if run --check; then ok "--check exits 0 when not saved"; else bad "--check exits 0 when not saved" "$(cat "$LOG/out")"; fi

# 5. Another SSID can be given, including one with spaces.
if run --yes 'FRITZ!Box 7530 XJ'; then ok "custom SSID exits 0"; else bad "custom SSID exits 0" "$(cat "$LOG/out")"; fi
grep -q 'forget-network 0' "$LOG/actions" && ok "custom SSID forgets its id" \
  || bad "custom SSID forgets its id" "$(cat "$LOG/actions")"

# 6. Without --yes and no terminal, nothing is forgotten.
fresh_state
if run; then bad "no confirmation exits 1"; else ok "no confirmation exits 1"; fi
[ ! -f "$LOG/actions" ] && ok "no confirmation forgets nothing" || bad "no confirmation forgets nothing"
grep -q 'aborted' "$LOG/out" && ok "abort is explained" || bad "abort is explained" "$(cat "$LOG/out")"

# 7. No phone.
printf 'List of devices attached\n' >"$LOG/devices"
if run --yes; then bad "no phone exits 1"; else ok "no phone exits 1"; fi
grep -q 'no phone attached' "$LOG/out" && ok "no phone message" || bad "no phone message" "$(cat "$LOG/out")"

# 8. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
