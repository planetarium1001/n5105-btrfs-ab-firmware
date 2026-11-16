#!/usr/bin/env bash
# Module: ab
# The payload an upgrade installs has to carry the same tooling the image ships. Without
# the btrfs closure the upgraded slot boots and then cannot finish: the boot hook records
# btrfs-tool-missing, the health check has nothing to reclaim with, and the slot never
# commits - on a machine that is a hang, in CI it was a 900 second timeout.
#   ac-1 the payload build merges the runtime closure into the platform layer and refuses
#        to produce a payload without an executable usr/sbin/btrfs
#   ac-2 the platform layer's mode rules keep that tool executable
#   ac-3 the upgrade refuses a payload whose platform layer has no btrfs, before the slot
#        is marked pending
#   ac-4 ci-s5 hands the runtime tree to the payload build
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

payload_build="$root/scripts/ci/payload-build.sh"
platform_sh="$root/platform/lib/upgrade/platform.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------- #
# ac-1: the payload build merges the runtime tree and refuses to ship without btrfs
# --------------------------------------------------------------------------- #

build_src=$(cat "$payload_build")
assert_contains "$build_src" "CI_PLATFORM_RUNTIME_DIR" \
  "ac-1 the payload build takes the runtime tree"
assert_contains "$build_src" 'cp -a "${runtime_tree}/." "${work}/content/platform/"' \
  "ac-1 the runtime closure is merged into the payload's platform layer"
assert_contains "$build_src" '[ -d "${runtime_tree}" ]' \
  "ac-1 a missing runtime tree stops the build"
assert_contains "$build_src" '[ -x "${work}/content/platform/usr/sbin/btrfs" ]' \
  "ac-1 the payload is refused without an executable btrfs"
assert_contains "$build_src" 'payload_platform_bytes' \
  "ac-1 the platform layer size is published for the report"

# --------------------------------------------------------------------------- #
# ac-1b: a real payload build, with the runtime closure merged in
#
# The interesting question is not "is the file there" but "does the layer hide anything
# the root filesystem already provides". The platform layer is the first lower layer of
# the merged root, so a second copy of musl, libz or libgcc in it wins over @sys and the
# upgraded system stops running its own tools - which is what a broken upgrade looks like.
# --------------------------------------------------------------------------- #

fixtures="$tmp/fixtures"
mkdir -p "$fixtures/fetch/upstream" "$fixtures/bin" "$fixtures/rootfs/etc" \
  "$fixtures/runtime/usr/sbin" "$fixtures/runtime/lib" "$fixtures/runtime/usr/lib"
printf 'init\n' >"$fixtures/rootfs/etc/init"
# libz is provided by the root filesystem, so the layer must not carry a second copy.
printf 'system libz\n' >"$fixtures/rootfs/libz-marker"
mkdir -p "$fixtures/rootfs/lib"
printf 'system libz\n' >"$fixtures/rootfs/lib/libz.so.1"
tar -czf "$fixtures/fetch/upstream/rootfs.tar.gz" -C "$fixtures/rootfs" .
printf 'kernel\n' >"$fixtures/fetch/upstream/kernel.bin"
printf 'initramfs\n' >"$fixtures/initramfs.cpio.gz"
: >"$fixtures/runtime/usr/sbin/btrfs"
printf 'runtime libz\n' >"$fixtures/runtime/lib/libz.so.1"
printf 'runtime zstd\n' >"$fixtures/runtime/usr/lib/libzstd.so.1"

# bsdtar does not know the GNU ownership flags the build uses for reproducibility; strip
# them so the stage runs unchanged on a developer machine.
cat >"$fixtures/bin/tar" <<'SHIM'
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
chmod +x "$fixtures/bin/tar"
# BSD sed cannot combine -i with several -e expressions; write the result in place
# instead, which is what the Linux build host gets from GNU sed.
cat >"$fixtures/bin/sed" <<'SHIM'
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
chmod +x "$fixtures/bin/sed"

payload_out="$tmp/out/payload.tar"
PATH="$fixtures/bin:$PATH" \
  CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" CI_FETCH_DIR="$fixtures/fetch" \
  CI_INITRAMFS="$fixtures/initramfs.cpio.gz" CI_UPSTREAM_VERSION="25.12.2" \
  CI_PLATFORM_VERSION="0.0.7-test" \
  CI_PLATFORM_RUNTIME_DIR="$fixtures/runtime" CI_PAYLOAD_OUT="$payload_out" \
  CI_EMIT_OUTPUT="$tmp/ci/outputs.env" \
  bash "$payload_build" >"$tmp/build.log" 2>&1
