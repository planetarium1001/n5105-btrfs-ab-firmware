#!/usr/bin/env bash
# Module: ci
# Guards what a user reads on the GitHub run page: the workflow / job / step names, the
# frozen judge tokens behind them, the artifact vocabulary and the merged log uploads.
#
# These are display semantics, so the assertions are static: they never boot anything.
# They exist because a rename is easy to half-do, and a half-renamed pipeline still runs
# - it just stops being readable, or silently stops uploading the log a failure needs.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

WF="$root/.github/workflows"

# --------------------------------------------------------------------------- #
# ac-1: the three entry points say what they are
# --------------------------------------------------------------------------- #

assert_contains "$(cat "$WF/ci.yml")" "name: Firmware CI - build and validate" \
  "ac-1 the validation entry point is named"
assert_contains "$(cat "$WF/release.yml")" "name: Firmware CI - release" \
  "ac-1 the release entry point is named"
assert_contains "$(cat "$WF/ci-debug.yml")" "name: Firmware CI - debug session" \
  "ac-1 the manual debugging entry point is named"

# --------------------------------------------------------------------------- #
# ac-2: one vocabulary for the five stages, and no second spelling for a stage
# --------------------------------------------------------------------------- #

stages=(1 2 3 4 5)
sems=(probe image boot slots upgrade)
details=(
  "kernel mounts btrfs"
  "four partitions"
  "layered root"
  "A/B state machine"
  "upgrade and reclaim"
)

for idx in 0 1 2 3 4; do
  num=${stages[$idx]}
  sem=${sems[$idx]}
  detail=${details[$idx]}
  job="S${num} ${sem} - ${detail}"
  workflow="$WF/ci-s${num}.yml"
  assert_file_exists "$workflow" "ac-2 stage workflow exists: ci-s${num}.yml"
  assert_contains "$(head -n 1 "$workflow")" "name: S${num} ${sem}" \
    "ac-2 ci-s${num}.yml is named S${num} ${sem}"
  assert_contains "$(cat "$workflow")" "    name: ${job}" \
    "ac-2 the ci-s${num} job carries the same label"
  assert_contains "$(cat "$WF/ci.yml")" "    name: ${job}" \
    "ac-2 the graph node in ci.yml carries the same label"
done

