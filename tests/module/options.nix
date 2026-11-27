{ lib, fixtures }:
let
  inherit (fixtures)
    on
    off
    fallbackOn
    dedupOn
    apOn
    apNamed
    apAutoconnect
    apNoRejoin
    apNoFirewall
    apHairpin
    apHairpinNoFailOpen
    ;
in
assert lib.assertMsg (
  on.systemd.timers.phone-tun-toggle.timerConfig.OnUnitActiveSec == "5s"
) "the proxy probe must run every 5 s";
assert lib.assertMsg (
  on.systemd.timers.phone-tun-toggle.timerConfig.OnBootSec == "20s"
) "the probe must not fire before the network is up";
assert lib.assertMsg (
  on.systemd.services.phone-tun.serviceConfig.UMask == "0077"
) "the tunnel's generated config must stay root-only";
assert lib.assertMsg (
  on.systemd.services.phone-tun.serviceConfig.RuntimeDirectoryMode == "0700"
) "the tunnel's runtime directory must stay root-only";
assert lib.assertMsg (
  on.phoneLink.effectiveProxyHosts == [ "10.9.9.9" ]
) "proxyHost must be the only effective host by default";
assert lib.assertMsg (
  fallbackOn.phoneLink.effectiveProxyHosts == [
    "10.9.9.9"
    "10.23.190.38"
    "10.9.9.8"
  ]
) "proxyHosts must keep their declared order after proxyHost";
assert lib.assertMsg (
  dedupOn.phoneLink.effectiveProxyHosts == [
    "10.9.9.9"
    "10.23.190.38"
    "10.9.9.8"
  ]
) "effectiveProxyHosts must not repeat proxyHost";
assert lib.assertMsg (
  on.networking.firewall.interfaces.wlptest0.allowedUDPPorts == [ 67 ]
) "the AP interface must allow DHCP";
assert lib.assertMsg (
  on.networking.firewall.interfaces.wlptest0.allowedTCPPorts == [ ]
) "the AP must not open DNS over TCP";
assert lib.assertMsg (
  !(lib.elem "multi-user.target" on.systemd.services.phone-tun.wantedBy)
) "the tunnel must never start at boot";
assert lib.assertMsg (
  !(on.systemd.services ? phone-socks-relay)
) "the relay must stay off unless enableRelay is set";
assert lib.assertMsg (lib.any (
  rule: lib.hasPrefix "d /run/phone-link " rule
) on.systemd.tmpfiles.rules) "the runtime port directory must survive a stopped tunnel";
assert lib.assertMsg (lib.any (
  rule: rule == "f+ /run/phone-link/proxy-port 0644 root root - 1081"
) on.systemd.tmpfiles.rules) "the runtime port file must be seeded from proxyPort";
assert lib.assertMsg (lib.hasInfix "PHONE_AP_IF=wlptest0"
  on.environment.etc."phone-link/env".text
) "apInterface must reach the module configuration";
assert lib.assertMsg (lib.hasInfix "PHONE_PROXY_HOST=10.9.9.9"
  on.environment.etc."phone-link/env".text
) "proxyHost must reach the module configuration";
assert lib.assertMsg (lib.hasInfix "PHONE_PROXY_PORT=1081"
  on.environment.etc."phone-link/env".text
) "proxyPort must reach the module configuration";
assert lib.assertMsg (lib.hasInfix "PHONE_RUNTIME_PORT_FILE=/run/phone-link/proxy-port"
  on.environment.etc."phone-link/env".text
) "the runtime port file must reach the module configuration";
assert lib.assertMsg (lib.any
  (line: lib.hasPrefix "PHONE_NFT=" line && lib.hasSuffix "/bin/nft" line)
  (lib.splitString "\n" on.environment.etc."phone-link/env".text)
) "the nft binary the AP unit runs must reach the doctor";
assert lib.assertMsg (lib.hasInfix "PHONE_AP_CON=testlink"
  apNamed.environment.etc."phone-link/env".text
) "ap.name must reach the module configuration";
assert lib.assertMsg (lib.hasInfix "PHONE_AP_SSID='Test Link'"
  apNamed.environment.etc."phone-link/env".text
) "ap.ssid must reach the module configuration";
assert lib.assertMsg (lib.hasInfix "PHONE_AP_ADDRESS=192.168.98.1/24"
  apNamed.environment.etc."phone-link/env".text
) "ap.address must reach the module configuration";
assert lib.assertMsg (lib.hasInfix "PHONE_PROXY_USER=linkuser"
  apNamed.environment.etc."phone-link/env".text
) "proxyUser must reach the module configuration";
assert lib.assertMsg (lib.hasInfix "PHONE_SECRETS=/etc/nixos/other-secrets"
  apNamed.environment.etc."phone-link/env".text
) "secretsFile must reach the module configuration";
assert lib.assertMsg (
  apNamed.environment.etc."phone-link/ap-profile".text == "testlink"
) "the declarative profile marker must name the configured AP";
assert lib.assertMsg (
  apNamed.networking.networkmanager.ensureProfiles.profiles ? testlink
) "a non-default ap.name must be the declared profile";
assert lib.assertMsg (lib.hasInfix "1.1.1.1"
  on.environment.etc."resolv.conf".text
) "manageResolver must pin resolv.conf";
assert lib.assertMsg (
  !(off.systemd.services ? phone-tun)
) "the module must define nothing unless enabled";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.profiles ? phonelink
) "ap.enable must declare the phonelink profile";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.wifi-security.psk
  == "$PHONE_AP_PASS"
) "the AP profile must keep the PSK out of the store";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.environmentFiles
  == [ "/etc/nixos/phone-socks-secrets" ]
) "the AP profile must read the secrets file";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.wifi.ssid == "TestLink"
) "ap.ssid must reach the profile";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.connection.autoconnect == false
) "the AP must stay down until phone-ap-up by default";
assert lib.assertMsg (
  apAutoconnect.networking.networkmanager.ensureProfiles.profiles.phonelink.connection.autoconnect
  == true
) "ap.autoconnect must reach the profile";
assert lib.assertMsg (
  apAutoconnect.networking.networkmanager.ensureProfiles.profiles.phonelink.ipv4.method == "manual"
) "ap.autoconnect must not change the link-only IPv4 method";
assert lib.assertMsg (
  !(apAutoconnect.networking.networkmanager.ensureProfiles.profiles.phonelink.ipv4 ? gateway)
) "ap.autoconnect must not install a default gateway";
assert lib.assertMsg (
  !(apAutoconnect.networking.networkmanager.ensureProfiles.profiles.phonelink.ipv4 ? dns)
) "ap.autoconnect must not advertise DNS";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.ipv4.address1 == "192.168.99.1/24"
) "ap.address must reach the profile";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.ipv4.method == "manual"
) "the AP profile must not use NetworkManager's shared (NAT/forwarding) method";
assert lib.assertMsg (
  !(apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.ipv4 ? gateway)
) "the AP profile must not install a default gateway";
assert lib.assertMsg (
  !(apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.ipv4 ? dns)
) "the AP profile must not advertise DNS";
assert lib.assertMsg (
  apOn.systemd.services ? phone-link-ap-dhcp
) "ap.enable must run its own DHCP server";
assert lib.assertMsg
  (lib.hasInfix "--port=0" apOn.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
  "the AP's dnsmasq must serve DHCP only, not DNS";
assert lib.assertMsg
  (lib.hasInfix "--dhcp-range=192.168.99.10,192.168.99.254,3600" apOn.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
  "the DHCP range must follow ap.address";
assert lib.assertMsg
  (lib.hasInfix "--dhcp-option=option:router" apOn.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
  "the DHCP server must not send a router option";
assert lib.assertMsg
  (lib.hasInfix "--dhcp-option=option:dns-server" apOn.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
  "the DHCP server must not send a DNS option";
assert lib.assertMsg
  (lib.hasInfix "--interface=wlp110s0" apOn.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
  "the DHCP server must listen on the AP interface";
assert lib.assertMsg
  (lib.hasInfix "--conf-dir=/etc/NetworkManager/dnsmasq-shared.d" apOn.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
  "the DHCP server must read the existing dhcp-host reservations";
assert lib.assertMsg (lib.hasInfix "iifname \"wlp110s0\" drop" apOn.phoneLink.ap.noForwardRules)
  "the AP must drop forwarded traffic";
assert lib.assertMsg (
  apOn.systemd.services ? phone-link-ap-noforward
) "ap.enable must install the AP forward drop";
assert lib.assertMsg (
  apNoFirewall.systemd.services ? phone-link-ap-noforward
) "the AP forward drop must not depend on networking.firewall.enable";
assert lib.assertMsg (
  apOn.phoneLink.ap.uplink == "none"
) "the AP must stay link-only unless uplink is set";
assert lib.assertMsg (
  apOn.phoneLink.ap.forwardClient == apOn.phoneLink.proxyHost
) "forwardClient must default to the proxy host";
assert lib.assertMsg (
  apOn.phoneLink.ap.forwardRules == apOn.phoneLink.ap.noForwardRules
) "uplink = none must keep the plain forward drop";
assert lib.assertMsg (
  apOn.phoneLink.ap.hairpinRules == ""
) "uplink = none must not masquerade anything";
assert lib.assertMsg (
  !(lib.hasInfix "ip saddr" apOn.phoneLink.ap.forwardRules)
) "uplink = none must not accept any AP client";
assert lib.assertMsg (
  !(lib.hasInfix "phone_link_hairpin" apOn.phoneLink.ap.ruleset)
) "uplink = none must not install the hairpin table";
assert lib.assertMsg
  (lib.hasInfix ''iifname "wlp110s0" ip saddr 192.168.77.232 accept'' apHairpin.phoneLink.ap.forwardRules)
  "uplink = tunnel must accept the configured client";
assert lib.assertMsg (lib.hasInfix ''iifname "wlp110s0" drop'' apHairpin.phoneLink.ap.forwardRules)
  "uplink = tunnel must keep dropping every other AP client";
assert lib.assertMsg (
  builtins.match ".*accept.*drop.*" (
    lib.replaceStrings [ "\n" ] [ " " ] apHairpin.phoneLink.ap.forwardRules
  ) != null
) "the accept must come before the drop";
assert lib.assertMsg
  (lib.hasInfix "table ip phone_link_hairpin" apHairpin.phoneLink.ap.hairpinRules)
  "uplink = tunnel must install a separate nat table";
assert lib.assertMsg
  (lib.hasInfix ''oifname "phone-tun" ip saddr 192.168.77.232 masquerade'' apHairpin.phoneLink.ap.hairpinRules)
  "the masquerade must be scoped to the client and the tunnel";
assert lib.assertMsg (
  !(lib.hasInfix "192.168.99.0/24" apHairpin.phoneLink.ap.hairpinRules)
) "the masquerade must not be a general AP NAT";
assert lib.assertMsg
  (lib.hasInfix "--dhcp-option=option:router,192.168.99.1" apHairpin.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
  "uplink = tunnel must send the AP address as the router";
assert lib.assertMsg
  (lib.hasInfix "--dhcp-option=option:dns-server,9.9.9.9" apHairpin.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
  "uplink = tunnel must send uplinkDns as the resolver";
assert lib.assertMsg (
  !(lib.hasInfix "--dhcp-option=option:router," apOn.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
) "uplink = none must not send a router value";
assert lib.assertMsg (
  !(lib.hasInfix "--dhcp-option=option:dns-server," apOn.systemd.services.phone-link-ap-dhcp.serviceConfig.ExecStart)
) "uplink = none must not send a resolver value";
assert lib.assertMsg (apHairpin.boot.kernel.sysctl."net.ipv4.ip_forward"
) "uplink = tunnel must enable forwarding";
assert lib.assertMsg (
  !(apOn.boot.kernel.sysctl ? "net.ipv4.ip_forward")
) "uplink = none must not change ip_forward";
assert lib.assertMsg (
  apHairpin.networking.firewall.extraForwardRules == ""
) "the hairpin must not add NixOS firewall forward rules";
assert lib.assertMsg (
  !(on.systemd.services ? phone-link-ap-dhcp)
) "the AP DHCP server must be opt-in";
assert lib.assertMsg (
  !(on.systemd.services ? phone-link-ap-noforward)
) "the AP forward drop must be opt-in";
assert lib.assertMsg (
  !(on.systemd.services ? phone-link-ap-rejoin)
) "the rejoin watchdog must be opt-in with ap.enable";
assert lib.assertMsg (
  apOn.systemd.services ? phone-link-ap-rejoin
) "ap.enable must define the rejoin watchdog by default";
assert lib.assertMsg (
  apOn.systemd.services.phone-link-ap-rejoin.serviceConfig.Type == "oneshot"
) "the rejoin watchdog must be a oneshot";
assert lib.assertMsg (
  apOn.systemd.services.phone-link-ap-rejoin.serviceConfig.EnvironmentFile
  == "/etc/nixos/phone-socks-secrets"
) "the rejoin watchdog must read the PSK from the secrets file";
assert lib.assertMsg (
  apOn.systemd.timers.phone-link-ap-rejoin.timerConfig.OnUnitActiveSec == "30s"
) "the rejoin watchdog must tick every 30 s";
assert lib.assertMsg (
  apOn.systemd.timers.phone-link-ap-rejoin.timerConfig.OnBootSec == "45s"
) "the rejoin watchdog must wait for the AP to come up";
assert lib.assertMsg (
  !(apNoRejoin.systemd.services ? phone-link-ap-rejoin)
) "ap.rejoin = false must not define the rejoin watchdog";
assert lib.assertMsg (
  !(apNoRejoin.systemd.timers ? phone-link-ap-rejoin)
) "ap.rejoin = false must not define the rejoin timer";
assert lib.assertMsg (
  !(on.systemd.services ? phone-link-ap-failopen)
) "the fail-open watchdog must stay off unless enabled";
assert lib.assertMsg (apHairpin.phoneLink.apFailOpen.enable
) "uplink = tunnel must enable fail-open by default";
assert lib.assertMsg (
  apHairpin.systemd.services ? phone-link-ap-failopen
) "uplink = tunnel must define the fail-open watchdog";
assert lib.assertMsg (
  apHairpin.phoneLink.apFailOpen.client == "192.168.77.232"
) "fail-open must follow the hairpin's forwardClient";
assert lib.assertMsg (
  apHairpinNoFailOpen.phoneLink.apFailOpen.enable == false
) "an explicit apFailOpen.enable = false must win over the hairpin default";
assert lib.assertMsg (
  !(apHairpinNoFailOpen.systemd.services ? phone-link-ap-failopen)
  && !(apHairpinNoFailOpen.systemd.timers ? phone-link-ap-failopen)
) "apFailOpen.enable = false must define neither unit nor timer";
assert lib.assertMsg (
  apHairpin.systemd.timers.phone-link-ap-failopen.timerConfig.OnUnitActiveSec == "5s"
) "the fail-open watchdog must tick every 5 s";
assert lib.assertMsg (
  apHairpin.systemd.timers.phone-link-ap-failopen.timerConfig.OnBootSec == "30s"
) "the fail-open watchdog must wait for the AP to come up";
assert lib.assertMsg (lib.hasInfix "PHONE_AP_CLIENT=192.168.77.232" (
  builtins.readFile apHairpin.systemd.services.phone-link-ap-failopen.serviceConfig.ExecStart
)) "the fail-open watchdog must bind the configured client";
assert lib.assertMsg (lib.hasInfix "PHONE_AP_HAIRPIN_RULES=/nix/store/" (
  builtins.readFile apHairpin.systemd.services.phone-link-ap-failopen.serviceConfig.ExecStart
)) "the fail-open watchdog must bind the merged ruleset";
assert lib.assertMsg (lib.hasInfix "PHONE_AP_NOFORWARD_RULES=/nix/store/" (
  builtins.readFile apHairpin.systemd.services.phone-link-ap-failopen.serviceConfig.ExecStart
)) "the fail-open watchdog must bind the no-forward rules";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.wifi.band == "a"
) "the AP must default to 5 GHz";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.wifi.channel == 149
) "the AP must default to the non-DFS 5 GHz channel 149";
assert lib.assertMsg (
  apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.wifi."channel-width" == 80
) "the AP must default to 80 MHz";
assert lib.assertMsg
  (lib.hasInfix "phonelink.nmconnection" apOn.systemd.services.NetworkManager-ensure-profiles.script)
  "ensure-profiles must write the AP keyfile";
assert lib.assertMsg
  (lib.hasInfix "phonelink.nmconnection" apOn.systemd.services.NetworkManager-ensure-profiles.preStart)
  "ensure-profiles must migrate a hand-made profile";
assert lib.assertMsg (
  !(on.networking.networkmanager.ensureProfiles.profiles ? phonelink)
) "the AP profile must be opt-in";
true
