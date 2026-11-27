# Fail-open watchdog for the PhoneLink AP hairpin.
#
# Kept in its own module so the hairpin change stays additive and so the
# watchdog is easy to review on its own: import it next to
# `modules/phone-link.nix` (the flake's default module does) and enable it.  It
# only touches the two tables in the #42 interface contract: `inet
# phone_link_ap` and `ip phone_link_hairpin`.  It does not own the AP profile,
# the DHCP unit or the rules; it renders the merged `ap.ruleset` and
# `ap.noForwardRules` into the files the script loads.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.phoneLink;
  failOpen = cfg.apFailOpen;

  # The healthy rules are exactly what the AP forward unit loads: the client
  # accept, the drop for every other source, and the scoped masquerade.  The
  # unhealthy rules are the plain drop the link-only AP installs.
  noForwardRules = pkgs.writeText "phone-link-ap-noforward.nft" cfg.ap.noForwardRules;
  healthyRules = pkgs.writeText "phone-link-ap-ruleset.nft" cfg.ap.ruleset;

  failOpenScript = pkgs.writeShellScript "phone-ap-failopen" ''
    export PHONE_AP_IF=${lib.escapeShellArg cfg.apInterface}
    export PHONE_AP_CLIENT=${lib.escapeShellArg failOpen.client}
    export PHONE_AP_TUN_IF=${lib.escapeShellArg cfg.interfaceName}
    export PHONE_NFT=${lib.escapeShellArg "${pkgs.nftables}/bin/nft"}
    export PHONE_AP_SYSTEMCTL=${config.systemd.package}/bin/systemctl
    export PHONE_TUN_UNIT=phone-tun.service
    export PHONE_AP_FAILOPEN_STATE=/run/phone-link/ap-failopen.state
    export PHONE_AP_NOFORWARD_RULES=${lib.escapeShellArg (toString noForwardRules)}
    export PHONE_AP_HAIRPIN_RULES=${lib.escapeShellArg (toString healthyRules)}
    export PHONE_AP_FAILOPEN_GRACE=${toString failOpen.grace}
    export PHONE_AP_FAILOPEN_THROTTLE=${toString failOpen.throttle}
    export PHONE_AP_FAILOPEN_REQUIRE_HAIRPIN=1
    export PHONE_AP_FAILOPEN_NAT=${if failOpen.nat then "1" else "0"}
    export PATH=${
      lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        pkgs.iproute2
        pkgs.nftables
      ]
    }
    exec ${pkgs.bash}/bin/bash ${../lib/phone-ap-failopen.sh}
  '';
in
{
  options.phoneLink.apFailOpen = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Remove the AP hairpin while `phone-tun` is unhealthy, and restore it
        once the tunnel has been healthy for `grace` seconds.  Defaults to on
        when `phoneLink.ap.uplink = "tunnel"` (the healthy state), because a
        validated AP with a dead tunnel blackholes the phone; set it to
        `false` to run the hairpin unguarded.
      '';
    };

    client = lib.mkOption {
      type = lib.types.str;
      default = cfg.ap.forwardClient;
      description = ''
        The one AP client the watchdog requires in the hairpin, normally the
        phone.  Defaults to `phoneLink.ap.forwardClient`, the same source the
        merged hairpin accepts and masquerades.
      '';
    };

    grace = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 15;
      description = ''
        Seconds the tunnel must stay healthy before the hairpin is restored.
        The tunnel probe runs every 5 s, so a one- or two-tick toggle cannot
        restore and flap the hairpin.
      '';
    };

    throttle = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = ''
        Minimum seconds between two restores.  Fail-open itself is immediate:
        safety does not wait for the throttle.
      '';
    };

    nat = lib.mkOption {
      type = lib.types.bool;
      default = cfg.ap.uplink == "tunnel";
      description = ''
        Require the scoped masquerade table for a healthy hairpin.  On by
        default with `phoneLink.ap.uplink = "tunnel"`; set false only for an
        accept-only hairpin.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # mkDefault so `apFailOpen.enable = false` is the documented escape hatch
      # and wins over the hairpin-derived default.
      phoneLink.apFailOpen.enable = lib.mkDefault (cfg.ap.uplink == "tunnel");

      assertions = [
        {
          assertion = !failOpen.enable || cfg.ap.enable;
          message = "phoneLink.apFailOpen.enable requires phoneLink.ap.enable";
        }
        {
          assertion = !failOpen.enable || cfg.ap.uplink == "tunnel";
          message = "phoneLink.apFailOpen.enable requires phoneLink.ap.uplink = \"tunnel\"";
        }
      ];
    }
    (lib.mkIf (cfg.enable && failOpen.enable) {
      systemd.services.phone-link-ap-failopen = {
        description = "Remove the PhoneLink AP hairpin while phone-tun is unhealthy";
        after = [ "network.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = failOpenScript;
        };
      };

      # Same 5 s cadence as phone-tun-toggle, so a dead tunnel opens within one
      # tick and the 60 s Android fallback budget is not spent by the watchdog.
      systemd.timers.phone-link-ap-failopen = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "5s";
          AccuracySec = "1s";
        };
      };
    })
  ];
}