# A stage label must appear exactly once as a job label in the whole pipeline, otherwise
# the report's duration join key (`S<n> `) is ambiguous. The workflow-level label of the
# stage file itself is counted separately, because GitHub shows both.
for num in 1 2 3 4 5; do
  job_hits=0
  workflow_hits=0
  for workflow in "$WF"/*.yml; do
    count=$(grep -cE "^    name: S${num} " "$workflow" 2>/dev/null || true)
    job_hits=$((job_hits + ${count:-0}))
    count=$(grep -cE "^name: S${num} " "$workflow" 2>/dev/null || true)
    workflow_hits=$((workflow_hits + ${count:-0}))
  done
  # Two labels on purpose: the graph node in ci.yml and the inner job of the stage file.
  assert_eq "${job_hits}" "2" "ac-2 S${num} is the same label in ci.yml and its stage file"
  assert_eq "${workflow_hits}" "1" "ac-2 S${num} is exactly one stage workflow"
done

# --------------------------------------------------------------------------- #
# ac-2: the separator vocabulary - one " - ", no parentheses, no colons, no middots
# --------------------------------------------------------------------------- #

for workflow in "$WF"/*.yml; do
  offenders=$(grep -nE '^[[:space:]]*(- )?name: .*(\(|\)|·)' "$workflow" 2>/dev/null || true)
  assert_eq "${offenders}" "" "ac-2 $(basename "$workflow") uses no parentheses or middots in names"
  offenders=$(grep -nE '^[[:space:]]*- name: .*: ' "$workflow" 2>/dev/null || true)
  assert_eq "${offenders}" "" "ac-2 $(basename "$workflow") uses no colon inside a step name"
done

# --------------------------------------------------------------------------- #
# ac-3: every stage ends with the same summary block
# --------------------------------------------------------------------------- #

for num in 1 2 3 4 5; do
  workflow="$WF/ci-s${num}.yml"
  text="$(cat "$workflow")"
  assert_contains "$text" "      - name: Write stage summary" \
    "ac-3 ci-s${num}.yml writes the stage summary"
  assert_contains "$text" "bash scripts/ci/stage-summary.sh" \
    "ac-3 ci-s${num}.yml uses the shared renderer"
  assert_contains "$text" "--stage s${num}" \
    "ac-3 ci-s${num}.yml passes its own stage"
done

# --------------------------------------------------------------------------- #
# ac-9: the judge tokens are frozen; only the display names moved
# --------------------------------------------------------------------------- #

assert_contains "$(cat "$root/initramfs/init")" 'S1-RESULT=ok kernel=${VERMAGIC}' \
  "ac-9 the S1 judge line is unchanged"
assert_contains "$(cat "$root/tests/modules/image/guest-assert.sh")" 'S2-RESULT=ok parts=${found}' \
  "ac-9 the S2 judge line is unchanged"
assert_contains "$(cat "$root/initramfs/boot/post.sh")" "S3-RESULT=ok slot=%s" \
  "ac-9 the S3 judge line is unchanged"
assert_contains "$(cat "$root/scripts/ci/ab-phase.sh")" "S4-RESULT=ok phase=%s" \
  "ac-9 the S4 judge line is unchanged"
assert_contains "$(cat "$root/scripts/ci/s5-phase.sh")" "S5-RESULT=ok upgrade=%s" \
  "ac-9 the S5 judge line is unchanged"

unknown_prefixes="$(grep -rn "S[6-9]-RESULT" "$WF" "$root/scripts/ci" 2>/dev/null || true)"
assert_eq "${unknown_prefixes}" "" "ac-9 no sixth stage prefix appeared"

# --------------------------------------------------------------------------- #
# ac-10 / ac-12: one artifact vocabulary, one copy of each log
# --------------------------------------------------------------------------- #

report=$(python3 - "$root" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
workflows = sorted((root / ".github" / "workflows").glob("*.yml"))
allowed = {
    "upstream-files",
    "payload-upgrade",
    "image-probe",
    "image-install",
    "debug-session",
}
problems = []

targets = workflows + sorted((root / ".github" / "actions").glob("*/action.yml"))
for path in targets:
    # stage-evidence derives its names from its inputs; the call sites are checked below.
    if path.parent.name == "stage-evidence":
        continue
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        if "uses: actions/upload-artifact" not in line:
            continue
        name = ""
        for follow in lines[index + 1:]:
            if re.match(r"^\s*- name:", follow):
                break
            match = re.match(r"^\s+name:\s*(.+?)\s*$", follow)
            if match:
                name = match.group(1)
                break
        if not name:
            problems.append(f"{path.name}: upload without a name")
            continue
        # A name built from an expression (debug-${{ inputs.stage }}-logs) is compared on
        # its literal prefix, which is the part a reader sees in the artifact list.
        name = re.sub(r"\$\{\{.*?\}\}", "stage", name)
        if name in allowed:
            continue
        if re.fullmatch(r"evidence-s[1-5]", name):
            continue
        if re.fullmatch(r"logs-[a-z0-9]+", name):
            continue
        if re.fullmatch(r"debug-[a-z0-9-]+", name):
            continue
        problems.append(f"{path.name}: unexpected artifact name {name!r}")

