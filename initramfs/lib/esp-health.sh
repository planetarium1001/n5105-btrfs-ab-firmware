#!/bin/sh
# The ESP health probe: a read-only verdict on the EFI system partition.
#
# The leading candidate for the 05:36 poweroff is the ESP itself (`esp-mount-failed`,
# `state-missing` right after it), and that is the one fault surface on this machine that
# cannot be repaired from the running system: when it is broken, the machine is the only
# thing that can say so. So this file reads the volume and nothing else. It writes no FAT,
# rebuilds nothing, changes no partition and runs no repair tool - not now, and not behind
# a flag. What it produces is evidence:
#
#   esp=<ok|dirty|unreadable> boot=<n> sig=<ok|bad> dirty_bit=<0|1> fsinfo=<ok|bad|na> mount=<rw|fail>
#
# The verdict is a cross-check of four readings, and the components stay in the line so a
# person holding the pulled disk can judge for themselves:
#
#   sig        the 55AA boot signature at offset 510. Missing means the volume does not
#              even look like a FAT volume: `unreadable`, whatever else the bytes say.
#   dirty_bit  bit 27 of FAT[1], the clean-shutdown bit (fatgen103 §3.1). A volume that was
#              unmounted cleanly carries it set; the kernel clears it while the volume is in
#              use, so after a power cut it is clear.
#   fsinfo     the FAT32 FSInfo sector: its three signatures and a free-count that fits the
#              volume's cluster count. `na` means the volume has no FSInfo sector (FAT12/16,
#              or a BPB that names none), which is a statement, not a failed check.
#   mount      the real result of the read-write mount the caller then performs.
#
# A single dirty bit is *not* a verdict: a hard power cut lights it every time (PRD risk 2),
# and reporting every machine that lost power as "dirty" is noise, not evidence. `dirty`
# therefore needs the bit plus one witness - the kernel's own "not properly unmounted"
# line, or an FSInfo sector that no longer parses. Both cases are visible in the line either
# way, which is the point of splitting the components out.
#
# Nothing here changes a boot decision. A dirty or unreadable verdict is recorded and the
# boot continues on the read-only strategy it would have used anyway.
#
# POSIX sh on purpose: this runs under the busybox in the initramfs, whose applets are the
# ones in scripts/ci/initramfs-tools.lock.json (`dd`, `hexdump`, `awk`, `sync`, ... - no
# `stat`, no `od`, no repair tool of any kind).

# Where the boot sector is buffered. It has to be a tmpfs (nothing is mounted yet when the
# probe runs), so this directory exists for one boot and goes away with the initramfs.
WF_ESP_HEALTH_TMP="${WF_ESP_HEALTH_TMP:-/run/esp-health}"
# The three programs, named so a test can count the calls instead of trusting the source.
WF_DD="${WF_DD:-dd}"
WF_HEXDUMP="${WF_HEXDUMP:-hexdump}"
WF_DMESG="${WF_DMESG:-dmesg}"

# wf_esp_health_hex <file> <offset> <count>: those bytes, in memory order, as lowercase hex.
#
# `dd bs=1` is byte addressed on purpose: the boot sector is read once into a buffer and
# every field below is taken out of that buffer, so the number of device reads stays small
# and none of them has to be aligned to anything.
#
# A short read is a *failed* read, never a zero. Without the length check a `dd` that could
# not reach the volume returns nothing, the parser below turns "no bytes" into the number 0,
# and for the clean-shutdown bit 0 means "unmounted cleanly" - the probe would then report a
# healthy FAT it never read. That is the one lie this file must not tell.
wf_esp_health_hex() {
    wf_ehh_file="$1"
    wf_ehh_skip="${2:-0}"
    wf_ehh_count="${3:-1}"
    [ -n "${wf_ehh_file}" ] || return 1
    [ -r "${wf_ehh_file}" ] || return 1
    wf_ehh_out="$("${WF_DD}" if="${wf_ehh_file}" bs=1 skip="${wf_ehh_skip}" \
        count="${wf_ehh_count}" 2>/dev/null \
        | "${WF_HEXDUMP}" -v -e '1/1 "%02x"' 2>/dev/null \
        | tr -d ' \n')"
    [ "${#wf_ehh_out}" -eq $(( wf_ehh_count * 2 )) ] || return 1
    printf '%s' "${wf_ehh_out}"
    return 0
}

