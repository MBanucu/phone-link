# Work in progress

Ideas taken from the user's messages, in the order they are being built.
Delete an item once it is implemented and committed; delete the file when the
list is empty.

## A failure brings its own pictures

- [ ] When a check fails, pull the frames that explain it out of the recording
  by itself: the start of the step, the moment of the check, and the end of
  the step, plus one before every action the harness took and one after
  every change the accessibility capture recorded, into the run's folder
  next to the XML. The clock mapping it needs is here: every instant the
  phone writes down is in `clock.txt`'s timeline, so the work is the
  harness pulling the frames it wants and naming them after what they show
  (`frame-<check>-<offset>.png`) instead of a person searching for them.

## A recording that can be played before the run is over

- [ ] Record into something streamable. `screenrecord` writes a plain MP4 with
  its index (`moov`) at the end, so `screen.mp4` cannot be played, seeked or
  previewed — in a browser, a player, a mail attachment — until the run has
  finished and the file was closed; a run that is cut short leaves a file
  with no index at all. The pixels are already H.264, so this needs no
  re-encoding: a remux at the end (`ffmpeg -c copy -movflags +faststart`)
  gives a file that plays and seeks from the first byte, and
  `-movflags frag_keyframe+empty_moov` gives a fragmented MP4 that can be
  read while it is still being written. The cost is a second pass over
  5–80 MB at the end of a run (seconds, no decode) and peak disk for both
  copies; the phone's own recorder has no flag for either, so the remux has
  to happen on the host, or the harness has to read the file out to the host
  while the run goes on.

## The proxy app, a project of its own

- [ ] Move `android/` out into its own repository, with its own build and its
  own releases. It started as the other half of this setup — a SOCKS5
  listener the laptop drives — and has become an app with a list of proxies,
  per-proxy segments, its own log and counters, a Quick Settings tile, a
  rename dialog and info marks on every control; none of that is NixOS, and
  the only thing left that ties the two together is the adb contract between
  `bin/` and the service, which the app documents itself (`About this app`)
  and which is worth keeping that way. What moves with it: `build.sh`
  (aapt2, javac, d8, apksigner — no Gradle, no dependencies),
  `android/default.nix`'s APK derivation, the test-only capture app and the
  live harness (`tests/live/proxy-app.sh`, `clock.sh`, `frames.sh`), which
  drive this app and nothing else. What stays: the NixOS module, the
  scripts, the GUI.

  Then the distribution, which is most of the work: an AAB for Google Play
  beside the APK (a tag already publishes a signed APK —
  `.github/workflows/release.yml` with the keystore as a repository secret), a
  `fastlane` metadata tree with description, screenshots and per-version
  changelogs, and the stores themselves. F-Droid first: it is the natural
  home for a dependency-free FOSS app that already builds from source with
  no Gradle, and its inclusion policy fits; IzzyOnDroid is the faster front
  door while F-Droid's own review and build queue is worked through. Google
  Play needs an account, a target-API level to keep up with and Google's app
  signing; Amazon Appstore, Huawei AppGallery and Samsung Galaxy Store take
  the same APK with more paperwork. GitHub Releases plus Obtainium needs
  none of it — a signed APK on a release is installable and updatable from
  the phone — and is worth having from the first tag whatever else happens.

## The scroll that sometimes cannot find Save

- [ ] `plain Save` failed once while the one-step runs were being built, and
  once at 02:46 before that, on `tap-scroll id=save_service 12000`: after
  the port was typed and the keyboard put away, the scroll for the service
  switch row timed out, and the check that saves the switches failed with
  it. Nothing about the app was wrong; the step's own navigation was. It is
  a minute's run now, with `PHONE_LIVE_ONLY="plain Save"`, which is what
  makes it worth chasing.

## The rest of the menu

- [ ] `Save as` and `All events` are the two menu items no step has ever
  pressed; `Delete` was in the same state until the delete-while-running
  step. Both are cheap to write now that the panel helpers exist: Save as
  with a new name has to leave the old proxy alone and open the new one, and
  Save as onto an existing name has to ask before overwriting; All events
  has to show more than the open proxy's own log and say what it is when
  there is nothing in it.

## Test results in something a query can read

