#!/usr/bin/env bash
# Module: upgrade
# A downgrade leaves the machine running one kernel while its package metadata still
# describes another: world pins the old kernel and distfeeds still name the old release.
# On a real machine that makes "install a kmod for this kernel" either silently do nothing
# (rc=0) or fail with a `satisfies: world[kernel=...]` message (rc=99) - see
# 20261111-12 quality.md. platform/lib/upgrade/packages.sh aligns both files offline,
# before the machine is allowed to try the slot:
#   ac-1 (parent ac-18) world's kernel pin is rewritten to the target's kernel and every
#        other pin is kept byte for byte
#   ac-2 the feed files the *base* ships are the ones aligned: a shadow that carries only the
#        old release/kernel is dropped, an edit of the user's is moved (feeds-rewritten), and
#        a file the base does not ship is never created
#   ac-3 a slot whose metadata needs nothing is left untouched
#   ac-4 an unknown target kernel or an unwritable file ends in `limited` + a reason, and
#        the upgrade still installs the slot
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

packages_lib="$root/platform/lib/upgrade/packages.sh"
platform_sh="$root/platform/lib/upgrade/platform.sh"
ab_upgrade="$root/platform/usr/sbin/ab-upgrade"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# align_with <library> <sys> <upper>: run an aligner in its own shell, so the library's
# variables cannot leak between cases. The library is a parameter because one case below
# drives the read-back with a copy of it (see (e)).
align_with() {
  sh -c '. "$1"; ab_packages_align "$2" "$3" "$4" "$5"; rc=$?; printf "rc=%s reason=%s kernel=%s\n" "$rc" "${AB_PACKAGES_REASON}" "${AB_PACKAGES_KERNEL}"' \
    _ "$1" "$tmp/payload" b "$2" "$3"
}

# align <sys> <upper>: run the aligner the device runs.
align() {
  align_with "$packages_lib" "$1" "$2"
}

mkpayload() { # <version>
  rm -rf "$tmp/payload"
  mkdir -p "$tmp/payload"
  printf '{"format":"ab-payload/1","rootfs":"%s","members":{}}\n' "$1" >"$tmp/payload/manifest.json"
}

# =========================================================================== #
# ac-1: world's kernel pin follows the target
# =========================================================================== #

mkpayload 25.12.0
sys="$tmp/sys"
upper="$tmp/upper"
mkdir -p "$sys/etc/apk" "$upper/etc/apk"
cat >"$sys/etc/apk/world" <<'WORLD'
busybox
kernel=6.12.87~bd81971a8c-r1
kmod-usb-storage
luci
WORLD
cat >"$upper/etc/apk/world" <<'WORLD'
busybox
kernel=6.12.103~ff11223344-r1
kmod-usb-storage
luci
WORLD
out="$(align "$sys" "$upper")"
assert_contains "$out" "rc=0" "ac-1 a world that pins the old kernel is aligned"
assert_contains "$out" "kernel=kernel=6.12.87~bd81971a8c-r1" "ac-1 the aligner reports the identity it wrote"
assert_eq "$(grep '^kernel=' "$upper/etc/apk/world")" "kernel=6.12.87~bd81971a8c-r1" \
  "ac-1 the writable layer's pin is the target's kernel"
# Everything that is not the kernel pin is the user's and stays exactly as it was.
assert_eq "$(grep -v '^kernel=' "$upper/etc/apk/world" | tr '\n' ' ')" "busybox kmod-usb-storage luci " \
  "ac-1 the user's other pins are kept"

# =========================================================================== #
# ac-2: the feed files the base ships are the ones aligned
# =========================================================================== #
# The measured image (192.168.2.49, 2026-11-18) has /etc/apk/repositories.d/*.list and
# neither /etc/apk/distfeeds.list nor /etc/apk/repositories. A writable layer is a snapshot
# of the running one, so the user's copy of a feed file survives an upgrade and shadows the
# base's own; writing the two legacy names instead is how `packages=aligned` came to
# describe a file apk never opens.

