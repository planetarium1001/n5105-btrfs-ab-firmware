# ssh-debug — handoff

Owner: `ssh-debug`. Scope: a manual, dispatch-only SSH debugging entry point for the
S4/S5 "upgraded slot never finishes its health check" class of failure, plus the docs and
the design check that keep it from turning into a hidden gate.

Nothing was committed or pushed. `.workflow/**` was not touched. `ci.yml`, `ci-s1..s5.yml`
and `release.yml` are byte-identical to the checkout I received.

## The four conclusions

### 1. Feasibility: yes, with `mxschmitt/action-tmate` pinned to a commit

Verified 2026-11-10 against the upstream repositories, not against memory:

| Route | Verdict |
|---|---|
| `mxschmitt/action-tmate` | **Recommended.** Latest release `v3.24` published 2026-05-29, default branch last pushed 2026-11-06, 3591 stars, `node24` runtime. |
| GitHub's own debugging | Real, but not interactive: `ACTIONS_RUNNER_DEBUG` / `ACTIONS_STEP_DEBUG` secrets or variables, the `runner.debug` context, and a re-run with debug logging (`gh run rerun --debug`, `-d` present in the installed gh 2.101.0). It gives more log, never a shell. |
| `csexton/debugger-action` | **Do not use.** Not archived, but the default branch's last commit is 2020-07-19 (checked via the commits API); it still tells you to `uses: csexton/debugger-action@master`, has its own 15-minute keepalive scheme, and its README credits `mxschmitt/action-tmate` as its ancestor. Six years stale on a floating ref. |

Sources: <https://github.com/mxschmitt/action-tmate/releases/tag/v3.24>,
<https://github.com/mxschmitt/action-tmate/blob/v3.24/action.yml>,
<https://github.com/csexton/debugger-action>,
<https://docs.github.com/en/actions/how-tos/monitor-workflows/enable-debug-logging>.

Pinned to `35b54afac29c97fb54faba5b513f8fbd1882f113` (`# v3.24`), not to `v3`: a third-party
action that runs with the runner's credentials should not be able to change under a moved
tag. `check_design.py debug-ssh` rejects anything that is not `vX.Y.Z` or a 40-hex sha.

### 2. Security: the repository is public, so `limit-access-to-actor: true` is mandatory

`gh repo view --json visibility` → `PUBLIC` (owner `planetarium1001`). Consequences and the
exact semantics, read out of `src/index.js` at the pinned commit:

- **Default is not private.** `limit-access-to-actor` defaults to `auto`, which authorises
  the dispatcher's keys *only if* their GitHub profile has at least one public SSH key.
  With no key on the profile it logs a warning and continues **open to anyone**.
- **`true` is unconditional.** It calls `users.listPublicKeysForUser({username: actor})`
  and writes those keys into `authorized_keys`. `actor` is `github.context.actor`, the
  user who dispatched the run — not the PR author, not a maintainer. Zero keys registered ⇒
  the step throws `No public SSH keys registered with <login>'s GitHub profile` and no
  session exists.
- **`sudo`** (`auto` by default) only affects how the action installs `openssh-client`
  and `xz-utils`; on a hosted runner it is passwordless anyway, and inside the session
  `sudo` is unrestricted — which is the point of a debug shell and also why it is not a
  security boundary.
- **`max-duration` does not exist.** The `action.yml` at v3.24 declares only `sudo`,
  `install-dependencies`, `limit-access-to-actor`, `detached`, `connect-timeout-seconds`,
  `tmate-server-*`, `msys2-location`, `github-token`. The session is bounded by
  `timeout-minutes` on the step and the job. The workflow and the check follow the real
  knob; the check still accepts a future `max-duration`.
- **`continue` is not a parameter either.** It is a *file*: creating `/continue` or
  `$GITHUB_WORKSPACE/continue` makes the action stop waiting and lets the job continue.
  Documented as such in the docs.
- **The web shell URL is not covered by the key check.** If the run log shows
  `Web shell: https://tmate.io/t/...`, treat it as a bearer credential.

Risk verdict for a public repo: with `limit-access-to-actor: true` the SSH string in a
public log is a locator, not a credential — the private key is. The residual exposure is
(a) that web-shell URL if one is printed, (b) everything echoed into the session, and
(c) the fact that anyone with write access can dispatch the workflow *on any branch*, so
`--ref main` is a rule, not a preference. The repository has no Actions secrets
(`gh secret list` and `gh variable list` are both empty), so the shell holds only a
read-only `GITHUB_TOKEN`. Cleanup: `gh run delete <run-id>` removes the public connection
string when the log is no longer needed.

### 3. Environment: no KVM, TCG only, ~55-61 s per uefi-disk boot

- Passwordless `sudo`, `losetup`, `mkfs.btrfs`, OVMF, `qemu-system-x86`, `sfdisk`/`blkid`,
  `btrfs-progs` are all present after one `apt-get install`; the stage workflows already
  prove the exact package list.
