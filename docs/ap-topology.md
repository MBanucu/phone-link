# Which device hosts the AP

The link between the laptop and the phone can be built three ways. They use the
same proxy address, the same link-only rules and the same tunnel; what differs
is who owns the access point and what happens when the laptop reboots.

| topology | who is the AP | laptop role | survives a laptop reboot? | extra hardware |
|---|---|---|---|---|
| **Laptop-local AP** (current default) | this laptop, `phoneLink.ap.role = "local"` | AP and tunnel endpoint | no: the AP disappears with the laptop, and Android may not auto-join the link-only AP again (#33) | none |
| **External always-on AP** (`#37`) | a separate always-on box, `phoneLink.ap.role = "external"` | Wi-Fi client of that AP | yes: the AP never reboots with the laptop; the laptop re-joins it like any other Wi-Fi network | one AP-class device, and a second radio or Ethernet if the laptop needs another network at the same time |
| **Phone hotspot** (`#38`) | the phone | Wi-Fi client of the phone | yes in principle: the phone's hotspot stays up | none, but the app must allow its listener while the phone is the hotspot, the hotspot must be kept on, and battery use is higher |

## Why the external AP is the only one that removes the failure

A laptop reboot is a local-AP reboot. The phone loses the association, and on
this ROM (Blackview XPLORE 2, Android 15) the link-only AP is marked "no
internet" and the saved network is temporarily disabled from auto-join; the
phone can stay away for the temporary-disable window even though it is sitting
on the desk (#33). The rejoin watchdog narrows that to seconds when USB is
available, but it is a recovery, not an absence of the failure.

An external AP that stays powered through the laptop's reboot never sends the
deauthentication in the first place. The laptop comes back as a client, and the
existing 5 s tunnel probe starts `phone-tun` as soon as the proxy answers. That
is the only topology in the comparison that removes the failure mode rather
than working around it.

The phone-hotspot topology also survives a laptop reboot, but it is not a
software-only switch today:

- the current `org.phonelink.proxy` only opens its listener while the phone is a
  **client of the configured SSID**, so it deliberately refuses the hotspot
  path; the app needs a hotspot allowance (or `any_network`) first (#38);
- Android's "turn off hotspot automatically" must be disabled and the user has
  to enable tethering once; a normal app cannot enable it;
- the hotspot costs more battery than a station association, and the phone
  advertises an internet-capable AP, so its validation succeeds and the
  laptop's traffic can bypass the proxy unless the tunnel is kept.

For those reasons #38 stays open. The decision recorded here is that the
external AP is the supported always-on topology for now; the hotspot is a
separate app-side change, not a fallback this module can promise.

## What the external AP must be

The AP must remain a **link only**. It is not an uplink, not a router and not an
internet-sharing hotspot. These invariants are the same ones the local AP
enforces (`docs/phone-network.md`), just on someone else's firmware:

- **No NAT and no uplink.** Forwarded traffic from the phone must not reach the
  internet through the AP, or Android will validate the Wi-Fi and take the
  phone's default route away from mobile data. Keep the AP's WAN/uplink
  disconnected or firewalled, and do not enable router/NAT mode.
- **No DHCP router option and no DNS option.** The phone must stay unvalidated
  so it keeps cellular as its default. If the firmware insists on a gateway,
  prefer a DHCP-only server or a static address on the phone; do not advertise
  the AP as a router.
- **No forwarding.** Drop forwarded packets entering the AP's client bridge.
  A plain bridged AP with no uplink usually satisfies this; a travel router in
  router mode does not.
- **A DHCP reservation for the phone.** `phoneLink.proxyHost` must be the
  address the phone always gets on the external AP. Without the reservation the
  address can change and the tunnel, adb and sshfs lose their target. Set
  `proxyHost` to the reserved address; `proxyHosts` still works for a USB
  fallback.
- **The same SSID and PSK** you put in `phoneLink.ap.ssid` and
  `PHONE_AP_PASS`. The rejoin watchdog uses them to nudge the phone back over
  USB adb.
- **WPA2-PSK** (the app's SSID gate and `phone-wifi-connect` assume it).

An OpenWrt box, a travel router in bridge/AP mode, or a Raspberry Pi with
`hostapd` and a DHCP-only `dnsmasq` all work. The laptop does not manage any of
them; document the box's own configuration outside this repository.

## Laptop as a client

With `phoneLink.ap.role = "external"` the module creates no AP profile, no
DHCP server, no nftables tables and no AP firewall hole. The laptop's Wi-Fi
interface is a normal client:

1. Configure the external AP's Wi-Fi in NetworkManager (or the desktop's
   network settings) as an ordinary WPA2 client, with autoconnect on. It must
   not be an AP-mode profile.
2. Give it the reserved address for the phone in `phoneLink.proxyHost`, e.g.:

   ```nix
   phoneLink = {
     enable = true;
     proxyHost = "192.168.50.20";   # the phone's reservation on the external AP

     ap = {
       role = "external";
       ssid = "BoatLink";           # the external AP's SSID
       # apInterface is the laptop's client interface, wlp110s0 by default
       # ap.enable is not needed: this host owns no AP profile.
     };
   };
   ```

3. Keep `PHONE_AP_PASS` in `phoneLink.secretsFile`; the rejoin watchdog uses it
   when it nudges the phone back over USB. `ap.rejoin = false` disables the
   watchdog.

The tunnel itself is unchanged: it still probes `proxyHost`, still uses the
5 s toggle, and still starts only when the proxy answers. A laptop reboot
re-joins the external AP and the tunnel returns without the phone ever seeing
the AP go away.

### What the commands and the doctor say

- `phone-ap-up`: with an external AP there is nothing on this host to activate.
  It says so and still asks the rejoin watchdog to nudge the phone back if it is
  away; it does not run `iw` or `nmcli` for an AP profile.
- `phone-ap-down`: says the AP is external and changes nothing; the external AP
  and the laptop's client link stay up. There is no hotspot join in this role.
- `phone-ap-create` / `phone-ap-delete`: no local profile exists to create or
  delete, so they explain the external role and return without touching
  NetworkManager.
- `phone-doctor` reports `ap role: external`, the laptop's client link
  (`external ap link`), and whether the phone holds `proxyHost`
  (`ap station: phone … on …`). A missing client link or a phone that is not on
  the external AP is named with the fix (`join it in NetworkManager`,
  `phone-wifi-connect <ssid>`); it is never reported as "AP is down". The
  proxy, tunnel and boot facts are still checked as before.

## Live acceptance still pending from #37

The software half is what this change implements. The hardware half is still a
live step on the real external AP and is **not** proven by the hermetic tests.
The step-by-step procedure, AP invariants and evidence table are in
[external-ap-acceptance.md](external-ap-acceptance.md):

- reboot the laptop three times with the phone on the external AP and confirm
  the phone stays associated and `phone-tun` starts within 30 s each time, with
  no USB cable;
- confirm on the box that there is no NAT, no DNS option, no uplink and no
  forwarding, and that the phone's internet stays on cellular;
- record the hardware, the DHCP reservation and the laptop's client profile.

Until those runs are recorded, `Refs #37` (not `Closes`) is the honest reference.
