#!/usr/bin/env bash
# Hermetic tests for bin/phone-link: the shared registry covers every script,
# unknown ids fail, and run passes flags, escalation-free, to the right script.
# No phone, no network, no GTK.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LINK=$ROOT/bin/phone-link
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUBS=$TMP/bin
mkdir -p "$STUBS"
export HOME=$TMP XDG_CACHE_HOME=$TMP/cache
export PATH="$ROOT/bin:$PATH"

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

# Through bash explicitly: the checkout wrapper has a /usr/bin/env shebang,
# which a hermetic build sandbox does not provide.
run() {
  bash "$LINK" "$@" >"$TMP/out" 2>"$TMP/err"
}

# 1. list --json names every script in bin/ and nothing else.
if run list --json; then ok "list --json exits 0"; else bad "list --json exits 0" "$(cat "$TMP/err")"; fi
if python3 - "$TMP/out" >"$TMP/ids" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
print("\n".join(sorted(item["id"] for item in data)))
PY
then ok "list --json parses"; else bad "list --json parses" "$(head -3 "$TMP/out" "$TMP/err")"; fi

: >"$TMP/expected"
for file in "$ROOT"/bin/*; do
  name=$(basename "$file")
  case $name in
    # Not actions: the shared-core CLI, the panel itself and the release-only
    # screenshots driver.
    phone-link | phone-link-gui | phone-link-gui-screenshots) continue ;;
  esac
  printf '%s\n' "$name" >>"$TMP/expected"
done
sort -o "$TMP/expected" "$TMP/expected"
if diff -u "$TMP/expected" "$TMP/ids" >"$TMP/diff"; then
  ok "the registry covers every script"
else
  bad "the registry covers every script" "$(cat "$TMP/diff")"
fi

# 2. check-registry agrees, and catches a script with no entry.
if run check-registry $(cat "$TMP/expected"); then
  ok "check-registry accepts bin/"
else
  bad "check-registry accepts bin/" "$(cat "$TMP/err")"
fi
if run check-registry $(cat "$TMP/expected") extra-script; then
  bad "check-registry rejects a missing action"
else
  ok "check-registry rejects a missing action"
fi
grep -q 'no action for: extra-script' "$TMP/err" && ok "names the missing action" \
  || bad "names the missing action" "$(cat "$TMP/err")"

# 3. Unknown ids and unsupported flags fail with a message, not a run.
if run run nope; then bad "unknown action exits 2"; else
  [ "$?" -eq 2 ] && ok "unknown action exits 2" || ok "unknown action fails"
fi
grep -q 'unknown action: nope' "$TMP/err" && ok "unknown action is explained" \
  || bad "unknown action is explained" "$(cat "$TMP/err")"
if run run phone-net-status --check; then bad "--check on a read-only action fails"; else
  ok "--check on a read-only action fails"
fi
grep -q 'has no --check' "$TMP/err" && ok "--check refusal is explained" \
  || bad "--check refusal is explained" "$(cat "$TMP/err")"

# 4. run executes the script, streams its output and keeps its exit status.
cat >"$STUBS/phone-fix-mobile-data" <<'EOF'
#!/usr/bin/env bash
printf 'argv:%s\n' "$*"
printf 'mobile data done\n'
exit 7
EOF
# A non-root action with --yes: a root one would be planned through pkexec,
# which behaves differently in a desktop session and in a sandbox.
cat >"$STUBS/phone-wifi-forget" <<'EOF'
#!/usr/bin/env bash
printf 'argv:%s\n' "$*"
exit 0
EOF
cat >"$STUBS/phone-doctor" <<'EOF'
#!/usr/bin/env bash
printf '{"ready": true, "counts": {"ok": 1}, "sections": []}\n'
EOF
# Same reason: the stubs are executed directly, so point them at this bash.
BASH=$(command -v bash)
for stub in "$STUBS"/*; do sed -i "1s|.*|#!$BASH|" "$stub"; done
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

if run run phone-fix-mobile-data --check; then bad "run keeps the exit status"; else
  ok "run keeps the exit status"
fi
grep -q '^argv:--check$' "$TMP/out" && ok "run passes --check" \
  || bad "run passes --check" "$(cat "$TMP/out")"
grep -q '^mobile data done$' "$TMP/out" && ok "run streams the output" \
  || bad "run streams the output" "$(cat "$TMP/out")"

if run run phone-wifi-forget --yes; then ok "confirmed destructive run exits 0"; else
  bad "confirmed destructive run exits 0" "$(cat "$TMP/err")"
fi
grep -q '^argv:--yes$' "$TMP/out" && ok "run passes --yes" \
  || bad "run passes --yes" "$(cat "$TMP/out")"

run run phone-fix-mobile-data --yes
grep -q -- '--yes' "$TMP/out" && bad "no --yes for an action without it" \
  || ok "no --yes for an action without it"

# 5. Root actions escalate (sudo when usable, else pkexec), user actions do not.
if PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
import shutil

from phone_link import actions

root = actions.plan(actions.BY_ID["phone-ap-up"])
user = actions.plan(actions.BY_ID["phone-fix-mobile-data"])
assert user[-1].endswith("phone-fix-mobile-data"), user
assert "pkexec" not in user, user
if __import__("os").geteuid() != 0 and (
    shutil.which("sudo") or shutil.which("pkexec")
):
    assert root[0].endswith(("sudo", "pkexec")), root
    assert "phone-ap-up" in root[-1], root
PY
then ok "root actions escalate, user actions do not"; else
  bad "root actions escalate, user actions do not"
fi

# 6. status is the doctor's JSON, unchanged.
if run status; then ok "status exits 0 when ready"; else
  bad "status exits 0 when ready" "$(cat "$TMP/err")"
fi
python3 - "$TMP/out" >/dev/null <<'PY' && ok "status is JSON" || bad "status is JSON"
import json
import sys

json.load(open(sys.argv[1]))
PY

# 7. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi
grep -q 'check-registry' "$TMP/out" && ok "--help lists the commands" \
  || bad "--help lists the commands"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
