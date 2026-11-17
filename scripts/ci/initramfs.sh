#!/usr/bin/env bash
# Stage "initramfs": build the minimal initramfs used by the module-load probe.
#
# Contents, and nothing else:
#   /bin/busybox         the upstream busybox package, with its musl loader and applets
#   /init                initramfs/init from this repository
#   /lib/modules/<kver>/ the modules unpacked by the kmods stage
#   an empty /proc /sys /dev /mnt

#
# Inputs (environment):
#   CI_KMODS_OUT       directory produced by the kmods stage (contains modules/)
#   CI_KERNEL_VERSION  kernel version, must match the module directory
#   CI_INITRAMFS_OUT   destination file (default: $CI_TMP_ROOT/initramfs/initramfs.cpio.gz)
#   CI_EXTRA_FILES     space separated "<source>:<path inside the initramfs>" pairs,
#                      used to stage the guest assertion scripts of later stages
#   CI_INITRAMFS_TOOLSET
#                      which locked toolset to stage: probe (busybox, musl, kmod),
#                      boot (probe + sfdisk/blkid/blockdev/btrfs) or assert (same as
#                      boot, for the S2 guest assertion). Defaults to probe for the
#                      module-load probe and boot for initramfs/boot/init.
#                      The programs, their libraries and every digest come from
#                      scripts/ci/initramfs-tools.lock.json; nothing is taken from the
#                      build host, whose libc and program versions drift with the
#                      runner image.
#   CI_INITRAMFS_LIB_DIR
#                      shell libraries staged into /lib (default: <repo>/initramfs/lib,
#                      which carries wf.sh for the state parsing and grow.sh for the
#                      first-boot growth; set it to an empty string to stage none)
#   CI_INITRAMFS_SHARED_LIBS
#                      space separated libraries that also ship in the platform layer
#                      and must run as the same bytes in both places (default:
#                      <repo>/platform/lib/disk-identity.sh, which resolves the boot disk,
#                      and <repo>/platform/lib/ab-slot-cfg.sh, which the initramfs uses
#                      for the fail-safe abandon and ab-slot/ab-boot use to pick a slot).
#                      Each one is copied
#                      unchanged to /lib and verified with cmp, so the initramfs can
#                      never resolve the boot disk with a different implementation than
#                      ab-boot and ab-slot use. Set it to an empty string to stage none.
#   CI_INIT_SCRIPT     which init to install as /init
#                      (default: initramfs/init, the S1 probe)
#
# Outputs: initramfs_path, initramfs_size, initramfs_modules, busybox_version,
#          initramfs_toolset, initramfs_tools_digest, initramfs_tools_versions,
#          initramfs_tools_bytes, initramfs_libs, initramfs_extra_files

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

on_error() {
    local status=$?
    ci_log "ERROR line ${LINENO}: ${BASH_COMMAND} (exit ${status})"
    exit "${status}"
}
trap on_error ERR

ci_stage_init initramfs

ci_require_cmd cpio gzip find sort cmp python3 awk

# --------------------------------------------------------------------------- #
# The /dev contract
# --------------------------------------------------------------------------- #
# The initramfs owns /dev for the window before switch_root. This kernel has no devtmpfs
# and the upstream busybox has no mdev applet, so the nodes have to be inside the archive:
# init/initramfs.c unpacks a newc device entry by calling init_mknod, and that is the only
# way a device node can exist in an initramfs at all.
#
# initramfs/lib/wf.sh carries the one list, WF_DEV_CONTRACT, with an owner for every
# entry, and this stage reads it out of that file instead of carrying a second copy: the
# boot (wf_make_dev / wf_assert_dev) and the build then assert the same list, which is the
# whole point - a copied list is the drift this stage exists to stop.
#
# mknod(1) needs CAP_MKNOD and the build host is an unprivileged runner (a laptop running
# this suite is macOS, which has no newc device nodes at all), so the entries cannot come
# from the build host filesystem. The two programs below generate them as newc records and
# grade the archive afterwards. They are kept in variables rather than functions because
# this file's structure is frozen in tests/fixtures/ci-structure-fingerprint.txt: a new
# named helper there is a re-baseline with its own reason, not a detail of this change.
dev_contract_source="${CI_REPO_ROOT}/initramfs/lib/wf.sh"

# dev_contract_insert: <tree.cpio> <out.cpio>, with WF_DEV_CONTRACT in the environment.
# Copies the tree's records, adds one newc record for every "ours" entry the tree does not
# already carry (at dev/<name>), keeps the trailer and the 512-byte padding, and prints the
# paths it added.
dev_contract_insert='
import os
import sys

