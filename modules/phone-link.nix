# phone-link: send the laptop's traffic through the phone's SOCKS proxy and, if
# wanted, open the firewall for the laptop access point the phone joins.
#
# The phone is never rooted and nothing here starts a tunnel at boot: a 5 s
# timer probes the proxy port and only keeps the TUN alive while it answers, so
# a missing phone or a stopped proxy app cannot blackhole traffic.
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

  # The values the commands, the doctor and the live harness share. A plain
  # KEY=VALUE file, no secret in it: the password stays in cfg.secretsFile and
  # is read at run time. The scripts read the environment first, then this
  # file, then their built-in defaults, so a one-off PHONE_* override still
  # works and a non-default phoneLink deployment needs no repeated exports.
  moduleEnv = ''
    PHONE_AP_IF=${lib.escapeShellArg cfg.apInterface}
    PHONE_AP_CON=${lib.escapeShellArg cfg.ap.name}
    PHONE_AP_SSID=${lib.escapeShellArg cfg.ap.ssid}
    PHONE_AP_ADDRESS=${lib.escapeShellArg cfg.ap.address}
    PHONE_AP_BAND=${lib.escapeShellArg cfg.ap.band}
    PHONE_AP_CHANNEL=${lib.escapeShellArg (toString cfg.ap.channel)}
    PHONE_AP_CHANNEL_WIDTH=${lib.escapeShellArg (toString cfg.ap.channelWidth)}
    PHONE_AP_DECLARATIVE=${lib.escapeShellArg "/etc/phone-link/ap-profile"}
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
          "password": "@PHONE_SOCKS_PASS@"
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
  # line and any character in it survives; the result is root-only.
  tunConfig = pkgs.writeScript "phone-tun-config" ''
    #!${pkgs.python3}/bin/python3
    import json
    import os
    import tempfile

    template = "${singboxConfig}"
    target = "/run/phone-tun/config.json"
    port_file = "${portFile}"
    host_file = "${hostFile}"
    hosts = ${builtins.toJSON effectiveHosts}
    fallback_host = ${builtins.toJSON cfg.proxyHost}
    fallback_port = ${toString cfg.proxyPort}

    try:
        with open(port_file, encoding="utf-8") as f:
            port = int(f.read().strip())
    except (OSError, ValueError):
        port = fallback_port
    if not 0 < port < 65536:
        port = fallback_port

    try:
        with open(host_file, encoding="utf-8") as f:
            host = f.read().strip()
    except OSError:
        host = fallback_host
    if host not in hosts:
        host = fallback_host

    password = os.environ["PHONE_SOCKS_PASS"]

    with open(template, encoding="utf-8") as f:
        config = json.load(f)
    for outbound in config["outbounds"]:
        if outbound.get("tag") == "phone":
            outbound["server"] = host
            outbound["server_port"] = port
            outbound["password"] = password

    directory = os.path.dirname(target)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".config.", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2)
            f.write("\n")
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
  '';

  toggle = pkgs.writeShellScript "phone-tun-toggle" ''
    set -u
    port=$(${runtimePort} ${portFile} ${toString cfg.proxyPort})
    host=
    for candidate in ${lib.escapeShellArgs effectiveHosts}; do
      if ${pkgs.coreutils}/bin/timeout 3 \
          ${pkgs.bash}/bin/bash -c "exec 3<>/dev/tcp/$candidate/$port" 2>/dev/null; then
        host=$candidate
        break
      fi
    done
    if [ -n "$host" ]; then
      tmp=${runtimeDir}/.proxy-host.$$
      printf '%s\n' "$host" > "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" ${hostFile}
      exec ${config.systemd.package}/bin/systemctl start phone-tun.service
    fi
    exec ${config.systemd.package}/bin/systemctl stop phone-tun.service
  '';

  relay = pkgs.writeShellScript "phone-socks-relay" ''
    port=$(${runtimePort} ${portFile} ${toString cfg.proxyPort})
    host=$(${pkgs.coreutils}/bin/cat ${hostFile} 2>/dev/null || true)
    case "$host" in
      ${lib.concatMapStringsSep "|" (h: lib.escapeShellArg h) effectiveHosts}) ;;
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
  apSubnet = lib.concatStringsSep "." (
    lib.take 3 (lib.splitString "." (lib.head (lib.splitString "/" cfg.ap.address)))
  );
  apNoForwardRules = ''
    table inet phone_link_ap {
      chain forward {
        type filter hook forward priority -10; policy accept;
        iifname "${cfg.apInterface}" drop
      }
    }
  '';
  apNoForwardStop = pkgs.writeShellScript "phone-link-ap-noforward-stop" ''
    ${pkgs.nftables}/bin/nft delete table inet phone_link_ap 2>/dev/null || true
  '';
