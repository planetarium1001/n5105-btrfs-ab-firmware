#!/usr/bin/env bash
# Module: plugins
# The `ab-packages plugins ...` surface, and the one attribution `sources` gained.
#
# What is under test is the CLI's own contract: the line it prints, the verdict it writes, and -
# the part that can ruin a machine silently - the argv it hands apk. The transaction seam
# (`ab_packages_repos_file`, `ab_packages_run_bounded`, `_packages_apk_repos_args`) belongs to
# the packages library; when it is there this module uses the real one, and until it is, the
# stand-in at the bottom of this file answers in the shape that unit's handoff states.
#
#   ac-4  a plugin whose feed offers a higher version of a name the world holds is blocked with
#         `shadow:<name>`, and `allow-shadow = yes` records `shadow-allowed` and admits it.
#   ac-6  apply is one apk transaction behind the usual question: nothing is installed before a
#         `y` or a `--yes`, a failed transaction answers `apk-<rc>`, and a plugin that names no
#         package answers `plugin-nothing-to-install` with rc 0.
#   ac-8  `sources <name>` attributes a plugin's feed as `source=plugin:<label>`, and a feed of a
#         plugin the user switched off keeps the old `feed` attribution.
#   ac-1  a static refusal reaches the CLI unchanged and costs no network request at all.
#   ac-3  no subcommand writes /etc/apk: the feed file and the world are byte-identical after
#         every call in this file.
#
# and three things the CLI owns on its own:
#
#   * a `package` value is a word on an `apk add` line, so an apk option spelled as a package is
#     refused before apk is called at all;
#   * a check whose verdict cannot be written is not a check that passed;
#   * the running root is handed to apk without `--root`, and a fixture tree with one.
#
# Everything is local: apk is a stand-in that prints the shapes measured on the device, the
# fetcher is a script that answers only for the URLs a fixture declares, and the machine tree is
# under mktemp. Nothing here can reach the real /etc/apk or the network.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

cli="$root/platform/usr/sbin/ab-packages"
plugins_lib="$root/platform/lib/ab-plugins.sh"
packages_lib="$root/platform/lib/upgrade/packages.sh"
for f in "$cli" "$plugins_lib" "$packages_lib"; do
  if [ ! -f "$f" ]; then
    printf 'not ok 1 - the files under test exist\n' >&2
    printf '    missing %s\n' "$f" >&2
    exit 1
  fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- a machine-shaped tree ---------------------------------------------------
# The declarations are upper layer (/etc/ab), the feeds are where apk reads them, and the world
# is the list of names the shadow question is about: `plugins check` compares against the world,
# so the fixture has to have one.
site="$tmp/site"
mkdir -p "$site/etc/apk/repositories.d" "$site/etc/apk/keys" "$site/etc/ab/plugins.d" \
  "$site/lib/apk/db" "$site/boot/ab"
printf '%s\n' 'https://base.invalid/releases/25.12.2/targets/x86/64/packages/packages.adb' \
  >"$site/etc/apk/repositories.d/distfeeds.list"
cat >"$site/etc/apk/world" <<'WORLD'
base-files
htop=3.3.0-r1
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
!libc
@core
WORLD
cat >"$site/lib/apk/db/installed" <<'DB'
C:Q1aaaa=
P:htop
V:3.3.0-r1
DB

# The bytes ac-3 is about: whatever happens below, these two files are the machine's own.
world_before=$(cat "$site/etc/apk/world")
feeds_before=$(cat "$site/etc/apk/repositories.d/distfeeds.list")
feeds_ls_before=$(ls "$site/etc/apk/repositories.d")

# The verdict writer is the library's, so a fixture's "already checked" state is written the
# same way a check writes it (including the digest that makes it speak for this conf).
# shellcheck source=../../../platform/lib/ab-plugins.sh
. "$plugins_lib"

# mkplugin <label>: one plugin.conf on stdin.
mkplugin() {
  mkdir -p "$site/etc/ab/plugins.d/$1"
  cat >"$site/etc/ab/plugins.d/$1/plugin.conf"
}

