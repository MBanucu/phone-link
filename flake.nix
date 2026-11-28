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
      version = "0.20.1";

      # Every script in bin/ is packaged, except the entry points that are not
      # actions: the CLI, which is coreScripts, and the GUI's two, which its own
      # package installs. Generated from the directory, because the typed list
      # drifted — phone-proxy-boot was in bin/ and in the action registry and not
      # here, so it worked from a checkout and did not exist once installed, and
      # only a full `nix flake check` said anything.
      scripts =
        let
          entries = builtins.readDir ./bin;
          regular = lib.filterAttrs (_: type: type == "regular") entries;
          notActions = [
            "phone-link"
            "phone-link-gui"
            "phone-link-gui-screenshots"
          ];
        in
        builtins.filter (name: !builtins.elem name notActions) (builtins.attrNames regular);

      # Installed next to the scripts but deliberately outside the registry:
      # the registry check requires exactly one action per script, and these
      # two are the shared-core CLI and the GUI itself.
      coreScripts = [ "phone-link" ];

      # Everything the scripts call at runtime.  The wrappers put these on PATH,
      # so a script behaves the same from the store and from a checkout.
      #
      # nmcli is the exception: it talks to the host's NetworkManager daemon,
      # so the host's client is the one that matches it.  A newer bundled
      # client warns about the version skew (and can mis-read properties), so
      # `networkmanager` is appended after these instead of prepended.
      runtimeDeps =
        pkgs: with pkgs; [
          android-tools
          avahi
          bash
          coreutils
          curl
          gawk
          git
          gnugrep
          gnused
          iproute2
          iw
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
                    --prefix PATH : ${lib.makeBinPath deps} \
                    --suffix PATH : ${lib.makeBinPath [ pkgs.networkmanager ]}
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
                  --prefix XDG_DATA_DIRS : "$schema_dirs:${dataDirs}" \
                  --set PHONE_LINK_VERSION ${version}
                # sudo's askpass: the graphical password prompt for a root
                # action, wrapped like the app so GTK and the package resolve.
                install -Dm755 ${./gui}/askpass "$out/libexec/phone-link-gui-askpass"
                patchShebangs "$out/libexec/phone-link-gui-askpass"
                wrapProgram "$out/libexec/phone-link-gui-askpass" \
                  --prefix PATH : ${lib.makeBinPath [ guiPython ]} \
                  --prefix GI_TYPELIB_PATH : ${typelibs} \
                  --prefix XDG_DATA_DIRS : "$schema_dirs:${dataDirs}" \
                  --suffix PYTHONPATH : "$out/share/phone-link-gui/lib/python"
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

          registry = pkgs.runCommand "phone-link-registry-check" { } ''
            # The single source is phone_link.actions: the shims,
            # commands/__init__.py and the docs/scripts.md table are generated
            # from it. Check the source tree first, then the packaged table
            # against the installed scripts.
            export PYTHONPATH=${./lib/python}
            export PYTHONDONTWRITEBYTECODE=1
            ${pkgs.python3}/bin/python3 -m phone_link.registry_gen --check --root ${./.}
            ${package}/bin/phone-link check-registry ${lib.escapeShellArgs scripts}
            touch $out
          '';

          # The packaged GUI resolves the same table and its GTK imports, which
          # a plain `python3 -m` check would not prove.
          gui-registry = pkgs.runCommand "phone-link-gui-registry-check" { } ''
            # GTK/fontconfig want a writable HOME in the build sandbox
            export HOME=$TMPDIR XDG_CACHE_HOME=$TMPDIR/cache
            mkdir -p "$XDG_CACHE_HOME"
            # Same generated files, checked from the source tree the GUI reads.
            export PYTHONPATH=${./lib/python}
            export PYTHONDONTWRITEBYTECODE=1
            ${pkgs.python3}/bin/python3 -m phone_link.registry_gen --check --root ${./.}
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

          # Everything a user or a maintainer runs: the entry points and the
          # shared shell, then every tracked script under tests/ — the suites,
          # the shared harness, check-timings.sh and the live runbooks. The test
          # list is read from the directory so a new suite cannot be forgotten.
          shellcheck =
            pkgs.runCommand "phone-link-shellcheck"
              {
                nativeBuildInputs = [ pkgs.shellcheck ];
              }
              ''
                shellcheck -S warning ${./bin}/* ${./lib}/*.sh ${./tests/run} ${
                  lib.escapeShellArgs (
                    lib.filter (path: lib.hasSuffix ".sh" (toString path)) (lib.filesystem.listFilesRecursive ./tests)
                  )
                }
                touch $out
              '';

          # Parse every Python module without importing it. The GUI modules
          # need GTK at import time, but `compileall` only reads syntax, so this
          # needs no display, no typelibs and no network. The copy is what gets
          # compiled: the store is read-only, and a stale `__pycache__` must not
          # be able to stand in for the source.
          python =
            pkgs.runCommand "phone-link-python-check"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                cp -r ${./lib/python} "$TMPDIR/python"
                chmod -R u+w "$TMPDIR/python"
                find "$TMPDIR/python" -name __pycache__ -type d -exec rm -rf {} +
                python3 -m compileall -q "$TMPDIR/python"
                touch $out
              '';

          # Lint and types over the same package: ruff reads ./pyproject.toml for
          # the rule set and the GI import exception, mypy for the paths and the
          # GTK stubs it does not have. Both write only to $TMPDIR, because the
          # source tree in the store is read-only.
          python-lint =
            pkgs.runCommand "phone-link-python-lint-check"
              {
                nativeBuildInputs = [
                  pkgs.mypy
                  pkgs.ruff
                ];
              }
              ''
                cd ${./.}
                export HOME=$TMPDIR
                export RUFF_CACHE_DIR=$TMPDIR/ruff-cache
                ruff check --no-cache .
                ruff format --no-cache --check .
                mypy --cache-dir=$TMPDIR/mypy-cache
                touch $out
              '';

          format = pkgs.runCommand "phone-link-format-check" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${./flake.nix} ${
              lib.escapeShellArgs (
                lib.filter (path: lib.hasSuffix ".nix" (toString path)) (
                  lib.filesystem.listFilesRecursive ./modules ++ lib.filesystem.listFilesRecursive ./tests/module
                )
              )
            }
            touch $out
          '';

          module = import ./tests/module {
            inherit
              lib
              pkgs
              self
              system
              ;
          };

          # Hermetic CLI tests: stub adb/curl first on PATH, no phone, no network.
          # The source script is used (not the wrapper), because wrapProgram
          # prepends its own PATH and would shadow the stubs.
          #
          # The check also times itself. `timings.csv` in the output has a row per
          # suite (`total`) plus whatever rows a suite contributes about its own
          # parts, so a suite with a slow compile reads differently from one with
          # slow tests. The build log ends with the slowest, because the question this
          # answers is asked mid-build: a check with no timing is a check nobody
          # can watch. `tests/check-timings.sh` keeps the history across builds.
          script =
            pkgs.runCommand "phone-link-script-check"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.gnused
                  pkgs.git
                  pkgs.python3
                ];
              }
              ''
                # One runner for the flake and for `tests/run` on a checkout:
                # it selects every tests/*.test.sh, runs each from the source
                # root (so ../bin and ../lib resolve), prints PASS/FAIL with the
                # seconds, and writes the same suite,part,ms rows this check
                # keeps. The timings file is the runner's only side output.
                PHONE_RUN_TIMINGS=$TMPDIR/timings.csv \
                  bash ${self.outPath}/tests/run --timings
                mkdir -p $out
                cp "$TMPDIR/timings.csv" $out/timings.csv
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

      nixosModules =
        let
          phoneLink = import ./modules/phone-link;
          failOpen = import ./modules/phone-link-failopen.nix;
        in
        {
          default = {
            imports = [
              phoneLink
              failOpen
            ];
          };
          phone-link = {
            imports = [
              phoneLink
              failOpen
            ];
          };
          fail-open = failOpen;
        };

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = runtimeDeps pkgs ++ [
            pkgs.shellcheck
            pkgs.nixfmt
            pkgs.ruff
            pkgs.mypy
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
          exec ${pkgs.nixfmt}/bin/nixfmt "''${files[@]}"
        ''
      );
    };
}
