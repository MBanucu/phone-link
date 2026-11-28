"""The doctor suite, case for case with tests/phone-doctor.test.sh.

Each method is one numbered section of the shell suite; ``CASES`` names the
section, the shell file's line and how many assertions it made, and
``test_case_inventory`` refuses to run if the two inventories disagree.  The
shell suite stays in place until this one is accepted, so a reviewer can run
both.
"""

from __future__ import annotations

import re
import textwrap
import unittest
from dataclasses import dataclass

from . import fixtures
from .fixtures import DUMPSYS
from .harness import BASH, ROOT, SHELL_SUITE, Case


@dataclass(frozen=True)
class ShellCase:
    """One numbered section of the shell suite and its Python replacement."""

    section: str
    shell_line: int
    test: str
    assertions: int


CASES: tuple[ShellCase, ...] = (
    ShellCase("1", 224, "test_case_01_ready_setup", 15),
    ShellCase("1b", 257, "test_case_01b_stock_wifi_globals", 3),
    ShellCase("2", 267, "test_case_02_no_phone", 5),
    ShellCase("3", 277, "test_case_03_locked_phone", 3),
    ShellCase("4", 284, "test_case_04_forwarding_off", 4),
    ShellCase("5", 295, "test_case_05_hotspot_mode", 5),
    ShellCase("6", 310, "test_case_06_dead_proxy", 2),
    ShellCase("6b", 317, "test_case_06b_listening_port_mismatch", 3),
    ShellCase("7", 328, "test_case_07_missing_secrets", 3),
    ShellCase("7b", 335, "test_case_07b_open_secrets_file", 2),
    ShellCase("8", 343, "test_case_08_inactive_tunnel", 3),
    ShellCase("9", 350, "test_case_09_usb_tether_off", 2),
    ShellCase("10", 356, "test_case_10_ap_down", 3),
    ShellCase("10b", 365, "test_case_10b_ap_units_stopped", 4),
    ShellCase("10c", 377, "test_case_10c_nft_drop", 4),
    ShellCase("10c2", 389, "test_case_10c2_module_nft_path", 5),
    ShellCase("10d", 419, "test_case_10d_no_station", 3),
    ShellCase("10d2", 432, "test_case_10d2_hint_needs_ssid", 3),
    ShellCase("10d3", 444, "test_case_10d3_external_role", 6),
    ShellCase("10d4", 472, "test_case_10d4_external_phone_away", 4),
    ShellCase("10d5", 495, "test_case_10d5_external_no_link", 5),
    ShellCase("10e", 520, "test_case_10e_missing_tools", 1),
    ShellCase("11", 549, "test_case_11_doze_allowlist", 3),
    ShellCase("12", 559, "test_case_12_auto_start_off", 2),
    ShellCase("12b", 566, "test_case_12b_state_file", 6),
    ShellCase("12c", 585, "test_case_12c_boot_set", 2),
    ShellCase("12c-2", 592, "test_case_12c2_battery_vs_oem", 4),
    ShellCase("12c-3", 605, "test_case_12c3_old_app_unknown", 2),
    ShellCase("12c-4", 614, "test_case_12c4_likely_blocked", 6),
    ShellCase("12c-5", 637, "test_case_12c5_old_blocked_line", 3),
    ShellCase("12d", 650, "test_case_12d_denied_grants", 16),
    ShellCase("12e", 673, "test_case_12e_undeclared_grant", 2),
    ShellCase("12f", 681, "test_case_12f_manifest_facts", 6),
    ShellCase("12g", 704, "test_case_12g_notifications_target", 2),
    ShellCase("13", 714, "test_case_13_missing_apk", 4),
    ShellCase("12-installed", 727, "test_case_12_installed", 5),
    ShellCase("14", 744, "test_case_14_old_lock", 2),
    ShellCase("14b", 767, "test_case_14b_matching_tag", 3),
    ShellCase("14c", 784, "test_case_14c_moved_tag", 3),
    ShellCase("14d", 798, "test_case_14d_branch_ahead", 2),
    ShellCase("14e", 811, "test_case_14e_lock_behind", 2),
    ShellCase("14f", 824, "test_case_14f_matching_branch", 2),
    ShellCase("14g", 837, "test_case_14g_checkout_ahead", 3),
    ShellCase("14h", 854, "test_case_14h_peeled_tag", 2),
    ShellCase("14i", 865, "test_case_14i_remote_only", 6),
    ShellCase("15", 890, "test_case_15_analyze", 9),
    ShellCase("16", 913, "test_case_16_mdns_reconnect", 3),
    ShellCase("17", 926, "test_case_17_refused_connect", 2),
    ShellCase("18", 936, "test_case_18_wireless_debugging_off", 3),
    ShellCase("19", 950, "test_case_19_pinned_port", 3),
    ShellCase("20", 964, "test_case_20_help", 1),
    ShellCase("release", 967, "test_case_99_release", 2),
)

SHELL_ASSERTIONS = 199
SHELL_SECTIONS = 51


