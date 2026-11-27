"""Read-only regulatory-domain check for the AP's configured channel.

The laptop AP beacons on a channel that cfg80211 must allow with IR (initiating
radiation).  On a fresh boot with no client association the domain is
``country 00`` and 5 GHz channel 149 is passive-scan only, so wpa_supplicant
cannot start AP mode; NetworkManager then reports a misleading 802.1X
supplicant timeout (issue #91).  This module answers one question without
changing anything: is the configured channel usable for an AP right now?

Two read-only sources, in this order:

* ``iw phy <phy> channels`` is the decision source.  It is the effective
  per-channel state of the wiphy, which is what matters on a card with a
  self-managed (LAR) regulatory domain: the global country can be ``00`` while
  the device still allows a channel, or the other way round.
* ``iw reg get`` supplies the country for the message and is the fallback when
  the phy channel list cannot be read (older ``iw``, no phy name).

Both parsers are pure functions over captured text so the command, the doctor
and the tests cannot disagree about what the output means.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable, Sequence

# The module's own channel range is 1..196; a band's label is only used in
# messages.
BAND_LABELS = {"a": "5 GHz", "bg": "2.4 GHz"}

_COUNTRY_RE = re.compile(r"^country\s+([0-9A-Z]{2}):")
_SECTION_RE = re.compile(r"^(global|phy#\d+)\b")
_RANGE_RE = re.compile(
    r"\(\s*(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s*@\s*\d+\)(.*)$"
)
_PHY_CHANNEL_RE = re.compile(r"^\s*\*\s*\d+(?:\.\d+)?\s*MHz\s*\[(\d+)\](.*)$")
_WIPHY_RE = re.compile(r"^Wiphy\s+(phy\d+)", re.MULTILINE)
_WIPHY_ID_RE = re.compile(r"^\s*wiphy\s+(\d+)\s*$", re.MULTILINE)

# Flags that make a channel unusable for an AP, as `iw reg get` spells them.
# DFS is deliberately not here: an AP may use a DFS channel with radar
# detection, and the issue is passive scan / no IR.
_BLOCKING_FLAGS = ("NO-IR", "PASSIVE-SCAN")


@dataclass(frozen=True)
class Verdict:
    """What the regulatory domain says about one AP channel.

    ``allowed`` is ``None`` when neither source could be read; callers degrade
    on that instead of blocking a working setup.  ``reason`` is empty when the
    channel is usable, otherwise ``passive-only``, ``disabled``, ``not listed``
    or ``not supported by this device``.
    """

    allowed: bool | None
    country: str
    reason: str = ""

    @property
    def blocked(self) -> bool:
        return self.allowed is False


@dataclass(frozen=True)
class _Section:
    country: str = ""
    # (start MHz, end MHz, blocking reason) for every range line.
    ranges: tuple[tuple[float, float, str], ...] = ()


def channel_label(band: str, channel: int) -> str:
    """`channel 149 (5 GHz, band a)` for the messages."""
    name = BAND_LABELS.get(band)
    if name:
        return f"channel {channel} ({name}, band {band})"
    return f"channel {channel} (band {band})"


def country_label(country: str) -> str:
    return f"regulatory domain {country}" if country else "an unknown regulatory domain"


def remediation(country: str) -> str:
    """The fixes to name when a channel is not usable.

    ``country`` is the domain that was read; a world domain (``00``) cannot be
    set back, so the example is DE, the domain the issue was observed in.  The
    caller substitutes its own country code.
    """
    example = country if country and country != "00" else "DE"
    return (
        f'set phoneLink.ap.country = "{example}" (next boot), '
        f"run iw reg set {example} now, "
        'or use a 2.4 GHz channel (phoneLink.ap.band = "bg")'
    )


def parse_phy_channels(text: str) -> dict[int, str]:
    """Map channel -> blocking reason from `iw phy <phy> channels`.

    An empty reason means the channel is usable.  Channels absent from the
    output are not in the returned map at all: the device does not list them.
    """
    channels: dict[int, str] = {}
    for line in text.splitlines():
        match = _PHY_CHANNEL_RE.match(line)
        if not match:
            continue
        channel = int(match.group(1))
        flags = match.group(2).lower()
        if "disabled" in flags:
            channels[channel] = "disabled"
        elif "no ir" in flags or "passive" in flags:
            channels[channel] = "passive-only"
        else:
            channels[channel] = ""
    return channels


def parse_reg_get(text: str) -> dict[str, _Section]:
    """Map section (`global` or `phy#N`) to its country and frequency ranges."""
    sections: dict[str, _Section] = {}
    scope = "global"
    country = ""
    ranges: list[tuple[float, float, str]] = []

    def flush() -> None:
        if country or ranges:
            sections[scope] = _Section(country, tuple(ranges))

    for raw in text.splitlines():
        line = raw.strip()
        header = _SECTION_RE.match(line)
        if header:
            flush()
            scope = header.group(1)
            country = ""
            ranges = []
            continue
        match = _COUNTRY_RE.match(line)
        if match:
            country = match.group(1)
            continue
        match = _RANGE_RE.match(line)
        if match:
            start, end, rest = (
                float(match.group(1)),
                float(match.group(2)),
                match.group(3),
            )
            flags = rest.upper()
            reason = ""
            if any(flag in flags for flag in _BLOCKING_FLAGS):
                reason = "passive-only"
            ranges.append((start, end, reason))
    flush()
    # A file with no explicit section headers still has a global section.
    if "global" not in sections and (country or ranges):
        sections["global"] = _Section(country, tuple(ranges))
    return sections


def _center_mhz(band: str, channel: int) -> float:
    if channel == 14:
        return 2484.0
    if 1 <= channel <= 13:
        return 2407.0 + 5.0 * channel
    return 5000.0 + 5.0 * channel


def _section_for(sections: dict[str, _Section], phy: str) -> _Section | None:
    key = f"phy#{phy.removeprefix('phy')}" if phy else ""
    if key and key in sections and sections[key].ranges:
        return sections[key]
    return sections.get("global")


def _country_for(sections: dict[str, _Section], phy: str) -> str:
    key = f"phy#{phy.removeprefix('phy')}" if phy else ""
    if key and key in sections and sections[key].country:
        return sections[key].country
    if "global" in sections and sections["global"].country:
        return sections["global"].country
    for section in sections.values():
        if section.country:
            return section.country
    return ""


def _reason_from_reg(
    sections: dict[str, _Section], phy: str, band: str, channel: int
) -> str | None:
    section = _section_for(sections, phy)
    if section is None or not section.ranges:
        return None
    center = _center_mhz(band, channel)
    containers = [
        reason
        for start, end, reason in section.ranges
        if start <= center <= end
    ]
    if not containers:
        return "not listed"
    # A channel covered by one usable range is usable, even if another range
    # touches its edge with a narrower flag set.
    if "" in containers:
        return ""
    return containers[0] or "passive-only"


def evaluate(
    band: str,
    channel: int,
    *,
    phy_channels: str = "",
    reg_get: str = "",
    phy: str = "",
) -> Verdict:
    """Combine captured `iw` text into one verdict, without running anything."""
    sections = parse_reg_get(reg_get) if reg_get else {}
    country = _country_for(sections, phy)
    listed = parse_phy_channels(phy_channels) if phy_channels else {}

    if listed:
        if channel in listed:
            reason = listed[channel]
        else:
            # The device owns its channel list; do not fall back to a global
            # country that may not describe this wiphy.
            reason = "not supported by this device"
    elif reg_get:
        reason = _reason_from_reg(sections, phy, band, channel)
        if reason is None:
            return Verdict(None, country)
    else:
        return Verdict(None, country)

    return Verdict(reason == "", country, reason)


def probe(
    band: str,
    channel: int,
    *,
    interface: str,
    capture: Callable[[Sequence[str]], str],
) -> Verdict:
    """Read the wiphy and domain with `capture`, then evaluate them.

    ``capture`` is the commands' `shell.capture` or the doctor's `ctx.text`:
    both return "" when the command cannot run, which is the unknown case.
    """
    phy = ""
    if interface:
        match = _WIPHY_ID_RE.search(capture(["iw", "dev", interface, "info"]))
        if match:
            phy = f"phy{match.group(1)}"

    channels_text = ""
    if phy:
        channels_text = capture(["iw", "phy", phy, "channels"])
    if not channels_text:
        match = _WIPHY_RE.search(capture(["iw", "phy"]))
        if match:
            phy = match.group(1)
            channels_text = capture(["iw", "phy", phy, "channels"])

    reg_text = capture(["iw", "reg", "get"])
    return evaluate(
        band,
        channel,
        phy_channels=channels_text,
        reg_get=reg_text,
        phy=phy,
    )
