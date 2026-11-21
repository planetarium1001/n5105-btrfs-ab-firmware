#!/usr/bin/env bash
# Module: plugins
# The recipes that ship with the platform layer: they are data, so a test is what keeps them
# from rotting into something the plugin library would refuse.
#
# The subject is docs/examples/plugins/istore/plugin.conf, the recipe a machine's owner copies
# into /etc/ab/plugins.d/ - the image itself carries no declaration. Two
# properties matter and neither is visible by reading the file:
#
#   ac-1 the shape: the declaration validates, ships disabled, names three feeds and one
#        package. A typo in a key name is refused by the library at runtime - on a machine,
#        by an operator, after an upgrade - so it is cheaper to catch it here.
#   ac-4 the contribution: while it is disabled it adds nothing to a transaction; once it is
#        enabled *and* checked, it adds exactly its feeds, after the machine's own; and if the
#        declaration changes after that check, it contributes nothing again (fail-closed).
#
# Nothing here reaches the network or apk: the recipe is judged as text, which is the same
# rule the library follows.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-plugins.sh"
recipe="$root/docs/examples/plugins/istore/plugin.conf"
if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the plugin library exists\n' >&2
  exit 1
fi
if [ ! -f "$recipe" ]; then
  printf 'not ok 1 - the iStore recipe is documented as an example to copy\n' >&2
  printf '    missing %s\n' "$recipe" >&2
  exit 1
fi
# shellcheck source=../../../platform/lib/ab-plugins.sh
source "$lib"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The recipe declares a key path that lives on a booted machine, so a fixture root carries a
# stand-in: the library checks existence, and that is the whole contract it promises.
site="$tmp/site"
mkdir -p "$site/etc/ab/plugins.d/istore" "$site/etc/apk/keys"
cp "$recipe" "$site/etc/ab/plugins.d/istore/plugin.conf"
: >"$site/etc/apk/keys/istore-apk.pem"

# --- ac-1: the shipped shape -------------------------------------------------
assert_eq "$(grep -c '^enabled=no$' "$recipe")" "1" \
  "the example arrives disabled: a third-party store is the operator's decision, not a default"

AB_PLUGINS_REASON=""
if ab_plugins_validate "$site" istore; then
  validated=ok
else
  validated="refused:${AB_PLUGINS_REASON}"
fi
assert_eq "$validated" "ok" "the documented declaration passes the static rules"
assert_eq "$AB_PLUGINS_KIND" "packages" "it is a package set, so apply has something to install"
assert_eq "$AB_PLUGINS_ENABLED" "no" "and it stays off until someone says otherwise"
assert_eq "$AB_PLUGINS_FEED_COUNT" "3" "three feeds: store, compat, meta"
assert_eq "$AB_PLUGINS_PACKAGE_COUNT" "1" "one named package; apk resolves the rest"

assert_eq "$(ab_plugins_feeds "$site" istore | tr '\n' ' ')" \
  "https://istore.istoreos.com/repo-apk/all/store/packages.adb https://istore.istoreos.com/repo-apk/all/compat/packages.adb https://istore.istoreos.com/repo-apk/all/meta/packages.adb " \
  "the feeds keep the order the recipe lists them, which is the order apk reads"

# --- ac-4: what the recipe contributes ---------------------------------------
repos="$tmp/repos"
printf 'https://base.invalid/releases/25.12.2/packages/x86_64/base/packages.adb\n' >"$repos"
ab_plugins_repos_append "$site" "$repos"
assert_eq "$(wc -l <"$repos" | tr -d ' ')" "1" \
  "a disabled recipe contributes nothing: the machine's own feed is the whole file"

assert_eq "$(ab_plugins_verdict_state "$site" istore)" "never" \
  "and nothing has been checked, which is the state a fresh machine is in"

# Enabled and checked: this is the state an operator reaches with three documented commands.
sed -i.bak 's/^enabled=no$/enabled=yes/' "$site/etc/ab/plugins.d/istore/plugin.conf"
assert_eq "$(ab_plugins_verdict_state "$site" istore)" "never" \
  "enabling alone is not a check: a machine with no verdict still contributes nothing"
ab_plugins_verdict_write "$site" istore ok none
assert_eq "$(ab_plugins_verdict_state "$site" istore)" "ok" "after a check it reads ok"

printf 'https://base.invalid/releases/25.12.2/packages/x86_64/base/packages.adb\n' >"$repos"
ab_plugins_repos_append "$site" "$repos"
assert_eq "$(wc -l <"$repos" | tr -d ' ')" "4" \
  "an enabled, checked recipe adds exactly its three feeds"
assert_eq "$(sed -n '1p' "$repos")" "https://base.invalid/releases/25.12.2/packages/x86_64/base/packages.adb" \
  "the base feed stays first: apk reads top to bottom and the base must win a tie"
assert_eq "$(sed -n '2p' "$repos")" "https://istore.istoreos.com/repo-apk/all/store/packages.adb" \
  "then the store feed"

# The digest is what makes "checked" mean "checked for this text": an edit after the check
# takes the feeds back out without anyone remembering to re-check.
printf 'feed = https://istore.istoreos.com/repo-apk/all/extra/packages.adb\n' >>"$site/etc/ab/plugins.d/istore/plugin.conf"
printf 'https://base.invalid/releases/25.12.2/packages/x86_64/base/packages.adb\n' >"$repos"
ab_plugins_repos_append "$site" "$repos"
assert_eq "$(wc -l <"$repos" | tr -d ' ')" "1" \
  "an edited declaration contributes nothing until it is checked again"

finish
