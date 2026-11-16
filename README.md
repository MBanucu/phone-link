# phone-link

Nix flake with scripts and a NixOS module for using an unrooted Android phone as
the laptop's internet uplink and as an adb target over Wi-Fi, without a USB
cable.

- `packages.<system>.phone-link` — the diagnostic/control scripts, with every
  runtime tool wrapped onto their `PATH`
- `packages.<system>.phone-link-gui` — the GTK4/libadwaita control panel (since
  0.2.0)
- `nixosModules.default` — the tunnel, the declarative access-point profile and
  its firewall holes
- `packages.<system>.proxy-apk` — the proxy APK, built from `android/` without
  Gradle
- `devShells.default`, `devShells.android` (the APK toolchain), `formatter`,
  `checks`
- `android/` — the SOCKS5 proxy APK of our own, with a panel and a Quick
  Settings tile for on-device start/stop, several proxies listening at once on
  their own ports, built without Gradle:
  `nix develop .#android && ./android/build.sh`, see `android/README.md`
- `CHANGELOG.md` — released changes, Keep a Changelog format
- `docs/phone-network.md` — measured behaviour, evidence and the traps

## Install the module

```nix
# flake.nix
{
  inputs.phone-link.url = "github:MBanucu/phone-link/v0.4.0";

  outputs = { self, nixpkgs, phone-link, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [
        phone-link.nixosModules.default
        {
          phoneLink = {
            enable = true;
            ap.enable = true;
            apInterface = "wlp110s0";
            proxyHost = "192.168.77.232";
            secretsFile = "/etc/nixos/phone-socks-secrets";
          };
        }
      ];
    };
  };
}
```

Pinning the tag, as above, keeps the machine on a reviewed revision; use the
bare `github:MBanucu/phone-link` to track `main`, and `nix flake update
phone-link` to move from one tag to the next.

The module never starts the tunnel at boot. A 5 s timer probes the proxy port and
keeps `phone-tun.service` running only while it answers, so a missing phone or a
stopped proxy app cannot blackhole traffic.

### Options

| option | default | meaning |
|---|---|---|
| `phoneLink.enable` | `false` | enable the tunnel, timer and AP firewall holes |
| `phoneLink.apInterface` | `wlp110s0` | interface of the laptop access point |
| `phoneLink.ap.enable` | `false` | declare the AP profile from `PHONE_AP_PASS` (requires `phoneLink.enable`) |
| `phoneLink.ap.name` | `phonelink` | NetworkManager connection name |
| `phoneLink.ap.ssid` | `PhoneLink` | SSID of the laptop access point |
| `phoneLink.ap.band` / `channel` | `bg` / `1` | 802.11 band and channel |
| `phoneLink.ap.address` | `192.168.77.1/24` | IPv4 address of the AP interface |
| `phoneLink.proxyHost` | `192.168.77.232` | address of the phone's SOCKS proxy |
| `phoneLink.proxyPort` | `1080` | SOCKS port |
| `phoneLink.proxyUser` | `proxy` | SOCKS username |
| `phoneLink.secretsFile` | `/etc/nixos/phone-socks-secrets` | file with `PHONE_SOCKS_PASS=…` (and `PHONE_AP_PASS=…` with `ap.enable`) |
| `phoneLink.interfaceName` | `phone-tun` | TUN device name |
| `phoneLink.tunAddress` | `172.19.0.1/30` | TUN address |
| `phoneLink.logLevel` | `warn` | sing-box log level |
| `phoneLink.cacheProxyApk` | `true` | stock the ambulance kit during activation: this checkout's proxy APK plus the APKs of the newest releases, so every install/update leaves versions a repair can fall back on |
| `phoneLink.manageResolver` | `true` | pin `/etc/resolv.conf` to `1.1.1.1`/`9.9.9.9` |
| `phoneLink.openApFirewall` | `true` | allow DHCP/DNS from AP clients |
| `phoneLink.enableRelay` | `false` | run the local SOCKS/HTTP relay (`gost`) |
| `phoneLink.relaySocksPort` / `relayHttpPort` | `1081` / `1082` | relay ports |

## Use the scripts

```sh
nix build            # ./result/bin/{phone-net-status,phone-ap-up,…}
nix run              # phone-net-status
nix develop          # shell with the scripts and their tools
```

Or straight from the checkout: `./bin/phone-net-status`.

