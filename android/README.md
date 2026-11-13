# phone-link proxy

The SOCKS5 listener the laptop's tunnel talks to, as our own app instead of the
vendored `com.tokyoxpa3.androidproxy`.

Small on purpose: no AndroidX, no Gradle, no third-party dependencies, so the
build is `aapt2` + `javac` + `d8` + `apksigner` and needs nothing from the
network once the SDK is in the store.

## Why it exists

- **Egress is cellular by construction.** On the AP link the phone's default
  network is the laptop, so a socket opened on the default route comes back to
  the host that asked for it. `Egress` holds an active `TRANSPORT_CELLULAR`
  `NetworkRequest` and resolves and connects on it —
  `docs/phone-network.md`, section "How the proxy gets out over cellular".
- **It listens on `0.0.0.0`**, so the port is the same on `ap0`, `rndis0` and
  `wlan0` and survives the address changing. That is trap 5 fixed rather than
  worked around.
- **The wake lock is held only while a client is connected.** The app it
  replaces holds one for as long as it runs, which made
  `5GProxy::WakeLock` the phone's largest partial wake lock (16 h accounted,
  ~79 min held in one acquisition).
- **No screen automation.** The service is exported and guarded by
  `android.permission.DUMP`, so `am start-foreground-service` drives it and
  nothing else does. Starting or stopping the proxy does not need the phone
  unlocked, a uiautomator dump, or a button text.

## When it listens

The port is only open while the phone is a client of the configured SSID, so it
can sit on a hotel or café Wi-Fi without offering a relay to it:

| phone state | verdict |
|---|---|
| client of the configured SSID (`PhoneLink` by default) | listening |
| joined any other Wi-Fi | paused, port closed |
| no Wi-Fi at all | paused, port closed |

Tethering does not count: the hotspot and USB paths are out of scope for this
app, so the port stays closed there too (the vendored app still covers hotspot
mode).

The service stays in the foreground while paused and reports why
(`not listening: on "FRITZ!Box 7530 XJ", not "PhoneLink"`), so it opens by
itself when the phone rejoins `PhoneLink`. SSID changes arrive as connectivity
callbacks, so nothing is polled.

Reading the SSID is reading location data, and three things are needed for it,
all in the manifest: `ACCESS_FINE_LOCATION` granted and location switched on;
`ACCESS_WIFI_STATE`, because `WifiManager` is the source that is not redacted on
this build (the copy in `NetworkCapabilities` reports `<unknown ssid>`); and a
foreground service of type `location` alongside `specialUse`, because a
`specialUse`-only service counts as a background app for location access. A
redacted SSID is treated as "not the configured one", never as a match.

## Build

```sh
nix develop .#android
./android/build.sh
```

The SDK (build-tools 35.0.0 + platform 35) comes from the flake's `android`
dev shell. `debug.keystore` is tracked in the repository, so every build —
local or in the sandbox — carries the same signature and `adb install -r`
updates the sideloaded app instead of failing with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`. It is a throwaway debug key: never ship
this app with it. `build/` stays ignored. Before the key was tracked, each
`nix build` generated its own and every install needed an uninstall, which also
deleted the app's stored configuration.

`nix flake check` builds the same APK in the sandbox (`proxy-apk`), and
`nix build .#proxy-apk` gives the artifact without a phone.

## Tests

- `tests/proxy-app.test.sh` — hermetic, plain JDK. It compiles `Upstream`,
  `Closeables`, `ProxyConfig`, `ProxyState`, `ProxyRuntime` and `Socks5Server`
  **without** `android.jar` and runs 25 cases: method negotiation, both
  credential failures, unauthenticated mode, CONNECT for IPv4 and for a domain
  name, relaying 32 KiB, half-close, a refused command, an unknown address
  type, an upstream failure reply, client counting, a non-SOCKS greeting; the
  configuration rules (port range, credentials, anonymous, SSID, byte limits);
  the status text the panel, the tile and the notification share; the runtime
  listener; and the `running` flag the tile turns into its subtitle. This is
  why the code has a `Logger` seam, an `Upstream` interface and a config/state
  split instead of `Log.i`, `Egress` and string building inside the service —
  and why the `script` check carries a JDK.