# wf_esp_health_le <hex bytes>: the little-endian number those bytes spell.
#
# Every number in a FAT boot sector is little-endian, and the only arithmetic this needs is
# "first byte is the least significant", which is four lines of awk - cheaper and clearer
# than a shell loop per byte.
wf_esp_health_le() {
    printf '%s' "${1:-}" | awk '
        BEGIN { digits = "0123456789abcdef" }
        {
            hex = tolower($0)
            if (hex == "" || length(hex) % 2 != 0) { print "0"; exit }
            value = 0
            scale = 1
            for (i = 1; i <= length(hex); i += 2) {
                hi = index(digits, substr(hex, i, 1)) - 1
                lo = index(digits, substr(hex, i + 1, 1)) - 1
                if (hi < 0 || lo < 0) { print "0"; exit }
                value += (hi * 16 + lo) * scale
                scale *= 256
            }
            printf "%.0f", value
        }'
}

# wf_esp_health_num <value>: the value as a plain decimal, 0 when it is not one.
wf_esp_health_num() {
    case "${1:-}" in
        '' | *[!0-9]*) printf '0' ;;
        *) printf '%s' "$1" ;;
    esac
}

# wf_esp_health_block_size <device>: the sector size the volume is addressed in.
#
# The BPB is the first answer and the only one that can be right about a volume that is not
# the device's own, but a BPB that did not survive cannot be trusted to place the FAT either:
# then the device's logical block size decides, which is the same lookup initramfs/lib/grow.sh
# uses before it writes a partition table (4Kn disks report 4096 there).
wf_esp_health_block_size() {
    wf_ehb_name="$(basename "${1:-}")"
    if command -v di_sector_size >/dev/null 2>&1; then
        wf_ehb_value="$(di_sector_size "$1" 2>/dev/null)" || wf_ehb_value=""
        case "${wf_ehb_value}" in
            '' | *[!0-9]* | 0) : ;;
            *)
                printf '%s' "${wf_ehb_value}"
                return 0
                ;;
        esac
    fi
    for wf_ehb_file in \
        "${WF_SYS_BLOCK}/${wf_ehb_name}/queue/logical_block_size" \
        "${WF_SYS_BLOCK}/${wf_ehb_name}/../queue/logical_block_size"
    do
        [ -r "${wf_ehb_file}" ] || continue
        wf_ehb_value="$(cat "${wf_ehb_file}" 2>/dev/null)"
        case "${wf_ehb_value}" in
            '' | *[!0-9]* | 0) continue ;;
        esac
        printf '%s' "${wf_ehb_value}"
        return 0
    done
    printf '%s' "${WF_SECTOR_BYTES:-512}"
    return 0
}

# wf_esp_health_dirty_fat32 <device> <fat offset>: prints 1 when FAT[1] says "not cleanly
# unmounted" and 0 when it says "clean". Non-zero *return* means the entry could not be read,
# which is a third answer and must not be collapsed into either of the two (see the comment
# on wf_esp_health_hex).
#
# FAT[1] starts at the fourth byte of the first FAT. Its bit 27 is the clean-shutdown bit:
# set means the volume was unmounted properly, clear means something took the machine down
# with the volume in use. A FAT12/16 volume has no such field and says nothing here.
wf_esp_health_dirty_fat32() {
    wf_ehd_entry_hex="$(wf_esp_health_hex "$1" "$2" 4)" || return 1
    wf_ehd_entry="$(wf_esp_health_num "$(wf_esp_health_le "${wf_ehd_entry_hex}")")"
    # 0x08000000: bit 27 of the entry, i.e. inside the 28-bit entry itself and not in the
    # reserved top nibble a FAT32 entry never uses.
    if [ "$((wf_ehd_entry & 134217728))" -eq 0 ]; then
        printf '1'
    else
        printf '0'
    fi
    return 0
}

# wf_esp_health_dmesg_dirty: did the kernel say this volume was not unmounted properly.
#
# The mount that the caller performs right before this runs is what makes the kernel look at
# the volume, and the message it logs then is the second witness the dirty bit needs. It is
# scoped to this boot, because the ring buffer is: a line from an earlier boot is gone.
wf_esp_health_dmesg_dirty() {
    "${WF_DMESG}" 2>/dev/null | grep -q 'not properly unmounted' || return 1
    return 0
}