build_rc=$?
assert_eq "$build_rc" "0" "ac-1 a payload builds with the runtime closure merged"
assert_file_exists "$payload_out" "ac-1 the payload tar was produced"

mkdir -p "$tmp/unpacked/platform"
tar -xf "$payload_out" -C "$tmp/unpacked"
tar -xf "$tmp/unpacked/platform.tar" -C "$tmp/unpacked/platform" || {
  echo "could not unpack platform.tar" >&2
  exit 1
}
# The layer must be a real tree, not an empty extraction that makes every check pass.
assert_file_exists "$tmp/unpacked/platform/usr/sbin/btrfs" \
  "ac-1 the platform layer unpacks to a tree"
assert_file_exists "$tmp/unpacked/platform/etc/init.d/ab-boot" \
  "ac-1 and carries the platform hooks"
assert_eq "$([ -x "$tmp/unpacked/platform/usr/sbin/btrfs" ] && echo yes)" "yes" \
  "ac-1 the payload platform layer carries an executable btrfs"
assert_eq "$([ -e "$tmp/unpacked/platform/lib/libz.so.1" ] && echo shadowed || echo absent)" "absent" \
  "ac-1 a library the root filesystem provides is not shadowed by the layer"
assert_eq "$([ -e "$tmp/unpacked/platform/usr/lib/libzstd.so.1" ] && echo kept || echo lost)" "kept" \
  "ac-1 a library only the runtime provides is kept"
assert_contains "$(cat "$tmp/build.log")" "dropped the runtime files the root filesystem already provides: lib/libz.so.1" \
  "ac-1 the drop is reported"
assert_contains "$(cat "$tmp/ci/outputs.env" 2>/dev/null || cat "$tmp/build.log")" \
  "payload_platform_shadowed" \
  "ac-1 the report names the dropped file"
# The build must refuse a payload without the tooling.
rm -rf "$tmp/ci2"
PATH="$fixtures/bin:$PATH" \
  CI_TMP_ROOT="$tmp/ci2" CI_LOG_DIR="$tmp/ci2/logs" CI_FETCH_DIR="$fixtures/fetch" \
  CI_INITRAMFS="$fixtures/initramfs.cpio.gz" CI_UPSTREAM_VERSION="25.12.2" \
  CI_PLATFORM_VERSION="0.0.7-test" \
  CI_PLATFORM_RUNTIME_DIR="$tmp/no-runtime" CI_PAYLOAD_OUT="$tmp/out/payload2.tar" \
  bash "$payload_build" >"$tmp/build2.log" 2>&1
assert_eq "$?" "1" "ac-1 a payload without a runtime tree is refused"
assert_contains "$(cat "$tmp/build2.log")" "runtime tree not found" \
  "ac-1 the refusal says what is missing"

# --------------------------------------------------------------------------- #
# ac-2: the mode rules the payload uses keep the tool executable
# --------------------------------------------------------------------------- #

layer="$tmp/layer"
mkdir -p "$layer/usr/sbin" "$layer/usr/lib" "$layer/etc/init.d" "$layer/lib/upgrade"
: >"$layer/usr/sbin/btrfs"
: >"$layer/usr/sbin/ab-slot"
: >"$layer/usr/lib/libfake.so.1"
: >"$layer/etc/init.d/ab-boot"
: >"$layer/lib/upgrade/platform.sh"
: >"$layer/lib/ab-slot-cfg.sh"
# The helper comes from the CI library, which sets -euo pipefail: run it in a subshell so
# the test's own control flow is not affected.
(
  # shellcheck source=scripts/ci/lib.sh
  . "$root/scripts/ci/lib.sh"
  ci_platform_modes "$layer"
)
assert_eq "$([ -x "$layer/usr/sbin/btrfs" ] && echo yes)" "yes" \
  "ac-2 ci_platform_modes keeps usr/sbin/btrfs executable"
assert_eq "$([ -x "$layer/usr/sbin/ab-slot" ] && echo yes)" "yes" \
  "ac-2 and the slot tool with it"
assert_eq "$([ -x "$layer/usr/lib/libfake.so.1" ] && echo no || echo no)" "no" \
  "ac-2 shared objects stay plain files"
assert_eq "$([ -x "$layer/etc/init.d/ab-boot" ] && echo yes)" "yes" \
  "ac-2 the init hooks stay executable"
assert_eq "$([ -x "$layer/lib/ab-slot-cfg.sh" ] && echo no || echo no)" "no" \
  "ac-2 a sourced library is readable, not executable"

# --------------------------------------------------------------------------- #
# ac-3: the upgrade refuses a platform layer without btrfs
# --------------------------------------------------------------------------- #

