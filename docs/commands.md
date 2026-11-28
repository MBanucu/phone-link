# Commands: the shell/Python split

`bin/` holds the command names. The body of a normal command is a Python
function under `lib/python/phone_link/commands/`; `phone-doctor` is the one
exception, with its own package under `lib/python/phone_doctor/`. The table in
[`actions.py`](../lib/python/phone_link/actions.py) is the **single metadata
source** for the command surface: id, group, `module:function`, short summary,
usage line, escalation (`root`), GUI visibility, variants and the
`docs/scripts.md` description.

## Where shell stops

Python carries anything with branching, state, parsing, retries or structured
output: commands, the decisions a unit makes, harnesses.

Shell is only three things: the generated `bin/` shims, an `ExecStart` hook that
`exec`s one Python module, and Nix activation snippets.

A new `lib/*.sh` over about 40 lines, or a new `tests/*.test.sh`, needs an issue
saying why Python is not the answer. The files already there are migrated under
#116 and #117, not expanded.

`tests/check.sh` is the one sanctioned large shell file in this repo: it turns
`nix build` into one entry point and holds no logic of its own. The proxy repo's
equivalent is `build.sh`.

[`registry_gen.py`](../lib/python/phone_link/registry_gen.py) generates the
`bin/` shims, `commands/__init__.py` and the scripts table from that one table.
The flake's `registry` and `gui-registry` checks run it in `--check` mode and
fail when any view disagrees, so a shim or a docs row is never hand-edited.

The four entry points in `bin/` that are not `phone_link.commands` functions
are listed explicitly in the table: the shared CLI (`phone-link`), the GUI's
two entry points (`phone-link-gui`, `phone-link-gui-screenshots`) and the
doctor (`phone-doctor`, which is an action but lives in `phone_doctor`).

## What runs when you type a command

1. `bin/<name>` — a generated shim. It finds `../lib/python` (checkout) or
   `../share/phone-link/lib/python` (store install), sets
   `PYTHONDONTWRITEBYTECODE=1`, exports `PHONE_LINK_SHIM`, and executes
   `python3 -m phone_link.commands <name> "$@"`. Do not edit it: change the
   table and regenerate.
2. `lib/python/phone_link/commands/__init__.py` — the generated `COMMANDS` map
   from script name to function. The name is the contract; the registry, the
   Nix wrappers, the tests and the GUI all address scripts, not modules.
3. `lib/python/phone_link/commands/<area>.py` — the function and its `USAGE_*`
   text, grouped by area: `status`, `adb`, `wifi`, `usb`, `ap`, `tunnel`,
   `repair`, `install`, `proxy`, `device`, `maintenance`, `doctor_fix`; the
   helpers those modules share live in `common.py`.
4. `lib/python/phone_link/actions.py` — the source of everything above: the
   `Action` carries id, group, title, summary, docs description, usage,
   `module:function`, `root`, `supports_check`, `supports_yes`, `destructive`,
   `long_running`, `confirm` and `variants`. `phone-link run` and the GUI both
   read it, so a command missing here is missing from the panel even when its
   script works.

`phone-doctor` is the exception: the generated `bin/phone-doctor` hands over to
`python3 -m phone_doctor`, and the checker is one module per symptom group under
`lib/python/phone_doctor/`. It is still an `Action` (`kind="doctor"`) like
every other script.

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
- do not edit it by hand: `registry_gen` writes it from the table, and the
  `registry` check fails when the file differs.

```sh
# after editing the Action in lib/python/phone_link/actions.py:
PYTHONPATH=lib/python python3 -m phone_link.registry_gen --write
```

## Which home?

| The change is… | Home | Real example |
|---|---|---|
| adb, `dumpsys`, JSON, argparse; a laptop-side read or state change | Python action in `lib/python/phone_link/commands/<area>.py` | `phone-net-status` in `commands/status.py` |
| a long-running loop a systemd unit runs and a test stubs | Python, with a shell `ExecStart` hook that `exec`s it; the existing `lib/*.sh` helpers move under #116 | `phone-tun-toggle` in `lib/phone-tun-toggle.sh`, started by `modules/phone-link/config/tunnel.nix` |
| an option, unit, generated config, firewall rule or watchdog | `modules/*.nix` | `phoneLink.ap.uplink` in `modules/phone-link/options/ap.nix` |
| presentation only, over the same actions | `lib/python/phone_link_gui/` | the Proxy port page in `lib/python/phone_link_gui/port_page.py`; it runs `phone-proxy-switch`, it does not implement it |
| a new proof, not a user-facing command | `flake.nix` / `tests/`, not `bin/` | the `registry` check in `flake.nix` |

