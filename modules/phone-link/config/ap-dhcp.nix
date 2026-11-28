# DHCP for the link-only AP, and the forwarding knob the hairpin needs.
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
  config = lib.mkIf (cfg.enable && cfg.ap.enable && cfg.ap.role == "local") {
    # DHCP only: this replaces NetworkManager's shared dnsmasq, which
    # also sent a router and DNS option and installed NAT.  It reads the
    # same root-only drop-in directory NetworkManager used, so a
    # `dhcp-host` reservation there keeps the phone's address.
    #
    # The link-only AP sends neither option.  In the hairpin mode the
    # client needs both: the AP address as its default route, and a
    # resolver address that only has to enter the tunnel (sing-box
    # hijacks port 53 there).  The phone has no default route otherwise.
    systemd.services.phone-link-ap-dhcp = {
      description = "DHCP for the PhoneLink access point";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0755 /etc/NetworkManager/dnsmasq-shared.d";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.dnsmasq}/bin/dnsmasq"
          "--keep-in-foreground"
          "--conf-file=/dev/null"
          "--bind-dynamic"
          "--interface=${cfg.apInterface}"
          "--except-interface=lo"
          "--port=0"
          "--dhcp-range=${cfg.ap.dhcpRange}"
          "--dhcp-leasefile=/var/lib/phone-link/dnsmasq-${cfg.apInterface}.leases"
          "--dhcp-option=option:router${
            lib.optionalString (cfg.ap.uplink == "tunnel") ",${internal.apAddress}"
          }"
          "--dhcp-option=option:dns-server${
            lib.optionalString (cfg.ap.uplink == "tunnel") ",${cfg.ap.uplinkDns}"
          }"
          "--conf-dir=/etc/NetworkManager/dnsmasq-shared.d"
        ];
        StateDirectory = "phone-link";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Forwarding must be on for the hairpin; keep the declarative default
    # while still letting the host's own sysctl setting win.
    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkIf (cfg.ap.uplink == "tunnel") (
      lib.mkDefault true
    );
  };
}
