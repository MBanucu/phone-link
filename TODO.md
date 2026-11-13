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

      Then the distribution, which is most of the work: signed release builds in
      CI on a tag (the keystore as a CI secret — not the throwaway debug key
      this repository tracks), an AAB for Google Play beside the APK, a
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

## A stable proxy and a test proxy on the same phone

- [ ] Testing an unstable build must not replace the proxy the phone uses every
      day. Today it does: the harness installs the app under test over the
      installed one (`adb install -r`, the same package, so the same store), and
      every step that saves or deletes a profile, starts and stops listeners or
      flips the service switches runs against the real configuration. Keeping
      the app installed (`KEEP_APP=1`) only keeps the *last tested* build
      installed. What is wanted: two packages on one phone — the stable one the
      phone lives on, and an unstable one from any build — both installable, both
      startable, listening at the same time on their own ports, with their own
      store, their own notifications and their own Quick Settings tiles, so a
      test run never touches the daily proxy and the daily proxy never shows up
      in a test's list. The mechanism is mostly there: the harness takes the
      package name from `PHONE_PROXY_PKG`, the service is addressed as
      `$PKG/.ProxyService`, and the panel reads the package from its own
      resources — so an `applicationId` suffix for a test build
      (`org.phonelink.proxy` vs `org.phonelink.proxy.test`, built by `build.sh`
      with one more `aapt2` flag) may be the whole of it. What has to be checked
      and made explicitly package-relative: the manifest's service, receiver and
      tile components (a `TileService` component is unique per package, and two
      apps both offering "Proxy" in the shade is a thing to expect), the
      notification channel and both notification ids (they are per package,
      which is what makes two notifications possible), the `dumpsys activity
      service` and `am start-foreground-service` commands the scripts and the
      help text use, the preference/store file (already per package), and the
      capture app's a11y setting, which is per component and so already fine.
      Then the harness: install the *test* package, never the stable one, and
      prove in a step that the other one is untouched — its dumpsys still lists
      its listener, its store still holds its profiles. The daily proxy and the
      unstable one also have to coexist as *listeners*: different ports
      (mandatory), and both claiming the SSID is fine, since that is a predicate
      rather than a binding.

## Tests that run on the phone instead of over adb

- [ ] Evaluate on-device testing and use it where it wins. Every check today
      costs a round trip and, worse, a *capture*: the harness asks the phone what
      is on screen, decides on the laptop, and taps over a broadcast. Android
      has frameworks that run inside the device: instrumentation tests
      (`androidx.test` with Espresso for the app's own views, UiAutomator for
      the shade and other apps) launched with `am instrument`, the platform's
      own (deprecated) `InstrumentationTestRunner`, `cmd uiautomator runtest`
      with a jar built against the platform's `uiautomator.jar`, and
      `uiautomator2`-style servers driven from the host. What has to be answered
      first: which of them exist on *this* phone and at this API level, and what
      each costs to build without Gradle and without dependencies — the repo
      builds APKs with `aapt2`, `javac`, `d8` and `apksigner` by hand, and an
      instrumentation APK needs a runner class on the device (either the
      platform runner or a vendored `androidx.test` jar) plus a
      `testInstrumentationRunner` in its manifest, which is more manifest than
      a dependency-free build has ever had to carry. What would actually move:
      assertions about the app itself (this view says that, this switch is off,
      this page is showing), which is most of what the harness checks, and
      waiting for a view instead of for a captured hierarchy — UiAutomator has
      `UiDevice.wait(Until.hasObject(...))` and Espresso synchronises on the UI
      thread by itself. What cannot move: the tunnel tests (a request from the
      laptop through the phone's SOCKS5 port), `dumpsys`, `logcat`, the video and
      the clock fit, and anything about the phone's network — the phone cannot
      test the thing the phone is. A middle path worth costing: keep the harness
      as the driver and the record, but let it call a small on-device test APK
      for the checks that are pure UI (`am instrument` for one test class,
      result read from its output), so the phone decides what it saw and the
      laptop still decides what that means.

## A failure that points at itself

- [ ] Make a failed check say where it failed without a person reading the run.
      Today `bad "the panel lists a configuration saved over adb"` prints the
      claim and, in some steps, `panel_where`; working out *why* means opening
      the artifacts and correlating three timelines by hand — the harness's own
      output, `actions.csv` (the phone's instants) and `ui-index.csv` (which
      capture was which), with `clock.txt` to place them in the video. What
      should be there instead: every check recorded with the harness file and
      line that made it (`BASH_LINENO`, `FUNCNAME`, `$0`), the step it belongs
      to, its verdict and the phone instant it was decided at, in one
      `checks.csv` beside `timings.csv`; and on failure the harness printing, by
      itself, the last handful of things that happened before it — the actions
      and captures from the CSVs around that instant, the screen that was
      captured (or the fact that no capture could be taken, which is itself the
      answer when an app has gone from the stack), and whether the previous
      check in the same step passed. The pieces exist — the capture index, the
      action log, the clock mapping, the per-step timings — the work is one
      timeline assembled at the end of a step rather than a hunt after a run.
      Worth doing before the frames wish, because the frames then hang off the
      instants this produces instead of being guessed.
