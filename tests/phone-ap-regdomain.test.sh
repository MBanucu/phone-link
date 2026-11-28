#!/usr/bin/env bash
# Hermetic tests for the AP regulatory-domain parse (issue #91): the captured
# `iw reg get` / `iw phy` fixtures, the shared helper the command and the
# doctor use, and the doctor's `ap_channel` result. No phone, no network, no
# root, and the AP is never up.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIXTURES=$ROOT/tests/fixtures

. "$ROOT/tests/lib/harness.sh"
suite

# 1. The country-00 and country-DE captures: channel 149 is present in both,
#    but passive-only (NO-IR/PASSIVE-SCAN) in the world domain.
if PYTHONPATH="$ROOT/lib/python" python3 - "$FIXTURES" <<'PY'
import sys
from pathlib import Path

from phone_link import regdomain

fixtures = Path(sys.argv[1])
zero = (fixtures / "iw-reg-country-00.txt").read_text()
de = (fixtures / "iw-reg-country-de.txt").read_text()

v = regdomain.evaluate("a", 149, reg_get=zero)
assert v.country == "00", v
assert v.allowed is False and v.reason == "passive-only", v

v = regdomain.evaluate("a", 149, reg_get=de)
assert v.country == "DE", v
assert v.allowed is True and v.reason == "", v

# 2.4 GHz is untouched by the 5 GHz flags.
v = regdomain.evaluate("bg", 6, reg_get=zero)
assert v.allowed is True, v
v = regdomain.evaluate("bg", 1, reg_get=de)
assert v.allowed is True, v

for band, channel in (("a", 36), ("a", 149), ("bg", 1), ("bg", 13)):
    assert regdomain.channel_label(band, channel).startswith("channel "), band
PY
then ok "iw reg get parses country 00 (149 passive) and DE (149 allowed)"
else bad "iw reg get parses country 00 (149 passive) and DE (149 allowed)"
fi

# 2. The per-channel wiphy list is the decision source when it is readable,
#    including a device that reports no IR, a disabled channel, and a
#    self-managed domain that differs from the global country.
if PYTHONPATH="$ROOT/lib/python" python3 - "$FIXTURES" <<'PY'
import sys
from pathlib import Path

from phone_link import regdomain

fixtures = Path(sys.argv[1])
zero_reg = (fixtures / "iw-reg-country-00.txt").read_text()
zero_phy = (fixtures / "iw-phy-channels-country-00.txt").read_text()
de_phy = (fixtures / "iw-phy-channels-country-de.txt").read_text()

v = regdomain.evaluate("a", 149, phy_channels=zero_phy, reg_get=zero_reg, phy="phy0")
assert v.allowed is False and v.reason == "passive-only", v
assert v.country == "00", v

v = regdomain.evaluate("a", 149, phy_channels=de_phy, reg_get=zero_reg, phy="phy0")
assert v.allowed is True, v
# The phy list wins over the stale global domain: that is what makes a
# self-managed card work when the global country is still 00.
assert v.country == "00", v

v = regdomain.evaluate("a", 165, phy_channels=zero_phy, reg_get=zero_reg, phy="phy0")
assert v.allowed is False and v.reason == "passive-only", v

channels = regdomain.parse_phy_channels(zero_phy)
assert channels[149] == "passive-only", channels.get(149)
assert channels[14] == "disabled", channels.get(14)
assert channels[1] == "", channels.get(1)

# A channel the device does not list is not usable, even if the country list
# happens to have a range for it.
v = regdomain.evaluate("a", 32, phy_channels=de_phy, reg_get=zero_reg, phy="phy0")
assert v.allowed is False and v.reason == "not supported by this device", v
PY
then ok "iw phy channels parses no-IR, disabled and self-managed cases"
else bad "iw phy channels parses no-IR, disabled and self-managed cases"
fi

# 3. Unknown is not a block: the command and the doctor must degrade instead
#    of refusing a working setup.
if PYTHONPATH="$ROOT/lib/python" python3 <<'PY'
from phone_link import regdomain

for verdict in (
    regdomain.evaluate("a", 149),
    regdomain.evaluate("a", 149, phy_channels="", reg_get=""),
):
    assert verdict.allowed is None, verdict
    assert verdict.country == "", verdict

assert 'phoneLink.ap.country = "DE"' in regdomain.remediation("00")
assert 'iw reg set DE' in regdomain.remediation("00")
assert 'phoneLink.ap.country = "FR"' in regdomain.remediation("FR")
assert 'iw reg set FR' in regdomain.remediation("FR")
PY
then ok "an unreadable domain is unknown, and the fix names the country"
else bad "an unreadable domain is unknown, and the fix names the country"
fi

