# Work in progress

Ideas taken from the user's messages, in the order they are being built.
Delete an item once it is implemented and committed; delete the file when the
list is empty.

## The proxy app's own repository

- [x] Pushed. `MBanucu/phone-link-proxy` exists, its `main` and `v0.10.0` are
  there, its four `ANDROID_*` secrets are set with a key generated for it
  (SHA-256 `8D:22:ED:6D:…:3B:B2`; the keystore and its password are in
  `~/.config/phone-link/`, and they are the only copy outside the secret —
  back them up), the tag's run built and attached
  `phone-link-proxy-0.10.0.apk` and its `.sha256`, and a bare
  `phone-proxy-install --check` fetches it and matches the checksum. The key is
  new, so a phone on 0.9.x needs `--replace-signer` once, which clears its
  saved proxies; the release notes say so.

- [ ] The store listings. F-Droid wants an app id and a review round (the
  metadata it reads is in the tree); Google Play wants a developer account, an
  AAB and Google's app signing, which needs `bundletool` and a key that is not
  in any checkout. Neither can be created from here.

- [ ] Screenshots for the fastlane tree. The text is done, the pictures are
  not: they need a phone showing proxies that are nobody's real ones, which is
  a cleaning decision before it is a capture one.
