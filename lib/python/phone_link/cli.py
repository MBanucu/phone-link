"""`phone-link`: list and run the actions the GUI also exposes.

Kept deliberately small: it is the CLI half of the shared registry, so the GUI
and the shell cannot drift apart, and `check-registry` is what the flake runs.
"""

from __future__ import annotations

import json
import shlex
import sys

from . import actions
from .runner import stream

USAGE = """usage: phone-link <command> [options]

commands:
  list [--json] [--group GROUP]   list the actions (the GUI's table)
  run <id> [--check] [--yes] [-- ARGS...]
                                  run one action, streaming its output
  status                          print phone-doctor's report as JSON
  check-registry [ID...]          fail when an action and a script disagree
"""


def _print_list(args: list[str]) -> int:
    as_json = "--json" in args
    group = ""
    if "--group" in args:
        index = args.index("--group")
        if index + 1 >= len(args):
            print("error: --group needs a name", file=sys.stderr)
            return 2
        group = args[index + 1]

    selected = actions.ACTIONS
    if group:
        if group not in dict(actions.GROUPS):
            print(f"error: unknown group: {group}", file=sys.stderr)
            return 2
        selected = tuple(actions.actions_in(group))

    if as_json:
        print(
            json.dumps(
                [
                    {
                        "id": action.id,
                        "group": action.group,
                        "title": action.title,
                        "summary": action.summary,
                        "root": action.root,
                        "check": action.supports_check,
                        "yes": action.supports_yes,
                    }
                    for action in selected
                ],
                indent=2,
            )
        )
        return 0

    for group_id, title in actions.GROUPS:
        members = [action for action in selected if action.group == group_id]
        if not members:
            continue
        print(title)
        for action in members:
            print(f"  {action.id:<32} {action.title}")
    return 0


def _print_status() -> int:
    doctor = actions.doctor_bin()
    if not doctor:
        print("error: phone-doctor not found on PATH", file=sys.stderr)
        return 127
    outcome = stream([doctor, "--json"])
    if outcome.error:
        print(f"error: {outcome.error}", file=sys.stderr)
        return 127
    sys.stdout.write(outcome.text() + "\n")
    return outcome.exit_code


def _run(args: list[str]) -> int:
    if not args:
        print("error: run needs an action id", file=sys.stderr)
        return 2
    action = actions.BY_ID.get(args[0])
    if action is None:
        known = ", ".join(sorted(actions.BY_ID))
        print(f"error: unknown action: {args[0]}", file=sys.stderr)
        print(f"known actions: {known}", file=sys.stderr)
        return 2

    check = False
    assume_yes = False
    rest: list[str] = []
    passthrough = False
    for value in args[1:]:
        if passthrough:
            rest.append(value)
        elif value == "--":
            passthrough = True
        elif value == "--check":
            check = True
        elif value == "--yes":
            assume_yes = True
        else:
            rest.append(value)

    if check and not action.supports_check:
        print(f"error: {action.id} has no --check", file=sys.stderr)
        return 2

    argv = actions.plan(
        action, args=tuple(rest), check=check, assume_yes=assume_yes
    )
    print(f"$ {shlex.join(argv)}", file=sys.stderr)
    outcome = stream(argv, on_line=lambda line: print(line, flush=True))
    return outcome.exit_code


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print(USAGE, file=sys.stderr)
        return 2
    command, rest = args[0], args[1:]

    if command in ("-h", "--help", "help"):
        print(USAGE, end="")
        return 0
    if command == "list":
        return _print_list(rest)
    if command == "run":
        return _run(rest)
    if command == "status":
        return _print_status()
    if command == "check-registry":
        problems = actions.validate(tuple(rest))
        if problems:
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            return 1
        print(f"registry ok: {len(actions.ACTIONS)} actions")
        return 0

    print(f"error: unknown command: {command}", file=sys.stderr)
    print(USAGE, end="", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
