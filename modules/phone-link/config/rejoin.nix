# Rejoin watchdog: re-assert the phone's association over USB adb.  It runs in
# the local role with `ap.enable`, and on its own in the external role.
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
  config = lib.mkIf (cfg.enable && cfg.ap.rejoin && (cfg.ap.enable || cfg.ap.role == "external")) {
    # The phone's own auto-join is off for a link-only AP (Android saw no
    # internet), so a 30 s tick re-asserts the association over USB adb.
    # The service exits non-zero when the phone is away; that is normal
    # and must not fail the boot, hence no Restart and no boot ordering.
    # With role = "external" the laptop cannot see a station dump, so the
    # same watchdog asks the phone over USB whether it holds proxyHost and
    # nudges it onto ap.ssid when it does not.  It runs without ap.enable
    # there because that option only describes the profile this host owns.
    systemd.services.phone-link-ap-rejoin = {
      description = "Re-assert the phone's association with the PhoneLink AP";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = cfg.secretsFile;
        ExecStart = internal.rejoin;
      };
    };

    systemd.timers.phone-link-ap-rejoin = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "45s";
        OnUnitActiveSec = "30s";
        AccuracySec = "1s";
      };
    };
  };
}
