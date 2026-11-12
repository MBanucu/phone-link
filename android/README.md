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
dev shell. `debug.keystore` is created on the first build and kept, so
`adb install -r` accepts the next build; both it and `build/` are ignored.

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
  built APK. It unlocks the phone through `bin/phone-unlock` when `sudo -n`
  allows it (the shade ignores tile clicks and uiautomator cannot dump a
  sleeping panel), then: install, open the panel and require it to stay up,
  `auto_start` reaching the service and showing in the panel, `200` through the
  tunnel, a wrong password refused, an unrelated SSID keeping the port closed
  with the service up, `any_network` bypassing the predicate, stop, start and
  stop again from the Quick Settings tile, and uninstall. A phone that stays
  locked skips the steps that need the screen instead of failing. Not part of
  `nix flake check`.

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
use is the battery-optimization allowlist:

```sh
adb shell am start-foreground-service -n org.phonelink.proxy/.ProxyService \
    -a org.phonelink.proxy.action.START --ez auto_start true

# the boot restart needs this once; it survives reboots
adb shell cmd deviceidle whitelist +org.phonelink.proxy
# or: Settings -> Apps -> Phone link proxy -> Battery -> Unrestricted
```

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

Every extra is persisted, so a later start without one reuses the stored value;
pass it explicitly to change a setting.

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
- No settings activity; everything is driven by adb intents.
- The `phone-proxy-*` scripts still talk to the old app's screen and its
  `Start 5G Proxy` / `Stop Proxy Service` buttons. Repointing them at this
  service is the next change, and it deletes the unlock + uiautomator path.
- No `dial` language: it accepts `CONNECT` only. `BIND` and `UDP ASSOCIATE` are
  answered with `command not supported`.
