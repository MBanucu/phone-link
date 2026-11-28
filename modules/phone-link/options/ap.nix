# Access-point options: the local AP profile, the external-AP role, the
# link-only forward policy and the DHCP hole.
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
  options.phoneLink = {
    apInterface = lib.mkOption {
      type = lib.types.str;
      default = "wlp110s0";
      description = ''
        Wireless interface used for the laptop access point, or as the client
        interface when `phoneLink.ap.role = "external"`.
      '';
    };

    ap = {
      role = lib.mkOption {
        type = lib.types.enum [
          "local"
          "external"
        ];
        default = "local";
        description = ''
          Who owns the access point.  `"local"` is the laptop AP this module
          declares, with its DHCP server, forward drop and firewall hole.
          `"external"` means an always-on AP outside this host (OpenWrt, a
          travel router, a Pi): the module creates no profile, DHCP unit,
          nftables rules or AP firewall hole, and `phone-ap-up` / `phone-ap-down`
          do not touch the radio.  The laptop joins the external AP as a
          client; `apInterface` is that client interface, `ap.ssid` is the
          external SSID the rejoin watchdog nudges the phone back to, and
          `proxyHost` must be the DHCP reservation for the phone.  The AP must
          stay link-only: no NAT, no DHCP router or DNS option, no uplink and
          no forwarding.  `ap.uplink` may not be `"tunnel"` in this role.
          See docs/ap-topology.md.
        '';
      };

      enable = lib.mkEnableOption "the declarative PhoneLink access-point profile";

      name = lib.mkOption {
        type = lib.types.str;
        default = "phonelink";
        description = "NetworkManager connection name.";
      };

      ssid = lib.mkOption {
        type = lib.types.str;
        default = "PhoneLink";
        description = ''
          SSID of the laptop access point.  With `role = "external"` it is the
          external AP's SSID the rejoin watchdog nudges the phone back to.
        '';
      };

      autoconnect = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let NetworkManager activate the AP at boot.  Off by default, so the
          profile stays down until `phone-ap-up` runs.  Turning it on reserves
          the radio for the AP; a 5 GHz activation that fails then leaves no
          link at all (see #7).  Ignored with `role = "external"`.
        '';
      };

      rejoin = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Re-assert the phone's association with the AP when the AP comes back
          with no station.  Android validates the link-only AP as "no
          internet" and temporarily disables auto-join for the saved network,
          so after an AP restart the phone stays away for up to that window
          (about 10 minutes) and then rejoins on its own (issues #33 and #36).
          The watchdog runs over USB adb only, is throttled to one attempt
          every five minutes, and does nothing while any station is
          associated.  Requires `phoneLink.ap.enable` in the local role; with
          `role = "external"` it runs on its own and checks the phone over USB
          instead of a station dump.  With no USB the watchdog does nothing;
          the phone returns when the temporary disable expires or when someone
          re-selects the network on the phone.
        '';
      };

      band = lib.mkOption {
        type = lib.types.enum [
          "a"
          "bg"
        ];
        default = "a";
        description = "802.11 band: a for 5 GHz, bg for 2.4 GHz.";
      };

      channel = lib.mkOption {
        type = lib.types.ints.between 1 196;
        default = 149;
        description = ''
          802.11 channel. 149 is a non-DFS 5 GHz channel that this Intel 8265
          allows for an AP; 36 and 44 are the other usual non-DFS choices, but
          the card's self-managed regulatory domain currently marks them
          "no IR", so they cannot beacon.
        '';
      };

      channelWidth = lib.mkOption {
        type = lib.types.enum [
          0
          20
          40
          80
        ];
        default = 80;
        description = ''
          AP channel width in MHz: 0 (auto), 20, 40 or 80. NetworkManager 1.50+
          exposes this as 802-11-wireless.channel-width; 80 MHz needs an
          explicit channel, and 2.4 GHz can be at most 40 MHz.
        '';
      };

      country = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[A-Z]{2}");
        default = null;
        example = "DE";
        description = ''
          Regulatory country for the AP, as an uppercase ISO 3166-1 alpha-2
          code (e.g. `"DE"`).  `null` leaves the regulatory domain alone.

          When set, the module adds
          `cfg80211.ieee80211_regdom=<country>` to `boot.kernelParams`, so the
          domain is right before NetworkManager activates the AP at boot —
          even on a fresh boot with no Wi-Fi client association to learn a
          country from.  The kernel parameter takes effect on the next boot;
          to change it now, run `iw reg set <country>`.

          Without it, a boot in the world domain (`country 00`) cannot use
          5 GHz channel 149 for AP mode: the channel is passive-scan only and
          wpa_supplicant fails with a misleading 802.1X timeout.
        '';
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "192.168.77.1/24";
        description = "IPv4 address of the AP interface.";
      };

      uplink = lib.mkOption {
        type = lib.types.enum [
          "none"
          "tunnel"
        ];
        default = "none";
        description = ''
          Whether the AP may carry its client's traffic.  `"none"` keeps the
          AP a link only: forwarded traffic entering the AP interface is
          dropped, the DHCP server sends no router or DNS option, and Android
          keeps mobile data as its default network.  `"tunnel"` hairpins the
          one client in `forwardClient` through `phone-tun`, so the phone can
          validate the AP and reach the internet over the tunnel instead of
          looping it back over the same link.  Every other AP client stays
          dropped.  The tunnel must be up: while it is down the accepted
          client's traffic is no longer routed into `phone-tun`, and the
          fail-open watchdog in #46 is what restores the plain drop for that
          state.
        '';
      };

      forwardClient = lib.mkOption {
        type = lib.types.str;
        default = cfg.proxyHost;
        description = ''
          The single AP client allowed through when `uplink = "tunnel"`.
          Defaults to `proxyHost`, which is the phone on the AP.  It is the
          source address in both the forward accept and the masquerade; every
          other source entering the AP interface is dropped.
        '';
      };

      uplinkDns = lib.mkOption {
        type = lib.types.str;
        default = "1.1.1.1";
        description = ''
          DNS server advertised to the AP client when `uplink = "tunnel"`.
          The address only has to enter the tunnel: sing-box's `hijack-dns`
          answers it through the proxy's DoH server, so the proxy never has to
          carry UDP.  Ignored when `uplink = "none"`.
        '';
      };

      dhcpRange = lib.mkOption {
        type = lib.types.str;
        default = "${internal.apSubnet}.10,${internal.apSubnet}.254,3600";
        description = ''
          dnsmasq DHCP range and lease time, as `start,end,lease`.  The default
          is .10–.254 in the /24 of `address`, for one hour.  With
          `uplink = "none"` this is DHCP only: the AP sends no router or DNS
          option.  With `uplink = "tunnel"` it sends the AP address as the
          router and `uplinkDns` as the resolver.
        '';
      };

      noForwardRules = lib.mkOption {
        type = lib.types.lines;
        internal = true;
        readOnly = true;
        default = internal.apNoForwardRules;
        description = ''
          nftables rules that drop forwarded traffic entering from the AP
          interface, so the AP cannot become the phone's internet uplink.
          Unchanged by `uplink = "tunnel"`; the effective rules are in
          `forwardRules`.
        '';
      };

      forwardRules = lib.mkOption {
        type = lib.types.lines;
        internal = true;
        readOnly = true;
        default = internal.apForwardRules;
        description = ''
          The effective `inet phone_link_ap` forward rules: the plain drop, or
          the one-client accept followed by the drop when `uplink = "tunnel"`.
        '';
      };

      hairpinRules = lib.mkOption {
        type = lib.types.lines;
        internal = true;
        readOnly = true;
        default = internal.apHairpinRules;
        description = ''
          The scoped `ip phone_link_hairpin` masquerade when
          `uplink = "tunnel"`, otherwise empty.
        '';
      };

      ruleset = lib.mkOption {
        type = lib.types.lines;
        internal = true;
        readOnly = true;
        default = internal.apRuleset;
        description = ''
          Both nftables tables as one ruleset, exactly what the AP's forward
          unit loads.  Read-only, so checks can render the same file.
        '';
      };
    };

    openApFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Allow DHCP from clients of the laptop access point.  The AP does not
        serve DNS: the phone keeps LTE as its default and resolves directly
        over it.
      '';
    };
  };
}
