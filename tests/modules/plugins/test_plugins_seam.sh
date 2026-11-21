#!/usr/bin/env bash
# Module: plugins
# The seam: where a declared feed enters a transaction, and what happens when none does.
#
# The plugin library decides *which* feeds a declaration contributes; this file is about the
# one place they enter `apk`, and about the machine behaving exactly as it did before when
# nothing is declared. The subject is design.md §7 and three acceptances:
#
#   ac-9 zero plugins change nothing. Every apk command line the transaction layer writes is
#        byte for byte the one it wrote before this seam existed, and `--repositories-file`
#        does not appear in a command that never carried it. The gate is the exception the
#        design names: it has always passed one, and here it must still pass exactly one,
#        holding exactly the machine's own feed files.
#   ac-3 the machine's own files are read, never written. `repositories.d/*.list` and
#        `distfeeds.list` are byte for byte what they were after a gate, a prefetch and a
#        follow: a plugin set lives in one /tmp file, not in /etc.
#   ac-7 an unreachable feed does not fail a transaction. The record keeps its existing
#        `follow=pending reason=network`, and one journal line says the declared feed was
#        suspended for this run.
#
# Two more rules are asserted here because they are properties of the same seam:
#
#   * the file a transaction reads is made by mktemp only when a plugin is really in play, and
#     removed with the apk call that read it - so nothing under /tmp is left to be found, and a
#     machine with no plugin leaves nothing at all;
#   * a declared feed that cannot be injected (no writable /tmp) is journalled as `plugin-skip`,
#     and the prune - the one caller that must not guess - answers `prune-unanswerable` instead
#     of dropping world entries on half a source list;
#   * the snapshot's fetch asks the same seam, or a body only a declared feed carries would be a
#     payload gap and the offline revert would have no way back.
#
# Every case runs the library in its own shell (`sh -c`, sourcing packages.sh) with a stub apk
# first on PATH, and every fixture is a temporary directory: nothing here runs apk for real or
# writes outside $tmp.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib_packages="$root/platform/lib/upgrade/packages.sh"
lib_plugins="$root/platform/lib/ab-plugins.sh"
ab_slot="$root/platform/usr/sbin/ab-slot"

for must in "$lib_packages" "$lib_plugins" "$ab_slot"; do
  if [ ! -f "$must" ]; then
    printf 'not ok 1 - %s exists\n' "$must" >&2
    printf '    missing %s\n' "$must" >&2
    exit 1
  fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The seam writes one file per process under TMPDIR. Pointing TMPDIR inside the fixture keeps
# that file where these assertions can read it, and off the machine's /tmp.
TMPDIR="$tmp/scratch"
export TMPDIR
mkdir -p "$TMPDIR"

# The plugin library is sourced here as well: writing a verdict is how a test says "someone
# ran `plugins check` and it passed".
# shellcheck source=../../../platform/lib/ab-plugins.sh
. "$lib_plugins"

# --- the trees ---------------------------------------------------------------
# The shapes the measured image has: the feeds in `repositories.d/` (apk-tools 3), a user's
# own feed that must never be lost, and two worlds whose pins agree (P is asked before any apk
# is run, and a disagreeing pin would stop every case at the first proposition).
base="$tmp/base"
target="$tmp/target"
mkbase() {
  rm -rf "$base" "$target" "$tmp/gate-tmp"
  mkdir -p "$base/etc/apk" "$target/etc/apk/repositories.d" "$target/lib/apk/db" \
    "$target/etc/apk/ab/local" "$tmp/gate-tmp"
  for tree in "$base" "$target"; do
    cat >"$tree/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
libc=1.2.5-r5
htop=3.3.0-r1
WORLD
  done
  printf '%s\n' \
    'https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/base/packages.adb' \
    >"$target/etc/apk/repositories.d/distfeeds.list"
  printf '# add your custom package feeds here\nhttps://pkgs.example.net/x86_64/packages.adb\n' \
    >"$target/etc/apk/repositories.d/customfeeds.list"
}

# base_feeds: the machine's own feed files, in apk's order (repositories.d/*.list, the glob
# sorted, which is the order _packages_feed_files reads them in).
base_feeds() {
  cat "$target/etc/apk/repositories.d/customfeeds.list" \
    "$target/etc/apk/repositories.d/distfeeds.list"
}

