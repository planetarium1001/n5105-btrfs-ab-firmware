#!/usr/bin/env bash
# Module: plugins
# End to end: one person, one declaration, and the whole path through the tool.
#
# The other files in this module assert the library's verdicts (`test_plugins_lib.sh`), the
# seam's apk command lines (`test_plugins_seam.sh`) and the CLI's own contract
# (`test_plugins_cli.sh`). This one runs the *user's* path in one machine, in one order, with
# nothing stubbed but the two binaries that would touch the world: a machine with no plugin,
# a declaration dropped in, a check, the repositories file a transaction would read, one
# install, an edit, a switch-off - and the machine's own feed files byte for byte what they
# were at the start.
#
# What each stage is here to prove:
#
#   never checked  a declaration contributes nothing. The default is the quiet one, so a
#                  typo in a feed cannot add a source to a transaction before anybody looked.
#   checked ok     the feed joins the repositories file, after the machine's own feeds.
#   apply          exactly one apk transaction, reading that same file.
#   edited         the verdict stops speaking for the file (`stale`) and the feed leaves the
#                  repositories file *without* a new check. This is the fail-closed half: the
#                  alternative is an edit that quietly keeps the old admission.
#   enabled = no   the switch takes it out of every transaction, and nothing else changes.
#
# Everything is local: apk is a stand-in that prints the shapes measured on the device and
# journals its argv, the fetcher answers only for the URLs the fixture declares, and the
# machine tree is under mktemp. /etc/apk of the machine running this test is never read or
# written.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

cli="$root/platform/usr/sbin/ab-packages"
plugins_lib="$root/platform/lib/ab-plugins.sh"
packages_lib="$root/platform/lib/upgrade/packages.sh"
assets_lib="$root/platform/lib/ab-pkgs-assets.sh"
plan_lib="$root/platform/lib/ab-plan.sh"
for f in "$cli" "$plugins_lib" "$packages_lib" "$assets_lib" "$plan_lib"; do
  if [ ! -f "$f" ]; then
    printf 'not ok 1 - the files under test exist\n' >&2
    printf '    missing %s\n' "$f" >&2
    exit 1
  fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

site="$tmp/site"
scratch="$tmp/scratch"
bin="$tmp/bin"
apk_calls="$tmp/apk-calls"
fetch_calls="$tmp/fetch-calls"
policy_table="$tmp/policy.table"
mkdir -p "$site/etc/apk/repositories.d" "$site/etc/apk/keys" "$site/etc/ab/plugins.d" \
  "$site/lib/apk/db" "$site/boot/ab" "$scratch" "$bin"
: >"$apk_calls"
: >"$fetch_calls"

# --- the machine -------------------------------------------------------------
# A machine of the shape the measured image has: the feed in repositories.d (apk-tools 3),
# a world with one package on a feed and one installed from the database, and no plugin.
printf '%s\n' 'https://downloads.example.org/releases/25.12.2/targets/x86/64/packages/packages.adb' \
  >"$site/etc/apk/repositories.d/distfeeds.list"
cat >"$site/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
htop=3.3.0-r1
WORLD
cat >"$site/lib/apk/db/installed" <<'DB'
C:Q1aaaa=
P:htop
V:3.3.0-r1
DB
plugins_dir="$site/etc/ab/plugins.d"

machine_feed_bytes() {
  cat "$site/etc/apk/repositories.d/distfeeds.list"
}

# machine_feed_digest: every file of the directory these assertions are about, with its
# digest and its name. `repositories.d` is what apk reads on this image, so "the plugin path
# never writes /etc/apk" is this value not moving - a new file, a deleted file and an edited
# file all change it.
machine_feed_digest() {
  ( cd "$site/etc/apk/repositories.d" && ls -A | sort
    for f in "$site"/etc/apk/repositories.d/*; do
      [ -f "$f" ] || continue
      printf '%s %s\n' "${f##*/}" "$(file_digest "$f")"
    done ) 2>/dev/null
}

# file_digest: the digest of one file, whichever tool this machine has. The assertion is
# "these bytes did not change", so the tool may not be the same on every machine, but the
# answer has to be.
file_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
    return 0
  fi
  shasum -a 256 "$1" | awk '{ print $1 }'
}

