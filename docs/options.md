# Module options

Every public `phoneLink` option with its default. `modules/phone-link.nix` is
authoritative: this table is a hand-maintained copy, and the module wins when
they disagree. The fail-open options are declared in
`modules/phone-link-failopen.nix`.

| option | default | meaning |
|---|---|---|
| `phoneLink.enable` | `false` | enable the tunnel, timer and AP firewall holes |
| `phoneLink.apInterface` | `wlp110s0` | interface of the laptop access point, or the client interface with `ap.role = "external"` |
| `phoneLink.ap.role` | `local` | `local` declares and owns the laptop AP; `external` means an always-on AP elsewhere (no local profile, DHCP, nftables rules or firewall hole; the laptop is a client) |
| `phoneLink.ap.enable` | `false` | declare the AP profile from `PHONE_AP_PASS` (requires `phoneLink.enable`); with `role = "external"` it only gates the profile this host does not own, so the rejoin watchdog runs without it |
| `phoneLink.ap.autoconnect` | `false` | let NetworkManager activate the local AP at boot (reserves the radio; a failed 5 GHz activation leaves no link); ignored with an external AP |
| `phoneLink.ap.rejoin` | `true` | re-assert the phone's association over USB adb after an AP restart (30 s timer, 5 min throttle; requires `ap.enable`) |
| `phoneLink.ap.name` | `phonelink` | NetworkManager connection name |
| `phoneLink.ap.ssid` | `PhoneLink` | SSID of the laptop access point; with `role = "external"` the external AP's SSID the rejoin watchdog nudges to |
| `phoneLink.ap.band` / `channel` / `channelWidth` | `a` / `149` / `80` | 802.11 band, channel and AP channel width (5 GHz, non-DFS); local role only |
| `phoneLink.ap.address` | `192.168.77.1/24` | IPv4 address of the local AP interface; local role only |
| `phoneLink.ap.uplink` | `none` | `none` keeps the AP link-only; `tunnel` hairpins one client through `phone-tun` so the AP can validate; must stay `none` with `role = "external"` |
| `phoneLink.ap.forwardClient` | `phoneLink.proxyHost` | the one AP client accepted when `uplink = "tunnel"`; every other source stays dropped (local role only) |
| `phoneLink.ap.uplinkDns` | `1.1.1.1` | DNS advertised to that client when `uplink = "tunnel"`; it is answered by the tunnel, not UDP-over-SOCKS (local role only) |
| `phoneLink.apFailOpen.enable` | `uplink == "tunnel"` | remove the AP hairpin while `phone-tun` is unhealthy; default-on with the hairpin, set `false` to disable |
| `phoneLink.apFailOpen.client` | `phoneLink.ap.forwardClient` | the one AP client the watchdog requires in the hairpin |
| `phoneLink.apFailOpen.grace` / `throttle` | `15` / `30` | healthy seconds before a restore / minimum seconds between restores |
| `phoneLink.ap.dhcpRange` | `.10–.254` of the AP /24, 3600 s | DHCP range and lease time; the AP sends no router or DNS option unless `uplink = "tunnel"` (local role only) |
| `phoneLink.proxyHost` | `192.168.77.232` | primary address of the phone's SOCKS proxy |
| `phoneLink.proxyHosts` | `[]` | additional addresses tried in order after `proxyHost`, e.g. the USB tether; when none answers, default-route gateways and point-to-point peers are probed last |
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
