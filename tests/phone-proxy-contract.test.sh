#!/usr/bin/env bash
# Hermetic tests for the proxy app's contract version: `contract_version <n>`
# in the non-secret state.txt and in the service's dump. A stub adb serves the
# fixtures and a small Python "device" answers the one-shot transfer, so the
# suite needs no phone, no root and no network.
#
#   bash tests/phone-proxy-contract.test.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$here/.." && pwd)
BASH_BIN=$(command -v bash)

. "$ROOT/tests/lib/harness.sh"
tmpdir WORK
export LOG="$WORK"
mkdir -p "$WORK/stub" "$WORK/home"

# The commands escalate by asking `id -u`; the tests already have every path
# under the temporary directory, so they must not re-run through sudo.
stub_cmd id "$WORK/stub" <<'ID'
#!/usr/bin/env bash
printf '0\n'
ID

# The fake device: accept the one connection adb forward delivers and answer
# EXPORT/IMPORT the way ProfileTransfer does. The token itself is covered by
# phone-proxy-transfer; here it only has to be a line the device reads.
stub_cmd device.py "$WORK" <<'DEVICE'
#!/usr/bin/env python3
import os
import socket
import sys

log, mode = sys.argv[1], sys.argv[2]
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(os.path.join(log, "local_port"), "w") as handle:
    handle.write(str(server.getsockname()[1]))

conn, _ = server.accept()
with conn:
    stream = conn.makefile("rb")
    stream.readline()  # PLX1 <token>
    if mode == "export":
        body = open(os.path.join(log, "doc.json"), "rb").read()
        conn.sendall(b"OK %d\n" % len(body) + body)
    else:
        header = stream.readline().decode("ascii", "replace").split()
        body = stream.read(int(header[1]))
        with open(os.path.join(log, "imported.json"), "wb") as handle:
            handle.write(body)
        conn.sendall(b"OK 1\n")
DEVICE

# adb: the install/shell shape, the app's intents, and the forward that starts
# the device. `state.txt` and the service dump are plain fixture files, so a
# case says exactly which source carries the version.
stub_cmd adb "$WORK/stub" <<'ADB'
#!/usr/bin/env bash
log=${ADB_LOG:-$LOG/adb.log}
printf '%s\n' "$*" >>"$log"
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
cmd="${args[*]:-}"
case "${args[0]:-}" in
  devices) printf 'List of devices attached\nTESTPHONE\tdevice\n\n' ;;
  install | install-multiple) printf 'Performing Streamed Install\nSuccess\n' ;;
  forward)
    if [ "${args[1]:-}" = "--remove" ]; then
      if [ -s "$LOG/server.pid" ]; then
        kill "$(cat "$LOG/server.pid")" 2>/dev/null || true
      fi
      exit 0
    fi
    rm -f "$LOG/local_port"
    python3 "$LOG/device.py" "$LOG" "$(cat "$LOG/mode")" \
      </dev/null >/dev/null 2>>"$LOG/python.err" &
    printf '%s\n' "$!" >"$LOG/server.pid"
    for _ in $(seq 1 100); do
      [ -s "$LOG/local_port" ] && break
      sleep 0.02
    done
    cat "$LOG/local_port"
    ;;
  shell)
    case "$cmd" in
      *"pm path "*) printf 'package:/data/app/base.apk\n' ;;
      *"dumpsys package"*) printf '        versionName=0.1.0\n' ;;
      *"dumpsys activity service"*) cat "$LOG/dump" ;;
      *"state.txt"*) [ -f "$LOG/state" ] && cat "$LOG/state" ;;
      *"ip -4 -o addr show"*) cat "$LOG/ips" ;;
      *"am start-foreground-service"*)
        printf '%s\n' "$cmd" >>"$LOG/actions"
        case "$cmd" in
          *".EXPORT"*) printf 'export' >"$LOG/mode" ;;
          *".IMPORT"*) printf 'import' >"$LOG/mode" ;;
        esac
        ;;
    esac
    ;;
esac
exit 0
ADB