src, dst = sys.argv[1], sys.argv[2]
manifest = os.environ.get("WF_DEV_CONTRACT", "")
if not manifest.strip():
    raise SystemExit("initramfs: empty /dev contract")


def normalise(name):
    return name[2:] if name.startswith("./") else name


def walk(blob):
    offset = 0
    while offset < len(blob):
        if blob[offset:offset + 6] != b"070701":
            raise SystemExit("initramfs: expected a newc header at offset %d" % offset)
        values = [int(blob[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
        filesize, namesize = values[6], values[11]
        name_end = offset + 110 + namesize
        name = blob[offset + 110:name_end - 1].decode("utf-8", "replace")
        end = (name_end + 3) & ~3
        end = (end + filesize + 3) & ~3
        yield name, blob[offset:end]
        offset = end


blob = open(src, "rb").read()
records = []
names = set()
trailer = b""
for name, record in walk(blob):
    if name == "TRAILER!!!":
        trailer = record
        break
    records.append(record)
    names.add(normalise(name))
if not trailer:
    raise SystemExit("initramfs: the archive carries no TRAILER!!! record")

added = []
ino = 0x00C0FFEE
for spec in manifest.split():
    fields = spec.split(":")
    if len(fields) != 6:
        raise SystemExit("initramfs: malformed contract entry %r" % spec)
    name, kind, owner, major, minor, mode = fields
    path = normalise(name) if kind == "dir" else "dev/" + normalise(name)
    if owner != "ours" or path in names:
        continue
    if kind == "dir":
        st_mode, nlink, rdev_major, rdev_minor = 0o40755, 2, 0, 0
    else:
        st_mode = 0o20000 | int(mode, 8)
        nlink, rdev_major, rdev_minor = 1, int(major), int(minor)
    name_bytes = path.encode() + b"\0"
    values = (ino, st_mode, 0, 0, nlink, 0, 0, 0, 0, rdev_major, rdev_minor, len(name_bytes), 0)
    record = b"070701" + b"".join(b"%08X" % value for value in values) + name_bytes
    record += b"\0" * ((4 - len(record) % 4) % 4)
    records.append(record)
    added.append(path)
    ino += 1

out = b"".join(records) + trailer
out += b"\0" * ((512 - len(out) % 512) % 512)
with open(dst, "wb") as handle:
    handle.write(out)
print(" ".join(added))
'

# dev_contract_check: reads the `cpio -itv` listing of one archive, with -v manifest and
# -v archive. Prints one line per way the archive fails the contract and nothing when it
# passes. The listing comes from cpio, so the check reads the bytes the kernel will read
# instead of trusting the program that wrote them, and an archive that does not list at all
# is a finding rather than an empty pass. A "kernel" entry that appears in our archive is a
# finding too: two owners for one path is how a console ends up bound to an inode nobody
# reads.
dev_contract_check='
BEGIN {
    count = split(manifest, spec, " ")
    for (i = 1; i <= count; i++) {
        if (split(spec[i], field, ":") != 6) {
            printf "malformed contract entry: %s\n", spec[i]
            count = i - 1
            break
        }
        name[i] = field[1]
        type[i] = field[2]
        owner[i] = field[3]
        major[i] = field[4]
        minor[i] = field[5]
    }
}
{
    entry = $NF
    sub(/^\.\//, "", entry)
    if (entry == "." || entry == "") next
    seen[entry] = $0
    listed = 1
}
END {
    if (!listed) {
        printf "unreadable: %s does not list as a cpio archive\n", archive
        exit
    }
    if (!("dev" in seen))
        printf "dev/: missing (the archive carries no /dev directory)\n"
    else if (substr(seen["dev"], 1, 1) != "d")
        printf "dev/: expected a directory, the archive carries %s\n", seen["dev"]
    for (i = 1; i <= count; i++) {
        expected = type[i] " " major[i] ":" minor[i]
        path = (type[i] == "dir") ? name[i] : "dev/" name[i]
        if (!(path in seen)) {
            if (owner[i] == "kernel") continue
            printf "%s: missing (expected %s)\n", path, expected
            continue
        }
        line = seen[path]
        if (owner[i] == "kernel") {
            printf "%s: shipped although the kernel provides it: %s\n", path, line
            continue
        }
        kind = (type[i] == "dir") ? "d" : "c"
        if (substr(line, 1, 1) != kind) {
            printf "%s: expected %s, the archive carries %s\n", path, expected, line
            continue
        }
        if (type[i] == "dir") continue
        ids = ""
        n = split(line, token, /[ \t]+/)
        for (j = 1; j <= n; j++) {
            if (token[j] ~ /^[0-9]+,$/) { ids = token[j] token[j + 1]; break }
            if (token[j] ~ /^[0-9]+,[0-9]+$/) { ids = token[j]; break }
        }
        gsub(/,/, ":", ids)
        if (ids != major[i] ":" minor[i])
            printf "%s: expected %s:%s, the archive carries %s\n", path, major[i], minor[i], ids
    }
}
'

kmods_out="${CI_KMODS_OUT:-${CI_TMP_ROOT}/kmods}"
kernel_version="${CI_KERNEL_VERSION:?CI_KERNEL_VERSION is required}"
out_file="${CI_INITRAMFS_OUT:-${CI_TMP_ROOT}/initramfs/initramfs.cpio.gz}"
init_script="${CI_INIT_SCRIPT:-${CI_REPO_ROOT}/initramfs/init}"

module_dir="${kmods_out}/modules/lib/modules/${kernel_version}"
[ -d "${module_dir}" ] || ci_die "module directory not found: ${module_dir}"
[ -f "${module_dir}/btrfs.ko" ] || ci_die "btrfs.ko not found in ${module_dir}"

stage="${CI_TMP_ROOT}/initramfs/root"
rm -rf "${stage}"
mkdir -p "${stage}/bin" "${stage}/proc" "${stage}/sys" "${stage}/dev" "${stage}/mnt" \
    "${stage}/lib/modules/${kernel_version}"

# Every foreign program comes from the locked upstream packages: busybox itself, its
# musl loader, the partition tools and their libraries. scripts/ci/initramfs-tools.sh
# verifies each .apk and each extracted file against the lockfile, so a program can
# only enter this initramfs if its digest is the one the release published.
toolset="${CI_INITRAMFS_TOOLSET:-}"
if [ -z "${toolset}" ]; then
    # No leading slash in the pattern: the path may be relative, and a boot init that
    # silently fell back to the probe toolset would build an image that boots and then
    # cannot grow the disk. Both spellings must select boot.
    case "${init_script}" in
        *initramfs/boot/init) toolset="boot" ;;
        *) toolset="probe" ;;
    esac
fi
ci_log "toolset: ${toolset}"

tools_summary="${CI_TMP_ROOT}/initramfs/tools-${toolset}.json"
mkdir -p "$(dirname "${tools_summary}")"
CI_APK_TOOLS_SUMMARY="${tools_summary}" \
    bash "${CI_SCRIPT_DIR}/initramfs-tools.sh" --toolset "${toolset}" --stage "${stage}"

tools_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
        "${tools_summary}" "$1"
}
tools_digest="$(tools_field digest)"
tools_versions="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["versions"]))' "${tools_summary}")"
tools_bytes="$(tools_field bytes)"
tools_files="$(tools_field files)"
busybox_version="$(printf '%s\n' ${tools_versions} | sed -n 's/^busybox=//p')"

# The toolset is a promise: probe boots and loads modules, boot/assert additionally
# partition and grow the disk. A toolset that lost one of its programs would still boot
# and only fail at the disk, so the build asserts every promised program is there.
require_toolset_programs() {
    local program
    for program in "$@"; do
        [ -e "${stage}${program}" ] || ci_die "the ${toolset} toolset is missing ${program}"
    done
}
require_toolset_programs /bin/busybox /bin/sh /lib/ld-musl-x86_64.so.1 /lib/libc.so \
    /sbin/kmod /sbin/insmod /sbin/modprobe
case "${toolset}" in
    probe) ;;
    boot|assert)
        require_toolset_programs /usr/sbin/sfdisk /usr/sbin/blockdev /usr/sbin/blkid /usr/sbin/btrfs
        ;;
    *) ci_die "unknown toolset: ${toolset} (expected probe, boot or assert)" ;;