platform_src=$(cat "$platform_sh")
assert_contains "$platform_src" 'upgrade_fail "platform-layer-without-btrfs"' \
  "ac-3 the upgrade refuses a platform layer without btrfs"
assert_contains "$platform_src" '[ -x "${_platform}/usr/sbin/btrfs" ]' \
  "ac-3 the check is on the extracted layer, not on the payload's manifest"

# The refusal has to happen while the payload is being copied, i.e. before the slot is
# marked pending: a pending slot without the tooling is the hang this prevents.
copy_body="$(sed -n '/^platform_copy_rootfs()/,/^}/p' "$platform_sh")"
refuse_line="$(printf '%s\n' "$copy_body" | grep -n 'platform-layer-without-btrfs' | head -n 1 | cut -d: -f1)"
assert_eq "$([ -n "$refuse_line" ] && echo present)" "present" \
  "ac-3 the refusal lives in platform_copy_rootfs"
assert_contains "$(sed -n '/^platform_upgrade_end()/,/^}/p' "$platform_sh")" 'ab-slot pending' \
  "ac-3 the pending marker is only set after the copy succeeded"

# --------------------------------------------------------------------------- #
# ac-4: ci-s5 wires the runtime tree into the payload build
# --------------------------------------------------------------------------- #

s5_body=$(cat "$root/.github/workflows/ci-s5.yml")
assert_contains "$s5_body" "CI_PLATFORM_RUNTIME_DIR: \${{ runner.temp }}/ci/runtime" \
  "ac-4 ci-s5 gives the payload build the runtime tree"
# The same tree feeds the disk image, so image and payload carry one closure.
assert_eq "$(printf '%s\n' "$s5_body" | grep -c 'CI_PLATFORM_RUNTIME_DIR:')" "2" \
  "ac-4 both the image and the payload use the runtime tree"

# --------------------------------------------------------------------------- #
# ac-5 (F1 ac-2): the snapshot inherits a package shadow, so the copy clears it
# --------------------------------------------------------------------------- #
# The new slot's writable layer is a snapshot of the running one, so it also inherits the
# upstream /lib/upgrade files an apk upgrade wrote into the upper. Upper wins over every
# lower layer, so the platform layer installed right after the snapshot would never be
# the adapter the slot loads. The copy has to move them aside - after the snapshot,
# before @sys is replaced - keep them under /mnt/p4/ab/shadow-backup-<ts>/ and never fail
# the install when it cannot.

shadow_body="$(sed -n '/^_upgrade_shadow_clean()/,/^}/p' "$platform_sh")"
manifest_body="$(sed -n '/^_upgrade_shadow_manifest()/,/^}/p' "$platform_sh")"
assert_eq "$([ -n "$shadow_body" ] && echo present)" "present" \
  "ac-5 the cleanup is one helper"
# The set to clear is derived from the payload's own platform.tar, not from a name list in
# the helper: the layer about to be installed is what a leftover upper copy would shadow,
# so the payload defines the set. The four upstream names survive only as the fallback for
# a payload whose member cannot be listed.
assert_contains "$manifest_body" 'platform.tar' \
  "ac-5 the path set is derived from the payload's platform layer"
assert_contains "$manifest_body" 'tar -tvf' \
  "ac-5 the derivation reads the member types, not only the names"
assert_contains "$shadow_body" 'derived ' \
  "ac-5 the run reports how many paths the layer list had"
assert_contains "$shadow_body" 'reason=platform-tar-unreadable' \
  "ac-5 an unreadable member falls back to the upstream names and says so"
for rel in lib/upgrade/platform.sh lib/upgrade/fwtool.sh lib/upgrade/stage2 lib/upgrade/tar.sh; do
  assert_contains "$shadow_body" "$rel" "ac-5 the fallback still names ${rel}"
done
assert_contains "$shadow_body" 'shadow-backup-' \
  "ac-5 the moved files are kept under a backup directory"
assert_contains "$shadow_body" 'reason=shadow-backup-failed' \
  "ac-5 a failed backup records a token"
assert_contains "$shadow_body" 'reason=shadow-move-failed' \
  "ac-5 a failed move records a token"

