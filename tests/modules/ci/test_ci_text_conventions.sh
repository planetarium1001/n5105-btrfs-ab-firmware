#!/usr/bin/env bash
# Module: ci
# Guards docs/ci-text-contract.md: the seven rules that decide what the pipeline says to a
# human - workflow, job and step labels, input descriptions, the stage summary, the report,
# the diagnostics block, the issue and pull request bodies the upstream watch renders, and
# the release title and notes.
#
# The rules exist because a text rewrite is the one change that looks harmless and is not:
# a label and the `id:` below it are one line apart, and the pipeline happily runs a step
# whose name no longer matches what it does. Six rules are asserted here; the seventh - the
# judgement call - is a review checklist in the document itself.
#
# Rule 7 is the seatbelt for the other six. It compares the surface against
# tests/fixtures/ci-structure-fingerprint.txt, a sorted list of the keys, action pins,
# identifiers and judge tokens that no prose change may touch. A batch that only rewrites
# words leaves the fingerprint byte-identical; a batch that moves a key prints exactly which
# one. Regenerating the baseline is a separate commit with a filled-in `# reason:` header,
# because a re-baseline mixed into a text batch hides the one thing the file is for.
#
#   CI_TEXT_FINGERPRINT_WRITE=1 \
#   CI_TEXT_FINGERPRINT_REASON='ci-s5 passes CI_BOOT_SOURCE_*, L2' \
#     bash tests/modules/ci/test_ci_text_conventions.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

FINGERPRINT="tests/fixtures/ci-structure-fingerprint.txt"
# The one release title template, rendered with a version for the length and punctuation
# assertions below.
TITLE_TEMPLATE="N5105 AB firmware {tag}"

# Writing the baseline needs a reason. Refusing here rather than trusting the convention is
# what keeps a re-baseline reviewable: the header is the only record of why the structure
# moved, and an empty one is a baseline nobody can judge.
if [ "${CI_TEXT_FINGERPRINT_WRITE:-0}" = "1" ] && [ -z "${CI_TEXT_FINGERPRINT_REASON:-}" ]; then
  echo "CI_TEXT_FINGERPRINT_REASON is empty: state why the structure changed" >&2
  exit 2
fi

