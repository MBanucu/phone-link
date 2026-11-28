# Resolver pinning: the tunnel answers DNS itself, so the host resolvers must
# not loop back into the laptop's own dnsmasq over the phone's tether.
{ config, lib, ... }:
let
  cfg = config.phoneLink;
in
{
  config = lib.mkIf (cfg.enable && cfg.manageResolver) {
    networking.networkmanager.dns = "none";
    networking.resolvconf.enable = false;
    environment.etc."resolv.conf".text = ''
      nameserver 1.1.1.1
      nameserver 9.9.9.9
    '';
  };
}