- `tests/live/proxy-app.sh` — needs a phone with a Wi-Fi client link and the
  built APK (by default `android/build/phone-link-proxy.apk`, or the file named
  by `PROXY_APP_APK`). It unlocks the phone through `bin/phone-unlock` when
  `sudo -n` allows it (the shade ignores tile clicks and uiautomator cannot dump
  a sleeping panel), then: install, open the list, require a card to open its
  proxy, `auto_start` showing on the `Service` segment, the header warning and
  the battery request, `200` through the tunnel, a wrong password refused, the
  `anonymous` box applied by the one button, an unrelated SSID keeping the port
  closed with the service up, `any_network` bypassing the predicate, profiles
  saved and loaded over adb, `Save` on both segments, a card starting and
  stopping its proxy, `Rename` from the menu and `RENAME_PROFILE` over adb, the
  info marks and `About this app`, `New proxy`, ten saved proxies without losing
  the button under them, the traffic counters and the log
  on the `Log` segment, stop, start and stop again from the Quick Settings tile,
  and uninstall. A phone that stays locked skips the steps that need the screen
  instead of failing. Not part of `nix flake check`.

  Every run leaves its evidence in `result-live/<UTC start>/` (gitignored, or
  `PHONE_LIVE_ARTIFACTS`): `screen.mp4`, the phone's screen recorded for the
  whole run, and `ui-NNNNN.xml`, the screen as XML for every change the
  accessibility capture recorded — 387 of them in the last run, against 122
  from polling — with `ui-index.csv` giving each one's timestamp and what
  caused it, so what the phone showed at a moment can be re-read afterwards.
  `tests/live/frames.sh result-live/<run>/screen.mp4 0:42 95.5` writes a still
  per moment; it needs ffmpeg on the host. Each step's duration and pass/fail
  counts are appended to `result-live/timings.csv`, one row per step plus a
  `TOTAL` row: the file is never rewritten, which is what makes "how long does
  this run cost" a question with an answer. `PHONE_LIVE_CAPTURE=0` turns the
  recording and the snapshots off for a quick run.

  The steps wait on the phone, not on the clock. The service answers a `WAIT`
  broadcast when the screen does one of three things: holds a piece of XML
  (`--es has 'text="OK"'`), stops holding it (`--ez gone true`), changes at all
  (`--ez change true`), or has been still for a moment (`--ei quiet 250`). The
  broadcast is held, so the harness's next command arrives the instant the
  screen said it — after a tap it asks for "still", after a dialog it asks for
  the dialog's own button — and the answer is the result code: `0` for the
  screen, `1` for the clock. Measured: a needle already on screen answers in
  0.13 s, one that never arrives returns at the timeout with `result=1`, and the
  first run built this way took 324 s against 377 s of fixed sleeps, with the
  steps that open dialogs (`Save`, the info marks, `new proxy`) each 5–11 s
  cheaper. `PHONE_LIVE_DUMPS=uiautomator` falls back to sleeping a second.

  Everything the phone writes down is on one clock
  (`SystemClock.elapsedRealtimeNanos()`, which counts through deep sleep):
  `ui-index.csv` gives each capture the instant it was read, `actions.csv`
  every tap, swipe, Back and Home the service took, with the instant it
  dispatched it, and `input.csv` the typing, which has to go through `input`
  and so carries the two readings that bracket it — the interval the instant is
  inside. Taps go through the service because `input tap` is a fresh JVM per
  call: it costs a third of a second and nobody can say when it landed.

  That clock is tied to `screen.mp4` by flashing: the service paints the whole
  screen the one magenta nothing else here is, at instants it records
  (`clock.csv`), once when the recorder is up and once before it is stopped.
  `tests/live/clock.sh` finds those flashes in the video (decoding at 1×1, a
  few seconds of it) and fits `video_seconds = offset_s + drift * (device_ns -
  ref_ns) / 1e9` into `clock.txt`. Measured on a 380 s run: 16 edges fitted to
  ±4.5 ms across the 308 s between the two bursts. The drift is part of that:
  43 ppm over 308 s is 13 ms, so a mapping without it would be wrong by more
  than the target by the end of a run. One flash on its own can sit a few
  frames away from the line, because a screen changes 60 times a second and the
  encoder skips frames when it is busy with an animation — which is why the fit,
  not the worst edge, is what a run reports. The first burst is looked for from the
  second placed from it, because the recording begins whenever `screenrecord`
  got going and its last frame can be seconds after the last flash (it only
  encodes a screen that changes): neither end of the file is a time the phone
  knows. A run fails when the fit is worse than 10 ms.

  The XML comes from `capture/` — a second, test-only APK with an
  `AccessibilityService` that writes the screen on demand and once per changed
  screen. `adb shell uiautomator dump` costs about 2.5 s here (a cold JVM, then
  the wait for a quiet accessibility window); the service is already connected,
  so a requested capture is 0.1–0.4 s, and the whole run went from 530 s to
  under 380 s while making 6 more checks. The harness installs it, enables it through
  `settings put secure enabled_accessibility_services` (and puts the phone's
  previous value back), and uninstalls it at the end; `PHONE_LIVE_DUMPS=uiautomator`
  keeps the slow path, which is also what happens when the capture APK is not
  built.

  It writes what `uiautomator` would have: only what is visible (an off-screen
  child of a scroll view has no place in a dump, and a caller that taps the
  centre of one taps something else), and only the windows of the app in front
  plus its own dialogs, so the status bar and the launcher behind it stay out
  of the way.

