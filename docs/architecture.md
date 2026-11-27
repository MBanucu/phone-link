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
- `modules/` — `phone-link.nix` declares the options, systemd units and the
  generated sing-box config; `phone-link-failopen.nix` adds the fail-open
  watchdog. Neither contains a shell implementation.
- `lib/` — `python/phone_link/` is the action registry and the command bodies,
  `python/phone_doctor/` the checker (one module per symptom group),
  `python/phone_link_gui/` the GTK4 panel; `lib/*.sh` are the helpers the units
  run (tunnel toggle, AP rejoin, fail-open).
- `bin/` — one shim per command. A shim only resolves `PYTHONPATH` and hands
  over to `phone_link.commands`; the implementation is never here.
- `tests/` — `*.test.sh` are hermetic (stub `adb`/`curl`/`avahi-browse`) and run
  from the flake's `script` check; `tests/live/` needs the real phone and is
  never part of `nix flake check`.
- `docs/` — this map, `options.md`, `scripts.md`, `checks.md`, `operations.md`,
  `phone-network.md` (measured behaviour and traps) and `hairpin-measure.md`
  (the live runbook).

## I want to…

| Task | First file | Test to run |
|---|---|---|
| Change the tunnel | `modules/phone-link.nix` (`phone-tun`, `phone-tun-toggle`, generated config) | `nix build .#checks.x86_64-linux.module` and `bash tests/phone-tun-toggle.test.sh` |
| Change the AP profile | `modules/phone-link.nix` (`networking.networkmanager.ensureProfiles`); the imperative path is `lib/python/phone_link/commands/network.py` | `nix build .#checks.x86_64-linux.module` and `bash tests/phone-ap-create.test.sh` |
| Change the hairpin or fail-open | `modules/phone-link.nix` (`ap.uplink`, the `ap.*Rules` values); `modules/phone-link-failopen.nix` + `lib/phone-ap-failopen.sh` for the watchdog | `nix build .#checks.x86_64-linux.module` and `bash tests/phone-ap-failopen.test.sh` |
| Change or add a command | `lib/python/phone_link/commands/<group>.py`, then its entry in `commands/__init__.py` and `actions.py`; the matching `bin/<name>` is only the shim | `bash tests/<name>.test.sh`, plus `nix build .#checks.x86_64-linux.registry` |
| Change a module option | `modules/phone-link.nix`; document it in the [options table](options.md) | `nix build .#checks.x86_64-linux.module` |
| Add or change a test | `tests/<name>.test.sh` | `bash tests/<name>.test.sh`; all suites: `nix build .#checks.x86_64-linux.script` |
| Change the GUI | `lib/python/phone_link_gui/app.py` (pages beside it); argv still comes from `lib/python/phone_link/actions.py` | `nix build .#checks.x86_64-linux.gui` and `.#checks.x86_64-linux.gui-registry` |
| Change the proxy install | `lib/python/phone_link/commands/phone.py` (`phone_proxy_install`); the app itself is `MBanucu/phone-link-proxy` | `bash tests/phone-proxy-install.test.sh` |

[`nix build .#checks.x86_64-linux.format`](checks.md) guards the Nix files,
[`shellcheck`](checks.md) guards `bin/`, `lib/*.sh` and every `*.sh` under
`tests/`, and [`python`](checks.md) compiles `lib/python/`. Every suite also
runs through the `script` check inside `nix flake check`; [checks.md](checks.md)
has the full table and how to run one target.

## Module options and the units they create

All option defaults and descriptions are in the [options table](options.md).

| Group | Options | Units and generated files |
|---|---|---|
| Tunnel | `enable`, `proxyHost`, `proxyHosts`, `proxyPort`, `proxyUser`, `interfaceName`, `tunAddress`, `logLevel`, `manageResolver`, `enableRelay`, `relaySocksPort`, `relayHttpPort` | `phone-tun.service`, `phone-tun-toggle.service` + `.timer`, `phone-socks-relay.service` (with `enableRelay`); `/etc/phone-link/env` and the `/run/phone-link` tmpfiles — in `modules/phone-link.nix` |
| AP | `apInterface`, `ap.*`, `openApFirewall` | the `NetworkManager-ensure-profiles` AP profile, `phone-link-ap-dhcp.service`, `phone-link-ap-noforward.service`, `phone-link-ap-rejoin.service` + `.timer`, and the DHCP firewall hole — in `modules/phone-link.nix` |
| Fail-open | `apFailOpen.enable`, `apFailOpen.client`, `apFailOpen.grace`, `apFailOpen.throttle`, `apFailOpen.nat` | `phone-link-ap-failopen.service` + `.timer` — in `modules/phone-link-failopen.nix` |
| Packaging | `cacheProxyApk` | `system.activationScripts.phone-apk-cache` (an activation script, not a unit) — in `modules/phone-link.nix` |
| Secrets | `secretsFile`, `proxyUser` | no unit of its own: the file is the `EnvironmentFile` of `phone-tun`, `phone-socks-relay` and `phone-link-ap-rejoin`, and supplies the AP profile's PSK placeholder |

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
- [docs/checks.md](checks.md) — what each target proves, how to run one and the
  timing history.
- [docs/operations.md](operations.md) — install detail, the two modes, one-time
  setup, uninstall and troubleshooting.
- [docs/phone-network.md](phone-network.md) — measured topology, DNS and the
  traps that cost time.
- [docs/hairpin-measure.md](hairpin-measure.md) — the before/after live runbook.
- [AGENTS.md](../AGENTS.md) — the repository rules and the wishlist workflow.
- [MBanucu/phone-link-proxy](https://github.com/MBanucu/phone-link-proxy) — the
  proxy app, its adb contract, its tests and its releases.