copy_body="$(sed -n '/^platform_copy_rootfs()/,/^}/p' "$platform_sh")"
snap_line="$(printf '%s\n' "$copy_body" | grep -n 'snapshotted' | head -n 1 | cut -d: -f1)"
shadow_line="$(printf '%s\n' "$copy_body" | grep -n -F '_upgrade_shadow_clean "${_new_layer}"' | head -n 1 | cut -d: -f1)"
sys_line="$(printf '%s\n' "$copy_body" | grep -n "replace the target slot's system tree" | head -n 1 | cut -d: -f1)"
assert_eq "$([ -n "$snap_line" ] && [ -n "$shadow_line" ] && [ -n "$sys_line" ] &&
  [ "$snap_line" -lt "$shadow_line" ] && [ "$shadow_line" -lt "$sys_line" ] && echo ordered)" \
  "ordered" "ac-5 the shadow is cleared after the snapshot and before @sys is replaced"
# The call has to hand the payload over. Without it the helper cannot derive anything and
# every run would silently take the fallback.
assert_contains "$copy_body" '_upgrade_shadow_clean "${_new_layer}" "${_payload}"' \
  "ac-5 the copy passes the payload the list is derived from"

# The helper itself, on a fixture writable layer: the four files moved, the user's files and
# the rest of lib/upgrade untouched, one backup that still carries the original bytes. No
# payload is passed, so this is the fallback path - the case a payload without a readable
# platform.tar takes, and the behaviour the function had before the list was derived.
shadow_p4="$tmp/shadow-p4"
shadow_layer="@overlay-25.12.2"
mkdir -p "$shadow_p4/$shadow_layer/upper/lib/upgrade" "$shadow_p4/$shadow_layer/upper/etc"
for rel in platform.sh fwtool.sh stage2 tar.sh; do
  printf 'upstream %s\n' "$rel" >"$shadow_p4/$shadow_layer/upper/lib/upgrade/$rel"
done
printf 'user edit\n' >"$shadow_p4/$shadow_layer/upper/etc/banner"
printf 'platform only\n' >"$shadow_p4/$shadow_layer/upper/lib/upgrade/other.sh"

out="$(AB_P4="$shadow_p4" AB_ESP="$tmp/esp" AB_PARTITIONS_LIB="$tmp/no-partitions.sh" \
  sh -c '. "$1"; _upgrade_shadow_clean "@overlay-25.12.2"' sh "$platform_sh" 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-5 a cleanup failure never fails the copy"
assert_eq "$(ls "$shadow_p4/$shadow_layer/upper/lib/upgrade" 2>/dev/null | tr '\n' ' ')" \
  "other.sh " "ac-5 exactly the four upstream files are moved out of the upper"
assert_file_exists "$shadow_p4/$shadow_layer/upper/etc/banner" \
  "ac-5 the user's own upper files are left alone"
assert_contains "$out" "reason=platform-tar-unreadable" \
  "ac-5 with no payload the fallback is named in the log"
backup="$(find "$shadow_p4/ab" -mindepth 1 -maxdepth 1 -name 'shadow-backup-*' 2>/dev/null | head -n 1)"
assert_eq "$([ -n "$backup" ] && echo present)" "present" "ac-5 the move leaves a backup directory"
for rel in platform.sh fwtool.sh stage2 tar.sh; do
  assert_file_exists "$backup/lib/upgrade/$rel" "ac-5 the backup keeps ${rel}"
done
assert_eq "$(cat "$backup/lib/upgrade/platform.sh" 2>/dev/null)" "upstream platform.sh" \
  "ac-5 the backup carries the bytes that were there"
assert_contains "$out" "shadow moved out of the snapshot: lib/upgrade/platform.sh" \
  "ac-5 each moved file is named"
assert_contains "$out" "backup " "ac-5 the backup path is reported"

# Nothing to move: no backup directory is created.
out="$(AB_P4="$tmp/shadow-empty" AB_ESP="$tmp/esp" AB_PARTITIONS_LIB="$tmp/no-partitions.sh" \
  sh -c '. "$1"; _upgrade_shadow_clean "@overlay-1"' sh "$platform_sh" 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-5 a layer without an upper is a no-op"
assert_eq "$([ -d "$tmp/shadow-empty/ab" ] && echo created || echo none)" "none" \
  "ac-5 and it creates no backup directory"

# The backup cannot be made: token, no failure, the file stays where it was.
fail_p4="$tmp/shadow-fail"
mkdir -p "$fail_p4/$shadow_layer/upper/lib/upgrade"
printf 'upstream platform\n' >"$fail_p4/$shadow_layer/upper/lib/upgrade/platform.sh"
printf 'not a directory\n' >"$fail_p4/ab"
out="$(AB_P4="$fail_p4" AB_ESP="$tmp/esp" AB_PARTITIONS_LIB="$tmp/no-partitions.sh" \
  sh -c '. "$1"; _upgrade_shadow_clean "@overlay-25.12.2"' sh "$platform_sh" 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-5 a backup that cannot be created does not fail the copy"