# wf_esp_health_probe <device>: read the volume, print the three readings.
#
# Every read goes through `dd if=`, and the only `of=` target is the buffer under
# WF_ESP_HEALTH_TMP. The volume is opened read-only and never written - not to clear the
# dirty bit, not to refresh FSInfo, not for anything.
wf_esp_health_probe() {
    wf_ehp_dev="${1:-}"
    wf_ehp_sig="bad"
    wf_ehp_dirty="0"
    wf_ehp_fsinfo="na"
    # read=error means at least one structure could not be read. It is reported next to the
    # components rather than folded into them, and it can only ever make the verdict worse.
    wf_ehp_read="ok"
    if [ -n "${wf_ehp_dev}" ] && [ -r "${wf_ehp_dev}" ]; then
        wf_ehp_dir="${WF_ESP_HEALTH_TMP}"
        mkdir -p "${wf_ehp_dir}" 2>/dev/null || :
        wf_ehp_boot="${wf_ehp_dir}/boot-sector.bin"
        rm -f "${wf_ehp_boot}" 2>/dev/null || :
        # 512 bytes, always: the BPB fields and the signature at offset 510 live in the
        # first 512 bytes of the volume whatever the volume's own sector size is, so this
        # is the one read that must not be scaled by anything.
        if ! "${WF_DD}" if="${wf_ehp_dev}" bs=512 count=1 of="${wf_ehp_boot}" 2>/dev/null \
            || [ ! -s "${wf_ehp_boot}" ]; then
            # Nothing could be read from the volume at all.
            wf_ehp_read="error"
        else
            # H1: the 55AA signature, the volume's own claim to be a FAT volume.
            if [ "$(wf_esp_health_hex "${wf_ehp_boot}" 510 2)" = "55aa" ]; then
                wf_ehp_sig="ok"
            fi
            # Everything below is an offset in bytes, and the volume's own BPB says how
            # many bytes a sector has. A BPB that names none is read at the size the
            # device reports: on a 4Kn volume a 512-byte assumption looks at the wrong
            # place entirely and invents a dirty bit that is not there.
            wf_ehp_bps="$(wf_esp_health_le "$(wf_esp_health_hex "${wf_ehp_boot}" 11 2)")"
            case "${wf_ehp_bps}" in
                512 | 1024 | 2048 | 4096) : ;;
                *) wf_ehp_bps="$(wf_esp_health_block_size "${wf_ehp_dev}")" ;;
            esac
            wf_ehp_bps="$(wf_esp_health_num "${wf_ehp_bps}")"
            [ "${wf_ehp_bps}" -ge 512 ] || wf_ehp_bps=512
            wf_ehp_reserved="$(wf_esp_health_num \
                "$(wf_esp_health_le "$(wf_esp_health_hex "${wf_ehp_boot}" 14 2)")")"
            wf_ehp_fats="$(wf_esp_health_num \
                "$(wf_esp_health_le "$(wf_esp_health_hex "${wf_ehp_boot}" 16 1)")")"
            wf_ehp_fatsz16="$(wf_esp_health_num \
                "$(wf_esp_health_le "$(wf_esp_health_hex "${wf_ehp_boot}" 22 2)")")"
            wf_ehp_fatsz32="$(wf_esp_health_num \
                "$(wf_esp_health_le "$(wf_esp_health_hex "${wf_ehp_boot}" 36 4)")")"
            wf_ehp_fat_off=$((wf_ehp_reserved * wf_ehp_bps))

            if [ "${wf_ehp_fatsz16}" -eq 0 ] && [ "${wf_ehp_fatsz32}" -gt 0 ]; then
                # H2: the clean-shutdown bit, and H3: the FSInfo sector. Both exist on a
                # FAT32 volume only, and both are read straight off the device: neither can
                # be answered from the 512-byte boot sector buffer.
                wf_ehp_fsinfo="ok"
                if wf_ehp_dirty_value="$(wf_esp_health_dirty_fat32 \
                    "${wf_ehp_dev}" $((wf_ehp_fat_off + 4)))"; then
                    wf_ehp_dirty="${wf_ehp_dirty_value}"
                else
                    # The FAT could not be read. Saying "0" here would be the same lie as
                    # saying the volume was unmounted cleanly.
                    wf_ehp_read="error"
                    wf_ehp_dirty="unknown"
                fi
                wf_ehp_fsinfo_sec="$(wf_esp_health_num \
                    "$(wf_esp_health_le "$(wf_esp_health_hex "${wf_ehp_boot}" 48 2)")")"
                case "${wf_ehp_fsinfo_sec}" in
                    0 | 65535)
                        # The BPB names no FSInfo sector: there is nothing to check, and
                        # saying so is more useful than a green tick for a check that never
                        # ran.
                        wf_ehp_fsinfo="na"
                        ;;
                    *)
                        wf_ehp_fi_off=$((wf_ehp_fsinfo_sec * wf_ehp_bps))
                        if ! wf_ehp_lead="$(wf_esp_health_hex "${wf_ehp_dev}" "${wf_ehp_fi_off}" 4)" \
                            || ! wf_ehp_mid="$(wf_esp_health_hex "${wf_ehp_dev}" $((wf_ehp_fi_off + 484)) 4)" \
                            || ! wf_ehp_tail="$(wf_esp_health_hex "${wf_ehp_dev}" $((wf_ehp_fi_off + 508)) 4)"; then
                            # The FSInfo sector could not be read. That is not an FSInfo
                            # that failed its checks, and it is certainly not a clean one.
                            wf_ehp_read="error"
                            wf_ehp_fsinfo="unknown"
                        elif [ "${wf_ehp_lead}" != "52526141" ] \
                            || [ "${wf_ehp_mid}" != "72724161" ] \
                            || [ "${wf_ehp_tail}" != "000055aa" ]; then
                            wf_ehp_fsinfo="bad"
                        else
                            if ! wf_ehp_free_hex="$(wf_esp_health_hex "${wf_ehp_dev}" $((wf_ehp_fi_off + 488)) 4)" \
                                || ! wf_ehp_next_hex="$(wf_esp_health_hex "${wf_ehp_dev}" $((wf_ehp_fi_off + 492)) 4)"; then
                                wf_ehp_read="error"
                                wf_ehp_fsinfo="unknown"
                                wf_ehp_free_hex=""
                                wf_ehp_next_hex=""
                            fi
                            wf_ehp_free="$(wf_esp_health_num "$(wf_esp_health_le "${wf_ehp_free_hex}")")"
                            wf_ehp_next="$(wf_esp_health_num "$(wf_esp_health_le "${wf_ehp_next_hex}")")"
                            wf_ehp_clusters=0
                            wf_ehp_total="$(wf_esp_health_num "$(wf_esp_health_le \
                                "$(wf_esp_health_hex "${wf_ehp_boot}" 19 2)")")"
                            if [ "${wf_ehp_total}" -eq 0 ]; then
                                wf_ehp_total="$(wf_esp_health_num "$(wf_esp_health_le \
                                    "$(wf_esp_health_hex "${wf_ehp_boot}" 32 4)")")"
                            fi
                            wf_ehp_spc="$(wf_esp_health_num "$(wf_esp_health_le \
                                "$(wf_esp_health_hex "${wf_ehp_boot}" 13 1)")")"
                            wf_ehp_rootent="$(wf_esp_health_num "$(wf_esp_health_le \
                                "$(wf_esp_health_hex "${wf_ehp_boot}" 17 2)")")"
                            wf_ehp_root_secs=$(((wf_ehp_rootent * 32 + wf_ehp_bps - 1) / wf_ehp_bps))
                            wf_ehp_data_start=$((wf_ehp_reserved \
                                + wf_ehp_fats * wf_ehp_fatsz32 + wf_ehp_root_secs))
                            if [ "${wf_ehp_spc}" -gt 0 ] \
                                && [ "${wf_ehp_total}" -gt "${wf_ehp_data_start}" ]; then
                                wf_ehp_clusters=$(((wf_ehp_total - wf_ehp_data_start) \
                                    / wf_ehp_spc))
                            fi
                            if [ "${wf_ehp_clusters}" -le 0 ]; then
                                wf_ehp_fsinfo="bad"
                            else
                                # 0xFFFFFFFF is the documented "unknown", not a count that
                                # has to fit.
                                if [ "${wf_ehp_free}" -ne 4294967295 ] \
                                    && [ "${wf_ehp_free}" -gt "${wf_ehp_clusters}" ]; then
                                    wf_ehp_fsinfo="bad"
                                fi
                                if [ "${wf_ehp_next}" -ne 4294967295 ] \
                                    && [ "${wf_ehp_next}" -gt "${wf_ehp_clusters}" ]; then
                                    wf_ehp_fsinfo="bad"
                                fi
                            fi
                        fi
                        ;;
                esac
            fi
        fi
    fi
    printf 'sig=%s dirty_bit=%s fsinfo=%s read=%s' \
        "${wf_ehp_sig}" "${wf_ehp_dirty}" "${wf_ehp_fsinfo}" "${wf_ehp_read}"
    return 0
}

