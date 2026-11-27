#!/usr/bin/env bash
# Hermetic tests for lib/phone-tun-toggle.sh: stub systemctl, the TCP probe and
# the route/address source, and render the config with the real
# lib/phone-tun-config.py the unit runs in ExecStartPre. No network, no phone,
# no systemd, no real ip command.
set -u

BASH_BIN=$(command -v bash)
PYTHON_BIN=$(command -v python3)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOGGLE=$ROOT/lib/phone-tun-toggle.sh
CONFIG_PY=$ROOT/lib/phone-tun-config.py
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin
mkdir -p "$LOG" "$STUBS" "$TMP/run/phone-link" "$TMP/run/phone-tun"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$*"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$*"
}

PRIMARY=192.168.77.232
FALLBACK=10.23.190.38
TEMPLATE=$TMP/template.json
export PRIMARY_HOST=$PRIMARY PYTHON_BIN CONFIG_PY TEMPLATE
export PHONE_TUN_HOSTS="$PRIMARY $FALLBACK"
export PHONE_TUN_PORT_FILE=$TMP/run/phone-link/proxy-port
export PHONE_TUN_FALLBACK_PORT=1080
export PHONE_TUN_HOST_FILE=$TMP/run/phone-link/proxy-host
export PHONE_TUN_PENDING_FILE=$TMP/run/phone-link/proxy-host.pending
export PHONE_TUN_CONFIG_FILE=$TMP/run/phone-tun/config.json
export PHONE_TUN_RUNTIME_DIR=$TMP/run/phone-link
export PHONE_TUN_SYSTEMCTL=$STUBS/systemctl
export PHONE_TUN_PROBE=$STUBS/probe PHONE_TUN_PROBE_TIMEOUT=1
# Discovery is off unless a test opts in, so the suite never runs `ip`.
export PHONE_TUN_GATEWAYS=""
printf '1081\n' >"$PHONE_TUN_PORT_FILE"

# The store template has placeholders; the generator fills them in.
cat >"$TEMPLATE" <<'EOF'
{
  "outbounds": [
    {
      "type": "socks",
      "tag": "phone",
      "server": "@PHONE_SOCKS_HOST@",
      "server_port": 0,
      "password": "@PHONE_SOCKS_PASS@"
    },
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

cat >"$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/actions"
case "${1:-}" in
  is-active)
    [ "$(cat "$LOG/state" 2>/dev/null)" = active ]
    ;;
  start | restart)
    printf 'active\n' >"$LOG/state"
    # ExecStartPre, as the unit runs it after every real start.
    PHONE_SOCKS_PASS=test "$PYTHON_BIN" "$CONFIG_PY" \
      "$TEMPLATE" "$PHONE_TUN_CONFIG_FILE" "$PHONE_TUN_PORT_FILE" \
      "$PHONE_TUN_HOST_FILE" "$PRIMARY_HOST" "$PHONE_TUN_FALLBACK_PORT" \
      $PHONE_TUN_HOSTS || exit 1
    ;;
  stop)
    printf 'inactive\n' >"$LOG/state"
    ;;
esac
EOF

cat >"$STUBS/probe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$LOG/probes"
grep -qxF "$1" "$LOG/reachable"
EOF

# Synthetic `ip` output: one default gateway and one point-to-point peer.
cat >"$STUBS/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/ipargs"
case "$*" in
  "route show default")
    printf 'default via 10.19.134.25 dev enp55s0u2 proto dhcp metric 100\n'
    ;;
  "-4 addr show")
    cat <<'IP'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
    inet 127.0.0.1/8 scope host lo
2: enp55s0u2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 10.19.134.112/24 brd 10.19.134.255 scope global dynamic enp55s0u2
3: usb0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500
    inet 10.99.0.2 peer 10.99.0.1/32 scope global usb0
IP
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS"/systemctl "$STUBS"/probe "$STUBS"/ip
chmod +x "$STUBS"/systemctl "$STUBS"/probe "$STUBS"/ip

run() {
  "$BASH_BIN" "$TOGGLE" >"$LOG/out" 2>&1
}
reset() {
  printf 'inactive\n' >"$LOG/state"
  : >"$LOG/actions"
  : >"$LOG/reachable"
  : >"$LOG/probes"
  : >"$LOG/ipargs"
  rm -f "$PHONE_TUN_HOST_FILE" "$PHONE_TUN_PENDING_FILE" "$PHONE_TUN_CONFIG_FILE"
}
probes() {
  cat "$LOG/probes" 2>/dev/null || true
}
changes() {
  grep -E '^(start|restart|stop) ' "$LOG/actions" || true
}
host() {
  cat "$PHONE_TUN_HOST_FILE" 2>/dev/null || true
}
config_server() {
  "$PYTHON_BIN" - "$PHONE_TUN_CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    config = json.load(f)
print(next(o["server"] for o in config["outbounds"] if o.get("tag") == "phone"))
PY
}

