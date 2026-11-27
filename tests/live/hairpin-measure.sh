#!/usr/bin/env bash
# Measure the AP hairpin before and after #43/#44/#46 land.
#
#   tests/live/hairpin-measure.sh --check
#   tests/live/hairpin-measure.sh --dry-run
#   sudo tests/live/hairpin-measure.sh --mode before
#   sudo tests/live/hairpin-measure.sh --mode after
#   sudo tests/live/hairpin-measure.sh --mode after --fallback
#   sudo tests/live/hairpin-measure.sh --mode after --bootstrap
#   tests/live/hairpin-measure.sh --compare result-live/hairpin-... result-live/hairpin-...
#
# The runbook is docs/hairpin-measure.md; this file is the measurement, not the
# enablement.  A run does not add forwarding, NAT or DHCP options: it reads the
# feature that is already live, and leaves every network setting as it found it.
# The one exception is --fallback, which needs #46 and is explicit: it stops the
# tunnel (and its 5 s toggle timer) and restores both with a trap.
#
# What is measured:
#   - phone ICMP, TCP :443 and an 8 MB HTTP transfer, direct cellular in the
#     "before" run and through the hairpin in the "after" run.  The phone has
#     nc/toybox/ping and no curl, so an HTTPS *request* is recorded only when a
#     TLS client is present; otherwise it is reported unavailable, not guessed.
#   - the laptop's 500 sequential and 200-at-40 soaks, plus 5 x 8 MB, through
#     the tunnel (default) or the SOCKS listener (--via socks).
#   - proxy client count every 5 s, the app's max_connections, phone battery
#     for 30 minutes (or --battery-minutes), and AP retry counters.
#   - phone + laptop at the same time (after only), fallback time (needs #46)
#     and bootstrap time from AP up to validation (needs #43/#44).
#
# Everything that cannot be measured yet is written as UNAVAILABLE with the
# issue that owns it.  Do not replace a missing number with a plausible one.
#
# Environment overrides (no secret is ever written to the repository):
#   PHONE_MEASURE_OUT              evidence directory (--out wins over it)
#   PHONE_MEASURE_HTTPS_HOST       HTTPS/TCP target (default speed.cloudflare.com)
#   PHONE_MEASURE_BYTES_URL       8 MB source (default plain HTTP from Cloudflare)
#   PHONE_MEASURE_BYTES            expected body size (default 8388608)
#   PHONE_MEASURE_SOAK_URL         laptop request URL (default https://example.com/)
#   PHONE_MEASURE_SEQ               sequential requests (default 500)
#   PHONE_MEASURE_PAR              concurrent requests (default 200)
#   PHONE_MEASURE_PAR_WORKERS      concurrency (default 40)
#   PHONE_MEASURE_LAPTOP_DOWNLOADS 8 MB downloads (default 5)
#   PHONE_MEASURE_PHONE_SAMPLES    phone latency samples (default 10)
#   PHONE_MEASURE_PHONE_DOWNLOADS  phone 8 MB downloads (default 3)
#   PHONE_MEASURE_BATTERY_MINUTES  monitoring window (default 30; 0 skips)
#   PHONE_MEASURE_VIA              tunnel or socks (default tunnel)
#   PHONE_MEASURE_FAILOPEN_UNIT    #46 unit to look for
#   PHONE_MEASURE_ALLOW_FALLBACK   1 also required for --fallback
#   PHONE_HAIRPIN_ACTIVE           1/0 overrides feature detection
#
# It is deliberately not named *.test.sh, so `nix flake check` never runs a
# measurement.  Its dry-run, self-test and compare paths need no phone or root;
# tests/hairpin-measure.test.sh exercises those in the flake.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN=$ROOT/bin
export PATH="$BIN:$PATH"
# shellcheck source=../../lib/phone-net.sh
. "$ROOT/lib/phone-net.sh"

ADB=${PHONE_MEASURE_ADB:-adb}
CURL=${PHONE_MEASURE_CURL:-curl}
IW=${PHONE_MEASURE_IW:-iw}
NFT=${PHONE_NFT:-${PHONE_MEASURE_NFT:-nft}}
SYSTEMCTL=${PHONE_MEASURE_SYSTEMCTL:-systemctl}
SUDO=${PHONE_MEASURE_SUDO:-sudo}
TIMEOUT=${PHONE_MEASURE_TIMEOUT:-timeout}

HTTPS_HOST=${PHONE_MEASURE_HTTPS_HOST:-speed.cloudflare.com}
HTTPS_PORT=${PHONE_MEASURE_HTTPS_PORT:-443}
BYTES_URL=${PHONE_MEASURE_BYTES_URL:-http://speed.cloudflare.com/__down?bytes=8388608}
BYTES_EXPECTED=${PHONE_MEASURE_BYTES:-8388608}
SOAK_URL=${PHONE_MEASURE_SOAK_URL:-https://example.com/}
SEQ=${PHONE_MEASURE_SEQ:-500}
PAR=${PHONE_MEASURE_PAR:-200}
PAR_WORKERS=${PHONE_MEASURE_PAR_WORKERS:-40}
LAPTOP_DOWNLOADS=${PHONE_MEASURE_LAPTOP_DOWNLOADS:-5}
PHONE_SAMPLES=${PHONE_MEASURE_PHONE_SAMPLES:-10}
PHONE_DOWNLOADS=${PHONE_MEASURE_PHONE_DOWNLOADS:-3}
BATTERY_MINUTES=${PHONE_MEASURE_BATTERY_MINUTES:-30}
VIA=${PHONE_MEASURE_VIA:-tunnel}
FAILOPEN_UNIT=${PHONE_MEASURE_FAILOPEN_UNIT:-phone-link-ap-failopen.service}
TOGGLE_TIMER=${PHONE_MEASURE_TOGGLE_TIMER:-phone-tun-toggle.timer}
AP_IF=${PHONE_AP_IF:-wlp110s0}
TUN_IF=${PHONE_MEASURE_TUN_IF:-phone-tun}

MODE=auto
RUN=0
DRY_RUN=0
CHECK=0
SELF_TEST=0
FALLBACK=0
BOOTSTRAP=0
COMPARE_BEFORE=
COMPARE_AFTER=
OUT=
SERIAL=
PHASE=
# Internal scratch/state; clear anything an inherited environment might carry,
# so --check or --dry-run can never remove or replace a caller's files/services.
WORK=
MONITOR_PID=
MONITOR_STOP=
FALLBACK_RESTORE=
FALLBACK_TIMER_WAS=0
FALLBACK_TUNNEL_WAS=0
STARTED_AT=$(date -u +%Y%m%dT%H%M%SZ)

usage() {
  cat <<'USAGE'
usage: tests/live/hairpin-measure.sh --check
       tests/live/hairpin-measure.sh --dry-run
       tests/live/hairpin-measure.sh --self-test
       tests/live/hairpin-measure.sh --compare BEFORE_DIR AFTER_DIR
       sudo tests/live/hairpin-measure.sh --mode before|after|auto [options]

  --check              print what this host and phone can measure; no writes
  --dry-run            print the plan and the commands; no phone, no root
  --self-test          exercise the parsers and summaries; no phone, no root
  --compare A B        render the before/after table from two evidence dirs
  --mode MODE          before (link-only, cellular default), after (hairpin),
                       or auto (hairpin active -> after, otherwise before)
  --out DIR            evidence directory (default result-live/hairpin-<UTC>)
  --via tunnel|socks   laptop requests through the TUN (default) or the
                       SOCKS listener (matches the older 500/200 numbers)
  --fallback           stop phone-tun and time the cellular fallback; needs
                       #46, root, hairpin active and PHONE_MEASURE_ALLOW_FALLBACK=1
  --bootstrap          time AP up -> AP validated; needs #43/#44 and live hairpin
  --battery-minutes N  monitoring window, 0 to skip the 30 minute wait
  --no-battery         same as --battery-minutes 0
  --no-shared          skip the phone+laptop concurrent 8 MB pair
  --quick              short smoke run: 20/20/2 requests, 2 minute window
  -h, --help           this text
USAGE
}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif have_cmd "$SUDO" && "$SUDO" -n true >/dev/null 2>&1; then
    "$SUDO" -n "$@"
  else
    return 1
  fi
}

while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --self-test) SELF_TEST=1 ;;
    --mode)
      shift
      [ $# -gt 0 ] || die "--mode needs before, after or auto"
      MODE=$1
      RUN=1
      ;;
    --out)
      shift
      [ $# -gt 0 ] || die "--out needs a directory"
      OUT=$1
      ;;
    --via)
      shift
      [ $# -gt 0 ] || die "--via needs tunnel or socks"
      VIA=$1
      ;;
    --fallback) FALLBACK=1; RUN=1 ;;
    --bootstrap) BOOTSTRAP=1; RUN=1 ;;
    --battery-minutes)
      shift
      [ $# -gt 0 ] || die "--battery-minutes needs a number"
      BATTERY_MINUTES=$1
      ;;
    --no-battery) BATTERY_MINUTES=0 ;;
    --no-shared) SHARED=0 ;;
    --quick)
      SEQ=20
      PAR=20
      PAR_WORKERS=10
      LAPTOP_DOWNLOADS=2
      PHONE_SAMPLES=3
      PHONE_DOWNLOADS=1
      BATTERY_MINUTES=2
      ;;
    --compare)
      shift
      [ $# -ge 2 ] || die "--compare needs BEFORE_DIR AFTER_DIR"
      COMPARE_BEFORE=$1
      COMPARE_AFTER=$2
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

# --out wins over the environment; the environment wins over the timestamped
# default.  This is also the path --dry-run reports.
OUT=${OUT:-${PHONE_MEASURE_OUT:-}}
SHARED=${SHARED:-1}
case $MODE in before|after|auto) ;; *) die "--mode must be before, after or auto" ;; esac
case $VIA in tunnel|socks) ;; *) die "--via must be tunnel or socks" ;; esac
case $BATTERY_MINUTES in '' | *[!0-9]*) die "--battery-minutes must be a non-negative integer" ;; esac

