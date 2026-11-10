#!/usr/bin/env bash
# Module: design
# Verifies the workflow-expression guard in scripts/check_design.py: the `runner` context
# is legal inside a step and illegal everywhere else, and getting that wrong makes a
# whole workflow undispatchable.
#
#   ac-5 the guard accepts every valid step-level placement of the runner context
#   ac-5 and rejects the workflow-level and job-level ones, which is the defect it exists
#        for: ci-debug.yml shipped with a workflow-level runner.temp and could not be run
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The guard is a pure function of the workflow text, so the cases are written out here
# instead of being injected into a copy of the real file.
guard() { # <yaml on stdin> -> problem count, then the flagged line numbers
  cat >"$tmp/case.yml"
  python3 - "$tmp/case.yml" <<'PY'
import sys

sys.path.insert(0, "scripts")
import check_design

problems = check_design._runner_context_problems(open(sys.argv[1], encoding="utf-8").read())
print(len(problems))
for number, _ in problems:
    print(number)
PY
}

# --------------------------------------------------------------------------- #
# ac-5: valid placements are accepted
# --------------------------------------------------------------------------- #

valid=$(cat <<'YAML'
env:
  CI_PLATFORM_VERSION: "0.0.2"
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      JOB_LEVEL: literal
    steps:
      - name: Step with a condition
        if: ${{ runner.os == 'Linux' }}
        run: echo hi
      - name: Step with an inline expression
        run: echo ${{ runner.temp }}
        env:
          SCRATCH: ${{ runner.temp }}/ci
YAML
)
assert_eq "$(printf '%s\n' "$valid" | guard)" "0" \
  "ac-5 a runner context inside a step is accepted"
assert_eq "$(printf '%s\n' "$valid" | guard | wc -l | tr -d ' ')" "1" \
  "ac-5 and nothing is reported for the whole file"

# --------------------------------------------------------------------------- #
# ac-5: the placements GitHub rejects are reported, with their line numbers
# --------------------------------------------------------------------------- #

invalid=$(cat <<'YAML'
env:
  WORKFLOW_LEVEL: ${{ runner.temp }}/ci
jobs:
  build:
    env:
      JOB_LEVEL: ${{ runner.temp }}/ci
    steps:
      - name: fine
        run: echo ok
YAML
)
assert_eq "$(printf '%s\n' "$invalid" | guard)" "2
2
6" "ac-5 workflow-level and job-level runner contexts are both reported"

# The bracket form and a comment that merely mentions the context have to be told apart:
# one is the same defect spelled differently, the other is documentation.
bracket=$(cat <<'YAML'
env:
  SCRATCH: ${{ runner['temp'] }}
YAML
)
assert_eq "$(printf '%s\n' "$bracket" | guard)" "1
2" "ac-5 the bracket form of the runner context is reported too"

comment=$(cat <<'YAML'
# a workflow-level runner.temp is a parse error
env:
  CI_PLATFORM_VERSION: "0.0.2"
YAML
)
assert_eq "$(printf '%s\n' "$comment" | guard)" "0" \
  "ac-5 a comment that mentions the runner context is not a problem"

# --------------------------------------------------------------------------- #
# ac-5: the real workflows are clean, and the check is wired into the suite
# --------------------------------------------------------------------------- #

assert_command_ok "ac-5 every workflow in the repository passes the guard" \
  python3 scripts/check_design.py workflow-expressions
assert_contains "$(python3 scripts/check_design.py no-such-check 2>&1 || true)" "workflow-expressions" \
  "ac-5 the check is registered under its own name"

finish