| script | what it does |
|---|---|
| `phone-net-status` | links, routes, resolver, proxy probes, adb transports, phone state |
| `phone-doctor` | check every runtime condition of the setup (forwarding, AP profile/address, adb, phone link, secrets, proxy, tunnel, tether, internet), the APK this checkout builds, the installed app versus this checkout's `android/AndroidManifest.xml` (or `PHONE_PROXY_MANIFEST`) and the phone SDK, and whether the source checkout is newer than the installed flake lock; exit non-zero if a required one is unmet; the adb check reconnects a phone whose wireless-debugging port changed by reading its `_adb-tls-connect._tcp` mDNS record; `--analyze` prints one `fail`/`warn` line with a stable problem id for scripts |
| `phone-doctor-fix` | list the fixes for the problems `phone-doctor --analyze` reports, run one dedicated script per problem in dependency order, then re-check (`--yes` skips the prompt, `--dry-run` only lists, `--required` leaves warnings alone, `--which-doctor` prints the `phone-doctor` it reads — the one beside the checkout unless `PHONE_DOCTOR` says otherwise; run with `sudo`) |
| `phone-fix-apk` | stock the ambulance box: copy this checkout's proxy APK into `/var/cache/phone-link` so a repair on a machine without the tree can still reinstall the app; `--releases [N]` also keeps the APKs of the newest N releases (5 by default) as a repair kit of several versions, each checked against its `.sha256` and named after its tag, older ones pruned past three times N (`--refresh` replaces the copy and refreshes the kit, `--check` lists the box) |
| `phone-fix-forwarding` | set `net.ipv4.ip_forward=1` for the running kernel (`--check` reports only) |
| `phone-fix-internet` | restore internet for the APK download/check by trying mobile data, USB tethering, then the phone hotspot with the laptop as a client, verifying HTTPS after each (`--check` reports only) |
| `phone-fix-mobile-data` | enable the phone's mobile data and wait for a default route (`--check` reports only) |
| `phone-fix-tunnel` | start `phone-tun`, or restart it when its route is missing, and wait for the route (`--check` reports only) |
| `phone-proxy-check` | request through the proxy on the hotspot and AP addresses (needs root for the secret) |
| `phone-proxy-install` | install/update the proxy app — this checkout's build (`android/build/phone-link-proxy.apk`) unless an APK is named; `--release [TAG]` takes the APK attached to a release of this repository (checksum checked), `--build` builds this checkout and installs what it produced (with `PHONE_APP_KEYSTORE` in the environment the build is signed with that key, so it goes over a release-signed app without an uninstall), `--fdroid` fetches the vendored F-Droid app instead, `--replace-signer` uninstalls a differently signed copy first (which clears its data), `--pull` copies the installed APK off the phone, `--status` reports the version |
| `phone-proxy-uninstall` | remove the proxy app (`--check` previews, `--keep-data` keeps app data, `--yes` skips the prompt) |
| `phone-proxy-data-clear` | wipe the proxy app's data, back to port 1080 with no auth (`--check` previews, `--yes` skips the prompt) |
| `phone-proxy-battery-whitelist` | add the proxy app to the device-idle (Doze) whitelist so the proxy is not killed with the screen off (`--check` only reports) |
| `phone-proxy-boot` | make this repository's app actually come back after a reboot: allowlist it, grant background location and turn `auto_start` on (`--check` reports which of the three is missing) |
| `phone-proxy-setup` | start the proxy through the app's own intent with the port, credentials and auto-start as extras, then verify a request through the listener (`--check` reports the settings and checks the request) |
| `phone-proxy-start` | start the proxy through the app's own intent and wait until the service says it is listening (`--check` only reports) |
| `phone-proxy-stop` | stop the proxy through the app's own intent and wait until the service is gone (`--check` only reports) |
| `net-check` | fetch a fresh URL with curl, Chrome and Nix, reporting which of the three reach the internet |
| `phone-reboot-unlock` | reboot the phone, wait for boot, then unlock once (`--yes` skips the prompt) |
| `phone-tether-cycle` | switch USB to MTP so `net-check` runs with RNDIS off, then lock and unlock the phone to restore the tether, verify it and report (`--yes` skips the prompt; needs the PIN, so run with `sudo`) |
| `phone-usb-tether-check` | report whether USB tethering is active and whether the internet answers over the host's tether route |
| `phone-usb-tether-default` | make USB tethering the default USB action, keeping adb (`--check` reports only) |
| `phone-wifi-connect` | join PhoneLink (or another SSID) with WPA2 and wait for the association (`--check` reports) |
| `phone-wifi-enable` | turn the phone's Wi-Fi radio on (`--check` reports) |
| `phone-wifi-forget` | forget a saved network, default PhoneLink (`--check`, `--yes`) |
| `phone-wifi-concurrency` | report whether Wi-Fi client and hotspot can run together (STA+AP), read-only; exit 2 if the phone does not say |
| `phone-unlock` | unlock the lock screen with `PHONE_PIN` from the secrets file (`--check` only reports locked/unlocked) |
| `phone-ap-create` | create the `phonelink` AP profile from the root-only `PHONE_AP_PASS` secret (`--refresh` rewrites it after a PSK change, `--check` reports) |
| `phone-ap-delete` | delete the `phonelink` AP profile from NetworkManager, bringing it down first if active (`--check` reports, `--yes` skips the prompt; a declared profile returns at the next boot) |
| `phone-ap-up` | preflight the radio, then `nmcli connection up phonelink` |
| `phone-ap-down` | drop the AP and rejoin the phone's hotspot |
| `phone-link-uninstall` | remove the AP profile and APK caches after unwiring the module (`--check`, `--yes`, `--keep-cache`); straight from the checkout |
| `adb-wifi-connect` | connect adb to the phone over TCP |
| `adb-wifi-connect --prepare` | once over USB: `adb tcpip 5555` (the tether blips) |
| `phone-adb-wifi` | enable adb over Wi-Fi on the phone: legacy `adb tcpip 5555` and Android 11+ wireless debugging on its random TLS port, then connect (`--legacy`, `--tls`, `--check`) |
| `phone-proxy-install` | install the APK with `-r -g`; for this repository's own app it also grants `WRITE_SECURE_SETTINGS`, which lets the app turn wireless debugging back on itself |
| `phone-tunnel-run` | run the built tunnel config in the foreground |
| `phone-tunnel-run --via-adb` | same, with the upstream reached through `adb reverse` |

