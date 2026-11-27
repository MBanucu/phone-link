# Operations

## Install the module

The install snippet is in the [README](../README.md#install-the-module). Use the
bare `github:MBanucu/phone-link` to track `main`, or pin a tag or revision in
the input URL to keep the machine on a reviewed revision. A tag is part of the
input URL, so `nix flake update phone-link` alone keeps the same tag: change the
tag in `flake.nix` first, then run `nix flake update phone-link` to refresh
`flake.lock`.

The module declares the tunnel and the AP but installs no packages, so without
the `environment.systemPackages` line there is no `phone-ap-up`, `phone-doctor`
or `phone-proxy-*` on the machine.

The module never starts the tunnel at boot. A 5 s timer probes the proxy port and
keeps `phone-tun.service` running only while it answers, so a missing phone or a
stopped proxy app cannot blackhole traffic.

## The AP link

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

## External always-on AP

A laptop reboot is a local-AP reboot: the phone loses the link and may not
auto-join the link-only AP again (#33). Setting `phoneLink.ap.role = "external"`
moves the AP to a separate always-on box so a laptop reboot cannot disconnect
the phone; the full comparison, the invariants and the laptop-as-client setup
are in [ap-topology](ap-topology.md).

In that role the module creates no AP profile, DHCP server, nftables table or
DHCP firewall hole, and `phone-ap-up` / `phone-ap-down` explain the role and
change nothing on the radio. `ap.ssid` is the external AP's SSID, `apInterface`
is the laptop's client interface, and `proxyHost` must be the phone's DHCP
reservation on that AP. The external AP itself must stay link-only: no NAT, no
DHCP router or DNS option, no uplink and no forwarded traffic, or Android will
validate the Wi-Fi and drop cellular as the default. `ap.rejoin` keeps the USB
nudge working: it asks the phone over adb whether it holds `proxyHost` and calls
`cmd wifi connect-network <ap.ssid>` when it does not. The doctor reports the
role, the laptop's client link and the phone's association instead of an
"AP down" failure.

## Freeing the radio for normal Wi-Fi

The single radio cannot be the AP and a client on another channel at once, so
while `phonelink` is active NetworkManager sees only PhoneLink and
`iw dev wlp110s0 scan` fails with `Operation not supported (-95)`. The default
`phone-ap-down` is not the way out: it stops the AP and then joins the phone's
own hotspot, which is still not a normal network.

```sh
sudo phone-ap-down --client   # stop the AP; join nothing; the radio is free
```

`--client` stops the AP and never calls
`nmcli connection up "$PHONE_HOTSPOT_CON"`. NetworkManager can then scan and
join a normal network from system settings. The Status page's **PhoneLink
access point** switch is the same control: on runs `phone-ap-up`, off runs
`phone-ap-down --client`, both through the GUI's sudo/pkexec flow. When the
switch is off its subtitle says the phone link is down by design.

This is deliberately not persisted — no file and no NetworkManager change
survives the toggle. A reboot returns to the configured boot state: with
`phoneLink.ap.autoconnect = true` the AP comes back, otherwise it stays down
until `phone-ap-up`. Switching back on restores the AP, the phone rejoins, and
the hairpin/tunnel return.

## The AP band

The AP defaults to 5 GHz channel 149 at 80 MHz. 149 is non-DFS and one of the
channels this Intel 8265 allows for an AP; its self-managed (LAR) regulatory
domain marks 36/44 `no IR`. `channelWidth = 0` lets NetworkManager choose the
width (NetworkManager 1.50+ supports the setting; 2.4 GHz is capped at 40 MHz).
The hand-made profile from `phone-ap-create` uses the same band, channel and
width.

## Hairpin uplink: `ap.uplink = "tunnel"`

The link-only AP is the default, but Android then never validates it and this
phone drops the association (#11). `ap.uplink = "tunnel"` makes one client — the
phone — a real uplink without making the AP a general router:

```nix
phoneLink.ap = {
  enable = true;
  uplink = "tunnel";
  # forwardClient = "192.168.77.232";  # default: phoneLink.proxyHost
  # uplinkDns = "1.1.1.1";
};
```

The packet path is short and entirely on the laptop:

1. The phone sends to its new default route, `192.168.77.1`, with source
   `192.168.77.232`. The forwarded packet enters `wlp110s0`.
2. `inet phone_link_ap` (priority -10) matches
   `iifname "wlp110s0" ip saddr 192.168.77.232 accept` and lets it through; the
   `iifname "wlp110s0" drop` behind it still cuts off every other AP client.
3. The `ip rule` set sing-box installed sends it to table 2022, so it leaves
   through `phone-tun` (`via 172.19.0.2`) instead of the laptop's own uplink.
4. `ip phone_link_hairpin` postrouting masquerades exactly
   `oifname "phone-tun" ip saddr 192.168.77.232` to the TUN address, so
   sing-box's gvisor stack sees `172.19.0.1` and conntrack can reverse it on the
   way back.
5. The tunnel's SOCKS connection to `192.168.77.232:<phoneLink.proxyPort>`
   (1080 by default) stays on the main table (`192.168.0.0/16` is in the
   sing-box `route_exclude_address` list), so the forwarded packet and the
   tunnel's own uplink meet at the proxy without the proxy entering the tunnel.

The DHCP server changes with the mode: it advertises the AP address as the
router and `uplinkDns` as the resolver. The link-only DHCP sends neither, and
the phone has no default route, so both options are required for the hairpin.
DNS needs **no new ip rule**: on the live laptop
`ip route get 1.1.1.1 from 192.168.77.232 iif wlp110s0` already resolves to
`via 172.19.0.2 dev phone-tun table 2022` through rule 9001, ahead of the
dport-53-to-main rule. The DNS packet enters the TUN, and sing-box's existing
`{"protocol": "dns", "action": "hijack-dns"}` resolves it with the `remote` DoH
server through the proxy and synthesizes the reply. No UDP is carried over
SOCKS, and the phone's later app DNS goes through the same hijack.

Loop safety is the same property as before: the proxy's own egress is a
cellular-bound request in the app, not the AP default route, and the laptop's
tunnel socket to the proxy is excluded from the tunnel. The hairpin is not
free: every phone byte crosses the AP link **twice** — phone→laptop as the
forwarded packet and laptop→phone inside the tunnel's SOCKS connection to the
proxy. That is not a loop, because both crossings terminate at the proxy and
its egress is cellular, but it halves the useful airtime of the single-radio AP
and adds the extra Wi-Fi hop to the round-trip latency.

Failure semantics: the accept does not check the tunnel's state. If
`phone-tun` is not running, sing-box's ip rules and the table-2022 route are
gone too, so the accepted packet is no longer sent into the tunnel. With no
other default route the kernel fails it as unreachable; with a second uplink (a
USB tether) it can follow the laptop's main table. The fail-open watchdog
removes `ip phone_link_hairpin` and restores the plain drop in that state; it is
on by default with `uplink = "tunnel"` and described below. There are no NixOS
firewall rules for the hairpin: the only forward drop is
`inet phone_link_ap`, so the policy holds with
`networking.firewall.enable = false` too. `net.ipv4.ip_forward` is set as a
`mkDefault` when the mode is on.

Keep `forwardClient` to the phone's reservation. A second AP client, or a
spoofed source other than the configured one, still matches the drop. The
doctor keeps its `ap forward drop` check: in this mode the table still contains
the `iifname "wlp110s0" drop`, so the finding stays `ok` rather than reporting
a hairpin as a missing drop.

## Failing open when the tunnel is down

A validated AP takes the phone's default route. If `phone-tun` then dies, that
validated Wi-Fi is a blackhole until Android revalidates. The fail-open
watchdog closes that window: `phoneLink.apFailOpen.enable` defaults to
`phoneLink.ap.uplink == "tunnel"`, so enabling the hairpin enables the guard
unless it is explicitly set to `false`.

The timer runs every 5 s. Each tick checks that `phone-tun.service` is active,
the `phone-tun` device exists, the client `ip saddr … accept` is in `inet
phone_link_ap`, and (with `nat = true`, the default in tunnel mode) the scoped
`masquerade` is in `ip phone_link_hairpin`. An unhealthy tick deletes both
hairpin tables and loads `phoneLink.ap.noForwardRules` in one nft transaction,
so forwarding is never open in between. Android's next connectivity probe then
fails and it falls back to cellular.

A healthy tunnel only restores `phoneLink.ap.ruleset` after 15 s healthy
(`grace`) and at most once per 30 s (`throttle`), so the 5 s probe cannot flap
the hairpin. Fail-open does not wait for either: safety comes first. State lives
in `/run/phone-link/ap-failopen.state`; it is read, never sourced, and a
malformed file is treated as unknown. A reboot starts from unknown, and the
first healthy tick adopts an existing hairpin.

The watchdog's own part is one 5 s tick. The 60 s acceptance budget is that
tick plus Android's revalidation of the now-failing AP; issue #47 records the
measured fallback. A dead tunnel, a missing TUN device and an externally
flushed hairpin take the same path. Set
`phoneLink.apFailOpen.enable = false` only when deliberately running the
hairpin unguarded. The script takes `PHONE_AP_IF`, `PHONE_AP_CLIENT`,
`PHONE_AP_TUN_IF`, `PHONE_NFT`, `PHONE_AP_NOFORWARD_RULES`,
`PHONE_AP_HAIRPIN_RULES`, `PHONE_AP_FAILOPEN_STATE`,
`PHONE_AP_FAILOPEN_GRACE` and `PHONE_AP_FAILOPEN_THROTTLE` from the
environment, so the same file runs under the unit and under a test.

Set `phoneLink.ap.autoconnect = true` to bring the AP back after a reboot
without running `phone-ap-up`. It lets NetworkManager activate the profile at
boot, which reserves the radio for the AP; if the 5 GHz activation fails, there
is no link at all (#7). It does not fix a phone that drops the link while
associated — that is the phone-side cause in #11 — and it does not add the
2.4 GHz fallback (#7).

## Rejoining the AP after a restart

Android validates this link-only AP as "no internet" and, after a few reports,
temporarily disables auto-join for the saved network
(`NETWORK_SELECTION_TEMPORARY_DISABLED`, reason
`NETWORK_SELECTION_DISABLED_NO_INTERNET_TEMPORARY`). That disable is temporary:
with no USB the phone rejoined by itself about 120 s after an AP restart once
the window had passed, and Android documents the window as up to 10 minutes
(#36). With USB the watchdog shortens the wait to seconds (#33).

With `ap.enable = true`, `phone-link-ap-rejoin.timer` checks every 30 s. It acts
only when the AP interface is up, `iw dev <iface> station dump` has no station,
and `adb -d` sees the USB device; then it runs
`cmd wifi connect-network <ssid> wpa2 $PHONE_AP_PASS` over USB and waits up to
30 s for the station. If that does not bring the phone back it falls back to
`svc wifi disable`/`enable`. Attempts are throttled to one per five minutes
(`/run/phone-link/ap-rejoin.last`), so a phone that ignores the command is not
hammered. The service exits non-zero when the phone is away; that is normal and
does not fail the boot.

A deliberate switch-on does not wait out that window: `phone-ap-up` clears the
throttle file and starts `phone-link-ap-rejoin.service` as soon as the AP is
back, so the association is asked for immediately. A missing unit
(`phoneLink.ap.rejoin = false`) or no USB adb is a no-op and never fails the
switch.

Do not make the AP answer Android's connectivity probe. It has to stay
unvalidated so the phone keeps using cellular; the watchdog re-asserts the
association from the laptop instead.

The watchdog needs USB adb, because the Wi-Fi adb transport is gone exactly when
this is needed. Without USB it does nothing and the phone returns when Android's
temporary disable expires (up to ~10 minutes), or immediately if someone
toggles Wi-Fi or re-selects the network on the phone (`phone-wifi-connect
PhoneLink`). Set `phoneLink.ap.rejoin = false` to disable the timer.

## The proxy port

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

## The configuration the module shares

The module writes the non-secret `phoneLink` values to `/etc/phone-link/env`:
the AP interface, name, SSID and address, the proxy host(s), port and user,
the secrets path, the runtime port file, and the `nft` binary the AP's
no-forward unit runs. The commands, the doctor and
`lib/phone-net.sh` read it, so a non-default deployment needs no repeated
`PHONE_*` exports, while an environment variable still wins for a one-off run.
`PHONE_CONFIG_FILE` points the readers at another file in a test. The port file
is written from `phoneLink.proxyPort` when tmpfiles runs, so the value the
doctor sees after a boot is the module's own rather than an older run's.

## One adb serial

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

## USB-primary and host fallback

The address is also runtime state. `phoneLink.proxyHost` is the primary address
and `phoneLink.proxyHosts` lists fallbacks tried in order after it. Every 5 s,
`phone-tun-toggle` opens a TCP connection to each effective host (`proxyHost`,
then `proxyHosts`, with duplicates removed) and, only when none of them
answers, to gateways gathered once for that tick: the `ip route show default`
next hops and the peer addresses of point-to-point links. Gateways are
deduplicated against the declared hosts and the AP host, which is never probed
through the tunnel. The first address that answers is recorded in
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
tether address is assigned per connection, so a stale USB entry no longer has
to be edited by hand: after the declared hosts fail, the toggle probes that
boot's default-route gateway and any point-to-point peer. The runtime host file
is what saves a rebuild when only the reachable path changes. The relay reads
the same file and falls back to `phoneLink.proxyHost` when it is absent or does
not hold an address.

`proxyHosts` only chooses among addresses the phone answers on. The app still
gates its listener on the configured SSID, so a USB address does not help while
the phone is off `PhoneLink`: the app has no listener and the tunnel has
nothing to reach. USB-primary therefore needs either the phone also joined to
`PhoneLink`, or the app started with `any_network` (the panel's **Ignore the
SSID**), which the app documents as a test/escape hatch. Without one of those,
`proxyHosts` alone is not a USB fallback.

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
associated: the AP is DHCP-only and drops forwarded traffic (see the
[options](options.md)), so the link carries the laptop's tunnel to the proxy and
the phone's own internet does not cross it. The association drop in #11 is
separate.
`phoneLink.ap.uplink = "tunnel"` is the opt-in opposite: the phone's traffic is
hairpinned through the laptop's tunnel so Android can validate the AP; every
other AP client is still dropped.

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

With `phoneLink.ap.role = "external"` there is no profile to create: configure
the external AP itself (link-only, DHCP reservation for `proxyHost`) and join
it from NetworkManager as a normal client. Keep `PHONE_AP_PASS` in the secrets
file so the rejoin watchdog can nudge the phone back over USB; `ap.enable` is
not needed. See [ap-topology](ap-topology.md) for the invariants and the
laptop-as-client example.

The proxy is a signed release APK from `MBanucu/phone-link-proxy`, not a build
of this checkout; `phone-proxy-install` fetches the latest release unless you
name one. Install it while the laptop
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
the battery exemption, grants the fine/coarse, background and notification
permissions the boot start and the SSID read need, and checks the manifest
facts the app cannot change from adb: the direct-boot flag and a receiver for
`LOCKED_BOOT_COMPLETED`. A missing manifest fact is reported as
"reinstall the release"; the check never claims more than that, because only a
reboot without unlocking proves the listener comes up. DokeOS Auto Start
Management is the gate adb cannot read or write: the command names the screen
and repeats the app's dated "likely blocked" fact, without promising a restart.
The app's foreground service is `specialUse`, not `location`: a `location`
service type cannot start before the first unlock and is not needed for the
SSID read.

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
`MBanucu/phone-link-proxy` — the latest release, or the version the phone
reports — and never built in this checkout. The `phone-proxy-*` scripts talk to it over its own adb interface —
`start-foreground-service` with `org.phonelink.proxy.action.START` or `STOP`
and the configuration as extras, and `dumpsys activity service` for what it is
doing — so a start needs no screen, keyguard or taps. The service is a
`specialUse` foreground service, not a `location` one; reading the SSID needs
the location permission, but a `location` service type cannot start before the
first unlock. The app follows the network that matches the configured SSID (and re-checks after unlock), keeps the port closed when the phone is on
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
phone-proxy-install --release <tag>        # a particular tag
phone-proxy-install --release --replace-signer
```

That last one is for a phone whose app was built locally: the debug key is a
different signature, so adb refuses to update in place and the app has to go
first — which used to clear its saved proxies. For `org.phonelink.proxy` the
command now exports them first (`phone-proxy-export`), uninstalls and installs,
then imports them back (`phone-proxy-import`), starts the proxy that was in use
and verifies it answers on the port it had. If the installed app is too old to
export, nothing is uninstalled: update it in place first, or accept the loss by
uninstalling it yourself. The backup is
`$PHONE_PROXY_BACKUP` (default `/etc/nixos/phone-link-proxies.json`, beside the
secrets), mode 0600, and holds every proxy's password in clear text. The export
refuses a path inside a git work tree unless that repository ignores it: add
`phone-link-proxies.json` to `/etc/nixos/.gitignore`, or set
`PHONE_PROXY_BACKUP`/`--out` to a path outside the repository. Both
actions need the screen on and the phone unlocked; the laptop never prints a
password.
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
`org.phonelink.proxy-<version>.apk`; installs use `adb install -r -g`, so updating
keeps the app's settings.

## Requirements

`NetworkManager` on `wpa_supplicant` (iwd cannot do AP mode) and
the phone's proxy listening on the reachable address. The AP itself no longer
needs `net.ipv4.ip_forward`, because it does not forward; the doctor's
`ip_forward` check and `phone-fix-forwarding` are unchanged.
