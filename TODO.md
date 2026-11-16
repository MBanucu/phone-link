# Work in progress

Ideas taken from the user's messages, in the order they are being built.
Delete an item once it is implemented and committed; delete the file when the
list is empty.

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

