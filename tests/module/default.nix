{
  lib,
  pkgs,
  self,
  system,
}:
let
  # Evaluate the module without building a system: once with non-default
  # values so the generated units can be inspected, once untouched to
  # prove it defines nothing unless enabled.
  base = {
    system.stateVersion = "26.05";
    fileSystems."/" = {
      device = "/dev/sda1";
      fsType = "ext4";
    };
    boot.loader.grub.devices = [ "/dev/sda" ];
  };
  evalModule =
    extra:
    (lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        base
      ]
      ++ extra;
    }).config;
  on = evalModule [
    {
      phoneLink = {
        enable = true;
        apInterface = "wlptest0";
        proxyHost = "10.9.9.9";
        proxyPort = 1081;
      };
    }
  ];
  off = evalModule [ ];
  fallbackOn = evalModule [
    {
      phoneLink = {
        enable = true;
        proxyHost = "10.9.9.9";
        proxyHosts = [
          "10.23.190.38"
          "10.9.9.8"
        ];
      };
    }
  ];
  dedupOn = evalModule [
    {
      phoneLink = {
        enable = true;
        proxyHost = "10.9.9.9";
        proxyHosts = [
          "10.23.190.38"
          "10.9.9.8"
          "10.9.9.9"
        ];
      };
    }
  ];
  apOn = evalModule [
    {
      networking.networkmanager.enable = true;
      phoneLink = {
        enable = true;
        ap = {
          enable = true;
          ssid = "TestLink";
          address = "192.168.99.1/24";
        };
      };
    }
  ];
  # A non-default name and credentials path must reach both the env
  # file the commands read and the declarative-profile marker.
  apNamed = evalModule [
    {
      networking.networkmanager.enable = true;
      phoneLink = {
        enable = true;
        ap = {
          enable = true;
          name = "testlink";
          ssid = "Test Link";
          address = "192.168.98.1/24";
        };
        proxyUser = "linkuser";
        secretsFile = "/etc/nixos/other-secrets";
      };
    }
  ];
  # Autoconnect reserves the radio and must still be a link-only profile.
  apAutoconnect = evalModule [
    {
      networking.networkmanager.enable = true;
      phoneLink = {
        enable = true;
        ap = {
          enable = true;
          autoconnect = true;
        };
      };
    }
  ];
  # The country option must reach the kernel command line and merge with an
  # existing boot.kernelParams; unset must add nothing.
  apCountry = evalModule [
    {
      boot.kernelParams = [ "quiet" ];
      networking.networkmanager.enable = true;
      phoneLink = {
        enable = true;
        ap = {
          enable = true;
          country = "DE";
        };
      };
    }
  ];
  # The rejoin watchdog is on by default with ap.enable, and off when
  # ap.rejoin = false.
  apNoRejoin = evalModule [
    {
      networking.networkmanager.enable = true;
      phoneLink = {
        enable = true;
        ap = {
          enable = true;
          rejoin = false;
        };
      };
    }
  ];
  # The AP's forward drop must not depend on the NixOS firewall.
  apNoFirewall = evalModule [
    {
      networking.networkmanager.enable = true;
      networking.firewall.enable = false;
      phoneLink = {
        enable = true;
        ap.enable = true;
      };
    }
  ];
  # Opt-in hairpin: the one client is accepted, masqueraded into the
  # tunnel, and gets a router and DNS option from DHCP.  The default
  # stays link-only.
  apHairpin = evalModule [
    {
      networking.networkmanager.enable = true;
      phoneLink = {
        enable = true;
        ap = {
          enable = true;
          ssid = "TestLink";
          address = "192.168.99.1/24";
          uplink = "tunnel";
          forwardClient = "192.168.77.232";
          uplinkDns = "9.9.9.9";
        };
      };
    }
  ];
  # The hairpin enables fail-open by default, but an explicit false must
  # win; that is the escape hatch for a deliberately unguarded link.
  apHairpinNoFailOpen = evalModule [
    {
      networking.networkmanager.enable = true;
      phoneLink = {
        enable = true;
        ap = {
          enable = true;
          uplink = "tunnel";
          forwardClient = "192.168.77.232";
        };
        apFailOpen.enable = false;
      };
    }
  ];
  # The external AP is another host: the module must define no profile, DHCP,
  # forward drop or firewall hole, while the USB rejoin nudge still applies.
  # proxyHost is the DHCP reservation on that AP.
  apExternal = evalModule [
    {
      networking.networkmanager.enable = true;
      phoneLink = {
        enable = true;
        proxyHost = "192.168.50.20";
        ap = {
          enable = true;
          role = "external";
          ssid = "BoatLink";
        };
      };
    }
  ];
  # Role external is complete on its own: the user need not set ap.enable,
  # which only describes the local profile this host does not own.
  apExternalNoEnable = evalModule [
    {
      phoneLink = {
        enable = true;
        proxyHost = "192.168.50.20";
        ap = {
          role = "external";
          ssid = "BoatLink";
        };
      };
    }
  ];
  relayOn = evalModule [
    {
      phoneLink = {
        enable = true;
        enableRelay = true;
      };
    }
  ];
  fixtures = {
    inherit
      on
      off
      fallbackOn
      dedupOn
      apOn
      apNamed
      apAutoconnect
      apCountry
      apNoRejoin
      apNoFirewall
      apHairpin
      apHairpinNoFailOpen
      apExternal
      apExternalNoEnable
      relayOn
      ;
    # A path with context, so the check builds the generated config.
    tunnelConfig = on.phoneLink.configFile;
  };
in
assert import ./options.nix { inherit lib fixtures; };
import ./units.nix { inherit pkgs fixtures; }
