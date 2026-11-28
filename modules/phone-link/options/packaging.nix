# Packaging options: the non-unit activation behaviour that keeps the proxy
# APK available offline.
{ lib, ... }:
{
  options.phoneLink = {
    cacheProxyApk = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Download the proxy APK into the ambulance cache during activation, so
        installing or updating the system always leaves a copy that can be
        reinstalled without a network.  Ignored when phone-fix-apk is not on
        the system PATH.
      '';
    };
  };
}
