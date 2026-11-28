# Declarative base: the regulatory domain kernel parameter and the invariant
# assertions.  None of this depends on `enable`; a misconfiguration should be
# reported even before the tunnel is switched on.
{ config, lib, ... }:
let
  cfg = config.phoneLink;
in
{
  # The earliest place to set the domain: before the wiphy is registered and
  # before NetworkManager can activate the AP, and it survives NM restarts.
  # It only applies on the next boot; `iw reg set` is the runtime fix.
  boot.kernelParams = lib.optional (
    cfg.ap.country != null
  ) "cfg80211.ieee80211_regdom=${cfg.ap.country}";

  assertions = [
    {
      assertion = !cfg.ap.enable || cfg.enable;
      message = "phoneLink.ap.enable requires phoneLink.enable = true";
    }
    {
      assertion = !cfg.ap.enable || config.networking.networkmanager.enable;
      message = "phoneLink.ap.enable requires networking.networkmanager.enable = true";
    }
    {
      assertion = !cfg.ap.enable || cfg.ap.band != "bg" || cfg.ap.channelWidth <= 40;
      message = "phoneLink.ap.channelWidth must be 0, 20 or 40 when phoneLink.ap.band is bg";
    }
    {
      assertion = !cfg.ap.fallback.enable || cfg.ap.band == "a";
      message = "phoneLink.ap.fallback.enable requires phoneLink.ap.band = \"a\"; a 2.4 GHz AP cannot fall back to 2.4 GHz";
    }
    {
      assertion = !cfg.ap.fallback.enable || cfg.ap.role == "local";
      message = "phoneLink.ap.fallback.enable requires phoneLink.ap.role = \"local\"; an external AP has no local profile to fall back from";
    }
    {
      assertion = cfg.ap.role == "local" || cfg.ap.uplink == "none";
      message = "phoneLink.ap.role = \"external\" requires phoneLink.ap.uplink = \"none\"";
    }
    {
      assertion = cfg.ap.uplink == "none" || cfg.ap.enable;
      message = "phoneLink.ap.uplink = \"tunnel\" requires phoneLink.ap.enable = true";
    }
    {
      assertion = cfg.ap.uplink == "none" || cfg.ap.forwardClient != "";
      message = "phoneLink.ap.uplink = \"tunnel\" needs a forwardClient (defaults to proxyHost)";
    }
  ];
}