`phone-doctor` is a Python package under `lib/python/phone_doctor`, with one
module per symptom group (`flake`, `host`, `phone`, `secrets`, `proxy`,
`tunnel`, `tether`, `internet`, `adb_wifi`); `bin/phone-doctor` only resolves it.
`lib/phone-net.sh` remains for the live harness in `tests/live`.

`lib/python/phone_link/commands` holds the CLI half: one function per `bin/`
script, grouped by area (`status`, `phone`, `network`, `proxy`, `device`,
`maintenance`, `doctor_fix`), with `settings`, `shell`, `phone` and `ui` as the
shared layer. A `bin/phone-*` file is a thin shim that resolves the package next
to the checkout or the store install and hands over to it, so the script names
stay the contract: `phone_link.actions`, the Nix wrappers, the doctor and the
tests all address them by name.

## GUI

`packages.<system>.phone-link-gui` is a GTK4/libadwaita control panel for the
same setup, new in **0.2.0**. It reads the doctor's `--json` report for its
status page and runs the scripts with the flags declared in
`lib/python/phone_link/actions.py`:

```sh
nix run .#gui                                 # from a checkout
nix run github:MBanucu/phone-link/v0.4.0#gui  # straight from the tag
nix build .#phone-link-gui                    # or build it and run the binary
```

The module installs the scripts but not the panel; add the package to get the
desktop entry and icon as well:

```nix
environment.systemPackages = [ phone-link.packages.${pkgs.system}.phone-link-gui ];
```

Every action has its `--check` preview plus its variants (F-Droid install,
tunnel through `adb reverse`, legacy adb port, keep-cache uninstall, …) in the
row's menu, and the output streams into a log window exactly as the script
printed it, exit status included. The header searches every action by name or
summary (Ctrl+F), the sidebar badges the number of failing checks, and Ctrl+R
re-checks the setup. Failing and warning checks that have a repair carry
a **Fix** button that runs the same script the doctor's fixer uses; the
root-only `secrets` rows offer Authenticate instead. Nothing is reimplemented: `phone_link.actions`
decides the argv and `phone_link.runner` streams it for both the GUI and
`phone-link run`, and the `registry` check fails when a script exists in `bin/`
without an action entry.

