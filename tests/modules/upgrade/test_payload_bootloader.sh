#!/usr/bin/env bash
# Module: upgrade
# The bootloader is the one thing an update can write that a machine cannot recover from:
# the ESP is shared by both slots, so `ab-slot rollback` cannot bring a loader back. This
# module proves both halves:
#   ac-1 (parent) the payload carries grub.cfg + the EFI loader and the manifest records
#        the loader's size, sha256 and GRUB version; a payload built without a boot tree
#        says so, and CI_REQUIRE_BOOTLOADER=1 turns that into a build failure
#   ac-2 (parent) ab-upgrade writes it the only way that is allowed: measure the current
#        bytes, back them up on the writable partition, stage, write, compare byte for
#        byte, restore on mismatch - and never touch the target slot when any step fails.
#        --bootloader requires the member, --no-bootloader never writes at all.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

payload_build="$root/scripts/ci/payload-build.sh"
grub_render="$root/scripts/ci/grub-render.sh"
ab_upgrade="$root/platform/usr/sbin/ab-upgrade"
lib="$root/platform/lib/upgrade/platform.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Everything this test writes goes under $tmp: it runs the real scripts from the repository,
# so a relative path in either the scripts or the stubs would otherwise land in the worktree
# (the previous version of the cp stub did exactly that, once per suite run).
cd "$tmp" || exit 1

# --- a stand-in for the upstream EFI loader ---------------------------------
# The real one is 638,976 bytes of GRUB 2.12 (measured on 25.12.0/25.12.1/25.12.2, all
# three byte identical). What matters for these checks is the shape: GRUB's own version
# message followed by the version token, and bytes that can be told apart.
make_loader() { # <path> <fill>
  python3 - "$1" "$2" <<'PY'
import sys
data = b"MZ" + (sys.argv[2].encode() * 64) + b"\0" + b"GNU GRUB  version %s\0" + b"2.12\0" + b"\0" * 4096
open(sys.argv[1], "wb").write(data)
PY
}

# =========================================================================== #
# ac-1: the payload carries the bootloader and the manifest records it
# =========================================================================== #

build="$tmp/ci"
mkdir -p "$tmp/fixtures/fetch/upstream" "$tmp/fixtures/rootfs/etc" \
  "$tmp/fixtures/runtime/usr/sbin" "$tmp/fixtures/esp/EFI/BOOT" "$tmp/fixtures/bin"
printf 'init\n' >"$tmp/fixtures/rootfs/etc/init"
tar -czf "$tmp/fixtures/fetch/upstream/rootfs.tar.gz" -C "$tmp/fixtures/rootfs" .
printf 'kernel\n' >"$tmp/fixtures/fetch/upstream/kernel.bin"
printf 'initramfs\n' >"$tmp/fixtures/initramfs.cpio.gz"
: >"$tmp/fixtures/runtime/usr/sbin/btrfs"
make_loader "$tmp/fixtures/esp/EFI/BOOT/BOOTX64.EFI" one

# bsdtar refuses the GNU reproducibility flags the build uses, and BSD sed cannot combine
# -i with several -e expressions; both are Linux behaviour by the time this runs in CI.
cat >"$tmp/fixtures/bin/tar" <<'SHIM'
#!/bin/sh
kept=""
for arg in "$@"; do
  case "${arg}" in
    --numeric-owner | --owner=* | --group=*) continue ;;
  esac
  kept="${kept} ${arg}"
done
# shellcheck disable=SC2086  # the arguments are rebuilt on purpose
exec /usr/bin/tar ${kept}
SHIM
cat >"$tmp/fixtures/bin/sed" <<'SHIM'
#!/bin/sh
if [ "${1:-}" = "-i" ]; then
  shift
  script=""
  while [ "${1:-}" = "-e" ]; do
    script="${script} -e $2"
    shift 2
  done
  target="$1"
  # shellcheck disable=SC2086  # the expressions are single words by construction
  /usr/bin/sed ${script} "${target}" >"${target}.shim" && mv "${target}.shim" "${target}"
  exit $?
fi
exec /usr/bin/sed "$@"
SHIM
chmod +x "$tmp/fixtures/bin/tar" "$tmp/fixtures/bin/sed"

payload_out="$tmp/out/payload.tar"
PATH="$tmp/fixtures/bin:$PATH" \
  CI_TMP_ROOT="$build" CI_LOG_DIR="$build/logs" CI_FETCH_DIR="$tmp/fixtures/fetch" \
  CI_INITRAMFS="$tmp/fixtures/initramfs.cpio.gz" CI_UPSTREAM_VERSION="25.12.2" \
  CI_PLATFORM_VERSION="0.0.7-test" \
  CI_PLATFORM_RUNTIME_DIR="$tmp/fixtures/runtime" CI_PAYLOAD_OUT="$payload_out" \
  CI_EMIT_OUTPUT="$build/outputs.env" CI_BOOT_SRC="$tmp/fixtures/esp" \
  bash "$payload_build" >"$tmp/build.log" 2>&1
assert_eq "$?" "0" "ac-1 a payload builds from an ESP tree"

members="$(tar -tf "$payload_out")"
assert_contains "$members" "boot.tar" "ac-1 the payload carries a bootloader member"

mkdir -p "$tmp/unpacked"
tar -xf "$payload_out" -C "$tmp/unpacked"
manifest="$tmp/unpacked/manifest.json"
assert_eq "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["bootloader"]["member"])' "$manifest")" \
  "boot.tar" "ac-1 the manifest names the bootloader member"
assert_eq "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))["bootloader"];print(d["grub_version"])' "$manifest")" \
  "2.12" "ac-1 the manifest records the GRUB version read from the loader"
assert_eq "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["members"]["boot.tar"]["sha256"])' "$manifest")" \
  "$(shasum -a 256 "$tmp/unpacked/boot.tar" | cut -d' ' -f1)" \
  "ac-1 the bootloader member is in the member table with its digest"

