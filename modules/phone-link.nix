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
          "server": "${cfg.proxyHost}",
          "server_port": ${toString cfg.proxyPort},
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

  toggle = pkgs.writeShellScript "phone-tun-toggle" ''
    set -u
    if ${pkgs.coreutils}/bin/timeout 3 \
        ${pkgs.bash}/bin/bash -c "exec 3<>/dev/tcp/${cfg.proxyHost}/${toString cfg.proxyPort}" 2>/dev/null; then
      exec ${config.systemd.package}/bin/systemctl start phone-tun.service
    fi
    exec ${config.systemd.package}/bin/systemctl stop phone-tun.service
  '';

  relay = pkgs.writeShellScript "phone-socks-relay" ''
    exec ${pkgs.gost}/bin/gost \
      -L socks5://127.0.0.1:${toString cfg.relaySocksPort} \
      -L http://127.0.0.1:${toString cfg.relayHttpPort} \
      -F "socks5://${cfg.proxyUser}:$PHONE_SOCKS_PASS@${cfg.proxyHost}:${toString cfg.proxyPort}"
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

      band = lib.mkOption {
        type = lib.types.str;
        default = "bg";
        description = "802.11 band (bg or a).";
      };

      channel = lib.mkOption {
        type = lib.types.ints.between 1 196;
        default = 1;
        description = "802.11 channel.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "192.168.77.1/24";
        description = "IPv4 address of the AP interface.";
      };
    };

    proxyHost = lib.mkOption {
      type = lib.types.str;
      default = "192.168.77.232";
      description = "Address the phone's SOCKS proxy listens on.";
    };

    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 1080;
      description = "Port of the phone's SOCKS proxy.";
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
      description = "Allow DHCP and DNS from clients of the laptop access point.";
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
              EnvironmentFile = cfg.secretsFile;
              ExecStartPre = "${pkgs.bash}/bin/bash -c '${pkgs.gnused}/bin/sed \"s|@PHONE_SOCKS_PASS@|$PHONE_SOCKS_PASS|\" ${singboxConfig} > /run/phone-tun/config.json'";
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
                autoconnect = false;
                interface-name = cfg.apInterface;
              };
              wifi = {
                mode = "ap";
                ssid = cfg.ap.ssid;
                band = cfg.ap.band;
                channel = cfg.ap.channel;
              };
              wifi-security = {
                key-mgmt = "wpa-psk";
                psk = "$PHONE_AP_PASS";
              };
              ipv4 = {
                method = "shared";
                address1 = cfg.ap.address;
              };
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
            allowedUDPPorts = [
              53
              67
            ];
            allowedTCPPorts = [ 53 ];
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
