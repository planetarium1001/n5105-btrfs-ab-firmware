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
# The source is `apk info -v`. Bare `apk info` is deliberately never read: under
# apk-tools 3 (3.0.5 on the measured machine, 2026-11-14) it prints the names only, which
# is how a 317-package machine produced a snapshot of versionless lines. `apk list
# --installed` is the documented fallback, and its first field is the same `name-version`.
#
# The split is "the last dash followed by a digit": names carry dashes
# (kmod-nls-iso8859-1) and versions carry one of their own (-r1), so neither the first nor
# the last dash is right. A line that does not split is a failure, not something to drop:
# returning fewer lines than there were is exactly the silent loss this exists to catch.
#
# Returns 0 with the lines on stdout, 1 when apk cannot answer at all, 2 when a line does
# not split. The lines that did not split (up to three) are named on stderr.
_packages_installed() {
    _raw=""
    if _info=$(apk info -v 2>/dev/null); then
        _raw=${_info}
    fi
    if [ -z "${_raw}" ]; then
        _raw=$(apk list --installed 2>/dev/null | awk 'NF { print $1 }')
    fi
    [ -n "${_raw}" ] || return 1

    _total=$(printf '%s\n' "${_raw}" | grep -c . || true)
    _unparsed=$(printf '%s\n' "${_raw}" | grep . | sed -n '/^\(.*\)-\([0-9].*\)$/!p')
    if [ -n "${_unparsed}" ]; then
        _bad=$(printf '%s\n' "${_unparsed}" | grep -c . || true)
        printf 'packages: %s of %s lines could not be split into name and version\n' \
            "${_bad}" "${_total}" >&2
        printf '%s\n' "${_unparsed}" | head -n 3 | while IFS= read -r _line; do
            printf 'packages: unparsed %s\n' "${_line}" >&2
        done
        return 2
    fi
    printf '%s\n' "${_raw}" | grep . | sed -n 's/^\(.*\)-\([0-9].*\)$/\1 \2/p'
}