# 1. Both transports up: the declared primary is used and the tunnel starts.
reset
printf '%s\n' "$PRIMARY" "$FALLBACK" >"$LOG/reachable"
if run; then ok "the toggle exits 0"; else bad "the toggle exits 0 ($(cat "$LOG/out"))"; fi
[ "$(host)" = "$PRIMARY" ] && ok "the primary is written to the host file" \
  || bad "the primary is written to the host file (got $(host))"
[ "$(config_server)" = "$PRIMARY" ] && ok "the config carries the primary" \
  || bad "the config carries the primary (got $(config_server))"
[ "$(changes)" = "start phone-tun.service" ] && ok "the tunnel is started once" \
  || bad "the tunnel is started once (got $(changes))"

# 2. The same selection on later ticks does not touch systemd.
: >"$LOG/actions"
if run; then ok "a stable tick exits 0"; else bad "a stable tick exits 0 ($(cat "$LOG/out"))"; fi
[ -z "$(changes)" ] && ok "a stable selection does not restart" \
  || bad "a stable selection does not restart (got $(changes))"

# 3. The primary stops answering while the fallback is up: the host file moves
#    at once, the restart waits for the next tick, and the config then carries
#    the fallback.
printf '%s\n' "$FALLBACK" >"$LOG/reachable"
: >"$LOG/actions"
run
[ "$(host)" = "$FALLBACK" ] && ok "the fallback reaches the host file immediately" \
  || bad "the fallback reaches the host file immediately (got $(host))"
[ -z "$(changes)" ] && ok "a first change is not acted on yet" \
  || bad "a first change is not acted on yet (got $(changes))"
[ "$(config_server)" = "$PRIMARY" ] && ok "the running tunnel still carries the primary" \
  || bad "the running tunnel still carries the primary (got $(config_server))"

run
[ "$(changes)" = "restart phone-tun.service" ] && ok "the confirmed fallback restarts the tunnel" \
  || bad "the confirmed fallback restarts the tunnel (got $(changes))"
[ "$(config_server)" = "$FALLBACK" ] && ok "the restarted config carries the fallback" \
  || bad "the restarted config carries the fallback (got $(config_server))"
[ ! -e "$PHONE_TUN_PENDING_FILE" ] && ok "the confirmed host clears the pending file" \
  || bad "the confirmed host clears the pending file"

# 4. Once the tunnel runs on the fallback, further ticks leave it alone.
: >"$LOG/actions"
run
[ -z "$(changes)" ] && ok "the fallback is stable without a restart loop" \
  || bad "the fallback is stable without a restart loop (got $(changes))"

# 5. The primary coming back is preferred again, after the same confirmation.
printf '%s\n' "$PRIMARY" "$FALLBACK" >"$LOG/reachable"
: >"$LOG/actions"
run
[ -z "$(changes)" ] && ok "the returning primary waits one tick" \
  || bad "the returning primary waits one tick (got $(changes))"
run
[ "$(changes)" = "restart phone-tun.service" ] && ok "the returning primary restarts the tunnel" \
  || bad "the returning primary restarts the tunnel (got $(changes))"
[ "$(config_server)" = "$PRIMARY" ] && ok "the declared preference order returns to the primary" \
  || bad "the declared preference order returns to the primary (got $(config_server))"

# 6. One failed probe does not cost a reconnect: a flap that recovers before
#    the next tick never restarts.
reset
printf '%s\n' "$PRIMARY" "$FALLBACK" >"$LOG/reachable"
run
printf '%s\n' "$FALLBACK" >"$LOG/reachable"
run
printf '%s\n' "$PRIMARY" "$FALLBACK" >"$LOG/reachable"
run
case "$(changes)" in
  *restart*) bad "a one-tick flap does not restart (got $(changes))" ;;
  *) ok "a one-tick flap does not restart" ;;
esac
[ "$(config_server)" = "$PRIMARY" ] && ok "a flap leaves the config on the primary" \
  || bad "a flap leaves the config on the primary (got $(config_server))"

# 7. No host answers: the tunnel is stopped, as before.
printf '' >"$LOG/reachable"
: >"$LOG/actions"
run
[ "$(changes)" = "stop phone-tun.service" ] && ok "no reachable host stops the tunnel" \
  || bad "no reachable host stops the tunnel (got $(changes))"

GATEWAY=10.19.134.25
PEER=10.99.0.1
# 8. A declared host that answers wins before discovery: the gateway is not
#    even probed.
reset
printf '%s\n' "$PRIMARY" >"$LOG/reachable"
export PHONE_TUN_GATEWAYS="$GATEWAY"
run
[ "$(host)" = "$PRIMARY" ] && ok "a declared host still wins over a gateway" \
  || bad "a declared host still wins over a gateway (got $(host))"
