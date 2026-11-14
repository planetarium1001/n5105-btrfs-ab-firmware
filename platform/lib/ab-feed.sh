#!/bin/sh
# ab-feed.sh - the update feed: configuration, fetching, and the AB-FEED 1 index.
#
# Requires platform/lib/ab-version.sh (ab_version_valid, ab_version_cmp): this file
# validates versions and orders entries, and deliberately does not re-implement either.
# Callers source ab-version.sh first; keeping the dependency explicit is what lets the
# tests exercise this library with nothing but a temporary directory.
#
# This library never writes a slot and never runs apk. It turns bytes on a server into
# "there is a release, here is its payload and its digest", or into a stable reason
# token. ab-upgrade does the deciding and the installing; everything here is a pure
# function of files and environment, which is what makes it testable without a network.
#
#   ab_feed_config_load <file>          read /etc/ab/update.conf
#   ab_feed_fetch <url> <out>           one file, via a replaceable fetcher
#   ab_feed_index_parse <file> [chan]   validate an index and print one line per entry
#   ab_feed_pick <parsed> <installed>   the newest entry above the installed platform
#   ab_feed_stepwise <parsed> <installed>  the next entry, one at a time
#   ab_feed_sha256 <file>               sha256sum, or shasum -a 256 on macOS
#   ab_feed_verify_member <file> <entry>   size and digest of a downloaded payload
#   ab_feed_space_ok <dir> <bytes>      room for a download plus ten percent
#
# Every failure sets AB_FEED_REASON to a token callers print verbatim; nothing here
# decides what a failure means for the user.
#
# The index is plain text on purpose: a third-party mirror can produce it with
# sha256sum and printf, and the device needs no JSON parser. The file is ordered
# newest first; ab_feed_index_parse enforces that order instead of sorting, because a
# sorted view would hide a publisher that stopped maintaining the order.

AB_FEED_REASON=""
AB_FEED_URL=""
AB_FEED_CHANNEL="stable"
AB_FEED_VERIFY="sha256"

# _ab_feed_fail <token>: record the reason and return non-zero.
_ab_feed_fail() {
    AB_FEED_REASON="$1"
    return 1
}

# _ab_feed_trim <text>: strip leading and trailing blanks.
_ab_feed_trim() {
    _t=${1:-}
    _t=${_t#"${_t%%[![:space:]]*}"}
    _t=${_t%"${_t##*[![:space:]]}"}
    printf '%s' "${_t}"
}

ab_feed_config_load() {
    _conf=${1:-}
    AB_FEED_REASON=""
    AB_FEED_URL=""
    AB_FEED_CHANNEL="stable"
    AB_FEED_VERIFY="sha256"
    [ -f "${_conf}" ] || _ab_feed_fail no-feed-config || return 1

    while IFS= read -r _line || [ -n "${_line}" ]; do
        _line=$(_ab_feed_trim "${_line}")
        case "${_line}" in
            '' | '#'*) continue ;;
        esac
        _key=${_line%%=*}
        _val=${_line#*=}
        _key=$(_ab_feed_trim "${_key}")
        _val=$(_ab_feed_trim "${_val}")
        case "${_key}" in
            UPDATE_FEED_URL) AB_FEED_URL="${_val}" ;;
            UPDATE_CHANNEL) AB_FEED_CHANNEL="${_val:-stable}" ;;
            UPDATE_VERIFY) AB_FEED_VERIFY="${_val:-sha256}" ;;
            UPDATE_PIN) AB_FEED_PIN="${_val}" ;;
            *) : ;;
        esac
    done <"${_conf}"

    [ -n "${AB_FEED_URL}" ] || _ab_feed_fail feed-conf-missing-url || return 1
    case "${AB_FEED_URL}" in
        https://*) : ;;
        *) _ab_feed_fail feed-conf-url || return 1 ;;
    esac
    case "${AB_FEED_CHANNEL}" in
        stable | edge) : ;;
        *) _ab_feed_fail feed-conf-channel || return 1 ;;
    esac
    case "${AB_FEED_VERIFY}" in
        sha256) : ;;
        *) _ab_feed_fail feed-verify-unsupported || return 1 ;;
    esac
    # A hand-written pin is held to the same shape as `--pin`: an unparsable one would
    # silently stop protecting the machine.
    if [ -n "${AB_FEED_PIN:-}" ]; then
        ab_version_valid "${AB_FEED_PIN}" || _ab_feed_fail pin-invalid-version || return 1
    fi
    return 0
}

