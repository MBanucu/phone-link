{
  description = "phone-link: scripts and NixOS modules for using an unrooted Android phone as Wi-Fi uplink and adb target";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = "0.1.0";

      scripts = [
        "adb-wifi-connect"
        "net-check"
        "phone-ap-down"
        "phone-ap-up"
        "phone-net-status"
        "phone-proxy-battery-whitelist"
        "phone-proxy-check"
        "phone-proxy-data-clear"
        "phone-proxy-install"
        "phone-proxy-setup"
        "phone-proxy-start"
        "phone-proxy-stop"
        "phone-proxy-uninstall"
        "phone-tunnel-run"
        "phone-unlock"
        "phone-usb-tether-check"
        "phone-wifi-concurrency"
      ];

      # Everything the scripts call at runtime.  The wrappers put these on PATH,
      # so a script behaves the same from the store and from a checkout.
      runtimeDeps =
        pkgs: with pkgs; [
          android-tools
          avahi
          bash
          coreutils
          curl
          gawk
          gnugrep
          gnused
          iproute2
          iw
          networkmanager
          python3
          sing-box
          systemd
          util-linux
        ];
    in
    {
      packages = eachSystem (
        pkgs:
        let
          deps = runtimeDeps pkgs;
        in
        rec {
          phone-link =
            pkgs.runCommand "phone-link-${version}"
              {
                nativeBuildInputs = [ pkgs.makeWrapper ];
                meta = {
                  description = "Diagnostics and control scripts for the phone-link setup";
                  license = lib.licenses.mit;
                  platforms = systems;
                  mainProgram = "phone-net-status";
                };
              }
              ''
                mkdir -p "$out/bin"
                install -Dm644 ${./lib/phone-net.sh} "$out/share/phone-link/lib/phone-net.sh"
                install -Dm644 ${./lib/phone-ui.sh} "$out/share/phone-link/lib/phone-ui.sh"
                ${lib.concatMapStringsSep "\n" (name: ''
                  install -Dm755 ${./bin}/${name} "$out/share/phone-link/bin/${name}"
                  # Point the shebang at the store bash: /usr/bin/env does not
                  # exist in every environment the scripts run in.
                  patchShebangs "$out/share/phone-link/bin/${name}"
                  wrapProgram "$out/share/phone-link/bin/${name}" \
                    --prefix PATH : ${lib.makeBinPath deps}
                  ln -s "$out/share/phone-link/bin/${name}" "$out/bin/${name}"
                '') scripts}
              '';

          default = phone-link;
        }
      );

      checks = eachSystem (
        pkgs:
        let
          inherit (pkgs.stdenv.hostPlatform) system;
          package = self.packages.${system}.phone-link;

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
          # A path with context, so the check builds the generated config.
          tunnelConfig = on.phoneLink.configFile;
        in
        {
          # Deliberately not the package itself: a check that *is* the package is
          # deduplicated away, which is how `nix flake check` used to run nothing.
          package = pkgs.runCommand "phone-link-package-check" { } ''
            for name in ${lib.escapeShellArgs scripts}; do
              test -x ${package}/bin/"$name" || {
                echo "missing or not executable: $name"
                exit 1
              }
              grep -q android-tools ${package}/bin/"$name" || {
                echo "wrapper lost its runtime PATH: $name"
                exit 1
              }
            done
            status=$(${package}/bin/phone-net-status 2>&1 || true)
            case "$status" in
              *"wifi link"*) ;;
              *)
                echo "phone-net-status produced no status output"
                exit 1
                ;;
            esac
            touch $out
          '';

          shellcheck = pkgs.runCommand "phone-link-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
              shellcheck -S warning ${./bin}/* ${./lib}/*.sh
            touch $out
          '';

          format = pkgs.runCommand "phone-link-format-check" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${./flake.nix} ${./modules/phone-link.nix}
            touch $out
          '';

          module =
            assert lib.assertMsg (
              on.systemd.timers.phone-tun-toggle.timerConfig.OnUnitActiveSec == "5s"
            ) "the proxy probe must run every 5 s";
            assert lib.assertMsg (
              on.systemd.timers.phone-tun-toggle.timerConfig.OnBootSec == "20s"
            ) "the probe must not fire before the network is up";
            assert lib.assertMsg (
              on.networking.firewall.interfaces.wlptest0.allowedUDPPorts == [
                53
                67
              ]
            ) "the AP interface must allow DHCP and DNS";
            assert lib.assertMsg (
              on.networking.firewall.interfaces.wlptest0.allowedTCPPorts == [ 53 ]
            ) "the AP interface must allow DNS over TCP";
            assert lib.assertMsg (
              !(lib.elem "multi-user.target" on.systemd.services.phone-tun.wantedBy)
            ) "the tunnel must never start at boot";
            assert lib.assertMsg (
              !(on.systemd.services ? phone-socks-relay)
            ) "the relay must stay off unless enableRelay is set";
            assert lib.assertMsg (lib.hasInfix "1.1.1.1"
              on.environment.etc."resolv.conf".text
            ) "manageResolver must pin resolv.conf";
            assert lib.assertMsg (
              !(off.systemd.services ? phone-tun)
            ) "the module must define nothing unless enabled";
            pkgs.runCommand "phone-link-module-check" { } ''
              grep -q '"server": "10.9.9.9"' ${tunnelConfig}
              grep -q '"server_port": 1081' ${tunnelConfig}
              grep -q '"interface_name": "phone-tun"' ${tunnelConfig}
              grep -q '"password": "@PHONE_SOCKS_PASS@"' ${tunnelConfig}
              grep -qF 'sing-box run -c /run/phone-tun/config.json' \
                ${pkgs.writeText "phone-tun-exec-start" on.systemd.services.phone-tun.serviceConfig.ExecStart}
              touch $out
            '';

          # Hermetic CLI tests: stub adb/curl first on PATH, no phone, no network.
          # The source script is used (not the wrapper), because wrapProgram
          # prepends its own PATH and would shadow the stubs.
          script =
            pkgs.runCommand "phone-link-script-check"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.gnused
                  pkgs.python3
                ];
              }
              ''
                # Run every suite from the flake source root, so each test's
                # ../bin and ../lib lookups resolve; interpolating ./bin alone
                # would give a store path without its siblings.
                for t in ${self.outPath}/tests/*.test.sh; do
                  bash "$t"
                done
                touch $out
              '';
        }
      );

      apps = eachSystem (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.phone-link}/bin/phone-net-status";
          meta.description = "Show the state of the phone link";
        };
      });

      nixosModules = {
        default = import ./modules/phone-link.nix;
        phone-link = import ./modules/phone-link.nix;
      };

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = runtimeDeps pkgs ++ [
            pkgs.shellcheck
            pkgs.nixfmt-rfc-style
          ];
        };
      });

      formatter = eachSystem (
        pkgs:
        pkgs.writeShellScriptBin "nixfmt-nix-files" ''
          files=()
          for f in "$@"; do
            case "$f" in *.nix) files+=("$f") ;; esac
          done
          if [ ''${#files[@]} -eq 0 ]; then
            echo "nixfmt: no .nix files given" >&2
            exit 0
          fi
          exec ${pkgs.nixfmt-rfc-style}/bin/nixfmt-rfc-style "''${files[@]}"
        ''
      );
    };
}
