# Commands: the shell/Python split

`bin/` holds the command names. The body of a normal command is a Python
function under `lib/python/phone_link/commands/`; `phone-doctor` is the one
exception, with its own package under `lib/python/phone_doctor/`. Long-running
logic that a systemd unit runs stays in `lib/*.sh`. The table in
[`actions.py`](../lib/python/phone_link/actions.py) is the one description of
each command that the GUI and `phone-link run` share, so a command is not done
until both `bin/` and that table know about it.

The three files in `bin/` that are not actions are the shared CLI
(`phone-link`) and the GUI's two entry points (`phone-link-gui`,
`phone-link-gui-screenshots`). Everything else in `bin/` has exactly one
`Action`.

## What runs when you type a command

1. `bin/<name>` — a shim. It finds `../lib/python` (checkout) or
   `../share/phone-link/lib/python` (store install), sets
   `PYTHONDONTWRITEBYTECODE=1`, exports `PHONE_LINK_SHIM`, and executes
   `python3 -m phone_link.commands <name> "$@"`.
2. `lib/python/phone_link/commands/__init__.py` — `COMMANDS` maps the script
   name to the function. The name is the contract; the registry, the Nix
   wrappers, the tests and the GUI all address scripts, not modules.
3. `lib/python/phone_link/commands/<area>.py` — the function and its `USAGE_*`
   text, grouped by area: `status`, `phone`, `network`, `proxy`, `device`,
   `maintenance`, `doctor_fix`.
4. `lib/python/phone_link/actions.py` — the `Action`: id, group, title,
   summary, `root`, `supports_check`, `supports_yes`, `destructive`,
   `long_running`, `confirm` and `variants`. `phone-link run` and the GUI both
   use it, so a command missing here is missing from the panel even when its
   script works.

`phone-doctor` is the exception: `bin/phone-doctor` hands over to
`python3 -m phone_doctor`, and the checker is one module per symptom group under
`lib/python/phone_doctor/`. It still has an `Action` like every other script.

`phone_link.settings` reads `PHONE_*`, then the module's non-secret
`/etc/phone-link/env`, then the built-in default — the same env-first precedence
as `lib/phone-net.sh`. The root-only secrets (`PHONE_PIN`, `PHONE_AP_PASS`) are
read separately by `phone_link.phone`. A new command uses these helpers, and
`phone_link.shell`, rather than inventing another lookup.

## The `PHONE_LINK_SHIM` escalation contract

A root action calls `as_root` in
[`phone.py`](../lib/python/phone_link/phone.py). When it is not already root it
re-executes through sudo as:

```sh
sudo -- env PHONE_PIN=… PHONE_SECRETS=… "$PHONE_LINK_SHIM" "$@"
```

The shim exports `PHONE_LINK_SHIM` for exactly this. Running
`./bin/phone-ap-up` must escalate into the checkout shim that was invoked, not
into a `/usr/bin/phone-ap-up` that `PATH` happens to find; otherwise an older
installed copy runs silently and the change you are testing is not the change
that ran. The registry lookup is only a fallback for a direct
`python3 -m phone_link` run.

Consequences for a shim:

- keep the `export PHONE_LINK_SHIM="$shim"` line; do not rename it;
- keep it logic-free — resolve the package, hand over, nothing else;
- copy an existing shim such as [`bin/phone-net-status`](../bin/phone-net-status)
  instead of writing a new one from memory.

## Which home?

| The change is… | Home | Real example |
|---|---|---|
| adb, `dumpsys`, JSON, argparse; a laptop-side read or state change | Python action in `lib/python/phone_link/commands/<area>.py` | `phone-net-status` in `commands/status.py` |
| a long-running loop a systemd unit runs and a test stubs | `lib/*.sh`, wired by a module wrapper | `phone-tun-toggle` in `lib/phone-tun-toggle.sh`, started by `modules/phone-link/config/tunnel.nix` |
| an option, unit, generated config, firewall rule or watchdog | `modules/*.nix` | `phoneLink.ap.uplink` in `modules/phone-link/options/ap.nix` |
| presentation only, over the same actions | `lib/python/phone_link_gui/` | the Proxy port page in `lib/python/phone_link_gui/port_page.py`; it runs `phone-proxy-switch`, it does not implement it |
| a new proof, not a user-facing command | `flake.nix` / `tests/`, not `bin/` | the `registry` check in `flake.nix` |

