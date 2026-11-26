# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The AP can come back after a reboot. The declarative profile hardcoded
  `connection.autoconnect = false`, and nothing ran `phone-ap-up` at boot, so
  the AP stayed down and `phone-tun` had no path until someone brought it up.
  `phoneLink.ap.autoconnect` (default `false`; the generated profile is
  unchanged unless it is set) writes the profile's autoconnect, so
  NetworkManager can activate the AP at boot. Enabling it reserves the radio
  for the AP, and a 5 GHz activation that fails leaves no link at all (see
  #7).

- The tunnel can follow more than one phone address. `phoneLink.proxyHost` is
  still the primary, and the new `phoneLink.proxyHosts` lists fallbacks in the
  order they should be tried, e.g. the USB tether `10.23.190.38` before the AP
  address. The 5 s probe tries each effective host and writes the first that
  answers to `/run/phone-link/proxy-host`; `phone-tun`'s generated config and
  the relay read that file, so switching between USB and the AP needs no
  rebuild. With `proxyHosts = []` the probe and the tunnel behave exactly as
  before.

- The pinned adb port is asked first. The keeper app on the phone keeps adbd on
  `PHONE_ADB_PORT` (5555) after every reboot, so `adb.py` now probes
  `<AP or hotspot address>:5555` whenever a serial has to be resolved or
  retargeted, and only falls back to the `_adb-tls-connect._tcp` record when
  nothing answers there. A pinned phone costs one `adb connect` instead of a
  browse, and the serial it returns is still the right one after the next
  reboot. `phone-doctor` reports that transport as the network transport, and
  the doctor's serial resolution uses the same probe. `PHONE_ADB_MDNS=0` still
  switches both off.

- The proxy port is a control instead of a rebuild. It used to be three facts
  that never met: `phoneLink.proxyPort` was baked into the sing-box config, the
  toggle's probe and the relay; the scripts read `PHONE_PROXY_PORT` from the
  environment; and the phone listened on whatever port its last start or saved
  proxy used — so changing ports was a module edit and a switch, and a phone
  listening elsewhere was found by a failing request. `phone-proxy-switch`
  makes the two ends agree: `--port N` takes a port the phone already listens
  on and `--profile NAME` starts that saved proxy over the app's adb contract
  when it is not running; either way a request through the new port has to
  answer 200 before anything on the laptop changes, the port is written to
  `/run/phone-link/proxy-port` (the default `phoneLink.proxyPort` now names)
  which the tunnel's `ExecStartPre`, the 5 s probe, the relay and the scripts
  read, `phone-tun` and the relay are restarted only if they were running, and
  the phone's listener on the old port is stopped last. A phone that cannot
  start the port, or refuses the laptop's credentials, has what the switch
  started stopped again and the laptop left where it was. The panel has a
  **Proxy port** page that lists the phone's saved proxies and the port in use.
  A saved proxy with another user is refused up front with the reason: adb
  never prints a proxy's password, so the laptop can only offer its own
  `PHONE_SOCKS_PASS`. The doctor grows `proxy_port` — the laptop's port against
  the phone's listeners — and `proxy_request` follows a switch without an
  environment variable.

### Changed

- The laptop access point ran on 2.4 GHz channel 1 at 20 MHz, in the most
  crowded part of the band, which is where the phone's TX retries and the
  laptop↔phone RTT came from. `phoneLink.ap` now defaults to 5 GHz channel 149
  at 80 MHz (`band = "a"`, `channel = 149`, `channelWidth = 80`). 149 is
  non-DFS and one of the 5 GHz channels this Intel 8265 allows an AP to beacon
  on; `iw phy phy0 info` marks 36/44 `no IR` under its self-managed (LAR)
  regulatory domain. `phone-ap-create` writes the same band, channel and width
  for the non-declarative profile, and `channelWidth = 0` lets NetworkManager
  choose the width instead.

### Fixed

- The generated sing-box config no longer puts the proxy password on a command
  line or leaves it world-readable. `phone-tun-config` used `sed` to substitute
  `PHONE_SOCKS_PASS` into a template, which exposed the password in
  `/proc/<pid>/cmdline`, broke on `|`, `&` or `\` in the password, and wrote
  `/run/phone-tun/config.json` as `0644`. It is a small Python writer now: it
  reads the password from the environment, parses the template as JSON, sets the
  outbound port and password, and writes the result atomically with mode
  `0600`. The unit also sets `UMask = "0077"` and
  `RuntimeDirectoryMode = "0700"`.

- The PhoneLink AP is a link, not the phone's internet uplink. The declarative
  profile used NetworkManager's `shared` method, which ran dnsmasq with a router
  and DNS option and installed NAT and forwarding, so Android validated the AP
  and sent every non-proxy flow through the laptop and back over the same 2.4
  GHz link. The profile is `manual` now: the `192.168.77.0/24` address and
  connected route stay, a `phone-link-ap-dhcp` unit answers DHCP only (no router
  or DNS option; `phoneLink.ap.dhcpRange` sets the range and lease time), and a
  `phone-link-ap-noforward` unit drops forwarded packets entering the AP
  interface in its own nftables table, so the drop also holds with the NixOS
  firewall disabled and does not depend on its backend. The same
  `/etc/NetworkManager/dnsmasq-shared.d` drop-ins are read, so the phone's
  `dhcp-host` reservation keeps working. The phone now has no internet path
  through the laptop and keeps mobile data as its default network; the
  laptop→`192.168.77.232` proxy path is output, not forwarding, and is
  unchanged.

- The doctor's one cached answer about releases is named after the repository
  it is about. It was a single file, so pointing `PHONE_PROXY_REPO` at a fork —
  or at the repository the app lived in before it had one of its own — could
  answer with a tag cached from another repository.

## [0.11.0] - 2026-11-17

### Changed

- The proxy app is a project of its own (`MBanucu/phone-link-proxy`) and this
  checkout no longer builds it. `android/`, its flake shell, the `proxy-apk`
  package and check, the release workflow that attached its APK, and the live
  harness that drove it (`tests/live/proxy-app.sh` with `phone.sh`, `clock.sh`,
  `frames.sh`, `pictures.py`, `remux.sh` and `results.py`) left for that
  repository, with `tests/proxy-app.test.sh` and the tests of the harness's
  tools. What stays is what drives it: the adb contract, the scripts, the
  module and the GUI.
- `phone-proxy-install` with no argument is the newest release of the app's
  repository (`PHONE_PROXY_REPO` overrides it), checksum checked. `--build`
  says where the build went instead of installing a file this checkout cannot
  produce, and a file built in the app's checkout is still installed by naming
  it.
- `phone-doctor` reports the version the installed app says rather than warning
  that it is not this checkout's build, and its "newer release" check reads the
  app's repository. `phone-fix-apk` stocks that repository's releases.
- `tests/live/doctor-fix-proxy.sh` takes the test build from a checkout of the
  app's repository (`PHONE_PROXY_APP`, default `../phone-link-proxy`), so the
  repair test no longer needs this tree to build the app.

## [0.10.0] - 2026-11-17

### Added

- The live run presses the two menu items no step had ever pressed. `Save
  as…` was the one way to copy a proxy that the run never used, so a name typed
  into it, a copy that opens in place of its source, the question asked before
  replacing a name, and both answers to it were unverified; `All events` was the
  one view no check opened, so whether it showed more than the open proxy's own
  log — or said anything when there was nothing — was a guess. The steps now
  require a copy under a new name that leaves the source alone and opens the
  copy, a second `Save as…` onto an existing name that asks which name it would
  replace, Cancel leaving that name untouched and OK replacing it with the form,
  and an empty log that says so before an `All events` that shows another
  proxy's start which the open proxy's own page does not. Measured on the phone:
  `PHONE_LIVE_ONLY="save as,all events"` is 70.2 s and 22 checks, green, and the
  first full run to use them still has to write their medians.

- A live run's history is a database as well as a pile of CSVs. The rows were
  there — `timings.csv` with a step per row and its seconds, `checks.csv` with a
  verdict per check — but flat files keyed by a run id and nothing else, so
  "what does this step cost on this phone", "did this check fail before" and
  "which step got slower" were shell one-liners over the whole history or not
  asked at all, and the run's own settings (the build, the phone, capture on or
  off, what a filtered run asked for) were nowhere. Every run now writes those
  settings to `run.csv` before its first step and again when it ends, and
  `tests/live/results.py` fills `result-live/results.sqlite3` with `runs`,
  `steps` and `checks` from the CSVs. The CSVs stay canonical and the import is
  one-way and repeatable, so a run needs no database to start, an interrupted
  run still imports what it reached, and a schema change costs a re-import
  rather than the history. `tests/results.test.sh` covers it without a phone;
  measured against this checkout's own history, the 89 runs import as 384
  steps and 1 577 checks, with the filtered runs that predate their own timing
  file read as filtered and not as green full runs.

- A failed check brings its own pictures. The run kept the recording and the
  clock mapping but left the searching to a person: after a failed step someone
  had to know where in a five-minute video the check was decided. Every failure
  now records the instant it happened, on the phone's own clock, beside its
  step's start and end; once the mapping is fitted, `tests/live/pictures.py`
  pulls the frame at each of those and one just before every action the harness
  took and one just after every change the capture service recorded, into the
  run's folder next to the XML, named after what they show
  (`frame-<check>-<offset>.png`). The run reports how many as a check of its
  own. One decode pass over the failed step's part of the video is the cost —
  measured on a 16 s step with 54 frames of the 379 s recording, 94 s;
  `tests/pictures.test.sh` covers the plan with no phone and no ffmpeg, and a
  green run pays nothing.

### Fixed

- The plain-Save step no longer scrolls a page it never opened. After the port
  was typed and the keyboard put away, the step tapped the Service tab and then
  scrolled for `save_service`; a tab tap is dispatched while the page is still
  redrawing and was sometimes swallowed, so the scroll ran on the Listener page,
  found nothing in its twelve seconds, and the step failed with the save that
  depended on it — twice, and with nothing wrong with the app. `panel_tab` now
  asks the page it wanted for the first control on it, from the top, and taps
  again if the page did not change; `panel_tap` retries a scroll that came back
  without its control; and the plain-Save step checks that the Service segment
  opened instead of letting the next scroll find out for it. Measured on the
  phone: `PHONE_LIVE_ONLY="plain Save"` twice, 12 checks each, green, with
  `PASS the Service segment opens from the field the keyboard raised`.

- The daily proxy coming back when the AP does is checked, not assumed. The
  doctor's live run dropped the laptop AP, and its last step then ran
  `phone-proxy-setup` to start the daily app again — which made a pass
  indistinguishable from a listener that had never come back. That run now
  waits a minute for the app to be listening on the port it had, with nothing
  run to put it there, and only restarts it after the check fails, to leave the
  phone as it was found. The app already followed the network back: measured on
  this phone, dropping the AP pauses the listener within 10 s (`not listening:
  the default network is not Wi-Fi`) and restoring it re-binds `0.0.0.0:1081`
  on its own 25 s later, and the repaired run ends `PASS the daily app came back
  on port 1081 by itself` (26 passed, 0 failed).

- `phone-doctor` can read the app while its service is stopped. `auto_start`
  came from `dumpsys activity service`, which prints nothing for a stopped
  service — so `app_boot` degraded to "allowlist yes, but auto_start could not be
  read" exactly when the app was not listening, which is the state a broken
  phone is in, and the one fact that decides whether it comes back at boot went
  unread. Every change to the app's store now rewrites
  `/sdcard/Android/data/<package>/files/state.txt` with the few facts a check
  asks for (`auto_start`, `adb_wifi`, the port, the SSID it gates on,
  `any_network`, the proxy in use), and the check falls back to that file when
  the dump has nothing. No credentials are in it. Covered by three cases in
  `tests/phone-doctor.test.sh`: a stopped app that will come back is a pass, one
  with `auto_start` off fails naming the switch, and neither place answering is
  still the old warning.

### Changed

- A run's recording plays and seeks from its first byte. `screenrecord` writes
  the MP4 index at the end, so `screen.mp4` could not be played, seeked or
  previewed until the recorder closed it, and a run that was cut short left a
  file with no index at all — the one artifact a person reaches for first was
  the one that was least usable. A run now gives it one copy pass with no
  decode before it exits (`tests/live/remux.sh`), moves the index to the front
  and reopens the first bytes to check that it did, failing a check rather than
  keeping a file it cannot vouch for; `PHONE_LIVE_REMUX=0` keeps the raw
  recording. Measured on the longest recording in `result-live`: 143 MB and
  379 s remuxed in 0.7 s, duration unchanged, clock fit still 1.5 ms. Reading
  the file while the run goes on was the other half of the idea and is not
  what this does: the only way to get frames as they happen is the phone's raw
  H.264 pipe, and raw H.264 carries no timestamps, which is exactly what the
  clock fit maps. The index moves after the run instead.

## [0.9.2] - 2026-11-16

## [0.9.1] - 2026-11-16

## [0.9.0] - 2026-11-16

## [0.8.0] - 2026-11-16

### Added

- The panel can export every saved proxy to one file and import it back. The
  saved configurations — names, ports, SSIDs, users, passwords, `anonymous`,
  `any_network`, `auto_start`, `adb_wifi`, the tile marks, the configuration in
  use — lived only in the app's own store, so an uninstall (the only way onto a
  differently signed build, which the release APK now is), a lost phone or a
  factory reset took the lot and setting them up again meant typing passwords on
  a phone keyboard. The menu writes them through `ACTION_CREATE_DOCUMENT` and
  reads them through `ACTION_OPEN_DOCUMENT`, a versioned JSON document that says
  plainly that it holds plain-text passwords, with replace-all or merge-by-name
  on the way back in. adb cannot: the contract deliberately never prints a
  password, so a `dumpsys`-based export would bring back proxies that cannot
  connect.

## [0.7.0] - 2026-11-16

### Added

- `phone-doctor` says when a newer release exists. The phone knew nothing about
  releases, and it could not have: `AndroidManifest.xml` said `versionCode="1"`
  and `versionName="0.1.0"` for every APK ever built, so a phone three releases
  behind passed every check. `android/build.sh` now stamps the project's version
  into a copy of the manifest from `android/version` (kept equal to the flake's
  `version` by a `nix flake check`), the release asset is named after it, and a
  new `app_release` check compares the installed name with the newest tag — a
  warning, cached for a day, and `skip` on a host that cannot ask.

### Added

- `phone-proxy-install --build` builds this checkout's app and installs it in one
  step, signing with `PHONE_APP_KEYSTORE` when the environment names one. An app
  change needed a shell detour and, worse, an uninstall: the release APK is
  signed with the release key and `android/build.sh` signs a tree build with the
  debug key, so adb refused in place and the way through was
  `--replace-signer`, which takes the app's store with it. The flag says which
  key signs the build before it starts, so an app-side change can be tried on
  the phone the same day it is written.

### Changed

- The release check refetches instead of trusting a stale answer: a cached tag
  that is not newer than the installed build cannot be the newest one, so the
  doctor asks again rather than saying "nothing newer than v0.9.0" to a phone
  running 0.9.1 for the rest of the day.

- The flake packages every script in `bin/` instead of a typed list. The list
  had already drifted — `phone-proxy-boot` was in `bin/` and in the action
  registry but not in the package, so it worked from a checkout and did not
  exist once installed — and only `nix flake check` said so. `phone-link` and
  the GUI stay out by name.

- `phone-doctor-fix` starts the proxy after the AP and the phone's link are
  back. The app only listens on the network the phone joined, so a `SETUP` sent
  while the AP was down was refused by its own SSID gate and the repair reported
  failure over an ordering, not a fault.
- The doctor's live self-repair test runs as `org.phonelink.proxy.test`: it
  uninstalls and reconfigures the test build on port 18080, and requires the
  daily app's state line to be untouched, so a run no longer costs the phone its
  saved proxies. It also refuses to start unless the adb route survives the AP
  drop, and `phone.app_apk()` (and the doctor's copy) install the test build
  when the package under test is the test one.
- `phone-doctor`'s app checks (`app_installed`, `app_boot`) follow the package
  under test instead of `org.phonelink.proxy`. The module hardcoded it, so a
  doctor pointed at the test build read the daily app's allowlist and the test
  app's listener — and reported "not on the battery allowlist" about an app that
  was on it. The service component now carries the app's own class namespace,
  because `.ProxyService` resolves against the manifest package, which a renamed
  build does not share with the Java classes.
- `phone-proxy-install` puts the app back on the battery allowlist. The entry is
  kept by package name and goes away with the uninstall, so an uninstall and
  reinstall quietly lost "comes back after a reboot" until somebody remembered
  `phone-proxy-boot`.
- The repair kit prunes itself. Nothing ever removed an APK from the ambulance
  box, so a host that followed this repository for a year would collect every
  version it ever stocked — 150 kB each, and `apk_cached()` picks by mtime, so
  the museum would slowly push the newest aside. Once the kit holds more than
  three times the size asked for, it is trimmed back to that size, oldest
  first, and the run names what it dropped.

- `phone-doctor-fix` reads its problems from the doctor beside it, not the one
  first on PATH. On a host whose checkout is ahead of the last activation the
  two are different programs, so the fixer reported "no required problems to
  fix" while `./bin/phone-doctor` printed `fail app_boot` — the failure was in a
  check the deployed doctor did not have. The doctor next to the package now
  wins over PATH (a store install finds its own the same way), `PHONE_DOCTOR`
  still overrides both, `--which-doctor` prints the choice without running
  anything, and every run names the doctor it used.

## [0.6.0] - 2026-11-16

### Added

- The ambulance box keeps a repair kit, not just one APK. Installing the app on
  a machine with no tree needed a copy of the build that host made, and that is
  the one version that may no longer be what the phone wants: an older release
  is often the thing that works. `phone-fix-apk --releases [N]` keeps the APKs
  attached to the newest N releases (5 by default) beside the build, each
  checked against the `.sha256` the release carries and named after its tag, so
  two releases of the same app version do not overwrite each other; activation
  runs it with `--refresh`, so the kit follows new releases without anyone
  remembering to ask, and every failure is a warning rather than a blocked
  repair — the box exists for the moment the network is what broke.

- The installer knows about the release APK, and about the key it is signed
  with. A tagged release is the signed copy of this app, but the only way to get
  it was `gh release download` and the only way onto it from a locally built
  install was an uninstall the error never mentioned: adb says
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE` and the script said "adb install failed".
  `phone-proxy-install --release [TAG]` downloads the release's APK, checks the
  `.sha256` beside it and installs it from the cache; `--replace-signer` removes
  the installed copy first, saying what that costs (the app's saved proxies),
  and asking unless `--yes`; and a refused install now names the cause and the
  flag instead of the symptom.

## [0.5.0] - 2026-11-16

### Added

- A tag publishes an installable APK. The app was built locally or not at all:
  the GitHub releases were notes for the flake with no assets, and the only
  signature a build carried was the debug key tracked in this repository, which
  anyone could sign an update with. `android/build.sh` now signs with a key
  named in the environment — `PHONE_APP_KEYSTORE`, its alias and the two
  passwords, which reach `apksigner` as `env:` references so neither shows up in
  a process listing or a build log — and `.github/workflows/release.yml` runs on
  a `v*` tag, builds from the tagged tree with the release key kept in
  repository secrets, reads the certificate back out of the finished APK and
  refuses to publish if it is the debug one, then attaches
  `phone-link-proxy-<version>.apk` and its `.sha256` to the release for the tag.
  A checkout without a release key is unaffected: it still builds the
  debug-signed APK the phone updates in place with.

- A live run says how much of it is left. `result-live/timings.csv` kept one row
  per step per run and was only ever read after the fact; the harness now prices
  the steps it is about to take at the median of their last five runs, marks a
  step with no history of its own (`~`) and lends it the median of the others,
  prints the plan once, and then a line every fifteen seconds naming the step it
  is in, how long that step has been running, what it usually takes and what the
  run has left. A step that outlives its estimate makes the rest of the run look
  slower rather than pinning the number at zero, which is what a run stuck on one
  step would otherwise read as; a step that runs away — twice its usual time and
  half a minute over it — gets a `slow` line of its own, once, so a hang does not
  look like a number that keeps growing; and the last line compares the two: the first
  full run planned 6m59s and took 7m01s (+1%). A filtered run is priced as the
  steps it asked for, not as all of them. The arithmetic is `tests/live/eta.sh`,
  plain bash and awk, and `tests/eta.test.sh` covers it without a phone;
  `PHONE_LIVE_ETA=0` turns the estimate off, `PHONE_LIVE_ETA_EVERY` and
  `PHONE_LIVE_ETA_RUNS` are the knobs.

- The Quick Settings tile can take more than one press to turn off. A press
  used to have two states — start the tile's set, stop it — so a phone whose
  proxies are really two sets, a narrow one that is always on and a wider one
  for the laptop, had to start the second from the panel. "The tile" now has a
  cycle: sets (the tile's proxies, the proxy in use, every saved proxy) that a
  press brings up in that order before the stop side. A set that is already
  fully up is skipped and a wider one starts only what is missing, because a
  listener that is already up would be replaced on its port and lose its
  clients — the second press of "the tile's proxies, then every saved proxy,
  then off" adds the saved ones and leaves the running ones alone, and the
  third stops them all. The subtitle names the set that is up, since a cycle
  nobody can read is a cycle people get lost in: "listening: the tile's",
  "listening: every saved proxy". Empty by default, so the tile is what it
  always was until someone asks for a cycle; `dumpsys` says
  `tile_cycle  none` or names the sets, and the live tile step ticks the box,
  presses three times and requires the tile's set, then the saved ones, then
  nothing, before unticking it again.

- The app builds twice, so a test build can live beside the one the phone runs.
  `build.sh` writes `phone-link-proxy.apk` under `org.phonelink.proxy` and
  `phone-link-proxy-test.apk` under `org.phonelink.proxy.test` from the same
  sources, and a phone holds both: testing an unstable build used to replace the
  daily proxy and run every save, delete and listener against the real
  configuration, and now the two are separate apps with their own store, their
  own listeners, their own notification and their own Quick Settings tile — the
  daily proxy on 1081 and a test build on 18080 answered at the same time, and
  neither listed the other's saved proxies. The manifest names its components in
  full, because a relative `.ProxyService` would follow the relinked id to a
  class that does not exist; the resource table is *not* renamed with it, so an
  id stays `org.phonelink.proxy:id/…` while a component becomes
  `org.phonelink.proxy.test/org.phonelink.proxy.ProxyService`, and the help
  text, the `dumpsys` line it documents and the on-device checks all read the
  package they are running as. The label says which is which — "Phone link
  proxy (test)", "Proxy (test)" — in the launcher, the notification and the
  tile. The live harness installs only the test package and proves the other
  instance is untouched, by reading its dump before the run and requiring the
  same dump after it.

- `dumpsys` says which network the tunnel leaves by. The app pins its egress to
  cellular on purpose — a socket on the default route would come back down the
  Wi-Fi link the requester is on — but nothing said so, and from outside the
  phone the route is invisible: `ping` follows the default route, which is the
  Wi-Fi one. The service now prints `egress ccmni1 (cellular, network 113)`, or
  that it is waiting for a cellular network, or that no listener has started;
  the help text says the dump carries it.

- A tunnel check that fails says whose fault it was. Five checks failed in one
  run — `request through the tunnel`, `two proxies serve at once`, the tile
  starting both — and all of it was the phone's uplink having a bad minute: a
  `curl` through the same proxy answered 200 a few minutes later. The check knew
  only that `curl` exited non-zero, so the run had to be repeated to learn that.
  Now a `tunnel_check` asks the phone whose fault it was: the network the app
  says its egress is bound to, a ping sent through *that* interface, the phone's
  own default route, the app's byte counters and last word for the port. Its
  verdict picks the side — "the app's egress (ccmni1) cannot reach 1.1.1.1: the
  proxy was given a request that network could not carry", "the app's egress
  reaches the internet while the phone's default route does not: the proxy was
  fine", "the app's egress reaches the internet, but that address does not
  answer it: the check's own address was unreachable", "the app is still waiting
  for a cellular network", or "both work, so the proxy is the suspect" — prints
  it under the FAIL with the raw egress line above it, and appends a quoted row
  to `uplink.csv`. Probing the default route was the first version, and it
  tested the wrong path: `ping` follows the Wi-Fi link the laptop made, while the
  tunnel leaves by cellular, so a cellular outage would still have been read as
  a proxy bug. Five adb calls and one `logcat`, paid only when a check fails;
  `PHONE_LIVE_TUNNEL_URL` names the server the checks ask for (default
  `https://example.com`), which is also how the failure path is exercised on
  purpose: pointed at `https://10.255.255.1/` the verdict came back "the app's
  egress (ccmni1) reaches the internet, but that address does not answer it",
  and a green run prints nothing.

### Fixed

- A filtered run counted its preamble nowhere: the seconds that start a proxy on
  the test port and save it — the thing every filtered step opens by — were spent
  but never priced, so the estimate ran short. The second run of `PHONE_LIVE_ONLY
  ="stop"` planned 19.2 s and took 32.9 s (+71%). The preamble is a step of its
  own now — `== preamble` in the log and a row in `timings.csv` — so it is timed,
  priced and borrowed like every other step until it has a history: the next run
  planned 31.9 s against 32.0 s taken (+0%).

- `RENAME_PROFILE renames from adb` waited two seconds after the intent and then
  asked the dump once, which is a guess at whose write lands second: the panel
  is open at that moment and rewrites its own view of the store, and in a full
  run the check lost the race and read the old name. It watches for the change
  now, as the checks that watch the screen already did.

- A run leaves nothing on the phone's card. The screen dumps `uiautomator` was
  asked for (`/sdcard/proxy-app-ui.xml`, `/sdcard/proxy-app-shot.xml`) stayed
  there after runs that ended cleanly, because the cleanup removed the proxies
  it saved and not the files it wrote. They are removed now, and the run asks
  again afterwards rather than trusting the delete — "the run leaves no screen
  dumps on the phone's card" is a check of its own that names what is still
  there. Verified with two dumps planted before the run: gone when it ended, one
  green check. A wildcard delete was the tempting version and the wrong one: it
  would take a `dbg.xml` the run never wrote, on a phone somebody else may be
  using.

- `phone-doctor`'s `[adb over wi-fi]` line can tell a phone whose wireless
  debugging is off from one that is not on the network. Both used to read
  `USB only (phone-adb-wifi)`, which is wrong advice in the first case: the
  phone is on the network, adbd simply is not listening, and the fix is on the
  phone. The mDNS record is now read for what it says rather than for the
  address alone — a name that is announced and never resolves is wireless
  debugging switched off ("announced with no address: wireless debugging is off
  on the phone (or turn it on from a cable with phone-adb-wifi)"), and nothing
  announced at all keeps the old line. Seen for real on 2026-11-15: `46287`
  stopped answering, the record was two announcements with no address for 15 s,
  and the phone came back twenty minutes later on `35161` without a reboot.

- A run no longer blames Wi-Fi for a phone that adb cannot reach. When the
  wireless-debugging endpoint went away, every read through adb came back empty
  and the harness stopped with "the phone needs a Wi-Fi client link for this
  harness (address=none ssid=none)" — a different fault, with a different fix,
  from the one that had actually happened. It now spends one `adb get-state`
  before the first read: a serial that no longer answers is retargeted at the
  endpoint adbd advertises over mDNS (the port changes when wireless debugging
  restarts, not when the phone reboots, so the old one is stale rather than
  wrong), and only when that fails too does the run stop, saying which link is
  gone and what the phone is telling the network — "adbd is advertised with no
  address in its record, which is wireless debugging switched off on the phone",
  "nothing on this network advertises _adb-tls-connect", or "it advertises
  <endpoint>, and that does not answer either". Observed for real: a stale
  `192.168.77.232:46287` was replaced by the advertised `192.168.77.232:35161`
  in the same second, and the run then passed every check.

- A short run's clock fit knew about one burst of flashes. `clock.sh` split the
  phone's record on a gap and looked for each burst in a window of the video,
  but it took every flash in that window as belonging to the burst — so on a
  run short enough to hold both calibrations, a 13-second recording answered 16
  where the burst had 8, and the step failed with "burst 1: 8 flashes in the
  phone's record, 16 in the recording". Three of the twenty-one recordings here
  still failed that way, and it cost about half of the short runs. The video's
  flashes are now split on a gap too, the same 2.5 s at both ends, and the run
  with this burst's number of flashes nearest where the first burst put it is
  the one. Splitting on the gap alone was not enough and the second attempt
  showed why: on an older recording the phone's own flash loop stuttered, with a
  one-second gap inside a single burst, so a 1 s threshold tore a burst in two
  and the search then paired the *other* burst — the states match either way,
  which is why nothing caught it and the fit came out at -985000 ppm. The
  threshold is now 2.5 s (the calibrations are 4 s apart at the least) and the
  matched run has to last as long as the phone's burst, within 250 ms, or the
  step fails saying the two spans. Replaying the fitter over every recording in
  `result-live` recovers the three failures and reproduces every other one
  digit for digit, and the failure now says what the window held ("the recording
  has runs of 8 8") instead of just that it could not be fitted.

## [0.4.0] - 2026-11-15

### Added

- A run keeps its checks as a file. `checks.csv` beside the run's artifacts has a
  row per check — the step, the verdict, the harness file and line that asked it,
  the function it was asked from, when the laptop decided it, and the claim — so
  a failed run can be read as a list instead of as scrollback. A failure also
  prints, by itself, what happened just before it: the previous check in the same
  step, the phone's clock (`/proc/uptime`, the same clock as `actions.csv` and
  `ui-index.csv`, which `clock.txt` maps into the recording), and the phone's last
  three actions and two captures. Measured cost when nothing fails: none; a
  failure costs three adb calls.
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

- The Quick Settings tile has settings of its own, on a page in the app's menu
  (`The tile`). Which proxies the tile switches is now something the phone says:
  every proxy has a switch on its Service page, and the menu's page lists them
  all, so the tile is a switch for a set instead of "whatever was started last".
  A click starts that set while none of it is up and stops it while any is; a
  proxy the tile does not name is left as it is, and with nothing named the tile
  is what it was. What a click starts and what it stops are set separately — the
  proxies on the tile, the proxy in use, or every saved proxy — so "start them
  all, stop only mine" is expressible without a second tile. Long-pressing the
  tile keeps Android's answer (App info): the page is in the app, where the rest
  of its settings live, and reachable without opening the shade. The rules are
  `TilePlan` in plain Java, covered by the JVM suite; the panel, the shade and
  `dumpsys` all read the same `TileScope`.

- The hermetic check knows where its time goes. `nix build
  .#checks.x86_64-linux.script` times every suite and writes `timings.csv` into
  its output — a row per suite, plus the parts a suite knows about, which is how
  `tests/proxy-app.test.sh` shows that 2.2 s of its 2.7 s is one `javac` and
  0.3 s is its 43 cases — and the build log ends with the five slowest, so the
  question is answered by the log that asked it. Because a store path cannot be
  compared with the last one, `tests/check-timings.sh` builds the check and
  appends the rows to `result-checks/timings.csv` (append-only, keyed by run,
  like `result-live/timings.csv`), printing each suite beside the last time it
  was measured. First measurement: 32 suites, 197.8 s, of which
  `phone-fix-internet` 48.6 s, `phone-unlock` 46.1 s and `phone-adb-wifi`
  22.1 s.

### Changed

- The doctor looks at our app, not the 5G proxy. Every doctor line about the
  proxy measured the vendored F-Droid app: presence was `pm path
  com.tokyoxpa3.androidproxy`, the version was whatever F-Droid's API
  suggested, "up to date" compared the two, and the fix reinstalled from the
  ambulance cache or a download. It now measures the app this checkout builds —
  presence from `android/AndroidManifest.xml` (or `PHONE_PROXY_MANIFEST`) and
  the installed app's `versionName`/`versionCode` from `dumpsys package`, so
  "up to date" means "this tree", and a reinstall is `phone-proxy-install` with
  this checkout's build. There is one notion of "the APK" now:
  `PHONE_PROXY_APK`, then `android/build/phone-link-proxy.apk`, then the
  ambulance cache, shared by the doctor, the installer and the repair — so a
  named file that is missing is a required failure instead of a silent fallback.
  `PHONE_PROXY_PKG` still overrides the package and now defaults to
  `org.phonelink.proxy`; `phone-proxy-uninstall` and `phone-proxy-data-clear`
  still work on the vendored app by naming it, `phone-proxy-install --fdroid`
  still installs it, and `phone-fix-apk` copies the build into the cache
  instead of downloading (a build is a file; nothing to fetch).
  `phone-proxy-start`, `phone-proxy-stop` and `phone-proxy-setup` talk to the
  app's own adb interface — `am start-foreground-service` with
  `org.phonelink.proxy.action.START`/`STOP` and the configuration as extras,
  `dumpsys activity service` for what it is doing — instead of unlocking,
  tapping and typing on its settings screen, so a start is one adb call and a
  `--check` is one dump. `phone-proxy-setup --check` also sends one request
  through the listener, because the app prints its configuration but never its
  password. The three suites went from 542 lines of screen driving to 61 cases
  of intents and dumps.

- The live doctor-fix harness repairs with this checkout's build. It stocked the
  ambulance cache first — a download while the phone was still up — and handed
  the repair whatever the cache happened to hold. It now requires
  `android/build/phone-link-proxy.apk` (`PHONE_PROXY_APK=<file>` for another
  one), parks a byte-identical copy of it in the ambulance box before it touches
  the phone, and hands the repair that file, so `phone-doctor-fix --required`
  installs exactly what the tree built with nothing on the network; afterwards it
  requires the doctor to say the app is this checkout's build.

- A filtered run keeps its own timing history. Full runs and `PHONE_LIVE_ONLY`
  runs write their step rows to the same file, and the same step does not cost
  the same in both — `stop` is 2.5 s in a full run and 15–16 s in a filtered one,
  where the app was just installed and the panel is where the preamble left it —
  so every filtered run dragged the medians a full run was planned with, and the
  next full run dragged them back. Filtered runs write
  `result-live/timings-partial.csv` now and are priced from it, while the full
  history is read as full runs only, so the filtered runs it already holds stop
  counting: the full run's plan for `stop` went from 15.4 s to 2.5 s. The first
  filtered run of a new history is priced from the full one and says so by
  marking every step with a `~`, which is what the plan already used for a guess.

- A run can be asked for one of its steps. `PHONE_LIVE_ONLY="card toggle,rename"`
  runs only the steps it names — by the name the log prints — instead of all
  twenty-three: a step is a function now (`card toggle` is `step_card_toggle`)
  and the run walks the list of them, so the filter costs a `case` and no step
  is copied in order to be run on its own. The steps are not independent, so a
  filtered run first does the little preamble any step may lean on — the phone
  awake, the app installed, one proxy saved under the name a page opens by —
  and says what it was asked for in the log, how many of the twenty-three
  actually ran in the summary, and writes a `PARTIAL` row where a full run
  writes `TOTAL`, so the history can never read a filtered run as a green one.
  A name no step answers to stops the run with the list. `checks.csv` gains a
  little by the same move: the `function` column names the step
  (`step_card_toggle`) instead of `main`. Measured: `PHONE_LIVE_ONLY="panel
  state"` is 35.4 s and 6 checks (unlock 10.4, install 5.0, the step 19.7) and
  `PHONE_LIVE_ONLY="plain Save"` 64.4 s and 8 checks, against 304 s and 91
  checks for the whole run.
- A listener is asked for instead of held in the service. `ProxyService` (689
  lines) kept the sockets, the `Running` records that answered for them and the
  store's front door in one class; a listener is now `Port` (174) — the socket
  it binds, the network it waits for, the traffic it moved and the state the
  panel, the tile and the notification read — and the listeners themselves are
  `Ports` (140), keyed by port because a port is what a listener is: a start on
  a taken port replaces that one and leaves every other port listening, a stop
  is a name, a number or all of them, and the order is the order they were
  started in. What is left in the service (547 lines) is what a port cannot
  answer for itself — the foreground notification, the shared cellular egress,
  the wake lock that follows the total clients, the saved configurations and
  the actions adb sends — through a `Port.Host` of six methods. Behaviour is
  unchanged: the live run makes the same claims.
- The panel is three files instead of one. `MainActivity` keeps what a press
  means — Start, Save, Rename, Delete, the dialogs, and the header both screens
  sit under — and asks two screens for the rest: `HomeScreen` draws the list of
  cards, `ProxyScreen` the open proxy's page, each told which proxy it is
  showing. 1111 lines became 740 + 460 + 113, and the page owns the name it is
  showing, so a card and a page cannot disagree about which proxy a press is
  about. Behaviour is unchanged: the live run makes the same claims.
- The live harness is two files: `tests/live/proxy-app.sh` — the run, its
  verdicts, its evidence and the steps that make claims — and
  `tests/live/phone.sh` beside it, which is how to look at and drive the phone:
  captures, gestures, sequences, the panel's navigation, unlock and settings.
  1833 lines in one script became 1192 + 647, so a step reads as a claim instead
  of as adb.
- The card's own Start/Stop is now checked by the phone. The `card toggle` step
  kept eight claims, five of which were only the words on a card
  (Stopped/Start, Running/Stop, the in-use mark); those moved into the on-device
  suite, which already presses the card, and the step keeps what only the laptop
  can see — the listener up after the press, serving this proxy's credentials,
  and gone after the second one. The run went from 91 checks to 86, still green.

### Fixed

- A build that cannot see a file that is not committed now says so. `nix build`
  copies the git tree, so a class added but never `git add`ed is missing from
  the build and javac blames the code that uses it — a page of "cannot find
  symbol" about work that compiles in the checkout. `android/build.sh` adds two
  lines to that failure ("if a class was just added, make sure it is
  committed"), and both dev shells list the untracked `*.java` and `*.xml` under
  `android/` when you enter them.

- Three test suites slept through the check. Most of `phone-unlock.test.sh`'s
  46 s, `phone-fix-internet.test.sh`'s 49 s and `phone-adb-wifi.test.sh`'s 22 s
  was `time.sleep` waiting for a lock screen to animate, a network to come up or
  an adbd port to reappear — on a phone that the test had already replaced with
  a stub. Those waits are `PHONE_UNLOCK_POLL`, `PHONE_FIX_SETTLE` and
  `PHONE_ADB_POLL` now, with the same defaults as the literals they replace, so
  a real phone waits exactly as long as before, and the three suites set them to
  0. Measured with the new timings: the check's 32 suites went 197.8 s → 86.4 s
  (46.1 → 2.5, 48.6 → 1.5, 22.1 → 1.8) with every check still passing — 25, 17
  and 26 of them.

- Deleting a saved proxy over adb took the configuration and left the listener
  running under a name the store no longer had — a port nothing could show and
  the panel could not stop, because the page went with the profile. The comment
  in `deleteSaved` said the listener "keeps its port but loses the name it is
  listed under" and no code did that. It now stops the listener, which is what
  the panel's own Delete already did, so both ways of deleting one end the same;
  the dialog says so too ("If its proxy is listening, its port closes with it").

- A run's verdict is printed after its last check. The summary line came before
  the exit trap that fits the recording to the phone's clock, so it counted one
  check fewer than the run made and — worse — a clock fit worse than 10 ms
  printed its `FAIL` after the script had already decided the exit status, which
  meant a failing run still exited 0. The last steps are over, cleanup decides,
  and an interrupted run keeps the status it already had.

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

[Unreleased]: https://github.com/MBanucu/phone-link/compare/v0.11.0...HEAD
[0.11.0]: https://github.com/MBanucu/phone-link/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/MBanucu/phone-link/compare/v0.9.2...v0.10.0
[0.9.2]: https://github.com/MBanucu/phone-link/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/MBanucu/phone-link/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/MBanucu/phone-link/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/MBanucu/phone-link/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/MBanucu/phone-link/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/MBanucu/phone-link/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/MBanucu/phone-link/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/MBanucu/phone-link/compare/v0.3.8...v0.4.0
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
