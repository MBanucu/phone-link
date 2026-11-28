"""Repair the problems phone-doctor reports, one script per problem.

The order is deliberate: the AP and the phone's link to it come after the
things that do not need a network, because bringing the AP up moves the phone's
address; and the proxy is started last of all, because its listener only runs on
the network the phone joined — setup sent while the AP is down is refused by the
app's own SSID gate, and the repair would report failure over an ordering.
"""

from __future__ import annotations

import os
import re
import sys

from .. import actions, phone
from ..shell import capture, die, log, run

USAGE = """usage: phone-doctor-fix [--yes] [--dry-run] [--required] [--which-doctor]

Runs phone-doctor --analyze, then the fix script for each problem it reports,
in dependency order, and re-checks afterwards. --yes skips the confirmation;
--dry-run only lists what would run; --required ignores warnings and only
fixes required failures. Problems without a fix script are printed with the
manual step. PHONE_PROXY_APK=/path/app.apk installs the proxy from that file
instead of the APK this checkout builds, which keeps the repair working when
the network it restores is itself down. --which-doctor prints the phone-doctor
the problems are read from and exits: the one beside this checkout, unless
PHONE_DOCTOR names another.
"""

FIX_ORDER = (
    "ip_forward ap_profile phone_unlocked phone_default proxy_app app_boot "
    "phone_tun tunnel_route rndis0 network_transport ap_address phone_address "
    "proxy_request https"
).split()

FIX_SCRIPTS = {
    "ip_forward": "phone-fix-forwarding",
    "ap_profile": "phone-ap-create",
    "ap_address": "phone-ap-up",
    "phone_unlocked": "phone-unlock",
    "phone_address": "phone-wifi-connect",
    "phone_default": "phone-fix-mobile-data",
    "proxy_app": "phone-proxy-install",
    "proxy_request": "phone-proxy-setup",
    "app_boot": "phone-proxy-boot",
    "phone_tun": "phone-fix-tunnel",
    "tunnel_route": "phone-fix-tunnel",
    "rndis0": "phone-usb-tether-default",
    "network_transport": "phone-adb-wifi",
    "https": "phone-fix-internet",
}

MANUAL_HINTS = {
    "adb_device": (
        "attach the phone over USB (or run phone-adb-wifi from a trusted host)"
    ),
    "ap_profile": 'create the phonelink profile with the nmcli command in README "One-time setup"',
    "ap_dhcp": "enable phoneLink.ap and rebuild (nixos-rebuild switch)",
    "ap_noforward": "enable phoneLink.ap and rebuild (nixos-rebuild switch)",
    "ap_noforward_rules": "reload the AP forward drop: systemctl restart phone-link-ap-noforward",
    "ap_station": "join the phone to the AP: phone-wifi-connect PhoneLink",
    "ap_link": "join this laptop to the external AP in NetworkManager",
    "wifi_reconnect": "apply the reconnect globals explicitly: phone-wifi-reconnect",
    "secrets_mode": "chmod 600 the secrets file (it holds PHONE_SOCKS_PASS)",
    "resolver": "pin /etc/resolv.conf via phoneLink.manageResolver and rebuild",
    "secrets": "write the secrets file with PHONE_SOCKS_PASS and PHONE_PIN (root, mode 600)",
    "ap_pass": "add PHONE_AP_PASS to the secrets file",
    "apk_cache": (
        "download the app's newest release: phone-proxy-install --release "
        "(this checkout does not build it)"
    ),
    "proxy_version": (
        "update the app: phone-proxy-install --release (or phone-doctor-fix --yes)"
    ),
    "proxy_compat": "the installed app does not fit this phone; pick a compatible APK",
    "app_installed": (
        "install the app: phone-proxy-install, or name a release APK to install"
    ),
    "app_oem_autostart": (
        'enable "Phone link proxy" in System Manager → App Management → '
        "Auto Start Management, or run wireless-adb-keeper/autostart-allow.sh "
        '"Phone link proxy" / phone-link-tools/autotoggle'
    ),
    "flake_update": "update the source and rebuild: nix flake update phone-link",
    "https": "retry after the proxy/tether fixes; net-check shows which fetch fails",
}


