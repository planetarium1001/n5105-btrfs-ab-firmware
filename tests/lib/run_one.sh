#!/usr/bin/env bash
# Helper that runs a single test in its own process and records the exit code.
# Called by tests/run.sh; not meant to be executed directly.
set -uo pipefail

test_file=${1:?test file required}
out_dir=${2:?output dir required}
root=${3:?repo root required}

rel=${test_file#"$root"/}
name=${rel#tests/modules/}
name=${name//\//__}
name=${name%.sh}

bash "$test_file" >"$out_dir/$name.log" 2>&1
code=$?

printf '%s %s\n' "$code" "$name" >>"$out_dir/results"
exit 0