# feeds_digest: every feed file the machine ships, with its digest - "ac-3 nothing was
# written" is this value not changing.
feeds_digest() {
  ( cd "$target" && find etc/apk -maxdepth 2 -type f \( -name '*.list' -o -name repositories \) \
      | sort | while IFS= read -r f; do
        printf '%s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"
      done )
}

# --- the plugins -------------------------------------------------------------
site="$tmp/site"
mkdir -p "$site/etc/ab/plugins.d" "$site/etc/apk/keys"
: >"$site/etc/apk/keys/demo.pem"

# mkplugin <label> <<'CONF': one declaration.
mkplugin() {
  mkdir -p "$site/etc/ab/plugins.d/$1"
  cat >"$site/etc/ab/plugins.d/$1/plugin.conf"
}

# --- the stub apk ------------------------------------------------------------
# Answers the shapes the transaction layer reads: `update`'s status, the solver's output,
# `fetch` landing bodies, and `policy` naming a source for every name. Its argv is the
# evidence, so it records the whole line first thing.
bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >>"${APK_CALLS:-/dev/null}"
applet=""
simulate=0
repos=""
fetch_out=""
positional=""
while [ $# -gt 0 ]; do
  arg=$1
  shift
  case "$arg" in
    --repositories-file) repos=${1:-}; shift ;;
    --root|--cache-dir|--timeout|--cache-max-age|--virtual) shift ;;
    -o) fetch_out=${1:-}; shift ;;
    --simulate) simulate=1 ;;
    -*) ;;
    update|upgrade|add|fetch|policy|search|info|del)
      if [ -n "$applet" ]; then positional="$positional $arg"; else applet=$arg; fi
      ;;
    *) positional="$positional $arg" ;;
  esac
done
# What the command actually read: the last set apk was pointed at, kept for the assertions.
if [ -n "${APK_REPOS_SEEN:-}" ] && [ -n "$repos" ] && [ -f "$repos" ]; then
  cat "$repos" >"${APK_REPOS_SEEN}"
fi
case "$applet" in
  update) exit "${APK_UPDATE_RC:-0}" ;;
  upgrade)
    if [ "$simulate" = "1" ]; then
      [ -n "${APK_SIM_OUT:-}" ] && cat "${APK_SIM_OUT}"
      exit "${APK_SIM_RC:-0}"
    fi
    exit 0
    ;;
  fetch)
    rc=${APK_FETCH_RC:-0}
    [ "$rc" != "0" ] && exit "$rc"
    for body in ${positional}; do
      name=${body%%[=<>~]*}
      printf 'APK %s\n' "$name" >"${fetch_out}/${name}-1.0-r1.apk"
    done
    exit 0
    ;;
  policy)
    printf '%s:\n  3.3.0-r1:\n    lib/apk/db/installed\n    https://pkgs.example.net/x86_64/packages.adb\n' \
      "${positional##* }"
    exit 0
    ;;
  *) exit 0 ;;
esac
APK
chmod +x "$bin/apk"
export PATH="$bin:$PATH"

# A solver answer that moves one package, so the prefetch runs its whole path (update,
# simulate, fetch) instead of stopping at "nothing to move".
cat >"$tmp/moving" <<'OUT'
( 1/1) Upgrading htop (3.3.0-r1 -> 3.5.3-r1)
OK: 282.0 MiB in 316 packages
OUT

# seam <plugins-root> <function> [args...]: one library call in its own shell.
#
# AB_PLUGINS_LIB is named explicitly because a sourced file cannot discover its own sibling: in
# a checkout this is how the library under test is found, and on a machine the installed
# /lib/ab-plugins.sh is what the same order resolves to. AB_ESP and AB_PACKAGES_FILE point at
# the fixture so a record or a journal line lands where the assertions can read it; per case
# knobs (APK_UPDATE_RC, ...) are exported by the caller, because they are what the stub reads.
seam() {
  _seam_plugins=$1
  _seam_fn=$2
  shift 2
  AB_PLUGINS_ROOT="$_seam_plugins" \
    AB_PLUGINS_LIB="$lib_plugins" AB_PACKAGES_LIB="$lib_packages" \
    AB_ESP="$tmp/esp" AB_PACKAGES_FILE="$tmp/packages" \
    APK_CALLS="$tmp/calls" APK_REPOS_SEEN="$tmp/seen.repos" \
    APK_SIM_OUT="$tmp/moving" \
    sh -c '. "$1"; shift; fn=$1; shift; "$fn" "$@"; printf "rc=%s\n" "$?"' \
    _ "$lib_packages" "$_seam_fn" "$@"
}