## Run

```sh
adb install -r -g android/build/phone-link-proxy.apk

# start (credentials are required unless anonymous is passed explicitly)
adb shell am start-foreground-service -n org.phonelink.proxy/.ProxyService \
    -a org.phonelink.proxy.action.START \
    --ei port 1080 --es user proxy --es password "$PHONE_SOCKS_PASS"

# stop
adb shell am start-foreground-service -n org.phonelink.proxy/.ProxyService \
    -a org.phonelink.proxy.action.STOP
```

`-g` grants `POST_NOTIFICATIONS` at install; the foreground notification is
what keeps the service out of the background-start rules, and it carries a Stop
action.

The same start and stop are on the phone: the app is a launcher entry ("Phone
link proxy") and the notification opens it.

```sh
adb shell am start -n org.phonelink.proxy/.MainActivity
```

The panel shows the live state (`listening on 0.0.0.0:1080 · 0 clients`, or why
it is closed), pre-fills the stored port, user, password and SSID, and writes
through the same `ConfigStore` as the adb extras, so both paths configure one
listener. `anonymous` stays adb-only, because the panel always asks for a
password; the panel's Start also re-reads the fields, so changing them and
pressing Start restarts the listener with the new settings.

The same two actions are on a Quick Settings tile: tapping "Phone link proxy"
starts the service, tapping it again stops it, and the subtitle says what is
happening — `listening`, `paused` (the service is up but the SSID did not
match) or `off`. The tile follows the panel, adb and the boot receiver because
all of them publish into the same `ProxyRuntime`.

A tile click is user interaction, so the tile may start a foreground service
from the background, but Android still refuses the `location` service type for
such a start unless the app may read location *in the background*. Grant
"Allow all the time" in the app's location settings (`adb install -g` does it
for a test build); without it the service cannot start from the shade at all
and says so in a notification, because a foreground service without a type is
not allowed for this target and a service that cannot read the SSID has nothing
to offer anyway. From the panel the same start works either way, since the app
is visible.

```sh
adb shell cmd statusbar add-tile org.phonelink.proxy/.ProxyTile
adb shell cmd statusbar expand-settings
adb shell cmd statusbar click-tile org.phonelink.proxy/.ProxyTile
```

