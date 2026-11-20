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
#                                                does not follow apk's naming. Only a fast path:
#                                                the file name is never the identity.
#   ab_pkgs_asset_identify <path>                `name version` from the package's own metadata
#                                                (`apk adbdump`, then `.PKGINFO`); the file name
#                                                only when there is no apk on the machine
#   ab_pkgs_asset_format <path>                   v3 | v2 | ipk | run | unknown, by magic
#   ab_pkgs_assets_list <root>                   `name version path bytes`, one body per line
#   ab_pkgs_assets_bytes <root>                  bytes of every kept body
#   ab_pkgs_assets_highest <root> <name>         path of the highest kept version; 1 none,
#                                                2 cannot be ordered
#   ab_pkgs_policy_sources <root> <name>         one source per line: `installed` or a feed URL
#   ab_pkgs_policy_versions <root> <name>        `version source` pairs, one per line
#   ab_pkgs_installed_version <root> <name>      the version apk's database records, or 1
#   ab_pkgs_version_cmp <root> <a> <b>           -1 | 0 | 1, ordered by apk's own rules
#   ab_pkgs_assets_capture <root> <file>...      keep the body; sets _CAPTURED/_REASON/_STATE
#   ab_pkgs_assets_capture_declared <root> <name> <version> <file>
#                                                keep a body under a declared identity, but only
#                                                after the package itself confirms it
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
AB_PKGS_ASSETS_CAPTURED_NAMES=""
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
# This is a fast path, not the identity: `ab_pkgs_asset_identify` asks the package itself first
# and only falls back here on a machine with no apk to ask. Two shapes are accepted:
#
#   <name>-<version>-r<rev>.apk   `foo-bar-1.2.3-r1.apk` -> `foo-bar 1.2.3-r1`
#   <name>-<version>.apk          `minieap-0.94.0.apk`   -> `minieap 0.94.0`
#
# apk versions may not contain a `-`, so in both shapes the name ends at the dash before the
# version; a version always starts with a digit, which is what keeps `foo-bar.apk` (no version
# at all) from being split into `foo` + `bar`. The second shape exists because apk's own
# metadata may carry no revision at all (`minieap 0.94.0`, measured 2026-11-20).
ab_pkgs_asset_split() {
    _as_stem=${1##*/}
    _as_stem=${_as_stem%.apk}
    _as_last=${_as_stem##*-}
    _as_rest=${_as_stem%-*}
    [ "${_as_rest}" = "${_as_stem}" ] && return 1
    case "${_as_last}" in
        r?*)
            _as_num=${_as_last#r}
            case "${_as_num}" in
                '' | *[!0-9]*) ;;
                *)
                    _as_ver=${_as_rest##*-}
                    case "${_as_ver}" in
                        [0-9]*) ;;
                        *) return 1 ;;
                    esac
                    _as_name=${_as_rest%-*}
                    [ -n "${_as_name}" ] || return 1
                    printf '%s %s\n' "${_as_name}" "${_as_ver}-${_as_last}"
                    return 0
                    ;;
            esac
            ;;
    esac
    case "${_as_last}" in
        [0-9]*) ;;
        *) return 1 ;;
    esac
    [ -n "${_as_rest}" ] || return 1
    printf '%s %s\n' "${_as_rest}" "${_as_last}"
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

# _ab_pkgs_adbdump <file>: `name version` from the package's own ADB metadata, or 1.
#
# apk-tools 3 packages are ADB containers (`ADBd` magic) whose head carries an `info:` block
# with `name:` and `version:`. `apk adbdump` prints that block and then the whole file table; the
# reader below stops at `paths:`, so a 29 MiB package costs its header, not its payload (measured
# 2026-11-20: 0.35 s for the full dump, less when it stops early). This is the identity apk
# itself installs by, which is why the file name never has to be trusted. An index file
# (`packages.adb`) also answers rc=0 but has no `info:` block, hence the emptiness check.
_ab_pkgs_adbdump() {
    [ -f "$1" ] || return 1
    command -v apk >/dev/null 2>&1 || return 1
    _ad_out=$(apk adbdump "$1" 2>/dev/null | awk '
        /^info:/ { inside = 1; next }
        inside && /^  name: / { name = substr($0, 9); next }
        inside && /^  version: / { version = substr($0, 12); next }
        inside && /^paths:/ { exit }
        END { if (name != "" && version != "") print name " " version }
    ')
    [ -n "${_ad_out}" ] || return 1
    _ad_name=${_ad_out%% *}
    _ad_ver=${_ad_out#* }
    case "${_ad_name}" in
        '' | *' '*) return 1 ;;
    esac
    case "${_ad_ver}" in
        '' | *' '*) return 1 ;;
    esac
    printf '%s %s\n' "${_ad_name}" "${_ad_ver}"
}

