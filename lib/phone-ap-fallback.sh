#!/usr/bin/env bash
# Switch the local AP profile to its 2.4 GHz fallback once per boot.
#
# The 5 GHz AP is the default because it is much faster, but an activation can
# fail for reasons outside this host's control (the card's self-managed
# regulatory domain, a stale wpa_supplicant state, a driver that refuses the
# channel).  A failed AP means no link at all, so one attempt with the
# conservative 2.4 GHz settings is better than nothing.
#
# Called two ways:
#   * by phone-ap-up --now --reason TEXT after the 5 GHz attempt failed;
#   * by phone-link-ap-fallback.service at boot when ap.autoconnect is on:
#     it waits PHONE_AP_FALLBACK_DELAY for the 5 GHz AP to appear first.
#
# One attempt per boot: the state file lives under /run.  The next boot (or
# phone-ap-down, which restores the declared profile) retries 5 GHz.
#
# No secret is read or written here: NetworkManager already holds the PSK in
# the profile; this script only changes band, channel and width.
set -u

CON=${PHONE_AP_CON:-phonelink}
DELAY=${PHONE_AP_FALLBACK_DELAY:-30}
CHANNEL=${PHONE_AP_FALLBACK_CHANNEL:-1}
WIDTH=${PHONE_AP_FALLBACK_WIDTH:-20}
STATE=${PHONE_AP_FALLBACK_STATE:-/run/phone-link/ap-fallback}

now=0
reason=""
while [ $# -gt 0 ]; do
    case $1 in
        --now) now=1 ;;
        --reason)
            shift
            reason=${1:-}
            ;;
        *)
            printf 'phone-ap-fallback: unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

active() {
    nmcli -t -f NAME connection show --active 2>/dev/null | grep -Fxq -- "$CON"
}

if [ "$now" = 0 ]; then
    # Wait for the 5 GHz AP to come up; return as soon as it does, so a valid
    # 5 GHz boot pays only the first second, not the whole delay.
    waited=0
    while [ "$waited" -lt "$DELAY" ]; do
        if active; then
            exit 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
fi

if active; then
    exit 0
fi

if [ -e "$STATE" ]; then
    printf 'phone-ap-fallback: already attempted this boot, not looping (%s)\n' \
        "$STATE" >&2
    exit 1
fi

case $CHANNEL in
    '' | *[!0-9]* | 0)
        printf 'phone-ap-fallback: bad channel: %s\n' "$CHANNEL" >&2
        exit 2
        ;;
esac
if [ "$CHANNEL" -gt 11 ]; then
    printf 'phone-ap-fallback: bad channel: %s (1..11)\n' "$CHANNEL" >&2
    exit 2
fi
case $WIDTH in
    20 | 40) ;;
    *)
        printf 'phone-ap-fallback: bad width: %s\n' "$WIDTH" >&2
        exit 2
        ;;
esac

printf 'phone-ap-fallback: 5 GHz AP did not start%s; trying 2.4 GHz channel %s at %s MHz (one attempt per boot)\n' \
    "${reason:+ ($reason)}" "$CHANNEL" "$WIDTH" >&2

# Record the attempt before touching the profile, so a failure part-way
# through still counts as this boot's one attempt.
mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
{
    printf 'attempted=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'channel=%s\n' "$CHANNEL"
    printf 'width=%s\n' "$WIDTH"
    printf 'reason=%s\n' "${reason:-unknown}"
} >"$STATE" 2>/dev/null || {
    printf 'phone-ap-fallback: cannot write %s\n' "$STATE" >&2
    exit 1
}

if ! nmcli connection modify "$CON" \
    802-11-wireless.band bg \
    802-11-wireless.channel "$CHANNEL" \
    802-11-wireless.channel-width "$WIDTH"; then
    printf 'phone-ap-fallback: could not change %s to 2.4 GHz\n' "$CON" >&2
    exit 1
fi

if ! nmcli connection up "$CON"; then
    printf 'phone-ap-fallback: %s did not activate on 2.4 GHz\n' "$CON" >&2
    exit 1
fi

if ! active; then
    printf 'phone-ap-fallback: %s is not active after the fallback\n' "$CON" >&2
    exit 1
fi

printf 'phone-ap-fallback: %s is up on 2.4 GHz channel %s at %s MHz; 5 GHz is retried at the next boot or after phone-ap-down\n' \
    "$CON" "$CHANNEL" "$WIDTH" >&2
