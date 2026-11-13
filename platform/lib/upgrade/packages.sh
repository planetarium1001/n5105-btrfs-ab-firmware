#!/bin/sh
# packages.sh - make the target slot's package metadata describe the version it carries.
#
# A downgrade (or an upgrade) replaces the system tree but not the user's apk state: the
# writable layer carries `/etc/apk/world`, which pins the kernel the machine used to run,
# and `/etc/apk/distfeeds.list`, which still points at the old release. On a real machine
# that combination fails like this (measured on 2026-11-11, 20261111-12 quality.md):
#
#   apk add kmod-usb-storage        -> rc=0 and nothing happens
#   apk add kmod-usb-storage=6.12.87-r1
#                                   -> rc=99 kernel-6.12.103: breaks: ... satisfies: world[kernel=6.12.103]
#
# So installing a kmod for the kernel the machine is now running is impossible, and the
# failure text names neither cause. This library aligns the two files with the version the
# slot now carries, before the machine is allowed to try it.
#
# The alignment is offline and file-level on purpose:
#
#   * it never runs `apk`. A machine that upgrades while its feeds are unreachable is
#     normal, and "aligned" is a statement about the metadata, not about the network;
#   * it never adds or removes packages. `--force-broken-world` plus installing a different
#     kernel package would add a second owner of the ESP's kernel/initrd files, which is
#     exactly what ab-slot owns.
#
# ab_packages_align <payload-dir> <target-slot> <target-sys> <target-upper>
#
#   Returns 0 when the target's metadata names the target version, non-zero with
#   AB_PACKAGES_REASON set when it cannot (nothing to align from, an unwritable file, a
#   rewrite that did not read back). AB_PACKAGES_KERNEL carries the identity that was
#   written, for the state line the caller publishes.
#
# Neither failure blocks the upgrade: the machine boots and runs, it just cannot install
# packages matched to its kernel until the metadata is fixed, and that is what the
# `packages=` field of `ab-slot status` is for.

# Read by the caller.
# shellcheck disable=SC2034
AB_PACKAGES_REASON=""
# shellcheck disable=SC2034
AB_PACKAGES_KERNEL=""

_packages_fail() {
    AB_PACKAGES_REASON="$1"
    printf 'packages: %s\n' "$1" >&2
    return 1
}

# _packages_kernel_lines <file>: every `kernel=` line of a world file, one per line.
_packages_kernel_lines() {
    [ -f "$1" ] || return 0
    sed -n 's/^\(kernel=[^[:space:]]*\).*/\1/p' "$1"
}

# _packages_kernel_from_db <installed>: the kernel package the slot's apk database holds,
# as `kernel=<version>`. Used when the payload's own world file does not pin one.
_packages_kernel_from_db() {
    [ -f "$1" ] || return 0
    awk '
        /^P:kernel$/ { find = 1; next }
        /^$/ { find = 0 }
        find && /^V:/ { printf "kernel=%s\n", substr($0, 3); exit }
    ' "$1"
}

# _packages_version_from_manifest <payload-dir>: the version the payload claims.
_packages_version_from_manifest() {
    sed -n 's/.*"rootfs": *"\([^"]*\)".*/\1/p' "$1/manifest.json" 2>/dev/null | head -n 1
}

# _packages_rewrite <file> <awk-program> <awk -v args...>: rewrite through a copy, keep the
# original as <file>.ab-align.bak, and rename. A reader never sees half a file, and the
# original is still there to roll back to when the result does not read back.
_packages_rewrite() {
    _file="$1"
    _program="$2"
    shift 2
    _bak="${_file}.ab-align.bak"
    _tmp="${_file}.ab-align.$$"
    [ -f "${_bak}" ] || cp "${_file}" "${_bak}" 2>/dev/null || return 1
    # shellcheck disable=SC2086  # the -v assignments are single words by construction
    awk "$@" "${_program}" "${_file}" >"${_tmp}" 2>/dev/null || {
        rm -f "${_tmp}" 2>/dev/null || true
        return 1
    }
    sync 2>/dev/null || true
    mv "${_tmp}" "${_file}" 2>/dev/null || {
        rm -f "${_tmp}" 2>/dev/null || true
        return 1
    }
    sync 2>/dev/null || true
    return 0
}