now_ms() { date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))'; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- URL parsing, used by the phone's nc fetch and by the self-test ---------
# Only http:// URLs without userinfo or a query comma are accepted; the phone
# side is a shell string, so a URL that cannot be made plain is refused.
parse_url() { # URL -> sets URL_HOST URL_PORT URL_PATH; false when unusable
  local url=$1 rest hostport path
  URL_HOST='' URL_PORT='' URL_PATH=''
  case $url in
    http://*) rest=${url#http://} ;;
    *) return 1 ;;
  esac
  case $rest in
    *[[:space:]]* | *@*) return 1 ;;
  esac
  hostport=${rest%%/*}
  if [ "$hostport" = "$rest" ]; then
    path=/
  else
    path=/${rest#*/}
  fi
  hostport=${hostport%%\?*}
  case $hostport in
    *:*) URL_HOST=${hostport%:*}; URL_PORT=${hostport##*:} ;;
    *) URL_HOST=$hostport; URL_PORT=80 ;;
  esac
  URL_PATH=$path
  case $URL_HOST in '' | *[!A-Za-z0-9.-]*) return 1 ;; esac
  case $URL_PORT in '' | *[!0-9]*) return 1 ;; esac
  case $URL_PATH in *"'"* | *'"'* | *'$'* | *'`'* | *\\* | *';'* | *' '* | *$'\n'*) return 1 ;; esac
  [ "$URL_PORT" -ge 1 ] && [ "$URL_PORT" -le 65535 ]
}

# --- statistics -------------------------------------------------------------
# stdin: one number per line, unsorted.  Output is one stable line so the
# summary and the compare table can use the same numbers.
stats() {
  sort -n | awk '
    { v[NR] = $1; sum += $1 }
    END {
      if (NR == 0) { print "n=0"; exit }
      p = int((NR * 95 + 99) / 100)
      if (p < 1) p = 1
      if (p > NR) p = NR
      med = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
      printf "n=%d min=%.3f median=%.3f p95=%.3f max=%.3f mean=%.3f", \
        NR, v[1], med, v[p], v[NR], sum / NR
    }
  '
}

# The phone's clock gives nanoseconds.  Keep that raw value (no lossy ms
# rounding) and convert to Mbit/s in one place, so the same arithmetic is used
# for the standalone phone download and the shared pair.
mbps_from_ns() { # bytes nanoseconds -> Mbit/s
  awk -v b="${1:-0}" -v ns="${2:-0}" 'BEGIN {
    if (ns > 0) printf "%.2f", (b * 8 * 1000) / ns
    else print "0"
  }'
}

# --- proxy state parsing ----------------------------------------------------
# The app prints one `running` line per listener, each with its own client
# count, plus counters.  Sum the clients, because the ceiling is shared.
parse_clients() {
  awk '
    /running/ {
      line = $0
      if (match(line, /[0-9]+ clients?/)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/ .*/, "", s)
        total += s
      }
    }
    END { print total + 0 }
  '
}

parse_max_connections() {
  sed -n 's/^[[:space:]]*max_connections[[:space:]]*//p' | head -1
}

parse_ping_times() {
  sed -n 's/.*time=\([0-9.][0-9.]*\) ms.*/\1/p'
}

# --- feature detection ------------------------------------------------------
# These are read-only.  A missing nft or an unprivileged caller reports
# "unknown", which later becomes UNAVAILABLE rather than a made-up number.
HAIRPIN_FORWARD=unknown
HAIRPIN_NAT=unknown
HAIRPIN_DHCP=unknown
AP_VALIDATED=unknown
DEFAULT_TRANSPORT=unknown
AP_NETID=
DEFAULT_NETID=
AP_CREATED_MS=
AP_FIRST_VALIDATED_MS=
TEMP_DISABLED=unknown

rules_have_forward() {
  # Any scoped client accept in the AP table is the feature; forwardClient is
  # configurable and defaults to the proxy host, but detection must not assume
  # it stayed at that address.
  grep -Eq 'ip saddr [0-9.]+ accept' 2>/dev/null
}

rules_have_hairpin_nat() {
  awk '
    /table ip phone_link_hairpin/ { table = 1 }
    table && /masquerade/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

detect_network() {
  local rules psout dump line wifi nc dline
  AP_VALIDATED=unknown
  DEFAULT_TRANSPORT=unknown
  AP_NETID='' DEFAULT_NETID='' AP_CREATED_MS='' AP_FIRST_VALIDATED_MS='' TEMP_DISABLED=unknown
  if [ -n "${PHONE_HAIRPIN_ACTIVE:-}" ]; then
    case $PHONE_HAIRPIN_ACTIVE in
      0) HAIRPIN_FORWARD=no; HAIRPIN_NAT=no ;;
      1) HAIRPIN_FORWARD=yes; HAIRPIN_NAT=yes ;;
    esac
  fi
  if have_cmd "$NFT"; then
    if rules=$(as_root "$NFT" list ruleset 2>/dev/null); then
      if printf '%s\n' "$rules" | rules_have_forward; then
        HAIRPIN_FORWARD=yes
      else
        HAIRPIN_FORWARD=no
      fi
      if printf '%s\n' "$rules" | rules_have_hairpin_nat; then
        HAIRPIN_NAT=yes
      else
        HAIRPIN_NAT=no
      fi
    fi
  fi
  if have_cmd ps; then
    psout=$(ps -eo args= 2>/dev/null || true)
    case $psout in
      *"--interface=$AP_IF"*'option:router,'*) HAIRPIN_DHCP=yes ;;
      *"--interface=$AP_IF"*) HAIRPIN_DHCP=no ;;
    esac
  fi
  [ -n "$SERIAL" ] || return 0
  dump=$("$ADB" -s "$SERIAL" shell dumpsys connectivity 2>/dev/null) || return 0
  DEFAULT_NETID=$(printf '%s\n' "$dump" | sed -n 's/^Active default network: \([0-9][0-9]*\).*/\1/p' | head -1)
  line=$(printf '%s\n' "$dump" | grep -F 'InterfaceName: wlan0' |
    grep -F "SSID: \"$PHONE_AP_SSID\"" | head -1)
  if [ -n "$line" ]; then
    AP_NETID=$(printf '%s\n' "$line" | sed -n 's/.*network{\([0-9][0-9]*\)}.*/\1/p')
    AP_CREATED_MS=$(printf '%s\n' "$line" |
      sed -n 's/.* created \([0-9][0-9]*\) firstValidated.*/\1/p')
    AP_FIRST_VALIDATED_MS=$(printf '%s\n' "$line" |
      sed -n 's/.* firstValidated \([0-9][0-9]*\).*/\1/p')
    nc=$(printf '%s\n' "$line" | grep -o 'nc{[^}]*}' | head -1)
    case $nc in
      *VALIDATED*) AP_VALIDATED=yes ;;
      *) AP_VALIDATED=no ;;
    esac
  else
    AP_VALIDATED=no
  fi
  if [ -n "$DEFAULT_NETID" ]; then
    if [ "$DEFAULT_NETID" = "$AP_NETID" ]; then
      DEFAULT_TRANSPORT='wifi-ap'
    else
      dline=$(printf '%s\n' "$dump" | grep -F "network{$DEFAULT_NETID}" | head -1)
      case $dline in
        *'Transports: CELLULAR'*) DEFAULT_TRANSPORT=cellular ;;
        *'Transports: USB'*) DEFAULT_TRANSPORT=usb ;;
        *'Transports: WIFI'*) DEFAULT_TRANSPORT='wifi-other' ;;
        *'Transports: ETHERNET'*) DEFAULT_TRANSPORT=ethernet ;;
      esac
    fi
  fi
  wifi=$("$ADB" -s "$SERIAL" shell dumpsys wifi 2>/dev/null |
    grep -E 'TEMPORARY_DISABLED|NO_INTERNET' | head -1)
  if [ -n "$wifi" ]; then TEMP_DISABLED=yes; else TEMP_DISABLED=no; fi
}

