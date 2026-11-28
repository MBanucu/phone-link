"""Install, update, uninstall and clear the proxy app over adb.

These actions change only the phone and need no root, except when a signer
replacement has to write the exported proxies beside the root-only secrets.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
import time

from .. import phone, settings
from ..shell import capture, die, log, run_both, run_text, status
from .common import _confirm_stdin, _serial, _shell


USAGE_DATA_CLEAR = """usage: phone-proxy-data-clear [--yes] [--check]

Deletes the proxy app's data over adb (pm clear). Without --yes it asks first
and refuses in a non-interactive shell. --check only reports what would run.
"""

USAGE_UNINSTALL = """usage: phone-proxy-uninstall [--yes] [--keep-data] [--check]

Uninstalls the phone's SOCKS proxy app over adb. Without --yes it asks first,
and refuses in a non-interactive shell. --check only reports what would go.
"""

USAGE_INSTALL = """usage: phone-proxy-install [APK...]
       phone-proxy-install --fdroid [--check]
       phone-proxy-install --release [TAG]
       phone-proxy-install --pull [DIR]
       phone-proxy-install --status
       phone-proxy-install --check APK

Installs or updates the phone's SOCKS proxy app over adb (-r -g) — with no
argument, the newest release of the app's own repository
(MBanucu/phone-link-proxy, PHONE_PROXY_REPO to override) — pulls the installed
APK off the phone for later reinstalls, or reports what is installed. --fdroid
fetches the vendored proxy from F-Droid instead, for a phone that still runs
it; --release takes the latest release, or the one named by the tag given, and
checks the .sha256 beside it before installing it. An APK built from a
checkout of the app's repository is installed by naming the file.

An app signed with a different key cannot be updated in place — adb refuses the
install — so --replace-signer uninstalls it first. That also clears the app's
saved proxies; --yes skips the prompt. It is what a phone moving from a locally
built APK to a signed release needs, once. For this app, the saved proxies are
exported to PHONE_PROXY_BACKUP first, imported back after the install, and the
proxy that was in use is started and verified on the port it had; if the
installed app cannot export, nothing is uninstalled. The backup holds every
password in clear text and is written mode 0600 beside the secrets.

Downloads are cached in $PHONE_APK_DIR, defaulting to
$XDG_CACHE_HOME/phone-link (or ~/.cache/phone-link), named
<pkg>-<version>-<code>.apk for F-Droid and after the release's asset otherwise.
"""


def phone_proxy_data_clear(args: list[str]) -> int:
    """Delete the proxy app's data (port, credentials, auto-start flag)."""
    assume_yes = False
    check_only = False
    for value in args:
        if value in ("-y", "--yes"):
            assume_yes = True
        elif value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_DATA_CLEAR, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_DATA_CLEAR, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    serial = _serial()
    package = settings.PHONE_PROXY_PKG
    log(f"phone: {serial}")

    if not _shell(serial, "pm", "path", package):
        log(f"{package}: not installed, nothing to clear")
        log("data left behind by a --keep-data uninstall is only removed by a full")
        log("uninstall, or by reinstalling and running this script")
        return 0
    if check_only:
        log(f"would run: adb -s {serial} shell pm clear {package}")
        return 0

    if not assume_yes:
        prompt = (
            f"Delete all data of {package} on {serial} "
            "(port, credentials, auto-start)? [y/N] "
        )
        if not sys.stdin.isatty():
            die("refusing to clear data without --yes (not a terminal)")
        if not _confirm_stdin(prompt):
            log("aborted")
            return 1

    output = capture(["adb", "-s", serial, "shell", "pm", "clear", package]).replace(
        "\r", ""
    )
    if "Success" not in output:
        die(f"pm clear failed: {output or 'no output'}")

    # The app is force-stopped, so no LAN address should still accept
    # connections.
    left = False
    for _ in range(5):
        left = False
        for address in phone.phone_ips(serial):
            if phone.tcp_open(address, 1):
                left = True
        if not left:
            break
        time.sleep(1)

    log(f"cleared {package} data (port back to 1080, auth disabled, auto-start off)")
    if left:
        log(
            "warning: a LAN address still accepts connections; the app may have restarted"
        )
    log(
        "the proxy is gone: the tunnel stops within 5 s; run phone-proxy-setup to restore it"
    )
    return 0


