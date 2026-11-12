#!/usr/bin/env bash
# Module: upgrade
# The release payload must carry the bootloader.
#
# It did not. scripts/ci/assemble.sh - the builder behind the tar users download - shipped
# rootfs.tar.gz, kernel.bin, initramfs.cpio.gz and platform.tar, so a machine that was only
# ever updated kept the GRUB it was flashed with. The S5 test payload
# (scripts/ci/payload-build.sh) did carry boot.tar, so CI exercised the member, went green,
# and the defect survived in the one artefact nobody re-checked.
#
# This is therefore a test of the release path, not of a function: it runs the real
# scripts/ci/assemble.sh end to end with the environment the CI stage hands it, then reads
# the payload the stage published. A unit test on ci_boot_member_stage would stay green for
# exactly the regression that happened - the fragment was fine, the release builder never
# called it - and the manifest alone is not evidence either, because the manifest is written
# from the same tree: every identity it records is compared here against the bytes that are
# really inside payload.tar and against the ESP fixture those bytes came from.
#   ac-1 the real assembler publishes a payload and its own checker accepts it
#   ac-2 payload.tar carries boot.tar, and the manifest's member table names it with the
#        digest and size of the bytes in the tar
#   ac-3 the manifest's bootloader block records the identity: member, GRUB version read
#        from the loader, loader_sha256/loader_bytes and menu_sha256, each matching the
#        fixture ESP and the shipped member
#   ac-4 the member unpacks to EFI/BOOT/BOOTX64.EFI and boot/grub/grub.cfg, and the loader
#        is the ESP's loader byte for byte
#   ac-5 the stage's payload_members output names boot.tar (what a device unpacks)
#   ac-6 the menu the image stage rendered wins over the one the stage would render - the
#        branch CI takes - and it ships byte for byte
#   ac-7 without a boot source the release build fails, and says the bootloader is why; no
#        payload is published
#   ac-8 both builders source the shared fragment and both call it, so the release payload
#        and the S5 payload cannot drift again
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

assemble="$root/scripts/ci/assemble.sh"
payload_build="$root/scripts/ci/payload-build.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Everything this test writes lives under $tmp. The assembler chmods the platform tree it
# is pointed at (ci_platform_modes "${CI_REPO_ROOT}/platform"), so CI_REPO_ROOT is a copy:
# running against the checkout would leave the worktree's file modes modified.
cd "$tmp" || exit 1

upstream_version="25.12.2"
platform_version="0.0.7-test"
kernel_package="6.12.103-1-0123456789abcdef0123456789abcdef"

sha_of() { # <file>: portable sha256 of a file's bytes
  python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
}

bytes_of() { # <file>: size of a file's bytes
  wc -c <"$1" | tr -d ' '
}

json_get() { # <file> <key:key:...>: one value out of a JSON document
  python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split(":"):
    value = value[key]
print(value)
PY
}

show_log() { # <log>: the stage's own output, indented, when an assertion needs explaining
  sed 's/^/    /' "$1" >&2
}

# --- a stand-in for the upstream EFI loader ---------------------------------
# The real one is 638,976 bytes of GRUB 2.12. What this test needs from it is the shape
# boot-member.sh reads the version out of - GRUB's own message followed by the version
# token - and bytes that can be told apart from any other loader.
make_loader() { # <path> <fill>
  python3 - "$1" "$2" <<'PY'
import sys
data = b"MZ" + (sys.argv[2].encode() * 64) + b"\0" + b"GNU GRUB  version %s\0" + b"2.12\0" + b"\0" * 4096
open(sys.argv[1], "wb").write(data)
PY
}

# --- fixtures: what the earlier CI stages hand the assemble stage -----------
mkdir -p "$tmp/fetch/upstream" "$tmp/rootfs/etc" "$tmp/runtime/usr/sbin" \
  "$tmp/esp/EFI/BOOT" "$tmp/bin" "$tmp/repo-root"
printf 'init\n' >"$tmp/rootfs/etc/init"
tar -czf "$tmp/fetch/upstream/rootfs.tar.gz" -C "$tmp/rootfs" .
printf 'kernel 6.12.103\n' >"$tmp/fetch/upstream/kernel.bin"

# ab-upgrade --check refuses an initramfs that carries no module vermagic (the real boot
# initramfs carries lib/modules/<ver>/btrfs.ko next to the metadata), so the fixture is a
# real cpio.gz with one module in it.
mkdir -p "$tmp/cpio/lib/modules/6.12.103"
printf 'vermagic=6.12.103 SMP mod_unload \n' >"$tmp/cpio/lib/modules/6.12.103/btrfs.ko"
( cd "$tmp/cpio" && find . -print | cpio -o -H newc 2>/dev/null ) | gzip -9 >"$tmp/initramfs.cpio.gz"

