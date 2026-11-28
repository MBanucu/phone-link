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
  };
}