# _ab_feed_which <cmd>: the first usable fetcher, or nothing.
ab_feed_fetch() {
    _url=${1:?ab_feed_fetch needs a url}
    _out=${2:?ab_feed_fetch needs an output path}
    AB_FEED_REASON=""
    if [ -n "${UPDATE_FETCH_CMD:-}" ]; then
        # Tests and unusual transports replace the fetcher wholesale. The command gets
        # the url and the output path as $1 and $2.
        if sh -c "${UPDATE_FETCH_CMD}" ab-fetch "${_url}" "${_out}"; then
            return 0
        fi
        rm -f "${_out}"
        _ab_feed_fail feed-unreachable
        return 1
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        if uclient-fetch -q -O "${_out}" "${_url}" 2>/dev/null; then
            return 0
        fi
        rm -f "${_out}"
        _ab_feed_fail feed-unreachable
        return 1
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget -q -O "${_out}" "${_url}" 2>/dev/null; then
            return 0
        fi
        rm -f "${_out}"
        _ab_feed_fail feed-unreachable
        return 1
    fi
    _ab_feed_fail feed-no-fetcher
}

# _ab_feed_field_ok <name> <value>: the per-field validation the index needs.
_ab_feed_field_ok() {
    case "${1}" in
        platform | base | kernel)
            ab_version_valid "${2}" || _ab_feed_fail feed-index-version || return 1
            ;;
        sha256)
            case "${2}" in
                *[!0-9a-fA-F]* | '') _ab_feed_fail feed-index-field || return 1 ;;
            esac
            [ "${#2}" -eq 64 ] || _ab_feed_fail feed-index-field || return 1
            ;;
        size)
            case "${2}" in
                '' | *[!0-9]*) _ab_feed_fail feed-index-field || return 1 ;;
            esac
            [ "${2}" -gt 0 ] || _ab_feed_fail feed-index-field || return 1
            ;;
    esac
    return 0
}

ab_feed_index_parse() {
    _file=${1:?ab_feed_index_parse needs a file}
    _want_channel=${2:-stable}
    AB_FEED_REASON=""
    _fmt=""
    _channel=""
    _in=0
    _seen_entry=0
    _last=""

    while IFS= read -r _line || [ -n "${_line}" ]; do
        _line=$(_ab_feed_trim "${_line}")
        case "${_line}" in
            '' | '#'*) continue ;;
        esac
        _key=${_line%% *}
        _val=""
        case "${_line}" in
            *' '*) _val=$(_ab_feed_trim "${_line#* }") ;;
        esac
        case "${_key}" in
            AB-FEED)
                # The header is the first line of the file and appears once; an index that
                # says so twice has two answers to "which format is this".
                [ -z "${_fmt}" ] || _ab_feed_fail feed-index-field || return 1
                [ "${_seen_entry}" = "0" ] || _ab_feed_fail feed-index-field || return 1
                _fmt=${_val}
                case "${_fmt}" in
                    1) : ;;
                    *) _ab_feed_fail feed-index-version || return 1 ;;
                esac
                ;;
            channel)
                # Nothing may precede the header: the format of the file is what the
                # first line promises, and a reader that accepts a later header is
                # guessing.
                [ -n "${_fmt}" ] || _ab_feed_fail feed-index-field || return 1
                _channel=${_val}
                ;;
            generated)
                # Informational only: it records when the publisher rendered the index.
                :
                ;;
            entry)
                [ -n "${_fmt}" ] || _ab_feed_fail feed-index-field || return 1
                [ "${_in}" = 0 ] || _ab_feed_fail feed-index-field || return 1
                _in=1
                _seen_entry=1
                _platform="" _base="" _kernel="" _payload="" _size="" _sha="" _url="" _notes=""
                ;;
            end)
                [ "${_in}" = 1 ] || _ab_feed_fail feed-index-field || return 1
                _in=0
                [ -n "${_platform}" ] || _ab_feed_fail feed-index-field || return 1
                [ -n "${_base}" ] || _ab_feed_fail feed-index-field || return 1
                [ -n "${_kernel}" ] || _ab_feed_fail feed-index-field || return 1
                [ -n "${_payload}" ] || _ab_feed_fail feed-index-field || return 1
                [ -n "${_size}" ] || _ab_feed_fail feed-index-field || return 1
                [ -n "${_sha}" ] || _ab_feed_fail feed-index-field || return 1
                _ab_feed_field_ok platform "${_platform}" || return 1
                _ab_feed_field_ok base "${_base}" || return 1
                _ab_feed_field_ok kernel "${_kernel}" || return 1
                _ab_feed_field_ok size "${_size}" || return 1
                _ab_feed_field_ok sha256 "${_sha}" || return 1
                if [ -z "${_url}" ]; then
                    _url="${AB_FEED_URL%/}/${_payload}"
                else
                    # An explicit url is used as given, so it has to be as trustworthy as
                    # the base url: absolute and encrypted, nothing else is accepted.
                    case "${_url}" in
                        https://*) : ;;
                        *) _ab_feed_fail feed-index-field || return 1 ;;
                    esac
                fi
                if [ -n "${_last}" ]; then
                    _cmp=$(ab_version_cmp "${_last}" "${_platform}")
                    [ "${_cmp}" -gt 0 ] || _ab_feed_fail feed-index-order || return 1
                fi
                _last=${_platform}
                printf '%s|%s|%s|%s|%s|%s|%s\n' \
                    "${_platform}" "${_base}" "${_kernel}" "${_size}" "${_sha}" "${_url}" "${_notes}"
                ;;
            platform | base | kernel | payload | size | sha256 | url | notes)
                [ "${_in}" = 1 ] || _ab_feed_fail feed-index-field || return 1
                # One field, one value: a second occurrence means the publisher and this
                # reader disagree about which line wins, so the entry is refused rather
                # than resolved by position.
                case "${_key}" in
                    platform) [ -z "${_platform}" ] || _ab_feed_fail feed-index-field || return 1; _platform=${_val} ;;
                    base) [ -z "${_base}" ] || _ab_feed_fail feed-index-field || return 1; _base=${_val} ;;
                    kernel) [ -z "${_kernel}" ] || _ab_feed_fail feed-index-field || return 1; _kernel=${_val} ;;
                    payload) [ -z "${_payload}" ] || _ab_feed_fail feed-index-field || return 1; _payload=${_val} ;;
                    size) [ -z "${_size}" ] || _ab_feed_fail feed-index-field || return 1; _size=${_val} ;;
                    sha256) [ -z "${_sha}" ] || _ab_feed_fail feed-index-field || return 1; _sha=${_val} ;;
                    url) [ -z "${_url}" ] || _ab_feed_fail feed-index-field || return 1; _url=${_val} ;;
                    notes) [ -z "${_notes}" ] || _ab_feed_fail feed-index-field || return 1; _notes=${_val} ;;
                esac
                ;;
            *)
                _ab_feed_fail feed-index-field || return 1
                ;;
        esac
    done <"${_file}"

    [ -n "${_fmt}" ] || _ab_feed_fail feed-index-version || return 1
    [ "${_in}" = 0 ] || _ab_feed_fail feed-index-field || return 1
    [ -n "${_channel}" ] || _ab_feed_fail feed-index-field || return 1
    [ "${_channel}" = "${_want_channel}" ] || _ab_feed_fail feed-index-channel || return 1
    return 0
}