chmod +x "$WORK/stub"/* 2>/dev/null || true
export PATH="$WORK/stub:$PATH"
export PHONE_SECRETS="$WORK/secrets"
export PHONE_PROXY_BACKUP="$WORK/backup.json"
# The host's deployed module file is not part of the fixture: an empty one
# keeps the defaults this suite asserts.
export PHONE_CONFIG_FILE="$WORK/config"
: >"$PHONE_CONFIG_FILE"
# The app answers in the fixtures it just wrote; there is nothing to wait out.
export PHONE_PROXY_TRANSFER_WAIT=1 PHONE_PROXY_WAIT=1
printf 'PHONE_SOCKS_PASS=not-a-real-secret\n' >"$PHONE_SECRETS"
printf '2: wlan0    inet 192.168.77.232/24 brd 192.168.77.255 scope global wlan0\n' \
  >"$WORK/ips"
printf 'apkbytes' >"$WORK/local.apk"

cat >"$WORK/doc.json" <<'DOC'
{"app": "phone-link-proxy", "version": 1, "in_use": "daily", "selected": "daily",
 "active": {"name": "daily", "port": 1080, "max_connections": 256, "user": "proxy",
            "password": "dummy-pass", "ssid": "PhoneLink", "anonymous": false,
            "any_network": false, "auto_start": true, "adb_wifi": true,
            "wifi_lock": false, "tile": false},
 "saved": [{"name": "daily", "port": 1080, "max_connections": 256, "user": "proxy",
            "password": "dummy-pass", "ssid": "PhoneLink", "anonymous": false,
            "any_network": false, "auto_start": true, "adb_wifi": true,
            "wifi_lock": false, "tile": false}]}
DOC

run() {
  local script=$1
  shift
  HOME="$WORK/home" PATH="$WORK/stub:$PATH" \
    PHONE_SECRETS="$WORK/secrets" PHONE_PROXY_BACKUP="$WORK/backup.json" \
    PHONE_PROXY_TRANSFER_WAIT=1 PHONE_PROXY_WAIT=1 \
    "$BASH_BIN" "$ROOT/bin/$script" "$@" >"$LOG/out" 2>"$LOG/err"
}

fresh() {
  rm -f "$LOG/adb.log" "$LOG/actions" "$LOG/state" "$LOG/dump" \
    "$LOG/local_port" "$LOG/server.pid" "$LOG/mode" "$LOG/imported.json" \
    "$LOG/backup.json" "$LOG/export.json" "$LOG/none.json" "$LOG/python.err"
  : >"$LOG/actions"
  : >"$LOG/adb.log"
}

json() { # json EXPR
  python3 -c "import json; d=json.load(open('$LOG/out')); print($1)"
}

# The service block a running app prints, with the contract line the app has
# spoken since contract 1.
running_dump() {
  cat >"$LOG/dump" <<'DUMP'
  contract_version 1
  state       listening on 0.0.0.0:1081 · 0 clients
  running     port 1081 · ↓ 0 B · ↑ 0 B · 0 clients
  saved       "daily" — port 1081 · SSID PhoneLink · user proxy · auto-start on · wireless debugging off
DUMP
}

# 1. Contract 1 in state.txt: the transfer commands pass the gate, export
#    writes the document and import sends it back.
fresh
printf 'contract_version 1\nauto_start true\n' >"$LOG/state"
: >"$LOG/dump"
run phone-proxy-export --out "$LOG/export.json"
rc=$?
[ "$rc" = 0 ] && ok "contract 1 lets an export run" \
  || bad "contract 1 lets an export run" "exit $rc: $(cat "$LOG/err")"
cmp -s "$WORK/doc.json" "$LOG/export.json" && ok "the export writes the phone's document" \
  || bad "the export writes the phone's document" "$(cat "$LOG/export.json" 2>/dev/null)"
grep -q 'action.EXPORT' "$LOG/adb.log" && ok "the export reaches the app" \
  || bad "the export reaches the app" "$(cat "$LOG/adb.log")"

run phone-proxy-import "$LOG/export.json"
rc=$?
[ "$rc" = 0 ] && ok "contract 1 lets an import run" \
  || bad "contract 1 lets an import run" "exit $rc: $(cat "$LOG/err")"
cmp -s "$WORK/doc.json" "$LOG/imported.json" && ok "the import sends exactly the backup" \
  || bad "the import sends exactly the backup" "$(cat "$LOG/imported.json" 2>/dev/null)"

# 1b. Contract 1 only in the dump: state.txt has no line, so the fallback is
#     what carries the version.
fresh
printf '  contract_version 1\n' >"$LOG/dump"
run phone-proxy-export --out "$LOG/export.json"
rc=$?
[ "$rc" = 0 ] && ok "the dump carries the version when state.txt does not" \
  || bad "the dump carries the version when state.txt does not" "exit $rc: $(cat "$LOG/err")"

# 1c. Contract 1 still runs the transfer commands' own validation: a malformed
#     import says so instead of being refused as an old app.
fresh
printf 'contract_version 1\nauto_start true\n' >"$LOG/state"
printf 'not a document' >"$WORK/bad.json"
run phone-proxy-import "$WORK/bad.json"
rc=$?
[ "$rc" = 1 ] && ok "a malformed import under contract 1 exits 1" \
  || bad "a malformed import under contract 1 exits 1" "exit $rc: $(cat "$LOG/err")"
grep -Fq 'not JSON' "$LOG/err" && ok "the malformed document is the error" \
  || bad "the malformed document is the error" "$(cat "$LOG/err")"
grep -Fq 'update the app to contract' "$LOG/err" \
  && bad "contract 1 is not called too old" || ok "contract 1 is not called too old"

# 2. No version line is contract 0: export and import refuse with the exact
#    fix and never start a transfer.
fresh
printf 'auto_start true\n' >"$LOG/state"
: >"$LOG/dump"
run phone-proxy-export --out "$LOG/none.json"
rc=$?
[ "$rc" = 1 ] && ok "an export of a contract 0 app exits 1" \
  || bad "an export of a contract 0 app exits 1" "exit $rc: $(cat "$LOG/err")"
grep -Fq 'update the app to contract >= 1: run phone-proxy-install' "$LOG/err" \
  && ok "the export names the exact update" \
  || bad "the export names the exact update" "$(cat "$LOG/err")"
[ -e "$LOG/none.json" ] && bad "a refused export writes no file" \
  || ok "a refused export writes no file"
grep -q 'action.EXPORT' "$LOG/adb.log" && bad "a refused export sends no EXPORT" \
  || ok "a refused export sends no EXPORT"
grep -q ' forward ' "$LOG/adb.log" && bad "a refused export opens no forward" \
  || ok "a refused export opens no forward"

run phone-proxy-import "$WORK/doc.json"
rc=$?
[ "$rc" = 1 ] && ok "an import of a contract 0 app exits 1" \
  || bad "an import of a contract 0 app exits 1" "exit $rc: $(cat "$LOG/err")"
grep -Fq 'update the app to contract >= 1: run phone-proxy-install' "$LOG/err" \
  && ok "the import names the exact update" \
  || bad "the import names the exact update" "$(cat "$LOG/err")"
grep -q 'action.IMPORT' "$LOG/adb.log" && bad "a refused import sends no IMPORT" \
  || ok "a refused import sends no IMPORT"

# 2b. A fresh install, or an update from a build without the line, leaves
#     state.txt stale or absent until the app runs. The install has already
#     succeeded, so it notes the unverified version instead of failing; the
#     transfer commands keep their hard gate.
fresh
printf 'auto_start true\n' >"$LOG/state"
: >"$LOG/dump"
run phone-proxy-install "$WORK/local.apk"
rc=$?
[ "$rc" = 0 ] && ok "an install with a stale state file exits 0" \
  || bad "an install with a stale state file exits 0" "exit $rc: $(cat "$LOG/err")"
grep -Fq 'has not published contract >= 1 yet' "$LOG/err" \
  && ok "the install notes the unverified contract" \
  || bad "the install notes the unverified contract" "$(cat "$LOG/err")"
grep -q ' install -r -g' "$LOG/adb.log" && ok "the install itself happened" \
  || bad "the install itself happened" "$(cat "$LOG/adb.log")"

# 2c. A fresh install with app data already published as contract 1 (the
#     normal case after opening the app once) passes without the note.
fresh
printf 'contract_version 1\nauto_start true\n' >"$LOG/state"
: >"$LOG/dump"
run phone-proxy-install "$WORK/local.apk"
rc=$?
[ "$rc" = 0 ] && ok "an install with a published contract 1 exits 0" \
  || bad "an install with a published contract 1 exits 0" "exit $rc: $(cat "$LOG/err")"
grep -Fq 'has not published contract' "$LOG/err" \
  && bad "a verified contract 1 install stays quiet" \
  || ok "a verified contract 1 install stays quiet"

fresh
printf 'contract_version 1\nauto_start true\n' >"$LOG/state"
: >"$LOG/dump"
run phone-proxy-install "$WORK/local.apk"
rc=$?
[ "$rc" = 0 ] && ok "an installed contract 1 app exits 0" \
  || bad "an installed contract 1 app exits 0" "exit $rc: $(cat "$LOG/err")"

# 3. A newer app is a warning: start --check and --list both still answer.
fresh
printf 'contract_version 2\nauto_start true\n' >"$LOG/state"
running_dump
run phone-proxy-start --check
rc=$?
[ "$rc" = 0 ] && ok "start --check works on a newer app" \
  || bad "start --check works on a newer app" "exit $rc: $(cat "$LOG/err")"
grep -Fq 'the app speaks contract 2' "$LOG/err" && ok "the warning names the app's contract" \
  || bad "the warning names the app's contract" "$(cat "$LOG/err")"
grep -Fq 'this laptop knows contract 1' "$LOG/err" \
  && ok "the warning names the laptop's contract" \
  || bad "the warning names the laptop's contract" "$(cat "$LOG/err")"

run phone-proxy-switch --list
rc=$?
[ "$rc" = 0 ] && ok "--list works on a newer app" \
  || bad "--list works on a newer app" "exit $rc: $(cat "$LOG/err")"
grep -Fq 'the app speaks contract 2' "$LOG/err" && ok "--list logs the newer warning" \
  || bad "--list logs the newer warning" "$(cat "$LOG/err")"
[ "$(json 'd["contract"]')" = 2 ] && ok "--list reports the parsed newer contract" \
  || bad "--list reports the parsed newer contract" "$(cat "$LOG/out")"

# 4. The list payload keeps its keys and adds `contract`.
fresh
printf 'contract_version 1\nauto_start true\n' >"$LOG/state"
running_dump
run phone-proxy-switch --list
rc=$?
[ "$rc" = 0 ] && ok "a contract 1 list exits 0" \
  || bad "a contract 1 list exits 0" "exit $rc: $(cat "$LOG/err")"
[ "$(json 'd["contract"]')" = 1 ] && ok "the list reports contract 1" \
  || bad "the list reports contract 1" "$(cat "$LOG/out")"
[ "$(json 'sorted(d)')" = "['active', 'contract', 'port_source', 'running', 'runtime_file', 'saved', 'service']" ] \
  && ok "the list keeps every existing key and adds only contract" \
  || bad "the list keeps every existing key and adds only contract" "$(cat "$LOG/out")"
[ "$(json 'd["saved"][0]["name"]')" = daily ] && ok "the saved entry shape is unchanged" \
  || bad "the saved entry shape is unchanged" "$(cat "$LOG/out")"

# 4b. An app that does not print the version is reported as unknown, not as an
#     error, so the panel can keep showing the old app's list.
fresh
printf 'auto_start true\n' >"$LOG/state"
: >"$LOG/dump"
run phone-proxy-switch --list
rc=$?
[ "$rc" = 0 ] && ok "--list works on an app without a version" \
  || bad "--list works on an app without a version" "exit $rc: $(cat "$LOG/err")"
[ "$(json 'd["contract"] is None')" = True ] && ok "an unknown contract is null" \
  || bad "an unknown contract is null" "$(cat "$LOG/out")"

finish
