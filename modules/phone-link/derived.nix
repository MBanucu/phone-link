# Values derived from `phoneLink.*` and shared by more than one part of the
# module: runtime paths, the generated sing-box config, the scripts the units
# run, and the nftables rules.  Kept in one file so an option default (for
# example `ap.ruleset`) and the unit that loads it cannot drift apart.
#
# This is a plain function, not a NixOS module: the files under `options/` and
# `config/` import it and take only the values they need, so evaluation stays
# lazy.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.phoneLink;

  # The port the laptop is actually using. `phoneLink.proxyPort` is the default
  # and the value after a reboot; `phone-proxy-switch` (and the panel's port
  # page) writes the chosen one here, and every unit reads it when it starts,
  # so a switch needs no rebuild and no restart of the timer.
  runtimeDir = "/run/phone-link";
  portFile = "${runtimeDir}/proxy-port";
  runtimePort = pkgs.writeShellScript "phone-link-runtime-port" ''
    # $1 is the file, $2 the module's default.
    port=$(${pkgs.coreutils}/bin/cat "$1" 2>/dev/null || true)
    case "$port" in
      [0-9]*) ;;
      *) port=$2 ;;
    esac
    printf '%s' "$port"
  '';

  # The first address is the configured primary; the rest are fallbacks tried
  # in the order they are declared. lib.unique keeps that order and removes a
  # host that is also listed as a fallback.
  effectiveHosts = lib.unique ([ cfg.proxyHost ] ++ cfg.proxyHosts);
  hostFile = "${runtimeDir}/proxy-host";
  pendingHostFile = "${runtimeDir}/proxy-host.pending";
  tunConfigFile = "/run/phone-tun/config.json";

  # The values the commands, the doctor and the live harness share. A plain
  # KEY=VALUE file, no secret in it: the password stays in cfg.secretsFile and
  # is read at run time. The scripts read the environment first, then this
  # file, then their built-in defaults, so a one-off PHONE_* override still
  # works and a non-default phoneLink deployment needs no repeated exports.
  moduleEnv = ''
    PHONE_AP_ROLE=${lib.escapeShellArg cfg.ap.role}
    PHONE_AP_IF=${lib.escapeShellArg cfg.apInterface}
    PHONE_AP_CON=${lib.escapeShellArg cfg.ap.name}
    PHONE_AP_SSID=${lib.escapeShellArg cfg.ap.ssid}
    PHONE_AP_ADDRESS=${lib.escapeShellArg cfg.ap.address}
    PHONE_AP_BAND=${lib.escapeShellArg cfg.ap.band}
    PHONE_AP_CHANNEL=${lib.escapeShellArg (toString cfg.ap.channel)}
    PHONE_AP_CHANNEL_WIDTH=${lib.escapeShellArg (toString cfg.ap.channelWidth)}
    PHONE_AP_DECLARATIVE=${lib.escapeShellArg "/etc/phone-link/ap-profile"}
    # phone-ap-up clears this file before asking the watchdog to run, so the
    # command and the timer share one throttle state.
    PHONE_AP_REJOIN_STATE=${lib.escapeShellArg "${runtimeDir}/ap-rejoin.last"}
    # The AP's no-forward unit runs this binary; the doctor reads the same path
    # because nft is not on PATH for an ordinary user.
    PHONE_NFT=${lib.escapeShellArg "${pkgs.nftables}/bin/nft"}
    PHONE_PROXY_HOST=${lib.escapeShellArg cfg.proxyHost}
    PHONE_PROXY_HOSTS=${lib.escapeShellArg (lib.concatStringsSep " " cfg.proxyHosts)}
    # PHONE_AP_IP is the old name for the phone's address on the AP; the proxy
    # host is what the commands probe, and the pinned adb probe uses it too.
    PHONE_AP_IP=${lib.escapeShellArg cfg.proxyHost}
    PHONE_PROXY_PORT=${toString cfg.proxyPort}
    PHONE_PROXY_USER=${lib.escapeShellArg cfg.proxyUser}
    PHONE_SECRETS=${lib.escapeShellArg cfg.secretsFile}
    PHONE_RUNTIME_DIR=${lib.escapeShellArg runtimeDir}
    PHONE_RUNTIME_PORT_FILE=${lib.escapeShellArg portFile}
  '';

  settings = ''
    {
      "log": { "level": "${cfg.logLevel}", "timestamp": true },
      "dns": {
        "servers": [
          { "type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "phone" }
        ],
        "final": "remote",
        "strategy": "ipv4_only"
      },
      "inbounds": [
        {
          "type": "tun",
          "tag": "tun-in",
          "interface_name": "${cfg.interfaceName}",
          "address": [ "${cfg.tunAddress}" ],
          "mtu": 1400,
          "auto_route": true,
          "stack": "gvisor",
          "route_exclude_address": [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "169.254.0.0/16",
            "127.0.0.0/8"
          ]
        }
      ],
      "outbounds": [
        {
          "type": "socks",
          "tag": "phone",
          "server": "@PHONE_SOCKS_HOST@",
          "server_port": "@PHONE_SOCKS_PORT@",
          "version": "5",
          "username": "${cfg.proxyUser}",
          "password": "@PHONE_SOCKS_PASS@",
          "connect_timeout": "10s"
        },
        { "type": "direct", "tag": "direct" }
      ],
      "route": {
        "auto_detect_interface": true,
        "final": "phone",
        "rules": [
          { "action": "sniff" },
          { "protocol": "dns", "action": "hijack-dns" }
        ]
      }
    }
  '';
  singboxConfig = pkgs.writeText "phone-tun.json" settings;

  # The store config has placeholders for the three things that change at run
  # time: the host actually reachable (the toggle writes it after probing), the
  # port (the panel) and the password (root-only secrets file).  Python rather
  # than sed reads the template as JSON, so the password is never on a command
  # line and any character in it survives; the result is root-only.  The script
  # takes its inputs as arguments so the same generator can be tested against a
  # temporary tree.
  tunConfig = pkgs.writeShellScript "phone-tun-config" ''
    exec ${pkgs.python3}/bin/python3 ${../../lib/phone-tun-config.py} \
      ${singboxConfig} \
      ${tunConfigFile} \
      ${lib.escapeShellArg portFile} \
      ${lib.escapeShellArg hostFile} \
      ${lib.escapeShellArg cfg.proxyHost} \
      ${toString cfg.proxyPort} \
      ${lib.escapeShellArgs effectiveHosts}
  '';

  # Started and restarted by the timer. The logic lives in a plain script so the
  # test suite can run it with stubbed systemctl and probe commands; the module
  # only binds the paths, the declared host order and the binaries.
  toggle = pkgs.writeShellScript "phone-tun-toggle" ''
    export PHONE_TUN_HOSTS=${lib.escapeShellArg (lib.concatStringsSep " " effectiveHosts)}
    export PHONE_TUN_AP_HOST=${lib.escapeShellArg cfg.proxyHost}
    export PHONE_TUN_PORT_FILE=${lib.escapeShellArg portFile}
    export PHONE_TUN_FALLBACK_PORT=${toString cfg.proxyPort}
    export PHONE_TUN_HOST_FILE=${lib.escapeShellArg hostFile}
    export PHONE_TUN_PENDING_FILE=${lib.escapeShellArg pendingHostFile}
    export PHONE_TUN_CONFIG_FILE=${lib.escapeShellArg tunConfigFile}
    export PHONE_TUN_RUNTIME_DIR=${lib.escapeShellArg runtimeDir}
    export PHONE_TUN_SYSTEMCTL=${config.systemd.package}/bin/systemctl
    export PHONE_TUN_UNIT=phone-tun.service
    export PATH=${
      lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        pkgs.iproute2
        pkgs.python3
      ]
    }
    exec ${pkgs.bash}/bin/bash ${../../lib/phone-tun-toggle.sh}
  '';

  # Android marks the link-only AP as "no internet" and temporarily disables
  # auto-join for the saved network, so the phone never returns after the AP
  # restarts.  This re-asserts the association over USB adb instead of making
  # the AP answer the connectivity probe, which would route the phone's traffic
  # through the link-only AP.  The logic is in lib/ so a test can drive it with
  # stub iw/adb/sleep commands; the throttle state lives under /run and is
  # therefore reset by a reboot, where the AP profile is fresh anyway.
  rejoin = pkgs.writeShellScript "phone-link-ap-rejoin" ''
    export PHONE_AP_ROLE=${lib.escapeShellArg cfg.ap.role}
    export PHONE_AP_IF=${lib.escapeShellArg cfg.apInterface}
    export PHONE_AP_SSID=${lib.escapeShellArg cfg.ap.ssid}
    export PHONE_AP_SECURITY=wpa2
    # The external role checks the phone over USB instead of a local station
    # dump, so it needs the address the phone holds on the foreign AP.
    export PHONE_PROXY_HOST=${lib.escapeShellArg cfg.proxyHost}
    export PHONE_AP_REJOIN_STATE=${lib.escapeShellArg "${runtimeDir}/ap-rejoin.last"}
    export PATH=${
      lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        pkgs.iw
        pkgs.android-tools
        pkgs.iproute2
      ]
    }
    exec ${pkgs.bash}/bin/bash ${../../lib/phone-ap-rejoin.sh}
  '';

  relay = pkgs.writeShellScript "phone-socks-relay" ''
    port=$(${runtimePort} ${portFile} ${toString cfg.proxyPort})
    host=$(${pkgs.coreutils}/bin/cat ${hostFile} 2>/dev/null || true)
    # The toggle writes a declared host or a gateway it discovered on the
    # tether; anything else falls back to the configured primary.
    case "$host" in
      ''' | *[!0-9.]* | .* | *. | *..*) host=${lib.escapeShellArg cfg.proxyHost} ;;
      *.*.*.*) ;;
      *) host=${lib.escapeShellArg cfg.proxyHost} ;;
    esac
    exec ${pkgs.gost}/bin/gost \
      -L socks5://127.0.0.1:${toString cfg.relaySocksPort} \
      -L http://127.0.0.1:${toString cfg.relayHttpPort} \
      -F "socks5://${cfg.proxyUser}:$PHONE_SOCKS_PASS@$host:$port"
  '';

  # The AP is a link, not an uplink.  NetworkManager's "shared" method ran
  # dnsmasq with a router and DNS option and installed NAT, which let the phone
  # validate the AP and send its internet traffic through the laptop and back
  # over the same 2.4 GHz link.  The profile is "manual" now: it keeps the
  # address and the connected route, and this dnsmasq answers DHCP only, with
  # no router and no DNS option.  Forwarded traffic from the AP is dropped in
  # its own nftables table, so the rule also holds when the NixOS firewall is
  # disabled and does not depend on its backend.
  #
  # `ap.uplink = "tunnel"` is the opt-in exception: one configured client is
  # accepted into the forward hook and its traffic is routed into phone-tun by
  # the ip rules sing-box already installed, then masqueraded to the TUN
  # address.  The drop stays after the accept, so every other AP client is
  # still cut off.  No ip rule is added for DNS: on the live system
  # `ip route get 1.1.1.1 from 192.168.77.232 iif wlp110s0` already resolves to
  # `via 172.19.0.2 dev phone-tun table 2022`, because rule 9001
  # (`not from all iif lo lookup 2022`) comes before the dport-53-to-main rule.
  # The forwarded DNS packet therefore enters the TUN and sing-box's existing
  # `{"protocol": "dns", "action": "hijack-dns"}` answers it through the
  # remote DoH server; the proxy never sees UDP.  No NixOS firewall rule is
  # added either: the only forward drop in this setup is the table below.
  apAddress = lib.head (lib.splitString "/" cfg.ap.address);
  apSubnet = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." apAddress));
  apNoForwardRules = ''
    table inet phone_link_ap {
      chain forward {
        type filter hook forward priority -10; policy accept;
        iifname "${cfg.apInterface}" drop
      }
    }
  '';
  apForwardRules =
    if cfg.ap.uplink == "tunnel" then
      ''
        table inet phone_link_ap {
          chain forward {
            type filter hook forward priority -10; policy accept;
            iifname "${cfg.apInterface}" ip saddr ${cfg.ap.forwardClient} accept
            iifname "${cfg.apInterface}" drop
          }
        }
      ''
    else
      apNoForwardRules;
  # A separate nat table, so stopping the AP or the fail-open path removes the
  # masquerade without touching a table someone else owns.  Only the one client
  # is translated, and only on the way out of the TUN: the tunnel's own socket
  # to the proxy leaves through the AP interface (192.168.0.0/16 is in the
  # sing-box route_exclude_address list) and must not be NATed here.
  apHairpinRules = lib.optionalString (cfg.ap.uplink == "tunnel") ''
    table ip phone_link_hairpin {
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "${cfg.interfaceName}" ip saddr ${cfg.ap.forwardClient} masquerade
      }
    }
  '';
  apRuleset = apForwardRules + apHairpinRules;
  apNoForwardStop = pkgs.writeShellScript "phone-link-ap-noforward-stop" ''
    ${pkgs.nftables}/bin/nft delete table inet phone_link_ap 2>/dev/null || true
    ${pkgs.nftables}/bin/nft delete table ip phone_link_hairpin 2>/dev/null || true
  '';
in
{
  inherit
    runtimeDir
    portFile
    runtimePort
    effectiveHosts
    hostFile
    pendingHostFile
    tunConfigFile
    moduleEnv
    settings
    singboxConfig
    tunConfig
    toggle
    rejoin
    relay
    apAddress
    apSubnet
    apNoForwardRules
    apForwardRules
    apHairpinRules
    apRuleset
    apNoForwardStop
    ;
}