reset_calls() {
  : >"$tmp/calls"
  rm -f "$tmp/seen.repos" "$tmp/packages" "$tmp/esp/ab/plugins.journal"
}

# =========================================================================== #
# ac-9: no plugin declared, no command line changed
# =========================================================================== #
# The old-image shape: no /etc/ab/plugins.d at all. The library is still installed, which is
# the harder case - it must contribute nothing rather than not be found.
nosite="$tmp/nosite"
mkbase
reset_calls
before="$(feeds_digest)"

out="$(seam "$nosite" ab_packages_repos_file "$target" "$tmp/repos.zero")"
assert_contains "$out" "rc=0" "ac-9 the seam builds a feed set from the machine's own files"
assert_eq "$(cat "$tmp/repos.zero")" "$(base_feeds)" \
  "ac-9 with no plugin the assembled file is exactly the machine's own feeds, in apk's order"

out="$(seam "$nosite" ab_packages_prefetch "$target")"
assert_contains "$out" "rc=0" "ac-9 a prefetch on a machine with no plugin still lands its bodies"
assert_eq "$(sed -n '1p' "$tmp/calls")" \
  "--root $target --cache-dir $target/etc/apk/ab/cache --timeout 300 update" \
  "ac-9 the prefetch's first command is byte for byte the one it was before the seam"
assert_eq "$(grep -c 'repositories-file' "$tmp/calls")" "0" \
  "ac-9 and no prefetch command carries --repositories-file"
assert_eq "$(grep -c '' "$tmp/calls")" "3" \
  "ac-9 the whole path ran: index, solver, fetch"

# A fresh tree: the prefetch above left bodies in the cache, and a follow that finds them
# takes the offline path (a different set of commands, tested by the upgrade module).
mkbase
reset_calls
out="$(seam "$nosite" ab_packages_follow "$target")"
assert_contains "$out" "rc=0" "ac-9 a follow on a machine with no plugin runs"
assert_eq "$(sed -n '1p' "$tmp/calls")" "--root $target --timeout 300 update" \
  "ac-9 the follow's first command is byte for byte the one it was before the seam"
assert_eq "$(grep -c 'repositories-file' "$tmp/calls")" "0" \
  "ac-9 and no follow command carries --repositories-file"

# The gate is the one command that always carried --repositories-file: the invariant there is
# "still exactly one, holding exactly what it held before", not "none".
reset_calls
out="$(seam "$nosite" ab_packages_gate "$target" "$base")"
assert_contains "$out" "rc=0" "ac-9 the gate answers ok on a machine with no plugin"
assert_eq "$(grep -c '' "$tmp/calls")" "5" \
  "ac-9 the gate ran index, solver and one policy per world name, as before"
assert_eq "$(grep -o -- '--repositories-file' "$tmp/calls" | wc -l | tr -d ' ')" "5" \
  "ac-9 every gate call carries exactly one --repositories-file, never two"
assert_eq "$(cat "$tmp/seen.repos")" "$(base_feeds)" \
  "ac-9 the gate's feed set is the machine's own files, byte for byte"

assert_eq "$(feeds_digest)" "$before" \
  "ac-3 the gate and the prefetch left every feed file untouched"

# Nothing is declared, so nothing was injected - and nothing was made under /tmp either: the
# private directory is created only once a plugin is in play, so a machine without one pays
# nothing per apk call and leaves nothing behind.
assert_eq "$(find "$TMPDIR" -maxdepth 1 -name 'ab-plugins.*' | wc -l | tr -d ' ')" "0" \
  "m1 a machine with no plugin leaves no directory under /tmp"

# =========================================================================== #
# ac-9: a declared plugin enters every transaction through the same seam
# =========================================================================== #
mkplugin alpha <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://alpha.invalid/feed
feed = https://alpha.invalid/extra
CONF
mkplugin beta <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://beta.invalid/feed
CONF
ab_plugins_verdict_write "$site" alpha ok none
ab_plugins_verdict_write "$site" beta ok none

