# Working in this repository

Notes for whoever — person or agent — is changing this checkout. They are the
rules the work here has settled into, not a style guide.

## Where things are

- `TODO.md` — the wishlist: ideas from the user, in the order they are being
  built, one `##` section per wish with a paragraph that says what is wrong
  today and what "done" means. Delete a section once it is implemented and
  committed; delete the file when the list is empty.
- `CHANGELOG.md` — Keep a Changelog, with entries written as "what was wrong
  and what it is now", not as a diff summary.
- `README.md` — the operator's view: every script, every option, every module
  setting. `android/README.md` is the app's own manual (the adb contract, the
  panel, the settings).
- `lib/python/phone_link/` — one function per command, `bin/` is a wrapper each;
  `phone_doctor/` is the checker, one module per symptom group.
- `android/` — the proxy app: `build.sh` builds it without Gradle, `src/` holds
  the Java, `test/` the Android-free unit tests, `devicetest/` the on-device
  instrumentation. `tests/live/` drives it on a real phone.
- `tests/*.test.sh` — hermetic suites with stub `adb`/`curl`; they run inside
  `nix flake check` and need no phone, no root and no network.

## Rules

- **Wishes go in `TODO.md` first.** Before building a feature the user asked
  for, write the wish down; delete it when the work is committed. A bottleneck
  found while working — something that slows development down or makes a
  command lie — is a wish too, even if nobody asked for the fix yet.
- **Conventional Commits**, one change per commit: `feat(scope): …`,
  `fix(scope): …`, `test(live): …`, `docs(todo): …`, `chore(release): …`. The
  footer is `Co-Authored-By: Codebuff <noreply@codebuff.com>` and nothing else.
- **No secrets in scripts or in the repository.** Passwords come from
  `/etc/nixos/phone-socks-secrets` (or `PHONE_*` variables) at run time; the
  only tracked key is `android/debug.keystore`, which is a throwaway and is
  never what a release is signed with.
- **Never edit `tests/live/proxy-app.sh` while a run is executing.** It is read
  as it runs; a half-written file is a run that fails somewhere unrelated.
- **A speed claim needs a measurement.** Say what was measured and by how much,
  or leave the number out.
- **Leave the tree green.** `nix flake check` (or at least
  `bash tests/check-timings.sh`) before committing; `shellcheck -S warning` and
  `actionlint` where they apply. Fix the cause of a failing check; never
  weaken an assertion to make one pass.

## Working the wishlist autonomously

When asked to work the wishlist and not report back until it is empty:

1. Read `TODO.md` and order the wishes by your own judgement: small and
   unblocking first, then the ones that make the tools more honest, then the
   long ones. Say the order in the first commit message if it is not obvious.
2. Take one wish at a time: write (or refine) its section in `TODO.md`, do the
   work, document it (`README.md`/`android/README.md` and `CHANGELOG.md`), run
   the affected suites, then delete the section and commit.
3. Add wishes as you go — especially for the phone doctor, whose job is to be
   right about the phone, and for anything that made this work slower or less
   sure than it should have been. Fix them in the same run when they are small.
4. Cut a release when a coherent set has landed: bump `version` in `flake.nix`,
   move `## [Unreleased]` into a dated section with its comparison link, commit
   `android/version` (the APK's stamped version; `nix flake check` refuses a
   mismatch), commit `chore(release): X.Y.Z`, tag `vX.Y.Z`, push `main` and the tag, watch the
   `Release` workflow, and replace the generated notes with the CHANGELOG
   section plus how to install what was attached.
5. Some wishes are not an agent's to finish: creating a repository, a store
   account, a signing identity. Leave those sections in place, make them
   narrower if the rest can be done (a piece that *is* buildable), and say why
   they were left.

## The phone is not a fixture

It is somebody's daily uplink. Prefer `--check`, `--dry-run` and read-only
paths; when a change needs the phone, say what it costs (an uninstall clears the
app's saved proxies) and put it back the way it was found — the app's saved
configuration, its listener port, its battery exemption.
