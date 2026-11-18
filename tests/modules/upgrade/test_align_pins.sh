#!/usr/bin/env bash
# Module: upgrade
# The pins that decide whether a package can run on this base belong to the base, and the
# aligner moves all three of them as one set.
#
# Measured on the device (2026-11-18): the 25.12.0 base pins base-files=1933~... and
# kernel=6.12.87~..., the 25.12.2 base pins 1950~... and 6.12.103~.... The previous aligner
# moved only `kernel=`, so a machine crossing that pair kept a base-files pin from the release
# it had left, and `apk info -v` disagreed with the feed the slot now read.
#
#   ac-1 the three pins (kernel=, base-files=, libc=) are rewritten together, to the values the
#        target base's own world carries, and every other line of the user's world is kept.
#   ac-2 a pin the base does not carry is the user's and is left alone; a base that pins
#        nothing gets no pin invented for it.
#   ac-3 two different pins for one of the three names means two of them were installed at some
#        point: that is `multiple-kernel-pins`, and then *no* file is written - not the world,
#        not the feeds.
#   ac-4 an alignment that has nothing to move does not touch the file at all (no rewrite, no
#        pre-rewrite copy), and a second run changes nothing.
#
# The feed half of the aligner is covered by test_apk_align.sh; this file adds the pin set and
# keeps the two contracts from fighting (a world the base does not pin must stay untouched).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

packages_lib="$root/platform/lib/upgrade/packages.sh"
if [ ! -f "$packages_lib" ]; then
  printf 'not ok 1 - the packages library exists\n' >&2
  printf '    missing %s\n' "$packages_lib" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# align <sys> <upper> [version]: run the aligner the device runs, in its own shell so the
# library's variables cannot leak between cases.
align() {
  _version=${3:-25.12.2}
  rm -rf "$tmp/payload"
  mkdir -p "$tmp/payload"
  printf '{"format":"ab-payload/1","rootfs":"%s","members":{}}\n' "$_version" >"$tmp/payload/manifest.json"
  sh -c '. "$1"; ab_packages_align "$2" "$3" "$4" "$5"; rc=$?
         printf "rc=%s reason=%s kernel=%s follow=%s hint=%s\n" \
           "$rc" "${AB_PACKAGES_REASON:-none}" "${AB_PACKAGES_KERNEL}" "${AB_PACKAGES_FOLLOW}" "${AB_PACKAGES_HINT}"' \
    _ "$packages_lib" "$tmp/payload" b "$1" "$2" 2>&1
}

# A base tree as the payload ships it: the three pins, and a feed file naming its own release
# and its own kmods build (which is where the kmods segment comes from).
mkbase() { # <dir>
  rm -rf "$1"
  mkdir -p "$1/etc/apk/repositories.d"
  cat >"$1/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
busybox
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
libc=1.2.5-r5
luci
WORLD
  cat >"$1/etc/apk/repositories.d/distfeeds.list" <<'FEEDS'
https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/packages/packages.adb
https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/base/packages.adb
https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/kmods/6.12.103-1-0413601b/packages.adb
FEEDS
}

# The writable layer of the machine that is being upgraded: its world still describes the
# release it is leaving.
mkupper() { # <dir>
  rm -rf "$1"
  mkdir -p "$1/etc/apk/repositories.d"
  cat >"$1/etc/apk/world" <<'WORLD'
base-files=1933~f20c1d4e5f60
busybox
docker
kernel=6.12.87~bd81971a8c-r1
libc=1.2.5-r4
luci-theme-argon
WORLD
  # The user's own mirror: the file is an edit, not a shadow of the base's copy, so the
  # aligner has to rewrite it rather than drop it - both halves of the metadata move in the
  # same run, which is what this file is about.
  cat >"$1/etc/apk/repositories.d/distfeeds.list" <<'FEEDS'
# mirrored by the operator, do not rewrite the host
https://mirror.example.net/immortalwrt/releases/25.12.0/targets/x86/64/packages/packages.adb
https://mirror.example.net/immortalwrt/releases/25.12.0/packages/x86_64/base/packages.adb
https://mirror.example.net/immortalwrt/releases/25.12.0/targets/x86/64/kmods/6.12.87-1-bd81971a8c/packages.adb
FEEDS
}

# Every file under a directory with its digest, in a stable order: the "nothing was written"
# assertions compare two of these, so not even a timestamp edit can hide.
snapshot_tree() {
  ( cd "$1" && find . -type f | sort | while IFS= read -r f; do
      printf '%s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"
    done )
}