# (a) a copy that carries nothing but the old release and the old kernel build is a shadow:
#     dropping it lets the base's own file win, and the next upgrade stops inheriting it.
mkdir -p "$sys/etc/apk/repositories.d" "$upper/etc/apk/repositories.d"
cat >"$sys/etc/apk/repositories.d/distfeeds.list" <<'FEEDS'
https://downloads.immortalwrt.org/releases/25.12.0/targets/x86/64/packages/packages.adb
https://downloads.immortalwrt.org/releases/25.12.0/packages/x86_64/base/packages.adb
https://downloads.immortalwrt.org/releases/25.12.0/targets/x86/64/kmods/6.12.87-1-bd81971a8c/packages.adb
FEEDS
cat >"$upper/etc/apk/repositories.d/distfeeds.list" <<'FEEDS'
https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/packages/packages.adb
https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/base/packages.adb
https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/kmods/6.12.103-1-ff11/packages.adb
FEEDS
printf '# add your custom package feeds here\n' >"$upper/etc/apk/repositories.d/customfeeds.list"
out="$(align "$sys" "$upper")"
assert_contains "$out" "rc=0" "ac-2 a shadowed feed file does not stop the alignment"
assert_eq "$([ -f "$upper/etc/apk/repositories.d/distfeeds.list" ] && echo present || echo gone)" "gone" \
  "ac-2 a copy that only carried the old release and kernel is dropped, so the base's own file wins"
assert_eq "$(grep -c 'releases/25.12.0/' "$sys/etc/apk/repositories.d/distfeeds.list")" "3" \
  "ac-2 the feed apk will read names the target release"
assert_eq "$(cat "$upper/etc/apk/repositories.d/customfeeds.list")" \
  "# add your custom package feeds here" \
  "ac-2 the user's own feed list is never touched"
assert_eq "$([ -e "$upper/etc/apk/repositories.d/distfeeds.list.ab-align.bak" ] && echo leftover || echo clean)" "clean" \
  "ac-2 a dropped shadow leaves no pre-rewrite copy behind"

# (b) a file the user changed keeps every byte the upgrade does not have to move: the
#     release and the kernel-bound kmods directory follow the target, the mirror and the
#     comment stay, and the note says an edit was moved rather than dropped.
cat >"$upper/etc/apk/repositories.d/distfeeds.list" <<'FEEDS'
# my own mirror, do not rewrite the host
https://mirror.example.net/immortalwrt/releases/25.12.2/packages/x86_64/base/packages.adb
https://mirror.example.net/immortalwrt/releases/25.12.2/targets/x86/64/kmods/6.12.103-1-ff11/packages.adb
FEEDS
out="$(align "$sys" "$upper")"
feeds="$upper/etc/apk/repositories.d/distfeeds.list"
assert_contains "$out" "rc=0" "ac-2 a feed file the user changed is aligned, not dropped"
assert_contains "$out" "reason=feeds-rewritten" \
  "ac-2 the alignment notes that an edit was moved, so nobody has to guess"
assert_eq "$(grep -c 'releases/25.12.0/' "$feeds")" "2" \
  "ac-2 every line of the user's file moves to the target release"
assert_eq "$(grep -c 'releases/25.12.2/' "$feeds")" "0" \
  "ac-2 no line still names the release the machine came from"
assert_eq "$(grep -c 'kmods/6.12.87-1-bd81971a8c/' "$feeds")" "1" \
  "ac-2 the kernel-bound kmods directory is the target's, taken from the base's own file"
assert_eq "$(grep -c 'kmods/6.12.103-1-ff11/' "$feeds")" "0" \
  "ac-2 and the old kernel's directory is gone"
