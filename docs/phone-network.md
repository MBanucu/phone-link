# Phone link: measured behaviour and traps

Everything below was measured on this laptop (Intel Wi-Fi, `wlp110s0`) and the
phone (`XPLO2EEA0001541`, Android 15, unrooted).

## Topology

Phone, hotspot mode (measured with the vendored app; the current
`org.phonelink.proxy` is built around the AP link and leaves hotspot and USB
paths out of scope):

```
ap0      10.244.108.165/24     SOCKS 0.0.0.0:1080 is bound here
rndis0   172.26.192.42/24      USB tether, also bound
```

Laptop joins `XPLORE 2` (the phone's own hotspot), gets `10.244.108.149/24`,
gateway `10.244.108.165`. The hotspot provides **no** direct internet: with the
tether route removed, `https://1.1.1.1` and `https://example.com` both time out
(`000`), while `curl --socks5-hostname proxy:PASS@10.244.108.165:1080` returns
`200`. So the proxy is not an optimisation; it is the only uplink.

AP mode:

```
laptop wlp110s0   192.168.77.1/24   NetworkManager "manual" + DHCP-only dnsmasq,
                                    5 GHz ch 149/80 MHz
phone  wlan0      192.168.77.232     DHCP reservation, proxy binds this address
```

The AP is a link, not an uplink and not an internet-sharing hotspot.
`phoneLink.ap` uses NetworkManager's `manual`
method, so the address and the `192.168.77.0/24` connected route are there but
NetworkManager installs no DHCP, NAT or forwarding. A separate dnsmasq answers
DHCP without a router or DNS option, and forwarded packets entering `wlp110s0`
are dropped in a dedicated nftables table. The phone therefore has no internet
path through the laptop and keeps mobile data as its default. The
`ap.uplink = "tunnel"` mode below is the explicit, scoped exception. The
laptop→`192.168.77.232` direction is output, not forwarding, so the proxy, adb
and sshfs are unaffected.

`phoneLink.ap.autoconnect` defaults to `false`: NetworkManager does not
activate the profile at boot, so the radio stays free for a client link.
Setting it `true` brings the AP back after a reboot, at the cost of reserving
the radio; a failed 5 GHz activation then leaves no link at all (#7).

The link-only profile does not keep this phone associated for long. In the
2026-11-26 runs the phone dropped the DHCP-only AP after 34 s
(`AP-STA-CONNECTED` 14:31:23 → `AP-STA-DISCONNECTED` 14:31:57); advertising a
router option, still with no DNS and still dropping forwarded traffic, extended
it to 94 s. At the drop the Wi-Fi is gone, the app closes its listener by
design and `phone-tun` goes inactive. That is #11, not a validation success, and
it is open: the 30-minute screen-off acceptance run is still pending. USB
tethering is the practical unattended path until it lands. The earlier #4
acceptance run finished inside the first ~30 s window, so it shows the
forwarding loop is gone, not that the link is stable.

The tether address is assigned per connection (it has been `172.26.192.42`,
`10.207.119.29` and `10.186.76.251`); the hotspot and AP addresses below are
stable.

## USB-primary and the runtime host

`rndis0` has carried `10.23.190.38`, and the proxy binds it as well as the
Wi-Fi addresses. How to list the tether and the AP in `proxyHost`/`proxyHosts`,
and how the 5 s probe keeps `/run/phone-link/proxy-host` current, is in
[operations](operations.md#usb-primary-and-host-fallback).

## The AP band

It used to be 2.4 GHz channel 1 at 20 MHz, the most crowded part of the band
here.

Channel 149 is non-DFS and one of the few 5 GHz channels this Intel 8265 lets
an AP beacon on. `iw phy phy0 info` marks 36/44 `(no IR)` under the card's
self-managed (LAR) regulatory domain, and every DFS channel (52-144) as
`(no IR, radar detection)`; 149-165 carry no such flag. `iw reg get` allows
80 MHz on 5735-5835, so channel 149 at 80 MHz fits 5735-5815. The width is
`802-11-wireless.channel-width`, which NetworkManager exposes from 1.50 on.

The single-radio constraint in trap 4 still holds: the card cannot be a client
and an AP on different channels. In AP mode that is exactly the intended case —
the phone is the client and the laptop's uplink is `phone-tun` — so the AP owns
the radio and needs no client link of its own.

The default band, channel and width are in
[operations](operations.md#the-ap-band).

## The AP hairpin: `ap.uplink = "tunnel"`

The link-only AP above is the default. `phoneLink.ap.uplink = "tunnel"` makes
the phone (the one address in `ap.forwardClient`, default `proxyHost`) a real
uplink, so Android can validate the AP while every other AP client stays
dropped. It is one scoped exception, not NetworkManager's old shared NAT.

Packet path, laptop side:

```
phone 192.168.77.232 -> 1.1.1.1
  wlp110s0 (forward, inet phone_link_ap priority -10)
    iifname "wlp110s0" ip saddr 192.168.77.232 accept
    iifname "wlp110s0" drop              # everyone else
  ip rule 9001: not from all iif lo lookup 2022
  phone-tun: via 172.19.0.2
  ip phone_link_hairpin postrouting (priority srcnat)
    oifname "phone-tun" ip saddr 192.168.77.232 masquerade
  sing-box socks outbound -> 192.168.77.232:<phoneLink.proxyPort> (main table, 192.168.0.0/16 excluded)
  proxy -> cellular (app's explicit cellular NetworkRequest)
```

The reverse path is already safe: conntrack un-NATs the reply to
`192.168.77.232` and the `9002: from all iif phone-tun goto 9010` rule leaves it
on the main table, where `192.168.77.232` is the connected route on `wlp110s0`.
The tunnel's own socket to the proxy also stays on the main table, so the proxy's
cellular egress does not come back over the AP.

The hairpin still crosses the AP link twice: the phone's payload goes
phone→laptop as the forwarded packet, and laptop→phone again inside the tunnel's
SOCKS connection to the proxy (`phoneLink.proxyPort`, 1080 by default; 1081 on
the live phone). That is not a loop, because both crossings terminate at the
proxy and its egress is an explicit cellular request, but it halves the useful
airtime of the single-radio AP and adds the extra Wi-Fi hop to the round-trip
latency.

The DHCP server is the other half: with `uplink = "tunnel"` dnsmasq adds
`--dhcp-option=option:router,192.168.77.1` and
`--dhcp-option=option:dns-server,1.1.1.1` (`ap.uplinkDns`). The link-only DHCP
sends neither, and the phone's main table has no default route, so without both
the hairpin would have nothing to accept.

DNS deliberately adds **no ip rule**. Measured on this laptop:

```
$ ip route get 1.1.1.1 from 192.168.77.232 iif wlp110s0
1.1.1.1 from 192.168.77.232 via 172.19.0.2 dev phone-tun table 2022
$ ip route get 192.168.77.232
192.168.77.232 dev wlp110s0 src 192.168.77.1
```

Rule 9001 (`not from all iif lo lookup 2022`) runs before the dport-53-to-main
rule, so the phone's DNS packet enters the TUN like any other forwarded packet.
sing-box's existing `{"protocol": "dns", "action": "hijack-dns"}` rule answers
port 53 with the `remote` DoH server through the proxy, so the TCP-only SOCKS
upstream never sees UDP and the phone's later lookups take the same path. The
alternative considered in #44 — a dnsmasq on `192.168.77.1:53` — is not needed.

Failure semantics: the nft accept does not test `phone-tun`. When the tunnel is
not running, sing-box's ip rules and the table-2022 route are gone as well, so
the accepted packet is no longer sent into the tunnel: with no other default
route the kernel fails it as unreachable, and with a second uplink such as a USB
tether it can follow the laptop's main table. The fail-open watchdog below
closes that window and is on by default with `uplink = "tunnel"`. There are no
NixOS firewall rules for the hairpin: the only forward drop in this setup is
`inet phone_link_ap`, and the doctor keeps reporting its
`iifname "wlp110s0" drop` as the AP forward drop.

## Failing open when the tunnel is down

The hairpin is what lets the phone validate the AP, and a validated Wi-Fi takes
the phone's default route. That is only safe while `phone-tun` is actually
carrying traffic. If the tunnel stops while the hairpin stays, the phone can sit
on a validated-but-dead Wi-Fi and blackhole its own internet until Android
revalidates. The link-only AP has the opposite, safer failure: the phone keeps
cellular.

`phone-link-ap-failopen` closes that gap and is enabled by default whenever
`phoneLink.ap.uplink = "tunnel"`; set `phoneLink.apFailOpen.enable = false` only
to run the hairpin unguarded. Every 5 s it checks:

- `phone-tun.service` is active and its `phone-tun` device exists;
- `inet phone_link_ap` still carries the client accept (an `ip saddr … accept`
  rule, not just the chain's `policy accept`);
- when the hairpin uses NAT, `ip phone_link_hairpin` still carries the scoped
  `masquerade` for that client.

If any check fails, it deletes `ip phone_link_hairpin` and replaces
`inet phone_link_ap` with `ap.noForwardRules`, in one nft transaction: every
packet entering from the AP is dropped again, so the phone's next connectivity
probe fails and Android falls back to cellular. It is idempotent — an already
open state does not touch nft — and an externally flushed hairpin takes the same
path as a dead tunnel.

Restore is deliberately slower than fail-open. After a restore the tunnel must
stay healthy for `PHONE_AP_FAILOPEN_GRACE` seconds (15 by default) and at least
`PHONE_AP_FAILOPEN_THROTTLE` seconds (30 by default) must have passed since the
last change; a 5 s toggle therefore cannot flap the hairpin. The healthy rules
are `ap.ruleset` (client accept, drop and scoped masquerade), the same text the
AP forward unit loads. The state file is
`/run/phone-link/ap-failopen.state` and holds the mode plus the healthy and
change timestamps. It is read, never sourced, and a malformed file is treated as
unknown.

The watchdog's own contribution to recovery is one 5 s tick. The 60 s
acceptance budget is that tick plus Android's revalidation and switch to
cellular; #47 is where the live number is recorded. No watchdog action is needed
for suspend or reboot: the AP disappears with the laptop, so the phone falls
back naturally.

The unit lives in the additive `modules/phone-link-failopen.nix`; the default
flake module imports it, but it defines nothing unless `ap.uplink = "tunnel"`
(or `apFailOpen.enable` is set explicitly).

## How the proxy gets out over cellular

Measured on the AP link before the AP became DHCP-only, with the phone joined to
`PhoneLink`. The app in that run was the vendored
`com.tokyoxpa3.androidproxy`; the current `org.phonelink.proxy` (0.12.0) makes
the same cellular request, and only the requestor package differs. The phone's
default network was the **laptop's AP**, not mobile data:

```
Active default network: 102
NetworkAgentInfo{network{102} ... ni{WIFI CONNECTED ...}
  lp{{InterfaceName: wlan0 LinkAddresses: [ ... 192.168.77.232/24 ]
      DnsAddresses: [ /192.168.77.1 ]
      Routes: [ ... 0.0.0.0/0 -> 192.168.77.1 wlan0 ]}}
  nc{[ Transports: WIFI Capabilities: NOT_METERED&INTERNET&...&VALIDATED ...]}
```

A plain SOCKS server that just connects on the default route would therefore
send the tunnel's traffic back to the laptop, which forwards it to the phone's
proxy again: a loop that never reaches the internet. The app avoids that with an
explicit, bound cellular request, visible in the same dump:

```
NetworkRequest [ REQUEST id=326, [ Transports: CELLULAR
  Capabilities: INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&NOT_VCN_MANAGED
  Forbidden: LOCAL_NETWORK Uid: 10323 RequestorUid: 10323
  RequestorPkg: com.tokyoxpa3.androidproxy ] ]
uid/pid:10323/6913 activeRequest: 326
```

So the proxy's egress is cellular by construction, and the name is literal: the
app asks for a cellular `Network` and opens its upstream sockets and DNS lookups
on it (`Network.socketFactory` / `Network.getAllByName` in API terms) rather than
on the default network.

Consequences worth knowing:

- No cellular means no tunnel, even though the proxy still accepts connections on
  `wlan0`. Check `phone-fix-mobile-data` / `phone-net-status` before blaming the
  tunnel for `curl` exiting `000`.
- With the old shared uplink the AP link was `NOT_METERED` and even `VALIDATED`
  (the laptop's shared uplink answered the phone's validation probe), so
  Android did **not** hand the default route back to mobile data by itself. The
  90 s observation in trap 8 did not generalise. The module no longer advertises
  an uplink, so the link-only AP fails validation and mobile data stays the
  default — but this phone then drops the association after 34 s (#11). The
  acceptance run in
  [issue #4](https://github.com/MBanucu/phone-link-proxy/issues/4) is therefore
  not closed; the pending 30-minute screen-off run in #11 is what would confirm
  a stable link.
- Anything replacing the app must make the same request and bind to it.
  `Socket(host, port)` on an unvalidated/validated Wi-Fi default is exactly the
  loop described above.

Reproduce with the dump written to a file first — `dumpsys connectivity | grep`
dies with `/system/bin/printf: Argument list too long`:

```sh
adb shell 'dumpsys connectivity > /data/local/tmp/conn.txt'
adb shell 'grep -n 10323 /data/local/tmp/conn.txt'
```

## Traps, in the order they cost time

1. **A hotspot phone is not a Wi-Fi client.** `cmd wifi status` prints
   "Wifi is disabled" while the SoftAP runs; `ap0` exists but `wlan0` does not.
   Consequence: the `Wireless debugging` toggle is unavailable, and adbd cannot
   be switched to TCP from the shell either (`cmd adb` only exposes
   `is-wifi-supported` / `is-wifi-qr-supported`). The vendored proxy also
   refused `am start-foreground-service` with "Requires permission not exported
   from uid 10300"; the current `org.phonelink.proxy` is exported and guarded
   by `android.permission.DUMP`, so the adb contract works once there is a
   Wi-Fi client link. In AP mode the `adb_wifi_enabled` setting can be
   written over adb instead, which is what `phone-adb-wifi` does.
2. **`adb tcpip 5555` resets the USB gadget.** adbd restarts, rndis disappears
   and re-appears, so the USB tether drops for a few seconds. If the phone is the
   only uplink, the laptop's internet dies with it. Replugging the cable fixes it.
3. **DHCP to the AP client is firewalled.** `nixos-fw` ends in
   `nixos-fw-log-refuse` and had no `udp/67` rule, so the phone associated
   (`Supplicant state: COMPLETED`, RSSI -36) but stayed at `IP: null`, with no
   `DHCPDISCOVER` in the laptop's journal. `modules/phone-link.nix` adds UDP 67
   (DHCP only; the AP serves no DNS).
4. **A single radio cannot be client and AP on different channels.** `iw list`
   reports `managed + AP` only for `#channels <= 1`, so starting the AP drops the
   client link to the phone's hotspot. AP mode therefore has no uplink of its own.
5. **The vendored proxy binds a fixed set of interface addresses at start, not
   `0.0.0.0`.** After joining the AP the old
   `com.tokyoxpa3.androidproxy` kept listening on the stale
   `10.244.108.165` and on `127.0.0.1`/`172.26.192.42`, but not on
   `192.168.77.232`, so the tunnel could not connect. Workarounds were to
   restart the app while the AP link was up, or use `--via-adb`
   (`adb reverse tcp:1080`) to reach the `127.0.0.1` listener. This is fixed in
   `org.phonelink.proxy`: it listens on `0.0.0.0`, so the port is the same on
   `ap0`, `rndis0` and `wlan0` and survives the address changing. `--via-adb`
   still works.
6. **DNS loop.** With the tether, the laptop's resolver is the phone's tether DNS
   (`rndis0`'s address, which changes per connection). That forwards to the
   phone's default network; under the old shared AP that was the `PhoneLink`
   Wi-Fi whose DNS was the laptop (`192.168.77.1`), and the lookup came straight
   back. Result: every name lookup fails and every `curl` exits `000` even
   though raw IPs work. `modules/phone-link.nix` avoids this by pinning
   `/etc/resolv.conf` to `1.1.1.1`/`9.9.9.9`, and the AP no longer advertises
   the laptop as a DNS server either.
7. **Policy routing is not obvious.** sing-box (gvisor stack) installs
   `ip rule` entries with fwmark 2022 and a table 2022 route, so
   `ip route get 1.1.1.1` shows `via 172.19.0.2 dev phone-tun table 2022`.
   `curl --interface wlp110s0` bypasses the TUN and is the control that proves the
   proxy carries the traffic (`000` on the hotspot, `200` through the tunnel).
8. **Android's no-internet Wi-Fi.** An AP without an uplink is unvalidated. With
   the link-only AP the phone keeps mobile data as the default network, but it
   does not stay associated: 34 s in the DHCP-only run, 94 s with a router
   option added, and the listener closes at the drop and `phone-tun` stops.
   That is the #11 blocker; the 30-minute screen-off acceptance run is still
   pending. The module used to give the AP a shared uplink, so it could come up
   `VALIDATED` and take the default route itself — that is the state the
   cellular section above was measured in. It now runs the AP DHCP-only and
   drops forwarded AP traffic, which is the intended design but not yet a
   stable unattended link.

## Verified results

Tunnel against the hotspot address, with the tether default route deleted:

```
route to 1.1.1.1 : via 172.19.0.2 dev phone-tun table 2022
curl example.com 200 · codebuff 301 · freebuff 200 · cache.nixos.org 200
nix flake metadata OK · Chrome <title>Example Domain
outbound/socks[phone] connections: 23
control bound to wlp110s0: 000
stop -> TUN gone, routes restored, direct 200
```

adb over Wi-Fi on the hotspot (TCP transport, not USB):

```
socket 10.244.108.149:37916 -> 10.244.108.165:5555
adb -s 10.244.108.165:5555 shell echo -> OK
```

## Phone-side facts worth remembering

- **Historical, and the source of most of the measurements above:** the vendored
  `com.tokyoxpa3.androidproxy`, service `.Socks5ProxyService`, credentials
  `proxy:<proxy password>` (secret lives in `/etc/nixos/phone-socks-secrets`).
  The current app is `MBanucu/phone-link-proxy`, package `org.phonelink.proxy`,
  service `.ProxyService`, release 0.12.0. It listens on `0.0.0.0` and gates the
  port on the configured SSID (`PhoneLink` by default); `any_network` (the
  panel's **Ignore the SSID**) bypasses the gate, and `wifi_lock` is an opt-in
  experiment for the no-uplink AP. Its foreground service is `specialUse`, not
  `location`; the location permission is only what reading the SSID needs.
  `phone-proxy-install` takes a signed release, `phone-proxy-setup` is the
  first-run path, and `phone-proxy-boot` makes it come back after a reboot.
- `adb tcpip 5555` works, but `persist.adb.tcp.port` cannot be written:
  `setprop` is denied by SELinux for `shell` (`Enforcing`, `ro.build.type=user`),
  so there is no way to make the legacy 5555 listener start after a reboot.
- `mdnsd` runs on the phone and advertises `_adb._tcp` with hostname
  `Android.local` on the interface of its active network (seen on the tether).
  The wireless-debugging service is `_adb-tls-connect._tcp`; it is advertised on
  the AP link (`wlp110s0`) too, and its record carries the random TLS port that
  `avahi-browse -rt` reads.
- Wireless debugging (Android 11+) works headlessly here: `settings put global
  adb_wifi_enabled 1` starts a TLS adbd on that random port, and the host's key
  is already trusted, so `adb connect` needs no pairing. `adb tcpip 5555`
  restarts adbd and leaves wireless debugging on with a new random port, so both
  listeners work at once.
