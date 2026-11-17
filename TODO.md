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