# ab_pkgs_asset_format <file>: `v3`, `v2`, `ipk`, `run` or `unknown`, by magic bytes only.
#
# The store can explain why a body was refused: an ipk is an `ar` archive (iStore's old line),
# a `.run` is a shell script, a v2 package is a tar whose `.PKGINFO` this library can read even
# though apk-tools 3 refuses to install it. Sniffing is `head -c 4` plus `tar -t` because the
# image has no `od`/`xxd` (measured 2026-11-18). A file this cannot name is `unknown`, and the
# caller reports it as unidentified rather than guessing.
ab_pkgs_asset_format() {
    [ -f "$1" ] || return 1
    _af_magic=$(head -c 4 "$1" 2>/dev/null)
    case "${_af_magic}" in
        ADBd) printf 'v3'; return 0 ;;
        '!<ar') printf 'ipk'; return 0 ;;
        '#!'*) printf 'run'; return 0 ;;
    esac
    if tar -xzOf "$1" .PKGINFO >/dev/null 2>&1 \
        || tar -xzOf "$1" ./.PKGINFO >/dev/null 2>&1; then
        printf 'v2'
        return 0
    fi
    printf 'unknown'
    return 0
}

# _ab_pkgs_simulate_identity <root> <file>: `name version` from apk's own transaction plan, or 1.
#
# `apk add --simulate` installs nothing and writes nothing; it prints one line per package it
# would install, in dependency order, so the last `Installing`/`Replacing` line is the file's own
# package. This is the fallback for a machine whose apk no longer ships `adbdump`: the question
# "what is this file" is still answered by apk itself, never by the name. A package already
# installed at the same version answers `Replacing`, which is why both verbs are parsed.
_ab_pkgs_simulate_identity() {
    _si_root=${1:-/}
    _si_file=$2
    command -v apk >/dev/null 2>&1 || return 1
    _si_prefix=$(_ab_pkgs_root "${_si_root}")
    if [ -z "${_si_prefix}" ]; then
        _si_out=$(apk add --simulate --allow-untrusted --no-network "${_si_file}" 2>/dev/null) || return 1
    else
        _si_out=$(apk --root "${_si_prefix}" add --simulate --allow-untrusted --no-network "${_si_file}" 2>/dev/null) || return 1
    fi
    printf '%s\n' "${_si_out}" | awk '
        /^[0-9]+\/[0-9]+ Installing / {
            line = $0
            sub(/^[0-9]+\/[0-9]+ Installing /, "", line)
            if (line ~ /\(.*\)$/) {
                name = line; sub(/ \(.*$/, "", name)
                ver = line; sub(/^.* \(/, "", ver); sub(/\)$/, "", ver)
                last = name " " ver
            }
            next
        }
        /^[0-9]+\/[0-9]+ Replacing / {
            line = $0
            sub(/^[0-9]+\/[0-9]+ Replacing /, "", line)
            if (line ~ /\(.* -> .*\)$/) {
                name = line; sub(/ \(.*$/, "", name)
                ver = line; sub(/^.* -> /, "", ver); sub(/\)$/, "", ver)
                last = name " " ver
            }
            next
        }
        END { if (last != "") print last }
    ' | grep .
}

# ab_pkgs_asset_identify <path>: `name version`, or 1.
#
# The order is the identity order, not a convenience order:
#
#   1. the package's own metadata (`apk adbdump`) - the same bytes apk installs by;
#   2. `.PKGINFO` for a v2 tar package (legacy, and what the fixtures build);
#   3. the file name, only on a machine with no apk to ask (a fixture tree, a build host).
#
# A machine with apk that cannot read the file is refused here; `ab_pkgs_assets_capture_declared`
# is the one path that lets a person state the identity instead, and it has to be confirmed.
ab_pkgs_asset_identify() {
    [ -f "$1" ] || return 1
    _ai_meta=$(_ab_pkgs_adbdump "$1") && { printf '%s\n' "${_ai_meta}"; return 0; }
    _ab_pkgs_pkginfo "$1" && return 0
    command -v apk >/dev/null 2>&1 && return 1
    ab_pkgs_asset_split "$1"
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

# ab_pkgs_version_cmp <root> <a> <b>: public spelling of the ordering above, for callers whose
# question is "did the declaration match" rather than "which body is newest".
ab_pkgs_version_cmp() {
    _ab_pkgs_version_cmp "$@"
}

# ab_pkgs_assets_list <root>: `name version path bytes` for every kept body, one per line.
# A file this library cannot name is left out of the listing on purpose: reporting it as a
# body of some name would make the gate believe a replay is possible that is not.
ab_pkgs_assets_list() {
    _al_dir=$(ab_pkgs_assets_dir "${1:-/}")
    [ -d "${_al_dir}" ] || return 0
    while IFS= read -r _al_file; do
        [ -n "${_al_file}" ] || continue
        # The store's own invariant is that a body is named after its identity, so the name is
        # the cheap answer here; a file dropped in by hand keeps the old behaviour and is read
        # from its metadata instead. Listing does not spawn apk per body on the common path.
        _al_id=$(ab_pkgs_asset_split "${_al_file}") \
            || _al_id=$(ab_pkgs_asset_identify "${_al_file}") || continue
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

# ab_pkgs_installed_version <root> <name>: the public spelling of the database question.
ab_pkgs_installed_version() {
    _ab_pkgs_installed_version "$@"
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

# ab_pkgs_policy_versions <root> <name>: `version source` pairs from `apk policy`.
#
# `apk policy` prints one block per candidate version and, under each, the sources that offer it
# (the installed database is one such "source"). The superseded rule needs more than "some feed
# knows this name": a feed that only offers an older version is not a replacement for a body the
# machine runs, so this reader keeps the version attached to each source.
ab_pkgs_policy_versions() {
    _pvv_root=${1:-/}
    _pvv_name=$2
    _pvv_out=$(_ab_pkgs_apk "${_pvv_root}" policy "${_pvv_name}" 2>/dev/null) || return 1
    printf '%s\n' "${_pvv_out}" | awk '
        /^[^ \t].*:$/ { next }
        /^[ \t]+[^ \t].*:$/ { ver = $1; sub(/:$/, "", ver); next }
        /^[ \t]+[^ \t]/ { if (ver != "") print ver " " $1; next }
    ' | grep .
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
# _ab_pkgs_asset_keep <root> <file> <name> <version>: copy one body under its canonical name.
#
# Returns 0 when written, 2 when the same bytes were already there, 1 when the store cannot be
# written (reason set). The copy is written beside its destination and renamed: a power cut
# leaves the store with the old body or the new one, never half of either.
_ab_pkgs_asset_keep() {
    _ak_root=$1
    _ak_file=$2
    _ak_name=$3
    _ak_ver=$4
    _ak_dir=$(ab_pkgs_assets_dir "${_ak_root}")
    if ! mkdir -p "${_ak_dir}" 2>/dev/null; then
        AB_PKGS_ASSETS_REASON="assets-unwritable"
        return 1
    fi
    _ak_dest="${_ak_dir}/${_ak_name}-${_ak_ver}.apk"
    if [ -f "${_ak_dest}" ] \
        && [ "$(_ab_pkgs_file_bytes "${_ak_dest}")" = "$(_ab_pkgs_file_bytes "${_ak_file}")" ]; then
        return 2
    fi
    _ak_tmp="${_ak_dest}.tmp.$$"
    if ! cp "${_ak_file}" "${_ak_tmp}" 2>/dev/null; then
        AB_PKGS_ASSETS_REASON="assets-unwritable"
        return 1
    fi
    sync 2>/dev/null || :
    if ! mv "${_ak_tmp}" "${_ak_dest}" 2>/dev/null; then
        rm -f "${_ak_tmp}" 2>/dev/null || :
        AB_PKGS_ASSETS_REASON="assets-unwritable"
        return 1
    fi
    sync 2>/dev/null || :
    return 0
}

# ab_pkgs_assets_capture <root> <file>...: keep the bodies of local packages.
#
# This is the moment a body is kept: apk itself keeps nothing (measured: `/var` is a tmpfs and
# the default cache dies with the boot), so the body is copied here while it still exists. The
# identity comes from the package's own metadata (see ab_pkgs_asset_identify); a body that
# cannot be named is refused with a token that says why - `asset-unidentified` for a file whose
# metadata cannot be read, `asset-format-ipk` / `asset-format-run` for a file that is not an
# apk at all. A body that is already kept byte for byte is left alone.
ab_pkgs_assets_capture() {
    _ac_root=${1:?ab_pkgs_assets_capture needs a root}
    shift
    AB_PKGS_ASSETS_CAPTURED=""
    AB_PKGS_ASSETS_CAPTURED_NAMES=""
    AB_PKGS_ASSETS_REASON=""
    AB_PKGS_ASSETS_STATE=""
    _ac_kept=0
    for _ac_file in "$@"; do
        if [ ! -f "${_ac_file}" ] || [ ! -s "${_ac_file}" ]; then
            AB_PKGS_ASSETS_REASON="asset-missing"
            continue
        fi
        _ac_fmt=$(ab_pkgs_asset_format "${_ac_file}") || _ac_fmt="unknown"
        case "${_ac_fmt}" in
            ipk)
                AB_PKGS_ASSETS_REASON="asset-format-ipk"
                continue
                ;;
            run)
                AB_PKGS_ASSETS_REASON="asset-format-run"
                continue
                ;;
        esac
        if ! _ac_id=$(ab_pkgs_asset_identify "${_ac_file}"); then
            AB_PKGS_ASSETS_REASON="asset-unidentified"
            continue
        fi
        _ac_name=${_ac_id%% *}
        _ac_ver=${_ac_id#* }
        # 0 wrote it, 2 found the same bytes already there: both are "this body is kept". Treating
        # 2 as a failure would make a second `replay <same file>` report a store it did not write.
        _ab_pkgs_asset_keep "${_ac_root}" "${_ac_file}" "${_ac_name}" "${_ac_ver}"
        case $? in
            0 | 2)
                AB_PKGS_ASSETS_CAPTURED="${AB_PKGS_ASSETS_CAPTURED} ${_ac_name}-${_ac_ver}"
                AB_PKGS_ASSETS_CAPTURED_NAMES="${AB_PKGS_ASSETS_CAPTURED_NAMES} ${_ac_name}"
                _ac_kept=$((_ac_kept + 1))
                ;;
            *) continue ;;
        esac
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

# ab_pkgs_assets_capture_declared <root> <name> <version> <file>: keep a body a person named.
#
# The declaration is the last resort for a file whose identity no tool on the machine can read.
# It is never taken on trust: the package's own metadata, or apk's own transaction plan when the
# metadata cannot be read, has to agree with it before anything is written. A declaration that
# cannot be confirmed leaves the store untouched - `asset-name-mismatch` for a disagreement,
# `asset-name-unverifiable` for "nothing here can answer". The install that follows is still one
# `apk add --allow-untrusted <body>`; the declaration only decides the store's file name.
ab_pkgs_assets_capture_declared() {
    _acd_root=${1:?ab_pkgs_assets_capture_declared needs a root}
    _acd_name=$2
    _acd_ver=$3
    _acd_file=$4
    AB_PKGS_ASSETS_CAPTURED=""
    AB_PKGS_ASSETS_CAPTURED_NAMES=""
    AB_PKGS_ASSETS_REASON=""
    AB_PKGS_ASSETS_STATE=""
    case "${_acd_name}" in
        '' | *' '*)
            AB_PKGS_ASSETS_STATE="failed"
            AB_PKGS_ASSETS_REASON="asset-name-mismatch"
            return 1
            ;;
    esac
    case "${_acd_ver}" in
        '' | *' '*)
            AB_PKGS_ASSETS_STATE="failed"
            AB_PKGS_ASSETS_REASON="asset-name-mismatch"
            return 1
            ;;
    esac
    if [ ! -f "${_acd_file}" ] || [ ! -s "${_acd_file}" ]; then
        AB_PKGS_ASSETS_STATE="failed"
        AB_PKGS_ASSETS_REASON="asset-missing"
        return 1
    fi
    _acd_fmt=$(ab_pkgs_asset_format "${_acd_file}") || _acd_fmt="unknown"
    case "${_acd_fmt}" in
        ipk)
            AB_PKGS_ASSETS_STATE="failed"
            AB_PKGS_ASSETS_REASON="asset-format-ipk"
            return 1
            ;;
        run)
            AB_PKGS_ASSETS_STATE="failed"
            AB_PKGS_ASSETS_REASON="asset-format-run"
            return 1
            ;;
    esac
    _acd_actual=$(ab_pkgs_asset_identify "${_acd_file}") || _acd_actual=""
    if [ -z "${_acd_actual}" ]; then
        _acd_actual=$(_ab_pkgs_simulate_identity "${_acd_root}" "${_acd_file}") || _acd_actual=""
        if [ -z "${_acd_actual}" ]; then
            AB_PKGS_ASSETS_STATE="failed"
            AB_PKGS_ASSETS_REASON="asset-name-unverifiable"
            return 1
        fi
    fi
    # The name has to match exactly; the version is compared the way apk compares versions, so
    # `0.94.0-r0` and `0.94.0` are the same declaration rather than a mismatch a person has to
    # debug. When apk cannot order them at all, exact equality is the only honest answer.
    _acd_actual_name=${_acd_actual%% *}
    _acd_actual_ver=${_acd_actual#* }
    _acd_ok=1
    if [ "${_acd_actual_name}" = "${_acd_name}" ]; then
        _acd_cmp=$(_ab_pkgs_version_cmp "${_acd_root}" "${_acd_actual_ver}" "${_acd_ver}") \
            || _acd_cmp=""
        case "${_acd_cmp}" in
            0) _acd_ok=0 ;;
            '')
                [ "${_acd_actual_ver}" = "${_acd_ver}" ] && _acd_ok=0
                ;;
        esac
    fi
    if [ "${_acd_ok}" -ne 0 ]; then
        AB_PKGS_ASSETS_STATE="failed"
        AB_PKGS_ASSETS_REASON="asset-name-mismatch"
        return 1
    fi
    # The store is named after the package's own spelling, not the declaration's: a body filed
    # as `foo-1.0-r0.apk` while apk records `1.0` would make the next gate ask the wrong question.
    _acd_store_ver=${_acd_actual_ver:-${_acd_ver}}
    _ab_pkgs_asset_keep "${_acd_root}" "${_acd_file}" "${_acd_name}" "${_acd_store_ver}"
    case $? in
        0 | 2) : ;;
        *)
            AB_PKGS_ASSETS_STATE="failed"
            [ -n "${AB_PKGS_ASSETS_REASON}" ] || AB_PKGS_ASSETS_REASON="assets-unwritable"
            return 1
            ;;
    esac
    AB_PKGS_ASSETS_CAPTURED=" ${_acd_name}-${_acd_store_ver}"
    AB_PKGS_ASSETS_CAPTURED_NAMES=" ${_acd_name}"
    AB_PKGS_ASSETS_STATE="ok"
    ab_pkgs_assets_prune "${_acd_root}" || :
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