# text_scan <mode>: one python pass over the surface, one subcommand per rule, so a failure
# names the rule and prints `path:line: what` instead of a diff nobody can attribute.
text_scan() {
  python3 - "$root" "$1" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
mode = sys.argv[2]

WORKFLOWS = sorted((root / ".github" / "workflows").glob("*.yml"))
ACTIONS = sorted((root / ".github" / "actions").glob("*/action.yml"))
SCRIPTS = sorted((root / "scripts" / "ci").glob("*.sh"))
# Files whose `name:` is a label. The scripts print labels instead of declaring them, so
# they are covered by the fingerprint and by the rendered-body assertions, not by rule 2.
LABELS = WORKFLOWS + ACTIONS

STEP_RE = re.compile(r"^\s*- name: (.+)$")
JOB_RE = re.compile(r"^ {4}name: (.+)$")
WORKFLOW_NAME_RE = re.compile(r"^name: (.+)$")
ON_RE = re.compile(r"""^(?:on|"on"|'on'):[ ]*(.*)$""")
TRIGGER_RE = re.compile(r"^ {2}([A-Za-z_][\w-]*):")

# The pipeline's own verb vocabulary. A step either acts - first word from this list - or
# opens a phase with one of the markers below. Adding a verb here is a deliberate widening
# of the vocabulary; inventing a noun is what the rule is there to stop.
VERBS = {
    "Add", "Assert", "Assemble", "Boot", "Build", "Bump", "Check", "Collect", "Commit",
    "Create", "Cross-check", "Decide", "Derive", "Detect", "Download", "Export", "Fetch",
    "Guard", "Install", "Keep", "Lint", "Mount", "Open", "Preflight", "Prepare", "Print",
    "Publish",
    "Push", "Read", "Record", "Render", "Report", "Resolve", "Restore", "Run", "Select",
    "Squash", "Stop", "Tag", "Unmount", "Unpack", "Upload", "Verify", "Write",
}
MARKER_RE = re.compile(r"^(?:Boot [1-9]|Phase [1-9][a-z]?|Fixture|Preflight) - \S")
STAGE_JOB_RE = re.compile(r"^S[1-5] [a-z]+ - .+$")
PHRASE_JOB_RE = re.compile(r"^[a-z][a-z0-9-]*( [a-z0-9/-]+)*( - .+)?$")
STAGE_WORKFLOW_RE = re.compile(r"^[a-z][a-z0-9 -]*$")

# Rule 5: the five header rows. `release.sh` and both workflows render key-value blocks, so
# a header that spells `item | value` is the same table with a second name for `field`.
HEADERS = {
    "| stage | verdict | key line | artifact and sha256 | next command |",
    "| stage | verdict | duration | artifact |",
    "| field | value |",
    "| job | result |",
    "| artifact | size | sha256 |",
}
PRINTF_RE = re.compile(r"printf '([^']*)'")
DIVIDER_CELLS = re.compile(r"^\|( *-{3,} *\|)+$")


def lines_of(path):
    return path.read_text(encoding="utf-8").splitlines()


def rel(path):
    return path.relative_to(root).as_posix()


def label_values():
    """Every `name:` value that a reader sees, with its file and line."""
    for path in LABELS:
        for number, line in enumerate(lines_of(path), 1):
            match = WORKFLOW_NAME_RE.match(line) or JOB_RE.match(line) or STEP_RE.match(line)
            if match:
                yield path, number, match.group(1).strip()


def triggers_of(path):
    """Top-level keys of the `on:` block; flow style (`on: [push]`) included."""
    lines = lines_of(path)
    for index, line in enumerate(lines):
        match = ON_RE.match(line)
        if not match:
            continue
        rest = match.group(1).strip()
        if rest:
            return {name for name in re.findall(r"[A-Za-z_]+", rest)}
        keys = set()
        for follow in lines[index + 1:]:
            if not follow.strip() or follow.lstrip().startswith("#"):
                continue
            if not follow.startswith(" "):
                break
            key = TRIGGER_RE.match(follow)
            if key:
                keys.add(key.group(1))
        return keys
    return set()


def non_ascii():
    problems = []
    for path in WORKFLOWS + ACTIONS + SCRIPTS:
        for number, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("#"):
                continue
            if any(ord(ch) > 0x7F for ch in line):
                problems.append(f"{rel(path)}:{number}: {line.strip()[:160]}")
    return problems


def bad_labels():
    problems = []
    for path, number, value in label_values():
        if value.startswith("${{"):
            # A composite forwarding its caller's name: the caller's label is the one that
            # has to obey the rule, and it is checked where it is written.
            continue
        if value != value.strip():
            problems.append(f"{rel(path)}:{number}: whitespace around {value!r}")
        if value.endswith((".", "!", ";")):
            problems.append(f"{rel(path)}:{number}: punctuation at the end of {value!r}")
    return problems


def overlong():
    problems = []
    caps = {"workflow": 40, "job": 40, "step": 60}
    for path in WORKFLOWS + ACTIONS:
        for number, line in enumerate(lines_of(path), 1):
            kind = None
            value = ""
            if WORKFLOW_NAME_RE.match(line):
                kind, value = "workflow", WORKFLOW_NAME_RE.match(line).group(1)
            elif STEP_RE.match(line):
                kind, value = "step", STEP_RE.match(line).group(1)
            elif JOB_RE.match(line):
                kind, value = "job", JOB_RE.match(line).group(1)
            if not kind:
                continue
            cap = caps[kind]
            if len(value.strip()) > cap:
                problems.append(f"{rel(path)}:{number}: {kind} name is {len(value.strip())} characters, cap is {cap}: {value.strip()!r}")
    return problems


def workflow_shapes():
    problems = []
    for path in WORKFLOWS:
        name = lines_of(path)[0]
        match = WORKFLOW_NAME_RE.match(name)
        if not match:
            problems.append(f"{rel(path)}: no workflow name on the first line")
            continue
        value = match.group(1).strip()
        entry = triggers_of(path) != {"workflow_call"}
        if entry:
            if not value.startswith("Firmware CI - "):
                problems.append(f"{rel(path)}: an entry point is named 'Firmware CI - <role>', not {value!r}")
        elif value.startswith("Firmware CI - "):
            problems.append(f"{rel(path)}: a reusable workflow may not carry the entry point prefix: {value!r}")
        elif not (re.match(r"^S[1-5] [a-z]+$", value) or STAGE_WORKFLOW_RE.match(value)):
            problems.append(f"{rel(path)}: a reusable workflow is named for its role: {value!r}")
    return problems


def step_shapes():
    problems = []
    for path in WORKFLOWS + ACTIONS:
        for number, line in enumerate(lines_of(path), 1):
            match = STEP_RE.match(line)
            if not match:
                continue
            value = match.group(1).strip()
            if MARKER_RE.match(value):
                continue
            if value.split()[0] not in VERBS:
                problems.append(f"{rel(path)}:{number}: a step starts with a verb or a phase marker: {value!r}")
            if re.search(r"\bS[1-5]\b", value):
                problems.append(f"{rel(path)}:{number}: a step carries no stage number, its job already does: {value!r}")
    return problems


def job_shapes():
    problems = []
    for path in WORKFLOWS:
        for number, line in enumerate(lines_of(path), 1):
            match = JOB_RE.match(line)
            if not match:
                continue
            value = match.group(1).strip()
            if STAGE_JOB_RE.match(value) or PHRASE_JOB_RE.match(value):
                continue
            problems.append(f"{rel(path)}:{number}: a job is a stage label or a verb phrase: {value!r}")
    return problems


def printed_rows(path):
    """Every line a script prints, in order, with its source line number.

    A table header and its divider may be in one literal (`| a | b |\\n| --- | --- |`) or
    in two calls on adjacent lines, so the two are compared as printed text, not as source.
    """
    rows = []
    for number, line in enumerate(lines_of(path), 1):
        for literal in PRINTF_RE.findall(line):
            for segment in literal.split("\\n"):
                rows.append((number, segment.strip()))
    return rows


def header_rows():
    problems = []
    for path in WORKFLOWS + ACTIONS + SCRIPTS:
        rows = printed_rows(path)
        for index, (number, segment) in enumerate(rows[:-1]):
            if not (segment.startswith("|") and segment.endswith("|")):
                continue
            if "%" in segment:
                continue
            if not DIVIDER_CELLS.match(rows[index + 1][1]):
                continue
            if segment not in HEADERS:
                problems.append(f"{rel(path)}:{number}: {segment}")
    return problems


def fingerprint():
    """Structure only: the keys a prose rewrite must not touch.

    Human-readable values are dropped (`name:`, a flow mapping's `description:`, trailing
    comments), so the output is identical before and after a text-only change.
    """
    struct_keys = {
        "on", "jobs", "steps", "runs", "uses", "needs", "with", "outputs", "inputs",
        "env", "id", "if", "runs-on", "timeout-minutes", "continue-on-error", "shell",
        "working-directory", "permissions", "secrets", "matrix", "include", "exclude",
        "concurrency", "group", "cancel-in-progress", "default", "required", "type",
        "strategy", "max-parallel", "fail-fast", "defaults",
    }
    name_parents = {"with", "matrix", "outputs", "env", "inputs"}
    value_parents = ("with", "env", "outputs", "inputs", "matrix")
    key_re = re.compile(r"^( *)(?:- +)?([A-Za-z_][A-Za-z0-9_.-]*):(.*)$")
    item_re = re.compile(r"^( *)- ")
    description_re = re.compile(r'description:\s*("(?:[^"\\]|\\.)*"|[^,}]*)')
    judge_re = re.compile(r"S[1-5]-RESULT=")
    var_re = re.compile(r"\b((?:CI|AB)_[A-Z0-9_]+)\b")
    flag_re = re.compile(r"(--[a-z][a-z0-9-]+)")
    function_re = re.compile(r"^([a-z][a-z0-9_]*)\(\)")

    def sanitize(value):
        value = description_re.sub("description:<text>", value)
        return re.sub(r"\s+#.*$", "", value).strip()

    out = []
    for path in WORKFLOWS + ACTIONS:
        stack: list[tuple[int, str]] = []
        counters: dict[tuple[int, str], int] = {}

        def pop_at_least(indent):
            while stack and stack[-1][0] >= indent:
                stack.pop()

        for line in lines_of(path):
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            item = item_re.match(line)
            if item:
                indent = len(item.group(1))
                pop_at_least(indent)
                parent = ".".join(segment for _, segment in stack)
                index = counters.get((indent, parent), 0)
                counters[(indent, parent)] = index + 1
                stack.append((indent, f"[{index}]"))
            match = key_re.match(line)
            if not match:
                continue
            indent = len(match.group(1))
            key = match.group(2)
            if not item:
                pop_at_least(indent)
            segments = [segment for _, segment in stack]
            where = ".".join(segments + [key])
            if (
                key in struct_keys
                or (key == "name" and name_parents.intersection(segments))
                or (segments and segments[-1] in value_parents)
            ):
                out.append(f"yaml {rel(path)} {where} = {sanitize(match.group(3))}")
            stack.append((indent + 2 if item else indent, key))

    for path in SCRIPTS:
        text = path.read_text(encoding="utf-8")
        for name in sorted({match.group(1) for match in map(function_re.match, text.splitlines()) if match}):
            out.append(f"sh-fn {rel(path)} {name}")
        for name in sorted({match.group(1) for match in var_re.finditer(text)}):
            out.append(f"sh-var {rel(path)} {name}")
        for name in sorted({match.group(1) for match in flag_re.finditer(text)}):
            out.append(f"sh-flag {rel(path)} {name}")

    for path in WORKFLOWS + ACTIONS + SCRIPTS:
        text = path.read_text(encoding="utf-8")
        for name in sorted(set(judge_re.findall(text))):
            out.append(f"judge {rel(path)} {name}")

    return sorted(set(out))


modes = {
    "non-ascii": non_ascii,
    "labels": bad_labels,
    "lengths": overlong,
    "workflow-shapes": workflow_shapes,
    "step-shapes": step_shapes,
    "job-shapes": job_shapes,
    "headers": header_rows,
}
if mode == "fingerprint":
    sys.stdout.write("\n".join(fingerprint()) + "\n")
else:
    sys.stdout.write("\n".join(modes[mode]()))
PY
}

