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
stages=$(find "$WORKFLOWS" -maxdepth 1 -name 'ci-*.yml' ! -name 'ci-debug.yml' | wc -l | tr -d ' ')
targets=$(grep -h "uses: \./" "$WORKFLOWS"/*.yml | sed 's/.*uses: \.\///' | grep '/ci-' | sort -u)
# ci.yml is the entry and release.yml is the tag-triggered publisher; both call the
# reusable stage workflows and are not stages themselves, so they must not be counted.
assert_eq "$(printf '%s\n' "$targets" | wc -l | tr -d ' ')" "$stages" "every stage workflow is referenced"
for entry in ci.yml release.yml; do
  assert_file_exists "$root/.github/workflows/${entry}" "root workflow exists: ${entry}"
done
while read -r target; do
  [[ -z "$target" ]] && continue
  assert_file_exists "$root/$target" "uses target exists: $target"
done <<<"$targets"
calls=$(grep -l "^  workflow_call:" "$WORKFLOWS"/ci-*.yml | wc -l | tr -d ' ')
assert_eq "$calls" "$stages" "every stage workflow is callable"

# ac-3 cache key covers upstream version and tool/script digests
assert_contains "$(cat "$CI_SCRIPTS/lib.sh")" "CI_TOOLS_VERSION" "tool epoch participates in the key"
assert_contains "$(cat "$CI_SCRIPTS/resolve.sh")" "sha256" "script digests participate in the key"

# ac-4 diagnostics are uploaded even when a stage fails
# ci-debug.yml is a manual debugging entry point, not a stage: its only upload is the
# short-lived debug-<stage>-logs diagnostics artifact, it renders no verdict, and it is
# excluded from the stage counts above for that reason.
for workflow in "$WORKFLOWS"/ci-*.yml; do
  [[ $(basename "$workflow") == ci-debug.yml ]] && continue
  count=$(grep -c "if: always()" "$workflow")
  [[ $count -ge 2 ]] && result=ok || result=thin
  assert_eq "$result" "ok" "$(basename "$workflow") collects and uploads diagnostics unconditionally"
done

# ac-5 verify stage runs the design checks, syntax check and shellcheck
verify=$(cat "$CI_SCRIPTS/verify.sh")
assert_contains "$verify" "check_design.py" "verify runs the design checks"
assert_contains "$verify" "bash -n" "verify runs a syntax check"
assert_contains "$verify" "shellcheck" "verify runs shellcheck"

# ac-6 assemble builds a complete payload and validates it with the product checker;
# a member it cannot produce is a build failure, never a manifest entry that admits it
assemble_script="$(cat "$CI_SCRIPTS/assemble.sh")"
assert_contains "$assemble_script" "ab-upgrade" "assemble validates with ab-upgrade"
assert_contains "$assemble_script" "--check" "assemble validates in check mode"
assert_contains "$assemble_script" "platform.tar" "assemble ships the platform layer"
assert_contains "$assemble_script" "initramfs.cpio.gz" "assemble ships the boot initramfs"
assert_eq "$(printf '%s' "${assemble_script}" | grep -c 'missing_members')" "0" \
  "assemble no longer publishes a payload with missing members"

# the initramfs builder takes every program from the locked upstream packages, and a
# glibc interpreter that slips back in is a build failure
assert_contains "$(cat "$CI_SCRIPTS/initramfs.sh")" 'initramfs-tools.sh" --toolset "${toolset}"' \
  "builder stages the locked toolset instead of copying host binaries"
assert_contains "$(cat "$CI_SCRIPTS/initramfs.sh")" 'glibc artifact in the initramfs' \
  "builder fails when a glibc artifact reaches the initramfs"

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
