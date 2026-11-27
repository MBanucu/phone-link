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
- `devShells.default`, `formatter`, `checks`
- the proxy app itself is not here any more: it is
  [`MBanucu/phone-link-proxy`](https://github.com/MBanucu/phone-link-proxy),
  with its own flake, tests, release workflow and store metadata, and
  `phone-proxy-install` fetches its releases
- `CHANGELOG.md` — released changes, Keep a Changelog format
- `docs/phone-network.md` — measured behaviour, evidence and the traps

## Install the module

```nix
# flake.nix
{
  inputs.phone-link.url = "github:MBanucu/phone-link/v0.12.1";

  outputs = { self, nixpkgs, phone-link, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [
        phone-link.nixosModules.default
        {
          environment.systemPackages = [
            phone-link.packages.${pkgs.system}.phone-link
          ];

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
bare `github:MBanucu/phone-link` to track `main`. A tag is part of the input
URL, so `nix flake update phone-link` alone keeps the same tag: change the tag
in `flake.nix` first, then run `nix flake update phone-link` to refresh
`flake.lock`. The module declares the tunnel and the AP but installs no
packages, so without the `environment.systemPackages` line above there is no
`phone-ap-up`, `phone-doctor` or `phone-proxy-*` on the machine.

The module never starts the tunnel at boot. A 5 s timer probes the proxy port and
keeps `phone-tun.service` running only while it answers, so a missing phone or a
stopped proxy app cannot blackhole traffic.

### Options

| option | default | meaning |
|---|---|---|
| `phoneLink.enable` | `false` | enable the tunnel, timer and AP firewall holes |
| `phoneLink.apInterface` | `wlp110s0` | interface of the laptop access point |
| `phoneLink.ap.enable` | `false` | declare the AP profile from `PHONE_AP_PASS` (requires `phoneLink.enable`) |
| `phoneLink.ap.autoconnect` | `false` | let NetworkManager activate the AP at boot (reserves the radio; a failed 5 GHz activation leaves no link) |
| `phoneLink.ap.rejoin` | `true` | re-assert the phone's association over USB adb after an AP restart (30 s timer, 5 min throttle; requires `ap.enable`) |
| `phoneLink.ap.name` | `phonelink` | NetworkManager connection name |
| `phoneLink.ap.ssid` | `PhoneLink` | SSID of the laptop access point |
| `phoneLink.ap.band` / `channel` / `channelWidth` | `a` / `149` / `80` | 802.11 band, channel and AP channel width (5 GHz, non-DFS) |
| `phoneLink.ap.address` | `192.168.77.1/24` | IPv4 address of the AP interface |
| `phoneLink.ap.dhcpRange` | `.10–.254` of the AP /24, 3600 s | DHCP range and lease time; the AP sends no router or DNS option |
| `phoneLink.proxyHost` | `192.168.77.232` | primary address of the phone's SOCKS proxy |
| `phoneLink.proxyHosts` | `[]` | additional addresses tried in order after `proxyHost`, e.g. the USB tether |
| `phoneLink.proxyPort` | `1080` | default SOCKS port; the port in use is `/run/phone-link/proxy-port` |
| `phoneLink.proxyUser` | `proxy` | SOCKS username |
| `phoneLink.secretsFile` | `/etc/nixos/phone-socks-secrets` | file with `PHONE_SOCKS_PASS=…` (and `PHONE_AP_PASS=…` with `ap.enable`) |
| `phoneLink.interfaceName` | `phone-tun` | TUN device name |
| `phoneLink.tunAddress` | `172.19.0.1/30` | TUN address |
| `phoneLink.logLevel` | `warn` | sing-box log level |
| `phoneLink.cacheProxyApk` | `true` | stock the ambulance kit during activation: the APKs of the newest app releases, so every install/update leaves versions a repair can fall back on |
| `phoneLink.manageResolver` | `true` | pin `/etc/resolv.conf` to `1.1.1.1`/`9.9.9.9` |
| `phoneLink.openApFirewall` | `true` | allow DHCP from AP clients; the AP serves no DNS (the phone resolves over LTE) |
| `phoneLink.enableRelay` | `false` | run the local SOCKS/HTTP relay (`gost`) |
| `phoneLink.relaySocksPort` / `relayHttpPort` | `1081` / `1082` | relay ports |

The AP is a link, not an uplink and not an internet-sharing hotspot.
`ap.enable` keeps the `192.168.77.0/24`
address and DHCP, so the phone's reservation, the proxy at
`192.168.77.232`, adb and sshfs keep working, but the profile uses
NetworkManager's `manual` method. A separate dnsmasq answers DHCP without a
router or DNS option, and forwarded packets entering the AP interface are
dropped in a dedicated nftables table. The phone therefore has no internet path
through the laptop: Android should fail validation on the AP and keep mobile
data as its default network, instead of looping every byte over the AP link
twice. The laptop→`192.168.77.232` direction is output, not forwarding, so the
tunnel still reaches the proxy.

That design does not keep this phone associated for long. The phone drops the
DHCP-only AP after roughly 34 s in the 2026-11-26 runs (94 s when a router
option was advertised), and the proxy listener closes with the link; #11 tracks
the cause and the pending 30-minute screen-off acceptance. USB tethering is the
practical unattended fallback until it is fixed. The short #4 run only showed
that the forwarding loop was gone; it finished before the drop.

The AP defaults to 5 GHz channel 149 at 80 MHz. 149 is non-DFS and one of the
channels this Intel 8265 allows for an AP; its self-managed (LAR) regulatory
domain marks 36/44 `no IR`. `channelWidth = 0` lets NetworkManager choose the
width (NetworkManager 1.50+ supports the setting; 2.4 GHz is capped at 40 MHz).
The hand-made profile from `phone-ap-create` uses the same band, channel and
width.

Set `phoneLink.ap.autoconnect = true` to bring the AP back after a reboot
without running `phone-ap-up`. It lets NetworkManager activate the profile at
boot, which reserves the radio for the AP; if the 5 GHz activation fails, there
is no link at all (#7). It does not fix a phone that drops the link while
associated — that is the phone-side cause in #11 — and it does not add the
2.4 GHz fallback (#7).

### Rejoining the AP after a restart

Android validates this link-only AP as "no internet" and, after a few reports,
turns auto-join off for the saved network (`NETWORK_SELECTION_TEMPORARY_DISABLED`,
reason `NETWORK_SELECTION_DISABLED_NO_INTERNET_TEMPORARY`). The AP can then be up
with no station and the phone will not return on its own (#33).

With `ap.enable = true`, `phone-link-ap-rejoin.timer` checks every 30 s. It acts
only when the AP interface is up, `iw dev <iface> station dump` has no station,
and `adb -d` sees the USB device; then it runs
`cmd wifi connect-network <ssid> wpa2 $PHONE_AP_PASS` over USB and waits up to
30 s for the station. If that does not bring the phone back it falls back to
`svc wifi disable`/`enable`. Attempts are throttled to one per five minutes
(`/run/phone-link/ap-rejoin.last`), so a phone that ignores the command is not
hammered. The service exits non-zero when the phone is away; that is normal and
does not fail the boot.

Do not make the AP answer Android's connectivity probe. It has to stay
unvalidated so the phone keeps using cellular; the watchdog re-asserts the
association from the laptop instead.

The watchdog needs USB adb, because the Wi-Fi adb transport is gone exactly when
this is needed. Without USB the phone must be rejoined by hand
(`phone-wifi-connect PhoneLink`). Set `phoneLink.ap.rejoin = false` to disable
the timer.

The port is the one setting that is not a rebuild: `phoneLink.proxyPort` is
the default, and `phone-proxy-switch` (or the panel's **Proxy port** page)
writes the port the phone is actually listening on to
`/run/phone-link/proxy-port`. `phone-tun`'s `ExecStartPre`, the 5 s probe, the
relay and every script read that file, so switching takes effect at the next
start of those units — nothing in the store changes, and the timer keeps
working. It lives in `/run`, so a reboot is back to `phoneLink.proxyPort`; the
phone's auto-start may bring up another saved proxy at another port, which the
doctor reports until you switch again. `PHONE_RUNTIME_PORT_FILE` moves the file
for a test, and `PHONE_PROXY_PORT` overrides both for a one-off run.

### The configuration the module shares

The module writes the non-secret `phoneLink` values to `/etc/phone-link/env`:
the AP interface, name, SSID and address, the proxy host(s), port and user,
the secrets path, the runtime port file, and the `nft` binary the AP's
no-forward unit runs. The commands, the doctor and
`lib/phone-net.sh` read it, so a non-default deployment needs no repeated
`PHONE_*` exports, while an environment variable still wins for a one-off run.
`PHONE_CONFIG_FILE` points the readers at another file in a test. The port file
is written from `phoneLink.proxyPort` when tmpfiles runs, so the value the
doctor sees after a boot is the module's own rather than an older run's.

### One adb serial

The live phone can have two transports at once — USB and a Wi-Fi address — and
a bare `adb` then refuses to choose or picks the wrong one. Every command
resolves one serial: `PHONE_SERIAL` when it is set, otherwise the attached
phone. When more than one transport is attached, they are grouped by hardware
identity (`ro.serialno`, or the product/model/device descriptor from
`adb devices -l` when the property is empty). One phone reachable twice is
therefore not ambiguous: its USB transport wins because it survives a reboot;
between network transports the address in `PHONE_PROXY_HOST`/`PHONE_AP_IP`
wins, then the first sorted serial. Only two genuinely different phones stop
the command and list the devices, and `PHONE_SERIAL` still overrides both.
All device calls are pinned to that serial, including `adb reverse` and the
repair paths in `phone-fix-internet`; values with spaces are quoted for the
remote shell. `PHONE_SERIAL` is what makes a destructive command safe when two
different phones are up.

### USB-primary and host fallback

The address is also runtime state. `phoneLink.proxyHost` is the primary address
and `phoneLink.proxyHosts` lists fallbacks tried in order after it. Every 5 s,
`phone-tun-toggle` opens a TCP connection to each effective host (`proxyHost`,
then `proxyHosts`, with duplicates removed) and records the first that answers in
`/run/phone-link/proxy-host`; `phone-tun`'s generated config reads that file, so
the tunnel follows the path that is actually up without a rebuild. When the host
the running tunnel dials is not the one the probe chose, the toggle restarts
`phone-tun.service`, because only a restart reruns the config generator in
`ExecStartPre`; `systemctl start` on a running unit leaves sing-box on the old
address. A change is confirmed by the next tick before the restart, so one
failed probe does not cost a reconnect and a flapping probe cannot restart in a
loop — a real failover lands within two ticks, about 10 s. When no host answers
the tunnel is stopped, as before. With `proxyHosts = []` the probe tries only
`phoneLink.proxyHost`, exactly as it used to.

To prefer USB tethering and fall back to the access point:

```nix
phoneLink = {
  enable = true;
  proxyHost = "10.23.190.38";        # USB tether, tried first
  proxyHosts = [ "192.168.77.232" ]; # AP address when the cable is out
};
```

Swap the two values to keep the AP primary and use USB only as a fallback. The
tether address is assigned per connection, so put the address the phone
currently shows in `proxyHost`/`proxyHosts`; the runtime host file is what
saves a rebuild when only the reachable path changes. The relay reads the same
file and falls back to `phoneLink.proxyHost` when it is absent.

`proxyHosts` only chooses among addresses the phone answers on. The app still
gates its listener on the configured SSID, so a USB address does not help while
the phone is off `PhoneLink`: the app has no listener and the tunnel has
nothing to reach. USB-primary therefore needs either the phone also joined to
`PhoneLink`, or the app started with `any_network` (the panel's **Ignore the
SSID**), which the app documents as a test/escape hatch. Without one of those,
`proxyHosts` alone is not a USB fallback.

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
| `phone-doctor` | check every runtime condition of the setup (forwarding, AP profile/address, adb, phone link, secrets, proxy, the port the laptop uses against the phone's listeners, tunnel, tether, internet), the APK a repair would install, the version the installed app reports and the phone SDK, and whether the source checkout is newer than the installed flake lock; exit non-zero if a required one is unmet; the adb check reconnects a phone whose wireless-debugging port changed by reading its `_adb-tls-connect._tcp` mDNS record, and reports the pinned port first when the phone answers there; it reports the two Wi-Fi reconnect globals as an optional line and names `phone-wifi-connect PhoneLink` when the AP is on air with no station; `--analyze` prints one `fail`/`warn` line with a stable problem id for scripts |
| `phone-doctor-fix` | list the fixes for the problems `phone-doctor --analyze` reports, run one dedicated script per problem in dependency order, then re-check (`--yes` skips the prompt, `--dry-run` only lists, `--required` leaves warnings alone, `--which-doctor` prints the `phone-doctor` it reads — the one beside the checkout unless `PHONE_DOCTOR` says otherwise; run with `sudo`) |
| `phone-fix-apk` | stock the ambulance box: copy the app APK the cache or `PHONE_PROXY_APK` names into `/var/cache/phone-link` so a repair on a machine without a download can still reinstall the app; `--releases [N]` also keeps the APKs of the newest N releases (5 by default) as a repair kit of several versions, each checked against its `.sha256` and named after its tag, older ones pruned past three times N (`--refresh` replaces the copy and refreshes the kit, `--check` lists the box) |
| `phone-fix-forwarding` | set `net.ipv4.ip_forward=1` for the running kernel (`--check` reports only) |
| `phone-fix-internet` | restore internet for the APK download/check by trying mobile data, USB tethering, then the phone hotspot with the laptop as a client, verifying HTTPS after each (`--check` reports only) |
| `phone-fix-mobile-data` | enable the phone's mobile data and wait for a default route (`--check` reports only) |
| `phone-fix-tunnel` | start `phone-tun`, or restart it when its route is missing, and wait for the route (`--check` reports only) |
| `phone-proxy-check` | request through the proxy on the hotspot and AP addresses (needs root for the secret) |
| `phone-proxy-install` | install/update the proxy app — with no argument the newest signed release of `MBanucu/phone-link-proxy` (`PHONE_PROXY_REPO` overrides), checksum checked, unless an APK is named; `--release [TAG]` takes a named release instead, `--build` names the app's repository and refuses (this checkout no longer builds it), `--fdroid` fetches the legacy vendored app instead, `--replace-signer` uninstalls a differently signed copy first (which clears its data), `--pull` copies the installed APK off the phone, `--status` reports the version; for `org.phonelink.proxy` it also grants `WRITE_SECURE_SETTINGS` and the battery allowlist, so the app can turn wireless debugging back on itself |
| `phone-proxy-uninstall` | remove the proxy app (`--check` previews, `--keep-data` keeps app data, `--yes` skips the prompt) |
| `phone-proxy-data-clear` | wipe the proxy app's data, back to port 1080 with no auth (`--check` previews, `--yes` skips the prompt) |
| `phone-proxy-battery-whitelist` | add the proxy app to the device-idle (Doze) whitelist so the proxy is not killed with the screen off (`--check` only reports) |
| `phone-proxy-boot` | make the proxy app come back after a reboot: add it to the device-idle allowlist, grant the location permissions the SSID read and boot start need, and turn `auto_start` on; the service itself is `specialUse`, not a `location` one (`--check` reports which of the three is missing) |
| `phone-proxy-setup` | the first-run path: start the proxy through the app's own intent with the port, credentials and auto-start as extras, then verify a request through the listener; `--max-connections N` also sends the SOCKS connection ceiling (16..1024, left out the app keeps its saved value — 256 on a fresh install), and `--check` reports the settings, including the ceiling when the app prints it, and checks the request |
| `phone-proxy-switch` | make the laptop use a port the phone listens on: `--profile NAME` starts that saved proxy when it is not running and `--port N` requires the phone to be listening there, a request through the new port has to answer 200 before the laptop changes, then the port is written to `/run/phone-link/proxy-port`, `phone-tun` and the relay are restarted if they were running, and the phone's listener on the old port is stopped last (`--check` compares the two ports, `--list` prints the phone's saved proxies and listeners as JSON for the panel) |
| `phone-proxy-start` | start the proxy through the app's own intent and wait until the service says it is listening (`--check` only reports; a fresh install with no saved proxy says to run `phone-proxy-setup` instead of sending a bare START) |
| `phone-proxy-stop` | stop the proxy through the app's own intent and wait until the service is gone (`--check` only reports) |
| `net-check` | fetch a fresh URL with curl, Chrome and Nix, reporting which of the three reach the internet |
| `phone-reboot-unlock` | reboot the phone, wait for boot, then unlock once (`--yes` skips the prompt) |
| `phone-tether-cycle` | switch USB to MTP so `net-check` runs with RNDIS off, then lock and unlock the phone to restore the tether, verify it and report (`--yes` skips the prompt; needs the PIN, so run with `sudo`) |
| `phone-usb-tether-check` | report whether USB tethering is active and whether the internet answers over the host's tether route |
| `phone-usb-tether-default` | make USB tethering the default USB action, keeping adb (`--check` reports only) |
| `phone-wifi-connect` | join PhoneLink (or another SSID) with WPA2 and wait for the association (`--check` reports) |
| `phone-wifi-reconnect` | apply the two Android globals that let the phone rejoin after a long AP outage (`network_avoid_bad_wifi=0`, `wifi_always_requested=1`); `--check` only reports and exits 0 when both match |
| `phone-wifi-enable` | turn the phone's Wi-Fi radio on (`--check` reports) |
| `phone-wifi-forget` | forget a saved network, default PhoneLink (`--check`, `--yes`) |
| `phone-wifi-concurrency` | report whether Wi-Fi client and hotspot can run together (STA+AP), read-only; exit 2 if the phone does not say |
| `phone-unlock` | unlock the lock screen with `PHONE_PIN` from the secrets file (`--check` only reports locked/unlocked) |
| `phone-ap-create` | create the `phonelink` AP profile on 5 GHz channel 149 at 80 MHz from the root-only `PHONE_AP_PASS` secret (`--refresh` rewrites it after a PSK change, `--check` reports) |
| `phone-ap-delete` | delete the `phonelink` AP profile from NetworkManager, bringing it down first if active (`--check` reports, `--yes` skips the prompt; a declared profile returns at the next boot) |
| `phone-ap-up` | preflight the radio, then `nmcli connection up phonelink` |
| `phone-ap-down` | drop the AP and rejoin the phone's hotspot |
| `phone-link-uninstall` | remove the AP profile and APK caches after unwiring the module (`--check`, `--yes`, `--keep-cache`); straight from the checkout |
| `adb-wifi-connect` | connect adb to the phone over TCP |
| `adb-wifi-connect --prepare` | once over USB: `adb tcpip 5555` (the tether blips) |
| `phone-adb-wifi` | enable adb over Wi-Fi on the phone: legacy `adb tcpip 5555` and Android 11+ wireless debugging on its random TLS port, then connect (`--legacy`, `--tls`, `--check`) |
| `phone-tunnel-run` | run the built tunnel config in the foreground |
| `phone-tunnel-run --via-adb` | same, with the upstream reached through `adb reverse` |

After a long AP outage Android does not always rejoin on its own. The doctor
reports the two reconnect globals as an informational line and prints the
recovery command when the AP is on air with no station:
`phone-wifi-connect PhoneLink` (the same 3 s `cmd wifi connect-network` path).
`phone-wifi-reconnect` is the explicit action that writes
`network_avoid_bad_wifi=0` and `wifi_always_requested=1`; nothing changes the
globals unless it is run.

`phone-doctor` is a Python package under `lib/python/phone_doctor`, with one
module per symptom group (`flake`, `host`, `phone`, `secrets`, `proxy`,
`tunnel`, `tether`, `internet`, `adb_wifi`); `bin/phone-doctor` only resolves it.
The app checks read the service's `dumpsys` while it runs, and the app's own
`files/state.txt` when it does not: a stopped service prints nothing, which is
exactly the state a broken phone is in, and `auto_start` is the fact the boot
check needs.
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
nix run github:MBanucu/phone-link/v0.12.1#gui  # straight from the tag
nix build .#phone-link-gui                    # or build it and run the binary
```

The module itself installs no packages: the install snippet above adds the
scripts, and this adds the panel with its desktop entry and icon:

```nix
environment.systemPackages = [ phone-link.packages.${pkgs.system}.phone-link-gui ];
```

Every action has its `--check` preview plus its variants (F-Droid install,
tunnel through `adb reverse`, legacy adb port, keep-cache uninstall, …) in the
row's menu, and the output streams into a log window exactly as the script
printed it, exit status included. The header searches every action by name or
summary (Ctrl+F), the sidebar badges the number of failing checks, and Ctrl+R
re-checks the setup. The **Proxy port** page is the one thing a row cannot
say: it reads the phone's saved proxies and the ports it is listening on, and
choosing one runs `phone-proxy-switch` — with the phone asked first and the
laptop following only once the new port answers. A saved proxy whose user the
laptop has no password for is listed with the reason and cannot be chosen. Failing and warning checks that have a repair carry
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
| `shellcheck` | every script and `lib/*.sh` is clean at shellcheck warning level |
| `format` | `flake.nix` and `modules/phone-link.nix` are nixfmt-clean |
| `module` | the module generates the expected sing-box config and units (5 s probe, 20 s first run, AP DHCP hole, a DHCP-only AP with no router/DNS option, an nftables forward drop that also works with the firewall off, an opt-in AP autoconnect that leaves the profile link-only, an opt-in rejoin watchdog, pinned resolver, never started at boot) and defines nothing when disabled |
| `script` | hermetic tests with stub `adb`/`curl`/`avahi-browse`: for `phone-proxy-install` the F-Droid version selection, cache keying and reuse, `--check` staying read-only, the exact install argv and `--pull` naming; for `phone-proxy-uninstall` the confirm/`--yes` guard, `--keep-data`, idempotence and the exact uninstall argv; for `phone-proxy-data-clear` the prompt guard, `--check` staying read-only and the `pm clear` argv; for `phone-proxy-setup` the START intent's extras, the `--max-connections` extra and its 16..1024 refusals, the verification request, the settings `--check` against a stub service dump (including an old app's missing ceiling line); for `phone-proxy-switch` a listening port and a saved proxy started by name, the closed port and the proxy whose user the laptop has no password for refused, the failed start and the refused password rolled back, the request answered before the tunnel restart and the old port dropped only after it, and `--check`/`--list` staying read-only; for `phone-unlock` the keyguard check, PIN entry and wrong-PIN failure; for `phone-proxy-battery-whitelist` the idempotent add, `--check` and the device-idle argv; for `phone-proxy-start`/`phone-proxy-stop` the START/STOP intents, the dumped state, the already-running/stopped no-op, the gated start and the proxy that will not stop; for `phone-wifi-concurrency` the supported, unsupported and inconclusive verdicts and the read-only queries; for `phone-usb-tether-check` the rndis0/usb state, the host route and a source-bound request; for `net-check` the three fetches, their failure modes and the cache-busting URL; for `phone-reboot-unlock` the reboot/wait/unlock sequence, the slow-boot wait, the aborted prompt and the boot timeout; for `phone-usb-tether-default` the current and screen-unlocked functions, the `--check` report and an ineffective setter; for `phone-wifi-enable` the idempotent enable and `--check`; for `phone-wifi-forget` the saved-network table, the prompt/`--yes` guard and idempotence; for `phone-wifi-connect` the password sources, remote quoting of SSID/passphrase and the association wait; for `phone-wifi-reconnect` the matching and mismatching `--check` report, both writes and the idempotent re-read; for `phone-tether-cycle` the MTP disable, the health check, the lock/unlock restore, an adb abort retry, the already-off case, an unhealthy restore and the prompt guard; for `phone-adb-wifi` the legacy/TLS split, the mDNS port lookup, the `adb_wifi_enabled` write, the already-on case and the missing-port failure; for `phone-doctor` the ready, hotspot, locked, missing-adb, missing-secrets and dead-proxy paths, the app that is off the battery allowlist or has `auto_start` off (named separately in `[app]`), plus a rotated adb port found over mDNS; ; and `tests/phone-adb-mdns.test.sh` the stale network serial that is rewritten to the advertised port, the retry after a transport vanished mid-command, the serial recovered from the record when `adb devices` is empty, the preferred address when two phones are advertised and `PHONE_ADB_MDNS=0`; and for `--build` the refusal that names the app's repository and a bare install fetching the newest release; and `tests/phone-tun-toggle.test.sh` the primary chosen when both hosts answer, the fallback that restarts `phone-tun` after one confirming tick and lands in the generated config, the stable selection that never restarts, a one-tick flap that does not restart, and the stop when no host answers; and `tests/phone-ap-rejoin.test.sh` the down interface and the associated station that make no adb call, the missing USB device that writes no state, one successful `connect-network` with the right SSID and key management, the Wi-Fi disable/enable fallback, the throttle on an immediate second run, and a PSK that never reaches stdout or stderr |