`click-tile` is a no-op while the shade is closed, so expand it first; to check
the result, `dumpsys activity services org.phonelink.proxy | grep isForeground`
should show `types=0x00000008` (location) and `curl` through the port should
answer `200`.

The panel's other checkbox, "Start automatically and keep running (also after a
reboot)", stores `auto_start`. With it on, the app wants the service up all the
time: `START_STICKY` keeps it alive, the boot receiver starts it after a
reboot, and the SSID gate opens and closes the port as the phone comes and goes
from the AP, so the tile is not needed in the common case. The boot start is
best effort: Android 15 refuses some foreground service types from
`BOOT_COMPLETED`, which is why the service declares `location` alone — a
`specialUse` type, which would describe a proxy better, cannot be started there
at all, and Android 15 counts a `location` start from `BOOT_COMPLETED` as a
background start, which it denies unless an exemption applies. The exemption to
use is the battery-optimization allowlist, and the panel asks for it itself:
the line under the auto-start checkbox says whether it is granted, tapping it
opens the system request, and pressing Start with auto-start on asks when it is
missing. That line is drawn red and bold while auto-start is on and the
exemption is missing, and as an ordinary small line once the checkbox is off —
only a promise the app cannot keep is worth a colour. The adb path has the same switch, and the exemption can be granted
without touching the phone:

```sh
adb shell am start-foreground-service -n org.phonelink.proxy/.ProxyService \
    -a org.phonelink.proxy.action.START --ez auto_start true

# same as the panel's "Open settings" + Allow; survives reboots
adb shell cmd deviceidle whitelist +org.phonelink.proxy
```

Wireless debugging is the other half of that. This phone clears
`adb_wifi_enabled` on some reboots, and while it is off nothing advertises the
port the laptop needs — the old way back was Developer options → Wireless
debugging, which asks for a human on the phone. The checkbox "Turn wireless
debugging back on when the phone joins the SSID" (`adb_wifi`, on by default)
has the app write that setting whenever the uplink gate opens, which is the same
write `phone-adb-wifi` makes over adb. A normal app cannot write a secure
setting, so it needs the one permission adb can hand out:

```sh
# phone-proxy-install runs this after installing this APK
adb shell pm grant org.phonelink.proxy android.permission.WRITE_SECURE_SETTINGS
```

The panel is two screens: home is the list of saved proxies, and one of them
opens for its settings and its log. That page is split into three segments —
`Listener` (the port, the credentials, the SSID and the two listener boxes),
`Service` (auto-start, wireless debugging, and what the phone says about each)
and `Log` (this run's counters and that proxy's events) — so nothing has to be
scrolled past to reach the next thing. `Back` (or the arrow in the header)
returns to the list.

The title bar is gone. Its only content was the app's own name, so the layout
carries a header row of icons instead: the name of the list (or of the open
proxy with a back arrow), a warning mark that appears exactly while a reboot
restart cannot work (tapping it opens the battery request, from either screen),
an `i` for the app's own Info, and the burger. The menu holds `New proxy`,
`Save`, `Save as…`, `Rename`, `Delete` for the open one, `All events`, and
`About this app` — the same Info the header's `i` opens. The open proxy carries
a plain `Save` next to `Revert`, and `Save as…`/`Rename`/`Delete` stay in the
menu so the form is not crowded.

Every control explains itself: the small `i` next to a field, a box, `Save`,
`Revert`, the one button under the segments, `New proxy` and the log's `Clear`
opens a dialog with what that control is for. The marks are the same
information the Info dialog carries, one control at a time, so a first run does
not need the whole contract.

