# The build shell for the proxy APK: a JDK, an Android SDK with build-tools and
# one platform, and zip. Kept out of flake.nix so the flake stays wiring and the
# SDK (which is large) stays in a shell of its own.
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
in
pkgs.mkShell {
  packages = [
    androidPkgs.jdk17
    androidPkgs.zip
  ];
  ANDROID_SDK_ROOT = "${sdk.androidsdk}/libexec/android-sdk";
  shellHook = ''
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
    echo "android: $ANDROID_SDK_ROOT"
  '';
}
