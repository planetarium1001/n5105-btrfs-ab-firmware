#!/bin/sh
# ab-pkgs-assets.sh - the package bodies no source carries, kept where a replay can find them.
#
# A follow (platform/lib/upgrade/packages.sh) asks the feeds for every world entry, so a
# package that came from a feed follows the base by itself. A package installed from a local
# `.apk` file has no source: apk records that it is installed and never where it came from,
# and the body is gone the moment the transaction ends. Measured on the device 2026-11-18:
# `find / -name '*.apk'` is empty after installing four local packages, because `/var` is a
# tmpfs and the default package cache (`/var/cache/apk`) dies with the boot. Such a package
# cannot be replayed, and the record says `skipped=local:<name>` - "kept installed, no body".
#
# This library is the other half of that answer: a place to keep the body, on the writable
# layer next to `world` and the apk database, so it rides the generation snapshot and needs
# no new subvolume, no initramfs change and nothing on /data (design.md §10).
#
#   <root>/etc/apk/ab/local/<name>-<version>.apk   kept bodies (long term)
#   <root>/etc/apk/ab/cache/*.apk                  one follow's downloads (consumed)
#   <root>/etc/apk/ab/local/superseded             the bodies a feed took back over
#
# The flat `<name>-<version>.apk` naming is not a style choice: `_packages_gate_local` finds a
# kept body with `ls <assets>/<name>-*.apk`, so the file name *is* the interface between the
# gate and this store, and it is the same `<name>-<pkgver>-r<rev>.apk` shape `apk fetch`
# writes. `ab_pkgs_asset_split` reads it back, and only bodies that follow it are stored: a
# file this library cannot name is refused instead of being filed under a guessed name.
#
# Four rules, and each one is a decision:
#
#   * one body per name - the highest version. Two versions of one package are two worlds,
#     and the gate's `ls <name>-*.apk` must not have to choose.
#   * a body whose name a feed starts offering is `superseded`: the feed is now the better
#     source (it is signed, it follows the base, it is maintained), so the body is recorded in
#     the journal and deleted. Deleting it is what turns "the user keeps a stale copy for
#     ever" into a fact somebody can read.
#   * the store is bounded by AB_PKGS_CACHE_MAX (default 256 MiB). Over the bound, the
#     oldest bodies that are not the installed version go first: a body the machine runs is
#     the one replay would want.
#   * replay is `apk add --allow-untrusted <body>` on the running root and nothing else. apk's
#     own protected paths turn a `/etc/config/*` the user edited into `*.apk-new`, so the
#     user's file survives; measured 2026-11-18 on the device (`apk upgrade dnsmasq-full`
#     kept an edited `/etc/config/dhcp` byte for byte and wrote `dhcp.apk-new`).
#
# Nothing here runs a transaction except `ab_pkgs_assets_replay`, nothing writes outside
# `<root>/etc/apk/ab/`, and no command needs a network: `apk policy`, `apk version -t` and
# `apk add <file>` all answer from what is already on the disk.
#
# Interface (all POSIX sh, callers may run under `set -u`):
#   ab_pkgs_assets_dir <root>                    the kept-body directory for <root>
#   ab_pkgs_cache_dir <root>                     the follow cache directory for <root>
#   ab_pkgs_asset_split <path>                   `name version` from an apk file name; 1 if it
#                                                does not follow apk's naming
#   ab_pkgs_asset_identify <path>                `name version` from the file name, else from
#                                                the package's own `.PKGINFO`
#   ab_pkgs_assets_list <root>                   `name version path bytes`, one body per line
#   ab_pkgs_assets_bytes <root>                  bytes of every kept body
#   ab_pkgs_assets_highest <root> <name>         path of the highest kept version; 1 none,
#                                                2 cannot be ordered
#   ab_pkgs_policy_sources <root> <name>         one source per line: `installed` or a feed URL
#   ab_pkgs_assets_capture <root> <file>...      keep the body; sets _CAPTURED/_REASON/_STATE
#   ab_pkgs_assets_superseded <root>             journal then delete bodies a feed offers
#   ab_pkgs_assets_prune <root>                  one version per name, then the quota
#   ab_pkgs_assets_maintain <root>               superseded + prune, in that order
#   ab_pkgs_assets_replay <root> [<name>...]     `apk add --allow-untrusted` per body
#   ab_pkgs_assets_report <root>                 `assets=<n> assets-bytes=<n> superseded=<n>`
#   ab_pkgs_cache_report <root>                  the same facts for the cache directory
#   ab_pkgs_cache_clean <root>                   empty the cache, keep the kept bodies
#
# Every outcome is reported as a token a caller can print, never as prose it has to parse:
# a store that could not be read must not look like an empty one.

