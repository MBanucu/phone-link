#!/usr/bin/env bash
# Hermetic tests for tests/live/results.py: the CSV history made queryable.
# No phone, no run: the files a run leaves are written by the test, and the
# importer is asked the questions the wishlist wanted a database for.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

IMPORT="$ROOT/tests/live/results.py"
RESULTS=$TMP/results
DB=$TMP/results.sqlite3
mkdir -p "$RESULTS"

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

# One question of the database, as a line.
sql() {
  python3 - "$DB" "$1" <<'EOF'
import sqlite3, sys
try:
    row = sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()
except sqlite3.Error as error:
    print(f"error: {error}")
    raise SystemExit(0)
if row is None:
    print("(none)")
else:
    line = "\t".join("" if value is None else str(value) for value in row)
    print(line if line else "(none)")
EOF
}

# A full run, with its steps and its total.
cat >"$RESULTS/timings.csv" <<'EOF'
run,step,seconds,passed,failed,status
20261116T000000Z,unlock,3.0,1,0,ok
20261116T000000Z,panel,12.5,3,0,ok
20261116T000000Z,TOTAL,180.0,7,0,ok
EOF

# A filtered run: its own history file, steps and section name.
cat >"$RESULTS/timings-partial.csv" <<'EOF'
run,step,seconds,passed,failed,status
20261116T010000Z,unlock,4.0,1,0,ok
20261116T010000Z,preamble,5.5,0,0,ok
20261116T010000Z,stop,15.0,4,0,ok
20261116T010000Z,PARTIAL,24.5,5,0,partial
EOF

# The run folders: the full run has settings and checks, the filtered one only
# a checks file (a run from before run.csv existed has to import too).
mkdir -p "$RESULTS/20261116T000000Z" "$RESULTS/20261116T010000Z"
cat >"$RESULTS/20261116T000000Z/run.csv" <<'EOF'
key,value
kind,full
started,2026-11-16T00:00:00Z
device,"XPLO2EEA0001541"
app_build,"0.9.2"
capture,1
ssid,"PhoneLink"
port,18080
EOF
cat >"$RESULTS/20261116T000000Z/checks.csv" <<'EOF'
run,step,verdict,file,line,function,decided_ms,claim
20261116T000000Z,unlock,pass,tests/live/proxy-app.sh,790,step_unlock,1794795267014,"the phone is unlocked"
20261116T000000Z,panel,fail,tests/live/proxy-app.sh,851,step_panel,1794795270195,"the panel opens, ""really"""
EOF
cat >"$RESULTS/20261116T010000Z/checks.csv" <<'EOF'
run,step,verdict,file,line,function,decided_ms,claim
20261116T010000Z,stop,pass,tests/live/proxy-app.sh,1680,step_stop,1794800000000,"the port closes"
EOF

if python3 "$IMPORT" --results "$RESULTS" --db "$DB" >"$TMP/out" 2>"$TMP/err"; then
  ok 'the importer fills a database from the CSVs'
else
  bad 'the importer fills a database from the CSVs' "$(cat "$TMP/err")"
fi
case $(cat "$TMP/out") in
  '2 runs, 5 steps, 3 checks -> '*) ok 'and says how much it read' ;;
  *) bad 'and says how much it read' "$(cat "$TMP/out")" ;;
esac

same "$(sql 'SELECT kind FROM runs WHERE id="20261116T000000Z"')" full \
  'a run named by a TOTAL row is a full run'
same "$(sql 'SELECT kind FROM runs WHERE id="20261116T010000Z"')" filtered \
  'a run in the filtered history is a filtered run'
same "$(sql 'SELECT status FROM runs WHERE id="20261116T010000Z"')" partial \
  'and is never mistaken for a green full run'
same "$(sql 'SELECT seconds,passed,failed FROM runs WHERE id="20261116T000000Z"')" \
  $'180.0\t7\t0' 'a full run keeps its total, passes and failures'
same "$(sql 'SELECT steps_asked FROM runs WHERE id="20261116T010000Z"')" '(none)' \
  'a run from before run.csv has no settings and does not invent them'

same "$(sql 'SELECT app_build,device,capture FROM runs WHERE id="20261116T000000Z"')" \
  $'0.9.2\tXPLO2EEA0001541\t1' 'the settings a run wrote are columns'
same "$(sql 'SELECT json_extract(settings,"$.ssid") FROM runs WHERE id="20261116T000000Z"')" \
  PhoneLink 'and the ones the schema has no column for are kept as JSON'

