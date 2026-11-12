# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The APK is signed with one key tracked in `android/debug.keystore` instead of
  one generated inside each build. Every `nix build` used a fresh key, so
  `adb install -r` failed with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` and the only
  way in was an uninstall, which threw away the app's configuration. Two
  successive builds now carry the same certificate and install over each other.
- A rotated wireless-debugging port no longer breaks a command. Every adb call
  now goes through `phone_link/adb.py`, which leaves an attached target alone
  (a USB serial costs nothing) and, when a network serial is gone or a command
  failed on it, reads the phone's `_adb-tls-connect._tcp` record, reconnects and
  runs the command again on the advertised port. Resolving a serial
  (`phone_serial()`, the doctor's `Context.serial`) uses the same lookup, so
  "no phone attached" is reported only when the phone really is absent.
  `PHONE_ADB_MDNS=0` disables the lookup.

### Changed

- The title bar is gone, because the only thing in it was the app's own name.
  The header row now holds the name, the `Info` button, a `⚠` that appears
  exactly while a reboot restart cannot work (it opens the battery request
  from any page) and a menu with `Save`, `Save as…`, `Delete configuration` and
  jumps to `Saved` and `Log`. A line under the state names the configuration
  the form is working on, and `Listener` and `Service` each carry a plain
  `Save` that writes the form back to it — saving no longer needs the `Saved`
  page. Measured on the phone: with the exemption removed the header shows
  `⚠` and tapping it opens the battery dialog; `Save` on the `Listener` page
  wrote `port 1082` into the selected configuration.
- The panel fits one screen. The state lines and `Start`/`Stop` are fixed at the
top and bottom and the middle is a menu of three pages — `Listener`, `Saved`,
`Service` — so nothing has to be scrolled to reach a button; the pages are
remembered across a rotation. Everything the old form held is on one page at a
time, and the pages scroll only if a smaller screen needs it.
- A saved configuration is the whole panel, not half of it: the two service
  switches (auto-start, wireless debugging) are stored and restored with the
  listener's fields, the `Holds:` line names them, and loading one leaves the
  switches as a draft until Start, like the fields (measured: loading a saved
  configuration with both off flips both boxes, shows `Not applied yet`, and
  leaves the running service on its own values).
- Saving and loading configurations over adb: `SAVE_PROFILE` keeps what the
  service has under `--es profile NAME` without disturbing a running listener,
  `START --es profile NAME` starts that configuration again with any other
  extra applied on top, `dumpsys` lists what is saved with each one's switches,
  and an unknown name starts nothing and says so. Measured on the phone: a
  profile holding `auto-start on · wireless debugging on` brought both back to
  `true` after they had been set to `false`.

### Added

- A `Log` page: the last 200 events, newest first with a time — service state
  changes with their reason, client counts, settings written, profiles saved,
  loaded and deleted, wireless debugging turned back on, and failures. It is
  in memory only and cleared with a tap; `adb logcat -s phone-link-proxy` stays
  the complete record. A bandwidth graph is not part of it: that needs byte
  counters in the relay and a drawn view, which is a change of its own.
- `DELETE_PROFILE` over adb removes a saved configuration by name, like the
  panel's `Delete`, and leaves a running listener alone.
- The app explains itself. An `Info` button next to the panel's state line
  opens what this app is for, when the port opens, what each control does and
  the whole adb contract with every extra; the service prints that same text
  followed by its current state for `adb shell dumpsys activity service
  org.phonelink.proxy/.ProxyService`, so an agent reads the contract and the
  facts together on stdout. `--ez help true` on the activity opens the dialog
  for a phone in one's hand (a stopped service has no record to dump).
- The battery line is a warning exactly while it warns: red and bold while
  auto-start is on and the exemption is missing, an ordinary small line when
  the checkbox is off. Measured from a screenshot of that row: 31 374 red
  pixels with the box ticked, 0 after unticking.
- The app turns Android's wireless debugging back on by itself when the phone
  joins the configured SSID, because this phone clears the setting on some
  reboots and nothing advertises the adb port while it is off. The panel has a
  checkbox for it ("Turn wireless debugging back on when the phone joins the
  SSID", also `--ez adb_wifi true|false`), and both preference checkboxes now
  follow the store, so a change made over adb while the panel is open appears
  there at once. The write needs `WRITE_SECURE_SETTINGS`, which adb can grant,
  so `phone-proxy-install` grants it after installing this repository's own
  APK. Measured: with the switch on, switching the setting off and having the
  phone re-join `PhoneLink` ends with the app logging `wireless debugging
  enabled (it was off)`, a fresh mDNS record and a working `adb connect`.
- The panel gained a site-manager-like list of saved configurations: `Save
  as…` keeps the form under a name, the picker shows what each one holds
  without the password, `Load` puts one into the form without starting or
  storing anything, and `Delete` removes it after confirmation. The line above
  the form always shows what the service is running with (`In use: …`, or
  `Last started: …`) without touching the edited fields, and `Reset` copies
  that back into the form.
- The panel says what Android's wireless debugging is doing at that moment
  (and when the app lacks the permission to change it), marks edited fields as
  `Not applied yet — press Start` until they are, and exposes the `anonymous`
  extra as "Listen without authentication". Start is the filled button, so the
  action that applies the form no longer looks like the one that stops it.
- `android/`: a SOCKS5 proxy APK of our own, built with `aapt2`/`javac`/`d8`
  instead of Gradle from the new `nix develop .#android` shell. It holds an
  explicit cellular `NetworkRequest` for its egress, listens on the wildcard
  address, takes a wake lock only while a client is connected, and is driven by
  `am start-foreground-service` through a `DUMP`-guarded service, so starting
  the proxy no longer needs the phone unlocked. The listener is gated on the
  uplink: it opens only while the phone is a client of the configured SSID, and
  otherwise stays closed with the reason in the notification. The
  `phone-proxy-*` scripts still drive the vendored app.
