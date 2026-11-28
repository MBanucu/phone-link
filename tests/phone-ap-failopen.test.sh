#!/usr/bin/env bash
# Hermetic tests for lib/phone-ap-failopen.sh: stub nft, systemctl, ip and date,
# keep the tables in files and move the clock by hand. No tunnel, no root, no
# network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/lib/phone-ap-failopen.sh
. "$ROOT/tests/lib/harness.sh"
suite --no-home
mkdir -p "$LOG/tables" "$TMP/run/phone-link"


CLIENT=192.168.77.232
NOFORWARD=$TMP/noforward.nft
HAIRPIN=$TMP/hairpin.nft
STATE=$TMP/run/phone-link/ap-failopen.state

cat >"$NOFORWARD" <<EOF
table inet phone_link_ap {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "wlp110s0" drop
  }
}
EOF

cat >"$HAIRPIN" <<EOF
table inet phone_link_ap {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "wlp110s0" ip saddr $CLIENT accept
    iifname "wlp110s0" drop
  }
}
table ip phone_link_hairpin {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "phone-tun" ip saddr $CLIENT masquerade
  }
}
EOF

# nft: `list table <family> <name>` reads a file; `-f` applies deletes and
# materializes the tables named at the start of a line.  The real nft applies a
# file as one transaction; the order in the file is what this models.
stub nft
answer nft <<'EOF'
printf '%s\n' "$*" >>"$LOG/nft_calls"
case "${1:-}" in
  list)
    table=$LOG/tables/$3.$4
    [ -f "$table" ] || exit 1
    cat "$table"
    ;;
  -f)
    cp "$2" "$LOG/last_batch"
    while IFS= read -r line; do
      case "$line" in
        'delete table inet '*) rm -f "$LOG/tables/inet.${line#delete table inet }" ;;
        'delete table ip '*) rm -f "$LOG/tables/ip.${line#delete table ip }" ;;
      esac
    done <"$2"
    if grep -q '^table inet phone_link_ap {' "$2"; then
      cp "$2" "$LOG/tables/inet.phone_link_ap"
    fi
    if grep -q '^table ip phone_link_hairpin {' "$2"; then
      cp "$2" "$LOG/tables/ip.phone_link_hairpin"
    fi
    printf '%s\n' "$*" >>"$LOG/nft_loads"
    ;;
esac
EOF

stub systemctl
answer systemctl <<'EOF'
printf '%s\n' "$*" >>"$LOG/systemctl_calls"
case "${1:-}" in
  is-active) [ "$(cat "$LOG/tun_state" 2>/dev/null)" = active ] ;;
esac
EOF

stub ip
answer ip <<'EOF'
case "$*" in
  'link show dev '*) [ "$(cat "$LOG/link_state" 2>/dev/null)" = up ] ;;
esac
EOF

stub date
answer date <<'EOF'
cat "$LOG/now" 2>/dev/null || printf '0\n'
EOF


export PHONE_AP_IF=wlp110s0
export PHONE_AP_CLIENT=$CLIENT
export PHONE_AP_TUN_IF=phone-tun
export PHONE_NFT=$STUBS/nft
export PHONE_AP_SYSTEMCTL=$STUBS/systemctl
export PHONE_AP_IP=$STUBS/ip
export PHONE_AP_DATE=$STUBS/date
export PHONE_TUN_UNIT=phone-tun.service
export PHONE_AP_FAILOPEN_STATE=$STATE
export PHONE_AP_NOFORWARD_RULES=$NOFORWARD
export PHONE_AP_HAIRPIN_RULES=$HAIRPIN
export PHONE_AP_FAILOPEN_GRACE=15
export PHONE_AP_FAILOPEN_THROTTLE=30
export PHONE_AP_FAILOPEN_REQUIRE_HAIRPIN=1

run() {
  "$BASH_BIN" "$SCRIPT" >"$LOG/out" 2>"$LOG/err"
  status=$?
  cat "$LOG/out" "$LOG/err" >>"$LOG/output"
  return "$status"
}

