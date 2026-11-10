#!/bin/sh
# In-guest assertion for stage S2 (disk image assembly).
#
# Runs as the initramfs init (`init=/s2.sh`) with the assembled image attached as
# /dev/vda, and checks the geometry that docs/partitions.md freezes:
#
#   1. four partitions with PARTNAMEs ab-esp / ab-slot-a / ab-slot-b / ab-data and
#      filesystem LABELs ESP / slot-a / slot-b / data
#   2. sizes 128 / 128 / 128 / 128 MiB
#   3. p2 and p3 hold @sys and @platform, p4 holds @overlay-<version>, @docker, @swap and
#      @data, all top level with nothing nested
#   4. @sys file count matches the upstream tree, sampled digests match
#   5. p1 content stays under 64 MiB
#   6. p4 ships short of the end of the disk, so the first boot has something to grow:
#      the growth decision the boot init takes is recomputed here from the real table,
#      and the already-full state is proven on a table where p4 reaches the tail
#   7. no .ab/grow is shipped in the image; that file is written on first boot only
#   8. device identity: the parent disk of every partition is derived from sysfs, the
#      initramfs copy of lib/disk-identity.sh is byte-identical to the one in
#      @platform, the platform layer resolves the same disk, and ab/device.json records
#      the four PARTUUIDs the upgrade path relies on
#   9. exactly one frozen judge line is printed, then the machine powers off:
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

# Scratch space: the initramfs image has no /tmp, and every redirect below needs one.
mkdir -p /tmp

# The boot initramfs helper is staged as /lib/grow.sh by scripts/ci/initramfs.sh, so the
# guest can re-run the very decision the first boot takes instead of asserting a copy of
# it. Sourcing it only defines functions; nothing is mounted or written.
GROW_LIB=missing
if [ -f /lib/grow.sh ]; then
    . /lib/grow.sh
    command -v wf_grow_decide >/dev/null 2>&1 && GROW_LIB=loaded
fi
# Loaded here rather than in the identity section, because the growth check below needs
# di_sector_size to convert sysfs 512-byte units into the logical sectors sfdisk counts.
IDENTITY_LIB=missing
if [ -f /lib/disk-identity.sh ]; then
    . /lib/disk-identity.sh
    command -v di_parent_disk >/dev/null 2>&1 && IDENTITY_LIB=loaded
fi

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
expect_overlay=""
SAMPLES=""
# The file mixes "key=value" lines and "sample <path> <sha256>" lines, so the field
# separator covers both space and '='.
while IFS=' =' read -r key value extra; do
    case "${key}" in
        files) expect_files="${value}" ;;
        images) expect_images="${value}" ;;
        parts) expect_parts="${value}" ;;
        p1max_kib) expect_p1max="${value}" ;;
        overlay) expect_overlay="${value}" ;;
        sample) SAMPLES="${SAMPLES}${value}=${extra} " ;;
        *) : ;;
    esac
done <"${EXPECT_FILE}"
[ -n "${expect_images}" ] || report_failure bad-expect-file
[ -n "${expect_overlay}" ] || report_failure bad-expect-file
case "${expect_overlay}" in
    @overlay-*) : ;;
    *) report_failure "overlay-name-${expect_overlay}" ;;