# _packages_sha256 <file>: the hex digest of a payload, or empty when no tool can make
# one. The device is busybox (sha256sum); a build host may have shasum or openssl.
_packages_sha256() {
    [ -f "$1" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{ print $1; exit }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{ print $1; exit }'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{ print $NF; exit }'
    else
        return 1
    fi
}

# _packages_payload_file <payload-dir> <name> <version>: the .apk a package was fetched
# as. `apk fetch` names it <name>-<version>.apk; the glob is only a second chance for a
# version apk re-spelled.
_packages_payload_file() {
    if [ -n "${3:-}" ]; then
        _exact="$1/$2-$3.apk"
        if [ -f "${_exact}" ]; then
            printf '%s' "${_exact}"
            return 0
        fi
    fi
    _found=$(find "$1" -maxdepth 1 -name "$2-*.apk" 2>/dev/null | head -n 1)
    [ -n "${_found}" ] || return 1
    printf '%s' "${_found}"
}


# _packages_prune_payloads <payload-dir> <packages>: drop archives that are not the
# installed set's name-version pair. A per-package fetch that hit a rolled feed leaves the
# newer file behind, and the recursive fallback may add another version; the record only
# ever lists the expected files, but a leftover would still be installed by a glob-style
# consumer, so it is removed here.
_packages_prune_payloads() {
    _pr_dir=$1
    for _pr_f in "${_pr_dir}"/*.apk; do
        [ -f "${_pr_f}" ] || continue
        _pr_keep=0
        while IFS=' ' read -r _pr_name _pr_ver; do
            [ -n "${_pr_name}" ] || continue
            if [ "${_pr_f}" = "${_pr_dir}/${_pr_name}-${_pr_ver}.apk" ]; then
                _pr_keep=1
                break
            fi
        done <<PRUNE_LIST
$2
PRUNE_LIST
        [ "${_pr_keep}" = "1" ] || rm -f "${_pr_f}"
    done
}

# ab_packages_payloads_verified <snapshot> <payload-dir>: 0 when the snapshot lists
# payloads, the directory holds them, and every recorded sha256 matches the file; the
# number verified is printed. 1 when there is nothing usable to verify (no payload lines,
# no directory, a file that is not there); 2 when a digest does not match.
#
# The digest list is the whole trust chain for a local .apk: the device reports
# `UNTRUSTED signature` and we do not carry its keyring, so `--allow-untrusted` is only
# safe because the record says what each byte should be.
ab_packages_payloads_verified() {
    _verified_files=$(ab_packages_payload_files "$1" "$2") || return $?
    printf '%s\n' "${_verified_files}" | grep -c .
}

# ab_packages_payload_files <snapshot> <payload-dir>: the .apk paths the snapshot lists and
# whose digest matches, one per line. Same returns as ab_packages_payloads_verified.
#
# The caller installs exactly these paths instead of a glob of the directory: a file that
# apk fetch dropped in but the snapshot does not list was never checked by anything, and
# installing it would put a package on the machine that no record vouches for.
ab_packages_payload_files() {
    _snap=$1
    _pdir=$2
    _apkfiles=$(sed -n 's/^apkfile  *//p' "${_snap}" 2>/dev/null)
    [ -n "${_apkfiles}" ] || return 1
    [ -d "${_pdir}" ] || return 1
    _found=""
    while IFS=' ' read -r _name _sha; do
        [ -n "${_name}" ] || continue
        _file=$(_packages_payload_file "${_pdir}" "${_name}" "") || return 1
        _got=$(_packages_sha256 "${_file}")
        [ -n "${_got}" ] || return 2
        [ "${_got}" = "${_sha}" ] || return 2
        _found="${_found}${_file}
"
    done <<APKFILES
${_apkfiles}
APKFILES
    [ -n "${_found}" ] || return 1
    printf '%s' "${_found}"
}

# _packages_world_report <snapshot>: reconcile the world with the package set. The count
# line goes to stdout (it is a machine-readable fact); the first five world entries that
# have no package in the snapshot go to stderr, because a name apk would have to resolve
# again is exactly what a replay cannot fix on its own.
_packages_world_report() {
    awk '
        /^pkg      / { pkg[$2] = 1; next }
        /^world    / { entry[++n] = substr($0, 10); next }
        END {
            matched = 0
            shown = 0
            for (i = 1; i <= n; i++) {
                key = entry[i]
                sub(/[=<>~].*/, "", key)
                if (key in pkg) {
                    matched++
                } else if (shown < 5) {
                    printf "  world-unmatched  %s\n", key > "/dev/stderr"
                    shown++
                }
            }
            printf "revert world=%d matched=%d\n", n, matched
        }
    ' "$1"
}

# _packages_fetch_per_package <payload-dir> <packages>: fetch every installed package on
# its own, without `--recursive`. The installed set already contains the dependency closure
# (apk installed it), so a recursive solve adds nothing but a reason to fail: it makes apk
# resolve the pinned set against `/etc/apk/world`, and on a freshly flashed machine that
# world is older than the feed, so the solve dies on `world[libopenssl3=...]` and takes
# every payload with it.
#
# The loop stops at the first fetch that fails: one failure is enough to know this route
# does not work here, and a machine whose feed is unreachable must not spend one connection
# attempt per installed package before the caller falls back. Returns 0 when every fetch
# succeeded, 1 otherwise; whether the files actually landed is checked separately.
_packages_fetch_per_package() {
    _pp_dir=$1
    _pp_missing=0
    # apk-tools 3.0.5 rejects a version pin in `apk fetch` ("unable to select package (or
    # its dependencies)" for every `name=version` tried on the device), so the fetch has to
    # name the package only. That still avoids the one-shot `--recursive` world solve, which
    # was the F2 defect. The version is then checked against the installed set: a feed that
    # has rolled since the machine was flashed hands back a newer file, and recording that
    # file would make the snapshot describe a state that never existed. Such a package is
    # dropped and counted as missing; the caller's recursive fallback may still land it, and
    # otherwise the record says payload-incomplete instead of pretending.
    while IFS=' ' read -r _pp_name _pp_ver; do
        [ -n "${_pp_name}" ] || continue
        if ! apk fetch -o "${_pp_dir}" "${_pp_name}" >/dev/null 2>&1; then
            # A fetch that cannot run at all is a feed/network failure: stop here instead of
            # paying a connection timeout for every installed package.
            return 1
        fi
        if [ -f "${_pp_dir}/${_pp_name}-${_pp_ver}.apk" ]; then
            for _pp_f in "${_pp_dir}/${_pp_name}-"*.apk; do
                [ -f "${_pp_f}" ] || continue
                [ "${_pp_f}" = "${_pp_dir}/${_pp_name}-${_pp_ver}.apk" ] || rm -f "${_pp_f}"
            done
        else
            rm -f "${_pp_dir}/${_pp_name}-"*.apk 2>/dev/null || true
            _pp_missing=$((_pp_missing + 1))
        fi
    done <<PACKAGES
$2
PACKAGES
    [ "${_pp_missing}" -eq 0 ]
}

# _packages_payload_record <payload-dir> <apkfile> <packages>: write one
# `apkfile <name> <sha256>` line per package whose archive is present and digestable, print
# how many packages had no usable archive. A file without a digest is a missing payload,
# not a line to write and hope: the digest list is the whole trust chain for a local .apk
# (the device does not carry the feed's keyring), and a revert verifies every line of it.
_packages_payload_record() {
    _pr_dir=$1
    _pr_apkfile=$2
    : >"${_pr_apkfile}"
    _pr_missing=0
    while IFS=' ' read -r _pr_name _pr_ver; do
        [ -n "${_pr_name}" ] || continue
        _pr_sha=""
        if _pr_file=$(_packages_payload_file "${_pr_dir}" "${_pr_name}" "${_pr_ver}"); then
            _pr_sha=$(_packages_sha256 "${_pr_file}")
        fi
        if [ -z "${_pr_sha}" ]; then
            _pr_missing=$((_pr_missing + 1))
            continue
        fi
        printf 'apkfile  %s %s\n' "${_pr_name}" "${_pr_sha}" >>"${_pr_apkfile}"
    done <<PACKAGES
$3
PACKAGES
    printf '%s' "${_pr_missing}"
}

# ab_packages_snapshot <layer> <upstream> <platform> [--no-payloads]: write one snapshot,
# print its path.
#
# The payloads are fetched by default, because on the measured machine the feed carries
# only the newest version (`apk policy htop` -> 3.5.3-r1 while the machine runs 3.3.0-r1),
# so a manifest without the files cannot be replayed once anything moved. A failed or
# partial fetch is recorded as `payloads no` plus one `payload-gap <reason>` line, and the
# manifest still succeeds: the record of what this machine runs is the main deliverable,
# the files are the part that needs a network.
#
# The fetch has two stages. Stage one is _packages_fetch_per_package above: no solver, one
# package per call. Stage two is the historical one-shot `apk fetch --recursive`, kept as a
# fallback for whatever stage one cannot fetch (a package a re-spelled feed answers to, an
# apk that disagrees about `name=version` on the command line). Either stage is judged by
# the files and digests on disk, never by the fetch command's exit status; a set that does
# not cover every installed package is a `payload-gap`, and its directory is removed.
ab_packages_snapshot() {
    _layer=${1:?ab_packages_snapshot needs a layer}
    _upstream=${2:?ab_packages_snapshot needs the upstream version}
    _platform=${3:?ab_packages_snapshot needs the platform version}
    shift 3
    _want_payloads=1
    for _arg in "$@"; do
        case "${_arg}" in
            --no-payloads) _want_payloads=0 ;;
            *)
                _packages_fail "snapshot-argument-invalid"
                return 1
                ;;
        esac
    done

    _dir=$(_packages_snapshot_dir "${_layer}")
    mkdir -p "${_dir}" || return 1

    _id=$(date -u +%Y%m%dT%H%M%SZ)
    _file="${_dir}/snapshot-${_id}.txt"
    # The id has one-second resolution; two snapshots in the same second are told apart by
    # a -N suffix. Reusing the bare name after its predecessor was reaped would make a
    # *new* snapshot sort before the -N files that are actually older, and the retention
    # pass would delete it. So once any file exists for this id, the next one is
    # max(+N)+1, never the bare name again.
    if [ -e "${_file}" ] || ls "${_dir}/snapshot-${_id}-"*.txt >/dev/null 2>&1; then
        _max=0
        for _f in "${_dir}/snapshot-${_id}.txt" "${_dir}/snapshot-${_id}-"*.txt; do
            [ -e "${_f}" ] || continue
            _b=${_f##*/}
            _b=${_b%.txt}
            _b=${_b##*-}
            case "${_b}" in
                '' | *[!0-9]*) _s=1 ;;
                *) _s=${_b} ;;
            esac
            [ "${_s}" -gt "${_max}" ] && _max=${_s}
        done
        _n=$((_max + 1))
        _file="${_dir}/snapshot-${_id}-${_n}.txt"
    fi
    # The payload directory is named after the snapshot, not after the id: a same-second
    # second snapshot is `-2` and needs its own .d, or two records would share a payload
    # set that only one of them describes.
    _sid=${_file##*/snapshot-}
    _sid=${_sid%.txt}
    _snapdir="${_dir}/snapshot-${_sid}.d"
    _pdir="${_snapdir}/payloads"

    _packages=$(_packages_installed)
    _prc=$?
    if [ "${_prc}" -ne 0 ]; then
        case "${_prc}" in
            2) _packages_fail "apk-info-unparsed" ;;
            *) _packages_fail "apk-info-failed" ;;
        esac
        return 1
    fi
    _pkgnum=$(printf '%s\n' "${_packages}" | grep -c . || true)
    # The world of an image-stage system lives in @sys, not in the writable layer: the
    # first boot of a flashed image has an empty upper. Falling back to the merged view
    # keeps `world=N` honest there; a payload slot always has its own file in upper.
    _worldfile="${_layer}/upper/etc/apk/world"
    [ -f "${_worldfile}" ] || _worldfile=/etc/apk/world
    # A world with entries but no readable package list is not an empty machine, it is a
    # broken apk. Writing "0 packages" here would make every later revert a silent no-op.
    if [ "${_pkgnum}" -eq 0 ] && [ -s "${_worldfile}" ]; then
        _packages_fail "apk-info-empty"
        return 1
    fi
    _worldnum=0
    if [ -f "${_worldfile}" ]; then
        _worldnum=$(grep -c . "${_worldfile}" || true)
    fi

    _payloads_written=0
    _payload_gap=""
    _apkfiles=""
    if [ "${_want_payloads}" = "1" ] && [ "${_pkgnum}" -gt 0 ]; then
        _apkfiles="${_snapdir}/apkfile"
        if mkdir -p "${_pdir}" 2>/dev/null; then
            # Stage one: no --recursive, no world solve. The installed set is the closure.
            _packages_fetch_per_package "${_pdir}" "${_packages}" || true
            _missing=$(_packages_payload_record "${_pdir}" "${_apkfiles}" "${_packages}")
            _fallback_failed=0
            if [ "${_missing}" != "0" ]; then
                # Stage two: the historical one-shot fetch, for the machines where fetching
                # pins one at a time does not land every file. It may hit the same world
                # solve, which is why it is no longer the only attempt.
                printf 'packages: payload fetch fell back to --recursive (per-package fetch incomplete)\n' >&2
                _pins=$(printf '%s\n' "${_packages}" | awk '{ print $1 "=" $2 }')
                # shellcheck disable=SC2086  # one word per pin by construction
                if apk fetch --recursive -o "${_pdir}" ${_pins} >/dev/null 2>&1; then
                    _packages_prune_payloads "${_pdir}" "${_packages}"
                    _missing=$(_packages_payload_record "${_pdir}" "${_apkfiles}" "${_packages}")
                else
                    _fallback_failed=1
                fi
            fi
            if [ "${_missing}" = "0" ]; then
                _payloads_written=1
            elif [ "${_fallback_failed}" = "1" ]; then
                # A feed that cannot be reached and a disk that filled up look the same
                # from here, and either way the manifest is still worth writing.
                _payload_gap="apk-fetch-failed"
            else
                # Both fetch routes answered and the set is still short. Naming it
                # incomplete keeps the reason stable for a reader; nothing is claimed.
                _payload_gap="payload-incomplete"
            fi
        else
            _payload_gap="payloads-unwritable"
        fi
        if [ "${_payloads_written}" = "0" ]; then
            # Nothing half-populated is left behind: a directory that exists but does not
            # verify would send a later revert down the local path with a broken set.
            rm -rf "${_snapdir}" 2>/dev/null || true
            _apkfiles=""
        fi
    fi

    {
        printf 'AB-APK-SNAPSHOT 1\n'
        printf 'created  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'upstream %s\n' "${_upstream}"
        printf 'platform %s\n' "${_platform}"
        printf 'packages %s\n' "${_pkgnum}"
        printf 'world %s\n' "${_worldnum}"
        if [ "${_payloads_written}" = "1" ]; then
            printf 'payloads yes\n'
        else
            printf 'payloads no\n'
        fi
        if [ -n "${_payload_gap}" ]; then
            printf 'payload-gap %s\n' "${_payload_gap}"
        fi
        if [ -f "${_worldfile}" ]; then
            while IFS= read -r _entry || [ -n "${_entry}" ]; do
                [ -n "${_entry}" ] || continue
                printf 'world    %s\n' "${_entry}"
            done <"${_worldfile}"
        fi
        printf '%s\n' "${_packages}" | while IFS=' ' read -r _name _version; do
            [ -n "${_name}" ] || continue
            printf 'pkg      %s %s\n' "${_name}" "${_version}"
        done
        if [ "${_payloads_written}" = "1" ] && [ -f "${_apkfiles}" ]; then
            cat "${_apkfiles}"
        fi
        printf 'end\n'
    } >"${_file}" || {
        rm -rf "${_snapdir}" 2>/dev/null || true
        rm -f "${_file}" 2>/dev/null || true
        _packages_fail "snapshot-unwritable"
        return 1
    }
    # The record is what a later revert trusts; the payload files are worth several hundred
    # megabytes and may still be in flight through the page cache.
    sync 2>/dev/null || true
    if [ -n "${_apkfiles}" ]; then
        rm -f "${_apkfiles}" 2>/dev/null || true
    fi
    if [ -n "${_payload_gap}" ]; then
        printf 'packages: payload-gap %s\n' "${_payload_gap}" >&2
    fi

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
    find "${_dir}" -maxdepth 1 -name 'snapshot-*.txt' 2>/dev/null \
        | sed 's#^.*/##' | awk '
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
        # The payloads belong to exactly one manifest: reaping the text without the .d
        # would leave up to 300 MiB of files nothing on the machine can name.
        rm -rf "${_dir}/${_name%.txt}.d" || :
    done
}

