#!/usr/bin/env bash
# Hermetic tests for the status page's stream parser and row state machine.
# It imports no GTK: the widget code is the only part that needs a display.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$*"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s%s\n' "$*" "${2:+ ($2)}"
}

out=$(PYTHONPATH="$ROOT/lib/python" python3 - <<'PY'
import json

from phone_link_gui.status_model import PENDING, StatusStream, parse_line

# -- parser ---------------------------------------------------------
assert parse_line("") is None
assert parse_line("   ") is None
assert parse_line("warning: adb is slow") is None
assert parse_line("{not json") is None
assert parse_line('["event"]') is None
assert parse_line('{"event": "unknown"}') is None
assert parse_line('{"event": "section", "name": "[flake]"}') == {
    "event": "section", "name": "[flake]"
}
result = {"event": "result", "section": "[flake]", "result": {"id": "x"}}
assert parse_line(json.dumps(result)) == result
assert parse_line('{"event": "done", "ready": true, "counts": {}}')["event"] == "done"


def report():
    return {
        "ready": True,
        "counts": {"ok": 2, "warn": 0, "fail": 0, "skip": 0},
        "sections": [
            {
                "name": "[a]",
                "results": [
                    {"status": "ok", "id": "a1", "label": "a one", "detail": "old"},
                    {"status": "ok", "id": "a2", "label": "a two", "detail": "old"},
                ],
            },
            {
                "name": "[b]",
                "results": [
                    {"status": "ok", "id": "b1", "label": "b one", "detail": "old"},
                ],
            },
        ],
    }


def result_event(section, cid, status, detail="new"):
    return {
        "event": "result",
        "section": section,
        "result": {"status": status, "id": cid, "label": cid, "detail": detail},
    }


# -- pending -> result ----------------------------------------------
stream = StatusStream(report=report())
assert stream.ready is True
assert stream.total_rows() == 3
stream.begin()
assert all(row.pending for rows in stream.rows.values() for row in rows.values())
assert stream.reported_rows() == 0
assert stream.counts() == {"ok": 0, "warn": 0, "fail": 0, "skip": 0}

change = stream.apply(result_event("[a]", "a1", "fail"))
assert change.accepted and not change.new_row and change.row.status == "fail"
assert stream.counts()["fail"] == 1 and stream.reported_rows() == 1
# A repeated event for the same row updates it in place rather than adding one.
assert stream.apply(result_event("[a]", "a1", "ok")).row.status == "ok"
assert len(stream.rows["[a]"]) == 2
assert stream.apply(
    {"event": "done", "ready": False, "counts": {"ok": 3, "warn": 0, "fail": 0, "skip": 0}}
).accepted
assert stream.done and stream.ready is False
# The check that never sent a result keeps the last report's value.
assert stream.rows["[a]"]["a1"].status == "ok"
assert stream.rows["[a]"]["a2"].status == "ok"
assert stream.rows["[b]"]["b1"].status == "ok"
assert stream.reported_rows() == 3
assert stream.payload()["sections"][0]["results"][0]["id"] == "a1"

# -- unknown and out-of-order ids are ignored -----------------------
stream = StatusStream(report=report())
stream.begin()
assert not stream.apply(result_event("[a]", "nope", "fail")).accepted
assert not stream.apply(result_event("[missing]", "a1", "fail")).accepted
assert not stream.apply(result_event("[b]", "a1", "fail")).accepted
assert stream.total_rows() == 3
assert all(row.pending for rows in stream.rows.values() for row in rows.values())

# -- first run: no report, section skeleton, results define the rows --
stream = StatusStream(["[a]", "[b]"])
assert stream.total_rows() == 0
stream.begin()
assert stream.apply({"event": "section", "name": "[a]"}).new_section is False
change = stream.apply(result_event("[a]", "new1", "warn"))
assert change.accepted and change.new_row
assert stream.apply(result_event("[a]", "new2", "ok")).new_row
stream.apply({"event": "done", "ready": True, "counts": {}})
assert stream.ready is True
assert [row.cid for row in stream.rows["[a]"].values()] == ["new1", "new2"]
assert stream.rows["[b]"] == {}

# -- error path: restore the last report, keep the error ------------
stream = StatusStream(report=report())
stream.begin()
stream.apply(result_event("[a]", "a1", "fail"))
stream.fail("phone-doctor exited 1")
assert stream.error == "phone-doctor exited 1"
assert not stream.done
assert stream.rows["[a]"]["a1"].status == "ok"
assert stream.rows["[a]"]["a1"].detail == "old"
assert stream.rows["[a]"]["a2"].status == "ok"
assert stream.counts() == {"ok": 3, "warn": 0, "fail": 0, "skip": 0}

print("all")
PY
)
if [ "$out" = all ]; then
  ok "parser and row state machine (pending, results, unknown ids, error)"
else
  bad "parser and row state machine (pending, results, unknown ids, error)" "$out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
