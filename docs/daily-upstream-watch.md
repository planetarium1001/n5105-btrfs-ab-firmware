# Daily upstream watch

**English** | [简体中文](daily-upstream-watch.zh-CN.md)

The daily watch ([`upstream-watch.yml`](../.github/workflows/upstream-watch.yml)) is the automatic
release line: it discovers a new formal ImmortalWrt release, builds it through the ordinary
pipeline, moves the pin, merges, tags and publishes - all inside one run graph, because a commit or
a tag pushed with `GITHUB_TOKEN` starts no workflow of its own. What the watch is and how the two
release lines differ is in [ci-release-lines.md](ci-release-lines.md); this page is the runbook:
when it runs, how to read a run, how to rehearse one, how to recover a failure, what it needs, and
what it costs.

## When it runs

The trigger is a schedule in [`upstream-watch.yml`](../.github/workflows/upstream-watch.yml):

```yaml
on:
  schedule:
    - cron: "0 16 * * *"
```

`0 16 * * *` is 16:00 UTC, which is midnight in Beijing. That is the nominal time, and it is not
the time the run starts: GitHub's `schedule` trigger is best-effort and starts late when its queue
is busy. Measured on this repository, runs queued for the 20:00 UTC cron this workflow used to
declare actually started here:

| queued for 20:00 UTC on | started (UTC) | delay |
|---|---|---|
| 2026-11-11 | 2026-11-12T00:48 | +4.8 h |
| 2026-11-12 | 2026-11-13T00:34 | +4.6 h |
| 2026-11-13 | 2026-11-14T00:34 | +4.6 h |
| 2026-11-14 | 2026-11-14T23:30 | +3.5 h |

That is a delay of 3.5 to 4.8 hours, and it is why the cron now names 16:00 UTC instead of 20:00
UTC: with the same delay the build lands around 04:00 Beijing instead of mid-morning. 04:00 is an
expectation, not a guarantee - a late queue can still start the run later, and a day whose queue is
empty can start it earlier. The workflow's own comment records the measurement and the target.

Two smaller facts about the trigger:

- the schedule is read from the default branch, so a change to the cron takes effect only after it
  is merged;
- `workflow_dispatch` can start the same graph at any time, which is what a rehearsal and a
  recovery use (sections 3 and 4).

## The three outcomes

One run is one of three shapes. Which one it was is visible from the run list and the job list, and
the run page says it in the job graph.

| Outcome | The graph | How it reads |
|---|---|---|
| A new release | `detect` -> `bump` -> `build` -> `locks` -> `merge` -> `publish` | green run, `bump/build/locks/merge/publish` all ran, a bare `<X.Y.Z>` tag and a release exist afterwards |
| Nothing new | `detect` only | green run, every other job is `skipped`, no branch, tag or release was created |
| Failure | any job fails or is cancelled | red run, and one issue titled `[auto-release] <version>` labelled `auto-release` |

The jobs behind the first shape, in the order they run:

- `detect` finds the newest formal upstream release and compares it with the pin, and also reports
  the merge state (the pin in the base branch, the merge commit, the tag);
- `bump` edits only `.github/upstream-pin.conf` on `auto/upstream-<version>` and opens or updates a
  pull request against the base branch; it never pushes to `main`;
- `build` calls [`ci.yml`](../.github/workflows/ci.yml) with `upstream_version=<the new release>`,
  so the same five stages prove the new base in this same run;
- `locks` derives the three lockfiles from the fetched upstream files, commits them to the branch,
  and asserts the committed files with `CI_LOCK_STRICT=1`;
- `merge` reads the merge state, guards the diff (exactly four files may change), squash-merges the
  pull request with the branch deleted, and pushes an annotated bare `<X.Y.Z>` tag at the commit
  the API reports for that pull request;
- `publish` calls [`release-publish.yml`](../.github/workflows/release-publish.yml) with
  `tag-policy: bare` - the same implementation and the same preflight the tagged line uses.

Two things about this graph are worth knowing before reading a run page:

- the automatic line's `publish` waits for `detect` and `merge`, so a green watch run proves the
  build and the merge, not that the release installs over the previous one. The two upgrade gates
  ([`ci-upgrade-gates.yml`](../.github/workflows/ci-upgrade-gates.yml), `cross` and `same-base`) are
  wired into the tagged line's [`release.yml`](../.github/workflows/release.yml), whose `publish`
  needs `[build, cross, same-base]`;
- `skipped` means two different things. On a quiet day every job except `detect` is `skipped` and the
  run is a success; inside a gate, a skipped proof is not a passed one and the gate fails.

The commands that answer the three questions:

```sh
# which runs happened, newest first - the "did it do anything today" answer
gh run list --workflow upstream-watch.yml --limit 5

# one run in detail: which job ran and how each ended
gh run view <run-id> --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'

# a release that a green run created
gh release view <version> --json tagName,isDraft,publishedAt,assets

# the one place a red run writes
gh issue list --label auto-release --state open
gh run view <run-id> --log-failed
```

A quiet day also answers "is the watch still alive": when nothing has happened for 50 days the
`heartbeat` job pushes a `heartbeat-YYYYMM` tag, which is activity for GitHub without being a `v*`
tag. It shows up in the tag list:

```sh
git ls-remote --tags origin 'heartbeat-*'
```

## Rehearsing a run

A rehearsal dispatches the same workflow with a forced version, `dry-run` on, and a scratch base:

```sh
gh workflow run upstream-watch.yml --ref main \
  -f version=25.12.1 \
  -F dry-run=true \
  -f base=rehearsal/upstream-watch
```

`-F` is used for the boolean input; `-f` would pass the string `"true"` to a boolean field.

| Input | Default | What it does |
|---|---|---|
| `version` | empty | treat this formal release as the new one instead of discovering it. Validated like the pin: `X.Y.Z`, upstream major at least 25. Required when `resume` is set |
| `dry-run` | `false` | rehearse: `merge` skips the squash merge and the tag, and `publish` creates a draft release instead of a published one |
| `base` | `main` | the branch the pull request is opened against and merged into. While `dry-run` is on, `bump` refuses `main` or `master`, so a rehearsal has to name a scratch base |
| `resume` | empty | `merge` or `publish`: continue a failed run (section 4). Empty means "discover the release" |

The forced version must not already be the pin: `detect` refuses that with "the forced version is
already the pin; nothing to rehearse", and points at `resume` for a release that already merged.
Rehearse a formal version the pin does not name, for example the previous one.

What a rehearsal does, job by job: `detect` accepts the forced version instead of discovering one;
`bump` opens `auto/upstream-<version>` and the pull request against the scratch base, creating the
base branch from this run's commit when it does not exist yet; `build` runs the ordinary pipeline
for that upstream release; `locks` derives and commits the three lockfiles and asserts them;
`merge` reads the merge state and guards the diff, and then **skips both the squash merge and the
tag** - the run summary prints which of the two was skipped and why; `publish` uploads and checks
the bytes and creates a **draft** release.

What a rehearsal does not do:

- it does **not** merge: the scratch base branch is not moved, and no pull request is merged;
- it does **not** push a tag: the remote tag set is byte for byte the same before and after.

What it can leave behind, and how to clean it up:

| Left behind | Cleanup |
|---|---|
| `auto/upstream-<version>` and an open pull request | `gh pr list --head auto/upstream-25.12.1`, then `gh pr close <number> --delete-branch` |
| the scratch base branch, when the rehearsal created it | `git push origin --delete rehearsal/upstream-watch` |
| one draft release | `gh release delete 25.12.1 --yes` |

A draft release does not create a tag, so `--yes` alone is enough to remove it; `--cleanup-tag` is
only needed for a release whose tag exists. Never delete a `v*` tag to tidy up a rehearsal: `v*`
tags belong to the other release line, and its releases are not rehearsal leftovers.

A rehearsal is repeatable: the same dispatch replaces the branch it created last time, the lockfile
steps are no-ops when the files already describe the release, and `publish` deletes and recreates
the draft rather than refusing (it refuses only if the version already exists as a **published**
release, which a rehearsal can never produce).

## Recovering a failure

A red run opens or updates one issue, `[auto-release] <version>`, labelled `auto-release`, and the
issue body carries the failed jobs, the run URL and the two recovery scripts. Read three fields
before choosing one:

| Field in the issue | Means |
|---|---|
| `base pin` | the pin the base branch currently carries. Equal to `<version>` means the squash merge already landed |
| `merge commit` | the commit the pull request was merged as, when it is known |
| `tag pushed` | whether the remote tag already exists, and at which commit |

The same three facts can be read without the issue, because they are exactly what the read-only
`merge-state` subcommand prints:

```sh
bash scripts/ci/upstream-watch.sh merge-state 25.13.0
```

**Before the merge** - the base branch does not carry the pin and the tag does not exist. The run
can be repeated from the start; a recovery dispatch is told which release it is recovering, so it
does not rediscover one:

```sh
gh workflow run upstream-watch.yml -f version=25.13.0 -f resume=merge
```

`resume=merge` re-runs the whole graph for that version. It is idempotent, so repeating a step that
already succeeded is safe: the branch push uses `--force-with-lease`, the lockfile steps do nothing
when the files already describe the release, the squash merge is skipped when the base branch
already carries the pin, and a tag that already names the merge commit is left alone.