The list is the app: one card per saved proxy with its name, its state —
`Running` in green, `Waiting` while the service is up but the network does not
match, `Stopped` otherwise — and what it holds (`port 1081 · SSID PhoneLink ·
user proxy`, then `auto-start on · wireless debugging on`), never the password.
The card of the one the service is using says `in use · …` and follows the
service as clients come and go. With nothing saved the page says so, and
`New proxy` is the way in either way: it copies the configuration in use — same
credentials and network — takes the next free port, and opens the result, so
the wizard is the opened proxy itself. Only the cards scroll: `New proxy` is
pinned under them, because with a dozen saved proxies a button at the end of
the list is a dozen cards away (measured with ten: the button stays on screen
and the eleventh proxy is created without scrolling). A name that already
exists is refused rather than overwritten; `Save as…` is the way to make a copy
on purpose.

That shape is also where several proxies will report into once the service can
run more than one at a time: a card's state is already that proxy's own state,
and the list is rebuilt from the store. Today exactly one can be running, and
the card of the one that is says so.

There is one button instead of two: it says `Start` while that proxy is not the
one running and `Stop` while it is, on the card and on the open proxy alike. On
the card it starts or stops that proxy without opening it and without asking
for the battery exemption; on the open page it stores the form into the proxy
first and then starts it, so the proxy that runs is the one that was saved and
the list marks the right card. A name is only a label, so `Rename` moves the
settings, the two switches and the mark of which proxy is in use with it.

Each proxy keeps its own log: the last 200 things that happened to it, newest
first with a time — the state changes (`listening on 0.0.0.0:1081 · 0
clients`, `not listening: on "FRITZ", not "PhoneLink"`), its settings being
saved, wireless debugging being turned back on, and failures with their
reason. Events are tagged with the proxy they belong to, by the service while
it runs that proxy and by the panel when it writes about a named one; `All
events` in the menu shows everything, whatever it was about. The log lives in
memory and is cleared with a tap, because the complete record is still
`adb logcat -s phone-link-proxy`.

Above a proxy's events are the traffic counters for the current run — `↓ 6.5 kB
· ↑ 1.9 kB · now 0 B/s down, 0 B/s up` — and a sparkline of the last minute in
one-second steps, one line per direction, hidden while nothing has moved. The
bytes are counted in the relay where they are copied (`Socks5Server.pump`), the
panel samples them once a second while a proxy is open, and a start resets both,
so the page answers "what has this run moved" rather than "what has this phone
ever moved".

Both preference checkboxes follow the store, so `--ez auto_start …` or
`--ez adb_wifi …` while the panel is open shows up there without reopening it.
Ticking wireless debugging stores it at once — it only changes what happens on
the next SSID match — while auto-start waits for `Save`, and a form that
differs from the saved proxy says `Not saved yet — Save writes this to the
configuration`. `Revert` drops the edits and shows the store again.
Under the wireless-debugging checkbox a line says what Android is doing right
now (`Wireless debugging: on — adb can reach the phone`), and why the app cannot
help when the permission was never granted. Everything else on the page is
setup, which only takes effect on `Save` or `Start`: the same page exposes the
`anonymous` extra as "Listen without authentication". Start is the filled
button because it is the one that does something.

The panel also explains itself: the `i` in the header — and `About this app` in
the menu — opens a dialog with what the app is, when the port opens, what every
control does and the whole adb contract, and each control's own `i` explains
that one control. The same text is the service's own `dumpsys` dump,
followed by what it is doing right now, so an agent reads the contract and the
facts on stdout without a screen:

```sh
adb shell dumpsys activity service org.phonelink.proxy/.ProxyService
```

A stopped service has no record to dump, so there the panel is the way in, or
`adb shell am start -n org.phonelink.proxy/.MainActivity --ez help true` opens
the same dialog on the phone.

Measured on the phone (Android 15): with the switch on, `settings put global
adb_wifi_enabled 0` plus the phone re-joining `PhoneLink` ends with
`wireless debugging enabled (it was off)` in the log, the mDNS record back on a
new port and `adb connect` working again; with the switch off the log says
`wireless debugging left alone: the panel switch is off` and the setting keeps
the value it had.

Measured on the phone (Android 15): without the allowlist the receiver logs
`Background started FGS: Disallowed`, the service record stays behind with
`app=null` and no port opens. With it, the service comes back at boot —
`types=0x00000008`, `uplink allowed: on "PhoneLink"`, `listening on
0.0.0.0:1081` — and a request through it answers `200`.

A reboot also rotates the wireless-debugging port, so adb needs the new one.
The phone advertises it over mDNS, which Avahi reads in about a second — much
faster than scanning 32768–60999, where an aggressive scan can also miss it:

```sh
ADDR=$(avahi-browse -rtp _adb-tls-connect._tcp 2>/dev/null |
    awk -F';' '$1=="=" && $3=="IPv4" {print $8":"$9; exit}')
