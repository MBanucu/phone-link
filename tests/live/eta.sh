#!/usr/bin/env bash
# How much of a run is left, from the step timings of past runs.
#
#   . tests/live/eta.sh
#
# `result-live/timings.csv` is append-only with one row per step per run, so the
# last N rows of a step are its last N runs and the median of them is what the
# step usually costs — the same file a person reads after a run, used while one
# is going.
#
# The plan prints once at the start: what the run should cost and what each step
# is priced at. A step the history has never seen (every new check writes one)
# is priced at the median of the ones it has and marked with a `~`, so a guess
# reads like a guess instead of hiding in the total. `PHONE_LIVE_ETA=0` turns
# the estimate off, `PHONE_LIVE_ETA_EVERY` (seconds) says how often the ticker
# speaks, `PHONE_LIVE_ETA_RUNS` how many past runs a median is taken over.
#
# The number is not "the plan minus what has happened": a step that outlives its
# estimate says the run is going slower, and the rest of it is priced the way
# the step is really going, so the line keeps moving while a step drags instead
# of sitting at zero and hiding the hang. Plain bash and awk, no phone, which is
# what makes tests/eta.test.sh able to cover the arithmetic.
set -u

# Steps and what they usually cost, in milliseconds, filled by eta_load.
declare -A ETA_MEDIAN=()

# How far past its estimate a step has to be before it is worth a word, on top
# of twice its usual time: a two-second step at five is not news, a minute at
# three is.
ETA_SLOW_MS=${ETA_SLOW_MS:-30000}

# Reads the history: for every step, the median of its last RUNS rows.
eta_load() { # eta_load TIMINGS.csv [RUNS]
  local file=$1 runs=${2:-5} step seconds
  ETA_MEDIAN=()
  [ -f "$file" ] || return 0
  # A tab separates the step from its number, because a step's name has spaces
  # in it ("card toggle") and a space would split the name.
  while IFS=$'\t' read -r step seconds; do
    [ -n "$step" ] && [ -n "$seconds" ] || continue
    ETA_MEDIAN[$step]=$(awk -v s="$seconds" 'BEGIN { printf "%.0f", s * 1000 }')
  done <<EOF
$(awk -F, -v runs="$runs" '
  NR == 1 { next }
  # TOTAL and PARTIAL are runs, not steps, and a filtered run has no step rows.
  NF < 3 || $2 == "" || $2 == "TOTAL" || $2 == "PARTIAL" { next }
  { n[$2]++; v[$2, n[$2]] = $3 + 0 }
  END {
    for (step in n) {
      from = n[step] - runs + 1
      if (from < 1) from = 1
      c = 0
      for (i = from; i <= n[step]; i++) w[++c] = v[step, i]
      for (i = 2; i <= c; i++) {
        x = w[i]
        for (j = i - 1; j >= 1 && w[j] > x; j--) w[j + 1] = w[j]
        w[j + 1] = x
      }
      median = (c % 2) ? w[(c + 1) / 2] : (w[c / 2] + w[c / 2 + 1]) / 2
      printf "%s\t%s\n", step, median
    }
  }' "$file")
EOF
}

# The median of what is known, for a step that has no history of its own.
eta_fallback() {
  local step
  [ "${#ETA_MEDIAN[@]}" -gt 0 ] || return 0
  for step in "${!ETA_MEDIAN[@]}"; do
    printf '%s\n' "${ETA_MEDIAN[$step]}"
  done | sort -n | awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) exit
      printf "%.0f", (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
    }'
}

# Milliseconds as a person reads them: 0.4s, 12.4s, 1m02s, 1h02m.
eta_fmt() { # eta_fmt MILLISECONDS
  local ms=${1:-0}
  [ "$ms" -ge 0 ] || ms=0
  awk -v ms="$ms" 'BEGIN {
    s = ms / 1000
    if (s < 60) printf "%.1fs", s
    else if (s < 3600) printf "%dm%02ds", int(s / 60), int(s) % 60
    else printf "%dh%02dm", int(s / 3600), int(s / 60) % 60
  }'
}