# --- stand-ins for the two binaries that would touch the world ---------------
# apk: `update`, `policy`, `version -t` and `add`, each in the shape the device prints. Every
# line is journalled before it is answered, because "one transaction" and "the read-only
# commands ran nothing" are asserted from that journal rather than from a message the tool
# wrote about itself.
cat >"$bin/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >>"${APK_CALLS:-/dev/null}"
applet=""
names=""
a=""
b=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root|--cache-dir|--repositories-file|--timeout) shift 2 ;;
    --no-network|-q|--quiet) shift ;;
    update|policy|add|upgrade|version|adbdump) applet=$1; shift ;;
    -*) shift ;;
    *)
      case "${applet}" in
        version) if [ -z "${a}" ]; then a=$1; else b=$1; fi ;;
        *) names="${names} $1" ;;
      esac
      shift
      ;;
  esac
done

case "${applet}" in
  update) exit "${APK_UPDATE_RC:-0}" ;;
  add|upgrade) exit "${APK_ADD_RC:-0}" ;;
  version)
    awk -v a="${a}" -v b="${b}" 'BEGIN {
      sub(/-r[0-9]+$/, "", a); sub(/-r[0-9]+$/, "", b)
      split(a, x, "."); split(b, y, ".")
      for (i = 1; i <= 4; i++) {
        if ((x[i] + 0) > (y[i] + 0)) { print ">"; exit }
        if ((x[i] + 0) < (y[i] + 0)) { print "<"; exit }
      }
      print "="
    }'
    ;;
  policy)
    # `apk policy <name>...`: a `<name> policy:` line, the version, then the sources that
    # offer it, one level deeper. Only the installed database offers the world's names here,
    # which is the "no shadow" answer the check has to reach and the one a plugin that merely
    # adds packages produces.
    for name in ${names}; do
      awk -v want="${name}" '
        $1 == want { print want " policy:"; print "  " $2 ":"; print "    " $3 }
      ' "${APK_POLICY_TABLE:-/dev/null}"
    done
    ;;
esac
exit 0
APK

# uclient-fetch: `-q --spider -T <secs> <url>`, 0 when the URL answers. Only a URL the fixture
# declares is ever named, and a URL in $FETCH_DOWN does not answer - the two answers the
# check has to tell apart.
cat >"$bin/uclient-fetch" <<'FETCH'
#!/bin/sh
url=""
for arg in "$@"; do
  case "${arg}" in
    http://*|https://*) url=${arg} ;;
  esac
done
[ -n "${url}" ] || exit 1
printf '%s\n' "${url}" >>"${FETCH_CALLS:-/dev/null}"
case "
${FETCH_DOWN:-}
" in
  *"
${url}
"*) exit 1 ;;
esac
exit 0
FETCH
chmod +x "$bin/apk" "$bin/uclient-fetch"

# --- how the tool is run -----------------------------------------------------
export APK_CALLS="$apk_calls"
export APK_POLICY_TABLE="$policy_table"
export FETCH_CALLS="$fetch_calls"
export FETCH_DOWN=""

# run <args...>: the tool, with this fixture as the machine it believes it is on. Every tree
# it reads is named here, so a bug in the tool cannot reach the machine running the test.
run() {
  AB_PACKAGES_ROOT="$site" \
    AB_PLUGINS_ROOT="$site" \
    AB_PACKAGES_LIB="$packages_lib" \
    AB_PKGS_ASSETS_LIB="$assets_lib" \
    AB_PLAN_LIB="$plan_lib" \
    AB_PLUGINS_LIB="$plugins_lib" \
    AB_ESP="$site/boot" \
    AB_PACKAGES_FILE="$site/boot/ab/packages" \
    AB_PLUGINS_CHECK_TIMEOUT=20 \
    TMPDIR="$scratch" \
    PATH="$bin:$PATH" \
    sh "$cli" "$@"
}

out=""
rc=0
call() {
  out=$(run "$@" 2>&1)
  rc=$?
}

# https_lines <text>: the URL lines of a printed repositories file.
https_lines() {
  printf '%s\n' "$1" | grep -E '^https?://' || true
}

# apk_transactions: how many package transactions the stand-in was asked to run. `update` is
# not one - it fetches indexes - so this counts `add` and `upgrade` only.
apk_transactions() {
  grep -cE '(^| )(add|upgrade)( |$)' "$apk_calls" 2>/dev/null || true
}

# --- 1. the empty machine ----------------------------------------------------
# Nothing declared is a state, not a failure: both read-only commands answer with a token a
# script can test, and neither runs apk or a fetcher.
call plugins list
assert_eq "$rc" "0" "plugins list exits 0 on a machine with no plugin"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" "plugins=none" \
  "an empty machine says plugins=none rather than printing nothing"

