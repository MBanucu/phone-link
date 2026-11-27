#!/usr/bin/env bash
# Hermetic tests for root escalation: sudo re-runs the shim that was invoked,
# not whichever installed copy PATH finds, and keeps the documented PHONE_*
# overrides. sudo is a stub; no root, no phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)

. "$ROOT/tests/lib/harness.sh"
tmpdir TMP
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
mkdir -p "$LOG" "$STUBS" "$TMP/checkout/bin"

stub_cmd id "$STUBS" <<'EOF'
printf '1000\n'
EOF
stub_cmd sudo "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/sudo"
exit 0
EOF
# A decoy installed copy that PATH would prefer over the checkout.
stub_cmd phone-ap-up "$STUBS" <<'EOF'
printf 'installed copy\n' >>"$LOG/ran"
exit 0
EOF
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

finish