# Hairpin is considered live when the scoped forwarding rule is present and
# either the NAT table exists (the contract in #42) or Android has validated
# the AP.  A manual override wins, because detection is unprivileged in --check.
hairpin_live() {
  case ${PHONE_HAIRPIN_ACTIVE:-} in
    0) return 1 ;;
    1) return 0 ;;
  esac
  [ "$HAIRPIN_FORWARD" = yes ] || return 1
  [ "$HAIRPIN_NAT" = yes ] || [ "$AP_VALIDATED" = yes ]
}

fail_open_present() {
  case ${PHONE_MEASURE_FAILOPEN:-} in
    1) return 0 ;;
    0) return 1 ;;
  esac
  have_cmd "$SYSTEMCTL" || return 1
  "$SYSTEMCTL" list-unit-files --no-pager 2>/dev/null |
    grep -Fq "$FAILOPEN_UNIT" && return 0
  "$SYSTEMCTL" cat "$FAILOPEN_UNIT" >/dev/null 2>&1
}

tunnel_active() {
  have_cmd "$SYSTEMCTL" &&
    "$SYSTEMCTL" is-active --quiet phone-tun.service 2>/dev/null
}

tunnel_route() {
  ip route get 1.1.1.1 2>/dev/null | grep -Fq "$TUN_IF"
}

# --- evidence ---------------------------------------------------------------
prepare_out() {
  if [ -z "$OUT" ]; then
    OUT=$ROOT/result-live/hairpin-$STARTED_AT
  fi
  mkdir -p "$OUT" || die "cannot create $OUT"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/hairpin-measure.XXXXXX") || die "mktemp failed"
  : >"$OUT/results.csv"
  : >"$OUT/phone-latency.csv"
  : >"$OUT/phone-download.csv"
  : >"$OUT/phone-state.csv"
  : >"$OUT/laptop-soak-seq.csv"
  : >"$OUT/laptop-soak-par.csv"
  : >"$OUT/laptop-download.csv"
  : >"$OUT/proxy-samples.csv"
  : >"$OUT/battery.csv"
  : >"$OUT/ap-samples.csv"
  : >"$OUT/shared.csv"
  : >"$OUT/fallback.csv"
  : >"$OUT/bootstrap.csv"
  printf 'metric,value,state,evidence\n' >>"$OUT/results.csv"
  printf 'epoch,phase,ap_validated,default_transport,temp_disabled,ap_netid,default_netid,ap_created_ms,ap_first_validated_ms\n' \
    >>"$OUT/phone-state.csv"
  printf 'epoch,phase,clients,max_connections,state\n' >>"$OUT/proxy-samples.csv"
  printf 'epoch,phase,level,status,usb,ac,wireless,temp,voltage\n' >>"$OUT/battery.csv"
  printf 'epoch,tx_bytes,rx_bytes,tx_packets,tx_retries,tx_failed,signal,tx_bitrate,rx_bitrate,connected_s\n' \
    >>"$OUT/ap-samples.csv"
  printf 'phase,via,url,i,code,time\n' >>"$OUT/laptop-soak-seq.csv"
  printf 'phase,via,url,i,code,time\n' >>"$OUT/laptop-soak-par.csv"
  printf 'phase,via,url,i,code,time,bytes,expected\n' >>"$OUT/laptop-download.csv"
  printf 'phase,phone_bytes,phone_ns,phone_mbps,laptop_code,laptop_time,laptop_bytes,laptop_mbps\n' \
    >>"$OUT/shared.csv"
  printf 'phase,start_ms,end_ms,delta_ms,ap_validated_after,default_after,timer_was_active\n' \
    >>"$OUT/fallback.csv"
  printf 'phase,source,seconds,ap_up_age_s,failed_probes,temp_disabled,ap_first_validated_ms\n' \
    >>"$OUT/bootstrap.csv"
  printf '%s\n' "$PHASE" >"$OUT/phase"
  {
    printf 'started=%s\n' "$(utc_now)"
    printf 'phase=%s\n' "$PHASE"
    printf 'mode=%s\n' "$MODE"
    printf 'via=%s\n' "$VIA"
    printf 'host=%s\n' "$(hostname 2>/dev/null || true)"
    printf 'serial=%s\n' "${SERIAL:-}"
    printf 'ap_if=%s\n' "$AP_IF"
    printf 'proxy_host=%s\n' "$PHONE_PROXY_HOST"
    printf 'proxy_port=%s\n' "$PHONE_PROXY_PORT"
    printf 'proxy_pkg=%s\n' "$PHONE_PROXY_PKG"
  } >"$OUT/meta.env"
}

cleanup() {
  if [ -n "${FALLBACK_RESTORE:-}" ]; then
    restore_after_fallback
  fi
  [ -n "${MONITOR_PID:-}" ] && kill "$MONITOR_PID" 2>/dev/null
  [ -n "${MONITOR_PID:-}" ] && wait "$MONITOR_PID" 2>/dev/null
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

record() { # metric value state evidence
  printf '%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" >>"$OUT/results.csv"
}

unavailable() { # metric reason
  printf '%s,n/a,UNAVAILABLE (%s),-\n' "$1" "$2" >>"$OUT/results.csv"
  log "UNAVAILABLE $1: $2"
}

set_phase() {
  PHASE=$1
  printf '%s\n' "$PHASE" >"$OUT/phase"
}

# --- phone probes -----------------------------------------------------------
require_phone() {
  [ -n "$SERIAL" ] && return 0
  if ! have_cmd "$ADB"; then
    return 1
  fi
  SERIAL=$(phone_serial 2>/dev/null) || return 1
  export PHONE_SERIAL="$SERIAL"
  return 0
}

phone_reachable() { # TCP :443, the path the proxy can actually carry (no ICMP)
  "$ADB" -s "$SERIAL" shell \
    "nc -z -w 3 -4 ${PHONE_MEASURE_REACH_HOST:-1.1.1.1} 443 >/dev/null 2>&1" \
    >/dev/null 2>&1
}

phone_ping_series() { # host samples -> one RTT per line
  local host=$1 samples=$2 out times
  out=$("$ADB" -s "$SERIAL" shell \
    "ping -c $samples -i 0.2 -W 2 $host" 2>/dev/null) || true
  times=$(printf '%s\n' "$out" | parse_ping_times)
  [ -n "$times" ] || return 1
  printf '%s\n' "$times"
}

phone_tcp443_series() { # host samples
  local host=$1 samples=$2 i rc value out
  for i in $(seq 1 "$samples"); do
    out=$("$ADB" -s "$SERIAL" shell \
      "s=\$(date +%s%N); nc -z -w 5 -4 $host $HTTPS_PORT >/dev/null 2>&1; r=\$?; e=\$(date +%s%N); echo \$r \$((e-s))" \
      2>/dev/null) || out="1 0"
    rc=${out%% *}
    value=${out#* }
    case $rc in 0) printf '%s\n' "$((value / 1000000))" ;; *) return 1 ;; esac
  done
}

phone_https_series() { # host samples, only when the phone has curl
  local host=$1 samples=$2 i code time out
  for i in $(seq 1 "$samples"); do
    out=$("$ADB" -s "$SERIAL" shell \
      "curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 https://$host/ 2>/dev/null" \
      2>/dev/null) || return 1
    code=${out%% *}
    time=${out#* }
    [ "$code" = 200 ] || return 1
    awk -v t="$time" 'BEGIN { printf "%.0f\n", t * 1000 }'
  done
}

# Fetch the 8 MB body with the phone's nc.  A host FIFO keeps the phone's stdin
# open until the server closes, so nc does not send FIN before the response;
# nothing is written to the phone.  The second field is the phone's own
# nanosecond delta; mbps_from_ns is the only place it becomes a rate.
phone_fetch_bytes() { # host port path timeout_s -> "bytes ns"
  local host=$1 port=$2 path=$3 timeout_s=$4
  local fifo=$WORK/phone-in.$$ out=$WORK/phone-out.$$ pid n ns
  rm -f "$fifo"
  mkfifo "$fifo" || return 1
  : >"$out"
  exec 9<>"$fifo" || { rm -f "$fifo"; return 1; }
  (
    "$TIMEOUT" $((timeout_s + 15)) "$ADB" -s "$SERIAL" shell \
      "s=\$(date +%s%N); n=\$(nc -4 -w $timeout_s -W $timeout_s $host $port | sed '1,/^\r\$/d' | wc -c); e=\$(date +%s%N); echo \$n \$((e-s))" \
      <"$fifo" >"$out" 2>/dev/null
  ) &
  pid=$!
  printf 'GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' \
    "$path" "$host" >&9 || true
  wait "$pid" 2>/dev/null
  exec 9>&-
  rm -f "$fifo"
  read -r n ns <"$out" || true
  rm -f "$out"
  case ${n:-} in '' | *[!0-9]*) return 1 ;; esac
  case ${ns:-} in '' | *[!0-9]*) return 1 ;; esac
  printf '%s %s\n' "$n" "$ns"
}

