# Interactive Debugging over SSH

**English** | [简体中文](debug-ssh.zh-CN.md)

## What this entry point is

`ci-debug.yml` is a manual debugging entry point, not a pipeline stage. It installs the
tooling the boot stages install, runs the same `scripts/ci/` stages they run, and then
hands the runner to a session you can log into over SSH.

- Trigger: `workflow_dispatch` only. No `push`, no `pull_request`, no `workflow_call`.
- Gate: none. It grades nothing, renders no verdict, and no other workflow calls it.
  The one thing it publishes is a diagnostics artifact, `debug-<stage>-logs`, kept for
  seven days: the build logs and the guest console of the session's first boot.
- Lifetime: bounded by `timeout-minutes` (200 on the session step, 240 on the job).
- Access: `limit-access-to-actor: true`, so only the dispatcher's own SSH keys open the
  shell.

`scripts/check_design.py debug-ssh` fails the build if any of those stop being true, so
"someone wired it to `push`" is a red design check, not a review comment.

## Measured evidence that it is needed

S1/S2/S3 are green; S4/S5 are not, and their failures need a boot observed from the
inside rather than a longer log. From run `42815980945` (2026-11-10):

| Job | Wall clock | Boot steps |
|---|---|---|
| s4 | 5 min 01 s | boots 1-4 took 61 s / 55 s / 57 s / 56 s |
| s5 | failed | boot 3 used its entire 900 s `CI_QEMU_TIMEOUT`, then failed |

A push-and-wait round trip is roughly ten minutes, and a round trip yields one bit:
pass or fail. A session yields the serial console, the ESP, the loop device and the
chance to try a command before writing any code. The 62 s the s4 job needed from
checkout to a finished disk image is the reason a prepared session is useful: the
expensive part is already done when the shell opens.

## Triggering a session

From the CLI, always from `main`:

```sh
gh workflow run ci-debug.yml --ref main -f stage=s4 -f boot_timeout=1200
gh run list --workflow ci-debug.yml --limit 1
```

From the web UI: **Actions** -> **ci-debug** -> **Run workflow**, branch `main`, pick a
`stage`.

| `stage` | What runs before the shell opens |
|---|---|
| `none` | Tooling only. The cheapest session, for reading scripts and probing the runner. |
| `build-disk` | `resolve` -> `fetch` -> `kmods` -> `esp-prepare` -> `platform-runtime` -> `initramfs` -> `disk` -> the GRUB preflight. Stops before any boot. |
| `s4` | `build-disk`, plus the network fixture and boot 1 (fresh image, commit slot a). |
| `s5` | `build-disk`, plus the upgrade payload, the s5 fixtures and boot 1 (fresh install is healthy). |

`boot_timeout` is `CI_QEMU_TIMEOUT` for that first boot. The default is 1200 s, not the
900 s the stage workflows use, because s5's boot 3 needed more than 900 s.

Dispatching from `main` matters: `workflow_dispatch` runs the workflow file *from the
selected ref*, so a session dispatched on a branch executes that branch's version of
every step below. Only dispatch a ref you would also let run arbitrary commands on a
runner.

## Connecting

The step prints the connection string every five seconds:

```
SSH: ssh <token>@<region>.tmate.io
```

```sh
ssh <token>@<region>.tmate.io
# or, when the key is not the default one:
ssh -i ~/.ssh/id_ed25519 <token>@<region>.tmate.io
```

`limit-access-to-actor: true` means tmate authorises only the public SSH keys registered
on the GitHub profile of the user who dispatched the run:

- You must have at least one SSH key on your GitHub account
  ([adding a key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)).
  With none, the step fails outright: `No public SSH keys registered with <login>'s
  GitHub profile`.
- Nobody else can use the string, even though the log is public. The string is a
  locator, not a credential: the private key is the credential.
- If the log also shows a `Web shell:` URL, treat it as a credential in its own right and
  do not paste it anywhere. It is a bearer link, not covered by the key check.

## What the runner already has prepared

Everything lives under `$RUNNER_TEMP/ci`; the checkout is untouched.

| Path | What it is |
|---|---|
| `${RUNNER_TEMP}/ci/disk/n5105-ab-image.img` | The 514 MiB GPT image the preflight has just accepted. |
| `${RUNNER_TEMP}/ci/initramfs/boot.cpio.gz` | The boot initramfs, with `initramfs/boot/init` and the s3 post script. |
| `${RUNNER_TEMP}/ci/fetch/upstream/kernel.bin` | The upstream kernel GRUB loads from the ESP. |
| `${RUNNER_TEMP}/ci/esp`, `${RUNNER_TEMP}/ci/runtime` | Staged ESP and btrfs runtime closure. |
| `${RUNNER_TEMP}/ci/logs/` | `debug-prepare.log`, `debug-fixtures.log`, `debug-boot1.log`. |

The step summary of the prepare step prints the same paths, so they can be copied
without guessing.

## Driving a boot by hand

The boot is `scripts/ci/qemu-smoke.sh` with the environment the stage workflow
passes; nothing about it is special to CI:

```sh
export CI_TMP_ROOT="${RUNNER_TEMP}/ci"
export CI_KERNEL="${CI_TMP_ROOT}/fetch/upstream/kernel.bin"
export CI_INITRAMFS="${CI_TMP_ROOT}/initramfs/boot.cpio.gz"
export CI_QEMU_DISK="${CI_TMP_ROOT}/disk/n5105-ab-image.img"
export CI_QEMU_MODE=uefi-disk
export CI_JUDGE_PREFIX=""
export CI_QEMU_CASE=manual
export CI_QEMU_TIMEOUT=1800
export CI_QEMU_STOP_PATTERN='^(ab-commit: committed slot=|ab-commit: stage=healthcheck-done .*result=fail|ab-commit: stage=commit .*result=fail|ab-boot: stage=boot result=fail)'
bash scripts/ci/qemu-smoke.sh
```

