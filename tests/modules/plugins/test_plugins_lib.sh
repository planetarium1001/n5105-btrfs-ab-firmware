#!/usr/bin/env bash
# Module: plugins
# The plugin library: what a plugin declaration is allowed to say, and what it contributes.
#
# The subject is the contract in prd.md ac-1/ac-2/ac-5 and design.md §2/§3/§6: a plugin is a
# directory of key=value declarations, the library is a pure function of files (no apk, no
# network, no writes except the verdict it is asked to write), and the set it contributes to a
# transaction is exactly "enabled=yes and verdict=ok and the conf has not changed since".
#
#   ac-1 the static verdict: one reason token per failure, and the first failure is the one
#        reported - a config that is wrong in two ways must not answer with a token that
#        depends on hash order.
#   ac-2 the contributed set: base lines stay first, plugin lines follow in label order, and a
#        plugin whose conf changed after its check contributes nothing (fail-closed).
#   ac-5 the two static guards: kernel modules and architecture-bound feeds are refused by
#        default and admitted only when the declaration says so.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-plugins.sh"
if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the plugin library exists\n' >&2
  printf '    missing %s\n' "$lib" >&2
  exit 1
fi
# shellcheck source=../../../platform/lib/ab-plugins.sh
source "$lib"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# mksite <name>: a machine root with one empty plugins.d, printed on stdout.
mksite() {
  local site="$tmp/$1"
  mkdir -p "$site/etc/ab/plugins.d"
  printf '%s' "$site"
}

# mkplugin <site> <label> <<'CONF': write one plugin.conf.
mkplugin() {
  local site=$1 label=$2
  mkdir -p "$site/etc/ab/plugins.d/$label"
  cat >"$site/etc/ab/plugins.d/$label/plugin.conf"
}

# reason <site> <label>: the library's answer for one plugin, as a bare token.
reason() {
  local site=$1 label=$2
  AB_PLUGINS_REASON=""
  if ab_plugins_validate "$site" "$label"; then
    printf 'ok'
  else
    printf '%s' "$AB_PLUGINS_REASON"
  fi
}

site=$(mksite static)
mkdir -p "$site/etc/apk/keys"
: >"$site/etc/apk/keys/demo.pem"

# --- ac-1: a well-formed declaration of each kind -----------------------------
mkplugin "$site" good-source <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://example.invalid/base
feed = https://example.invalid/extra
key = /etc/apk/keys/demo.pem
arch = noarch
allow-shadow = no
allow-kmod = no
CONF
assert_eq "$(reason "$site" good-source)" "ok" "a source plugin with two feeds validates"

mkplugin "$site" good-packages <<'CONF'
api = 1
kind = packages
enabled = no
package = htop
package = tmux
CONF
assert_eq "$(reason "$site" good-packages)" "ok" "a package set with two names validates"

# --- ac-1: one token per way of being wrong -----------------------------------
mkplugin "$site" bad-api <<'CONF'
api = 2
kind = source
feed = https://example.invalid/base
CONF
assert_eq "$(reason "$site" bad-api)" "plugin-api-unsupported" "api other than 1 is refused"

mkplugin "$site" bad-kind <<'CONF'
api = 1
kind = files
CONF
assert_eq "$(reason "$site" bad-kind)" "plugin-kind-invalid" "an unknown kind is refused"

mkplugin "$site" bad-enabled <<'CONF'
api = 1
kind = source
enabled = maybe
feed = https://example.invalid/base
CONF
assert_eq "$(reason "$site" bad-enabled)" "plugin-enabled-invalid" "enabled must be yes or no"

mkplugin "$site" no-feed <<'CONF'
api = 1
kind = source
enabled = yes
CONF
assert_eq "$(reason "$site" no-feed)" "plugin-no-feed" "a source plugin without a feed is refused"

mkplugin "$site" no-package <<'CONF'
api = 1
kind = packages
enabled = yes
feed = https://example.invalid/base
CONF
assert_eq "$(reason "$site" no-package)" "plugin-no-package" "a package set without names is refused"

mkplugin "$site" bad-scheme <<'CONF'
api = 1
kind = source
feed = ftp://example.invalid/base
CONF
assert_eq "$(reason "$site" bad-scheme)" "plugin-feed-scheme" "only http(s) feeds are admitted"

# The key is a typo of `package`: it must not be silently ignored, because a plugin that
# declares nothing and says nothing is indistinguishable from one that works.
mkplugin "$site" unknown-key <<'CONF'
api = 1
kind = packages
package = htop
pakage = tmux
CONF
assert_eq "$(reason "$site" unknown-key)" "plugin-unknown-key" "an unknown key is refused, not ignored"

