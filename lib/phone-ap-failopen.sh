#!/usr/bin/env bash
# Fail open the PhoneLink AP hairpin when the tunnel is not healthy.
#
# The hairpin is the only thing that lets the phone validate the laptop AP: an
# `accept` for the one client in `inet phone_link_ap` and (optionally) a scoped
# masquerade in `ip phone_link_hairpin`.  If `phone-tun` dies while that path is
# in place, Android keeps a validated-but-dead Wi-Fi as its default network and
# blackholes its own internet.  This watchdog removes the hairpin whenever the
# tunnel is inactive, its TUN device is gone, or the hairpin rules themselves
# are missing, so the phone's next connectivity probe fails and Android falls
# back to cellular.  When the tunnel has been healthy for a grace period it
# restores the hairpin.
#
# It is deliberately small and idempotent: every tick recomputes the desired
# state, a state file remembers the current one and the healthy streak, and an
# nft replacement is a single `delete`+`table` batch so forwarding is never
# open in between.  Restores need both the grace period and the throttle, so a
# 5 s tunnel toggle cannot flap the hairpin; a failure opens immediately.
#
# Values come from the environment so the module binds its own paths and a test
# can run the same script against a temporary tree:
#   PHONE_AP_IF                     AP interface (default wlp110s0)
#   PHONE_AP_CLIENT                 the one client allowed through (may be empty)
#   PHONE_AP_TUN_IF                 tunnel device (default phone-tun)
#   PHONE_NFT                       nft binary (default nft)
#   PHONE_AP_SYSTEMCTL              systemctl binary (default systemctl)
#   PHONE_AP_IP                     ip binary (default ip)
#   PHONE_AP_DATE                   date binary for epochs (default date)
#   PHONE_TUN_UNIT                  unit to watch (default phone-tun.service)
#   PHONE_AP_FAILOPEN_STATE         state file (default /run/phone-link/ap-failopen.state)
#   PHONE_AP_NOFORWARD_RULES        no-forward rules file; built in when absent
#   PHONE_AP_HAIRPIN_RULES          healthy hairpin rules file; no restore without it
#   PHONE_AP_FAILOPEN_AP_TABLE      AP table name (default phone_link_ap)
#   PHONE_AP_FAILOPEN_HAIRPIN_TABLE NAT table name (default phone_link_hairpin)
#   PHONE_AP_FAILOPEN_GRACE         healthy seconds before restoring (default 15)
#   PHONE_AP_FAILOPEN_THROTTLE      seconds between restores (default 30)
#   PHONE_AP_FAILOPEN_REQUIRE_HAIRPIN  also require the hairpin for health
#                                      (default 1; 0 watches the tunnel only)
#   PHONE_AP_FAILOPEN_NAT           require the scoped masquerade table
#                                      (default 1; 0 for an accept-only hairpin)
set -u

iface=${PHONE_AP_IF:-wlp110s0}
client=${PHONE_AP_CLIENT:-}
tun_if=${PHONE_AP_TUN_IF:-phone-tun}
nft_cmd=${PHONE_NFT:-nft}
systemctl_cmd=${PHONE_AP_SYSTEMCTL:-systemctl}
ip_cmd=${PHONE_AP_IP:-ip}
date_cmd=${PHONE_AP_DATE:-date}
tun_unit=${PHONE_TUN_UNIT:-phone-tun.service}
state_file=${PHONE_AP_FAILOPEN_STATE:-/run/phone-link/ap-failopen.state}
no_forward_rules=${PHONE_AP_NOFORWARD_RULES:-}
hairpin_rules=${PHONE_AP_HAIRPIN_RULES:-}
ap_table=${PHONE_AP_FAILOPEN_AP_TABLE:-phone_link_ap}
hairpin_table=${PHONE_AP_FAILOPEN_HAIRPIN_TABLE:-phone_link_hairpin}
grace=${PHONE_AP_FAILOPEN_GRACE:-15}
throttle=${PHONE_AP_FAILOPEN_THROTTLE:-30}
require_hairpin=${PHONE_AP_FAILOPEN_REQUIRE_HAIRPIN:-1}
nat=${PHONE_AP_FAILOPEN_NAT:-1}

case "$grace" in
  '' | *[!0-9]*) grace=15 ;;
