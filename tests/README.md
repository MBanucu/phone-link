# Tests

The suites in this directory are hermetic: they stub `adb`, `curl`, `iw`,
`nmcli`, `systemctl` and friends, and need no phone, no root and no network. The
exceptions are `tests/live/`, which drive real hardware and are never part of
`nix flake check`.

Every suite is a `tests/*.test.sh` file. `tests/run` finds them, and the flake's
`script` check calls the same runner over the same glob, so a suite outside
`tests/*.test.sh` does not run in CI. `tests/run --list` prints what a selection
would run.

## Which suite for this change?

The index below reads as *suite → what it proves → the first file it guards*.
Start from the file you changed and read across; a suite named after a `bin/`
command is usually the first one to run.

### AP and Wi-Fi

| Suite | Proves | Guards |
| --- | --- | --- |
| `phone-ap-up` | the link-only AP activates without forwarding, preflights the regulatory domain, and nudges the rejoin unit | `bin/phone-ap-up` |
| `phone-ap-down` | the default stops the AP and joins the hotspot; `--client` frees the radio; a failed stop is reported | `bin/phone-ap-down` |
| `phone-ap-create` | the profile is created link-only with the secret PSK, and only with the module's DHCP/drop units | `bin/phone-ap-create` |
| `phone-ap-delete` | `--check` is read-only and `--yes` downs then deletes the profile | `bin/phone-ap-delete` |
| `phone-ap-rejoin` | a missing station is rejoined through adb, with a throttle and an external-role path | `lib/phone-ap-rejoin.sh` |
| `phone-ap-failopen` | a dead tunnel drops the hairpin and leaves the AP drop, without rewriting nft twice | `lib/phone-ap-failopen.sh` |
| `phone-ap-regdomain` | channel 149 is passive-only in country 00 and allowed in DE, for the command and the doctor | `lib/python/phone_link/regdomain.py` |
| `phone-wifi-connect` | a saved network is joined with the passphrase the handler expects | `bin/phone-wifi-connect` |
| `phone-wifi-enable` | the radio is enabled and polled until it reports on | `bin/phone-wifi-enable` |
| `phone-wifi-forget` | exactly the named saved network is forgotten | `bin/phone-wifi-forget` |
| `phone-wifi-reconnect` | the two global Wi-Fi settings are checked, applied and read back | `bin/phone-wifi-reconnect` |
| `phone-wifi-concurrency` | the recorded wifi/status/ip dumps are parsed for the concurrency report | `bin/phone-wifi-concurrency` |
| `phone-usb-tether-check` | host routes and the phone side agree that USB tethering works | `bin/phone-usb-tether-check` |
| `phone-usb-tether-default` | `svc usb setFunctions` is applied and read back | `bin/phone-usb-tether-default` |
| `phone-tether-cycle` | an unhealthy tether is disabled, unlocked, restored and verified, or reported | `bin/phone-tether-cycle` |
| `hairpin-measure` | the live hairpin script's self-test, dry-run plan, read-only check and table | `tests/live/hairpin-measure.sh` |

### Tunnel

| Suite | Proves | Guards |
| --- | --- | --- |
| `phone-tun-toggle` | the unit state and the rendered sing-box config follow the TCP probe and the route source | `lib/phone-tun-toggle.sh` |
| `phone-fix-tunnel` | a stopped tunnel is restarted and its state reported | `bin/phone-fix-tunnel` |
| `phone-fix-forwarding` | `ip_forward` is written and read back | `bin/phone-fix-forwarding` |
| `phone-fix-internet` | routing, DNS and the per-path fixes are tried in order and reported | `bin/phone-fix-internet` |
| `phone-fix-mobile-data` | mobile data is enabled and the default route is waited for | `bin/phone-fix-mobile-data` |

### Proxy and app