expected_set="$(base_feeds)
https://alpha.invalid/feed
https://alpha.invalid/extra
https://beta.invalid/feed"

mkbase
reset_calls
before="$(feeds_digest)"

out="$(seam "$site" ab_packages_repos_file "$target" "$tmp/repos.plugin")"
assert_contains "$out" "rc=0" "ac-9 the seam builds a set with a plugin declared"
assert_eq "$(cat "$tmp/repos.plugin")" "$expected_set" \
  "ac-9 the machine's own feeds come first, then the declared ones in label order"

# The same call twice describes the same set once: the file is rebuilt, not appended to.
seam "$site" ab_packages_repos_file "$target" "$tmp/repos.plugin" >/dev/null
assert_eq "$(cat "$tmp/repos.plugin")" "$expected_set" \
  "ac-9 a second call on the same file appends nothing twice"

reset_calls
out="$(seam "$site" ab_packages_prefetch "$target")"
assert_contains "$out" "rc=0" "ac-9 the prefetch runs with a plugin declared"
assert_eq "$(grep -c 'repositories-file' "$tmp/calls")" "3" \
  "ac-9 every prefetch command reads the declared feeds"
assert_contains "$(sed -n '1p' "$tmp/calls")" "--repositories-file ${TMPDIR}/ab-plugins." \
  "ac-9 the injected file lives in one /tmp directory, named per process"
assert_contains "$(sed -n '1p' "$tmp/calls")" "/repositories " \
  "ac-9 and the file it names is a repositories file, which is what apk reads"
assert_eq "$(cat "$tmp/seen.repos")" "$expected_set" \
  "ac-9 the file apk was pointed at is the base lines followed by the plugin lines"

mkbase
reset_calls
out="$(seam "$site" ab_packages_follow "$target")"
assert_contains "$out" "rc=0" "ac-9 the follow runs with a plugin declared"
assert_eq "$(grep -o -- '--repositories-file' "$tmp/calls" | wc -l | tr -d ' ')" \
  "$(grep -c '' "$tmp/calls")" \
  "ac-9 every follow command reads the declared feeds too: one repository view per machine"
assert_eq "$(cat "$tmp/seen.repos")" "$expected_set" \
  "ac-9 and that view is the same file"

mkbase
reset_calls
out="$(seam "$site" ab_packages_gate "$target" "$base")"
assert_contains "$out" "rc=0" "ac-9 the gate answers with a plugin declared"
assert_eq "$(cat "$tmp/seen.repos")" "$expected_set" \
  "ac-9 the gate judges the transaction the first boot will run, plugin feeds included"

assert_eq "$(feeds_digest)" "$before" \
  "ac-3 a declared plugin is injected from /tmp and never from the machine's own files"
assert_eq "$(ls "$target/etc/apk/repositories.d" | sort | tr '\n' ' ')" \
  "customfeeds.list distfeeds.list " \
  "ac-3 no file is added to repositories.d: the machine still has exactly its own two"

# =========================================================================== #
# ac-2/ac-9: a plugin that is not admitted contributes nothing
# =========================================================================== #
# stale: the declaration changed after someone checked it, so the verdict no longer speaks
# for the file and the feed is withheld (fail-closed).
stale="$tmp/stale"
mkdir -p "$stale/etc/ab/plugins.d/drifted"
cat >"$stale/etc/ab/plugins.d/drifted/plugin.conf" <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://drifted.invalid/feed
CONF
ab_plugins_verdict_write "$stale" drifted ok none
printf 'feed = https://drifted.invalid/other\n' >>"$stale/etc/ab/plugins.d/drifted/plugin.conf"

mkbase
reset_calls
out="$(seam "$stale" ab_packages_prefetch "$target")"
assert_contains "$out" "rc=0" "ac-9 a stale plugin does not stop the transaction"
assert_eq "$(grep -c 'repositories-file' "$tmp/calls")" "0" \
  "ac-9 a plugin whose declaration changed after its check is not injected"

# disabled: checked and fine, and the user turned it off.
off="$tmp/off"
mkdir -p "$off/etc/ab/plugins.d/offsome"
cat >"$off/etc/ab/plugins.d/offsome/plugin.conf" <<'CONF'
api = 1
kind = source
enabled = no
feed = https://off.invalid/feed
CONF
ab_plugins_verdict_write "$off" offsome ok none