- **No usable `/dev/kvm`** on a standard `ubuntu-latest` runner (nested virtualisation is
  offered on Linux *larger* runners, not the standard pool), and the pipeline does not want
  it anyway: `scripts/ci/qemu-smoke.sh:139` hardcodes `-accel tcg`. The debug workflow
  therefore *records* `/dev/kvm` and virt type instead of asserting them.
- Measured from run `42815980945` (2026-11-10) through the jobs API: s4 job 5 min 01 s
  wall clock, its four uefi-disk boots 61 / 55 / 57 / 56 s, checkout→ready image 62 s.
  s5's boot 3 hit its 900 s `CI_QEMU_TIMEOUT` exactly and failed — the default
  `boot_timeout` here is 1200 s for that reason.

### 4. Cost and lifetime

- 6 h is the hard job cap; this workflow sets 200 min on the session step and 240 on the
  job, so a forgotten session cannot reach it.
- Job concurrency is per plan (20 Free / 40 Pro / 60 Team / 500 Enterprise); a live session
  holds one slot. `concurrency: ci-debug-<ref>` with `cancel-in-progress: true` means a
  second dispatch replaces the first instead of queueing a second runner.
- Reconnect works while the job lives: the tmate session outlives an SSH disconnect and the
  same string works again. It dies when the shell session ends, the step times out, or the
  run is cancelled.

## What was delivered

| File | State |
|---|---|
| `.github/workflows/ci-debug.yml` | New. `workflow_dispatch` only (`none`/`build-disk`/`s4`/`s5` + `boot_timeout`), `permissions: contents: read`, pinned tmate, `limit-access-to-actor: true`, 200/240 min bounds, no new shell script. |
| `docs/debug-ssh.md`, `docs/debug-ssh.zh-CN.md` | New. 9 `##` sections each, same structure as `docs/boot-overlay.md`. |
| `docs/README.md`, `docs/README.zh-CN.md` | Index row + `debug-ssh` in the individual-check list. |
| `scripts/check_design.py` | New `check_debug_ssh` (`debug-ssh`): dispatch-only trigger, explicit `permissions`, no write scope, pinned action ref, `limit-access-to-actor: true`, duration bound 1..360 min. |
| `tests/modules/design/test_docs.sh` | Runs `debug-ssh` with the other design checks. |
| `tests/modules/ci/test_pipeline.sh` | `ci-debug.yml` excluded from the stage counts and from the `if: always()` rule — it is not a stage and uploads nothing on purpose. |
| `tests/modules/ci/test_step_env.sh` | Understands the `ci_load_env_file` path (env-file chaining, the documented local interface) and fails if any workflow other than `ci-debug.yml` uses it instead of static `env:` wiring. Previously it flagged ci-debug's 10 stage calls. |

## Why the two test edits are not gate-weakening

`tests/modules/ci/test_pipeline.sh` counts `ci-*.yml` as stages; `ci-debug.yml` matches the
glob by name (which the task fixed) but is not a reusable stage, so it is excluded from the
count, the `workflow_call` count and the `if: always()` rule. `test_step_env.sh` cannot see
values that only exist after `resolve.sh` runs; the debug workflow therefore wires them the
way `scripts/ci/README.md` documents for a local run, and the test now recognises exactly
that mechanism, while a new assertion keeps every *stage* workflow on static `env:` wiring.

## Local verification

```
ruby -ryaml -e 'YAML.load_file(".github/workflows/ci-debug.yml")'   # parses (no PyYAML here)
python3 scripts/check_design.py all                                  # 12 checks ok
./tests/run.sh --module design                                       # 1/0
./tests/run.sh --module ci                                           # 2/0
./tests/run.sh                                                       # 22/0
```

Negative tests of the new check (each mutation applied, verified red, restored, `diff`
confirmed identical): `push` trigger, `@v3` floating ref, `limit-access-to-actor: auto`,
missing duration bound, `contents: write`.

## Two side effects the Lead should know about

1. `scripts/ci/resolve.sh` hashes every `.github/workflows/*.yml` into the cache key, so
   landing this file invalidates the upstream cache once; the next CI run re-downloads
   rootfs/kernel/kmods and then settles.
2. I could not exercise the workflow itself (it needs a dispatch). The scripts it calls, the
   env chaining and the step env wiring are verified statically and by the two module tests;
   the first real dispatch should be `stage=build-disk` on `main` as a smoke test before
   trusting `stage=s5`.

## What the Lead has to decide

- Whether `docs/debug-ssh.md`'s "delete the run afterwards" habit should be a written policy
  in `docs/lifecycle.md` or stays advice in the debug doc. I kept it out of the contract
  docs on purpose.
- Whether to add `stage=assemble`/`stage=s3` later. I stopped at the four the task named;
  adding one is two lines (`options:` plus one `if:`).

## For the user, in one line each

- Trigger: **Actions → ci-debug → Run workflow**, branch `main`, `stage=s4` (or
  `gh workflow run ci-debug.yml --ref main -f stage=s4`).
- First command after connecting: `cd "$GITHUB_WORKSPACE" && ls -l "$RUNNER_TEMP/ci"` then
  re-run the boot by hand with `CI_QEMU_TIMEOUT=1800` (exact block in
  `docs/debug-ssh.md`, "Driving a boot by hand").
