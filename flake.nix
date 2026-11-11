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
      version = "0.3.4";

      scripts = [
        "adb-wifi-connect"
        "net-check"
        "phone-adb-wifi"
        "phone-ap-create"
        "phone-ap-delete"
        "phone-ap-down"
        "phone-ap-up"
        "phone-doctor"
        "phone-doctor-fix"
        "phone-fix-apk"
        "phone-fix-forwarding"
        "phone-fix-internet"
        "phone-fix-mobile-data"
        "phone-fix-tunnel"
        "phone-link-uninstall"
        "phone-net-status"
        "phone-proxy-battery-whitelist"
        "phone-proxy-check"
        "phone-proxy-data-clear"
        "phone-proxy-install"
        "phone-proxy-setup"
        "phone-proxy-start"
        "phone-proxy-stop"
        "phone-proxy-uninstall"
        "phone-reboot-unlock"
        "phone-tether-cycle"
        "phone-tunnel-run"
        "phone-unlock"
        "phone-usb-tether-check"
        "phone-usb-tether-default"
        "phone-wifi-concurrency"
        "phone-wifi-connect"
        "phone-wifi-enable"
        "phone-wifi-forget"
      ];

      # Installed next to the scripts but deliberately outside the registry:
      # the registry check requires exactly one action per script, and these
      # two are the shared-core CLI and the GUI itself.
      coreScripts = [ "phone-link" ];

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
                # phone-doctor is a Python package: one module per symptom group.
                # It must live under lib/python so the checkout-relative
                # PYTHONPATH in bin/phone-doctor also works from the store.
                mkdir -p "$out/share/phone-link/lib/python"
                # phone_doctor is the doctor; phone_link is the action registry
                # and runner that `phone-link` and the GUI both read.
                cp -r ${./lib/python}/phone_doctor ${./lib/python}/phone_link \
                  "$out/share/phone-link/lib/python/"
                # A checkout may carry bytecode; the copy is read-only, so make
                # it writable before pruning what should never be installed.
                chmod -R u+w "$out/share/phone-link/lib/python"
                find "$out/share/phone-link/lib/python" -name __pycache__ \
                  -type d -exec rm -rf {} +
                ${lib.concatMapStringsSep "\n" (name: ''
                  install -Dm755 ${./bin}/${name} "$out/share/phone-link/bin/${name}"
                  # Point the shebang at the store bash: /usr/bin/env does not
                  # exist in every environment the scripts run in.
                  patchShebangs "$out/share/phone-link/bin/${name}"
                  wrapProgram "$out/share/phone-link/bin/${name}" \
                    --prefix PATH : ${lib.makeBinPath deps}
                  ln -s "$out/share/phone-link/bin/${name}" "$out/bin/${name}"
                '') (scripts ++ coreScripts)}
              '';

          default = phone-link;

          # The desktop shell: the same actions as the scripts, plus the
          # doctor's findings. It ships the phone-link package for the actions
          # themselves, so the GUI never reimplements one.
          phone-link-gui =
            let
              guiPython = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
              # makeSearchPath resolves multi-output packages to their "bin"
              # output, which is not where the typelibs are; ask for "out".
              typelibs = lib.makeSearchPathOutput "out" "lib/girepository-1.0" [
                pkgs.gtk4
                pkgs.libadwaita
                # cairo-1.0.typelib lives here, not in cairo
                pkgs.gobject-introspection
                pkgs.glib
                pkgs.pango
                pkgs.cairo
                pkgs.gdk-pixbuf
                pkgs.graphene
                pkgs.harfbuzz
              ];
              dataDirs = lib.makeSearchPathOutput "out" "share" [
                pkgs.gtk4
                pkgs.libadwaita
                pkgs.adwaita-icon-theme
                pkgs.hicolor-icon-theme
                pkgs.shared-mime-info
                # glib finds its schemas under $XDG_DATA_DIRS/glib-2.0/schemas
                pkgs.gsettings-desktop-schemas
              ];
            in
            pkgs.runCommand "phone-link-gui-${version}"
              {
                nativeBuildInputs = [ pkgs.makeWrapper ];
                meta = {
                  description = "GTK4/libadwaita control panel for the phone link";
                  license = lib.licenses.mit;
                  platforms = systems;
                  mainProgram = "phone-link-gui";
                };
              }
              ''
                mkdir -p "$out/share/phone-link-gui/lib/python"
                cp -r ${./lib/python}/phone_link ${./lib/python}/phone_doctor \
                  ${./lib/python}/phone_link_gui "$out/share/phone-link-gui/lib/python/"
                chmod -R u+w "$out/share/phone-link-gui/lib/python"
                find "$out/share/phone-link-gui/lib/python" -name __pycache__ \
                  -type d -exec rm -rf {} +
                install -Dm755 ${./bin}/phone-link-gui "$out/bin/phone-link-gui"
                patchShebangs "$out/bin/phone-link-gui"
                # nixpkgs keeps schemas under share/gsettings-schemas/<pkg>,
                # and GLib only finds them when that directory is on
                # XDG_DATA_DIRS. Without it GtkSettings gets no schema source
                # at all, so the app loses the user's fonts and dark mode.
                schema_dirs=$(find -L \
                  ${pkgs.gtk4}/share/gsettings-schemas \
                  ${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas \
                  -mindepth 1 -maxdepth 1 -type d | sort | paste -sd:)
                wrapProgram "$out/bin/phone-link-gui" \
                  --prefix PATH : ${
                    lib.makeBinPath [
                      phone-link
                      guiPython
                    ]
                  } \
                  --prefix GI_TYPELIB_PATH : ${typelibs} \
                  --prefix XDG_DATA_DIRS : "$schema_dirs:${dataDirs}"
                install -Dm644 ${./gui}/phone-link-gui.desktop \
                  "$out/share/applications/phone-link-gui.desktop"
                install -Dm644 ${./gui}/phone-link-gui.svg \
                  "$out/share/icons/hicolor/scalable/apps/phone-link-gui.svg"
              '';
        }
      );

      checks = eachSystem (
        pkgs:
        let
          inherit (pkgs.stdenv.hostPlatform) system;
          package = self.packages.${system}.phone-link;
          gui = self.packages.${system}.phone-link-gui;

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
            ${package}/bin/phone-doctor --help >/dev/null
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

          # The GUI's table and bin/ must agree: a script with no action fails
          # here, which is what keeps "every CLI action is in the GUI" true.
          registry = pkgs.runCommand "phone-link-registry-check" { } ''
            ${package}/bin/phone-link check-registry ${lib.escapeShellArgs scripts}
            touch $out
          '';

          # The packaged GUI resolves the same table and its GTK imports, which
          # a plain `python3 -m` check would not prove.
          gui-registry = pkgs.runCommand "phone-link-gui-registry-check" { } ''
            # GTK/fontconfig want a writable HOME in the build sandbox
            export HOME=$TMPDIR XDG_CACHE_HOME=$TMPDIR/cache
            mkdir -p "$XDG_CACHE_HOME"
            ${gui}/bin/phone-link-gui --check-registry ${lib.escapeShellArgs scripts}
            touch $out
          '';

          # Build the real window, every page and a log window under Xvfb: a
          # widget that cannot construct fails here instead of at first launch.
          gui =
            pkgs.runCommand "phone-link-gui-check"
              {
                nativeBuildInputs = [
                  pkgs.dbus
                  pkgs.xauth
                  pkgs.xvfb-run
                ];
              }
              ''
                export GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none
                export GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1
                export HOME=$TMPDIR XDG_CACHE_HOME=$TMPDIR/cache
                mkdir -p "$XDG_CACHE_HOME"
                export XDG_RUNTIME_DIR=$TMPDIR/runtime
                mkdir -p "$XDG_RUNTIME_DIR"
                chmod 700 "$XDG_RUNTIME_DIR"
                # no /etc in the sandbox: point dbus at the packaged session.conf
                dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf \
                  -- xvfb-run -a ${gui}/bin/phone-link-gui --selftest
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
            assert lib.assertMsg (
              apOn.networking.networkmanager.ensureProfiles.profiles ? phonelink
            ) "ap.enable must declare the phonelink profile";
            assert lib.assertMsg (
              apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.wifi-security.psk
              == "$PHONE_AP_PASS"
            ) "the AP profile must keep the PSK out of the store";
            assert lib.assertMsg (
              apOn.networking.networkmanager.ensureProfiles.environmentFiles
              == [ "/etc/nixos/phone-socks-secrets" ]
            ) "the AP profile must read the secrets file";
            assert lib.assertMsg (
              apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.wifi.ssid == "TestLink"
            ) "ap.ssid must reach the profile";
            assert lib.assertMsg (
              apOn.networking.networkmanager.ensureProfiles.profiles.phonelink.ipv4.address1 == "192.168.99.1/24"
            ) "ap.address must reach the profile";
            assert lib.assertMsg
              (lib.hasInfix "phonelink.nmconnection" apOn.systemd.services.NetworkManager-ensure-profiles.script)
              "ensure-profiles must write the AP keyfile";
            assert lib.assertMsg
              (lib.hasInfix "phonelink.nmconnection" apOn.systemd.services.NetworkManager-ensure-profiles.preStart)
              "ensure-profiles must migrate a hand-made profile";
            assert lib.assertMsg (
              !(on.networking.networkmanager.ensureProfiles.profiles ? phonelink)
            ) "the AP profile must be opt-in";
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
        gui = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.phone-link-gui}/bin/phone-link-gui";
          meta.description = "Open the phone-link control panel";
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
            (pkgs.python3.withPackages (ps: [ ps.pygobject3 ]))
            pkgs.gtk4
            pkgs.libadwaita
            pkgs.gobject-introspection
            pkgs.dbus
            pkgs.xauth
            pkgs.xvfb-run
          ];
          shellHook = ''
            export PYTHONPATH="$PWD/lib/python''${PYTHONPATH:+:$PYTHONPATH}"
          '';
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