mkbase
reset_calls
out="$(seam "$off" ab_packages_prefetch "$target")"
assert_contains "$out" "rc=0" "ac-9 a disabled plugin does not stop the transaction"
assert_eq "$(grep -c 'repositories-file' "$tmp/calls")" "0" \
  "ac-9 a disabled plugin is not injected even with a fresh ok verdict"

# never checked: the declaration exists and nobody has judged it.
never="$tmp/never"
mkdir -p "$never/etc/ab/plugins.d/unchecked"
cat >"$never/etc/ab/plugins.d/unchecked/plugin.conf" <<'CONF'
api = 1
kind = source
feed = https://unchecked.invalid/feed
CONF

mkbase
reset_calls
out="$(seam "$never" ab_packages_prefetch "$target")"
assert_contains "$out" "rc=0" "ac-9 an unchecked plugin does not stop the transaction"
assert_eq "$(grep -c 'repositories-file' "$tmp/calls")" "0" \
  "ac-9 an unchecked plugin is not injected: nothing is admitted on its own word"

# =========================================================================== #
# ac-7: the declared feed is unreachable
# =========================================================================== #
# The index did not answer. The record keeps the token it always had, and one journal line
# says a declared feed was suspended for this run - the record cannot tell a base feed from a
# plugin one, and that is the question an operator asks next.
mkbase
reset_calls
export APK_UPDATE_RC=1
out="$(seam "$site" ab_packages_prefetch "$target")"
unset APK_UPDATE_RC
assert_contains "$out" "rc=1" "ac-7 a prefetch whose index never answered fails, as before"
assert_file_exists "$tmp/esp/ab/plugins.journal" \
  "ac-7 the suspended feed is journalled on the ESP"
assert_contains "$(cat "$tmp/esp/ab/plugins.journal" 2>/dev/null)" \
  "plugin-suspended reason=network" \
  "ac-7 the journal line names the suspension and its reason"
assert_eq "$(grep -c '' "$tmp/esp/ab/plugins.journal" 2>/dev/null)" "1" \
  "ac-7 one line per event, not one per apk call"
assert_contains "$(cat "$tmp/packages" 2>/dev/null)" "follow=pending" \
  "ac-7 the follow record still says a follow is owed"
assert_matches "$(cat "$tmp/packages" 2>/dev/null)" \
  '^packages=[a-z]+ reason=network ' \
  "ac-7 and its reason is still the one word the record always used: network"
assert_eq "$(grep -c 'repositories-file' "$tmp/calls")" "1" \
  "ac-7 the failing command is the one that read the declared feeds"

# The control: the same failure on a machine with no plugin writes no journal line, because
# nothing was suspended.
reset_calls
export APK_UPDATE_RC=1
out="$(seam "$nosite" ab_packages_prefetch "$target")"
unset APK_UPDATE_RC
assert_contains "$out" "rc=1" "ac-7 a machine with no plugin fails the same way"
assert_eq "$(ls "$tmp/esp/ab/plugins.journal" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-7 and journals nothing: no declared feed was in play"

# The follow's own network branch: the probe says the machine has no usable network.
reset_calls
mkdir -p "$tmp/probe"
cat >"$tmp/probe/ab-net-probe.sh" <<'PROBE'
ab_net_probe() { return 1; }
PROBE
out="$(AB_ESP="$tmp/esp" AB_PACKAGES_FILE="$tmp/packages" \
  AB_PLUGINS_ROOT="$site" AB_PLUGINS_LIB="$lib_plugins" AB_PACKAGES_LIB="$lib_packages" \
  APK_CALLS="$tmp/calls" \
  sh -c '. "$1"; . "$2"; shift 2; ab_packages_follow "$@"; printf "rc=%s\n" "$?"' \
  _ "$lib_packages" "$tmp/probe/ab-net-probe.sh" "$target")"
assert_contains "$out" "rc=1" "ac-7 a follow with no usable network stays pending"
assert_contains "$(cat "$tmp/esp/ab/plugins.journal" 2>/dev/null)" \
  "plugin-suspended reason=network" \
  "ac-7 and says the declared feed was suspended rather than left silently out"