The `script` check also covers `phone-doctor --analyze` (problem ids, AP down and
a missing APK, warnings-only, no headers or `ok` lines),
`phone-doctor-fix` (dry run, ordered application, an install from the cached
APK, the manual APK step, manual-only and failed-fix paths) and the fix scripts (ambulance APK, AP
profile creation from the secret, forwarding, mobile data, tunnel: apply,
no-op and read-only `--check`).

### Where the check's time goes

`nix build .#checks.x86_64-linux.script` times itself: `timings.csv` in the
output has a row per suite and, where a suite knows them, a row per part, and
the build log ends with the five slowest, so the question "which suite got
slower" is answered by the log that asked it. A store path cannot be compared with the
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
checks passing. `PHONE_PROXY_WAIT` and `PHONE_PROXY_SETTLE` are the same idea
for `phone-proxy-switch`: how long the app gets to put a listener on a port,
and the old one to go away.

### Live end-to-end test

`tests/live/doctor-fix-proxy.sh` breaks the setup on purpose and checks that the
doctor repairs it. It runs the app's **test build**
(`org.phonelink.proxy.test`, from a checkout of the app's repository built
once — `PHONE_PROXY_APP`, default `../phone-link-proxy` — listening on 18080) so
a run never costs the phone the proxies the daily build has saved, and it
requires the daily app's state line to be the same at the end.
It parks that build in the ambulance box, drops the laptop AP,
uninstalls the test app, requires `phone-doctor` to report `ap_address`,
`proxy_app` and `proxy_request`, runs `phone-doctor-fix --yes --required`, and
requires a clean doctor, the AP back up, the phone joined again, the installed
app's version reported, and the daily app listening on the port it had
*without* a command being run to start it — the phone rejoins the SSID on its own, and the
listener follows the network back. Nothing is downloaded: the repair installs
the parked file,
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

