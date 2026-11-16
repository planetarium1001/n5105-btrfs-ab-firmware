#!/usr/bin/env bash
# Module: ci
# ac-6: the publishing half of a release is one reusable workflow both release lines call.
#
# Why this file exists: the publish job used to live inside release.yml, which meant the
# upstream auto-release line (task 20261112-02) would have had to grow a second copy of
# "what publishing means" — image kind check, payload, SHA256SUMS, notes, summary — and the
# two copies would drift. release-publish.yml is that job, extracted; release.yml and
# upstream-watch.yml are two callers of it.
#
# The assertions below are structural on purpose: a reusable workflow's inputs are the
# contract with its callers, and a publish step that runs before the preflight is exactly
# the failure this task exists to prevent.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

publish=".github/workflows/release-publish.yml"
release=".github/workflows/release.yml"

assert_file_exists "$publish" "ac-6 the reusable publish workflow exists"
assert_file_exists "$release" "ac-6 the tagged release line still exists"

publish_text=$(cat "$publish")
release_text=$(cat "$release")

# --------------------------------------------------------------------------- #
# ac-6: the reusable workflow is callable and declares its contract
# --------------------------------------------------------------------------- #

assert_contains "$publish_text" "on:
  workflow_call:" "ac-6 release-publish.yml is a reusable workflow"

# input_decl <name> <file>: the whole `name:` line of one workflow_call input.
input_line() {
  awk -v want="$2" '
    /^    inputs:$/ { ininputs = 1; next }
    ininputs && /^    [a-z-]+:$/ { ininputs = 0 }
    ininputs && $1 == want ":" { print; got = 1; exit }
    END { exit(got ? 0 : 1) }
  ' "$1"
}

for input in tag tag-policy title platform_version upstream_version image-artifact payload-artifact extra-notes dry-run; do
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if input_line "$publish" "$input" >/dev/null; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-6 release-publish.yml declares the input $input"
  else
    _assert_fail "ac-6 release-publish.yml declares the input $input" "not found under workflow_call.inputs"
  fi
done

# The tag is the caller's decision, so it has to be required: a release published under an
# empty tag is a release nobody can find.
assert_contains "$(sed -n '/^      tag:$/,/^        type:/p' "$publish")" "required: true" \
  "ac-6 the tag input is required"

# dry-run defaults to false: a rehearsal is opt-in, publishing is the default.
assert_contains "$(sed -n '/^      dry-run:$/,/^permissions:/p' "$publish")" "default: false" \
  "ac-6 dry-run defaults to false"

# --------------------------------------------------------------------------- #
# ac-6: publishing keeps the least privilege it needs
# --------------------------------------------------------------------------- #

assert_contains "$publish_text" "permissions:
  contents: read" "ac-6 the reusable workflow asks for contents: read by default"
write_blocks=$(grep -c 'contents: write' "$publish")
assert_eq "$write_blocks" "1" "ac-6 exactly one step of the reusable workflow may write contents"

# --------------------------------------------------------------------------- #
# ac-6: the preflight runs before anything is created
# --------------------------------------------------------------------------- #

preflight_line=$(grep -n 'bash scripts/ci/release-preflight.sh' "$publish" | head -n 1 | cut -d: -f1)
create_line=$(grep -n 'gh release create' "$publish" | head -n 1 | cut -d: -f1)
_ASSERT_COUNT=$((_ASSERT_COUNT + 1))
if [ -n "$preflight_line" ] && [ -n "$create_line" ] && [ "$preflight_line" -lt "$create_line" ]; then
  printf 'ok %d - %s\n' "$_ASSERT_COUNT" \
    "ac-6 the release preflight runs before the release is created (line $preflight_line < $create_line)"
else
  _assert_fail "ac-6 the release preflight runs before the release is created" \
    "preflight=[$preflight_line] create=[$create_line]"
fi

# The exit status of the preflight has to reach the step: `| tee` without pipefail would
# swallow it, and a refused release would then be published.
step_block() {
  awk -v want="$2" '
    /^      - / { if (found) exit; block = $0 "\n"; next }
    { block = block $0 "\n" }
    index($0, want) { found = 1 }
    END { if (found) printf "%s", block }
  ' "$1"
}
preflight_step=$(step_block "$publish" 'bash scripts/ci/release-preflight.sh')
assert_contains "$preflight_step" "set -euo pipefail" \
  "ac-6 the preflight step fails the job when the preflight fails"