Actions that need root escalate with `sudo`, so the first one asks for the
password in a small dialog and sudo remembers it for a few minutes: the
following root actions run without asking again. Where sudo is not usable,
`pkexec` is the fallback, and that one does ask every time (its policy is
`auth_admin`). Those rows carry a lock (searching `root` lists them), and the
status banner offers the same authentication for the root-only secrets, which
otherwise show as unreadable. The layout collapses to a single
pane below 720sp, so a narrow window or a touch screen still works.

### Screenshots

`bin/phone-link-gui-screenshots` builds the panel from the checkout and writes
one PNG per state into `screenshots/`: the status page with this machine's
doctor report, every action page, the search states, the narrow layout and a
failed run. It needs `nix`, `Xvfb`, `dbus-run-session` and ImageMagick, and
takes `--out DIR` (and `--scale 1` for smaller files). A capture that comes out
all black fails the run instead of being written.

```sh
bin/phone-link-gui-screenshots
```

`phone-link list` and `phone-link run <id> [--check] [--yes]` are the CLI half of
the same table, and `phone-link status` prints the doctor's JSON.

## Checks

`nix flake check` runs these checks per system:

| check | what it proves |
|---|---|
| `registry` | every script in `flake.nix` has an action in the GUI's table, and every action has an executable script |
| `gui-registry` | the packaged GUI imports GTK4/libadwaita and its table matches the scripts |
| `gui` | the real window, every page and the log window construct under Xvfb |
| `package` | every script in the flake exists, is executable, kept its wrapped `PATH`, and `phone-net-status` prints a status |
| `proxy-apk` | the app in `android/` compiles and signs in the sandbox, so a break fails the check instead of a manual build |
| `shellcheck` | every script and `lib/phone-net.sh` is clean at shellcheck warning level |
| `format` | `flake.nix`, `modules/phone-link.nix` and `android/default.nix` are nixfmt-clean |
| `module` | the module generates the expected sing-box config and units (5 s probe, 20 s first run, AP DHCP/DNS holes, pinned resolver, never started at boot) and defines nothing when disabled |
| `script` | hermetic tests with stub `adb`/`curl`/`avahi-browse`: for `phone-proxy-install` the F-Droid version selection, cache keying and reuse, `--check` staying read-only, the exact install argv and `--pull` naming; for `phone-proxy-uninstall` the confirm/`--yes` guard, `--keep-data`, idempotence and the exact uninstall argv; for `phone-proxy-data-clear` the prompt guard, `--check` staying read-only and the `pm clear` argv; for `phone-proxy-setup` the START intent's extras, the verification request, the settings `--check` against a stub service dump; for `phone-unlock` the keyguard check, PIN entry and wrong-PIN failure; for `phone-proxy-battery-whitelist` the idempotent add, `--check` and the device-idle argv; for `phone-proxy-start`/`phone-proxy-stop` the START/STOP intents, the dumped state, the already-running/stopped no-op, the gated start and the proxy that will not stop; for `phone-wifi-concurrency` the supported, unsupported and inconclusive verdicts and the read-only queries; for `phone-usb-tether-check` the rndis0/usb state, the host route and a source-bound request; for `net-check` the three fetches, their failure modes and the cache-busting URL; for `phone-reboot-unlock` the reboot/wait/unlock sequence, the slow-boot wait, the aborted prompt and the boot timeout; for `phone-usb-tether-default` the current and screen-unlocked functions, the `--check` report and an ineffective setter; for `phone-wifi-enable` the idempotent enable and `--check`; for `phone-wifi-forget` the saved-network table, the prompt/`--yes` guard and idempotence; for `phone-wifi-connect` the password sources, remote quoting of SSID/passphrase and the association wait; for `phone-tether-cycle` the MTP disable, the health check, the lock/unlock restore, an adb abort retry, the already-off case, an unhealthy restore and the prompt guard; for `phone-adb-wifi` the legacy/TLS split, the mDNS port lookup, the `adb_wifi_enabled` write, the already-on case and the missing-port failure; for `phone-doctor` the ready, hotspot, locked, missing-adb, missing-secrets and dead-proxy paths, the app that is off the battery allowlist or has `auto_start` off (named separately in `[app]`), plus a rotated adb port found over mDNS; ; and `tests/phone-adb-mdns.test.sh` the stale network serial that is rewritten to the advertised port, the retry after a transport vanished mid-command, the serial recovered from the record when `adb devices` is empty, the preferred address when two phones are advertised and `PHONE_ADB_MDNS=0`; and `tests/proxy-app.test.sh` compiles the app's Android-free classes and runs the SOCKS5 handshake, authentication, CONNECT/reply codes, relay, half-close and client counting against a local echo upstream, plus the configuration rules, the status text and the runtime listener |

