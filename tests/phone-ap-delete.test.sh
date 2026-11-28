#!/usr/bin/env bash
# Hermetic tests for bin/phone-ap-delete: stub nmcli and sudo.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-ap-delete
. "$ROOT/tests/lib/harness.sh"
suite
export PHONE_AP_DECLARATIVE=$TMP/ap-profile


stub nmcli
answer nmcli <<'EOF'
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

stub id
answer id <<'EOF'
printf '0\n'
EOF

stub sudo
answer sudo <<'EOF'
exec "$@"
EOF


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

# 6. A declarative profile is reported while checking.
printf 'phonelink\n' >"$PHONE_AP_DECLARATIVE"
printf 'phonelink\n' >"$LOG/names"
: >"$LOG/active"
rm -f "$LOG/actions"
if run --check; then ok "declarative --check exits 0"; else bad "declarative --check exits 0"; fi
grep -q 'declared by phoneLink.ap' "$LOG/out" \
  && ok "reports the declarative owner" || bad "reports the declarative owner" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "declarative --check changes nothing" \
  || ok "declarative --check changes nothing"

# 7. External role: there is no local profile this host owns, so nothing is
#    stopped or deleted.
rm -f "$PHONE_AP_DECLARATIVE"
printf 'phonelink\n' >"$LOG/names"
printf 'phonelink:wlp110s0\n' >"$LOG/active"
rm -f "$LOG/actions"
if PHONE_AP_ROLE=external run --yes; then ok "external delete exits 0"; else
  bad "external delete exits 0" "$(cat "$LOG/out")"
fi
grep -q 'AP is external (phoneLink.ap.role = "external")' "$LOG/out" \
  && ok "explains that the AP is external" || bad "explains that the AP is external"
grep -q 'nothing is deleted' "$LOG/out" \
  && ok "says nothing is deleted" || bad "says nothing is deleted"
[ -s "$LOG/actions" ] && bad "external role deletes nothing" \
  || ok "external role deletes nothing"

# 8. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

finish
