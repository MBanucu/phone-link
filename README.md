# phone-link

Nix flake with scripts and a NixOS module for using an unrooted Android phone as
the laptop's internet uplink and as an adb target over Wi-Fi, without a USB
cable.

- `packages.<system>.phone-link` — the diagnostic/control scripts, with every
  runtime tool wrapped onto their `PATH`
- `packages.<system>.phone-link-gui` — the GTK4/libadwaita control panel (since
  0.2.0)
- `nixosModules.default` — the tunnel, the declarative access-point profile and
  its firewall holes
- `devShells.default`, `formatter`, `checks`
- `docs/phone-network.md` — measured behaviour, evidence and the traps

## Install the module

```nix
# flake.nix
{
  inputs.phone-link.url = "github:MBanucu/phone-link/v0.3.2";

  outputs = { self, nixpkgs, phone-link, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [
        phone-link.nixosModules.default
        {
          phoneLink = {
            enable = true;
            ap.enable = true;
            apInterface = "wlp110s0";
            proxyHost = "192.168.77.232";
            secretsFile = "/etc/nixos/phone-socks-secrets";
          };
        }
      ];
    };
  };
}
```

Pinning the tag, as above, keeps the machine on a reviewed revision; use the
bare `github:MBanucu/phone-link` to track `main`, and `nix flake update
phone-link` to move from one tag to the next.

The module never starts the tunnel at boot. A 5 s timer probes the proxy port and
keeps `phone-tun.service` running only while it answers, so a missing phone or a
stopped proxy app cannot blackhole traffic.

### Options

| option | default | meaning |
|---|---|---|
| `phoneLink.enable` | `false` | enable the tunnel, timer and AP firewall holes |
| `phoneLink.apInterface` | `wlp110s0` | interface of the laptop access point |
| `phoneLink.ap.enable` | `false` | declare the AP profile from `PHONE_AP_PASS` (requires `phoneLink.enable`) |
| `phoneLink.ap.name` | `phonelink` | NetworkManager connection name |
| `phoneLink.ap.ssid` | `PhoneLink` | SSID of the laptop access point |
| `phoneLink.ap.band` / `channel` | `bg` / `1` | 802.11 band and channel |
| `phoneLink.ap.address` | `192.168.77.1/24` | IPv4 address of the AP interface |
| `phoneLink.proxyHost` | `192.168.77.232` | address of the phone's SOCKS proxy |
| `phoneLink.proxyPort` | `1080` | SOCKS port |
| `phoneLink.proxyUser` | `proxy` | SOCKS username |
| `phoneLink.secretsFile` | `/etc/nixos/phone-socks-secrets` | file with `PHONE_SOCKS_PASS=…` (and `PHONE_AP_PASS=…` with `ap.enable`) |
| `phoneLink.interfaceName` | `phone-tun` | TUN device name |
| `phoneLink.tunAddress` | `172.19.0.1/30` | TUN address |
| `phoneLink.logLevel` | `warn` | sing-box log level |
| `phoneLink.cacheProxyApk` | `true` | download the proxy APK during activation, so every install/update stocks the ambulance cache |
| `phoneLink.manageResolver` | `true` | pin `/etc/resolv.conf` to `1.1.1.1`/`9.9.9.9` |
| `phoneLink.openApFirewall` | `true` | allow DHCP/DNS from AP clients |
| `phoneLink.enableRelay` | `false` | run the local SOCKS/HTTP relay (`gost`) |
| `phoneLink.relaySocksPort` / `relayHttpPort` | `1081` / `1082` | relay ports |

## Use the scripts

```sh
nix build            # ./result/bin/{phone-net-status,phone-ap-up,…}
nix run              # phone-net-status
nix develop          # shell with the scripts and their tools
```

Or straight from the checkout: `./bin/phone-net-status`.

