#!/usr/bin/env bash
# Test runner.
#
# Discovers tests/modules/<module>/test_*.sh and runs them concurrently.
# Each test is an independent process: exit 0 means pass, non-zero means fail.
# Output of every test is captured to tests/.out/<module>__<name>.log.
#
# Usage:
#   ./tests/run.sh                 # all modules, default parallelism
#   ./tests/run.sh --jobs 8        # explicit parallelism
#   ./tests/run.sh --module design # one module
#   ./tests/run.sh --list          # list discovered tests
#   ./tests/run.sh --verbose       # echo test output on failure
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULES_DIR="$ROOT/tests/modules"
OUT_DIR="$ROOT/tests/.out"

JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
MODULE_FILTER=""
LIST_ONLY=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) JOBS=${2:?--jobs needs a value}; shift 2 ;;
    --module) MODULE_FILTER=${2:?--module needs a value}; shift 2 ;;
    --list) LIST_ONLY=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mapfile -t TESTS < <(find "$MODULES_DIR" -mindepth 2 -maxdepth 2 -name 'test_*.sh' | sort)
if [[ -n "$MODULE_FILTER" ]]; then
  mapfile -t TESTS < <(printf '%s\n' "${TESTS[@]}" | grep "/${MODULE_FILTER}/" || true)
fi

if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "no tests found" >&2
  exit 1
fi

if [[ $LIST_ONLY -eq 1 ]]; then
  printf '%s\n' "${TESTS[@]}"
  exit 0
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

start=$(date +%s)
printf '%s\n' "${TESTS[@]}" \
  | xargs -P "$JOBS" -I{} bash "$ROOT/tests/lib/run_one.sh" {} "$OUT_DIR" "$ROOT"
elapsed=$(( $(date +%s) - start ))

pass=0
fail=0
failed_names=()
while read -r code name; do
  if [[ "$code" == "0" ]]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    failed_names+=("$name")
    printf 'FAIL %s (exit %s)\n' "$name" "$code"
  fi
done < <(sort -k2 "$OUT_DIR/results")

echo
echo "passed: $pass  failed: $fail  jobs: $JOBS  elapsed: ${elapsed}s"

if [[ $fail -gt 0 ]]; then
  echo "logs: $OUT_DIR"
  if [[ $VERBOSE -eq 1 ]]; then
    for name in "${failed_names[@]}"; do
      echo "--- $name ---"
      cat "$OUT_DIR/${name}.log" || true
    done
  fi
  exit 1
fi
