# Tests

Tests are organised by module. Each module owns one concern, so a failure maps to a
single area instead of an anonymous suite.

## Layout

```text
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

Twelve modules, one directory each under `tests/modules/`:

| Module | Concern |
|---|---|
| `ab` | The A/B slot state machine and the commands around it: `ab-slot`, the upgrade boot hook, `ab-backup` / `ab-restore`, GRUB rendering, the payload's platform files, the degraded profiles |
| `boot` | What the initramfs does before userspace: boot breadcrumbs, the console log ring, ESP health, interrupted-boot recovery, the `p4` grow, state parsing, the stdout contract |
| `ci` | The CI itself: the upstream watch, its keepalive log and the automation audit log, the schedule health check, the cross and same-base upgrades, release preflight, naming and publishing, the text conventions, and the structure fingerprint |
| `design` | The documents satisfy `scripts/check_design.py`; no workflow uses a GitHub context where the platform rejects it |
| `device` | The real-machine driver in `scripts/device/`: status parsing, polling, verdicts and step order, driven by a stub `ssh` instead of a device |
| `docs` | Documents a reader follows literally: the backup products and the restore decision tree, the two-phase `boot-overlay` grow, the rule that a device is never shrunk; and the style rules, measured by `scripts/check_docs_style.py` |
| `image` | The S2 guest assertion script and the contracts it checks: partition geometry, GPT PARTNAMEs, filesystem labels |
| `net` | The first-boot network seed and the defaults it renders into it |
| `plugins` | The declared package sources: the plugin library's verdicts, the seam where a feed enters an apk transaction, the CLI's lines and exit codes, the recipe that ships disabled, and one declaration followed end to end |
| `release` | The release stage: artifact names, checksums, notes, and that publishing is a tag action |
| `runtime` | The runtime closure: the btrfs tooling in the platform layer, the lockfile that names it, and the loud failure when it is missing |
| `upgrade` | `ab-upgrade` and the payload: feed modes and exit codes, payload validation, the bootloader member, version policy, apk alignment, package revert |

New modules are added as directories under `tests/modules/` and are picked up automatically.

## In CI

The suite is a stage check, not an optional report. The `verify` stage
([`ci-verify.yml`](../.github/workflows/ci-verify.yml), job `Static Checks`) runs
[`scripts/ci/verify.sh`](../scripts/ci/verify.sh), and its fifth check is
`./tests/run.sh` with no arguments - every module, default parallelism:

```sh
./tests/run.sh
```

- **Offline.** No network, no root, no device and no QEMU. A test that would need a device
  stubs `ssh`, a test that would need `gh` injects a stub through `CI_GH`.
- The upstream fixture is a local file, so the same command passes on a developer laptop and
  on the runner.
- **Hard gate.** A failing suite fails the stage. `verify.sh` keeps the full output in
  `logs/verify-tests.log` and prints the tails of up to five failing test logs into the step.
- It also folds `tests: fail` into the stage summary, which fails `verify` as a whole.
- **Channels are cleared.** `run.sh` unsets `GITHUB_OUTPUT`, `GITHUB_ENV`,
  `GITHUB_STEP_SUMMARY`, `GITHUB_PATH` and `GITHUB_STATE` before running anything.
- A test that inherits a step's channels writes its output into the run instead of stdout,
  which is how three tests once failed on a runner and passed on a laptop.
- **Budget.** The `Static Checks` job has 30 minutes, which covers the linters, the design
  checks and the whole suite.