# _ab_pkgs_journal_kept <root> <name> <version> <reason>: the other store decision.
#
# A body a feed only knows an older version of is kept, and that is a decision too: without this
# line the journal would only ever record deletions, and "why is this body still here" would be
# unanswerable. Same file, same append-only shape, different verb.
_ab_pkgs_journal_kept() {
    _jk_file=$(_ab_pkgs_superseded_path "$1")
    # This decision is re-made on every maintain run; the journal is append-only, so writing the
    # same fact again would grow a file that is supposed to be a record. One line per decision.
    grep -qF "kept name=$2 version=$3 reason=$4 " "${_jk_file}" 2>/dev/null && return 0
    _jk_when=$(date -u +%s 2>/dev/null) || _jk_when=0
    printf 'kept name=%s version=%s reason=%s at=%s\n' "$2" "$3" "$4" "${_jk_when}" \
        >>"${_jk_file}" 2>/dev/null || :
}

# ab_pkgs_assets_superseded <root>: a body a feed has taken over, by version, is no longer needed.
#
# The question is asked per name, once, and answered by `apk policy`. A feed owns the name only
# when it offers a version at least as new as the body: a feed that only knows an older version
# cannot replace the body the machine runs, and deleting it would throw away the one copy a
# replay could use (measured 2026-11-20: `minieap 0.94.0` was deleted because distfeeds offered
# only `0.93-r2`). So the version comes first and the decision follows it:
#
#   feed_version >= body_version  -> journal `superseded`, then delete the body
#   feed_version <  body_version  -> keep the body, journal `kept ... reason=source-older`
#   no feed source, or no answer  -> keep the body, say nothing (or `unknown` when apk failed)
#
# Sets AB_PKGS_ASSETS_SUPERSEDED (space list of `name-version` actually deleted) and _STATE
# (ok|unknown|no-apk).
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
        if ! _sup_vers=$(ab_pkgs_policy_versions "${_sup_root}" "${_sup_name}"); then
            # No answer means no decision: deleting a body because apk could not be asked would
            # throw away the only copy of a package on the strength of a missing tool.
            AB_PKGS_ASSETS_STATE="unknown"
            continue
        fi
        # The highest version any source other than the installed database offers; the installed
        # database is never a source that can "take a body back over".
        _sup_feed_ver=""
        _sup_feed_src=""
        while IFS=' ' read -r _sup_v _sup_s; do
            [ -n "${_sup_v}" ] || continue
            [ "${_sup_s}" = "lib/apk/db/installed" ] && continue
            if [ -z "${_sup_feed_ver}" ]; then
                _sup_feed_ver=${_sup_v}
                _sup_feed_src=${_sup_s}
                continue
            fi
            if ! _sup_cmp=$(_ab_pkgs_version_cmp "${_sup_root}" "${_sup_v}" "${_sup_feed_ver}"); then
                _sup_feed_ver=""
                break
            fi
            [ "${_sup_cmp}" = "1" ] && _sup_feed_ver=${_sup_v} && _sup_feed_src=${_sup_s}
        done <<VERS