mkdir -p "$tmp/boot"
tar -xf "$tmp/unpacked/boot.tar" -C "$tmp/boot"
assert_file_exists "$tmp/boot/EFI/BOOT/BOOTX64.EFI" "ac-1 the member carries the EFI loader"
assert_file_exists "$tmp/boot/boot/grub/grub.cfg" "ac-1 the member carries our rendered menu"
assert_eq "$(shasum -a 256 "$tmp/boot/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" \
  "$(shasum -a 256 "$tmp/fixtures/esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" \
  "ac-1 the loader ships byte identical to the ESP tree it came from"
# The menu in the payload is ours (it names both slots), not the upstream one.
assert_contains "$(cat "$tmp/boot/boot/grub/grub.cfg")" "n5105-b" \
  "ac-1 the menu is the slot menu, not the upstream single-kernel one"

# --check-loader: the manifest is the contract for the bytes
assert_eq "$(bash "$grub_render" --check-loader "$tmp/boot/EFI/BOOT/BOOTX64.EFI" "$manifest" >/dev/null 2>&1; echo $?)" \
  "0" "ac-1 the loader matches the manifest's loader_sha256"
make_loader "$tmp/other.efi" two
assert_eq "$(bash "$grub_render" --check-loader "$tmp/other.efi" "$manifest" >/dev/null 2>&1; echo $?)" \
  "1" "ac-1 a different loader is rejected against the manifest"
printf '{"format":"ab-payload/1","rootfs":"x","members":{}}\n' >"$tmp/noboot.json"
assert_eq "$(bash "$grub_render" --check-loader "$tmp/boot/EFI/BOOT/BOOTX64.EFI" "$tmp/noboot.json" >/dev/null 2>&1; echo $?)" \
  "1" "ac-1 a manifest without a bootloader block cannot pass the comparison"

# A build without an ESP tree ships no bootloader and says so; asking for one is fatal.
PATH="$tmp/fixtures/bin:$PATH" \
  CI_TMP_ROOT="$tmp/ci-noboot" CI_LOG_DIR="$tmp/ci-noboot/logs" \
  CI_FETCH_DIR="$tmp/fixtures/fetch" CI_INITRAMFS="$tmp/fixtures/initramfs.cpio.gz" \
  CI_PLATFORM_VERSION="0.0.7-test" \
  CI_UPSTREAM_VERSION="25.12.2" CI_PLATFORM_RUNTIME_DIR="$tmp/fixtures/runtime" \
  CI_PAYLOAD_OUT="$tmp/out/payload-noboot.tar" \
  bash "$payload_build" >"$tmp/build-noboot.log" 2>&1
assert_eq "$?" "0" "ac-1 a payload without a boot tree still builds (old callers keep working)"
assert_contains "$(cat "$tmp/build-noboot.log")" "carries no bootloader" \
  "ac-1 the build says the payload carries no bootloader"
assert_eq "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["bootloader"])' "$tmp/ci-noboot/payload/work/stage/manifest.json")" \
  "None" "ac-1 the manifest records no bootloader instead of inventing one"

PATH="$tmp/fixtures/bin:$PATH" \
  CI_TMP_ROOT="$tmp/ci-require" CI_LOG_DIR="$tmp/ci-require/logs" \
  CI_FETCH_DIR="$tmp/fixtures/fetch" CI_INITRAMFS="$tmp/fixtures/initramfs.cpio.gz" \
  CI_PLATFORM_VERSION="0.0.7-test" \
  CI_UPSTREAM_VERSION="25.12.2" CI_PLATFORM_RUNTIME_DIR="$tmp/fixtures/runtime" \
  CI_PAYLOAD_OUT="$tmp/out/payload-require.tar" CI_REQUIRE_BOOTLOADER=1 \
  bash "$payload_build" >"$tmp/build-require.log" 2>&1
assert_eq "$?" "1" "ac-1 CI_REQUIRE_BOOTLOADER=1 refuses a payload without one"
assert_contains "$(cat "$tmp/build-require.log")" "CI_REQUIRE_BOOTLOADER=1" \
  "ac-1 the refusal names the switch that asked for it"

# =========================================================================== #
# ac-1: where the shipped menu comes from - every branch, not just the rendering one
#
# CI does not let the payload stage render its own menu: the image stage renders
# $CI_TMP_ROOT/disk/grub.cfg first and the payload stage is pointed at it. That branch was
# never exercised here, and it was broken in the one way the self-rendering branch could not
# show: `<work>/render` only existed inside the branch that rendered, so the redirect of the
# menu check's log failed and the `||` reported "the menu violates the rendering rules" -
# a message that sends the reader to the menu instead of to the missing directory. S5 stayed
# red while this suite was green.
# =========================================================================== #

# A menu the checker accepts, taken from the self-rendering build above and then made
# *distinguishable*: a straight copy would make "the member ships the external menu byte for
# byte" compare a file with itself, which stays green even when the external branch is dead.
# (The first version of this test did exactly that; the audit's mutation experiment caught
# it - rendering the menu instead of using this one left all 114 assertions green.)
menu_ok="$tmp/menu-ok/grub.cfg"
mkdir -p "$tmp/menu-ok"
cp "$build/payload/work/render/grub.cfg" "$menu_ok"
printf '\n# menu rendered by the image stage, not by the payload\n' >>"$menu_ok"

# --- the menu the image stage rendered, found by convention -----------------
external="$tmp/ci-external"
mkdir -p "$external/disk"
cp "$menu_ok" "$external/disk/grub.cfg"
PATH="$tmp/fixtures/bin:$PATH" \
  CI_TMP_ROOT="$external" CI_LOG_DIR="$external/logs" \
  CI_FETCH_DIR="$tmp/fixtures/fetch" CI_INITRAMFS="$tmp/fixtures/initramfs.cpio.gz" \
  CI_PLATFORM_VERSION="0.0.7-test" \
  CI_UPSTREAM_VERSION="25.12.2" CI_PLATFORM_RUNTIME_DIR="$tmp/fixtures/runtime" \
  CI_PAYLOAD_OUT="$tmp/out/payload-external.tar" CI_BOOT_SRC="$tmp/fixtures/esp" \
  bash "$payload_build" >"$tmp/build-external.log" 2>&1
assert_eq "$?" "0" "ac-1 a payload builds with the image stage disk/grub.cfg"
assert_contains "$(cat "$tmp/build-external.log")" "boot.tar" \
  "ac-1 the external-menu build still reports the bootloader member"
assert_file_exists "$external/payload/work/render/grub-check.log" \
  "ac-1 the render directory exists even when the menu came from outside"
assert_eq "$(grep -c 'no such file' "$tmp/build-external.log")" "0" \
  "ac-1 the external-menu build never reports a missing file"
mkdir -p "$tmp/external-unpacked"
tar -xf "$tmp/out/payload-external.tar" -C "$tmp/external-unpacked"
mkdir -p "$tmp/external-boot"
tar -xf "$tmp/external-unpacked/boot.tar" -C "$tmp/external-boot"
assert_eq "$(shasum -a 256 "$tmp/external-boot/boot/grub/grub.cfg" | cut -d' ' -f1)" \
  "$(shasum -a 256 "$menu_ok" | cut -d' ' -f1)" \
  "ac-1 the member ships the external menu byte for byte instead of rendering another one"

# --- the menu named outright -----------------------------------------------
cfg_build="$tmp/ci-cfg"
PATH="$tmp/fixtures/bin:$PATH" \
  CI_TMP_ROOT="$cfg_build" CI_LOG_DIR="$cfg_build/logs" \
  CI_FETCH_DIR="$tmp/fixtures/fetch" CI_INITRAMFS="$tmp/fixtures/initramfs.cpio.gz" \
  CI_PLATFORM_VERSION="0.0.7-test" \
  CI_UPSTREAM_VERSION="25.12.2" CI_PLATFORM_RUNTIME_DIR="$tmp/fixtures/runtime" \
  CI_PAYLOAD_OUT="$tmp/out/payload-cfg.tar" CI_BOOT_SRC="$tmp/fixtures/esp" \
  CI_BOOTLOADER_CFG="$menu_ok" \
  bash "$payload_build" >"$tmp/build-cfg.log" 2>&1
assert_eq "$?" "0" "ac-1 a payload builds from CI_BOOTLOADER_CFG"
assert_file_exists "$cfg_build/payload/work/render/grub-check.log" \
  "ac-1 CI_BOOTLOADER_CFG builds write the check log in the same directory"

# --- the menu the caller named wins over the one a stage left behind --------
# Both variables set, pointing at different menus: CI_GRUB_OUTPUT is what an earlier stage
# rendered, CI_BOOTLOADER_CFG is what the caller chose. The fragment read the former
# unconditionally for one revision and shipped a menu nobody named, so the priority has to
# be asserted with two distinguishable files rather than assumed.
menu_other="$tmp/menu-other/grub.cfg"
mkdir -p "$tmp/menu-other"
cp "$menu_ok" "$menu_other"
printf '# rendered by some earlier stage, not the menu this build was told to ship\n' >>"$menu_other"
both="$tmp/ci-both"
mkdir -p "$both/disk"
cp "$menu_other" "$both/disk/grub.cfg"
PATH="$tmp/fixtures/bin:$PATH" \
  CI_TMP_ROOT="$both" CI_LOG_DIR="$both/logs" \
  CI_FETCH_DIR="$tmp/fixtures/fetch" CI_INITRAMFS="$tmp/fixtures/initramfs.cpio.gz" \
  CI_PLATFORM_VERSION="0.0.7-test" \
  CI_UPSTREAM_VERSION="25.12.2" CI_PLATFORM_RUNTIME_DIR="$tmp/fixtures/runtime" \
  CI_PAYLOAD_OUT="$tmp/out/payload-both.tar" CI_BOOT_SRC="$tmp/fixtures/esp" \
  CI_BOOTLOADER_CFG="$menu_ok" CI_GRUB_OUTPUT="$menu_other" \
  bash "$payload_build" >"$tmp/build-both.log" 2>&1
assert_eq "$?" "0" "ac-1 a build with both menu variables set succeeds"
mkdir -p "$tmp/both" "$tmp/both-boot"
tar -xf "$tmp/out/payload-both.tar" -C "$tmp/both"
tar -xf "$tmp/both/boot.tar" -C "$tmp/both-boot"
assert_eq "$(shasum -a 256 "$tmp/both-boot/boot/grub/grub.cfg" | cut -d' ' -f1)" \
  "$(shasum -a 256 "$menu_ok" | cut -d' ' -f1)" \
  "ac-1 CI_BOOTLOADER_CFG wins over CI_GRUB_OUTPUT"
assert_eq "$(grep -c 'not the menu this build was told to ship' "$tmp/both-boot/boot/grub/grub.cfg")" "0" \
  "ac-1 the menu the earlier stage rendered is not the one that ships"

# --- an external menu that really does violate the rules --------------------
# The failure has to be the checker's, so the log it was written to has to exist: that is
# the difference between "the menu is wrong" and "the log could not be created".
bad_menu="$tmp/menu-bad/grub.cfg"
mkdir -p "$tmp/menu-bad"
# A menu that satisfies every rule but the last: an unreplaced placeholder. Starting from
# the accepted menu keeps the failure the checker reports the one under test (rule 5).
cp "$menu_ok" "$bad_menu"
printf '\n# @UNREPLACED@\n' >>"$bad_menu"
bad="$tmp/ci-bad-menu"
PATH="$tmp/fixtures/bin:$PATH" \
  CI_TMP_ROOT="$bad" CI_LOG_DIR="$bad/logs" \
  CI_FETCH_DIR="$tmp/fixtures/fetch" CI_INITRAMFS="$tmp/fixtures/initramfs.cpio.gz" \
  CI_PLATFORM_VERSION="0.0.7-test" \
  CI_UPSTREAM_VERSION="25.12.2" CI_PLATFORM_RUNTIME_DIR="$tmp/fixtures/runtime" \
  CI_PAYLOAD_OUT="$tmp/out/payload-bad-menu.tar" CI_BOOT_SRC="$tmp/fixtures/esp" \
  CI_BOOTLOADER_CFG="$bad_menu" \
  bash "$payload_build" >"$tmp/build-bad-menu.log" 2>&1
assert_eq "$?" "1" "ac-1 a menu that breaks the rendering rules fails the build"
assert_contains "$(cat "$tmp/build-bad-menu.log")" "violates the rendering rules" \
  "ac-1 the failure says the menu broke the rules"
assert_file_exists "$bad/payload/work/render/grub-check.log" \
  "ac-1 and the log the checker wrote to exists, so the message is the checker's"
assert_contains "$(cat "$bad/payload/work/render/grub-check.log")" "rule 5" \
  "ac-1 the log carries the rule the checker found, not a shell redirection error"

# --- the platform version has no fallback ----------------------------------
# assemble.sh and disk.sh lost theirs first; a value invented here would end up in the
# rendered release file, which is the number the payload is judged by.
no_version=$(env -u CI_PLATFORM_VERSION \
  PATH="$tmp/fixtures/bin:$PATH" \
  CI_TMP_ROOT="$tmp/ci-no-version" CI_LOG_DIR="$tmp/ci-no-version/logs" \
  CI_FETCH_DIR="$tmp/fixtures/fetch" CI_INITRAMFS="$tmp/fixtures/initramfs.cpio.gz" \
  CI_UPSTREAM_VERSION="25.12.2" CI_PLATFORM_RUNTIME_DIR="$tmp/fixtures/runtime" \
  CI_PAYLOAD_OUT="$tmp/out/payload-no-version.tar" CI_BOOT_SRC="$tmp/fixtures/esp" \
  bash "$payload_build" 2>&1)
assert_eq "$?" "1" "ac-1 payload-build.sh refuses to run without CI_PLATFORM_VERSION"
assert_contains "$no_version" "CI_PLATFORM_VERSION is required" \
  "ac-1 the refusal names the missing platform version"
assert_eq "$(grep -c ':-0\.0\.' "$payload_build")" "0" \
  "ac-1 payload-build.sh carries no platform version fallback"

# =========================================================================== #
# ac-2: the write path
# =========================================================================== #

esp="$tmp/esp"
p4="$tmp/p4"
slots="$tmp/slots"
bin="$tmp/bin"
mkdir -p "$esp/EFI/BOOT" "$esp/boot/grub" "$esp/ab/log" "$p4" "$slots/b/@sys" "$slots/b/@platform" \
  "$slots/b/@sys/sbin" "$slots/b/@sys/etc" "$bin"
printf '#!/bin/sh\n' >"$slots/b/@sys/sbin/init"
chmod +x "$slots/b/@sys/sbin/init"

# What the ESP looks like before the upgrade: a loader and a menu of the flashed release.
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" old
printf 'set default=0\nset fallback=0\n' >"$esp/boot/grub/grub.cfg"
printf '{"generation":1,"committed":"a","pending":null,"slots":{"a":{"rootfs":"25.12.2","upper":"@overlay-25.12.2"},"b":{"rootfs":"25.12.2","upper":"@overlay-25.12.2"}}}\n' \
  >"$esp/ab/state.json"
old_loader_sha="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"

# --- stubs: everything the adapter would touch on a real machine ------------
cat >"$bin/sha256sum" <<'STUB'
#!/bin/sh
for f in "$@"; do
  [ -f "$f" ] && printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
done
STUB
cat >"$bin/ab-slot" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:-/dev/null}"
case "${1:-status}" in
  status)
    if [ -n "${STUB_STATUS_FILE:-}" ] && [ -f "${STUB_STATUS_FILE}" ]; then
      cat "${STUB_STATUS_FILE}"
    else
      printf '%s\n' "${STUB_STATUS:-slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none p4=ok}"
    fi
    ;;
  rootfs) printf '%s\n' "${STUB_ROOTFS:-25.12.2}" ;;
  layer)
    if [ "${STUB_FAIL_SLOT:-}" = "layer" ]; then
      echo "stub: refusing layer write" >&2
      exit 1
    fi
    exit 0
    ;;
  next) printf '%s\n' "next=${STUB_NEXT:-b}" ;;
  gc) exit 0 ;;
  *) exit 0 ;;