assert_contains "$out" "reason=shadow-backup-failed" "ac-5 and the token says why"
assert_file_exists "$fail_p4/$shadow_layer/upper/lib/upgrade/platform.sh" \
  "ac-5 nothing is moved when there is nowhere to keep it"

# --------------------------------------------------------------------------- #
# ac-9 (F8): the cleanup set is the payload's platform layer, so the paths that are not
# part of upstream's sysupgrade interface are cleared too
# --------------------------------------------------------------------------- #
# F8 on a real machine: a platform-only update from 0.0.9 to 0.0.10 left
# upper/etc/platform-release holding the old version, overlay returned the upper copy, and
# the machine kept reporting 0.0.9 although the new @platform said 0.0.10. The four-name
# list above cannot fix that: /etc/platform-release is not one of the names. The set is
# therefore derived from the payload's platform.tar - exactly the files the layer about to
# be installed ships - and the upper copy of any of them is the shadow.

mkplatform() { # <dir> [extra files...]: a platform.tar with the given regular members
  local dir="$1" member
  shift
  mkdir -p "$dir/src"
  for member in "$@"; do
    mkdir -p "$dir/src/$(dirname "$member")"
    printf 'layer %s\n' "$member" >"$dir/src/$member"
  done
  tar -cf "$dir/platform.tar" -C "$dir/src" .
}

# The layer a real payload carries, contracted to the paths this case is about.
derived="$tmp/derived-payload"
mkplatform "$derived" etc/platform-release lib/upgrade/platform.sh usr/sbin/ab-slot \
  usr/lib/libfake.so.1 etc/rc.d/S15ab-boot

# A manifest listing the member's regular files is what the helper reads.
manifest_out="$(AB_P4="$tmp/none" sh -c '. "$1"; _upgrade_shadow_manifest "$2"' sh \
  "$platform_sh" "$derived" 2>&1)"
assert_contains "$manifest_out" "etc/platform-release" \
  "ac-9 the derived list carries a layer file upstream does not own"
assert_contains "$manifest_out" "lib/upgrade/platform.sh" \
  "ac-9 and the one it does"
assert_contains "$manifest_out" "usr/sbin/ab-slot" \
  "ac-9 and the layer's own tools"
# Directories and symlinks are not regular files: their upper copy is either meaningless or
# not what this cleanup repairs, and moving one would delete the user's directory entry.
assert_eq "$(printf '%s\n' "$manifest_out" | grep -c 'etc/rc.d/$' || true)" "0" \
  "ac-9 a directory member is not in the derived list"
assert_eq "$(printf '%s\n' "$manifest_out" | grep -c '\./$' || true)" "0" \
  "ac-9 the archive's own root entry is not in the derived list"

# The motivating F8 case: upper/etc/platform-release (the old version) is moved out and
# backed up, and the merged view falls through to the layer the payload installs.
derived_p4="$tmp/derived-p4"
derived_layer="@overlay-25.12.2"
mkdir -p "$derived_p4/$derived_layer/upper/etc" "$derived_p4/$derived_layer/upper/lib/upgrade" \
  "$derived_p4/$derived_layer/upper/usr/sbin" "$derived_p4/$derived_layer/upper/usr/lib"
printf 'PLATFORM_VERSION=0.0.9\n' >"$derived_p4/$derived_layer/upper/etc/platform-release"
printf 'upstream platform\n' >"$derived_p4/$derived_layer/upper/lib/upgrade/platform.sh"
# The user's own files, and a file the payload's layer does not ship: neither may be touched.
printf 'user edit\n' >"$derived_p4/$derived_layer/upper/etc/banner"
printf 'not in this platform.tar\n' >"$derived_p4/$derived_layer/upper/lib/upgrade/other.sh"
printf 'shadow of a layer tool\n' >"$derived_p4/$derived_layer/upper/usr/sbin/ab-slot"
# A symlink whose name happens to be a layer path: not a regular file in the tar, but the
# upper has a link there. It must survive, because this cleanup moves files only.
ln -sf ../init.d/ab-boot "$derived_p4/$derived_layer/upper/etc/rc.d" 2>/dev/null || true

out="$(AB_P4="$derived_p4" AB_ESP="$tmp/esp" AB_PARTITIONS_LIB="$tmp/no-partitions.sh" \
  sh -c '. "$1"; _upgrade_shadow_clean "@overlay-25.12.2" "$2"' sh \
  "$platform_sh" "$derived" 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-9 a derived cleanup never fails the copy"
assert_contains "$out" "shadow cleanup derived 5 path(s) from platform.tar" \
  "ac-9 the run reports how many paths it derived"
