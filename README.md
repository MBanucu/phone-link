# phone-link

Nix flake with scripts and a NixOS module for using an unrooted Android phone as
the laptop's internet uplink and as an adb target over Wi-Fi, without a USB
cable.

**Start here:** [`docs/architecture.md`](docs/architecture.md) maps the layers,
the first file to open for each task, and the units the module options create.

- `packages.<system>.phone-link` — the diagnostic/control scripts, with every
  runtime tool wrapped onto their `PATH`
- `packages.<system>.phone-link-gui` — the GTK4/libadwaita control panel
- `nixosModules.default` — the tunnel, the declarative access-point profile and
  its firewall holes
- `devShells.default`, `formatter`, `checks`
- the proxy app itself is not here any more: it is
  [`MBanucu/phone-link-proxy`](https://github.com/MBanucu/phone-link-proxy),
  with its own flake, tests, release workflow and store metadata, and
  `phone-proxy-install` fetches its releases

## Install the module

```nix
# flake.nix
{
  inputs.phone-link.url = "github:MBanucu/phone-link";

  outputs = { self, nixpkgs, phone-link, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [
        phone-link.nixosModules.default
        {
          environment.systemPackages = [
            phone-link.packages.${pkgs.system}.phone-link
          ];

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

`version` in `flake.nix` is this repository's version; the proxy version is
whatever the phone reports, or the latest release of the proxy app. Pin a
reviewed tag or revision in the input URL to stay on it; the bare URL tracks
`main`. The module declares the tunnel and the AP but installs no packages, so
without the `environment.systemPackages` line there is no `phone-ap-up`,
`phone-doctor` or `phone-proxy-*` on the machine. It never starts the tunnel at
boot: a 5 s probe keeps `phone-tun` running only while the proxy answers, so a
missing phone or a stopped proxy app cannot blackhole traffic. The pinning
detail and the one-time setup are in
[operations](docs/operations.md#install-the-module).

## Three commands

```sh
phone-net-status   # links, routes, resolver, proxy probes, adb transports, phone state
phone-doctor       # every required condition; exits non-zero if one is unmet
sudo phone-ap-up   # activate the AP profile
```

From a checkout, `nix run` runs `phone-net-status`, `nix build` writes the
scripts to `./result/bin/`, and `nix develop` is a shell with the scripts and
their tools. `nix run .#gui` opens the panel. Every other command and flag is in
[scripts](docs/scripts.md).

## Documentation

- [docs/architecture.md](docs/architecture.md) — the layers, the first file for
  each task, and the units each option group creates
- [docs/options.md](docs/options.md) — every module option and its default
- [docs/scripts.md](docs/scripts.md) — every command, the GUI and the
  screenshots runbook
- [docs/commands.md](docs/commands.md) — the shell/Python split and the recipe
  for adding a command
- [docs/checks.md](docs/checks.md) — what each `checks.*` target proves and the
  timing history
- [docs/operations.md](docs/operations.md) — install detail, the two modes,
  one-time setup, uninstall and troubleshooting
- [docs/phone-network.md](docs/phone-network.md) — measured behaviour, evidence
  and the traps
- [docs/hairpin-measure.md](docs/hairpin-measure.md) — the before/after runbook
  for the AP hairpin (#47)
- [docs/proxy-boundary.md](docs/proxy-boundary.md) — which repository owns the
  app contract, build, install and live harnesses, and the change order
- [CHANGELOG.md](CHANGELOG.md) — released changes, Keep a Changelog format
