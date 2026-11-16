# Release lines

**English** | [简体中文](ci-release-lines.zh-CN.md)

A firmware release leaves this repository along one of two lines. The **tagged line** releases
our own version: you push a `v0.0.9` tag and a release appears. The **upstream line** releases
a new ImmortalWrt base: the daily watch notices a new formal upstream release, builds it, moves
the pin, merges and publishes under the bare upstream version (`25.13.0`).

The two lines differ in how they are triggered and in what the tag has to prove. They do not
differ in what publishing means: both call
[`release-publish.yml`](../.github/workflows/release-publish.yml) and it runs
[`release-preflight.sh`](../scripts/ci/release-preflight.sh) before anything is created. Two
callers and one implementation is what keeps the two lines from drifting, and it is why a
release made by the watch is checked the same way as one made by hand.

The tagged line adds two gates to that check: its `publish` job waits for the cross-version
upgrade and for the same-base upgrade as well as for the build. `release.yml` declares
`publish: needs: [build, cross, same-base]`; the cross gate on its own, `needs: [build, cross]`,
does not prove the same-base claim the update prompt makes. A tag whose gate is red, or skipped
because no previous formal release could be found, creates no release at all. The upstream line
gates its publish on the merge instead; it runs neither gate.

## The two lines side by side

| | Tagged line | Upstream line |
|---|---|---|
| Trigger | push of a `v*` tag (`release.yml`) | `schedule` (`0 16 * * *`), or `workflow_dispatch` of `upstream-watch.yml` |
| Tag shape | `v<X.Y.Z>`, for example `v0.0.8` | bare `<X.Y.Z>`, for example `25.13.0` |
| `VERSION` | the tag must equal it: the tag without its `v` is the platform version being released | not edited by the release; it must still carry the platform version the image records |
| Which upstream is built | the pin in `.github/upstream-pin.conf`; no version input is passed | the release `detect` just found, passed to `ci.yml` as `upstream_version` |
| Build | `ci.yml`, called with `workflow_call` | `ci.yml`, called with `workflow_call`, in the same run |
| Publishing entry | `release.yml` calls `release-publish.yml` with `tag-policy: v` | the watch's `publish` job calls it with `tag-policy: bare` |
| Release title | `N5105 AB firmware {tag}` | `ImmortalWrt N5105 A/B firmware {tag}`; the publisher derives it from `tag-policy`, neither caller passes a title |
| Assets | `n5105-ab-<upstream>-install.img.gz`, `n5105-ab-<upstream>-install-wan-ssh.img.gz` (tag builds only), `n5105-ab-<upstream>-upgrade.tar`, `SHA256SUMS` | the first, the third and `SHA256SUMS`; no convenience image |
| Where a failure lands | the run on the tag goes red; nothing is published and the tag stays | one Issue titled `[auto-release] <version>`, labelled `auto-release` |

The asset names carry the upstream base and the role, never our own counter, and both lines
produce them with the same script (`scripts/ci/release.sh`). `release-notes.md` is written next
to them and becomes the release body, so the notes are the text above the assets, not another
file to download.

### The convenience image

A tag build produces two disk images instead of one. They differ in a single rendered value,
`NET_WAN_SSH`, which decides whether the firewall gets one `allow_ssh_wan` rule (`22/tcp`) on
the WAN side; the kernel, the rootfs, the platform layer and the update payload are the same
bytes in both. `scripts/ci/release.sh` turns that into a distinguishable name by appending
`-wan-ssh`, so a downloads page can never offer "the image with the port open" under the name
of the one without it.

| Where the second image comes from | What it is called |
|---|---|
| the `Derive the convenience image` step of `ci-s3.yml`, on every build | Actions artifact `image-install-wan-ssh`, file `n5105-ab-image-wan-ssh.img.gz` inside it |
| `release.sh` with `CI_VARIANT_IMAGE=<the variant build>` | `n5105-ab-<upstream>-install-wan-ssh.img.gz` |