[ "$(probes)" = "$PRIMARY" ] && ok "no gateway is probed while a declared host answers" \
  || bad "no gateway is probed while a declared host answers (got $(probes | tr '\n' ' '))"

# 9. Every declared host is stale and the default gateway answers: the gateway
#    reaches the host file, is confirmed on the next tick and the config follows.
reset
export PHONE_TUN_GATEWAYS="$GATEWAY"
printf '%s\n' "$PRIMARY" >"$LOG/reachable"
run
printf '%s\n' "$GATEWAY" >"$LOG/reachable"
: >"$LOG/actions"
run
[ "$(host)" = "$GATEWAY" ] && ok "a discovered gateway reaches the host file" \
  || bad "a discovered gateway reaches the host file (got $(host))"
[ -z "$(changes)" ] && ok "a discovered gateway waits one tick" \
  || bad "a discovered gateway waits one tick (got $(changes))"
[ "$(config_server)" = "$PRIMARY" ] && ok "the running tunnel stays on the declared host" \
  || bad "the running tunnel stays on the declared host (got $(config_server))"
run
[ "$(changes)" = "restart phone-tun.service" ] && ok "the confirmed gateway restarts the tunnel" \
  || bad "the confirmed gateway restarts the tunnel (got $(changes))"
[ "$(config_server)" = "$GATEWAY" ] && ok "the restarted config carries the gateway" \
  || bad "the restarted config carries the gateway (got $(config_server))"

# 10. Neither a declared host nor a gateway answers: the unit still stops.
printf '' >"$LOG/reachable"
: >"$LOG/actions"
run
[ "$(changes)" = "stop phone-tun.service" ] && ok "a dead declared host and gateway stop the tunnel" \
  || bad "a dead declared host and gateway stop the tunnel (got $(changes))"

# 11. Duplicates are removed: the AP host and every declared host are skipped
#     before a gateway is probed.
reset
export PHONE_TUN_AP_HOST=10.10.10.10
export PHONE_TUN_GATEWAYS="$PRIMARY $FALLBACK $PHONE_TUN_AP_HOST $GATEWAY"
printf '%s\n' "$GATEWAY" >"$LOG/reachable"
run
[ "$(host)" = "$GATEWAY" ] && ok "the first answering gateway is selected" \
  || bad "the first answering gateway is selected (got $(host))"
[ "$(grep -cxF "$PRIMARY" "$LOG/probes")" = 1 ] && ok "a declared host is not probed twice" \
  || bad "a declared host is not probed twice (got $(probes | tr '\n' ' '))"
[ "$(grep -cxF "$PHONE_TUN_AP_HOST" "$LOG/probes")" = 0 ] && ok "the AP host is skipped as a gateway" \
  || bad "the AP host is skipped as a gateway (got $(probes | tr '\n' ' '))"
[ "$(probes)" = "$PRIMARY
$FALLBACK
$GATEWAY" ] && ok "declared hosts keep their order before the gateway" \
  || bad "declared hosts keep their order before the gateway (got $(probes | tr '\n' ' '))"

# 12. A point-to-point peer is found from `ip -4 addr show`, after the default
#     gateway, when the override is not set.
reset
unset PHONE_TUN_GATEWAYS
export PHONE_TUN_IP=$STUBS/ip
export PHONE_TUN_AP_HOST=$PRIMARY
printf '%s\n' "$PEER" >"$LOG/reachable"
run
[ "$(host)" = "$PEER" ] && ok "a point-to-point peer is discovered" \
  || bad "a point-to-point peer is discovered (got $(host))"
[ "$(probes)" = "$PRIMARY
$FALLBACK
$GATEWAY
$PEER" ] && ok "the default gateway is probed before the peer" \
  || bad "the default gateway is probed before the peer (got $(probes | tr '\n' ' '))"
[ "$(grep -cxF "route show default" "$LOG/ipargs")" = 1 ] &&
  [ "$(grep -cxF -- "-4 addr show" "$LOG/ipargs")" = 1 ] &&
  ok "routes and addresses are gathered once per tick" \
  || bad "routes and addresses are gathered once per tick (got $(cat "$LOG/ipargs"))"

# 13. The explicit override is the only source when it is set, including empty:
#     no route command runs.
reset
export PHONE_TUN_GATEWAYS=""
unset PHONE_TUN_IP
export PHONE_TUN_IP=$TMP/does-not-exist
run
[ ! -s "$LOG/ipargs" ] && ok "an empty gateway override skips the route command" \
  || bad "an empty gateway override skips the route command (got $(cat "$LOG/ipargs"))"
[ "$(changes)" = "stop phone-tun.service" ] && ok "an unreachable host stops without discovery" \
  || bad "an unreachable host stops without discovery (got $(changes))"
unset PHONE_TUN_IP PHONE_TUN_AP_HOST
export PHONE_TUN_GATEWAYS=""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