call plugins repos
assert_eq "$rc" "0" "plugins repos exits 0 on a machine with no plugin"
assert_eq "$(https_lines "$out")" \
  "https://downloads.example.org/releases/25.12.2/targets/x86/64/packages/packages.adb" \
  "the repositories file is the machine's own feed, alone"
assert_contains "$out" "plugins=none" \
  "and the command says that nothing was added to the file it printed"
assert_eq "$(apk_transactions)" "0" "reading a repositories file runs no apk transaction"

call plugins check
assert_eq "$rc" "0" "checking nothing is not a failure"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" "plugins=none" \
  "check answers with the same token"
assert_eq "$([ -s "$fetch_calls" ] && echo fetched || echo quiet)" "quiet" \
  "checking nothing fetches nothing: the network stage only runs for a declaration"

feeds_before=$(machine_feed_digest)
feed_bytes_before=$(machine_feed_bytes)
world_before=$(cat "$site/etc/apk/world")

# --- 2. a declaration that nobody has checked -------------------------------
# The declaration is the documented shape: both kinds may carry a feed, and the packages are
# the names `apply` installs. It is enabled, and it still contributes nothing yet.
mkdir -p "$plugins_dir/istore"
cat >"$plugins_dir/istore/plugin.conf" <<'CONF'
api = 1
kind = packages
enabled = yes
feed = https://istore.example.net/packages
package = luci-app-demo
package = demo-helper
CONF

call plugins list
assert_eq "$rc" "0" "plugins list exits 0 with one declaration"
assert_eq "$out" "label=istore kind=packages enabled=yes checked=never reason=none feeds=1 packages=2" \
  "the row reports the declaration and that no check has spoken for it"
call plugins repos
assert_eq "$(https_lines "$out" | grep -c .)" "1" \
  "a declaration nobody checked adds no source: it is not in the repositories file"
assert_eq "$(apk_transactions)" "0" "the read-only commands still ran no transaction"

# --- 3. check: the feed answers, and nothing it offers shadows the base -----
# The world's htop is offered by the installed database and by no candidate source, which is
# the ordinary "a plugin adds packages, it does not replace them" answer.
printf '%s\n' 'htop 3.3.0-r1 lib/apk/db/installed' >"$policy_table"
call plugins check istore
assert_eq "$rc" "0" "check admits a reachable feed with nothing shadowed"
assert_eq "$out" "plugin=istore verdict=ok reason=none" "the verdict line is the whole answer"
assert_eq "$(cat "$fetch_calls")" "https://istore.example.net/packages" \
  "the probe asked the declared feed and nothing else"
assert_eq "$(grep -cE '(^| )update( |$)' "$apk_calls")" "1" \
  "checking reads the index once: the shadow question is asked of apk, not re-implemented"
assert_file_exists "$plugins_dir/istore/.verdict" \
  "the verdict is on disk, where every later transaction reads it instead of asking again"

call plugins list
assert_eq "$out" "label=istore kind=packages enabled=yes checked=ok reason=none feeds=1 packages=2" \
  "the row now says ok, which is what admits the feed"

# --- 4. the repositories file a transaction would read ----------------------
call plugins repos
assert_eq "$rc" "0" "plugins repos exits 0"
assert_eq "$(https_lines "$out" | head -n 1)" \
  "https://downloads.example.org/releases/25.12.2/targets/x86/64/packages/packages.adb" \
  "the machine's own feed still comes first: the base wins a tie in apk's ordering"
assert_eq "$(https_lines "$out" | tail -n 1)" "https://istore.example.net/packages" \
  "the checked plugin's feed follows it"
assert_contains "$out" "1 plugin feed(s) from 1 plugin(s)" \
  "the command says how much of the file is plugins"

# --- 5. apply: one transaction, from that same file ------------------------
: >"$apk_calls"
call plugins apply istore --yes
assert_eq "$rc" "0" "apply installs what the plugin names"
# The block comes before the transaction even when --yes answers it: a log of the run says
# what was about to happen, and that it did not touch the world record.
assert_matches "$out" 'packages +luci-app-demo demo-helper' \
  "the plan block names the packages before apk is run"
assert_contains "$out" "the world record" "and says the record is not touched"
assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "plugin=istore result=installed packages=2" \
  "the result names the plugin"
assert_eq "$(apk_transactions)" "1" \
  "exactly one transaction for two packages: installing them one at a time is how half a plugin lands"
assert_eq "$(grep -cE '(^| )add( |$)' "$apk_calls")" "1" "the transaction is an add"
assert_contains "$(cat "$apk_calls")" "add luci-app-demo demo-helper" \
  "apk is given the declared names, in the declared order"
