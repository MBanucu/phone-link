#!/usr/bin/env bash
# Hermetic tests for escalation: a root action asks for the password once, and
# sudo's timestamp carries the following ones, so the dialog does not reappear.
# sudo and pkexec are stubs on PATH; no phone, no polkit, no root.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUBS=$TMP/bin
mkdir -p "$STUBS"
export ESCALATION_LOG=$TMP/log
export ESCALATION_STAMP=$TMP/stamp

cat >"$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
# -n true: succeed only after something authenticated; -A: ask once, then
# remember, which is what sudo's own timestamp does.
printf 'sudo %s\n' "$*" >>"$ESCALATION_LOG"
mode=
cmd=()
while [ $# -gt 0 ]; do
  case $1 in
    -n | -A) mode=$1 ;;
    *) cmd+=("$1") ;;
  esac
  shift
done
if [ "$mode" = -n ] && [ "${cmd[*]-}" = true ]; then
  [ -f "$ESCALATION_STAMP" ] && exit 0
  exit 1
fi
if [ "$mode" = -A ]; then
  printf 'prompt\n' >>"$ESCALATION_LOG"
  : >"$ESCALATION_STAMP"
fi
exec "${cmd[@]}"
EOF
cat >"$STUBS/pkexec" <<'EOF'
#!/usr/bin/env bash
printf 'prompt pkexec\n' >>"$ESCALATION_LOG"
exec "$@"
EOF
cat >"$STUBS/askpass" <<'EOF'
#!/usr/bin/env bash
printf 'secret\n'
EOF
BASH=$(command -v bash)
for stub in "$STUBS"/*; do sed -i "1s|.*|#!$BASH|" "$stub"; done
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
export ASKPASS=$STUBS/askpass

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

# 1. A user action never escalates, so it can never open the dialog.
if PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
from phone_link import actions

argv = actions.plan(actions.BY_ID["phone-wifi-enable"], env={})
assert not any(part.endswith(("sudo", "pkexec")) for part in argv), argv
PY
then ok "a user action does not escalate"; else bad "a user action does not escalate"; fi

# 2. A live sudo timestamp (or a NOPASSWD rule) never asks.
: >"$ESCALATION_STAMP"
if PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
from phone_link import actions

argv = actions.plan(actions.BY_ID["phone-ap-up"], env={})
assert argv[0].endswith("/sudo"), argv
assert argv[1:3] == ["-n", "env"], argv
PY
then ok "an authenticated sudo runs without asking"; else bad "an authenticated sudo runs without asking"; fi

# 3. The first root action plans one prompt through the askpass helper.
rm -f "$ESCALATION_STAMP"
if PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
import os

from phone_link import actions

argv = actions.plan(actions.BY_ID["phone-ap-up"], env={"SUDO_ASKPASS": os.environ["ASKPASS"]})
assert argv[0].endswith("/sudo"), argv
assert argv[1:3] == ["-A", "env"], argv
PY
then ok "the first root action asks through askpass"; else bad "the first root action asks through askpass"; fi

# 4. After that one authentication, three more root actions plan no dialog.
"$STUBS/sudo" -A true >/dev/null
: >"$ESCALATION_LOG"
if PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
from phone_link import actions

for action_id in ("phone-ap-up", "phone-fix-tunnel", "phone-doctor-fix"):
    argv = actions.plan(actions.BY_ID[action_id], env={})
    assert argv[1:3] == ["-n", "env"], (action_id, argv)
PY
then ok "the following root actions ask nothing"; else bad "the following root actions ask nothing"; fi
if [ "$(grep -c '^prompt' "$ESCALATION_LOG")" -eq 0 ]; then
  ok "no prompt was triggered by the following actions"
else
  bad "no prompt was triggered by the following actions" "$(grep '^prompt' "$ESCALATION_LOG")"
fi

# 5. Without a timestamp and without askpass, pkexec is the fallback.
rm -f "$ESCALATION_STAMP"
if PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
from phone_link import actions

argv = actions.plan(actions.BY_ID["phone-ap-up"], env={})
assert argv[0].endswith("/pkexec"), argv
PY
then ok "without sudo it falls back to pkexec"; else bad "without sudo it falls back to pkexec"; fi

# 6. The PHONE_* overrides still reach the script.
: >"$ESCALATION_STAMP"
if PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
from phone_link import actions

argv = actions.plan(actions.BY_ID["phone-ap-up"], env={"PHONE_PIN": "1234"})
assert "PHONE_PIN=1234" in argv, argv
assert argv.index("PHONE_PIN=1234") < len(argv) - 1, argv
PY
then ok "the PHONE_* overrides are passed through"; else bad "the PHONE_* overrides are passed through"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
