#!/usr/bin/env bash
# Module: design
# Verifies that the design documents satisfy every assertion in
# scripts/check_design.py, and that the repository version field is valid.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root"

for check in partitions esp-data-only overlay-layers generation-model gc-policy \
             log-ring conflict-model payload-contract links text; do
  out=$(python3 scripts/check_design.py "$check" 2>&1)
  code=$?
  assert_eq "$code" "0" "design check: $check"
  if [[ $code -ne 0 ]]; then
    printf '%s\n' "$out" >&2
  fi
done

assert_file_exists "$root/VERSION" "VERSION file exists"
version=$(tr -d '[:space:]' <"$root/VERSION")
assert_matches "$version" '^0\.[0-9]+\.[0-9]+$' "VERSION stays on major zero"
assert_contains "$(cat "$root/README.md")" "0.0.0" "README states the current version"

finish