reset() {
  : >"$LOG/nft_calls"
  : >"$LOG/nft_loads"
  : >"$LOG/systemctl_calls"
  : >"$LOG/last_batch"
  : >"$LOG/output"
  rm -f "$STATE"
  rm -rf "$LOG/tables"
  mkdir -p "$LOG/tables"
  printf 'inactive\n' >"$LOG/tun_state"
  printf 'up\n' >"$LOG/link_state"
  printf '1000\n' >"$LOG/now"
}

set_now() {
  printf '%s\n' "$1" >"$LOG/now"
}

tunnel_up() {
  printf 'active\n' >"$LOG/tun_state"
  printf 'up\n' >"$LOG/link_state"
}

tunnel_down() {
  printf 'inactive\n' >"$LOG/tun_state"
}

hairpin_tables() {
  cp "$HAIRPIN" "$LOG/tables/inet.phone_link_ap"
  cp "$HAIRPIN" "$LOG/tables/ip.phone_link_hairpin"
}

mode() {
  sed -n 's/^mode=//p' "$STATE" 2>/dev/null || true
}

loads() {
  wc -l <"$LOG/nft_loads" 2>/dev/null || printf '0\n'
}

ap_table() {
  cat "$LOG/tables/inet.phone_link_ap" 2>/dev/null || true
}

hairpin_table() {
  cat "$LOG/tables/ip.phone_link_hairpin" 2>/dev/null || true
}

# 1. A dead tunnel removes the hairpin and leaves only the AP drop; a second
#    tick in the same state does not rewrite nft.
reset
hairpin_tables
tunnel_down
if run; then ok "a down tunnel exits 0"; else bad "a down tunnel exits 0 ($(cat "$LOG/err"))"; fi
case "$(ap_table)" in
  *"$CLIENT accept"*) bad "the AP accept is removed" ;;
  *drop*) ok "the AP accept is removed" ;;
  *) bad "the AP table still carries the drop" ;;
esac
[ -e "$LOG/tables/ip.phone_link_hairpin" ] && bad "the hairpin NAT table is deleted" \
  || ok "the hairpin NAT table is deleted"
[ "$(mode)" = open ] && ok "the state records the open mode" \
  || bad "the state records the open mode (got $(mode))"
[ "$(loads)" = 1 ] && ok "the fail-open is one nft transaction" \
  || bad "the fail-open is one nft transaction (got $(loads))"

run
[ "$(loads)" = 1 ] && ok "a second unhealthy tick is a no-op" \
  || bad "a second unhealthy tick is a no-op (got $(loads))"

# 2. A healthy tunnel restores after the grace period and the throttle window,
#    not on the first active tick.
tunnel_up
set_now 1010
run
[ -e "$LOG/tables/ip.phone_link_hairpin" ] && bad "no restore inside the grace period" \
  || ok "no restore inside the grace period"
set_now 1020
run
[ -e "$LOG/tables/ip.phone_link_hairpin" ] && bad "no restore inside the throttle window" \
  || ok "no restore inside the throttle window"
set_now 1031
if run; then ok "a sustained healthy tunnel exits 0"; else bad "a sustained healthy tunnel exits 0 ($(cat "$LOG/err"))"; fi
case "$(ap_table)" in
  *"$CLIENT accept"*) ok "the AP client accept is restored" ;;
  *) bad "the AP client accept is restored" ;;
esac
case "$(hairpin_table)" in
  *masquerade*) ok "the scoped masquerade is restored" ;;
  *) bad "the scoped masquerade is restored" ;;
esac
[ "$(mode)" = closed ] && ok "the state records the closed mode" \
  || bad "the state records the closed mode (got $(mode))"
[ "$(loads)" = 2 ] && ok "the restore is one nft transaction" \
  || bad "the restore is one nft transaction (got $(loads))"

run
[ "$(loads)" = 2 ] && ok "a second healthy tick is a no-op" \
  || bad "a second healthy tick is a no-op (got $(loads))"

# 3. A tunnel that drops after a restore opens immediately (safety does not
#    wait for a grace period), and a later one-tick recovery does not restore.
tunnel_down
set_now 1035
run
[ -e "$LOG/tables/ip.phone_link_hairpin" ] && bad "a post-restore failure removes the hairpin" \
  || ok "a post-restore failure removes the hairpin"