# The runtime stage's btrfs tooling: the payload's platform layer has to ship a runnable one.
: >"$tmp/runtime/usr/sbin/btrfs"
chmod +x "$tmp/runtime/usr/sbin/btrfs"

make_loader "$tmp/esp/EFI/BOOT/BOOTX64.EFI" loader-one
loader_sha="$(sha_of "$tmp/esp/EFI/BOOT/BOOTX64.EFI")"
loader_bytes="$(bytes_of "$tmp/esp/EFI/BOOT/BOOTX64.EFI")"

# --- the checkout as the stage sees it, minus the tools of a real machine ---
# The stage is pointed at a copy of the tree for two reasons. It chmods
# ${CI_REPO_ROOT}/platform, and it runs the product's checker from
# ${CI_REPO_ROOT}/platform/usr/sbin with that directory first on PATH, so the ab-slot that
# would ask a real btrfs about a real partition is replaced in the copy while the checkout
# keeps the real one.
#
# scripts/ci is copied as well: scripts/ci/grub-render.sh resolves its template as
# ${CI_REPO_ROOT}/scripts/ci/grub.cfg.in, so a copy without it cannot render the menu the
# payload ships and the stage dies with "cannot render the bootloader menu for the payload".
cp -a "$root/platform/." "$tmp/repo-root/platform/"
mkdir -p "$tmp/repo-root/scripts"
cp -a "$root/scripts/ci" "$tmp/repo-root/scripts/ci"

cat >"$tmp/bin/sha256sum" <<'STUB'
#!/bin/sh
# The target has busybox sha256sum; macOS has shasum. Only the digest field is consumed.
real=/usr/bin/sha256sum
[ -x "$real" ] || real=/bin/sha256sum
[ -x "$real" ] || real=""
for f in "$@"; do
  [ -f "$f" ] || continue
  if [ -n "$real" ]; then
    "$real" "$f" | cut -d' ' -f1 | tr -d '\n'
  else
    shasum -a 256 "$f" | cut -d' ' -f1 | tr -d '\n'
  fi
  printf '  %s\n' "$f"
done
STUB
cat >"$tmp/bin/ab-slot" <<'STUB'
#!/bin/sh
case "${1:-status}" in
  status) printf '%s\n' "${STUB_STATUS:-slot=a upper=@overlay-25.12.0 generation=1 committed=a pending=none p4=ok esp=ok}" ;;
  rootfs) printf '%s\n' "${STUB_ROOTFS:-25.12.0}" ;;
  *) exit 0 ;;
