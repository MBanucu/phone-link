#!/usr/bin/env bash
# Hermetic tests for tests/live/eta.sh: the estimate of what a run has left.
# Plain bash and awk, no phone, no history of its own: a timings.csv written by
# the test stands in for the runs that came before.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/live/eta.sh"

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
same() { # same GOT WANT CLAIM
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "got '$1', wanted '$2'"; fi
}

# Three runs of two steps, plus the run's own row — which is not a step.
cat >"$TMP/timings.csv" <<'EOF'
run,step,seconds,passed,failed,status
r1,panel,10.0,7,0,ok
r1,rename,4.0,2,0,ok
r1,TOTAL,100.0,9,0,ok
r2,panel,12.0,7,0,ok
r2,rename,6.0,2,0,ok
r2,TOTAL,110.0,9,0,ok
r3,panel,14.0,7,0,ok
r3,rename,8.0,2,0,ok
r3,TOTAL,120.0,9,0,ok
r4,PARTIAL,3.0,1,0,partial
EOF

eta_load "$TMP/timings.csv"
same "${ETA_MEDIAN[panel]:-}" 12000 'a step is priced at the median of its runs'
same "${ETA_MEDIAN[rename]:-}" 6000 'a second step too'
same "${ETA_MEDIAN[TOTAL]:-}" '' 'the run total is not a step'
same "${ETA_MEDIAN[PARTIAL]:-}" '' 'neither is a partial run'
same "$(eta_fallback)" 9000 'a step with no history borrows the median of the ones that have'

eta_load "$TMP/timings.csv" 2
same "${ETA_MEDIAN[panel]:-}" 13000 'only the last runs count when asked for fewer'
same "${ETA_MEDIAN[rename]:-}" 7000 'and the even count averages the middle two'

same "$(eta_fmt 400)" 0.4s 'a fraction of a second'
same "$(eta_fmt 12400)" 12.4s 'a short step'
same "$(eta_fmt 62000)" 1m02s 'minutes'
same "$(eta_fmt 3730000)" 1h02m 'an hour'
same "$(eta_fmt -5)" 0.0s 'nothing left reads as no time, not as a negative'

same "$(eta_left 10000 20000 4000)" 26000 'the current step still has some of its own'
same "$(eta_left 10000 20000 10000)" 20000 'a step exactly on its estimate leaves the rest'
same "$(eta_left 10000 20000 20000)" 40000 'a step twice its estimate slows the whole run'
same "$(eta_left 0 20000 99000)" 20000 'a step with no estimate cannot slow anything'

eta_load "$TMP/timings.csv"
# Called directly, not in a substitution: the total it leaves behind is what
# the run judges itself against at the end.
eta_plan panel rename never-seen >"$TMP/plan"
plan=$(cat "$TMP/plan")
same "$ETA_PLAN_MS" 27000 'the plan adds the steps it can price'
case $plan in
  'plan 27.0s: '*) ok 'the plan says what the run should cost' ;;
  *) bad 'the plan says what the run should cost' "$plan" ;;
esac
case $plan in
  *'~9.0s never-seen'*) ok 'a step with no history is priced and marked as a guess' ;;
  *) bad 'a step with no history is priced and marked as a guess' "$plan" ;;
esac

: >"$TMP/empty.csv"
printf 'run,step,seconds,passed,failed,status\n' >"$TMP/empty.csv"
eta_load "$TMP/empty.csv"
same "${#ETA_MEDIAN[@]}" 0 'an empty history prices nothing'
eta_plan panel >"$TMP/plan"
plan=$(cat "$TMP/plan")
same "$ETA_PLAN_MS" 0 'and claims no time at all'
case $plan in
  *'? panel'*) ok 'the plan says so instead of inventing a number' ;;
  *) bad 'the plan says so instead of inventing a number' "$plan" ;;
esac

# What the ticker reads, written by the mark at a step boundary.
ETA_ORDER=(panel rename never-seen)
declare -A ETA_EST=([panel]=10000 [rename]=6000 [never-seen]=9000)
ETA_STATE=$TMP/state
eta_mark rename 5000
IFS=$'\t' read -r marked cur after started rest <"$ETA_STATE"
same "$marked" rename 'the mark names the step it is in'
same "$cur" 6000 'its own estimate'
same "$after" 9000 'and what the steps after it cost'
same "$rest" 1 'how many are after it'
same "$started" 5000 'and when it began'

# The ticker itself: one line a second, reading the mark the way the run writes.
ETA_STATE=$TMP/state
eta_ticker "$TMP/state" 1 >"$TMP/ticks" 2>&1 &
ticker=$!
sleep 1
ETA_STATE=$TMP/state
eta_mark panel 0
printf 'x' >/dev/null
sleep 2
kill "$ticker" 2>/dev/null
wait "$ticker" 2>/dev/null
line=$(head -1 "$TMP/ticks")
case $line in
  eta\ *\ left\ *\(rename\ *) ok 'the ticker says what is left and where the run is' ;;
  *) bad 'the ticker says what is left and where the run is' "$line" ;;
esac
case $line in
  *'1 step after'*) ok 'and how many steps follow, in words that fit' ;;
  *) bad 'and how many steps follow, in words that fit' "$line" ;;
esac

ETA_STATE=$TMP/state
eta_ticker "$TMP/state" 1 >"$TMP/ticks2" 2>&1 &
ticker=$!
sleep 2
kill "$ticker" 2>/dev/null
wait "$ticker" 2>/dev/null
over=$(tail -1 "$TMP/ticks2")
case $over in
  *'over its estimate'*) ok 'a step past its estimate says so instead of claiming none is left' ;;
  *) bad 'a step past its estimate says so instead of claiming none is left' "$over" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