assert_contains "$(cat "$feeds")" "mirror.example.net" "ac-2 the user's mirror host is kept"
assert_eq "$(head -n 1 "$feeds")" "# my own mirror, do not rewrite the host" \
  "ac-2 the user's comment survives the rewrite"

# (c) a base that does not ship a feed file does not get one created: an unused file is not
#     evidence, and the user's own copy is left exactly as it is.
rm -rf "$sys/etc/apk/repositories.d" "$sys/etc/apk/distfeeds.list" "$sys/etc/apk/repositories"
rm -rf "$upper/etc/apk/repositories.d"
rm -f "$upper/etc/apk/distfeeds.list" "$upper/etc/apk/repositories"
printf '%s\n' 'https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/base/packages.adb' \
  >"$upper/etc/apk/distfeeds.list"
out="$(align "$sys" "$upper")"
assert_contains "$out" "rc=0" "ac-2 a base without a feed file still aligns the world"
assert_eq "$(cat "$upper/etc/apk/distfeeds.list")" \
  "https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/base/packages.adb" \
  "ac-2 a feed file the base does not ship is left exactly as the user had it"
assert_eq "$([ -e "$upper/etc/apk/repositories" ] && echo present || echo absent)" "absent" \
  "ac-2 no feed file is created out of thin air"
assert_eq "$([ -e "$upper/etc/apk/distfeeds.list.ab-align.bak" ] && echo leftover || echo clean)" "clean" \
  "ac-2 and no pre-rewrite copy appears for a file that was not touched"

# (d) customfeeds.list is the user's own feed list by definition, so the align step never
#     rewrites it; the read-back must not ask it to name the target release either. A base
#     that ships the template plus a writable layer a feed step left naming the release the
#     machine came from is exactly that state - and it used to be reported as a failure of
#     the whole alignment (`distfeeds-not-verified`), with the correct skip in hand.
cf_sys="$tmp/cf-sys"
cf_upper="$tmp/cf-upper"
mkdir -p "$cf_sys/etc/apk/repositories.d" "$cf_upper/etc/apk/repositories.d"
printf 'busybox\nkernel=6.12.87~bd81971a8c-r1\n' >"$cf_sys/etc/apk/world"
printf 'busybox\nkernel=6.12.103~ff11223344-r1\n' >"$cf_upper/etc/apk/world"
cat >"$cf_sys/etc/apk/repositories.d/distfeeds.list" <<'FEEDS'
https://downloads.immortalwrt.org/releases/25.12.0/targets/x86/64/packages/packages.adb
FEEDS
cat >"$cf_sys/etc/apk/repositories.d/customfeeds.list" <<'FEEDS'
# add your custom package feeds here
# https://example.net/immortalwrt/releases/<version>/packages/<arch>/base/packages.adb
# https://example.net/immortalwrt/releases/<version>/targets/<target>/kmods/<kernel>/packages.adb
FEEDS
cat >"$cf_upper/etc/apk/repositories.d/customfeeds.list" <<'FEEDS'
# my own feeds, added while the machine ran 25.12.2
https://mirror.example.net/immortalwrt/releases/25.12.2/packages/x86_64/base/packages.adb
https://mirror.example.net/immortalwrt/releases/25.12.2/targets/x86/64/kmods/6.12.103-1-ff11/packages.adb
FEEDS
cp "$cf_upper/etc/apk/repositories.d/customfeeds.list" "$tmp/cf-user-content"
out="$(align "$cf_sys" "$cf_upper")"
assert_contains "$out" "rc=0" \
  "ac-2 a customfeeds.list that still names the old release does not fail the alignment"
assert_eq "$(cmp -s "$tmp/cf-user-content" "$cf_upper/etc/apk/repositories.d/customfeeds.list" \
  && echo same || echo changed)" "same" \
  "ac-2 the user's customfeeds.list is kept byte for byte"
assert_eq "$(grep -c 'releases/25.12.2/' "$cf_upper/etc/apk/repositories.d/customfeeds.list")" "2" \
  "ac-2 none of its old release references is rewritten"
