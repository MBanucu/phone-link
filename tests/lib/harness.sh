# shellcheck shell=bash
# Shared scaffolding for the hermetic shell suites.
#
#   . "$ROOT/tests/lib/harness.sh"
#   suite                     # temp dir, LOG, STUBS, HOME, PATH, cleanup
#   stub nmcli                 # a stub that logs its argv and answers from below
#   answer nmcli <<'EOF'
#   case "$*" in ...
#   EOF
#
# Sourcing this file defines functions and counters only: it prints nothing,
# changes no option and installs no trap.  The trap is installed by `suite`,
# because only then is there a path to remove.  bash and coreutils only.
#
# A suite keeps its own fixtures and `run` wrapper; these helpers replace the
# parts every suite wrote the same way: the temporary directory, the PATH with
# stubs first, the call log and the pass/fail count.

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

# _suite_path DIR PATH — print PATH, resolving a relative PATH under DIR.
_suite_path() {
  case $2 in
    '') printf '%s' "$1" ;;
    .) printf '%s' "$1" ;;
    /*) printf '%s' "$2" ;;
    *) printf '%s/%s' "$1" "$2" ;;
  esac
}

# suite [TMPVAR] [--log DIR] [--stubs DIR] [--home DIR] [--no-home]
#
# The one entry point a suite calls before its first stub.  It creates the
# temporary directory (TMP by default, or the named variable), exports LOG,
# STUBS and HOME as subdirectories of it, makes them, and puts STUBS first on
# PATH.  The temporary directory is removed at exit.  DIR arguments may be
# relative to the temporary directory; `--log .` means the temporary directory
# itself.
#
# ROOT is located as the parent of the directory the calling suite lives in
# when the suite has not set it already, so every suite resolves the checkout
# the same way.  BASH_BIN is exported for the suites that run a script with it.
suite() {
  local tmpvar=TMP log_rel=log stubs_rel=bin home_rel=. want_home=1 dir
  while [ "$#" -gt 0 ]; do
    case $1 in
      --log)
        log_rel=${2:?suite: --log needs a directory}
        shift 2
        ;;
      --stubs)
        stubs_rel=${2:?suite: --stubs needs a directory}
        shift 2
        ;;
      --home)
        home_rel=${2:?suite: --home needs a directory}
        shift 2
        ;;
      --no-home)
        want_home=0
        shift
        ;;
      -*)
        printf 'suite: unknown option: %s\n' "$1" >&2
        return 2
        ;;
      *)
        tmpvar=$1
        shift
        ;;
    esac
  done

  if [ -z "${ROOT:-}" ]; then
    ROOT=$(cd "$(dirname "${BASH_SOURCE[1]:-tests/lib/harness.sh}")/.." && pwd) ||
      return 1
    export ROOT
  fi

  tmpdir "$tmpvar" || return 1
  printf -v dir '%s' "${!tmpvar}"

  LOG=$(_suite_path "$dir" "$log_rel")
  STUBS=$(_suite_path "$dir" "$stubs_rel")
  export LOG STUBS
  if [ "$want_home" -eq 1 ]; then
    HOME=$(_suite_path "$dir" "$home_rel")
    export HOME
    mkdir -p "$HOME" || return 1
  fi
  mkdir -p "$LOG" "$STUBS" || return 1
  PATH=$STUBS:$PATH
  export PATH
  BASH_BIN=${BASH_BIN:-${BASH:-$(command -v bash)}}
  export BASH_BIN
}

# stub_cmd NAME [DIR] — write an executable stub at DIR/NAME (DIR defaults to
# STUBS) from stdin, with this bash as its interpreter.  Use it for a stub that
# is wholly specific to one suite; use `stub NAME` + `answer` for the usual
# shape, where the harness writes the log and the suite only writes the answer.
#
#   stub_cmd iw <<'EOF'
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
    printf '#!%s\n' "${BASH:-/bin/bash}"
    cat
  } >"$dir/$name" || return
  chmod +x "$dir/$name"
}

# answer NAME [FILE] — write the answer script for stub NAME from FILE or
# stdin.  The stub calls it with the original argv after logging the call, so
# the answer only has to decide what to print and which status to return.
#
#   answer nmcli <<'EOF'
#   case "$*" in
#     "-t -f NAME con show") cat "$LOG/names" ;;
#   esac
#   EOF
#
# Do not repeat the shebang; `answer` adds this bash as the interpreter.
answer() {
  local name=${1:-} file=${2:-} dir=${STUBS:-}
  if [ -z "$name" ] || [ -z "$dir" ]; then
    printf 'answer: usage: answer NAME [FILE] (or set STUBS)\n' >&2
    return 2
  fi
  mkdir -p "$dir" || return
  {
    printf '#!%s\n' "${BASH:-/bin/bash}"
    if [ -n "$file" ]; then
      cat "$file"
    else
      cat
    fi
  } >"$dir/.$name.answer" || return
  chmod +x "$dir/.$name.answer"
}

# stub NAME [DIR] — write an executable stub at DIR/NAME (DIR defaults to
# STUBS).  Every call appends its argv to LOG/NAME.log, so each stub has one
# call log and a suite can tell the commands apart.  If DIR/.NAME.answer exists
# (written by `answer`), it runs with the same argv and its status is the
# stub's; otherwise the stub succeeds and prints nothing.
#
# `stub adb` is the common device/install/shell/dumpsys adb stub (stub_adb),
# and still honours `answer adb` for a suite that needs a different phone.
stub() {
  local name=${1:-} dir=${2:-${STUBS:-}} answer
  if [ -z "$name" ] || [ -z "$dir" ]; then
    printf 'stub: usage: stub NAME [DIR] (or set STUBS)\n' >&2
    return 2
  fi
  if [ "$name" = adb ]; then
    stub_adb "$dir"
    return
  fi
  mkdir -p "$dir" || return
  answer=$dir/.$name.answer
  {
    printf '#!%s\n' "${BASH:-/bin/bash}"
    printf 'log=${LOG:-%s}/%s.log\n' "$dir" "$name"
    printf 'mkdir -p "${log%%/*}" 2>/dev/null || true\n'
    printf 'printf "%%s\\n" "$*" >>"$log"\n'
    printf 'answer=%q\n' "$answer"
    printf 'if [ -x "$answer" ]; then exec "$answer" "$@"; fi\n'
    printf 'exit 0\n'
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
# `answer adb` (DIR/.adb.answer) replaces all the answers with a suite's own,
# while this stub still does the logging.  The full argv, including `-s`, is
# logged.  For the built-in answers `-s SERIAL` is accepted and stripped, so
# the suite sees the same argv the scripts send.
stub_adb() {
  local dir=${1:-${STUBS:-}}
  if [ -z "$dir" ]; then
    printf 'stub_adb: usage: stub_adb [DIR] (or set STUBS)\n' >&2
    return 2
  fi
  mkdir -p "$dir" || return
  {
    printf '#!%s\n' "${BASH:-/bin/bash}"
    cat <<'ADB'
log=${ADB_LOG:-$LOG/adb.log}
mkdir -p "$(dirname "$log")" 2>/dev/null || true
printf '%s\n' "$*" >>"$log"

answer=__ADB_ANSWER__
if [ -x "$answer" ]; then
  "$answer" "$@"
  exit $?
fi

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
          || printf '        versionName=%s\r\n  contract_version 1\r\n' \
            "${ADB_STUB_VERSION:-1.7.4}"
        ;;
    esac
    ;;
esac

exit 0
ADB
  } | awk -v answer="$dir/.adb.answer" '{ gsub(/__ADB_ANSWER__/, answer); print }' \
    >"$dir/adb" || return
  chmod +x "$dir/adb"
}
