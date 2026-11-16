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

## The app comes back when the AP does

- [ ] The app's listener stops when the network it listens on goes away and does
  not start again by itself: the doctor's harness drops the laptop AP, the phone
  leaves the SSID, and the daily proxy sits at `stopped` until something runs
  `phone-proxy-setup` again. `auto_start` is documented as "come back after a
  reboot and stay up (the SSID still gates the port)", so the app should treat a
  network that comes back as a start: listen for the connectivity change and
  bind the port again when the saved SSID is the one the phone joined. Done when
  a run that drops and restores the AP ends with the daily app listening on the
  port it had, without a command being run to put it there.

## The doctor can read a stopped app

- [ ] `phone-doctor` can only read the app's stored settings while its service
  is running — `auto_start` comes from `dumpsys activity service`, and a stopped
  service prints nothing — so the `app_boot` check degrades to "allowlist yes,
  but auto_start could not be read" exactly when the app is not listening, which
  is the state a broken phone is in. The app should publish the few facts a
  check needs (`auto_start`, the listening port, the SSID it gates on) where adb
  can read them without the service: `dumpsys activity service` for a running
  one, and a small file under its own external directory for a stopped one, or
  an `ACTION_REPORT` the doctor can start for one line of output.
