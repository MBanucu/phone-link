# Tunnel options: the TUN device, logging, resolver handling and the generated
# sing-box configuration.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  internal = import ../derived.nix {
    inherit
      config
      lib
      pkgs
      ;
  };
in
{
  options.phoneLink = {
    enable = lib.mkEnableOption "the phone-link tunnel";

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

    manageResolver = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pin /etc/resolv.conf to public resolvers.  Needed because the tunnel
        answers DNS itself and the phone's tether DNS would otherwise loop back
        into the laptop's dnsmasq.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      internal = true;
      readOnly = true;
      default = internal.singboxConfig;
      description = ''
        Generated sing-box config with the password placeholder.  Read-only, so
        checks and consumers can reference the same file the unit uses.
      '';
    };
  };
}