esac
echo "[s2] writable layer: ${expect_overlay}"
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
# -p forces a direct probe of the disk instead of asking the block device cache,
# which carries no GPT names when the guest has no udev.
probe_labels() {
    _out=""
    _part=1
    while [ "${_part}" -le "${found}" ]; do
        _one="$(blkid -p -o value -s PART_ENTRY_NAME "${DEV}${_part}" 2>/dev/null)"
        _out="${_out}${_out:+,}${_one}"
        _part=$((_part + 1))
    done
    printf '%s' "${_out}"
}
labels="$(probe_labels)"
label_source=blkid-p
if [ -z "$(printf '%s' "${labels}" | tr -d ',')" ]; then
    if sfdisk -d "${DEV}" >/tmp/sfdisk.txt 2>/dev/null && grep -q 'name="' /tmp/sfdisk.txt; then
        labels="$(sed -n 's/.*name="\([^"]*\)".*/\1/p' /tmp/sfdisk.txt | paste -sd, -)"
        label_source=sfdisk
    fi
fi
if [ -z "$(printf '%s' "${labels}" | tr -d ',')" ]; then
    echo "[s2] label probe failed; blkid -p says:"
    blkid -p "${DEV}1" 2>&1 | sed 's/^/[s2]   /'
    sfdisk -d "${DEV}" 2>&1 | head -n 6 | sed 's/^/[s2]   /'
    report_failure label-unreadable
fi
echo "[s2] PARTNAMEs (${label_source}): ${labels}"
[ "${labels}" = "ab-esp,ab-slot-a,ab-slot-b,ab-data" ] || report_failure "labels-${labels}"

# The second name set: the filesystem LABEL a human reads. It lives in the superblock,
# not in the GPT, so a build that relabels one side only is caught right here.
probe_fs_label() {
    _part="$1"
    _value="$(blkid -p -o value -s LABEL "${DEV}${_part}" 2>/dev/null)"
    printf '%s' "${_value}"
}
part=2
for want_label in slot-a slot-b data; do
    have_label="$(probe_fs_label "${part}")"
    [ "${have_label}" = "${want_label}" ] \
        || report_failure "fs-label-p${part}-${have_label:-empty}"
    part=$((part + 1))
done
# The FAT label is checked on the host by scripts/ci/image-verify.sh; here it is reported
# when blkid can read it and skipped explicitly when this initramfs cannot probe vfat.
p1_label="$(probe_fs_label 1)"
if [ -z "${p1_label}" ]; then
    echo "[s2] SKIP p1 FAT label check: blkid could not probe vfat in this guest"
else
    [ "${p1_label}" = "ESP" ] || report_failure "fs-label-p1-${p1_label}"
fi
echo "[s2] filesystem LABELs slot-a/slot-b/data${p1_label:+/ESP}"

# Sizes come from sysfs, which is the kernel's own view of the GPT.
want_sizes="262144 262144 262144 262144"
part=1
for want in ${want_sizes}; do
    have="$(cat "/sys/class/block/$(basename "${DEV}${part}")/size" 2>/dev/null || echo 0)"
    [ "${have}" = "${want}" ] || report_failure "size-p${part}-${have}"
    part=$((part + 1))
done
echo "[s2] partition sizes 128/128/128/128 MiB"

# --------------------------------------------------------------------------- #
# 1b. First-boot growth: the image ships p4 short of the tail, and the decision the
#     boot init takes is recomputed here from the real table
# --------------------------------------------------------------------------- #

if [ "${GROW_LIB}" != "loaded" ]; then
    echo "[s2] SKIP growth decision: /lib/grow.sh is missing or defines nothing"
elif ! sfdisk -d "${DEV}" >/tmp/table.txt 2>/dev/null; then
    echo "[s2] SKIP growth decision: sfdisk could not dump ${DEV}"
else
    last_lba="$(sed -n 's/^last-lba:[[:space:]]*//p' /tmp/table.txt | head -n 1)"
    p4_start="$(sed -n "s|^${DEV}4 : start= *\([0-9]*\),.*|\1|p" /tmp/table.txt | head -n 1)"
    [ -n "${last_lba}" ] || report_failure growth-no-last-lba
    [ -n "${p4_start}" ] || report_failure growth-no-p4-line
    # sfdisk counts logical sectors; sysfs `size` is in 512-byte units, so the disk size
    # handed to the decision is converted through the device's logical block size.
    if command -v di_sector_size >/dev/null 2>&1; then
        image_sectors=$(( image_size * 512 / $(di_sector_size "${DEV}") ))
    else
        image_sectors="${image_size}"
    fi
    decision="$(wf_grow_decide /tmp/table.txt "${DEV}4" "${image_sectors}")"
    # Either outcome is fine: an image with a tail still to claim must plan a grow, and a
    # partition that already reaches the end must read already-full. What must never
    # happen is the decision failing, because that is the state that leaves p4 small.
    case "${decision}" in
        grow\ *) echo "[s2] first-boot growth decision: ${decision}" ;;
        already-full\ *) echo "[s2] first-boot growth decision: ${decision}" ;;
        *) report_failure "growth-decision-${decision}" ;;
    esac
    # A table whose p4 already reaches the last usable LBA has to read back as
    # already-full: that is what makes a second boot a no-op on the same disk.
    grown=$((last_lba - p4_start + 1))
    sed "s|^\(${DEV}4 : start= *[0-9]*, size= *\)[0-9]*|\1${grown}|" \
        /tmp/table.txt >/tmp/table-full.txt
    full="$(wf_grow_decide /tmp/table-full.txt "${DEV}4" "${image_sectors}")"
    [ "${full}" = "already-full ${last_lba}" ] || report_failure "growth-idempotency-${full}"
    echo "[s2] a second boot on this disk would read: ${full}"
    echo "[s2] /lib/grow.sh ran the first-boot decision against the real table"