assert_eq "$(grep -c 'releases/25.12.0/' "$cf_upper/etc/apk/repositories.d/customfeeds.list")" "0" \
  "ac-2 and the target release is not pasted into it either"
assert_eq "$([ -e "$cf_upper/etc/apk/repositories.d/customfeeds.list.ab-align.bak" ] && echo leftover || echo clean)" "clean" \
  "ac-2 a file that is never written leaves no pre-rewrite copy behind"
assert_eq "$(grep '^kernel=' "$cf_upper/etc/apk/world")" "kernel=6.12.87~bd81971a8c-r1" \
  "ac-2 the rest of the alignment still did its work"

# (e) the exemption is customfeeds.list and nothing else. With today's align step the read-back
#     cannot be reached with a stale distfeeds.list - every feed file it owns is rewritten or
#     dropped, so a file that survives already names the target - and that is exactly why the
#     guard needs a case that drives it directly. The library copy below overrides the one
#     function that would otherwise fix the file, leaving the read-back as the only thing that
#     can notice a stale release. If the skip were written as "skip feed files", or moved up
#     over the whole loop, this case is what fails.
# The state is set up rather than inherited from (d): this case is about the customfeeds file
# and nothing else, so the upper carries no other feed file that could fail the read-back.
rm -f "$cf_upper/etc/apk/repositories.d/distfeeds.list"
inj_lib="$tmp/packages-readback-only.sh"
cp "$packages_lib" "$inj_lib"
cat >>"$inj_lib" <<'SHIM'

# Test shim: pretend the align step owns no feed file at all, so the read-back decides alone.
_packages_feed_align_one() {
    _packages_feed_result="none"
    return 0
}
SHIM
out="$(align_with "$inj_lib" "$cf_sys" "$cf_upper")"
assert_contains "$out" "rc=0" \
  "ac-2 the read-back alone accepts a stale customfeeds.list"
printf 'https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/packages/packages.adb\n' \
  >"$cf_upper/etc/apk/repositories.d/distfeeds.list"
out="$(align_with "$inj_lib" "$cf_sys" "$cf_upper")"
assert_contains "$out" "rc=1" "ac-2 a stale distfeeds.list is still a failure, not a skipped file"
assert_contains "$out" "reason=distfeeds-not-verified" \
  "ac-2 and the reason names the read-back that caught it"

# =========================================================================== #
# ac-3: nothing to do is not a failure
# =========================================================================== #

rm -rf "$upper/etc/apk"
mkdir -p "$upper/etc/apk"
printf 'busybox\nluci\n' >"$upper/etc/apk/world"
out="$(align "$sys" "$upper")"
assert_contains "$out" "rc=0" "ac-3 a world without a kernel pin needs no rewrite"
assert_eq "$(cat "$upper/etc/apk/world" | tr '\n' ' ')" "busybox luci " \
  "ac-3 the world file is untouched"
assert_contains "$out" "kernel=kernel=6.12.87~bd81971a8c-r1" \
  "ac-3 the target's kernel identity is still reported"

# =========================================================================== #
# ac-4: what cannot be proven ends in limited, with a reason
# =========================================================================== #

# No world in the target and no apk database: the target kernel is unknown, so the pin
# cannot be moved. The upgrade must say so and continue.
mkdir -p "$tmp/bare-sys/etc/apk" "$tmp/bare-upper/etc/apk"
printf 'busybox\nkernel=6.12.103~ff11223344-r1\n' >"$tmp/bare-upper/etc/apk/world"
out="$(align "$tmp/bare-sys" "$tmp/bare-upper")"
assert_contains "$out" "rc=1" "ac-4 an unknown target kernel is limited, not aligned"
assert_contains "$out" "reason=kernel-unknown" "ac-4 the reason names what is missing"
assert_eq "$(grep '^kernel=' "$tmp/bare-upper/etc/apk/world")" "kernel=6.12.103~ff11223344-r1" \
  "ac-4 a limited alignment leaves the user's file alone"

