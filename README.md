# phone-link

Nix flake with scripts and a NixOS module for using an unrooted Android phone as
the laptop's internet uplink and as an adb target over Wi-Fi, without a USB
cable.

- `packages.<system>.phone-link` — the diagnostic/control scripts, with every
  runtime tool wrapped onto their `PATH`
- `nixosModules.default` — the tunnel plus the access-point firewall holes
- `devShells.default`, `formatter`, `checks`
- `docs/phone-network.md` — measured behaviour, evidence and the traps

## Install the module

```nix
# flake.nix
{
  inputs.phone-link.url = "path:/home/michi/dev/phone-link";

  outputs = { self, nixpkgs, phone-link, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [
        phone-link.nixosModules.default
        {
          phoneLink = {
            enable = true;
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

The module never starts the tunnel at boot. A 5 s timer probes the proxy port and
keeps `phone-tun.service` running only while it answers, so a missing phone or a
stopped proxy app cannot blackhole traffic.

### Options

| option | default | meaning |
|---|---|---|
| `phoneLink.enable` | `false` | enable the tunnel, timer and AP firewall holes |
| `phoneLink.apInterface` | `wlp110s0` | interface of the laptop access point |
| `phoneLink.proxyHost` | `192.168.77.232` | address of the phone's SOCKS proxy |
| `phoneLink.proxyPort` | `1080` | SOCKS port |
| `phoneLink.proxyUser` | `proxy` | SOCKS username |
| `phoneLink.secretsFile` | `/etc/nixos/phone-socks-secrets` | file with `PHONE_SOCKS_PASS=…` |
| `phoneLink.interfaceName` | `phone-tun` | TUN device name |
| `phoneLink.tunAddress` | `172.19.0.1/30` | TUN address |
| `phoneLink.logLevel` | `warn` | sing-box log level |
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
| `phone-ap-up` | preflight the radio, then `nmcli connection up phonelink` |
| `phone-ap-down` | drop the AP and rejoin the phone's hotspot |
| `adb-wifi-connect` | connect adb to the phone over TCP |
| `adb-wifi-connect --prepare` | once over USB: `adb tcpip 5555` (the tether blips) |
| `phone-adb-wifi` | enable adb over Wi-Fi on the phone: legacy `adb tcpip 5555` and Android 11+ wireless debugging on its random TLS port, then connect (`--legacy`, `--tls`, `--check`) |
| `phone-tunnel-run` | run the built tunnel config in the foreground |
| `phone-tunnel-run --via-adb` | same, with the upstream reached through `adb reverse` |

`lib/phone-net.sh` holds the shared functions (`phone_proxy_check`, `tcp_open`,
`phone_ips`, `adb_transport`, …); source it so addresses and ports live in one
place.

## Checks

`nix flake check` runs five checks per system:

| check | what it proves |
|---|---|
| `package` | all six scripts exist, are executable, kept their wrapped `PATH`, and `phone-net-status` prints a status |
| `shellcheck` | every script and `lib/phone-net.sh` is clean at shellcheck warning level |
| `format` | `flake.nix` and `modules/phone-link.nix` are nixfmt-clean |
| `module` | the module generates the expected sing-box config and units (5 s probe, 20 s first run, AP DHCP/DNS holes, pinned resolver, never started at boot) and defines nothing when disabled |
| `script` | hermetic tests with stub `adb`/`curl`: for `phone-proxy-install` the F-Droid version selection, cache keying and reuse, `--check` staying read-only, the exact install argv and `--pull` naming; for `phone-proxy-uninstall` the confirm/`--yes` guard, `--keep-data`, idempotence and the exact uninstall argv; for `phone-proxy-data-clear` the prompt guard, `--check` staying read-only and the `pm clear` argv; for `phone-proxy-setup` the field order, values typed, auto-start toggle and Start tap against a stub settings screen; for `phone-unlock` the keyguard check, PIN entry and wrong-PIN failure; for `phone-proxy-battery-whitelist` the idempotent add, `--check` and the device-idle argv; for `phone-proxy-start`/`phone-proxy-stop` the Start/Stop tap, the already-running/stopped no-op and the failed-start path; for `phone-wifi-concurrency` the supported, unsupported and inconclusive verdicts and the read-only queries; for `phone-usb-tether-check` the rndis0/usb state, the host route and a source-bound request; for `net-check` the three fetches, their failure modes and the cache-busting URL; for `phone-reboot-unlock` the reboot/wait/unlock sequence, the slow-boot wait, the aborted prompt and the boot timeout; for `phone-usb-tether-default` the current and screen-unlocked functions, the `--check` report and an ineffective setter; for `phone-wifi-enable` the idempotent enable and `--check`; for `phone-wifi-forget` the saved-network table, the prompt/`--yes` guard and idempotence; for `phone-wifi-connect` the password sources, remote quoting of SSID/passphrase and the association wait; for `phone-tether-cycle` the MTP disable, the health check, the lock/unlock restore, an adb abort retry, the already-off case, an unhealthy restore and the prompt guard; for `phone-adb-wifi` the legacy/TLS split, the mDNS port lookup, the settings toggle, the already-on case and the missing-port failure |

The `module` check evaluates a NixOS configuration with non-default options, so
it catches option or unit regressions without building a system or a VM.

## The two modes

| | hotspot mode | AP mode |
|---|---|---|
| who runs the AP | the phone | the laptop (`phonelink`) |
| laptop uplink | phone's SOCKS proxy at `10.244.108.165:1080` | phone's SOCKS proxy at `192.168.77.232:1080` |
| phone Wi-Fi client | **off** (`cmd wifi status`: "Wifi is disabled") | on, joined to `PhoneLink` |
| adb over Wi-Fi | works until the phone reboots, then needs `adb tcpip` over USB | `phone-adb-wifi` re-enables wireless debugging and reconnects without a cable |

Android cannot be hotspot and Wi-Fi client at once, and its `Wireless debugging`
toggle needs the Wi-Fi client stack. AP mode is therefore the only cable-free way
back to adb after a phone reboot. For hotspot mode set `phoneLink.proxyHost =
"10.244.108.165"`.

## One-time setup

The AP profile contains the Wi-Fi PSK, so it is created by hand and stays out of
the store:

```sh
nmcli connection add type wifi ifname wlp110s0 con-name phonelink \
  autoconnect no ssid PhoneLink 802-11-wireless.mode ap \
  802-11-wireless.band bg 802-11-wireless.channel 1 \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk '<psk>' \
  ipv4.method shared ipv4.addresses 192.168.77.1/24

install -m600 /dev/null /etc/nixos/phone-socks-secrets
printf 'PHONE_SOCKS_PASS=%s\nPHONE_PIN=%s\n' '<proxy password>' '<phone PIN>' \
  | sudo tee /etc/nixos/phone-socks-secrets
```

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