tunnel_up
set_now 1040
run
[ -e "$LOG/tables/ip.phone_link_hairpin" ] && bad "a one-tick recovery stays open" \
  || ok "a one-tick recovery stays open"
tunnel_down
set_now 1045
run
[ "$(loads)" = 3 ] && ok "a repeat failure while open does not rewrite nft" \
  || bad "a repeat failure while open does not rewrite nft (got $(loads))"

# 4. The tunnel is active but the hairpin route disappeared (an external
#    flush): that is unhealthy too, so the AP drop comes back.
reset
hairpin_tables
tunnel_up
if run; then ok "a first healthy run adopts the existing hairpin"; else bad "a first healthy run adopts the existing hairpin"; fi
[ "$(mode)" = closed ] && ok "the adopted state is closed" \
  || bad "the adopted state is closed (got $(mode))"
[ "$(loads)" = 0 ] && ok "adopting an existing hairpin does not rewrite nft" \
  || bad "adopting an existing hairpin does not rewrite nft (got $(loads))"
rm -f "$LOG/tables/ip.phone_link_hairpin"
set_now 2005
run
[ -e "$LOG/tables/ip.phone_link_hairpin" ] && bad "a missing hairpin removes the accept" \
  || ok "a missing hairpin removes the accept"
case "$(ap_table)" in
  *"$CLIENT accept"*) bad "the missing-route fail-open drops forwarding" ;;
  *drop*) ok "the missing-route fail-open drops forwarding" ;;
  *) bad "the missing-route fail-open drops forwarding" ;;
esac

# 5. No nft binary: nothing to do, but the watchdog must not fail or write a
#    state that would suppress the next real tick.
reset
hairpin_tables
tunnel_down
PHONE_NFT=$TMP/no-such-nft
if run; then ok "a missing nft exits 0"; else bad "a missing nft exits 0"; fi
[ -e "$STATE" ] && bad "a missing nft writes no state" \
  || ok "a missing nft writes no state"
[ -s "$LOG/nft_calls" ] && bad "a missing nft makes no nft call" \
  || ok "a missing nft makes no nft call"
PHONE_NFT=$STUBS/nft
export PHONE_NFT

# 6. No healthy rules file yet: the watchdog stays open instead of guessing a
#    hairpin, and later restores once the module provides the file.
reset
tunnel_down
run
tunnel_up
set_now 3000
PHONE_AP_HAIRPIN_RULES=$TMP/no-hairpin.nft
export PHONE_AP_HAIRPIN_RULES
run
[ -e "$LOG/tables/ip.phone_link_hairpin" ] && bad "no rules file leaves the hairpin open" \
  || ok "no rules file leaves the hairpin open"
[ "$(mode)" = open ] && ok "no rules file keeps the open state" \
  || bad "no rules file keeps the open state (got $(mode))"
PHONE_AP_HAIRPIN_RULES=$HAIRPIN
export PHONE_AP_HAIRPIN_RULES
set_now 3030
run
[ -e "$LOG/tables/ip.phone_link_hairpin" ] && ok "the hairpin returns when the rules file does" \
  || bad "the hairpin returns when the rules file does"

# 7. A future last_change (the clock stepped back) is treated as stale, so it
#    cannot suppress a restore for the length of the jump.
reset
tunnel_up
set_now 5000
printf 'mode=open\nhealthy_since=0\nunhealthy_since=0\nlast_change=999999\n' >"$STATE"
run
set_now 5020
run
[ -e "$LOG/tables/ip.phone_link_hairpin" ] && ok "a future timestamp does not suppress a restore" \
  || bad "a future timestamp does not suppress a restore"

# 8. A malformed state file is treated as unknown, not sourced and not fatal.
reset
hairpin_tables
tunnel_down
printf 'mode=open\nhealthy_since=not-a-number\n' >"$STATE"
if run; then ok "a malformed state file does not fail the run"; else bad "a malformed state file does not fail the run"; fi
[ "$(mode)" = open ] && ok "a malformed state file still fails open" \
  || bad "a malformed state file still fails open (got $(mode))"

finish
