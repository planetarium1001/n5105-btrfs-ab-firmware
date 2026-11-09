# CI stage scripts

Every stage of the pipeline is a shell script in this directory. The workflows in
`.github/workflows/` only orchestrate: they check out the repository, run one script,
upload the results and collect diagnostics. Keeping the logic here means a stage can be
reproduced locally with the same inputs the workflow passes.

| Workflow | Stage |
|---|---|
| `.github/workflows/ci.yml` | entry point: triggers, stage selection, final verdict |
| `.github/workflows/ci-resolve.yml` | resolve |
| `.github/workflows/ci-fetch.yml` | fetch |
| `.github/workflows/ci-assemble.yml` | assemble |
| `.github/workflows/ci-verify.yml` | verify |
| `.github/workflows/ci-report.yml` | report |

The stage workflows sit at the root of `.github/workflows/` and not in a subdirectory:
GitHub does not support reusable workflows in subdirectories of that directory, so the
`ci-<stage>.yml` naming keeps the grouping visible while staying callable.

## Files

| Script | Stage | Purpose |
|---|---|---|
| `lib.sh` | — | shared helpers, pinned upstream version, cache key inputs; sourced by the others |
| `resolve.sh` | resolve | pick the upstream release, cross-check the kernel module directory, derive the cache key |
| `fetch.sh` | fetch | download rootfs, kernel and btrfs module, verify every sha256, write a receipt |
| `assemble.sh` | assemble | build the payload directory and `manifest.json` (S0 skeleton) |
| `verify.sh` | verify | `bash -n`, ShellCheck, `python3 scripts/check_design.py all` |
| `report.sh` | report | render the verdict and fail the run when a scheduled stage failed |
| `diagnostics.sh` | all | environment facts, disk usage and file inventories for failure triage |

## Stage graph

```
resolve ──┬── fetch ── assemble ──┐
          └── verify ─────────────┴── report
```

`workflow_dispatch` selects how much of the graph runs, so a failed run resumes instead
of restarting:

| `stage` | Stages executed |
|---|---|
| `all` (default) | resolve, fetch, assemble, verify, report |
| `fetch` | resolve, fetch, report |
| `assemble` | resolve, fetch, assemble, report |
| `verify` | resolve, verify, report |

`resolve` always runs: it is a handful of small downloads and it publishes the upstream
version and cache key that the report needs.

## Cache key

```
cache_key = upstream-<version>-<sha256(key material)[0..16]>
key material = upstream_version, kmods_dir, kernel_package,
               rootfs/kernel/btrfs-module sha256,
               CI_TOOLS_VERSION, CI_TOOLS,
               sha256 of every scripts/ci/*.sh and .github/workflows/**/*.yml
```

Consequences:

- an unchanged upstream release, tool set and CI script set hits the cache and skips
  the network
- bumping `CI_UPSTREAM_VERSION_PIN` or `CI_TOOLS_VERSION` in `lib.sh`, or editing any CI
  script or workflow, produces a different key, so stale downloads are never reused
- `restore-keys: upstream-<version>-` still allows a partial reuse after a script edit;
  every restored file is re-verified against the pinned sha256, so a stale cache entry
  can only ever be discarded, never silently trusted

## Running a stage locally

The scripts need no GitHub-specific tooling; `GITHUB_OUTPUT` and `GITHUB_STEP_SUMMARY`
are optional, and `CI_OUTPUT_ENV` turns stage outputs into a `KEY=VALUE` file that the
next stage can load.

```sh
export CI_TMP_ROOT=/tmp/ci
mkdir -p "$CI_TMP_ROOT"

CI_OUTPUT_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/resolve.sh
CI_RESOLVE_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/fetch.sh
CI_UPSTREAM_VERSION="$(sed -n 's/^upstream_version=//p' "$CI_TMP_ROOT/resolve.env")" \
  CI_KERNEL_PACKAGE="$(sed -n 's/^kernel_package=//p' "$CI_TMP_ROOT/resolve.env")" \
  bash scripts/ci/assemble.sh
bash scripts/ci/verify.sh
bash scripts/ci/report.sh
```

`lib.sh` falls back to `shasum -a 256` when `sha256sum` is absent, so the scripts also run
on macOS.
