# Proxy and relay options: the phone's SOCKS endpoint, the generated host list
# and the optional local SOCKS/HTTP relay.
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
        runtime host until the next probe finds another.  When none of the
        declared addresses answers, the toggle also probes that boot's default
        route gateways and point-to-point peers on the proxy port, so a USB
        tether whose subnet changed needs no edit here; this list still pins
        the addresses tried before discovery.
      '';
    };

    effectiveProxyHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      internal = true;
      readOnly = true;
      default = internal.effectiveHosts;
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
        port in use to ${internal.portFile}, which the units and the scripts read; this
        is the value they use until one is chosen, and again after a reboot.
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
}