`tests/live/proxy-app.sh` — the app's own end-to-end run — lives in the app's
repository (`MBanucu/phone-link-proxy`, under `tests/live/`), together with the
phone plumbing it shares (`phone.sh`), the tools that read a run's evidence
(`frames.sh`, `clock.sh`, `pictures.py`, `remux.sh`) and the one that makes the
CSV history queryable (`results.py`). It installs the app's test build
(`org.phonelink.proxy.test`, port 18080), so a run never touches the proxy the
phone lives on, and `nix flake check` never runs it. That repository's README
has the steps, the claims they make and the measurements behind them.

The two live runs meet at the same phone: this repository's doctor test breaks
the setup and requires the repair, and the app's run requires the panel and the
adb contract. Neither is part of `nix flake check`.

The `module` check evaluates a NixOS configuration with non-default options, so
it catches option or unit regressions without building a system or a VM.

## The two modes

| | hotspot mode | AP mode |
|---|---|---|
| who runs the AP | the phone | the laptop (`phonelink`) |
| laptop uplink | phone's SOCKS proxy at `10.244.108.165:1080` | phone's SOCKS proxy at `192.168.77.232:1080` |
| phone Wi-Fi client | **off** (`cmd wifi status`: "Wifi is disabled") | on, joined to `PhoneLink` |
| adb over Wi-Fi | keeps its port only if the keeper app pins 5555, otherwise works until the phone reboots | `phone-adb-wifi` re-enables wireless debugging and reconnects without a cable |

