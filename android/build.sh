#!/bin/sh
# Build the APKs of this project without Gradle: aapt2, javac, d8, zipalign,
# apksigner. No AndroidX and no third-party dependencies means no repository to
# resolve, so the build works offline once the SDK is in the store.
#
# The APKs that come out of it:
#
#   build/phone-link-proxy.apk  the proxy itself (sources in src/, res/)
#   build/phone-link-proxy-test.apk
#                               the same app under its own package,
#                               org.phonelink.proxy.test, so an unstable build
#                               can be installed next to the one the phone lives
#                               on: own store, own listeners, own notification,
#                               own tile
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

# Signing. Two keys, one code path: `debug.keystore`, tracked in the repository,
# so every build carries the same signature and `adb install -r` updates the app
# instead of refusing it; and, when one is named in the environment, a release
# key, which is what an APK meant for other people is signed with.
#
#   PHONE_APP_KEYSTORE       the keystore file (JKS or PKCS12)
#   PHONE_APP_KEY_ALIAS      the key inside it
#   PHONE_APP_KEYSTORE_PASS  its store password
#   PHONE_APP_KEY_PASS       the key's password, if it is not the store's
#
# The passwords reach apksigner as `env:` references, so neither appears in a
# process listing or in the log of the job that built the release.
keystore="$here/debug.keystore"
key_alias=androiddebugkey
ks_pass=pass:android
key_pass=pass:android
if [ -n "${PHONE_APP_KEYSTORE:-}" ]; then
    keystore=$PHONE_APP_KEYSTORE
    key_alias=${PHONE_APP_KEY_ALIAS:-}
    ks_pass=env:PHONE_APP_KEYSTORE_PASS
    key_pass=${PHONE_APP_KEY_PASS:+env:PHONE_APP_KEY_PASS}
    if [ ! -f "$keystore" ]; then
        echo "build.sh: PHONE_APP_KEYSTORE is not a file: $keystore" >&2
        exit 2
    fi
    if [ -z "$key_alias" ]; then
        echo "build.sh: PHONE_APP_KEY_ALIAS is required with PHONE_APP_KEYSTORE" >&2
        exit 2
    fi
    if [ -z "${PHONE_APP_KEYSTORE_PASS:-}" ]; then
        echo "build.sh: PHONE_APP_KEYSTORE_PASS is required with PHONE_APP_KEYSTORE" >&2
        exit 2
    fi
fi

# The debug key is a throwaway, which is why nothing here is secret; it is only
# generated when the file is missing, e.g. in a checkout that lost it, and never
# when a release key is what will sign the build.
if [ -z "${PHONE_APP_KEYSTORE:-}" ] && [ ! -f "$keystore" ]; then
    keytool -genkeypair \
        -keystore "$keystore" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=phone-link proxy debug" >/dev/null 2>&1
fi

# The project's version, stamped into the manifest at build time: a phone that
# reports 0.1.0 for every release cannot be asked which one it runs. The tracked
# manifest is a template, `android/version` is the one source, and
# `nix flake check` refuses it drifting from the flake's `version`.
app_version=$(tr -d '[:space:]' <"$here/version")
case $app_version in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "build.sh: android/version is not X.Y.Z: '$app_version'" >&2
        exit 2
        ;;
esac
# Only ever up: 0.8.1 must sort above 0.8.0 on the phone too.
app_code=$(printf '%s' "$app_version" \
    | awk -F. '{ printf "%d%02d%02d", $1, $2, $3 }')

# build_apk NAME SOURCE_DIR RESOURCE_DIR MANIFEST [PACKAGE]
#
# PACKAGE relinks the manifest under another application id. The classes keep
# the package they were compiled in, so a component is addressed by the full
# class name as well — see the manifest's header.
build_apk() {
    name=$1
    src=$2
    res=$3
    manifest=$4
    package=${5:-}
    # The stamped copy, not the template: unaligned.apk is what ships.
    stamped="$build/$name/AndroidManifest.xml"
    mkdir -p "$build/$name"
    sed -e "s/android:versionCode=\"[^\"]*\"/android:versionCode=\"$app_code\"/" \
        -e "s/android:versionName=\"[^\"]*\"/android:versionName=\"$app_version\"/" \
        "$manifest" >"$stamped"
    manifest=$stamped
    work="$build/$name"
    mkdir -p "$work/res" "$work/gen" "$work/classes" "$work/dex"

    "$build_tools/aapt2" compile --dir "$res" -o "$work/res/resources.zip"
    if [ -n "$package" ]; then
        set -- link --rename-manifest-package "$package"
    else
        set -- link
    fi
    "$build_tools/aapt2" "$@" \
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
    set -- --ks "$keystore" --ks-pass "$ks_pass" --ks-key-alias "$key_alias"
    if [ -n "$key_pass" ]; then
        set -- "$@" --key-pass "$key_pass"
    fi
    "$build_tools/apksigner" sign "$@" --out "$apk" "$work/aligned.apk"
    "$build_tools/apksigner" verify --print-certs "$apk" | head -3

    echo "built $apk ($(wc -c < "$apk") bytes)"
}

build_apk phone-link-proxy "$here/src" "$here/res" "$here/AndroidManifest.xml"

# The same app under org.phonelink.proxy.test, which is what the live harness
# installs, so a test run never replaces the proxy the phone uses every day.
# Only the label differs: two identical "Phone link proxy" entries in the
# launcher and two identical "Proxy" tiles are a thing to avoid.
test_res="$build/phone-link-proxy-test-res"
cp -r "$here/res" "$test_res"
sed -i \
    -e 's|<string name="app_name">[^<]*</string>|<string name="app_name">Phone link proxy (test)</string>|' \
    -e 's|<string name="tile_label">[^<]*</string>|<string name="tile_label">Proxy (test)</string>|' \
    "$test_res/values/strings.xml"
build_apk phone-link-proxy-test "$here/src" "$test_res" \
    "$here/AndroidManifest.xml" org.phonelink.proxy.test
build_apk capture "$here/capture/src" "$here/capture/res" "$here/capture/AndroidManifest.xml"
# The instrumentation runs inside the app under test, so its manifest has to
# name that application id: the live harness drives the test package, and
# PROXY_APP_ID names another build for a run against it.
proxy_id=${PROXY_APP_ID:-org.phonelink.proxy.test}
test_manifest="$build/devicetest-manifest.xml"
sed -e "s|android:targetPackage=\"[^\"]*\"|android:targetPackage=\"$proxy_id\"|" \
    "$here/devicetest/AndroidManifest.xml" >"$test_manifest"
build_apk devicetest "$here/devicetest/src" "$here/devicetest/res" "$test_manifest"
