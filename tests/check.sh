#!/usr/bin/env bash
# One entry point for the flake checks: the cheap set before a push, one
# target while iterating, or the full gate.
#
#   tests/check.sh fast
#   tests/check.sh all
#   tests/check.sh --list
#
# `fast` builds format, shellcheck, python, python-lint, python-tests, module
# and script in that order and stops at the first failure, naming it. `all` is
# `nix flake check`, the gate CI runs. Each target is one
# `nix build .#checks.x86_64-linux.<name>`, so there is one definition of every
# check and nothing extra to install but nix.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1
SYSTEM=${SYSTEM:-x86_64-linux}
FAST=(format shellcheck python python-lint python-tests module script)

usage() {
  cat <<'EOF'
usage: tests/check.sh <target>

  fast           format, shellcheck, python, python-lint, python-tests, module and script
  all            nix flake check, the full gate (includes the GUI)
  --list         every target with a one-line description
  --help         this text

  format         nixfmt-clean flake.nix, modules/*.nix and tests/module/*.nix
  shellcheck     bin/, lib/*.sh and every *.sh under tests/ at warning level
  python         compile every module under lib/python/ without importing it
  python-lint    ruff check, ruff format --check and mypy over lib/python/ and tests/python/
  python-tests   the migrated Python suite under tests/python/
  module         the NixOS module's generated config and units
  script         every hermetic tests/*.test.sh suite
  package        every script is installed, executable and kept its wrapped PATH
  registry       the action table matches the scripts
  gui-registry   the packaged GUI imports GTK and matches the scripts
  gui            the real window constructs under Xvfb

`fast` stops at the first failure and names the target. `all` does not replace
`nix flake check`; it is that command.
EOF
}

list_targets() {
  printf '%-14s %s\n' \
    fast 'format, shellcheck, python, python-lint, python-tests, module and script' \
    all 'nix flake check, the full gate (includes the GUI)' \
    format 'nixfmt-clean flake.nix, modules/*.nix and tests/module/*.nix' \
    shellcheck 'bin/, lib/*.sh and every *.sh under tests/ at warning level' \
    python 'compile every module under lib/python/ without importing it' \
    python-lint 'ruff check, ruff format --check and mypy over lib/python/ and tests/python/' \
    python-tests 'the migrated Python suite under tests/python/' \
    module "the NixOS module's generated config and units" \
    script 'every hermetic tests/*.test.sh suite' \
    package 'every script is installed, executable and kept its wrapped PATH' \
    registry 'the action table matches the scripts' \
    'gui-registry' 'the packaged GUI imports GTK and matches the scripts' \
    gui 'the real window constructs under Xvfb'
}

require_nix() {
  command -v nix >/dev/null 2>&1 && return 0
  printf 'tests/check.sh: nix is not on PATH\n' >&2
  return 1
}

build_target() {
  local target=$1
  printf '==> %s\n' "$target"
  if nix build --no-link ".#checks.$SYSTEM.$target"; then
    printf '<== %s ok\n' "$target"
    return 0
  fi
  printf '\ncheck failed: %s\n' "$target" >&2
  return 1
}

run_fast() {
  local target
  for target in "${FAST[@]}"; do
    build_target "$target" || return 1
  done
}

run_all() {
  printf '==> nix flake check\n'
  if nix flake check; then
    printf '<== all ok\n'
    return 0
  fi
  printf '\ncheck failed: all (nix flake check)\n' >&2
  return 1
}

if [ "$#" -gt 1 ]; then
  printf 'tests/check.sh: too many arguments\n\n' >&2
  usage >&2
  exit 2
fi

case ${1:-} in
  fast)
    require_nix && run_fast || exit 1
    ;;
  all)
    require_nix && run_all || exit 1
    ;;
  --list)
    list_targets
    ;;
  --help | -h)
    usage
    ;;
  format | shellcheck | python | python-lint | python-tests | module | script | package | registry | gui-registry | gui)
    require_nix && build_target "$1" || exit 1
    ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    printf 'tests/check.sh: unknown target: %s\n\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