- [ ] Every run already leaves rows — a step per row with its seconds and
  counts in `result-live/timings.csv` (and `timings-partial.csv`), a check per
  row with its verdict, file, line and the phone's instant in `checks.csv`,
  and the suites in `result-checks/timings.csv` — but they are flat files keyed
  by a run id and nothing else, and the run's own settings are nowhere: which
  build of the app, which phone, capture on or off, a filtered run and which
  steps, whether the note explains a slow run. Questions that are cheap to ask
  of a database are awkward of a CSV: what a step's median is for each kind of
  run, whether a check has failed before, which steps got slower after a
  change, what a full run costs on this device compared with that one. A small
  relational schema would answer them — `runs` (id, kind full or filtered, the
  steps asked for, started, seconds, pass/fail, device, app build, capture,
  and any other setting the harness read), `steps` (run, name, position,
  seconds, pass/fail), `checks` (run, step, verdict, claim, file, line,
  function, decided_ms) — with the CSV left canonical and a one-way importer
  filling the database, so a run never needs a database to start, an old file
  can be imported again, and a schema change costs a re-import and not a
  reopened history. SQLite in `result-live/` would do: one file, no daemon,
  and `sqlite3` reads it without the project.

## The doctor's live test leaves the daily proxy alone

- [ ] `tests/live/doctor-fix-proxy.sh` breaks the setup on the one app the phone
  lives on: it uninstalls `org.phonelink.proxy`, so a run costs the phone the
  proxies it had saved and reconfiguring afterwards. The app's own harness
  already solved this — `tests/live/proxy-app.sh` drives
  `org.phonelink.proxy.test` out of `phone-link-proxy-test.apk` and never
  touches the daily build — and the doctor's harness only needs the same
  package. What stands in the way is the repair, not the driver: the doctor
  reads `PHONE_PROXY_PKG`, but `phone-proxy-install` installs whatever
  application id the APK carries and `app_apk()` hands it the production build,
  so "reinstall the app" would put the daily proxy back and leave the test one
  gone — a repair of a package the check it was fixing was not measuring. The
  fix should install the APK that matches `PHONE_PROXY_PKG` (the test build for
  the test package, the tree's build otherwise), the harness should run as the
  test package and install it first, and the daily app should still be
  listening on its own port at the end, which the run can require.

## The live doctor test needs a route that survives itself

- [ ] `tests/live/doctor-fix-proxy.sh` is the one live test that takes the
  wireless route away from under itself: step 3 drops the laptop AP, and the
  phone's adb rides on it (`adb devices` has a single `192.168.77.232:<port>`
  transport here), so from that step to the AP coming back — the uninstall, the
  doctor's complaints, `phone-doctor-fix --yes --required`, and the exit trap
  that is supposed to put everything back — every adb call is addressed to a
  transport that no longer answers. What it checks before dropping is the USB
  *tether* (`rndis0` has an address), which is not the same thing: adb can be
  up only over Wi-Fi with the tether sitting there, and the run then cuts its
  own link and cannot restore anything. It should require a route that outlives
  the drop before it drops anything — an adb transport that is a USB serial
  rather than a `host:port` one, or the phone answering at the tether address —
  and skip with the reason (cable, `phone-adb-wifi`) when neither is there, the
  way `tests/live/proxy-app.sh` already refuses to start on a link it cannot
  reach. `phone.sh`'s `adb_link` recovery is the other half of this: mDNS finds
  a rotated wireless port, but not a phone that left the network.

## The saved proxies can leave and come back

- [ ] Every proxy the panel holds — its name, port, SSID, user and password,
  `anonymous`, auto-start and the wireless-debugging switch — lives only in the
  app's own store, so an uninstall (the only way onto a differently signed
  build, which the release APK now is), a lost phone or a factory reset takes
  the lot, and setting it up again means typing passwords on a phone keyboard.
  The panel should export all of them to one file the user picks and import
  them back: `ACTION_CREATE_DOCUMENT` and `ACTION_OPEN_DOCUMENT` rather than a
  fixed path, a small versioned document (the fields above, per name, plus the
  running configuration), and on import a choice between replacing what is
  there and merging by name. It is the only way out through the UI worth
  having: the adb interface deliberately prints no password —
  `phone-proxy-setup --check` says as much — so a `dumpsys`-based export would
  bring back proxies that cannot connect. The file holds passwords, so the
  export should say that plainly and the app should not put it anywhere by
  itself.