# 256 MiB, in bytes. Written out because `256M` is a unit this shell cannot compare.
AB_PKGS_CACHE_MAX="${AB_PKGS_CACHE_MAX:-268435456}"
# The one name apk gives the source of a package that only the installed database knows.
AB_PKGS_ASSET_SUBDIR="etc/apk/ab/local"
AB_PKGS_CACHE_SUBDIR="etc/apk/ab/cache"
AB_PKGS_SUPERSEDED_FILE="superseded"

# Read by the caller.
# shellcheck disable=SC2034
AB_PKGS_ASSETS_STATE=""
# shellcheck disable=SC2034
AB_PKGS_ASSETS_REASON=""
# shellcheck disable=SC2034
AB_PKGS_ASSETS_CAPTURED=""
# shellcheck disable=SC2034
AB_PKGS_ASSETS_PRUNED=""
# shellcheck disable=SC2034
AB_PKGS_ASSETS_SUPERSEDED=""
# shellcheck disable=SC2034
AB_PKGS_ASSETS_BYTES=0
# shellcheck disable=SC2034
AB_PKGS_REPLAY_STATE=""
# shellcheck disable=SC2034
AB_PKGS_REPLAY_OK=0
# shellcheck disable=SC2034
AB_PKGS_REPLAY_UNCHANGED=0
# shellcheck disable=SC2034
AB_PKGS_REPLAY_FAILED=0

# _ab_pkgs_root <root>: the prefix paths are built from, empty for `/`.
#
# `--root /` would make apk treat the running system as a sandbox, so the running root is
# spelled as no prefix at all and a fixture tree is spelled as its own path. One spelling,
# decided here instead of in every caller.
_ab_pkgs_root() {
    _apr_root=${1:-/}
    while [ "${#_apr_root}" -gt 1 ] && [ "${_apr_root%/}" != "${_apr_root}" ]; do
        _apr_root=${_apr_root%/}
    done
    [ "${_apr_root}" = "/" ] && _apr_root=""
    printf '%s' "${_apr_root}"
}

# ab_pkgs_assets_dir <root>: where kept bodies live. Always under the root being judged or
# repaired: a fixture tree must not file a body into the machine running the test.
ab_pkgs_assets_dir() {
    printf '%s/%s' "$(_ab_pkgs_root "${1:-/}")" "${AB_PKGS_ASSET_SUBDIR}"
}

ab_pkgs_cache_dir() {
    printf '%s/%s' "$(_ab_pkgs_root "${1:-/}")" "${AB_PKGS_CACHE_SUBDIR}"
}

_ab_pkgs_superseded_path() {
    printf '%s/%s' "$(ab_pkgs_assets_dir "${1:-/}")" "${AB_PKGS_SUPERSEDED_FILE}"
}

# _ab_pkgs_apk <root> <apk arguments...>: one apk command bound to <root>. Returns 127 when
# there is no apk at all, which every caller reports as its own token instead of as a failure
# of the package it asked about.
_ab_pkgs_apk() {
    _ap_root=$1
    shift
    command -v apk >/dev/null 2>&1 || return 127
    if [ -z "${_ap_root}" ]; then
        apk "$@"
    else
        apk --root "${_ap_root}" "$@"
    fi
}

# _ab_pkgs_file_bytes <file>: the size, from the file itself. `du` answers in blocks (the
# busybox one in KiB) and the number has to be comparable with AB_PKGS_CACHE_MAX.
_ab_pkgs_file_bytes() {
    _afb_size=$(wc -c <"$1" 2>/dev/null | tr -d ' ')
    case "${_afb_size}" in
        '' | *[!0-9]*) _afb_size=0 ;;
    esac
    printf '%s' "${_afb_size}"
}

# _ab_pkgs_mtime <file>: seconds since the epoch. Both spellings are tried because the tests
# run on a laptop (BSD `stat -f`) and the image runs busybox (`stat -c`); an answer of 0 means
# "older than everything we can measure", which is the safe direction for a quota.
_ab_pkgs_mtime() {
    _amt=$(stat -c %Y "$1" 2>/dev/null) || _amt=$(stat -f %m "$1" 2>/dev/null) || _amt=""
    case "${_amt}" in
        '' | *[!0-9]*) _amt=0 ;;
    esac
    printf '%s' "${_amt}"
}

