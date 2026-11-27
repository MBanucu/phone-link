# Checks

Run every target with `nix flake check`; run one with
`nix build .#checks.x86_64-linux.<name>`. The checks per system are:

| check | what it proves |
|---|---|
| `registry` | every script in `flake.nix` has an action in the GUI's table, and every action has an executable script |
| `gui-registry` | the packaged GUI imports GTK4/libadwaita and its table matches the scripts |
| `gui` | the real window, every page and the log window construct under Xvfb |
| `package` | every script in the flake exists, is executable, kept its wrapped `PATH`, and `phone-net-status` prints a status |
| `shellcheck` | `bin/` and `lib/*.sh` are clean at shellcheck warning level (the `tests/` suites are not shellchecked yet) |
| `python` | every module under `lib/python/` compiles without being imported; GTK is not loaded |
| `format` | `flake.nix`, both `modules/*.nix` files and `tests/module/*.nix` are nixfmt-clean |
| `module` | the module generates the expected sing-box config and units (5 s probe, 20 s first run, AP DHCP hole, a DHCP-only AP with no router/DNS option, an nftables forward drop that also works with the firewall off, an opt-in hairpin with one accepted client, a scoped masquerade and DHCP router/DNS, a default-on fail-open watchdog with that hairpin and an explicit off switch, an opt-in AP autoconnect that leaves the profile link-only, an opt-in rejoin watchdog, pinned resolver, never started at boot) and defines nothing when disabled |
| `script` | every `tests/*.test.sh` suite runs hermetically with stub `adb`/`curl`/`avahi-browse`; [architecture](architecture.md#i-want-to) shows how to run one suite |

The `script` check also covers `phone-doctor --analyze` (problem ids, AP down and
a missing APK, warnings-only, no headers or `ok` lines),
`phone-doctor-fix` (dry run, ordered application, an install from the cached
APK, the manual APK step, manual-only and failed-fix paths) and the fix scripts (ambulance APK, AP
profile creation from the secret, forwarding, mobile data, tunnel: apply,
no-op and read-only `--check`).

### Where the check's time goes

`nix build .#checks.x86_64-linux.script` times itself: `timings.csv` in the
output has a row per suite and, where a suite knows them, a row per part, and
the build log ends with the five slowest, so the question "which suite got
slower" is answered by the log that asked it. A store path cannot be compared with the
last one, so `tests/check-timings.sh` builds the check, appends the rows to
`result-checks/timings.csv` (append-only, keyed by run, like
`result-live/timings.csv`) and prints every suite beside the last time it was
measured:

```sh
bash tests/check-timings.sh
```

A suite that wants its own parts named writes `part,ms` rows to the file in
`$PHONE_TEST_TIMINGS` and the check adds the suite's name to them.

A suite that waits — for a lock screen to animate, for adbd to come back, for a
network to come up — is waiting for a phone that a stub is not, and it used to
do that in real seconds: `phone-unlock` spent 46 s of a 198 s check asleep in
`time.sleep`, `phone-fix-internet` 49 s and `phone-adb-wifi` 22 s. Those waits
are now `PHONE_UNLOCK_POLL`, `PHONE_FIX_SETTLE` and `PHONE_ADB_POLL` (defaults
unchanged, so a real phone waits exactly as before) and the three suites set
them to 0, which is 86 s for the whole check instead of 198 s with the same
checks passing. `PHONE_PROXY_WAIT` and `PHONE_PROXY_SETTLE` are the same idea
for `phone-proxy-switch`: how long the app gets to put a listener on a port,
and the old one to go away.

### Live end-to-end test

`tests/live/doctor-fix-proxy.sh` breaks the setup on purpose and checks that the
doctor repairs it. It runs the app's **test build**
(`org.phonelink.proxy.test`, from a checkout of the app's repository built
once — `PHONE_PROXY_APP`, default `../phone-link-proxy` — listening on 18080) so
a run never costs the phone the proxies the daily build has saved, and it
requires the daily app's state line to be the same at the end.
It parks that build in the ambulance box, drops the laptop AP,
uninstalls the test app, requires `phone-doctor` to report `ap_address`,
`proxy_app` and `proxy_request`, runs `phone-doctor-fix --yes --required`, and
requires a clean doctor, the AP back up, the phone joined again, the installed
app's version reported, and the daily app listening on the port it had
*without* a command being run to start it — the phone rejoins the SSID on its own, and the
listener follows the network back. Nothing is downloaded: the repair installs
the parked file,
and the harness requires it to be byte for byte the build — which is what keeps
the repair working when the removed proxy was the laptop's only uplink. It
refuses to start unless the adb route survives the AP drop (a cable, or a
transport that is not on the AP's subnet), so a run cannot cut its own link to
the phone. The fixer brings the AP and the phone's link up before it starts the
proxy, because the app only listens on the network the phone joined, and
reinstalls and reconfigures the app on exit if the repair failed.

```sh
sudo tests/live/doctor-fix-proxy.sh
```

`tests/live/proxy-app.sh` — the app's own end-to-end run — lives in the app's
repository (`MBanucu/phone-link-proxy`, under `tests/live/`), together with the
phone plumbing it shares (`phone.sh`), the tools that read a run's evidence
(`frames.sh`, `clock.sh`, `pictures.py`, `remux.sh`) and the one that makes the
CSV history queryable (`results.py`). It installs the app's test build
(`org.phonelink.proxy.test`, port 18080), so a run never touches the proxy the
phone lives on, and `nix flake check` never runs it. That repository's README
has the steps, the claims they make and the measurements behind them.

`tests/live/hairpin-measure.sh` records the numbers for the AP hairpin
([#47](https://github.com/MBanucu/phone-link/issues/47)): the phone's direct and
hairpin latency/8 MB transfer, the laptop's 500 sequential / 200-at-40 / 5 x
8 MB soaks, proxy client headroom, battery over 30 minutes, the shared path,
fallback (needs #46) and bootstrap (needs #43/#44). A normal run is read-only
with respect to the network and the phone; `--fallback` is explicit because it
stops the tunnel, and restores it with a trap. `--check` and `--dry-run` need no
phone or root. `docs/hairpin-measure.md` is the runbook, including what stays
`UNAVAILABLE` until the feature is live and the before/after table for #47.

```sh
sudo tests/live/hairpin-measure.sh --check
sudo tests/live/hairpin-measure.sh --mode before
sudo tests/live/hairpin-measure.sh --mode after
tests/live/hairpin-measure.sh --compare result-live/hairpin-before result-live/hairpin-after
```

The live runs meet at the same phone: this repository's doctor test breaks the
setup and requires the repair, the app's run requires the panel and the adb
contract, and the hairpin measurement records what the network does. None is
part of `nix flake check`.

The `module` check evaluates a NixOS configuration with non-default options, so
it catches option or unit regressions without building a system or a VM.
