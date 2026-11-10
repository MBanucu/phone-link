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
| `phone-ap-up` | preflight the radio, then `nmcli connection up phonelink` |
| `phone-ap-down` | drop the AP and rejoin the phone's hotspot |
| `adb-wifi-connect` | connect adb to the phone over TCP |
| `adb-wifi-connect --prepare` | once over USB: `adb tcpip 5555` (the tether blips) |
| `phone-tunnel-run` | run the built tunnel config in the foreground |
| `phone-tunnel-run --via-adb` | same, with the upstream reached through `adb reverse` |

`lib/phone-net.sh` holds the shared functions (`phone_proxy_check`, `tcp_open`,
`phone_ips`, `adb_transport`, …); source it so addresses and ports live in one
place.

## Checks

`nix flake check` runs four checks per system:

| check | what it proves |
|---|---|
| `package` | all six scripts exist, are executable, kept their wrapped `PATH`, and `phone-net-status` prints a status |
| `shellcheck` | every script and `lib/phone-net.sh` is clean at shellcheck warning level |
| `format` | `flake.nix` and `modules/phone-link.nix` are nixfmt-clean |
| `module` | the module generates the expected sing-box config and units (5 s probe, 20 s first run, AP DHCP/DNS holes, pinned resolver, never started at boot) and defines nothing when disabled |

The `module` check evaluates a NixOS configuration with non-default options, so
it catches option or unit regressions without building a system or a VM.

## The two modes

| | hotspot mode | AP mode |
|---|---|---|
| who runs the AP | the phone | the laptop (`phonelink`) |
| laptop uplink | phone's SOCKS proxy at `10.244.108.165:1080` | phone's SOCKS proxy at `192.168.77.232:1080` |
| phone Wi-Fi client | **off** (`cmd wifi status`: "Wifi is disabled") | on, joined to `PhoneLink` |
| adb over Wi-Fi | works until the phone reboots, then needs `adb tcpip` over USB | `Wireless debugging` toggle usable, so adb comes back with a tap |

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
printf 'PHONE_SOCKS_PASS=%s\n' '<proxy password>' | sudo tee /etc/nixos/phone-socks-secrets
```

Requirements: `NetworkManager` on `wpa_supplicant` (iwd cannot do AP mode),
`net.ipv4.ip_forward = 1`, and the phone's proxy listening on the reachable
address.
