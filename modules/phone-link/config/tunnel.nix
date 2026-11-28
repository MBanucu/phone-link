# Tunnel units: the sing-box TUN, the 5 s probe that starts and stops it, the
# runtime port files and the shared module environment.
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
  config = lib.mkIf cfg.enable {
    systemd.services.phone-tun = {
      description = "Route all traffic through the phone SOCKS proxy";
      after = [ "network.target" ];
      # Started and stopped by phone-tun-toggle.service, never at boot.
      serviceConfig = {
        RuntimeDirectory = "phone-tun";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        EnvironmentFile = cfg.secretsFile;
        ExecStartPre = internal.tunConfig;
        ExecStart = "${pkgs.sing-box}/bin/sing-box run -c /run/phone-tun/config.json";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    systemd.services.phone-tun-toggle = {
      description = "Start or stop phone-tun depending on the phone proxy";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = internal.toggle;
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
      "d ${internal.runtimeDir} 0755 root root -"
      "f+ ${internal.portFile} 0644 root root - ${toString cfg.proxyPort}"
    ];

    # One non-secret configuration for the commands, the doctor and the
    # live harness; the environment still wins over it.
    environment.etc."phone-link/env".text = internal.moduleEnv;
  };
}
