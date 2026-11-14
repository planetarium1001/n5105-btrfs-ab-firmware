#!/usr/bin/env bash
# Module: ci
# Guards that a stage gate can actually fail its step.
#
# Every stage step that runs a script pipes it into tee:
#
#   run: bash scripts/ci/image-verify.sh 2>&1 | tee -a "${CI_LOG_DIR}/image-verify.log"
#
# The default Linux shell for a `run:` step is `bash -e {0}`, with no pipefail, so that
# pipeline reports tee's status and the gate reports success no matter what the script
# said. Measured on run 43553833091: image-verify refused the image, the step stayed green,
# its `expect_file` output was never written, and the failure surfaced one step later as
# `[qemu] ERROR: initramfs not found`.
#
#   ac-1  a workflow that pipes anything into tee declares `defaults.run.shell: bash`,
#         which GitHub expands to `bash --noprofile --norc -eo pipefail {0}`
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

# gate_defaults <workflow>: 0 when the file declares, at the workflow root,
#   defaults:
#     run:
#       shell: bash
# The three lines are what carries pipefail; a step-local `set -o pipefail` would also do
# for one step, but the rule is per file so a new tee step cannot be added without it.
gate_defaults() {
  awk '
    /^defaults: *\{run: *\{shell: *bash\}\}/ { ok = 1 }
    /^defaults:$/ {
      getline
      if ($0 != "  run:") next
      getline
      if ($0 == "    shell: bash") ok = 1
    }
    END { exit ok ? 0 : 1 }
  ' "$1"
}

checked=0
for file in .github/workflows/*.yml; do
  grep -qF '| tee' "$file" || continue
  checked=$((checked + 1))
  name="$(basename "$file")"
  if gate_defaults "$file"; then
    assert_eq "pipefail" "pipefail" "ac-1 ${name} lets a piped gate fail its step"
  else
    assert_eq "no-pipefail-defaults" "pipefail" "ac-1 ${name} lets a piped gate fail its step"
  fi
done

# A rule that checks nothing passes forever: the two stages that lost this the loudest
# must be in the set, and the set has to stay wide (12 stage workflows and four others).
assert_eq "$([ "$checked" -ge 10 ] && echo wide)" "wide" \
  "ac-1 the rule has real files to check (${checked} workflows pipe into tee)"
assert_eq "$(grep -lF '| tee' .github/workflows/ci-s1.yml .github/workflows/ci-s2.yml 2>/dev/null | wc -l | tr -d ' ')" \
  "2" "ac-1 the two image stages are in the checked set"

# The shape itself: no workflow may rely on the runner's default shell, and the step that
# lost its failure must still pipe the script (the log is the evidence a red step leaves).
assert_contains "$(cat .github/workflows/ci-s2.yml)" 'bash scripts/ci/image-verify.sh 2>&1' \
  "ac-1 the image check still leaves its log through tee"
assert_contains "$(cat .github/workflows/ci-s2.yml)" 'shell: bash' \
  "ac-1 ci-s2 declares the pipefail shell"

finish