assert_contains "$out" "shadow moved out of the snapshot: etc/platform-release" \
  "ac-9 the F8 path is cleared even though no package owns it"
assert_contains "$out" "shadow moved out of the snapshot: usr/sbin/ab-slot" \
  "ac-9 and the layer's own tools, which the four-name list never covered"
assert_eq "$([ -e "$derived_p4/$derived_layer/upper/etc/platform-release" ] && echo there || echo gone)" \
  "gone" "ac-9 upper/etc/platform-release no longer shadows the new layer"
assert_file_exists "$derived_p4/$derived_layer/upper/etc/banner" \
  "ac-9 a user file that is not a layer path is left alone"
assert_file_exists "$derived_p4/$derived_layer/upper/lib/upgrade/other.sh" \
  "ac-9 a lib/upgrade file this payload does not ship is left alone"
derived_backup="$(find "$derived_p4/ab" -mindepth 1 -maxdepth 1 -name 'shadow-backup-*' 2>/dev/null | head -n 1)"
assert_eq "$(cat "$derived_backup/etc/platform-release" 2>/dev/null)" "PLATFORM_VERSION=0.0.9" \
  "ac-9 the backup keeps the bytes that were shadowing the layer"
assert_file_exists "$derived_backup/lib/upgrade/platform.sh" \
  "ac-9 nested paths are backed up under their own relative path"
assert_file_exists "$derived_backup/usr/sbin/ab-slot" \
  "ac-9 and so are the layer's tools"

# An empty layer list (a payload whose platform layer really carries no files) is not a
# fallback: it moves nothing, creates no backup, and says the list was derived as empty.
empty_derived="$tmp/derived-empty"
mkdir -p "$empty_derived/src"
tar -cf "$empty_derived/platform.tar" -C "$empty_derived/src" .
empty_p4="$tmp/derived-empty-p4"
mkdir -p "$empty_p4/$derived_layer/upper/etc"
printf 'user edit\n' >"$empty_p4/$derived_layer/upper/etc/banner"
out="$(AB_P4="$empty_p4" AB_ESP="$tmp/esp" AB_PARTITIONS_LIB="$tmp/no-partitions.sh" \
  sh -c '. "$1"; _upgrade_shadow_clean "@overlay-25.12.2" "$2"' sh \
  "$platform_sh" "$empty_derived" 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-9 an empty derived list is not an error"
assert_contains "$out" "shadow cleanup derived 0 path(s) from platform.tar" \
  "ac-9 it reports an empty derivation instead of falling back"
assert_eq "$([ -d "$empty_p4/ab" ] && echo created || echo none)" "none" \
  "ac-9 an empty list creates no backup directory"
assert_file_exists "$empty_p4/$derived_layer/upper/etc/banner" \
  "ac-9 and touches nothing"

# A damaged member is not silently treated as "the layer is empty": the fallback names the
# upstream four and the token says why, so an operator can tell the two apart.
broken_payload="$tmp/broken-payload"
mkdir -p "$broken_payload"
printf 'this is not a tar\n' >"$broken_payload/platform.tar"
broken_p4="$tmp/broken-p4"
mkdir -p "$broken_p4/$derived_layer/upper/lib/upgrade"
printf 'upstream platform\n' >"$broken_p4/$derived_layer/upper/lib/upgrade/platform.sh"
printf 'not a layer name\n' >"$broken_p4/$derived_layer/upper/lib/upgrade/other.sh"
out="$(AB_P4="$broken_p4" AB_ESP="$tmp/esp" AB_PARTITIONS_LIB="$tmp/no-partitions.sh" \
  sh -c '. "$1"; _upgrade_shadow_clean "@overlay-25.12.2" "$2"' sh \
  "$platform_sh" "$broken_payload" 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-9 a damaged platform.tar does not fail the copy"
assert_contains "$out" "reason=platform-tar-unreadable" \
  "ac-9 a damaged member takes the fallback and says why"
assert_eq "$([ -e "$broken_p4/$derived_layer/upper/lib/upgrade/platform.sh" ] && echo there || echo gone)" \
  "gone" "ac-9 the fallback list is what gets cleared when the member cannot be read"
assert_file_exists "$broken_p4/$derived_layer/upper/lib/upgrade/other.sh" \
  "ac-9 and the fallback still only touches the four names upstream owns"