# The plan, one line, and ETA_PLAN_MS for the end of the run to be judged
# against. Prices come from the history; a step with none is borrowed and marked.
eta_plan() { # eta_plan STEP...
  local fallback step value total=0 line="" assumed="" part
  fallback=$(eta_fallback)
  for step in "$@"; do
    value=${ETA_MEDIAN[$step]:-}
    if [ -n "$value" ]; then
      part=$(eta_fmt "$value")
    elif [ -n "$fallback" ]; then
      value=$fallback
      part="~$(eta_fmt "$value")"
      assumed="$assumed $step"
    else
      value=0
      part="?"
      assumed="$assumed $step"
    fi
    total=$((total + value))
    line="$line $part $step ·"
  done
  ETA_PLAN_MS=$total
  printf 'plan %s:%s\n' "$(eta_fmt "$total")" "$line"
  if [ -n "$assumed" ]; then
    printf 'plan   (no history of its own, priced like the rest:%s)\n' "$assumed"
  fi
  return 0
}

# Milliseconds from now until the end, or at least none.
eta_left() { # eta_left EST_CURRENT EST_AFTER ELAPSED
  local cur=${1:-0} after=${2:-0} elapsed=${3:-0} left
  if [ "$cur" -le 0 ]; then
    left=$after
  elif [ "$elapsed" -le "$cur" ]; then
    left=$((after + cur - elapsed))
  else
    # The step is over its estimate, so the rest is priced at the same pace: a
    # step that takes twice its median means the run does, not that the steps
    # after it became free.
    left=$(((cur + after) * elapsed / cur - elapsed))
  fi
  [ "$left" -ge 0 ] || left=0
  printf '%s\n' "$left"
}

# What the ticker reads: the step, what it usually takes, what the ones after it
# cost, when it started and how many steps follow. Rewritten whole and moved
# into place, so a tick never reads half a line.
eta_mark() { # eta_mark NAME STARTED_MS
  [ -n "${ETA_STATE:-}" ] || return 0
  local name=$1 started=$2 i j after=0 rest=0
  for i in "${!ETA_ORDER[@]}"; do
    [ "${ETA_ORDER[$i]}" = "$name" ] || continue
    for ((j = i + 1; j < ${#ETA_ORDER[@]}; j++)); do
      after=$((after + ${ETA_EST[${ETA_ORDER[$j]}]:-0}))
      rest=$((rest + 1))
    done
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${ETA_EST[$name]:-0}" "$after" \
      "$started" "$rest" >"$ETA_STATE.part"
    mv "$ETA_STATE.part" "$ETA_STATE"
    return 0
  done
  return 0
}

# Whether a step is worth a word: twice its estimate and ETA_SLOW_MS over it,
# so a small step that took a moment longer is not a warning and a step that has
# hung is.
eta_slow() { # eta_slow ESTIMATE ELAPSED -> true when the step is the news
  local cur=${1:-0} elapsed=${2:-0}
  [ "$cur" -gt 0 ] || return 1
  [ "$elapsed" -ge $((cur * 2)) ] || return 1
  [ $((elapsed - cur)) -ge "$ETA_SLOW_MS" ]
}

# One line every few seconds until it is killed: the step it is in, how long
# that step has been running, what it usually takes and what is left. A step
# that has outlived its estimate says so, because a run stuck on one step would
# otherwise read as a run with nothing left to do — and a step that has really
# run away says it once, as a warning, rather than looking like a slow tick.
eta_ticker() { # eta_ticker STATE SECONDS
  local state=$1 every=$2 step cur after started rest elapsed left note word
  local last="" warned=""
  while :; do
    sleep "$every"
    [ -s "$state" ] || continue
    IFS=$'\t' read -r step cur after started rest <"$state" || continue
    [ -n "$step" ] || continue
    if [ "$step" != "$last" ]; then
      last=$step
      warned=""
    fi
    elapsed=$(($(date +%s%3N) - started))
    left=$(eta_left "$cur" "$after" "$elapsed")
    note=""
    [ "$cur" -le 0 ] || [ "$elapsed" -le "$cur" ] || note=", over its estimate"
    word=steps
    [ "$rest" = 1 ] && word=step
    if [ -z "$warned" ] && eta_slow "$cur" "$elapsed"; then
      warned=1
      printf 'slow %s %s in, usually %s (%s×, %s over)\n' \
        "$step" "$(eta_fmt "$elapsed")" "$(eta_fmt "$cur")" \
        "$(awk -v e="$elapsed" -v c="$cur" 'BEGIN { printf "%.1f", e / c }')" \
        "$(eta_fmt "$((elapsed - cur))")"
    fi
    printf 'eta %s left  (%s %s in, usually %s%s; %s %s after)\n' \
      "$(eta_fmt "$left")" "$step" "$(eta_fmt "$elapsed")" "$(eta_fmt "$cur")" \
      "$note" "$rest" "$word"
  done
}
