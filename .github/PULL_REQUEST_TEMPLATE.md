## Summary

<!-- What was wrong, and what is different now. One change per PR. -->

## Test evidence

<!-- The commands you ran and their result. Not "tests pass" — the output. -->

```console
$ nix flake check
...
```

## Hardware and phone impact

<!--
What this costs on a real phone: does it need the phone, does it restart the
tunnel or the AP, does it clear saved proxies or settings? Write "none" if no
phone was touched.
-->

## Linked issues

<!-- Closes #... / Refs #... — one issue per PR where it can be. -->

## Checklist

- [ ] `nix flake check` passes (or the affected suites, if a full run is not practical — say which)
- [ ] Shell and Nix changes pass `shellcheck -S warning` and `nixfmt --check`
- [ ] `README.md` and `CHANGELOG.md` updated for user-visible changes
- [ ] No secrets, real addresses or personal data added
- [ ] Hermetic tests still need no phone, root or network