assert_contains "$preflight_step" "tee -a" \
  "ac-6 the preflight verdict reaches the stage log"

# --------------------------------------------------------------------------- #
# ac-6: the image defence-in-depth check came along
# --------------------------------------------------------------------------- #

for needle in 'kind' 'S3 boot init' 'S1-RESULT' 'publish.img'; do
  assert_contains "$publish_text" "$needle" "ac-6 the reusable publish keeps the image check ($needle)"
done
assert_contains "$publish_text" 'image-install' "ac-6 the install image artifact keeps its name"
assert_contains "$publish_text" 'payload-upgrade' "ac-6 the payload artifact keeps its name"
assert_contains "$publish_text" 'gh release upload "${TAG}"' "ac-6 re-publishing an existing tag uploads again"
assert_contains "$publish_text" '--clobber' "ac-6 re-publishing overwrites instead of failing"

# --------------------------------------------------------------------------- #
# ac-1: a re-run over a draft publishes it, and a published release stays alone
# --------------------------------------------------------------------------- #

# Uploading the bytes again is not publishing. The v0.0.8 pre-review found the branch that
# only does `gh release upload --clobber`: a release left as a draft stays invisible while
# the run reports success, which is the one failure mode nobody notices in time.
publish_step=$(step_block "$publish" 'id: publish')
assert_contains "$publish_step" 'gh release edit "${TAG}" --draft=false' \
  "ac-1 re-running over a draft publishes the release"
assert_contains "$publish_step" '--json isDraft --jq .isDraft' \
  "ac-1 the draft state is read before it is changed"

# Idempotent in the other direction: a published release is never deleted and recreated, so
# a second automatic run cannot withdraw a release a machine may already have downloaded.
republish="$(sed -n '/elif gh release view/,/^          fi$/p' "$publish")"
assert_eq "$(printf '%s\n' "$republish" | grep -c 'gh release delete' || true)" "0" \
  "ac-1 re-running over a published release never deletes it"
assert_eq "$(printf '%s\n' "$republish" | grep -c 'gh release edit' || true)" "1" \
  "ac-1 the exists branch edits the release in exactly one place"

# --------------------------------------------------------------------------- #
# ac-3: the release notes carry the conclusion, not a fixed claim
# --------------------------------------------------------------------------- #

# A re-run publishes whatever the tag/CI actually proves; the notes must not assert a stage
# result the publish job never read.
assert_eq "$(grep -c 'S1 to S5 all passed' "$publish" || true)" "0" \
  "ac-3 the notes never claim the five stages passed"
assert_contains "$publish_step" 'Verified by CI run %s' \
  "ac-3 the notes still name the run that proved the release"
assert_contains "$publish_step" "The stage verdicts are in that" \
  "ac-3 the notes point at the run's report instead of restating its verdict"

# --------------------------------------------------------------------------- #
# ac-6: dry-run publishes nothing
# --------------------------------------------------------------------------- #

publish_step=$(step_block "$publish" 'id: publish')
assert_contains "$publish_step" 'if [ "${DRY_RUN}" = "true" ]' \
  "ac-6 the publish step branches on dry-run"
assert_contains "$publish_step" '--draft' \
  "ac-6 a dry run creates a draft, never a published release"

# --------------------------------------------------------------------------- #
# ac-6: release.yml is only the caller now
# --------------------------------------------------------------------------- #

assert_contains "$release_text" 'uses: ./.github/workflows/ci.yml' \
  "ac-6 the tagged line still builds through the ordinary pipeline"
assert_contains "$release_text" 'uses: ./.github/workflows/release-publish.yml' \
  "ac-6 the tagged line publishes through the reusable workflow"
assert_contains "$(sed -n '/publish:/,/^$/p' "$release" | grep -v '^\s*#')" 'tag-policy: v' \
  "ac-6 the tagged line asks for the v tag policy"
assert_contains "$release_text" 'tag: ${{ github.ref_name }}' \
  "ac-6 the tagged line publishes the tag it was triggered by"

assert_eq "$(grep -c 'gh release' "$release")" "0" \
  "ac-6 release.yml no longer carries publishing steps of its own"
assert_eq "$(grep -c 'runs-on:' "$release")" "0" \
  "ac-6 release.yml schedules no job of its own, so it needs no timeout"

# --------------------------------------------------------------------------- #
# ac-1: the tagged line publishes only after the cross-version upgrade passed
#
# v0.0.9 went out published while cross was red (run 43622253559) because `publish` only
# needed `build`. The stage is a gate now: a red cross - or a skipped one, which the stage
# reports as not-green because a skipped proof is not a passed proof - publishes nothing.
# --------------------------------------------------------------------------- #

