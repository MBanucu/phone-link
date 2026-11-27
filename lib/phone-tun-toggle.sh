#!/usr/bin/env bash
# Keep phone-tun dialing the first proxy host that answers.
#
# The module runs this every 5 s. The declared hosts are tried in order (the
# configured primary first, then the fallbacks) and the winner is written to
# the host file, which `phone-tun-config` and the relay read. The tunnel itself
# only learns the new address when its config is regenerated in ExecStartPre:
# `systemctl start` on a running unit is a no-op, so a changed host needs a
# restart.
#
# Android picks a new USB tether subnet on every boot, so a declared USB
# fallback goes stale. After every declared host has failed, one tick gathers
# gateways: the next hop of each default route and the peer address of a
# point-to-point link (rndis/tether shows `peer x.x.x.x/32`). Those are
# deduplicated against the declared list and the AP host, then probed on the
# proxy port exactly like a declared host. The AP is a link, not an uplink, so
# it is never probed through the tunnel. A normal router simply refuses the
# proxy port, which costs one connection attempt.
#
# A changed host is confirmed on the next tick before the tunnel is restarted.
# That keeps one failed probe (a half-open socket, one dropped packet) from
# costing a reconnect and keeps a flapping probe from restarting the tunnel in
# a loop; a real failover lands within two ticks (~10 s). The host file is
# written immediately, because the relay and the next start read it, but the
# restart that re-points the running sing-box waits for the confirmation.
#
# Values come from the environment so the module can bind them to its own
# paths and a test can run the same script against a temporary tree:
#   PHONE_TUN_HOSTS          hosts in preference order, space separated
#   PHONE_TUN_AP_HOST        the AP host, never a gateway candidate (optional)
#   PHONE_TUN_GATEWAYS       explicit gateway candidates, space separated;
#                            set (even empty) replaces the route/address probe
#   PHONE_TUN_IP             ip binary used to find gateways (default ip)
#   PHONE_TUN_PORT_FILE      runtime port file (default /run/phone-link/proxy-port)
#   PHONE_TUN_FALLBACK_PORT  port when the file is missing or invalid (default 1080)
#   PHONE_TUN_HOST_FILE      selected host (default /run/phone-link/proxy-host)
#   PHONE_TUN_PENDING_FILE   unconfirmed host (default <host file>.pending)
#   PHONE_TUN_CONFIG_FILE    generated sing-box config (default /run/phone-tun/config.json)
#   PHONE_TUN_RUNTIME_DIR    directory for the atomic host-file write (default /run/phone-link)
#   PHONE_TUN_SYSTEMCTL      systemctl binary (default systemctl)
#   PHONE_TUN_UNIT           the unit to start, restart or stop (default phone-tun.service)
#   PHONE_TUN_PROBE_TIMEOUT  seconds per TCP probe (default 3)
#   PHONE_TUN_PROBE          optional probe command; called with host and port,
#                            exit 0 means reachable. Tests use this instead of
#                            a real socket.
set -u

: "${PHONE_TUN_HOSTS:?PHONE_TUN_HOSTS must list the proxy hosts}"
port_file=${PHONE_TUN_PORT_FILE:-/run/phone-link/proxy-port}
fallback_port=${PHONE_TUN_FALLBACK_PORT:-1080}
host_file=${PHONE_TUN_HOST_FILE:-/run/phone-link/proxy-host}
pending_file=${PHONE_TUN_PENDING_FILE:-$host_file.pending}
config_file=${PHONE_TUN_CONFIG_FILE:-/run/phone-tun/config.json}
runtime_dir=${PHONE_TUN_RUNTIME_DIR:-/run/phone-link}
systemctl=${PHONE_TUN_SYSTEMCTL:-systemctl}
unit=${PHONE_TUN_UNIT:-phone-tun.service}
probe_timeout=${PHONE_TUN_PROBE_TIMEOUT:-3}
ap_host=${PHONE_TUN_AP_HOST:-}
ip_cmd=${PHONE_TUN_IP:-ip}

