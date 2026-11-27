# Scripts

Every command in `packages.<system>.phone-link`, plus the panel. Run them from
`nix develop`, from `./bin/` in the checkout, or after installing the package.

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
| `phone-doctor` | check every runtime condition of the setup (forwarding, AP role and link/address, adb, phone link, secrets, proxy, the port the laptop uses against the phone's listeners, tunnel, tether, internet), the APK a repair would install, the version the installed app reports and the phone SDK, and whether the source checkout is newer than the installed flake lock; exit non-zero if a required one is unmet; the adb check reconnects a phone whose wireless-debugging port changed by reading its `_adb-tls-connect._tcp` mDNS record, and reports the pinned port first when the phone answers there; it reports the two Wi-Fi reconnect globals as an optional line and names `phone-wifi-connect PhoneLink` when the AP is on air with no station; with `ap.role = "external"` it reports the external role, the laptop's client link and whether the phone holds `proxyHost`, instead of "AP is down"; `--analyze` prints one `fail`/`warn` line with a stable problem id for scripts |
| `phone-doctor-fix` | list the fixes for the problems `phone-doctor --analyze` reports, run one dedicated script per problem in dependency order, then re-check (`--yes` skips the prompt, `--dry-run` only lists, `--required` leaves warnings alone, `--which-doctor` prints the `phone-doctor` it reads — the one beside the checkout unless `PHONE_DOCTOR` says otherwise; run with `sudo`) |
| `phone-fix-apk` | stock the ambulance box: copy the app APK the cache or `PHONE_PROXY_APK` names into `/var/cache/phone-link` so a repair on a machine without a download can still reinstall the app; `--releases [N]` also keeps the APKs of the newest N releases (5 by default) as a repair kit of several versions, each checked against its `.sha256` and named after its tag, older ones pruned past three times N (`--refresh` replaces the copy and refreshes the kit, `--check` lists the box) |
| `phone-fix-forwarding` | set `net.ipv4.ip_forward=1` for the running kernel (`--check` reports only) |
| `phone-fix-internet` | restore internet for the APK download/check by trying mobile data, USB tethering, then the phone hotspot with the laptop as a client, verifying HTTPS after each (`--check` reports only) |
| `phone-fix-mobile-data` | enable the phone's mobile data and wait for a default route (`--check` reports only) |
| `phone-fix-tunnel` | start `phone-tun`, or restart it when its route is missing, and wait for the route (`--check` reports only) |
| `phone-proxy-check` | request through the proxy on the hotspot and AP addresses (needs root for the secret) |
| `phone-proxy-install` | install/update the proxy app — with no argument the newest signed release of `MBanucu/phone-link-proxy` (`PHONE_PROXY_REPO` overrides), checksum checked, unless an APK is named; `--release [TAG]` takes a named release instead, `--build` names the app's repository and refuses (this checkout no longer builds it), `--fdroid` fetches the legacy vendored app instead, `--replace-signer` exports the saved proxies first (`phone-proxy-export`), uninstalls and installs, then imports them back and starts/verifies the proxy that was in use — an app that cannot export is not uninstalled, and for the vendored app the old loss-on-uninstall still applies; `--pull` copies the installed APK off the phone, `--status` reports the version; for `org.phonelink.proxy` it also grants `WRITE_SECURE_SETTINGS` and the battery allowlist, so the app can turn wireless debugging back on itself |
| `phone-proxy-export` | pull every saved proxy with its port, SSID, credentials and switches off the phone over a one-shot loopback socket and write it root-only (mode 0600) beside the secrets (`PHONE_PROXY_BACKUP`, default `/etc/nixos/phone-link-proxies.json`; `--out FILE` overrides) — the same `ProfileDocument` JSON the app's menu exports, never a file on the phone; the phone must be unlocked |
| `phone-proxy-import` | write a `phone-proxy-export` backup back into the app over the same one-shot socket, replacing every saved proxy; the app validates the whole document first, so a malformed file changes nothing; the phone must be unlocked |
| `phone-proxy-uninstall` | remove the proxy app (`--check` previews, `--keep-data` keeps app data, `--yes` skips the prompt) |
| `phone-proxy-data-clear` | wipe the proxy app's data, back to port 1080 with no auth (`--check` previews, `--yes` skips the prompt) |
| `phone-proxy-battery-whitelist` | add the proxy app to the device-idle (Doze) whitelist so the proxy is not killed with the screen off (`--check` only reports) |
| `phone-proxy-boot` | make the proxy app come back after a reboot: add it to the device-idle allowlist, grant the location and notification permissions the SSID read and boot start need, turn `auto_start` on, and check that the installed build can start before the first unlock (direct-boot flag and a `LOCKED_BOOT_COMPLETED` receiver); the service itself is `specialUse`, not a `location` one (`--check` names every missing input and says which one needs a reinstall). DokeOS Auto Start Management is a separate gate behind a signature permission: it names the screen and the app's dated "likely blocked" fact, and never claims the gate is open |
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
| `phone-ap-create` | create the `phonelink` AP profile on 5 GHz channel 149 at 80 MHz from the root-only `PHONE_AP_PASS` secret (`--refresh` rewrites it after a PSK change, `--check` reports); a no-op with `ap.role = "external"` because there is no local profile to create |
| `phone-ap-delete` | delete the `phonelink` AP profile from NetworkManager, bringing it down first if active (`--check` reports, `--yes` skips the prompt; a declared profile returns at the next boot); a no-op with `ap.role = "external"` |
| `phone-ap-up` | preflight the radio, then `nmcli connection up phonelink`; with `ap.role = "external"` it says the AP is external, runs no `iw`/`nmcli`, and only asks the rejoin watchdog to nudge the phone back over USB |
| `phone-ap-down` | drop the AP and rejoin the phone's hotspot; `--client` stops the AP and leaves the radio free for NetworkManager, without joining anything; with `ap.role = "external"` it is a no-op and says the external AP stays up |
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
check needs. The file also carries `oem_autostart unreadable` because the
DokeOS list is signature-protected, and `last_boot no_broadcast <epoch>` only
when the app's boot receiver missed the current boot with auto-start on. That
line is the observation, not the conclusion; the doctor renders the dated
"likely blocked" wording, not a read of the vendor list.
`lib/phone-net.sh` remains for the live harness in `tests/live`.

`lib/python/phone_link/commands` holds the CLI half: one function per `bin/`
script, grouped by area (`status`, `phone`, `network`, `proxy`, `device`,
`maintenance`, `doctor_fix`), with `settings`, `shell`, `phone` and `ui` as the
shared layer. A `bin/phone-*` file is a thin shim that resolves the package next
to the checkout or the store install and hands over to it, so the script names
stay the contract: `phone_link.actions`, the Nix wrappers, the doctor and the
tests all address them by name. The recipe for adding one, and the rule for
choosing Python, `lib/*.sh`, a module option or the GUI, is in
[commands](commands.md).

## GUI

`packages.<system>.phone-link-gui` is a GTK4/libadwaita control panel for the
same setup. It reads the doctor's `--json` report for its
status page and runs the scripts with the flags declared in
`lib/python/phone_link/actions.py`:

```sh
nix run .#gui                                 # from a checkout
nix run github:MBanucu/phone-link#gui       # straight from the flake
nix build .#phone-link-gui                    # or build it and run the binary
```

The module itself installs no packages: the [README's install
snippet](../README.md#install-the-module) adds the scripts, and this adds the panel
with its desktop entry and icon:

```nix
environment.systemPackages = [ phone-link.packages.${pkgs.system}.phone-link-gui ];
```

The **Status** page opens with a **PhoneLink access point** switch, above the
doctor's findings. It reads the real state without root (the AP connection
active, or `iw dev <ap_if> info` reporting `type AP`) and runs `phone-ap-up`
when switched on or `phone-ap-down --client` when switched off, through the same
sudo/pkexec path as the action rows. While it is off the subtitle says the phone
link is down by design and that a network is joined in system settings; the
switch is not persisted, so a reboot returns to the configured boot state
(`phoneLink.ap.autoconnect`). The action row's menu carries the same
`--client` variant.

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