base="$tmp/sys"
upper="$tmp/upper"

# =========================================================================== #
# ac-1: the three pins move together, from the base's own world
# =========================================================================== #

mkbase "$base"
mkupper "$upper"
out="$(align "$base" "$upper")"
assert_contains "$out" "rc=0" "ac-1 a world pinning the old release is aligned"
assert_eq "$(grep '^kernel=' "$upper/etc/apk/world")" \
  "kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1" \
  "ac-1 the kernel pin is the base's kernel"
assert_eq "$(grep '^base-files=' "$upper/etc/apk/world")" "base-files=1950~0c4cd0f9920a" \
  "ac-1 the base-files pin is the base's base-files (this is the drift the old aligner left)"
assert_eq "$(grep '^libc=' "$upper/etc/apk/world")" "libc=1.2.5-r5" \
  "ac-1 the libc pin is the base's libc"
assert_eq "$(grep -v -e '^kernel=' -e '^base-files=' -e '^libc=' "$upper/etc/apk/world" | tr '\n' ' ')" \
  "busybox docker luci-theme-argon " \
  "ac-1 every other world entry is kept byte for byte"
assert_eq "$(grep -c '^kernel=' "$upper/etc/apk/world")" "1" \
  "ac-1 the three-set rewrite leaves exactly one kernel pin"
assert_contains "$out" "world pinned kernel base-files libc to this base" \
  "ac-1 the ring log names all three names it moved, so nobody has to diff the file"
assert_contains "$out" "kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1" \
  "ac-1 the identity that was written is reported for the state line"

# The same run also moves the feed files: the pin set and the feeds describe one release.
assert_eq "$(grep -c 'releases/25.12.2/' "$upper/etc/apk/repositories.d/distfeeds.list")" "3" \
  "ac-1 the edited feed file moves to the base's release in the same run"
assert_eq "$(grep -c 'kmods/6.12.103-1-0413601b/' "$upper/etc/apk/repositories.d/distfeeds.list")" "1" \
  "ac-1 and to the base's own kmods build"
assert_eq "$(grep -c 'mirror.example.net' "$upper/etc/apk/repositories.d/distfeeds.list")" "3" \
  "ac-1 the operator's mirror is kept"
assert_contains "$out" "reason=feeds-rewritten" \
  "ac-1 and the record note says a feed edit was moved rather than dropped"
assert_eq "$([ -e "$upper/etc/apk/world.ab-align.bak" ] && echo leftover || echo clean)" "clean" \
  "ac-1 the pre-rewrite copy is removed once the result reads back"

# =========================================================================== #
# ac-1: the record-side promise
# =========================================================================== #
# A base whose metadata was aligned has not had its packages followed, and the caller has to be
# able to say so in the same line. An alignment that failed must not hand over a follow state.
assert_contains "$out" "follow=pending" "ac-1 a successful alignment hands over follow=pending"
assert_contains "$out" "hint=ab-packages update" \
  "ac-1 and the command that finishes the job"

# =========================================================================== #
# ac-2: a pin the base does not carry is the user's
# =========================================================================== #

mkbase "$base"
# The base pins only the kernel here: a release that does not pin base-files or libc has no
# opinion about them, and replacing the user's pin with a guess would be worse than leaving it.
printf 'busybox\nkernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1\n' >"$base/etc/apk/world"
mkupper "$upper"
before_world="$(cat "$upper/etc/apk/world")"
out="$(align "$base" "$upper")"
assert_contains "$out" "rc=0" "ac-2 a base that pins one name still aligns"
assert_eq "$(grep '^kernel=' "$upper/etc/apk/world")" \
  "kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1" "ac-2 the pinned name moves"
assert_eq "$(grep '^base-files=' "$upper/etc/apk/world")" "base-files=1933~f20c1d4e5f60" \
  "ac-2 a base-files pin the base does not carry is left exactly as the user had it"
assert_eq "$(grep '^libc=' "$upper/etc/apk/world")" "libc=1.2.5-r4" \
  "ac-2 and so is libc"
assert_eq "$(grep -c . "$upper/etc/apk/world")" "$(printf '%s\n' "$before_world" | grep -c .)" \
  "ac-2 no pin is added and none is removed"