# --------------------------------------------------------------------------- #
# Rule 1 - English on the CI surface
# --------------------------------------------------------------------------- #

assert_eq "$(text_scan non-ascii)" "" \
  "rule 1 every non-comment line of the CI surface is ASCII"

# The exemption is real, not accidental: the translations are the one place Chinese is
# allowed, and a rule whose exemption quietly disappeared would be a rule the repository
# cannot follow.
assert_file_exists "docs/ci-text-contract.zh-CN.md" "rule 1 the contract has its translation"
assert_file_exists "docs/ci-pipeline.zh-CN.md" "rule 1 the pipeline page keeps its translation"

# --------------------------------------------------------------------------- #
# Rule 2 - a label is not a sentence
# --------------------------------------------------------------------------- #

assert_eq "$(text_scan labels)" "" \
  "rule 2 no label ends in a period, an exclamation mark or whitespace"

# --------------------------------------------------------------------------- #
# Rule 3 - length caps
# --------------------------------------------------------------------------- #

assert_eq "$(text_scan lengths)" "" \
  "rule 3 workflow 40, job 40, step 60 characters"

# --------------------------------------------------------------------------- #
# Rule 4 - one grammatical slot per level
# --------------------------------------------------------------------------- #

assert_eq "$(text_scan workflow-shapes)" "" \
  "rule 4 an entry point is 'Firmware CI - <role>', a reusable file names its stage or role"