esac
STUB
# The adapter asks about two filesystems: the writable partition (5% rule) and the ESP
# (the bootloader has to fit). One stub answers both so a test can starve just one.
cat >"$bin/df" <<'STUB'
#!/bin/sh
if [ "${STUB_DF_ESP_GARBAGE:-0}" = "1" ]; then
  case "$*" in
    *esp*) : ;;
    *) avail="${STUB_DF_AVAIL:-800000}"
       printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
       printf '/dev/fake %s 0 %s 0%% %s\n' "${STUB_DF_TOTAL:-1000000}" "${avail}" "${STUB_DF_MOUNT:-/tmp}"
       exit 0 ;;
  esac
  # A mount point long enough to wrap the columns: the fourth field of the second line is
  # then not a number, which is what the space check has to refuse instead of ignoring.
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf '/dev/fake 1000000 0 no-room-left 100%% /var/folders/a/very/long/mount/point/for/boot\n'
  exit 0
fi
avail="${STUB_DF_AVAIL:-800000}"
case "$*" in
  *esp*) avail="${STUB_DF_ESP_AVAIL:-${STUB_DF_AVAIL:-800000}}" ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake %s 0 %s 0%% %s\n' "${STUB_DF_TOTAL:-1000000}" "${avail}" "${STUB_DF_MOUNT:-/tmp}"