- The app has a panel: a launcher activity with the live state, the port, user,
  password, SSID and `any_network` fields, and Start/Stop buttons. It writes
  through the same `ConfigStore` as the adb extras and reads live state from a
  shared `ProxyRuntime`, so both control paths configure one listener; the
  notification now opens the panel.
- The proxy can start without anybody touching it: the panel's "Start
  automatically and keep running" checkbox (an `auto_start` adb extra) makes
  the boot receiver bring the service back after a reboot, `START_STICKY`
  keeps it up, and the existing SSID gate opens the port only on the configured
  network — so the tile is for the cold case, not the daily one. The service
  now declares the `location` foreground type alone, because Android 15 refuses
  a `specialUse` service from `BOOT_COMPLETED`; a start from the shade without
  background location now reports why instead of crashing. The boot restart
  also needs the app on the battery-optimization allowlist — Android 15 treats a
  `location` start from `BOOT_COMPLETED` as a background start — so the panel
  asks for that exemption: a line under the auto-start checkbox reports whether
  it is granted, tapping it opens the system request, and Start asks when
  auto-start is on without it. The measurement behind it: with the allowlist the
  service comes back at boot and serves `200`; without it the system logs
  `Background started FGS: Disallowed` and no port opens.
- The same start and stop are on a Quick Settings tile whose subtitle says
  `listening`, `paused` or `off`. A tile click may start a foreground service
  from the background, but Android only accepts the `location` type there when
  the app may read location in the background, so the service asks for that
  permission and reports a notification instead of crashing the shade when it
  is denied.
- `tests/proxy-app.test.sh` runs 25 hermetic cases for the app (handshake,
  credential failures, CONNECT and reply codes, relay, half-close, client
  counting, configuration rules, status text, runtime listener) on a plain JDK,
  inside the `script` check;
  `tests/live/proxy-app.sh` exercises the installed app on the phone from
  install to uninstall, including the Quick Settings tile, `auto_start`, the
  panel's wireless-debugging line and its "Listen without authentication"
  checkbox. `checks.proxy-apk` and `packages.proxy-apk` build the
  APK in the sandbox, so a compile break fails `nix flake check`.
- `docs/phone-network.md` records why the proxy works at all: the phone's default
  network on the AP link is the laptop, so the app holds an explicit cellular
  `NetworkRequest` and sends its egress out on that network instead. Trap 5 now
  names the wildcard-bind fix and trap 8 the validated-AP case.

### Changed

- The app's SOCKS5 code no longer touches Android APIs: the upstream connection
  and the logger are seams (`Upstream`, `Socks5Server.Logger`), so the protocol
  compiles and runs on a plain JDK and is covered by
  `tests/proxy-app.test.sh`.
- The 34 scripts in `bin/` are thin shims over one Python function per script in
  `lib/python/phone_link/commands`, built on shared `settings`, `shell`, `phone`
  and `ui` modules. Script names, flags and output are unchanged, so the Nix
  wrappers, the GUI's action table, the doctor and the hermetic tests keep
  addressing the same files.

### Removed

- `lib/phone-ui.sh`, the uiautomator helpers, superseded by `phone_link.ui`.
  `lib/phone-net.sh` stays for the live harness in `tests/live`.

### Fixed

- The panel's title bar covered the top of the form: Android 15 lays every
  window out edge to edge for apps that target it, so the device default action
  bar was drawn over the status line and the `Port` label. The app has its own
  theme that opts out of that enforcement, which puts the content back below the
  bar.
- A stop delivered with `am start-foreground-service` (the documented stop, and
  what the live harness cleans up with) never reached the foreground, so the
  system reported a foreground service that did not start in time. The service
  now promotes itself before acting on either action.
- `phone-doctor` recovers from a rotated wireless-debugging port instead of
  calling it "USB only": its adb-over-Wi-Fi check reads the phone's
  `_adb-tls-connect._tcp` mDNS record (`avahi-browse -rtp`), runs `adb connect`
  on that address and reports the transport, so the rest of the report can run
  again after a reboot.
- A reboot rotates the phone's wireless-debugging port, which left the adb
  connection gone and a full-range port scan as the only way back. The phone
  advertises the port over mDNS, so the README replaces the minute-long scan
  with an `avahi-browse _adb-tls-connect._tcp` one-liner that answers in about a
  second.
- `phone-unlock` woke the panel with a single `KEYCODE_WAKEUP` and then typed
  the PIN on faith, so a press that landed while the display was still powering
  on left the phone locked and every caller saw a stale screen. It now reads
  the keyguard and screen state from one `dumpsys window policy` (retrying a
  truncated dump), sends the wake key until the screen reports itself on, uses
  `wm dismiss-keyguard` for a swipe-only lock, and retries the PIN up to three
  times — so `--check` can also say `phone is asleep` instead of claiming the
  phone is unlocked.
- `nix fmt` works again: nixpkgs renamed `nixfmt-rfc-style` to `nixfmt` and the
  formatter script still pointed at the old binary, so it failed without
  formatting anything. The `format` check now also covers `android/shell.nix`.


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