measure_phone() {
  local path=$1 target=$2 samples=$3 i value n ns mbps ok=1 out
  set_phase phone
  detect_network
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date +%s)" "$path" "$AP_VALIDATED" "$DEFAULT_TRANSPORT" "$TEMP_DISABLED" \
    "$AP_NETID" "$DEFAULT_NETID" "$AP_CREATED_MS" "$AP_FIRST_VALIDATED_MS" \
    >>"$OUT/phone-state.csv"

  # ICMP: the phone's own clock, one adb call for all samples.
  : >"$WORK/icmp"
  phone_ping_series "$target" "$samples" >>"$WORK/icmp" || true
  if [ -s "$WORK/icmp" ]; then
    i=0
    while IFS= read -r value; do
      i=$((i + 1))
      printf '%s,%s,icmp,%s,%s,1,%s\n' "$path" "$PHASE" "$target" "$i" "$value" \
        >>"$OUT/phone-latency.csv"
    done <"$WORK/icmp"
    record "phone_icmp_median_ms" "$(stats <"$WORK/icmp" | sed -n 's/.*median=\([0-9.]*\).*/\1/p')" measured "phone-latency.csv ($path)"
  else
    unavailable "phone_icmp_median_ms" "phone did not answer ping"
  fi

  # TCP :443: the closest thing to HTTPS latency this phone has without curl.
  : >"$WORK/tcp"
  if phone_tcp443_series "$target" "$samples" >"$WORK/tcp"; then
    i=0
    while IFS= read -r value; do
      i=$((i + 1))
      printf '%s,%s,tcp443,%s,%s,1,%s\n' "$path" "$PHASE" "$target" "$i" "$value" \
        >>"$OUT/phone-latency.csv"
    done <"$WORK/tcp"
    record "phone_tcp443_median_ms" "$(stats <"$WORK/tcp" | sed -n 's/.*median=\([0-9.]*\).*/\1/p')" measured "phone-latency.csv ($path)"
  else
    unavailable "phone_tcp443_median_ms" "phone could not open TCP $HTTPS_PORT"
  fi

  # A real HTTPS request needs a TLS client; this phone has none.
  if "$ADB" -s "$SERIAL" shell 'command -v curl >/dev/null 2>&1' 2>/dev/null; then
    : >"$WORK/https"
    if phone_https_series "$target" "$samples" >"$WORK/https"; then
      i=0
      while IFS= read -r value; do
        i=$((i + 1))
        printf '%s,%s,https,%s,%s,1,%s\n' "$path" "$PHASE" "$target" "$i" "$value" \
          >>"$OUT/phone-latency.csv"
      done <"$WORK/https"
      record "phone_https_median_ms" "$(stats <"$WORK/https" | sed -n 's/.*median=\([0-9.]*\).*/\1/p')" measured "phone-latency.csv ($path)"
    else
      unavailable "phone_https_median_ms" "phone curl did not complete"
    fi
  else
    unavailable "phone_https_median_ms" "phone has no curl/wget/openssl; ICMP and TCP :443 recorded instead"
  fi

  # 8 MB over HTTP through the same path.
  if parse_url "$BYTES_URL"; then
    : >"$WORK/downloads"
    for i in $(seq 1 "$PHONE_DOWNLOADS"); do
      if out=$(phone_fetch_bytes "$URL_HOST" "$URL_PORT" "$URL_PATH" 60); then
        n=${out%% *}
        ns=${out#* }
        mbps=$(mbps_from_ns "$n" "$ns")
        ok=0
        [ "$n" = "$BYTES_EXPECTED" ] && ok=1
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$path" "$PHASE" "$BYTES_URL" "$i" \
          "$ok" "$n" "$BYTES_EXPECTED" "$ns" "$mbps" >>"$OUT/phone-download.csv"
        record "phone_8mb_mbps_$i" "$mbps" measured "phone-download.csv ($path, $n/$BYTES_EXPECTED bytes)"
      else
        printf '%s,%s,%s,%s,0,0,%s,0,0\n' "$path" "$PHASE" "$BYTES_URL" "$i" \
          "$BYTES_EXPECTED" >>"$OUT/phone-download.csv"
        unavailable "phone_8mb_mbps_$i" "phone nc transfer failed"
      fi
    done
  else
    unavailable "phone_8mb_mbps" "PHONE_MEASURE_BYTES_URL is not a plain http:// URL"
  fi
}

# --- laptop probes ----------------------------------------------------------
proxy_password() {
  if [ -n "${PHONE_SOCKS_PASS:-}" ]; then
    printf '%s' "$PHONE_SOCKS_PASS"
  elif have_cmd sudo && [ -r "$PHONE_SECRETS" ]; then
    phone_proxy_pass 2>/dev/null || true
  else
    return 1
  fi
}

curl_request() { # url mode(short|download)
  local url=$1 mode=$2 pass max=30
  [ "$mode" = download ] && max=180
  local -a cmd=("$CURL" -4 -sS --max-time "$max" -o /dev/null)
  if [ "$mode" = download ]; then
    cmd+=(-w '%{http_code} %{time_total} %{size_download}')
  else
    cmd+=(-w '%{http_code} %{time_total}')
  fi
  if [ "$VIA" = socks ]; then
    pass=$(proxy_password) || return 1
    cmd+=(--socks5-hostname "$PHONE_PROXY_USER:$pass@$PHONE_PROXY_HOST:$PHONE_PROXY_PORT")
  fi
  cmd+=("$url")
  "${cmd[@]}"
}