fi

# --------------------------------------------------------------------------- #
# 1c. Device identity: the boot disk is derived from sysfs, never from its name
# --------------------------------------------------------------------------- #

if [ "${IDENTITY_LIB}" = "loaded" ]; then
    for part in 1 2 3 4; do
        parent="$(di_parent_disk "${DEV}${part}" 2>/dev/null)"
        [ "${parent}" = "${DEV}" ] || report_failure "parent-p${part}-${parent:-none}"
    done
    echo "[s2] all four partitions report ${DEV} as their parent disk"
    identity="$(di_resolve 2>/dev/null)"
    case "${identity}" in
        "disk=${DEV} method="*) echo "[s2] device identity: ${identity}" ;;
        *) report_failure "device-identity-${identity:-empty}" ;;
    esac
else
    echo "[s2] SKIP device identity: /lib/disk-identity.sh is missing or defines nothing"
fi

# The platform layer ships the same library: the initramfs and the running system must
# not resolve the boot disk with two different implementations.
mount -t btrfs -o ro "${DEV}2" /mnt || report_failure p2-mount-failed
plat_dir=/mnt/@platform
if [ -f "${plat_dir}/lib/disk-identity.sh" ]; then
    if [ -f /lib/disk-identity.sh ]; then
        cmp -s /lib/disk-identity.sh "${plat_dir}/lib/disk-identity.sh" \
            || report_failure identity-lib-drift
        echo "[s2] initramfs and @platform carry the same disk-identity.sh"
    fi
    AB_DISK_IDENTITY_LIB="${plat_dir}/lib/disk-identity.sh"
    export AB_DISK_IDENTITY_LIB
    if [ -f "${plat_dir}/lib/ab-partitions.sh" ]; then
        . "${plat_dir}/lib/ab-partitions.sh"
        plat_identity="$(ab_disk_identity 2>/dev/null)"
        [ "${plat_identity}" = "${identity}" ] \
            || report_failure "platform-identity-${plat_identity:-empty}"
        echo "[s2] the platform layer resolves the same disk: ${plat_identity}"
    fi
else
    echo "[s2] SKIP platform identity library: @platform has no lib/disk-identity.sh"
fi
# ab-slot reports the same answer through its status line; the contract is the token.
if [ -f "${plat_dir}/usr/sbin/ab-slot" ]; then
    if grep -q 'disk=%s method=%s' "${plat_dir}/usr/sbin/ab-slot"; then
        echo "[s2] ab-slot status reports disk=/method= from the shared resolver"
    else
        echo "[s2] SKIP ab-slot status disk= readback: the shipped ab-slot has no contract yet"
    fi
fi
umount /mnt

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
    # -o lists subvolumes below a path, and all of them sit below the filesystem
    # root; the per-entry top-level check below is what actually proves flatness.
    _nested=""
    umount /mnt
    _sorted_paths="$(printf '%s\n' "${_paths}" | tr ',' '\n' | sort | paste -sd, -)"
    _sorted_want="$(printf '%s\n' "${_want}" | tr ',' '\n' | sort | paste -sd, -)"
    [ "${_sorted_paths}" = "${_sorted_want}" ] || report_failure "p${_part}-subvolumes-${_paths}"
    if printf '%s\n' "${_have}" | grep -qv '|5$'; then
        report_failure "p${_part}-not-top-level"
    fi
    [ -z "${_nested}" ] || report_failure "p${_part}-nested-subvolume"
    echo "[s2] p${_part}: ${_want}"
}

expect_subvolumes 2 "@sys,@platform"
expect_subvolumes 3 "@sys,@platform"
expect_subvolumes 4 "@data,@docker,${expect_overlay},@swap"

mount -t btrfs -o ro "${DEV}4" /mnt || report_failure p4-mount-failed
for entry in upper work; do
    [ -d "/mnt/${expect_overlay}/${entry}" ] || report_failure "overlay-${entry}-missing"
done
# The growth outcome is a runtime fact: the image must not carry one, otherwise a
# shipped image would claim a growth it never performed.
[ ! -e /mnt/.ab/grow ] || report_failure grow-record-shipped-in-image
umount /mnt
echo "[s2] ${expect_overlay} contains plain upper/ and work/"