# _ab_pkgs_asset_files <dir>: every body in a directory, one absolute-ish path per line.
_ab_pkgs_asset_files() {
    [ -d "$1" ] || return 0
    for _aaf in "$1"/*.apk; do
        [ -f "${_aaf}" ] || continue
        printf '%s\n' "${_aaf}"
    done
}

# ab_pkgs_asset_split <path|basename>: `name version` from apk's own archive name.
#
# apk versions may not contain a `-` (it separates the version from the revision), so the last
# two dashes are unambiguous: `foo-bar-1.2.3-r1.apk` -> name `foo-bar`, version `1.2.3-r1`.
# A version always starts with a digit, which is what keeps a body named `foo-bar.apk` (no
# version at all) from being split into `foo` + `bar`.
ab_pkgs_asset_split() {
    _as_stem=${1##*/}
    _as_stem=${_as_stem%.apk}
    _as_rev=${_as_stem##*-}
    case "${_as_rev}" in
        r?*) ;;
        *) return 1 ;;
    esac
    _as_num=${_as_rev#r}
    case "${_as_num}" in
        '' | *[!0-9]*) return 1 ;;
    esac
    _as_rest=${_as_stem%-*}
    [ "${_as_rest}" = "${_as_stem}" ] && return 1
    _as_ver=${_as_rest##*-}
    case "${_as_ver}" in
        [0-9]*) ;;
        *) return 1 ;;
    esac
    _as_name=${_as_rest%-*}
    [ -n "${_as_name}" ] || return 1
    printf '%s %s\n' "${_as_name}" "${_as_ver}-${_as_rev}"
}

# _ab_pkgs_pkginfo <file>: `name version` from the package's own `.PKGINFO`.
#
# apk v2 packages are a tar archive whose first member is `.PKGINFO` (`pkgname = `, `pkgver =
# `). Both member spellings are tried because an archive built by hand may or may not carry
# the leading `./`. This is only a fallback for a file that was renamed: a package in apk's
# own naming never needs it, and a package this cannot read is refused rather than guessed at.
_ab_pkgs_pkginfo() {
    _apk_info=$(tar -xzOf "$1" .PKGINFO 2>/dev/null) \
        || _apk_info=$(tar -xzOf "$1" ./.PKGINFO 2>/dev/null) \
        || return 1
    _apk_name=$(printf '%s\n' "${_apk_info}" | sed -n 's/^pkgname[ ]*=[ ]*//p' | head -n 1)
    _apk_ver=$(printf '%s\n' "${_apk_info}" | sed -n 's/^pkgver[ ]*=[ ]*//p' | head -n 1)
    [ -n "${_apk_name}" ] || return 1
    # A version starts with a digit and may carry any suffix apk allows (`1.2.3-r1`, `1.3_rc1`),
    # so only the first character is a shape this file can insist on.
    case "${_apk_ver}" in
        [0-9]*) ;;
        *) return 1 ;;
    esac
    printf '%s %s\n' "${_apk_name}" "${_apk_ver}"
}

ab_pkgs_asset_identify() {
    [ -f "$1" ] || return 1
    ab_pkgs_asset_split "$1" && return 0
    _ab_pkgs_pkginfo "$1"
}

# _ab_pkgs_version_cmp <root> <a> <b>: prints -1, 0 or 1. The ordering is apk's own, asked of
# `apk version -t`: apk versions have pre-release and revision suffixes (`1.2-r2`, `1.3_rc1`)
# that no numeric comparison here could order without re-implementing apk's rules. Without apk
# the question has no answer and this fails, rather than ordering two versions wrongly.
_ab_pkgs_version_cmp() {
    _vc_root=$1
    _vc_a=$2
    _vc_b=$3
    _vc_out=$(_ab_pkgs_apk "${_vc_root}" version -t "${_vc_a}" "${_vc_b}" 2>/dev/null) || return 1
    _vc_out=$(printf '%s' "${_vc_out}" | tr -d ' \t\n')
    case "${_vc_out}" in
        '<' | -lt) printf '%s' -1 ;;
        '=' | -eq) printf '%s' 0 ;;
        '>' | -gt) printf '%s' 1 ;;
        *) return 1 ;;
    esac
}

# ab_pkgs_assets_list <root>: `name version path bytes` for every kept body, one per line.
# A file this library cannot name is left out of the listing on purpose: reporting it as a
# body of some name would make the gate believe a replay is possible that is not.
ab_pkgs_assets_list() {
    _al_dir=$(ab_pkgs_assets_dir "${1:-/}")
    [ -d "${_al_dir}" ] || return 0
    while IFS= read -r _al_file; do
        [ -n "${_al_file}" ] || continue
        _al_id=$(ab_pkgs_asset_identify "${_al_file}") || continue
        _al_name=${_al_id%% *}
        _al_ver=${_al_id#* }
        printf '%s %s %s %s\n' "${_al_name}" "${_al_ver}" "${_al_file}" \
            "$(_ab_pkgs_file_bytes "${_al_file}")"
    done <<FILES
$(_ab_pkgs_asset_files "${_al_dir}")
FILES
}

ab_pkgs_assets_bytes() {
    _ab_total=0
    while IFS=' ' read -r _ab_name _ab_ver _ab_path _ab_size; do
        [ -n "${_ab_name}" ] || continue
        case "${_ab_size}" in
            '' | *[!0-9]*) continue ;;
        esac
        _ab_total=$((_ab_total + _ab_size))
    done <<LIST
$(ab_pkgs_assets_list "${1:-/}")
LIST
    printf '%s' "${_ab_total}"
}