The GUI never reimplements an action: it reads the table, and
`phone_link.runner` streams the same argv that `phone-link run` uses. A new
paginated widget is fine; a second copy of a command's logic is not.

## Recipe: add a Python command

Assume the command is `<name>` and belongs to area `<area>`. **Three files are
the change**; the shim, `COMMANDS` entry and docs row are generated.

1. **The body.**
   `lib/python/phone_link/commands/<area>.py` — add the function and its
   `USAGE_*` text. Use the shared `shell`, `phone` and `settings` helpers; do
   not shell out to `adb` with a second serial-selection rule.
2. **The metadata.**
   `lib/python/phone_link/actions.py` — add one `Action` to `SCRIPTS` with
   `module="phone_link.commands.<area>"`, `function="<function>"`, `group`,
   `title`, `summary`, `doc` (the docs row), `usage` (the first line of the
   command's `USAGE_*`; set `usage_const` so the check compares them), and the
   flags it really supports. `root=True` when the command needs root,
   `supports_check=True` only when `--check` exists, and a `Variant` for each
   documented non-default call. This is what the GUI shows.
3. **The test.**
   `tests/<name>.test.sh` — a hermetic suite with stub `adb`/`curl` and the
   shared harness in [`tests/lib/harness.sh`](../tests/lib/harness.sh); name it
   after the script. The flake runs `tests/*.test.sh`, so a suite outside that
   glob never runs. [tests/README.md](../tests/README.md) has the harness and
   the suite-to-change table.
4. **Generate the mechanical files.**

   ```sh
   PYTHONPATH=lib/python python3 -m phone_link.registry_gen --write
   ```

   That writes `bin/<name>`, the `COMMANDS` entry in
   `commands/__init__.py` and the row in [docs/scripts.md](scripts.md). The
   generated shim keeps the `PHONE_LINK_SHIM` export and resolves the checkout
   or store package; never edit a generated file by hand.
5. **The prose.** Add an entry under `## [Unreleased]` in
   [CHANGELOG.md](../CHANGELOG.md). The README no longer keeps a per-script
   table; it links the scripts page.
6. **The flake.** Normally nothing: the package and the `package` check read
   `bin/`, and the registry check reads the table. Change `flake.nix` only if
   the command needs a new runtime tool in `runtimeDeps` (and then the
   `format` check matters).

Validate:

```sh
# From a checkout: pass bin/ explicitly; this is what the flake does.
expected=$(ls bin | grep -vE '^(phone-link|phone-link-gui|phone-link-gui-screenshots)$')
PYTHONPATH=lib/python python3 -m phone_link.registry_gen --check
PYTHONPATH=lib/python python3 -m phone_link check-registry $expected

nix build .#checks.x86_64-linux.registry
nix build .#checks.x86_64-linux.script
nix build .#checks.x86_64-linux.shellcheck
```

`nix build .#checks.x86_64-linux.registry` is the completeness proof: it runs
`registry_gen --check` against the source tree (shims, `COMMANDS` and the docs
table) and then the packaged `phone-link check-registry` with the packaged
`bin/` list. A bare `phone-link check-registry` with no arguments checks the
table's internal consistency (unique ids, known groups, executable scripts,
`module:function`, usage) and, in a checkout, the generated files; passing the
`bin/` list is what proves the packaged install has exactly those scripts.
The flake's `script` check runs every `tests/*.test.sh`. When the recipe above
is followed, both are green.

### Dry run

A throwaway `phone-docs-example` added exactly as above — function in
`commands/status.py`, one `Action` in `actions.py`, a tiny
`tests/phone-docs-example.test.sh`, then `registry_gen --write` — passes
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
- **A hand-edited shim, `commands/__init__.py` or docs row** fails
  `registry_gen --check` with `out of date (run … --write)`; there is no
  second copy to keep in sync.
- **A `module:function` or `usage` that the body does not have** fails
  `check-registry` before any command runs.
- **A test outside `tests/*.test.sh`** is never run by the `script` check.
- **A second settings precedence** in a new command makes the doctor and the
  scripts disagree about which proxy port or module value is in use. Use
  `phone_link.settings` for configuration and `phone_link.phone` for secrets.
