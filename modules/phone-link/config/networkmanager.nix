# NetworkManager profile for the laptop-local AP, plus the migration preStart
# and the marker the commands use to tell a declarative profile from a hand-made
# one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.phoneLink;
  internal = import ../derived.nix {
    inherit
      config
      lib
      pkgs
      ;
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.ap.enable && cfg.ap.role == "local") {
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

    # Remove a persistent profile left by phone-ap-create, so enabling
    # phoneLink.ap does not leave two profiles with the same name.
    systemd.services.NetworkManager-ensure-profiles.preStart = ''
      rm -f -- ${lib.escapeShellArg "/etc/NetworkManager/system-connections/${cfg.ap.name}.nmconnection"}
    '';

    # Lets the scripts tell a declarative profile from a hand-made one.
    # The external role has no profile here, and the role in
    # /etc/phone-link/env is what commands and the doctor read instead.
    environment.etc."phone-link/ap-profile".text = cfg.ap.name;

    # The 2.4 GHz fallback script: `phone-ap-up` runs it after a failed
    # 5 GHz attempt, and the boot unit below runs the same file so both share
    # one state file and one attempt per boot.
    environment.etc."phone-link/ap-fallback.sh" = lib.mkIf cfg.ap.fallback.enable {
      source = internal.apFallback;
      mode = "0755";
    };

    # At boot NetworkManager tries the 5 GHz profile unattended, so a failure
    # there is the case no one can run phone-ap-up for.  The unit waits
    # `ap.fallback.delay` for the 5 GHz AP to appear (and returns as soon as it
    # does), then makes the one fallback attempt.  It only exists when the AP
    # is meant to come up at boot; with autoconnect off the AP stays down until
    # phone-ap-up, which runs the same script itself.
    systemd.services.phone-link-ap-fallback = lib.mkIf (cfg.ap.fallback.enable && cfg.ap.autoconnect) {
      description = "Fall back to 2.4 GHz when the PhoneLink 5 GHz AP cannot start";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "NetworkManager.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = internal.apFallback;
        TimeoutStartSec = "${toString (cfg.ap.fallback.delay + 60)}s";
      };
    };
  };
}