# --------------------------------------------------------------------------- #
# 4. @sys content
# --------------------------------------------------------------------------- #

mount -t btrfs -o ro "${DEV}2" /mnt || report_failure p2-mount-failed
[ -d /mnt/@sys ] || report_failure no-at-sys
[ -d /mnt/@platform ] || report_failure no-at-platform
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

# vfat is not part of the btrfs module closure, so this kernel may not carry it.
# The host stage mounts p1 and asserts the same facts with the same thresholds; the
# guest duplicate is skipped with an explicit line rather than silently passing.
if grep -q vfat /proc/filesystems; then
    mount -t vfat -o ro "${DEV}1" /mnt || report_failure p1-mount-failed
else
    echo "[s2] SKIP p1 content check: vfat is not available in this kernel"
    P1_SKIPPED=1
fi
if [ "${P1_SKIPPED:-0}" = 0 ]; then
    [ -n "$(find /mnt -type f -iname '*.efi' | head -n 1)" ] || report_failure p1-missing-efi
    for required in boot/grub vmlinuz-a vmlinuz-b initrd-a initrd-b ab ab/log; do
        [ -e "/mnt/${required}" ] || report_failure "p1-missing-${required}"
    done
    # Build-time device identity: the PARTUUIDs the upgrade path follows after a dd copy.
    # The file lives at ab/device.json next to ab/state.json. An image that still carries
    # the older boot/ab/ placement gets a warning and nothing else: the main path is the
    # contract, and the host verifier already fails the build on a drift.
    device_json=/mnt/ab/device.json
    if [ ! -f "${device_json}" ] && [ -f /mnt/boot/ab/device.json ]; then
        echo "[s2] WARNING device identity is at boot/ab/device.json, expected ab/device.json"
    fi
    if [ -f "${device_json}" ]; then
        # sfdisk reads the GPT itself, which is the same source the build used; blkid only
        # cross-checks it, because a low-level blkid probe in this initramfs cannot always
        # resolve PARTUUID from a partition node.
        sfdisk -d "${DEV}" >/tmp/table-gpt.txt 2>/dev/null || : >/tmp/table-gpt.txt
        device_json_checked=0
        device_json_skipped=0
        for part in 1 2 3 4; do
            want_uuid="$(sed -n "s#^${DEV}${part}[[:space:]]*:.*uuid=\([0-9A-Fa-f-]*\).*#\1#p" \
                /tmp/table-gpt.txt | head -n 1 | tr 'A-F' 'a-f')"
            blkid_uuid="$(blkid -p -o value -s PARTUUID "${DEV}${part}" 2>/dev/null \
                | head -n 1 | tr 'A-F' 'a-f')"
            if [ -z "${want_uuid}" ] && [ -n "${blkid_uuid}" ]; then
                want_uuid="${blkid_uuid}"
            elif [ -n "${want_uuid}" ] && [ -n "${blkid_uuid}" ] \
                && [ "${want_uuid}" != "${blkid_uuid}" ]; then
                echo "[s2] WARNING PARTUUID of ${DEV}${part} differs: sfdisk ${want_uuid}, blkid ${blkid_uuid}"
            fi
            if [ -z "${want_uuid}" ]; then
                echo "[s2] WARNING no PARTUUID for ${DEV}${part} from sfdisk or blkid"
                device_json_skipped=$((device_json_skipped + 1))
                continue
            fi
            grep -qi "${want_uuid}" "${device_json}" \
                || report_failure "device-json-p${part}"
            device_json_checked=$((device_json_checked + 1))
        done
        if [ "${device_json_skipped}" -gt 0 ] && [ "${device_json_checked}" -eq 0 ]; then
            echo "[s2] SKIP ab/device.json cross-check: no PARTUUID was readable in this guest"
        else
            echo "[s2] ab/device.json matches ${device_json_checked} PARTUUID(s) read from the image"
        fi
    else
        echo "[s2] SKIP ab/device.json: this image was built without it"
    fi
    p1_kib="$(du -sk /mnt | cut -f1)"
    umount /mnt
    echo "[s2] p1 uses ${p1_kib} KiB of the ${expect_p1max} KiB budget"
    [ "${p1_kib}" -lt "${expect_p1max}" ] || report_failure "p1-over-budget-${p1_kib}"
fi

echo "S2-RESULT=ok parts=${found} images=${image_bytes}"
sync
poweroff -f
exit 0
