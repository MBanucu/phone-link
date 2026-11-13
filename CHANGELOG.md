# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The panel's own checks can run on the phone, inside the proxy's process.
  `android/devicetest/` is an instrumentation with no JUnit and no androidx — one
  `Instrumentation` subclass, loaded by `am instrument`, that starts the
  activity and reads its views — and the harness's new step `the page from the
  inside` drives it: two saved proxies, one started from its card, the other's
  page saying `Start adds this one beside the others`, that page starting it and
  saying which port it listens on, both cards marked *in use*, the page's `Stop`
  stopping only that one, and the card stopping the last. A check is now a
  claim about a view instead of a claim about a captured hierarchy: the badge,
  the word on the button, the line under it, and the expected strings come from
  the app's own resource table. What it cannot decide is anything outside the
  process — that a port serves, what the screen looks like, `dumpsys`, `logcat`
  — so those stay where they were, and the harness still decides what a verdict
  means, recording every status the phone sends as its own check. `am instrument`
  starts the app's process again, which is why this is a step of its own with
  nothing listening when it starts. Measured: 10 claims (nine checks and one
  that says all nine ran) in 13.0 s, of which about eight is the two profiles
  being saved over adb, against `several at once` losing its three page checks
  and 4.3 s (28.1 s → 23.8 s); the run as a whole went 249 s → 282 s for eight
  more checks, 91 passed and 0 failed.

### Fixed

- A page's Start and Stop mean that page's proxy, and the line under them says
  what Start will do. `Stop` sent a bare `STOP`, which stops *every* listener, so
  with two proxies up the button under one of them closed both; it now names its
  proxy, as does a card's Stop, and the others keep listening. The footer no
  longer claims `Another proxy is running — Start switches to this one`, which
  stopped being true when the service learned to hold more than one listener: it
  says `Stopped — Start adds this one beside the others`, or `Stopped — port N is
  another proxy's; Start replaces it` when a listener already holds the port the
  form would use. The toggle's and the card's `i` dialogs now say the same, and
  that starting marks the proxy *in use* — the mark on its card, which is what
  the tile and a reboot start. Measured on the phone: with `laptop` listening on
  1081 and `footer-check` open on 18082, the footer said the old sentence, Start
  left both ports listening, and Stop closed both; after the change the footer
  says it adds this one, Start opens 18082 beside 1081, and Stop closes 18082 and
  leaves 1081 alone.
- The harness no longer gives up on the capture service after three seconds. A
  freshly installed app's accessibility service can be held back by this phone's
  own startup policy, and a run that came up without it fell back to uiautomator
  and lost 27 checks that need the service — one run did exactly that. It now
  waits up to thirty seconds for a capture to come back before deciding.
- A touch or a drag no longer runs on top of the one before it. The capture
  service dispatched gestures and returned, so four drags 1 ms apart went down
  as one three-fingered gesture that moved nothing, and the tap after them was
  swallowed — two harness checks failed on it (`the mark opens the battery
  request`, `Clear empties the log`) before every gesture was waited out. A
  control that has to be tapped after a scroll now also has to hold still for
  two looks, because a page gliding under a tap has moved it by then.
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

- The panel is now a list of proxies and one page per proxy, instead of four
  pages of one form. Home shows every saved proxy as a card with its name, its
  own state — `Running` (green), `Waiting`, `Stopped` — and what it holds, with
  the one the service is using marked `in use`. Tapping a card opens that proxy:
  its listener and service settings, `Save` and `Revert`, and its own log with
  this run's byte counters. The state is one small line above `Start`/`Stop`
  rather than a block at the top, which is what the list and the form needed.
  With nothing saved the page says so and `New proxy` is the way in; the button
  copies the configuration in use, takes the next free port and opens the
  result, so the opened proxy is the wizard. `Start` on an open proxy stores the
  form into it first, so the proxy that runs is the one that was saved and the
  list marks the right card. Measured on the phone: starting a proxy turns its
  card green and says `in use · port 18080`, and `dumpsys` reports
  `profile "harness-save"`. Every card that has a listener of its own is green
  now that several can run at once.