| script | what it does |
|---|---|
| `phone-net-status` | links, routes, resolver, proxy probes, adb transports, phone state |
| `phone-doctor` | check every runtime condition of the setup (forwarding, AP profile/address, adb, phone link, secrets, proxy, tunnel, tether, internet), the cached proxy APK, the installed app versus F-Droid's latest and the phone SDK, and whether the source checkout is newer than the installed flake lock; exit non-zero if a required one is unmet; `--analyze` prints one `fail`/`warn` line with a stable problem id for scripts |
| `phone-doctor-fix` | list the fixes for the problems `phone-doctor --analyze` reports, run one dedicated script per problem in dependency order, then re-check (`--yes` skips the prompt, `--dry-run` only lists, `--required` leaves warnings alone; run with `sudo`) |
| `phone-fix-apk` | stock the ambulance box: cache the proxy APK in `/var/cache/phone-link` so the app can be reinstalled without a network (`--refresh` re-downloads, `--check` reports) |
| `phone-fix-forwarding` | set `net.ipv4.ip_forward=1` for the running kernel (`--check` reports only) |
| `phone-fix-internet` | restore internet for the APK download/check by trying mobile data, USB tethering, then the phone hotspot with the laptop as a client, verifying HTTPS after each (`--check` reports only) |
| `phone-fix-mobile-data` | enable the phone's mobile data and wait for a default route (`--check` reports only) |
| `phone-fix-tunnel` | start `phone-tun`, or restart it when its route is missing, and wait for the route (`--check` reports only) |
| `phone-proxy-check` | request through the proxy on the hotspot and AP addresses (needs root for the secret) |
| `phone-proxy-install` | install/update the proxy app from an APK; `--fdroid` fetches F-Droid's suggested version, `--pull` copies it off the phone, `--status` reports the version |
| `phone-proxy-uninstall` | remove the proxy app (`--check` previews, `--keep-data` keeps app data, `--yes` skips the prompt) |
| `phone-proxy-data-clear` | wipe the proxy app's data, back to port 1080 with no auth (`--check` previews, `--yes` skips the prompt) |
| `phone-proxy-battery-whitelist` | add the proxy app to the device-idle (Doze) whitelist so the proxy is not killed with the screen off (`--check` only reports) |
| `phone-proxy-setup` | write port, credentials and auto-start through the app's settings screen, start the proxy and verify a request through it (`--check` only reports) |
| `phone-proxy-start` | tap Start and wait until the proxy is running (`--check` only reports) |
| `phone-proxy-stop` | tap Stop and wait until the proxy is off (`--check` only reports) |
| `net-check` | fetch a fresh URL with curl, Chrome and Nix, reporting which of the three reach the internet |
| `phone-reboot-unlock` | reboot the phone, wait for boot, then unlock once (`--yes` skips the prompt) |
| `phone-tether-cycle` | switch USB to MTP so `net-check` runs with RNDIS off, then lock and unlock the phone to restore the tether, verify it and report (`--yes` skips the prompt; needs the PIN, so run with `sudo`) |
| `phone-usb-tether-check` | report whether USB tethering is active and whether the internet answers over the host's tether route |
| `phone-usb-tether-default` | make USB tethering the default USB action, keeping adb (`--check` reports only) |
| `phone-wifi-connect` | join PhoneLink (or another SSID) with WPA2 and wait for the association (`--check` reports) |
| `phone-wifi-enable` | turn the phone's Wi-Fi radio on (`--check` reports) |
| `phone-wifi-forget` | forget a saved network, default PhoneLink (`--check`, `--yes`) |
| `phone-wifi-concurrency` | report whether Wi-Fi client and hotspot can run together (STA+AP), read-only; exit 2 if the phone does not say |
| `phone-unlock` | unlock the lock screen with `PHONE_PIN` from the secrets file (`--check` only reports locked/unlocked) |
| `phone-ap-create` | create the `phonelink` AP profile from the root-only `PHONE_AP_PASS` secret (`--refresh` rewrites it after a PSK change, `--check` reports) |
| `phone-ap-delete` | delete the `phonelink` AP profile from NetworkManager, bringing it down first if active (`--check` reports, `--yes` skips the prompt; a declared profile returns at the next boot) |
| `phone-ap-up` | preflight the radio, then `nmcli connection up phonelink` |
| `phone-ap-down` | drop the AP and rejoin the phone's hotspot |
| `phone-link-uninstall` | remove the AP profile and APK caches after unwiring the module (`--check`, `--yes`, `--keep-cache`); straight from the checkout |
| `adb-wifi-connect` | connect adb to the phone over TCP |
| `adb-wifi-connect --prepare` | once over USB: `adb tcpip 5555` (the tether blips) |
| `phone-adb-wifi` | enable adb over Wi-Fi on the phone: legacy `adb tcpip 5555` and Android 11+ wireless debugging on its random TLS port, then connect (`--legacy`, `--tls`, `--check`) |
| `phone-tunnel-run` | run the built tunnel config in the foreground |
| `phone-tunnel-run --via-adb` | same, with the upstream reached through `adb reverse` |