# The port the panel chose, with the module's default when the file is absent
# or does not hold a usable port (same rule as phone-link-runtime-port).
port=$(cat "$port_file" 2>/dev/null || true)
case "$port" in
  '' | *[!0-9]*) port=$fallback_port ;;
esac
# The length check keeps a huge number out of the arithmetic test below.
if [ "${#port}" -gt 5 ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
  port=$fallback_port
fi

probe() {
  if [ -n "${PHONE_TUN_PROBE:-}" ]; then
    "$PHONE_TUN_PROBE" "$1" "$port"
  else
    timeout "$probe_timeout" "$BASH" -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$port" 2>/dev/null
  fi
}

# The gateways worth trying after the declared hosts. The override exists so a
# test (or a one-off run) can name them without an `ip` command; with it set to
# the empty string discovery is off. Otherwise the default routes and the peer
# of every point-to-point link are read once per tick.
gateway_candidates() {
  if [ -n "${PHONE_TUN_GATEWAYS+x}" ]; then
    # Word splitting is the point: the override is a plain host list.
    # shellcheck disable=SC2086
    printf '%s\n' $PHONE_TUN_GATEWAYS
    return 0
  fi
  "$ip_cmd" route show default 2>/dev/null | awk '
    {
      for (i = 1; i < NF; i++)
        if ($i == "via")
          print $(i + 1)
    }
  '
  "$ip_cmd" -4 addr show 2>/dev/null | awk '
    {
      for (i = 1; i < NF; i++)
        if ($i == "peer") {
          peer = $(i + 1)
          sub(/\/.*/, "", peer)
          print peer
        }
    }
  '
}

selected=
# Word splitting is the point: the module passes the list space separated so a
# host can never be interpreted as shell syntax.
# shellcheck disable=SC2086
for candidate in $PHONE_TUN_HOSTS; do
  if probe "$candidate"; then
    selected=$candidate
    break
  fi
done

# Declared hosts first, gateways after them. The AP host and every declared
# host are in `tried`, so a gateway that repeats one of them is never probed
# twice; the AP is a link and must not be reached through the tunnel.
if [ -z "$selected" ]; then
  tried=" $ap_host $PHONE_TUN_HOSTS "
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case " $tried " in
      *" $candidate "*) continue ;;
    esac
    tried="$tried$candidate "
    if probe "$candidate"; then
      selected=$candidate
      break
    fi
  done < <(gateway_candidates)
fi

# No host answers: stop the tunnel so traffic cannot stay blackholed, and
# forget an unconfirmed change so it does not trigger a restart next time.
if [ -z "$selected" ]; then
  rm -f "$pending_file"
  exec "$systemctl" stop "$unit"
fi

tmp=$runtime_dir/.proxy-host.$$
printf '%s\n' "$selected" >"$tmp"
mv -f "$tmp" "$host_file"

running=0
if "$systemctl" is-active --quiet "$unit"; then
  running=1
fi

if [ "$running" -eq 0 ]; then
  rm -f "$pending_file"
  exec "$systemctl" start "$unit"
fi

# The host the running tunnel actually dials: its generated config, not the
# host file, which may already carry a candidate that is not confirmed yet.
current=
if [ -r "$config_file" ]; then
  current=$(python3 - "$config_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
except (OSError, ValueError):
    raise SystemExit(0)
for outbound in config.get("outbounds", []):
    if outbound.get("tag") == "phone":
        sys.stdout.write(outbound.get("server", ""))
        break
PY
  )
fi

if [ "$selected" = "$current" ]; then
  rm -f "$pending_file"
  exit 0
fi

# A change is only acted on once the next tick chooses the same host.
pending=$(cat "$pending_file" 2>/dev/null || true)
if [ "$pending" = "$selected" ]; then
  rm -f "$pending_file"
  exec "$systemctl" restart "$unit"
fi
printf '%s\n' "$selected" >"$pending_file"