**After the merge** - the base branch pins the version, or the tag exists. There is no starting
over: `detect` would see the pin already at that release, and a plain re-run cannot undo a squash.
Finish the publishing half instead:

```sh
gh workflow run upstream-watch.yml -f version=25.13.0 -f resume=publish
```

`resume=publish` skips discovery, reports the state it continues from (`mode=resume`, `base pin`,
`merge commit`, `tag pushed`), reuses the merged pin and the pushed tag, and does not merge or tag
again. It is safe to repeat for the same reason: an existing tag that names the merge commit is a
no-op, and an existing published release is uploaded over (a draft is promoted).

**When the release itself is wrong** - the squash merged the wrong content, or the tag must be
replaced. That is the one path where a tag is deleted, and it is a manual act:

```sh
gh release delete 25.13.0 --yes --cleanup-tag   # removes the release and its tag
git revert --no-edit <merge-commit>
gh workflow run upstream-watch.yml -f version=25.13.0
```

The workflow never deletes or force-pushes a tag, and `resume=merge` refuses a release whose tag
already exists.

**The idempotency rule.** A tag in this repository is immutable. If a tag with the version already
exists and names a different commit than the merge the workflow is about to publish, the run fails -
`merge-state` stops with "tags are immutable, refusing to force one" - and the tag is never moved or
overwritten. That is also why a recovery is dispatched with the same version rather than with a new
one: the version identifies the merge and the tag the recovery continues from.

## Preconditions

The watch uses no secret; everything below is repository or organisation configuration that has to
be true for the automatic line to work at all.

- **The repository is public.** A scheduled workflow in a public repository is disabled after 60
  days without repository activity, which would switch the automatic release line off silently.
  That is the only reason the `heartbeat` job exists: after `CI_HEARTBEAT_INTERVAL_DAYS` (50 by
  default) without a heartbeat tag, a release tag or a commit touching the pin, it pushes
  `heartbeat-YYYYMM`. The name is asserted against `^heartbeat-[0-9]{6}$` and the workflow refuses
  to push anything matching `v*`, so a heartbeat can never start a release.
- **The default `GITHUB_TOKEN` has write permission.** Settings -> Actions -> General -> Workflow
  permissions must allow read and write. Each job narrows the grant to what it writes
  (`contents: write`, `pull-requests: write`, `issues: write`), and a repository or organisation
  default of read-only makes `bump` fail at the push or the pull request.
- **`main` does not require checks a token-created pull request cannot satisfy.** A branch, pull
  request or tag pushed with `GITHUB_TOKEN` starts no workflow (GitHub's recursion guard), so a
  required status check on `main` would never report and `gh pr merge` would wait forever; a
  required approving review has the same effect unless someone gives it. Branch protection that
  requires neither is compatible with the watch.

## Cost and rollback

Every job that runs steps carries a `timeout-minutes` budget. The watch's own jobs:

| Job | Ceiling |
|---|---|
| `detect` | 10 min |
| `heartbeat` | 10 min |
| `bump` | 10 min |
| `locks` | 45 min |
| `merge` | 15 min |
| `issue` | 10 min |

`build` has no ceiling of its own because it calls a reusable workflow; it inherits the pipeline's.
The five-stage pipeline measured 18 minutes end to end (run `43708356221`, S5 being the longest
single stage at 17 minutes). `publish` inherits `release-publish.yml`'s 35 minutes.

So a green run costs what its path costs:

- **nothing new**: one `detect` job. The three scheduled runs of the previous graph took 8 to 14
  seconds each - the cheapest possible proof that the watch is alive;
- **a new release**: the build of the new base (18 minutes measured) plus `locks`, `merge` and
  `publish`. Summing the ceilings above is the worst case, not the expected one;
- **a tagged release** additionally pays the two upgrade gates, which the watch does not run: the
  cross gate's 35-minute job ceiling and the same-base gate's 25-minute one.

**Rolling back a released version.** A tag is a published fact, and this repository does not move
tags - `merge-state` exists to refuse exactly that. The two supported moves are:

- **Roll forward.** Revert the squash commit on the default branch to restore the pin and the three
  lockfiles, and correct the release with the next one: the tagged line takes a new `v*` tag, the
  upstream line takes the next formal upstream release. The published tag and release stay as
  history. Reverting does not make the same version releasable again: the tag still names the old
  merge commit, so a later run for that version stops at the tag check instead of re-releasing it.
- **Delete a tag by hand, deliberately.** Only when the tag and the release are wrong, and only as a
  human act: `gh release delete <version> --yes --cleanup-tag`, then revert the squash, then
  dispatch a normal run. The workflow never does this on its own.

If the release a user already installed is wrong, the fix is a new version, not a retracted one:
installed machines never look up a tag that used to exist.
