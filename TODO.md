# Work in progress

Ideas taken from the user's messages, in the order they are being built.
Delete an item once it is implemented and committed; delete the file when the
list is empty.

## One port, chosen from the panel

- [ ] Switching the proxy port from the laptop GUI. The port lives in three
  places that never talk to each other: `phoneLink.proxyPort` is baked into the
  sing-box config, the `phone-tun` toggle's `/dev/tcp` probe and the relay's
  upstream at build time; the scripts and the doctor read `PHONE_PROXY_PORT`
  from the environment; and the phone's listener is whatever
  `phone-proxy-setup --port` or one of the app's saved proxies last started. So
  changing ports is a module edit and `nixos-rebuild switch`, and a phone
  listening somewhere else is found by the tunnel failing its request, not by
  anything that asked the phone first. Done means one control in the GUI: pick a
  port, or a proxy saved on the phone by name, and the laptop makes it the
  active one — requiring the phone to be listening there (starting that saved
  proxy over the adb contract when it is not, and refusing instead of
  half-switching when the phone cannot serve it), then repointing the tunnel and
  the relay without a rebuild (a runtime file under `/run` with
  `phoneLink.proxyPort` as its default, read by the units and by the scripts),
  restarting what was running, and dropping the old port only once the new one
  has answered. The doctor grows the matching check — the port the laptop is
  using and the port the phone is listening on are the same — and the GUI shows
  which one that is. The part that is more than a form: a saved proxy carries
  its own user and password, and the adb contract never prints a password, so a
  switch to another proxy needs its credentials from the secrets file; either
  the switch offers only the proxies the laptop already has credentials for and
  says why for the rest, or the control asks for the one it is missing. What
  proves it: a hermetic suite with stub `adb`/`curl` covering the order above,
  the refusal and a phone that fails to start, and the module check for the
  runtime file and the toggle reading it.

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
