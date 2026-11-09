#!/usr/bin/env bash
# Module: ci
# Verifies the pipeline skeleton: single entry point, reusable stages at the
# workflows top level, hashed cache keys, always-on diagnostics, and a local
# static verification path.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root"

WORKFLOWS="$root/.github/workflows"
CI_SCRIPTS="$root/scripts/ci"

# ac-1 single entry point with a stage selector
entry=$(cat "$WORKFLOWS/ci.yml")
assert_contains "$entry" "workflow_dispatch" "entry exposes workflow_dispatch"
assert_contains "$entry" "stage:" "entry declares a stage input"
for stage in all fetch assemble verify; do
  assert_contains "$entry" "          - $stage" "stage option present: $stage"
done

# ac-2 reusable workflows live at the top level and all targets resolve
subdirs=$(find "$WORKFLOWS" -mindepth 1 -type d | wc -l | tr -d ' ')
assert_eq "$subdirs" "0" "no subdirectories under .github/workflows"
targets=$(grep -h "uses: \./" "$WORKFLOWS"/*.yml | sed 's/.*uses: \.\///' | sort -u)
assert_eq "$(printf '%s\n' "$targets" | wc -l | tr -d ' ')" "5" "five reusable workflows are referenced"
while read -r target; do
  [[ -z "$target" ]] && continue
  assert_file_exists "$root/$target" "uses target exists: $target"
done <<<"$targets"
calls=$(grep -l "^  workflow_call:" "$WORKFLOWS"/ci-*.yml | wc -l | tr -d ' ')
assert_eq "$calls" "5" "every stage workflow is callable"

# ac-3 cache key covers upstream version and tool/script digests
assert_contains "$(cat "$CI_SCRIPTS/lib.sh")" "CI_TOOLS_VERSION" "tool epoch participates in the key"
assert_contains "$(cat "$CI_SCRIPTS/resolve.sh")" "sha256" "script digests participate in the key"

# ac-4 diagnostics are uploaded even when a stage fails
always=$(grep -c "if: always()" "$WORKFLOWS"/ci-*.yml | awk -F: '{s+=$2} END {print s}')
assert_eq "$always" "10" "each of the five stages uploads diagnostics unconditionally"

# ac-5 verify stage runs the design checks, syntax check and shellcheck
verify=$(cat "$CI_SCRIPTS/verify.sh")
assert_contains "$verify" "check_design.py" "verify runs the design checks"
assert_contains "$verify" "bash -n" "verify runs a syntax check"
assert_contains "$verify" "shellcheck" "verify runs shellcheck"

# ac-6 assemble never fabricates missing members
assert_contains "$(cat "$CI_SCRIPTS/assemble.sh")" "missing_members" "assemble records missing members"

# local static verification
for script in "$CI_SCRIPTS"/*.sh "$root/tests/run.sh"; do
  assert_command_ok "bash -n $(basename "$script")" bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  for script in "$CI_SCRIPTS"/*.sh; do
    assert_command_ok "shellcheck $(basename "$script")" shellcheck --severity=error "$script"
  done
else
  printf '# shellcheck unavailable, skipped\n'
fi

finish