assert_matches "$(cat "$tmp/packages" 2>/dev/null)" '^packages=[a-z]+ reason=network ' \
  "ac-7 the follow record keeps its network reason too"

# =========================================================================== #
# ac-9: no apk call in the platform layer bypasses the seam
# =========================================================================== #
# The transaction call sites live in three files: the two tools and the package library. A
# single one that forgot the arguments would give the same machine two repository views, so the
# omission is asserted on the whole layer rather than on one file. What is not a transaction is
# excluded by shape, not by file:
#
#   * a comment, and a sentence a command prints (`say "apk update"`, `printf 'row ...'`) -
#     neither runs anything;
#   * `apk --version`, an identity question, and `apk adbdump`, which reads a local file;
#   * a call carrying `--no-network`, which cannot read a feed at all, so a missing feed set
#     there is not a bypass.
#
# Anything else has to have a word in front of the applet - the seam's own `--repositories-file`
# pair, or the root it names.
bare=$(grep -rnE '(^|[^-_[:alnum:]])apk (update|upgrade|add|fetch)([[:space:]]|$)' "$root/platform" \
  | grep -v -e ':[0-9]*:[[:space:]]*#' -e 'say "' -e 'printf' -e '--version' -e 'adbdump' \
      -e '--no-network' || true)
assert_eq "$bare" "" \
  "ac-9 every apk transaction in the platform layer takes its feed set from the seam"
assert_eq "$(grep -c 'apk ${_repos} ' "$ab_slot")" "4" \
  "ac-9 all four transactions in ab-slot carry them: update, upgrade, add --allow-untrusted, add name=version"

# The library builds its apk commands in five wrappers - the refresh layer's (which the prune
# inside a follow asks its "no such package" question through), the prefetch's, the follow's,
# and the snapshot's two fetches - and each asks the one function that decides the feed set. A
# wrapper that forgot would answer a question about a machine with two repository views.
assert_eq "$(grep -cE '^[[:space:]]+_[a-z]+_repos=\$\(_packages_apk_repos_args ' "$lib_packages")" "5" \
  "ac-9 every apk wrapper inside the library asks the seam for its feed set"

# =========================================================================== #
# ac-9: the snapshot's fetch reads the feeds a follow reads
# =========================================================================== #
# `ab-slot packages snapshot` fetches the bodies a revert installs, and that revert is the
# offline way back. A fetch that read only the base's feeds would record a payload gap for every
# package a declared feed carries - exactly the packages the way back is for - so both stages
# are asked through the seam. This exercises stage one, the one package per call.
rm -rf "$tmp/payloads"
mkdir -p "$tmp/payloads"
reset_calls
out="$(seam "$site" _packages_fetch_per_package "$tmp/payloads" "htop 1.0-r1")"
assert_contains "$out" "rc=0" "the per-package fetch of a snapshot runs"
assert_eq "$(grep -c '' "$tmp/calls")" "1" "one apk call for one package"
assert_contains "$(sed -n '1p' "$tmp/calls")" "--repositories-file ${TMPDIR}/ab-plugins." \
  "the fetch reads the file that holds the declared feeds"
assert_contains "$(sed -n '1p' "$tmp/calls")" " fetch -o " \
  "and the command is still the fetch it was, with the output directory it was given"
# This fetch runs on the machine that is running, so its feed set is this machine's own files
# plus the declared ones - and the declared ones come last, exactly as in a follow's file.
assert_eq "$(sed -n '$p' "$tmp/seen.repos")" "https://beta.invalid/feed" \
  "the declared feeds are in the file the fetch read, after the machine's own"
assert_eq "$(grep -c -- '--root' "$tmp/calls")" "0" \
  "and the running root is named without --root: a fetch here is a transaction on this machine"

# With nothing declared the same call is byte for byte the one it always was.
reset_calls
out="$(seam "$nosite" _packages_fetch_per_package "$tmp/payloads" "htop 1.0-r1")"
assert_contains "$out" "rc=0" "the same fetch on a machine with no plugin runs"
assert_eq "$(grep -c 'repositories-file' "$tmp/calls")" "0" \
  "ac-9 and carries no --repositories-file: nothing was declared to add"