# wf_esp_health_finish "<probe>" <boot> <mount>: the verdict line, once the mount answered.
#
# Split from the probe because the last two witnesses only exist after the mount: the mount
# is the fourth reading, and it is also what makes the kernel log its opinion of the volume.
wf_esp_health_finish() {
    wf_ehf_probe="${1:-}"
    wf_ehf_boot="${2:-1}"
    wf_ehf_mount="${3:-fail}"
    wf_ehf_sig="bad"
    wf_ehf_dirty="0"
    wf_ehf_fsinfo="na"
    wf_ehf_read="error"
    for wf_ehf_kv in ${wf_ehf_probe}; do
        case "${wf_ehf_kv}" in
            sig=*) wf_ehf_sig="${wf_ehf_kv#sig=}" ;;
            dirty_bit=*) wf_ehf_dirty="${wf_ehf_kv#dirty_bit=}" ;;
            fsinfo=*) wf_ehf_fsinfo="${wf_ehf_kv#fsinfo=}" ;;
            read=*) wf_ehf_read="${wf_ehf_kv#read=}" ;;
        esac
    done
    wf_ehf_token="ok"
    # A structure that could not be read is not a clean structure: `unreadable` says the boot
    # cannot vouch for this volume, which is the truth, and it can never be talked down to ok.
    if [ "${wf_ehf_read}" != "ok" ] || [ "${wf_ehf_sig}" != "ok" ] \
        || [ "${wf_ehf_mount}" != "rw" ]; then
        wf_ehf_token="unreadable"
    else
        wf_ehf_witness="0"
        wf_esp_health_dmesg_dirty && wf_ehf_witness="1"
        if [ "${wf_ehf_dirty}" = "1" ] && [ "${wf_ehf_fsinfo}" = "bad" ]; then
            wf_ehf_token="dirty"
        elif [ "${wf_ehf_dirty}" = "1" ] && [ "${wf_ehf_witness}" = "1" ]; then
            wf_ehf_token="dirty"
        elif [ "${wf_ehf_fsinfo}" = "bad" ] && [ "${wf_ehf_witness}" = "1" ]; then
            wf_ehf_token="dirty"
        fi
    fi
    printf 'esp=%s boot=%s sig=%s dirty_bit=%s fsinfo=%s mount=%s read=%s' \
        "${wf_ehf_token}" "${wf_ehf_boot}" "${wf_ehf_sig}" "${wf_ehf_dirty}" \
        "${wf_ehf_fsinfo}" "${wf_ehf_mount}" "${wf_ehf_read}"
    return 0
}