| Suite | Proves | Guards |
| --- | --- | --- |
| `phone-proxy-install` | the newest release is fetched by versionCode, cached, checksummed and installed with the exact adb argv | `bin/phone-proxy-install` |
| `phone-proxy-uninstall` | `--check` never uninstalls and `--yes` sends the uninstall argv | `bin/phone-proxy-uninstall` |
| `phone-proxy-setup` | the app's intents, dump and LAN address are read, and the listener is requested | `bin/phone-proxy-setup` |
| `phone-proxy-start` | a stopped proxy is started and the listening state is observed | `bin/phone-proxy-start` |
| `phone-proxy-stop` | a running proxy is stopped and a proxy that keeps listening fails | `bin/phone-proxy-stop` |
| `phone-proxy-switch` | a listening port is probed, used, then the old one is dropped after the tunnel restart | `bin/phone-proxy-switch` |
| `phone-proxy-list` | a stopped service still shows its saved proxies from the app's index, while a live dump wins | `bin/phone-proxy-switch` |
| `phone-proxy-boot` | grants, the boot receiver and the idle whitelist are checked and applied | `bin/phone-proxy-boot` |
| `phone-proxy-transfer` | saved proxies export and import over the one-shot adb-forward socket | `bin/phone-proxy-export` |
| `phone-proxy-data-clear` | the app's data is cleared only when installed, with `--yes` | `bin/phone-proxy-data-clear` |
| `phone-proxy-battery-whitelist` | the app is put on the device-idle whitelist, read-only under `--check` | `bin/phone-proxy-battery-whitelist` |
| `phone-fix-apk` | a stand-in build is copied into the cache and a wrong checksum is rejected | `bin/phone-fix-apk` |
| `phone-link-uninstall` | the AP, proxy, cache and generated profiles are removed in the documented order | `bin/phone-link-uninstall` |
| `phone-adb-serial` | PHONE_SERIAL wins, two devices are an error, and a missing `-s` gets the resolved serial | `lib/python/phone_link/adb.py` |
| `phone-adb-mdns` | a pinned adbd port is tried first and mDNS rediscovers the wireless-debugging port | `lib/python/phone_link/adb.py` |
| `phone-adb-wifi` | wireless debugging is enabled through settings/props and one advertised TLS service | `bin/phone-adb-wifi` |

### Doctor

| Suite | Proves | Guards |
| --- | --- | --- |
| `phone-doctor` | every check reads the stubbed phone and reports the documented sections and counts | `bin/phone-doctor` |
| `phone-doctor-fix` | the doctor's problems become ordered fixes, and one failed fix does not stop the rest | `bin/phone-doctor-fix` |
| `phone-doctor-context` | the secrets parser matches `read_secrets` and PHONE_PROXY_PORT is validated | `lib/python/phone_doctor/context.py` |
| `phone-doctor-parallel` | fast results stream before a slow one, order is canonical and caches initialise once | `lib/python/phone_doctor/parallel.py` |
| `phone-doctor-stream` | `--json-stream` emits the events in the fixed order under the stubbed modules | `lib/python/phone_doctor/cli.py` |
| `net-check` | the route, DNS and HTTPS probes answer from the stubs and are reported honestly | `bin/net-check` |
| `phone-net-status` | the tether interface comes from the route to the phone, not a hard-coded name | `bin/phone-net-status` |

### Maintenance, CLI and GUI

| Suite | Proves | Guards |
| --- | --- | --- |
| `phone-unlock` | a locked screen is woken, swiped and its PIN entered, with bounded polls | `bin/phone-unlock` |
| `phone-reboot-unlock` | a phone that goes offline and comes back is unlocked after the reboot | `bin/phone-reboot-unlock` |
| `phone-as-root` | sudo re-runs the shim that was invoked and keeps the PHONE_* overrides | `lib/python/phone_link/phone.py` |
| `phone-link-cli` | the registry covers every script, unknown ids fail, and `run` passes argv and exit status | `bin/phone-link` |
| `registry` | the generated shims, COMMANDS map and docs table agree with the actions table, and each drift is caught | `lib/python/phone_link/registry_gen.py` |
| `phone-link-escalation` | one password prompt is reused by sudo's timestamp for the following root actions | `lib/python/phone_link/actions.py` |
| `gui-status-stream` | the status page's stream parser and row state machine, without GTK | `lib/python/phone_link_gui/status_model.py` |

### Module and live

| Target | Proves | Guards |
| --- | --- | --- |
| `module` check (`tests/module`) | the NixOS module's generated config and units | `modules/phone-link.nix` |
| `tests/live/doctor-fix-proxy.sh` | the doctor's repair against a real phone (sudo, USB tether; not in CI) | `bin/phone-doctor-fix` |
| `tests/live/hairpin-measure.sh` | the AP hairpin measurement on real hardware (not in CI) | `lib/phone-ap-failopen.sh` |

When a `bin/` script has no suite yet, its sibling suites are the closest model.
Adding a suite is covered below.

## Commands

```sh
# Every suite, through the same runner the flake check uses.
./tests/run

# Exactly the AP suites (the pattern is a glob, so quote it).
./tests/run 'phone-ap-*'

# Several names, four at a time.
./tests/run phone-ap-up phone-doctor --parallel 4

# One suite and its time, plus the slowest five.
./tests/run phone-ap-up --timings

# What a pattern would select, without running it.
./tests/run --list 'phone-*'

# The cheap set before a push: format, shellcheck, python, module, script.
bash tests/check.sh fast

# The same build, keeping per-suite times in result-checks/timings.csv and
# printing each suite beside its last measurement.
bash tests/check-timings.sh

# The live doctor repair. Root, a phone and a USB tether; see below.
sudo tests/live/doctor-fix-proxy.sh
```