assert_eq "$(text_scan job-shapes)" "" \
  "rule 4 a stage job is 'S<n> <semantic> - <what it proves>', any other job is a verb phrase"
assert_eq "$(text_scan step-shapes)" "" \
  "rule 4 a step is '<Verb phrase>' or '<Marker> - <claim>'"

# --------------------------------------------------------------------------- #
# Rule 5 - fixed summary tables
# --------------------------------------------------------------------------- #

assert_eq "$(text_scan headers)" "" \
  "rule 5 every table header is one of the five, lowercase and in order"

assert_contains "$(cat scripts/ci/stage-summary.sh)" \
  "| stage | verdict | key line | artifact and sha256 | next command |" \
  "rule 5 the stage summary keeps its five columns"
assert_contains "$(cat scripts/ci/report.sh)" "| stage | verdict | duration | artifact |" \
  "rule 5 the report keeps its four columns"

# --------------------------------------------------------------------------- #
# Rule 6 - fixed title templates
# --------------------------------------------------------------------------- #

# Both bodies are rendered by the real code path, so the template is asserted where it is
# produced and not only where it is documented.
cp ".github/upstream-pin.conf" "$tmp/pin.conf"
render_body() {
  local sub="$1" out="$2"
  shift 2
  env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CI_OUTPUT_ENV="$tmp/render.env" \
    CI_TMP_ROOT="$tmp/ci" CI_UPSTREAM_PIN_FILE="$tmp/pin.conf" \
    CI_UPSTREAM_VERSION=25.13.0 CI_PREVIOUS_PIN=25.12.2 \
    CI_MATRIX_CANDIDATES="25.13.0 25.12.2 25.12.1 25.12.0" CI_MATRIX_GAPS=1 \
    CI_RUN_URL="https://github.com/example/repo/actions/runs/42" \
    CI_AUTO_FAILED_STAGE=s5 CI_AUTO_REASON="S5-RESULT=fail reason=qemu-timeout" \
    CI_LOG_ARTIFACT=evidence-s5 \
    bash scripts/ci/upstream-watch.sh "${sub}" --out "${out}" >/dev/null 2>&1
}

