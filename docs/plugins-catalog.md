# Plugin recipes we have run

**English** | [简体中文](plugins-catalog.zh-CN.md)

This page is the short list of plugin recipes that were measured on a real machine: one
declaration per section, the steps that were run, and what came out. The mechanism - the fields
of `plugin.conf`, the four commands, the three guardrails - is [plugins.md](plugins.md), and
nothing here repeats it. The list exists so that a second person does not have to start from the
field table and guess.

A recipe is a declaration plus the notes a person needs before running it. Being listed here
means the recipe was run end to end on the reference machine and the outcomes written below were
observed there. It means nothing else: not that we endorse the source, and not that the source
will still answer tomorrow.

## The catalogue

| Recipe | `kind` | Default | Installs | Sources | Key | In one sentence |
| --- | --- | --- | --- | --- | --- | --- |
| [`istore`](#istore) | `packages` | `enabled = no` | `luci-app-store`, and the 16 packages its own dependencies pulled in the same transaction | three `packages.adb` indexes under `https://istore.istoreos.com/repo-apk/all/` | yes, `/etc/apk/keys/istore-apk.pem` | a third-party app store for OpenWrt, off until someone turns it on |

The "Installs" column is the measured count, not the number of `package` lines: one declared name
is 17 packages in one transaction, and every one of them is a world entry afterwards.

## iStore

**Not endorsed, not enabled.** iStore is a third-party application store for OpenWrt. This
project does not test it, does not support it, and does not switch it on: the recipe ships with
`enabled = no` and stays off until the person who owns the machine turns it on, reads the
verdict, and decides. What follows is the shape of a recipe that worked, not a recommendation.

The declaration, at `/etc/ab/plugins.d/istore/plugin.conf`:

```
api = 1
kind = packages
enabled = no
feed = https://istore.istoreos.com/repo-apk/all/store/packages.adb
feed = https://istore.istoreos.com/repo-apk/all/compat/packages.adb
feed = https://istore.istoreos.com/repo-apk/all/meta/packages.adb
package = luci-app-store
key = /etc/apk/keys/istore-apk.pem
```

### What it does

The store tree publishes three apk indexes - `store`, `compat` and `meta` - and the recipe
declares all three, so a name the store expects from any of them resolves. One declared package
is the whole of what the recipe names: `luci-app-store`. Everything else arrives because apk
resolved it, so a package the store needs from the base feed is installed from the base feed.

Measured on 2026-11-21, on the base this release line ships:

* `plugins check istore` answered `verdict=ok`, with nothing shadowed (`reason=none`);
* `plugins apply istore` installed 17 packages in one transaction;
* after two system updates that each switched slots, the 17 packages were still installed,
  `/etc/config/istore` and `/opt/docker` were still there, and the follow recorded
  `kept=259 dropped=0`.

### Turning it on

The recipe ships with `enabled = no`. Set `enabled = yes` in that file, then three commands: the
key, the check, the install.

```sh
wget -O /etc/apk/keys/istore-apk.pem https://istore.istoreos.com/repo-apk/istore-apk.pem
ab-packages plugins check istore
ab-packages plugins apply istore
```

`check` is the one command that goes to the network; `apply` prints the plan block, asks the one
question every write here asks, and installs nothing until it is answered. To see the file apk
will read before the transaction, `ab-packages plugins repos` prints it.

### The key, first

`key` is a presence check, not an import: with no file at that path the check refuses with
`plugin-key-missing` before it fetches anything. The file is the store's own public key,
published at `https://istore.istoreos.com/repo-apk/istore-apk.pem`. This project does not manage
a keyring and does not import one ([plugins.md](plugins.md#guardrails)), so a feed's assurance is
an `https://` address and whatever apk itself checks - nothing more.

### Risks and what it does not do

* **Versions follow the source.** Nothing here pins a version: what the tree publishes today is
  what `apply` installs and what a later follow maintains. `allow-shadow = no` is the bound. If
  the tree starts offering a *higher* version of a package the world already holds, `check`
  blocks it with `shadow:<name>` instead of letting the next follow move a package nobody named.
* **It writes a conffile of its own.** `luci-app-store` installs
  `/etc/apk/repositories.d/compat.list`. That is the package's own behaviour, not the plugin's:
  the plugin writes nothing under `/etc/apk`, and none of its three feeds appear in any machine
  feed file. It is worth knowing because that file outlives the recipe - remove it if you remove
  the store.
* **The recipe is one URL away from breaking.** A tree that reorganises its paths answers
  something other than `verdict=ok` on the next check, and a feed that stops answering is
  `feed-unreachable`. That is the recipe failing honestly, rather than an install that fails
  halfway.
* **What it does not do.** The store is installed and reachable; nothing about it is supported by
  this project. No dependency handling between plugins, no key import, no GUI, no uninstall. A
  recipe cannot hook a boot, an install or an upgrade step, and `plugins apply` does not write
  `/boot/ab/packages` - one plugin's package list is not the follow's verdict.

### Turning it off

```
enabled = no
```

or `rm -rf /etc/ab/plugins.d/istore`. Either one is complete and neither needs a new check. Both
leave the 17 packages installed: they are apk's, and removing one is `apk del <name>`'s job, not
this project's. A switched-off plugin also stops contributing its feeds, so a later follow's
prune can drop a world entry that only this tree offered - the package stays installed, with its
configuration - and turning the recipe back on and checking it again puts the feeds back
([plugins.md](plugins.md#turning-a-plugin-off)).

## Writing your own recipe

A recipe is a declaration, and the field table is in
[plugins.md](plugins.md#the-declaration): eight keys, of which `api`, `kind` and one of
`feed` / `package` are the minimum. The four commands and what each one answers are in
[plugins.md](plugins.md#the-four-commands). Nothing on this page is a template to copy blind -
the fields are a contract and the guardrails apply to a declaration you wrote exactly as they
apply to the one above.

What a recipe of your own has that this list cannot give it is a check. Run
`ab-packages plugins check <label>` before `ab-packages plugins apply <label>`: the first is the
question "is this source usable here at all", and the second is the decision to use it.

## The edge of this catalogue

* **Only what was run is listed.** A recipe someone tried once and did not finish is not here,
  and neither is a declaration that was checked but never applied. The list is short because it
  is measured, not because it is complete.
* **The sources will move.** Every address above answered on 2026-11-21. The answer to "does
  this still work" is `ab-packages plugins check <label>`, not this page.
* **One machine, one release line.** A recipe verified on the reference machine on one base is
  not a claim about another release line, another architecture, or another mirror.
* **Listing is not endorsement.** Inclusion says a recipe ran and what came out; it says nothing
  about whether you should run it.