Android cannot be hotspot and Wi-Fi client at once, and wireless debugging needs
a Wi-Fi client link, which AP mode provides. There `phone-adb-wifi` enables it by
writing `adb_wifi_enabled`, so the Settings toggle is not needed once adb is
reachable. The legacy `5555` listener does not survive a reboot. For hotspot mode
set `phoneLink.proxyHost = "10.244.108.165"`. `org.phonelink.proxy` is the AP-mode
app and pauses off `PhoneLink`; hotspot mode still uses the vendored app.

In AP mode the phone keeps mobile data as its default network while it is
associated: the AP is DHCP-only and drops forwarded traffic (see the options
above), so the link carries the laptop's tunnel to the proxy and the phone's own
internet does not cross it. The association drop in #11 is separate.

Both ends deal with the port being new after every reboot. The first thing
`lib/python/phone_link/adb.py` asks is the **pinned** port: the keeper app on
the phone (`MBanucu/wireless-adb-keeper`) has adbd listen on `PHONE_ADB_PORT`
(default `5555`) with the Termux adb it already has, so `192.168.77.232:5555`
answers the next boot too. Whenever a serial has to be resolved or retargeted,
that address is tried before anything else — one `adb connect` when it answers,
no browse, and a serial the next command can keep using. A phone without the
app answers nothing there, which costs one refused connect.

