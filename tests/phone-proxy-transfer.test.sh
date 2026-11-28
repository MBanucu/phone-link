#!/usr/bin/env bash
# Hermetic tests for the proxy app's saved-proxy transfer over adb:
# bin/phone-proxy-export, bin/phone-proxy-import and the export/import steps of
# bin/phone-proxy-install --replace-signer.
#
# A stub adb speaks just enough of the app's contract, and a small Python
# "device" stands in for the one-shot loopback socket behind adb forward. No
# phone, no network, no root: the id stub reports uid 0 so the commands do not
# escalate, and every path is under the suite's temporary directory.
#
#   bash tests/phone-proxy-transfer.test.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$here/.." && pwd)
. "$ROOT/tests/lib/harness.sh"
suite WORK --log . --stubs stub --home home

stub_cmd id "$WORK/stub" <<'ID'
#!/usr/bin/env bash
printf '0\n'
ID

# The fake device: accept the one connection adb forward would deliver, check
# the one-time token, and answer EXPORT/IMPORT the way ProfileTransfer does.
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
    token = open(os.path.join(log, "token")).read().strip()
    hello = stream.readline().decode("ascii", "replace").strip()
    if hello != "PLX1 " + token:
        conn.sendall(b"ERR bad-token the token does not match this transfer\n")
        raise SystemExit(0)
    if mode == "export":
        body = open(os.path.join(log, "doc.json"), "rb").read()
        conn.sendall(b"OK %d\n" % len(body) + body)
    else:
        header = stream.readline().decode("ascii", "replace").split()
        length = int(header[1])
        body = stream.read(length)
        with open(os.path.join(log, "imported.json"), "wb") as handle:
            handle.write(body)
        count = int(open(os.path.join(log, "import_count")).read().strip())
        conn.sendall(b"OK %d\n" % count)
DEVICE

# adb: the device/install/dumpsys shape, plus forward and the am actions. The
# transfer's token and mode are recorded by the am handler, which is exactly
# where the real app reads them.
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
  uninstall) printf 'Success\n'; : >"$LOG/running"; : >"$LOG/saved" ;;
  forward)
    if [ "${args[1]:-}" = "--remove" ]; then
      if [ -s "$LOG/server.pid" ]; then
        kill "$(cat "$LOG/server.pid")" 2>/dev/null || true
      fi
      exit 0
    fi
    if [ -f "$LOG/nothing" ]; then
      printf '54321\n'
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
      *"pm path "*)
        [ "${ADB_STUB_ABSENT:-0}" = 1 ] || printf 'package:/data/app/base.apk\n'
        ;;
      *"dumpsys package"*) printf '        versionName=0.14.0\n' ;;
      *"dumpsys activity service"*)
        printf '  contract_version 1\n'
        [ -s "$LOG/running" ] && cat "$LOG/running"
        [ -s "$LOG/saved" ] && cat "$LOG/saved"
        if [ -s "$LOG/state" ]; then
          printf '  state %s\n' "$(cat "$LOG/state")"
        fi
        ;;
      *"ip -4 -o addr show"*) cat "$LOG/ips" ;;
      *"am start-foreground-service"*)
        printf '%s\n' "$cmd" >>"$LOG/actions"
        case "$cmd" in
          *".EXPORT"*)
            printf 'export' >"$LOG/mode"
            sed -n 's/.*--es token \([^ ]*\).*/\1/p' <<<"$cmd" >"$LOG/token"
            ;;
          *".IMPORT"*)
            printf 'import' >"$LOG/mode"
            sed -n 's/.*--es token \([^ ]*\).*/\1/p' <<<"$cmd" >"$LOG/token"
            ;;
          *"action.START"*)
            port=$(sed -n 's/.*--ei port \([0-9][0-9]*\).*/\1/p' <<<"$cmd")
            [ -n "$port" ] || port=1080
            printf '  running     port %s · 0 clients\n' "$port" >>"$LOG/running"
            printf 'listening on 0.0.0.0:%s · 0 clients' "$port" >"$LOG/state"
            ;;
          *"action.STOP"*)
            : >"$LOG/state"
            : >"$LOG/running"
            ;;
        esac
        ;;
    esac
    ;;
esac
exit 0
ADB

stub_cmd curl "$WORK/stub" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/curl.log"
printf '%s' "$(cat "$LOG/http_code" 2>/dev/null || printf 200)"
CURL

export PHONE_SECRETS="$WORK/secrets"
export PHONE_PROXY_BACKUP="$WORK/backup.json"
# The app answers in the dump it just wrote; there is nothing to wait out.
export PHONE_PROXY_TRANSFER_WAIT=1 PHONE_PROXY_WAIT=1
printf 'PHONE_SOCKS_PASS=not-a-real-secret\n' >"$PHONE_SECRETS"
printf '2: wlan0    inet 192.168.77.232/24 brd 192.168.77.255 scope global wlan0\n' \
  >"$WORK/ips"
printf '200' >"$WORK/http_code"
printf 'apkbytes' >"$WORK/local.apk"

