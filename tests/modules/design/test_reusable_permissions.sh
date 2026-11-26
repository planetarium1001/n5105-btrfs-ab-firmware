#!/usr/bin/env bash
# Module: design
# Verifies the reusable-workflow permission guard in scripts/check_design.py.
#
# A caller job's `permissions:` is a *ceiling*, not a scope: every job of the called workflow
# has to fit inside it, and a job that asks for more makes GitHub reject the whole run at
# startup - no job list, no log, only "This run likely failed because of a workflow file
# issue". That is how the daily upstream watch and the tag release line went dead: ci.yml's
# `audit` job asks for `contents: write`, and both callers granted only `contents: read`.
#
# The guard is only worth having if it sees every shape YAML authors actually write, and if
# what it cannot see is reported instead of skipped. So half of these cases are spellings:
# `write-all`, a flow mapping, `{}`, a quoted `uses:`, and an indentation the parser does not
# follow.
#
#   ac-3 the guard rejects a called job that asks for more than the caller grants
#   ac-3 and accepts the same call once the caller grants it, in every spelling of a grant
#   ac-3 it resolves an inherited ceiling, a multi-level chain and two callers of one workflow
#   ac-3 it reports what it cannot parse - a shape it silently skipped would be an unchecked call
#   ac-4 every workflow in the repository passes the guard, and the check is registered
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The guard is a pure function of the workflow texts, so each case is a directory of small
# workflows written here instead of injected into a copy of the real tree.
guard_dir() { # <dir> -> problem count, then one `file: message` line per problem
  python3 - "$1" <<'PY'
import pathlib
import sys

sys.path.insert(0, "scripts")
import check_design

directory = pathlib.Path(sys.argv[1])
texts = {path.name: path.read_text(encoding="utf-8") for path in sorted(directory.glob("*.yml"))}
problems = check_design._workflow_call_permission_problems(texts)
print(len(problems))
for where, message in problems:
    print(f"{where}: {message}")
PY
}

write_workflow() { # <dir> <file> <heredoc on stdin>
  mkdir -p "$1"
  cat >"$1/$2"
}

assert_problems() { # <dir> <count> <description>
  assert_eq "$(guard_dir "$1" | head -n 1)" "$2" "$3"
}

# --------------------------------------------------------------------------- #
# ac-3: a write request above the caller's ceiling is the defect
# --------------------------------------------------------------------------- #

over=$tmp/over
write_workflow "$over" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/called.yml
    permissions:
      contents: read
YAML
write_workflow "$over" called.yml <<'YAML'
name: Called
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      contents: write
YAML
assert_problems "$over" "1" "ac-3 a called job that asks for more than its caller grants is a problem"
assert_contains "$(guard_dir "$over")" "contents" \
  "ac-3 the problem names the permission that was not granted"

# --------------------------------------------------------------------------- #
# ac-3: the same call is fine once the caller grants it
# --------------------------------------------------------------------------- #

granted=$tmp/granted
write_workflow "$granted" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/called.yml
    permissions:
      contents: write
YAML
write_workflow "$granted" called.yml <<'YAML'
name: Called
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      contents: write
YAML
assert_problems "$granted" "0" "ac-3 the same call is accepted once the caller grants the write"

# A job without its own `permissions:` inherits the called file's top-level block, so a
# top-level write is just as much a request as a job-level one.
inherited=$tmp/inherited
write_workflow "$inherited" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/called.yml
    permissions:
      contents: read
YAML
write_workflow "$inherited" called.yml <<'YAML'
name: Called
on:
  workflow_call:
permissions:
  contents: write
jobs:
  audit:
    runs-on: ubuntu-latest
YAML
assert_problems "$inherited" "1" \
  "ac-3 a called file's top-level write is inherited by its jobs and still checked"

# --------------------------------------------------------------------------- #
# ac-3: every spelling of a job-level block is read, on both sides of the call
#
# These are the shapes that made the first version of this guard blind: a job-level
# `permissions:` written inline was skipped, so the job looked like it inherited `read`.
# --------------------------------------------------------------------------- #

inline=$tmp/inline
write_workflow "$inline" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  all:
    uses: ./.github/workflows/all.yml
    permissions:
      contents: read
  flow:
    uses: ./.github/workflows/flow.yml
    permissions:
      contents: read
YAML
write_workflow "$inline" all.yml <<'YAML'
name: All
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
    permissions: write-all
YAML
write_workflow "$inline" flow.yml <<'YAML'
name: Flow
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
    permissions: {contents: write}
YAML
assert_eq "$(guard_dir "$inline" | grep -c 'all.yml: job')" "1" \
  "ac-3 a job-level 'permissions: write-all' is a write request, not an invisible line"