# The kernel can also come from the target's apk database, which is what a slot without a
# world file still carries.
mkdir -p "$tmp/db-sys/lib/apk/db" "$tmp/db-upper/etc/apk"
printf 'P:busybox\nV:1.36\n\nP:kernel\nV:6.12.87~bd81971a8c-r1\n\n' >"$tmp/db-sys/lib/apk/db/installed"
printf 'kernel=6.12.103~ff11223344-r1\n' >"$tmp/db-upper/etc/apk/world"
out="$(align "$tmp/db-sys" "$tmp/db-upper")"
assert_contains "$out" "rc=0" "ac-4 the apk database is used when the slot has no world file"
assert_eq "$(grep '^kernel=' "$tmp/db-upper/etc/apk/world")" "kernel=6.12.87~bd81971a8c-r1" \
  "ac-4 the pin follows the kernel the database records"

# An unwritable world file is a limited result, not a crash and not a silent pass.
mkdir -p "$tmp/ro-sys/etc/apk" "$tmp/ro-upper/etc/apk"
cp "$sys/etc/apk/world" "$tmp/ro-sys/etc/apk/world"
printf 'kernel=6.12.103~ff11223344-r1\n' >"$tmp/ro-upper/etc/apk/world"
chmod 500 "$tmp/ro-upper/etc/apk"
out="$(align "$tmp/ro-sys" "$tmp/ro-upper")"
chmod 700 "$tmp/ro-upper/etc/apk"
# Running as root ignores the permission bits, so the check only means something for a
# normal user; either way the file must be intact and the answer must be a token.
case "${out}" in
  *"rc=1"*) assert_contains "$out" "reason=world-unwritable" "ac-4 an unwritable world is reported" ;;
  *"rc=0"*) assert_eq "$(grep '^kernel=' "$tmp/ro-upper/etc/apk/world")" "kernel=6.12.87~bd81971a8c-r1" \
    "ac-4 a writable world is aligned even under a restrictive mode" ;;
  *) assert_eq "${out}" "unexpected output" ;;
esac

# Two different kernel pins in the user's world mean two kernels were installed at some
# point. Picking one would be a guess; the result says so instead.
mkdir -p "$tmp/multi-sys/etc/apk" "$tmp/multi-upper/etc/apk"
printf 'kernel=6.12.87~bd81971a8c-r1\n' >"$tmp/multi-sys/etc/apk/world"
printf 'busybox\nkernel=6.12.103~ff11223344-r1\nkernel=6.11.5~dead-r1\n' \
  >"$tmp/multi-upper/etc/apk/world"
out="$(align "$tmp/multi-sys" "$tmp/multi-upper")"
assert_contains "$out" "rc=1" "ac-4 two different kernel pins are limited, not silently half fixed"
assert_contains "$out" "reason=multiple-kernel-pins" "ac-4 the reason names the ambiguity"
assert_eq "$(grep -c '^kernel=' "$tmp/multi-upper/etc/apk/world")" "2" \
  "ac-4 a limited result leaves both pins alone"

# A version that is not a plain version token never reaches a feed path.
printf '{"format":"ab-payload/1","rootfs":"25.12.0&x","members":{}}\n' >"$tmp/payload/manifest.json"
mkdir -p "$tmp/bad-sys/etc/apk" "$tmp/bad-upper/etc/apk"
printf 'kernel=6.12.87~bd81971a8c-r1\n' >"$tmp/bad-sys/etc/apk/world"
printf 'https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/packages/packages.adb\n' \
  >"$tmp/bad-upper/etc/apk/distfeeds.list"