`phone-doctor` is a Python package under `lib/python/phone_doctor`, with one
module per symptom group (`flake`, `host`, `phone`, `secrets`, `proxy`,
`tunnel`, `tether`, `internet`, `adb_wifi`); `bin/phone-doctor` only resolves it.

`lib/phone-net.sh` holds the shared functions (`phone_proxy_check`, `tcp_open`,
`phone_ips`, `adb_transport`, …); source it so addresses and ports live in one
place.

## GUI

`packages.<system>.phone-link-gui` is a GTK4/libadwaita control panel for the
same setup, new in **0.2.0**. It reads the doctor's `--json` report for its
status page and runs the scripts with the flags declared in
`lib/python/phone_link/actions.py`:

```sh
nix run .#gui                                 # from a checkout
nix run github:MBanucu/phone-link/v0.3.2#gui  # straight from the tag
nix build .#phone-link-gui                    # or build it and run the binary
```

The module installs the scripts but not the panel; add the package to get the
desktop entry and icon as well:

```nix
environment.systemPackages = [ phone-link.packages.${pkgs.system}.phone-link-gui ];
```

Every action has its `--check` preview plus its variants (F-Droid install,
tunnel through `adb reverse`, legacy adb port, keep-cache uninstall, …) in the
row's menu, and the output streams into a log window exactly as the script
printed it, exit status included. The header searches every action by name or
summary (Ctrl+F), the sidebar badges the number of failing checks, and Ctrl+R
re-checks the setup. Nothing is reimplemented: `phone_link.actions`
decides the argv and `phone_link.runner` streams it for both the GUI and
`phone-link run`, and the `registry` check fails when a script exists in `bin/`
without an action entry.

Actions that need root go through `pkexec`, so they run from the desktop session
with one password prompt; the status banner offers the same for the root-only
secrets, which otherwise show as unreadable. The layout collapses to a single
pane below 720sp, so a narrow window or a touch screen still works.

### Screenshots

`bin/phone-link-gui-screenshots` builds the panel from the checkout and writes
one PNG per state into `screenshots/`: the status page with this machine's
doctor report, every action page, the search states, the narrow layout and a
failed run. It needs `nix`, `Xvfb`, `dbus-run-session` and ImageMagick, and
takes `--out DIR` (and `--scale 1` for smaller files). A capture that comes out
all black fails the run instead of being written.

```sh
bin/phone-link-gui-screenshots
```

`phone-link list` and `phone-link run <id> [--check] [--yes]` are the CLI half of
the same table, and `phone-link status` prints the doctor's JSON.

## Checks

`nix flake check` runs these checks per system:

