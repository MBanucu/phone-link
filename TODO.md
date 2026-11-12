# Work in progress

Ideas taken from the user's messages, in the order they are being built.
Delete an item once it is implemented and committed; delete the file when the
list is empty.

## Several proxies at once

- [ ] Run several proxies on different ports at the same time, which is what the
      list was shaped for: every saved proxy already carries its own port,
      credentials, SSID, switches, log tag and card. Today the service holds one
      `Socks5Server`, one `Uplink` and one `ProxyState` (`ProxyRuntime.state` is
      a single static), so starting a second proxy replaces the first and the
      panel says so. The work is a runtime table instead of that static: a
      listener and its state per proxy, `START --es profile` adding rather than
      replacing, `STOP --es profile` stopping one and `STOP` stopping all,
      `dumpsys` listing every running proxy with its port and bytes (the traffic
      counters are one total per run today), a notification that names them,
      and the tile deciding whether it toggles all or the last one. The SOCKS5
      side needs nothing: a server binds a port and knows nothing of the others.

## A failure brings its own pictures

- [ ] When a check fails, pull the frames that explain it out of the recording
      by itself: the start of the step, the moment of the check, and the end of
      the step, plus one before every action the harness took and one after
      every change the accessibility capture recorded, into the run's folder
      next to the XML. The clock mapping it needs is here: every instant the
      phone writes down is in `clock.txt`'s timeline, so the work is the
      harness pulling the frames it wants and naming them after what they show
      (`frame-<check>-<offset>.png`) instead of a person searching for them.

## A recording that can be played before the run is over

- [ ] Record into something streamable. `screenrecord` writes a plain MP4 with
      its index (`moov`) at the end, so `screen.mp4` cannot be played, seeked or
      previewed — in a browser, a player, a mail attachment — until the run has
      finished and the file was closed; a run that is cut short leaves a file
      with no index at all. The pixels are already H.264, so this needs no
      re-encoding: a remux at the end (`ffmpeg -c copy -movflags +faststart`)
      gives a file that plays and seeks from the first byte, and
      `-movflags frag_keyframe+empty_moov` gives a fragmented MP4 that can be
      read while it is still being written. The cost is a second pass over
      5–80 MB at the end of a run (seconds, no decode) and peak disk for both
      copies; the phone's own recorder has no flag for either, so the remux has
      to happen on the host, or the harness has to read the file out to the host
      while the run goes on.

## A UI test that waits on the phone instead of on the clock

- [ ] Drive the steps by events, not by `sleep`. Today every step is a fixed
      sequence — tap, `sleep 1`, dump, tap, `sleep 2` — so a step costs whatever
      the longest animation in it costs, and a slow phone needs bigger sleeps
      than a fast one while a fast one still pays for them. The pieces are
      already here: the capture service sees every accessibility event and
      writes the screen as XML for each change, stamped with the phone's clock.
      What is missing is a way for the host to *wait* on the stream — a
      broadcast that says "return when a capture whose XML contains this text
      arrives, or after N ms", answered by the service — and a rewrite of the
      waits as conditions: wait for the dialog's button, not for a second; wait
      for the card to say Running, not for two seconds and hope. That also makes
      the harness's own timeline the phone's timeline, which is the same work as
      the failure frames above: every wait gets an event time, so a failure can
      say not just which step but which screen never arrived.
