#!/usr/bin/env bash
# Module: ci
# Every workflow step that runs a stage script must pass the environment that
# script declares as required. Missing wiring only shows up at run time, as an
# aborted stage long after the job started, so it is checked statically here.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root"

report=$(python3 - "$root" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
workflows = sorted((root / ".github/workflows").glob("*.yml"))
scripts = {p.name: p for p in (root / "scripts/ci").glob("*.sh")}

required = {}
for name, path in scripts.items():
    text = path.read_text()
    required[name] = sorted(set(re.findall(r"\$\{([A-Z][A-Z0-9_]*):\?", text)))

problems = []
checked = 0
for workflow in workflows:
    lines = workflow.read_text().splitlines()
    step_env = []
    job_env = []
    step_name = None
    in_step = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if re.match(r"^\s{6}- ", line):
            # A new list item at step level starts a new step.
            in_step = True
            step_name = stripped[2:].strip()
            step_env = []
        if re.match(r"^\s{4}env:\s*$", line):
            job_env = []
            j = i + 1
            while j < len(lines) and re.match(r"^\s{6}\S", lines[j]) and not lines[j].strip().startswith("- "):
                m = re.match(r"^\s{6}([A-Z][A-Z0-9_]*):", lines[j])
                if m:
                    job_env.append(m.group(1))
                j += 1
        if re.match(r"^\s{8}env:\s*$", line):
            step_env = []
            j = i + 1
            while j < len(lines) and re.match(r"^\s{10}\S", lines[j]):
                m = re.match(r"^\s{10}([A-Z][A-Z0-9_]*):", lines[j])
                if m:
                    step_env.append(m.group(1))
                j += 1
        run = re.search(r"bash scripts/ci/([a-z0-9_-]+\.sh)", line)
        if not run or not in_step:
            continue
        script = run.group(1)
        if script not in required:
            continue
        checked += 1
        missing = [v for v in required[script] if v not in step_env and v not in job_env]
        if missing:
            problems.append(
                f"{workflow.name}: step {step_name!r} runs {script} without {', '.join(missing)}"
            )

print(f"checked={checked}")
for line in problems:
    print(f"problem:{line}")
PY
)

checked=$(printf '%s\n' "$report" | sed -n 's/^checked=//p')
assert_eq "${checked:-0}" "$(printf '%s\n' "$report" | grep -c '^checked=' >/dev/null && echo "$checked")" "stage scripts were scanned"
[[ "${checked:-0}" -gt 0 ]] && result=ok || result=none
assert_eq "$result" "ok" "at least one stage script invocation was found"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  assert_eq "wired" "$line" "every required env var is passed to its stage script"
done < <(printf '%s\n' "$report" | sed -n 's/^problem://p')

finish
