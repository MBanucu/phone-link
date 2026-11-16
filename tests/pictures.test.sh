#!/usr/bin/env bash
# Hermetic tests for tests/live/pictures.py: which frames a failed check gets
# and where in the recording they are. No phone and no ffmpeg: the plan is what
# is tested, from the files a run leaves — a clock mapping, the failures it
# wrote, and the actions and captures it stamped.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PICTURES="$ROOT/tests/live/pictures.py"
RUN=$TMP/run
mkdir -p "$RUN"

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

# One second of video per 1e9 device nanoseconds, starting at 3 s in: the
# arithmetic is then a subtraction, and a frame named at 12.000 s is a claim a
# person can check against the recording.
cat >"$RUN/clock.txt" <<'EOF'
# the phone's clock in the recording
ref_ns 1000000000
offset_s 3.000000000
drift 1.0
EOF

# One failed check in a step from 10 s to 20 s (device seconds since boot), the
# check decided at 15 s: 12.000 s, 17.000 s and 22.000 s in the video.
cat >"$RUN/failures.csv" <<'EOF'
check,step,start_ns,fail_ns,end_ns
1,plain Save,10000000000,15000000000,20000000000
EOF

cat >"$RUN/actions.csv" <<'EOF'
start_ns,end_ns,kind,detail
500000000,510000000,tap,1 2
11000000000,11100000000,tap,720 1600
14000000000,14100000000,swipe,1300,1200 1300,2200
25000000000,25100000000,tap,1 2
EOF

cat >"$RUN/input.csv" <<'EOF'
start_ns,end_ns,kind,what
16000000000,16100000000,input,text 18099
EOF

cat >"$RUN/ui-index.csv" <<'EOF'
n,device_ns,wall_ms,trigger
1,13000000000,1794795270752,change
2,18000000000,1794795275752,change
3,25000000000,1794795282752,change
EOF

plan=$(python3 "$PICTURES" --plan "$RUN" 2>"$TMP/err")
status=$?
if [ "$status" -eq 0 ]; then
  ok 'the plan is made from the files a run leaves'
else
  bad 'the plan is made from the files a run leaves' "$(cat "$TMP/err")"
fi

name() { # name FRAME -> the second it is taken at
  printf '%s\n' "$plan" | awk -F, -v want="$1" '$1 == want { print $2 }'
}

same() { # same GOT WANT CLAIM
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "got '$1', wanted '$2'"; fi
}

same "$(name frame-1-step-start.png)" 12.000 'the frame at the start of the step'
same "$(name frame-1-check.png)" 17.000 'the frame at the moment the check was decided'
same "$(name frame-1-step-end.png)" 22.000 'and the frame at the end of the step'
same "$(name frame-1-action-1-before.png)" 12.800 'a frame just before each action the harness took'
same "$(name frame-1-action-2-before.png)" 15.800 'the second action too'
same "$(name frame-1-input-1-before.png)" 17.800 'typing is an action, and gets a frame'
same "$(name frame-1-capture-1-after.png)" 15.200 'a frame just after each change the capture service recorded'
same "$(name frame-1-capture-2-after.png)" 20.200 'the second change too'
same "$(name frame-1-action-3-before.png)" '' 'an action outside the step is not in it'
same "$(name frame-1-capture-3-after.png)" '' 'and neither is a capture outside it'
same "$(printf '%s\n' "$plan" | grep -c .)" 8 'only the frames the step has'

# The gaps are a setting, because a tap stamped when the phone took it and a
# capture stamped after the screen changed are both a moment past the screen.
plan=$(python3 "$PICTURES" --plan "$RUN" --before 0.5 --after 0.1 2>/dev/null)
same "$(name frame-1-action-1-before.png)" 12.500 'how far before an action is a setting'
same "$(name frame-1-capture-1-after.png)" 15.100 'and how far after a capture'

# A frame is never asked for before the recording begins, nor past its end.
cat >"$RUN/failures.csv" <<'EOF'
check,step,start_ns,fail_ns,end_ns
2,early,500000000,1000000000,1100000000
EOF
plan=$(python3 "$PICTURES" --plan "$RUN" --before 5 2>/dev/null)
same "$(name frame-2-step-start.png)" 2.500 'a step at the beginning of the run is found'
same "$(name frame-2-action-1-before.png)" 0.000 'and a frame before it is clamped to the first one'
cat >"$RUN/failures.csv" <<'EOF'
check,step,start_ns,fail_ns,end_ns
2,late,10000000000,15000000000,20000000000
EOF
plan=$(python3 "$PICTURES" --plan "$RUN" --duration 5 2>/dev/null)
same "$(name frame-2-step-end.png)" 5.000 'a frame past the end of a recording is clamped to its length'

# A green run leaves no failures, and that is nothing to pull, not an error.
cat >"$RUN/failures.csv" <<'EOF'
check,step,start_ns,fail_ns,end_ns
EOF
out=$(python3 "$PICTURES" --plan "$RUN" 2>"$TMP/err")
if [ "$?" -eq 0 ] && ! printf '%s\n' "$out" | grep -q '^frame-'; then
  ok 'a run with no failures plans no frames'
else
  bad 'a run with no failures plans no frames' "$out $(cat "$TMP/err")"
fi

# Without a clock mapping there is nowhere to look, and it says so.
rm -f "$RUN/clock.txt"
cat >"$RUN/failures.csv" <<'EOF'
check,step,start_ns,fail_ns,end_ns
1,plain Save,10000000000,15000000000,20000000000
EOF
if python3 "$PICTURES" --plan "$RUN" >/dev/null 2>"$TMP/err"; then
  bad 'a run with no clock mapping is refused'
else
  ok 'a run with no clock mapping is refused'
fi
case $(cat "$TMP/err") in
  *'cannot read the clock mapping'*) ok 'and says why' ;;
  *) bad 'and says why' "$(cat "$TMP/err")" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