# job_needs <workflow> <job-id>: the needs list of one job, normalized to words so the
# assertion does not depend on whether it is written as a flow or a block sequence.
job_needs() {
  awk -v want="$2" '
    /^  [A-Za-z0-9_-]+:$/ { job = $1; sub(":$", "", job); injob = (job == want); next }
    injob && /^    needs:/ {
      sub(/^[[:space:]]*needs:[[:space:]]*/, "")
      gsub(/[][,]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, ""); sub(/ $/, "")
      print; exit
    }
  ' "$1"
}

# Two gates, not one, and both named by the job that publishes: cross proves an upgrade
# across whatever base the two releases pinned, same-base proves the patch-range claim the
# update prompt makes. `needs` is the whole enforcement here - GitHub skips a dependent job
# when a job it needs is skipped - so every gate has to be named, and the order they are
# written in is not part of the contract.
publish_needs="$(job_needs "$release" publish)"
for gate in build cross same-base; do
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  case " ${publish_needs} " in
    *" ${gate} "*) printf 'ok %d - %s\n' "$_ASSERT_COUNT" \
      "ac-1 the publish gate waits for ${gate}" ;;
    *) _assert_fail "ac-1 the publish gate waits for ${gate}" \
      "needs is '${publish_needs}': publishing without it ships an unproven release" ;;
  esac
done
assert_eq "$(printf '%s\n' ${publish_needs} | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')" \
  "build cross same-base" \
  "ac-1 the publish gate waits for exactly the build and the two upgrade gates"

# A skipped gate is not a passed gate. `needs` turns a skip into a skip, never into green,
# but only if nothing re-enables the job: `if: always()` on publish would let both gates be
# skipped and the release still go out.
assert_eq "$(sed -n '/^  publish:/,/^    needs:/p' "$release" | grep -c 'always()')" "0" \
  "ac-1 the publish job is not re-enabled over a skipped gate"
assert_contains "$(cat "$release")" "a skipped gate is not a passed" \
  "ac-1 and the file records why a skip may not publish"

assert_contains "$(sed -n '/^  cross:/,/^  publish:/p' "$release")" \
  'uses: ./.github/workflows/ci-upgrade-cross.yml' \
  "ac-1 the second gate is the cross stage, not a second build"
assert_eq "$(grep -c '^  cross:$' "$release")" "1" \
  "ac-1 the cross job still exists for the gate to wait on"

# The same-base gate is the new half, and it reaches the shared gates workflow in the mode
# that owns it: a second implementation of the same-base criteria would be a second answer
# to the question the two gates exist to answer.
assert_eq "$(grep -c '^  same-base:$' "$release")" "1" \
  "ac-1 the same-base job exists for the gate to wait on"
assert_contains "$(sed -n '/^  same-base:/,/^  publish:/p' "$release")" \
  'uses: ./.github/workflows/ci-upgrade-gates.yml' \
  "ac-1 the same-base gate is the shared gates workflow, not a copy"
assert_contains "$(sed -n '/^  same-base:/,/^  publish:/p' "$release")" \
  "mode: same-base" \
  "ac-1 and it runs in the same-base mode"

# --------------------------------------------------------------------------- #
# ac-6 / ac-10 tail: the three floating @v4 pins in release.yml are gone
# --------------------------------------------------------------------------- #

