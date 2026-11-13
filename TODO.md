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

## More of the test on the phone, not over adb

- [ ] Ask how far this goes: a step that is a straight line already runs as one
      message (the sequences above), but the step's *shape* — open this card,
      read that field, decide, go on — is still written in bash. Every decision
      costs a round trip to the host, and every look at the screen costs another
      (about 0.1 s each; the run makes several hundred of them). What could move
      is anything the phone can answer about itself: resolving a control and
      tapping it (done), waiting for it (done), reading a field's text, deciding
      which page or dialog is showing, and the branches that follow from those —
      "if the list is not showing, go back once and look again". What cannot
      move is anything about the rest of the world: a request through the
      tunnel, dumpsys, logcat, the artifacts pulled to the host, the clock
      fit — the phone cannot test the thing the phone is. The shape of the
      answer is probably a second instruction set on top of the sequences — a
      small conditional or a named routine the host can call — plus the harness
      becoming a list of routines with its assertions still in bash, so a
      failure still says which claim was wrong rather than "the script failed".
      Worth doing where a step is long and branchy (`panel_open`, the scroll
      loops, the rename dance); not worth it for a step that is one tap and one
      request. The trap to avoid: a self-reported verdict. The phone may say
      what it saw; the host decides what that means.