# A base that pins none of the three installs no pins of its own either.
mkbase "$base"
printf 'busybox\nluci\n' >"$base/etc/apk/world"
mkupper "$upper"
printf 'busybox\nluci\nkernel=6.12.87~bd81971a8c-r1\n' >"$upper/etc/apk/world"
out="$(align "$base" "$upper")"
assert_contains "$out" "reason=kernel-unknown" \
  "ac-2 a world pinning a kernel its base does not know is limited, not guessed"
assert_eq "$(grep '^kernel=' "$upper/etc/apk/world")" "kernel=6.12.87~bd81971a8c-r1" \
  "ac-2 and the user's pin is left alone"

# =========================================================================== #
# ac-3: two pins for one name is a conflict, and nothing is written
# =========================================================================== #
mkbase "$base"
mkupper "$upper"
printf 'busybox\nkernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1\nkernel=6.11.5~dead-r1\n' \
  >"$upper/etc/apk/world"
before="$(snapshot_tree "$upper")"
out="$(align "$base" "$upper")"
assert_contains "$out" "rc=1" "ac-3 two kernel pins are limited, not silently half fixed"
assert_contains "$out" "reason=multiple-kernel-pins" "ac-3 the reason names the ambiguity"
assert_eq "$(snapshot_tree "$upper")" "$before" \
  "ac-3 no file changed at all: not the world, not the feed list"
assert_contains "$out" "follow=" "ac-3 a failed alignment hands over no follow state"
case "$out" in
  *"follow=pending"*) assert_eq "pending" "none" "ac-3 a failed alignment must not promise a follow" ;;
  *) assert_eq "none" "none" "ac-3 a failed alignment hands over an empty follow state" ;;
esac

# The same rule for the other two names, and its own token: `multiple-kernel-pins` would be a
# wrong description of two base-files pins.
printf 'base-files=1933~f20c1d4e5f60\nbase-files=1940~aaaa\nkernel=6.12.87~bd81971a8c-r1\n' \
  >"$upper/etc/apk/world"
before="$(snapshot_tree "$upper")"
out="$(align "$base" "$upper")"
assert_contains "$out" "rc=1" "ac-3 two base-files pins are limited too"
assert_contains "$out" "reason=multiple-base-pins" \
  "ac-3 and the reason says which name is ambiguous"
assert_eq "$(snapshot_tree "$upper")" "$before" \
  "ac-3 nothing is written for that conflict either"

# =========================================================================== #
# ac-4: nothing to do is not a rewrite
# =========================================================================== #

mkbase "$base"
mkupper "$upper"
# The user's world already describes the base (a second upgrade to the same release).
cp "$base/etc/apk/world" "$upper/etc/apk/world"
cp "$base/etc/apk/repositories.d/distfeeds.list" "$upper/etc/apk/repositories.d/distfeeds.list"
rm -f "$upper/etc/apk/repositories.d/distfeeds.list"
# The feed copy is gone (the shadow rule) and the world is the base's: the metadata already
# matches, so the file must keep its mtime as well as its bytes.
world_before="$(shasum -a 256 <"$upper/etc/apk/world")"
out="$(align "$base" "$upper")"
assert_contains "$out" "rc=0" "ac-4 a world that already matches is aligned without work"
assert_contains "$out" "metadata already matched" "ac-4 and says so in the ring log line"
assert_eq "$(shasum -a 256 <"$upper/etc/apk/world")" "$world_before" \
  "ac-4 the world is not rewritten when there is nothing to move"
assert_eq "$([ -e "$upper/etc/apk/world.ab-align.bak" ] && echo leftover || echo clean)" "clean" \
  "ac-4 and no pre-rewrite copy appears"

# Idempotent: the second run of the same upgrade writes the same bytes.
mkbase "$base"
mkupper "$upper"
align "$base" "$upper" >/dev/null
first="$(snapshot_tree "$upper")"
out="$(align "$base" "$upper")"
assert_contains "$out" "rc=0" "ac-4 the second run is still aligned"
assert_eq "$(snapshot_tree "$upper")" "$first" \
  "ac-4 and changes not one byte of the layer the first run produced"

# =========================================================================== #
# The three names are the library's, not the caller's guess
# =========================================================================== #
sh -c '. "$1"; printf "%s\n" "${AB_PACKAGES_PINS}"' _ "$packages_lib" >"$tmp/pins"
assert_eq "$(cat "$tmp/pins")" "kernel base-files libc" \
  "the pin set is named in one place: kernel, base-files, libc"

finish
