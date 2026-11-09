# Tests

Tests are organised by module. Each module owns one concern, so a failure maps to a
single area instead of an anonymous suite.

## Layout

```
tests/
  run.sh                     # parallel runner
  lib/assert.sh              # assertion helpers
  lib/run_one.sh             # per-test process wrapper, used by run.sh
  modules/<module>/test_*.sh # one module per directory
```

## Running

| Command | Effect |
|---|---|
| `./tests/run.sh` | every module, parallelism = CPU count |
| `./tests/run.sh --jobs 8` | bound parallelism |
| `./tests/run.sh --module design` | single module |
| `./tests/run.sh --list` | list discovered tests |
| `./tests/run.sh --verbose` | print logs of failing tests |

Parallelism defaults to the CPU count and can be overridden with `--jobs` or `JOBS`.
Each test runs in its own process, so modules never share state. Per-test output is
written to `tests/.out/<module>__<name>.log`, which is git-ignored.

## Writing a test

```bash
#!/usr/bin/env bash
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

assert_eq "$(some command)" "expected" "what this proves"

finish
```

Rules:

- the exit status of `finish` is the test result; a test must not call `exit` early
- one assertion per behaviour, with a message that states what it proves
- tests must not write outside the repository, and must clean up temporary files
- a test that needs root or a real device reports `skip` instead of failing

## Modules

| Module | Concern |
|---|---|
| `design` | design documents satisfy `scripts/check_design.py`, version field is valid |

New modules are added as directories under `tests/modules/` and are picked up automatically.