render_body pr-body "$tmp/pr.md"
assert_file_exists "$tmp/pr.md" "rule 6 the pull request body renders"
assert_eq "$(head -n 1 "$tmp/pr.md")" "# Upstream 25.13.0 (pin 25.12.2 -> 25.13.0)" \
  "rule 6 the pull request heading names the version and both sides of the pin"

render_body issue-body "$tmp/issue.md"
assert_file_exists "$tmp/issue.md" "rule 6 the issue body renders"
assert_eq "$(head -n 1 "$tmp/issue.md")" "# [auto-release] 25.13.0" \
  "rule 6 the issue title is '[auto-release] <version>', the deduplication key"

# One release template, in one place. The default belongs to the publisher; a call site that
# spells the template again is the same decision made twice, and the two drift.
assert_contains "$(cat .github/workflows/release-publish.yml)" \
  "default: \"${TITLE_TEMPLATE}\"" \
  "rule 6 the publisher defaults the title to 'N5105 AB firmware <version>'"
for caller in release.yml upstream-watch.yml; do
  assert_eq "$(grep -cE '^ +title: ' ".github/workflows/${caller}" || true)" "0" \
    "rule 6 ${caller} leaves the release title to the publisher"
done
# A second template for the same product line is the drift this rule exists to stop.
assert_eq "$(grep -rc 'ImmortalWrt N5105 A/B firmware' .github/ 2>/dev/null \
  | grep -v ':0$' || true)" "" \
  "rule 6 one release template for the product, not one per release line"