def _doctor() -> str:
    path = os.environ.get("PHONE_DOCTOR") or actions.doctor_bin() or ""
    if not path or not os.access(path, os.X_OK):
        die("phone-doctor not found (set PHONE_DOCTOR)")
    return path


def _describe(problem: str) -> str:
    script = FIX_SCRIPTS[problem]
    if problem != "proxy_app":
        return script
    apk = phone.app_apk()
    return f"{script} {apk}" if apk else script


def _manual(problem: str) -> str:
    return MANUAL_HINTS.get(problem, "no automatic fix")


def _run_cmd(name: str, *args: str) -> int:
    path = actions.binary(actions.BY_ID[name])
    if not os.access(path, os.X_OK):
        log(f"error: {name} not found")
        return 1
    return run([path, *args])


def _run_fix(problem: str) -> int:
    if problem == "proxy_app":
        # Offline reinstall: the network may be the thing this fix restores.
        apk = phone.app_apk()
        if apk:
            if not os.path.isfile(apk):
                log(f"error: app APK is not a file: {apk}")
                return 1
            return _run_cmd("phone-proxy-install", apk)
        return _run_cmd("phone-proxy-install")
    if problem in ("phone_tun", "tunnel_route"):
        return _run_cmd("phone-fix-tunnel")
    return _run_cmd(FIX_SCRIPTS[problem])


def phone_doctor_fix(args: list[str]) -> int:
    """Run the fix script for each problem the doctor reports."""
    assume_yes = False
    dry_run = False
    required = False
    which_doctor = False
    for value in args:
        if value == "--yes":
            assume_yes = True
        elif value == "--dry-run":
            dry_run = True
        elif value == "--required":
            required = True
        elif value == "--which-doctor":
            which_doctor = True
        elif value in ("-h", "--help"):
            print(USAGE, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    doctor = _doctor()
    if which_doctor:
        # The path alone, for scripts and for asking "which doctor is this?"
        # without running it: both can be on a machine at once.
        print(doctor)
        return 0
    log(f"doctor: {doctor}")
    problems = capture([doctor, "--analyze"])
    lines = problems.splitlines()
    if required:
        lines = [line for line in lines if line.split()[:1] == ["fail"]]
    if not any(line.strip() for line in lines):
        log("no required problems to fix" if required else "nothing to fix")
        return 0

    print("problems:")
    for line in lines:
        print(f"  {line}")

    actions_to_run = [
        problem
        for problem in FIX_ORDER
        if any(
            re.match(rf"^(fail|warn) {re.escape(problem)}( |$)", line) for line in lines
        )
    ]
    manual = []
    for line in lines:
        fields = line.split()
        if len(fields) < 2 or fields[0] not in ("fail", "warn"):
            continue
        problem = fields[1]
        if problem not in FIX_SCRIPTS and problem not in manual:
            manual.append(problem)

    print("\nfixes:")
    if actions_to_run:
        for problem in actions_to_run:
            print(f"  {problem:<18} {_describe(problem)}")
    else:
        print("  none")
    print("manual:")
    if manual:
        for problem in manual:
            print(f"  {problem:<18} {_manual(problem)}")
    else:
        print("  none")

    if dry_run:
        log("dry run: nothing applied")
        return 0
    if not actions_to_run:
        log("no automatic fixes; follow the manual steps above")
        return 1

    if not assume_yes:
        count = len(actions_to_run)
        sys.stderr.write(f"Apply {count} fix(es) now? [y/N] ")
        sys.stderr.flush()
        try:
            with open("/dev/tty", encoding="utf-8") as tty:
                answer = tty.readline().strip()
        except OSError:
            answer = ""
        if answer not in ("y", "Y", "yes", "YES"):
            die("aborted")

    for problem in actions_to_run:
        log(f"fixing {problem} with {_describe(problem)}")
        if _run_fix(problem) != 0:
            log(f"warning: the {problem} fix failed")

    log("re-checking")
    remaining = capture([doctor, "--analyze"])
    remaining_lines = remaining.splitlines()
    if required:
        remaining_lines = [
            line for line in remaining_lines if line.split()[:1] == ["fail"]
        ]
    if any(line.strip() for line in remaining_lines):
        print("still open:")
        for line in remaining_lines:
            print(f"  {line}")
        return 1
    log("all reported problems are fixed")
    return 0