STUB
# The two slots are real btrfs filesystems on a machine; a directory tree with the same
# subvolume names is enough for everything the adapter asks of them.
cat >"$bin/btrfs" <<'STUB'
#!/bin/sh
case "${1:-}" in
  subvolume)
    case "${2:-}" in
      snapshot) cp -a "$3" "$4" 2>/dev/null || true ;;
      create)
        # STUB_FAIL_BTRFS=create injects the "a step after the bootloader write failed"
        # case, which is what the ESP rollback exists for.
        if [ "${STUB_FAIL_BTRFS:-}" = "create" ]; then
          echo "stub: refusing subvolume create" >&2
          exit 1
        fi
        mkdir -p "$3"
        ;;
      delete)
        shift 2
        for a in "$@"; do [ "$a" = "-C" ] && continue; rm -rf "$a"; done
        ;;
      *) : ;;
    esac
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
ab_find_partition() { printf '%s' "${STUB_PARTITION:-/dev/fake}"; }
STUB
cat >"$bin/mv" <<'STUB'
#!/bin/sh
# STUB_CORRUPT_MV=1 makes the rename itself land the wrong bytes: the staged copy verified
# fine before it, so this is the only way to reach the comparison that runs after the move.
# Only the first rename is corrupted: a machine whose FAT rename goes wrong once can still
# be restored, and the cases below need to tell "the write went wrong" from "nothing works".
if [ "${STUB_CORRUPT_MV:-0}" = "1" ] && [ ! -f "${STUB_MV_MARKER:-/nonexistent}" ]; then
  case "$*" in
    *BOOTX64.EFI*)
      for last in "$@"; do :; done
      /bin/mv "$@" || exit 1
      printf 'after-rename' >>"${last}"
      : >"${STUB_MV_MARKER:-/dev/null}"
      exit 0
      ;;
  esac
fi
exec /bin/mv "$@"
STUB
cat >"$bin/cp" <<'STUB'
#!/bin/sh
# STUB_CORRUPT=1 makes a copy out of the ESP staging directory land corrupted, which is
# the only way to prove the "compare after write, restore on mismatch" branch: everything
# else in the path reports success exactly like a broken FAT write would.
# STUB_CORRUPT_MENU=1 does the same for grub.cfg only, so the menu's own pre-write check
# cannot hide behind the loader's.
# `cp src dst` is two arguments. An earlier version of this stub assumed three and handed
# BSD cp an empty destination, which copies the file into the *current directory* - the
# repository root, because the test cd's there. That is how stray BOOTX64.EFI/grub.cfg files
# kept appearing in the worktree after every suite run.
dst="${3:-$2}"
case "${STUB_CORRUPT:-0}:$*" in
  1:*".boot-stage"*)
    /bin/cp "$1" "$dst" || exit 1
    printf 'corrupted' >>"$dst"
    exit 0
    ;;
