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

## Build

```sh
nix develop .#android
./android/build.sh
```

The SDK (build-tools 35.0.0 + platform 35) comes from the flake's `android`
dev shell. `debug.keystore` is created on the first build and kept, so
`adb install -r` accepts the next build; both it and `build/` are ignored.

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

Passing the credential on the `am` command line puts it in the shell process's
argv for the moment the command runs — the same exposure as any `adb shell`
argument, and the reason `phone-link` keeps it in the root-only secrets file
rather than the Nix store. `anonymous=true` is refused by default because a
wildcard listener on a Wi-Fi LAN is an open relay.

## What this scaffold does not do yet

- No SSID/uplink predicate: it listens wherever the phone is. On an unrelated
  Wi-Fi with the service running, port 1080 is reachable by that LAN (behind the
  password).
- No settings activity; everything is driven by adb intents.
- The `phone-proxy-*` scripts still talk to the old app's screen and its
  `Start 5G Proxy` / `Stop Proxy Service` buttons. Repointing them at this
  service is the next change, and it deletes the unlock + uiautomator path.
- No `dial` language: it accepts `CONNECT` only. `BIND` and `UDP ASSOCIATE` are
  answered with `command not supported`.