def phone_proxy_uninstall(args: list[str]) -> int:
    """Uninstall the phone's SOCKS proxy app."""
    assume_yes = False
    keep_data = False
    check_only = False
    for value in args:
        if value in ("-y", "--yes"):
            assume_yes = True
        elif value == "--keep-data":
            keep_data = True
        elif value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_UNINSTALL, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_UNINSTALL, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    serial = _serial()
    package = settings.PHONE_PROXY_PKG
    log(f"phone: {serial}")

    paths = [
        line.removeprefix("package:")
        for line in _shell(serial, "pm", "path", package).splitlines()
        if line.startswith("package:")
    ]
    if not paths:
        log(f"{package}: not installed, nothing to do")
        return 0

    version = ""
    for line in _shell(serial, "dumpsys", "package", package).splitlines():
        match = re.match(r" *versionName=(.*)$", line)
        if match:
            version = match.group(1)
            break
    log(f"{package}: installed, version {version or 'unknown'}")
    for path in paths:
        log(f"  {path}")

    # `adb uninstall -k` is refused on Android 15 (it points at `cmd package`
    # instead), so keeping data goes through the package manager directly.
    command = (
        ["shell", "cmd", "package", "uninstall", "-k", package]
        if keep_data
        else ["uninstall", package]
    )

    if check_only:
        log(f"would run: adb -s {serial} {' '.join(command)}")
        return 0

    if not assume_yes:
        prompt = f"Uninstall {package} from {serial}? [y/N] "
        if not sys.stdin.isatty():
            die("refusing to uninstall without --yes (not a terminal)")
        if not _confirm_stdin(prompt):
            log("aborted")
            return 1

    if status(["adb", "-s", serial, *command]) != 0:
        die("adb uninstall failed")
    if _shell(serial, "pm", "path", package):
        die("still installed after uninstall")

    log(f"uninstalled {package}{' (data kept)' if keep_data else ''}")
    log("the proxy is gone: the tunnel stops within 5 s; run phone-net-status")
    return 0