# ab_pkgs_assets_highest <root> <name>: the highest kept version of one package.
#
# Returns 1 when there is none and 2 when apk could not order them, which are different
# answers: "nothing kept" is a gap to report, "cannot order" is a machine whose apk is
# missing or broken and whose store must be left alone.
ab_pkgs_assets_highest() {
    _ah_root=${1:-/}
    _ah_name=$2
    _ah_best=""
    _ah_best_ver=""
    while IFS=' ' read -r _ah_n _ah_v _ah_p _ah_b; do
        [ "${_ah_n}" = "${_ah_name}" ] || continue
        if [ -z "${_ah_best}" ]; then
            _ah_best=${_ah_p}
            _ah_best_ver=${_ah_v}
            continue
        fi
        _ah_cmp=$(_ab_pkgs_version_cmp "${_ah_root}" "${_ah_v}" "${_ah_best_ver}") || return 2
        if [ "${_ah_cmp}" = "1" ]; then
            _ah_best=${_ah_p}
            _ah_best_ver=${_ah_v}
        fi
    done <<LIST
$(ab_pkgs_assets_list "${_ah_root}")
LIST
    [ -n "${_ah_best}" ] || return 1
    printf '%s\n' "${_ah_best}"
}

# _ab_pkgs_installed_version <root> <name>: the version this machine has installed, read from
# apk's own database. Asked of the database rather than of `apk info` so that the question
# answers in a fixture tree and needs no apk binary.
_ab_pkgs_installed_version() {
    _iv_db="$(_ab_pkgs_root "$1")/lib/apk/db/installed"
    [ -f "${_iv_db}" ] || return 1
    awk -v want="$2" '
        /^P:/ { pkg = substr($0, 3); next }
        pkg == want && /^V:/ { print substr($0, 3); exit }
    ' "${_iv_db}" 2>/dev/null
}

# ab_pkgs_policy_sources <root> <name>: every source that offers <name>, one per line.
#
# `apk policy` is the only authority on this and it is the same question the gate's L
# proposition asks: an answer whose only source is `lib/apk/db/installed` is a local package,
# and a body for it is worth keeping. Header lines (they end in `:`) are not sources, and an
# empty answer is not "local" - it is an answer this library cannot read, so it returns 1.
ab_pkgs_policy_sources() {
    _ps_root=${1:-/}
    _ps_name=$2
    _ps_out=$(_ab_pkgs_apk "${_ps_root}" policy "${_ps_name}" 2>/dev/null) || return 1
    _ps_src=$(printf '%s\n' "${_ps_out}" | sed 's/^[ \t]*//' | grep -v '^$' | grep -v ':$')
    [ -n "${_ps_src}" ] || return 1
    printf '%s\n' "${_ps_src}"
}