for wf in "$release" "$publish"; do
  floating=$(grep -E '^\s*uses:' "$wf" | sed -E 's/^[[:space:]]*uses:[[:space:]]*//' \
    | grep -vE '^\./' | grep -vE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}( # v[0-9].*)?$' || true)
  assert_eq "$floating" "" "ac-6 every third-party action in $wf is pinned to a 40-character sha"
  uncommented=$(grep -E '^\s*uses:' "$wf" | sed -E 's/^[[:space:]]*uses:[[:space:]]*//' \
    | grep -vE '^\./' | grep -vE ' # v[0-9]' || true)
  assert_eq "$uncommented" "" "ac-6 every pin in $wf names the release it pins"
done

# --------------------------------------------------------------------------- #
# ac-6: a reusable workflow owns no concurrency and declares a budget
# --------------------------------------------------------------------------- #

assert_eq "$(grep -c '^concurrency:' "$publish")" "0" \
  "ac-6 the reusable workflow leaves concurrency to its caller"
assert_eq "$(grep -c 'cancel-in-progress:' "$publish")" "0" \
  "ac-6 the reusable workflow never cancels its caller"
assert_eq "$(grep -c 'timeout-minutes:' "$publish" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes" \
  "ac-6 the reusable workflow declares a timeout budget"

# --------------------------------------------------------------------------- #
# ac-6: a rehearsal replaces its own untagged draft instead of piling one up per run
#
# `gh release create --draft "${TAG}"` in a rehearsal runs before the tag is pushed, and
# GitHub answers with an *untagged* draft (releases/tag/untagged-...). The repeatability
# guard looked the release up by "${TAG}", so it never found the draft it had made one run
# earlier: every rehearsal left another one behind and the branch that was supposed to
# replace it was dead code. No text assertion can catch that - the text was all there and
# the guard still did nothing - so the step's own run block is extracted and executed
# against a `gh` stub, and the assertions are on the calls the stub recorded.
# --------------------------------------------------------------------------- #

# step_extract <block|run> <workflow> <step>: the step's own YAML lines, or the body of its
# `run: |` block dedented. Read as text, like tests/modules/ci/test_ci_hooks_flag.sh reads
# the same shape: no YAML parser is assumed, and a step that stops being found has to be a
# failure rather than an empty string that makes every assertion below pass.
step_extract() {
    python3 - "$1" "$2" "$3" <<'PY'
import re
import sys

mode, path, name = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines()

start = indent = None
for number, line in enumerate(lines):
    match = re.match(r"^(\s*)- name:\s*" + re.escape(name) + r"\s*$", line)
    if match:
        start, indent = number, len(match.group(1))
        break
if start is None:
    sys.exit(3)  # step not found

block = [lines[start]]
run_indent = None
body = []
for line in lines[start + 1:]:
    stripped = line.strip()
    here_indent = len(line) - len(line.lstrip(" "))
    if stripped.startswith("- ") and here_indent <= indent:
        break  # the next step
    block.append(line)
    if run_indent is None:
        match = re.match(r"^(\s*)run:\s*\|\s*$", line)
        if match:
            run_indent = len(match.group(1))
        continue
    if stripped and here_indent <= run_indent:
        run_indent = None  # the body ended before the step did
        continue
    body.append(line)

if mode == "block":
    sys.stdout.write("\n".join(block) + "\n")
    sys.exit(0)

if not body:
    sys.exit(4)  # step without a run block
while body and not body[-1].strip():
    body.pop()
common = min(
    (len(line) - len(line.lstrip(" ")) for line in body if line.strip()),
    default=0,
)
sys.stdout.write("\n".join(line[common:] if line.strip() else "" for line in body) + "\n")
PY
}

publish_script="$tmp/publish-run.sh"
if step_extract run "$publish" "Publish the GitHub Release" >"$publish_script" \
  2>"$tmp/extract.err"; then
  printf 'ok %d - %s\n' "$((_ASSERT_COUNT = _ASSERT_COUNT + 1))" \
    "ac-6 the publish step body can be extracted and run"
else
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  _assert_fail "ac-6 the publish step body can be extracted and run" \
    "$(cat "$tmp/extract.err")"
fi

# An extraction that came back empty (or a step name that stopped matching) would make
# every assertion below pass against nothing, so the body is pinned before it is used.
assert_eq "$([ -s "$publish_script" ] && echo non-empty || echo empty)" "non-empty" \
  "ac-6 the extracted body is not an empty file"
assert_contains "$(cat "$publish_script")" 'gh release create "${TAG}"' \
  "ac-6 the extracted body is the publish script"
assert_contains "$(cat "$publish_script")" 'set -euo pipefail' \
  "ac-6 the extracted body keeps the step's shell options"
assert_matches "$(cat "$publish_script")" 'DRY_RUN' \
  "ac-6 the extracted body still branches on dry-run"

# The `gh` the step runs against: records every call and models the one behaviour the
# guard exists for - `release create --draft` on a tag that was never pushed comes back as
# an untagged draft, and deleting that tagName removes it.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
: "${GH_STUB_LOG:?}" "${GH_STUB_STATE:?}"
state="${GH_STUB_STATE}"
printf 'gh %s\n' "$*" >>"${GH_STUB_LOG}"

[ "${1:-}" = "release" ] || { echo "stub gh: unsupported command: ${1:-}" >&2; exit 64; }
shift
sub="${1:-}"
shift || true

case "${sub}" in
  view)
    exec python3 - "${state}" "${1:?tag}" "$*" <<'PY'
