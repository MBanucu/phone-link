# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
