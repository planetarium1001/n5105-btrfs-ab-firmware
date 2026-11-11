#!/usr/bin/env bash
# Module: ci
# An image is judged by its member table, not by its label.
#
# ab/image.json says which initramfs an image carries, but it is a file the build writes;
# the archive is the bytes a machine runs. v0.0.6/v0.0.7 published an image whose initrd
# was the S1 probe while the record said nothing useful, and nothing caught it. The CI
# guest assertion is the same class of defect in the other direction: /s3-post.sh writes
# probe files into the writable layer and powers the machine off when it disagrees, so a
# flashed machine must not carry it.
#
# ac-12 makes that decidable on this host:
#   ac-12a image-verify.sh refuses an initrd that carries an s3- member in a kind=boot image
#   ac-12b the same archive under kind=probe is accepted, i.e. the verdict follows
#          ab/image.json's kind instead of a hard-coded answer
#   ac-12c an archive that cannot be read is refused with its own reason, not silently
#          treated as clean
#   ac-12d the member rule is what the image check calls, and the image S3 publishes is
#          built without the hook while the two kernel boots use the archive that has it
#
# The fixtures are the two build modes of scripts/ci/initramfs.sh: same tree, packed with
# `find . | cpio -H newc`, once with /s3-post.sh staged (AB_CI_HOOKS=1) and once without.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

iv="$root/scripts/ci/image-verify.sh"
s3="$root/.github/workflows/ci-s3.yml"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

assert_command_ok "ac-12 the host can read an initramfs (cpio and gzip)" \
    bash -c 'command -v cpio && command -v gzip'

# make_initrd <out> [<member>...]: the tree scripts/ci/initramfs.sh always stages, plus
# the members named on the command line, packed the way that stage packs it.
make_initrd() {
    local out="$1" src="$tmp/tree-$RANDOM" member
    shift
    mkdir -p "$src/bin" "$src/lib" "$src/proc" "$src/sys" "$src/dev" "$src/mnt"
    printf '#!/bin/sh\nexec /sbin/init\n' >"$src/init"
    chmod 0755 "$src/init"
    printf 'busybox\n' >"$src/bin/busybox"
    printf '# wf\n' >"$src/lib/wf.sh"
    for member in "$@"; do
        mkdir -p "$src/$(dirname "${member}")"
        printf 'ci\n' >"$src/${member}"
    done
    (cd "$src" && find . -print0 | cpio --null -o -H newc 2>/dev/null) | gzip -9 >"${out}"
}

production="$tmp/boot.cpio.gz"
ci_hooks="$tmp/ci-hooks.cpio.gz"
make_initrd "${production}"
make_initrd "${ci_hooks}" "s3-post.sh"

# ab/image.json is written by the build with the same helper the disk stage uses, so the
# kind the check is given below is the kind an image really records.
# shellcheck source=scripts/ci/image-identity.sh
source "$root/scripts/ci/image-identity.sh"
image_json="$tmp/ab/image.json"
mkdir -p "$tmp/ab"
ii_image_json boot boot.cpio.gz 0.0.1 25.12.2 2026-11-11T00:00:00Z >"${image_json}"
recorded_kind="$(sed -n 's/.*"kind": *"\([a-z]*\)".*/\1/p' "${image_json}" | head -n 1)"
assert_eq "${recorded_kind}" "boot" \
    "ac-12 the fixture ab/image.json records kind=boot, the only kind a machine may run"

# check_initrd <initrd> <kind>: run the host-only mode of image-verify.sh; sets $out and
# $rc. The mode exists so the rule can be exercised without an image, a loop device or
# sudo, and it is the same function the full image check calls.
check_initrd() {
    out="$(bash "${iv}" --check-initrd "$1" "$2" 2>&1)"
    rc=$?
}

# --------------------------------------------------------------------------- #
# ac-12a: a production initrd is accepted, one with the CI hook is not
# --------------------------------------------------------------------------- #

check_initrd "${production}" "${recorded_kind}"
assert_eq "${rc}" "0" "ac-12a a kind=boot initrd without an s3- member is accepted"
assert_contains "${out}" "accepted" "ac-12a and the check says so"

check_initrd "${ci_hooks}" "${recorded_kind}"
assert_eq "$([ "${rc}" -ne 0 ] && echo refused || echo accepted)" "refused" \
    "ac-12a the same image carrying /s3-post.sh as kind=boot is refused"
assert_contains "${out}" "s3-post.sh" \
    "ac-12a the refusal names the offending member"
assert_contains "${out}" "AB_CI_HOOKS" \
    "ac-12a and the flag that decides whether it belongs there"
assert_contains "${out}" "kind=boot" \
    "ac-12a and the kind it was judged as"

# --------------------------------------------------------------------------- #
# ac-12b: the verdict follows ab/image.json, not a hard-coded answer
# --------------------------------------------------------------------------- #

check_initrd "${ci_hooks}" "probe"
assert_eq "${rc}" "0" \
    "ac-12b a kind=probe image may carry the CI hook: the member table is judged by the kind"
assert_contains "${out}" "kind=probe" \
    "ac-12b and the log says which kind allowed it"

check_initrd "${production}" "probe"
assert_eq "${rc}" "0" "ac-12b a kind=probe image without the hook is accepted too"

# --------------------------------------------------------------------------- #
# ac-12c: an unreadable archive is a different failure, and it is reported
# --------------------------------------------------------------------------- #

printf 'this is not a gzip archive\n' >"$tmp/broken.cpio.gz"
check_initrd "$tmp/broken.cpio.gz" "${recorded_kind}"
assert_eq "$([ "${rc}" -ne 0 ] && echo refused || echo accepted)" "refused" \
    "ac-12c an archive that cannot be read is refused, not assumed clean"
assert_contains "${out}" "readable gzip cpio archive" \
    "ac-12c and the reason is the archive, not a member"

# --------------------------------------------------------------------------- #
# ac-12d: the image check calls the rule, and S3 installs the clean archive
# --------------------------------------------------------------------------- #

iv_text="$(cat "${iv}")"
assert_contains "${iv_text}" 'CI_MEMBER_PREFIX="s3-"' \
    "ac-12d image-verify defines the member prefix it forbids"
assert_contains "${iv_text}" 'for initrd in initrd-a initrd-b; do' \
    "ac-12d image-verify walks both initrds of the image"
assert_contains "${iv_text}" 'assert_no_ci_hooks "${p1}/${initrd}" "${image_kind}"' \
    "ac-12d and judges each one against the kind ab/image.json records"

s3_text="$(cat "${s3}")"
assert_contains "${s3_text}" 'CI_INITRAMFS: ${{ steps.initramfs.outputs.initramfs_path }}' \
    "ac-12d the image S3 publishes is assembled from the production initramfs"
assert_eq "$(printf '%s\n' "${s3_text}" | grep -c 'steps\.initramfs_ci\.outputs')" "2" \
    "ac-12d only the two kernel boots load the archive that carries the CI hook"

finish
