#!/bin/sh
# ab-version.sh - compare release versions, for the update prompt and nothing else.
#
# An update is described by three numbers, and none of them may be inferred from
# another (see docs/update.md):
#
#   base      the upstream ImmortalWrt release, "25.12.2". The rootfs and the kernel
#             come from it, so it is the number that decides how risky an update is.
#   kernel    the kernel package version, "6.12.103". It usually moves with the base
#             and sometimes does not, which is exactly why it is read from the index
#             instead of being derived from the base delta.
#   platform  this project's own layer, "0.0.8" (PLATFORM_VERSION). It counts our
#             releases on a given base and says nothing about the system underneath.
#
# The level is a statement about *test coverage*, not about the size of the change:
#
#   X1  a different major        nothing here crosses a major line
#   Y2  more than one minor      those releases are not built together
#   Y1  exactly one minor        neighbouring lines are built together
#   Z2  more than three patches  outside the covered range
#   Z1  up to three patches      covered by CI
#
# Two more answers are not levels at all and are kept apart so callers cannot
# accidentally treat "nothing to do" as "an update": `current` and `downgrade`.
#
# Functions (all POSIX sh, no external commands):
#   ab_version_valid <v>             0 when <v> is X.Y.Z, 1 otherwise
#   ab_version_cmp <a> <b>           prints -1, 0 or 1; exits 2 on a malformed version
#   ab_version_delta <a> <b>         prints "major N", "minor N", "patch N" or "none"
#   ab_version_level <a> <b>         prints X1|Y2|Y1|Z2|Z1, or current|downgrade
#
# The comparison is numeric per segment on purpose: a string comparison would sort
# 0.0.10 before 0.0.9 and make the updater offer a downgrade as an update.

# _ab_version_digits <v>: the value with leading zeroes stripped, so that `[ -lt ]`
# and `$(( ))` stay decimal instead of reading 010 as octal.
_ab_version_digits() {
    _av=${1:-}
    while :; do
        case "${_av}" in
            0?*) _av=${_av#0} ;;
            *) break ;;
        esac
    done
    [ -n "${_av}" ] || _av=0
    printf '%s' "${_av}"
}

ab_version_valid() {
    _v=${1:-}
    [ -n "${_v}" ] || return 1
    case "${_v}" in
        *[!0-9.]*) return 1 ;;
    esac
    case "${_v}" in
        *.*.*) ;;
        *) return 1 ;;
    esac
    _vmaj=${_v%%.*}
    _vrest=${_v#*.}
    _vmin=${_vrest%%.*}
    _vpat=${_vrest#*.}
    [ -n "${_vmaj}" ] || return 1
    [ -n "${_vmin}" ] || return 1
    [ -n "${_vpat}" ] || return 1
    case "${_vmaj}${_vmin}${_vpat}" in
        *[!0-9]*) return 1 ;;
    esac
    if [ "${_v}" != "${_vmaj}.${_vmin}.${_vpat}" ]; then
        # More than three segments, e.g. 1.2.3.4.
        return 1
    fi
    return 0
}

# _ab_version_split <v>: sets AB_MAJOR, AB_MINOR, AB_PATCH. The caller has already
# validated <v>; this only exists so the three callers below do not repeat the parsing.
_ab_version_split() {
    _sv=${1}
    AB_MAJOR=$(_ab_version_digits "${_sv%%.*}")
    _srest=${_sv#*.}
    AB_MINOR=$(_ab_version_digits "${_srest%%.*}")
    AB_PATCH=$(_ab_version_digits "${_srest#*.}")
}

ab_version_cmp() {
    ab_version_valid "${1:-}" || return 2
    ab_version_valid "${2:-}" || return 2
    _ab_version_split "${1}"
    _am=${AB_MAJOR} _an=${AB_MINOR} _ap=${AB_PATCH}
    _ab_version_split "${2}"
    _bm=${AB_MAJOR} _bn=${AB_MINOR} _bp=${AB_PATCH}

    if [ "${_am}" -lt "${_bm}" ]; then
        printf '%s\n' -1
        return 0
    fi
    if [ "${_am}" -gt "${_bm}" ]; then
        printf '%s\n' 1
        return 0
    fi
    if [ "${_an}" -lt "${_bn}" ]; then
        printf '%s\n' -1
        return 0
    fi
    if [ "${_an}" -gt "${_bn}" ]; then
        printf '%s\n' 1
        return 0
    fi
    if [ "${_ap}" -lt "${_bp}" ]; then
        printf '%s\n' -1
        return 0
    fi
    if [ "${_ap}" -gt "${_bp}" ]; then
        printf '%s\n' 1
        return 0
    fi
    printf '%s\n' 0
}

ab_version_delta() {
    ab_version_valid "${1:-}" || return 2
    ab_version_valid "${2:-}" || return 2
    _ab_version_split "${1}"
    _am=${AB_MAJOR} _an=${AB_MINOR} _ap=${AB_PATCH}
    _ab_version_split "${2}"
    _bm=${AB_MAJOR} _bn=${AB_MINOR} _bp=${AB_PATCH}

    if [ "${_am}" -ne "${_bm}" ]; then
        printf 'major %s\n' "$((_bm - _am))"
        return 0
    fi
    if [ "${_an}" -ne "${_bn}" ]; then
        printf 'minor %s\n' "$((_bn - _an))"
        return 0
    fi
    if [ "${_ap}" -ne "${_bp}" ]; then
        printf 'patch %s\n' "$((_bp - _ap))"
        return 0
    fi
    printf 'none\n'
}

# ab_version_level <installed-base> <available-base>: the tier the prompt uses.
# Only the base version is passed here: the kernel and platform numbers are shown to
# the user but never decide the level.
ab_version_level() {
    ab_version_valid "${1:-}" || return 2
    ab_version_valid "${2:-}" || return 2
    # cmp <installed> <available>: -1 means the candidate is newer, 1 means it is older.
    _cmp=$(ab_version_cmp "${1}" "${2}")
    if [ "${_cmp}" -gt 0 ]; then
        printf 'downgrade\n'
        return 0
    fi
    if [ "${_cmp}" -eq 0 ]; then
        printf 'current\n'
        return 0
    fi

    _ab_version_split "${1}"
    _am=${AB_MAJOR} _an=${AB_MINOR} _ap=${AB_PATCH}
    _ab_version_split "${2}"
    _bm=${AB_MAJOR} _bn=${AB_MINOR} _bp=${AB_PATCH}

    if [ "${_am}" -ne "${_bm}" ]; then
        printf 'X1\n'
        return 0
    fi
    _dm=$((_bn - _an))
    if [ "${_dm}" -gt 1 ]; then
        printf 'Y2\n'
        return 0
    fi
    if [ "${_dm}" -eq 1 ]; then
        printf 'Y1\n'
        return 0
    fi
    _dp=$((_bp - _ap))
    if [ "${_dp}" -gt 3 ]; then
        printf 'Z2\n'
        return 0
    fi
    printf 'Z1\n'
}
