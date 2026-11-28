# phone-link: send the laptop's traffic through the phone's SOCKS proxy and, if
# wanted, open the firewall for the laptop access point the phone joins.
#
# The phone is never rooted and nothing here starts a tunnel at boot: a 5 s
# timer probes the proxy port and only keeps the TUN alive while it answers, so
# a missing phone or a stopped proxy app cannot blackhole traffic.
#
# The parts live in options/ (one file per option group) and config/ (one file
# per group of units or generated configuration); derived.nix holds the values
# both sides share.  The fail-open watchdog stays a separate module and is
# imported by the flake next to this one.
{
  imports = [
    ./options/tunnel.nix
    ./options/proxy.nix
    ./options/ap.nix
    ./options/secrets.nix
    ./options/packaging.nix

    ./config/base.nix
    ./config/tunnel.nix
    ./config/networkmanager.nix
    ./config/ap-dhcp.nix
    ./config/firewall.nix
    ./config/rejoin.nix
    ./config/relay.nix
    ./config/resolver.nix
    ./config/packaging.nix
  ];
}