import json, sys
state, tag, args = sys.argv[1], sys.argv[2], sys.argv[3]
match = [r for r in json.load(open(state + "/releases.json")) if r["tagName"] == tag]
if not match:
    sys.exit(1)
release = match[0]
if "--jq" in args:
    field = args.split("--jq", 1)[1].split()[0].lstrip(".")
    value = release.get(field, "")
    print("true" if value is True else "false" if value is False else value)
else:
    print(json.dumps(release))
PY
    ;;
  list)
    cat "${state}/releases.json"
    ;;
  delete)
    python3 - "${state}" "${1:?tagName}" <<'PY'
import json, sys
state, tag_name = sys.argv[1], sys.argv[2]
path = state + "/releases.json"
releases = json.load(open(path))
kept = [r for r in releases if r["tagName"] != tag_name]
if len(kept) == len(releases):
    print("stub gh: no release " + tag_name, file=sys.stderr)
    sys.exit(1)
json.dump(kept, open(path, "w"))
PY
    ;;
  create)
    tag="${1:?tag}"
    shift
    title=""
    draft=false
    while [ $# -gt 0 ]; do
      case "${1}" in
        --title) title="${2:-}"; shift 2 ;;
        --draft) draft=true; shift ;;
        --notes-file) shift 2 ;;
        *) shift ;;
      esac
    done
    python3 - "${state}" "${tag}" "${title}" "${draft}" <<'PY'
import json, sys
state, tag, title, draft = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "true"
path = state + "/releases.json"
releases = json.load(open(path))
try:
    pushed = {line.strip() for line in open(state + "/pushed-tags") if line.strip()}
except FileNotFoundError:
    pushed = set()
if tag in pushed:
    tag_name = tag
else:
    untagged = [r for r in releases if r["tagName"].startswith("untagged-")]
    tag_name = "untagged-%04d" % (len(untagged) + 1)
releases.append({
    "isDraft": draft,
    "name": title,
    "tagName": tag_name,
    "url": "https://github.com/stub/releases/tag/" + tag_name,
})
json.dump(releases, open(path, "w"))
PY
    ;;
  *)
    echo "stub gh: unsupported release subcommand: ${sub}" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$stub_bin/gh"

# The release assets the step globs over and the inputs it reads from its env, prepared
# the way the job would have left them.
release_tag="25.12.1"
release_title="ImmortalWrt N5105 A/B firmware 25.12.1"
release_dir="$tmp/release"
mkdir -p "$release_dir"
printf 'payload\n' >"$release_dir/payload.tar"
printf '%s  %s\n' "0123456789abcdef0123456789abcdef" "payload.tar" >"$release_dir/SHA256SUMS"

