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
print(Context({'PHONE_PROXY_PORT': '70000', 'PHONE_RUNTIME_PORT_FILE': '$port_file', 'PHONE_CONFIG_FILE': '/nonexistent'}).proxy_port)")
[ "$out" = 1080 ] && ok "rejects an out-of-range port" || bad "rejects an out-of-range port" "$out"

printf 'nope\n' >"$port_file"
out=$(py "from phone_doctor.context import Context
print(Context({'PHONE_PROXY_PORT': '0', 'PHONE_RUNTIME_PORT_FILE': '$port_file', 'PHONE_CONFIG_FILE': '/nonexistent'}).proxy_port)")
[ "$out" = 1080 ] && ok "rejects zero and a bad runtime file" \
  || bad "rejects zero and a bad runtime file" "$out"

# 5. The module's /etc/phone-link/env reaches settings and the doctor, with the
#    environment still winning. Values with spaces survive the shell quoting
#    the Nix module uses.
config=$TMP/env
cat >"$config" <<'EOF'
PHONE_AP_IF='wlptest9'
PHONE_AP_CON='TestLink'
PHONE_AP_SSID='A link with spaces'
PHONE_AP_ADDRESS='10.42.0.1/24'
PHONE_AP_BAND='bg'
PHONE_AP_CHANNEL='6'
PHONE_AP_CHANNEL_WIDTH='40'
PHONE_PROXY_HOST='10.9.9.9'
PHONE_PROXY_HOSTS='10.9.9.8 10.23.190.38'
PHONE_PROXY_PORT='1081'
PHONE_PROXY_USER='linkuser'
PHONE_SECRETS='/etc/nixos/test-secrets'
PHONE_RUNTIME_PORT_FILE='/run/test-link/proxy-port'
EOF
out=$(PHONE_CONFIG_FILE="$config" py "
from phone_link import settings
print(settings.PHONE_AP_IF)
print(settings.PHONE_AP_CON)
print(settings.PHONE_AP_SSID)
print(settings.PHONE_AP_ADDRESS)
print(settings.PHONE_AP_BAND)
print(settings.PHONE_AP_CHANNEL)
print(settings.PHONE_AP_CHANNEL_WIDTH)
print(settings.PHONE_PROXY_HOST)
print(' '.join(settings.PHONE_PROXY_HOSTS))
print(settings.PHONE_PROXY_PORT)
print(settings.PHONE_PROXY_USER)
print(settings.PHONE_SECRETS)
print(settings.PHONE_RUNTIME_PORT_FILE)
")
[ "$out" = "wlptest9
TestLink
A link with spaces
10.42.0.1/24
bg
6
40
10.9.9.9
10.9.9.8 10.23.190.38
1081
linkuser
/etc/nixos/test-secrets
/run/test-link/proxy-port" ] \
  && ok "the module configuration reaches settings" \
  || bad "the module configuration reaches settings" "$out"

out=$(py "
from phone_doctor.context import Context
ctx = Context({'PHONE_CONFIG_FILE': '$config'})
print(ctx.ap_if)
print(ctx.ap_con)
print(ctx.proxy_host)
print(ctx.proxy_port)
print(ctx.proxy_user)
print(ctx.secrets_file)
")
[ "$out" = "wlptest9
TestLink
10.9.9.9
1081
linkuser
/etc/nixos/test-secrets" ] \
  && ok "the module configuration reaches the doctor" \
  || bad "the module configuration reaches the doctor" "$out"

# 6. The environment still wins over the file.
out=$(PHONE_CONFIG_FILE="$config" PHONE_AP_IF=envif py 'from phone_link import settings
print(settings.PHONE_AP_IF)')
[ "$out" = envif ] && ok "the environment wins over the module file" \
  || bad "the environment wins over the module file" "$out"

# 7. ap_declarative compares the profile file with the configured AP name, not
#    the built-in "phonelink".
profile=$TMP/ap-profile
printf 'TestLink\n' >"$profile"
out=$(PHONE_CONFIG_FILE="$config" PHONE_AP_DECLARATIVE="$profile" py \
  'from phone_link import phone
print(phone.ap_declarative())')
[ "$out" = True ] && ok "a non-default AP name is declarative" \
  || bad "a non-default AP name is declarative" "$out"
printf 'phonelink\n' >"$profile"
out=$(PHONE_CONFIG_FILE="$config" PHONE_AP_DECLARATIVE="$profile" py \
  'from phone_link import phone
print(phone.ap_declarative())')
[ "$out" = False ] && ok "the built-in name is not treated as the configured one" \
  || bad "the built-in name is not treated as the configured one" "$out"

# 8. nft is resolved like the module's other values: the environment, then the
#    module file, then a shell that has it on PATH.
mkdir -p "$TMP/nft-env" "$TMP/nft-path"
env_nft=$TMP/nft-env/nft
file_nft=$TMP/nft-env/module-nft
cat >"$env_nft" <<'EOF'
#!/bin/sh
exit 0
EOF
cp "$env_nft" "$file_nft"
cp "$env_nft" "$TMP/nft-path/nft"
chmod +x "$env_nft" "$file_nft" "$TMP/nft-path/nft"
missing_config=$TMP/no-such-env
printf "PHONE_NFT='%s'\n" "$file_nft" >"$TMP/nft-config"
printf "PHONE_NFT='%s'\n" "$TMP/no-such-nft" >"$TMP/nft-bad-config"
out=$(py "
from phone_doctor.context import Context
print(Context({'PHONE_CONFIG_FILE': '$TMP/nft-config', 'PHONE_NFT': '$env_nft'}).nft)
print(Context({'PHONE_CONFIG_FILE': '$TMP/nft-config'}).nft)
print(Context({'PHONE_CONFIG_FILE': '$missing_config', 'PATH': '$TMP/nft-path'}).nft)
print(Context({'PHONE_CONFIG_FILE': '$TMP/nft-bad-config', 'PATH': '$TMP/nft-path'}).nft)
print(Context({'PHONE_CONFIG_FILE': '$missing_config', 'PATH': '/nonexistent'}).nft)
print(Context({'PHONE_CONFIG_FILE': '$missing_config'}).have('$env_nft'))
print(Context({'PHONE_CONFIG_FILE': '$missing_config', 'PATH': '/nonexistent'}).have('nft'))
")
[ "$out" = "$env_nft
$file_nft
$TMP/nft-path/nft
$TMP/nft-path/nft
None
True
False" ] && ok "resolves nft through the environment, the module file and PATH" \
  || bad "resolves nft through the environment, the module file and PATH" "$out"

# 9. Two threads resolving serial, secrets and the nmcli profile probe do the
#    work once and see one consistent answer. A module-level resolve_serial
#    stub counts how often the serial cache actually ran.
out=$(PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import phone_doctor.context as context
from phone_doctor.context import Context

serial_calls = 0
serial_lock = threading.Lock()


def resolve(_env):
    global serial_calls
    with serial_lock:
        serial_calls += 1
    time.sleep(0.05)
    return "SERIAL"


context.resolve_serial = resolve


class CountingSecrets:
    def __init__(self):
        self.calls = 0
        self.lock = threading.Lock()

    def read_text(self):
        with self.lock:
            self.calls += 1
        time.sleep(0.05)
        return "PHONE_SOCKS_PASS=secret\nPHONE_PIN=1234\n"


class CountingContext(Context):
    def __init__(self):
        super().__init__({"PHONE_CONFIG_FILE": "/nonexistent"})
        self.secret_path = CountingSecrets()
        self.profile_calls = 0
        self.profile_lock = threading.Lock()

    @property
    def secrets_file(self):
        return self.secret_path

    def text(self, argv, timeout=None):
        if argv and argv[0] == "nmcli":
            with self.profile_lock:
                self.profile_calls += 1
            time.sleep(0.05)
            return "phonelink\n"
        return ""


ctx = CountingContext()


def work(_index):
    return (
        ctx.serial,
        ctx.secrets()["PHONE_PIN"],
        ctx.profile_exists(),
        ctx.serial_error,
    )


with ThreadPoolExecutor(max_workers=8) as pool:
    answers = list(pool.map(work, range(8)))

assert answers == [("SERIAL", "1234", True, "")] * 8, answers
assert serial_calls == 1, serial_calls
assert ctx.secret_path.calls == 1, ctx.secret_path.calls
assert ctx.profile_calls == 1, ctx.profile_calls
print("initialised-once")
PY
)
[ "$out" = initialised-once ] && ok "concurrent caches initialise once" \
  || bad "concurrent caches initialise once" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