def phone_proxy_install(args: list[str]) -> int:
    """Install, update, pull or report the phone's SOCKS proxy app."""
    mode = "install"
    use_fdroid = False
    use_release = False
    replace_signer = False
    assume_yes = False
    extra: list[str] = []
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--pull":
            mode = "pull"
        elif value == "--status":
            mode = "status"
        elif value == "--check":
            mode = "check"
        elif value == "--install":
            mode = "install"
        elif value == "--fdroid":
            use_fdroid = True
        elif value == "--release":
            use_release = True
        elif value == "--build":
            # The app has its own repository and its own build now, so this
            # checkout cannot produce the APK. Say where it comes from instead
            # of failing as if the option were never ours.
            print(USAGE_INSTALL, end="", file=sys.stderr)
            die(
                "the app is built in its own repository "
                f"({settings.PHONE_PROXY_REPO}): install a release with "
                "--release, or name an APK you built there"
            )
        elif value == "--replace-signer":
            replace_signer = True
        elif value in ("-y", "--yes"):
            assume_yes = True
        elif value in ("-h", "--help"):
            print(USAGE_INSTALL, end="", file=sys.stderr)
            return 0
        elif value == "--":
            extra.extend(args[index + 1 :])
            break
        elif value.startswith("-"):
            print(USAGE_INSTALL, end="", file=sys.stderr)
            die(f"unknown option: {value}")
        else:
            extra.append(value)
        index += 1

    if mode == "status" and use_fdroid:
        die("--status does not download; drop --fdroid")
    if mode == "pull" and use_fdroid:
        die("--pull reads the phone, not F-Droid; drop --fdroid")
    if use_fdroid and extra:
        die("--fdroid fetches the APK itself; drop the path argument")
    if use_fdroid and use_release:
        die("--fdroid and --release both fetch an APK; pick one")
    if use_release and mode in ("status", "pull"):
        die(f"--{mode} does not download; drop --release")
    if use_release and len(extra) > 1:
        die("--release takes one tag at most")
    if replace_signer and mode == "check":
        die("--check installs nothing; drop --replace-signer")

    serial = _serial()
    package = settings.PHONE_PROXY_PKG
    log(f"phone: {serial}")

    # The saved proxies live in the app, so replacing a differently signed app
    # has to get them out first. Imported here, not at module load, because the
    # proxy commands import this module.
    from . import proxy as proxy_commands

    def remote_paths() -> list[str]:
        return [
            line.removeprefix("package:")
            for line in _shell(serial, "pm", "path", package).splitlines()
            if line.startswith("package:")
        ]

    def installed_version() -> str:
        for line in _shell(serial, "dumpsys", "package", package).splitlines():
            match = re.match(r" *versionName=(.*)$", line)
            if match:
                return match.group(1)
        return ""

    def show_status() -> int:
        paths = remote_paths()
        if not paths:
            log(f"{package}: not installed")
            return 1
        log(f"{package}: installed, version {installed_version() or 'unknown'}")
        for path in paths:
            log(f"  {path}")
        return 0

    def cache_dir() -> str:
        return os.environ.get("PHONE_APK_DIR") or (
            os.path.join(
                os.environ.get("XDG_CACHE_HOME")
                or os.path.join(os.environ.get("HOME", ""), ".cache"),
                "phone-link",
            )
        )

    def download(url: str, destination: str, *, timeout: float = 330) -> bool:
        """Fetch url to destination, writing nothing when it fails."""
        code, _ = run_text(
            ["curl", "-fsSL", "--max-time", "300", "-o", f"{destination}.part", url],
            timeout=timeout,
        )
        if code != 0:
            try:
                os.unlink(f"{destination}.part")
            except OSError:
                pass
            return False
        return True

    def release_apk() -> str:
        """The APK attached to a release of the app's repository, checked."""
        repo = settings.PHONE_PROXY_REPO
        tag = extra[0] if extra else ""
        wanted = tag or "latest"
        api = (
            f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
            if tag
            else f"https://api.github.com/repos/{repo}/releases/latest"
        )
        code, body = run_text(["curl", "-fsSL", "--max-time", "30", api], timeout=40)
        if code != 0:
            die(f"cannot read the {wanted} release of {repo}")
        # The release's assets are the only thing needed from the document, and
        # the APK is the one asset without a suffix.
        urls = re.findall(r'"browser_download_url":\s*"([^"]+)"', body)
        apk_url = next((url for url in urls if url.endswith(".apk")), "")
        if not apk_url:
            die(f"the {wanted} release of {repo} has no APK attached")
        name = apk_url.rsplit("/", 1)[-1]
        log(f"release: {wanted} ({name})")

        cache = cache_dir()
        file = os.path.join(cache, name)
        if os.path.isfile(file) and os.path.getsize(file) > 0:
            log(f"cached: {file}")
            return file
        os.makedirs(cache, exist_ok=True)
        if not download(apk_url, file):
            die(f"download failed: {apk_url}")

        # A release carries the checksum beside the APK; without one there is
        # nothing to compare, which is said rather than passed over.
        expected = ""
        code, sums = run_text(
            ["curl", "-fsSL", "--max-time", "30", apk_url + ".sha256"], timeout=40
        )
        if code == 0 and sums.strip():
            expected = sums.split()[0]
        with open(f"{file}.part", "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        if expected:
            if digest != expected:
                os.unlink(f"{file}.part")
                die(
                    f"checksum mismatch for {name}: downloaded {digest}, release says {expected}"
                )
            log(f"checksum: {digest} matches the release")
        else:
            log("warning: the release carries no .sha256; the download is unchecked")
        os.replace(f"{file}.part", file)
        log(f"downloaded: {file} ({os.path.getsize(file)} bytes)")
        return file

    def fdroid_latest() -> str:
        api = f"https://f-droid.org/api/v1/packages/{package}"
        code, body = run_text(["curl", "-fsSL", "--max-time", "30", api], timeout=40)
        if code != 0:
            die(f"{package} is not on F-Droid (or the API is unreachable)")
        match = re.search(r'"suggestedVersionCode":([0-9]+)', body)
        if not match:
            die(f"F-Droid lists no suggested version for {package}")
        version_code = match.group(1)
        name_match = re.search(
            rf'"versionName":"([^"]*)","versionCode":{version_code}', body
        )
        name = name_match.group(1) if name_match else ""
        log(
            f"F-Droid: {name or 'versionCode ' + version_code} (versionCode {version_code})"
        )

        cache = cache_dir()
        # Keyed by versionCode too: a rebuild can keep versionName and still
        # be new.
        file = os.path.join(cache, f"{package}-{name or 'unknown'}-{version_code}.apk")
        if os.path.isfile(file) and os.path.getsize(file) > 0:
            log(f"cached: {file}")
        else:
            os.makedirs(cache, exist_ok=True)
            url = f"https://f-droid.org/repo/{package}_{version_code}.apk"
            code, _ = run_text(
                ["curl", "-fsSL", "--max-time", "300", "-o", f"{file}.part", url],
                timeout=330,
            )
            if code != 0:
                try:
                    os.unlink(f"{file}.part")
                except OSError:
                    pass
                die(f"download failed: {package} versionCode {version_code}")
            os.replace(f"{file}.part", file)
            log(f"downloaded: {file} ({os.path.getsize(file)} bytes)")
        return file

    def pull_apks(destination: str) -> int:
        paths = remote_paths()
        if not paths:
            die(f"{package} is not installed on {serial}")
        os.makedirs(destination, exist_ok=True)
        for path in paths:
            log(f"pull {path}")
            if status(["adb", "-s", serial, "pull", path, f"{destination}/"]) != 0:
                die(f"pull failed: {path}")

        # A single base.apk gets a self-describing name so reinstalls need no
        # guess.
        if len(paths) == 1:
            source = os.path.join(destination, os.path.basename(paths[0]))
            target = os.path.join(
                destination,
                f"{package}-{installed_version() or 'unknown'}.apk",
            )
            os.replace(source, target)

        listing = capture(["ls", "-l", destination])
        if listing:
            log(listing)
        log(f"install later with: phone-proxy-install {destination}/*.apk")
        return 0

    def install_apks(apks: list[str]) -> None:
        one = len(apks) == 1
        argv = (
            ["adb", "-s", serial, "install", "-r", "-g", apks[0]]
            if one
            else ["adb", "-s", serial, "install-multiple", "-r", "-g", *apks]
        )
        # adb says why it refused; the reason decides what to say next, so the
        # output is kept and printed rather than dropped.
        code, output = run_both(argv, timeout=300)
        if output.strip():
            log(output.strip())
        if code != 0:
            if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in output or "ignature" in output:
                die(
                    "the installed app is signed with a different key, so adb "
                    "cannot update it in place: --replace-signer uninstalls it "
                    "first (which clears the app's saved proxies)"
                )
            die("adb install failed" if one else "adb install-multiple failed")
        grant_settings()

    def grant_settings() -> None:
        """Let our own app switch wireless debugging back on.

        WRITE_SECURE_SETTINGS is a development permission: adb can hand it out
        and nothing on the phone can, so it belongs to the install rather than
        to a step somebody has to remember. Only for the APK this repository
        builds — a third-party proxy has no business holding it, and the grant
        fails harmlessly for one that does not declare it.
        """
        if not package.startswith(settings.PHONE_APP_NAMESPACE):
            return
        argv = [
            "adb",
            "-s",
            serial,
            "shell",
            "pm",
            "grant",
            package,
            "android.permission.WRITE_SECURE_SETTINGS",
        ]
        if status(argv) != 0:
            log(
                "warning: cannot grant WRITE_SECURE_SETTINGS; the panel's "
                "wireless-debugging switch will not work"
            )
            return
        log(
            "granted WRITE_SECURE_SETTINGS: the app can turn wireless debugging back on"
        )
        # The device-idle allowlist is kept by package and goes away with the
        # uninstall, so an app put back is not yet the app that came back after
        # a reboot. Put the entry back with the install rather than leaving it
        # to a step somebody has to remember.
        argv = [
            "adb",
            "-s",
            serial,
            "shell",
            "cmd",
            "deviceidle",
            "whitelist",
            f"+{package}",
        ]
        if status(argv) == 0:
            log("on the battery allowlist: the app can come back after a reboot")
        else:
            log(
                "warning: cannot add the app to the battery allowlist (run phone-proxy-boot)"
            )

    if mode == "status":
        return show_status()
    if mode == "pull":
        return pull_apks(extra[0] if extra else os.path.join(os.getcwd(), "apk"))

    # A bare install is the newest release of the app's own repository: this
    # checkout used to build it, and no longer does.
    local_apks: list[str] = []
    if use_release:
        # extra[0], when there is one, is the tag to take.
        local_apks = [release_apk()]
    elif use_fdroid:
        local_apks = [fdroid_latest()]
    elif extra:
        local_apks = list(extra)
    else:
        local_apks = [release_apk()]

    for apk in local_apks:
        if not os.path.isfile(apk):
            die(f"not a file: {apk}")
        log(f"APK: {apk} ({os.path.getsize(apk)} bytes)")

    if mode == "check":
        log("check only; nothing installed")
        return 0

    # An app signed with another key cannot be updated in place; the only way
    # onto a differently signed build is to remove the old one, and the app's
    # data goes with it. Said before it happens, and asked about unless --yes.
    # Our own app is asked for its saved proxies first, so the uninstall does
    # not cost them; the backup is written root-only beside the secrets.
    restore_document: dict | None = None
    installed = remote_paths()
    if replace_signer and installed:
        log(
            f"{package} is installed: replacing it with a differently signed "
            "build uninstalls it first, which clears the app's saved proxies"
        )
        if not assume_yes:
            if not sys.stdin.isatty():
                die("refusing to replace the app without --yes (not a terminal)")
            if not _confirm_stdin(f"Uninstall {package} and install over it? [y/N] "):
                log("aborted")
                return 1
        if package.startswith(settings.PHONE_APP_NAMESPACE):
            proxy_commands.check_backup_path(settings.PHONE_PROXY_BACKUP)
            if not proxy_commands.backup_writable():
                # The backup belongs beside the root-only secrets; the export
                # writes it there, so run the whole replacement as root.
                phone.as_root("phone-proxy-install", args)
            log("exporting the saved proxies before the uninstall")
            restore_document = proxy_commands.export_to(
                serial, settings.PHONE_PROXY_BACKUP
            )
        else:
            log(
                "the vendored proxy has no export action; its saved proxies "
                "will be lost with the uninstall"
            )
        if status(["adb", "-s", serial, "uninstall", package]) != 0:
            die("adb uninstall failed")
        log(f"uninstalled {package}")

    install_apks(local_apks)
    if package.startswith(settings.PHONE_APP_NAMESPACE):
        # Say what was installed as far as it can be seen. This cannot be a
        # hard gate: an update from a build without the line, and a fresh
        # install, leave state.txt stale or absent until the app runs, so the
        # install has succeeded either way. EXPORT and IMPORT stay hard-gated.
        proxy_commands.note_contract(serial)
    if restore_document is not None:
        # The app is back and empty; put its saved proxies back and prove the
        # proxy that was in use answers on the port it had before.
        log("importing the saved proxies after the install")
        proxy_commands.restore(serial, restore_document, settings.PHONE_PROXY_BACKUP)
    show_status()
    if restore_document is not None:
        log("the app's saved proxies are back; phone-proxy-check reports the link")
    else:
        log("open the app once and start the proxy, then run phone-proxy-check")
    return 0