before_feeds="$(cat "$tmp/bad-upper/etc/apk/distfeeds.list")"
out="$(align "$tmp/bad-sys" "$tmp/bad-upper")"
assert_contains "$out" "rc=1" "ac-4 a version outside the safe character set is refused"
assert_contains "$out" "reason=version-invalid" "ac-4 the reason names the version"
assert_eq "$(cat "$tmp/bad-upper/etc/apk/distfeeds.list")" "$before_feeds" \
  "ac-4 and the user's feeds file is untouched"
mkpayload 25.12.0

# =========================================================================== #
# ac-5: the upgrade runs it and publishes the verdict
# =========================================================================== #

# The call site is in platform_copy_rootfs, after the target tree exists and before the
# slot is marked pending: a verdict published after the switch would describe the wrong
# boot.
copy_body="$(sed -n '/^platform_copy_rootfs()/,/^}/p' "$platform_sh")"
assert_contains "$copy_body" 'lib/upgrade/packages.sh' \
  "ac-5 the adapter takes the aligner from the new platform layer"
assert_contains "$copy_body" 'ab_packages_align' "ac-5 and calls it while the slot is being written"
assert_contains "$(cat "$platform_sh")" 'ab_packages_record' "ac-5 the verdict has one writer"
assert_eq "$(printf '%s\n' "$copy_body" | grep -c 'ab_packages_align')" "1" \
  "ac-5 it is called exactly once per install"
align_line="$(printf '%s\n' "$copy_body" | grep -n 'ab_packages_align' | head -n 1 | cut -d: -f1)"
end_line="$(printf '%s\n' "$copy_body" | grep -n 'UPGRADE_NEW_LAYER=' | head -n 1 | cut -d: -f1)"
assert_eq "$([ -n "$align_line" ] && [ -n "$end_line" ] && [ "$align_line" -lt "$end_line" ] && echo before)" \
  "before" "ac-5 the alignment happens while the slot is written, not after it is announced"

# The record itself: one line, atomic, readable by ab-slot.
(
  # shellcheck source=platform/lib/upgrade/platform.sh disable=SC1090
  . "$platform_sh"
  AB_PACKAGES_FILE="$tmp/packages"
  ab_packages_record aligned none 25.12.0 "kernel=6.12.87~bd81971a8c-r1" b
)
assert_eq "$(cat "$tmp/packages")" \
  "packages=aligned reason=none version=25.12.0 kernel=kernel=6.12.87~bd81971a8c-r1 slot=b" \
  "ac-5 the published record is one line ab-slot can read, and it names the slot it describes"
leftover=0
for candidate in "$tmp"/packages.tmp*; do
  [ -e "$candidate" ] && leftover=$((leftover + 1))
done
assert_eq "$leftover" "0" "ac-5 no temporary file is left behind"

# And the whole path: an install whose payload carries the aligner rewrites the upper and
# publishes `packages=aligned`.
# --------------------------------------------------------------------------- #
# stand-in machine
# --------------------------------------------------------------------------- #
esp="$tmp/e2e/esp"
p4="$tmp/e2e/p4"
slots="$tmp/e2e/slots"
bin="$tmp/e2e/bin"
mkdir -p "$esp/ab/log" "$p4" "$bin" "$slots/b/@sys/sbin" "$slots/b/@sys/etc/apk" \
  "$slots/b/@platform" "$p4/@overlay-25.12.2/upper/etc/apk/repositories.d"
printf '#!/bin/sh\n' >"$slots/b/@sys/sbin/init"
chmod +x "$slots/b/@sys/sbin/init"
printf '{"generation":1,"committed":"a","pending":null,"slots":{"a":{"rootfs":"25.12.2","upper":"@overlay-25.12.2"},"b":{"rootfs":"25.12.2","upper":"@overlay-25.12.2"}}}\n' \
  >"$esp/ab/state.json"
printf 'busybox\nkernel=6.12.103~ff11223344-r1\n' >"$p4/@overlay-25.12.2/upper/etc/apk/world"
printf 'https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/packages/packages.adb\n' \
  >"$p4/@overlay-25.12.2/upper/etc/apk/repositories.d/distfeeds.list"

