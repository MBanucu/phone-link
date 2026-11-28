"""The doctor suite's fixtures, in one place.

``install`` puts the fake commands and the secrets file in the sandbox;
``fresh_state`` writes the two transports, the AP, the app and the flake the
way a healthy host has them, exactly as the shell suite's ``fresh_state`` did.
A case then changes the one file it is about.
"""

from __future__ import annotations

from .harness import Sandbox
from .stubs import ANSWERS

DEVICES = (
    "List of devices attached\nXPLO2EEA0001541\tdevice\n192.168.77.232:5555\tdevice\n"
)
IPS = (
    "2: wlan0    inet 192.168.77.232/24 brd 192.168.77.255 scope global wlan0\n"
    "3: rndis0    inet 10.9.9.9/24 brd 10.9.9.255 scope global rndis0\n"
)
RNDIS = "3: rndis0    inet 10.9.9.9/24 brd 10.9.9.255 scope global rndis0\n"
NFT_DROP = (
    "table inet phone_link_ap {\n"
    "\tchain forward {\n"
    '\t\tiifname "wlp110s0" drop\n'
    "\t}\n"
    "}\n"
)
DUMPSYS = (
    "    versionCode=1 minSdk=26 targetSdk=34\n"
    "    versionName=0.1.0\n"
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
    "        38b0d9 org.phonelink.proxy/.BootReceiver filter edb9a9e\n"
)
SERVICE_DUMP = "      running     port 1080 · 0 clients\n      auto-start  true\n"
APP_STATE = (
    "auto_start true\n"
    "adb_wifi true\n"
    "port 1080\n"
    "ssid PhoneLink\n"
    "any_network false\n"
    "in_use \n"
    "oem_autostart unreadable\n"
)


def install(sandbox: Sandbox) -> None:
    """The stubs every doctor case runs against, and the secrets file."""
    for name, body in ANSWERS.items():
        sandbox.stub(name)
        sandbox.answer(name, body)
    sandbox.secrets(
        "PHONE_SOCKS_PASS=pass\nPHONE_PIN=1234\nPHONE_AP_PASS=pass\n",
    )


def flake_lock(sandbox: Sandbox, ref: str, rev: str) -> None:
    """Write the installed lock, tracking REF at REV (a GitHub input)."""
    if ref:
        original = (
            '"original": {"owner": "MBanucu", "repo": "phone-link", '
            f'"type": "github", "ref": "{ref}"}},'
        )
    else:
        original = (
            '"original": {"owner": "MBanucu", "repo": "phone-link", "type": "github"},'
        )
    lock = (
        f'{{ "nodes": {{ "phone-link": {{ {original} "locked": '
        f'{{"lastModified": 100, "rev": "{rev}", "type": "github"}} }} }} }}\n'
    )
    (sandbox.root / "nixos").mkdir(parents=True, exist_ok=True)
    (sandbox.root / "nixos" / "flake.lock").write_text(lock, encoding="utf-8")


def fresh_state(sandbox: Sandbox) -> None:
    """The healthy host, as the shell suite wrote it before each case."""
    sandbox.env["PHONE_SERIAL"] = "XPLO2EEA0001541"
    sandbox.write_log("devices", DEVICES)
    sandbox.write_log("keyguard", "false\n")
    sandbox.write_log("ips", IPS)
    sandbox.write_log("default_route", "default via 10.0.0.1 dev wlan0\n")
    sandbox.write_log("rndis", RNDIS)
    sandbox.write_log("pm", "package:/data/app/base.apk\n")
    sandbox.write_log("ap_addr", "wlp110s0 UP 192.168.77.1/24\n")
    sandbox.write_log("nmcli_cons", "phonelink\n")
    sandbox.write_log("ap-profile", "phonelink\n")
    sandbox.write_log("ap_dhcp", "active\n")
    sandbox.write_log("ap_noforward", "active\n")
    sandbox.write_log("nft", NFT_DROP)
    sandbox.write_log("iw_station", "Station aa:bb:cc:dd:ee:ff (on wlp110s0)\n")
    sandbox.write_log("iw_info", "ssid PhoneLink\n")
    sandbox.write_log(
        "iw_link",
        "Connected to aa:bb:cc:dd:ee:ff (on wlp110s0)\n\tSSID: PhoneLink\n",
    )
    sandbox.write_log("avoid", "0\n")
    sandbox.write_log("always", "1\n")
    sandbox.write_log("forward", "1\n")
    sandbox.write_log("tunnel", "active\n")
    sandbox.write_log("rules", "2022: from all fwmark 0x7e6 lookup 2022\n")
    sandbox.write_log("proxy_code", "200")
    sandbox.write_log("internet_code", "200")
    sandbox.write_log("resolv.conf", "nameserver 1.1.1.1\nnameserver 9.9.9.9\n")
    sandbox.write_log("dumpsys", DUMPSYS)
    sandbox.write_log("service_dump", SERVICE_DUMP)
    sandbox.write_log("app_state", APP_STATE)
    sandbox.write_log("whitelist", "user,org.phonelink.proxy,10332\n")
    sandbox.write_log("sdk", "35\n")
    # The APK a repair would use is a file here, so the check reports what it
    # was given and nothing else; the version is whatever the phone says.
    (sandbox.root / "app.apk").write_text("", encoding="utf-8")
    sandbox.touch_log("avahi")
    sandbox.touch_log("connected")
    sandbox.touch_log("connect_ok")
    # By default the phone has not pinned adbd: the pinned probe is a connect
    # that fails, and the case that wants a pinned phone removes this file.
    sandbox.write_log("deny", "192.168.77.232:5555\n10.244.108.165:5555\n")
    sandbox.write_log("local_head", "abc\n")
    sandbox.write_log("remote_head", "abc\n")
    sandbox.write_log("ancestor", "no\n")
    sandbox.remove_log("remote_refs")
    sandbox.write_log("head_time", "200\n")