esac
case "$throttle" in
  '' | *[!0-9]*) throttle=30 ;;
esac
case "$require_hairpin" in
  0 | 1) ;;
  *) require_hairpin=1 ;;
esac
case "$nat" in
  0 | 1) ;;
  *) nat=1 ;;
esac

now() {
  "$date_cmd" +%s
}

state_dir=${state_file%/*}
if [ "$state_dir" = "$state_file" ]; then
  state_dir=.
fi
mkdir -p "$state_dir" 2>/dev/null || true

# The state file is a KEY=VALUE list, read rather than sourced.  A missing,
# truncated or hand-edited file means "unknown", which the first healthy tick
# adopts or the first unhealthy tick opens.
mode=
healthy_since=0
unhealthy_since=0
last_change=0
if [ -r "$state_file" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      mode) mode=$value ;;
      healthy_since) healthy_since=$value ;;
      unhealthy_since) unhealthy_since=$value ;;
      last_change) last_change=$value ;;
    esac
  done <"$state_file"
fi
case "$mode" in
  open | closed) ;;
  *) mode= ;;
esac
case "$healthy_since" in
  '' | *[!0-9]*) healthy_since=0 ;;
esac
case "$unhealthy_since" in
  '' | *[!0-9]*) unhealthy_since=0 ;;
esac
case "$last_change" in
  '' | *[!0-9]*) last_change=0 ;;
esac

# A missing nft is not actionable; do nothing and leave the state alone.  The
# timer retries, and this must not make a oneshot service fail every 5 s.
if ! command -v "$nft_cmd" >/dev/null 2>&1; then
  exit 0
fi

table_exists() {
  "$nft_cmd" list table "$1" "$2" >/dev/null 2>&1
}

tunnel_up() {
  "$systemctl_cmd" is-active --quiet "$tun_unit" 2>/dev/null || return 1
  "$ip_cmd" link show dev "$tun_if" >/dev/null 2>&1 || return 1
  return 0
}

# Healthy means the tunnel is active with its device, the AP accept rule is in
# place, and the NAT table (when used) still carries the scoped masquerade.  A
# mode of `open` deliberately has no hairpin, so it only requires the tunnel;
# otherwise the watchdog would fight its own last action.
hairpin_ok() {
  local ap_out nat_out
  ap_out=$("$nft_cmd" list table inet "$ap_table" 2>/dev/null) || return 1
  # `policy accept` is not the hairpin; the accept must be scoped to a source.
  case "$ap_out" in
    *saddr*accept*) ;;
    *) return 1 ;;
  esac
  if [ -n "$client" ]; then
    case "$ap_out" in
      *"$client"*) ;;
      *) return 1 ;;
    esac
  fi
  if [ "$nat" -eq 1 ]; then
    nat_out=$("$nft_cmd" list table ip "$hairpin_table" 2>/dev/null) || return 1
    case "$nat_out" in
      *masquerade*) ;;
      *) return 1 ;;
    esac
    if [ -n "$client" ]; then
      case "$nat_out" in
        *"$client"*) ;;
        *) return 1 ;;
      esac
    fi
  fi
  return 0
}

write_state() {
  local tmp
  tmp=${state_file}.$$
  if {
    printf 'mode=%s\n' "$mode"
    printf 'healthy_since=%s\n' "$healthy_since"
    printf 'unhealthy_since=%s\n' "$unhealthy_since"
    printf 'last_change=%s\n' "$last_change"
  } >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Replace both tables in one nft transaction.  Deleting the old AP table and
# re-creating it in the same batch leaves no interval where forwarding is
# accepted; loading a table over an existing one would fail instead.
load_rules() {
  local rules=$1
  local batch status

  batch=$(mktemp "${TMPDIR:-/tmp}/phone-ap-failopen.XXXXXX") || return 1
  if {
    if table_exists inet "$ap_table"; then
      printf 'delete table inet %s\n' "$ap_table"
    fi
    if table_exists ip "$hairpin_table"; then
      printf 'delete table ip %s\n' "$hairpin_table"
    fi
    cat "$rules"
  } >"$batch" 2>/dev/null; then
    "$nft_cmd" -f "$batch"
    status=$?
  else
    status=1
  fi
  rm -f "$batch"
  return "$status"
}

# Built-in equivalent of the module's no-forward rules: every packet entering
# from the AP is dropped, with no client exception.  It is used when the module
# does not provide a rules file, so fail-open never depends on a missing path.
fail_open() {
  local batch status

  batch=$(mktemp "${TMPDIR:-/tmp}/phone-ap-failopen.XXXXXX") || return 1
  if {
    if table_exists inet "$ap_table"; then
      printf 'delete table inet %s\n' "$ap_table"
    fi
    if table_exists ip "$hairpin_table"; then
      printf 'delete table ip %s\n' "$hairpin_table"
    fi
    if [ -n "$no_forward_rules" ] && [ -r "$no_forward_rules" ]; then
      cat "$no_forward_rules"
    else
      printf 'table inet %s {\n' "$ap_table"
      printf '  chain forward {\n'
      printf '    type filter hook forward priority -10; policy accept;\n'
      printf '    iifname "%s" drop\n' "$iface"
      printf '  }\n}\n'
    fi
  } >"$batch" 2>/dev/null; then
    "$nft_cmd" -f "$batch"
    status=$?
  else
    status=1
  fi
  rm -f "$batch"
  return "$status"
}

restore_hairpin() {
  if [ -z "$hairpin_rules" ] || [ ! -r "$hairpin_rules" ]; then
    return 2
  fi
  load_rules "$hairpin_rules"
}

now_epoch=$(now)
case "$now_epoch" in
  '' | *[!0-9]*) now_epoch=0 ;;
esac
# A timestamp from the future means the clock stepped back; do not let it
# suppress restores for the length of the jump.
if [ "$last_change" -gt "$now_epoch" ]; then
  last_change=0
fi

healthy=0
if tunnel_up; then
  if [ "$mode" = open ] || [ "$require_hairpin" -eq 0 ]; then
    healthy=1
  elif hairpin_ok; then
    healthy=1
  fi
fi

if [ "$healthy" -eq 1 ]; then
  unhealthy_since=0
  if [ "$healthy_since" -eq 0 ] || [ "$healthy_since" -gt "$now_epoch" ]; then
    healthy_since=$now_epoch
  fi
else
  healthy_since=0
  if [ "$unhealthy_since" -eq 0 ] || [ "$unhealthy_since" -gt "$now_epoch" ]; then
    unhealthy_since=$now_epoch
  fi
fi

if [ "$healthy" -eq 0 ]; then
  # Safety first: one unhealthy tick is enough to remove the hairpin.  An
  # already-open state is a no-op, so a short outage does not rewrite nft on
  # every 5 s tick.
  if [ "$mode" != open ]; then
    if fail_open; then
      mode=open
      last_change=$now_epoch
      unhealthy_since=$now_epoch
      healthy_since=0
      printf 'phone-link-ap-failopen: hairpin removed, phone-tun is not healthy\n' >&2
    else
      printf 'phone-link-ap-failopen: could not remove the hairpin\n' >&2
      write_state
      exit 1
    fi
  fi
elif [ "$require_hairpin" -eq 1 ] && [ "$mode" != closed ]; then
  if [ -z "$mode" ] && hairpin_ok; then
    # First run with the hairpin already in place: adopt it without touching
    # nft, and start the throttle clock from here.
    mode=closed
    last_change=$now_epoch
  elif [ -n "$hairpin_rules" ] && [ -r "$hairpin_rules" ]; then
    # A restore needs a sustained healthy tunnel and a quiet throttle window.
    # A 5 s toggle resets healthy_since, so it can never satisfy the grace.
    elapsed=$((now_epoch - healthy_since))
    since_change=$((now_epoch - last_change))
    if [ "$elapsed" -ge "$grace" ] &&
      { [ "$last_change" -eq 0 ] || [ "$since_change" -ge "$throttle" ]; }; then
      if restore_hairpin; then
        mode=closed
        last_change=$now_epoch
        healthy_since=$now_epoch
        printf 'phone-link-ap-failopen: hairpin restored\n' >&2
      else
        printf 'phone-link-ap-failopen: could not restore the hairpin\n' >&2
        write_state
        exit 1
      fi
    fi
  fi
fi

write_state
