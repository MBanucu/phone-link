"""The fake commands the doctor suites put first on PATH.

Each answer is the body of ``bin/.<name>.answer``; the stub that calls it has
already appended the whole argv to ``log/<name>.log``.  The answers are shell
because the commands they impersonate answer with the text a real one would,
and because a bash stub is what the shell suite used: the pilot changes the
suite, not the phone the suite makes up.
"""

from __future__ import annotations

ADB = r"""
target=""
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then target=${args[1]}; args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  devices) cat "$LOG/devices" ;;
  connect)
    printf '%s\n' "${args[1]:-}" >>"$LOG/connected"
    printf 'connected to %s\n' "${args[1]:-}"
    # $LOG/deny lists addresses adbd does not answer on: a phone that never
    # pinned its adbd, so the mDNS fallback is what the test is about.
    denied=0
    if [ -f "$LOG/deny" ] && grep -qx "${args[1]:-}" "$LOG/deny"; then
      denied=1
    fi
    if [ "$denied" = 0 ] && [ -f "$LOG/connect_ok" ]; then
      printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n%s\tdevice\n' \
        "${args[1]:-}" >"$LOG/devices"
    fi
    ;;
  shell)
    args=("${args[@]:1}")
    case "${args[*]}" in
      "dumpsys window policy") printf '  showing=%s\n' "$(cat "$LOG/keyguard")" ;;
      "ip -4 -o addr show rndis0") cat "$LOG/rndis" ;;
      "ip -4 -o addr show"*) cat "$LOG/ips" ;;
      "ip route show default") cat "$LOG/default_route" ;;
      "pm path "*) cat "$LOG/pm" ;;
      "dumpsys package "*) cat "$LOG/dumpsys" ;;
      "dumpsys deviceidle whitelist") cat "$LOG/whitelist" ;;
      "dumpsys activity service "*) cat "$LOG/service_dump" ;;
      "settings get global network_avoid_bad_wifi") cat "$LOG/avoid" ;;
      "settings get global wifi_always_requested") cat "$LOG/always" ;;
      # The app's own facts, for a service that is not running: the doctor
      # reads them from the file under the app's external directory.
      "cat /sdcard/Android/data/"*)
        cat "$LOG/app_state" 2>/dev/null ;;
      "getprop ro.build.version.sdk") cat "$LOG/sdk" ;;
    esac
    ;;
esac
"""

AVAHI = r"""
cat "$LOG/avahi"
"""

IP = r"""
case "$*" in
  "-4 -br addr show "*) cat "$LOG/ap_addr" ;;
  "rule show") cat "$LOG/rules" ;;
esac
"""

NMCLI = r"""
cat "$LOG/nmcli_cons"
"""

SYSCTL = r"""
cat "$LOG/forward"
"""

SYSTEMCTL = r"""
case "$*" in
  "is-active phone-tun.service")
    cat "$LOG/tunnel"
    [ "$(cat "$LOG/tunnel")" = active ] ;;
  "is-active phone-link-ap-dhcp.service")
    cat "$LOG/ap_dhcp"
    [ "$(cat "$LOG/ap_dhcp")" = active ] ;;
  "is-active phone-link-ap-noforward.service")
    cat "$LOG/ap_noforward"
    [ "$(cat "$LOG/ap_noforward")" = active ] ;;
  *)
    cat "$LOG/tunnel"
    [ "$(cat "$LOG/tunnel")" = active ] ;;
esac
"""

NFT = r"""
case "$*" in
  "list table inet phone_link_ap")
    [ -f "$LOG/nft" ] && cat "$LOG/nft" ;;
  *) exit 1 ;;
esac
"""

IW = r"""
case "$*" in
  "dev wlp110s0 station dump") cat "$LOG/iw_station" 2>/dev/null ;;
  "dev wlp110s0 info") cat "$LOG/iw_info" 2>/dev/null ;;
  "dev wlp110s0 link") cat "$LOG/iw_link" 2>/dev/null ;;
esac
"""

CURL = r"""
case "$*" in
  *--socks5-hostname*) printf '%s' "$(cat "$LOG/proxy_code")" ;;
  # The release check: no file queued means "could not ask", which is what an
  # offline host sees and what keeps this suite off the network.
  *api.github.com*) cat "$LOG/release_json" 2>/dev/null ;;
  *) printf '%s' "$(cat "$LOG/internet_code")" ;;
esac
"""

GIT = r"""
while [ "${1:-}" = "-C" ]; do shift 2; done
case "$*" in
  "rev-parse HEAD") cat "$LOG/local_head" ;;
  "log -1 --format=%ct") cat "$LOG/head_time" ;;
  "merge-base --is-ancestor "*) [ "$(cat "$LOG/ancestor")" = yes ] ;;
  "ls-remote "*)
    # A queued ref list stands in for the network; the older single-HEAD file
    # is enough for the path-input cases.
    if [ -s "$LOG/remote_refs" ]; then
      cat "$LOG/remote_refs"
    elif [ -n "$(cat "$LOG/remote_head")" ]; then
      printf '%s\tHEAD\n' "$(cat "$LOG/remote_head")"
    else
      exit 128
    fi
    ;;
esac
"""

# The doctor suite's stubs: one call log each, one answer each.
ANSWERS: dict[str, str] = {
    "adb": ADB,
    "avahi-browse": AVAHI,
    "ip": IP,
    "nmcli": NMCLI,
    "sysctl": SYSCTL,
    "systemctl": SYSTEMCTL,
    "nft": NFT,
    "iw": IW,
    "curl": CURL,
    "git": GIT,
}
