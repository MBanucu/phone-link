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
      next to the XML. That needs the ~10 ms clock mapping below, so it is the
      second half of the same work; the frames then arrive named after what they
      show (`frame-<check>-<offset>.png`) instead of being searched for by hand.

## Timestamps that survive the recording, to about 10 ms

- [ ] Put every action and every event on the phone on one clock that is tied
      to the recording's timeline closely enough to name the frame: the target
      is ±10 ms between "when this happened on the phone" and "where that is in
      `screen.mp4`". Today the host times the steps, the capture service times
      its snapshots with `System.currentTimeMillis()`, and the moment the
      recording started was never written down, so a failure names a step and
      not a frame. The shape: use `SystemClock.elapsedRealtimeNanos()` on the
      phone for everything on the phone (captures, the accessibility events they
      come from, and each action, stamped on the device rather than on the host
      so a tap reports when it landed and not when it was sent); bracket
      `screenrecord`'s start with a reading of that clock; and calibrate the
      offset between the device clock and the video's own timestamps by flashing
      a marker of known colour at a known device time at the start of the run
      and again at the end, then reading its `pts_time` back with `ffprobe` —
      the second marker also measures drift over the run, which is the only part
      that could exceed 10 ms. Frames are plentiful enough for that: measured on
      this phone, `screen.mp4` runs at the display's 60 Hz (one frame per
      16.7 ms, encoded only when the screen changes), so a known offset locates
      an event within half a frame, about 8 ms.
