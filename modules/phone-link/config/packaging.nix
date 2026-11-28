# Packaging activation: keep the proxy APK cached so a reinstall needs no
# network.  An activation script, not a unit, because it must follow the newest
# F-Droid version on every switch and a derivation cannot download.
{ config, lib, ... }:
let
  cfg = config.phoneLink;
in
{
  config = lib.mkIf (cfg.enable && cfg.cacheProxyApk) {
    # Runs on every switch/boot-time activation, not at build time: a Nix
    # derivation cannot download, and the cache must follow the newest
    # F-Droid version.
    system.activationScripts.phone-apk-cache = {
      text = ''
        if [ -x "${config.system.path}/bin/phone-fix-apk" ]; then
          "${config.system.path}/bin/phone-fix-apk" --refresh >&2 || true
        fi
      '';
    };
  };
}