# The serial console log is the one file every failure needs; it must be uploaded exactly
# once per stage, through the logs artifact, and never copied into a second artifact.
#
# Since task 20261112-03 the upload itself lives in .github/actions/stage-evidence: the
# workflow only names the stage and the paths, and the composite derives logs-<stage>.
# The invariants therefore split in two - what the call site asks for, and what the
# composite does with it - and both halves are asserted here.
composite = (root / ".github" / "actions" / "stage-evidence" / "action.yml").read_text(
    encoding="utf-8"
)
for num in range(1, 6):
    text = (root / ".github" / "workflows" / f"ci-s{num}.yml").read_text(encoding="utf-8")
    call = re.search(
        r"uses: \./\.github/actions/stage-evidence\n\s+with:\n((?:\s{10,}\S.*\n|\s*\n)*)",
        text,
    )
    if not call:
        problems.append(f"ci-s{num}.yml: no stage-evidence call")
        continue
    block = call.group(1)
    # Exact match: a rename to evidence-s2x must not pass as evidence-s2.
    if not re.search(rf"^\s+name: evidence-s{num}\s*$", block, re.M):
        problems.append(f"ci-s{num}.yml: does not name evidence-s{num}")
    if f"stage: s{num}" not in block:
        problems.append(f"ci-s{num}.yml: the stage-evidence stage is not s{num}")
    # The stage logs - serial copies included - travel with the evidence, once.
    if "ci/logs" not in block:
        problems.append(f"ci-s{num}.yml: evidence-s{num} does not carry the stage logs")
    if "serial-" in block:
        problems.append(f"ci-s{num}.yml: evidence-s{num} uploads a second copy of a serial log")
    if "logs-name:" in block:
        problems.append(f"ci-s{num}.yml: overrides the derived logs artifact name")
    if "logs-paths:" in block:
        problems.append(f"ci-s{num}.yml: overrides the diagnostics artifact path")

for needle, message in (
    ("name: ${{ inputs.name }}", "the evidence artifact is named by the caller"),
    ("path: ${{ inputs.paths }}", "the evidence artifact carries the caller's paths"),
    ("format('logs-{0}', inputs.stage)", "the diagnostics artifact is named logs-<stage>"),
    (
        "format('{0}/ci/diagnostics/summary.txt', runner.temp)",
        "the diagnostics artifact carries only the diagnostics summary",
    ),
):
    if needle not in composite:
        problems.append(f"stage-evidence: {message}")

release = (root / ".github" / "workflows" / "release-publish.yml").read_text(encoding="utf-8")
for needle in ("default: image-install", "default: payload-upgrade"):
    if needle not in release:
        problems.append(f"release-publish.yml: missing download of {needle!r}")

print("\n".join(problems))
PY
)
assert_eq "${report}" "" "ac-10 the artifacts and the log uploads follow the vocabulary"

# --------------------------------------------------------------------------- #
# ac-7 / ac-8: the release screen and the release notes line
# --------------------------------------------------------------------------- #

# Publishing lives in the reusable workflow now; release.yml only builds and calls it.
rel_text="$(cat "$WF/release.yml")"
assert_contains "$rel_text" "    name: verify pipeline - S1 to S5" \
  "ac-7 the release build job is named"
pub_text="$(cat "$WF/release-publish.yml")"
assert_contains "$pub_text" "      - name: Write the pre-publish summary" \
  "ac-7 the release summarises what it is about to publish"
assert_contains "$pub_text" "SHA256SUMS" "ac-7 the pre-publish summary reads the digests"
assert_contains "$pub_text" 'echo "kind=${kind}" >>"${GITHUB_OUTPUT}"' \
  "ac-7 the image kind check is published as an output"
assert_contains "$pub_text" "Verified by CI run" "ac-8 the release notes name the run that proved it"

# --------------------------------------------------------------------------- #
# ac-11: the stage map a reader lands on first
# --------------------------------------------------------------------------- #

readme="$(cat "$root/scripts/ci/README.md")"
assert_contains "$readme" "## Stage map" "ac-11 the stage map exists"
assert_contains "$readme" "What it proves" "ac-11 the stage map says what a stage proves"
assert_contains "$readme" "What breaks when it fails" "ac-11 the stage map says what a failure costs"
for num in 1 2 3 4 5; do
  assert_contains "$readme" "| S${num} |" "ac-11 the stage map has a row for S${num}"
done
assert_contains "$readme" "stage-summary.sh" "ac-11 the renderer is listed"

finish