The `script` check also covers `phone-doctor --analyze` (problem ids, AP down and
a missing APK, warnings-only, no headers or `ok` lines),
`phone-doctor-fix` (dry run, ordered application, an install from the tree's
build, the manual APK step, manual-only and failed-fix paths) and the fix scripts (ambulance APK, AP
profile creation from the secret, forwarding, mobile data, tunnel: apply,
no-op and read-only `--check`).

### Where the check's time goes

`nix build .#checks.x86_64-linux.script` times itself: `timings.csv` in the
output has a row per suite and, where a suite knows them, a row per part —
`tests/proxy-app.test.sh` splits its `javac` from its `cases` — and the build
log ends with the five slowest, so the question "which suite got slower" is
answered by the log that asked it. A store path cannot be compared with the
last one, so `tests/check-timings.sh` builds the check, appends the rows to
`result-checks/timings.csv` (append-only, keyed by run, like
`result-live/timings.csv`) and prints every suite beside the last time it was
measured:

```sh
bash tests/check-timings.sh
```

A suite that wants its own parts named writes `part,ms` rows to the file in
`$PHONE_TEST_TIMINGS` and the check adds the suite's name to them.

A suite that waits — for a lock screen to animate, for adbd to come back, for a
network to come up — is waiting for a phone that a stub is not, and it used to
do that in real seconds: `phone-unlock` spent 46 s of a 198 s check asleep in
`time.sleep`, `phone-fix-internet` 49 s and `phone-adb-wifi` 22 s. Those waits
are now `PHONE_UNLOCK_POLL`, `PHONE_FIX_SETTLE` and `PHONE_ADB_POLL` (defaults
unchanged, so a real phone waits exactly as before) and the three suites set
them to 0, which is 86 s for the whole check instead of 198 s with the same
checks passing.

### Live end-to-end test

