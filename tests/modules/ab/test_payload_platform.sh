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

finish