# --------------------------------------------------------------------------- #
# ac-9 (F8): the second layer, derived at build time - only apk-owned paths
# --------------------------------------------------------------------------- #
# The cleanup above repairs a snapshot; the prevention is `apk upgrade` refusing to write
# over a protected path. A `+` rule compares the visible file with the apk database, so it
# only applies to a path the database knows: /etc/platform-release has no owner (measured:
# `apk info -W /etc/platform-release` reports no owner package) and a rule for it protects
# nothing. The build therefore derives the list as the platform layer's files intersected
# with the root filesystem's apk database, and this asserts the derivation on real bytes:
# the real assembler, a rootfs whose database owns some of the layer's paths and not
# others, and the member the stage publishes.
assemble="$root/scripts/ci/assemble.sh"
assert_file_exists "$assemble" "ac-9 the release assembler exists"
# The stage requires an initramfs input before it reaches the platform layer. This case
# never boots it: only the stage's staging of the layer is under test.
printf 'initramfs\n' >"$tmp/derived-initramfs.cpio.gz"

# A rootfs whose apk database owns lib/upgrade/platform.sh and usr/sbin/ab-slot, and does
# not own etc/platform-release or usr/sbin/ab-upgrade. The record format is the one the
# stage parses: F:<dir> starts a directory context, R:<name> is an entry inside it.
apk_rootfs="$tmp/apk-rootfs"
mkdir -p "$apk_rootfs/etc" "$apk_rootfs/lib/apk/db"
printf 'init\n' >"$apk_rootfs/etc/init"
cat >"$apk_rootfs/lib/apk/db/installed" <<'DB'
C:Q1fixture=
P:base-files
V:1950~fixture
F:
R:lib
F:lib/upgrade
R:platform.sh
F:usr/sbin
R:ab-slot
DB
apk_fetch="$tmp/apk-fetch"
mkdir -p "$apk_fetch/upstream"
tar -czf "$apk_fetch/upstream/rootfs.tar.gz" -C "$apk_rootfs" .
printf 'kernel\n' >"$apk_fetch/upstream/kernel.bin"
apk_run="$tmp/apk-runtime"
mkdir -p "$apk_run/usr/sbin"
: >"$apk_run/usr/sbin/btrfs"
chmod +x "$apk_run/usr/sbin/btrfs"

# The stage stops after the platform layer when it cannot find a boot source; that failure
# comes after platform.tar is written, so the member is there to read. The stage exits
# non-zero on purpose, which is why the status is not asserted here.
apk_ci="$tmp/apk-ci"
mkdir -p "$apk_ci"
# bsdtar refuses the GNU reproducibility flags the build uses for platform.tar.
cat >"$tmp/apk-tar" <<'SHIM'
#!/bin/sh
kept=""
for arg in "$@"; do
  case "${arg}" in
    --numeric-owner | --owner=* | --group=*) continue ;;
  esac
  kept="${kept} ${arg}"
done
exec /usr/bin/tar ${kept}
SHIM
chmod +x "$tmp/apk-tar"
mkdir -p "$tmp/apk-bin"
mv "$tmp/apk-tar" "$tmp/apk-bin/tar"
PATH="$tmp/apk-bin:$PATH" \
  CI_TMP_ROOT="$apk_ci" CI_LOG_DIR="$apk_ci/logs" CI_FETCH_DIR="$apk_fetch" \
  CI_INITRAMFS="$tmp/derived-initramfs.cpio.gz" CI_UPSTREAM_VERSION="25.12.2" \
  CI_PLATFORM_VERSION="0.0.11-test" CI_KERNEL_PACKAGE="6.12.103-1-fixture" \
  CI_PLATFORM_RUNTIME_DIR="$apk_run" CI_OUTPUT_ENV="$apk_ci/outputs.env" \
  bash "$assemble" >"$tmp/apk-assemble.log" 2>&1
apk_member="$apk_ci/assemble/payload/platform.tar"
assert_file_exists "$apk_member" "ac-9 the stage publishes a platform.tar before the boot stage"
apk_list="$(tar -xzOf "$apk_member" ./etc/apk/protected_paths.d/ab-platform-shadow.list 2>/dev/null)"
assert_eq "$([ -n "$apk_list" ] && echo present)" "present" \
  "ac-9 the derived protected-path list is inside the platform layer"
assert_contains "$(cat "$tmp/apk-assemble.log")" "protected paths: 2 of" \
  "ac-9 the stage reports the derived count"

# Every entry: a `+` rule, a path inside the layer, and a path the database owns.
rule_count=0
bad_rule=0
while IFS= read -r line; do
  case "$line" in
    '' | '#'*) continue ;;
    +*) : ;;
    *) bad_rule=$((bad_rule + 1)) ; continue ;;
  esac
  rule_count=$((rule_count + 1))
  rel="${line#+}"
  tar -tf "$apk_member" | sed 's|^\./||' | grep -qxF "$rel" || bad_rule=$((bad_rule + 1))