adb connect "$ADDR"
```

Check it:

```sh
adb shell dumpsys activity services org.phonelink.proxy | grep isForeground
curl -sS -o /dev/null -w '%{http_code}\n' \
    --socks5-hostname proxy:"$PHONE_SOCKS_PASS"@192.168.77.232:1080 https://example.com
```

`adb logcat -s phone-link-proxy` reports the bound port, refused credentials and
every CONNECT that had no cellular network to use.

## Settings

Read from the intent on start and kept in the app's private preferences, so a
sticky restart or the boot receiver reuses them:

| extra | default | meaning |
|---|---|---|
| `port` (`--ei`) | `1080` | listen port, `1024..65535` |
| `user` (`--es`) | — | RFC 1929 username, required |
| `password` (`--es`) | — | RFC 1929 password, required |
| `anonymous` (`--ez`) | `false` | listen without authentication |
| `ssid` (`--es`) | `PhoneLink` | SSID the listener may run on |
| `any_network` (`--ez`) | `false` | ignore the predicate and always listen (tests) |
| `auto_start` (`--ez`) | `false` | come back after a reboot and stay up (the SSID still gates the port) |
| `adb_wifi` (`--ez`) | `true` | turn wireless debugging back on when the phone joins the SSID (needs `WRITE_SECURE_SETTINGS`) |
| `profile` (`--es`) | — | the saved configuration to start from; the extras above are applied on top of it |

Every extra is persisted, so a later start without one reuses the stored value;
pass it explicitly to change a setting.

A configuration the service already has can be kept under a name, which is what
the panel's `Save as…` does and what an agent does without a screen:

```sh
adb shell am start-foreground-service -n org.phonelink.proxy/.ProxyService \
    -a org.phonelink.proxy.action.SAVE_PROFILE --es profile hotel
```

Saving does not disturb a running listener. `dumpsys` lists what is saved with
the two switches each one holds, the panel's `Saved` page shows the same names,
and `START --es profile hotel` starts that configuration again later, on any
port or SSID the same command adds on top. An unknown name starts nothing and
logs `no saved configuration called "hotel"`; a name that already exists is
replaced, which is the "save again" the panel asks about and adb does not.
Removing one is the same shape, and also does not disturb a running listener:

```sh
adb shell am start-foreground-service -n org.phonelink.proxy/.ProxyService \
    -a org.phonelink.proxy.action.DELETE_PROFILE --es profile hotel
```

Passing the credential on the `am` command line puts it in the shell process's
argv for the moment the command runs — the same exposure as any `adb shell`
argument, and the reason `phone-link` keeps it in the root-only secrets file
rather than the Nix store. `anonymous=true` is refused by default because a
wildcard listener on a Wi-Fi LAN is an open relay.

## What this scaffold does not do yet

- Tethering is excluded on purpose, so a phone in hotspot or USB-tether mode has
  no listener from this app. Use the vendored proxy for that mode.
- The boot restart depends on the battery-optimization allowlist (see
  `Run`): with it the start is allowed, without it Android 15 denies the start
  and the listener stays off until the next explicit start or the tile.
- The `phone-proxy-*` scripts still talk to the old app's screen and its
  `Start 5G Proxy` / `Stop Proxy Service` buttons. Repointing them at this
  service is the next change, and it deletes the unlock + uiautomator path.
- No `dial` language: it accepts `CONNECT` only. `BIND` and `UDP ASSOCIATE` are
  answered with `command not supported`.