mkplugin "$site" missing-key <<'CONF'
api = 1
kind = source
feed = https://example.invalid/base
key = /etc/apk/keys/absent.pem
CONF
assert_eq "$(reason "$site" missing-key)" "plugin-key-missing" "a declared key must exist"

mkplugin "$site" outside-key <<'CONF'
api = 1
kind = source
feed = https://example.invalid/base
key = /tmp/elsewhere.pem
CONF
assert_eq "$(reason "$site" outside-key)" "plugin-key-outside" "a key outside /etc/apk/keys is refused"

# Two failures at once: the answer is the first one in the checker's own order, so that the
# message a user reads does not depend on which file happens to be read first.
mkplugin "$site" two-faults <<'CONF'
api = 1
kind = source
enabled = maybe
feed = ftp://example.invalid/base
CONF
assert_eq "$(reason "$site" two-faults)" "plugin-enabled-invalid" "the first fault is the one reported"

mkdir -p "$site/etc/ab/plugins.d/empty-dir"
assert_eq "$(reason "$site" empty-dir)" "plugin-conf-missing" "a plugin directory without plugin.conf is refused"
assert_eq "$(reason "$site" Not_A_Label)" "plugin-label-invalid" "a label apk tooling cannot quote is refused"

# --- ac-5: the two static guards ----------------------------------------------
mkplugin "$site" kmods-feed <<'CONF'
api = 1
kind = source
feed = https://example.invalid/releases/25.12.0/kmods/0413601b1c3f0490/kmods
CONF
assert_eq "$(reason "$site" kmods-feed)" "plugin-feed-kmods" "a kmods feed is refused by default"

mkplugin "$site" kmods-allowed <<'CONF'
api = 1
kind = source
feed = https://example.invalid/releases/25.12.0/kmods/0413601b1c3f0490/kmods
allow-kmod = yes
CONF
assert_eq "$(reason "$site" kmods-allowed)" "ok" "allow-kmod=yes admits a kmods feed"

mkplugin "$site" arch-feed <<'CONF'
api = 1
kind = source
feed = https://example.invalid/targets/x86_64/packages
CONF
assert_eq "$(reason "$site" arch-feed)" "plugin-feed-arch" "an architecture-bound feed is refused under arch=noarch"

mkplugin "$site" kmod-package <<'CONF'
api = 1
kind = packages
package = htop
package = kmod-usb-storage
CONF
assert_eq "$(reason "$site" kmod-package)" "plugin-package-kmod" "a kernel module package is refused by default"

mkplugin "$site" kmod-package-allowed <<'CONF'
api = 1
kind = packages
package = kmod-usb-storage
allow-kmod = yes
CONF
assert_eq "$(reason "$site" kmod-package-allowed)" "ok" "allow-kmod=yes admits a kernel module package"

# --- ac-1: a package name is a word on an `apk add` line ----------------------
# The names a declaration gives reach apk as arguments, so the shape of a name is part of the
# static contract: `-X` is an option, not a package, and `a b` is two words pretending to be
# one. Each of these would otherwise hand apk a permission no guardrail grants (the first two)
# or a second package the declaration never declared (the last).
mkplugin "$site" pkg-option <<'CONF'
api = 1
kind = packages
package = -X
CONF
assert_eq "$(reason "$site" pkg-option)" "plugin-package-invalid" \
  "a package name that starts with - is an option, and is refused"

mkplugin "$site" pkg-longopt <<'CONF'
api = 1
kind = packages
package = --allow-untrusted
CONF
assert_eq "$(reason "$site" pkg-longopt)" "plugin-package-invalid" \
  "an apk option dressed as a package name is refused"

mkplugin "$site" pkg-two-words <<'CONF'
api = 1
kind = packages
package = a b
CONF
assert_eq "$(reason "$site" pkg-two-words)" "plugin-package-invalid" \
  "a name with a blank in it is two packages, and is refused"

# The other half of the same rule: the names apk actually uses must still pass, including the
# punctuation apk allows between the characters.
mkplugin "$site" pkg-charset <<'CONF'
api = 1
kind = packages
package = luci-app-demo
package = htop
package = my_pkg.v2+git1
CONF
assert_eq "$(reason "$site" pkg-charset)" "ok" \
  "dots, underscores and plus signs are apk package names and are admitted"

mkplugin "$site" pkg-lead-dot <<'CONF'
api = 1
kind = packages
package = .hidden
CONF
assert_eq "$(reason "$site" pkg-lead-dot)" "plugin-package-invalid" \
  "an apk name has to start with a letter or a digit"