`tests/run` prints each suite's own output, then `PASS`/`FAIL` and its seconds,
and exits non-zero if any suite failed. `--parallel N` keeps N suites in flight
and still prints in suite order. `--timings` adds a slowest-first table;
`--timings-file FILE` (or `PHONE_RUN_TIMINGS=FILE`) writes the
`suite,part,ms` rows the flake check publishes, folding in a suite's own
`PHONE_TEST_TIMINGS` rows.

`bash tests/check-timings.sh` writes one `total` row per suite, plus any rows a
suite reports itself through `PHONE_TEST_TIMINGS`. A suite that stops appearing
in `timings.csv` is a suite the glob stopped finding.

## The shared harness

`tests/lib/harness.sh` is sourced, never executed. Sourcing it prints nothing,
changes no shell option and installs no trap. It is bash and coreutils only.

```sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib/harness.sh"
suite
stub nmcli
answer nmcli <<'EOF'
case "$*" in
  "-t -f NAME con show") cat "$LOG/names" ;;
esac
EOF
```

| Helper | Use |
| --- | --- |
| `ok DESCRIPTION` | record a passing assertion |
| `bad DESCRIPTION [DETAIL]` | record a failure, with captured output as the detail |
| `finish` | print `N passed, M failed` and exit non-zero if any failed |
| `suite [TMPVAR]` | create the temp directory, export `LOG`/`STUBS`/`HOME`, put the stubs first on `PATH`, trap cleanup and locate `ROOT` |
| `stub NAME [DIR]` | write a stub that logs its argv to `LOG/NAME.log` and answers through `DIR/.NAME.answer` |
| `answer NAME [FILE]` | write that answer from stdin (or FILE); it runs with the original argv |
| `stub_adb [DIR]` | the common device/install/shell/dumpsys adb stub |
| `stub_cmd NAME [DIR]` | write a wholly suite-specific stub from stdin |

`suite` takes `--log DIR`, `--stubs DIR`, `--home DIR` and `--no-home`; a
relative DIR is under the temporary directory, so a suite that wants `WORK` as
its log root and `WORK/stub` on `PATH` writes `suite WORK --log . --stubs stub`.
`ROOT` is the checkout root; `suite` locates it from the suite's own path when
the suite has not set it.

Every stub has one call log. `stub adb` logs to `$LOG/adb.log`; `stub iw` to
`$LOG/iw.log`; and so on. An answer only decides what to print and which status
to return. `stub adb` also honours `answer adb`, for a suite that needs a
different phone, while still writing the one log. Its built-in knobs are
documented in the file: `ADB_SERIAL`, `ADB_STUB_DEVICES`, `ADB_STUB_ABSENT`,
`ADB_STUB_VERSION`, `ADB_STUB_BAD_SIG` and `ADB_STUB_SHELL`.

Prefer `suite` over `TMP=$(mktemp -d)`: it is where the trap lives. Do not roll
a local `mktemp`, `trap`, `chmod +x` or `PATH` block; a suite with a genuinely
unique need may keep a small local addition, not the whole scaffold.

## New suite skeleton

This is under 30 lines to the first assertion. Copy it to
`tests/phone-example.test.sh` and replace the command and first case. No stub
is declared until the suite needs one.

```sh
#!/usr/bin/env bash
# Hermetic tests for bin/phone-example: stub adb, no phone, no network.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-example

. "$ROOT/tests/lib/harness.sh"
suite
stub adb

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. What the first case proves.
if run --check; then ok "--check exits 0"; else bad "--check exits 0" "$(cat "$LOG/out")"; fi

finish
```

## Migrating a suite

1. Source the harness after `ROOT` is known and replace `mktemp`/`trap` and the
   `LOG`/`STUBS`/`HOME`/`PATH`/`mkdir` block with `suite`.
2. Delete the local `pass`/`fail`, `ok` and `bad`; replace the final count and
   `[ "$fail" -eq 0 ]` with `finish`.
3. Replace each `cat >"$STUBS/name"` stub with `stub name` + `answer name`;
   keep the case body and drop its shebang and logging, because the stub logs.
4. Replace the adb stub with `stub_adb` when it has the common shape, or keep
   it as `answer adb` when the phone behaviour is the point.
5. Do not change an assertion, its description, or what it proves. Run the
   suite before and after and diff the `ok` lines and exit status.
6. `shellcheck -S warning tests/<suite>.test.sh tests/lib/harness.sh tests/run`.

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
