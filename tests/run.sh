#!/usr/bin/env bash
# Runs the scenarios under tests/cases/, each in a sandboxed $HOME of its own
# (see lib.sh), as many at a time as there are cores, and prints their output in
# name order as they finish. `bash tests/run.sh rm cp` runs just those; JOBS=1
# runs them one after another.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# One scenario, in a process of its own: an abort anywhere in it (an unbound
# variable, say) ends that process alone, and shows up as a missing count.
if [[ "${1:-}" == --case ]]; then
  ( . "$HERE/lib.sh"; . "$HERE/cases/$2"; echo "$PASS $FAIL $SECONDS" > "$OUT/$2.counts" ) \
    > "$OUT/$2.log" 2>&1
  : > "$OUT/$2.done"
  exit 0
fi

JOBS=${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}
OUT=$(mktemp -d); export OUT
cd "$HERE/cases"
if [[ $# -gt 0 ]]; then cases=$(for c; do echo "$c.sh"; done); else cases=$(ls *.sh); fi
for c in $cases; do [[ -f "$c" ]] || { echo "no such case: ${c%.sh}" >&2; exit 2; }; done

# Biggest first, so the longest scenarios are not what is left running alone at
# the end. Output still comes out in name order.
ls -S $cases | xargs -P "$JOBS" -n 1 bash "$HERE/run.sh" --case &

# A one-second poll: every sleep is a process, and on Git Bash a process is
# what the whole run is paying for.
PASS=0; FAIL=0; times=
for c in $cases; do
  until [[ -e "$OUT/$c.done" ]]; do sleep 1; done
  cat "$OUT/$c.log"
  if [[ -f "$OUT/$c.counts" ]]; then
    read -r p f s < "$OUT/$c.counts"
    PASS=$((PASS+p)); FAIL=$((FAIL+f)); times="$times$s ${c%.sh}"$'\n'
  else
    FAIL=$((FAIL+1)); printf '  FAIL  %s aborted before it finished\n' "${c%.sh}"
  fi
done
wait
rm -rf "$OUT"

echo
echo "passed: $PASS  failed: $FAIL"
# Which scenarios bound the run, for the Git Bash job above all.
printf '%s' "$times" | sort -rn | head -3 | awk '{printf "%s%s %ss", (NR>1 ? ", " : "slowest: "), $2, $1} END {print ""}'
[[ $FAIL -eq 0 ]]