cat >"$bin/sha256sum" <<'STUB'
#!/bin/sh
for f in "$@"; do
  [ -f "$f" ] && printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
done
STUB
cat >"$bin/ab-slot" <<'STUB'
#!/bin/sh
case "${1:-status}" in
  status) printf '%s\n' "slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none p4=ok" ;;
  rootfs) printf '%s\n' "25.12.2" ;;
  next) printf '%s\n' "next=b" ;;
  *) exit 0 ;;
esac
STUB
cat >"$bin/df" <<'STUB'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 1000000 0 800000 0%% /tmp\n'
STUB
cat >"$bin/btrfs" <<'STUB'
#!/bin/sh
case "${1:-}:${2:-}" in
  subvolume:snapshot) cp -a "$3" "$4" 2>/dev/null || true ;;
  subvolume:create) mkdir -p "$3" ;;
  subvolume:delete)
    shift 2
    for a in "$@"; do [ "$a" = "-C" ] && continue; rm -rf "$a"; done
    ;;
esac
exit 0
STUB
cat >"$bin/mount" <<'STUB'
#!/bin/sh
exit 0
STUB
cat >"$bin/ab-partitions.sh" <<'STUB'
# shellcheck shell=sh
ab_find_partition() { printf '%s' "/dev/fake"; }
STUB
chmod +x "$bin"/*

# payload whose rootfs pins the target kernel and whose platform layer carries the aligner
build_e2e_payload() { # <dir> <version> [--no-kernel-pin]
  local dir="$1" version="$2" pin=1
  [ "${3:-}" = "--no-kernel-pin" ] && pin=0
  rm -rf "$dir"
  mkdir -p "$dir/rootfs/sbin" "$dir/rootfs/etc/apk" "$dir/cpio/lib/modules/6.12.87" \
    "$dir/platform/lib/upgrade" "$dir/platform/usr/sbin"
  printf '#!/bin/sh\n' >"$dir/rootfs/sbin/init"
  chmod +x "$dir/rootfs/sbin/init"
  if [ "$pin" = "1" ]; then
    printf 'busybox\nkernel=6.12.87~bd81971a8c-r1\n' >"$dir/rootfs/etc/apk/world"
  else
    printf 'busybox\n' >"$dir/rootfs/etc/apk/world"
  fi
  # The feed list the base ships: repositories.d/*.list is what apk-tools 3 reads.
  mkdir -p "$dir/rootfs/etc/apk/repositories.d"
  printf 'https://downloads.immortalwrt.org/releases/%s/targets/x86/64/packages/packages.adb\n' \
    "${version}" >"$dir/rootfs/etc/apk/repositories.d/distfeeds.list"
  tar -czf "$dir/rootfs.tar.gz" -C "$dir/rootfs" .
  printf 'vermagic=6.12.87 SMP mod_unload \n' >"$dir/kernel.bin"
  printf 'vermagic=6.12.87 SMP mod_unload \n' >"$dir/cpio/lib/modules/6.12.87/btrfs.ko"
  ( cd "$dir/cpio" && find . -print | cpio -o -H newc 2>/dev/null ) | gzip -9 >"$dir/initramfs.cpio.gz"
  cp "$packages_lib" "$dir/platform/lib/upgrade/packages.sh"
  : >"$dir/platform/usr/sbin/btrfs"
  chmod +x "$dir/platform/usr/sbin/btrfs"
  tar -cf "$dir/platform.tar" -C "$dir/platform" .
  python3 - "$dir" "$version" <<'PYTHON'
import hashlib, json, pathlib, sys
stage = pathlib.Path(sys.argv[1])
members = {}
for name in ("initramfs.cpio.gz", "kernel.bin", "platform.tar", "rootfs.tar.gz"):
    data = (stage / name).read_bytes()
    members[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
(stage / "manifest.json").write_text(
    json.dumps({"format": "ab-payload/1", "rootfs": sys.argv[2], "members": members,
                "bootloader": None}, indent=2, sort_keys=True) + "\n")
PYTHON
  rm -rf "$dir/rootfs" "$dir/cpio" "$dir/platform"
  tar -cf "$dir/payload.tar" -C "$dir" manifest.json
  for member in rootfs.tar.gz kernel.bin initramfs.cpio.gz platform.tar; do
    tar -rf "$dir/payload.tar" -C "$dir" "$member"
  done
  printf '%s' "$dir/payload.tar"
}

payload="$(build_e2e_payload "$tmp/e2e/payload" 25.12.0)"
out="$(env PATH="$bin:$PATH" AB_ESP="$esp" AB_P4="$p4" AB_LIB="$platform_sh" \
  AB_PARTITIONS_LIB="$bin/ab-partitions.sh" AB_SLOTS_ROOT="$slots" \
  AB_PACKAGES_FILE="$esp/ab/packages" sh "$ab_upgrade" "$payload" 2>&1)"
assert_eq "$?" "0" "ac-5 the install with an aligner in the payload succeeds"
assert_contains "$out" "package meta aligned" "ac-5 the install reports an aligned result"
assert_contains "$(cat "$esp/ab/packages")" \
  "packages=aligned reason=none follow=pending version=25.12.0 kernel=kernel=6.12.87~bd81971a8c-r1" \
  "ac-5 the published verdict names the target kernel"
assert_contains "$(cat "$esp/ab/packages")" "slot=b" \
  "ac-5 the verdict names the slot it was written for"
new_layer_world="$(ls -d "$p4"/@overlay-25.12.0*/upper/etc/apk/world 2>/dev/null | head -n 1)"
assert_eq "$(grep -h '^kernel=' "${new_layer_world}" 2>/dev/null)" \
  "kernel=6.12.87~bd81971a8c-r1" "ac-5 the writable layer the new slot uses pins the new kernel"