# ab_feed_pick <parsed> <installed-platform>: the newest release the feed offers.
ab_feed_pick() {
    _parsed=${1:?} _installed=${2:?}
    while IFS='|' read -r _p _rest; do
        [ -n "${_p}" ] || continue
        _cmp=$(ab_version_cmp "${_p}" "${_installed}") || return 1
        if [ "${_cmp}" -gt 0 ]; then
            printf '%s\n' "${_p}"
            return 0
        fi
    done <"${_parsed}"
    printf '\n'
}

# ab_feed_stepwise <parsed> <installed-platform>: the smallest release above the
# installed one, so one command moves one release and each hop is committed on its own.
ab_feed_stepwise() {
    _parsed=${1:?} _installed=${2:?}
    _best=""
    while IFS='|' read -r _p _rest; do
        [ -n "${_p}" ] || continue
        _cmp=$(ab_version_cmp "${_p}" "${_installed}") || return 1
        [ "${_cmp}" -gt 0 ] || continue
        if [ -z "${_best}" ]; then
            _best=${_p}
            continue
        fi
        _cmp=$(ab_version_cmp "${_p}" "${_best}") || return 1
        [ "${_cmp}" -lt 0 ] && _best=${_p}
    done <"${_parsed}"
    printf '%s\n' "${_best}"
}

ab_feed_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${1}" | awk '{print $1}'
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${1}" | awk '{print $1}'
        return 0
    fi
    return 1
}

# ab_feed_verify_member <file> <entry-line>: the two checks a downloaded payload has
# to pass before it is handed to the installer.
ab_feed_verify_member() {
    _file=${1:?} _entry=${2:?}
    AB_FEED_REASON=""
    [ -f "${_file}" ] || _ab_feed_fail feed-payload-missing || return 1
    _want_size=$(printf '%s\n' "${_entry}" | cut -d'|' -f4)
    _want_sha=$(printf '%s\n' "${_entry}" | cut -d'|' -f5)
    _got_size=$(wc -c <"${_file}" | tr -d ' ')
    [ "${_got_size}" = "${_want_size}" ] || _ab_feed_fail feed-size-mismatch || return 1
    _got_sha=$(ab_feed_sha256 "${_file}") || _ab_feed_fail feed-digest-mismatch || return 1
    [ "${_got_sha}" = "${_want_sha}" ] || _ab_feed_fail feed-digest-mismatch || return 1
    return 0
}

# ab_feed_space_ok <dir> <bytes>: room for the download plus ten percent.
ab_feed_space_ok() {
    _dir=${1:?} _bytes=${2:?}
    # shellcheck disable=SC2034  # cleared per call; a caller prints it only when this fails
    AB_FEED_REASON=""
    _avail_k=$(df -k "${_dir}" 2>/dev/null | awk 'NR == 2 { print $4 }')
    case "${_avail_k}" in
        '' | *[!0-9]*) _ab_feed_fail feed-download-space || return 1 ;;
    esac
    _need_k=$(((_bytes + _bytes / 10 + 1023) / 1024))
    [ "${_avail_k}" -ge "${_need_k}" ] || _ab_feed_fail feed-download-space || return 1
    return 0
}