class DoctorCase(Case):
    """The doctor's sandbox: the shared stubs plus a fresh healthy host."""

    ASSERTIONS = {case.test: case.assertions for case in CASES}

    def setUp(self) -> None:
        super().setUp()
        fixtures.install(self.sandbox)
        fixtures.fresh_state(self.sandbox)

    # -- 1 -------------------------------------------------------------
    def test_case_01_ready_setup(self) -> None:
        run = self.sandbox.run()
        self.assert_exit(run, 0, "ready setup exits 0")
        self.assert_contains(
            run,
            "verdict: required conditions are met; 1 optional condition(s) open",
            "reports the one open OEM gate",
        )
        self.assert_matches(
            run,
            r"warn  OEM autostart.*unknown: the DokeOS list is unreadable",
            "says the OEM gate is unreadable",
        )
        self.assert_absent(run, r"^FAIL", "no failures")
        self.assert_contains(run, "ok    adb device", "reports the adb device")
        self.assert_matches(
            run,
            r"proxy request.*192.168.77.232:1080 -> 200",
            "reports the proxy request",
        )
        self.assert_matches(
            run,
            r"ok    proxy port.*laptop 1080, phone 1080",
            "matches the laptop's port with the phone's",
        )
        self.assert_contains(run, "network transport", "reports adb over Wi-Fi")
        self.assert_matches(
            run,
            r"ok    wifi reconnect.*network_avoid_bad_wifi=0, "
            r"wifi_always_requested=1 \(recommended\)",
            "reports the Wi-Fi reconnect globals",
        )
        self.assert_matches(
            run,
            r"ok    ap role.*local \(this laptop owns the AP\)",
            "reports the local AP role",
        )
        self.assert_contains(run, "ok    ap dhcp", "checks the AP DHCP unit")
        self.assert_contains(run, "ok    ap noforward", "checks the AP no-forward unit")
        self.assert_contains(
            run, "ok    ap forward drop", "checks the nft forward drop"
        )
        self.assert_matches(
            run,
            r"ok    ap station.*1 on wlp110s0",
            "checks the phone association",
        )
        self.assert_matches(run, r"ok    secrets mode.*600", "checks the secrets mode")

    # -- 1b ------------------------------------------------------------
    def test_case_01b_stock_wifi_globals(self) -> None:
        self.sandbox.write_log("avoid", "1\n")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "stock Wi-Fi globals still exit 0")
        self.assert_matches(
            run,
            r"warn  wifi reconnect.*network_avoid_bad_wifi=1, "
            r"wifi_always_requested=1",
            "reports the stock value as a warning",
        )
        self.assert_contains(run, "run phone-wifi-reconnect", "names the explicit fix")

    # -- 2 -------------------------------------------------------------
    def test_case_02_no_phone(self) -> None:
        del self.sandbox.env["PHONE_SERIAL"]
        self.sandbox.write_log("devices", "List of devices attached\n")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "missing phone exits 1")
        self.assert_contains(run, "FAIL  adb device", "fails the adb condition")
        self.assert_contains(run, "skip  phone address", "skips phone checks")
        self.assert_contains(run, "ok    https", "still checks the internet")
        self.assert_contains(run, "setup is not ready", "verdict is not ready")

    # -- 3 -------------------------------------------------------------
    def test_case_03_locked_phone(self) -> None:
        self.sandbox.write_log("keyguard", "true\n")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "locked phone still exits 0")
        self.assert_contains(run, "warn  phone unlocked", "warns about the keyguard")
        self.assert_contains(run, "optional condition(s) open", "counts the warning")

    # -- 4 -------------------------------------------------------------
    def test_case_04_forwarding_off(self) -> None:
        self.sandbox.write_log("forward", "0\n")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "forwarding off still exits 0")
        self.assert_contains(run, "warn  ip_forward", "warns about ip_forward")
        self.assert_contains(
            run,
            "the link-only AP does not forward",
            "says forwarding is not needed",
        )
        analyze = self.sandbox.run("--analyze")
        self.assert_matches(
            analyze, r"^warn ip_forward ", "--analyze reports it as a warning"
        )

    # -- 5 -------------------------------------------------------------
    def test_case_05_hotspot_mode(self) -> None:
        self.sandbox.touch_log("ap_addr")
        self.sandbox.touch_log("nmcli_cons")
        self.sandbox.remove_log("ap-profile")
        self.sandbox.write_log(
            "ips",
            "2: wlan0    inet 10.244.108.165/24 brd 10.244.108.255 "
            "scope global wlan0\n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "hotspot mode exits 0")
        self.assert_contains(run, "warn  ap profile", "warns about the AP profile")
        self.assert_contains(run, "warn  ap address", "warns about the AP address")
        self.assert_matches(
            run,
            r"skip  ap units.*phoneLink.ap is off",
            "skips the module-only AP checks",
        )
        self.assert_matches(
            run,
            r"proxy request.*10.244.108.165:1080 -> 200",
            "checks the hotspot address",
        )

    # -- 6 -------------------------------------------------------------
    def test_case_06_dead_proxy(self) -> None:
        self.sandbox.write_log("proxy_code", "000")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "dead proxy exits 1")
        self.assert_matches(
            run,
            r"FAIL  proxy request.*-> 000",
            "fails the proxy request",
        )

    # -- 6b ------------------------------------------------------------
    def test_case_06b_listening_port_mismatch(self) -> None:
        (self.sandbox.root / "runtime-port").write_text("1081\n", encoding="utf-8")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "a port mismatch still exits 0")
        self.assert_matches(
            run,
            r"warn  proxy port.*laptop 1081, phone listens on 1080",
            "warns about the mismatch",
        )
        self.assert_contains(run, "run phone-proxy-switch", "says how to switch")
        (self.sandbox.root / "runtime-port").unlink()

    # -- 7 -------------------------------------------------------------
    def test_case_07_missing_secrets(self) -> None:
        run = self.sandbox.run(
            env={"PHONE_SECRETS": str(self.sandbox.root / "missing")}
        )
        self.assert_exit(run, 1, "missing secrets exits 1")
        self.assert_contains(run, "FAIL  secrets", "fails the secrets condition")
        self.assert_matches(
            run,
            r"FAIL  proxy request.*PHONE_SOCKS_PASS",
            "explains the missing password",
        )

    # -- 7b ------------------------------------------------------------
    def test_case_07b_open_secrets_file(self) -> None:
        secrets = self.sandbox.root / "secrets"
        secrets.chmod(0o644)
        run = self.sandbox.run()
        self.assert_exit(run, 0, "an open secrets file still exits 0")
        self.assert_matches(
            run,
            r"warn  secrets mode.*644 \(should be 600\)",
            "warns about the secrets mode",
        )
        secrets.chmod(0o600)

    # -- 8 -------------------------------------------------------------
    def test_case_08_inactive_tunnel(self) -> None:
        self.sandbox.write_log("tunnel", "inactive\n")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "inactive tunnel exits 0")
        self.assert_contains(run, "warn  phone-tun", "warns about the tunnel")
        self.assert_absent(run, r"tunnel route", "skips the tunnel route")

    # -- 9 -------------------------------------------------------------
    def test_case_09_usb_tether_off(self) -> None:
        self.sandbox.touch_log("rndis")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "tether off exits 0")
        self.assert_contains(run, "warn  rndis0", "warns about the tether")

    # -- 10 ------------------------------------------------------------
    def test_case_10_ap_down(self) -> None:
        self.sandbox.touch_log("ap_addr")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "AP down exits 1")
        self.assert_contains(run, "FAIL  ap address", "fails the AP address")
        analyze = self.sandbox.run("--analyze")
        self.assert_matches(analyze, r"^fail ap_address ", "--analyze names ap_address")

    # -- 10b -----------------------------------------------------------
    def test_case_10b_ap_units_stopped(self) -> None:
        self.sandbox.write_log("ap_dhcp", "inactive\n")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "a stopped AP DHCP unit exits 1")
        self.assert_matches(
            run,
            r"FAIL  ap dhcp.*inactive \(phone-link-ap-dhcp.service\)",
            "names the stopped DHCP unit",
        )
        fixtures.fresh_state(self.sandbox)
        self.sandbox.write_log("ap_noforward", "failed\n")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "a failed no-forward unit exits 1")
        self.assert_matches(
            run,
            r"FAIL  ap noforward.*failed "
            r"\(phone-link-ap-noforward.service\)",
            "names the failed no-forward unit",
        )

    # -- 10c -----------------------------------------------------------
    def test_case_10c_nft_drop(self) -> None:
        self.sandbox.remove_log("nft")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "a missing nft table exits 1")
        self.assert_matches(
            run,
            r"FAIL  ap forward drop.*table inet phone_link_ap missing",
            "names the missing nft table",
        )
        fixtures.fresh_state(self.sandbox)
        self.sandbox.write_log(
            "nft",
            "table inet phone_link_ap {\n"
            "\tchain forward {\n"
            "\t\tpolicy accept\n"
            "\t}\n"
            "}\n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 1, "a table without the drop exits 1")
        self.assert_matches(
            run,
            r"FAIL  ap forward drop.*no drop for wlp110s0",
            "names the missing drop",
        )

    # -- 10c2 ----------------------------------------------------------
    def test_case_10c2_module_nft_path(self) -> None:
        module_nft = self.sandbox.root / "module-nft"
        self.sandbox.write_script(
            module_nft,
            f"#!{BASH}\n"
            'printf "%s\\n" "$*" >>"$LOG/module_nft"\n'
            'case "$*" in\n'
            '  "list table inet phone_link_ap") cat "$LOG/nft" ;;\n'
            "  *) exit 1 ;;\n"
            "esac\n",
        )
        config = self.sandbox.root / "phone-link-env"
        config.write_text(f"PHONE_NFT='{module_nft}'\n", encoding="utf-8")
        nft = self.sandbox.bin / "nft"
        saved = self.sandbox.root / "nft.path"
        nft.rename(saved)

        run = self.sandbox.run()
        self.assert_exit(run, 0, "the module's nft path checks the forward drop")
        self.assert_matches(
            run,
            r"ok    ap forward drop.*wlp110s0 dropped",
            "reports the drop from the module's nft",
        )
        self.assert_equal(
            self.sandbox.read_log("module_nft").rstrip("\n"),
            "list table inet phone_link_ap",
            "ran the absolute nft path, not PATH",
        )
        self.sandbox.remove_log("nft")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "a failing module nft query exits 1")
        self.assert_matches(
            run,
            r"FAIL  ap forward drop.*table inet phone_link_ap missing",
            "keeps a failing query a failure",
        )
        saved.rename(nft)
        config.unlink()

    # -- 10d -----------------------------------------------------------
    def test_case_10d_no_station(self) -> None:
        self.sandbox.touch_log("iw_station")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "no station is a warning")
        self.assert_matches(
            run,
            r"warn  ap station.*no phone associated on wlp110s0; "
            r"run phone-wifi-connect PhoneLink",
            "names the missing station and the recovery command",
        )
        analyze = self.sandbox.run("--analyze")
        self.assert_matches(
            analyze,
            r"^warn ap_station .*phone-wifi-connect PhoneLink",
            "--analyze reports ap_station as a warning with the command",
        )

    # -- 10d2 ----------------------------------------------------------
    def test_case_10d2_hint_needs_ssid(self) -> None:
        self.sandbox.touch_log("iw_station")
        self.sandbox.touch_log("iw_info")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "AP down with no station exits 1")
        self.assert_matches(
            run,
            r"FAIL  ap station.*no phone associated on wlp110s0",
            "keeps the plain failure when the SSID is not up",
        )
        self.assert_absent(
            run,
            r"phone-wifi-connect PhoneLink",
            "does not print the hint when the AP is down",
        )

    # -- 10d3 ----------------------------------------------------------
    def test_case_10d3_external_role(self) -> None:
        self.sandbox.remove_log("ap-profile")
        self.sandbox.touch_log("nmcli_cons")
        self.sandbox.write_log("ap_addr", "wlp110s0 UP 192.168.50.20/24\n")
        self.sandbox.write_log(
            "iw_link",
            "Connected to aa:bb:cc:dd:ee:ff (on wlp110s0)\n\tSSID: PhoneLink\n",
        )
        self.sandbox.write_log(
            "ips",
            "2: wlan0    inet 192.168.50.20/24 brd 192.168.50.255 scope global wlan0\n",
        )
        run = self.sandbox.run(
            env={
                "PHONE_AP_ROLE": "external",
                "PHONE_PROXY_HOST": "192.168.50.20",
            }
        )
        self.assert_exit(run, 0, "external role exits 0 without a local AP profile")
        self.assert_matches(
            run,
            r"ok    ap role.*external \(another host owns the AP; "
            r"the laptop is a client\)",
            "reports the external role",
        )
        self.assert_matches(
            run,
            r"ok    external ap link.*client of PhoneLink on wlp110s0",
            "reports the laptop's external AP link",
        )
        self.assert_matches(
            run,
            r"ok    ap station.*phone 192.168.50.20 on PhoneLink",
            "reports the phone on the external AP",
        )
        self.assert_absent(
            run,
            r"FAIL  ap address|FAIL  ap profile|phoneLink\.ap is off",
            "does not require the local AP in external role",
        )
        self.assert_matches(
            run,
            r"proxy request.*192.168.50.20:1080 -> 200",
            "probes the reservation instead of the hotspot",
        )

    # -- 10d4 ----------------------------------------------------------
    def test_case_10d4_external_phone_away(self) -> None:
        self.sandbox.remove_log("ap-profile")
        self.sandbox.touch_log("nmcli_cons")
        self.sandbox.write_log("ap_addr", "wlp110s0 UP 192.168.50.20/24\n")
        self.sandbox.write_log(
            "iw_link",
            "Connected to aa:bb:cc:dd:ee:ff (on wlp110s0)\n\tSSID: PhoneLink\n",
        )
        self.sandbox.write_log("ips", fixtures.RNDIS)
        run = self.sandbox.run(
            env={
                "PHONE_AP_ROLE": "external",
                "PHONE_PROXY_HOST": "192.168.50.20",
            }
        )
        self.assert_exit(run, 1, "a missing external association is a required failure")
        self.assert_matches(
            run,
            r"warn  ap station.*phone 192.168.50.20 is not on PhoneLink.*"
            r"phone-wifi-connect PhoneLink",
            "names the missing external association and the command",
        )
        self.assert_matches(
            run,
            r"FAIL  phone address.*192.168.50.20 not on the phone",
            "the phone address check agrees the reservation is absent",
        )
        self.assert_absent(
            run,
            r"FAIL  ap station|AP down",
            "does not blame the external AP",
        )

    # -- 10d5 ----------------------------------------------------------
    def test_case_10d5_external_no_link(self) -> None:
        self.sandbox.remove_log("ap-profile")
        self.sandbox.touch_log("nmcli_cons")
        self.sandbox.touch_log("ap_addr")
        self.sandbox.write_log("iw_link", "Not connected.\n")
        self.sandbox.write_log(
            "ips",
            "2: wlan0    inet 192.168.50.20/24 brd 192.168.50.255 scope global wlan0\n",
        )
        run = self.sandbox.run(
            env={
                "PHONE_AP_ROLE": "external",
                "PHONE_PROXY_HOST": "192.168.50.20",
            }
        )
        self.assert_exit(run, 0, "a missing external AP link is not a required failure")
        self.assert_matches(
            run, r"ok    ap role.*external", "still reports the external role"
        )
        self.assert_matches(
            run,
            r"warn  ap address.*no IPv4 \(not joined to the external AP\)",
            "warns about the missing client address",
        )
        self.assert_matches(
            run,
            r"warn  external ap link.*not a client of PhoneLink",
            "warns about the missing client link",
        )
        self.assert_absent(
            run,
            r"FAIL  ap address|AP down",
            "does not call the external AP down",
        )

    # -- 10e -----------------------------------------------------------
    def test_case_10e_missing_tools(self) -> None:
        marker = self.sandbox.log / "ap-profile"
        marker.write_text("phonelink\n", encoding="utf-8")
        code = textwrap.dedent(
            """\
            import sys

            from phone_doctor.checks import ap
            from phone_doctor.context import Context

            ctx = Context(
                {
                    "PATH": "/nonexistent",
                    "PHONE_AP_DECLARATIVE": sys.argv[1],
                    "PHONE_CONFIG_FILE": sys.argv[2],
                }
            )
            results = ap.check(ctx)
            assert len(results) == 6, results
            assert results[0].cid == "ap_role" and results[0].status.value == "ok", results
            assert all(r.status.value == "skip" for r in results[1:]), results
            channel = next(r for r in results if r.cid == "ap_channel")
            assert channel.detail == "iw not installed", channel
            forward = next(r for r in results if r.cid == "ap_noforward_rules")
            assert forward.detail == "nft not installed", forward
            assert ctx.nft is None, ctx.nft
            print("skipped: " + " ".join(r.cid for r in results))
            """
        )
        run = self.sandbox.run_python(
            code,
            str(marker),
            str(self.sandbox.log / "no-env"),
            env={"PYTHONPATH": str(ROOT / "lib" / "python")},
        )
        self.assert_exit(run, 0, "missing tools only skip")

    # -- 11 ------------------------------------------------------------
    def test_case_11_doze_allowlist(self) -> None:
        self.sandbox.touch_log("whitelist")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "app off the allowlist exits 1")
        self.assert_matches(
            run,
            r"FAIL  restarts at boot.*battery allowlist",
            "fails app_boot",
        )
        analyze = self.sandbox.run("--analyze")
        self.assert_matches(analyze, r"^fail app_boot ", "--analyze names app_boot")

    # -- 12 ------------------------------------------------------------
    def test_case_12_auto_start_off(self) -> None:
        self.sandbox.write_log("service_dump", "      auto-start  false\n")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "auto_start off exits 1")
        self.assert_matches(
            run,
            r"FAIL  restarts at boot.*auto_start is off",
            "names the switch",
        )

    # -- 12b -----------------------------------------------------------
    def test_case_12b_state_file(self) -> None:
        self.sandbox.touch_log("service_dump")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "a stopped app still passes its boot check")
        self.assert_matches(
            run,
            r"ok    restarts at boot.*auto_start on",
            "reads auto_start from the state file",
        )
        self.sandbox.write_log("app_state", "auto_start false\n")
        run = self.sandbox.run()
        self.assert_exit(run, 1, "a stopped app with auto_start off exits 1")
        self.assert_matches(
            run,
            r"FAIL  restarts at boot.*auto_start is off",
            "and names the switch it read",
        )
        self.sandbox.touch_log("app_state")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "no answer still exits 0")
        self.assert_matches(
            run,
            r"warn  restarts at boot.*state file answered",
            "says both places were asked",
        )

    # -- 12c -----------------------------------------------------------
    def test_case_12c_boot_set(self) -> None:
        run = self.sandbox.run()
        self.assert_exit(run, 0, "the full boot set passes")
        self.assert_matches(
            run,
            r"ok    restarts at boot.*auto_start on, allowlisted, "
            r"fine\+coarse location granted, background location granted, "
            r"notifications granted, boot_completed granted, "
            r"direct boot aware",
            "names the whole pre-unlock boot set",
        )

    # -- 12c-2 ---------------------------------------------------------
    def test_case_12c2_battery_vs_oem(self) -> None:
        run = self.sandbox.run()
        self.assert_exit(run, 0, "a battery-clear phone exits 0")
        self.assert_matches(
            run,
            r"ok    restarts at boot.*allowlisted",
            "still reports the battery gate clear",
        )
        self.assert_matches(
            run,
            r"warn  OEM autostart.*unknown: the DokeOS list is unreadable.*"
            r"separate gate",
            "does not turn the battery clear into an OEM clear",
        )
        self.assert_absent(
            run,
            r"^ok *.*OEM autostart",
            "the OEM gate is never reported ok",
        )

    # -- 12c-3 ---------------------------------------------------------
    def test_case_12c3_old_app_unknown(self) -> None:
        self.sandbox.write_log(
            "app_state",
            "auto_start true\nadb_wifi true\nport 1080\nssid PhoneLink\n"
            "any_network false\nin_use \n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "an old app with no OEM fact exits 0")
        self.assert_matches(
            run,
            r"warn  OEM autostart.*unknown: this app does not report "
            r"the DokeOS gate",
            "a missing fact is unknown",
        )

    # -- 12c-4 ---------------------------------------------------------
    def test_case_12c4_likely_blocked(self) -> None:
        self.sandbox.write_log(
            "app_state",
            "auto_start true\nadb_wifi true\nport 1080\nssid PhoneLink\n"
            "any_network false\nin_use \noem_autostart unreadable\n"
            "last_boot no_broadcast 1700000000\n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "a likely-blocked boot still exits 0")
        self.assert_matches(
            run,
            r"warn  OEM autostart.*likely blocked this boot "
            r"\(noticed 2023-11-14 22:13 UTC\)",
            "dates the likely-blocked boot",
        )
        self.assert_contains(
            run,
            "System Manager → App Management → Auto Start Management",
            "names the DokeOS screen",
        )
        self.assert_contains(
            run,
            "wireless-adb-keeper/autostart-allow.sh",
            "names the adb driver",
        )
        self.assert_contains(
            run,
            "phone-link-tools/autotoggle",
            "names the accessibility driver",
        )
        analyze = self.sandbox.run("--analyze")
        self.assert_matches(
            analyze,
            r"^warn app_oem_autostart .*likely blocked",
            "--analyze names the OEM check",
        )

    # -- 12c-5 ---------------------------------------------------------
    def test_case_12c5_old_blocked_line(self) -> None:
        self.sandbox.write_log(
            "app_state",
            "auto_start true\nadb_wifi true\nport 1080\nssid PhoneLink\n"
            "any_network false\nin_use \noem_autostart unreadable\n"
            "last_boot blocked 1700000000\n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "an old-style blocked line still exits 0")
        self.assert_matches(
            run,
            r"warn  OEM autostart.*unknown: the DokeOS list is unreadable",
            "an old blocked line is treated as unknown",
        )
        self.assert_absent(
            run, r"likely blocked this boot", "an old blocked line is not proof"
        )

    # -- 12d -----------------------------------------------------------
    def test_case_12d_denied_grants(self) -> None:
        entries = (
            ("ACCESS_COARSE_LOCATION", "coarse location is not granted"),
            ("ACCESS_FINE_LOCATION", "fine location is not granted"),
            (
                "ACCESS_BACKGROUND_LOCATION",
                "background location is not granted",
            ),
            ("POST_NOTIFICATIONS", "notifications are not granted"),
        )
        for permission, phrase in entries:
            with self.subTest(permission=permission):
                fixtures.fresh_state(self.sandbox)
                granted = f"android.permission.{permission}: granted=true"
                denied = f"android.permission.{permission}: granted=false"
                self.sandbox.write_log("dumpsys", DUMPSYS.replace(granted, denied))
                run = self.sandbox.run()
                self.assert_exit(run, 1, f"{permission} denied exits 1")
                self.assert_matches(
                    run,
                    rf"FAIL  restarts at boot.*{re.escape(phrase)}",
                    f"names the denied {permission}",
                )
                self.assert_contains(
                    run,
                    "run phone-proxy-boot",
                    f"a denied {permission} points at the fixer",
                )
                self.assert_absent(
                    run,
                    r"reinstall the release",
                    f"a denied {permission} is not called a manifest fact",
                )

    # -- 12e -----------------------------------------------------------
    def test_case_12e_undeclared_grant(self) -> None:
        self.sandbox.write_log(
            "dumpsys",
            DUMPSYS.replace(
                "    android.permission.ACCESS_FINE_LOCATION: granted=true\n",
                "",
            ),
        )
        run = self.sandbox.run()
        self.assert_exit(run, 1, "an undeclared grant exits 1")
        self.assert_matches(
            run,
            r"FAIL  restarts at boot.*the build does not declare "
            r"fine location.*reinstall the release",
            "an undeclared grant asks for a reinstall",
        )

    # -- 12f -----------------------------------------------------------
    def test_case_12f_manifest_facts(self) -> None:
        self.sandbox.write_log(
            "dumpsys",
            DUMPSYS.replace(
                "    android.permission.RECEIVE_BOOT_COMPLETED: granted=true\n",
                "",
            ),
        )
        run = self.sandbox.run()
        self.assert_exit(run, 1, "no boot permission exits 1")
        self.assert_matches(
            run,
            r"FAIL  restarts at boot.*RECEIVE_BOOT_COMPLETED is not "
            r"granted.*reinstall the release",
            "names the missing boot permission",
        )
        fixtures.fresh_state(self.sandbox)
        self.sandbox.write_log(
            "dumpsys",
            DUMPSYS.replace(" PARTIALLY_DIRECT_BOOT_AWARE", ""),
        )
        run = self.sandbox.run()
        self.assert_exit(run, 1, "no direct-boot flag exits 1")
        self.assert_matches(
            run,
            r"FAIL  restarts at boot.*this build is not direct-boot "
            r"aware.*reinstall the release",
            "names the missing direct-boot flag",
        )
        fixtures.fresh_state(self.sandbox)
        self.sandbox.write_log("dumpsys", DUMPSYS.split("Receiver Resolver Table:")[0])
        run = self.sandbox.run()
        self.assert_exit(run, 1, "no locked-boot receiver exits 1")
        self.assert_matches(
            run,
            r"FAIL  restarts at boot.*no receiver handles "
            r"LOCKED_BOOT_COMPLETED.*reinstall the release",
            "names the missing locked-boot receiver",
        )

    # -- 12g -----------------------------------------------------------
    def test_case_12g_notifications_target(self) -> None:
        self.sandbox.write_log(
            "dumpsys",
            DUMPSYS.replace("targetSdk=34", "targetSdk=32").replace(
                "    android.permission.POST_NOTIFICATIONS: granted=true\n",
                "",
            ),
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "targetSdk 32 needs no notification grant")
        self.assert_absent(
            run,
            r"ok    restarts at boot.*notifications",
            "does not name notifications when not required",
        )

    # -- 13 ------------------------------------------------------------
    def test_case_13_missing_apk(self) -> None:
        missing = self.sandbox.root / "missing.apk"
        run = self.sandbox.run(env={"PHONE_PROXY_APK": str(missing)})
        self.assert_exit(run, 1, "missing APK exits 1")
        self.assert_matches(
            run,
            rf"FAIL  app apk.*{re.escape(str(missing))} is not there",
            "fails the app apk check",
        )
        fixtures.fresh_state(self.sandbox)
        run = self.sandbox.run()
        self.assert_exit(run, 0, "the named APK passes")
        self.assert_matches(
            run,
            rf"ok    app apk.*{re.escape(str(self.sandbox.root / 'app.apk'))}",
            "passes with the APK it was given",
        )

    # -- the shell's second "12.": the installed version ---------------
    def test_case_12_installed(self) -> None:
        run = self.sandbox.run()
        self.assert_exit(run, 0, "the installed app exits 0")
        self.assert_matches(
            run,
            r"ok    proxy version.*0\.1\.0 \(1\)",
            "reports the installed version",
        )
        fixtures.fresh_state(self.sandbox)
        self.sandbox.write_log(
            "dumpsys",
            "    versionCode=24 minSdk=26 targetSdk=34\n"
            "    versionName=1.7.4\n"
            "    flags=[ HAS_CODE ]\n"
            "    privateFlags=[ PARTIALLY_DIRECT_BOOT_AWARE ]\n"
            "    android.permission.ACCESS_FINE_LOCATION: granted=true\n"
            "    android.permission.ACCESS_COARSE_LOCATION: granted=true\n"
            "    android.permission.ACCESS_BACKGROUND_LOCATION: granted=true\n"
            "    android.permission.POST_NOTIFICATIONS: granted=true\n"
            "    android.permission.RECEIVE_BOOT_COMPLETED: granted=true\n"
            "Receiver Resolver Table:\n"
            "  Non-Data Actions:\n"
            "      android.intent.action.LOCKED_BOOT_COMPLETED:\n"
            "        38b0d9 org.phonelink.proxy/.BootReceiver filter edb9a9e\n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "another version still exits 0")
        self.assert_matches(
            run,
            r"ok    proxy version.*1\.7\.4 \(24\)",
            "reports it without comparing",
        )
        self.assert_matches(
            run,
            r"ok    proxy compat.*minSdk 26 <= phone SDK 35",
            "checks the SDK compatibility",
        )

    # -- 14 ------------------------------------------------------------
    def test_case_14_old_lock(self) -> None:
        (self.sandbox.root / "src" / ".git").mkdir(parents=True)
        (self.sandbox.root / "nixos").mkdir()
        (self.sandbox.root / "nixos" / "flake.lock").write_text(
            "{\n"
            '  "nodes": {\n'
            '    "phone-link": {\n'
            '      "locked": {\n'
            '        "lastModified": 100\n'
            "      }\n"
            "    }\n"
            "  }\n"
            "}\n",
            encoding="utf-8",
        )
        run = self.sandbox.run(
            env={
                "PHONE_FLAKE_SRC": str(self.sandbox.root / "src"),
                "PHONE_NIXOS_DIR": str(self.sandbox.root / "nixos"),
            }
        )
        self.assert_exit(run, 0, "stale flake still exits 0")
        self.assert_matches(
            run, r"warn  flake update.*older", "warns about the stale lock"
        )

    # -- 14b -----------------------------------------------------------
    def test_case_14b_matching_tag(self) -> None:
        fixtures.fresh_state(self.sandbox)
        (self.sandbox.root / "src" / ".git").mkdir(parents=True)
        fixtures.flake_lock(self.sandbox, "v0.18.0", "c1cc38100000")
        self.sandbox.write_log("local_head", "111111111111\n")
        self.sandbox.write_log("head_time", "300\n")
        self.sandbox.write_log(
            "remote_refs",
            "c1cc38100000\trefs/tags/v0.18.0\nc1cc38100000\trefs/tags/v0.18.0^{}\n",
        )
        run = self.sandbox.run(
            env={
                "PHONE_FLAKE_SRC": str(self.sandbox.root / "src"),
                "PHONE_NIXOS_DIR": str(self.sandbox.root / "nixos"),
            }
        )
        self.assert_exit(run, 0, "a matching tag pin still exits 0")
        self.assert_matches(
            run,
            r"ok    flake update.*up to date \(c1cc38100000\)",
            "accepts a lock that matches its tag",
        )
        self.assert_absent(run, r"warn  flake update", "ignores a newer checkout HEAD")

    # -- 14c -----------------------------------------------------------
    def test_case_14c_moved_tag(self) -> None:
        (self.sandbox.root / "src" / ".git").mkdir(parents=True)
        fixtures.flake_lock(self.sandbox, "v0.18.0", "aaaaaaaaaaaa")
        self.sandbox.write_log(
            "remote_refs",
            "bbbbbbbbbbbb\trefs/tags/v0.18.0\nbbbbbbbbbbbb\trefs/tags/v0.18.0^{}\n",
        )
        run = self.sandbox.run(
            env={
                "PHONE_FLAKE_SRC": str(self.sandbox.root / "src"),
                "PHONE_NIXOS_DIR": str(self.sandbox.root / "nixos"),
            }
        )
        self.assert_exit(run, 0, "a moved tag still exits 0")
        self.assert_matches(
            run,
            r"warn  flake update.*the lock has aaaaaaaaaaaa, "
            r"tag v0\.18\.0 is at bbbbbbbbbbbb",
            "warns when the lock and the tag disagree",
        )
        self.assert_contains(
            run, "a tag should not move", "says the tag should not move"
        )

    # -- 14d -----------------------------------------------------------
    def test_case_14d_branch_ahead(self) -> None:
        (self.sandbox.root / "src" / ".git").mkdir(parents=True)
        fixtures.flake_lock(self.sandbox, "main", "aaaaaaaaaaaa")
        self.sandbox.write_log("local_head", "aaaaaaaaaaaa\n")
        self.sandbox.write_log(
            "remote_refs",
            "bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n",
        )
        run = self.sandbox.run(
            env={
                "PHONE_FLAKE_SRC": str(self.sandbox.root / "src"),
                "PHONE_NIXOS_DIR": str(self.sandbox.root / "nixos"),
            }
        )
        self.assert_exit(run, 0, "a branch pin ahead of the lock still exits 0")
        self.assert_matches(
            run,
            r"warn  flake update.*origin has newer commits "
            r"\(git pull, then rebuild\)",
            "warns when the branch is ahead",
        )

    # -- 14e -----------------------------------------------------------
    def test_case_14e_lock_behind(self) -> None:
        (self.sandbox.root / "src" / ".git").mkdir(parents=True)
        fixtures.flake_lock(self.sandbox, "main", "aaaaaaaaaaaa")
        self.sandbox.write_log("local_head", "bbbbbbbbbbbb\n")
        self.sandbox.write_log(
            "remote_refs",
            "bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n",
        )
        run = self.sandbox.run(
            env={
                "PHONE_FLAKE_SRC": str(self.sandbox.root / "src"),
                "PHONE_NIXOS_DIR": str(self.sandbox.root / "nixos"),
            }
        )
        self.assert_exit(run, 0, "a lock behind the branch still exits 0")
        self.assert_matches(
            run,
            r"warn  flake update.*system lock is older than .* HEAD",
            "warns that the lock is behind the branch",
        )

    # -- 14f -----------------------------------------------------------
    def test_case_14f_matching_branch(self) -> None:
        (self.sandbox.root / "src" / ".git").mkdir(parents=True)
        fixtures.flake_lock(self.sandbox, "main", "bbbbbbbbbbbb")
        self.sandbox.write_log("local_head", "aaaaaaaaaaaa\n")
        self.sandbox.write_log(
            "remote_refs",
            "bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n",
        )
        run = self.sandbox.run(
            env={
                "PHONE_FLAKE_SRC": str(self.sandbox.root / "src"),
                "PHONE_NIXOS_DIR": str(self.sandbox.root / "nixos"),
            }
        )
        self.assert_exit(run, 0, "a lock matching the branch still exits 0")
        self.assert_matches(
            run,
            r"warn  flake update.*origin has newer commits",
            "reports a checkout behind origin",
        )

    # -- 14g -----------------------------------------------------------
    def test_case_14g_checkout_ahead(self) -> None:
        (self.sandbox.root / "src" / ".git").mkdir(parents=True)
        fixtures.flake_lock(self.sandbox, "main", "bbbbbbbbbbbb")
        self.sandbox.write_log("local_head", "cccccccccccc\n")
        self.sandbox.write_log("ancestor", "yes\n")
        self.sandbox.write_log(
            "remote_refs",
            "bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n",
        )
        run = self.sandbox.run(
            env={
                "PHONE_FLAKE_SRC": str(self.sandbox.root / "src"),
                "PHONE_NIXOS_DIR": str(self.sandbox.root / "nixos"),
            }
        )
        self.assert_exit(run, 0, "a checkout ahead of the branch still exits 0")
        self.assert_matches(
            run,
            r"ok    flake update.*up to date \(bbbbbbbbbbbb\)",
            "does not call an ahead checkout stale",
        )
        self.assert_absent(
            run,
            r"warn  flake update",
            "keeps a branch lock matching origin quiet",
        )

    # -- 14h -----------------------------------------------------------
    def test_case_14h_peeled_tag(self) -> None:
        fixtures.flake_lock(self.sandbox, "v0.19.0", "bbbbbbbbbbbb")
        self.sandbox.write_log(
            "remote_refs",
            "aaaaaaaaaaaa\trefs/tags/v0.19.0\nbbbbbbbbbbbb\trefs/tags/v0.19.0^{}\n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "a peeled tag still exits 0")
        self.assert_matches(
            run,
            r"ok    flake update.*up to date \(bbbbbbbbbbbb\)",
            "prefers the peeled commit",
        )

    # -- 14i -----------------------------------------------------------
    def test_case_14i_remote_only(self) -> None:
        fixtures.flake_lock(self.sandbox, "main", "aaaaaaaaaaaa")
        self.sandbox.write_log(
            "remote_refs",
            "bbbbbbbbbbbb\tHEAD\nbbbbbbbbbbbb\trefs/heads/main\n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "an outdated remote lock still exits 0")
        self.assert_matches(
            run,
            r"warn  flake update.*origin is at bbbbbbbbbbbb, "
            r"the lock has aaaaaaaaaaaa",
            "warns when the lock is behind the remote",
        )
        fixtures.flake_lock(self.sandbox, "main", "bbbbbbbbbbbb")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "a matching remote still exits 0")
        self.assert_matches(
            run,
            r"ok    flake update.*up to date \(bbbbbbbbbbbb\)",
            "accepts a matching remote",
        )
        self.sandbox.touch_log("remote_refs")
        self.sandbox.touch_log("remote_head")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "an unreachable remote still exits 0")
        self.assert_matches(
            run,
            r"skip  flake update.*unreachable",
            "skips an unreachable remote",
        )
        (self.sandbox.root / "nixos" / "flake.lock").unlink()

    # -- 15 ------------------------------------------------------------
    def test_case_15_analyze(self) -> None:
        run = self.sandbox.run("--analyze")
        self.assert_exit(run, 0, "--analyze on a ready setup exits 0")
        self.assert_matches(
            run,
            r"^warn app_oem_autostart ",
            "--analyze names the unreadable OEM gate",
        )
        self.assert_absent(
            run,
            r"^(ok|fail|skip) ",
            "--analyze has only the OEM warning",
        )
        fixtures.fresh_state(self.sandbox)
        del self.sandbox.env["PHONE_SERIAL"]
        self.sandbox.write_log("devices", "List of devices attached\n")
        run = self.sandbox.run("--analyze")
        self.assert_exit(run, 1, "--analyze with problems exits 1")
        self.assert_matches(run, r"^fail adb_device ", "--analyze names the problem id")
        self.assert_absent(run, r"^ok ", "--analyze omits ok lines")
        self.assert_absent(run, r"^\[", "--analyze omits section headers")
        fixtures.fresh_state(self.sandbox)
        self.sandbox.write_log("keyguard", "true\n")
        run = self.sandbox.run("--analyze")
        self.assert_exit(run, 0, "--analyze with only warnings exits 0")
        self.assert_matches(run, r"^warn phone_unlocked ", "--analyze reports warnings")

    # -- 16 ------------------------------------------------------------
    def test_case_16_mdns_reconnect(self) -> None:
        self.sandbox.write_log(
            "devices", "List of devices attached\nXPLO2EEA0001541\tdevice\n"
        )
        self.sandbox.write_log(
            "avahi",
            "=;wlp110s0;IPv4;adb-XPLO2EEA0001541-D1gkYk;"
            "_adb-tls-connect._tcp;local;Android.local;192.168.77.232;"
            '44895;"v=ADB_SECURE_SERVICE_VERSION"\n',
        )
        self.sandbox.touch_log("connect_ok")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "a rotated adb port still exits 0")
        self.assert_matches(
            run,
            r"network transport.*192.168.77.232:44895",
            "reports the port from mDNS",
        )
        self.assert_text_contains(
            self.sandbox.read_log("connected"),
            "192.168.77.232:44895",
            "connects with adb",
        )

    # -- 17 ------------------------------------------------------------
    def test_case_17_refused_connect(self) -> None:
        self.sandbox.write_log(
            "devices", "List of devices attached\nXPLO2EEA0001541\tdevice\n"
        )
        self.sandbox.write_log(
            "avahi",
            "=;wlp110s0;IPv4;adb-XPLO2EEA0001541-D1gkYk;"
            "_adb-tls-connect._tcp;local;Android.local;192.168.77.232;"
            "44895;\n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "a refused connect still exits 0")
        self.assert_contains(
            run,
            "is advertised but adb connect failed",
            "names the advertised address",
        )

    # -- 18 ------------------------------------------------------------
    def test_case_18_wireless_debugging_off(self) -> None:
        self.sandbox.write_log(
            "devices", "List of devices attached\nXPLO2EEA0001541\tdevice\n"
        )
        self.sandbox.write_log(
            "avahi",
            "+;wlp110s0;IPv6;adb-XPLO2EEA0001541-D1gkYk;"
            "_adb-tls-connect._tcp;local\n"
            "+;wlp110s0;IPv4;adb-XPLO2EEA0001541-D1gkYk;"
            "_adb-tls-connect._tcp;local\n",
        )
        run = self.sandbox.run()
        self.assert_exit(run, 0, "an unresolved announcement still exits 0")
        self.assert_contains(
            run,
            "announced with no address: wireless debugging is off",
            "names wireless debugging as the fault",
        )
        self.assert_absent(run, r"USB only", "does not fall back to USB only")

    # -- 19 ------------------------------------------------------------
    def test_case_19_pinned_port(self) -> None:
        self.sandbox.remove_log("deny")
        self.sandbox.write_log(
            "devices", "List of devices attached\nXPLO2EEA0001541\tdevice\n"
        )
        self.sandbox.touch_log("connect_ok")
        run = self.sandbox.run()
        self.assert_exit(run, 0, "a pinned adb port still exits 0")
        self.assert_matches(
            run,
            r"network transport.*192.168.77.232:5555",
            "reports the pinned port",
        )
        self.assert_text_contains(
            self.sandbox.read_log("connected"),
            "192.168.77.232:5555",
            "connects to the pinned port",
        )

    # -- 20 ------------------------------------------------------------
    def test_case_20_help(self) -> None:
        run = self.sandbox.run("--help")
        self.assert_exit(run, 0, "--help exits 0")

    # -- the release check (unnumbered in the shell) -------------------
    def test_case_99_release(self) -> None:
        cache = (
            self.sandbox.cache
            / "phone-link"
            / "latest-release-MBanucu-phone-link-proxy"
        )
        cache.unlink(missing_ok=True)
        self.sandbox.write_log("release_json", '{"tag_name": "v9.9.9"}')
        fixtures.fresh_state(self.sandbox)
        run = self.sandbox.run("--analyze")
        self.assert_matches(run, r"^warn *app_release", "names a newer release")
        self.assert_contains(
            run,
            "run phone-proxy-install --release",
            "says how to get it",
        )
        cache.unlink(missing_ok=True)
        self.sandbox.remove_log("release_json")

    # -- parity --------------------------------------------------------
    def test_case_inventory(self) -> None:
        """Every shell section has one Python test, and the counts agree."""
        names = {
            name
            for name in dir(type(self))
            if name.startswith("test_case_") and name != "test_case_inventory"
        }
        self.assertEqual(
            {case.test for case in CASES},
            names,
            "CASES and the test methods disagree",
        )
        self.assertEqual(len(CASES), 52)
        self.assertEqual(len({case.section for case in CASES}), 52)
        self.assertEqual(sum(case.assertions for case in CASES), SHELL_ASSERTIONS)
        text = SHELL_SUITE.read_text(encoding="utf-8")
        sections = {
            number
            for number, line in enumerate(text.splitlines(), 1)
            if re.match(r"^# [0-9][0-9a-z-]*\.", line)
        }
        self.assertEqual(len(sections), SHELL_SECTIONS, "the shell suite changed shape")
        self.assertEqual(
            sections,
            {case.shell_line for case in CASES if case.section != "release"},
            "a shell section is not mapped to a Python test",
        )


if __name__ == "__main__":
    unittest.main()