The GUI never reimplements an action: it reads the table, and
`phone_link.runner` streams the same argv that `phone-link run` uses. A new
paginated widget is fine; a second copy of a command's logic is not.

## Recipe: add a Python command

Assume the command is `<name>` and belongs to area `<area>`. The first six
files below are the change; step 7 is normally a no-op.

1. **The body.**
   `lib/python/phone_link/commands/<area>.py` — add the function and its
   `USAGE_*` text. Use the shared `shell`, `phone` and `settings` helpers; do
   not shell out to `adb` with a second serial-selection rule.
2. **The name.**
   `lib/python/phone_link/commands/__init__.py` — add
   `"<name>": <area>.<function>` to `COMMANDS`.
3. **The shim.**
   `bin/<name>` — copy `bin/phone-net-status`, change the last line's
   `python3 -m phone_link.commands <name>` argument, keep the
   `PHONE_LINK_SHIM` export, make it executable. A shim is a wrapper, never the
   implementation.
4. **The action.**
   `lib/python/phone_link/actions.py` — add an `Action` with its group, title,
   summary and the flags it really supports. `root=True` when the command needs
   root, `supports_check=True` only when `--check` exists, and a `Variant` for
   each documented non-default call. This is what the GUI shows.
5. **The test.**
   `tests/<name>.test.sh` — a hermetic suite with stub `adb`/`curl` and the
   shared harness in [`tests/lib/harness.sh`](../tests/lib/harness.sh); name it
   after the script. The flake runs `tests/*.test.sh`, so a suite outside that
   glob never runs. [tests/README.md](../tests/README.md) has the harness and
   the suite-to-change table.
6. **The prose.**
   Add a row to the script table in [docs/scripts.md](scripts.md) and an entry
   under `## [Unreleased]` in [CHANGELOG.md](../CHANGELOG.md). The README no
   longer keeps a per-script table; it links the scripts page.
7. **The flake.**
   Normally nothing: `scripts` is generated from `bin/` minus the three entry
   points, so the package, `package` check and `registry` check pick the new
   file up. Change `flake.nix` only if the command needs a new runtime tool in
   `runtimeDeps` (and then the `format` check matters).

Validate:

```sh
# From a checkout: pass bin/ explicitly; this is what the flake does.
expected=$(ls bin | grep -vE '^(phone-link|phone-link-gui|phone-link-gui-screenshots)$')
./bin/phone-link check-registry $expected

nix build .#checks.x86_64-linux.registry
nix build .#checks.x86_64-linux.script
nix build .#checks.x86_64-linux.shellcheck
```

`nix build .#checks.x86_64-linux.registry` is the completeness proof: it runs
the packaged `phone-link check-registry` with the packaged `bin/` list. A bare
`phone-link check-registry` with no arguments only checks the table's internal
consistency (unique ids, known groups, executable scripts); it cannot notice a
`bin/` file nobody registered. The flake's `script` check runs every
`tests/*.test.sh`. When the recipe above is followed, both are green.

### Dry run

A throwaway `phone-docs-example` added exactly as above — function in
`commands/status.py`, entry in `COMMANDS`, a copied and renamed shim, an
`Action`, and a tiny `tests/phone-docs-example.test.sh` — passes
`nix build .#checks.x86_64-linux.registry` and
`nix build .#checks.x86_64-linux.script`. Remove the example before committing:
a page that cannot be followed is worse than no page.

## Failure modes

- **A `bin/` script without an `Action`** fails the registry with
  `no action for: <name>`. It also never appears in the GUI, because the GUI
  reads `actions.py`, not `bin/`.
- **An `Action` without a script** fails with
  `action without a script: <name>` (or `not executable` when the file is
  missing its mode). The flake only says so at `nix flake check`, which is why
  the registry check exists.
- **A shim with logic** is outside the test suite and outside the action table:
  it works from one path and not the other, and the `PHONE_LINK_SHIM` contract
  breaks when it escalates.
- **A test outside `tests/*.test.sh`** is never run by the `script` check.
- **A second settings precedence** in a new command makes the doctor and the
  scripts disagree about which proxy port or module value is in use. Use
  `phone_link.settings` for configuration and `phone_link.phone` for secrets.