assert_eq "$(guard_dir "$inline" | grep -c 'flow.yml: job')" "1" \
  "ac-3 a job-level flow mapping is a write request too"

wide=$tmp/wide
write_workflow "$wide" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/called.yml
    permissions: {contents: write}
YAML
write_workflow "$wide" called.yml <<'YAML'
name: Called
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
    permissions: {contents: write}
YAML
assert_problems "$wide" "0" \
  "ac-3 a caller's flow-mapping grant is read as a grant, not as the file's read-only default"

nowhere=$tmp/nowhere
write_workflow "$nowhere" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/called.yml
    permissions: {}
YAML
write_workflow "$nowhere" called.yml <<'YAML'
name: Called
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
YAML
assert_problems "$nowhere" "1" \
  "ac-3 an empty grant is no grant: a called job asking for contents: read exceeds it"

# --------------------------------------------------------------------------- #
# ac-3: chains, missing files and published actions
# --------------------------------------------------------------------------- #

chain=$tmp/chain
write_workflow "$chain" top.yml <<'YAML'
name: Top
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/middle.yml
    permissions:
      contents: write
YAML
write_workflow "$chain" middle.yml <<'YAML'
name: Middle
on:
  workflow_call:
permissions:
  contents: read
jobs:
  inner:
    uses: ./.github/workflows/leaf.yml
    permissions:
      contents: read
YAML
write_workflow "$chain" leaf.yml <<'YAML'
name: Leaf
on:
  workflow_call:
permissions:
  contents: read
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: write
YAML
assert_contains "$(guard_dir "$chain")" "leaf.yml" \
  "ac-3 a write request is judged against the ceiling of the whole chain, not only the caller"

missing=$tmp/missing
write_workflow "$missing" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/absent.yml
    permissions:
      contents: read
YAML
assert_problems "$missing" "1" \
  "ac-3 a uses: that names a workflow that does not exist is a startup failure too"

outside=$tmp/outside
write_workflow "$outside" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  checkout:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
YAML
assert_problems "$outside" "0" \
  "ac-3 a published action is not one of this repository's workflows"

# One workflow called from two places: the wide caller passing must not hide the narrow
# caller failing, which is why a visit is remembered with the ceiling it was made under.
shared=$tmp/shared
write_workflow "$shared" wide.yml <<'YAML'
name: Wide
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/called.yml
    permissions:
      contents: write
YAML
write_workflow "$shared" narrow.yml <<'YAML'
name: Narrow
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/called.yml
    permissions:
      contents: read
YAML
write_workflow "$shared" called.yml <<'YAML'
name: Called
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      contents: write
YAML
assert_contains "$(guard_dir "$shared")" "narrow.yml" \
  "ac-3 a wide caller does not excuse the narrow caller of the same workflow"

# --------------------------------------------------------------------------- #
# ac-3: what the guard cannot parse is reported, never skipped
# --------------------------------------------------------------------------- #

quoted=$tmp/quoted
write_workflow "$quoted" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: "./.github/workflows/called.yml"
    permissions:
      contents: read
YAML
write_workflow "$quoted" called.yml <<'YAML'
name: Called
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      contents: write
YAML
assert_contains "$(guard_dir "$quoted")" "called.yml" \
  "ac-3 a quoted uses: is still the call it spells"

indented=$tmp/indented
write_workflow "$indented" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
    build:
        uses: ./.github/workflows/called.yml
        permissions:
            contents: write
YAML
write_workflow "$indented" called.yml <<'YAML'
name: Called
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
YAML
assert_contains "$(guard_dir "$indented")" "not parsed" \
  "ac-3 a call the parser cannot follow is reported, because a silent skip is an unchecked call"

typo=$tmp/typo
write_workflow "$typo" caller.yml <<'YAML'
name: Caller
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/called.yml
    permissions:
      contents: read
YAML
write_workflow "$typo" called.yml <<'YAML'
name: Called
on:
  workflow_call:
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      contents: readd
YAML
assert_contains "$(guard_dir "$typo")" "readd" \
  "ac-3 a misspelled level is reported with its value instead of crashing the check"

# --------------------------------------------------------------------------- #
# ac-4: the real tree passes, and the check is wired into the suite
# --------------------------------------------------------------------------- #

assert_command_ok "ac-4 every workflow in the repository passes the permission guard" \
  python3 scripts/check_design.py reusable-permissions
assert_contains "$(python3 scripts/check_design.py no-such-check 2>&1 || true)" "reusable-permissions" \
  "ac-4 the check is registered under its own name"
assert_contains "$(python3 scripts/check_design.py all 2>&1 || true)" "reusable-permissions" \
  "ac-4 the guard runs as part of the aggregate"

finish