measure_laptop_soak() {
  set_phase laptop
  if ! have_cmd "$CURL"; then
    unavailable "laptop_soak" "curl is not installed on the laptop"
    return
  fi
  if [ "$VIA" = tunnel ] && ! tunnel_route; then
    unavailable "laptop_soak" "1.1.1.1 does not resolve via $TUN_IF (tunnel down)"
    return
  fi
  if [ "$VIA" = socks ] && ! proxy_password >/dev/null; then
    unavailable "laptop_soak" "no proxy password in PHONE_SOCKS_PASS or $PHONE_SECRETS"
    return
  fi

  log "laptop soak: $SEQ sequential through $VIA"
  local i res code time
  for i in $(seq 1 "$SEQ"); do
    if res=$(curl_request "$SOAK_URL" short); then
      code=${res%% *}
      time=${res#* }
    else
      code=000
      time=0
    fi
    printf '%s,%s,%s,%s,%s,%s\n' "$PHASE" "$VIA" "$SOAK_URL" "$i" "$code" "$time" \
      >>"$OUT/laptop-soak-seq.csv"
  done
  local seq_fail seq_p95
  seq_fail=$(awk -F, 'NR > 1 && $5 != 200 { n++ } END { print n + 0 }' "$OUT/laptop-soak-seq.csv")
  seq_p95=$(awk -F, 'NR > 1 { print $6 }' "$OUT/laptop-soak-seq.csv" | stats |
    sed -n 's/.*p95=\([0-9.]*\).*/\1/p')
  record "laptop_seq_requests" "$SEQ" measured "laptop-soak-seq.csv"
  record "laptop_seq_failures" "$seq_fail" measured "laptop-soak-seq.csv"
  record "laptop_seq_p95_s" "$seq_p95" measured "laptop-soak-seq.csv"

  log "laptop soak: $PAR at concurrency $PAR_WORKERS through $VIA"
  local worker=$WORK/soak-worker
  cat >"$worker" <<'WORKER'
#!/usr/bin/env bash
set -u
idx=$1
out=$2
url=$3
via=$4
proxy=$5
curl_bin=$6
res=$("$curl_bin" -4 -sS --max-time 120 -o /dev/null \
  -w '%{http_code} %{time_total}' \
  ${proxy:+--socks5-hostname "$proxy"} "$url" 2>/dev/null) || res="000 0"
printf '%s %s %s\n' "$idx" "${res%% *}" "${res#* }" >>"$out"
WORKER
  chmod +x "$worker"
  : >"$WORK/par"
  local proxy='' code
  if [ "$VIA" = socks ]; then
    proxy="$PHONE_PROXY_USER:$(proxy_password)@$PHONE_PROXY_HOST:$PHONE_PROXY_PORT"
  fi
  seq 1 "$PAR" | xargs -P "$PAR_WORKERS" -I{} "$worker" {} "$WORK/par" \
    "$SOAK_URL" "$VIA" "$proxy" "$CURL"
  awk -v phase="$PHASE" -v via="$VIA" -v url="$SOAK_URL" \
    '{ printf "%s,%s,%s,%s,%s,%s\n", phase, via, url, $1, $2, $3 }' \
    "$WORK/par" >>"$OUT/laptop-soak-par.csv"
  local par_fail par_p95
  par_fail=$(awk -F, 'NR > 1 && $5 != 200 { n++ } END { print n + 0 }' "$OUT/laptop-soak-par.csv")
  par_p95=$(awk -F, 'NR > 1 { print $6 }' "$OUT/laptop-soak-par.csv" | stats |
    sed -n 's/.*p95=\([0-9.]*\).*/\1/p')
  record "laptop_par_requests" "$PAR" measured "laptop-soak-par.csv"
  record "laptop_par_failures" "$par_fail" measured "laptop-soak-par.csv"
  record "laptop_par_p95_s" "$par_p95" measured "laptop-soak-par.csv"

  log "laptop downloads: $LAPTOP_DOWNLOADS x 8 MB"
  local i n mbps
  for i in $(seq 1 "$LAPTOP_DOWNLOADS"); do
    if res=$(curl_request "$BYTES_URL" download); then
      code=${res%% *}
      time=${res#* }
      n=${time#* }
      time=${time%% *}
      mbps=$(awk -v b="$n" -v t="$time" 'BEGIN { if (t > 0) printf "%.2f", (b * 8) / t / 1000000; else print "0" }')
      printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$PHASE" "$VIA" "$BYTES_URL" "$i" "$code" \
        "$time" "$n" "$BYTES_EXPECTED" >>"$OUT/laptop-download.csv"
      record "laptop_8mb_mbps_$i" "$mbps" measured "laptop-download.csv ($n/$BYTES_EXPECTED bytes)"
    else
      printf '%s,%s,%s,%s,000,0,0,%s\n' "$PHASE" "$VIA" "$BYTES_URL" "$i" \
        "$BYTES_EXPECTED" >>"$OUT/laptop-download.csv"
      unavailable "laptop_8mb_mbps_$i" "laptop curl download failed"
    fi
  done
}

# --- proxy, battery and AP telemetry ---------------------------------------
proxy_dump() {
  "$ADB" -s "$SERIAL" shell dumpsys activity service \
    "$PHONE_PROXY_PKG/.ProxyService" 2>/dev/null
}

proxy_state_word() {
  case $1 in
    *"listening on"*) printf 'listening' ;;
    *"waiting"*) printf 'waiting' ;;
    *"paused"*) printf 'paused' ;;
    *) printf 'stopped' ;;
  esac
}

battery_sample() { # -> csv fields
  local dump level status usb ac wireless temp voltage
  dump=$("$ADB" -s "$SERIAL" shell dumpsys battery 2>/dev/null) || return 1
  level=$(printf '%s\n' "$dump" | sed -n 's/^ *level: //p' | head -1)
  status=$(printf '%s\n' "$dump" | sed -n 's/^ *status: //p' | head -1)
  temp=$(printf '%s\n' "$dump" | sed -n 's/^ *temperature: //p' | head -1)
  voltage=$(printf '%s\n' "$dump" | sed -n 's/^ *voltage: //p' | head -1)
  usb=no
  printf '%s\n' "$dump" | grep -q 'USB powered: true' && usb=yes
  ac=no
  printf '%s\n' "$dump" | grep -q 'AC powered: true' && ac=yes
  wireless=no
  printf '%s\n' "$dump" | grep -q 'Wireless powered: true' && wireless=yes
  printf '%s,%s,%s,%s,%s,%s,%s\n' "${level:-}" "${status:-}" "$usb" "$ac" \
    "$wireless" "${temp:-}" "${voltage:-}"
}

monitor_loop() { # runs until the stop file appears
  local stop=$1 phase='' state clients max stateword batt tick=0
  while [ ! -f "$stop" ]; do
    phase=$(cat "$OUT/phase" 2>/dev/null || true)
    state=$(proxy_dump 2>/dev/null || true)
    clients=$(printf '%s\n' "$state" | parse_clients)
    max=$(printf '%s\n' "$state" | parse_max_connections)
    if [ -z "$max" ]; then
      max=$("$ADB" -s "$SERIAL" shell cat \
        "/sdcard/Android/data/$PHONE_PROXY_PKG/files/state.txt" 2>/dev/null |
        tr -d '\r' | parse_max_connections)
    fi
    stateword=$(proxy_state_word "$state")
    printf '%s,%s,%s,%s,%s\n' "$(date +%s)" "${phase:-unknown}" \
      "${clients:-}" "${max:-}" "$stateword" >>"$OUT/proxy-samples.csv"
    if [ $((tick % 12)) -eq 0 ]; then
      batt=$(battery_sample 2>/dev/null || true)
      [ -n "$batt" ] && printf '%s,%s,%s\n' "$(date +%s)" "${phase:-unknown}" \
        "$batt" >>"$OUT/battery.csv"
    fi
    tick=$((tick + 1))
    sleep 5
  done
}

start_monitor() {
  MONITOR_STOP=$WORK/monitor.stop
  rm -f "$MONITOR_STOP"
  monitor_loop "$MONITOR_STOP" &
  MONITOR_PID=$!
}

stop_monitor() {
  [ -n "${MONITOR_STOP:-}" ] && : >"$MONITOR_STOP"
  if [ -n "${MONITOR_PID:-}" ]; then
    wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=
  fi
}

phone_cpu_snapshot() {
  "$ADB" -s "$SERIAL" shell "dumpsys cpuinfo 2>/dev/null | grep -F '$PHONE_PROXY_PKG'" \
    >"$1" 2>/dev/null || true
}