- One proxy is three segments, not one long page: `Listener` holds the four
  fields and the two listener boxes, `Service` the auto-start and
  wireless-debugging switches with what the phone says about each, `Log` this
  run's counters and that proxy's events. Every control on them carries its own
  small `i` that explains it in a dialog, and so do the one button under the
  segments, the list's `New proxy` and the log's `Clear`. The header is icons —
  back, the warning mark, `i`, the burger — and the app's own `i` is in the
  menu (`About this app`) as well as in the header, where a legacy text button
  used to be.
- The list starts and stops a proxy by itself: every card carries a button that
  says `Start` or `Stop` according to what the service reports for *that*
  proxy, green and `Running` with it, and it never opens the proxy or asks for
  the battery exemption. The open proxy's one button does the same from its own
  page, filled while it starts and plain while it stops.
- The log is per proxy. Every entry is tagged with the proxy it belongs to —
  the service tags what happens while it runs one, the panel tags what it writes
  about a named one — so an open proxy shows its own starts, failures and
  uplink changes; the menu's `All events` still shows everything.
- A saved configuration is the whole panel, not half of it: the two service
  switches (auto-start, wireless debugging) are stored and restored with the
  listener's fields, and the card names them (measured: loading a saved
  configuration with both off flips both boxes, shows `Not saved yet`, and
  leaves the running service on its own values).
- Saving and loading configurations over adb: `SAVE_PROFILE` keeps what the
  service has under `--es profile NAME` without disturbing a running listener,
  `START --es profile NAME` starts that configuration again with any other
  extra applied on top, `dumpsys` lists what is saved with each one's switches,
  and an unknown name starts nothing and says so. Measured on the phone: a
  profile holding `auto-start on · wireless debugging on` brought both back to
  `true` after they had been set to `false`.

### Added

- The harness's scrolling loops run on the phone. A selector is several matchers
  that must sit on the same node (`id=card_name text=hotel`), and with it four
  instructions — `scroll-top`, `scroll-to`, `tap-scroll` and `read`, which
  answers the node's text in the broadcast's result data — so `panel_open`,
  `panel_tap`, `panel_checked` and `ui_text_seek` are one message each instead
  of 8–12. Measured: `tap-scroll` is 1.0–1.4 s from the broadcast to the tap,
  scrolling included, and `scroll-to` 0.9 s; the run is not faster (249.7 s
  against 239.7 s with one check more), because those loops were waiting for the
  page rather than for the round trips.

- Several proxies listen at once. The service holds a listener per port instead
  of one: `START` adds, a start on a port that is already taken replaces what
  held it, `STOP --es profile NAME` (or `--ei port N`) stops just that one and
  `STOP` alone stops them all. Each listener has its own uplink and its own
  byte counters, so a proxy's page says what that proxy moved; `dumpsys` lists
  every running one with its port, bytes and clients, the notification names
  them, the list marks every card that runs and the Quick Settings tile speaks
  for all of them. Starting a proxy on a port that a proxy already holds still
  replaces it, which is what the single-proxy scripts expect.

- Steps that are a straight line run on the phone in one message. The capture
  service takes a `SEQUENCE` broadcast — `tap`, `tap-id`, `tap-text`, `swipe`,
  `text`, `keyboard-off`, `back`, `home`, `wait`, `wait-gone`, `wait-change`,
  `wait-quiet`, `expect` — runs it on a thread of its own, stamps each
  instruction in `actions.csv` and answers with the instruction that failed. The
  harness uses it for the dialog dances (the name prompt, the rename, the menu,
  the battery request on every start, the port field), which removes the
  round trip per tap and per key and with it the Backspace dance that clearing a
  field used to cost. Measured: the new-proxy dialog is 0.9 s in one message, and
  a full run went from 324 s to 264 s with the same 72 checks — the steps that
  open dialogs (`rename`, `info marks`, `new proxy`, `Save`) 3–8 s cheaper each.
  Typing replaces the field instead of clearing it, so the two helpers it
  replaced, `ui_tap_text` and `close_keyboard`, are gone.