done <<<"$apk_list"
assert_eq "$bad_rule" "0" "ac-9 every rule is a + path the platform layer really ships"
assert_eq "$rule_count" "2" "ac-9 the derivation finds exactly the owned layer files"
assert_contains "$apk_list" "+lib/upgrade/platform.sh" \
  "ac-9 an apk-owned layer file is protected"
assert_contains "$apk_list" "+usr/sbin/ab-slot" \
  "ac-9 and so is another path the database owns"
# The core correctness claim: an unowned path is absent, because a rule for it would
# protect nothing while reading as if the problem had been handled.
assert_eq "$(printf '%s\n' "$apk_list" | grep -c 'platform-release' || true)" "0" \
  "ac-9 a layer file no package owns is not in the list"
assert_eq "$(printf '%s\n' "$apk_list" | grep -c 'ab-upgrade$' || true)" "0" \
  "ac-9 nor is a layer file the database does not know"
# A directory in the database is not a file to protect.
assert_eq "$(printf '%s\n' "$apk_list" | grep -c '^+lib/upgrade$' || true)" "0" \
  "ac-9 a directory entry is not turned into a rule"

# A rootfs with no readable database: no list at all, and the stage still speaks. A guessed
# list is the one outcome worse than none, because it could protect a path that should be
# updated.
apk_ci2="$tmp/apk-ci2"
mkdir -p "$apk_ci2"
apk_fetch2="$tmp/apk-fetch2"
mkdir -p "$apk_fetch2/upstream" "$tmp/apk-rootfs2/etc"
printf 'init\n' >"$tmp/apk-rootfs2/etc/init"
tar -czf "$apk_fetch2/upstream/rootfs.tar.gz" -C "$tmp/apk-rootfs2" .
printf 'kernel\n' >"$apk_fetch2/upstream/kernel.bin"
PATH="$tmp/apk-bin:$PATH" \
  CI_TMP_ROOT="$apk_ci2" CI_LOG_DIR="$apk_ci2/logs" CI_FETCH_DIR="$apk_fetch2" \
  CI_INITRAMFS="$tmp/derived-initramfs.cpio.gz" CI_UPSTREAM_VERSION="25.12.2" \
  CI_PLATFORM_VERSION="0.0.11-test" CI_KERNEL_PACKAGE="6.12.103-1-fixture" \
  CI_PLATFORM_RUNTIME_DIR="$apk_run" CI_OUTPUT_ENV="$apk_ci2/outputs.env" \
  bash "$assemble" >"$tmp/apk-assemble2.log" 2>&1
apk_member2="$apk_ci2/assemble/payload/platform.tar"
assert_file_exists "$apk_member2" "ac-9 a rootfs without an apk database still stages a layer"
assert_eq "$(tar -tf "$apk_member2" 2>/dev/null | grep -c 'ab-platform-shadow.list' || true)" "0" \
  "ac-9 and ships no derived list rather than a guessed one"
assert_contains "$(cat "$tmp/apk-assemble2.log")" "no derived protected-path list" \
  "ac-9 the missing database is reported"

# --------------------------------------------------------------------------- #
# ac-6 (F1 ac-2): the shadow does not come back on the next apk upgrade
# --------------------------------------------------------------------------- #
# The cleanup repairs a snapshot that already carries the shadow. The prevention is apk's
# own protected-path list: apk-tools 3 (`apk-protected_paths(5)`) reads
# /etc/apk/protected_paths.d/*.list and does not overwrite a protected path; a `+` rule
# protects a file only when the visible file is not the one in the apk database, which is
# this case. The platform layer therefore has to ship the list.
protected="$root/platform/etc/apk/protected_paths.d/ab-upgrade-adapter.list"
assert_file_exists "$protected" "ac-6 the platform layer carries an apk protected-path list"
protected_src="$(cat "$protected" 2>/dev/null)"
for rel in lib/upgrade/platform.sh lib/upgrade/fwtool.sh lib/upgrade/stage2 lib/upgrade/tar.sh; do
  assert_contains "$protected_src" "+${rel}" "ac-6 ${rel} is protected from being overwritten"
done
assert_contains "$protected_src" "upper" "ac-6 the comment says what the rule prevents"
assert_contains "$protected_src" "apk-new" "ac-6 the comment says where the package's copy goes"
# The list is now the exception; the general case is derived at build time.
assert_contains "$protected_src" "ab-platform-shadow.list" \
  "ac-6 the comment names the derived list that covers every other layer file"
assert_contains "$protected_src" "scripts/ci/assemble.sh" \
  "ac-6 the comment says where the derivation lives"

finish