# _packages_restore <file>: put the pre-rewrite copy back (used when the read-back fails).
_packages_restore() {
    _bak="$1.ab-align.bak"
    [ -f "${_bak}" ] || return 1
    cp "${_bak}" "$1" 2>/dev/null || return 1
    sync 2>/dev/null || true
    return 0
}

# _packages_world_mismatch <file> <wanted kernel line>: 0 when some `kernel=` line differs.
_packages_world_mismatch() {
    awk -v want="$2" '/^kernel=/ { if ($0 != want) bad = 1 } END { exit bad ? 0 : 1 }' "$1"
}

# _packages_feeds_mismatch <file> <wanted version>: 0 when some /releases/<x>/ names another
# version. The kernel-bound `kmods/<kver>-<hash>` part of a feed path is deliberately not
# touched: guessing a kernel build hash is worse than leaving the old one in plain sight.
_packages_feeds_mismatch() {
    awk -v want="$2" '
        {
            rest = $0
            while (match(rest, /\/releases\/[0-9][0-9.]*\//)) {
                seg = substr(rest, RSTART + 10, RLENGTH - 11)
                if (seg != want) bad = 1
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
        END { exit bad ? 0 : 1 }
    ' "$1"
}

ab_packages_align() {
    _payload="$1"
    _target="$2"
    _sys="$3"
    _upper="$4"
    AB_PACKAGES_REASON=""
    AB_PACKAGES_KERNEL=""

    _version="$(_packages_version_from_manifest "${_payload}")"
    if [ -z "${_version}" ]; then
        _packages_fail "payload-without-version"
        return 1
    fi
    # Defence in depth: the version is pasted into a feed path. `ab-upgrade` refuses a
    # version outside this character set already; a library that another caller drives must
    # not depend on that.
    case "${_version}" in
        .* | *[!A-Za-z0-9._~+-]*)
            _packages_fail "version-invalid"
            return 1
            ;;
    esac

    # 1. the kernel identity the target carries: what its own world pins, else what its
    #    apk database holds. Both are read from the payload's tree, never from the running
    #    system, because the running system is the version being replaced.
    _kernel="$(_packages_kernel_lines "${_sys}/etc/apk/world" | head -n 1)"
    if [ -z "${_kernel}" ]; then
        _kernel="$(_packages_kernel_from_db "${_sys}/lib/apk/db/installed")"
    fi

    # 2. world in the writable layer: the pin that makes apk refuse a kmod for this kernel.
    #    Every `kernel=` line is moved, not just the first one: a world with two pins would
    #    otherwise keep the second one and still report success.
    _world="${_upper}/etc/apk/world"
    _world_changed=0
    if [ -f "${_world}" ]; then
        _pins="$(_packages_kernel_lines "${_world}")"
        _pin_count="$(printf '%s\n' "${_pins}" | grep -c . || true)"
        if [ -n "${_pins}" ] && [ "${_pin_count}" -gt 1 ]; then
            _distinct="$(printf '%s\n' "${_pins}" | sort -u | grep -c . || true)"
            if [ "${_distinct}" -gt 1 ]; then
                # Two different pins mean two kernels were installed at some point; picking
                # one would be a guess about the user's intent.
                _packages_fail "multiple-kernel-pins"
                return 1
            fi
        fi
        if [ -n "${_pins}" ]; then
            if [ -z "${_kernel}" ]; then
                _packages_fail "kernel-unknown"
                return 1
            fi
            if [ "${_pins}" != "${_kernel}" ]; then
                if ! _packages_rewrite "${_world}" '{ if (/^kernel=/) { print want; next } print }' \
                    -v want="${_kernel}"; then
                    _packages_fail "world-unwritable"
                    return 1
                fi
                _world_changed=1
            fi
        fi
    fi
    AB_PACKAGES_KERNEL="${_kernel:-unknown}"

    # 3. distfeeds in the writable layer: the same seven lines the machine was flashed
    #    with, still naming the old release. The payload's own /etc/apk/distfeeds.list
    #    already names the new one, so a writable layer without one needs nothing.
    _feeds_changed=0
    for _feeds in "${_upper}/etc/apk/distfeeds.list" "${_upper}/etc/apk/repositories"; do
        [ -f "${_feeds}" ] || continue
        [ -n "$(sed -n 's|.*/releases/[0-9][0-9.]*/.*|&|p' "${_feeds}" | head -n 1)" ] || continue
        if _packages_feeds_mismatch "${_feeds}" "${_version}"; then
            if ! _packages_rewrite "${_feeds}" '
                    {
                        out = ""
                        rest = $0
                        while (match(rest, /\/releases\/[0-9][0-9.]*\//)) {
                            out = out substr(rest, 1, RSTART - 1) "/releases/" ver "/"
                            rest = substr(rest, RSTART + RLENGTH)
                        }
                        print out rest
                    }' -v ver="${_version}"; then
                _packages_fail "distfeeds-unwritable"
                return 1
            fi
            _feeds_changed=1
        fi
    done

    # 4. read back what was written: the verdict has to be evidence, not the intent. A
    #    rewrite that did not land is exactly the silent failure this whole task is about,
    #    and a rewrite that landed *wrong* (say, an `&` expanded inside the replacement) is
    #    worse than one that did not land, so the original comes back.
    if [ "${_world_changed}" = "1" ] && _packages_world_mismatch "${_world}" "${_kernel}"; then
        _packages_restore "${_world}"
        _packages_fail "world-not-verified"
        return 1
    fi
    for _feeds in "${_upper}/etc/apk/distfeeds.list" "${_upper}/etc/apk/repositories"; do
        [ -f "${_feeds}" ] || continue
        if _packages_feeds_mismatch "${_feeds}" "${_version}"; then
            _packages_restore "${_feeds}"
            _packages_fail "distfeeds-not-verified"
            return 1
        fi
    done
    # The pre-rewrite copies are only useful until the result is proven; a `.ab-align.bak`
    # left in the user's own /etc would be junk nobody knows to delete.
    rm -f "${_world}.ab-align.bak" 2>/dev/null || true
    rm -f "${_upper}/etc/apk/distfeeds.list.ab-align.bak" 2>/dev/null || true
    rm -f "${_upper}/etc/apk/repositories.ab-align.bak" 2>/dev/null || true

    _packages_log="packages: ${_target} on ${_version}"
    [ "${_world_changed}" = "1" ] && _packages_log="${_packages_log}, world pinned to ${_kernel}"
    [ "${_feeds_changed}" = "1" ] && _packages_log="${_packages_log}, distfeeds moved to ${_version}"
    [ "${_world_changed}" = "0" ] && [ "${_feeds_changed}" = "0" ] \
        && _packages_log="${_packages_log}, metadata already matched"
    printf '%s\n' "${_packages_log}" >&2
    return 0
}

# --------------------------------------------------------------------------- #
# Package snapshots: the record a package-level rollback replays
#
# A snapshot is text on the writable layer, in <layer>/apk/snapshots/. It is not a
# backup of files (ab-backup owns that): it records which versions this machine had, so
# `ab-slot packages revert` can ask apk for them again. That is why it stays out of the
# running root - nothing under upper/ changes because of it.
#
# The newest AB_APK_SNAPSHOT_KEEP are kept. Retention lives here rather than in the
# caller so a machine that is upgraded often does not accumulate a directory listing per
# week on a 128 MiB partition.
# --------------------------------------------------------------------------- #

AB_APK_SNAPSHOT_KEEP="${AB_APK_SNAPSHOT_KEEP:-3}"

_packages_snapshot_dir() {
    printf '%s/apk/snapshots' "$1"
}

# _packages_installed: one `name version` line per installed package.
#
# apk prints `name-version` with the version starting at the first dash followed by a
# digit; names themselves carry dashes (kmod-fs-btrfs), so the split cannot be "last
# dash" and cannot be "first dash" either.
_packages_installed() {
    _installed=$(apk info 2>/dev/null) || return 1
    printf '%s\n' "${_installed}" | sed -n 's/^\(.*\)-\([0-9][^-]*\(-r[0-9][^-]*\)\{0,1\}\)$/\1 \2/p'
}

# ab_packages_snapshot <layer> <upstream> <platform>: write one snapshot, print its path.
ab_packages_snapshot() {
    _layer=${1:?ab_packages_snapshot needs a layer}
    _upstream=${2:?ab_packages_snapshot needs the upstream version}
    _platform=${3:?ab_packages_snapshot needs the platform version}
    _dir=$(_packages_snapshot_dir "${_layer}")
    mkdir -p "${_dir}" || return 1

    _id=$(date -u +%Y%m%dT%H%M%SZ)
    _file="${_dir}/snapshot-${_id}.txt"
    _n=1
    while [ -e "${_file}" ]; do
        _n=$((_n + 1))
        _file="${_dir}/snapshot-${_id}-${_n}.txt"
    done

    _packages=$(_packages_installed) || _packages_fail apk-info-failed || return 1
    _pkgnum=$(printf '%s\n' "${_packages}" | grep -c . || true)
    # A world with entries but no readable package list is not an empty machine, it is a
    # broken apk. Writing "0 packages" here would make every later revert a silent no-op.
    if [ "${_pkgnum}" -eq 0 ] && [ -s "${_layer}/upper/etc/apk/world" ]; then
        _packages_fail apk-info-empty
        return 1
    fi

    {
        printf 'AB-APK-SNAPSHOT 1\n'
        printf 'created  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'upstream %s\n' "${_upstream}"
        printf 'platform %s\n' "${_platform}"
        if [ -f "${_layer}/upper/etc/apk/world" ]; then
            while IFS= read -r _entry || [ -n "${_entry}" ]; do
                [ -n "${_entry}" ] || continue
                printf 'world    %s\n' "${_entry}"
            done <"${_layer}/upper/etc/apk/world"
        fi
        printf '%s\n' "${_packages}" | while IFS=' ' read -r _name _version; do
            [ -n "${_name}" ] || continue
            printf 'pkg      %s %s\n' "${_name}" "${_version}"
        done
        printf 'end\n'
    } >"${_file}" || return 1

    _packages_snapshot_reap "${_layer}"
    printf '%s\n' "${_file}"
}

# _packages_snapshot_files <layer>: snapshot files, oldest first.
_packages_snapshot_files() {
    _dir=$(_packages_snapshot_dir "$1")
    [ -d "${_dir}" ] || return 0
    # The id has one-second resolution, so two snapshots in the same second are told apart
    # by a -N suffix. That suffix is the *later* write, which plain `sort` would place
    # first ("-" < "."); the sort key makes the number the last thing compared.
    ls -1 "${_dir}" 2>/dev/null | grep '^snapshot-.*\.txt$' | awk '
        {
            name = $0
            id = name
            sub(/^snapshot-/, "", id)
            sub(/\.txt$/, "", id)
            n = 1
            if (id ~ /-[0-9]+$/) {
                n = id
                sub(/^.*-/, "", n)
                sub(/-[0-9]+$/, "", id)
            }
            printf "%s %06d %s\n", id, n, name
        }' | sort | cut -d' ' -f3
}

_packages_snapshot_reap() {
    _dir=$(_packages_snapshot_dir "$1")
    _files=$(_packages_snapshot_files "$1")
    [ -n "${_files}" ] || return 0
    _count=$(printf '%s\n' "${_files}" | wc -l | tr -d ' ')
    [ "${_count}" -gt "${AB_APK_SNAPSHOT_KEEP}" ] || return 0
    _drop=$((_count - AB_APK_SNAPSHOT_KEEP))
    printf '%s\n' "${_files}" | head -n "${_drop}" | while IFS= read -r _name; do
        rm -f "${_dir}/${_name}" || :
    done
}

# _packages_snapshot_field <file> <key>: one header value, or empty.
_packages_snapshot_field() {
    sed -n "s/^$2  *//p" "$1" 2>/dev/null | head -n 1
}

# ab_packages_list <layer>: the snapshots on this layer, newest first.
ab_packages_list() {
    _layer=${1:?ab_packages_list needs a layer}
    _files=$(_packages_snapshot_files "${_layer}")
    if [ -z "${_files}" ]; then
        printf 'snapshot: no snapshots\n'
        printf '  Next: ab-slot packages snapshot\n'
        return 0
    fi
    _count=$(printf '%s\n' "${_files}" | wc -l | tr -d ' ')
    printf '%s snapshots kept (newest %s retained)\n' "${_count}" "${AB_APK_SNAPSHOT_KEEP}"
    printf '%s\n' "${_files}" | sort -r | while IFS= read -r _name; do
        _path="$(_packages_snapshot_dir "${_layer}")/${_name}"
        _id=${_name#snapshot-}
        _id=${_id%.txt}
        _base=$(_packages_snapshot_field "${_path}" upstream)
        _platform=$(_packages_snapshot_field "${_path}" platform)
        _pkgs=$(grep -c '^pkg ' "${_path}" 2>/dev/null || true)
        printf 'snapshot %s  base %s  platform %s  %s packages\n' \
            "${_id}" "${_base}" "${_platform}" "${_pkgs:-0}"
    done
}