in
{
  options.phoneLink = {
    enable = lib.mkEnableOption "the phone-link tunnel";

    apInterface = lib.mkOption {
      type = lib.types.str;
      default = "wlp110s0";
      description = "Wireless interface used for the laptop access point.";
    };

    ap = {
      enable = lib.mkEnableOption "the declarative PhoneLink access-point profile";

      name = lib.mkOption {
        type = lib.types.str;
        default = "phonelink";
        description = "NetworkManager connection name.";
      };

      ssid = lib.mkOption {
        type = lib.types.str;
        default = "PhoneLink";
        description = "SSID of the laptop access point.";
      };

      autoconnect = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let NetworkManager activate the AP at boot.  Off by default, so the
          profile stays down until `phone-ap-up` runs.  Turning it on reserves
          the radio for the AP; a 5 GHz activation that fails then leaves no
          link at all (see #7).
        '';
      };

      band = lib.mkOption {
        type = lib.types.enum [
          "a"
          "bg"
        ];
        default = "a";
        description = "802.11 band: a for 5 GHz, bg for 2.4 GHz.";
      };

      channel = lib.mkOption {
        type = lib.types.ints.between 1 196;
        default = 149;
        description = ''
          802.11 channel. 149 is a non-DFS 5 GHz channel that this Intel 8265
          allows for an AP; 36 and 44 are the other usual non-DFS choices, but
          the card's self-managed regulatory domain currently marks them
          "no IR", so they cannot beacon.
        '';
      };

      channelWidth = lib.mkOption {
        type = lib.types.enum [
          0
          20
          40
          80
        ];
        default = 80;
        description = ''
          AP channel width in MHz: 0 (auto), 20, 40 or 80. NetworkManager 1.50+
          exposes this as 802-11-wireless.channel-width; 80 MHz needs an
          explicit channel, and 2.4 GHz can be at most 40 MHz.
        '';
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "192.168.77.1/24";
        description = "IPv4 address of the AP interface.";
      };

      dhcpRange = lib.mkOption {
        type = lib.types.str;
        default = "${apSubnet}.10,${apSubnet}.254,3600";
        description = ''
          dnsmasq DHCP range and lease time, as `start,end,lease`.  The default
          is .10–.254 in the /24 of `address`, for one hour.  This is DHCP only:
          the AP sends no router or DNS option.
        '';
      };

      noForwardRules = lib.mkOption {
        type = lib.types.lines;
        internal = true;
        readOnly = true;
        default = apNoForwardRules;
        description = ''
          nftables rules that drop forwarded traffic entering from the AP
          interface, so the AP cannot become the phone's internet uplink.
        '';
      };
    };

    proxyHost = lib.mkOption {
      type = lib.types.str;
      default = "192.168.77.232";
      description = "Address the phone's SOCKS proxy listens on.";
    };

    proxyHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Additional addresses tried in order after `proxyHost`; e.g. the USB
        tether address `10.23.190.38`.  The first one that answers becomes the
        runtime host until the next probe finds another.
      '';
    };

    effectiveProxyHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      internal = true;
      readOnly = true;
      default = effectiveHosts;
      description = ''
        `proxyHost` followed by `proxyHosts`, in order and without duplicates.
        The scripts and checks read this instead of repeating the merge.
      '';
    };

    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 1080;
      description = ''
        Default port of the phone's SOCKS proxy. `phone-proxy-switch` writes the
        port in use to ${portFile}, which the units and the scripts read; this
        is the value they use until one is chosen, and again after a reboot.
      '';
    };

    proxyUser = lib.mkOption {
      type = lib.types.str;
      default = "proxy";
      description = "Username for the phone's SOCKS proxy.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos/phone-socks-secrets";
      description = ''
        Environment file providing PHONE_SOCKS_PASS.  Keep it outside the Nix
        store, readable by root only.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      internal = true;
      readOnly = true;
      default = singboxConfig;
      description = ''
        Generated sing-box config with the password placeholder.  Read-only, so
        checks and consumers can reference the same file the unit uses.
      '';
    };

    interfaceName = lib.mkOption {
      type = lib.types.str;
      default = "phone-tun";
      description = "Name of the TUN device.";
    };

    tunAddress = lib.mkOption {
      type = lib.types.str;
      default = "172.19.0.1/30";
      description = "Address of the TUN device.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "warn";
    };

    cacheProxyApk = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Download the proxy APK into the ambulance cache during activation, so
        installing or updating the system always leaves a copy that can be
        reinstalled without a network.  Ignored when phone-fix-apk is not on
        the system PATH.
      '';
    };

    manageResolver = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pin /etc/resolv.conf to public resolvers.  Needed because the tunnel
        answers DNS itself and the phone's tether DNS would otherwise loop back
        into the laptop's dnsmasq.
      '';
    };

    openApFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Allow DHCP from clients of the laptop access point.  The AP does not
        serve DNS: the phone keeps LTE as its default and resolves directly
        over it.
      '';
    };

    enableRelay = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run a local SOCKS/HTTP relay for apps that cannot use a TUN.";
    };

    relaySocksPort = lib.mkOption {
      type = lib.types.port;
      default = 1081;
    };

    relayHttpPort = lib.mkOption {
      type = lib.types.port;
      default = 1082;
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.ap.enable || cfg.enable;
          message = "phoneLink.ap.enable requires phoneLink.enable = true";
        }
        {
          assertion = !cfg.ap.enable || config.networking.networkmanager.enable;
          message = "phoneLink.ap.enable requires networking.networkmanager.enable = true";
        }
        {
          assertion = !cfg.ap.enable || cfg.ap.band != "bg" || cfg.ap.channelWidth <= 40;
          message = "phoneLink.ap.channelWidth must be 0, 20 or 40 when phoneLink.ap.band is bg";
        }
      ];
    }
    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          systemd.services.phone-tun = {
            description = "Route all traffic through the phone SOCKS proxy";
            after = [ "network.target" ];
            # Started and stopped by phone-tun-toggle.service, never at boot.
            serviceConfig = {
              RuntimeDirectory = "phone-tun";
              RuntimeDirectoryMode = "0700";
              UMask = "0077";
              EnvironmentFile = cfg.secretsFile;
              ExecStartPre = tunConfig;
              ExecStart = "${pkgs.sing-box}/bin/sing-box run -c /run/phone-tun/config.json";
              Restart = "on-failure";
              RestartSec = 10;
            };
          };

          systemd.services.phone-tun-toggle = {
            description = "Start or stop phone-tun depending on the phone proxy";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = toggle;
            };
          };

          systemd.timers.phone-tun-toggle = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "20s";
              OnUnitActiveSec = "5s";
              AccuracySec = "1s";
            };
          };

          boot.kernelModules = [ "tun" ];

          # `/run/phone-link` holds the port the panel chose. tmpfiles rather
          # than RuntimeDirectory: stopping the tunnel must not forget it. The
          # file is written from phoneLink.proxyPort when tmpfiles runs, so the
          # value the doctor and the scripts read is the module's own after a
          # boot instead of whatever an older run left behind; a switch inside
          # the running boot still wins until the next boot.
          systemd.tmpfiles.rules = [
            "d ${runtimeDir} 0755 root root -"
            "f+ ${portFile} 0644 root root - ${toString cfg.proxyPort}"
          ];

          # One non-secret configuration for the commands, the doctor and the
          # live harness; the environment still wins over it.
          environment.etc."phone-link/env".text = moduleEnv;
        }

        (lib.mkIf cfg.ap.enable {
          # NetworkManager writes the profile to /run at activation.  The PSK is
          # a placeholder in the store and comes from the root-only secrets file
          # through envsubst, so the password is never in a Nix path.
          networking.networkmanager.ensureProfiles = {
            environmentFiles = [ cfg.secretsFile ];
            profiles.${cfg.ap.name} = {
              connection = {
                id = cfg.ap.name;
                type = "wifi";
                autoconnect = cfg.ap.autoconnect;
                interface-name = cfg.apInterface;
              };
              wifi = {
                mode = "ap";
                ssid = cfg.ap.ssid;
                band = cfg.ap.band;
                channel = cfg.ap.channel;
              }
              // lib.optionalAttrs (cfg.ap.channelWidth != 0) {
                # 0 is NetworkManager's "auto"; leave the key out rather than
                # writing a value older NetworkManagers do not know.
                "channel-width" = cfg.ap.channelWidth;
              };
              wifi-security = {
                key-mgmt = "wpa-psk";
                psk = "$PHONE_AP_PASS";
              };
              ipv4 = {
                method = "manual";
                address1 = cfg.ap.address;
              };
            };
          };

          # DHCP only: this replaces NetworkManager's shared dnsmasq, which
          # also sent a router and DNS option and installed NAT.  It reads the
          # same root-only drop-in directory NetworkManager used, so a
          # `dhcp-host` reservation there keeps the phone's address.
          systemd.services.phone-link-ap-dhcp = {
            description = "DHCP for the PhoneLink access point (no uplink)";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            serviceConfig = {
              ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0755 /etc/NetworkManager/dnsmasq-shared.d";
              ExecStart = lib.concatStringsSep " " [
                "${pkgs.dnsmasq}/bin/dnsmasq"
                "--keep-in-foreground"
                "--conf-file=/dev/null"
                "--bind-dynamic"
                "--interface=${cfg.apInterface}"
                "--except-interface=lo"
                "--port=0"
                "--dhcp-range=${cfg.ap.dhcpRange}"
                "--dhcp-leasefile=/var/lib/phone-link/dnsmasq-${cfg.apInterface}.leases"
                "--dhcp-option=option:router"
                "--dhcp-option=option:dns-server"
                "--conf-dir=/etc/NetworkManager/dnsmasq-shared.d"
              ];
              StateDirectory = "phone-link";
              Restart = "always";
              RestartSec = 5;
            };
          };

          # The AP's own nftables table, not `firewall.extraForwardRules`:
          # that option only exists while the NixOS firewall is enabled, and
          # this drop has to hold either way.  priority -10 runs before the
          # filter chains, including the accept rule NetworkManager installs
          # for a shared connection.
          systemd.services.phone-link-ap-noforward = {
            description = "Drop forwarded traffic from the PhoneLink access point";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${pkgs.nftables}/bin/nft -f ${pkgs.writeText "phone-link-ap-noforward.nft" apNoForwardRules}";
              ExecStop = apNoForwardStop;
            };
          };

          # Remove a persistent profile left by phone-ap-create, so enabling
          # phoneLink.ap does not leave two profiles with the same name.
          systemd.services.NetworkManager-ensure-profiles.preStart = ''
            rm -f -- ${lib.escapeShellArg "/etc/NetworkManager/system-connections/${cfg.ap.name}.nmconnection"}
          '';

          # Lets the scripts tell a declarative profile from a hand-made one.
          environment.etc."phone-link/ap-profile".text = cfg.ap.name;
        })

        (lib.mkIf cfg.cacheProxyApk {
          # Runs on every switch/boot-time activation, not at build time: a Nix
          # derivation cannot download, and the cache must follow the newest
          # F-Droid version.
          system.activationScripts.phone-apk-cache = {
            text = ''
              if [ -x "${config.system.path}/bin/phone-fix-apk" ]; then
                "${config.system.path}/bin/phone-fix-apk" --refresh >&2 || true
              fi
            '';
          };
        })

        (lib.mkIf cfg.manageResolver {
          networking.networkmanager.dns = "none";
          networking.resolvconf.enable = false;
          environment.etc."resolv.conf".text = ''
            nameserver 1.1.1.1
            nameserver 9.9.9.9
          '';
        })

        (lib.mkIf cfg.openApFirewall {
          networking.firewall.interfaces.${cfg.apInterface} = {
            allowedUDPPorts = [ 67 ];
          };
        })

        (lib.mkIf cfg.enableRelay {
          systemd.services.phone-socks-relay = {
            description = "SOCKS5/HTTP relay to the phone proxy";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            serviceConfig = {
              EnvironmentFile = cfg.secretsFile;
              ExecStart = relay;
              Restart = "always";
              RestartSec = 5;
            };
          };
        })
      ]
    ))
  ];
}