After that, no adb call relies on the port it used a moment ago:
`lib/python/phone_link/adb.py` leaves a working target alone, and when a
network serial is gone it reads the phone's `_adb-tls-connect._tcp` record
(`avahi-browse -rtp`, about a second), connects to the advertised port and runs
the command again there. Resolving the serial in the first place goes through
the same lookup, so a rebooted phone is found instead of reported missing.
`PHONE_ADB_MDNS=0` disables both the pinned probe and the lookup, for a
machine whose mDNS cannot be trusted.

There has to be something to find, though: this phone clears wireless debugging
on some reboots, and while it is off nothing advertises a port at all. The proxy
app closes that gap itself — rejoining `PhoneLink` makes it write
`adb_wifi_enabled` back to `1`, the same write `phone-adb-wifi` makes over adb,
controlled by the panel checkbox "Turn wireless debugging back on when the phone
joins the SSID" (extra `adb_wifi`, on by default). That write is a secure
setting, so `phone-proxy-install` grants the app
`android.permission.WRITE_SECURE_SETTINGS` after installing the app's APK; a build
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

The proxy is a signed release APK from `MBanucu/phone-link-proxy` (0.12.0 at
the time of writing), not a build of this checkout. Install it while the laptop
still has its current uplink — the link-only AP cannot fetch the APK by itself —
then run setup once the phone has joined `PhoneLink`:

```sh
phone-proxy-install        # while online: newest signed release
sudo phone-proxy-setup     # first run: port and credentials, verified 200
phone-proxy-boot           # allowlist, location grants, auto_start
```

`phone-proxy-setup` is the first-run path: it starts the proxy through the
app's own intent on the port the laptop is using, turns `auto_start` on, and
requires a request through the listener to answer 200. `--max-connections N`
sets how many SOCKS connections the listener may keep open at once (16..1024);
left out, the app keeps its saved value, which is 256 on a fresh install.
`--check` prints the ceiling the phone reports and only treats a different one
as a failure when `--max-connections` was given. `phone-proxy-boot` adds
the battery exemption and the fine/background location permissions that the
boot start and the SSID read need. The app's foreground service is
`specialUse`, not `location`: a `location` service type cannot start before the
first unlock and is not needed for the SSID read.

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

The default app is `org.phonelink.proxy`, installed from a signed release of
`MBanucu/phone-link-proxy` — current release 0.12.0 — and never built in this
checkout. The `phone-proxy-*` scripts talk to it over its own adb interface —
`start-foreground-service` with `org.phonelink.proxy.action.START` or `STOP`
and the configuration as extras, and `dumpsys activity service` for what it is
doing — so a start needs no screen, keyguard or taps. The service is a
`specialUse` foreground service, not a `location` one; reading the SSID needs
the location permission, but a `location` service type cannot start before the
first unlock. Release 0.12.0 follows the network that matches the configured
SSID (and re-checks after unlock), keeps the port closed when the phone is on
another network or no Wi-Fi, and offers `wifi_lock` as an opt-in experiment for
the no-uplink AP; neither fixes the association drop in #11. `any_network` (the
panel's **Ignore the SSID**) bypasses the gate for a test or a USB-only setup.
The vendored F-Droid app remains a legacy fallback at
`PHONE_PROXY_PKG=com.tokyoxpa3.androidproxy`; its uninstall and data-clear are
the same commands.

The app's APK is built and published by the app's own repository: a `v*` tag
there builds `build.sh` in CI, signs with the release key from its secrets and
attaches `phone-link-proxy-<version>.apk` (with its `.sha256`) to the release —
that repository's README has the four secrets it needs.
`phone-proxy-install --release` installs it without leaving the checkout:

```sh
phone-proxy-install --release              # the latest release's APK
phone-proxy-install --release v0.12.0      # a particular tag
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

`--pull` names a single-APK backup `<package>-<version>.apk`, e.g.
`org.phonelink.proxy-0.12.0.apk`; installs use `adb install -r -g`, so updating
keeps the app's settings.

Requirements: `NetworkManager` on `wpa_supplicant` (iwd cannot do AP mode) and
the phone's proxy listening on the reachable address. The AP itself no longer
needs `net.ipv4.ip_forward`, because it does not forward; the doctor's
`ip_forward` check and `phone-fix-forwarding` are unchanged.
