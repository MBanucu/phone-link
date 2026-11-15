#!/bin/sh
# Build the APKs of this project without Gradle: aapt2, javac, d8, zipalign,
# apksigner. No AndroidX and no third-party dependencies means no repository to
# resolve, so the build works offline once the SDK is in the store.
#
# Two APKs come out of it:
#
#   build/phone-link-proxy.apk  the proxy itself (sources in src/, res/)
#   build/capture.apk           the test-only accessibility service that writes
#                               the screen as XML for the live harness
#                               (sources in capture/)
#   build/devicetest.apk        the test-only instrumentation that runs the
#                               panel's own checks inside the proxy's process
#                               (sources in devicetest/)
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd -P)
build="$here/build"

sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
if [ -z "$sdk" ]; then
    echo "build.sh: ANDROID_SDK_ROOT is not set; run inside 'nix develop .#android'" >&2
    exit 2
fi
if ! command -v javac >/dev/null 2>&1; then
    echo "build.sh: javac is not on PATH; run inside 'nix develop .#android'" >&2
    exit 2
fi

# Newest build-tools and platform the SDK carries, so a version bump in the
# flake does not need an edit here.
newest() {
    # -L: the SDK composes its directories as symlinks to their store paths.
    find -L "$1" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
        sort -V | tail -1
}
build_tools="$sdk/build-tools/$(newest "$sdk/build-tools")"
platform="$sdk/platforms/$(newest "$sdk/platforms")"
if [ -z "$build_tools" ] || [ ! -x "$build_tools/aapt2" ]; then
    echo "build.sh: no build-tools with aapt2 under $sdk" >&2
    exit 2
fi
android_jar="$platform/android.jar"
if [ ! -f "$android_jar" ]; then
    echo "build.sh: no android.jar under $sdk/platforms" >&2
    exit 2
fi

echo "build-tools: $build_tools"
echo "platform:    $android_jar"

rm -rf "$build"
mkdir -p "$build"

# One fixed key, tracked in the repository, so every build carries the same
# signature and `adb install -r` updates the app instead of refusing it. Only
# generated when the file is missing, e.g. in a checkout that lost it; the key
# is a throwaway debug key, which is why nothing here is secret.
keystore="$here/debug.keystore"
if [ ! -f "$keystore" ]; then
    keytool -genkeypair \
        -keystore "$keystore" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=phone-link proxy debug" >/dev/null 2>&1
fi

# build_apk NAME SOURCE_DIR RESOURCE_DIR MANIFEST
build_apk() {
    name=$1
    src=$2
    res=$3
    manifest=$4
    work="$build/$name"
    mkdir -p "$work/res" "$work/gen" "$work/classes" "$work/dex"

    "$build_tools/aapt2" compile --dir "$res" -o "$work/res/resources.zip"
    "$build_tools/aapt2" link \
        --manifest "$manifest" \
        --java "$work/gen" \
        -I "$android_jar" \
        -o "$work/unaligned.apk" \
        "$work/res/resources.zip"

    find "$src" "$work/gen" -name '*.java' -print | sort > "$work/sources.txt"
    # The sources are whatever is in this tree, and the tree is a store path
    # when the flake builds — a copy of git, so a file nobody committed does not
    # exist here. javac then blames the classes that use it, which reads as a
    # bug in code that compiles fine in the checkout. Say what the suspect is.
    if ! javac --release 11 -encoding UTF-8 -Xlint:all -Werror \
        -classpath "$android_jar" \
        -d "$work/classes" \
        @"$work/sources.txt"; then
        echo "build.sh: $name did not compile; if a class was just added, make" >&2
        echo "          sure it is committed: nix build sees only the git tree" >&2
        return 1
    fi

    # shellcheck disable=SC2046 # the build directory is ours and holds no spaces
    "$build_tools/d8" --lib "$android_jar" --min-api 29 --output "$work/dex" \
        $(find "$work/classes" -name '*.class' -print)

    cp "$work/unaligned.apk" "$work/base.apk"
    # Stored, not deflated: ART maps the dex in place rather than unpacking it.
    (cd "$work/dex" && zip -q -0 "$work/base.apk" classes.dex)

    "$build_tools/zipalign" -f -p 4 "$work/base.apk" "$work/aligned.apk"

    apk="$build/$name.apk"
    "$build_tools/apksigner" sign \
        --ks "$keystore" --ks-pass pass:android --key-pass pass:android \
        --ks-key-alias androiddebugkey \
        --out "$apk" "$work/aligned.apk"
    "$build_tools/apksigner" verify --print-certs "$apk" | head -3

    echo "built $apk ($(wc -c < "$apk") bytes)"
}

build_apk phone-link-proxy "$here/src" "$here/res" "$here/AndroidManifest.xml"
build_apk capture "$here/capture/src" "$here/capture/res" "$here/capture/AndroidManifest.xml"
build_apk devicetest "$here/devicetest/src" "$here/devicetest/res" "$here/devicetest/AndroidManifest.xml"