# wf_esp_health_state "<line>": just the token, for the breadcrumb that reports it.
wf_esp_health_state() {
    for wf_ehs_kv in ${1:-}; do
        case "${wf_ehs_kv}" in
            esp=*)
                printf '%s' "${wf_ehs_kv#esp=}"
                return 0
                ;;
        esac
    done
    printf 'unknown'
    return 0
}

# wf_esp_health_record <directory> "<line>": keep the verdict on the p4 side.
#
# <directory> is the p4 root subvolume mount point, which ab-boot mounts at /mnt/p4 at
# runtime. The write is the one initramfs/lib/grow.sh uses for `.ab/grow`: a temporary file,
# a sync, a rename, a sync - so a power cut during the write can lose the new line but can
# never leave half a line where a reader expects one.
wf_esp_health_record() {
    wf_ehr_dir="${1:-}"
    wf_ehr_line="${2:-}"
    [ -n "${wf_ehr_dir}" ] || return 1
    [ -n "${wf_ehr_line}" ] || return 1
    mkdir -p "${wf_ehr_dir}/.ab" 2>/dev/null || return 1
    wf_ehr_tmp="${wf_ehr_dir}/.ab/esp-health.tmp"
    printf '%s\n' "${wf_ehr_line}" >"${wf_ehr_tmp}" 2>/dev/null || return 1
    sync
    mv "${wf_ehr_tmp}" "${wf_ehr_dir}/.ab/esp-health" 2>/dev/null || return 1
    sync
    return 0
}
