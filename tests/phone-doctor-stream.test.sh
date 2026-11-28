#!/usr/bin/env bash
# Hermetic tests for phone-doctor --json-stream. The check modules are stubbed
# in-process, so no phone, root or network is involved, and the event order is
# fixed by the stubs.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib/harness.sh"
suite --no-home


cat >"$TMP/stub.py" <<'PY'
import os
import sys
import time

from phone_doctor import cli
from phone_doctor.model import fail, ok, skip, warn
from phone_doctor.status import Section


class Module:
    def __init__(self, section, results, delay=0.0):
        self.SECTION = section
        self._results = results
        self._delay = delay

    def check(self, _ctx):
        if self._delay:
            time.sleep(self._delay)
        return list(self._results)


MODULES = [
    Module("[zeta]", [warn("z1", "zeta one", "first"), ok("z2", "zeta two", "second")]),
    Module("[alpha]", [fail("a1", "alpha one", "third"), skip("a2", "alpha two", "fourth")], 0.7),
]


def fake_collect(_ctx, *, jobs, modules=None, on_section=None, on_result=None):
    # The real engine is tested in phone-doctor-parallel.test.sh. Here the
    # stub only has to keep the contract: section, then its results, in order.
    target = os.environ.get("STUB_JOBS_FILE")
    if target:
        with open(target, "w") as handle:
            handle.write(str(jobs))
    sections = []
    for module in MODULES:
        if on_section is not None:
            on_section(module.SECTION)
        results = tuple(module.check(_ctx))
        sections.append(Section(module.SECTION, results))
        if on_result is not None:
            for result in results:
                on_result(module.SECTION, result)
    return sections


cli.collect_parallel = fake_collect

sys.exit(cli.main(sys.argv[1:]))
PY

run() {
  PYTHONPATH="$ROOT/lib/python" python3 "$TMP/stub.py" "$@"
}

# 1. The stream has the section/result/done order of the report, and the exit
#    status is the normal "not ready" one.
run --json-stream >"$TMP/stream" 2>"$TMP/err"
code=$?
[ "$code" -eq 1 ] && ok "--json-stream exits 1 when a check fails" \
  || bad "--json-stream exits 1 when a check fails" "exit $code"
[ -s "$TMP/err" ] && bad "the stream writes no stderr" "$(cat "$TMP/err")" \
  || ok "the stream writes no stderr"

python3 - "$TMP/stream" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    lines = handle.read().splitlines()
events = [json.loads(line) for line in lines]
assert all(isinstance(event, dict) for event in events), events
kinds = [event["event"] for event in events]
assert kinds == [
    "section", "result", "result", "section", "result", "result", "done"
], kinds
assert events[0] == {"event": "section", "name": "[zeta]"}, events[0]
assert events[3] == {"event": "section", "name": "[alpha]"}, events[3]
assert events[1]["section"] == "[zeta]" and events[1]["result"]["id"] == "z1"
assert events[4]["section"] == "[alpha]" and events[4]["result"]["status"] == "fail"
assert events[-1] == {
    "event": "done",
    "ready": False,
    "counts": {"ok": 1, "warn": 1, "fail": 1, "skip": 1},
}, events[-1]
print("order")
PY
[ "$?" -eq 0 ] && ok "emits section/result/done in report order" \
  || bad "emits section/result/done in report order"

# 2. Rebuilding the document from the events gives exactly the --json payload.
run --json >"$TMP/report"
python3 - "$TMP/stream" "$TMP/report" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1]).read().splitlines()]
expected = json.load(open(sys.argv[2]))
sections = []
by_name = {}
for event in events:
    if event["event"] == "section":
        section = {"name": event["name"], "results": []}
        sections.append(section)
        by_name[event["name"]] = section
    elif event["event"] == "result":
        by_name[event["section"]]["results"].append(event["result"])
    elif event["event"] == "done":
        rebuilt = {
            "ready": event["ready"],
            "counts": event["counts"],
            "sections": sections,
        }
assert rebuilt == expected, (rebuilt, expected)
print("same")
PY
[ "$?" -eq 0 ] && ok "reconstructed stream equals --json" \
  || bad "reconstructed stream equals --json"

# 3. Every line is flushed before the run ends: reading the first events from a
#    pipe must not wait for the slow second section.
python3 - "$ROOT/lib/python" "$TMP/stub.py" <<'PY'
import json
import os
import subprocess
import sys

env = dict(os.environ, PYTHONPATH=sys.argv[1])
proc = subprocess.Popen(
    [sys.executable, sys.argv[2], "--json-stream"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    env=env,
)
first = proc.stdout.readline()
second = proc.stdout.readline()
assert first, "no first line"
assert second, "no second line"
assert json.loads(first) == {"event": "section", "name": "[zeta]"}, first
assert json.loads(second)["event"] == "result", second
assert proc.poll() is None, "the process finished before the slow section"
proc.communicate(timeout=10)
print("flushed")
PY
[ "$?" -eq 0 ] && ok "flushes each event before the run ends" \
  || bad "flushes each event before the run ends"

# 4. --json-stream shares --jobs with the report, so a parallel run streams in
#    completion order instead of forcing a sequential collect.
STUB_JOBS_FILE="$TMP/jobs" run --json-stream --jobs 3 >/dev/null 2>&1
[ "$(cat "$TMP/jobs" 2>/dev/null)" = 3 ] && ok "--json-stream forwards --jobs" \
  || bad "--json-stream forwards --jobs" "$(cat "$TMP/jobs" 2>/dev/null)"

finish
