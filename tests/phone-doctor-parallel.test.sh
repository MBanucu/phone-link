#!/usr/bin/env bash
# Hermetic tests for phone_doctor.parallel and the Context caches under
# threads: fast/slow ordering, canonical --json order, a raised check and
# one-time cache initialisation. No phone, no network, no root.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib/harness.sh"
suite
export PYTHONPATH="$ROOT/lib/python"


# 1. A fast module's result is announced while the slow module is still
#    running, the returned sections keep the module order, and nothing is
#    announced after collect_parallel returns.
out=$(python3 - <<'PY'
import threading

from phone_doctor.model import ok
from phone_doctor.parallel import collect_parallel

release = threading.Event()
events = []
lock = threading.Lock()


class Slow:
    SECTION = "[slow]"

    @staticmethod
    def check(_ctx):
        release.wait(2)
        return [ok("slow", "slow", "done")]


class Fast:
    SECTION = "[fast]"

    @staticmethod
    def check(_ctx):
        return [ok("fast", "fast", "done")]


def section(name):
    with lock:
        events.append(("section", name))


def result(name, item):
    with lock:
        events.append(("result", name, item.cid))
    if name == "[fast]":
        release.set()


sections = collect_parallel(
    None,
    jobs=2,
    modules=[Slow, Fast],
    on_section=section,
    on_result=result,
)
with lock:
    events.append(("return",))

announced = [event for event in events if event[0] in ("section", "result")]
assert announced == [
    ("section", "[fast]"),
    ("result", "[fast]", "fast"),
    ("section", "[slow]"),
    ("result", "[slow]", "slow"),
], events
assert [item.name for item in sections] == ["[slow]", "[fast]"], sections
assert events[-1] == ("return",), events
assert sum(1 for event in events if event[:2] == ("section", "[fast]")) == 1
assert sum(1 for event in events if event[:2] == ("result", "[fast]")) == 1
print("fast-first")
PY
)
[ "$out" = fast-first ] && ok "a fast check streams before a slow one finishes" \
  || bad "a fast check streams before a slow one finishes" "$out"

# 2. --jobs 1 and --jobs 2 produce the same --json document and section
#    order, even though the modules finish in a different order.
out=$(python3 - <<'PY'
import contextlib
import io
import json
import time

from phone_doctor import cli
from phone_doctor import parallel
from phone_doctor.model import ok

real = parallel.collect_parallel


class Slow:
    SECTION = "[slow]"

    @staticmethod
    def check(_ctx):
        time.sleep(0.1)
        return [ok("slow", "slow", "done")]


class Fast:
    SECTION = "[fast]"

    @staticmethod
    def check(_ctx):
        return [ok("fast", "fast", "done")]


class Other:
    SECTION = "[other]"

    @staticmethod
    def check(_ctx):
        return [ok("other", "other", "done")]


MODULES = [Slow, Fast, Other]


def fake(ctx, *, jobs, modules=None, on_section=None, on_result=None):
    return real(
        ctx,
        jobs=jobs,
        modules=MODULES,
        on_section=on_section,
        on_result=on_result,
    )


cli.collect_parallel = fake


def run(jobs):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = cli.main(["--json", "--jobs", str(jobs)])
    return code, buffer.getvalue()


code1, text1 = run(1)
code2, text2 = run(2)
assert text1 == text2, (text1, text2)
assert code1 == code2 == 0, (code1, code2)
payload = json.loads(text1)
assert [section["name"] for section in payload["sections"]] == [
    "[slow]",
    "[fast]",
    "[other]",
], payload
print("same-payload")
PY
)
[ "$out" = same-payload ] && ok "--jobs 1 and 2 print the same --json document" \
  || bad "--jobs 1 and 2 print the same --json document" "$out"

# 3. A module that raises becomes one stable failure, and its peers still
#    return in canonical order. The same happens on the sequential path.
out=$(python3 - <<'PY'
from phone_doctor.model import Status, ok
from phone_doctor.parallel import collect_parallel


class Before:
    SECTION = "[before]"

    @staticmethod
    def check(_ctx):
        return [ok("before", "before", "done")]


class Broken:
    SECTION = "[broken]"

    @staticmethod
    def check(_ctx):
        raise RuntimeError("kaboom")


class After:
    SECTION = "[after]"

    @staticmethod
    def check(_ctx):
        return [ok("after", "after", "done")]


for jobs in (1, 2):
    sections = collect_parallel(
        None, jobs=jobs, modules=[Before, Broken, After]
    )
    assert [section.name for section in sections] == [
        "[before]",
        "[broken]",
        "[after]",
    ], sections
    broken = sections[1].results
    assert len(broken) == 1, broken
    assert broken[0].status is Status.FAIL, broken
    assert broken[0].cid == "Broken_error", broken
    assert "kaboom" in broken[0].detail, broken
    assert [result.status for result in sections[0].results] == [Status.OK]
    assert [result.status for result in sections[2].results] == [Status.OK]
print("survives-raise")
PY
)
[ "$out" = survives-raise ] && ok "a raised check becomes one failure, peers survive" \
  || bad "a raised check becomes one failure, peers survive" "$out"

# 4. --jobs rejects zero with an argparse error, and auto is the documented
#    min(8, len(MODULES)).
if python3 -m phone_doctor --jobs 0 >/dev/null 2>"$TMP/jobs.err"; then
  bad "--jobs 0 is rejected"
else
  grep -q 'job count must be at least 1' "$TMP/jobs.err" \
    && ok "--jobs 0 is rejected with a clear error" \
    || bad "--jobs 0 is rejected with a clear error" "$(cat "$TMP/jobs.err")"
fi
out=$(python3 - <<'PY'
from phone_doctor.checks import MODULES
from phone_doctor.cli import _jobs

assert _jobs("auto") == min(8, len(MODULES)), _jobs("auto")
assert _jobs("3") == 3
print("jobs-ok")
PY
)
[ "$out" = jobs-ok ] && ok "--jobs auto and an explicit count parse" \
  || bad "--jobs auto and an explicit count parse" "$out"

finish
