# Firewall surface of the AP: its own nftables forward table (independent of
# the NixOS firewall) and the DHCP hole on the AP interface.
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
  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.ap.enable && cfg.ap.role == "local") {
      # The AP's own nftables table, not `firewall.extraForwardRules`:
      # that option only exists while the NixOS firewall is enabled, and
      # this policy has to hold either way.  priority -10 runs before the
      # filter chains, including the accept rule NetworkManager installs
      # for a shared connection.  With `uplink = "tunnel"` the same file
      # also carries the scoped postrouting masquerade; there is no NixOS
      # firewall rule, because the only forward drop here is this table.
      systemd.services.phone-link-ap-noforward = {
        description = "Apply the PhoneLink access point forward policy";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.nftables}/bin/nft -f ${pkgs.writeText "phone-link-ap.nft" cfg.ap.ruleset}";
          ExecStop = internal.apNoForwardStop;
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.openApFirewall && cfg.ap.role == "local") {
      networking.firewall.interfaces.${cfg.apInterface} = {
        allowedUDPPorts = [ 67 ];
      };
    })
  ];
}
