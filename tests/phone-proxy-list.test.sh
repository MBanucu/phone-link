#!/usr/bin/env bash
# `phone-proxy-switch --list` when the service is stopped.
#
# A stopped service prints nothing for `dumpsys activity service`, but the app
# keeps its non-secret saved-profile index in `files/state.txt`. This suite
# proves the list says "service stopped, these are saved" instead of two empty
# lists, and that it still prefers the live dump when one answers.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-proxy-switch

. "$ROOT/tests/lib/harness.sh"
suite

stub adb
answer adb <<'EOF'
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
cmd="${args[*]}"
case $cmd in
  "shell dumpsys activity service "*) cat "$LOG/dump" ;;
  "shell cat "*) cat "$LOG/state" ;;
esac
EOF

export PHONE_SERIAL=XPLO2EEA0001541
export PHONE_SECRETS=$TMP/secrets
export PHONE_RUNTIME_PORT_FILE=$TMP/proxy-port
export PHONE_PROXY_USER=proxy
printf 'PHONE_SOCKS_PASS=s3cret\n' >"$PHONE_SECRETS"

run_list() {
  "$BASH_BIN" "$SCRIPT" --list >"$LOG/out" 2>&1
}

json() { # json EXPR
  python3 -c "import json,sys; d=json.load(open('$LOG/out')); print($1)"
}

# The app's stored index, in the format SavedIndex.java writes: URL-safe
# Base64 with standard padding, `~` for an empty field.
index() {
  cat >"$LOG/state" <<'STATE'
auto_start true
saved_index_version 1
saved_index_count 2
saved_index TXkgUGhvbmU= 1080 cHJveHk= 0 1 UGhvbmVMaW5r 0
saved_index ZmFzdA== 2000 ~ 1 0 UGhvbmVMaW5r 1
STATE
}

stopped() {
  : >"$LOG/dump"
  index
}

# 1. Stopped with a saved index: names, ports and switches, no listeners.
stopped
if run_list; then ok "a stopped service exits 0"; else bad "a stopped service exits 0" "$(cat "$LOG/out")"; fi
[ "$(json 'd["service"]')" = stopped ] && ok "says the service is stopped" \
  || bad "says the service is stopped" "$(cat "$LOG/out")"
[ "$(json 'len(d["running"])')" = 0 ] && ok "no running listeners" \
  || bad "no running listeners" "$(cat "$LOG/out")"
[ "$(json 'len(d["saved"])')" = 2 ] && ok "both saved proxies are reported" \
  || bad "both saved proxies are reported" "$(cat "$LOG/out")"
[ "$(json 'd["saved"][0]["name"]')" = "My Phone" ] && ok "a name with a space decodes" \
  || bad "a name with a space decodes" "$(cat "$LOG/out")"
[ "$(json 'd["saved"][0]["port"]')" = 1080 ] && ok "the first port is reported" \
  || bad "the first port is reported" "$(cat "$LOG/out")"
[ "$(json 'd["saved"][0]["user"]')" = "proxy" ] && ok "the user decodes" \
  || bad "the user decodes" "$(cat "$LOG/out")"
[ "$(json 'd["saved"][1]["anonymous"]')" = True ] && ok "the anonymous flag survives" \
  || bad "the anonymous flag survives" "$(cat "$LOG/out")"
[ "$(json 'all(not e["running"] for e in d["saved"])')" = True ] \
  && ok "saved proxies are not claimed to be running" \
  || bad "saved proxies are not claimed to be running" "$(cat "$LOG/out")"
[ "$(json 'all(e["offerable"] for e in d["saved"])')" = True ] \
  && ok "both are offerable with the laptop credentials" \
  || bad "both are offerable with the laptop credentials" "$(cat "$LOG/out")"
grep -q 's3cret' "$LOG/out" && bad "the password stays out of the list" \
  || ok "the password stays out of the list"

# 2. A stopped service whose app never wrote an index: still two empty lists,
#    but the service state is named so the caller can wait for a newer app.
: >"$LOG/dump"
printf 'auto_start true\nport 1080\n' >"$LOG/state"
run_list
[ "$(json 'd["service"]')" = stopped ] && ok "an old app still says stopped" \
  || bad "an old app still says stopped" "$(cat "$LOG/out")"
[ "$(json 'd["saved"]')" = "[]" ] && ok "an old app has no index to report" \
  || bad "an old app has no index to report" "$(cat "$LOG/out")"

# 3. A real empty list is distinguishable from a missing index.
printf 'saved_index_version 1\nsaved_index_count 0\nsaved_index none\n' >"$LOG/state"
run_list
[ "$(json 'd["saved"]')" = "[]" ] && ok "an empty index reports no saved proxies" \
  || bad "an empty index reports no saved proxies" "$(cat "$LOG/out")"

# 4. The live dump wins while the service runs; a stale index is not merged.
index
cat >"$LOG/dump" <<'DUMP'
  state       listening on 0.0.0.0:1080 · 0 clients
  running     port 1080 · ↓ 0 B · ↑ 0 B · 0 clients
  saved       "daily" — port 1080 · SSID PhoneLink · user proxy · auto-start on · wireless debugging off
DUMP
run_list
[ "$(json 'd["service"]')" = running ] && ok "a running service says running" \
  || bad "a running service says running" "$(cat "$LOG/out")"
[ "$(json '[e["name"] for e in d["saved"]]')" = "['daily']" ] \
  && ok "the live saved list wins over the index" \
  || bad "the live saved list wins over the index" "$(cat "$LOG/out")"
[ "$(json 'd["running"]')" = "[1080]" ] && ok "the live listener is reported" \
  || bad "the live listener is reported" "$(cat "$LOG/out")"

# 5. A gated service (running, not listening) uses its own saved lines too.
cat >"$LOG/dump" <<'DUMP'
  state       waiting for an allowed network
  saved       "daily" — port 1080 · SSID PhoneLink · user proxy · auto-start on · wireless debugging off
DUMP
run_list
[ "$(json 'd["service"]')" = gated ] && ok "a gated service says gated" \
  || bad "a gated service says gated" "$(cat "$LOG/out")"
[ "$(json 'd["saved"][0]["name"]')" = daily ] && ok "a gated service still lists what is saved" \
  || bad "a gated service still lists what is saved" "$(cat "$LOG/out")"

# 6. A version this laptop does not understand is ignored, not misread.
: >"$LOG/dump"
printf 'saved_index_version 2\nsaved_index_count 1\nsaved_index ZmFzdA== 2000 ~ 1 0 UGhvbmVMaW5r 1\n' >"$LOG/state"
run_list
[ "$(json 'd["saved"]')" = "[]" ] && ok "an unknown index version is ignored" \
  || bad "an unknown index version is ignored" "$(cat "$LOG/out")"

# 7. A saved user the laptop has no password for is named, not offered.
stopped
cat >"$LOG/state" <<'STATE'
auto_start false
saved_index_version 1
saved_index_count 1
saved_index b3RoZXI= 3000 YWxpY2U= 0 0 UGhvbmVMaW5r 0
STATE
run_list
[ "$(json 'd["saved"][0]["offerable"]')" = False ] && ok "a foreign user is not offerable" \
  || bad "a foreign user is not offerable" "$(cat "$LOG/out")"
grep -q 'it uses user alice' "$LOG/out" && ok "the refusal names the user" \
  || bad "the refusal names the user" "$(cat "$LOG/out")"

finish