`tests/live/doctor-fix-proxy.sh` breaks the setup on purpose and checks that the
doctor repairs it. It runs the app's **test build**
(`org.phonelink.proxy.test`, from `android/build/phone-link-proxy-test.apk`,
listening on 18080) so a run never costs the phone the proxies the daily build
has saved, and it requires the daily app's state line to be the same at the end.
It parks this checkout's build in the ambulance box, drops the laptop AP,
uninstalls the test app, requires `phone-doctor` to report `ap_address`,
`proxy_app` and `proxy_request`, runs `phone-doctor-fix --yes --required`, and
requires a clean doctor, the AP back up, the phone joined again and the app at
this tree's version. Nothing is downloaded: the repair installs the parked file,
and the harness requires it to be byte for byte the build — which is what keeps
the repair working when the removed proxy was the laptop's only uplink. It
refuses to start unless the adb route survives the AP drop (a cable, or a
transport that is not on the AP's subnet), so a run cannot cut its own link to
the phone. The fixer brings the AP and the phone's link up before it starts the
proxy, because the app only listens on the network the phone joined, and
reinstalls and reconfigures the app on exit if the repair failed.

```sh
sudo tests/live/doctor-fix-proxy.sh
```

`tests/live/proxy-app.sh` exercises the app in `android/` end to end on a phone
that has a Wi-Fi client link: it unlocks the phone when `sudo -n` can run
`bin/phone-unlock`, installs the APK, opens the panel and requires its list of
saved proxies with the `New proxy` button, saves a configuration over adb and
requires its card to open that proxy and to show the `auto_start` it was saved
with, takes the battery exemption away and requires the header's warning mark
to appear and open the battery request, requires the panel's
wireless-debugging line to be one of its known states, starts the listener on a
spare port with throwaway credentials, requires `200` through the tunnel,
requires a wrong password to be refused, requires the open proxy's "Listen
without authentication" checkbox to drop the password on Start and unticking
it to demand one again, requires an unrelated SSID to keep the port closed
while the service stays up, requires `any_network=true` to bypass the
predicate, requires `dumpsys` and the list to show a configuration saved over
adb, starts it again by name (the two service switches come back with it),
requires an unknown name to start nothing, removes it again with
`DELETE_PROFILE`, opens a card, changes its port, requires the plain `Save` to
write the form (a toggled auto-start switch included) into that proxy, requires
a card's own button to start and stop its proxy and to say so, requires
`Rename` in the menu and `RENAME_PROFILE` over adb to move a proxy to a new
name, requires the info marks and `About this app` to open their dialogs,
requires that proxy's own log to show this run's counters, its events and their
port and `Clear` to empty them, stops it, then
starts and stops it again from the Quick Settings tile (skipped when the phone stays locked, since the shade
ignores clicks there) and uninstalls. It leaves the vendored proxy alone
(`KEEP_APP=1` keeps the new app installed, `PROXY_APP_PORT` picks another port).

Every run records the evidence a failure needs: `result-live/<timestamp>/`
holds the phone's screen as `screen.mp4` for the length of the run and the
screen as XML for every change the capture service recorded (`ui-index.csv`
says when each was taken and what caused it);
`tests/live/frames.sh result-live/<timestamp>/screen.mp4 0:42` turns any moment
of the recording into a still. The recorder puts the MP4 index (`moov`) at the
end, so the file it leaves cannot be played or seeked until the recorder has
closed it — and a run cut short leaves no index at all. `tests/live/remux.sh`
(which a run calls before it exits) does one copy pass with no decode to move
the index to the front, and checks the first bytes instead of trusting the
tool; `PHONE_LIVE_REMUX=0` keeps the raw file. Measured on the longest
recording here: 143 MB and 379 s remuxed in 0.7 s, same duration, and the
clock fit still passes. A live H.264 pipe from `screenrecord` would be
readable while it is written, but raw H.264 carries no frame times, and the
clock mapping needs them: the file is finished at the end rather than read
live.

A failed check leaves the frames that explain it, next to the run's XML:
`tests/live/pictures.py` plans them from the step's start, the moment the check
was decided and the step's end, plus one just before every action the harness
took and one just after every change the capture service recorded, and pulls
them out of `screen.mp4` through `clock.txt`, named after what they show
(`frame-<check>-<offset>.png`). The run says how many it pulled as a check of
its own. It costs one decode pass over the failed step's part of the video —
`PHONE_LIVE_FRAME_BEFORE`/`PHONE_LIVE_FRAME_AFTER` move the two gaps — and a
green run pays nothing. Measured on an artificial 16 s step with 54 frames out
of the 379 s recording: 94 s; real steps are seconds and cost seconds.

One row per step is appended to
`result-live/timings.csv` with its seconds and its pass/fail counts, and the
file is never rewritten, so a run's cost can be compared across runs.
`PHONE_LIVE_CAPTURE=0` runs without the recording and the snapshots.

### Asking the history a question

The CSVs are the record and stay canonical — a run writes them as it goes and
needs no database to start. `tests/live/results.py` reads them once into
`result-live/results.sqlite3` (one file, no daemon, readable by `sqlite3`
without this project), so the questions a flat file makes awkward are one
query: what a step's median is for each kind of run, whether a check failed
before, which steps got slower after a change, what a full run costs on this
phone against that one.

```sh
tests/live/results.py              # fills result-live/results.sqlite3
sqlite3 result-live/results.sqlite3 \
  'select name, count(*), round(avg(seconds), 1) from steps group by name order by 3 desc'
```

It is one-way and repeatable: the CSVs are never written, importing a run again
replaces its rows, and a schema change costs a re-import rather than the
history. Three tables — `runs` (kind, the steps a filtered run asked for,
started, seconds, passes, failures, device, app build, capture, and every other
setting the run read as JSON), `steps` (run, name, position, seconds,
pass/fail) and `checks` (run, step, verdict, claim, file, line, function, the
instant the laptop decided it). A run writes those settings to `run.csv` in
its own folder before the first step and again at the end; a run from before
that file existed still imports, with what its timing rows say.

What the phone did is stamped with the phone's own clock, so an action and the
screen it changed sit on one timeline: `actions.csv` holds every tap and swipe
with the instant the phone took it, `input.csv` the typing, which has to go
through `input` and carries the interval its instant is inside, and
`ui-index.csv` a time for every capture. That timeline is tied to the
recording by the flashes — the service paints the screen magenta at instants it
writes down, at the start and the end of a run, and `tests/live/clock.sh` finds
them in `screen.mp4` and fits a line through the pairs into `clock.txt`:

    video_seconds = offset_s + drift * (device_ns - ref_ns) / 1e9

The screen only changes 60 times a second, so one flash can be placed to half a
frame, about 8 ms; 16 of them fit to 4.5 ms in the run that added this, across
the 308 s between the two bursts, drift included — 43 ppm over that long would
be 13 ms at the end of a run, which is why the slope is part of the answer.
The run fails if the fit is worse than 10 ms. The recording's start is not
written anywhere, which is why it is measured rather than assumed.

The steps themselves wait on the phone rather than on the clock: after a tap the
harness asks the service to answer once the screen has stopped changing, and
where a step knows what it caused — a dialog, a menu item, a card that should
say `Running` — it waits for exactly that, so a quick phone is not made to wait
for a second and a busy one is not failed by it. The same run that first used
this took 324 s against 377 s of fixed sleeps, and the steps that wait for a
dialog gained the most (the info marks, `Save` and `new proxy` steps each lost
5–11 s).

A step that is a known straight line goes to the phone in one message: filling
a form and pressing its button used to be a broadcast per tap, per key and per
wait — a tenth of a second of adb each — and is now one script the service runs
on a thread of its own, answering with the instruction that stopped it. With
those in place the run is 264 s, the whole new-proxy dialog (open, type, press,
land on the page) is 0.9 s, and `rename`, `info marks` and `new proxy` lost
another 3–8 s each. What the host decides — whether the port serves, whether
dumpsys lists the profile — stays a step; the phone only does what it can see
on its own screen.

```sh
tests/live/proxy-app.sh
```

It is not named `*.test.sh`, so `nix flake check` never runs it; it needs the
phone and root (for the secrets), and it deletes the app's data.

The `module` check evaluates a NixOS configuration with non-default options, so
it catches option or unit regressions without building a system or a VM.

## The two modes

| | hotspot mode | AP mode |
|---|---|---|
| who runs the AP | the phone | the laptop (`phonelink`) |
| laptop uplink | phone's SOCKS proxy at `10.244.108.165:1080` | phone's SOCKS proxy at `192.168.77.232:1080` |
| phone Wi-Fi client | **off** (`cmd wifi status`: "Wifi is disabled") | on, joined to `PhoneLink` |
| adb over Wi-Fi | works until the phone reboots, then needs `adb tcpip` over USB | `phone-adb-wifi` re-enables wireless debugging and reconnects without a cable |

Android cannot be hotspot and Wi-Fi client at once, and wireless debugging needs
a Wi-Fi client link, which AP mode provides. There `phone-adb-wifi` enables it by
writing `adb_wifi_enabled`, so the Settings toggle is not needed once adb is
reachable. The legacy `5555` listener does not survive a reboot. For hotspot mode
set `phoneLink.proxyHost = "10.244.108.165"`.

Either way the port is new after every reboot, so no adb call relies on the one
it used a moment ago: `lib/python/phone_link/adb.py` leaves a working target
alone, and when a network serial is gone it reads the phone's
`_adb-tls-connect._tcp` record (`avahi-browse -rtp`, about a second), connects to
the advertised port and runs the command again there. Resolving the serial in
the first place goes through the same lookup, so a rebooted phone is found
instead of reported missing. `PHONE_ADB_MDNS=0` disables the lookup for a
machine whose mDNS cannot be trusted.

There has to be something to find, though: this phone clears wireless debugging
on some reboots, and while it is off nothing advertises a port at all. The proxy
app closes that gap itself — rejoining `PhoneLink` makes it write
`adb_wifi_enabled` back to `1`, the same write `phone-adb-wifi` makes over adb,
controlled by the panel checkbox "Turn wireless debugging back on when the phone
joins the SSID" (extra `adb_wifi`, on by default). That write is a secure
setting, so `phone-proxy-install` grants the app
`android.permission.WRITE_SECURE_SETTINGS` after installing its own APK; a build
installed by other means only logs that it cannot help, and
`phone-adb-wifi` remains the override.

## One-time setup

The AP profile needs the Wi-Fi PSK, so it is built from the same root-only
secrets file as the PIN and never enters the Nix store. With the module, set
`phoneLink.ap.enable = true` and keep `PHONE_AP_PASS` in that file:

```sh
install -m600 /dev/null /etc/nixos/phone-socks-secrets
printf 'PHONE_SOCKS_PASS=%s\nPHONE_PIN=%s\nPHONE_AP_PASS=%s\n' \
  '<proxy password>' '<phone PIN>' '<Wi-Fi PSK>' \
  | sudo tee /etc/nixos/phone-socks-secrets

sudo nixos-rebuild switch   # writes /run/.../phonelink.nmconnection from the secret
sudo phone-ap-up            # activates the AP
```

The generated profile lives in `/run/NetworkManager/system-connections/`; the
store only holds the `$PHONE_AP_PASS` placeholder. `phone-ap-create --refresh`
reloads it after rotating the PSK by restarting
`NetworkManager-ensure-profiles`, rather than editing NetworkManager's copy.

Without the module, `sudo phone-ap-create` still creates a persistent profile
in `/etc/NetworkManager/system-connections/`, and `--refresh` rewrites it.

If you previously created the profile with `phone-ap-create`, no manual step is
needed: the ensure unit removes the persistent `/etc` copy before writing the
declarative one, so only one profile with that name remains. The running AP
drops with the old profile, so run `sudo phone-ap-up` after the switch.

## Uninstall

Unwiring the module removes the units, firewall holes and installed scripts,
but NixOS has no uninstall hook for runtime state. Remove `phoneLink` (and the
package, if you added it) from `configuration.nix`, switch, then run the
uninstaller from the checkout — the installed scripts are gone by then:

```sh
sudo nixos-rebuild switch
sudo ./bin/phone-link-uninstall --yes
```

It stops any tunnel units still running, deletes the `phonelink` profile from
NetworkManager and from `/etc`/`/run`, and clears `/var/cache/phone-link` and
the invoking user's `~/.cache/phone-link`. It keeps
`/etc/nixos/phone-socks-secrets` and the phone's state, and prints the commands
to remove those (`phone-wifi-forget PhoneLink`, `phone-proxy-uninstall`). Use
`--check` to preview and `--keep-cache` to keep the APKs. A reboot is a simpler
alternative for the profile, but it will not clear the caches or the secrets
file.

The app in `android/` is the default one now: `phone-proxy-install` installs
this checkout's build, and the `phone-proxy-*` scripts talk to it over its own
adb interface — `start-foreground-service` with `org.phonelink.proxy.action.START`
or `STOP` and the configuration as extras, and `dumpsys activity service` for
what it is doing — so a start needs no screen, keyguard or taps. The vendored
F-Droid app still works with `PHONE_PROXY_PKG=com.tokyoxpa3.androidproxy`, and
its uninstall and data-clear are the same commands.

The app's APK is built from this tree, and a tagged release carries it: a `v*`
tag builds `android/build.sh` in CI, signs with the release key from the
repository's secrets and attaches `phone-link-proxy-<version>.apk` (with its
`.sha256`) to the release — `android/README.md` has the four secrets that needs.
`phone-proxy-install --release` installs it without leaving the checkout:

```sh
phone-proxy-install --release              # the latest release's APK
phone-proxy-install --release v0.5.0       # a particular tag
phone-proxy-install --release --replace-signer
```

That last one is for a phone whose app was built locally: the debug key is a
different signature, so adb refuses to update in place and the app has to go
first — which clears its saved proxies. There is nothing to fetch otherwise.
For a phone that still runs the vendored F-Droid app, that app is on F-Droid and
the script can use it as an update channel:

```sh
phone-proxy-install --fdroid            # download the suggested version, install
phone-proxy-install --fdroid --check    # download only, cache it, install nothing
```

Downloads are cached under `$PHONE_APK_DIR` (default
`$XDG_CACHE_HOME/phone-link`, i.e. `~/.cache/phone-link`) and named after the
version, so a repeat run installs from the cache. Without F-Droid access, back
the app up from a phone that has it and install from the copy:

```sh
phone-proxy-install --pull ~/dev/phone-link/apk
phone-proxy-install ~/dev/phone-link/apk/*.apk
```

`--pull` names a single-APK backup `com.tokyoxpa3.androidproxy-<version>.apk`;
installs use `adb install -r -g`, so updating keeps the app's settings.

Requirements: `NetworkManager` on `wpa_supplicant` (iwd cannot do AP mode),
`net.ipv4.ip_forward = 1`, and the phone's proxy listening on the reachable
address.
