#!/usr/bin/env bash
# Hermetic tests for the proxy app's Android-free logic: the SOCKS5 protocol,
# the configuration rules and the state text. Plain JDK, no phone, no Android
# SDK and no network.
#
#   bash tests/proxy-app.test.sh
#
# These classes are compiled without android.jar, which is only possible because
# they carry no Android types: the logging and the upstream connection are
# seams, not framework calls.
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
  "$ROOT/android/src/org/phonelink/proxy/EventLog.java"
  "$ROOT/android/src/org/phonelink/proxy/Help.java"
  "$ROOT/android/src/org/phonelink/proxy/ProxyConfig.java"
  "$ROOT/android/src/org/phonelink/proxy/ProxyState.java"
  "$ROOT/android/src/org/phonelink/proxy/ProxyRuntime.java"
  "$ROOT/android/src/org/phonelink/proxy/TileCycle.java"
  "$ROOT/android/src/org/phonelink/proxy/TilePlan.java"
  "$ROOT/android/src/org/phonelink/proxy/TileScope.java"
  "$ROOT/android/src/org/phonelink/proxy/Socks5Server.java"
  "$ROOT/android/src/org/phonelink/proxy/Traffic.java"
  "$ROOT/android/test/org/phonelink/proxy/ProxyAppTest.java"
)

# The compile is a part of this suite's time worth naming: it is one javac
# over twelve files, and when the whole check gets slower it matters whether
# that or the cases did. PHONE_TEST_TIMINGS=<file> gets `part,ms` rows the
# flake's script check folds into its timings.csv.
started=$(date +%s%N)
if ! "$JAVAC" -encoding UTF-8 -d "$TMP/classes" "${sources[@]}"; then
  printf '\n0 passed, 1 failed\n'
  exit 1
fi
compiled=$(date +%s%N)
part_timing() { # part_timing PART START END
  local ms=$(((($3 - $2)) / 1000000))
  printf '  %-6s %6s ms\n' "$1" "$ms"
  if [ -n "${PHONE_TEST_TIMINGS:-}" ]; then
    printf '%s,%s\n' "$1" "$ms" >>"$PHONE_TEST_TIMINGS"
  fi
}
part_timing javac "$started" "$compiled"

"$JAVA" -cp "$TMP/classes" org.phonelink.proxy.ProxyAppTest
status=$?
part_timing cases "$compiled" "$(date +%s%N)"
exit $status
