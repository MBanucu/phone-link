# Optional local SOCKS/HTTP relay for apps that cannot use the TUN.
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
  config = lib.mkIf (cfg.enable && cfg.enableRelay) {
    systemd.services.phone-socks-relay = {
      description = "SOCKS5/HTTP relay to the phone proxy";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        EnvironmentFile = cfg.secretsFile;
        ExecStart = internal.relay;
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
