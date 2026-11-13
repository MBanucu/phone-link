# Work in progress

Ideas taken from the user's messages, in the order they are being built.
Delete an item once it is implemented and committed; delete the file when the
list is empty.

## Several proxies at once

- [ ] Run several proxies on different ports at the same time, which is what the
      list was shaped for: every saved proxy already carries its own port,
      credentials, SSID, switches, log tag and card. Today the service holds one
      `Socks5Server`, one `Uplink` and one `ProxyState` (`ProxyRuntime.state` is
      a single static), so starting a second proxy replaces the first and the
      panel says so. The work is a runtime table instead of that static: a
      listener and its state per proxy, `START --es profile` adding rather than
      replacing, `STOP --es profile` stopping one and `STOP` stopping all,
      `dumpsys` listing every running proxy with its port and bytes (the traffic
      counters are one total per run today), a notification that names them,
      and the tile deciding whether it toggles all or the last one. The SOCKS5
      side needs nothing: a server binds a port and knows nothing of the others.

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

## Sequences that run on the phone, not one command at a time

- [ ] Let the service run a short sequence of actions itself. Every step of the
      harness is still a conversation: one `am broadcast` per tap or swipe
      (~0.1 s of adb round trip), one per wait, one or two per capture, so a
      step with five actions pays most of a second before the phone does
      anything; measured, the run makes ~120 gestures and ~400 captures, and the
      overhead is tens of seconds of the total. The service already has the
      pieces to do more per message — gestures with the instant they landed,
      Back and Home, waits on the screen (`has`/`gone`/`change`/`quiet`), and the
      XML it writes, which is what turns a control's `resource-id` or text into
      a point on the screen. A sequence would be a small script carried in one
      broadcast and run off the main thread: `tap-id save`, `wait text="Saved"
      2000`, `tap-id port`, `text 18099`, `back`, `settle 250`, `expect
      text="Saved"` — each instruction timed with the phone's clock and written
      to `actions.csv`, the result reported as the broadcast's data (which
      instruction failed, if any). The design question is where the line goes:
      waiting, resolving a control and typing are the phone's business, while
      assertions about `dumpsys`, ports and bytes need the host and must stay
      steps. Sequences would be used where a step is a known straight line — the
      dialog dances, the card toggle, the ten-proxy loop — and the harness would
      keep branching between them on what the host can see. The risk is
      debugging: a script that fails half way has to say exactly where, which is
      why every instruction reports its own outcome rather than a single
      yes/no.

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
