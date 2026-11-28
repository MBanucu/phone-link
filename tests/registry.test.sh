#!/usr/bin/env bash
# Hermetic tests for the single-source registry: the shims, COMMANDS map and
# docs table are generated from phone_link.actions, and the registry check
# fails when any of them drifts. No phone, no network, no nix.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib/harness.sh"
tmpdir TMP

# A throwaway checkout: the generator imports the package from this copy too,
# so check-registry resolves its root and bins from the copy, exactly as it
# does in a real checkout.
COPY=$TMP/checkout
mkdir -p "$COPY"
cp -r "$ROOT/bin" "$ROOT/docs" "$ROOT/lib" "$COPY/"
chmod -R u+w "$COPY"
find "$COPY/lib" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

expected=()
for path in "$COPY"/bin/*; do
  name=${path##*/}
  case $name in
    phone-link | phone-link-gui | phone-link-gui-screenshots) continue ;;
  esac
  expected+=("$name")
done

gen() {
  PYTHONPATH="$COPY/lib/python" PYTHONDONTWRITEBYTECODE=1 \
    python3 -m phone_link.registry_gen "$@"
}

check_registry() {
  (cd "$COPY" && PYTHONPATH="$COPY/lib/python" PYTHONDONTWRITEBYTECODE=1 \
    python3 -m phone_link check-registry "${expected[@]}") >"$TMP/out" 2>"$TMP/err"
}

if gen --check --root "$COPY" >"$TMP/out" 2>"$TMP/err"; then
  ok "generated files agree with the table"
else
  bad "generated files agree with the table" "$(cat "$TMP/err")"
fi

if check_registry; then
  ok "check-registry accepts the generated files"
else
  bad "check-registry accepts the generated files" "$(cat "$TMP/err")"
fi

# 1. A docs row that disagrees is caught by the registry check.
cp "$COPY/docs/scripts.md" "$TMP/scripts.md"
sed -i 's/links, routes, resolver/links and routes/' "$COPY/docs/scripts.md"
if check_registry; then
  bad "check-registry rejects a drifted docs row"
else
  ok "check-registry rejects a drifted docs row"
fi
grep -q 'docs/scripts.md: table is out of date' "$TMP/err" \
  && ok "the docs failure names the table" \
  || bad "the docs failure names the table" "$(cat "$TMP/err")"
cp "$TMP/scripts.md" "$COPY/docs/scripts.md"

# 2. A shim that disagrees is caught, and the PHONE_LINK_SHIM contract is
# part of the generated text.
cp "$COPY/bin/phone-net-status" "$TMP/shim"
printf '# drift\n' >>"$COPY/bin/phone-net-status"
if check_registry; then
  bad "check-registry rejects a drifted shim"
else
  ok "check-registry rejects a drifted shim"
fi
grep -q 'bin/phone-net-status: out of date' "$TMP/err" \
  && ok "the shim failure names the file" \
  || bad "the shim failure names the file" "$(cat "$TMP/err")"
cp "$TMP/shim" "$COPY/bin/phone-net-status"
grep -q 'export PHONE_LINK_SHIM' "$COPY/bin/phone-net-status" \
  && ok "a generated action shim exports PHONE_LINK_SHIM" \
  || bad "a generated action shim exports PHONE_LINK_SHIM"

# 3. A hand-edited COMMANDS map is caught.
cp "$COPY/lib/python/phone_link/commands/__init__.py" "$TMP/commands.py"
sed -i 's/"net-check": status.net_check/"net-check": status.phone_net_status/' \
  "$COPY/lib/python/phone_link/commands/__init__.py"
if check_registry; then
  bad "check-registry rejects a hand-edited COMMANDS map"
else
  ok "check-registry rejects a hand-edited COMMANDS map"
fi
grep -q 'commands/__init__.py: out of date' "$TMP/err" \
  && ok "the COMMANDS failure names the file" \
  || bad "the COMMANDS failure names the file" "$(cat "$TMP/err")"
cp "$TMP/commands.py" "$COPY/lib/python/phone_link/commands/__init__.py"

# 4. A script with no table entry and a table id with no script both fail.
printf '#!/usr/bin/env bash\nexit 0\n' >"$COPY/bin/phone-drift"
if check_registry; then
  bad "check-registry rejects a script with no entry"
else
  ok "check-registry rejects a script with no entry"
fi
grep -q 'shims without a table entry: phone-drift' "$TMP/err" \
  && ok "the extra-script failure names it" \
  || bad "the extra-script failure names it" "$(cat "$TMP/err")"
rm "$COPY/bin/phone-drift"

mv "$COPY/bin/net-check" "$TMP/net-check"
if check_registry; then
  bad "check-registry rejects a table id with no script"
else
  ok "check-registry rejects a table id with no script"
fi
grep -q 'missing shims: net-check' "$TMP/err" \
  && ok "the missing-script failure names it" \
  || bad "the missing-script failure names it" "$(cat "$TMP/err")"
mv "$TMP/net-check" "$COPY/bin/net-check"

# 5. Restored, it is green again.
if check_registry; then
  ok "the restored registry is green"
else
  bad "the restored registry is green" "$(cat "$TMP/err")"
fi

finish
