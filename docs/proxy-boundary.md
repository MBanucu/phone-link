# The phone-link / phone-link-proxy boundary

`MBanucu/phone-link` is the laptop side: scripts, the NixOS module, docs and
hermetic tests. `MBanucu/phone-link-proxy` is the Android app: source, the adb
contract, the APK build and signing, releases and the app's own live harness.
They are separate repositories with separate flakes and release processes, and
a change that needs both has an order.

This page is the ownership map and that order. It does **not** restate the
contract: the [proxy README](https://github.com/MBanucu/phone-link-proxy#readme)
is the manual for the intents, extras, `dumpsys` names, panel and settings, and
it stays the one owner of them.

## Ownership

| Area | Owner | Canonical path or page |
|---|---|---|
| adb contract: intents, actions, extras, `dumpsys` output, package names | `phone-link-proxy` | [proxy README](https://github.com/MBanucu/phone-link-proxy#readme) and `src/org/phonelink/proxy/` |
| APK build, signing, release workflow, store metadata | `phone-link-proxy` | `build.sh`, `.github/workflows/release.yml`, the [releases page](https://github.com/MBanucu/phone-link-proxy/releases) |
| install, update, uninstall, signer replacement, doctor version check | `phone-link` | `lib/python/phone_link/commands/install.py` (install, update, uninstall, data clear), `commands/proxy.py` (lifecycle, boot, battery) and `lib/python/phone_doctor/checks/proxy.py` |
| module, tunnel, AP, hairpin, fail-open | `phone-link` | `modules/phone-link/`, `modules/phone-link-failopen.nix` and the `lib/phone-*.sh` helpers the units run |
| live repair harness | `phone-link` | [`tests/live/doctor-fix-proxy.sh`](../tests/live/doctor-fix-proxy.sh) |
| live panel/contract harness | `phone-link-proxy` | `tests/live/proxy-app.sh` |
| test-build package and port | shared convention | `org.phonelink.proxy.test` on port 18080, produced by the app's `build.sh` and used by both harnesses |
| live phone plumbing | `phone-link-proxy` | `tests/live/phone.sh`; this repo's harness sources `lib/phone-net.sh` instead |

The two live harnesses share the test-build convention on purpose: the daily
app (`org.phonelink.proxy`) keeps its saved proxies, listener and port, so a
failed run costs the phone nothing. Neither repository may change the test
package or port alone; the app's `build.sh`, `tests/live/proxy-app.sh` and this
repo's `tests/live/doctor-fix-proxy.sh` have to change together.

## The contract version

The app owns the contract's shape and its version. Since contract 1 it prints
one integer on a line of its own, in `dumpsys activity service` and as the
first line of the non-secret `files/state.txt`:

```
  contract_version 1        # dumpsys, indented in the live block
contract_version 1          # state.txt, first line, before auto_start
```

The laptop parses that integer in one place, `lib/python/phone_link/contract.py`
(`KNOWN = 1`), preferring `state.txt` because it answers while the service is
stopped, and falling back to the dump. It is a version, not a feature string,
and it carries no password or token.

- **Too old** (`< 1`, or no line at all, which is contract 0):
  `phone-proxy-export` and `phone-proxy-import` refuse with `update the app to
  contract >= 1: run phone-proxy-install`. The transfer would otherwise wait
  for a socket an app that predates EXPORT/IMPORT never opens.
  `phone-proxy-start`, `phone-proxy-stop`, `phone-proxy-switch` and
  `phone-proxy-setup` keep working: the actions they send existed before the
  line.
- **After an install** the version is advisory, not a hard gate: a fresh
  install, and an update from a build without the line, leave `state.txt`
  stale or absent until the app runs, while the APK has already been installed
  successfully. The command notes that it cannot verify the contract yet and
  leaves the next export/import to report it. The restore after
  `--replace-signer` skips the gate for the same reason: the install cleared
  the app's data, and the backup in hand proves the previous app could export
  it.
- **Known** (`1`): the commands run as documented.
- **Newer** (`> 1`): every command that drives the app logs `the app speaks
  contract N; this laptop knows contract 1` and continues, because the actions
  this laptop sends are still actions the app accepts.

`phone-proxy-switch --list` reports the parsed integer as `contract`, `null`
when the app does not say. Bumping the integer is the app repository's change;
this checkout's `KNOWN` changes in the same change set only when the laptop has
to do something different with the new number.

## Version policy

- `version` in this repository's `flake.nix` is phone-link's version. It is not
  the app's version and does not pin one.
- This checkout neither builds nor bundles the app. `phone-proxy-install`
  fetches the newest signed release, or the tag named with `--release`, and
  checks its checksum; `--build` deliberately refuses and points at the app
  repository. The [releases page](https://github.com/MBanucu/phone-link-proxy/releases)
  is the version list; no release number belongs in this page or the README.
- The phone is authoritative about what is installed. `phone-doctor` reads the
  installed `versionName`/`versionCode` and `minSdk`, reports them, and compares
  them with the latest GitHub release. The comparison is cached for a day and
  bounded to a few seconds, so an offline laptop reports "unknown" instead of
  stalling. A measurement page may name the release a run was taken with; that
  is evidence, not a pin.
- Skew is reported, not enforced. An older installed app is a warning that names
  `phone-proxy-install --release`; a phone newer than the latest release is
  fine; an unreachable GitHub is a skip. A difference in the *contract* — an
  intent, extra or `dumpsys` field that one side does not understand — is a bug,
  not a version policy, and is filed in the repository that owns that side.

## Change order

**A contract change starts in the app.** File the issue in
`MBanucu/phone-link-proxy`, land the change with its tests, cut the release,
then update this repo's commands, doctor and tests against that released tag.
Do not merge laptop code that expects an unreleased contract: a phone on the
previous release is the normal case, not an error.

**A laptop-only change needs no app release.** Install/update policy, the
doctor's checks, the module, docs and hermetic tests all live here; file the
issue here and ship it.

**A change that needs both has two issues, linked.** The proxy issue comes
first, the laptop issue names the release it depends on, and both PRs say which
other repository they pair with. If you are unsure which side owns a fact,
check the ownership table above: if it changes the APK or what the APK exposes
over adb, it is the proxy's; if it changes a script, module, doc or hermetic
test on the laptop, it is this repo's.

## Live runs

[`tests/live/doctor-fix-proxy.sh`](../tests/live/doctor-fix-proxy.sh) breaks the
setup and proves the doctor repairs it. It needs root, a phone, a USB tether
that survives the AP being dropped, and a checkout of the app built once
(`PHONE_PROXY_APP`, default the sibling `../phone-link-proxy`). It parks the
test APK, drops the laptop AP, uninstalls the test app, requires the doctor to
report the expected problems, runs `phone-doctor-fix --yes --required`, and
requires a clean doctor and the daily app still listening where it was. It is
destructive to the test app's data and to the AP; it is never part of
`nix flake check`. [docs/checks.md](checks.md) has the step-by-step read.

`tests/live/proxy-app.sh` in the app repository is the panel/contract side of
the same phone: it installs the same test build and exercises the app's own
behaviour against the live phone. Its steps, claims and measurements are in the
proxy README; do not copy them here.

## Reciprocal link

The proxy repository should link its README and `AGENTS.md` back to this page so
the boundary is discoverable from the app side too. That is tracked as
[MBanucu/phone-link-proxy#53](https://github.com/MBanucu/phone-link-proxy/issues/53). When the proxy
adds that link, keep it pointing here rather than duplicating the table.