esac
STUB
cat >"$tmp/bin/df" <<'STUB'
#!/bin/sh
# macOS df has no GNU column layout; the stage and the checker both read field 2 (total)
# and field 4 (available) of the second line.
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake %s 0 %s 0%% %s\n' "${STUB_DF_TOTAL:-1000000}" "${STUB_DF_AVAIL:-800000}" "${STUB_DF_MOUNT:-/tmp}"
STUB
# The assemble stage formats and mounts a scratch btrfs for the checker's writable
# partition. Nothing here needs to be a filesystem: the stub only has to report success.
cat >"$tmp/bin/sudo" <<'STUB'
#!/bin/sh
while [ "${1:-}" = "-n" ]; do shift; done
exec "$@"
STUB
cat >"$tmp/bin/mkfs.btrfs" <<'STUB'
#!/bin/sh
exit 0
STUB
cat >"$tmp/bin/mount" <<'STUB'
#!/bin/sh
exit 0
STUB
cat >"$tmp/bin/umount" <<'STUB'
#!/bin/sh
exit 0
STUB
cat >"$tmp/bin/btrfs" <<'STUB'
#!/bin/sh
exit 0
STUB
# bsdtar refuses the GNU reproducibility flags the build uses.
cat >"$tmp/bin/tar" <<'STUB'
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
STUB
# BSD sed cannot combine -i with several -e expressions, and the image/release rendering
# uses that form.
cat >"$tmp/bin/sed" <<'STUB'
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
STUB
chmod +x "$tmp/bin"/*
cp "$tmp/bin/ab-slot" "$tmp/repo-root/platform/usr/sbin/ab-slot"
chmod +x "$tmp/repo-root/platform/usr/sbin/ab-slot"

# run_assemble <ci-tmp-root> <outputs-file> [ENV=VALUE...]
#
# The stage runs hermetically: every variable that could change which branch it takes is
# cleared first, so a value set in the developer's or the runner's shell (CI_GRUB_OUTPUT
# selects a menu, CI_BOOT_SRC a boot tree, GITHUB_OUTPUT would receive the stage's outputs)
# cannot make a green run mean something else.
run_assemble() {
  local ci_root="$1" outputs="$2"
  shift 2
  env \
    -u CI_GRUB_OUTPUT -u CI_GRUB_TEMPLATE -u CI_BOOTLOADER_CFG -u CI_BOOT_SRC \
    -u CI_BOOTLOADER_VERSION -u CI_REQUIRE_BOOTLOADER -u CI_BOOT_SOURCE_IMAGE \
    -u CI_BOOT_SOURCE_SHA256 \
    -u CI_ASSEMBLE_DIR -u CI_PAYLOAD_VERSION -u CI_OUTPUT_ENV -u GITHUB_OUTPUT \
    -u GITHUB_STEP_SUMMARY \
    PATH="$tmp/bin:$PATH" \
    CI_TMP_ROOT="$ci_root" CI_LOG_DIR="$ci_root/logs" CI_FETCH_DIR="$tmp/fetch" \
    CI_INITRAMFS="$tmp/initramfs.cpio.gz" \
    CI_PLATFORM_VERSION="$platform_version" CI_UPSTREAM_VERSION="$upstream_version" \
    CI_KERNEL_PACKAGE="$kernel_package" \
    CI_PLATFORM_RUNTIME_DIR="$tmp/runtime" CI_PLATFORM_SRC="$root/platform" \
    CI_REPO_ROOT="$tmp/repo-root" CI_OUTPUT_ENV="$outputs" \
    "$@" bash "$assemble"
}

# =========================================================================== #
# ac-1: the real release builder
# =========================================================================== #

ci1="$tmp/ci1"
mkdir -p "$ci1"
# CI_BOOT_SRC is the documented input; the default location is covered by ac-6.
run_assemble "$ci1" "$tmp/out1.env" CI_BOOT_SRC="$tmp/esp" >"$tmp/assemble-1.log" 2>&1
status=$?
assert_eq "$status" "0" "ac-1 the release assembler builds a payload from the CI environment"
[ "$status" = "0" ] || show_log "$tmp/assemble-1.log"

payload_dir="$ci1/assemble/payload"
payload_tar="$ci1/assemble/payload.tar"
assert_file_exists "$payload_tar" "ac-1 the stage publishes payload.tar"
assert_file_exists "$payload_dir/manifest.json" "ac-1 the payload carries a manifest"
# The stage hands every payload to the product's own checker, and that checker verifies
# the bootloader member against the manifest with the rules the device uses. Reaching this
# line means the assembled boot.tar passed them.
assert_contains "$(cat "$tmp/assemble-1.log")" "ab-upgrade: bootloader ok" \
  "ac-1 the product checker accepted the bootloader member"

# =========================================================================== #
# ac-2: the member is in the tar and in the member table
# =========================================================================== #

members="$(tar -tf "$payload_tar")"
assert_contains "$members" "boot.tar" \
  "ac-2 payload.tar carries boot.tar, the member the release used to be missing"
assert_contains "$members" "manifest.json" "ac-2 the payload still carries its manifest"
assert_contains "$members" "platform.tar" "ac-2 the payload still carries the platform layer"
assert_contains "$members" "rootfs.tar.gz" "ac-2 the payload still carries the upstream rootfs"

mkdir -p "$tmp/unpacked"
tar -xf "$payload_tar" -C "$tmp/unpacked"
manifest="$tmp/unpacked/manifest.json"
shipped_boot="$tmp/unpacked/boot.tar"
assert_file_exists "$shipped_boot" "ac-2 boot.tar unpacks out of the payload"
assert_eq "$(json_get "$manifest" "members:boot.tar:sha256")" "$(sha_of "$shipped_boot")" \
  "ac-2 the member table records boot.tar's real digest"
assert_eq "$(json_get "$manifest" "members:boot.tar:size")" "$(bytes_of "$shipped_boot")" \
  "ac-2 the member table records boot.tar's real size"

# =========================================================================== #
# ac-3: the bootloader identity in the manifest
# =========================================================================== #

assert_eq "$(json_get "$manifest" "bootloader:member")" "boot.tar" \
  "ac-3 the bootloader block names the member it describes"
assert_eq "$(json_get "$manifest" "bootloader:loader")" "EFI/BOOT/BOOTX64.EFI" \
  "ac-3 the bootloader block names the loader inside the member"
assert_eq "$(json_get "$manifest" "bootloader:menu")" "boot/grub/grub.cfg" \
  "ac-3 the bootloader block names the menu inside the member"
assert_eq "$(json_get "$manifest" "bootloader:grub_version")" "2.12" \
  "ac-3 the GRUB version recorded is the one read out of the loader"
assert_eq "$(json_get "$manifest" "bootloader:loader_sha256")" "$loader_sha" \
  "ac-3 loader_sha256 is the fixture ESP loader's real digest"
assert_eq "$(json_get "$manifest" "bootloader:loader_bytes")" "$loader_bytes" \
  "ac-3 loader_bytes is the fixture ESP loader's real size"

# =========================================================================== #
# ac-4: what the member actually contains
# =========================================================================== #

mkdir -p "$tmp/boot1"
tar -xf "$shipped_boot" -C "$tmp/boot1"
assert_file_exists "$tmp/boot1/EFI/BOOT/BOOTX64.EFI" "ac-4 the member carries the EFI loader"
assert_file_exists "$tmp/boot1/boot/grub/grub.cfg" "ac-4 the member carries our slot menu"
assert_eq "$(sha_of "$tmp/boot1/EFI/BOOT/BOOTX64.EFI")" "$loader_sha" \
  "ac-4 the loader ships byte identical to the ESP tree it came from"
# menu_sha256 has to describe the menu that is really in the member, not the one the stage
# meant to ship: an updater writes these bytes and compares against this value.
assert_eq "$(json_get "$manifest" "bootloader:menu_sha256")" \
  "$(sha_of "$tmp/boot1/boot/grub/grub.cfg")" \
  "ac-4 menu_sha256 is the digest of the menu inside boot.tar"

# =========================================================================== #
# ac-3b: the provenance the esp stage measured reaches the manifest
#
# ci-assemble.yml passes CI_BOOT_SOURCE_IMAGE/CI_BOOT_SOURCE_SHA256 from the esp step, and
# the composite had to learn to publish those two keys for that to mean anything. Without
# this case the wiring could be missing entirely and every assertion above would still pass,
# because the fallback (a name derived from CI_UPSTREAM_VERSION, digest null) looks fine.
# =========================================================================== #

prov_ci="$tmp/ci-prov"
mkdir -p "$prov_ci"
# Deliberately not the name boot-member.sh derives from CI_UPSTREAM_VERSION: with the
# derived name the assertion would pass whether the value was forwarded or invented.
prov_image="upstream-mirror-copy-25.12.2-uefi.img.gz"
prov_sha="$(python3 -c 'import hashlib;print(hashlib.sha256(b"combined-efi bytes").hexdigest())')"
run_assemble "$prov_ci" "$tmp/out-prov.env" CI_BOOT_SRC="$tmp/esp" \
  CI_BOOT_SOURCE_IMAGE="$prov_image" CI_BOOT_SOURCE_SHA256="$prov_sha" \
  >"$tmp/assemble-prov.log" 2>&1
status=$?
assert_eq "$status" "0" "ac-3b the stage builds with the provenance the esp stage measured"
[ "$status" = "0" ] || show_log "$tmp/assemble-prov.log"
assert_eq "$(json_get "$prov_ci/assemble/payload/manifest.json" "bootloader:source_image")" \
  "$prov_image" "ac-3b the manifest records the image the loader came out of"
assert_eq "$(json_get "$prov_ci/assemble/payload/manifest.json" "bootloader:source_sha256")" \
  "$prov_sha" "ac-3b the manifest records the verified digest instead of null"
# Without the inputs the digest stays null and is never invented, which is what the wiring
# above exists to prevent in the published payload.
assert_eq "$(json_get "$manifest" "bootloader:source_sha256")" "None" \
  "ac-3b a build without the provenance inputs records no digest rather than a guess"

# =========================================================================== #
# ac-5: the member list the workflow passes on
# =========================================================================== #

outputs="$tmp/out1.env"
assert_file_exists "$outputs" "ac-5 the stage publishes its outputs"
assert_eq "$(grep -c '^payload_members=' "$outputs")" "1" \
  "ac-5 the stage publishes payload_members exactly once"
published_members="$(sed -n 's/^payload_members=//p' "$outputs" | tail -n 1)"
# A token, not a substring: `boot.tar.old` in the list would satisfy a plain containment
# check while leaving a device with nothing to unpack.
assert_matches "$published_members" '(^|,)boot\.tar(,|$)' \
  "ac-5 payload_members names boot.tar, so a consumer unpacks the bootloader too"
assert_contains "$published_members" "rootfs.tar.gz" \
  "ac-5 payload_members still names the members it always had"

# =========================================================================== #
# ac-6: the menu CI actually ships - the one the image stage rendered
#
# The image stage renders $CI_TMP_ROOT/disk/grub.cfg first and the payload stage is
# pointed at it; that branch is the one CI takes, and it is the one a test that only
# exercises the self-rendering branch cannot see.
# =========================================================================== #

ci2="$tmp/ci2"
mkdir -p "$ci2/disk" "$ci2/esp/EFI/BOOT"
# Default boot source this time ($CI_TMP_ROOT/esp), which is where the esp stage writes.
cp "$tmp/esp/EFI/BOOT/BOOTX64.EFI" "$ci2/esp/EFI/BOOT/BOOTX64.EFI"
# The menu to ship: one the checker accepts (the one ac-4 proved came out of the first
# payload) plus a comment line of its own. The difference matters - a stage that ignored
# disk/grub.cfg and rendered its own menu from the same template would produce the same
# bytes, and "ships the external menu byte for byte" would pass for the wrong reason.
{
  cat "$tmp/boot1/boot/grub/grub.cfg"
  printf '# menu rendered by the image stage (fixture)\n'
} >"$ci2/disk/grub.cfg"
external_menu_sha="$(sha_of "$ci2/disk/grub.cfg")"
assert_eq "$([ "$(sha_of "$tmp/boot1/boot/grub/grub.cfg")" = "$external_menu_sha" ] && echo same || echo different)" \
  "different" "ac-6 the fixture menu is not the bytes the stage would render itself"

run_assemble "$ci2" "$tmp/out2.env" >"$tmp/assemble-2.log" 2>&1
status=$?
assert_eq "$status" "0" "ac-6 the stage builds when the image stage rendered the menu"
[ "$status" = "0" ] || show_log "$tmp/assemble-2.log"

mkdir -p "$tmp/unpacked2" "$tmp/boot2"
tar -xf "$ci2/assemble/payload.tar" -C "$tmp/unpacked2"
assert_contains "$(tar -tf "$tmp/unpacked2/boot.tar")" "boot/grub/grub.cfg" \
  "ac-6 the externally-menued payload still carries the menu"
tar -xf "$tmp/unpacked2/boot.tar" -C "$tmp/boot2"
assert_eq "$(sha_of "$tmp/boot2/boot/grub/grub.cfg")" "$external_menu_sha" \
  "ac-6 the member ships the image stage's menu byte for byte"
assert_eq "$(json_get "$tmp/unpacked2/manifest.json" "bootloader:menu_sha256")" \
  "$external_menu_sha" "ac-6 the manifest records the digest of the menu it shipped"

# =========================================================================== #
# ac-7: no boot source is a failure, not a payload without a bootloader
# =========================================================================== #

ci3="$tmp/ci3"
mkdir -p "$ci3"
# CI_REQUIRE_BOOTLOADER is not set here on purpose: the stage's default has to protect the
# release, because the workflow does not pass the switch.
run_assemble "$ci3" "$tmp/out3.env" CI_BOOT_SRC="$tmp/esp-does-not-exist" \
  >"$tmp/assemble-3.log" 2>&1
status=$?
assert_eq "$status" "1" "ac-7 a release build without a boot source fails"
refusal="$(cat "$tmp/assemble-3.log")"
assert_contains "$refusal" "no boot source" \
  "ac-7 the failure says the boot source is missing"
assert_contains "$refusal" "CI_REQUIRE_BOOTLOADER" \
  "ac-7 the failure names the switch that made it fatal"
# It has to be the bootloader that stopped the build, so the members staged before it must
# exist: a failure earlier in the stage would prove nothing about this member.
assert_file_exists "$ci3/assemble/payload/platform.tar" \
  "ac-7 the build got past the other members before refusing"
assert_eq "$([ -f "$ci3/assemble/payload.tar" ] && echo published || echo none)" "none" \
  "ac-7 a payload without a bootloader is never published"

# =========================================================================== #
# ac-8: one definition, both builders
#
# The defect was not a broken fragment: payload-build.sh carried the member while
# assemble.sh did not. A test of the fragment can never catch that, so the two callers are
# checked against each other here.
# =========================================================================== #

for builder in "$assemble" "$payload_build"; do
  name="${builder#"$root"/}"
  assert_eq "$(grep -c 'CI_SCRIPT_DIR}/boot-member.sh' "$builder")" "1" \
    "ac-8 ${name} sources the shared bootloader fragment"
  assert_eq "$(grep -c 'ci_boot_member_stage' "$builder")" "1" \
    "ac-8 ${name} stages the bootloader member through it"
done

finish