# 4. The doctor's ap_channel: warn in country 00, ok in DE, skip when the AP
#    is off or external, and skip when iw is absent. No AP state is involved.
stub_cmd iw "$STUBS" <<'EOF'
case "$*" in
  "dev wlp110s0 info") printf 'Interface wlp110s0\n\twiphy 0\n' ;;
  "phy phy0 channels") cat "$LOG/iw_phy" 2>/dev/null ;;
  "reg get") cat "$LOG/iw_reg" 2>/dev/null ;;
  "dev wlp110s0 station dump") : ;;
  "dev wlp110s0 link") : ;;
esac
EOF

if PYTHONPATH="$ROOT/lib/python" python3 - "$FIXTURES" "$LOG" "$STUBS" >"$LOG/doctor" <<'PY'
import os
import sys
from pathlib import Path

from phone_doctor.checks import ap
from phone_doctor.context import Context

fixtures = Path(sys.argv[1])
log = Path(sys.argv[2])
stubs = sys.argv[3]
marker = log / "ap-profile"

CASES = (
    ("warn-00", "local", "country-00", "a", "149", True),
    ("ok-de", "local", "country-de", "a", "149", True),
    ("ok-bg", "local", "country-00", "bg", "6", True),
    ("skip-off", "local", "country-00", "a", "149", False),
    ("skip-external", "external", "country-00", "a", "149", True),
)


def result(name):
    for item in ap.check(ctx):
        if item.cid == "ap_channel":
            print(f"{name}|{item.status.value}|{item.detail}")
            return
    raise AssertionError(f"no ap_channel in {name}")


for name, role, capture, band, channel, enabled in CASES:
    (log / "iw_reg").write_text((fixtures / f"iw-reg-{capture}.txt").read_text())
    (log / "iw_phy").write_text(
        (fixtures / f"iw-phy-channels-{capture}.txt").read_text()
    )
    if enabled:
        marker.write_text("phonelink\n")
    elif marker.exists():
        marker.unlink()
    ctx = Context(
        {
            "PATH": f"{stubs}:{os.environ.get('PATH', '')}",
            "LOG": str(log),
            "PHONE_CONFIG_FILE": str(log / "nonexistent"),
            "PHONE_AP_DECLARATIVE": str(marker),
            "PHONE_AP_IF": "wlp110s0",
            "PHONE_AP_ROLE": role,
            "PHONE_AP_BAND": band,
            "PHONE_AP_CHANNEL": channel,
        }
    )
    result(name)

# No iw in PATH: skip, not warn and not a crash.
ctx = Context(
    {
        "PATH": "/nonexistent",
        "PHONE_CONFIG_FILE": str(log / "nonexistent"),
        "PHONE_AP_DECLARATIVE": str(marker),
        "PHONE_AP_IF": "wlp110s0",
        "PHONE_AP_ROLE": "local",
    }
)
result("skip-no-iw")
PY
then
  ok "the doctor runs ap_channel without an AP state"
else
  bad "the doctor runs ap_channel without an AP state" "$(cat "$LOG/doctor")"
fi

grep -q '^warn-00|warn|channel 149 (5 GHz, band a) is passive-only in regulatory domain 00' \
  "$LOG/doctor" && ok "country 00 with 149 warns" \
  || bad "country 00 with 149 warns" "$(cat "$LOG/doctor")"
grep -q '^warn-00|warn|.*phoneLink.ap.country = "DE".*iw reg set DE.*2.4 GHz' \
  "$LOG/doctor" && ok "the warning names both fixes" \
  || bad "the warning names both fixes" "$(cat "$LOG/doctor")"
grep -q '^ok-de|ok|channel 149 (5 GHz, band a) allowed in regulatory domain DE' \
  "$LOG/doctor" && ok "country DE with 149 is ok" \
  || bad "country DE with 149 is ok" "$(cat "$LOG/doctor")"
grep -q '^ok-bg|ok|channel 6 (2.4 GHz, band bg) allowed' \
  "$LOG/doctor" && ok "2.4 GHz is ok in country 00" \
  || bad "2.4 GHz is ok in country 00" "$(cat "$LOG/doctor")"
grep -q '^skip-off|skip|phoneLink.ap is off' "$LOG/doctor" \
  && ok "AP off skips ap_channel" || bad "AP off skips ap_channel" "$(cat "$LOG/doctor")"
grep -q '^skip-external|skip|external AP' "$LOG/doctor" \
  && ok "external role skips ap_channel" \
  || bad "external role skips ap_channel" "$(cat "$LOG/doctor")"
grep -q '^skip-no-iw|skip|iw not installed' "$LOG/doctor" \
  && ok "missing iw skips ap_channel" \
  || bad "missing iw skips ap_channel" "$(cat "$LOG/doctor")"

finish