# _ab_pkgs_feed_kind <root> <url>: which feed list a URL came from. The two files the platform
# writes are named, so an attribution can say `customfeeds` rather than hiding behind "a feed":
# the difference is the user's own source and the one that follows the release.
_ab_pkgs_feed_kind() {
    _fk_root=$1
    _fk_url=$2
    _fk_dir="$(_ab_pkgs_root "${_fk_root}")/etc/apk/repositories.d"
    for _fk_file in "${_fk_dir}/distfeeds.list" "${_fk_dir}/customfeeds.list"; do
        [ -f "${_fk_file}" ] || continue
        if grep -qxF "${_fk_url}" "${_fk_file}" 2>/dev/null; then
            _fk_base=${_fk_file##*/}
            printf '%s' "${_fk_base%.list}"
            return 0
        fi
    done
    printf 'feed'
}

# ab_pkgs_assets_capture <root> <file>...: keep the bodies of local packages.
#
# This is the moment a body is kept: apk itself keeps nothing (measured: `/var` is a tmpfs and
# the default cache dies with the boot), so the body is copied here while it still exists. A
# body whose name cannot be read is refused with `reason=asset-unidentified` instead of being
# filed under a guess, and a body that is already kept byte for byte is left alone.
ab_pkgs_assets_capture() {
    _ac_root=${1:?ab_pkgs_assets_capture needs a root}
    shift
    AB_PKGS_ASSETS_CAPTURED=""
    AB_PKGS_ASSETS_REASON=""
    AB_PKGS_ASSETS_STATE=""
    _ac_dir=$(ab_pkgs_assets_dir "${_ac_root}")
    _ac_kept=0
    for _ac_file in "$@"; do
        if [ ! -f "${_ac_file}" ] || [ ! -s "${_ac_file}" ]; then
            AB_PKGS_ASSETS_REASON="asset-missing"
            continue
        fi
        if ! _ac_id=$(ab_pkgs_asset_identify "${_ac_file}"); then
            AB_PKGS_ASSETS_REASON="asset-unidentified"
            continue
        fi
        _ac_name=${_ac_id%% *}
        _ac_ver=${_ac_id#* }
        if ! mkdir -p "${_ac_dir}" 2>/dev/null; then
            AB_PKGS_ASSETS_STATE="failed"
            AB_PKGS_ASSETS_REASON="assets-unwritable"
            return 1
        fi
        _ac_dest="${_ac_dir}/${_ac_name}-${_ac_ver}.apk"
        # The copy is written beside its destination and renamed: a power cut leaves the store
        # with the old body or the new one, never half of either.
        if [ -f "${_ac_dest}" ] \
            && [ "$(_ab_pkgs_file_bytes "${_ac_dest}")" = "$(_ab_pkgs_file_bytes "${_ac_file}")" ]; then
            AB_PKGS_ASSETS_CAPTURED="${AB_PKGS_ASSETS_CAPTURED} ${_ac_name}-${_ac_ver}"
            _ac_kept=$((_ac_kept + 1))
            continue
        fi
        _ac_tmp="${_ac_dest}.tmp.$$"
        if ! cp "${_ac_file}" "${_ac_tmp}" 2>/dev/null; then
            AB_PKGS_ASSETS_REASON="assets-unwritable"
            continue
        fi
        sync 2>/dev/null || :
        if ! mv "${_ac_tmp}" "${_ac_dest}" 2>/dev/null; then
            rm -f "${_ac_tmp}" 2>/dev/null || :
            AB_PKGS_ASSETS_REASON="assets-unwritable"
            continue
        fi
        sync 2>/dev/null || :
        AB_PKGS_ASSETS_CAPTURED="${AB_PKGS_ASSETS_CAPTURED} ${_ac_name}-${_ac_ver}"
        _ac_kept=$((_ac_kept + 1))
    done
    if [ "${_ac_kept}" -gt 0 ]; then
        AB_PKGS_ASSETS_STATE="ok"
        # The kept set is only meaningful if it is one version per name, so the store is tidied
        # in the same breath as the body arriving.
        ab_pkgs_assets_prune "${_ac_root}" || :
    elif [ -z "${AB_PKGS_ASSETS_STATE}" ]; then
        AB_PKGS_ASSETS_STATE="failed"
        [ -n "${AB_PKGS_ASSETS_REASON}" ] || AB_PKGS_ASSETS_REASON="asset-unidentified"
        return 1
    fi
    return 0
}

# _ab_pkgs_journal <root> <name> <version> <source>: one line in the superseded journal.
#
# The journal is a file, not a record field: `/boot/ab/packages` is one line whose vocabulary
# belongs to the record's owner (design.md §2), and "this body was taken back over by a feed"
# is a fact about the store that outlives any one follow.
_ab_pkgs_journal() {
    _jw_file=$(_ab_pkgs_superseded_path "$1")
    _jw_when=$(date -u +%s 2>/dev/null) || _jw_when=0
    printf 'superseded name=%s version=%s source=%s at=%s\n' "$2" "$3" "$4" "${_jw_when}" \
        >>"${_jw_file}" 2>/dev/null || :
}

# ab_pkgs_assets_superseded <root>: a body whose name a feed offers is no longer needed.
#
# The question is asked per name, once, and answered by apk policy: if any source other than
# the installed database answers for the name, the feed owns it from now on - signed, following
# the base, maintained - and the kept copy is a stale second opinion that a replay would install
# over a newer feed version. So it is journalled first and deleted second: a body deleted
# without a line would be a package that silently stopped being replayable.
#
# Sets AB_PKGS_ASSETS_SUPERSEDED (space list of `name-version`) and _STATE (ok|unknown|no-apk).
ab_pkgs_assets_superseded() {
    _sup_root=${1:-/}
    AB_PKGS_ASSETS_SUPERSEDED=""
    AB_PKGS_ASSETS_STATE=""
    _sup_names=""
    while IFS=' ' read -r _sup_name _sup_ver _sup_path _sup_bytes; do
        [ -n "${_sup_name}" ] || continue
        case " ${_sup_names} " in
            *" ${_sup_name} "*) continue ;;
        esac
        _sup_names="${_sup_names} ${_sup_name}"
        if ! _sup_src=$(ab_pkgs_policy_sources "${_sup_root}" "${_sup_name}"); then
            # No answer means no decision: deleting a body because apk could not be asked would
            # throw away the only copy of a package on the strength of a missing tool.
            AB_PKGS_ASSETS_STATE="unknown"
            continue
        fi
        _sup_feed=$(printf '%s\n' "${_sup_src}" | grep -vx 'lib/apk/db/installed' | head -n 1)
        [ -n "${_sup_feed}" ] || continue
        _sup_kind=$(_ab_pkgs_feed_kind "${_sup_root}" "${_sup_feed}")
        while IFS=' ' read -r _sup_n2 _sup_v2 _sup_p2 _sup_b2; do
            [ "${_sup_n2}" = "${_sup_name}" ] || continue
            _ab_pkgs_journal "${_sup_root}" "${_sup_n2}" "${_sup_v2}" "${_sup_kind}"
            rm -f "${_sup_p2}" 2>/dev/null || :
            AB_PKGS_ASSETS_SUPERSEDED="${AB_PKGS_ASSETS_SUPERSEDED} ${_sup_n2}-${_sup_v2}"
        done <<BODIES
$(ab_pkgs_assets_list "${_sup_root}")
BODIES
    done <<LIST
$(ab_pkgs_assets_list "${_sup_root}")
LIST
    if [ -z "${AB_PKGS_ASSETS_STATE}" ]; then
        AB_PKGS_ASSETS_STATE="ok"
    fi
    return 0
}

# ab_pkgs_assets_prune <root>: one body per name, then the size bound.
#
# Two passes because they answer two questions, and the second must not undo the first:
#
#   1. per name, keep the highest version. Without apk this pass cannot order anything, so it
#      reports `reason=no-apk` and keeps the store as it is - an unorderable store is better
#      than a wrongly emptied one.
#   2. while the store is over AB_PKGS_CACHE_MAX, delete the oldest body that is not the
#      installed version. A body the machine runs is the one a replay wants, so it is the last
#      to go; if only current bodies are left, the oldest of those goes and the report says so.
#
# Sets AB_PKGS_ASSETS_PRUNED (space list of `name-version`) and AB_PKGS_ASSETS_BYTES.
ab_pkgs_assets_prune() {
    _pr_root=${1:-/}
    AB_PKGS_ASSETS_PRUNED=""
    AB_PKGS_ASSETS_REASON=""
    _pr_names=""
    while IFS=' ' read -r _pr_name _pr_ver _pr_path _pr_bytes; do
        [ -n "${_pr_name}" ] || continue
        case " ${_pr_names} " in
            *" ${_pr_name} "*) continue ;;
        esac
        _pr_names="${_pr_names} ${_pr_name}"
        if ! _pr_best=$(ab_pkgs_assets_highest "${_pr_root}" "${_pr_name}"); then
            AB_PKGS_ASSETS_REASON="no-apk"
            continue
        fi
        _pr_cur=$(_ab_pkgs_installed_version "${_pr_root}" "${_pr_name}") || _pr_cur=""
        while IFS=' ' read -r _pr_n2 _pr_v2 _pr_p2 _pr_b2; do
            [ "${_pr_n2}" = "${_pr_name}" ] || continue
            [ "${_pr_p2}" = "${_pr_best}" ] && continue
            # The version this machine runs is not a duplicate: a base that moved and a body it
            # still runs are two different answers, and dropping the running one would delete
            # the only thing a rollback could replay.
            [ -n "${_pr_cur}" ] && [ "${_pr_v2}" = "${_pr_cur}" ] && continue
            rm -f "${_pr_p2}" 2>/dev/null || :
            AB_PKGS_ASSETS_PRUNED="${AB_PKGS_ASSETS_PRUNED} ${_pr_n2}-${_pr_v2}"
        done <<BODIES
$(ab_pkgs_assets_list "${_pr_root}")
BODIES
    done <<LIST
$(ab_pkgs_assets_list "${_pr_root}")
LIST

    _pr_total=$(ab_pkgs_assets_bytes "${_pr_root}")
    if [ "${_pr_total}" -gt "${AB_PKGS_CACHE_MAX}" ]; then
        # Oldest first, and the installed versions last: the list is walked twice rather than
        # sorting two keys into one comparison.
        _pr_victims=""
        _pr_cur_victims=""
        while IFS=' ' read -r _pr_when _pr_name _pr_ver _pr_path _pr_bytes; do
            [ -n "${_pr_name}" ] || continue
            _pr_cur=$(_ab_pkgs_installed_version "${_pr_root}" "${_pr_name}") || _pr_cur=""
            if [ -n "${_pr_cur}" ] && [ "${_pr_ver}" = "${_pr_cur}" ]; then
                _pr_cur_victims="${_pr_cur_victims}
${_pr_when} ${_pr_name} ${_pr_ver} ${_pr_path} ${_pr_bytes}"
            else
                _pr_victims="${_pr_victims}
${_pr_when} ${_pr_name} ${_pr_ver} ${_pr_path} ${_pr_bytes}"
            fi
        done <<AGED
$(ab_pkgs_assets_list "${_pr_root}" | while IFS=' ' read -r _pr_n _pr_v _pr_p _pr_b; do
    printf '%s %s %s %s %s\n' "$(_ab_pkgs_mtime "${_pr_p}")" "${_pr_n}" "${_pr_v}" "${_pr_p}" "${_pr_b}"
done | sort -n)
AGED
        for _pr_list in "${_pr_victims}" "${_pr_cur_victims}"; do
            [ "${_pr_total}" -gt "${AB_PKGS_CACHE_MAX}" ] || break
            [ -n "${_pr_list}" ] || continue
            while IFS=' ' read -r _pr_when _pr_name _pr_ver _pr_path _pr_bytes; do
                [ -n "${_pr_path}" ] || continue
                [ "${_pr_total}" -gt "${AB_PKGS_CACHE_MAX}" ] || break
                [ -f "${_pr_path}" ] || continue
                rm -f "${_pr_path}" 2>/dev/null || continue
                case "${_pr_bytes}" in
                    '' | *[!0-9]*) _pr_bytes=0 ;;
                esac
                _pr_total=$((_pr_total - _pr_bytes))
                AB_PKGS_ASSETS_PRUNED="${AB_PKGS_ASSETS_PRUNED} ${_pr_name}-${_pr_ver}"
                AB_PKGS_ASSETS_REASON="quota"
            done <<QUOTA
