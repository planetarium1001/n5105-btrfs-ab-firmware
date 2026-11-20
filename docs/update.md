# Updating a machine from a feed

**English** | [简体中文](update.zh-CN.md)

This page is the contract for the two things a machine needs in order to update itself
from somewhere other than a USB stick: **a feed it can read**, and **a rule for how far
one update may jump**. It covers the configuration file, the two commands, the prompt you
are asked to confirm, every exit status and every `reason=` token, and how a publisher
builds a feed of their own.

For installing a payload you already have on disk, or for rescuing a machine whose
bootloader write was interrupted, see [install.md](install.md). This page only adds the
part that fetches.

## Before you start

You need a machine that booted a committed slot and passed its health checks: check with
`ab-slot status`, which must report `p4=ok` and a committed slot. You also need a working
network path to the feed.

The device carries no update state of its own. Nothing in this page adds a file to
`ab/state.json`, and nothing here changes how a slot is written: `ab-upgrade --feed`
downloads a payload, checks it, and then hands it to the same validation and installation
code that `ab-upgrade <payload>` runs.

Two things the machine must be able to do, and neither is guaranteed:

* fetch a file over HTTPS. `uclient-fetch` is preferred, then busybox `wget`; if neither
  exists the command refuses with `feed-no-fetcher` instead of failing halfway. On a
  machine without either, a transport can be supplied per run through
  `UPDATE_FETCH_CMD` (see [Configure a feed](#configure-a-feed)).
* write the payload into a directory with room for it. The default is `/tmp/ab-feed`,
  which on this board is memory; `AB_FEED_DIR` points it at a directory on p4 instead.

## The three version numbers

An update is described by three numbers. They are shown side by side because they answer
different questions, and none of them may be guessed from another.

| Number | Where it comes from | What it means | Does it decide the risk level? |
| --- | --- | --- | --- |
| `base` | the release's upstream version, e.g. `25.12.2`; recorded in the slot's `/etc/platform-release` as `UPSTREAM_VERSION` | the ImmortalWrt release underneath: the rootfs, the kernel and the package base all follow it | yes, and only this one |
| `kernel` | the kernel package version of the build, e.g. `6.12.103` | which kernel the payload installs. It usually moves with `base` and sometimes does not | no, it is shown |
| `platform` | this project's own layer, `PLATFORM_VERSION`, e.g. `0.0.8` | how many times we published this project on top of one `base`. It counts our releases, not the system's | no, it is shown |

All three come from one file, `/etc/platform-release`, and both command-line tools print
that same file, so "what am I running" never needs a path in the answer:

```sh
ab-slot --version        # or -V
ab-upgrade --version
```

Both print `PLATFORM_VERSION=`, `UPSTREAM_VERSION=` and `PLATFORM_STAGE=` and nothing else;
neither reads the slot state or needs root. The file stays where it is because `/etc` is
where a machine keeps its own identity (`/etc/os-release` is the same idea), and the
commands are the way a person should have to ask.

A `platform` bump with an unchanged `base` is an ordinary, low-risk update: the platform
layer (the scripts, the defaults, the menu) changes and the system underneath does not.
That is why the number that decides the risk is `base`, and why a prompt that only said
`0.0.8` would be hiding the thing the user needs to know.

The risk level always takes the most severe of the three comparisons: a jump that crosses
both a minor and several patches is a minor jump, not a patch jump.

## Configure an update source

The configuration is one file, `/etc/ab/update.conf`, in the same `key=value` style as
`/etc/net-defaults.conf`. `#` starts a comment.

The image ships one, and it points at this project's own releases:

```
UPDATE_SOURCE=release
UPDATE_RELEASE_REPO=planetarium1001/n5105-btrfs-ab-firmware
UPDATE_RELEASE_BASE=https://github.com
UPDATE_CHANNEL=stable
```

With that file in place a freshly flashed machine answers "is there something newer?"
without any setup, and the baseline it compares against is the newest release of this
project. The `release` source builds
`<UPDATE_RELEASE_BASE>/<UPDATE_RELEASE_REPO>/releases/latest/download/index.txt`, so the
release notes, the payload and its digest are all the published ones - nothing is
generated on the device.

Two things follow from `releases/latest`: it never names a pre-release, so an `-rc` line
needs a feed of its own; and a release published before this feature existed carries no
`index.txt`, so the download answers `404`. A fetcher reports that the same way it reports a
dead network - `feed-unreachable` - and the refusal adds a line saying which releases page
to look at. `feed-index-missing` is the other shape: the source answered, but what came back
is not an `AB-FEED` index (a proxy error page, a directory listing).

A self-hosted feed is the other source, unchanged:

```
UPDATE_SOURCE=feed
UPDATE_FEED_URL=https://example.org/n5105/feed/v1
UPDATE_CHANNEL=stable
UPDATE_VERIFY=sha256
```

| Key | Required | What it does |
| --- | --- | --- |
| `UPDATE_SOURCE` | no, default `release` when no `UPDATE_FEED_URL` is set, otherwise `feed` | which source answers "what is the newest release". `release` follows this project's published releases; `feed` reads `UPDATE_FEED_URL`. An older configuration that only sets `UPDATE_FEED_URL` keeps working as `feed` |
| `UPDATE_RELEASE_REPO` | for `release` | `owner/name` of the repository whose releases are the baseline. Point it at your own fork when you publish your own line |
| `UPDATE_RELEASE_BASE` | no, default `https://github.com` | the prefix the release URL is built from. Point it at a proxy and the rest of the path stays the same: `UPDATE_RELEASE_BASE=https://gh-proxy.example/https://github.com` fetches the same release through that proxy. It must start with `https://` |
| `UPDATE_FEED_URL` | when `UPDATE_SOURCE=feed` | the directory the feed lives in. The device fetches `<url>/index.txt`, and an entry without a `url` of its own is fetched from `<url>/<payload>`. It must start with `https://`; anything else is refused with `feed-conf-url` |
| `UPDATE_CHANNEL` | no, default `stable` | which line of releases this machine follows. The index declares its own `channel` and a mismatch is refused with `feed-index-channel`, so a machine cannot silently take an `edge` release |
| `UPDATE_VERIFY` | no, default `sha256` | how the downloaded file is checked. `sha256` is the only value this release implements; anything else is `feed-verify-unsupported`, reserved for signature checking later |
| `UPDATE_PIN` | no | the newest `platform` version this machine will move to on its own. Written by `ab-upgrade --pin`, removed by `ab-upgrade --unpin`; see [Holding a machine on one release](#holding-a-machine-on-one-release) |

`ab-upgrade --feed-url <url>` overrides `UPDATE_FEED_URL` for a single run, so one command
can try a mirror without editing the file. The file itself must still exist.
`ab-upgrade --release-repo <owner/name>` and `--release-base <url>` do the same for the
`release` source, which is how a fork or a proxy is tried once before it is written down.

`UPDATE_FETCH_CMD` is an escape hatch for a machine whose fetchers cannot do what the feed
needs: if it is set, its value is run as `sh -c "<cmd>" ab-fetch <url> <output>`. It is
what the tests use; it is also how a machine behind an unusual transport is served.

## Check for an update

```sh
ab-upgrade --feed-check
```

This command reads the configuration, fetches the index, and prints what it found. It
writes nothing, downloads no payload, and touches no slot. The first line names where the
answer came from, so a refusal and a comparison can never be confused with each other:

```
source=release feed=https://github.com/planetarium1001/n5105-btrfs-ab-firmware/releases/latest/download
```

When there is an update it prints one machine-readable line whose field order is fixed:

```
platform=0.0.6 platform_available=0.0.8 base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=patch 2 level=Z1 status=update
```

`platform` and `base` are what the running slot carries, `kernel` is the running kernel
(`uname -r`); the `_available` fields are what the newest entry in the index offers. `span`
is the `base` difference as `patch N`, `minor N`, `major N` or `none`; a downgrade reports
the same word with a negative count (`minor -1`) and `level=downgrade`. `level` is the risk
level from [Risk levels](#risk-levels-and-what-each-one-asks-of-you).

`status` says what the machine may do, and it is the field to branch on:

| Output | Exit | Meaning |
| --- | --- | --- |
| `status=update`, `level=Z1` … `X1` | `10` | there is a newer release. The level says how much of the jump is covered by tests |
| `0.0.8 is the newest release (base 25.12.2)` and `status=current` on the next line | `0` | nothing to do. The feed's newest release is the one running |
| the field line with `pin=<version> status=pinned` | `0` | a newer release exists but `UPDATE_PIN` holds this machine |
| the field line with `level=downgrade status=downgrade` | `0` | every entry in the feed is older than what runs here. A check that finds a downgrade is still a successful check; `--feed` is the command that refuses it |

Any refusal (no configuration, an unreachable feed, an index that does not parse) exits
`74` with a `reason=` token and no field line, because there is nothing true to report.

## Install an update

```sh
ab-upgrade --feed
```

The command repeats the check, prints the same field line, then shows the update block and
asks for confirmation. On confirmation it downloads the payload into
`${AB_FEED_DIR:-/tmp/ab-feed}`, checks the file's size and sha256 against the index, and
enters the ordinary installation path: the same manifest, member, kernel-module, free
space, bootloader and conflict checks that `ab-upgrade <payload>` runs. From there the
machine behaves exactly like a local update: the inactive slot is staged, the next boot
tries it, and a failed health check sends the machine back to the slot it came from.

| Flag | Use it when |
| --- | --- |
| `--yes` | the command has no terminal to ask on (a script, a job, an SSH one-liner with no TTY). Without it, a non-interactive run is refused with `feed-noninteractive` instead of waiting for input that will never come |
| `--direct` | a jump that crosses a major line, and you want the newest release in one step |
| `--stepwise` | a jump that crosses a major line, and you want one release per command. The smallest release above the running one is installed; nothing is queued, so every hop gets its own reboot, health check and commit |
| `--force` | the feed's newest release is older than what runs here and you want it anyway. Downgrades are refused with `feed-would-downgrade` without it |
| `--feed-url <url>` | try a mirror for this run only |

`--direct` and `--stepwise` are part of `--feed`; given on their own they are a usage error
and exit `2`. Both flags may appear anywhere on the command line.

The same lines that a local install writes are what this command writes: capture them the
way [install.md](install.md) shows, with the command piped through `tee` into
`/boot/ab/log/upgrade.log`. Refusals are additionally mirrored to the serial console, so a
machine whose only output is a serial line still says why it stopped.

After a successful install the machine has not changed yet: run `ab-slot status` to see the
other slot as `pending` and `next=<slot>`, then reboot. **Before that reboot `pending` is the
target slot, not `none`** - `pending=none` is what the rebooted machine reports once the boot
has committed the switch. A brief that promises `pending=none` before the reboot describes the
state after it, and the acceptance reader who trusts it will call a correct install a failure.
`pending` is also why it belongs with the fields a switch does *not* move when two settled
status lines are compared (see `AB_STATUS_FIELDS_STABLE` in `scripts/device/lib.sh`): an idle
machine answers `none` on both sides of the switch. Packages installed with `apk` are
**not** updated by this path. Aligning them with a new base is a separate operation with
its own commands, because a package that fails to resolve must not roll back a system
update that already passed its checks.

## What the update prompt says

The prompt is three lines of identity followed by three judgement lines. All of it is
written to stdout, so a log capture keeps it, except the `Proceed?` question itself, which
goes to stderr so that it stays visible when stdout is redirected to a file.

```
Update  base     25.12.2 -> 25.12.5
        kernel   6.12.103 -> 6.12.110
        platform 0.0.6 -> 0.0.8
  Change  PATCH ×3   · the entries above are what this update brings
  Tested  YES        · patch range covered in CI
  Risk    LOW        · running system replaced; previous slot is the way back
Proceed? [y/N]
```

The three identity lines are the only place that says *what changes*: each is written
`current -> candidate`, and one that does not move repeats the same number on both sides.
None of the three is inferred from the level.

The three judgement lines answer three different questions, always in this order:

* `Change` describes the **size** of the jump only: `NONE`, `PATCH ×N`, `MINOR +N` or
  `MAJOR +N`. It never claims which members moved; the identity lines above say that.
* `Tested` states **what CI covers**, as a fact and without hedging: `YES`, `PARTLY` or
  `NO`.
* `Risk` states what the coverage gap means here: `LOW`, `REAL`, `HIGHER` or `UNKNOWN`.

The judgement words are a closed vocabulary, always upper case, always separated from the
explanation by `·`. A bracketed note in parentheses is an aside; a bracketed note in square
brackets is a recommendation, such as `[recommended]`. A `Backup` line appears after `Risk`
for the levels that recommend one, and a `Route` line appears only when the update cannot
proceed without a route.

This block describes the system update. From 0.0.13 an install whose payload carries the plan
engine also prints a `Packages` block and `Config` block after it and asks about the follow
with `Proceed and follow N packages? [y/N] ` - one question for both, because the answer to
"replace the system" and "bring the packages along" is the same decision. What those blocks
contain is in [How packages follow a base](#how-packages-follow-a-base).

## Risk levels and what each one asks of you

The level is a statement about **test coverage**, not about the size of the change, and it
is computed from `base` alone. It changes what you are asked, never what the machine does:
every level ends in the same validation and the same write.

| Level | Condition | `Tested` | `Risk` | What you must do |
| --- | --- | --- | --- | --- |
| Z1 | same `base`, patch difference of 3 or less, including none at all | yes, covered | low | confirm with `y` or pass `--yes` |
| Z2 | same `base`, patch difference above 3 | no, outside the covered range | low but uncovered | confirm with `y` or pass `--yes`; a backup is recommended |
| Y1 | same major, minor difference of exactly 1 | partly | real | confirm with `y` or pass `--yes` |
| Y2 | same major, minor difference above 1 | no | higher | confirm with `y` or pass `--yes`; a backup is recommended |
| X1 | a different major | no | unknown | **choose** `--direct` or `--stepwise`; a backup is recommended |

Z1, the platform-only update: `base` and `kernel` do not move and only our layer changes.

```
Update  base     25.12.2 -> 25.12.2
        kernel   6.12.103 -> 6.12.103
        platform 0.0.7 -> 0.0.8
  Change  NONE       · platform layer only; base and kernel left as they are
  Tested  YES        · same-base update covered in CI
  Risk    LOW        · no kernel or package base change
Proceed? [y/N]
```

Z2, a patch jump longer than the covered range:

```
Update  base     25.12.2 -> 25.12.9
        kernel   6.12.103 -> 6.12.110
        platform 0.0.6 -> 0.0.8
  Change  PATCH ×7   · the entries above are what this update brings
  Tested  NO         · span outside the covered range
  Risk    LOW        · patches rarely change behaviour, but uncovered
Backup    ab-backup --help   (recommended)
Proceed? [y/N]
```

Y1, one release line forward:

```
Update  base     25.12.2 -> 25.18.0
        kernel   6.12.103 -> 6.12.140
        platform 0.0.8 -> 0.1.2
  Change  MINOR +1   · a new release line; the entries above are what this update brings
  Tested  PARTLY     · neighbouring lines built together; one cross-line upgrade in CI
  Risk    REAL       · installed packages may need rebuilding for the new base
Proceed? [y/N]
```

What backs `Tested PARTLY`: a minor jump is the one case CI covers by building the previous
formal release and upgrading it with this release's payload. On the tagged line that stage is a
gate - `release.yml` declares `publish: needs: [build, cross]` - so a release whose cross-line
upgrade was not proved is not published ([ci.md](ci.md)).

X1, a new major line. There is no `y` here: the command refuses until a route is chosen,
and prints both routes and the reason.

```
Update  base     25.12.2 -> 26.0.0
        kernel   6.12.103 -> 6.18.2
        platform 0.0.8 -> 1.0.0
  Change  MAJOR +1   · a new major line; the entries above are what this update brings
  Tested  NO         · nothing here crosses a major line
  Risk    UNKNOWN    · the package base may not be compatible
Backup    ab-backup --help   (recommended)
Route     --stepwise   install the next release, one at a time   [recommended]
          --direct     install the newest release in one step
ab-upgrade: refused, reason=feed-route-required
```

`--stepwise` walks the index: it installs the smallest release above the running one, so a
machine several release lines behind makes the same familiar jump repeatedly. If the index
no longer carries a release in between, the command refuses with `feed-no-such-release`
instead of jumping over the gap.

## Holding a machine on one release

`UPDATE_PIN` is an upper bound for the automatic path, not a lock:

```sh
ab-upgrade --pin 0.0.8      # ab-upgrade: pinned to 0.0.8
ab-upgrade --unpin          # ab-upgrade: pin removed
```

Both commands edit exactly one line of `/etc/ab/update.conf`, need no network, and leave
everything else in the file alone. A pin that is not a `MAJOR.MINOR.PATCH` version is
refused with `pin-invalid-version`.

What the pin does:

* `--feed-check` keeps working and reports `status=pinned` with the candidate and the pin,
  exiting `0`: a held machine is not nagged.
* `--feed` refuses with `feed-pinned` when the candidate is above the pin. A candidate
  equal to the pin installs normally.
* `--stepwise` stops at the pin.
* a pin below the running version is not an error: the check adds
  `warning pin-below-installed (UPDATE_PIN=0.0.5, running 0.0.7)`, because the usual cause
  is an operator who upgraded and forgot to move the pin.
* `ab-upgrade <payload>` ignores the pin entirely. The pin exists to stop a machine from
  moving on its own; it cannot stop a person who names a file.

Deleting the line, or `--unpin`, releases the machine. The pin is not written into
`ab/state.json` and does not affect `apk`.

## Package updates

A system update replaces a slot; packages are a separate transaction with a separate way
back. Both live on the writable layer. Bringing the packages onto a new base is part of an
upgrade and asks once ([How packages follow a base](#how-packages-follow-a-base)); the
commands below are the manual side - snapshots and versions you ask for by name.

```sh
ab-slot packages list            # snapshots on this layer, newest first
ab-slot packages snapshot        # record the world and every installed version now
ab-slot packages upgrade         # snapshot, then apk update && apk upgrade
ab-slot packages revert          # replay the newest snapshot's versions
```

`upgrade` refuses to run unless `ab-slot status` reports `packages=aligned` (or
`packages=followed`, which is the same metadata after the follow transaction ran): that field
means the writable layer's `world` pins the kernel this slot runs and `distfeeds` name the
release it runs. Upgrading packages behind a stale pin installs modules for a kernel the
machine is not running.


`packages=` is a verdict about the running slot's metadata, so it can say `unknown` too. The
`packages_reason=` beside it names why:

| `packages_reason=` | What it means | What to do |
| --- | --- | --- |
| `none` | the record speaks for this slot and the aligner ran | nothing |
| a token from the aligner (`payload-incomplete`, ...) | the record speaks for this slot but the aligner could not finish | the message names the step; re-run the system update |
| `other-slot` | the last record describes the *other* slot (a candidate that was installed and then abandoned) | it is honest, not broken: the next `ab-upgrade` rewrites the record, and `ab-slot rollback` retargets it |
| `no-record` | a rollback retargeted the record and there was no verdict for the new committed slot | the next `ab-upgrade` writes one |
| `unknown` | the record is missing or unreadable | re-run the system update |

Until an update or rollback rewrites it, `ab-slot packages upgrade` refuses on `unknown`: a
package transaction is only started when the metadata describes the running kernel and release.

Do the system update first and the package upgrade second. An `apk upgrade` rewrites
`/lib/upgrade/*`, whose names upstream's sysupgrade interface uses too, so the writable layer
would shadow this project's upgrade adapter and the next payload install would fail at
`platform_upgrade_begin`. From 0.0.11 the adapter is loaded from a source a package cannot
shadow, the shadowing copies are moved to `/mnt/p4/ab/shadow-backup-<timestamp>/`, and
`/etc/apk/protected_paths.d/ab-upgrade-adapter.list` keeps `apk upgrade` from rewriting those
paths (the package's copy lands as `*.apk-new` and apk's database still moves). The manual
repair for a machine shadowed before 0.0.11 is in [install.md](install.md).

`apk version -l '<'` answers from the cached index, so a machine that never ran `apk update`
prints an empty table with warnings and a non-zero exit; read the warnings and the exit
status, not the table. A machine on the newest release genuinely has zero candidates.

The counts a snapshot reports are `packages=`, `world=`, `payloads=` and the optional
`payload-gap=`. `payloads=no` means the snapshot was taken without the package archives (`--no-payloads`)
- it is the answer, not a missing one, and there is no second `reason=` field for it: a
`reason=` of `none` says "nothing was limited", and a snapshot that simply has no payloads
says so with `payloads=no`. `packages=` and `world=` say `unreadable` rather than `0` when the
record cannot be counted at all, so a corrupt snapshot and an empty one do not print the
same line.

A snapshot is text in `<layer>/apk/snapshots/` - the base and platform versions, every
world entry, every installed package with its version, and the counts that make the record
self-checking (`packages=`, `world=`, `payloads=`). The newest three are kept.

Alongside the text file the snapshot keeps the packages themselves, in
`snapshots/snapshot-<id>.d/payloads/`, with one `apkfile <name> <sha256>` line per archive: the
repositories carry one version of a package - the newest - so a version list on its own can
only restore what the source still has. `apk fetch` fills the directory at snapshot time,
which costs about 300 MiB and needs the network once. From 0.0.11 the fetch is per package, so
a package the feed no longer resolves cannot fail the whole set; apk-tools 3 rejects a version
pin in `apk fetch`, so the fetch names the package and checks the file it got against the
installed version. A feed that rolled since the machine was updated hands back a newer file for
some packages; those are dropped and counted missing, and the snapshot retries once with a
recursive `apk fetch` before giving up. `--no-payloads` gives a list-only snapshot
(`payloads=no`); `payload-incomplete` means the fetch ran but did not land every archive, so
the snapshot restores by version but not offline.

`revert` prefers the archives: it checks every sha256 against the snapshot, then installs
them in one `apk add` transaction. Local archives are installed with `--allow-untrusted`,
because the device has no keyring for them; the trust here is the digest list inside the
snapshot, written on the same partition, not a signature. A digest that does not match
refuses the whole revert instead of installing half a set. Without archives, `revert`
replays `<name>=<version>` instead - which on apk-tools 3 also writes those versions into
the world, so the machine stays pinned until a later `apk upgrade` is asked for.

Either path is only allowed on the same base: across a base those versions were built
against a different kernel and libc, which is what `ab-slot rollback` is for. A package
that cannot be restored is reported and the rest still go through:
`revert result=partial` names each one and exits 0. When nothing could be restored the
verdict is `revert result=fail` and the exit status is 1; a snapshot with no packages is
`revert result=empty`. A `failed` line names a package, not a cause: what apk said is in
`upgrade.log`. Every verdict also prints `world=<M> matched=<K>`, the number of world
entries and how many of them the snapshot's package set covers.

The package path has reason tokens of its own, printed on the same
`ab-slot: refused, reason=<token>` line:

| Reason | Exit | What it means |
| --- | --- | --- |
| `apk-info-unparsed` | 1 | `apk info -v` printed a line that is not `name-version`, so the snapshot refuses to write a record with packages missing. A machine whose apk prints names only is the defect this catches |
| `revert-payload-mismatch` | 74 | a `.apk` in the snapshot does not match the sha256 recorded in it. Nothing is installed: a set that does not verify is not a set |
| `revert-across-base` | 74 | the snapshot was taken on another base; use `ab-slot rollback` instead |
| `payload-gap` (a line, not a refusal) | - | the snapshot was written without payloads, and this line says why (`apk-fetch-failed`, `payload-incomplete`, `payloads-unwritable`). The manifest is still valid |

The two ways back, side by side:

| You want to undo | Use | What it restores |
| --- | --- | --- |
| the last system update | `ab-slot rollback` | the other slot: its base, its platform layer and its packages |
| a package change on this base | `ab-slot packages revert` | the versions in the snapshot, nothing else |

Both write `upgrade.log`; neither runs by itself.

## How packages follow a base

An update is two actions, and they are kept apart on purpose:

| Layer | When it runs | What it does | What a failure costs |
| --- | --- | --- | --- |
| mechanical alignment | always, inside `ab-upgrade` | writes the new base, points `world` and the feed list at it, judges the tree and prefetches | nothing: it is file work, and it never blocks the boot |
| package follow | by default, after `y` and on the first boot | one `apk upgrade` over the world, so packages built for the old base move onto the new one | only the packages: the machine boots and runs either way |

The follow is automatic, but it is not unconditional. Before the slot is written, `ab-upgrade`
judges three propositions on the tree that will be booted - the pins agree with the base, apk can
solve the transaction, and every local package is classified - and prints the result as a plan
block:

```
Packages
  - follow     39 to follow, 2 held back, 1 replay from local copies
  - gate       2 of 41 entries are held back; the rest can follow
```

**The block is a prediction; the record is the fact.** It is rendered from `apk --simulate` against
a staged copy of the tree, and the feed can change between the question and the boot. What
happened is what `/boot/ab/packages` says afterwards, and every verdict below is read from that
file, never from the block.

There are exactly three ways past the question, and the block names them when something is held
back:

| Answer | What happens |
| --- | --- |
| `y` (or `--yes`) | the base is switched and the packages follow it |
| `--system-only` / `--no-follow` | the base is switched, no package is touched, and the record says `follow=never` |
| `n` (or anything that is not an answer) | nothing is written at all: `ab-upgrade: declined, nothing was written` and exit `0` |

`--dry-run` (the same as `--check`) stops before the first write, and a run with no terminal and
no `--yes` refuses with `reason=noninteractive` and exit `74` instead of hanging. Enter is never an
answer, here as everywhere else.

What the machine then reports lives in one line, `/boot/ab/packages`:

```
packages=aligned reason=network follow=pending upgraded=0 kept=24 skipped=local:htop cache=0 version=25.12.2 kernel=kernel=6.12.103 slot=b hint=ab-packages update
```

`reason=` is the second field and `hint=` is the last, whose value holds a space (`ab-packages
update`), so a script can read either without parsing the middle. `follow=` is the state of the
follow itself:

| `follow=` | Meaning | What changes it |
| --- | --- | --- |
| `pending` | this base still owes a follow: no prefetch, or a transaction that has not run yet | the first boot, or `ab-packages update` |
| `followed` | the packages moved onto this base | - |
| `failed` | a transaction ran and failed, or moved nothing at all; `reason=` says which | `ab-packages update` |
| `abandoned` | the network fallback ran out of time (24 hours) | `ab-packages update` |
| `never` | the user chose a system-only switch | the next upgrade |

`ab-slot status` prints the pair together - `packages=followed packages_reason=none follow=followed
reason=none hint=none` - and, when a follow is still owed, two sentences about it:

```
ab-slot: packages were not followed: no usable network
ab-slot: retry when it is back: ab-packages update
```

That pair is the point: `packages=aligned` alone reads like "all good", and it means only that
the metadata matches the base. The packages are a separate answer.

## Prefetch, and a first boot with no network

The download happens before the switch, while the machine still runs a slot that works. After `y`,
`ab-upgrade` asks the solver which packages the transaction would move and runs `apk fetch` for
exactly those, into the new slot's own cache (`/etc/apk/ab/cache/` in the layer that will be
booted). One follow measured on this board is 3,445,041 bytes over 39 packages - the moving set,
not the 316-package world, because `apk fetch` over the world would pull about 105 MB. The first
boot then installs the prefetched files with no network at all:

```sh
apk --cache-dir /etc/apk/ab/cache --cache-max-age 100000 \
    add --virtual .ab-follow --allow-untrusted --force-non-repository \
    /etc/apk/ab/cache/*.apk
apk del .ab-follow
```

Repository bodies are signed by the index rather than per file, so installing them as files needs
`--allow-untrusted`. The virtual entry exists only around the transaction: `apk del` puts the world
back byte for byte. `--no-prefetch` skips the download and lets the first boot use the network; a
prefetch that fails is not an upgrade that fails - the record falls back to
`packages=aligned reason=network follow=pending`.

The fallback is only used when there was no prefetch. Its probe reads the first four bytes of the
target's index: a captive portal cannot fake the `ADBd` magic an apk index starts with, so `ok`,
`portal` and `offline` are told apart by evidence rather than by an HTTP status. Only `ok` lets a
transaction run:

| Rung | When it retries |
| --- | --- |
| W1 | immediately, then 15, 30, 60 and 120 seconds later (six attempts inside five minutes) |
| W2 | once per `ifup` event, so a cable or a VPN coming up is not ignored |
| W3 | every 30 minutes until 24 hours after the boot, after which the record says `follow=abandoned` |

One worker runs at a time (`/var/lock/ab-packages-follow.lock`), so two apk transactions cannot
interleave, and every attempt writes one `stage=packages-refresh` line to the ring log
(`ab-slot log`). The boot never waits for any of it.

## Why a package did not move

Every package that stayed where it was has one of five reasons, and the reason is written down
rather than guessed. The source of a package is asked of apk (`apk policy`): an answer with a feed
in it is a feed package, an answer whose only source is the installed database is a local one.

| Token | Plan block | Meaning | What the machine does | Where it is written |
| --- | --- | --- | --- | --- |
| `unreachable` | `UNREACHABLE` | the package comes from a source, and that source did not answer | keeps the installed version and the world entry, and retries | `reason=network`, `follow=pending` |
| `local` | `NO COPY` | a local package, and no body was kept | keeps the installed version; reinstall it once to keep a body | `skipped=local:<name>` |
| `stale-abi` | `ABI STALE` | a local body built against another kernel, or one that depends on one | does not replay it: a module that cannot load is worse than an old one | `skipped=stale-abi:<name>` |
| `gone` | `DROPPED` | no source offers it any more, and it is not a local package | removes the `world` entry, leaves the package installed | `dropped=<name>` |
| `pinned` | `PINNED` | pinned in `world` with `=` | leaves it alone, whatever the feed says | `skipped=pinned:<name>` |

The plan block groups the held-back packages under these words, in that order, and the record uses
the same vocabulary, so a line in a log and a group in a block are the same fact.
`ab-packages status` expands them into sentences:

```
ab-packages: held back by the last follow (local:htop,stale-abi:luci-app-x):
ab-packages:   htop: no body was kept, so it cannot be replayed; it stays installed at its version
ab-packages:   luci-app-x: built against another kernel; replaying it would install a module that cannot load
```

`ab-packages sources <name>` answers the neighbouring question - which of this machine's feeds
offers a package, with the full URL, when the plan block had to shorten it. A package nothing
offers and nothing kept is `DROPPED`: the `world` entry goes, the files on disk stay, and the next
`ab-upgrade` no longer tries to follow it.

## Keeping a local package body

A package installed from a local `.apk` file has no source. apk records that it is installed and
never where it came from, and on this machine the body is gone the moment the transaction ends:
`/var` is a tmpfs and the default package cache dies with the boot (measured 2026-11-18:
`find / -name '*.apk'` on a machine carrying four local packages answered nothing). So a machine
that replaces its base cannot put such a package back, and the record says `skipped=local:<name>`
rather than pretending otherwise.

From 0.0.13 the platform keeps a body on request:

```sh
ab-packages replay /tmp/htop-3.3.0-r1.apk    # installs it and keeps the body in the same step
ab-packages replay                           # installs every kept body again
```

Kept bodies live in `/etc/apk/ab/local/<name>-<version>.apk` - on the writable layer, beside
`world` and the apk database, so they ride the generation snapshot and never touch `/data`. The
store keeps one body per name (the highest version), which is also the name the gate looks for when
it asks whether a local package can be replayed.

Four rules bound the store:

* a body whose name a feed starts offering **at a version no older than the body** is
  `superseded`: journalled in `/etc/apk/ab/local/superseded`, then deleted. The feed is the better
  source - it is maintained and follows the base - and `ab-packages status` keeps printing the
  journal line, so the deletion is not silent. A feed that only offers an older version cannot
  replace what the machine runs: the body is kept and the journal gets a
  `kept ... reason=source-older` line instead;
* the store is bounded by `AB_PKGS_CACHE_MAX` (256 MiB by default). Over the bound, the oldest
  bodies that are not the installed version go first: a body the machine runs is the one a replay
  would want;
* a body's identity comes from the package itself, **never from its file name**: `apk adbdump`
  reads the `info:` block of a v3 package, `.PKGINFO` covers a v2/legacy tar, and the file name is
  only consulted on a machine with no apk to ask. So any name (`-x86_64`, `_v1.2.3`,
  `linux-amd64`, ...) can be handed over as it is; renaming is not part of the procedure. A file
  that is not an apk is refused by kind: an ipk answers `reason=asset-format-ipk`, a `.run`
  script answers `reason=asset-format-run`;
* when neither the metadata nor `apk add --simulate` can answer (for example a future apk that
  drops `adbdump`), the identity may be declared:

  ```sh
  ab-packages replay --name minieap --version 0.94.0 /tmp/minieap-0.94.0_x86-64.apk
  ```

  The declaration is never taken on trust: the package's own metadata, or apk's own transaction
  plan, has to agree with it, or the command refuses with `reason=asset-name-mismatch`; when
  neither can answer it refuses with `reason=asset-name-unverifiable`. Both refusals write
  nothing to the store, because a name nobody checked is a name the next upgrade will believe.

A replay is `apk add --allow-untrusted <body>` and nothing else: no `--force-*`, no `--overwrite`.
The trust is the file you kept, because there is no keyring for local archives; the digest list in
a package snapshot is a different mechanism with a different job. apk's protected paths then do the
part that matters for a person: a `/etc/config/*` you edited keeps its bytes and the package's own
copy lands beside it as `*.apk-new` (measured 2026-11-18: `apk upgrade dnsmasq-full` kept an edited
`/etc/config/dhcp` byte for byte and wrote `dhcp.apk-new`). Nothing merges those files for you -
see [troubleshooting.md](troubleshooting.md).

What is out of scope: a body built for another kernel (replaying it installs a module that cannot
load, so it is `stale-abi` and stays installed at its old version), and a base switch - a kept body
replays onto the base it was built for. `/etc/apk/ab/cache/` is the other directory: it holds one
follow's downloads and is emptied when the follow ends.

## The package commands

| Command | What it does | Writes |
| --- | --- | --- |
| `ab-packages status` | the record, the gap list and how long ago the last attempt was | nothing |
| `ab-packages sources [<name>...]` | every feed, or every source that offers a name (`feed`, `customfeeds`, `installed`) | nothing |
| `ab-packages update` | retries the follow: the gate, the plan, one question, one `apk upgrade`, and the record | the record, `/boot/ab/log/upgrade.log` |
| `ab-packages update --only <name>` | retries a single package with `apk upgrade <name>` and measures whether it moved; the record is left alone, because it describes the whole world | no record |
| `ab-packages replay [--yes] [--name <n> --version <v>] [<file.apk>...]` | installs kept bodies, or keeps the file it is handed and installs that; a file no tool can name takes a declared identity, which is checked | `/etc/apk/ab/local/` |
| `ab-packages cache status` / `cache clean` | what one follow left behind, or empty it (kept bodies stay) | the cache |

`ab-packages status` is deliberately offline and read-only: it asks no package manager and needs no
network, because the machine it is asked about may be the one whose packages are broken. Its first
line is facts a script can read, its second one the store and the cache, and everything after that
is the explanation. The time of the last attempt is the record's own write time - the record format
has no timestamp field, and it should not grow one for a fact the file system already keeps.

| Exit | Meaning |
| --- | --- |
| `0` | done, or nothing to do - including `n` at the question, which writes nothing |
| `1` | a transaction failed, or a name's sources could not be answered; the lines above say which |
| `2` | usage error |
| `74` | refused before anything was written (`reason=<token>` on one line) |

## The confirmation prompt

Every question the tool asks has the same shape: `Proceed? [y/N] `, and the package plan
asks the same way with the number in front of it, `Proceed and follow N packages? [y/N] `.
Enter, `n`, `N` and `no` all decline, and a decline is not an error - it prints
`ab-upgrade: declined, nothing was written reason=declined` (or `ab-packages: declined, ...`
for the package commands) and exits `0`. Only `y`, `Y`, `yes` and `YES` accept, and anything
else that is not an answer prints the same line again without moving on. A firmware write
that starts because somebody pressed Enter is a bug, so the safe answer is the default;
scripts pass `--yes` instead of piping a `y`.

`AB_UPGRADE_ASSUME_TTY=1` exists only for the test suite, which runs without a terminal: it
makes the prompt read stdin as if one were attached. It does not change which answers
accept, but it does bypass the `feed-noninteractive` refusal - so a pipeline that sets it can
reach the prompt where it would otherwise be refused. Nothing in this project sets it.

## Field reference

Every fact about a slot is published on a surface, and a field is verified by reading the
surface it comes from:

- `/boot/ab/state.json` - slot state, the single source of truth
- `/boot/ab/packages` - the one-line package record the last upgrade published
- `/boot/ab/log/` - the ring log, printed by `ab-slot log`
- `/proc/cmdline` and `/proc/mounts` - the slot this boot came from, and what is mounted

`<slot>` below is `a` or `b`, `<version>` is an upstream release such as `25.12.2`, and
`<layer>` is the writable layer name, `@overlay-<version>` with `-r<N>` appended when that
version is used a second time.

### The state file

`ab/state.json` is the truth; `boot/grub/ab-slot.cfg` is the hint GRUB can read. The hint holds
two commands, fallback first, so a write cut short still falls back to the committed slot.

| Field | Values | Meaning |
| --- | --- | --- |
| `generation` | integer, only grows | orders writable layers for reclamation; names none of them |
| `committed` | `a` \| `b` | the slot the machine is committed to run |
| `pending` | `a` \| `b` \| `null` | the candidate the next boot tries, `null` for none |
| `slots.<a\|b>.rootfs` | `<version>` | the upstream release that slot carries |
| `slots.<a\|b>.upper` | `<layer>` | the writable layer that slot boots on |

`generation` moves only in `ab-slot layer`, which is the command an update calls when it stages
a slot. `pending`, `commit`, `abandon` and `rollback` rewrite the file and leave the number
alone.

### `ab-slot status` fields

`ab-slot status` prints one machine-readable line on stdout and a human summary on stderr, so
`ab-slot status 2>/dev/null` is the line alone. The field order is fixed, and the package fields
at the end appear only when `/boot/ab/packages` exists.

| Field | Values | Meaning | Verify on the machine |
| --- | --- | --- | --- |
| `slot=` | `a` \| `b` | the slot this boot runs, from `ab.slot=` on the kernel command line; the committed slot when that is absent | `grep -o 'ab.slot=[ab]' /proc/cmdline` |
| `upper=` | `<layer>` | the writable layer of the running slot | `cat /boot/ab/state.json` and `btrfs subvolume list /mnt/p4` |
| `generation=` | integer | the layer ordering number | `cat /boot/ab/state.json` |
| `committed=` | `a` \| `b` | the slot the state commits | `cat /boot/ab/state.json` |
| `pending=` | `a` \| `b` \| `none` | the candidate the next boot tries | `cat /boot/ab/state.json` |
| `p4=` | `ok` \| `degraded` | `/mnt/p4` is mounted | `awk '$2=="/mnt/p4"' /proc/mounts` |
| `data=` | `ok` \| `missing` | `/data` is mounted | `awk '$2=="/data"' /proc/mounts` |
| `docker=` | `ok` \| `missing` | `/opt/docker` is mounted | `awk '$2=="/opt/docker"' /proc/mounts` |
| `swap=` | `ok` \| `missing` | `/swap` is mounted | `awk '$2=="/swap"' /proc/mounts` |
| `next=` | `a` \| `b` \| `unknown` | what GRUB will boot, read back from the hint file | `ab-slot next` |
| `disk=` | a device node, or `unknown` | the disk this machine booted from | `ab-slot log \| grep stage=device` |
| `method=` | `cmdline` \| `partuuid` \| `partname` \| `mount` \| `unique` \| `unresolved` \| `unavailable` | how that disk was established | the same `stage=device` line |
| `boot=` | `ok` \| `degraded` \| `unknown` | how this boot started, read from this boot's ring log | `ab-slot log \| grep stage=boot` |
| `esp=` | `ok` \| `dirty` \| `unreadable` \| `unknown` | the initramfs' verdict on the ESP it mounted | `ab-slot log \| grep stage=esp-health` |
| `packages=` | `aligned` \| `limited` \| `followed` \| `unknown` | whether the slot's package metadata describes the base it runs | `cat /boot/ab/packages` |
| `packages_reason=` | an aligner token, `none`, `no-record`, `other-slot`, `unknown` | why that verdict is what it is | `cat /boot/ab/packages` |
| `follow=` | `pending` \| `followed` \| `failed` \| `abandoned` \| `never` \| `unknown` | whether the packages were actually moved onto this base | `ab-packages status` |
| `reason=` | `none`, `network`, `timeout`, `no-evidence`, `apk-<rc>`, `no-world`, `no-apk`, `no-packages`, `feeds-rewritten`, `no-record`, `other-slot`, `unknown` | why the last follow attempt ended the way it did | `ab-packages status` |
| `hint=` | `ab-packages update` \| `none` | the command that retries the follow | `sed -n 's/^.* hint=//p' /boot/ab/packages` |

Three values are claims a machine must not make without evidence, so they read `unknown`
rather than a comfortable default: `boot=`, `esp=` and `packages=`.

### Reading a field in a script

One function reads most of the line. The `^` anchor matters: without it `reason=` also matches
`packages_reason=`.

```sh
ab-field() { ab-slot status 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p"; }
ab-field pending
ab-field follow
```

`hint=` holds a space, because its value is a command, so it is the last field of the record and
it has its own reader:

```sh
sed -n 's/^.* hint=//p' /boot/ab/packages
```

A field that names a slot's version has its own command, and it does not read the status line at
all:

```sh
ab-slot rootfs a
ab-slot rootfs b
```

## Exit status

| Exit | Meaning |
| --- | --- |
| `0` | nothing to do, or nothing done: `--feed-check` found the running release or a pin, the check found only a downgrade, or `--pin` / `--unpin` succeeded. An answered `n` at the prompt also exits `0`, having written nothing |
| `1` | a step failed after the checks passed, for example a full download directory or a missing library. The payload, or the machine, got past validation and something then broke |
| `2` | usage error: an unknown option, `--direct` or `--stepwise` without `--feed`, or a second payload argument |
| `10` | `--feed-check` found a newer release. This is not an error and not a success: it is the answer to the question, so a script can branch on it |
| `74` | refused before anything was written. The line is `ab-upgrade: refused, reason=<token>` and the token is in the table below |

The exit codes of the local install path (`0`, `1`, `74`, and what a refusal leaves on the
disk) are in [install.md](install.md).

## Reasons

Every refusal names one token, and the token is stable across releases, so a script or a
runbook can match on it. The line is always
`ab-upgrade: refused, reason=<token>`, and a `1` prints `ab-upgrade: failed, reason=<token>`.

| Reason | Exit | What it means and what to do |
| --- | --- | --- |
| `no-feed-config` | 74 | `/etc/ab/update.conf` does not exist. The image ships one; a machine without it had it removed, and the command will not guess a source |
| `feed-conf-missing-url` | 74 | the file exists but has no `UPDATE_FEED_URL` |
| `feed-conf-source` | 74 | `UPDATE_SOURCE` is neither `release` nor `feed`. A typo'd key is reported as a key, not as an unsafe address |
| `feed-conf-repo` | 74 | `UPDATE_RELEASE_REPO` is not `owner/name`, so the release URL cannot be built |
| `feed-conf-url` | 74 | `UPDATE_FEED_URL` or `UPDATE_RELEASE_BASE` is not an `https://` address. An unencrypted feed is refused: the digest in the index only protects the payload if the index itself cannot be swapped in transit |
| `feed-conf-channel` | 74 | `UPDATE_CHANNEL` is neither `stable` nor `edge` |
| `feed-verify-unsupported` | 74 | `UPDATE_VERIFY` names a mode this release does not implement. `sha256` is the only one |
| `feed-index-missing` | 74 | the source answered, but what came back is not an `AB-FEED 1` index: a proxy error page, a directory listing, or an HTML page served in place of the file. A release that simply predates the index answers `404` instead, which reads as `feed-unreachable` |
| `feed-unreachable` | 74 | the index or the payload could not be fetched: no route, no DNS, a `404`, or a transport that exited non-zero |
| `feed-no-fetcher` | 74 | the machine has neither `uclient-fetch` nor `wget`, and `UPDATE_FETCH_CMD` is unset |
| `feed-index-version` | 74 | the index's first line is not `AB-FEED 1`, or `platform` / `base` / `kernel` is not a `MAJOR.MINOR.PATCH` version |
| `feed-index-field` | 74 | a required field is missing, a field is outside an `entry` block, an unknown key appears, or `size` / `sha256` is malformed |
| `feed-index-order` | 74 | entries are not in strictly newest-first order. The publisher broke the ordering rule; the device refuses the whole index rather than sorting it, because a sorted view would hide a feed that stopped being maintained |
| `feed-index-channel` | 74 | the index declares a different `channel` than this machine follows |
| `feed-payload-missing` | 74 | the download finished but the file is not there |
| `feed-size-mismatch` | 74 | the downloaded file is not the size the index promises, so nothing is installed and the partial file is deleted before the refusal is printed |
| `feed-digest-mismatch` | 74 | the downloaded file's sha256 is not the index's. This is a failed download or a tampered file, never a warning, and nothing is installed |
| `feed-download-space` | 74 | the download directory has less than 110% of the payload free. Point `AB_FEED_DIR` at p4 instead of `/tmp` |
| `feed-pinned` | 74 | `UPDATE_PIN` holds this machine below the candidate. `ab-upgrade --unpin`, or `ab-upgrade --pin <newer version>` |
| `feed-would-downgrade` | 74 | the feed's newest release is older than the running one. Pass `--force` if that is really what you want |
| `feed-route-required` | 74 | the jump crosses a major line. Choose `--stepwise` (one release at a time) or `--direct` (straight to the newest) |
| `feed-no-such-release` | 74 | `--stepwise` found no release between the running one and the newest: the feed's index has been trimmed. Ask the publisher for the missing release, or use `--direct` |
| `feed-noninteractive` | 74 | there was no terminal to ask on. Add `--yes` to accept the prompt, or run the command from a terminal |
| `platform-release-missing` | 74 | the running slot's `/etc/platform-release` has no `PLATFORM_VERSION` or no `UPSTREAM_VERSION`, so the machine cannot say what it runs. Reinstall the platform layer |
| `feed-library-missing` | 1 | `ab-version.sh` or `ab-feed.sh` is not on the machine: the platform layer is incomplete |
| `pin-invalid-version` | 74 | `--pin` was given something that is not `MAJOR.MINOR.PATCH` |
| `pin-write-failed` | 74 | `/etc/ab/update.conf` could not be rewritten. Check that `/etc` is writable and has room |
| `cannot-create-workdir` | 1 | the scratch directory under `/tmp` could not be created |
| `cannot-create-feed-dir` | 1 | the download directory could not be created. Check `AB_FEED_DIR` |

The reasons a payload can be refused after it is downloaded are the installer's, and they
are listed in [install.md](install.md): from that point the feed path is the local path.

## Back up before a long jump

Z2, Y2 and X1 print `Backup    ab-backup --help   (recommended)`. That line is advice: nothing
calls `ab-backup` for you, because it needs a target medium and the space to hold the package.

This update path can always return to the **previous slot**, because the slot that runs today
is not touched. It cannot return you to the **previous release** once the older release is gone
from the feed, and it cannot bring back files you changed under `/data`. The three products and
the restore decision tree are in [backup.md](backup.md); the transaction and the automatic
revert are in [architecture.md](architecture.md), and an interrupted bootloader write in
[install.md](install.md).

## Build your own feed

A feed is a directory served over HTTPS with two kinds of file in it: `index.txt` and the
payloads it names. Any static host works. GitHub Releases works. Our CI is only the first
publisher, not a requirement.

`index.txt` is line oriented on purpose: a publisher can produce it with `sha256sum` and a
`printf`, and the device can read it with `awk` and nothing else.

```
AB-FEED 1
channel   stable
generated 2026-11-13T00:00:00Z
entry
  platform 0.0.8
  base     25.12.2
  kernel   6.12.103
  payload  n5105-ab-25.12.2-upgrade.tar
  size     20480000
  sha256   3f2a7c1d4e5b8091a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f607182
  url      https://example.org/n5105/feed/v1/n5105-ab-25.12.2-upgrade.tar
end
```

Rules a publisher has to keep:

| Rule | Why |
| --- | --- |
| the first line is `AB-FEED 1` | it is the format version. An unknown one is refused rather than guessed |
| `channel` is declared once, in the header | a machine follows one channel; a mismatch is refused |
| `entry` … `end` wraps each release | fields outside a block are refused, so a truncated file cannot be read as a shorter feed |
| `platform`, `base`, `kernel`, `payload`, `size`, `sha256` are all present | six facts, three of them identities. None is inferred from another |
| `platform`, `base` and `kernel` are `MAJOR.MINOR.PATCH` | the comparison is numeric per segment; a suffix such as `-r1` belongs to a package, not to these fields |
| `size` is the payload's size in bytes and `sha256` is its digest | the device checks both before anything is installed, and treats a mismatch as a failed download |
| entries are ordered newest `platform` first, strictly | the device checks the order and refuses the index otherwise |
| `url` is optional and, when present, absolute | without it the device resolves `payload` against its own `UPDATE_FEED_URL`, which is how one feed can be mirrored |
| `notes` is optional | an entry may carry a link for a human, such as the release page. The device parses it and does nothing else with it |

The `kernel` field is the kernel **version** (`6.12.103`), not the kernel package
(`6.12.103~<source hash>-r1`): the package suffix changes on every rebuild and says nothing
about which kernel runs.

Producing one from the release directories the pipeline already writes:

```sh
scripts/ci/feed-index.sh --out /srv/feed/v1/index.txt \
  --channel stable \
  --base-url https://example.org/n5105/feed/v1 \
  --release /srv/releases/v0.0.8 \
  --release /srv/releases/v0.0.7
```

Each `--release` directory is one published release and must contain `release-notes.md`
(which records the platform, upstream and kernel versions), `SHA256SUMS` and the payload
tar it lists. The stage sorts the entries itself, so the directories may be given in any
order. It re-hashes every payload and refuses a directory whose `SHA256SUMS` disagrees with
the file beside it, because a published index that does not match its payload is worse than
no index at all.

`scripts/ci/release.sh` runs this stage for you and adds `index.txt` to the artifacts of
every release for which it knows the kernel version, so a release is a feed entry without
anyone maintaining a list by hand. Passing earlier release directories through
`CI_FEED_HISTORY` puts them in the same index and gives `--stepwise` somewhere to step.

Two things a feed cannot do yet: it is not signed (`UPDATE_VERIFY` has room for a signature
mode and nothing implements one), and the digest it carries is only as trustworthy as the
HTTPS connection it arrived over. That is the same trust a browser download from a release
page gives you, and it is why the feed address must be `https://`.