doc="$WORK/doc.json"
cat >"$doc" <<'DOC'
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
printf '1' >"$WORK/import_count"

run() {
  local script=$1
  shift
    PHONE_SECRETS="$WORK/secrets" PHONE_PROXY_BACKUP="$WORK/backup.json" \
    PHONE_PROXY_TRANSFER_WAIT=1 PHONE_PROXY_WAIT=1 \
    bash "$ROOT/bin/$script" "$@" 2>&1
}

fresh() {
  rm -f "$WORK/adb.log" "$WORK/actions" "$WORK/curl.log" "$WORK/state" \
    "$WORK/running" "$WORK/saved" "$WORK/local_port" "$WORK/server.pid" \
    "$WORK/nothing" "$WORK/token" "$WORK/mode" "$WORK/imported.json" \
    "$WORK/backup.json" "$WORK/export.json" "$WORK/none.json"
  : >"$WORK/actions"
  : >"$WORK/adb.log"
}

passed() {
  ok "$1"
}
failed() {
  bad "$1" "${2:-}"
}

# 1. An export pulls the document, writes it 0600, and never prints a password.
fresh
out=$(run phone-proxy-export --out "$WORK/export.json")
rc=$?
if [ "$rc" = 0 ]; then passed "export exits 0"; else failed "export exits 0" "exit $rc: $out"; fi
if cmp -s "$doc" "$WORK/export.json"; then
  passed "export writes the phone's document"
else
  failed "export writes the phone's document" "$(ls -l "$WORK/export.json" 2>&1)"
fi
mode=$(stat -c %a "$WORK/export.json" 2>/dev/null || true)
if [ "$mode" = 600 ]; then passed "the backup is mode 0600"; else
  failed "the backup is mode 0600" "mode ${mode:-missing}"
fi
case $out in
  *dummy-pass*) failed "the export prints no password" "$out" ;;
  *) passed "the export prints no password" ;;
esac
grep -q 'action.EXPORT' "$WORK/adb.log" && passed "export sends the EXPORT action" \
  || failed "export sends the EXPORT action" "$(cat "$WORK/adb.log")"
grep -q 'forward --remove' "$WORK/adb.log" && passed "export removes the forward" \
  || failed "export removes the forward" "$(cat "$WORK/adb.log")"

# 2. An import sends exactly the file and reports the app's count.
#    The file from step 1 is the input, so it is not cleaned here.
rm -f "$WORK/imported.json"
out=$(run phone-proxy-import "$WORK/export.json")
rc=$?
if [ "$rc" = 0 ]; then passed "import exits 0"; else failed "import exits 0" "exit $rc: $out"; fi
if cmp -s "$doc" "$WORK/imported.json"; then
  passed "import sends exactly the backup"
else
  failed "import sends exactly the backup" "$(cat "$WORK/imported.json" 2>/dev/null)"
fi
case $out in
  *"imported 1 saved proxies"*) passed "import reports the count" ;;
  *) failed "import reports the count" "$out" ;;
esac
case $out in
  *dummy-pass*) failed "the import prints no password" "$out" ;;
  *) passed "the import prints no password" ;;
esac

# 2b. The backup must not become a git object. A path outside a work tree is
#     fine; inside one it has to be ignored, or the command refuses before it
#     writes or even asks the phone.
fresh
mkdir -p "$WORK/plain"
out=$(run phone-proxy-export --out "$WORK/plain/export.json")
rc=$?
[ "$rc" = 0 ] && passed "a non-git destination is written" \
  || failed "a non-git destination is written" "exit $rc: $out"

repo="$WORK/repo"
rm -rf "$repo"
mkdir -p "$repo/backups"
git -C "$repo" init -q
printf 'backups/*.json\n' >"$repo/.gitignore"
fresh
rm -f "$repo/backups/export.json"
out=$(run phone-proxy-export --out "$repo/backups/export.json")
rc=$?
if [ "$rc" = 0 ] && [ -s "$repo/backups/export.json" ]; then
  passed "an ignored path in a git work tree is written"
else
  failed "an ignored path in a git work tree is written" "exit $rc: $out"
fi

fresh
rm -f "$repo/proxies.json"
out=$(run phone-proxy-export --out "$repo/proxies.json")
rc=$?
[ "$rc" = 1 ] && passed "an unignored path in a git work tree exits 1" \
  || failed "an unignored path in a git work tree exits 1" "exit $rc: $out"
[ -e "$repo/proxies.json" ] && failed "an unignored backup is not written" \
  || passed "an unignored backup is not written"
case $out in
  *"git work tree"*".gitignore"*PHONE_PROXY_BACKUP*) \
    passed "an unignored backup names the fix" ;;
  *) failed "an unignored backup names the fix" "$out" ;;
esac
grep -q 'action.EXPORT' "$WORK/adb.log" \
  && failed "an unignored backup asks the phone nothing" \
  || passed "an unignored backup asks the phone nothing"

