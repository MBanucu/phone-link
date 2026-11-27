# Tests

The suites in this directory are hermetic: they stub `adb`, `curl`, `iw`,
`nmcli` and friends, and need no phone, no root and no network. The exceptions
are `tests/live/`, which drive real hardware and are never part of
`nix flake check`.

Every suite is a `tests/*.test.sh` file run by the flake's `script` check. Keep
that glob in mind: a suite outside `tests/*.test.sh` does not run in CI.

## Which suite for this change?

| You changed | Run |
| --- | --- |
| a `bin/` script | `tests/<script>.test.sh` (the suite named after the script) |
| unit logic in `lib/*.sh` | `phone-tun-toggle`, `phone-ap-rejoin`, `phone-ap-failopen` |
| the CLI, action registry, or root escalation | `phone-link-cli`, `phone-link-escalation`, `phone-as-root` |
| adb serial discovery or the phone's adb transport | `phone-adb-serial`, `phone-adb-mdns`, `phone-adb-wifi` |
| a NixOS module option or generated unit | the `module` check, not a shell suite (see #53) |
| a real phone, end to end | `tests/live/doctor-fix-proxy.sh` |

When a `bin/` script has no suite yet, its sibling suites are the closest
model. Adding a suite is covered below.

## Commands

```sh
# One suite. Run from anywhere; the suite finds the checkout itself.
bash tests/phone-ap-rejoin.test.sh

# Every suite, through the same glob CI uses.
nix build .#checks.x86_64-linux.script

# The cheap set before a push: format, shellcheck, python, module, script.
bash tests/check.sh fast

# The same build, keeping per-suite times in result-checks/timings.csv and
# printing each suite beside its last measurement.
bash tests/check-timings.sh

# The live doctor repair. Root, a phone and a USB tether; see below.
sudo tests/live/doctor-fix-proxy.sh
```

`bash tests/check-timings.sh` writes one `total` row per suite, plus any rows a
suite reports itself through `PHONE_TEST_TIMINGS`. A suite that stops appearing
in `timings.csv` is a suite the glob stopped finding.

## The shared harness

`tests/lib/harness.sh` is sourced, never executed. Sourcing it prints nothing,
changes no shell option and installs no trap. It is bash and coreutils only.

```sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib/harness.sh"
```

| Helper | Use |
| --- | --- |
| `ok DESCRIPTION` | record a passing assertion |
| `bad DESCRIPTION [DETAIL]` | record a failure, with captured output as the detail |
| `finish` | print `N passed, M failed` and exit non-zero if any failed |
| `tmpdir TMP` | create the temp directory and install the cleanup trap |
| `stub_cmd NAME [DIR]` | write a suite-specific stub from stdin (DIR defaults to `STUBS`) |
| `stub_adb [DIR]` | write the common device/install/shell/dumpsys adb stub |

Prefer `tmpdir TMP` over `TMP=$(tmpdir)`: a command substitution runs in a
subshell, so the cleanup trap installed there would not survive.

`stub_cmd` writes `DIR/NAME` with this bash as the interpreter, so build
sandboxes without `/usr/bin/env` work. Write the body as the script it will
become, without a shebang:

```sh
stub_cmd iw "$STUBS" <<'EOF'
case "$*" in
  list) printf '\t* AP\n\t* managed\n' ;;
esac
EOF
```

`stub_adb` logs every argv to `ADB_LOG` (default `$LOG/adb.log`), lists one
device, and answers the install, uninstall, pull, `pm path` and `dumpsys`
calls the proxy commands make. Its knobs are documented in the file:
`ADB_SERIAL`, `ADB_STUB_DEVICES`, `ADB_STUB_ABSENT`, `ADB_STUB_VERSION`,
`ADB_STUB_BAD_SIG` and `ADB_STUB_SHELL`.

A suite may keep its own `run`, fixtures and setup. The harness only replaces
the scaffolding every suite wrote the same way.

## New suite skeleton

This is under 30 lines to the first assertion. Copy it to
`tests/phone-example.test.sh` and replace the command and first case.

```sh
#!/usr/bin/env bash
# Hermetic tests for bin/phone-example: stub adb, no phone, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-example

. "$ROOT/tests/lib/harness.sh"
tmpdir TMP
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
mkdir -p "$LOG" "$STUBS"

stub_adb "$STUBS"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. What the first case proves.
if run --check; then ok "--check exits 0"; else bad "--check exits 0" "$(cat "$LOG/out")"; fi

finish
```

## Migrating a suite

1. Source the harness after `ROOT` is known and replace `mktemp`/`trap` with
   `tmpdir TMP`.
2. Delete the local `pass`/`fail`, `ok` and `bad`; replace the final count and
   `[ "$fail" -eq 0 ]` with `finish`.
3. Replace the adb stub with `stub_adb` when it has the common shape, and the
   remaining stubs with `stub_cmd` when their bodies are unchanged.
4. Do not change an assertion, its description, or what it proves. Run the
   suite before and after and diff the `ok` lines and exit status.
5. `shellcheck -S warning tests/<suite>.test.sh tests/lib/harness.sh`.

## Live tests

`tests/live/doctor-fix-proxy.sh` is the real-phone test of the doctor's repair.
It is not part of the `script` check and deliberately does not end in
`.test.sh`.

- **Run it with `sudo`**: it reads the root-only secrets and changes the AP.
- **Preconditions**: a phone attached over adb on a route that does not depend
  on the AP, a USB tether so the proxy can answer while the AP is down, and the
  app's checkout built once (`PHONE_PROXY_APP`, default `../phone-link-proxy`)
  or an APK in `PHONE_PROXY_APK`.
- **Cost**: it runs the test package (`org.phonelink.proxy.test`, port 18080),
  so the daily app's saved proxies, listener and port are left alone. It is
  still destructive: the test app's data is lost and the AP is dropped until
  the fixer restores it. Nothing is downloaded; the repair installs a file that
  is already in the checkout.

`tests/live/hairpin-measure.sh` measures the AP hairpin. Its hermetic suite is
`tests/hairpin-measure.test.sh`; run the live script directly only when the
measurement is the point.