${_pr_list}
QUOTA
        done
    fi
    # shellcheck disable=SC2034  # read by the caller after this returns (ab-packages status)
    AB_PKGS_ASSETS_BYTES=$(ab_pkgs_assets_bytes "${_pr_root}")
    return 0
}

# ab_pkgs_assets_maintain <root>: the whole store policy in the order that survives a failure.
# Superseded first: a body a feed has taken over must not be counted as "the highest version"
# by the prune that follows it.
ab_pkgs_assets_maintain() {
    _mt_root=${1:-/}
    ab_pkgs_assets_superseded "${_mt_root}" || :
    _mt_superseded=${AB_PKGS_ASSETS_SUPERSEDED}
    _mt_sup_state=${AB_PKGS_ASSETS_STATE}
    ab_pkgs_assets_prune "${_mt_root}" || :
    # shellcheck disable=SC2034  # both are read by the caller after this returns
    AB_PKGS_ASSETS_SUPERSEDED=${_mt_superseded}
    # shellcheck disable=SC2034
    AB_PKGS_ASSETS_SUPERSEDED_STATE=${_mt_sup_state}
    return 0
}

# ab_pkgs_assets_replay <root> [<name>...]: install kept bodies again.
#
# The command is `apk add --allow-untrusted <body>`: the body is on this machine, not in a
# signed feed, so the trust is the file the user kept, and apk's own protected paths keep a
# `/etc/config/*` the user edited (measured 2026-11-18: the user's file is untouched, the
# package's copy lands as `*.apk-new`). Nothing else is passed - no `--force-*`, no
# `--overwrite` - because "replay" means "install this body as it is", not "make it fit".
#
# "Did it move" is measured, not read off the output: the installed version is taken from apk's
# database before and after. A body already installed at that version answers `unchanged`, the
# same shape the record refuses to call `followed` for a follow that moved nothing.
#
# Sets AB_PKGS_REPLAY_{STATE,OK,UNCHANGED,FAILED}; prints one line per body it tried.
ab_pkgs_assets_replay() {
    _rp_root=${1:-/}
    shift
    AB_PKGS_REPLAY_STATE=""
    AB_PKGS_REPLAY_OK=0
    AB_PKGS_REPLAY_UNCHANGED=0
    AB_PKGS_REPLAY_FAILED=0
    _rp_any=0
    _rp_targets=""
    if [ "$#" -gt 0 ]; then
        for _rp_name in "$@"; do
            _rp_body=$(ab_pkgs_assets_highest "${_rp_root}" "${_rp_name}")
            _rp_highest_rc=$?
            if [ "${_rp_highest_rc}" -ne 0 ]; then
                # "nothing kept" and "nothing can order these versions" are different answers,
                # and the second one is a broken apk rather than a package the user has to install
                # again. The token says which, because the fix is different.
                case "${_rp_highest_rc}" in
                    2) _rp_why="cannot-order (apk version -t gave no answer)" ;;
                    *) _rp_why="no-body" ;;
                esac
                printf 'replay name=%s result=failed reason=%s\n' "${_rp_name}" "${_rp_why}"
                AB_PKGS_REPLAY_FAILED=$((AB_PKGS_REPLAY_FAILED + 1))
                _rp_any=1
                continue
            fi
            _rp_targets="${_rp_targets}
