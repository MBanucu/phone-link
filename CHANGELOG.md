# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The 34 scripts in `bin/` are thin shims over one Python function per script in
  `lib/python/phone_link/commands`, built on shared `settings`, `shell`, `phone`
  and `ui` modules. Script names, flags and output are unchanged, so the Nix
  wrappers, the GUI's action table, the doctor and the hermetic tests keep
  addressing the same files.

### Removed

- `lib/phone-ui.sh`, the uiautomator helpers, superseded by `phone_link.ui`.
  `lib/phone-net.sh` stays for the live harness in `tests/live`.

## [0.3.8] - 2026-11-11

### Fixed

- The doctor action and the status page's Fix and Authenticate rows carry the
  lock, since the doctor reads the root-only secrets and its report is
  incomplete without them.

## [0.3.7] - 2026-11-11

### Fixed

- `phone-doctor`'s flake-update check no longer skips silently when the lock
  input has no checkout path (`github:`); it compares the locked revision with
  the input's remote HEAD instead.

## [0.3.6] - 2026-11-11

### Fixed

- The status page keeps an authenticated escalation after an action instead of
  probing as the normal user again, so the root-only checks stay filled in and
  the Authenticate banner does not reappear.

## [0.3.5] - 2026-11-11

### Changed

- Root actions ask for the password once: a cached `sudo -n` is tried first,
  then `sudo -A` with the packaged askpass dialog for the first prompt, and
  `pkexec` only when sudo is unavailable.

## [0.3.4] - 2026-11-11

### Added

- A Fix button on every failing or warning check that has a repair; it runs the
  same action the fixer would, with the existing confirmation and streaming
  output. Root-only secret rows offer Authenticate instead.

## [0.3.3] - 2026-11-11

### Added

- A lock and tooltip on the 19 actions that need root, shown on group pages and
  in search results; `root` and `sudo` are searchable.

## [0.3.2] - 2026-11-11

### Fixed

- Action pages no longer repeat their title in the group header.
- The collapsed layout shows `2 failing` instead of the clipped long verdict,
  and a not-ready setup with no failures reads `not ready` rather than
  `not ready (0 failing)`.

## [0.3.1] - 2026-11-11

### Added

- `phone-link-gui-screenshots`, which builds the panel, drives the real window
  under Xvfb and writes one PNG per state, failing on an all-black capture.

## [0.3.0] - 2026-11-11

### Added

- Search over all actions by name, summary, id and group, with empty and
  no-match states instead of a blank page.
- A spinner while the doctor runs and an error state with Try again when it
  fails, failing and warning counts on section headings, a failing-count badge
  in the sidebar, a coloured exit status on a finished run, and Ctrl+R to
  re-check the setup.

## [0.2.0] - 2026-11-10

First tagged release. The scripts, the module and the panel below all shipped
with it.

### Added

- A GTK4/libadwaita control panel over one action table shared with the CLI in
  `lib/python/phone_link`, with the `registry` check failing when a script has
  no entry or an entry no script; both plan the same argv, including `--check`,
  `--yes` and escalation.
- The flake: the diagnostic and control scripts with every runtime tool wrapped
  onto their `PATH`, a NixOS module for the tunnel (5 s probe timer, never
  started at boot), the declarative `phonelink` access point with DHCP/DNS
  firewall holes and a pinned resolver, a dev shell, a formatter and the checks.
- Proxy scripts: install/update from an APK, F-Droid or the phone itself,
  uninstall, settings through the app's own screen, start, stop, data clear and
  the device-idle whitelist.
- Access point scripts: create the profile from the root-only `PHONE_AP_PASS`,
  up, down and delete, plus the USB tether default/check/cycle trio and
  `phone-wifi-connect`, `-enable`, `-forget` and the read-only STA+AP
  concurrency report.
- adb over Wi-Fi for both the legacy port and Android 11+ wireless debugging,
  `phone-reboot-unlock`, and `net-check` fetching through curl, Chrome and Nix
  to show which path reaches the internet.
- `phone-doctor` with one module per symptom group and `--analyze` output, and
  `phone-doctor-fix` running one script per problem in dependency order.
- `phone-link-uninstall` for the runtime leftovers once the module is unwired.

### Changed

- The AP passphrase lives in the root-only secrets file like the PIN, never in
  the Nix store; the profile is declared through NetworkManager, and a unit
  removes a stale `/etc` copy during migration.

### Fixed

- The panel escapes the doctor's text, so a detail with `<` or `&` renders
  literally instead of being dropped by Pango markup.
- The packaged panel finds its gsettings schemas through `XDG_DATA_DIRS`.
- `phone-doctor` installs under `lib/python`, where its wrapper looks for it.
- The proxy APK cache is found when `HOME` is unset during activation.

[Unreleased]: https://github.com/MBanucu/phone-link/compare/v0.3.8...HEAD
[0.3.8]: https://github.com/MBanucu/phone-link/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/MBanucu/phone-link/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/MBanucu/phone-link/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/MBanucu/phone-link/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/MBanucu/phone-link/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/MBanucu/phone-link/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/MBanucu/phone-link/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/MBanucu/phone-link/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/MBanucu/phone-link/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/MBanucu/phone-link/releases/tag/v0.2.0