| check | what it proves |
|---|---|
| `registry` | every script in `flake.nix` has an action in the GUI's table, and every action has an executable script |
| `gui-registry` | the packaged GUI imports GTK4/libadwaita and its table matches the scripts |
| `gui` | the real window, every page and the log window construct under Xvfb |
| `package` | every script in the flake exists, is executable, kept its wrapped `PATH`, and `phone-net-status` prints a status |
| `shellcheck` | every script and `lib/phone-net.sh` is clean at shellcheck warning level |
| `format` | `flake.nix` and `modules/phone-link.nix` are nixfmt-clean |
| `module` | the module generates the expected sing-box config and units (5 s probe, 20 s first run, AP DHCP/DNS holes, pinned resolver, never started at boot) and defines nothing when disabled |
| `script` | hermetic tests with stub `adb`/`curl`/`avahi-browse`: for `phone-proxy-install` the F-Droid version selection, cache keying and reuse, `--check` staying read-only, the exact install argv and `--pull` naming; for `phone-proxy-uninstall` the confirm/`--yes` guard, `--keep-data`, idempotence and the exact uninstall argv; for `phone-proxy-data-clear` the prompt guard, `--check` staying read-only and the `pm clear` argv; for `phone-proxy-setup` the field order, values typed, auto-start toggle and Start tap against a stub settings screen; for `phone-unlock` the keyguard check, PIN entry and wrong-PIN failure; for `phone-proxy-battery-whitelist` the idempotent add, `--check` and the device-idle argv; for `phone-proxy-start`/`phone-proxy-stop` the Start/Stop tap, the already-running/stopped no-op and the failed-start path; for `phone-wifi-concurrency` the supported, unsupported and inconclusive verdicts and the read-only queries; for `phone-usb-tether-check` the rndis0/usb state, the host route and a source-bound request; for `net-check` the three fetches, their failure modes and the cache-busting URL; for `phone-reboot-unlock` the reboot/wait/unlock sequence, the slow-boot wait, the aborted prompt and the boot timeout; for `phone-usb-tether-default` the current and screen-unlocked functions, the `--check` report and an ineffective setter; for `phone-wifi-enable` the idempotent enable and `--check`; for `phone-wifi-forget` the saved-network table, the prompt/`--yes` guard and idempotence; for `phone-wifi-connect` the password sources, remote quoting of SSID/passphrase and the association wait; for `phone-tether-cycle` the MTP disable, the health check, the lock/unlock restore, an adb abort retry, the already-off case, an unhealthy restore and the prompt guard; for `phone-adb-wifi` the legacy/TLS split, the mDNS port lookup, the `adb_wifi_enabled` write, the already-on case and the missing-port failure; for `phone-doctor` the ready, hotspot, locked, missing-adb, missing-secrets and dead-proxy paths |

The `script` check also covers `phone-doctor --analyze` (problem ids, AP down and
an empty ambulance box, warnings-only, no headers or `ok` lines),
`phone-doctor-fix` (dry run, ordered application, cached-APK install,
manual-only and failed-fix paths) and the fix scripts (ambulance APK, AP
profile creation from the secret, forwarding, mobile data, tunnel: apply,
no-op and read-only `--check`).

### Live end-to-end test

`tests/live/doctor-fix-proxy.sh` breaks the setup on purpose and checks that the
doctor repairs it: it stocks the ambulance APK, drops the laptop AP, uninstalls
the proxy app, requires `phone-doctor` to report `ap_address`, `proxy_app` and
`proxy_request`, runs `phone-doctor-fix --yes --required`, and requires a clean
doctor with the AP back up and the phone joined again. The fixer restores the AP
and the phone's link to it last, so every proxy fix runs while the phone is
still reachable. The APK is cached before the phone is touched, so the repair
works even when the removed proxy was the laptop's only uplink
(`PHONE_PROXY_APK=<file>` also forces a specific APK). It reinstalls and
reconfigures the app on exit if the repair failed.

```sh
sudo tests/live/doctor-fix-proxy.sh
```

It is not named `*.test.sh`, so `nix flake check` never runs it; it needs the
phone, root and F-Droid access, and it deletes the app's data.

The `module` check evaluates a NixOS configuration with non-default options, so
it catches option or unit regressions without building a system or a VM.

## The two modes

| | hotspot mode | AP mode |
|---|---|---|
| who runs the AP | the phone | the laptop (`phonelink`) |
| laptop uplink | phone's SOCKS proxy at `10.244.108.165:1080` | phone's SOCKS proxy at `192.168.77.232:1080` |
| phone Wi-Fi client | **off** (`cmd wifi status`: "Wifi is disabled") | on, joined to `PhoneLink` |
| adb over Wi-Fi | works until the phone reboots, then needs `adb tcpip` over USB | `phone-adb-wifi` re-enables wireless debugging and reconnects without a cable |