# =========================================================================== #
# m2: a declared feed that cannot be injected is not a machine without plugins
# =========================================================================== #
# /tmp unwritable with an active plugin: the transaction still runs on the machine's own feeds,
# which is the quiet fallback the seam has always had - but it is no longer silent. Silence is
# what would let a later prune read "the base does not offer this name" about a package the
# plugin's feed carries, and drop the world entry.
nowrite="$tmp/not-a-directory/deeper"
mkbase
reset_calls
out="$(TMPDIR="$nowrite" AB_PLUGINS_ROOT="$site" AB_PLUGINS_LIB="$lib_plugins" \
  AB_PACKAGES_LIB="$lib_packages" AB_ESP="$tmp/esp" AB_PACKAGES_FILE="$tmp/packages" \
  APK_CALLS="$tmp/calls" APK_SIM_OUT="$tmp/moving" \
  sh -c '. "$1"; shift; fn=$1; shift; "$fn" "$@"; printf "rc=%s\n" "$?"' \
  _ "$lib_packages" ab_packages_prefetch "$target")"
assert_contains "$out" "rc=0" "m2 a transaction whose feed file cannot be built still runs"
assert_eq "$(grep -c 'repositories-file' "$tmp/calls")" "0" \
  "m2 and it carries no feed set, because there was none to carry"
assert_file_exists "$tmp/esp/ab/plugins.journal" \
  "m2 the loss is written down instead of being left silent"
assert_contains "$(cat "$tmp/esp/ab/plugins.journal" 2>/dev/null)" \
  "plugin-skip reason=tmp-unwritable" \
  "m2 the journal line names the skipped plugin feed and why"
skips=$(grep -c 'plugin-skip reason=tmp-unwritable' "$tmp/esp/ab/plugins.journal" 2>/dev/null || true)
assert_eq "$([ "${skips:-0}" -ge 1 ] && echo journalled || echo silent)" "journalled" \
  "m2 one line per apk call that lost the feed set, and never zero"

# The prune is the caller that must not guess. Without the declared feeds it cannot tell "this
# release does not offer the name" from "the plugin's feed does", and an entry it dropped would
# be a package that was installed on purpose. It answers the way it answers any unanswerable
# question: it refuses, and nothing is touched.
world_before_prune="$(cat "$target/etc/apk/world")"
out="$(TMPDIR="$nowrite" AB_PLUGINS_ROOT="$site" AB_PLUGINS_LIB="$lib_plugins" \
  AB_PACKAGES_LIB="$lib_packages" AB_ESP="$tmp/esp" AB_PACKAGES_FILE="$tmp/packages" \
  APK_CALLS="$tmp/calls" \
  sh -c '. "$1"; shift; fn=$1; shift; "$fn" "$@"; printf "rc=%s reason=%s\n" "$?" "${AB_PACKAGES_PRUNE_REASON:-}"' \
  _ "$lib_packages" ab_packages_prune "$target")"
assert_contains "$out" "rc=2" "m2 the prune refuses to answer rather than prune blind"
assert_contains "$out" "reason=prune-unanswerable" \
  "m2 and names it with the reason it already had for an unaskable question"
assert_eq "$(cat "$target/etc/apk/world")" "$world_before_prune" \
  "m2 nothing was dropped from the world"

# The control: with no plugin declared the same prune answers normally, so the refusal above is
# about the missing feed set and not about the fixture.
mkbase
reset_calls
out="$(seam "$nosite" ab_packages_prune "$target")"
assert_contains "$out" "rc=0" "m2 a machine with no plugin prunes as it always did"

# Whatever the calls above had inside, none of them left its private directory behind.
assert_eq "$(find "$TMPDIR" -maxdepth 1 -name 'ab-plugins.*' | wc -l | tr -d ' ')" "0" \
  "m1 every injected-file directory was removed with the apk call that read it"

# =========================================================================== #
# the published watchdog
# =========================================================================== #
out="$(sh -c '. "$1"; ab_packages_run_bounded 0 sh -c "exit 7"; printf "rc=%s\n" "$?"' \
  _ "$lib_packages")"
assert_contains "$out" "rc=7" "the published watchdog forwards the command's own status"
out="$(sh -c '. "$1"; ab_packages_run_bounded notanumber echo bounded; printf "rc=%s\n" "$?"' \
  _ "$lib_packages")"
assert_contains "$out" "bounded" "a cap that is not a number runs the command unbounded"

finish