The variant job deliberately runs `boots: false`: the two images differ in one rendered file,
so the boot assertions (S2, S3 acceptance) are proved once, on the shipped default. The
convenience image is a way in for a machine that cannot be reached from the LAN, not a second
product line - and it is the reason the default could be closed at all.

`dry-run: true` is the rehearsal switch of the publisher: every step runs, the bytes are uploaded
and checked, and the release is created as a **draft** instead of a published one. A draft is
never published by the run that made it. On the upstream line a rehearsal also skips the two
steps that would merge and tag, so it cannot move a branch or push a tag - the full behaviour and
the cleanup commands are in [daily-upstream-watch.md](daily-upstream-watch.md). The tagged line
has no `dry-run` input of its own: a tag either publishes or publishes nothing.

## What the tag has to prove

A tag is a claim, and the preflight is where the claim is checked. `release-publish.yml` mounts
the image, proves the initrd inside it is the production one, and then runs the preflight -
all of it before `gh release create`; a refusal is a non-zero exit, not a warning, and nothing
is created.

Half of that proof runs as separate jobs. The cross-version stage builds an image from the
previous formal release, upgrades it with this release's payload, and requires it to boot,
commit and carry the payload's kernel and initrd. The same-base stage installs this release's
payload over the previous release's own published image and grades that the base and the kernel
did not move. `publish` needs `build`, `cross` and `same-base`, so a red or skipped gate leaves
the tag without a release - the hole that let v0.0.9 publish while cross was red (run
43622253559).

The checks below hold under both policies:

- the image record `ab/image.json` says `"kind": "boot"` - a probe image is refused;
- the published initrd prints `S3 boot init` and contains no `S1-RESULT` - this one is the
  workflow's own `Verify the image is bootable` step, not the preflight;
- the payload manifest is `ab-payload/1` and names a `rootfs` version;
- the payload tar really carries every member at the recorded sha256;
- the payload carries `boot.tar` with a `grub.cfg` and a GRUB core: an image nothing can
  update is not a release.

`--tag-policy v` (the tagged line) additionally asserts:

- the tag matches `^v[0-9]+\.[0-9]+\.[0-9]+$`;
- the platform version - read from `VERSION` unless the caller passed one - equals the tag
  without its `v`;
- `ab/image.json` records that same `platform_version`;
- `ab/image.json` `upstream_version` equals the payload manifest's `rootfs`.

`--tag-policy bare` (the upstream line) additionally asserts:

- the tag matches `^[0-9]+\.[0-9]+\.[0-9]+$`; a `v` prefix belongs to the other line and is
  refused here;
- `ab/image.json` `upstream_version` equals the tag;
- the payload manifest's `rootfs` equals the tag;
- `ab/image.json` `platform_version` equals the platform version, and the shipped `VERSION`
  file still carries that platform version. In other words the upstream line swaps the base
  and leaves our platform version alone: a release that quietly rewrote the system version
  would rename the platform of every machine that upgrades.

Every disagreement is reported in one pass, as `release-preflight: <reason>` lines, so one run
names every problem instead of the first one. An input that cannot be read at all ends the run
immediately: that is a broken invocation, not a verdict about the release.

