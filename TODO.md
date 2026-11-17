# Work in progress

Ideas taken from the user's messages, in the order they are being built.
Delete an item once it is implemented and committed; delete the file when the
list is empty.

## The app's proxies, over adb

- [ ] Exporting and importing the app's saved proxies is a tap-through: the
  menu's *Export every proxy…* opens the system picker, so someone has to choose
  a folder — in practice a shared one, which the confirmation dialog itself
  warns against, because the file holds every proxy's password in clear text —
  and *Import proxies…* needs the same taps to get it back. The adb contract
  cannot help: it never prints a password, by design, because anything on the
  `am` command line or in a `dumpsys` dump is readable by every process that can
  talk to adbd. So the two things that lose the proxies — a signing-key change
  (`phone-proxy-install --replace-signer` uninstalls first) and a lost or reset
  phone — are both recoverable only by hand, and the second only if the file
  was exported recently. Done means the laptop can do it over adb: one command
  that pulls every saved proxy with its port, SSID, credentials and flags into a
  file the laptop keeps private (root-only, beside the secrets), and one that
  puts them back after an install, so `--replace-signer` exports first and
  imports after instead of asking someone to remember. The app side is the same
  `ProfileDocument` JSON the menu already writes, so nothing new is trusted with
  the passwords; what needs deciding is how it crosses: a file the app writes
  where adb can read it, or a socket the laptop pulls through `adb forward` and
  that leaves no plain-text file on the phone at all — and what bounds it, since
  a command that hands out passwords is exactly what the contract refuses to
  have: a panel toggle that adb can only flip while the screen is unlocked, say,
  or an action only a debug build carries. What proves it: the Android-free unit
  test for the document round trip, a hermetic suite with a stub `adb` for the
  laptop side (export, install, import, and a phone that answers with nothing),
  and a live step that exports, replaces the signer and checks the proxy answers
  on the port it had before.

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

- [ ] The F-Droid merge request. Everything F-Droid asked for is now in
  `MBanucu/phone-link-proxy`: the licence (GPL-3.0-or-later, tag `v0.11.1`),
  the store text and images the fastlane tree already carried, and
  `fdroid/org.phonelink.proxy.yml`, a 0.11.1 entry that lints clean and that
  `fdroid rewritemeta` leaves alone. What is left is a GitLab account, the
  fork and branch `org.phonelink.proxy`, that file copied to `metadata/`, and
  their review — the first inclusion takes weeks. Their build re-signs the
  APK, so an install from f-droid.org cannot replace the GitHub one without an
  uninstall, which clears the app's saved proxies.

- [ ] The Play listing. A developer account, an AAB and Google's app signing,
  which needs `bundletool` and a key that is not in any checkout. Not an
  agent's to create.
