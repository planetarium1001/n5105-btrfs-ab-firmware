# Interactive Debugging over SSH

**English** | [简体中文](debug-ssh.zh-CN.md)

## What this entry point is

`ci-debug.yml` is a manual debugging entry point, not a pipeline stage. It installs the
tooling the boot stages install, runs the same `scripts/ci/` stages they run, and then
hands the runner to a session you can log into over SSH. The session is
`owenthereal/action-upterm`, pinned at commit `6c2d60e09009f59cb4c45c88767c78701f14d121`
(v2.8.1).

- Trigger: `workflow_dispatch` only. No `push`, no `pull_request`, no `workflow_call`.
- Gate: none. It grades nothing, renders no verdict, and no other workflow calls it.
  What it publishes is short-lived: the connection details in the run **summary page**, the
  same command as the `debug-session` artifact (one day), and `debug-<stage>-logs`
  (seven days) with the build logs and the guest console of the session's first boot.
- Lifetime: bounded three times -- `timeout-minutes: 10` on the session step,
  `timeout-minutes: 150` on the keep-alive step, which stops itself after 140 minutes even
  if nobody disconnects, and 240 minutes on the job.
- Access: `limit-access-to-actor: true` with `full-access: true`, so only the dispatcher's
  own GitHub SSH keys open the session, and those keys may run commands, transfer files and
  forward loopback ports.

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

The session step runs `owenthereal/action-upterm` with `detached: true`, so it publishes
`ssh-command`, `join-command` and `ssh-config` as step outputs and returns instead of
holding the step open. The step after it writes `ssh-command` into this run's **summary
page**; the next one uploads the same line as the `debug-session` artifact. Both are
reachable from the run page in the browser, and a script can read the artifact without
anybody watching a live log.

**It is upterm, not tmate, and that is deliberate.** tmate's own README states that "the
public tmate servers (ssh.tmate.io) were shut down in July 2025, so tmate no longer works
out of the box". That is what this repository measured: every session attempt hung for its
full timeout because `tmate wait tmate-ready` never became ready. `owenthereal/action-upterm`
is the maintained replacement and keeps the property that matters here -- the session is
authorised by the GitHub keys of the person who dispatched the run. Do not re-introduce a
tmate step: there is no public relay left for it to reach.

The summary block looks like this:

```
## Interactive session
Connect with your own key (limit-access-to-actor):
ssh session:<token>@uptermd.upterm.dev
```

```sh
ssh session:<token>@uptermd.upterm.dev
# or, when the key is not the default one:
ssh -i ~/.ssh/id_ed25519 session:<token>@uptermd.upterm.dev
```

`limit-access-to-actor: true` means upterm authorises only the public SSH keys registered
on the GitHub profile of the user who triggered -- or re-ran -- the run:

- You must have at least one SSH key on your GitHub account
  ([adding a key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)).
  With no key on the profile there is nothing to authorise, and a bot account never has
  one: the action skips an actor without keys rather than opening the session to everybody,
  so a run re-triggered by a bot can publish a command that no key can use.
- Nobody else can use the string, even though the repository is public and the summary and
  the artifact are readable by anyone who can see the run. The string locates the session;
  the private key is the credential.
- `full-access: true` is what makes the session usable for debugging: with it the authorised
  keys can run commands, transfer files and forward loopback ports. It is set here because
  watching a stalled boot is not a debug session, and because the job holds nothing worth
  protecting (see Security below).
- The summary and the artifact carry `ssh-command` only. The action also publishes
  `join-command` and `ssh-config` outputs, which carry the same token; the workflow copies
  neither of them, and all three should be treated as one credential -- do not paste any of
  them anywhere.

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
  it: the session step is bounded to 10 minutes, the keep-alive step to 150 minutes and it
  stops itself at 140, the job to 240.
- **What the action itself declares.** `action-upterm` v2.8.1, at the pinned commit, has
  inputs `limit-access-to-actor`, `limit-access-to-users`, `allow-exec`, `allow-forwarding`,
  `full-access`, `upterm-server` (default `ssh://uptermd.upterm.dev:22`), `known-hosts`,
  `wait-timeout-minutes`, `upterm-version` and `detached`. None of them is a session
  duration: the lifetime comes from `timeout-minutes` on the step (10) and on the job, which
  is what `scripts/check_design.py debug-ssh` asserts and what the comments in the workflow
  say. A bound moved into a shell literal nobody inspects is the same as no bound.