${_rp_body}"
        done
    else
        _rp_targets=$(ab_pkgs_assets_list "${_rp_root}" | awk '{ print $3 }')
    fi
    while IFS= read -r _rp_body; do
        [ -n "${_rp_body}" ] || continue
        _rp_any=1
        _rp_id=$(ab_pkgs_asset_identify "${_rp_body}") || {
            printf 'replay path=%s result=failed reason=asset-unidentified\n' "${_rp_body}"
            AB_PKGS_REPLAY_FAILED=$((AB_PKGS_REPLAY_FAILED + 1))
            continue
        }
        _rp_name=${_rp_id%% *}
        _rp_ver=${_rp_id#* }
        _rp_before=$(_ab_pkgs_installed_version "${_rp_root}" "${_rp_name}") || _rp_before=""
        # One transaction per body, its own status captured and its transcript kept for the log:
        # a status read through a pipe is not a status, and a second run would install twice.
        if _rp_out=$(_ab_pkgs_apk "${_rp_root}" add --allow-untrusted "${_rp_body}" 2>&1); then
            _rp_rc=0
        else
            _rp_rc=$?
        fi
        printf '%s\n' "${_rp_out}" | grep . | head -n 5 | sed 's/^/replay:   /' >&2
        _rp_after=$(_ab_pkgs_installed_version "${_rp_root}" "${_rp_name}") || _rp_after=""
        if [ "${_rp_rc}" -ne 0 ]; then
            printf 'replay name=%s version=%s result=failed reason=apk-%s\n' \
                "${_rp_name}" "${_rp_ver}" "${_rp_rc}"
            AB_PKGS_REPLAY_FAILED=$((AB_PKGS_REPLAY_FAILED + 1))
            continue
        fi
        if [ "${_rp_before}" = "${_rp_after}" ]; then
            printf 'replay name=%s version=%s result=unchanged\n' "${_rp_name}" "${_rp_ver}"
            AB_PKGS_REPLAY_UNCHANGED=$((AB_PKGS_REPLAY_UNCHANGED + 1))
            continue
        fi
        printf 'replay name=%s version=%s result=ok\n' "${_rp_name}" "${_rp_ver}"
        AB_PKGS_REPLAY_OK=$((AB_PKGS_REPLAY_OK + 1))
    done <<BODIES
${_rp_targets}
BODIES
    if [ "${_rp_any}" -eq 0 ]; then
        AB_PKGS_REPLAY_STATE="empty"
        return 3
    fi
    if [ "${AB_PKGS_REPLAY_FAILED}" -eq 0 ]; then
        AB_PKGS_REPLAY_STATE="ok"
        return 0
    fi
    if [ "${AB_PKGS_REPLAY_OK}" -eq 0 ] && [ "${AB_PKGS_REPLAY_UNCHANGED}" -eq 0 ]; then
        # shellcheck disable=SC2034  # read by the caller after this returns
        AB_PKGS_REPLAY_STATE="fail"
        return 1
    fi
    # shellcheck disable=SC2034
    AB_PKGS_REPLAY_STATE="partial"
    return 0
}

