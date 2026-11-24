# Plugins: declared package sources

**English** | [简体中文](plugins.zh-CN.md)

This page is the contract for adding a package source to a machine by writing a file, and for
what that source may do once it is there. It covers the declaration's fields, the four
`ab-packages plugins` subcommands, the three guardrails, what a source that does not answer
means, and how to switch the whole thing off again.

A package update is a transaction with its own way back ([update.md](update.md)). A plugin is
how a machine gets a source that the release feed does not carry - without editing
`/etc/apk/repositories.d`, and without anything of the plugin's own ever running.

## What a plugin is

A plugin is a directory holding one declaration; a check leaves one more file beside it.
Nothing else is read:

```text
/etc/ab/plugins.d/<label>/plugin.conf     the declaration, written by a person
/etc/ab/plugins.d/<label>/.verdict        written by `plugins check`, never by hand
```

`<label>` is the directory name, and it is what every command calls the plugin. It must match
`[a-z0-9][a-z0-9_-]*`: the label ends up in a message, on an apk command line as
`plugin:<label>`, and in a path under `/tmp`, so it is limited to characters that need no
quoting anywhere.

The directory sits under `/etc/ab`, which is the upper layer. A system update replaces the
system tree and does not move `/etc/ab`, so a declaration survives an upgrade and no upgrade
carries one along from a payload.

**A plugin is data, not a program.** It cannot add a step to an install, a hook to the boot, or
a command to the upgrade path; the whole vocabulary is "some apk feeds" and "some package
names". That is a deliberate limit rather than an unfinished feature: what a plugin can do
wrong is bounded by what it can say, and nothing a plugin declares runs before, during or after
an upgrade.

There is exactly one way a plugin reaches apk. For each apk call, one repositories file is
assembled under `/tmp`:

- the machine's own feed files, in apk's order: `repositories.d/*.list`, then `distfeeds.list`,
  then `repositories`;
- the feeds of every plugin a transaction may read.

apk reads that file top to bottom, and the base has to win a tie. That is why the plugin lines
come last.

Those machine files are read and never written. Nothing here edits `/etc/apk/repositories.d` or
`distfeeds.list`, so the aligner and the follow keep seeing exactly the base they were built to
see; a plugin source cannot turn a world entry into `gone` by disappearing. And with no plugin
declared, the apk command line is byte for byte the one this machine ran before plugins existed
- `--repositories-file` appears only when a plugin contributes a feed.

The file that is passed to apk lives in a directory `mktemp` creates (mode `700`) and is removed
with the command that needed it. A fixed name under `/tmp` would be a name another user can
place a symlink at, and this tool opens that file as root.

## The declaration

```text
api = 1
kind = packages
enabled = yes
feed = https://example.org/packages/packages.adb
package = luci-app-example
```