mkplugin alpha <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://plug.invalid/feed
CONF
mkplugin beta <<'CONF'
api = 1
kind = source
enabled = no
feed = https://off.invalid/feed
CONF
mkplugin delta <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://stale.invalid/feed
CONF
mkplugin epsilon <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://shadowed.invalid/feed
CONF
mkplugin gamma <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://gone.invalid/feed
CONF
mkplugin zeta <<'CONF'
api = 1
kind = packages
enabled = yes
feed = https://plug.invalid/feed
package = htop
package = tmux
CONF
ab_plugins_verdict_write "$site" alpha ok none
ab_plugins_verdict_write "$site" beta ok none
ab_plugins_verdict_write "$site" delta ok none
ab_plugins_verdict_write "$site" epsilon blocked shadow:htop
# delta is checked and then edited: the verdict stops speaking for the declaration (stale).
printf 'allow-kmod = no\n' >>"$site/etc/ab/plugins.d/delta/plugin.conf"

# --- stand-ins for the tools ------------------------------------------------
bin="$tmp/bin"
mkdir -p "$bin"
apk_calls="$tmp/apk-calls"
fetch_calls="$tmp/fetch-calls"
policy_table="$tmp/policy.table"
repos_seen="$tmp/repos-seen"
: >"$apk_calls"
: >"$fetch_calls"
: >"$policy_table"
: >"$repos_seen"

cat >"$bin/apk" <<'APK'
#!/bin/sh
# The three applets the plugin path uses, each in the shape the device prints:
#
#   update                           0, or $APK_UPDATE_RC
#   policy <name>...                 `<name> policy:`, then a version line, then the sources
#                                    that offer it, one level deeper - from $APK_POLICY_TABLE
#                                    (`name version source` rows), or garbage for the fixture
#                                    that must not be read as "no shadow"
#   version -t <a> <b>               `<`, `=` or `>`
#   add <name>..., upgrade <name>   0, or $APK_ADD_RC - and every call is journalled, because
#                                    "exactly one transaction" is asserted from the journal
printf '%s\n' "$*" >>"${APK_CALLS:-/dev/null}"
root=""
applet=""
names=""
a=""
b=""
repos=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2 ;;
    --repositories-file) repos=$2; shift 2 ;;
    --cache-dir|--timeout) shift 2 ;;
    --no-network|-q|--quiet) shift ;;
    update|policy|add|upgrade|version|adbdump) applet=$1; shift ;;
    -*) shift ;;
    *)
      case "$applet" in
        version) if [ -z "$a" ]; then a=$1; else b=$1; fi ;;
        *) names="$names $1" ;;
      esac
      shift
      ;;
  esac
done
# What apk was actually pointed at, marked with the applet: the assertions about the second
# `policy` question are about the file it read, not about its answer.
if [ -n "${APK_REPOS_SEEN:-}" ] && [ -n "$repos" ] && [ -f "$repos" ]; then
  printf -- '--- %s\n' "$applet" >>"${APK_REPOS_SEEN}"
  cat "$repos" >>"${APK_REPOS_SEEN}"
fi

case "$applet" in
  update) exit "${APK_UPDATE_RC:-0}" ;;
  add|upgrade) exit "${APK_ADD_RC:-0}" ;;
  version)
    awk -v a="$a" -v b="$b" 'BEGIN {
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
    case "${APK_POLICY_MODE:-format}" in
      garbage)
        printf 'this is not apk policy output\n'
        exit 0
        ;;
      empty) exit 0 ;;
    esac
    [ -f "${APK_POLICY_TABLE:-/dev/null}" ] || exit 0
    for name in $names; do
      awk -v want="$name" '
        $1 == want {
          if (ver[n] != $2) { ver[++n] = $2 }
          src[n] = src[n] "\n    " $3
        }
        END {
          print want " policy:"
          for (i = 1; i <= n; i++) { print "  " ver[i] ":"; print src[i] }
        }
      ' "${APK_POLICY_TABLE}"
    done
    ;;
esac
exit 0
APK