esac

# The initramfs must run on the musl loader alone. A glibc interpreter or library in
# here means a host binary slipped back in, which is exactly what this stage exists to
# prevent, so it is a build failure and not a warning.
require_musl_only() {
    local offender
    [ -L "${stage}/lib/ld-musl-x86_64.so.1" ] \
        || ci_die "missing /lib/ld-musl-x86_64.so.1: nothing in this initramfs could start"
    [ "$(readlink "${stage}/lib/ld-musl-x86_64.so.1")" = "libc.so" ] \
        || ci_die "/lib/ld-musl-x86_64.so.1 must point at libc.so"
    [ -f "${stage}/lib/libc.so" ] || ci_die "missing /lib/libc.so"
    offender="$(cd "${stage}" && find . \( -name 'ld-linux*' -o -name 'libc.so.6' \
        -o -name 'libreadline*' -o -name 'libtinfo*' -o -name 'libudev*' \
        -o -path '*x86_64-linux-gnu*' \) -print | head -n 1)"
    [ -z "${offender}" ] || ci_die "glibc artifact in the initramfs: ${offender}"
    ci_log "libc: musl only (/lib/ld-musl-x86_64.so.1 -> libc.so)"
}
require_musl_only

[ -f "${init_script}" ] || ci_die "init script not found: ${init_script}"
install -m 0755 "${init_script}" "${stage}/init"
ci_log "init: ${init_script#"${CI_REPO_ROOT}"/}"

