#!/usr/bin/env bash
# Shared UI helpers for the proxy scripts in ../bin.
#
# The app builds its screen in code and is not debuggable, so there is no
# resource id or preference file to use: the hierarchy is read with
# uiautomator and tapped by node centre. Source this after lib/phone-net.sh.
#
#   . "$(dirname -- "$0")/../lib/phone-net.sh"
#   . "$(dirname -- "$0")/../lib/phone-ui.sh"

PHONE_UI_REMOTE=${PHONE_UI_REMOTE:-/sdcard/phone-link-ui.xml}
PHONE_UI_TIMEOUT=${PHONE_UI_TIMEOUT:-20}

# phone_ui_unlock_bin -> the phone-unlock script, from PATH or next to us
phone_ui_unlock_bin() {
  local bin
  bin=$(command -v phone-unlock 2>/dev/null || true)
  if [ -z "$bin" ]; then
    bin=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../bin/phone-unlock
  fi
  [ -x "$bin" ] || return 1
  printf '%s' "$bin"
}

# phone_ui_keyguard SERIAL -> true while the lock screen is showing
phone_ui_keyguard() {
  adb -s "$1" shell dumpsys window policy 2>/dev/null \
    | tr -d '\r' | sed -n 's/^ *showing=\(true\|false\)$/\1/p' | head -1 | grep -qx true
}

# phone_ui_launch SERIAL -> bring the app's activity to the front
phone_ui_launch() {
  adb -s "$1" shell monkey -p "$PHONE_PROXY_PKG" \
    -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
}

# phone_ui_dump SERIAL FILE -> save the hierarchy; false if the app is not up
phone_ui_dump() {
  local serial=$1 file=$2
  # uiautomator can block while a dialog animates, so bound the dump.
  timeout "$PHONE_UI_TIMEOUT" adb -s "$serial" shell uiautomator dump "$PHONE_UI_REMOTE" \
    >/dev/null 2>&1 || return 1
  adb -s "$serial" pull "$PHONE_UI_REMOTE" "$file" >/dev/null 2>&1 || return 1
  [ -s "$file" ] || return 1
  grep -q "$PHONE_PROXY_PKG" "$file" || return 1
}

# phone_ui_scan FILE -> BUTTON and STATUS lines. Buttons are collected from
# every package so permission and battery dialogs are visible too.
phone_ui_scan() {
  python3 - "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET

tree = ET.parse(sys.argv[1])
for node in tree.iter("node"):
    cls = (node.get("class") or "").rsplit(".", 1)[-1]
    text = (node.get("text") or "").replace("\t", " ")
    bounds = node.get("bounds") or ""
    if not (bounds.startswith("[") and "][" in bounds):
        continue
    left, right = bounds.strip("[]").split("][")
    try:
        x1, y1 = (int(v) for v in left.split(","))
        x2, y2 = (int(v) for v in right.split(","))
    except ValueError:
        continue
    x, y = (x1 + x2) // 2, (y1 + y2) // 2
    if cls == "Button":
        print("BUTTON\t%d\t%d\t%s" % (x, y, text))
    elif cls == "TextView" and any(
        k in text
        for k in ("Proxy Running", "Failed to Start", "Proxy Stopped", "Starting", "Stopped")
    ):
        print("STATUS\t%s" % text)
PY
}

# phone_ui_button FILE REGEX -> "x y text" for the first button that matches
phone_ui_button() {
  phone_ui_scan "$1" \
    | awk -F'\t' -v p="$2" '$1 == "BUTTON" && $4 ~ p { print $2 " " $3 " " $4; exit }'
}

# phone_ui_blocker FILE -> "x y" of a dialog button that lets a start proceed
phone_ui_blocker() {
  local pat line
  for pat in '^Continue Anyway' '^Allow' '^OK' '^Got it' '^While using'; do
    line=$(phone_ui_scan "$1" \
      | awk -F'\t' -v p="$pat" '$1 == "BUTTON" && $4 ~ p { print $2 " " $3; exit }')
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return 0
    fi
  done
  return 1
}

# phone_ui_status FILE -> the app's status line, if any
phone_ui_status() {
  phone_ui_scan "$1" | awk -F'\t' '$1 == "STATUS" { print $2; exit }'
}