cat >"$bin/uclient-fetch" <<'FETCH'
#!/bin/sh
# `-q --spider -T <secs> <url>`: 0 when the URL answers, 1 when it does not. A URL in
# $FETCH_DOWN does not answer; nothing else is ever contacted, so a fixture cannot reach out.
url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url=$arg ;;
  esac
done
[ -n "$url" ] || exit 1
printf '%s\n' "$url" >>"${FETCH_CALLS:-/dev/null}"
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
# The seam stub has to be in place before the tool sources its library, and the tool is sourced
# rather than executed for exactly that reason: `. ab-packages` runs main with this script's
# argv, so the stand-in functions are already defined when the library is loaded.
seam="$tmp/seam.sh"
: >"$seam"
if ! grep -q '^ab_packages_repos_file()' "$packages_lib" 2>/dev/null \
  || ! grep -q '^ab_packages_run_bounded()' "$packages_lib" 2>/dev/null; then
  cat >"$seam" <<'SEAM'
ab_packages_repos_file() {
    _sr_root=$1
    _sr_out=$2
    : >"$_sr_out" || return 1
    for _sr_file in "$_sr_root"/etc/apk/repositories.d/*.list \
        "$_sr_root/etc/apk/distfeeds.list" "$_sr_root/etc/apk/repositories"; do
        [ -f "$_sr_file" ] || continue
        grep -v '^[[:space:]]*$' "$_sr_file" | grep -v '^#' >>"$_sr_out" || :
    done
    if command -v ab_plugins_repos_append >/dev/null 2>&1; then
        ab_plugins_repos_append "$_sr_root" "$_sr_out" || :
    fi
    return 0
}
ab_packages_run_bounded() {
    _br_secs=$1
    shift
    "$@"
}
_packages_apk_repos_args() {
    _ar_root=$1
    _ar_tmp=$2
    command -v ab_plugins_active_count >/dev/null 2>&1 || return 0
    [ "$(ab_plugins_active_count "$_ar_root")" -gt 0 ] || return 0
    _ar_file="$_ar_tmp/ab-repositories.$$"
    ab_packages_repos_file "$_ar_root" "$_ar_file" || return 1
    printf -- '--repositories-file %s' "$_ar_file"
}
SEAM
fi

runner="$tmp/ab-packages"
{
  printf '#!/bin/sh\n'
  [ ! -s "$seam" ] || printf '. %s\n' "$seam"
  printf '. %s\n' "$cli"
} >"$runner"
chmod +x "$runner"

export APK_CALLS="$apk_calls"
export APK_REPOS_SEEN="$repos_seen"
export APK_POLICY_TABLE="$policy_table"
export APK_POLICY_MODE=format
export APK_UPDATE_RC=0
export APK_ADD_RC=0
export FETCH_CALLS="$fetch_calls"
export FETCH_DOWN=""

# run <args...>: the tool, with this fixture as the machine it believes it is on.
run() {
  AB_PACKAGES_ROOT="$site" \
    AB_PLUGINS_ROOT="$site" \
    AB_PACKAGES_LIB="$packages_lib" \
    AB_PKGS_ASSETS_LIB="$root/platform/lib/ab-pkgs-assets.sh" \
    AB_PLAN_LIB="$root/platform/lib/ab-plan.sh" \
    AB_PLUGINS_LIB="$plugins_lib" \
    AB_ESP="$site/boot" \
    AB_PACKAGES_FILE="$site/boot/ab/packages" \
    PATH="$bin:$PATH" \
    sh "$runner" "$@"
}

out=""
rc=0
call() {
  out=$(run "$@" 2>&1)
  rc=$?
}

# shadow_table <name> <plugin version> <plugin feed>: the world name offered by both the
# installed database and a plugin's feed, which is the only shape a shadow can have.
shadow_table() {
  cat >"$policy_table" <<TABLE
$1 3.3.0-r1 lib/apk/db/installed
$1 $2 $3
TABLE
}

verdict_of() {
  sed -n 's/^verdict=//p' "$site/etc/ab/plugins.d/$1/.verdict" 2>/dev/null
}

reason_of() {
  sed -n 's/^reason=//p' "$site/etc/ab/plugins.d/$1/.verdict" 2>/dev/null
}

# apk_calls_matching <pattern>: how many journalled apk invocations contain it.
apk_calls_matching() {
  grep -c -- "$1" "$apk_calls" 2>/dev/null || true
}

# --- plugins list: one line per plugin, and the state of each check ---------
call plugins list
assert_eq "$rc" "0" "plugins list exits 0"
assert_eq "$out" "label=alpha kind=source enabled=yes checked=ok reason=none feeds=1 packages=0
label=beta kind=source enabled=no checked=ok reason=none feeds=1 packages=0
label=delta kind=source enabled=yes checked=stale reason=none feeds=1 packages=0
label=epsilon kind=source enabled=yes checked=blocked reason=shadow:htop feeds=1 packages=0
label=gamma kind=source enabled=yes checked=never reason=none feeds=1 packages=0
label=zeta kind=packages enabled=yes checked=never reason=none feeds=1 packages=2" \
  "list reports ok, never, stale and blocked, and the enabled switch, on one line each"

# --- plugins repos: base lines first, then only what a transaction may read --
call plugins repos
assert_eq "$rc" "0" "plugins repos exits 0"
assert_contains "$out" "https://base.invalid/releases/25.12.2/targets/x86/64/packages/packages.adb" \
  "repos carries the machine's own feed"
assert_eq "$(printf '%s\n' "$out" | grep -E '^(https?://|#)' | head -n 1)" \
  "https://base.invalid/releases/25.12.2/targets/x86/64/packages/packages.adb" \
  "the machine's own feed comes first, so the base wins a tie"
assert_eq "$(printf '%s\n' "$out" | grep -E '^(https?://)' | tail -n 1)" \
  "https://plug.invalid/feed" "the checked plugin's feed follows the base"
assert_eq "$(printf '%s\n' "$out" | grep -cE 'off\.invalid|stale\.invalid|shadowed\.invalid|gone\.invalid' || true)" \
  "0" "a disabled, stale, blocked or never-checked plugin contributes nothing"
assert_contains "$out" "plugin feed(s) from 1 plugin(s)" "repos says how much of it is plugins"

# --- ac-1/ac-7: a feed that does not answer blocks the plugin ---------------
mkplugin unreach <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://down.invalid/feed
CONF
FETCH_DOWN="https://down.invalid/feed"
call plugins check unreach
FETCH_DOWN=""
assert_eq "$rc" "74" "an unreachable feed is a refusal, not a success"
assert_contains "$out" "plugin=unreach verdict=blocked reason=feed-unreachable" \
  "the blocked line names the token"
assert_eq "$(verdict_of unreach)" "blocked" "the verdict records blocked"
assert_eq "$(reason_of unreach)" "feed-unreachable" "the verdict keeps the reason"
assert_eq "$(apk_calls_matching 'policy')" "0" \
  "a feed that does not answer costs no apk call: the question was already answered"

# --- ac-1: a declaration the static checker refuses never reaches the network --
mkplugin badkind <<'CONF'
api = 1
kind = files
CONF
call plugins check badkind
assert_eq "$rc" "74" "a static refusal exits 74"
assert_contains "$out" "plugin=badkind verdict=blocked reason=plugin-kind-invalid" \
  "the static token reaches the caller unchanged"
assert_eq "$(printf '%s\n' "$out" | grep -c 'did not answer' || true)" "0" \
  "nothing was fetched for a declaration that cannot be used"

# --- M3: a package name is a word on an `apk add` line, not an option --------
# `package = -X` passes a static check that only looks at the key, and the value then reaches
# apk as a word: `-X` is a repository option, `--allow-untrusted` is the whole trust guardrail.
# Both are refused as names, and nothing is handed to apk for them.
mkplugin optname <<'CONF'
api = 1
kind = packages
enabled = yes
package = -X
CONF
: >"$apk_calls"
call plugins check optname
assert_eq "$rc" "74" "a package name that is an apk option is refused by the check"
assert_contains "$out" "plugin=optname verdict=blocked reason=plugin-package-invalid" \
  "the token names the shape, not a crash"
assert_eq "$(verdict_of optname)" "blocked" "and the refusal is on the record"
call plugins apply optname --yes
assert_eq "$rc" "74" "apply refuses the same declaration"
assert_contains "$out" "reason=plugin-package-invalid" "the token reaches apply unchanged"
assert_eq "$(apk_calls_matching 'add')" "0" \
  "apk was never handed the option, with or without --yes"

mkplugin longoptname <<'CONF'
api = 1
kind = packages
enabled = yes
package = --allow-untrusted
CONF
: >"$apk_calls"
call plugins apply longoptname --yes
assert_eq "$rc" "74" "an apk permission dressed as a package name is refused too"
assert_contains "$out" "reason=plugin-package-invalid" "and by the same token"
assert_eq "$(apk_calls_matching 'add')" "0" "and apk was not run at all"

mkplugin twowords <<'CONF'
api = 1
kind = packages
enabled = yes
package = a b
CONF
: >"$apk_calls"
call plugins apply twowords --yes
assert_eq "$rc" "74" "a name with a blank in it is two names, and is refused"
assert_eq "$(apk_calls_matching 'add')" "0" "so nothing is installed for it"

# --- ac-4: shadow, and the permission that accepts it -----------------------
mkplugin shadower <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://shadow.invalid/feed
CONF
shadow_table htop 3.4.0-r1 https://shadow.invalid/feed
call plugins check shadower
assert_eq "$rc" "74" "a plugin that offers a higher version of a world name is blocked"
assert_contains "$out" "plugin=shadower verdict=blocked reason=shadow:htop" \
  "the token names the shadowed package"
assert_eq "$(reason_of shadower)" "shadow:htop" "the verdict carries the shadow token"

# The same declaration, with the permission the token asks for. It is a new check, so the
# digest matches again and the plugin may contribute.
mkplugin shadower <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://shadow.invalid/feed
allow-shadow = yes
CONF
call plugins check shadower
assert_eq "$rc" "0" "allow-shadow = yes admits the same plugin"
assert_contains "$out" "plugin=shadower verdict=ok reason=shadow-allowed" \
  "the verdict records that the shadow was allowed rather than unnoticed"
assert_eq "$(verdict_of shadower)" "ok" "the verdict is ok"
assert_eq "$(reason_of shadower)" "shadow-allowed" "the permission is on the record"

# The other end: the plugin's version is older than the base's, which is not a shadow at all.
mkplugin older <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://older.invalid/feed
CONF
shadow_table htop 3.2.0-r1 https://older.invalid/feed
call plugins check older
assert_eq "$rc" "0" "a lower version than the base is not a shadow"
assert_contains "$out" "plugin=older verdict=ok reason=none" "and the check says so plainly"

# --- ac-4: an answer that could not be read is unverifiable, never "no shadow" --
: >"$policy_table"
APK_POLICY_MODE=garbage
call plugins check older
APK_POLICY_MODE=format
assert_eq "$rc" "74" "unreadable apk policy output is a refusal"
assert_contains "$out" "plugin=older verdict=blocked reason=unverifiable" \
  "the token is unverifiable rather than a quiet ok"
assert_eq "$(reason_of older)" "unverifiable" "and it is on the record that way"

APK_UPDATE_RC=1
shadow_table htop 3.4.0-r1 https://older.invalid/feed
call plugins check older
APK_UPDATE_RC=0
assert_contains "$out" "plugin=older verdict=blocked reason=unverifiable" \
  "an index that could not be fetched is unverifiable too"

# --- M4: a verdict that could not be written is not a check that passed -----
# The verdict file is what every later transaction reads, so an `ok` on screen without the file
# behind it would be a promise nothing keeps. The write is made to fail as a *directory* named
# .verdict: `> .verdict` cannot replace a directory even for uid 0, which is the one way to be
# unwritable whatever user these tests run as.
mkplugin noquill <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://noquill.invalid/feed
CONF
mkdir -p "$site/etc/ab/plugins.d/noquill/.verdict"
: >"$policy_table"
printf '%s\n' 'htop 3.3.0-r1 lib/apk/db/installed' >"$policy_table"
call plugins check noquill
assert_eq "$rc" "74" "a check whose verdict could not be recorded is not a success"
assert_contains "$out" "plugin=noquill verdict=ok reason=verdict-unwritable" \
  "the answer says the verdict never reached the disk"
assert_eq "$(verdict_of noquill)" "" "nothing was written where the verdict belongs"

# The blocked half: the refusal still exits 74 with the reason it found, and the line also says
# that the refusal was not recorded - a later transaction will read whatever it read before.
rm -rf "$site/etc/ab/plugins.d/noquill"
mkplugin noquill2 <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://noquill2.invalid/feed
CONF
mkdir -p "$site/etc/ab/plugins.d/noquill2/.verdict"
FETCH_DOWN="https://noquill2.invalid/feed"
call plugins check noquill2
FETCH_DOWN=""
assert_eq "$rc" "74" "a blocked check stays blocked when its verdict cannot be recorded"
assert_contains "$out" "plugin=noquill2 verdict=blocked reason=feed-unreachable verdict-write=failed" \
  "and the line says the verdict was not written, next to the reason it found"
rm -rf "$site/etc/ab/plugins.d/noquill2" "$site/etc/ab/plugins.d/noquill"

# --- m3: a world that cannot be read is unverifiable, never "no shadow" -----
# The shadow question is asked over the names the world holds. "There is no world" and "the
# world is there and could not be read" are two different facts, and only the first one means
# there is nothing to shadow. A world that exists and cannot be read is a question nobody
# answered, so it is `unverifiable` - the same answer an unreadable apk policy gives.
# A directory where the world should be is the one shape that is unreadable whatever user the
# tests run as (mode bits do not stop root).
mkplugin noworld <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://noworld.invalid/feed
CONF
mv "$site/etc/apk/world" "$tmp/world.bak"
mkdir -p "$site/etc/apk/world"
: >"$policy_table"
printf '%s\n' 'htop 3.3.0-r1 lib/apk/db/installed' >"$policy_table"
call plugins check noworld
assert_eq "$rc" "74" "a world that exists and cannot be read is a refusal"
assert_contains "$out" "plugin=noworld verdict=blocked reason=unverifiable" \
  "the answer is unverifiable, not the quiet 'no shadow'"
assert_eq "$(reason_of noworld)" "unverifiable" "and that is what the verdict says"
rm -rf "$site/etc/ab/plugins.d/noworld"
rmdir "$site/etc/apk/world"
mv "$tmp/world.bak" "$site/etc/apk/world"

# --- ac-6: apply is one transaction, behind the question --------------------
: >"$apk_calls"
call plugins apply zeta
assert_eq "$rc" "74" "apply without a terminal and without --yes exits 74"
assert_contains "$out" "reason=noninteractive" "and says why it stopped"
assert_eq "$(apk_calls_matching 'add')" "0" "nothing was installed before the question"

: >"$apk_calls"
out=$(printf 'n\n' | AB_PLAN_ASSUME_TTY=1 run plugins apply zeta 2>&1)
rc=$?
assert_eq "$rc" "0" "declining the question is not a failure"
assert_contains "$out" "reason=declined" "the decline is named"
assert_eq "$(apk_calls_matching 'add')" "0" "a declined question installs nothing"

: >"$apk_calls"
out=$(printf 'y\n' | AB_PLAN_ASSUME_TTY=1 run plugins apply zeta 2>&1)
rc=$?
assert_eq "$rc" "0" "answering y installs what the plugin names"
assert_eq "$(apk_calls_matching 'add')" "1" "one transaction, not one per package"
assert_contains "$(cat "$apk_calls")" "add htop tmux" "apk is given the declared names"
assert_contains "$(cat "$apk_calls")" "--repositories-file" \
  "the transaction reads the repositories file the plugin needs"
assert_contains "$out" "plugin=zeta result=installed packages=2" "the result names the plugin"

: >"$apk_calls"
call plugins apply zeta --yes
assert_eq "$rc" "0" "--yes installs without asking"
assert_eq "$(apk_calls_matching 'add')" "1" "--yes is still exactly one transaction"
assert_contains "$(cat "$apk_calls")" "--repositories-file" "--yes reads the same repositories file"

# A failed transaction is reported with apk's status, and nothing pretends otherwise.
: >"$apk_calls"
APK_ADD_RC=3
call plugins apply zeta --yes
APK_ADD_RC=0
assert_eq "$rc" "1" "a failed apk transaction exits 1"
assert_contains "$out" "plugin=zeta result=failed reason=apk-3" "the reason carries apk's status"

# A plugin with feeds and no package has nothing to install, and that is a working plugin.
: >"$apk_calls"
call plugins apply alpha --yes
assert_eq "$rc" "0" "a source-only plugin installs nothing and is not a failure"
assert_contains "$out" "plugin=alpha result=nothing-to-install reason=plugin-nothing-to-install" \
  "the token says there was nothing to install"
assert_eq "$(apk_calls_matching 'add')" "0" "and apk was not run at all"

# --- ac-6: nothing is ever written to the world record ----------------------
# "no world record" is two facts, and the first one is the one this tool is about: the file is
# not there at all. Reading it with `cat` would have made "no such file" look like an empty one.
assert_eq "$([ -e "$site/boot/ab/packages" ] && echo present || echo absent)" "absent" \
  "apply writes no world record at all: that line describes a whole-world follow"

# --- ac-8: sources attributes a plugin's feed -------------------------------
# Two questions, because one cannot answer: `ab_pkgs_policy_sources` asks apk against /etc/apk,
# and a plugin's feeds are in no file there by design - that answer alone can never name a
# plugin on a real machine. So when a plugin contributes, the same question is asked again
# against the file a transaction would read, and the URL is attributed from there.
: >"$apk_calls"
: >"$repos_seen"
shadow_table htop 3.4.0-r1 https://plug.invalid/feed
call sources htop
assert_eq "$rc" "0" "sources answers for a package a plugin's feed carries"
assert_contains "$(cat "$apk_calls")" "--repositories-file" \
  "the attribution question is asked against the file that carries the plugin's feed"
assert_contains "$(cat "$repos_seen")" "https://plug.invalid/feed" \
  "and that file holds the plugin's URL on a line of its own"
assert_contains "$out" "package=htop source=plugin:alpha url=https://plug.invalid/feed" \
  "the URL is attributed to the plugin that declared it"
assert_contains "$out" "url=https://plug.invalid/feed" "and the URL is printed in full"

# The switch is the authority: a feed of a disabled plugin keeps the old attribution rather
# than claiming a plugin the user turned off.
: >"$repos_seen"
shadow_table htop 3.4.0-r1 https://off.invalid/feed
call sources htop
assert_contains "$out" "package=htop source=feed url=https://off.invalid/feed" \
  "a disabled plugin's feed is not attributed to it"
assert_eq "$(printf '%s\n' "$out" | grep -c 'plugin:beta' || true)" "0" \
  "and the disabled label is never named"

# --- the retry of one package reads the same repositories as the follow -----
: >"$apk_calls"
call update --only htop --yes
assert_eq "$(apk_calls_matching 'upgrade htop')" "1" "update --only runs one upgrade"
assert_contains "$(cat "$apk_calls")" "--repositories-file" \
  "the one-package retry carries the same repositories file as the follow"

# --- the empty machine, and check with no arguments -------------------------
# Nothing declared is not an error and must not read as one: `plugins=none` is the token a
# script tests, and both read-only commands still answer.
mv "$site/etc/ab/plugins.d" "$tmp/plugins.d.bak"
mkdir -p "$site/etc/ab/plugins.d"
call plugins list
assert_eq "$rc" "0" "plugins list exits 0 when nothing is declared"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" "plugins=none" \
  "list answers with the token instead of nothing at all"
call plugins check
assert_eq "$rc" "0" "checking nothing is not a failure"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" "plugins=none" \
  "check answers with the same token (and explains itself on stderr)"
: >"$apk_calls"
call plugins repos
assert_eq "$rc" "0" "repos answers on a machine with no plugins"
assert_eq "$(printf '%s\n' "$out" | grep -c '^https://base.invalid')" "1" \
  "the file it printed is the machine's own feed and nothing else"
assert_contains "$out" "plugins=none" "and says that nothing was added to the file it printed"
assert_eq "$(apk_calls_matching 'update')" "0" "repos ran no apk: it only assembles the file"

# And the second `apk policy` question an attribution needs does not happen at all here: with
# nothing declared there is one view of this machine's feeds, and a second call would only ask
# apk the same question twice (ac-9).
: >"$apk_calls"
call sources htop
assert_eq "$rc" "0" "sources answers on a machine with no plugin"
assert_eq "$(apk_calls_matching 'policy')" "1" \
  "exactly one apk policy call for one name: nothing declared, nothing to ask twice"
assert_eq "$(grep -c -- '--repositories-file' "$apk_calls" || true)" "0" \
  "and that one call is the one this command has always made"

# The seam answers "empty" for a machine with no feed file at all, and that is a fact about the
# machine rather than a failure to write: the command still prints and still exits 0.
mv "$site/etc/apk/repositories.d/distfeeds.list" "$tmp/distfeeds.list.bak"
call plugins repos
assert_eq "$rc" "0" "a machine with no feed file still answers"
assert_eq "$(printf '%s\n' "$out" | grep -c '^https://')" "0" "and the file it prints is empty"
mv "$tmp/distfeeds.list.bak" "$site/etc/apk/repositories.d/distfeeds.list"

# No argument means every declared plugin, which is the form the documentation offers.
mkplugin first <<'CONF'
api = 1
kind = source
feed = https://plug.invalid/feed
CONF
mkplugin second <<'CONF'
api = 1
kind = source
feed = https://plug.invalid/second
CONF
: >"$policy_table"
# One readable `apk policy` answer with no plugin source in it: the base offers htop and no
# candidate does, so the answer to the shadow question is a plain "none".
printf '%s\n' 'htop 3.3.0-r1 lib/apk/db/installed' >"$policy_table"
call plugins check
assert_eq "$rc" "0" "check with no arguments exits 0 when every plugin is fine"
assert_contains "$out" "plugin=first verdict=ok reason=none" "it checks the first declaration"
assert_contains "$out" "plugin=second verdict=ok reason=none" "and the second, without being told"
assert_eq "$(printf '%s\n' "$out" | grep -c '^plugin=')" "2" "one line per declared plugin"
rm -rf "$site/etc/ab/plugins.d"
mv "$tmp/plugins.d.bak" "$site/etc/ab/plugins.d"

# --- M1: the running root is never named with --root ------------------------
# `--root` is what makes apk treat a tree as a sandbox; a transaction against the machine this
# tool runs on must not be one, and a machine that is a fixture must be named. Both halves are
# asked of the one function that decides it, with the tool loaded but its `main` not run, and of
# the source, which must carry no hardcoded --root at any call site.
nomains="$tmp/ab-packages-nomain.sh"
grep -v '^main "$@"$' "$cli" >"$nomains"
root_args() {
  AB_PACKAGES_ROOT="$1" sh -c '. "$1"; _plugins_apk_root_args; printf "|"' _ "$nomains" \
    | tr -d '\n'
}
assert_eq "$(root_args /)" "|" "the running root is named with no --root at all"
assert_eq "$(root_args "$site")" "--root $site|" \
  "a fixture tree is named with --root, and only then"
assert_eq "$(grep -c 'apk --root' "$cli" || true)" "0" \
  "no call site hardcodes --root: every one asks the function above"
# The other side of the same rule: the fixture's transactions do carry it, so the empty answer
# above is a decision and not a function nobody calls.
: >"$apk_calls"
call plugins check alpha
assert_contains "$(cat "$apk_calls")" "--root $site" \
  "and a transaction against the fixture tree does name it"

# --- ac-3: no subcommand touched the machine's own feeds -------------------
assert_eq "$(cat "$site/etc/apk/world")" "$world_before" "the world is byte-identical"
assert_eq "$(cat "$site/etc/apk/repositories.d/distfeeds.list")" "$feeds_before" \
  "distfeeds.list is byte-identical"
assert_eq "$(ls "$site/etc/apk/repositories.d")" "$feeds_ls_before" \
  "no repository file was created or removed"

finish
