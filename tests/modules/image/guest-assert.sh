#!/bin/sh
# In-guest assertion for stage S2 (disk image assembly).
#
# Runs as the initramfs init (`init=/s2.sh`) with the assembled image attached as
# /dev/vda, and checks the geometry that docs/partitions.md freezes:
#
#   1. four partitions with PARTLABELs wf-esp / wf-slot-a / wf-slot-b / wf-shared
#   2. sizes 128 / 128 / 128 / 64 MiB
#   3. p2 and p3 hold @sys and @wf, p4 holds @overlay.gen0001, @docker, @swap and
#      @data, all top level with nothing nested
#   4. @sys file count matches the upstream tree, sampled digests match
#   5. p1 content stays under 64 MiB
#   6. exactly one frozen judge line is printed, then the machine powers off:
#
#        S2-RESULT=ok parts=4 images=<bytes>
#        S2-RESULT=fail reason=<token>
#
# Expectations come from /s2-expect.txt, written by scripts/ci/image-verify.sh:
#
#   files=<n>            regular files in the upstream rootfs tree
#   images=<bytes>       size of the disk image the host produced
#   parts=4              expected partition count
#   p1max_kib=<n>        p1 usage budget in KiB
#   sample <path> <sha256>   one sampled @sys file, verified from inside the guest

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DEV=/dev/vda
EXPECT_FILE=/s2-expect.txt

report_failure() {
    echo "S2-RESULT=fail reason=$1"
    sync
    poweroff -f
    exit 1
}

echo "[s2] disk image assertion starting"
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
if [ ! -b "${DEV}" ]; then
    # This kernel does not mount devtmpfs itself; mdev creates the device nodes.
    mdev -s 2>/dev/null
fi
mkdir -p /mnt

KVER="$(uname -r)"
echo "[s2] kernel ${KVER}"

# --------------------------------------------------------------------------- #
# Module load (btrfs arrives as a module on this kernel)
# --------------------------------------------------------------------------- #

MODDIR="/lib/modules/${KVER}"
[ -d "${MODDIR}" ] || report_failure no-module-directory
loaded=0
pass=1
while [ "${pass}" -le 4 ]; do
    for ko in "${MODDIR}"/*.ko; do
        [ -f "${ko}" ] || continue
        name="$(basename "${ko}" .ko | tr '-' '_')"
        [ -d "/sys/module/${name}" ] && continue
        if insmod "${ko}" 2>/dev/null; then
            loaded=$((loaded + 1))
        fi
    done
    [ -d /sys/module/btrfs ] && break
    pass=$((pass + 1))
done
[ -d /sys/module/btrfs ] || report_failure btrfs-not-loaded
echo "[s2] loaded ${loaded} module(s)"

[ -b "${DEV}" ] || report_failure no-block-device

# --------------------------------------------------------------------------- #
# Expectations
# --------------------------------------------------------------------------- #

[ -f "${EXPECT_FILE}" ] || report_failure no-expect-file
expect_files=""
expect_images=""
expect_parts=""
expect_p1max=""
SAMPLES=""
# The file mixes "key=value" lines and "sample <path> <sha256>" lines, so the field
# separator covers both space and '='.
while IFS=' =' read -r key value extra; do
    case "${key}" in
        files) expect_files="${value}" ;;
        images) expect_images="${value}" ;;
        parts) expect_parts="${value}" ;;
        p1max_kib) expect_p1max="${value}" ;;
        sample) SAMPLES="${SAMPLES}${value}=${extra} " ;;
        *) : ;;
    esac
done <"${EXPECT_FILE}"
[ -n "${expect_images}" ] || report_failure bad-expect-file
echo "[s2] expected ${expect_parts} partition(s), ${expect_files} file(s) in @sys, image ${expect_images} bytes"

# --------------------------------------------------------------------------- #
# 1./2. Partition table as the kernel sees it
# --------------------------------------------------------------------------- #

block_name="$(basename "${DEV}")"
image_size="$(cat "/sys/class/block/${block_name}/size" 2>/dev/null || echo 0)"
image_bytes=$((image_size * 512))
[ "${image_bytes}" = "${expect_images}" ] \
    || report_failure "image-size-${image_bytes}-expected-${expect_images}"
echo "[s2] device size ${image_bytes} bytes"

found=0
part=1
while [ -b "${DEV}${part}" ]; do
    found=$((found + 1))
    part=$((part + 1))
done
if [ "${found}" != "${expect_parts}" ]; then
    mdev -s 2>/dev/null
    found=0
    part=1
    while [ -b "${DEV}${part}" ]; do
        found=$((found + 1))
        part=$((part + 1))
    done
fi
[ "${found}" = "${expect_parts}" ] || report_failure "partitions-${found}"
echo "[s2] found ${found} partitions"

# Labels: sfdisk prints name="..." for GPT entries, blkid exposes PART_ENTRY_NAME.
labels=""
label_source=""
if sfdisk -d "${DEV}" >/tmp/sfdisk.txt 2>/dev/null && grep -q 'name="' /tmp/sfdisk.txt; then
    labels="$(sed -n 's/.*name="\([^"]*\)".*/\1/p' /tmp/sfdisk.txt | paste -sd, -)"
    label_source=sfdisk
