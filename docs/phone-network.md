# Phone link: measured behaviour and traps

Everything below was measured on this laptop (Intel Wi-Fi, `wlp110s0`) and the
phone (`XPLO2EEA0001541`, Android 15, unrooted).

## Topology

Phone, hotspot mode:

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
laptop wlp110s0   192.168.77.1/24   NetworkManager "shared", its own dnsmasq
phone  wlan0      192.168.77.232     DHCP lease, proxy binds this address
```

## Traps, in the order they cost time

1. **A hotspot phone is not a Wi-Fi client.** `cmd wifi status` prints
   "Wifi is disabled" while the SoftAP runs; `ap0` exists but `wlan0` does not.
   Consequence: the `Wireless debugging` toggle is unavailable, and adbd cannot
   be switched to TCP from the shell either (`cmd adb` only exposes
   `is-wifi-supported` / `is-wifi-qr-supported`, and starting the proxy service
   with `am start-foreground-service` fails with "Requires permission not
   exported from uid 10300").
2. **`adb tcpip 5555` resets the USB gadget.** adbd restarts, rndis disappears
   and re-appears, so the USB tether drops for a few seconds. If the phone is the
   only uplink, the laptop's internet dies with it. Replugging the cable fixes it.
3. **DHCP to the AP client is firewalled.** `nixos-fw` ends in
   `nixos-fw-log-refuse` and had no `udp/67` rule, so the phone associated
   (`Supplicant state: COMPLETED`, RSSI -36) but stayed at `IP: null`, with no
   `DHCPDISCOVER` in the laptop's journal. `modules/phone-link.nix` adds 53/67.
4. **A single radio cannot be client and AP on different channels.** `iw list`
   reports `managed + AP` only for `#channels <= 1`, so starting the AP drops the
   client link to the phone's hotspot. AP mode therefore has no uplink of its own.
5. **The phone's proxy binds a fixed set of interface addresses at start, not
   `0.0.0.0`.** After joining the AP it kept listening on the stale
   `10.244.108.165` and on `127.0.0.1`/`172.26.192.42`, but not on
   `192.168.77.232`, so the tunnel could not connect. Workarounds: restart the
   app while the AP link is up, or use `--via-adb` (`adb reverse tcp:1080`) which
   reaches the `127.0.0.1` listener.
6. **DNS loop.** With the tether, the laptop's resolver is the phone's tether DNS
   (`172.26.192.42`). That forwards to the phone's default network, which in AP
   mode is the `PhoneLink` Wi-Fi whose DNS is the laptop (`192.168.77.1`), which
   forwards back. Result: every name lookup fails and every `curl` exits `000`
   even though raw IPs work. `modules/phone-link.nix` avoids this by pinning
   `/etc/resolv.conf` to `1.1.1.1`/`9.9.9.9`.
7. **Policy routing is not obvious.** sing-box (gvisor stack) installs
   `ip rule` entries with fwmark 2022 and a table 2022 route, so
   `ip route get 1.1.1.1` shows `via 172.19.0.2 dev phone-tun table 2022`.
   `curl --interface wlp110s0` bypasses the TUN and is the control that proves the
   proxy carries the traffic (`000` on the hotspot, `200` through the tunnel).
8. **Android's no-internet Wi-Fi.** An AP without an uplink is unvalidated. The
   phone kept `PhoneLink` connected for 90 s of watching, with mobile data still
   the default network, but expect an "no internet" notification and possible
   network-selection games on other builds.

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

- Proxy app: `com.tokyoxpa3.androidproxy`, service `.Socks5ProxyService`,
  credentials `proxy:<proxy password>` (secret lives in `/etc/nixos/phone-socks-secrets`).
- `adb tcpip 5555` works, but `persist.adb.tcp.port` cannot be written:
  `setprop` is denied by SELinux for `shell` (`Enforcing`, `ro.build.type=user`),
  so there is no way to make adbd start on TCP after a reboot.
- `mdnsd` runs on the phone; it advertises `_adb._tcp` with hostname
  `Android.local`, but only on the interface of its active network (seen on the
  tether, not on the AP/hotspot side). Laptop side: `avahi-browse -art` finds it.
- Wireless debugging (Android 11+) works headlessly here: `settings put global
  adb_wifi_enabled 1` starts a TLS adbd on a random port, advertised as
  `_adb-tls-connect._tcp` with that port, which `avahi-browse -rt` reads. The
  host's key is already trusted, so `adb connect` needs no pairing. `adb tcpip
  5555` restarts adbd and leaves wireless debugging on with a new random port,
  so both listeners work at once.