ap_sample() { # epoch -> append one row
  local epoch=$1 dump txb rxb txp txr txf sig txbr rxbr conn
  dump=$("$IW" dev "$AP_IF" station dump 2>/dev/null) || return 1
  printf '%s\n' "$dump" | grep -q '^Station' || return 1
  txb=$(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*tx bytes:[[:space:]]*//p' | head -1)
  rxb=$(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*rx bytes:[[:space:]]*//p' | head -1)
  txp=$(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*tx packets:[[:space:]]*//p' | head -1)
  txr=$(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*tx retries:[[:space:]]*//p' | head -1)
  txf=$(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*tx failed:[[:space:]]*//p' | head -1)
  sig=$(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*signal:[[:space:]]*//p' | head -1)
  txbr=$(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*tx bitrate:[[:space:]]*//p' | head -1)
  rxbr=$(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*rx bitrate:[[:space:]]*//p' | head -1)
  conn=$(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*connected time:[[:space:]]*//p' | head -1)
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$epoch" "${txb%% *}" \
    "${rxb%% *}" "${txp%% *}" "${txr%% *}" "${txf%% *}" "${sig%% *}" \
    "${txbr%% *}" "${rxbr%% *}" "${conn%% *}" >>"$OUT/ap-samples.csv"
}

# --- shared bottleneck ------------------------------------------------------
measure_shared() {
  [ "$SHARED" = 1 ] || return 0
  detect_network
  if ! hairpin_live || [ "$AP_VALIDATED" != yes ] || [ "$DEFAULT_TRANSPORT" != wifi-ap ]; then
    unavailable "shared_bottleneck" "needs #43/#44 (hairpin not live or the AP is not the phone's default)"
    return
  fi
  if ! have_cmd "$CURL"; then
    unavailable "shared_bottleneck" "curl is not installed on the laptop"
    return
  fi
  parse_url "$BYTES_URL" || {
    unavailable "shared_bottleneck" "PHONE_MEASURE_BYTES_URL is not a plain http:// URL"
    return
  }
  set_phase shared
  ap_sample "$(date +%s)" || true
  log "shared bottleneck: phone and laptop download 8 MB at the same time"
  (
    if phone_fetch_bytes "$URL_HOST" "$URL_PORT" "$URL_PATH" 90 >"$WORK/shared-phone"; then
      n=$(awk '{ print $1 }' "$WORK/shared-phone")
      ns=$(awk '{ print $2 }' "$WORK/shared-phone")
      mbps=$(mbps_from_ns "$n" "$ns")
      printf '%s %s %s\n' "$n" "$ns" "$mbps" >"$WORK/shared-phone.result"
    else
      printf '0 0 0\n' >"$WORK/shared-phone.result"
    fi
  ) &
  local ppid=$! res code time n mbps pn=0 pns=0 pmbps=0
  if res=$(curl_request "$BYTES_URL" download); then
    code=${res%% *}
    time=${res#* }
    n=${time#* }
    time=${time%% *}
    mbps=$(awk -v b="$n" -v t="$time" 'BEGIN { if (t > 0) printf "%.2f", (b * 8) / t / 1000000; else print "0" }')
  else
    code=000
    time=0
    n=0
    mbps=0
  fi
  wait "$ppid" 2>/dev/null || true
  if [ -s "$WORK/shared-phone.result" ]; then
    read -r pn pns pmbps <"$WORK/shared-phone.result" || true
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$PHASE" "${pn:-0}" "${pns:-0}" \
    "${pmbps:-0}" "$code" "$time" "${n:-0}" "${mbps:-0}" >>"$OUT/shared.csv"
  if [ "${pn:-0}" = "$BYTES_EXPECTED" ]; then
    record "shared_phone_mbps" "${pmbps:-0}" measured "shared.csv"
  else
    unavailable "shared_phone_mbps" "phone transfer was ${pn:-0}/$BYTES_EXPECTED bytes"
  fi
  record "shared_laptop_mbps" "${mbps:-0}" measured "shared.csv"
  ap_sample "$(date +%s)" || true
}

# --- fallback (#46) ---------------------------------------------------------
restore_after_fallback() {
  [ -n "${FALLBACK_RESTORE:-}" ] || return 0
  log "restoring phone-tun and its toggle timer"
  if [ "${FALLBACK_TIMER_WAS:-0}" = 1 ]; then
    as_root "$SYSTEMCTL" start "$TOGGLE_TIMER" >/dev/null 2>&1 || true
  fi
  if [ "${FALLBACK_TUNNEL_WAS:-0}" = 1 ]; then
    as_root "$SYSTEMCTL" start phone-tun.service >/dev/null 2>&1 || true
  fi
  FALLBACK_RESTORE=
}

measure_fallback() {
  detect_network
  if [ "${PHONE_MEASURE_ALLOW_FALLBACK:-0}" != 1 ]; then
    unavailable "fallback_seconds" "pass PHONE_MEASURE_ALLOW_FALLBACK=1 as well: this stops the tunnel"
    return
  fi
  if ! fail_open_present; then
    unavailable "fallback_seconds" "needs #46 (no $FAILOPEN_UNIT)"
    return
  fi
  if ! hairpin_live || [ "$AP_VALIDATED" != yes ] || [ "$DEFAULT_TRANSPORT" != wifi-ap ]; then
    unavailable "fallback_seconds" "needs #43/#44 (hairpin not live or the AP is not the phone's default)"
    return
  fi
  if ! tunnel_active; then
    unavailable "fallback_seconds" "phone-tun is not active, so there is no fallback to measure"
    return
  fi
  if ! as_root "$SYSTEMCTL" is-active --quiet phone-tun.service; then
    unavailable "fallback_seconds" "cannot stop phone-tun (run with sudo)"
    return
  fi
  set_phase fallback
  FALLBACK_RESTORE=1
  FALLBACK_TUNNEL_WAS=1
  FALLBACK_TIMER_WAS=0
  local timer_was=0 start t i ok=none
  if as_root "$SYSTEMCTL" is-active --quiet "$TOGGLE_TIMER"; then
    timer_was=1
    FALLBACK_TIMER_WAS=1
    as_root "$SYSTEMCTL" stop "$TOGGLE_TIMER" >/dev/null 2>&1 || true
  fi
  start=$(now_ms)
  as_root "$SYSTEMCTL" stop phone-tun.service >/dev/null 2>&1 || {
    unavailable "fallback_seconds" "could not stop phone-tun"
    restore_after_fallback
    return
  }
  for i in $(seq 1 90); do
    if phone_reachable; then
      ok=yes
      break
    fi
    sleep 1
  done
  t=$(now_ms)
  detect_network
  delta=-1
  [ "$ok" = yes ] && delta=$((t - start))
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$PHASE" "$start" "$t" \
    "$delta" "$AP_VALIDATED" "$DEFAULT_TRANSPORT" \
    "$timer_was" >>"$OUT/fallback.csv"
  if [ "$ok" = yes ]; then
    record "fallback_seconds" "$(awk -v m="$delta" 'BEGIN { printf "%.1f", m / 1000 }')" measured "fallback.csv"
  else
    unavailable "fallback_seconds" "no phone TCP :443 within 90 s"
  fi
  restore_after_fallback
}

# --- bootstrap (#43/#44) ----------------------------------------------------
measure_bootstrap() {
  if ! hairpin_live; then
    unavailable "bootstrap_seconds" "needs #43/#44 (hairpin not live)"
    return
  fi
  set_phase bootstrap
  local ap_epoch='' start t i fails=0 temp=unknown
  if have_cmd "$SYSTEMCTL"; then
    ap_epoch=$(date -d "$("$SYSTEMCTL" show -p ActiveEnterTimestamp --value \
      phone-link-ap-dhcp.service 2>/dev/null)" +%s 2>/dev/null || true)
  fi
  start=$(date +%s)
  for i in $(seq 1 120); do
    detect_network
    [ "$AP_VALIDATED" = yes ] && break
    if ! phone_reachable; then
      fails=$((fails + 1))
    fi
    sleep 1
  done
  t=$(date +%s)
  [ "$AP_VALIDATED" = yes ] || {
    unavailable "bootstrap_seconds" "AP not validated within 120 s"
    return
  }
  temp=$TEMP_DISABLED
  local age=-1 source=harness
  if [ -n "$ap_epoch" ] && [ "$t" -ge "$ap_epoch" ]; then
    age=$((t - ap_epoch))
    if [ "$age" -le 300 ]; then
      source=ap-up
    fi
  fi
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$PHASE" "$source" "$((t - start))" \
    "$age" "$fails" "$temp" "$AP_FIRST_VALIDATED_MS" >>"$OUT/bootstrap.csv"
  if [ "$source" = ap-up ]; then
    record "bootstrap_seconds" "$age" measured "bootstrap.csv (AP up to validated)"
  else
    record "bootstrap_seconds" "$((t - start))" measured "bootstrap.csv (harness start to validated; start soon after reboot)"
  fi
  record "bootstrap_harness_probe_failures" "$fails" measured "bootstrap.csv (this harness's reachability checks)"
  unavailable "bootstrap_android_probe_failures" "Android does not expose its own validation probe count in dumpsys"
  record "bootstrap_temporary_disable" "$temp" measured "bootstrap.csv"
}

# --- summary and compare ----------------------------------------------------
summary_value() { # metric
  awk -F, -v key="$1" 'NR > 1 && $1 == key { print $2; exit }' "$OUT/results.csv"
}

summary_state() {
  awk -F, -v key="$1" 'NR > 1 && $1 == key { print $3; exit }' "$OUT/results.csv"
}

has_rows() {
  [ -s "$1" ] && [ "$(awk 'END { print NR }' "$1")" -gt 1 ]
}

battery_summary() {
  local first last
  first=$(awk -F, 'NR == 2 { print $3 }' "$OUT/battery.csv")
  last=$(awk -F, 'END { print $3 }' "$OUT/battery.csv")
  if [ -n "$first" ] && [ -n "$last" ]; then
    printf '%s->%s' "$first" "$last"
  else
    printf 'n/a'
  fi
}

write_summary() {
  local peak=unknown max=unknown headroom=unknown charging=unknown
  if has_rows "$OUT/proxy-samples.csv"; then
    peak=$(awk -F, 'NR > 1 && $3 != "" { if ($3 + 0 > max) max = $3 + 0 } END { print max + 0 }' \
      "$OUT/proxy-samples.csv")
    max=$(awk -F, 'NR > 1 && $4 != "" { print $4; exit }' "$OUT/proxy-samples.csv")
    if [ -n "$max" ] && [ "$max" -gt 0 ] 2>/dev/null; then
      headroom=$((max - peak))
    fi
    record "proxy_peak_clients" "$peak" measured "proxy-samples.csv"
    record "proxy_max_connections" "${max:-unknown}" measured "proxy-samples.csv"
    record "proxy_connection_headroom" "$headroom" measured "proxy-samples.csv"
    local phase_peak
    for phase_peak in phone laptop shared; do
      if awk -F, -v p="$phase_peak" 'NR > 1 && $2 == p { found = 1 } END { exit found ? 0 : 1 }' \
        "$OUT/proxy-samples.csv"; then
        record "proxy_peak_clients_$phase_peak" \
          "$(awk -F, -v p="$phase_peak" 'NR > 1 && $2 == p && $3 != "" { if ($3 + 0 > m) m = $3 + 0 } END { print m + 0 }' \
            "$OUT/proxy-samples.csv")" measured "proxy-samples.csv ($phase_peak phase)"
      fi
    done
  else
    unavailable "proxy_peak_clients" "no proxy samples (the run stopped before monitoring)"
  fi
  if has_rows "$OUT/battery.csv"; then
    if awk -F, 'NR > 1 && ($5 == "yes" || $6 == "yes" || $7 == "yes") { n++ } END { exit n ? 0 : 1 }' \
      "$OUT/battery.csv"; then
      charging=yes
    else
      charging=no
    fi
    record "battery_level" "$(battery_summary)" "measured (charging=$charging)" "battery.csv"
  else
    unavailable "battery_level" "no battery samples (the run stopped before monitoring)"
  fi
  if has_rows "$OUT/ap-samples.csv"; then
    local pdelta rdelta fdelta rpct
    read -r pdelta rdelta fdelta rpct < <(
      awk -F, 'NR == 2 { p = $4; r = $5; f = $6 } END {
        p += 0; r += 0; f += 0
        printf "%d %d %d %.2f\n", $4 - p, $5 - r, $6 - f, (p > 0 ? (($5 - r) / p) * 100 : 0)
      }' "$OUT/ap-samples.csv"
    )
    record "ap_tx_packets_delta" "$pdelta" measured "ap-samples.csv"
    record "ap_tx_retries_delta" "$rdelta" measured "ap-samples.csv"
    record "ap_tx_retry_pct" "$rpct" measured "ap-samples.csv"
    record "ap_tx_failed_delta" "$fdelta" measured "ap-samples.csv"
  else
    unavailable "ap_tx_retries_delta" "no AP station samples (phone not associated during the run)"
  fi

  awk -F, 'NR > 1 { printf "| %s | %s | %s |\n", $1, $2, $3 }' "$OUT/results.csv" \
    >"$WORK/results.rows"
  {
    printf '# Hairpin measurement — %s\n\n' "$PHASE"
    printf 'Started %s. Evidence: `%s`.\n\n' "$(utc_now)" "$OUT"
    printf '| measurement | value | state |\n|---|---|---|\n'
    cat "$WORK/results.rows"
    printf '\n## Proxy and battery\n\n'
    printf '| measurement | value | note |\n|---|---|---|\n'
    printf '| peak proxy clients | %s | sampled every 5 s |\n' "$peak"
    printf '| max_connections | %s | from the app state |\n' "${max:-unknown}"
    printf '| connection headroom | %s | max_connections minus peak |\n' "$headroom"
    printf '| battery level | %s | percent |\n' "$(battery_summary)"
    printf '| charging during run | %s | a level delta is not a battery number while charging |\n' "$charging"
    printf '\n## AP telemetry\n\n```\n'
    cat "$OUT/ap-samples.csv"
    printf '```\n\n## Unavailable until the feature lands\n\n'
    awk -F, 'NR > 1 && $3 ~ /^UNAVAILABLE/ { printf "- **%s** — %s\n", $1, $3 }' \
      "$OUT/results.csv"
    if ! awk -F, 'NR > 1 && $3 ~ /^UNAVAILABLE/ { found = 1 } END { exit found ? 0 : 1 }' \
      "$OUT/results.csv"; then
      printf '_None._\n'
    fi
    printf '\n## Reproduce\n\n```sh\ntests/live/hairpin-measure.sh --compare BEFORE_DIR AFTER_DIR\n```\n'
  } >"$OUT/summary.md"
  printf '\nsummary: %s\n' "$OUT/summary.md" >&2
}

compare() {
  local before=$1 after=$2 key bv av bs as
  [ -r "$before/results.csv" ] || die "no results.csv in $before"
  [ -r "$after/results.csv" ] || die "no results.csv in $after"
  printf '| measurement | before | after |\n|---|---|---|\n'
  {
    awk -F, 'NR > 1 { print $1 }' "$before/results.csv"
    awk -F, 'NR > 1 { print $1 }' "$after/results.csv"
  } | awk '!seen[$0]++' | while IFS= read -r key; do
    bv=$(awk -F, -v k="$key" 'NR > 1 && $1 == k { print $2; exit }' "$before/results.csv")
    av=$(awk -F, -v k="$key" 'NR > 1 && $1 == k { print $2; exit }' "$after/results.csv")
    bs=$(awk -F, -v k="$key" 'NR > 1 && $1 == k { print $3; exit }' "$before/results.csv")
    as=$(awk -F, -v k="$key" 'NR > 1 && $1 == k { print $3; exit }' "$after/results.csv")
    [ -n "$bv" ] || bv='—'
    [ -n "$av" ] || av='—'
    case $bs in UNAVAILABLE*) bv=$bs ;; esac
    case $as in UNAVAILABLE*) av=$as ;; esac
    printf '| %s | %s | %s |\n' "$key" "$bv" "$av"
  done
}

# --- check, dry run and self test ------------------------------------------
check_prereqs() {
  printf 'hairpin measurement check\n'
  printf '  root: %s\n' "$(id -u)"
  for c in "$ADB" "$CURL" "$IW" "$NFT" "$SYSTEMCTL" "$TIMEOUT"; do
    if have_cmd "$c"; then
      printf '  tool: %-12s %s\n' "${c##*/}" "yes"
    else
      printf '  tool: %-12s %s\n' "${c##*/}" "NO"
    fi
  done
  printf '  proxy: %s:%s (%s)\n' "$PHONE_PROXY_HOST" "$PHONE_PROXY_PORT" "$PHONE_PROXY_PKG"
  printf '  AP: %s %s\n' "$AP_IF" "$PHONE_AP_SSID"
  printf '  tunnel: %s\n' "$(tunnel_active && printf active || printf inactive)"
  printf '  tunnel route: %s\n' "$(tunnel_route && printf yes || printf no)"
  if require_phone; then
    printf '  phone: %s\n' "$SERIAL"
    detect_network
    printf '  hairpin: forward=%s nat=%s dhcp=%s ap_validated=%s\n' \
      "$HAIRPIN_FORWARD" "$HAIRPIN_NAT" "$HAIRPIN_DHCP" "$AP_VALIDATED"
    printf '  default network: %s\n' "$DEFAULT_TRANSPORT"
    printf '  proxy listener: %s\n' "$(proxy_state_word "$(proxy_dump 2>/dev/null || true)")"
    if "$ADB" -s "$SERIAL" shell 'command -v curl >/dev/null 2>&1' 2>/dev/null; then
      printf '  phone TLS client: yes\n'
    else
      printf '  phone TLS client: no (HTTPS request latency unavailable)\n'
    fi
    printf '  fail-open (#46): %s\n' "$(fail_open_present && printf present || printf absent)"
  else
    printf '  phone: none (dry-run and self-test still work)\n'
    printf '  phone TLS client: unknown (no phone)\n'
  fi
  printf '\navailability\n'
  if [ "$HAIRPIN_FORWARD" = yes ] && { [ "$HAIRPIN_NAT" = yes ] || [ "$AP_VALIDATED" = yes ]; }; then
    printf '  hairpin metrics: yes\n'
  else
    printf '  hairpin metrics: UNAVAILABLE (needs #43/#44; no scoped forward/NAT/validated AP)\n'
  fi
  printf '  phone 8 MB: yes when adb and nc are present\n'
  printf '  phone HTTPS request: only with a TLS client on the phone\n'
  printf '  laptop soak: %s\n' "$(have_cmd "$CURL" && printf yes || printf 'UNAVAILABLE (no curl)')"
  printf '  proxy peak + battery: yes when adb is present\n'
  printf '  fallback: %s\n' "$(fail_open_present && printf 'yes (needs #46 + --fallback)' || printf 'UNAVAILABLE (needs #46)')"
  printf '  bootstrap: %s\n' "$([ "$HAIRPIN_FORWARD" = yes ] && printf yes || printf 'UNAVAILABLE (needs #43/#44)')"
}

dry_run_plan() {
  local mode=$MODE
  [ "$mode" = auto ] && mode='before or after (decided by read-only feature detection)'
  cat <<EOF
hairpin measurement dry run — nothing is executed and no network is read

phase: $mode
evidence: ${OUT:-result-live/hairpin-<UTC>}
laptop requests: $VIA, $SOAK_URL
8 MB source: $BYTES_URL ($BYTES_EXPECTED bytes)

1. feature detection (read-only): nft forward accept + phone_link_hairpin NAT,
   dumpsys connectivity AP VALIDATED, DHCP router/DNS, fail-open unit.
   after mode with no hairpin -> all hairpin numbers are UNAVAILABLE (#43/#44).
2. phone, "before" = direct cellular / "after" = hairpin:
   ping $PHONE_SAMPLES x $HTTPS_HOST (ICMP)
   $PHONE_SAMPLES x TCP :$HTTPS_PORT on the same target
   HTTPS request only if the phone has curl (otherwise UNAVAILABLE)
   $PHONE_DOWNLOADS x 8 MB over HTTP with nc, body bytes counted on the phone
3. laptop:
   $SEQ sequential + $PAR at concurrency $PAR_WORKERS through $VIA
   $LAPTOP_DOWNLOADS x 8 MB, exact size from curl
4. proxy: client count every 5 s, max_connections, CPU snapshot
   battery: $BATTERY_MINUTES minutes (0 skips), level/temperature/charging state
   AP: iw station dump before/after, retries and failed frames as deltas
5. shared (after only): phone and laptop 8 MB at the same time
6. fallback (only with --fallback): requires #46, root, PHONE_MEASURE_ALLOW_FALLBACK=1;
   stops the toggle timer then phone-tun, times the first phone TCP :443 success, restores both
7. bootstrap (only with --bootstrap): requires #43/#44; waits for the AP to be
   VALIDATED, reports AP-up age and whether Android set TEMPORARY_DISABLED

Unavailable today (not measured, not guessed):
- hairpin phone latency/throughput, shared bottleneck, bootstrap: needs #43/#44
- fallback: needs #46
- HTTPS request latency: the phone has nc/toybox/ping and no curl, so only
  ICMP and TCP :443 are measured unless a TLS client is present
EOF
}

self_test() {
  local pass=0 fail=0 out got
  ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$*"; }
  bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }

  out=$(stats <<'EOF'
5
1
3
2
4
EOF
)
  case $out in *'n=5'*'median=3.000'*'p95=5.000'*) ok "stats median and p95" ;; *) bad "stats median and p95 ($out)" ;; esac

  got=$(mbps_from_ns 8388608 600751000)
  [ "$got" = 111.71 ] && ok "mbps_from_ns 600751000 ns = 111.71 Mbps" \
    || bad "mbps_from_ns 600751000 ns (got $got)"
  got=$(mbps_from_ns 8388608 1255250692)
  [ "$got" = 53.46 ] && ok "mbps_from_ns 1255250692 ns = 53.46 Mbps" \
    || bad "mbps_from_ns 1255250692 ns (got $got)"
  got=$(mbps_from_ns 0 0)
  [ "$got" = 0 ] && ok "mbps_from_ns zero duration is not a rate" \
    || bad "mbps_from_ns zero duration (got $got)"

  got=$(printf '%s\n' \
    '  running     port 1081 · ↓ 1.0 MB · ↑ 1.0 MB · 32 clients' \
    '  running     port 1082 · ↓ 0.0 MB · ↑ 0.0 MB · 5 clients' | parse_clients)
  [ "$got" = 37 ] && ok "proxy client counts are summed" || bad "proxy client counts ($got)"

  got=$(printf 'max_connections 256\nport 1081\n' | parse_max_connections)
  [ "$got" = 256 ] && ok "max_connections parses" || bad "max_connections ($got)"

  got=$(printf '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=14.5 ms\n' | parse_ping_times)
  [ "$got" = 14.5 ] && ok "ping time parses" || bad "ping time ($got)"

  if parse_url 'http://speed.cloudflare.com/__down?bytes=8388608'; then
    [ "$URL_HOST" = speed.cloudflare.com ] && [ "$URL_PORT" = 80 ] &&
      [ "$URL_PATH" = '/__down?bytes=8388608' ] &&
      ok "URL host/port/path parse" || bad "URL parse ($URL_HOST $URL_PORT $URL_PATH)"
  else
    bad "URL parse rejected a good URL"
  fi
  parse_url 'https://example.com/' && bad "https URL should be rejected for nc" ||
    ok "https URL is rejected for the nc path"
  parse_url 'http://example.com/x;rm' && bad "semicolon URL should be rejected" ||
    ok "unsafe URL is rejected"

  got=$(printf 'table ip phone_link_hairpin {\n chain postrouting { masquerade }\n}\n' | rules_have_hairpin_nat && printf yes || printf no)
  [ "$got" = yes ] && ok "hairpin NAT rule parses" || bad "hairpin NAT rule"

  got=$(printf 'table inet phone_link_ap {\n iifname "wlp110s0" ip saddr 192.168.77.232 accept\n}\n' | rules_have_forward && printf yes || printf no)
  [ "$got" = yes ] && ok "scoped forward rule parses" || bad "scoped forward rule"

  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

# --- main -------------------------------------------------------------------
if [ "$SELF_TEST" = 1 ]; then
  self_test
  exit $?
fi

if [ -n "$COMPARE_BEFORE" ]; then
  compare "$COMPARE_BEFORE" "$COMPARE_AFTER"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  dry_run_plan
  exit 0
fi

if [ "$CHECK" = 1 ]; then
  check_prereqs
  exit 0
fi

if [ "$RUN" = 0 ]; then
  usage >&2
  exit 2
fi

require_phone || die "no phone attached (see adb devices), or use --check/--dry-run"
OUT=${OUT:-$ROOT/result-live/hairpin-$STARTED_AT}
prepare_out
set_phase setup
detect_network

if [ "$MODE" = auto ]; then
  if hairpin_live; then MODE=after; else MODE=before; fi
fi
PHASE=$MODE
set_phase "$PHASE"
printf 'phase=%s\nmode=%s\n' "$MODE" "$MODE" >>"$OUT/meta.env"
if [ "$MODE" = after ] && ! hairpin_live; then
  unavailable "hairpin" "needs #43/#44 (no scoped forward/NAT; set PHONE_HAIRPIN_ACTIVE=1 only if the rules really are)"
  write_summary
  log "nothing hairpin-shaped was measured; falling back to the before run is safe"
  exit 2
fi
if [ "$MODE" = after ] && [ "$BOOTSTRAP" != 1 ] &&
  { [ "$AP_VALIDATED" != yes ] || [ "$DEFAULT_TRANSPORT" != wifi-ap ]; }; then
  unavailable "hairpin" "needs #43/#44 (the AP is not validated and the phone's default; use --bootstrap only for the boot measurement)"
  write_summary
  log "nothing hairpin-shaped was measured; falling back to the before run is safe"
  exit 2
fi
if [ "$MODE" = before ]; then
  if [ "$FALLBACK" = 1 ] || [ "$BOOTSTRAP" = 1 ]; then
    die "--fallback and --bootstrap measure the hairpin; use --mode after"
  fi
  if [ "$AP_VALIDATED" = yes ]; then
    log "warning: the AP is validated in a before run; the phone path is labelled by its default network"
  fi
fi

PHASE=$MODE
printf '%s\n' "$PHASE" >"$OUT/phase"
phone_cpu_snapshot "$OUT/phone-cpu-before.txt"
MONITOR_STARTED=$(date +%s)
start_monitor

# Bootstrap is the one measurement that has to happen before the phone uses the
# hairpin: run it first, then decide whether the AP is validated and default.
if [ "$BOOTSTRAP" = 1 ]; then
  measure_bootstrap
  detect_network
fi

if [ "$MODE" = after ]; then
  if [ "$AP_VALIDATED" = yes ] && [ "$DEFAULT_TRANSPORT" = wifi-ap ]; then
    phone_path=hairpin
  else
    phone_path=
  fi
elif [ "$DEFAULT_TRANSPORT" = cellular ]; then
  phone_path=direct-cellular
else
  phone_path=direct-$DEFAULT_TRANSPORT
fi
if [ -n "$phone_path" ]; then
  record "phone_path" "$phone_path" measured "phone-state.csv"
  measure_phone "$phone_path" "$HTTPS_HOST" "$PHONE_SAMPLES"
else
  unavailable "phone_hairpin" "AP not validated/default after bootstrap; phone numbers were not taken"
fi
ap_sample "$(date +%s)" || true
measure_laptop_soak
ap_sample "$(date +%s)" || true
measure_shared
if [ "$FALLBACK" = 1 ]; then
  measure_fallback
fi

# Keep the battery window honest: the monitor runs from the start for the
# requested number of minutes, even when the measurements finish sooner.
if [ "$BATTERY_MINUTES" -gt 0 ]; then
  deadline=$(( MONITOR_STARTED + BATTERY_MINUTES * 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 10
  done
fi

set_phase "done"
stop_monitor
ap_sample "$(date +%s)" || true
detect_network
phone_cpu_snapshot "$OUT/phone-cpu-after.txt"
write_summary
printf 'done: %s\n' "$OUT" >&2
exit 0
