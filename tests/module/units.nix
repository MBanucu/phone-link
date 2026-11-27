{ pkgs, fixtures }:
let
  inherit (fixtures)
    on
    relayOn
    fallbackOn
    apOn
    apHairpin
    tunnelConfig
    ;
in
pkgs.runCommand "phone-link-module-check" { } ''
  grep -q '"server": "@PHONE_SOCKS_HOST@"' ${tunnelConfig}
  grep -q '"server_port": "@PHONE_SOCKS_PORT@"' ${tunnelConfig}
  grep -q '"interface_name": "phone-tun"' ${tunnelConfig}
  grep -q '"password": "@PHONE_SOCKS_PASS@"' ${tunnelConfig}
  grep -qF 'sing-box run -c /run/phone-tun/config.json' \
    ${pkgs.writeText "phone-tun-exec-start" on.systemd.services.phone-tun.serviceConfig.ExecStart}
  # The port is not baked into the units: each one reads the file the
  # panel writes, with phoneLink.proxyPort as its fallback.
  grep -qF '/run/phone-link/proxy-port' \
    ${on.systemd.services.phone-tun.serviceConfig.ExecStartPre}
  grep -qF 'PHONE_TUN_PORT_FILE=/run/phone-link/proxy-port' \
    ${on.systemd.services.phone-tun-toggle.serviceConfig.ExecStart}
  grep -qF 'PHONE_TUN_FALLBACK_PORT=1081' \
    ${on.systemd.services.phone-tun-toggle.serviceConfig.ExecStart}
  grep -qF '/run/phone-link/proxy-port 1080' \
    ${relayOn.systemd.services.phone-socks-relay.serviceConfig.ExecStart}
  # The toggle probes in declared order and records the winner for
  # phone-tun-config and the relay.
  toggle=${fallbackOn.systemd.services.phone-tun-toggle.serviceConfig.ExecStart}
  grep -qF '/run/phone-link/proxy-host' "$toggle"
  grep -qF "PHONE_TUN_HOSTS='10.9.9.9 10.23.190.38 10.9.9.8'" "$toggle"
  grep -qF 'phone-tun.service' "$toggle"
  # The rejoin watchdog binds the configured SSID and the runtime
  # throttle file; adb comes from its PATH, not an absolute path.
  rejoin=${apOn.systemd.services.phone-link-ap-rejoin.serviceConfig.ExecStart}
  grep -qF 'PHONE_AP_SSID=TestLink' "$rejoin"
  grep -qF 'PHONE_AP_REJOIN_STATE=/run/phone-link/ap-rejoin.last' "$rejoin"
  grep -qF 'android-tools' "$rejoin"
  # The hairpin ruleset is exactly what the unit loads: the accept
  # comes before the drop, and the NAT is a separate scoped table.
  hairpin=${pkgs.writeText "phone-link-ap-hairpin.nft" apHairpin.phoneLink.ap.ruleset}
  grep -qF 'iifname "wlp110s0" ip saddr 192.168.77.232 accept' "$hairpin"
  grep -qF 'iifname "wlp110s0" drop' "$hairpin"
  grep -qF 'table ip phone_link_hairpin' "$hairpin"
  grep -qF 'oifname "phone-tun" ip saddr 192.168.77.232 masquerade' "$hairpin"
  accept_line=$(grep -nF 'ip saddr 192.168.77.232 accept' "$hairpin" | cut -d: -f1)
  drop_line=$(grep -nF 'iifname "wlp110s0" drop' "$hairpin" | cut -d: -f1)
  test -n "$accept_line" -a -n "$drop_line" -a "$accept_line" -lt "$drop_line"
  # DNS needs no ip rule: rule 9001 already sends the forwarded
  # packet into table 2022/phone-tun (measured with
  # `ip route get 1.1.1.1 from 192.168.77.232 iif wlp110s0`), and
  # sing-box's hijack-dns answers port 53 there.  The DHCP DNS
  # option and the hijack are the whole DNS path.
  grep -q '"action": "hijack-dns"' ${tunnelConfig}
  grep -q '"type": "https"' ${tunnelConfig}
  touch $out
''