assert_contains "$(cat .github/workflows/upstream-watch.yml)" \
  'chore(ci): pin upstream ${VERSION}' \
  "rule 6 the pull request and its commit share the pin-bump template"

# The stage verdict in the release notes is read from the run. A fixed sentence would print
# 'five stages passed' for a run that was asked to prove one.
assert_eq "$(grep -c 'S1 to S5 all passed' .github/workflows/release-publish.yml || true)" "0" \
  "rule 6 the release notes carry the conclusion, not a fixed claim"
assert_contains "$(cat .github/workflows/release-publish.yml)" "Verified by CI run" \
  "rule 6 the release notes still name the run that proved the release"

# A title is capped at 80 columns and ends without punctuation, measured on the rendered
# string rather than on the template.
rendered="${TITLE_TEMPLATE//\{tag\}/25.13.0}"
assert_eq "$(printf '%s' "${rendered}" | LC_ALL=C awk '{ print (length($0) <= 80) ? "ok" : "over 80" }')" \
  "ok" "rule 3 a rendered release title stays inside 80 columns: '${rendered}'"
case "${rendered}" in
  *.) tail=period ;;
  *'!') tail=bang ;;
  *) tail=clean ;;
esac
assert_eq "${tail}" "clean" "rule 2 '${rendered}' carries no trailing punctuation"

# --------------------------------------------------------------------------- #
# Rule 7 - structure is not text
# --------------------------------------------------------------------------- #

text_scan fingerprint >"$tmp/fingerprint.txt"

# The refusal above is asserted, not only written down: a writer that accepts an empty
# reason is the one hole in this rule.
refusal="$(CI_TEXT_FINGERPRINT_WRITE=1 CI_TEXT_FINGERPRINT_REASON= bash "${BASH_SOURCE[0]}" 2>&1)"
assert_contains "${refusal}" "CI_TEXT_FINGERPRINT_REASON is empty" \
  "rule 7 the writer refuses to re-baseline without a reason"

if [ "${CI_TEXT_FINGERPRINT_WRITE:-0}" = "1" ]; then
  {
    printf '# CI structure fingerprint - docs/ci-text-contract.md, rule 7.\n'
    printf '# Structure only: keys, action pins, identifiers and judge tokens. A prose\n'
    printf '# change must leave every line below byte-identical.\n'
    printf '# Regenerate: CI_TEXT_FINGERPRINT_WRITE=1 CI_TEXT_FINGERPRINT_REASON=<why> \\\n'
    printf '#   bash tests/modules/ci/test_ci_text_conventions.sh\n'
    printf '# reason: %s\n' "${CI_TEXT_FINGERPRINT_REASON:-}"
    cat "$tmp/fingerprint.txt"
  } >"$FINGERPRINT"
  echo "wrote $FINGERPRINT ($(wc -l <"$FINGERPRINT" | tr -d ' ') lines)"
  exit 0
fi

assert_file_exists "$FINGERPRINT" "rule 7 the structure baseline exists"
assert_matches "$(sed -n 's/^# reason: //p' "$FINGERPRINT" | head -n 1)" ".+" \
  "rule 7 the baseline records why it was taken"
assert_contains "$(cat "$FINGERPRINT")" "S1-RESULT=" \
  "rule 7 the baseline carries the frozen judge tokens"

grep -v '^#' "$FINGERPRINT" | sed '/^$/d' >"$tmp/baseline.txt"
structural_diff=$(diff -u "$tmp/baseline.txt" "$tmp/fingerprint.txt" | sed -n '3,40p')
assert_eq "${structural_diff}" "" \
  "rule 7 the structure fingerprint is unchanged (- baseline, + current; first 40 lines)"

if [ -n "${structural_diff}" ]; then
  printf 'rule 7: a text batch must not move a key. If this change is intended, re-baseline\n' >&2
  printf 'rule 7: in its own commit with a reason, and keep the diff in the review.\n' >&2
fi

finish
