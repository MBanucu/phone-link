#!/usr/bin/env bash
# Hermetic tests for bin/net-check: stub curl, Chrome and nix, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/net-check
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

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$LOG/curl.argv"
cat "$LOG/code" 2>/dev/null || printf '000'
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/curl"

cat >"$STUBS/google-chrome" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$LOG/chrome.argv"
case "$(cat "$LOG/chrome.mode" 2>/dev/null || echo ok)" in
  ok) printf '<html><title>Example Domain</title></html>\n' ;;
  empty) printf '<html><title>Captive portal</title></html>\n' ;;
  die) exit 1 ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/google-chrome"

cat >"$STUBS/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$LOG/nix.argv"
case "$(cat "$LOG/nix.mode" 2>/dev/null || echo ok)" in
  ok) printf '<html><title>Example Domain</title></html>\n' ;;
  empty) printf '<html><title>Captive portal</title></html>\n' ;;
  die) exit 1 ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/nix"

chmod +x "$STUBS/curl" "$STUBS/google-chrome" "$STUBS/nix"
# The script gets only the stubs: falling back to a real google-chrome or nix
# would make the "missing binary" cases pass for the wrong reason. The stubs
# still need these host tools, and the script's shim needs an interpreter.
for tool in timeout date grep readlink dirname cat python3; do
  ln -sf "$(command -v "$tool")" "$STUBS/$tool"
done
export PATH="$STUBS:$PATH"

reset_state() {
  printf '200' >"$LOG/code"
  printf 'ok' >"$LOG/chrome.mode"
  printf 'ok' >"$LOG/nix.mode"
  rm -f "$LOG/curl.argv" "$LOG/chrome.argv" "$LOG/nix.argv"
  # Restore binaries hidden by the missing-tool cases. Removing the file is
  # what makes command -v fail: a non-executable PATH entry is still found.
  [ -f "$TMP/chrome.hidden" ] && mv "$TMP/chrome.hidden" "$STUBS/google-chrome"
  [ -f "$TMP/nix.hidden" ] && mv "$TMP/nix.hidden" "$STUBS/nix"
  return 0
}

run() {
  env PATH="$STUBS" "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. All three reach the internet.
reset_state
if run; then
  ok "all tools exiting 0"
else
  bad "all tools exiting 0" "$(cat "$LOG/out")"
fi
grep -q 'curl:    https://example.com/?net-check=[0-9]* = 200' "$LOG/out" \
  && ok "curl fetch reported" || bad "curl fetch reported" "$(cat "$LOG/out")"
grep -q 'chrome:  google-chrome loaded https://example.com/?net-check=[0-9]*' "$LOG/out" \
  && ok "chrome fetch reported" || bad "chrome fetch reported" "$(cat "$LOG/out")"
grep -q 'nix:     builtins.fetchurl loaded https://example.com/?net-check=[0-9]*' "$LOG/out" \
  && ok "nix fetch reported" || bad "nix fetch reported" "$(cat "$LOG/out")"
grep -q 'verdict: the internet is reachable with curl, chrome and nix' "$LOG/out" \
  && ok "verdict says reachable" || bad "verdict says reachable" "$(cat "$LOG/out")"
grep -q -- '--headless' "$LOG/chrome.argv" && grep -q -- '--dump-dom' "$LOG/chrome.argv" \
  && ok "chrome runs headless and dumps the DOM" || bad "chrome runs headless and dumps the DOM" "$(cat "$LOG/chrome.argv")"
grep -q 'builtins.fetchurl' "$LOG/nix.argv" && ok "nix uses builtins.fetchurl" \
  || bad "nix uses builtins.fetchurl" "$(cat "$LOG/nix.argv")"
grep -q 'net-check=' "$LOG/curl.argv" && grep -q 'net-check=' "$LOG/chrome.argv" \
  && grep -q 'net-check=' "$LOG/nix.argv" && ok "every tool gets a cache-busting URL" \
  || bad "every tool gets a cache-busting URL"

# 2. curl fails, the other two are still checked.
reset_state
printf '000' >"$LOG/code"
if run; then
  bad "curl failure exits 1"
else
  ok "curl failure exits 1"
fi
grep -q 'curl:    .* = 000' "$LOG/out" && ok "curl failure reported" \
  || bad "curl failure reported" "$(cat "$LOG/out")"
grep -q 'chrome:  google-chrome loaded' "$LOG/out" && grep -q 'nix:     builtins.fetchurl loaded' "$LOG/out" \
  && ok "chrome and nix still run" || bad "chrome and nix still run" "$(cat "$LOG/out")"

# 3. No Chrome binary at all.
reset_state
mv "$STUBS/google-chrome" "$TMP/chrome.hidden"
if run; then
  bad "missing chrome exits 1"
else
  ok "missing chrome exits 1"
fi
grep -q 'chrome:  no google-chrome' "$LOG/out" && ok "missing chrome reported" \
  || bad "missing chrome reported" "$(cat "$LOG/out")"

# 4. Chrome starts but does not get the page.
reset_state
printf 'empty' >"$LOG/chrome.mode"
if run; then
  bad "chrome without the page exits 1"
else
  ok "chrome without the page exits 1"
fi
grep -q 'chrome:  google-chrome could not load' "$LOG/out" && ok "chrome failure reported" \
  || bad "chrome failure reported" "$(cat "$LOG/out")"

# 5. Nix cannot fetch.
reset_state
printf 'die' >"$LOG/nix.mode"
if run; then
  bad "nix failure exits 1"
else
  ok "nix failure exits 1"
fi
grep -q 'nix:     builtins.fetchurl could not load' "$LOG/out" && ok "nix failure reported" \
  || bad "nix failure reported" "$(cat "$LOG/out")"

# 6. Nix gets the wrong page.
reset_state
printf 'empty' >"$LOG/nix.mode"
if run; then
  bad "nix without the page exits 1"
else
  ok "nix without the page exits 1"
fi

# 7. Missing nix.
reset_state
mv "$STUBS/nix" "$TMP/nix.hidden"
if run; then
  bad "missing nix exits 1"
else
  ok "missing nix exits 1"
fi
grep -q 'nix:     not installed' "$LOG/out" && ok "missing nix reported" \
  || bad "missing nix reported" "$(cat "$LOG/out")"

# 8. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