esac
# A restore is a copy *out of* the backup directory. Matching on "@boot-backup" anywhere would
# also corrupt the copy that *creates* the backup, which is a different failure.
if [ "${STUB_CORRUPT_RESTORE:-0}" = "1" ]; then
  case "$1" in
    *"@boot-backup"*)
      case "$dst" in
        *"@boot-backup"*) : ;;
        *)
          /bin/cp "$1" "$dst" || exit 1
          printf 'restored-wrong' >>"$dst"
          exit 0
          ;;
      esac
      ;;
  esac
fi
case "${STUB_CORRUPT_MENU:-0}:$*" in
  1:*".boot-stage"*grub.cfg*)
    /bin/cp "$1" "$dst" || exit 1
    printf 'menu-corrupted' >>"$dst"
    exit 0
    ;;
esac
exec /bin/cp "$@"
STUB
chmod +x "$bin"/*

# --- payload builder -------------------------------------------------------
# build_payload <dir> <version> [--no-boot] [--lying-loader-sha]
build_payload() {
  local dir="$1" version="$2"
  shift 2
  local with_boot=1 lie=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-boot) with_boot=0; shift ;;
      --lying-loader-sha) lie=1; shift ;;
      *) echo "bad arg $1" >&2; return 1 ;;
    esac
  done
  rm -rf "$dir"
  mkdir -p "$dir/rootfs/sbin" "$dir/rootfs/etc" "$dir/cpio/lib/modules/6.12.103" \
    "$dir/boot/EFI/BOOT" "$dir/boot/boot/grub"
  printf '#!/bin/sh\n' >"$dir/rootfs/sbin/init"
  chmod +x "$dir/rootfs/sbin/init"
  printf 'payload %s\n' "$version" >"$dir/rootfs/etc/banner"
  tar -czf "$dir/rootfs.tar.gz" -C "$dir/rootfs" .
  printf 'vermagic=6.12.103 SMP mod_unload \n' >"$dir/kernel.bin"
  printf 'vermagic=6.12.103 SMP mod_unload \n' >"$dir/cpio/lib/modules/6.12.103/btrfs.ko"
  ( cd "$dir/cpio" && find . -print | cpio -o -H newc 2>/dev/null ) | gzip -9 >"$dir/initramfs.cpio.gz"
  printf 'platform\n' >"$dir/platform-member.txt"
  mkdir -p "$dir/platform/usr/sbin"
  : >"$dir/platform/usr/sbin/btrfs"
  chmod +x "$dir/platform/usr/sbin/btrfs"
  tar -cf "$dir/platform.tar" -C "$dir" platform-member.txt
  # The layer has to be runnable by the adapter's own check: an upgraded slot without
  # btrfs boots and then cannot commit, which is the failure that check exists for.
  tar -rf "$dir/platform.tar" -C "$dir/platform" usr
  if [ "$with_boot" = "1" ]; then
    make_loader "$dir/boot/EFI/BOOT/BOOTX64.EFI" new
    printf 'set default=0\nset fallback=0\n' >"$dir/boot/boot/grub/grub.cfg"
    tar -cf "$dir/boot.tar" -C "$dir/boot" .
  fi
  python3 - "$dir" "$version" "$with_boot" "$lie" <<'PYTHON'
import hashlib, json, pathlib, sys
stage = pathlib.Path(sys.argv[1])
version, with_boot, lie = sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"


def digest(path):
    data = pathlib.Path(path).read_bytes()
    return {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


names = ["initramfs.cpio.gz", "kernel.bin", "platform.tar", "rootfs.tar.gz"]
if with_boot:
    names.append("boot.tar")
members = {name: digest(stage / name) for name in names}
doc = {"format": "ab-payload/1", "rootfs": version, "members": members, "bootloader": None}
if with_boot:
    loader = digest(stage / "boot/EFI/BOOT/BOOTX64.EFI")
    sha = "0" * 64 if lie else loader["sha256"]
    doc["bootloader"] = {
        "member": "boot.tar",
        "loader": "EFI/BOOT/BOOTX64.EFI",
        "menu": "boot/grub/grub.cfg",
        "loader_bytes": loader["size"],
        "loader_sha256": sha,
        "menu_sha256": digest(stage / "boot/boot/grub/grub.cfg")["sha256"],
        "grub_version": "2.12",
    }
(stage / "manifest.json").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
PYTHON
  rm -rf "$dir/rootfs" "$dir/cpio" "$dir/platform" "$dir/platform-member.txt"
  tar -cf "$dir/payload.tar" -C "$dir" manifest.json
  for member in rootfs.tar.gz kernel.bin initramfs.cpio.gz platform.tar boot.tar; do
    [ -f "$dir/$member" ] && tar -rf "$dir/payload.tar" -C "$dir" "$member"
  done
  printf '%s' "$dir/payload.tar"
}

# run_install <payload.tar> [flags...] [ENV=value...]: flags reach ab-upgrade, assignments
# reach its environment; nothing is guessed from the payload's contents.
run_install() {
  local payload="$1"
  shift
  local flags="" assignments=""
  for arg in "$@"; do
    case "$arg" in
      *=*) assignments="${assignments} ${arg}" ;;
      *) flags="${flags} ${arg}" ;;
    esac
  done
  # shellcheck disable=SC2086  # the two lists are rebuilt on purpose
  env PATH="$bin:$PATH" AB_ESP="$esp" AB_P4="$p4" AB_LIB="$lib" \
    AB_PARTITIONS_LIB="$bin/ab-partitions.sh" AB_SLOTS_ROOT="$slots" \
    AB_PACKAGES_FILE="$esp/ab/packages" STUB_CALLS="$tmp/ab-slot.calls" \
    ${assignments} sh "$ab_upgrade" ${flags} "$payload" 2>&1
}

# --- the happy path --------------------------------------------------------
good="$(build_payload "$tmp/p1" 25.12.3-test1)"
out="$(run_install "$good")"
assert_eq "$?" "0" "ac-2 an upgrade with a bootloader in the payload succeeds"
assert_contains "$out" "bootloader written" "ac-2 the write is reported"
new_loader_sha="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"
assert_eq "$new_loader_sha" "$(shasum -a 256 "$tmp/p1/boot/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" \
  "ac-2 the ESP's loader is the payload's loader, byte for byte"
assert_eq "$(shasum -a 256 "$esp/boot/grub/grub.cfg" | cut -d' ' -f1)" \
  "$(shasum -a 256 "$tmp/p1/boot/boot/grub/grub.cfg" | cut -d' ' -f1)" \
  "ac-2 the ESP's menu is the payload's menu"
assert_file_exists "$p4/@boot-backup/25.12.3-test1/SHA256SUMS" \
  "ac-2 the bytes that were replaced are backed up on the writable partition"
assert_contains "$(cat "$p4/@boot-backup/25.12.3-test1/SHA256SUMS")" "$old_loader_sha" \
  "ac-2 the backup records the old loader's digest"
assert_file_exists "$p4/@boot-backup/25.12.3-test1/EFI/BOOT/BOOTX64.EFI" \
  "ac-2 the backup holds the old bytes themselves, not just a digest"
assert_contains "$out" "slot b is pending on" "ac-2 the slot is only marked pending after the write"

# --- a second install of the same bootloader writes nothing ----------------
rm -rf "$p4/@boot-backup"
out="$(run_install "$good" STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "0" "ac-2 reinstalling succeeds with --force"
assert_contains "$out" "bootloader unchanged" "ac-2 an identical bootloader is not rewritten"
assert_eq "$([ -d "$p4/@boot-backup" ] && echo made || echo none)" "none" \
  "ac-2 nothing is backed up when there is nothing to write"

# --- --no-bootloader is the escape hatch -----------------------------------
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" keepme
kept_sha="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"
other="$(build_payload "$tmp/p2" 25.12.4-test1)"
out="$(run_install "$other" --no-bootloader)"
assert_eq "$?" "0" "ac-2 --no-bootloader still installs the slot"
assert_contains "$out" "bootloader skipped-by-flag" "ac-2 the escape hatch says it skipped the write"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" "$kept_sha" \
  "ac-2 --no-bootloader leaves the loader's bytes untouched"

# --- a payload without the member: default says so, --bootloader refuses ---
bare="$(build_payload "$tmp/p3" 25.12.5-test1 --no-boot)"
out="$(run_install "$bare")"
assert_eq "$?" "0" "ac-2 a payload from before the member existed still installs"
assert_contains "$out" "bootloader absent-in-payload" "ac-2 the missing member is reported"

out="$(run_install "$bare" --bootloader)"
assert_eq "$?" "74" "ac-2 --bootloader refuses a payload without one"
assert_contains "$out" "reason=payload-without-bootloader" "ac-2 the refusal names the reason"

# --- failures: the target slot and the ESP stay as they were ---------------
state_before="$(shasum -a 256 "$esp/ab/state.json" | cut -d' ' -f1)"
esp_before="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"

: >"$tmp/ab-slot.calls"
lying="$(build_payload "$tmp/p4-payload" 25.12.6-test1 --lying-loader-sha)"
out="$(run_install "$lying")"
# A failure inside the bootloader stage is a refusal, not a half-done install: nothing was
# written and nothing has to be undone, which is exit 74 by the documented contract.
assert_eq "$?" "74" "ac-2 a payload whose boot.tar does not match its manifest is refused"
assert_contains "$out" "reason=bootloader-digest-mismatch" "ac-2 the failure names the mismatch"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" "$esp_before" \
  "ac-2 the failed install left the ESP's loader alone"
assert_eq "$(shasum -a 256 "$esp/ab/state.json" | cut -d' ' -f1)" "$state_before" \
  "ac-2 the failed install left the slot state alone"
# ab-upgrade reads the slot state before it writes anything; what must never happen is a
# state *mutation* (`layer`/`pending`) on an install that failed.
mutations="$(grep -cE '^(layer|pending|commit|rollback)' "$tmp/ab-slot.calls" 2>/dev/null || true)"
[ -n "$mutations" ] || mutations=0
assert_eq "$mutations" "0" "ac-2 the failed install never mutated the slot state"

# The write lands corrupted: the compare has to catch it and put the old bytes back.
out="$(run_install "$good" STUB_CORRUPT=1 STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "74" "ac-2 a write that does not land is refused (the ESP is back as it was)"
assert_contains "$out" "reason=bootloader-write-not-verified" "ac-2 the failure names the verification"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" "$esp_before" \
  "ac-2 the corrupted write was restored from the backup"
assert_eq "$(shasum -a 256 "$esp/ab/state.json" | cut -d' ' -f1)" "$state_before" \
  "ac-2 the restored install left the slot state alone"

# No room on the ESP: refuse before touching anything.
out="$(run_install "$good" STUB_DF_ESP_AVAIL=8 STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "74" "ac-2 an ESP without room is refused before anything is written"
assert_contains "$out" "reason=bootloader-no-space" "ac-2 the failure names the space check"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" "$esp_before" \
  "ac-2 a refused install writes nothing to the ESP"

# =========================================================================== #
# ac-3: the properties the audit of this path demanded
# =========================================================================== #
#
# Each case here exists because the previous version of these tests stayed green while the
# property it was supposed to guard was broken.

# --- ac-3a the stage runs before anything else is written -------------------
# The whole safety argument is that the ESP write happens while the target slot is still
# untouched. That is a property of the source order, so it is asserted on the source: a
# reordering that keeps every behaviour test green fails here.
payload_body="$(sed -n '/^platform_copy_rootfs()/,/^}/p' "$lib")"
boot_line="$(printf '%s\n' "$payload_body" | grep -n 'upgrade_bootloader_install' | head -n 1 | cut -d: -f1)"
snapshot_line="$(printf '%s\n' "$payload_body" | grep -n 'btrfs subvolume snapshot' | head -n 1 | cut -d: -f1)"
assert_eq "$([ -n "$boot_line" ] && [ -n "$snapshot_line" ] && [ "$boot_line" -lt "$snapshot_line" ] && echo before)" \
  "before" "ac-3a the bootloader is written before the writable layer is snapshotted"

# --- ac-3b flags after the payload are honoured ----------------------------
# `ab-upgrade payload.tar --check` used to install, and `... --no-bootloader` used to write
# the ESP: the parser stopped at the first positional argument.
before_sha="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"
: >"$tmp/ab-slot.calls"
out="$(run_install "$good" --check)"
assert_eq "$?" "0" "ac-3b --check after the payload is a dry run"
assert_contains "$out" "check only, nothing written" "ac-3b and it says so"
assert_eq "$(grep -cE '^(layer|pending|commit|rollback)' "$tmp/ab-slot.calls" || true)" "0" \
  "ac-3b --check after the payload mutated no slot state"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" "$before_sha" \
  "ac-3b --check after the payload wrote nothing to the ESP"

out="$(run_install "$good" --no-bootloader)"
assert_eq "$?" "0" "ac-3b --no-bootloader after the payload installs the slot"
assert_contains "$out" "bootloader skipped-by-flag" "ac-3b the escape hatch is honoured after the path too"

out="$(run_install "$good" --check --bootloader --no-bootloader)"
assert_eq "$?" "2" "ac-3b contradicting bootloader flags are a usage error"
out="$(run_install "$good" --no-bootloader --bootloader)"
assert_eq "$?" "2" "ac-3b and the same pair in the other order is refused too"
assert_contains "$out" "contradict each other" "ac-3b the message says what is wrong"
out="$(env PATH="$bin:$PATH" sh "$ab_upgrade" "$good" "$good" 2>&1)"
assert_eq "$?" "2" "ac-3b two payloads on the command line are a usage error"
assert_contains "$out" "unexpected argument" "ac-3b and the message names the problem"

# --- ac-3c .prev keeps the bytes that were replaced on the ESP itself -------
# The backup on the writable partition is unreachable for a machine that cannot start, and
# the boot chain lives on the same ESP, so a second copy has to stay next to the loader.
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" again
printf 'set default=1\nset fallback=1\n' >"$esp/boot/grub/grub.cfg"
prev_loader="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"
prev_menu="$(shasum -a 256 "$esp/boot/grub/grub.cfg" | cut -d' ' -f1)"
out="$(run_install "$good" STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "0" "ac-3c the install writes the bootloader"
assert_file_exists "$esp/EFI/BOOT/BOOTX64.EFI.prev" "ac-3c the replaced loader is kept as .prev"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI.prev" | cut -d' ' -f1)" "$prev_loader" \
  "ac-3c .prev is byte identical to the loader it replaced"
assert_eq "$(shasum -a 256 "$esp/boot/grub/grub.cfg.prev" | cut -d' ' -f1)" "$prev_menu" \
  "ac-3c the replaced menu is kept as .prev too"
assert_eq "$([ -e "$esp/EFI/BOOT/BOOTX64.EFI.new" ] && echo left || echo none)" "none" \
  "ac-3c no .new file is left behind"

# --- ac-3d a failure after the bootloader write rolls the ESP back ---------
# Without this, "the upgrade failed" could still mean "the ESP carries the new bootloader
# and the slot carries nothing".
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" rollbackme
rollback_sha="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"
rollback_state="$(shasum -a 256 "$esp/ab/state.json" | cut -d' ' -f1)"
later="$(build_payload "$tmp/p-later" 25.12.8-test1)"
out="$(run_install "$later" STUB_FAIL_BTRFS=create)"
assert_eq "$?" "1" "ac-3d a slot copy that fails after the bootloader write fails the install"
assert_contains "$out" "rolled the ESP bootloader back" "ac-3d the rollback is reported"
assert_contains "$(cat "$lib")" "upgrade_bootloader_rollback" "ac-3d the rollback has one implementation"
assert_contains "$(cat "$ab_upgrade")" "upgrade_bootloader_rollback" "ac-3d and the caller runs it"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" "$rollback_sha" \
  "ac-3d the ESP carries the bootloader it had before the failed install"
assert_eq "$(shasum -a 256 "$esp/ab/state.json" | cut -d' ' -f1)" "$rollback_state" \
  "ac-3d and the slot state is unchanged"

# --- ac-3o an empty backup is not a successful restore --------------------
# `_upgrade_boot_backup` records nothing when the ESP carried neither the loader nor the menu
# (a wiped ESP is a legal state), and the restore used to walk zero entries and return
# success. The install then logged "the ESP carries <digest> again" and ab-upgrade answered
# 74, "refused before writing anything", while the ESP was carrying bytes this run wrote and
# never verified - the one signal an operator uses to decide whether to reflash. The rollback
# has to say it failed instead.
esp_empty="$tmp/esp-empty"
mkdir -p "$esp_empty/ab/log"
cp "$esp/ab/state.json" "$esp_empty/ab/state.json"
out="$(run_install "$good" STUB_FAIL_BTRFS=create AB_ESP="$esp_empty" \
  AB_PACKAGES_FILE="$esp_empty/ab/packages")"
rc=$?
assert_eq "$rc" "1" "ac-3o a rollback with nothing to restore fails the install"
assert_contains "$out" "FAILED TO ROLL BACK" \
  "ac-3o the rollback admits it could not restore anything"
assert_eq "$(printf '%s\n' "$out" | grep -c 'rolled the ESP bootloader back')" "0" \
  "ac-3o and does not claim the ESP was rolled back"
assert_file_exists "$esp_empty/EFI/BOOT/BOOTX64.EFI" \
  "ac-3o the bytes the failed run wrote are still there, and now reported as uncertain"

# --- ac-3e a dirty ESP is not written to -----------------------------------
# esp=dirty is the one state in which a FAT write goes wrong and `df` lies; the upgrade
# refuses instead of trading a working machine for an untested one.
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" dirtyesp
dirty_sha="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"
printf '%s\n' 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none p4=ok boot=ok esp=dirty' \
  >"$tmp/status-dirty"
out="$(run_install "$good" STUB_STATUS_FILE="$tmp/status-dirty" STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "74" "ac-3e a dirty ESP refuses the install"
assert_contains "$out" "reason=bootloader-esp-dirty" "ac-3e the refusal names the ESP state"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" "$dirty_sha" \
  "ac-3e and nothing was written to it"
# The escape hatch still works on a dirty ESP: it never touches the loader.
out="$(run_install "$good" STUB_STATUS_FILE="$tmp/status-dirty" STUB_ROOTFS=25.12.0 --force --no-bootloader)"
assert_eq "$?" "0" "ac-3e --no-bootloader still installs on a dirty ESP"

# --- ac-3f --check refuses what the install would refuse -------------------
lying_check="$(build_payload "$tmp/p-lying-check" 25.12.9-test1 --lying-loader-sha)"
out="$(run_install "$lying_check" --check)"
assert_eq "$?" "74" "ac-3f a dry run refuses a payload whose boot.tar contradicts its manifest"
assert_contains "$out" "reason=bootloader-digest-mismatch" "ac-3f and names the mismatch"

# --- ac-3g unreadable df is a refusal, not a green light -------------------
out="$(run_install "$good" STUB_DF_ESP_GARBAGE=1 STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "74" "ac-3g an unparseable df refuses the install"
assert_contains "$out" "reason=bootloader-space-unknown" "ac-3g the refusal names the space check"

# --- ac-3h a corrupted menu is caught before it reaches the ESP ------------
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" menucheck
printf 'set default=1\nset fallback=1\n' >"$esp/boot/grub/grub.cfg"
menu_sha_before="$(shasum -a 256 "$esp/boot/grub/grub.cfg" | cut -d' ' -f1)"
out="$(run_install "$good" STUB_CORRUPT_MENU=1 STUB_ROOTFS=25.12.0 --force)"
# The staged menu is correct, so the pre-write check passes; the corruption lands on the
# copy, which is what the post-write comparison exists for.
assert_eq "$?" "74" "ac-3h a menu write that does not land is refused"
assert_contains "$out" "reason=bootloader-write-not-verified" "ac-3h the refusal names the comparison"
assert_eq "$(shasum -a 256 "$esp/boot/grub/grub.cfg" | cut -d' ' -f1)" "$menu_sha_before" \
  "ac-3h the ESP menu is back to the bytes it had before the attempt"

# --- ac-3i the newest backups survive pruning ------------------------------
# Retention used to sort by name, so installing 25.12.0 deleted the backup of the previous
# release and kept the oldest one.
rm -rf "$p4/@boot-backup"
for old in 25.9.0 25.10.0 25.12.9; do
  mkdir -p "$p4/@boot-backup/$old"
  : >"$p4/@boot-backup/$old/SHA256SUMS"
done
touch -t 202501010000 "$p4/@boot-backup/25.9.0"
touch -t 202506010000 "$p4/@boot-backup/25.10.0"
touch -t 202511010000 "$p4/@boot-backup/25.12.9"
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" prunecheck
out="$(run_install "$good" STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "0" "ac-3i the install that prunes succeeds"
assert_eq "$([ -d "$p4/@boot-backup/25.12.3-test1" ] && echo kept || echo gone)" "kept" \
  "ac-3i the backup just written is kept"
assert_eq "$([ -d "$p4/@boot-backup/25.12.9" ] && echo kept || echo gone)" "kept" \
  "ac-3i the newest previous backup is kept"
assert_eq "$([ -d "$p4/@boot-backup/25.9.0" ] && echo kept || echo gone)" "gone" \
  "ac-3i the oldest backup is the one removed"

# --- ac-3j the bytes are re-checked after the rename ----------------------
# The staged copy is verified before the move; a rename that lands something else (a torn
# FAT rename, a short write) is exactly the case that leaves a machine unbootable.
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" mvcheck
printf 'set default=1\nset fallback=1\n' >"$esp/boot/grub/grub.cfg"
mv_before="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"
out="$(run_install "$good" STUB_CORRUPT_MV=1 STUB_MV_MARKER="$tmp/mv-mark" STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "74" "ac-3j a rename that lands the wrong bytes is refused"
assert_contains "$out" "reason=bootloader-write-not-verified" "ac-3j the post-rename comparison caught it"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" "$mv_before" \
  "ac-3j and the ESP carries the loader it had before the attempt"

# --- ac-3k a rollback that cannot verify is a failure, not a refusal ------
# 74 promises "nothing was written". When the restore itself cannot be verified the ESP may
# carry the new loader while the old slot still runs, and that must not look like a refusal.
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" rollbackfail
rm -f "$tmp/mv-mark"
out="$(run_install "$good" STUB_CORRUPT_MV=1 STUB_MV_MARKER="$tmp/mv-mark" STUB_CORRUPT_RESTORE=1 STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "1" "ac-3k a rollback that cannot be verified leaves as a failure"
assert_contains "$out" "reason=bootloader-rollback-failed" "ac-3k and the reason says the ESP is uncertain"

# --- ac-3l the announce step failing rolls the ESP back too ---------------
# platform_upgrade_end writes the state file and the pending marker. If it fails after the
# bootloader was written, the pair has to be put back together.
make_loader "$esp/EFI/BOOT/BOOTX64.EFI" endfail
end_before="$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)"
out="$(run_install "$good" STUB_FAIL_SLOT=layer STUB_ROOTFS=25.12.0 --force)"
assert_eq "$?" "1" "ac-3l a state write that fails fails the install"
assert_contains "$out" "rolled the ESP bootloader back" "ac-3l the ESP is rolled back"
assert_eq "$(shasum -a 256 "$esp/EFI/BOOT/BOOTX64.EFI" | cut -d' ' -f1)" "$end_before" \
  "ac-3l and carries the bootloader it had"

# --- ac-3m the margin is the documented one -------------------------------
# Free space just under the documented margin is refused, just over it is accepted, so the
# number in the code and the number in the docs cannot drift apart silently.
margin_check() { # <free KiB>
  run_install "$good" STUB_DF_ESP_AVAIL="$1" STUB_ROOTFS=25.12.0 --force >/dev/null 2>&1
  printf '%s' "$?"
}
loader_k=$(( ( $(wc -c <"$tmp/p1/boot/EFI/BOOT/BOOTX64.EFI") + 1023 ) / 1024 ))
assert_eq "$(margin_check $((loader_k + 2000)))" "74" \
  "ac-3m less than the documented margin (loader + 4 MiB) is refused"
assert_eq "$(margin_check $((loader_k + 8000)))" "0" \
  "ac-3m more than the margin is accepted"

# --- ac-3n esp-prepare publishes the bootloader identity ------------------
# The build side is what puts the identity into the manifest; it needs sudo to mount the
# upstream image, so the contract is asserted on the script: the four outputs and the rule
# that reads the version out of the loader.
prepare_src="$(cat "$root/scripts/ci/esp-prepare.sh")"
for key in efi_loader_sha256 loader_bytes grub_version; do
  assert_contains "$prepare_src" "ci_emit_output \"${key}\"" "ac-3n esp-prepare publishes ${key}"
done
assert_contains "$prepare_src" 'GNU GRUB  version' \
  "ac-3n the version is read from GRUB's own message, not from a bare X.Y scan"
assert_contains "$prepare_src" 'unknown' \
  "ac-3n and an unreadable version is reported as unknown instead of guessed"

finish
