#!/usr/bin/env bash
# Hermetic tests for root escalation: sudo re-runs the shim that was invoked,
# not whichever installed copy PATH finds, and keeps the documented PHONE_*
# overrides. sudo is a stub; no root, no phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
mkdir -p "$LOG" "$STUBS" "$TMP/checkout/bin"

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

cat >"$STUBS/id" <<'EOF'
#!/usr/bin/env bash
printf '1000\n'
EOF
cat >"$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/sudo"
exit 0
EOF
# A decoy installed copy that PATH would prefer over the checkout.
cat >"$STUBS/phone-ap-up" <<'EOF'
#!/usr/bin/env bash
printf 'installed copy\n' >>"$LOG/ran"
exit 0
EOF
chmod +x "$STUBS/id" "$STUBS/sudo" "$STUBS/phone-ap-up"
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/id" "$STUBS/sudo" "$STUBS/phone-ap-up"
export PATH="$STUBS:$PATH"

shim=$TMP/checkout/bin/phone-ap-up
printf '#!%s\nexit 0\n' "$BASH_BIN" >"$shim"
chmod +x "$shim"

PHONE_LINK_SHIM="$shim" PHONE_PIN=1234 PHONE_SECRETS="$TMP/secrets" \
  PYTHONPATH="$ROOT/lib/python" python3 -c \
  'from phone_link import phone; phone.as_root("phone-ap-up", ["--check"])'

line=$(cat "$LOG/sudo" 2>/dev/null || true)
case "$line" in
  *"env"*"PHONE_PIN=1234"*"$shim"*"--check"*)
    ok "escalation runs the invoked shim with the PHONE_* overrides" ;;
  *) bad "escalation runs the invoked shim with the PHONE_* overrides" "$line" ;;
esac
case "$line" in
  *"PHONE_SECRETS=$TMP/secrets"*)
    ok "PHONE_SECRETS survives sudo" ;;
  *) bad "PHONE_SECRETS survives sudo" "$line" ;;
esac
[ -s "$LOG/ran" ] && bad "the PATH copy is not chosen" "$(cat "$LOG/ran")" \
  || ok "the PATH copy is not chosen"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