`CI_JUDGE_PREFIX=""` is what makes the run stop at the pattern instead of asserting a
result: the guest is never asked to grade itself. Then read the image back the way the
stage does:

```sh
export CI_IMAGE="${CI_TMP_ROOT}/disk/n5105-ab-image.img"
bash scripts/ci/grub-render.sh --verify-esp "${CI_IMAGE}"   # slot state vs runtime file
bash scripts/ci/ab-phase.sh --phase commit --slot a --expect-committed a --expect-pending none
bash scripts/ci/s5-phase.sh --phase toolchain --serial "${CI_TMP_ROOT}/qemu/serial-uefi-disk.log"
sudo losetup --find --show --partscan "${CI_IMAGE}"          # mount the ESP by hand
```

The serial log is `serial-<mode>.log` under `CI_QEMU_DIR`, so
`${CI_TMP_ROOT}/qemu/serial-uefi-disk.log` for the boot above. `docs/lifecycle.md`
documents what the probes are supposed to print; `scripts/ci/README.md` documents each
stage's inputs.

To test a hypothesis about the shipped code, edit the file under `scripts/` or
`platform/` and re-run the boot: the image has to be rebuilt (`bash scripts/ci/disk.sh`
with the same environment) for a change inside the guest, while `qemu-smoke.sh`,
`ab-phase.sh` and `grub-render.sh` can be re-run against the same image as often as
needed.

## Session lifetime, cost and cleanup

- **6 hours is the hard cap** on any GitHub-hosted job. This workflow stops well before
  it: 200 minutes for the session step, 240 for the job.
- `action-tmate` v3.24 has **no `max-duration` input** -- its `action.yml` declares only
  `sudo`, `install-dependencies`, `limit-access-to-actor`, `detached`,
  `connect-timeout-seconds`, `tmate-server-*`, `msys2-location` and `github-token`. The
  bound is `timeout-minutes`, which is what the check enforces and what the comments in
  the workflow say.
- **Reconnecting works while the job is alive**: the tmate session outlives an SSH
  disconnect, and the same string works again. It stops working when the shell session
  ends, the step hits its timeout, or the run is cancelled.
- **Ending early, on purpose**: `touch "${GITHUB_WORKSPACE}/continue"` from inside the
  session makes the action stop waiting and let the job finish. There is nothing after
  the session step, so this is the clean way to close it. Cancelling the run from the UI
  also works and is the right move if you simply walk away.
- **Closing the laptop is not closing the session**: tmate is tmux underneath, so a
  dropped connection leaves the session alive and billing. The bound above, and
  cancelling the run, are what actually stop it.
- **Cost**: a session occupies one of the plan's concurrent jobs (20 for Free, 40 Pro,
  60 Team, 500 Enterprise) for as long as it is open. A forgotten session costs runner
  minutes and, on a busy day, blocks a real run.
- **Residue**: the runner is a disposable VM, so nothing survives the job. What does
  survive is the run log, which keeps the connection string forever. After a session
  that mattered, delete it: `gh run delete <run-id>` (or delete the run from the UI).
- One session per branch: the `concurrency` group is `ci-debug-<ref>` with
  `cancel-in-progress: true`, so a second dispatch replaces the first instead of
  queueing two interactive runners.

## Security

The repository is **public** (`gh repo view --json visibility` reports `PUBLIC` on
2026-11-10), and that decides most of this section.

| Question | Answer |
|---|---|
| Is a tmate session connectable by anyone by default? | Yes. `limit-access-to-actor` defaults to `auto`, which restricts access only when the dispatcher happens to have a public SSH key on their profile. This workflow sets `true`, which is unconditional. |
| Who can dispatch this workflow? | Only users with write access to the repository. Everyone else cannot start a session. |
| Who can connect to a session? | Only the dispatcher's registered SSH keys. Not the author of a merged PR, not another maintainer, unless they dispatched it themselves. |
| What does the session hold? | A read-only `GITHUB_TOKEN` (`permissions: contents: read`), the checkout, and the build scratch. The repository has no Actions secrets, so there is no secret to leak from the runner. |
| What leaks anyway? | The connection string, the serial logs and every command typed in the session, all public in the run log. Treat "public log" as the default assumption, never paste an export that contains a secret. |
| Can it be widened? | Only by editing the workflow. `sudo` is unrestricted on hosted runners, so the session can install anything -- inside a VM that is destroyed afterwards, which is why this is a debugging tool and not a security boundary. |

Two rules follow from the table:

1. Dispatch from `main`, never from a branch you would not let run arbitrary code.
2. After a session, delete the run when its log is no longer needed.

## Why it cannot replace the CI gate

A session proves nothing about the repository:

- It has no verdict. `ci-debug` runs with `continue-on-error` on every prepared boot and
  its last step is an interactive shell, so a green run means "the session opened", not
  "the slot committed".
- It is not reproducible. Two sessions on the same commit can see different images,
  because the second one starts from whatever the first one did to the image by hand.
- It does not run on the events that matter. `push` and `pull_request` still go through
  `ci.yml` and its stages, and `release.yml` still builds releases from those stages.
- The graded path stays where it is: the frozen judge lines, the ESP assertions and the
  four gated boots of `ci-s4.yml` / `ci-s5.yml`. A fix discovered in a session becomes a
  commit, and the commit still has to turn those stages green.

A useful habit: use the session to learn *why* boot 3 stalls, write the smallest change
that makes it stop stalling, and let the next push be the proof.