new_layer_upper="$(ls -d "$p4"/@overlay-25.12.0*/upper 2>/dev/null | head -n 1)"
assert_eq "$([ -f "${new_layer_upper}/etc/apk/repositories.d/distfeeds.list" ] && echo present || echo gone)" "gone" \
  "ac-5 the shadowed feed copy the user never edited is gone from the new layer"
# The effective feed is the base's own file: the merged view names the new release, which is
# the only answer that makes `packages=aligned` mean something on this image.
assert_eq "$(grep -hc 'releases/25.12.0/' "$slots/b/@sys/etc/apk/repositories.d/distfeeds.list" 2>/dev/null)" "1" \
  "ac-5 and the feed apk will read names the new release"

# Without a kernel pin anywhere the install still goes through and says limited.
rm -rf "$p4"/@overlay-*
mkdir -p "$p4/@overlay-25.12.2/upper/etc/apk"
printf 'busybox\nkernel=6.12.103~ff11223344-r1\n' >"$p4/@overlay-25.12.2/upper/etc/apk/world"
unpinned="$(build_e2e_payload "$tmp/e2e/payload2" 25.12.1 --no-kernel-pin)"
out="$(env PATH="$bin:$PATH" AB_ESP="$esp" AB_P4="$p4" AB_LIB="$platform_sh" \
  AB_PARTITIONS_LIB="$bin/ab-partitions.sh" AB_SLOTS_ROOT="$slots" \
  AB_PACKAGES_FILE="$esp/ab/packages" sh "$ab_upgrade" "$unpinned" 2>&1)"
assert_eq "$?" "0" "ac-5 an install that cannot align still installs the slot"
assert_contains "$out" "package meta limited" "ac-5 and reports the limitation"
assert_contains "$(cat "$esp/ab/packages")" "packages=limited reason=kernel-unknown" \
  "ac-5 the verdict carries the reason"

finish
