# External-AP acceptance runbook (#37)

What this proves: with the phone on an **always-on** AP that does not reboot
with the laptop, three laptop reboots in a row leave the phone associated and
bring `phone-tun` back within 30 s, with **no USB cable**. The software half of
#37 is already merged; this is the hardware proof.

It cannot be simulated on the laptop: the failure being removed is "the AP
disappears with the laptop", so the AP has to be a second, independently
powered box.

## What you need

- An always-on AP: an OpenWrt/travel router, or a Raspberry Pi running
  `hostapd` + `dnsmasq`. It must stay powered while the laptop reboots (its own
  PSU, not the laptop's USB port).
- The laptop needs a way to reach the AP as a **client**. One radio can do
  client mode; it cannot be the AP at the same time. Keep the USB tether for
  setup and rollback, and unplug it for the runs.
- A second way to look at the AP during a run: LuCI/SSH over Ethernet, or the
  AP's own admin Wi-Fi on a different SSID.
- The phone's MAC address (for the reservation) and the current AP PSK from the
  root-only secrets file. The PSK is never committed.

## AP invariants

The external AP must be link-only in exactly the same sense as the laptop one;
otherwise the phone may prefer it as the internet path and the hairpin/egress
guard has nothing to protect.

| Property | Required |
|---|---|
| DHCP | address + netmask only; **no router option (3), no DNS option (6)** |
| Reservation | phone MAC → fixed address; long/infinite lease (`proxyHost`) |
| Uplink | none; no WAN cable, no NAT, no forwarding from the client SSID |
| IPv6 | no RA, no DHCPv6, no default route (disable it or assign no global prefix) |
| Client isolation | **off** — the laptop must reach the phone's proxy port |
| Band | 5 GHz, channel 149, 80 MHz (same as the laptop AP), or a measured equivalent |
| SSID/PSK | preferably the same SSID/PSK as the current laptop AP, so the phone needs no interaction |

On OpenWrt, the DHCP part is `list dhcp_option '3'` and `list dhcp_option '6'`
in `/etc/config/dhcp` (dnsmasq: no router, no DNS), plus a static `config host`
for the phone. Disable `ra`/`dhcpv6`/`ndp`, leave `isolate '0'`, and do not
create a WAN/uplink zone. On a Pi, the same lines are
`dhcp-option=3`, `dhcp-option=6` and `dhcp-host=<mac>,<ip>,infinite`; keep
`net.ipv4.ip_forward=0` and add no NAT rules.

## 1. Prepare the host (USB still connected)

Keep the current link up while you change the config. In `/etc/nixos`:

```nix
phoneLink = {
  ap.role = "external";
  ap.ssid = "PhoneLink";            # the external AP's SSID
  apInterface = "wlp110s0";         # now the laptop's client interface
  proxyHost = "192.168.88.10";      # the phone's DHCP reservation
  ap.rejoin = false;                # the USB watchdog cannot help in a no-USB run
  ap.enable = false;                # no local profile in this role
  ap.uplink = "none";
};
```

`sudo nixos-rebuild switch`. The local AP profile disappears; `phone-ap-up`
should now say the AP is external.

Bring the external AP up, then join it from the laptop. Use a **client** profile
whose name is not the old AP profile, and make it autoconnect:

```sh
sudo nmcli device wifi connect "PhoneLink" password "$PSK" \
  ifname wlp110s0 name phonelink-ext
sudo nmcli connection modify phonelink-ext \
  connection.autoconnect yes connection.autoconnect-priority 100 \
  ipv6.method ignore
```

Move the phone once. If the SSID matches the old AP it may join by itself;
otherwise:

```sh
PHONE_SERIAL=XPLO2EEA0001541 phone-wifi-connect "PhoneLink"
```

## 2. Preflight (still on USB)

Every line must hold before the first reboot:

```sh
iw dev wlp110s0 link                       # external SSID/BSSID
ip -4 addr show wlp110s0                   # 192.168.88.x
ip route                                   # NO default via the AP
ip -6 route                                # no default via the AP
ping -c3 192.168.88.10                     # the phone's reservation

PHONE_SERIAL=XPLO2EEA0001541 adb shell 'cmd wifi status; ip -4 addr; ip route'
# connected to the external SSID, holds 192.168.88.10,
# default via ccmni* (cellular), NOT via wlan0

PHONE_SERIAL=XPLO2EEA0001541 sudo phone-proxy-check   # 192.168.88.10:1081 -> 200
systemctl restart phone-tun
systemctl is-active phone-tun
curl -sS --interface 172.19.0.1 -o /dev/null -w '%{http_code}\n' https://example.com
PHONE_SERIAL=XPLO2EEA0001541 sudo phone-doctor
```

`phone-doctor` must say `ap role: external`, `external ap link: client of …`,
and `ap station: phone 192.168.88.10 on …`. The proxy, tunnel and boot checks
must still pass.

## 3. The three runs

For each run, **unplug USB first** and keep it unplugged through the reboot and
the evidence capture. If you need phone-side evidence after boot, use adb over
Wi-Fi (`adb connect 192.168.88.10:5555`, or let mDNS find it); do not plug the
cable back in during a run.

```sh
mkdir -p /tmp/external-ap-37/run$N
date -Is > /tmp/external-ap-37/run$N/before.txt
nmcli device status >> /tmp/external-ap-37/run$N/before.txt
iw dev wlp110s0 link >> /tmp/external-ap-37/run$N/before.txt
ip route >> /tmp/external-ap-37/run$N/before.txt
# record the phone's MAC in the AP station/lease table before the reboot

sudo systemctl reboot
```

After the reboot, record:

```sh
boot=$(date -d "$(uptime -s)" +%s)
tun=$(date -d "$(systemctl show -p ActiveEnterTimestamp --value phone-tun)" +%s)
echo "tunnel +$((tun-boot))s after boot"

nmcli device status
iw dev wlp110s0 link
ip -4 addr show wlp110s0
ip route; ip -6 route
systemctl is-active phone-tun
curl -sS --interface 172.19.0.1 -o /dev/null -w '%{http_code} %{time_total}s\n' https://example.com
PHONE_SERIAL=192.168.88.10:5555 sudo phone-doctor
adb devices -l          # no `usb:` line for the phone
```

On the AP, check the station/lease table: the phone's MAC must have stayed
associated through the laptop reboot, and the lease must still be
`192.168.88.10`. Repeat three times without reconnecting USB.

### Evidence table for #37

| run | USB unplugged | phone MAC on AP before / after | laptop IP | tunnel active after boot | proxy 200 | doctor |
|---|---|---|---|---|---|---|
| 1 | yes | | | s | | |
| 2 | yes | | | s | | |
| 3 | yes | | | s | | |

Also record the AP model/firmware, the DHCP reservation, the NixOS diff above,
and one `ip route` from the phone showing the cellular default. Attach the three
`before.txt`/after files to the issue. Close #37 only after three consecutive
passes.

## Reading a failure

- **Phone missing from the AP after reboot.** The AP stayed up, so this is
  Android dropping the association (the #33 class), not a laptop failure. The
  external AP does not fix auto-join; record it and keep #37 open. A Wi-Fi lock
  or an app-side rejoin is a different fix.
- **AP link up, tunnel later than 30 s.** Collect
  `journalctl -b -u NetworkManager -u phone-tun -u phone-tun-toggle` and
  `systemd-analyze critical-chain`. The usual causes are client autoconnect or
  the tunnel starting before the Wi-Fi route; that is a real finding for #37.
- **Phone has the reservation but the proxy does not answer.** Check the app's
  SSID gate, `auto_start`, and `phone-proxy-check`; the AP is not the problem.
- **The laptop has a default route via the AP.** The AP is forwarding or sending
  router/IPv6 options; fix the AP before re-running, or the phone may leave
  cellular.

## Rollback

```nix
phoneLink.ap.role = "local";
phoneLink.ap.enable = true;   # if it was on before
```

`sudo nixos-rebuild switch`, then `sudo phone-ap-up`; the phone rejoins the
laptop AP. Keep the USB tether until the tunnel answers again.
