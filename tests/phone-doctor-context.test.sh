#!/usr/bin/env bash
# Hermetic tests for phone_doctor.context: the secrets parser matches
# phone_link.phone.read_secrets, and PHONE_PROXY_PORT is validated. No phone,
# no network, no root.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log HOME=$TMP
mkdir -p "$LOG"

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

py() {
  PYTHONPATH="$ROOT/lib/python" python3 -c "$1"
}

secrets=$TMP/secrets
cat >"$secrets" <<'EOF'
# a comment
PHONE_SOCKS_PASS=plain
export PHONE_PIN="1234"
export PHONE_AP_PASS='ap pass'
export PHONE_EMPTY=""
BARE=
EOF
chmod 600 "$secrets"

# 1. `export KEY="value"` is accepted and the quotes are stripped, exactly as
#    phone_link.phone.read_secrets does.
out=$(py "
from phone_doctor.context import Context
values = Context({'PHONE_SECRETS': '$secrets'}).secrets()
print(values['PHONE_SOCKS_PASS'])
print(values['PHONE_PIN'])
print(values['PHONE_AP_PASS'])
print(repr(values['PHONE_EMPTY']))
")
[ "$out" = "plain
1234
ap pass
''" ] && ok "parses exported and quoted secrets" || bad "parses exported and quoted secrets" "$out"

# 2. The two parsers agree on every key they both see.
out=$(PHONE_SECRETS=$secrets py "
from phone_link import phone
from phone_doctor.context import Context
doctor = Context({'PHONE_SECRETS': '$secrets'}).secrets()
command = phone.read_secrets()
assert doctor == command, (doctor, command)
print('same')
")
[ "$out" = same ] && ok "agrees with the command parser" || bad "agrees with the command parser" "$out"

# 3. A valid environment port wins.
out=$(py "from phone_doctor.context import Context
print(Context({'PHONE_PROXY_PORT': '1081'}).proxy_port)")
[ "$out" = 1081 ] && ok "accepts a valid environment port" || bad "accepts a valid environment port" "$out"

# 4. An invalid environment port falls back to the runtime file, then 1080.
port_file=$TMP/runtime-port
printf '1082\n' >"$port_file"
out=$(py "from phone_doctor.context import Context
print(Context({'PHONE_PROXY_PORT': 'typo', 'PHONE_RUNTIME_PORT_FILE': '$port_file'}).proxy_port)")
[ "$out" = 1082 ] && ok "ignores a typo and reads the runtime file" \
  || bad "ignores a typo and reads the runtime file" "$out"

rm -f "$port_file"
out=$(py "from phone_doctor.context import Context
print(Context({'PHONE_PROXY_PORT': '70000', 'PHONE_RUNTIME_PORT_FILE': '$port_file'}).proxy_port)")
[ "$out" = 1080 ] && ok "rejects an out-of-range port" || bad "rejects an out-of-range port" "$out"

printf 'nope\n' >"$port_file"
out=$(py "from phone_doctor.context import Context
print(Context({'PHONE_PROXY_PORT': '0', 'PHONE_RUNTIME_PORT_FILE': '$port_file'}).proxy_port)")
[ "$out" = 1080 ] && ok "rejects zero and a bad runtime file" \
  || bad "rejects zero and a bad runtime file" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
