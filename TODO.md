# Work in progress

Ideas taken from the user's messages, in the order they are being built.
Delete an item once it is implemented and committed; delete the file when the
list is empty.

## The proxy app's own repository

- [ ] Push it. The split itself is done and committed on both sides: the app's
  history (44 commits of it) is a repository of its own with a flake of its own
  (shell, APK, unit, format and a changelog check), a `v*` release workflow, the
  live harness and the fastlane metadata, and this checkout consumes its
  releases. What is left is the part that is a decision rather than work:
  creating `MBanucu/phone-link-proxy`, setting its four `ANDROID_*` secrets,
  pushing `main` and `v0.10.0`, and pointing `phone-proxy-install` at it — it
  already defaults to that name.

- [ ] The store listings. F-Droid wants an app id and a review round (the
  metadata it reads is in the tree); Google Play wants a developer account, an
  AAB and Google's app signing, which needs `bundletool` and a key that is not
  in any checkout. Neither can be created from here.

- [ ] Screenshots for the fastlane tree. The text is done, the pictures are
  not: they need a phone showing proxies that are nobody's real ones, which is
  a cleaning decision before it is a capture one.
