# The build shell and the APK derivation for the proxy app: a JDK, an Android
# SDK with build-tools and one platform, and zip. Kept out of flake.nix so the
# flake stays wiring and the SDK (which is large) stays in a shell of its own.
#
# The Android SDK license is per-evaluation configuration, not a package
# argument, so nixpkgs is imported again here instead of reusing
# nixpkgs.legacyPackages.
{ pkgs, nixpkgs }:
let
  androidPkgs = import nixpkgs.outPath {
    system = pkgs.stdenv.hostPlatform.system;
    config = {
      android_sdk.accept_license = true;
      # Google's SDK components are unfree under several names (cmdline-tools,
      # platform-tools, build-tools, the platform zips), so this private nixpkgs
      # instance allows unfree rather than keeping a list that changes with the
      # SDK version. Nothing from here leaks into the other shells.
      allowUnfree = true;
    };
  };
  sdk = androidPkgs.androidenv.composeAndroidPackages {
    buildToolsVersions = [ "35.0.0" ];
    platformVersions = [ "35" ];
    includeCmake = false;
    includeEmulator = false;
    includeNDK = false;
    includeSources = false;
    includeSystemImages = false;
  };
  sdkRoot = "${sdk.androidsdk}/libexec/android-sdk";
in
{
  inherit sdkRoot;

  shell = pkgs.mkShell {
    packages = [
      androidPkgs.jdk17
      androidPkgs.zip
    ];
    ANDROID_SDK_ROOT = sdkRoot;
    shellHook = ''
      export ANDROID_HOME="$ANDROID_SDK_ROOT"
      echo "android: $ANDROID_SDK_ROOT"
      # The flake's build sees only the git tree: a new source file that nobody
      # added is missing from it, and the "cannot find symbol" errors that follow
      # read as a bug in the code just written.
      if command -v git >/dev/null 2>&1; then
        untracked=$(git ls-files --others --exclude-standard -- android 2>/dev/null |
          grep -E '\.(java|xml)$' || true)
        if [ -n "$untracked" ]; then
          printf '\nnote: untracked files are invisible to nix build:\n%s\n\n' "$untracked" >&2
        fi
      fi
    '';
  };

  # Compiled by `nix flake check`, and available as packages.<system>.proxy-apk.
  # The signing key is generated inside the build, so the artifact is valid but
  # not reproducible; installing it next to a phone-link build is the intent.
  apk =
    pkgs.runCommand "phone-link-proxy-apk"
      {
        nativeBuildInputs = [
          androidPkgs.jdk17
          androidPkgs.zip
        ];
        ANDROID_SDK_ROOT = sdkRoot;
      }
      ''
        export HOME=$TMPDIR
        cp -r ${./.} app
        chmod -R u+w app
        ./app/build.sh
        install -Dm644 app/build/phone-link-proxy.apk $out/phone-link-proxy.apk
        # The test-only accessibility service the live harness takes its dumps
        # from, and the test-only instrumentation that runs the panel's checks
        # inside the proxy's process; nothing installs them but a test run.
        install -Dm644 app/build/capture.apk $out/capture.apk
        install -Dm644 app/build/devicetest.apk $out/devicetest.apk
      '';
}
