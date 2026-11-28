# Architecture: start here

This page maps a task to the file to open first and the check that proves the
change. It names paths, options and units, never line numbers. Defaults and
flags live in the [options page](options.md), not here.

## Layers

```text
flake.nix  →  modules/*.nix  →  lib/python/* + lib/*.sh  →  bin/*  →  tests/  →  docs/
```

- `flake.nix` — the only entry point: `packages`, `nixosModules` (its `default`
  imports both modules below), `checks`, `apps`, `devShells` and `formatter`.
- `modules/` — `phone-link/` declares the options, systemd units and the
  generated sing-box config; `options/` holds one file per option group,
  `config/` one file per group of units or generated configuration, and
  `derived.nix` the values both sides share. `phone-link-failopen.nix` adds the
  fail-open watchdog. Neither contains a shell implementation.
- `lib/` — `python/phone_link/` is the action registry and the command bodies,
  one module per feature under `commands/` (`adb`, `wifi`, `usb`, `ap`,
  `tunnel`, `repair`, `install`, `proxy`; shared helpers in `common`),
  `python/phone_doctor/` the checker (one module per symptom group),
  `python/phone_link_gui/` the GTK4 panel; `lib/*.sh` are the helpers the units
  run (tunnel toggle, AP rejoin, fail-open).
- `bin/` — one shim per command. A shim only resolves `PYTHONPATH` and hands
  over to `phone_link.commands`; the implementation is never here.
- `pyproject.toml` — tooling only, no build: the ruff rule set (the default
  `E4`/`E7`/`E9`/`F` plus the GI import exception) and mypy's paths and
  `ignore_missing_imports`, read by the `python-lint` check. The packages are
  imported through `PYTHONPATH`, never installed from a wheel.
- `tests/` — `*.test.sh` are hermetic (stub `adb`/`curl`/`avahi-browse`) and run
  from the flake's `script` check; `tests/live/` needs the real phone and is
  never part of `nix flake check`.
- `docs/` — this map, `options.md`, `scripts.md`, `commands.md`, `checks.md`,
  `operations.md`, `phone-network.md` (measured behaviour and traps) and
  `hairpin-measure.md` (the live runbook).

## I want to…

| Task | First file | Test to run |
|---|---|---|
| Change the tunnel | `modules/phone-link/config/tunnel.nix` (`phone-tun`, `phone-tun-toggle`) and `modules/phone-link/derived.nix` (generated config) | `nix build .#checks.x86_64-linux.module` and `bash tests/phone-tun-toggle.test.sh` |
| Change the AP profile | `modules/phone-link/config/networkmanager.nix` (`networking.networkmanager.ensureProfiles`); the imperative path is `lib/python/phone_link/commands/ap.py` | `nix build .#checks.x86_64-linux.module` and `bash tests/phone-ap-create.test.sh` |
| Change the hairpin or fail-open | `modules/phone-link/options/ap.nix` (`ap.uplink`, the `ap.*Rules` values) and `derived.nix` (the rulesets); `modules/phone-link-failopen.nix` + `lib/phone-ap-failopen.sh` for the watchdog | `nix build .#checks.x86_64-linux.module` and `bash tests/phone-ap-failopen.test.sh` |
| Change or add a command | `lib/python/phone_link/commands/<group>.py`, then one `Action` in `actions.py` (its `module:function`, usage, docs row and flags); `registry_gen --write` writes the shim, `COMMANDS` entry and docs row. Full recipe in [commands](commands.md) | `bash tests/<name>.test.sh`, plus `nix build .#checks.x86_64-linux.registry` |
| Change a module option | `modules/phone-link/options/<group>.nix` (or `options/ap.nix` for `ap.*` and its rulesets); document it in the [options table](options.md) | `nix build .#checks.x86_64-linux.module` |
| Add or change a test | `tests/<name>.test.sh` | `bash tests/<name>.test.sh`; then `bash tests/check.sh fast` for the cheap set |
| Change the GUI | `lib/python/phone_link_gui/app.py` (pages beside it); argv still comes from `lib/python/phone_link/actions.py` | `nix build .#checks.x86_64-linux.gui` and `.#checks.x86_64-linux.gui-registry` |
| Change the proxy install | `lib/python/phone_link/commands/install.py` (`phone_proxy_install`); the app itself is `MBanucu/phone-link-proxy` | `bash tests/phone-proxy-install.test.sh` |

[`nix build .#checks.x86_64-linux.format`](checks.md) guards the Nix files,
[`shellcheck`](checks.md) guards `bin/`, `lib/*.sh` and every `*.sh` under
`tests/`, [`python`](checks.md) compiles `lib/python/`, and
[`python-lint`](checks.md) runs ruff and mypy over it against `pyproject.toml`.
Every suite also
runs through the `script` check inside `nix flake check`; [checks.md](checks.md)
has the full table and how to run one target.

## Module layout

`modules/phone-link/` is split by responsibility, not by line count:

| Path | Holds |
|---|---|
| `default.nix` | the imports; the module the flake exposes |
| `derived.nix` | values shared by options and units: runtime paths, generated sing-box config, unit scripts, nftables rulesets |
| `options/tunnel.nix` | `enable`, `interfaceName`, `tunAddress`, `logLevel`, `manageResolver`, `configFile` |
| `options/proxy.nix` | `proxyHost`, `proxyHosts`, `effectiveProxyHosts`, `proxyPort`, `enableRelay`, `relaySocksPort`, `relayHttpPort` |
| `options/ap.nix` | `apInterface`, `ap.*` including the read-only rule values, `openApFirewall` |
| `options/secrets.nix` | `proxyUser`, `secretsFile` |
| `options/packaging.nix` | `cacheProxyApk` |
| `config/base.nix` | `ap.country` kernel parameter and the assertions |
| `config/tunnel.nix` | `phone-tun.service`, `phone-tun-toggle.service` + `.timer`, tmpfiles and `/etc/phone-link/env` |
| `config/networkmanager.nix` | the AP profile, its migration `preStart` and `/etc/phone-link/ap-profile` |
| `config/ap-dhcp.nix` | `phone-link-ap-dhcp.service` and the hairpin's `ip_forward` |
| `config/firewall.nix` | `phone-link-ap-noforward.service` and the DHCP firewall hole |
| `config/rejoin.nix` | `phone-link-ap-rejoin.service` + `.timer` |
| `config/relay.nix` | `phone-socks-relay.service` |
| `config/resolver.nix` | `/etc/resolv.conf` and resolver pinning |
| `config/packaging.nix` | `system.activationScripts.phone-apk-cache` |

`phone-link-failopen.nix` stays a separate top-level module; the flake imports
it next to `phone-link/` for `nixosModules.default` and
`nixosModules.phone-link`.

## Module options and the units they create

All option defaults and descriptions are in the [options table](options.md).

| Group | Options | Units and generated files |
|---|---|---|
| Tunnel | `enable`, `proxyHost`, `proxyHosts`, `proxyPort`, `proxyUser`, `interfaceName`, `tunAddress`, `logLevel`, `manageResolver`, `enableRelay`, `relaySocksPort`, `relayHttpPort` | `phone-tun.service`, `phone-tun-toggle.service` + `.timer`, `phone-socks-relay.service` (with `enableRelay`); `/etc/phone-link/env` and the `/run/phone-link` tmpfiles — in `modules/phone-link/config/tunnel.nix` and `config/relay.nix` |
| AP | `apInterface`, `ap.role`, `ap.*`, `openApFirewall` | with `ap.role = "local"`: the `NetworkManager-ensure-profiles` AP profile, `phone-link-ap-dhcp.service`, `phone-link-ap-noforward.service` and the DHCP firewall hole; `phone-link-ap-rejoin.service` + `.timer` in both roles — in `modules/phone-link/config/networkmanager.nix`, `ap-dhcp.nix`, `firewall.nix` and `rejoin.nix` |
| Fail-open | `apFailOpen.enable`, `apFailOpen.client`, `apFailOpen.grace`, `apFailOpen.throttle`, `apFailOpen.nat` | `phone-link-ap-failopen.service` + `.timer` — in `modules/phone-link-failopen.nix` |
| Packaging | `cacheProxyApk` | `system.activationScripts.phone-apk-cache` (an activation script, not a unit) — in `modules/phone-link/config/packaging.nix` |
| Secrets | `secretsFile`, `proxyUser` | no unit of its own: the file is the `EnvironmentFile` of `phone-tun`, `phone-socks-relay` and `phone-link-ap-rejoin`, and supplies the AP profile's PSK placeholder — options in `modules/phone-link/options/secrets.nix` |

`configFile`, `effectiveProxyHosts` and `ap.noForwardRules` / `forwardRules` /
`hairpinRules` / `ruleset` are read-only generated values, not settings.

## `result*` at the repo root

- `result`, `result-script`, `result-checks`, `result-live`, … are what
  `nix build -o` leaves behind. A symlink such as `result` points into the Nix
  store, is disposable, and is recreated by the next build; `result-checks/` and
  `result-live/` are real directories.
- `result-checks/timings.csv` is the append-only suite-time history:
  `tests/check-timings.sh` appends one run's rows and compares the next build
  against the previous one. It is not a build output.
- The [checks page](checks.md) describes the same run-keyed history for live
  runs as `result-live/timings.csv`; live harnesses also keep per-run evidence
  under `result-live/` (for example `hairpin-*` from
  `tests/live/hairpin-measure.sh`).
- `.gitignore` covers the whole family with `result-*`. The symlinks can be
  rebuilt; the timing history cannot, so do not commit or delete it.

## Read next

- [README](../README.md) — what it is, the short install and the three commands.
- [docs/options.md](options.md) — every module option and its default; the
  module is authoritative.
- [docs/scripts.md](scripts.md) — every command, the GUI and the screenshots
  runbook.
- [docs/commands.md](commands.md) — the shell/Python split, the action table and
  the exact files a new command touches.
- [docs/checks.md](checks.md) — what each target proves, how to run one and the
  timing history.
- [docs/operations.md](operations.md) — install detail, the two modes, one-time
  setup, uninstall and troubleshooting.
- [docs/phone-network.md](phone-network.md) — measured topology, DNS and the
  traps that cost time.
- [docs/ap-topology.md](ap-topology.md) — laptop-local AP vs external always-on
  AP vs phone hotspot, and what each does on a laptop reboot.
- [docs/external-ap-acceptance.md](external-ap-acceptance.md) — the three-reboot
  hardware runbook for #37, with the AP invariants and the evidence table.
- [docs/hairpin-measure.md](hairpin-measure.md) — the before/after live runbook.
- [docs/proxy-boundary.md](proxy-boundary.md) — which repository owns the app
  contract, build, install and live harnesses, and the change order.
- [AGENTS.md](../AGENTS.md) — the repository rules and the wishlist workflow.
- [MBanucu/phone-link-proxy](https://github.com/MBanucu/phone-link-proxy) — the
  proxy app, its adb contract, its tests and its releases.