# _packages_snapshot_field <file> <key>: one header value, or empty.
_packages_snapshot_field() {
    sed -n "s/^$2  *//p" "$1" 2>/dev/null | head -n 1
}

# _packages_snapshot_count <file> <key>: a header count. The counts are read by pattern
# rather than with _packages_snapshot_field because `world 3` and the `world    <entry>`
# lines differ by one space: reading a snapshot written before the counts existed must not
# return the first entry as if it were a number.
_packages_snapshot_count() {
    sed -n "s/^$2 \([0-9][0-9]*\)\$/\\1/p" "$1" 2>/dev/null | head -n 1
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
        # A count that is not there is not a zero. A file this listing cannot read, or one
        # written before the header carried the counts, says nothing about how many packages
        # or world entries it holds; `${_pkgs:-0}` printed `0` for both, which is the one
        # answer a reader must never be given by accident. `0` is only what a readable
        # record with no such entry reports.
        # A readable regular file is the precondition for any count: busybox `grep -c`
        # answers 0 for a directory, so a corrupted record that happens to be one would read
        # as an empty snapshot. Measured on the device, 2026-11-16.
        if [ -f "${_path}" ] && [ -r "${_path}" ]; then
            _pkgs=$(grep -c '^pkg ' "${_path}" 2>/dev/null || true)
            _world=$(_packages_snapshot_count "${_path}" world)
        else
            _pkgs=""
            _world=""
        fi
        case "${_pkgs}" in
            '' | *[!0-9]*) _pkgs=unreadable ;;
        esac
        case "${_world}" in
            '' | *[!0-9]*) _world=unreadable ;;
        esac
        _payloads=$(_packages_snapshot_field "${_path}" payloads)
        printf 'snapshot %s  base %s  platform %s  %s packages  world %s  payloads %s\n' \
            "${_id}" "${_base}" "${_platform}" "${_pkgs}" "${_world}" "${_payloads:-no}"
    done
}
