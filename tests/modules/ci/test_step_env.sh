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

STEP_RE = re.compile(r"^\s{6}- ")
STEP_ENV_RE = re.compile(r"^\s{8}env:\s*$")
STEP_ENV_KEY_RE = re.compile(r"^\s{10}([A-Z][A-Z0-9_]*):")
JOB_ENV_RE = re.compile(r"^\s{4}env:\s*$")
JOB_ENV_KEY_RE = re.compile(r"^\s{6}([A-Z][A-Z0-9_]*):")
RUN_RE = re.compile(r"bash scripts/ci/([a-z0-9_-]+\.sh)")

problems = []
checked = 0
loader_elsewhere = 0
for workflow in workflows:
    lines = workflow.read_text().splitlines()

    job_env = []
    for i, line in enumerate(lines):
        if not JOB_ENV_RE.match(line):
            continue
        j = i + 1
        while (
            j < len(lines)
            and re.match(r"^\s{6}\S", lines[j])
            and not lines[j].strip().startswith("- ")
        ):
            m = JOB_ENV_KEY_RE.match(lines[j])
            if m:
                job_env.append(m.group(1))
            j += 1

    starts = [i for i, line in enumerate(lines) if STEP_RE.match(line)]
    for k, start in enumerate(starts):
        end = starts[k + 1] if k + 1 < len(starts) else len(lines)
        step = lines[start:end]
        step_name = step[0].strip()[2:].strip()

        step_env = []
        for i, line in enumerate(step):
            if not STEP_ENV_RE.match(line):
                continue
            step_env = []
            for follow in step[i + 1:]:
                if not re.match(r"^\s{10}\S", follow):
                    break
                m = STEP_ENV_KEY_RE.match(follow)
                if m:
                    step_env.append(m.group(1))

        # A step that loads the stage outputs from a KEY=VALUE file is wired by lib.sh:
        # ci_load_env_file exports every entry as CI_<UPPERCASE>, which is exactly how
        # scripts/ci/README.md documents running these stages without Actions. ci-debug.yml
        # needs that path because its values (upstream version, sha256s, kmods directory)
        # exist only after resolve.sh has run, so they cannot be written into the step.
        by_loader = any("ci_load_env_file" in line for line in step)

        for line in step:
            run = RUN_RE.search(line)
            if not run:
                continue
            script = run.group(1)
            if script not in required:
                continue
            checked += 1
            if by_loader:
                # Only workflows whose stage inputs are resolved at run time may use the
                # loader: a debug session (ci-debug.yml) and the automatic release line
                # (upstream-watch.yml, which derives the lockfiles).
                if workflow.name not in ("ci-debug.yml", "upstream-watch.yml"):
                    loader_elsewhere += 1
                continue
            missing = [v for v in required[script] if v not in step_env and v not in job_env]
            if missing:
                problems.append(
                    f"{workflow.name}: step {step_name!r} runs {script} without {', '.join(missing)}"
                )

print(f"checked={checked}")
print(f"loader_elsewhere={loader_elsewhere}")
for line in problems:
    print(f"problem:{line}")
PY
)

checked=$(printf '%s\n' "$report" | sed -n 's/^checked=//p')
assert_eq "${checked:-0}" "$(printf '%s\n' "$report" | grep -c '^checked=' >/dev/null && echo "$checked")" "stage scripts were scanned"
[[ "${checked:-0}" -gt 0 ]] && result=ok || result=none
assert_eq "$result" "ok" "at least one stage script invocation was found"

# A stage script reached through the loader is wired by construction, but the loader has
# to be a deliberate choice: only workflows whose stage inputs do not exist until
# resolve.sh has run may use it (ci-debug.yml for a debug session, upstream-watch.yml for
# the lockfile derivation of the automatic release line).
loader_uses=$(printf '%s\n' "$report" | sed -n 's/^loader_elsewhere=//p')
assert_eq "${loader_uses:-0}" "0" "no stage workflow relies on the loader instead of env wiring"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  assert_eq "wired" "$line" "every required env var is passed to its stage script"
done < <(printf '%s\n' "$report" | sed -n 's/^problem://p')

finish