assert_contains "$(cat "$apk_calls")" "--repositories-file" \
  "the transaction reads the file holding the plugin's feed, not some other view of the machine"
assert_eq "$([ -e "$site/boot/ab/packages" ] && echo present || echo absent)" "absent" \
  "apply writes no world record at all: that line describes a whole-world follow"

# --- 6. an edited declaration is not the one that was checked --------------
# This is the fail-closed half. The verdict stores the digest of the file it speaks for, so
# an edit - even one that only adds a package - makes it stale, and a stale plugin is not
# injected. Without this, editing a feed would keep the old admission forever.
printf 'package = demo-extra\n' >>"$plugins_dir/istore/plugin.conf"
call plugins list
assert_eq "$out" "label=istore kind=packages enabled=yes checked=stale reason=none feeds=1 packages=3" \
  "an edited declaration reports stale, and the new package is what it now declares"
call plugins repos
assert_eq "$(https_lines "$out" | grep -c .)" "1" \
  "the stale plugin's feed is out of the repositories file until it is checked again"
: >"$apk_calls"
call plugins apply istore --yes
assert_eq "$(apk_transactions)" "1" \
  "apply installs from the feeds the declaration names: naming a plugin is the decision"

call plugins check istore
assert_eq "$rc" "0" "checking the edited declaration admits it again"
call plugins repos
assert_eq "$(https_lines "$out" | tail -n 1)" "https://istore.example.net/packages" \
  "and its feed is back in the repositories file"

# --- 7. the switch ---------------------------------------------------------
# `enabled = no` is a complete answer: the plugin stays declared, its files stay where they
# are, and no transaction reads it. check does not even fetch, because there is nothing it
# could change.
cat >"$plugins_dir/istore/plugin.conf" <<'CONF'
api = 1
kind = packages
enabled = no
feed = https://istore.example.net/packages
package = luci-app-demo
package = demo-helper
CONF
: >"$fetch_calls"
: >"$apk_calls"
call plugins list
assert_contains "$out" "enabled=no" "the row shows the switch"
call plugins check istore
assert_eq "$rc" "0" "checking a disabled plugin is not a failure"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" \
  "plugin=istore verdict=skipped reason=plugin-disabled" \
  "check says the switch answered before the network was asked"
assert_eq "$([ -s "$fetch_calls" ] && echo fetched || echo quiet)" "quiet" \
  "a disabled plugin costs no request"
assert_eq "$(apk_transactions)" "0" "and no apk transaction"
call plugins repos
assert_eq "$(https_lines "$out" | grep -c .)" "1" \
  "a disabled plugin's feed is not in the repositories file, whatever its verdict says"

# Deleting the directory is the other way to disable it, and it leaves nothing behind that a
# later transaction could read.
rm -rf "$plugins_dir/istore"
call plugins list
assert_eq "$(printf '%s\n' "$out" | head -n 1)" "plugins=none" \
  "a deleted declaration is gone rather than half-remembered"
call plugins repos
assert_eq "$(https_lines "$out" | grep -c .)" "1" "and the repositories file is the machine's own again"

# --- 8. the machine's own files, byte for byte -----------------------------
# The whole path above - list, repos, check, apply, edit, switch off - reads the machine's
# feeds and never writes them. `/etc/apk/repositories.d` is what apk reads on this image, so
# this is the assertion that the plugin set lives in one /tmp file and nowhere else.
assert_eq "$(machine_feed_digest)" "$feeds_before" \
  "no file under /etc/apk/repositories.d was created, deleted or edited"
assert_eq "$(machine_feed_bytes)" "$feed_bytes_before" "distfeeds.list is byte-identical"
# The world is apk's to write, and here apk is a stand-in that writes nothing: what this
# asserts is that no *plugin* path edits it. (`plugins apply` does reach the world, through the
# apk it runs - see docs/plugins.md; there is no second writer in this tool.)
assert_eq "$(cat "$site/etc/apk/world")" "$world_before" \
  "no plugin path wrote a world entry of its own: only the apk it runs can, and the stand-in does not"

# The file apk reads is rebuilt per apk call, in a directory mktemp made. Every command above
# has returned, so every one of those directories is gone: a name under /tmp that outlives its
# command is a name that can be found and used by somebody else.
assert_eq "$(find "$scratch" -maxdepth 1 -name 'ab-plugins.*' | wc -l | tr -d ' ')" "0" \
  "m1 no injected-file directory is left behind under /tmp"

finish