- **`wait-timeout-minutes` is not the session's lifetime.** It is how long the action's post
  step (`post-if: '!cancelled()'`) waits for a guest; in detached mode that wait happens at
  the end of the job. Unset or `0` in detached mode means ten minutes, so the `5` in this
  workflow is a deliberate shortening, not a default.
- **Reconnecting works while the runner is alive**: the session outlives one SSH disconnect
  and the same command can be typed again. It stops working when the session ends, when the
  140-minute bound is reached, or when the run is cancelled. *Unverified:* whether the
  community relay admits a second simultaneous guest, and what that guest would see; do not
  plan around two people watching one session.
- **Ending early, on purpose**: type `exit` in the shell, or close the SSH client, and the
  session is done -- the post step finishes its wait, the keep-alive step sees the session
  gone and returns, and the job tears down. Cancelling the run from the UI works too: the
  keep-alive is gated on `!cancelled()` on purpose, so a cancel frees the runner instead of
  leaving a fresh sleep behind.
- **Closing the laptop is not closing the session**: the connection dropping does not end
  the session on the runner, which stays open and billing. The bound above, and cancelling
  the run, are what actually stop it.
- **Cost**: a session occupies one of the plan's concurrent jobs (20 for Free, 40 Pro,
  60 Team, 500 Enterprise) for as long as it is open. A forgotten session costs runner
  minutes and, on a busy day, blocks a real run.
- **Residue**: the runner is a disposable VM, so the machine does not survive the job. What
  survives is the run's **summary page** with the SSH command, the `debug-session` artifact
  (one day) holding the same command as a file, and the `debug-<stage>-logs` artifact
  (seven days) holding the boot evidence. After a session that mattered, delete the run once
  the logs are no longer needed: `gh run delete <run-id>` (or delete it from the UI).
- One session per branch: the `concurrency` group is `ci-debug-<ref>` with
  `cancel-in-progress: true`, so a second dispatch replaces the first instead of
  queueing two interactive runners.

## Security

The repository is **public** (`gh repo view --json visibility` reports `PUBLIC` on
2026-11-10), and that decides most of this section.

| Question | Answer |
|---|---|
| Is a session connectable by anyone by default? | Not with this workflow. The action gates the guest through its `limit-access-to-*` inputs, so `limit-access-to-actor: true` is what turns the string into "useless without the dispatcher's key"; it is set unconditionally here, and the check fails if it is removed. |
| Who can dispatch this workflow? | Only users with write access to the repository. Everyone else cannot start a session. |
| Who can connect to a session? | Only the GitHub SSH keys of the user who triggered or re-ran the run. Not the author of a merged PR, not another maintainer, unless they dispatched it themselves. Bot accounts carry no keys, so an actor without keys yields a session nobody can open. |
| What does `full-access` add? | The authorised keys may run commands, transfer files and forward loopback ports, so the session is a real shell and not a spectator view. It is only granted together with `limit-access-to-actor`, and it is granted inside a VM that is destroyed afterwards. |
| What does the session hold? | A read-only `GITHUB_TOKEN` (`permissions: contents: read`), the checkout, and the build scratch. The repository has no Actions secrets, so there is no secret to leak from the runner. |
| Who else is in the path? | The default relay, `uptermd.upterm.dev`, is a community service run by a third party: it brokers the connection and can see it. `upterm-server` and `known-hosts` point the action at a host you control instead, and **self-hosting is the hardened option** -- it is the only arrangement where the relay is not somebody else's machine. |
| What leaks anyway? | The SSH command itself (summary page and `debug-session` artifact), the step log lines that print the token, the serial logs and every command typed in the session, all public in the run log. Once the session is open the command is a credential for whoever owns the authorising keys. Treat "public log" as the default assumption, never paste an export that contains a secret. |
| Can it be widened? | Only by editing the workflow. `sudo` is unrestricted on hosted runners, so the session can install anything -- inside a VM that is destroyed afterwards, which is why this is a debugging tool and not a security boundary. |

Two rules follow from the table:

1. Dispatch from `main`, never from a branch you would not let run arbitrary code.
2. After a session, delete the run when its log is no longer needed -- the summary and the
   artifacts go with it.

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