elif blkid -o value -s PART_ENTRY_NAME "${DEV}1" >/dev/null 2>&1; then
    part=1
    while [ "${part}" -le "${found}" ]; do
        one="$(blkid -o value -s PART_ENTRY_NAME "${DEV}${part}" 2>/dev/null)"
        labels="${labels}${labels:+,}${one}"
        part=$((part + 1))
    done
    label_source=blkid
else
    report_failure label-unreadable
fi
echo "[s2] labels (${label_source}): ${labels}"
[ "${labels}" = "wf-esp,wf-slot-a,wf-slot-b,wf-shared" ] || report_failure "labels-${labels}"

# Sizes come from sysfs, which is the kernel's own view of the GPT.
want_sizes="262144 262144 262144 131072"
part=1
for want in ${want_sizes}; do
    have="$(cat "/sys/class/block/$(basename "${DEV}${part}")/size" 2>/dev/null || echo 0)"
    [ "${have}" = "${want}" ] || report_failure "size-p${part}-${have}"
    part=$((part + 1))
done
echo "[s2] partition sizes 128/128/128/64 MiB"

# --------------------------------------------------------------------------- #
# 3. Subvolume layout
# --------------------------------------------------------------------------- #

# expect_subvolumes <partition> <comma separated paths>
expect_subvolumes() {
    _part="$1"
    _want="$2"
    mount -t btrfs -o ro "${DEV}${_part}" /mnt || report_failure "p${_part}-mount-failed"
    _have="$(btrfs subvolume list /mnt 2>/dev/null \
        | sed -n 's/.*top level \([0-9]*\) path \(.*\)$/\2|\1/p' \
        | sort)"
    _paths="$(printf '%s\n' "${_have}" | cut -d'|' -f1 | paste -sd, -)"
    _nested="$(btrfs subvolume list -o /mnt 2>/dev/null)"
    umount /mnt
    [ "${_paths}" = "${_want}" ] || report_failure "p${_part}-subvolumes-${_paths}"
    if printf '%s\n' "${_have}" | grep -qv '|5$'; then
        report_failure "p${_part}-not-top-level"
    fi
    [ -z "${_nested}" ] || report_failure "p${_part}-nested-subvolume"
    echo "[s2] p${_part}: ${_want}"
}

expect_subvolumes 2 "@sys,@wf"
expect_subvolumes 3 "@sys,@wf"
expect_subvolumes 4 "@data,@docker,@overlay.gen0001,@swap"

mount -t btrfs -o ro "${DEV}4" /mnt || report_failure p4-mount-failed
for entry in upper work; do
    [ -d "/mnt/@overlay.gen0001/${entry}" ] || report_failure "overlay-${entry}-missing"
done
umount /mnt
echo "[s2] @overlay.gen0001 contains plain upper/ and work/"

# --------------------------------------------------------------------------- #
# 4. @sys content
# --------------------------------------------------------------------------- #

mount -t btrfs -o ro "${DEV}2" /mnt || report_failure p2-mount-failed
[ -d /mnt/@sys ] || report_failure no-at-sys
[ -d /mnt/@wf ] || report_failure no-at-wf
sys_files="$(find /mnt/@sys -type f | wc -l | tr -d ' ')"
echo "[s2] @sys has ${sys_files} file(s), expected ${expect_files}"
[ "${sys_files}" = "${expect_files}" ] || report_failure "at-sys-files-${sys_files}"

checked=0
for pair in ${SAMPLES}; do
    path="${pair%%=*}"
    want="${pair#*=}"
    [ -n "${path}" ] && [ -n "${want}" ] || report_failure "bad-sample-entry"
    [ -f "/mnt/@sys${path}" ] || report_failure "sample-missing-${path}"
    have="$(sha256sum "/mnt/@sys${path}" | cut -d' ' -f1)"
    [ "${have}" = "${want}" ] || report_failure "sample-digest-${path}"
    checked=$((checked + 1))
done
umount /mnt
echo "[s2] ${checked} sample digest(s) verified from inside the guest"
[ "${checked}" -gt 0 ] || report_failure no-samples

# --------------------------------------------------------------------------- #
# 5. p1 budget
# --------------------------------------------------------------------------- #

mount -t vfat -o ro "${DEV}1" /mnt || report_failure p1-mount-failed
for required in EFI/BOOT/BOOTX64.EFI boot/grub vmlinuz-a vmlinuz-b initrd-a initrd-b ab ab/log; do
    [ -e "/mnt/${required}" ] || report_failure "p1-missing-${required}"
done
p1_kib="$(du -sk /mnt | cut -f1)"
umount /mnt
echo "[s2] p1 uses ${p1_kib} KiB of the ${expect_p1max} KiB budget"
[ "${p1_kib}" -lt "${expect_p1max}" ] || report_failure "p1-over-budget-${p1_kib}"

echo "S2-RESULT=ok parts=${found} images=${image_bytes}"
sync
poweroff -f
exit 0