The history behind the image checks: v0.0.6 and v0.0.7 published S2's `image-probe`, and every
real machine shut down at the GRUB menu with `S1-RESULT=fail reason=no-device-node`. The
release now takes `image-install` (S3's artifact, the one built with the production initramfs)
and opens it to read its own record before publishing.

## The upstream watch

`upstream-watch.yml` is one run graph, because a commit or tag pushed with `GITHUB_TOKEN`
starts no workflow: "push the bump, let CI build it, let the tag release it" cannot work. The
operation of that graph - when it runs, how to read a run, how to rehearse one and how to recover
a failure - is [daily-upstream-watch.md](daily-upstream-watch.md).

| job | needs | permissions | What it does |
|---|---|---|---|
| `detect` | - | `contents: read` | `scripts/ci/upstream-watch.sh detect` finds the newest **formal** release (`X.Y.Z`; candidates, snapshots and below major 25 are dropped) and reports `changed`, `version`, `current_pin`; `matrix-select.sh` picks the new version plus the three formal releases before it; `heartbeat-tag.sh --dry-run` decides whether a heartbeat is due |
| `heartbeat` | `detect` | `contents: write` | pushes `heartbeat-YYYYMM` when nothing changed and the heartbeat is due. See below |
| `bump` | `detect` | `contents: write`, `pull-requests: write` | edits only `.github/upstream-pin.conf` on `auto/upstream-<version>` and opens a pull request. It never pushes to `main` |
| `build` | `detect`, `bump` | `contents: read`, `actions: read` | calls `ci.yml` with `upstream_version=<new release>`, so the new base is built by the same five stages in the same run |
| `locks` | `detect`, `bump`, `build` | `contents: write` | derives the three lockfiles from the `upstream-files` artifact, commits them to the branch, then asserts **the committed files** with `CI_LOCK_STRICT=1` |
| `merge` | `detect`, `bump`, `build`, `locks` | `contents: write`, `pull-requests: write` | reads the merge state (the pin in the base branch, the merge commit, the tag); skips the squash when the base already pins this version and the tag when it already names the merge commit; guards the diff; squash-merges with the branch deleted; tags the PR's `mergeCommit.oid`. With `dry-run` it reads and guards, then skips both the merge and the tag |
| `publish` | `detect`, `merge` | `contents: write`, `actions: read` | calls `release-publish.yml` with `tag-policy: bare` and the matrix candidates as extra notes |
| `issue` | all seven above | `contents: read`, `issues: write` | runs on `failure() || cancelled()` and writes the one place to look |

**A red run leaves exactly one trace.** The `issue` job titles the issue `[auto-release]
<version>` and labels it `auto-release`. If an open issue with the same title exists it comments
on it instead of opening a second one, and it ends with a non-zero exit so the job is red too.
The body carries the job results and the run URL.

**The heartbeat tag.** A scheduled workflow in a public repository is disabled after 60 days
without activity, which would turn the automatic release line off silently. `heartbeat-tag.sh`
creates `heartbeat-YYYYMM` only when nothing has happened for `CI_HEARTBEAT_INTERVAL_DAYS`
(50 by default), counting the newest of: the last heartbeat tag, the last bare release tag, and
the last commit that touched the pin. The name is asserted against `^heartbeat-[0-9]{6}$` and
the workflow refuses to push anything matching `v*`, because a `v*` tag would start the tagged
line and publish a firmware release built from nothing. The existence check reads tag history,
so that job checks out with `fetch-tags: true` and `fetch-depth: 50`.

**The merge.** The automatic change is a branch and a pull request, and everything is
re-checked before it lands:

- the base already pinning this version means the release happened while this run was
  building, so `merge` stops with `skip=true` and two overlapping runs converge instead of
  merging twice;
- `Guard the diff` allows exactly four files: `.github/upstream-pin.conf`,
  `scripts/ci/initramfs-tools.lock.json`, `scripts/ci/kmod-closure.json`,
  `scripts/ci/runtime-closure.json`. Anything else means the branch carries a change no build
  proved;
- the merge is a squash with the branch deleted, so a rollback is a revert of one commit;
- the tag is annotated and points at the `mergeCommit.oid` the API reports for that pull
  request, not at whatever the base branch points at by then.

**Why the watch declares no `concurrency`.** GitHub cannot nest concurrency groups: calling a
reusable workflow that declares one from a workflow that declares one silently drops the call,
and the job never appears in the run. The workflow this one builds with is `ci.yml`, which
declares one, so the watch declares none. Single flight is not lost - the `merge` job re-reads
the pin from the base branch and stops when the release has already happened.

## Worked example: v0.0.8

The tagged line has completed once. Run `43238859287` (`Firmware CI - release`, `event=push`,
`headBranch=v0.0.8`) ended with twelve jobs, all `success`: the eleven of the pipeline
(`read the platform version`, `resolve upstream`, `static checks`, `fetch upstream`,
`assemble payload`, `S1` to `S5`, `report`) plus `publish / publish the release`.

Release `v0.0.8` came out published, not a draft: `isDraft=false`,
`publishedAt=2026-11-12T14:51:00Z`, titled `N5105 AB firmware 0.0.8`, with three assets:

| Asset | Bytes |
|---|---|
| `n5105-ab-25.12.2-install.img.gz` | 53872414 |
| `n5105-ab-25.12.2-upgrade.tar` | 23500800 |
| `SHA256SUMS` | 193 |

That is the shape of a code-line release: `VERSION` said `0.0.8`, the tag was `v0.0.8`, the
image recorded platform `0.0.8` and upstream `25.12.2`, the preflight agreed with all three, and
the published image is the one S3 built with the production initramfs. `v0.0.8` predates the
convenience image, which is why the list above has three assets: a tag build from now on also
carries `image-install-wan-ssh`.

Both facts can be fetched again:

```sh
gh run view 43238859287 --json name,event,headBranch,conclusion
gh release view v0.0.8 --json tagName,isDraft,publishedAt,assets
```

The upstream line has not published in this repository yet: every tag here is a `v*` tag, and a
release made by the watch carries a bare `X.Y.Z` tag. The command answers it for the day you
read this:

```sh
gh api repos/:owner/:repo/tags --jq '.[].name'
```

## When to use which

**The tagged line** is for releasing our own platform. `VERSION` is the single source of the
version, so bump it and commit that first; the tag then follows from it:

```sh
tr -d '[:space:]' < VERSION
git tag -a "v$(tr -d '[:space:]' < VERSION)" -m "release $(tr -d '[:space:]' < VERSION)"
git push origin "v$(tr -d '[:space:]' < VERSION)"
```

The tag push is what starts the build; there is nothing to dispatch. A tag that disagrees with
`VERSION` is refused by the preflight, and the release never appears.

**The upstream line** is for a new ImmortalWrt base, and normally you do nothing: the `schedule`
names 16:00 UTC and ends successfully when there is nothing new. GitHub starts a scheduled run
late - measured at 3.5 to 4.8 hours on this repository - so it usually lands around 04:00 Beijing;
[daily-upstream-watch.md](daily-upstream-watch.md) is the runbook for the time, the reading of a
run and the recovery of a failure.

```sh
gh workflow run upstream-watch.yml --ref main
```

The inputs exist for a rehearsal and for a deliberate run:

| Input | What it changes |
|---|---|
| `version` | treats this formal release as the new one instead of discovering it; it is validated like a pin, so it must be `X.Y.Z` |
| `dry-run` | rehearses: `merge` skips the squash merge and the tag, and `publish` creates a **draft** release; the `bump` job refuses `main` or `master` as a base when this is on |
| `base` | the branch the pull request is opened against and merged into; default `main` |
| `resume` | `merge` or `publish`: continues a failed run, skipping discovery; it requires `version` |

A rehearsal therefore names a scratch base, and it merges nothing and tags nothing - the scratch
base branch and the remote tag set are unchanged - but it can leave a draft release behind:

```sh
gh workflow run upstream-watch.yml --ref main -f version=25.13.0 -F dry-run=true -f base=rehearsal-25.13.0
```

That draft, the pull request and the two branches are the rehearsal's own leftovers.
[daily-upstream-watch.md](daily-upstream-watch.md) has the commands that remove them, the two
recovery dispatches, and the rule that a tag is never moved.

The command that answers "did the automation do anything today" is the run list of that
workflow; the command that answers "did it fail" is the `auto-release` issue list:

```sh
gh run list --workflow upstream-watch.yml --limit 5
gh issue list --label auto-release --state open
```

Both lines build with [`ci.yml`](ci-pipeline.md), so neither can publish something the five
stages did not prove.