| Key | Required | Values | What it means |
| --- | --- | --- | --- |
| `api` | yes | `1` | the contract this file implements. A declaration written for a later api is refused rather than read half-way |
| `kind` | yes | `source`, `packages` | what it contributes. `source` contributes feeds; `packages` names packages to install, and may carry feeds as well |
| `enabled` | no, default `yes` | `yes`, `no` | the switch. `no` keeps the plugin out of every transaction without deleting anything |
| `feed` | for `kind = source`; repeatable | one `http(s)://` URL, no blanks | one apk repository, written the way the machine's own feed files write it: the index URL, `.../packages.adb`. A bare directory also works where the server publishes the index under the name apk asks for; the index URL is the form this project has run on a machine |
| `package` | for `kind = packages`; repeatable | `[A-Za-z0-9][A-Za-z0-9._+-]*` (an apk package name) | one name that `plugins apply` installs |
| `key` | no | `/etc/apk/keys/<name>.pem` | the key the feed is meant to be checked with. This release only checks that the file is present; it never imports a key |
| `arch` | no, default `noarch` | `noarch` | the only value there is. A feed published per architecture is refused; see [Guardrails](#guardrails) |
| `allow-shadow` | no, default `no` | `yes`, `no` | whether a feed that offers a higher version of a world package may be admitted |
| `allow-kmod` | no, default `no` | `yes`, `no` | whether a feed or a package may be a kernel-module tree |

Two rules about the file itself, and both exist for the same reason: a declaration that says
something the machine does not implement must not read as a declaration that works.

* an unknown key is a refusal with `plugin-unknown-key`, not a line that is skipped. A
  `package =` misspelt as `pakage =` would otherwise install nothing and say nothing, which is
  the failure this rule prevents;
* a key that may appear once may appear once, `plugin-key-duplicate`. Only `feed` and `package`
  repeat.

`#` starts a comment, blank lines are ignored, and the spaces around `=` are a convention
rather than a syntax - the parser trims both sides.

The static rules also bound values, not just key names. Each of these is a refusal:

- a label that is not `[a-z0-9][a-z0-9_-]*`;
- an `api` that is not `1`, a `kind` outside the two, an `enabled` that is neither `yes` nor
  `no`;
- a `kind = source` with no `feed`, or a `kind = packages` with no `package`;
- a URL that is not `http(s)`, or that carries a blank;
- a `package` that is not an apk package name;
- a key path outside `/etc/apk/keys/`, or a key file that does not exist.

Each has its own token in [Reason tokens](#reason-tokens). A declaration wrong in two ways
always answers with the same first one, so a script can branch on the answer.

The two value rules are worth their own sentence, because both exist to keep a declaration from
meaning more than it says:

* a `package` value is a *word on an `apk add` command line*. `package = -X` is a repository
  option, and `package = --allow-untrusted` is the one trust check apk still makes;
* a name with a blank in it is two names. None of them is a package, and each is
  `plugin-package-invalid`;
* a `feed` value becomes one line of the repositories file, and apk splits that line on blanks.
  A URL with a blank in it is therefore two sources, the second of which was never judged, so a
  blank is refused with `plugin-feed-scheme`.

## The four commands

```sh
ab-packages plugins list                 # what is declared, and what the last check said
ab-packages plugins check [<label>...]   # the network stage: is the feed there, does it shadow
ab-packages plugins apply <label>        # plan block, question, one apk transaction
ab-packages plugins repos                # the repositories file a transaction would read
```

| Command | What it answers | What it writes | Goes to the network |
| --- | --- | --- | --- |
| `list` | one line per declaration with a fixed field order: `label kind enabled checked reason feeds packages`, or `plugins=none` when nothing is declared | nothing | no |
| `check` | the static rules, then one HEAD per feed, then apk's own answer to "does this source offer a higher version of something the world holds?" | the verdict file | yes, and it is the only command that does |
| `apply` | installs the packages the declaration names, in one transaction, behind the same plan block and question every write here uses | apk's own state, the world entries included; not `/boot/ab/packages` | no, beyond what apk itself does |
| `repos` | the file a transaction would read, printed as it would be written: the machine's own feeds first, then the admitted plugin feeds | nothing (one file under `/tmp`, deleted when the command returns) | no |

`list` is a table because the questions people ask of it are about the columns: is it on
(`enabled=`), was it checked (`checked=`), and if it was refused, why (`reason=`). A row looks
like this:

```text
label=istore kind=packages enabled=no checked=stale reason=none feeds=1 packages=1
```

`repos` is the debugging and evidence command: it prints the file so that "the source is in"
and "the source is out" are things you can look at, rather than an inference from a package
that did not appear. It also prints one line of explanation on stderr, saying how many of the
lines above came from plugins.

`ab-packages sources <name>` is where an attribution shows. A source that belongs to the feed of
an enabled plugin is printed as `source=plugin:<label>` instead of `source=feed`, so a package
from somebody's own tree is never read as one the release ships. With nothing declared, the
command asks exactly what it always asked.

apk is the one that answers, and apk only knows the files under `/etc/apk` - where a plugin's
feeds are, by design, in no file. So when a plugin contributes, the same question is asked a
second time against the file a transaction would read: the machine's own feeds, then the
plugin's. The two answers are merged.

`apply` follows the rule every other write in this project follows. It prints the plan block and
asks the one question every write here asks: `Proceed and follow <n> packages? [y/N] `, with
`<n>` the number of packages the declaration names. Only `y` (or `--yes`, for a script) starts
the transaction, and a decline writes nothing and exits `0`.

A declaration that names no package answers `plugin-nothing-to-install` and exits `0`. A
source-only plugin is a working plugin, and there was simply nothing to install.

`apply` is bound by the static rules and by nothing else. The shadow question and the
reachability probe belong to `check`: they are questions about the *follow*, which moves
packages nobody named, while `apply` moves exactly what was written down.

So naming a plugin in `apply` is the decision to run it. The packages are installed from the
feeds that declaration names, whether or not a verdict exists for it.

`plugins check <label>` first is what makes that decision an informed one rather than the only
reading available. The plan block names the plugin and every package before the question is
asked, so the transaction is never wider than what was on the screen.

| Exit | Meaning |
| --- | --- |
| `0` | done, or nothing to do |
| `1` | a transaction failed; the line before it carries apk's status as `apk-<rc>` |
| `2` | usage |
| `74` | refused before anything was written |

Nothing here writes `/boot/ab/packages`. That record is the verdict of a whole-world follow
([update.md](update.md)); one plugin's package list is not that sentence.

The world is a different file, and `apply` does reach it - through apk, not by itself. `apk add`
records every name it installs in `/etc/apk/world`, which is how apk remembers that the name was
asked for. The transaction `plugins apply` runs is an `apk add` like any other.

So a package a plugin installed has a world entry from that moment on. What happens to it when
the plugin is switched off is in [Turning a plugin off](#turning-a-plugin-off).

## check is the only time this machine goes to the network

No transaction asks whether a feed is reachable or whether it shadows something. It reads a
verdict that a check wrote. That is what keeps the upgrade and follow paths offline and free of
timeouts, and it is why `check` is the one command with a wall-clock cap
(`AB_PLUGINS_CHECK_TIMEOUT`, 180 seconds by default).

What a check does, in this order:

1. the static rules of the previous section. A declaration that cannot be used never costs a
   request.
2. one HEAD request per declared feed, with the same fetcher and the same timeout the follow's
   own probe uses. A feed that does not answer is `feed-unreachable`, and the check stops there:
   there is nothing left to compare.
3. `apk update` into a cache under `/tmp`, then `apk policy` over the bare names the world
   holds, both against the repositories file this plugin would contribute to.
4. which source wins is apk's own business, so the ordering of two versions is asked of apk
   rather than re-implemented here.
5. the verdict, written to `.verdict`:

```text
verdict=ok
reason=none
checked=2026-11-21T03:12:44Z
conf=3f2a7c1d4e5b8091a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f607182
```

The verdict is the answer, not the printed line: it is the file every later transaction reads.
So a check that cannot write it says `plugin=<label> verdict=ok reason=verdict-unwritable` and
exits non-zero.

An `ok` on screen with no file behind it would be a promise nothing keeps, and the next
transaction would read whatever the last one left.

A *blocked* verdict that cannot be written keeps the token it found and gains
`verdict-write=failed` on the same line, because the refusal is still the answer. Only the
record of it is missing.

A plugin's feeds take part in a transaction when three things are true at once: `enabled = yes`,
the verdict says `ok`, and the digest in the verdict is the digest of the declaration as it is
now. Any one of them failing keeps the feeds out, silently, at the apk call - which is what
failing closed has to mean for a step that must not go to the network to decide.

The digest is why **an edited declaration has to be checked again**. Change one line and the old
verdict stops speaking for the file: `plugins list` reports `checked=stale`, and the feeds leave
the repositories file on the very next apk call, with no time wasted and no request made. One
`plugins check` writes a new verdict and the plugin is admitted again.

`checked=` in a `list` row is one of four words:

| Value | Meaning |
| --- | --- |
| `never` | nobody has checked this declaration. It contributes nothing |
| `ok` | the last check admitted exactly this text |
| `blocked` | the last check refused exactly this text; `reason=` carries the token |
| `stale` | a check happened and the declaration has changed since. Nothing contributes until it is checked again |

A stale verdict is not an error state to be repaired by a machine: it is the declaration asking
to be looked at again. And a plugin that has been switched off can still read `stale` or
`never`, because a check does not spend a request, or write a verdict, on a plugin that no
transaction will read.

## Guardrails

Three rules bound what a declared source may be. A plugin cannot grant itself any of them; two
of them are permissions written in the declaration, and the one that remains has no other
value.

`allow-shadow = no` is the default, and it answers the question a plugin source creates: does
it offer a *higher* version of a package the world already holds? If it does, the check blocks
it with `shadow:<name>` and says which name and which two versions.

Why: the follow moves the whole world in one `apk upgrade`. A feed that quietly offers
`htop 3.4` over the base's `3.3` is how a package nobody mentioned moves on the next boot, and
the machine that finds out is the one that just crossed a release.

`allow-shadow = yes` admits the plugin and records `shadow-allowed` instead of `none` in the
verdict, so "this was accepted on purpose" stays on the record. Pinning the base version in the
world is usually the better answer than allowing a shadow.

`allow-kmod = no` is the default. A package whose name starts with `kmod-`, and a feed whose
URL contains `/kmods/`, are refused with `plugin-package-kmod` and `plugin-feed-kmods`.

Why: this device carries its kernel modules in a directory per build
(`releases/<version>/kmods/<build hash>/kmods`), and a module built for another kernel installs
cleanly and then fails to load. The visible damage is not the module; it is the machine that
stops booting after the next base change. `allow-kmod = yes` exists for someone who has read
what that costs and has a reason.

`arch = noarch` is the default and the only value this release accepts. A feed URL that carries
an architecture segment (`/x86_64/`, `/x86_64_*/`, `/i386_*/`, `/aarch64_*/`, `/arm_*/`,
`/mips*/`, `/riscv64*/`) is refused with `plugin-feed-arch`.

Why: a tree published per architecture was built against that architecture's base, and this
project ships one target on one release line. Taking a tree built for another base is the
failure the aligner and the follow exist to prevent, so the default is to refuse rather than to
warn.

Two smaller bounds belong here: `key` must name a file that exists under `/etc/apk/keys/`
(`plugin-key-outside`, `plugin-key-missing`), and there is no way for a declaration to import
one. This system does not manage a keyring, and a plugin cannot make it start.

## When a feed does not answer

There are three different failures, and each has its own answer.

**A feed that does not answer at check time** is a refused check: `plugin=<label>
verdict=blocked reason=feed-unreachable`, exit `74`. The plugin contributes nothing, and
`plugins list` keeps saying so until it is checked again.

**A feed that was fine at check time and is unreachable at transaction time** fails nothing new.
The verdict still says `ok`, the feed is in the repositories file, and apk cannot fetch from it.

The transaction ends exactly the way a follow with no network has always ended: the record keeps
`follow=pending reason=network`, `ab-slot status` prints the two lines that say to retry with
`ab-packages update`, and one line is appended to `/boot/ab/plugins.journal`:

```text
2026-11-21T03:20:07Z plugin-suspended reason=network
```

That line is written only when a plugin was in play: with nothing declared, a failed follow
writes no such line at all. Its presence is therefore the difference between an ordinary
offline follow and one that also owed a plugin's feed - without anyone having to read apk's
output to find out. A journal that cannot be written does not fail anything: it explains a
decision, it does not make it.

**A plugin whose feed file cannot be built** (an active plugin and no writable `/tmp`) fails
nothing new either, and it is not silent. The transaction runs on the machine's own feeds, and
`/boot/ab/plugins.journal` gains one line per apk call that lost the set:

```text
2026-11-21T03:20:07Z plugin-skip reason=tmp-unwritable
```

One command refuses instead of going ahead: the world prune inside the follow. Asked without a
declared feed it cannot tell "this release does not offer the name" from "the plugin's feed
does". Dropping a world entry on half an answer would un-ask a package somebody installed on
purpose, so it answers `prune-unanswerable` and drops nothing.

Neither failure writes `/etc/apk/repositories.d`, `distfeeds.list` or a world entry. The
plugin's feeds live in one file under `/tmp` that is rebuilt for every apk call.

A source that disappears therefore leaves nothing behind in the machine's own package state.
The next transaction with a working network simply reads it again.

## Turning a plugin off

Two ways, and either one is complete:

```text
enabled = no                        # in plugin.conf
rm -rf /etc/ab/plugins.d/<label>     # the whole directory
```

Neither needs a new check. `enabled = no` keeps the plugin out of every transaction on the next
apk call, and a deleted directory has no declaration left to read.

`plugins list` keeps printing a switched-off plugin - a row with `enabled=no` - because
"declared but off" and "never here" are different facts. The second one is not a problem to
fix.

What neither of them does is uninstall anything: the packages are apk's, and they stay
installed. Deleting the directory also deletes the verdict, so a plugin turned back on later
reads `checked=never` and contributes nothing until it is checked again.

**A world entry does not disappear with the switch, and one path can take it away.** The names
`apply` installed stay in `/etc/apk/world`, so a follow keeps maintaining them from whatever
source offers them.

The path that removes an entry is the prune inside the follow (`ab_packages_follow`, run by the
first boot of a new base and by `ab-packages update`). It drops world entries *the release does
not offer*, judged over the feed set a transaction reads.

With the plugin switched off that set no longer holds its feed, so a package that only this feed
carried reads as unoffered and its entry is dropped. The package stays installed, with its
configuration, and `apk add <name>` (or a revert) puts the entry back.

It is the same rule every world entry has always obeyed, and it is why the plugin's feeds are
not a second package state: they decide where a name comes from, not whether the world is
allowed to forget it.

## Undoing what a plugin installed

The plugin layer keeps no state of its own. There is nothing to migrate, nothing to roll back,
and nothing to clean up beyond the directory itself. The packages it installed are ordinary apk
packages in the world, undone with the package tools that were already here
([update.md](update.md)):

| You want | Use | What it does |
| --- | --- | --- |
| the versions from before the install | `ab-slot packages revert` | replays the versions in the newest snapshot. Take `ab-slot packages snapshot` before installing something you may not keep, or there is nothing to return to |
| a kept body, installed again | `ab-packages replay [<file.apk>...]` | installs the bodies kept under `/etc/apk/ab/local/`, or keeps the file it is handed and installs that |
| the whole previous system, packages included | `ab-slot rollback` | returns to the other slot and its own package layer; a base change is this, not a package revert |

`ab-slot packages snapshot` records the machine and, unless told `--no-payloads`, fetches the
bodies a revert would install. That fetch reads the same feed set a follow reads, the plugin
feeds included.

So a package only a declared feed carries gets a body in the snapshot instead of a
`payload-gap`, and the offline way back exists for it too.

None of them removes a package. A package installed from a plugin is not "held" by the plugin
in any way a command could undo selectively: the plugin's name is not recorded on the package,
and the same package could have come from anywhere.

Removing one is apk's own operation: `apk del <name>`, which prints a plan and may take
dependants with it. It is deliberately not something this project does for you.

## An example: iStore

iStore is a third-party application store for OpenWrt. It appears here as the shape of a real
declaration, not as a recommendation. **This project does not endorse iStore, does not test it,
and does not enable it on the device it ships.**

The example is `enabled = no`, and it stays off until the person who owns the machine turns it
on, reads the verdict, and decides. The file is kept at
[examples/plugins/istore/plugin.conf](examples/plugins/istore/plugin.conf); copy it to
`/etc/ab/plugins.d/istore/plugin.conf` on the machine that should have it.

```text
/etc/ab/plugins.d/istore/plugin.conf

api = 1
kind = packages
enabled = no
feed = https://istore.istoreos.com/repo-apk/all/store/packages.adb
package = luci-app-store
```

The address is the shape iStore publishes its store tree under (`.../repo/all/store`) and the
package name is the one its installer installs. Neither is ours, either can move, and this
project cannot make them work - which is what `plugins check` is for. Two things about this shape are worth knowing before copying it:

* a feed has to serve an apk index that the apk on this machine can read. A tree that only
  carries the older package format answers `unverifiable` at check time.
* The plugin then contributes nothing, which is the honest answer to "can this machine use this
  source at all?", rather than an install that fails halfway.
* a mirror that puts an architecture segment in its path (`.../repo/x86_64/...`) is refused
  while `arch = noarch`. The `all` tree fits the guardrail; an architecture tree does not, and
  would need a release of this project that accepts one.

Turning it on looks like this, on a machine you are sitting in front of:

```sh
# set enabled = yes in the file above, then:
ab-packages plugins check istore      # the verdict, on screen, before anything is installed
ab-packages plugins repos             # the file a transaction would read, on screen
ab-packages plugins apply istore      # plan block, question, one apk transaction
```

If the answer is not one you want, `enabled = no` again, or delete the directory. Nothing about
this example is special: it is one declaration among others, and every guardrail above applies
to it exactly as it applies to a plugin you wrote yourself.

## Reason tokens

Every refusal names one token, and the token is stable, so a script or a runbook can match on
it. `plugins check` prints `plugin=<label> verdict=blocked reason=<token>` and exits `74`.

`plugins apply` prints `ab-packages: refused, reason=<token>` and exits `74` before anything is
installed.

| Token | When | What it means |
| --- | --- | --- |
| `plugin-label-invalid` | static | the directory name is not `[a-z0-9][a-z0-9_-]*` |
| `plugin-conf-missing` | static | the directory exists without a `plugin.conf` |
| `plugin-syntax` | static | a line that is not `key = value` |
| `plugin-unknown-key` | static | the declaration uses a key this release does not have |
| `plugin-key-duplicate` | static | a key that may appear once appears twice |
| `plugin-api-unsupported` | static | `api` is missing or is not `1` |
| `plugin-kind-invalid` | static | `kind` is neither `source` nor `packages` |
| `plugin-enabled-invalid` | static | `enabled` is neither `yes` nor `no` |
| `plugin-no-feed` | static | `kind = source` with no `feed` |
| `plugin-no-package` | static | `kind = packages` with no `package` |
| `plugin-feed-scheme` | static | a feed that is not an `http(s)://` address, or one containing a blank |
| `plugin-feed-kmods` | static | a feed whose URL contains `/kmods/`, and `allow-kmod` is not `yes` |
| `plugin-feed-arch` | static | a feed whose URL carries an architecture segment, and `arch = noarch` |
| `plugin-package-kmod` | static | a `kmod-*` package name, and `allow-kmod` is not `yes` |
| `plugin-package-invalid` | static | a `package` value that is not an apk package name: an `-option`, or two names in one |
| `plugin-key-outside` | static | `key` is not a path under `/etc/apk/keys/` |
| `plugin-key-missing` | static | the file `key` names is not there |
| `feed-unreachable` | check | a declared feed did not answer |
| `unverifiable` | check | apk could not answer, or there is no fetcher. Recorded as blocked, never as "no shadow" |
| `shadow:<name>` | check | the feed offers a higher version of `<name>` than the base does |
| `shadow-allowed` | check | the same, with `allow-shadow = yes`. The verdict is `ok` |
| `verdict-unwritable` | check | the check could not write `.verdict`; the question was answered but nothing will read the answer, and the check exits non-zero |
| `plugin-disabled` | check | `enabled = no`; nothing was fetched and no verdict was written |
| `plugin-nothing-to-install` | apply | the declaration names no package; exit `0`, nothing to do |
| `apk-<rc>` | apply | the transaction failed, with apk's own exit status |
| `plugins-lib-missing` | any | the plugin library is not on this machine |
| `plugins-lib-stale` | any | the package library on this machine is older than the command; re-install the platform layer |
| `plugins-repos-unwritable` | repos, check, apply | the repositories file could not be written under `/tmp` |

## What this does not do

What is out of scope is as deliberate as what is in it:

* **no code.** A plugin cannot hook a boot, an install, a health check or an upgrade step. The
  next levels of this idea - files and hooks - are not in this release, and nothing here
  pretends they are.
* **no dependency handling between plugins.** No ordering, no version constraints, no
  "plugin B needs plugin A". apk solves each transaction it is given; a plugin that would need
  another is a declaration that names what it needs as packages.
* **no trust chain.** A `key` is checked for presence only. This project does not import
  signing keys, does not verify a feed's signature, and HTTPS is the only assurance a feed has.
* **no catalogue and no market.** A plugin is a file you wrote or copied, with a label you
  chose. There is no remote list, no search, no GUI.
* **no editing of the machine's feed files.** `/etc/apk/repositories.d` and `distfeeds.list` are
  read and never written, and `/boot/ab/packages` is not written by `plugins apply`.
* The world is the one file of the package state that does move, and this path is not what
  writes it.
* `plugins apply` runs one apk transaction, and apk records the names it installs in
  `/etc/apk/world` exactly as it does for an `apk add` typed by hand.
* **no silent network.** Only `check` fetches anything, and `apply` runs one apk transaction
  that the person in front of the machine asked for.

For the package follow, the record it publishes and the way back from a package change, see
[update.md](update.md). For what to read first when a machine misbehaves, see
[troubleshooting.md](troubleshooting.md).