same "$(sql 'SELECT position,seconds FROM steps WHERE run="20261116T000000Z" AND name="panel"')" \
  $'2\t12.5' 'a step keeps the order the run took it in and what it cost'
same "$(sql 'SELECT count(*) FROM steps WHERE run="20261116T010000Z"')" 3 \
  'a filtered run imports its own steps'

same "$(sql 'SELECT verdict,claim FROM checks WHERE step="panel"')" \
  $'fail\tthe panel opens, "really"' 'a check keeps its verdict and the claim verbatim'
same "$(sql 'SELECT file,line,function FROM checks WHERE step="unlock"')" \
  $'tests/live/proxy-app.sh\t790\tstep_unlock' 'and where it was decided'

# The questions the wishlist named, asked of the database and not of a CSV.
same "$(sql 'SELECT avg(seconds) FROM steps WHERE name="unlock"')" 3.5 \
  'a step cost across runs is one query'
same "$(sql "SELECT count(DISTINCT run) FROM checks WHERE verdict='fail'")" 1 \
  'and so is whether a check has ever failed'

# Re-importing is the same history, not twice the history: an old file can be
# imported again and a schema change costs a re-import.
if python3 "$IMPORT" --results "$RESULTS" --db "$DB" >/dev/null 2>&1; then
  ok 'the importer can run again'
else
  bad 'the importer can run again'
fi
same "$(sql 'SELECT count(*) FROM runs')" 2 'a second import does not double the runs'
same "$(sql 'SELECT count(*) FROM steps')" 5 'or the steps'
same "$(sql 'SELECT count(*) FROM checks')" 3 'or the checks'

# A folder that is a run but has no timing rows: an interrupted run still says
# which steps it reached, in the order its checks did.
mkdir -p "$RESULTS/20261116T020000Z"
cat >"$RESULTS/20261116T020000Z/checks.csv" <<'EOF'
run,step,verdict,file,line,function,decided_ms,claim
20261116T020000Z,unlock,pass,tests/live/proxy-app.sh,790,step_unlock,1794800100000,"the phone is unlocked"
20261116T020000Z,panel,pass,tests/live/proxy-app.sh,851,step_panel,1794800200000,"the panel opens"
EOF
python3 "$IMPORT" --results "$RESULTS" --db "$DB" >/dev/null 2>"$TMP/err"
same "$(sql 'SELECT kind,status FROM runs WHERE id="20261116T020000Z"')" \
  $'unknown\tunknown' 'a run with no total is a run of unknown kind'
same "$(sql 'SELECT group_concat(name, ",") FROM (SELECT name FROM steps WHERE run="20261116T020000Z" ORDER BY position)')" \
  'unlock,panel' 'and its checks still say which steps it reached'
case $(cat "$TMP/err") in
  *'no run.csv'*) ok 'the importer says which run left no settings' ;;
  *) bad 'the importer says which run left no settings' "$(cat "$TMP/err")" ;;
esac

# A database path of its own is honoured, and a results folder that does not
# exist is a refusal rather than an empty database.
python3 "$IMPORT" --results "$RESULTS" --db "$TMP/other.sqlite3" >/dev/null 2>&1
same "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from runs").fetchone()[0])' "$TMP/other.sqlite3")" \
  3 'a named database is where the rows go'
if python3 "$IMPORT" --results "$TMP/nowhere" --db "$TMP/none.sqlite3" >/dev/null 2>&1; then
  bad 'a results folder that does not exist is refused'
else
  ok 'a results folder that does not exist is refused'
fi

# A PARTIAL row in the full history is a filtered run from before filtered runs
# had a file of their own; it must not be read as a full one.
mkdir -p "$TMP/legacy"
cat >"$TMP/legacy/timings.csv" <<'EOF'
run,step,seconds,passed,failed,status
20261115T230000Z,stop,9.0,1,0,ok
20261115T230000Z,PARTIAL,9.5,1,0,partial
EOF
python3 "$IMPORT" --results "$TMP/legacy" --db "$TMP/legacy.sqlite3" >/dev/null 2>&1
same "$(python3 -c 'import sqlite3,sys; print(" ".join(sqlite3.connect(sys.argv[1]).execute("select kind,status from runs").fetchone()))' "$TMP/legacy.sqlite3")" \
  'filtered partial' 'a PARTIAL row in the full history is still a filtered run'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
