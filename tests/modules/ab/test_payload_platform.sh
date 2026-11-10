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