${_sup_vers}
VERS
        [ -n "${_sup_feed_ver}" ] || continue
        _sup_kind=$(_ab_pkgs_feed_kind "${_sup_root}" "${_sup_feed_src}")
        while IFS=' ' read -r _sup_n2 _sup_v2 _sup_p2 _sup_b2; do
            [ "${_sup_n2}" = "${_sup_name}" ] || continue
            if ! _sup_dec=$(_ab_pkgs_version_cmp "${_sup_root}" "${_sup_feed_ver}" "${_sup_v2}"); then
                # The two versions cannot be ordered (no apk): keeping is the safe direction.
                AB_PKGS_ASSETS_STATE="unknown"
                continue
            fi
            case "${_sup_dec}" in
                0 | 1)
                    _ab_pkgs_journal "${_sup_root}" "${_sup_n2}" "${_sup_v2}" "${_sup_kind}"
                    rm -f "${_sup_p2}" 2>/dev/null || :
                    AB_PKGS_ASSETS_SUPERSEDED="${AB_PKGS_ASSETS_SUPERSEDED} ${_sup_n2}-${_sup_v2}"
                    ;;
                *)
                    # The feed is older: the body is still the only way to reinstall the version
                    # this machine runs, so it stays and the decision is written down.
                    _ab_pkgs_journal_kept "${_sup_root}" "${_sup_n2}" "${_sup_v2}" "source-older"
                    ;;
            esac
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