Android cannot be hotspot and Wi-Fi client at once, and wireless debugging needs
a Wi-Fi client link, which AP mode provides. There `phone-adb-wifi` enables it by
writing `adb_wifi_enabled`, so the Settings toggle is not needed once adb is
reachable. The legacy `5555` listener does not survive a reboot. For hotspot mode
set `phoneLink.proxyHost = "10.244.108.165"`.

## One-time setup

The AP profile needs the Wi-Fi PSK, so it is built from the same root-only
secrets file as the PIN and never enters the Nix store. With the module, set
`phoneLink.ap.enable = true` and keep `PHONE_AP_PASS` in that file:

```sh
install -m600 /dev/null /etc/nixos/phone-socks-secrets
printf 'PHONE_SOCKS_PASS=%s\nPHONE_PIN=%s\nPHONE_AP_PASS=%s\n' \
  '<proxy password>' '<phone PIN>' '<Wi-Fi PSK>' \
  | sudo tee /etc/nixos/phone-socks-secrets

sudo nixos-rebuild switch   # writes /run/.../phonelink.nmconnection from the secret
sudo phone-ap-up            # activates the AP
```

The generated profile lives in `/run/NetworkManager/system-connections/`; the
store only holds the `$PHONE_AP_PASS` placeholder. `phone-ap-create --refresh`
reloads it after rotating the PSK by restarting
`NetworkManager-ensure-profiles`, rather than editing NetworkManager's copy.

Without the module, `sudo phone-ap-create` still creates a persistent profile
in `/etc/NetworkManager/system-connections/`, and `--refresh` rewrites it.

If you previously created the profile with `phone-ap-create`, no manual step is
needed: the ensure unit removes the persistent `/etc` copy before writing the
declarative one, so only one profile with that name remains. The running AP
drops with the old profile, so run `sudo phone-ap-up` after the switch.

## Uninstall

Unwiring the module removes the units, firewall holes and installed scripts,
but NixOS has no uninstall hook for runtime state. Remove `phoneLink` (and the
package, if you added it) from `configuration.nix`, switch, then run the
uninstaller from the checkout — the installed scripts are gone by then:

```sh
sudo nixos-rebuild switch
sudo ./bin/phone-link-uninstall --yes
```

It stops any tunnel units still running, deletes the `phonelink` profile from
NetworkManager and from `/etc`/`/run`, and clears `/var/cache/phone-link` and
the invoking user's `~/.cache/phone-link`. It keeps
`/etc/nixos/phone-socks-secrets` and the phone's state, and prints the commands
to remove those (`phone-wifi-forget PhoneLink`, `phone-proxy-uninstall`). Use
`--check` to preview and `--keep-cache` to keep the APKs. A reboot is a simpler
alternative for the profile, but it will not clear the caches or the secrets
file.

The proxy APK is not vendored (it is not ours to ship), but the app is on
F-Droid, so the script can use F-Droid as its update channel:

```sh
phone-proxy-install --fdroid            # download the suggested version, install
phone-proxy-install --fdroid --check    # download only, cache it, install nothing
```

Downloads are cached under `$PHONE_APK_DIR` (default
`$XDG_CACHE_HOME/phone-link`, i.e. `~/.cache/phone-link`) and named after the
version, so a repeat run installs from the cache. Without F-Droid access, back
the app up from a phone that has it and install from the copy:

```sh
phone-proxy-install --pull ~/dev/phone-link/apk
phone-proxy-install ~/dev/phone-link/apk/*.apk
```

`--pull` names a single-APK backup `com.tokyoxpa3.androidproxy-<version>.apk`;
installs use `adb install -r -g`, so updating keeps the app's settings.

Requirements: `NetworkManager` on `wpa_supplicant` (iwd cannot do AP mode),
`net.ipv4.ip_forward = 1`, and the phone's proxy listening on the reachable
address.