# The rule is about the value, not about the kind that carries it: a `kind = source`
# declaration may name packages too, and those reach the same `apk add`.
mkplugin "$site" source-with-option <<'CONF'
api = 1
kind = source
feed = https://example.invalid/base
package = --force-broken-world
CONF
assert_eq "$(reason "$site" source-with-option)" "plugin-package-invalid" \
  "a package line of a source plugin is held to the same name rule"

# --- ac-5: a feed is one directory, not a list --------------------------------
# A feed URL becomes a line of the repositories file apk reads, and apk splits that line on
# blanks: a declaration with a blank in it would add a second source the scheme rule never saw.
mkplugin "$site" feed-blank <<'CONF'
api = 1
kind = source
feed = https://example.invalid/base https://elsewhere.invalid/other
CONF
assert_eq "$(reason "$site" feed-blank)" "plugin-feed-scheme" \
  "a feed URL containing a blank is refused rather than split into two sources"

# --- ac-2: what the set contributes ------------------------------------------
set2=$(mksite inject)
mkplugin "$set2" alpha <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://alpha.invalid/feed
feed = https://alpha.invalid/extra
CONF
mkplugin "$set2" beta <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://beta.invalid/feed
CONF
mkplugin "$set2" gamma <<'CONF'
api = 1
kind = source
enabled = no
feed = https://gamma.invalid/feed
CONF
mkplugin "$set2" delta <<'CONF'
api = 1
kind = source
enabled = yes
feed = https://delta.invalid/feed
CONF
mkplugin "$set2" epsilon <<'CONF'
api = 1
kind = source
feed = https://epsilon.invalid/feed
CONF

pdir="$set2/etc/ab/plugins.d"
ab_plugins_verdict_write "$set2" alpha ok none
ab_plugins_verdict_write "$set2" beta blocked shadow:htop
ab_plugins_verdict_write "$set2" gamma ok none
ab_plugins_verdict_write "$set2" delta ok none
ab_plugins_verdict_write "$set2" epsilon ok none
# delta is checked, then its declaration changes: the verdict no longer speaks for it.
printf 'feed = https://delta.invalid/new-feed\n' >>"$pdir/delta/plugin.conf"

assert_eq "$(ab_plugins_verdict_state "$set2" alpha)" "ok" "a fresh verdict reads back as ok"
assert_eq "$(ab_plugins_verdict_state "$set2" beta)" "blocked" "a blocked verdict reads back as blocked"
assert_eq "$(ab_plugins_verdict_state "$set2" delta)" "stale" "a conf changed after the check is stale"
assert_eq "$(ab_plugins_verdict_state "$set2" gamma)" "ok" "the verdict is written whether or not the plugin is enabled"

repos="$tmp/repos"
printf 'https://base.invalid/releases/25.12.0/packages\n' >"$repos"
ab_plugins_repos_append "$set2" "$repos"
assert_eq "$(cat "$repos")" "https://base.invalid/releases/25.12.0/packages
https://alpha.invalid/feed
https://alpha.invalid/extra
https://epsilon.invalid/feed" "only an enabled, verified, unchanged plugin contributes, in label order"

# The count a caller reports must be the same set: an operator asking "what did this
# transaction read" gets one answer from the file and the journals.
assert_eq "$(ab_plugins_active_count "$set2")" "2" "two plugins contribute"
assert_eq "$(ab_plugins_active_feeds "$set2" | wc -l | tr -d ' ')" "3" "together they contribute three feeds"

# A plugin with no verdict at all is not "probably fine": nothing is injected until someone
# has checked it, which is what makes the shadow question answerable before the machine runs.
set3=$(mksite never)
mkplugin "$set3" fresh <<'CONF'
api = 1
kind = source
feed = https://fresh.invalid/feed
CONF
repos3="$tmp/repos3"
: >"$repos3"
ab_plugins_repos_append "$set3" "$repos3"
assert_eq "$(ab_plugins_verdict_state "$set3" fresh)" "never" "an unchecked plugin is never"
assert_eq "$(cat "$repos3")" "" "an unchecked plugin contributes nothing"

# A blocked verdict keeps the declaration but not the feed, and the reason survives for the
# operator who asks why.
ab_plugins_verdict_write "$set3" fresh blocked shadow:diskman
assert_eq "$(ab_plugins_describe "$set3" fresh)" \
  "label=fresh kind=source enabled=yes checked=blocked reason=shadow:diskman feeds=1 packages=0" \
  "describe reports the state, the reason and the counts on one line"

finish