# ab_pkgs_assets_report <root>: the store as one line of facts, for a caller that prints them
# beside the record. A store that cannot be read says so instead of reporting zero bodies.
ab_pkgs_assets_report() {
    _ar_root=${1:-/}
    _ar_n=$(ab_pkgs_assets_list "${_ar_root}" | grep -c . || true)
    _ar_n=${_ar_n:-0}
    _ar_bytes=$(ab_pkgs_assets_bytes "${_ar_root}")
    _ar_sup=0
    _ar_file=$(_ab_pkgs_superseded_path "${_ar_root}")
    [ -r "${_ar_file}" ] && _ar_sup=$(grep -c '^superseded ' "${_ar_file}" 2>/dev/null || true)
    _ar_sup=${_ar_sup:-0}
    printf 'assets=%s assets-bytes=%s superseded=%s\n' "${_ar_n}" "${_ar_bytes}" "${_ar_sup}"
}

ab_pkgs_cache_report() {
    _cr_root=${1:-/}
    _cr_dir=$(ab_pkgs_cache_dir "${_cr_root}")
    _cr_n=0
    _cr_bytes=0
    while IFS= read -r _cr_file; do
        [ -n "${_cr_file}" ] || continue
        _cr_n=$((_cr_n + 1))
        _cr_bytes=$((_cr_bytes + $(_ab_pkgs_file_bytes "${_cr_file}")))
    done <<FILES
$(_ab_pkgs_asset_files "${_cr_dir}")
FILES
    printf 'cache-files=%s cache-bytes=%s cache-max=%s\n' "${_cr_n}" "${_cr_bytes}" "${AB_PKGS_CACHE_MAX}"
}

# ab_pkgs_cache_clean <root>: empty the follow cache and keep the kept bodies. The cache is a
# consumable (design.md §10): its bodies are in the apk database once the follow ran, and a
# machine that keeps both would pay for the same bytes twice on a 128 MiB layer.
ab_pkgs_cache_clean() {
    _cc_root=${1:-/}
    _cc_dir=$(ab_pkgs_cache_dir "${_cc_root}")
    _cc_bytes=0
    while IFS= read -r _cc_file; do
        [ -n "${_cc_file}" ] || continue
        _cc_bytes=$((_cc_bytes + $(_ab_pkgs_file_bytes "${_cc_file}")))
        rm -f "${_cc_file}" 2>/dev/null || :
    done <<FILES
$(_ab_pkgs_asset_files "${_cc_dir}")
FILES
    printf 'cache-cleaned=%s cache-bytes=0\n' "${_cc_bytes}"
    return 0
}
