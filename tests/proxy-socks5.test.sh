#!/usr/bin/env bash
# Hermetic tests for the proxy app's SOCKS5 protocol: plain JDK, no phone, no
# Android SDK and no network.
#
#   bash tests/proxy-socks5.test.sh
#
# The protocol classes are compiled without android.jar, which is only possible
# because Socks5Server and Upstream carry no Android types: the logging and the
# upstream connection are seams, not framework calls.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

JAVAC=${JAVAC:-javac}
JAVA=${JAVA:-java}
for tool in "$JAVAC" "$JAVA"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'missing %s: run this in nix develop .#android, or install a JDK\n' "$tool" >&2
    exit 2
  fi
done

sources=(
  "$ROOT/android/src/org/phonelink/proxy/Upstream.java"
  "$ROOT/android/src/org/phonelink/proxy/Closeables.java"
  "$ROOT/android/src/org/phonelink/proxy/Socks5Server.java"
  "$ROOT/android/test/org/phonelink/proxy/Socks5ServerTest.java"
)

if ! "$JAVAC" -d "$TMP/classes" "${sources[@]}"; then
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

exec "$JAVA" -cp "$TMP/classes" org.phonelink.proxy.Socks5ServerTest