# 3. A phone that answers nothing fails as a locked (or too old) phone, writes
#    no backup and says to unlock it.
fresh
: >"$WORK/nothing"
out=$(run phone-proxy-export --out "$WORK/none.json")
rc=$?
[ "$rc" = 1 ] && passed "a phone that answers nothing exits 1" \
  || failed "a phone that answers nothing exits 1" "exit $rc: $out"
[ -e "$WORK/none.json" ] && failed "a refused export writes no file" \
  || passed "a refused export writes no file"
case $out in
  *unlock*) passed "a refused export names the locked screen" ;;
  *) failed "a refused export names the locked screen" "$out" ;;
esac
grep -q 'action.EXPORT' "$WORK/adb.log" && passed "the locked attempt still asked the app" \
  || failed "the locked attempt still asked the app"

# 4. A malformed document is refused before anything is written.
fresh
printf 'not a document' >"$WORK/doc.json"
out=$(run phone-proxy-export --out "$WORK/none.json")
rc=$?
[ "$rc" = 1 ] && passed "a malformed export exits 1" \
  || failed "a malformed export exits 1" "exit $rc: $out"
[ -e "$WORK/none.json" ] && failed "a malformed export writes no file" \
  || passed "a malformed export writes no file"
case $out in
  *"not JSON"*) passed "a malformed export says it is not JSON" ;;
  *) failed "a malformed export says it is not JSON" "$out" ;;
esac
cat >"$doc" <<'DOC'
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
printf 'not json' >"$WORK/bad.json"
fresh
out=$(run phone-proxy-import "$WORK/bad.json")
rc=$?
[ "$rc" = 1 ] && passed "a malformed import exits 1" \
  || failed "a malformed import exits 1" "exit $rc: $out"
grep -q 'action.IMPORT' "$WORK/adb.log" && failed "a malformed import asks the app nothing" \
  || passed "a malformed import asks the app nothing"

# 5. --replace-signer exports first, then uninstalls, installs, imports and
#    starts the proxy that was in use. The backup is 0600 and the output has no
#    password.
fresh
out=$(run phone-proxy-install --replace-signer --yes "$WORK/local.apk")
rc=$?
if [ "$rc" = 0 ]; then passed "--replace-signer exits 0"; else
  failed "--replace-signer exits 0" "exit $rc: $out"
fi
export_line=$(grep -n 'action.EXPORT' "$WORK/adb.log" | head -1 | cut -d: -f1)
uninstall_line=$(grep -n 'uninstall org.phonelink.proxy' "$WORK/adb.log" | head -1 | cut -d: -f1)
install_line=$(grep -n ' install -r -g' "$WORK/adb.log" | head -1 | cut -d: -f1)
import_line=$(grep -n 'action.IMPORT' "$WORK/adb.log" | head -1 | cut -d: -f1)
start_line=$(grep -n 'action.START' "$WORK/adb.log" | head -1 | cut -d: -f1)
if [ -n "$export_line" ] && [ -n "$uninstall_line" ] && [ -n "$install_line" ] \
  && [ -n "$import_line" ] && [ -n "$start_line" ] \
  && [ "$export_line" -lt "$uninstall_line" ] \
  && [ "$uninstall_line" -lt "$install_line" ] \
  && [ "$install_line" -lt "$import_line" ] \
  && [ "$import_line" -lt "$start_line" ]; then
  passed "export, uninstall, install, import, start is the order"
else
  failed "export, uninstall, install, import, start is the order" "$(cat "$WORK/adb.log")"
fi
mode=$(stat -c %a "$WORK/backup.json" 2>/dev/null || true)
if [ "$mode" = 600 ]; then passed "the replace backup is mode 0600"; else
  failed "the replace backup is mode 0600" "mode ${mode:-missing}"
fi
if cmp -s "$doc" "$WORK/backup.json"; then
  passed "the replace backup is the exported document"
else
  failed "the replace backup is the exported document" "$(cat "$WORK/backup.json" 2>/dev/null)"
fi
case $out in
  *dummy-pass*) failed "the replace prints no password" "$out" ;;
  *) passed "the replace prints no password" ;;
esac
case $out in
  *"192.168.77.232:1080 -> https://example.com = 200"*)
    passed "the restored proxy answers on its old port"
    ;;
  *) failed "the restored proxy answers on its old port" "$out" ;;
esac
case $out in
  *"the proxy is listening"*) passed "the restore reports the observed listener" ;;
  *) failed "the restore reports the observed listener" "$out" ;;
esac

# 6. A different signer with an app that cannot export is not uninstalled:
#    losing the proxies silently is the failure this feature removes.
fresh
: >"$WORK/nothing"
out=$(run phone-proxy-install --replace-signer --yes "$WORK/local.apk")
rc=$?
[ "$rc" = 1 ] && passed "a replace with no export exits 1" \
  || failed "a replace with no export exits 1" "exit $rc: $out"
grep -q 'uninstall org.phonelink.proxy' "$WORK/adb.log" \
  && failed "no export means no uninstall" \
  || passed "no export means no uninstall"
case $out in
  *unlock*) passed "no export names the locked screen" ;;
  *) failed "no export names the locked screen" "$out" ;;
esac

finish
