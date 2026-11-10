#!/usr/bin/env bash
# Hermetic tests for bin/phone-ap-delete: stub nmcli and sudo.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-ap-delete
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

cat >"$STUBS/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-t -f NAME con show") cat "$LOG/names" ;;
  "-t -f NAME,DEVICE con show --active") cat "$LOG/active" ;;
  "connection down "*) printf '%s\n' "$*" >>"$LOG/actions" ;;
  "connection delete "*)
    printf '%s\n' "$*" >>"$LOG/actions"
    : >"$LOG/names"
    ;;
esac
EOF

cat >"$STUBS/id" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF

cat >"$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

sed -i "1s|.*|#!$BASH_BIN|" "$STUBS"/*
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check reports an active profile without changing it.
printf 'phonelink\nother\n' >"$LOG/names"
printf 'phonelink:wlp110s0\n' >"$LOG/active"
rm -f "$LOG/actions"
if run --check; then ok "--check exits 0"; else bad "--check exits 0" "$(cat "$LOG/out")"; fi
grep -q 'phonelink exists and is active on wlp110s0' "$LOG/out" \
  && ok "reports the active profile" || bad "reports the active profile" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "--check changes nothing" || ok "--check changes nothing"

# 2. --yes downs an active profile and deletes it.
printf 'phonelink\nother\n' >"$LOG/names"
printf 'phonelink:wlp110s0\n' >"$LOG/active"
rm -f "$LOG/actions"
if run --yes; then ok "delete exits 0"; else bad "delete exits 0" "$(cat "$LOG/out")"; fi
grep -qx 'connection down phonelink' "$LOG/actions" && ok "brings the AP down" \
  || bad "brings the AP down" "$(cat "$LOG/actions" 2>/dev/null)"
grep -qx 'connection delete phonelink' "$LOG/actions" && ok "deletes the profile" \
  || bad "deletes the profile" "$(cat "$LOG/actions" 2>/dev/null)"
[ -s "$LOG/names" ] && bad "profile is gone afterwards" || ok "profile is gone afterwards"

# 3. An inactive profile is deleted without a down.
printf 'phonelink\n' >"$LOG/names"
: >"$LOG/active"
rm -f "$LOG/actions"
if run --yes; then ok "inactive delete exits 0"; else bad "inactive delete exits 0"; fi
grep -q 'connection down' "$LOG/actions" && bad "inactive profile is not downed" \
  || ok "inactive profile is not downed"
grep -qx 'connection delete phonelink' "$LOG/actions" && ok "inactive profile is deleted" \
  || bad "inactive profile is deleted"

# 4. No profile: nothing to do.
: >"$LOG/names"
rm -f "$LOG/actions"
if run; then ok "missing profile exits 0"; else bad "missing profile exits 0"; fi
[ -s "$LOG/actions" ] && bad "missing profile runs nothing" || ok "missing profile runs nothing"

# 5. Without --yes in a non-interactive shell it refuses.
printf 'phonelink\n' >"$LOG/names"
rm -f "$LOG/actions"
if run >/dev/null 2>&1; then bad "no --yes exits 1"; else ok "no --yes exits 1"; fi
[ -s "$LOG/actions" ] && bad "no --yes deletes nothing" || ok "no --yes deletes nothing"

# 6. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