# The shell libraries that belong to this init script travel with it: initramfs/lib
# holds wf.sh (state parsing) and grow.sh (first-boot growth), and staging the directory
# means a new helper is picked up by every stage that installs this init instead of
# being listed again in each workflow's CI_EXTRA_FILES.
lib_dir="${CI_INITRAMFS_LIB_DIR-${CI_REPO_ROOT}/initramfs/lib}"
lib_count=0
if [ -n "${lib_dir}" ] && [ -d "${lib_dir}" ]; then
    for lib in "${lib_dir}"/*.sh; do
        [ -f "${lib}" ] || continue
        mkdir -p "${stage}/lib"
        install -m 0644 "${lib}" "${stage}/lib/$(basename "${lib}")"
        lib_count=$((lib_count + 1))
    done
fi
[ "${lib_count}" -eq 0 ] || ci_log "libraries: ${lib_count} file(s) from ${lib_dir#"${CI_REPO_ROOT}"/}"

# Shared libraries that belong to the platform layer but are needed before it is
# mounted. disk-identity.sh is the only implementation of "which disk carries us", and
# the boot initramfs must not carry a second copy that can drift: the staged file is
# compared with the source and a difference is a build failure.
shared_libs="${CI_INITRAMFS_SHARED_LIBS-${CI_REPO_ROOT}/platform/lib/disk-identity.sh ${CI_REPO_ROOT}/platform/lib/ab-slot-cfg.sh}"
shared_count=0
for shared in ${shared_libs}; do
    if [ ! -f "${shared}" ]; then
        ci_warn "shared library not found, skipped: ${shared}"
        continue
    fi
    mkdir -p "${stage}/lib"
    install -m 0644 "${shared}" "${stage}/lib/$(basename "${shared}")"
    cmp -s "${shared}" "${stage}/lib/$(basename "${shared}")" \
        || ci_die "staged $(basename "${shared}") differs from ${shared}"
    ci_log "shared library $(basename "${shared}"): byte-identical to ${shared#"${CI_REPO_ROOT}"/}"
    shared_count=$((shared_count + 1))
done

# Extra files, for example the S2 guest assertion script staged as /s2.sh.
extra_count=0
for spec in ${CI_EXTRA_FILES:-}; do
    src="${spec%%:*}"
    dest="${spec#*:}"
    [ "${src}" != "${dest}" ] || ci_die "CI_EXTRA_FILES entry needs <source>:<dest>, got ${spec}"
    [ -f "${src}" ] || ci_die "extra file not found: ${src}"
    mkdir -p "${stage}$(dirname "${dest}")"
    install -m 0755 "${src}" "${stage}${dest}"
    extra_count=$((extra_count + 1))
done

cp "${module_dir}"/*.ko "${stage}/lib/modules/${kernel_version}/"
module_count="$(find "${stage}/lib/modules" -name '*.ko' | wc -l | tr -d ' ')"
[ "${module_count}" -gt 0 ] || ci_die "no modules staged"

mkdir -p "$(dirname "${out_file}")"
# GNU cpio is what the runner provides; --null keeps the archive safe for names with
# spaces, but fall back to newline separation where the flag is missing.
# The kernel unpacks the initramfs as-is, so pin ownership to root and keep the modes.
tree_archive="${CI_TMP_ROOT}/initramfs/root.cpio"
archive_plain="${CI_TMP_ROOT}/initramfs/root-with-dev.cpio"
rm -f "${tree_archive}" "${archive_plain}"
if cpio --help 2>&1 | grep -q -- '--null'; then
    (cd "${stage}" && find . -print0 | cpio --null -o -H newc -R 0:0 2>/dev/null) >"${tree_archive}"
else
    (cd "${stage}" && find . -print | cpio -o -H newc -R 0:0 2>/dev/null) >"${tree_archive}"
fi

# The /dev entries the contract calls "ours" are inserted now, between the tree cpio and
# the gzip step: they cannot come from `find`, because creating a device node on the build
# host needs CAP_MKNOD and macOS has no newc device nodes at all.
dev_manifest="$(sed -n 's/^WF_DEV_CONTRACT="\([^"]*\)"$/\1/p' "${dev_contract_source}" 2>/dev/null \
    | head -n 1)" || dev_manifest=""
[ -n "${dev_manifest}" ] \
    || ci_die "no WF_DEV_CONTRACT line in ${dev_contract_source}: the /dev contract cannot be read"
# The list has to be the one the initramfs will assert at boot. A staged wf.sh that
# carries a different one would build and grade an archive against a rule the boot does
# not use, which is worse than a build that does not start.
if [ -f "${stage}/lib/wf.sh" ]; then
    staged_manifest="$(sed -n 's/^WF_DEV_CONTRACT="\([^"]*\)"$/\1/p' "${stage}/lib/wf.sh" 2>/dev/null \
        | head -n 1)" || staged_manifest=""
    [ "${staged_manifest}" = "${dev_manifest}" ] \
        || ci_die "the staged /lib/wf.sh carries a different /dev contract than ${dev_contract_source}"
fi
dev_entries="$(WF_DEV_CONTRACT="${dev_manifest}" \
    python3 -c "${dev_contract_insert}" "${tree_archive}" "${archive_plain}")"
[ -s "${archive_plain}" ] || ci_die "the /dev insertion produced no archive"
gzip -9 <"${archive_plain}" >"${out_file}"

gzip -t "${out_file}" || ci_die "produced initramfs is not valid gzip"
entries="$(gzip -dc "${out_file}" | cpio -t 2>/dev/null | wc -l | tr -d ' ')"
size_bytes="$(ci_file_size "${out_file}")"

# The assertion the stage exists for: the archive a machine will be flashed with carries
# every /dev entry the contract calls ours, with the right type and numbers. A missing or
# duplicated entry is a build failure, never a warning and never a skip - a boot that only
# finds out at runtime powers the machine off on somebody's desk.
deviations="$(gzip -dc "${out_file}" 2>/dev/null | cpio -itv 2>/dev/null \
    | awk -v manifest="${dev_manifest}" -v archive="${out_file}" "${dev_contract_check}" || true)"
if [ -n "${deviations}" ]; then
    while IFS= read -r deviation; do
        ci_log "  dev-contract: ${deviation}"
    done <<<"${deviations}"
    ci_die "the initramfs does not satisfy the /dev contract of ${dev_contract_source#"${CI_REPO_ROOT}"/}"
fi

ci_log "initramfs: ${out_file}"
ci_log "  size: ${size_bytes} bytes, ${entries} archive entries"
ci_log "  dev: ${dev_entries:-none generated} (contract from ${dev_contract_source#"${CI_REPO_ROOT}"/})"
ci_log "  toolset: ${toolset}, ${tools_files} locked file(s), digest ${tools_digest:0:12}"
ci_log "  modules: ${module_count}, ${lib_count} shell lib(s)"
ci_log "  shared libraries: ${shared_count}"
ci_log "  extra files: ${extra_count}"
ci_log "  busybox: ${busybox_version} (upstream apk)"
ci_log "  versions: ${tools_versions}"

ci_emit_output "initramfs_path" "${out_file}"
ci_emit_output "initramfs_size" "${size_bytes}"
ci_emit_output "initramfs_modules" "${module_count}"
ci_emit_output "busybox_version" "${busybox_version}"
ci_emit_output "initramfs_toolset" "${toolset}"
ci_emit_output "initramfs_tools_digest" "${tools_digest}"
ci_emit_output "initramfs_tools_versions" "${tools_versions}"
ci_emit_output "initramfs_tools_bytes" "${tools_bytes}"
ci_emit_output "initramfs_libs" "${lib_count}"
ci_emit_output "initramfs_shared_libs" "${shared_count}"
ci_emit_output "initramfs_extra_files" "${extra_count}"

ci_log "stage initramfs finished"