- The live harness waits on the phone instead of on the clock. The capture
  service answers a `WAIT` broadcast when the screen holds a piece of XML, stops
  holding it, changes at all, or has stood still for a moment, and the broadcast
  is held until then — so a step that taps and waits for a dialog continues on
  the dialog's event, and a step that taps and waits for the screen to settle
  continues as soon as it has. Measured: a needle already on screen is answered
  in 0.13 s, one that never arrives returns at its timeout, and the run went
  from 377 s to 324 s with the same 72 checks, the dialog-heavy steps (`Save`,
  the info marks, `new proxy`) each 5–11 s cheaper. `PHONE_LIVE_DUMPS=uiautomator`
  keeps the old sleeps, since there is no service to ask.
- Every instant the phone writes down now has a place in the recording. The
  capture service stamps what it records with the phone's own monotonic clock,
  takes the harness's taps and swipes through accessibility instead of sending
  them with `input` (a fresh JVM per call, so nobody could say when one landed),
  and paints the screen magenta at instants it writes down at the start and the
  end of a run; `tests/live/clock.sh` finds those flashes in `screen.mp4` and
  fits a line through them. A run of 380 s fits 16 edges to ±4.5 ms across the
  308 s between the two bursts, drift included (`clock.txt` holds the mapping),
  which turns "the phone did this at
  812345678901234" into "that is 211.962 s into the recording" — checked by
  pulling the frames back out for a capture of the `About this app` dialog and
  one of a proxy created at the end of a run, each showing what its XML says.
  The phone's screen changes 60 times a second, so one flash can only be placed
  to half a frame; the run fails if the fit is worse than 10 ms.
- `New proxy` is pinned under the list instead of sitting at the end of it: with
  ten proxies saved the button was ten cards away, which the live harness's new
  ten-proxy check made plain. Only the cards scroll now.
- The live harness takes its dumps from its own accessibility service
  (`android/capture/`, a test-only APK installed and removed by a run)  instead of `adb shell uiautomator dump`: a requested capture is 0.1–0.4 s against
  2.5 s (a cold JVM plus the wait for a quiet accessibility window), which took
  a whole run from 530 s to under 380 s, and it records a capture for every
  changed screen by itself — 387 in that run against 122 polled ones. It writes
  what `uiautomator` would have: only what is visible and only the windows of the
  app in front, so the harness's lookups behave the same on either source.
- A live run no longer hangs behind Play Protect: the offer to send an unknown
  app for a security check keeps `adb install` waiting on a dialog nobody can
  see, so `verifier_verify_adb_installs` is off for the run and put back after.
- The harness clears the `harness-*` profiles an interrupted run left behind,
  and `panel_open` scrolls to a card instead of requiring it on the first
  screen: a killed run used to poison the next one with its leftovers.
- `RENAME_PROFILE` renames a saved configuration over adb (`--es profile NAME
  --es to NEW`), and `Rename` in the panel's menu does the same on the phone:
  the settings, the two service switches and the mark of which proxy is in use
  move with the name, a name that is already taken is refused, and a proxy that
  is running keeps logging under its new name.
- A live run keeps what a later look needs: the phone's screen as an mp4, the
  screen as XML every time uiautomator serves a dump (about two and a half
  seconds on this phone) with an index of when each snapshot was taken, and one
  appended row per step in `result-live/timings.csv` with its
  seconds and its pass/fail counts. The CSV is only ever appended to, so the
  cost of a run can be read across runs and weighed against running it before a
  commit; `tests/live/frames.sh <recording> 0:42 95.5` turns any moment of a
  recording into a still. `PHONE_LIVE_CAPTURE=0` skips the recording and the
  snapshots, and the phone's autofill service is off for the run because its
  password sheet would take the focus from the next tap.
- The Log page counts bytes: `↓ 6.5 kB · ↑ 1.9 kB · now 0 B/s down, 0 B/s up`
  and a sparkline of the last minute, one line per direction. The counters sit
  where the relay copies (`Socks5Server.pump`), the panel samples them once a
  second while it is in front, and a start resets them, so the page answers
  what this run moved.
- `phone-doctor` grew an `[app]` section: it reports whether this repository's
  app is installed and whether it will actually come back at the next reboot —
  `auto_start` on, on the device-idle allowlist, background location granted —
  naming exactly which of the three is missing. `phone-proxy-boot` is its fix
  (and the fix `phone-doctor-fix` runs for `app_boot`); measured on the phone:
  with the allowlist removed the doctor fails with "not on the battery
  allowlist (run phone-proxy-boot)", `--check` exits 1, and the fix restores it.
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
