# shellcheck shell=bash
# Shared scaffolding for the hermetic shell suites.
#
#   . "$ROOT/tests/lib/harness.sh"
#   tmpdir TMP
#   stub_adb "$TMP/bin"
#
# Sourcing this file defines functions and counters only: it prints nothing,
# changes no option and installs no trap.  The trap is installed by `tmpdir`,
# because only then is there a path to remove.  bash and coreutils only.
#
# A suite keeps its own setup, fixtures and `run` wrapper; these helpers replace
# the parts every suite wrote the same way.

HARNESS_PASS=0
HARNESS_FAIL=0
HARNESS_TMPDIR=

# ok DESCRIPTION — record a passing assertion.
ok() {
  HARNESS_PASS=$((HARNESS_PASS + 1))
  printf 'ok   %s\n' "$*"
}

# bad DESCRIPTION [DETAIL] — record a failing assertion, with a detail on the
# same line when the caller has one (usually the captured output).
bad() {
  HARNESS_FAIL=$((HARNESS_FAIL + 1))
  if [ -n "${2:-}" ]; then
    printf 'FAIL %s (%s)\n' "$1" "$2"
  else
    printf 'FAIL %s\n' "$1"
  fi
}

# finish — print the count and exit non-zero if any assertion failed.  Call it
# as the last line of a suite; it does not exit on success, so the exit status
# is still the script's.
finish() {
  printf '\n%d passed, %d failed\n' "$HARNESS_PASS" "$HARNESS_FAIL"
  if [ "$HARNESS_FAIL" -ne 0 ]; then
    exit 1
  fi
}

# tmpdir [VARIABLE] — create the suite's temporary directory on first use and
# arrange to remove it at exit.  With a variable name, assign the path to it
# (`tmpdir TMP`); without one, print it.  Prefer the variable form: a command
# substitution runs in a subshell, so the EXIT trap would be lost.
tmpdir() {
  if [ -z "$HARNESS_TMPDIR" ]; then
    HARNESS_TMPDIR=$(mktemp -d) || return 1
    trap 'rm -rf -- "$HARNESS_TMPDIR"' EXIT
  fi
  if [ -n "${1:-}" ]; then
    printf -v "$1" '%s' "$HARNESS_TMPDIR"
  else
    printf '%s\n' "$HARNESS_TMPDIR"
  fi
}

# stub_cmd NAME [DIR] — write an executable stub at DIR/NAME (DIR defaults to
# STUBS) from stdin, with this bash as its interpreter.  Use it for a stub that
# is specific to one suite; use stub_adb for the usual adb shape.
#
#   stub_cmd iw <<'EOF'
#   #!/usr/bin/env bash
#   ...
#   EOF
#
# The body is copied verbatim: write it as the script it will become, and do
# not repeat the shebang.
stub_cmd() {
  local name=${1:-} dir=${2:-${STUBS:-}}
  if [ -z "$name" ] || [ -z "$dir" ]; then
    printf 'stub_cmd: usage: stub_cmd NAME [DIR] (or set STUBS)\n' >&2
    return 2
  fi
  mkdir -p "$dir" || return
  {
    printf '#!%s\n' "$BASH"
    cat
  } >"$dir/$name" || return
  chmod +x "$dir/$name"
}

# stub_adb [DIR] — write the common adb stub at DIR/adb (DIR defaults to STUBS).
#
# It logs every argv to ADB_LOG (default $LOG/adb.log), lists one attached
# device, succeeds at install/uninstall, writes a pulled file, and answers the
# shell calls the proxy commands make.  Knobs, all optional:
#
#   ADB_LOG             log path; parent directories are created
#   ADB_SERIAL          serial in `adb devices`; default TESTPHONE
#   ADB_STUB_DEVICES    file whose contents are the `devices` answer
#   ADB_STUB_ABSENT=1   `pm path` and `dumpsys` answer nothing
#   ADB_STUB_VERSION    versionName in the dumpsys answer; default 1.7.4
#   ADB_STUB_BAD_SIG=1  install fails the way a different signing key does
#   ADB_STUB_SHELL      executable called with the words after `shell`, instead
#                       of the built-in pm path / dumpsys answers
#
# `-s SERIAL` is accepted and stripped, so the suite sees the same argv the
# scripts send; the full argv, including -s, is what gets logged.
stub_adb() {
  local dir=${1:-${STUBS:-}}
  if [ -z "$dir" ]; then
    printf 'stub_adb: usage: stub_adb [DIR] (or set STUBS)\n' >&2
    return 2
  fi
  mkdir -p "$dir" || return
  {
    printf '#!%s\n' "$BASH"
    cat <<'ADB'
log=${ADB_LOG:-$LOG/adb.log}
mkdir -p "$(dirname "$log")" 2>/dev/null || true
printf '%s\n' "$*" >>"$log"

args=("$@")
if [ "${args[0]:-}" = "-s" ]; then
  args=("${args[@]:2}")
fi
cmd=${args[*]:-}

case "${args[0]:-}" in
  devices)
    if [ -n "${ADB_STUB_DEVICES:-}" ] && [ -f "$ADB_STUB_DEVICES" ]; then
      cat "$ADB_STUB_DEVICES"
    else
      printf 'List of devices attached\n%s\tdevice\n\n' \
        "${ADB_SERIAL:-TESTPHONE}"
    fi
    ;;
  install | install-multiple)
    if [ "${ADB_STUB_BAD_SIG:-0}" = 1 ]; then
      printf 'Performing Streamed Install\n'
      printf 'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package org.phonelink.proxy signatures do not match previously installed version; ignoring!]\n'
      exit 1
    fi
    printf 'Performing Streamed Install\nSuccess\n'
    ;;
  uninstall)
    printf 'Success\n'
    ;;
  pull)
    target=${args[2]:-}
    if [ -n "$target" ]; then
      mkdir -p "$target"
      printf 'apkbytes' >"$target/$(basename "${args[1]:-base.apk}")"
    fi
    ;;
  shell)
    if [ -n "${ADB_STUB_SHELL:-}" ] && [ -x "$ADB_STUB_SHELL" ]; then
      "$ADB_STUB_SHELL" "${args[@]:1}"
      exit $?
    fi
    case "$cmd" in
      *"pm path"*)
        [ "${ADB_STUB_ABSENT:-0}" = 1 ] \
          || printf 'package:/data/app/x/base.apk\r\n'
        ;;
      *dumpsys*)
        [ "${ADB_STUB_ABSENT:-0}" = 1 ] \
          || printf '        versionName=%s\r\n' "${ADB_STUB_VERSION:-1.7.4}"
        ;;
    esac
    ;;
esac

exit 0
ADB
  } >"$dir/adb" || return
  chmod +x "$dir/adb"
}