# state_init <dir> <releases-json> [pushed tag ...]: one stub-side repository state. A tag
# is "pushed" only when it is listed, which is exactly the difference between a rehearsal
# and a published release.
state_init() {
  local dir=$1 releases=$2
  shift 2
  mkdir -p "$dir"
  : >"$dir/calls.log"
  printf '%s\n' "$releases" >"$dir/releases.json"
  : >"$dir/pushed-tags"
  if [ $# -gt 0 ]; then
    printf '%s\n' "$@" >>"$dir/pushed-tags"
  fi
}

# rehearsal <state-dir> <output-env-file>: run the extracted step body with DRY_RUN=true,
# which is the branch under test. `rehearsal_status` is the step's own exit status.
rehearsal() {
  local state=$1 out=$2
  GH_STUB_LOG="$state/calls.log" GH_STUB_STATE="$state" \
    PATH="$stub_bin:$PATH" \
    TAG="$release_tag" TITLE="$release_title" DRY_RUN="true" \
    RELEASE_DIR="$release_dir" \
    RUN_URL="https://github.com/stub/actions/runs/1" \
    GITHUB_OUTPUT="$out" \
    bash "$publish_script" >"$state/stdout.log" 2>"$state/stderr.log"
  rehearsal_status=$?
}

# calls <state-dir> <command...>: how many recorded calls start with this command.
calls() {
  local state=$1
  shift
  local count
  count=$(grep -c "^gh $*" "$state/calls.log" 2>/dev/null) || count=0
  printf '%s\n' "$count"
}

# drafts <state-dir> <title>: how many draft releases carry this title on the remote.
drafts() {
  jq --arg title "$2" '[.[] | select(.isDraft and .name == $title)] | length' \
    "$1/releases.json"
}

# (a) two rehearsals of the same version, the tag never pushed.
state="$tmp/state-first"
state_init "$state" '[]'
rehearsal "$state" "$tmp/out-first.env"
assert_eq "$rehearsal_status" "0" "ac-6 the first rehearsal goes green (it publishes nothing)"
assert_eq "$(calls "$state" release create)" "1" \
  "ac-6 the first rehearsal creates exactly one draft"
assert_eq "$(calls "$state" release delete)" "0" \
  "ac-6 the first rehearsal has nothing to replace"
first_draft="$(jq -r '[.[] | select(.isDraft)] | .[0].tagName' "$state/releases.json")"
assert_matches "$first_draft" '^untagged-' \
  "ac-6 the rehearsal draft is untagged, so a lookup by tag cannot find it"

rehearsal "$state" "$tmp/out-second.env"
assert_eq "$rehearsal_status" "0" "ac-6 the second rehearsal goes green too"
assert_eq "$(calls "$state" release delete)" "1" \
  "ac-6 the second rehearsal deletes the draft the first one left"
assert_eq "$(grep '^gh release delete' "$state/calls.log" | awk '{print $4}')" "$first_draft" \
  "ac-6 the deleted tagName is the rehearsal's own untagged draft"
assert_contains "$(cat "$state/stdout.log")" "$first_draft" \
  "ac-6 the rehearsal says which draft it replaced"
assert_eq "$(calls "$state" release create)" "2" \
  "ac-6 each rehearsal still creates its own draft"
assert_eq "$(drafts "$state" "$release_title")" "1" \
  "ac-6 after two rehearsals exactly one draft of this title remains, not two"

# (b) the tag already has a published release: the rehearsal refuses, and touches nothing.
state="$tmp/state-published"
state_init "$state" \
  '[{"isDraft":false,"name":"ImmortalWrt N5105 A/B firmware 25.12.1","tagName":"25.12.1","url":"https://github.com/stub/releases/tag/25.12.1"}]' \
  "$release_tag"
rehearsal "$state" "$tmp/out-published.env"
assert_eq "$rehearsal_status" "1" \
  "ac-6 a rehearsal refuses to overwrite the published release"
assert_contains "$(cat "$state/stderr.log")" \
  "refusing to rehearse over the published release ${release_tag}" \
  "ac-6 the refusal names the release it will not touch"
assert_eq "$(calls "$state" release delete)" "0" "ac-6 a refusal deletes nothing"
assert_eq "$(calls "$state" release create)" "0" "ac-6 a refusal creates nothing"
assert_eq "$(drafts "$state" "$release_title")" "0" \
  "ac-6 a refusal leaves no draft behind"

# (c) a draft already sits under the real tag (the tag was pushed): unchanged behaviour,
# it is replaced, and the release list is never consulted on this path.
state="$tmp/state-tagged-draft"
state_init "$state" \
  '[{"isDraft":true,"name":"ImmortalWrt N5105 A/B firmware 25.12.1","tagName":"25.12.1","url":"https://github.com/stub/releases/tag/25.12.1"}]' \
  "$release_tag"
rehearsal "$state" "$tmp/out-tagged.env"
assert_eq "$rehearsal_status" "0" "ac-6 a draft under the real tag is replaced, as before"
assert_eq "$(calls "$state" release delete)" "1" \
  "ac-6 the tagged draft is deleted exactly once"
assert_eq "$(grep '^gh release delete' "$state/calls.log" | awk '{print $4}')" "$release_tag" \
  "ac-6 and the tag, not an untagged name, is what gets deleted"
assert_eq "$(calls "$state" release list)" "0" \
  "ac-6 the tagged branch does not consult the release list"
assert_eq "$(drafts "$state" "$release_title")" "1" \
  "ac-6 a replaced tagged draft leaves one draft behind"

# --------------------------------------------------------------------------- #
# ac-6: the files still parse as workflows
# --------------------------------------------------------------------------- #

if command -v actionlint >/dev/null 2>&1; then
  for wf in "$publish" "$release"; do
    out=$(actionlint -no-color -shellcheck "" "$wf" 2>&1)
    assert_eq "$out" "" "ac-6 actionlint accepts $wf"
  done
else
  printf 'ok %d - %s\n' "$((_ASSERT_COUNT = _ASSERT_COUNT + 1))" \
    "ac-6 actionlint is not installed here (the verify stage installs it and gates on it)"
fi

finish
