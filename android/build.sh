#!/bin/sh
# Build the phone-link proxy APK without Gradle: aapt2, javac, d8, zipalign,
# apksigner. No AndroidX and no third-party dependencies means no repository to
# resolve, so the build works offline once the SDK is in the store.
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
mkdir -p "$build/res" "$build/gen" "$build/classes" "$build/dex"

"$build_tools/aapt2" compile --dir "$here/res" -o "$build/res/resources.zip"
"$build_tools/aapt2" link \
    --manifest "$here/AndroidManifest.xml" \
    --java "$build/gen" \
    -I "$android_jar" \
    -o "$build/unaligned.apk" \
    "$build/res/resources.zip"

find "$here/src" "$build/gen" -name '*.java' -print | sort > "$build/sources.txt"
javac --release 11 -Xlint:all -Werror \
    -classpath "$android_jar" \
    -d "$build/classes" \
    @"$build/sources.txt"

# shellcheck disable=SC2046 # the build directory is ours and holds no spaces
"$build_tools/d8" --lib "$android_jar" --min-api 29 --output "$build/dex" \
    $(find "$build/classes" -name '*.class' -print)

cp "$build/unaligned.apk" "$build/base.apk"
# Stored, not deflated: ART maps the dex in place rather than unpacking it.
(cd "$build/dex" && zip -q -0 "$build/base.apk" classes.dex)

"$build_tools/zipalign" -f -p 4 "$build/base.apk" "$build/aligned.apk"

# Outside build/ so rebuilding keeps the signature and `adb install -r` works.
keystore="$here/debug.keystore"
if [ ! -f "$keystore" ]; then
    keytool -genkeypair \
        -keystore "$keystore" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=phone-link proxy debug" >/dev/null 2>&1
fi

apk="$build/phone-link-proxy.apk"
"$build_tools/apksigner" sign \
    --ks "$keystore" --ks-pass pass:android --key-pass pass:android \
    --ks-key-alias androiddebugkey \
    --out "$apk" "$build/aligned.apk"
"$build_tools/apksigner" verify --print-certs "$apk" | head -3

echo "built $apk ($(wc -c < "$apk") bytes)"
