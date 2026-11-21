#!/bin/sh
# ab-plugins.sh - the declarative package-source plugins: what a declaration may say, what a
# checked declaration contributes to a transaction, and how a stale one stops contributing.
#
# The whole plugin system is this file plus one seam in platform/lib/upgrade/packages.sh. A
# plugin is a directory of key=value lines, not a program:
#
#   /etc/ab/plugins.d/<label>/plugin.conf   the declaration (upper layer; an upgrade does not
#                                           move it, because the system tree is replaced and
#                                           /etc/ab is not)
#   /etc/ab/plugins.d/<label>/.verdict      the answer of the last `plugins check`: ok|blocked,
#                                           the token behind it, and the digest of the conf it
#                                           speaks for
#
# Two rules hold everywhere here:
#
#   * Nothing in this file runs apk and nothing reaches the network. A plugin declaration is
#     judged as text; "is this feed reachable, and does it shadow the base" is the one question
#     that needs the index, and it belongs to `ab-packages plugins check`.
#   * A plugin contributes nothing until someone has checked it *and* the declaration has not
#     changed since. The digest in the verdict is what makes "changed since" a fact rather than
#     a guess, and the fallback is always the quiet one: no feeds.
#
# Functions:
#   ab_plugins_dir <root>                     the plugins directory of a machine root
#   ab_plugins_labels <root>                  every plugin label, sorted
#   ab_plugins_validate <root> <label>        static verdict; sets AB_PLUGINS_REASON/_KIND/
#                                             _ENABLED/_FEED_COUNT/_PACKAGE_COUNT
#   ab_plugins_feeds <root> <label>           the declared feed URLs, one per line
#   ab_plugins_packages <root> <label>        the declared package names, one per line
#   ab_plugins_digest <root> <label>          sha256 of plugin.conf, or nothing when no tool
#   ab_plugins_verdict_state <root> <label>   ok|blocked|never|stale
#   ab_plugins_verdict_write <root> <label> <verdict> <reason>
#   ab_plugins_describe <root> <label>        one key=value line for `plugins list`
#   ab_plugins_active_feeds <root>            the feeds a transaction may read, label order
#   ab_plugins_active_count <root>            how many plugins contribute
#   ab_plugins_repos_append <root> <out>      append those feeds to an apk repositories file
#   ab_plugins_journal <file> <text>          one timestamped line, or nothing if unwritable
#
# Every refusal is a token a caller prints verbatim, so that a test asserts the reason rather
# than the message.

# Read by the caller.
AB_PLUGINS_REASON=""
AB_PLUGINS_KIND=""
AB_PLUGINS_ENABLED=""
AB_PLUGINS_FEED_COUNT=0
AB_PLUGINS_PACKAGE_COUNT=0

# The one place a declaration may name a key. Everything else is a typo, and a typo must not be
# silently ignored: a plugin whose `package =` line was misspelt installed nothing and said
# nothing, which is the failure mode this list exists to prevent.
_ab_plugins_keys="api kind enabled feed key arch allow-shadow allow-kmod package"

# _ab_plugins_trim <text>: leading and trailing blanks removed.
_ab_plugins_trim() {
    _abt=${1:-}
    _abt=${_abt#"${_abt%%[![:space:]]*}"}
    _abt=${_abt%"${_abt##*[![:space:]]}"}
    printf '%s' "${_abt}"
}

# _ab_plugins_blank <text>: 0 when it holds a blank - a space, or a tab.
#
# Two literal cases rather than a bracket class: a POSIX class inside a `case` pattern is read
# by some `/bin/sh` implementations (busybox ash among them) as the set of characters it can
# see between the brackets, which would make the test mean something else on the device than it
# does on a laptop. The tab is spelled through printf because a literal one is a character no
# reader of this file can see.
_ab_plugins_blank() {
    _ab_plugins_tab=$(printf '\t')
    case "${1:-}" in
        *" "*) return 0 ;;
        *"${_ab_plugins_tab}"*) return 0 ;;
    esac
    return 1
}

# _ab_plugins_root_of <path>: a path with no trailing slash, and empty for "/".
_ab_plugins_root_of() {
    _abr=${1:-}
    while [ "${#_abr}" -gt 1 ] && [ "${_abr%/}" != "${_abr}" ]; do
        _abr=${_abr%/}
    done
    [ "${_abr}" = "/" ] && _abr=""
    printf '%s' "${_abr}"
}

ab_plugins_dir() {
    _abd=$(_ab_plugins_root_of "${1:-/}")
    printf '%s/etc/ab/plugins.d' "${_abd}"
}

# _ab_plugins_conf <root> <label>: the declaration file of one plugin.
_ab_plugins_conf() {
    printf '%s/%s/plugin.conf' "$(ab_plugins_dir "$1")" "$2"
}

# _ab_plugins_verdict <root> <label>: the verdict file of one plugin.
_ab_plugins_verdict() {
    printf '%s/%s/.verdict' "$(ab_plugins_dir "$1")" "$2"
}

ab_plugins_labels() {
    _abl=$(ab_plugins_dir "$1")
    [ -d "${_abl}" ] || return 0
    for _abl_one in "${_abl}"/*; do
        [ -d "${_abl_one}" ] || continue
        printf '%s\n' "${_abl_one##*/}"
    done | LC_ALL=C sort
}

# _ab_plugins_key_known <key>: 0 when the declaration may use it.
_ab_plugins_key_known() {
    for _abk in ${_ab_plugins_keys}; do
        [ "${_abk}" = "$1" ] && return 0
    done
    return 1
}

# _ab_plugins_single <key>: 0 when repeating the key is a fault rather than a list.
_ab_plugins_single() {
    case "$1" in
        feed | package) return 1 ;;
    esac
    return 0
}

# ab_plugins_validate <root> <label>: the static verdict on one declaration. 0 when it may be
# checked (which is not the same as "it contributes"), 1 with a token in AB_PLUGINS_REASON.
ab_plugins_validate() {
    _av_root=$1
    _av_label=$2
    AB_PLUGINS_REASON=""
    AB_PLUGINS_KIND=""
    AB_PLUGINS_ENABLED=""
    AB_PLUGINS_FEED_COUNT=0
    AB_PLUGINS_PACKAGE_COUNT=0

    # The label is a directory name that ends up on an apk command line as `plugin:<label>` and
    # in a /tmp path, so it is limited to what needs no quoting anywhere.
    case "${_av_label}" in
        '' | *[!a-z0-9_-]*) AB_PLUGINS_REASON="plugin-label-invalid" ; return 1 ;;
    esac
    case "${_av_label}" in
        [!a-z0-9]*) AB_PLUGINS_REASON="plugin-label-invalid" ; return 1 ;;
    esac

    _av_conf=$(_ab_plugins_conf "${_av_root}" "${_av_label}")
    if [ ! -f "${_av_conf}" ]; then
        AB_PLUGINS_REASON="plugin-conf-missing"
        return 1
    fi

    _av_api=""
    _av_kind=""
    _av_enabled=""
    _av_key=""
    _av_arch=""
    _av_shadow=""
    _av_kmod=""
    _av_feeds=""
    _av_pkgs=""

    # One pass, everything collected: the faults are judged afterwards in a fixed order, so a
    # declaration wrong in two ways always answers with the same token.
    while IFS= read -r _av_line || [ -n "${_av_line}" ]; do
        case "${_av_line}" in
            '#'*) continue ;;
        esac
        _av_line=$(printf '%s' "${_av_line}" | sed 's/[[:space:]]*$//')
        [ -n "${_av_line}" ] || continue
        case "${_av_line}" in
            *=*) : ;;
            *)
                AB_PLUGINS_REASON="plugin-syntax"
                return 1
                ;;
        esac
        _av_k=$(_ab_plugins_trim "${_av_line%%=*}")
        _av_v=$(_ab_plugins_trim "${_av_line#*=}")
        if ! _ab_plugins_key_known "${_av_k}"; then
            AB_PLUGINS_REASON="plugin-unknown-key"
            return 1
        fi
        case "${_av_k}" in
            api)
                [ -z "${_av_api}" ] || { AB_PLUGINS_REASON="plugin-key-duplicate"; return 1; }
                _av_api=${_av_v}
                ;;
            kind)
                [ -z "${_av_kind}" ] || { AB_PLUGINS_REASON="plugin-key-duplicate"; return 1; }
                _av_kind=${_av_v}
                ;;
            enabled)
                [ -z "${_av_enabled}" ] || { AB_PLUGINS_REASON="plugin-key-duplicate"; return 1; }
                _av_enabled=${_av_v}
                ;;
            key)
                [ -z "${_av_key}" ] || { AB_PLUGINS_REASON="plugin-key-duplicate"; return 1; }
                _av_key=${_av_v}
                ;;
            arch)
                [ -z "${_av_arch}" ] || { AB_PLUGINS_REASON="plugin-key-duplicate"; return 1; }
                _av_arch=${_av_v}
                ;;
            allow-shadow)
                [ -z "${_av_shadow}" ] || { AB_PLUGINS_REASON="plugin-key-duplicate"; return 1; }
                _av_shadow=${_av_v}
                ;;
            allow-kmod)
                [ -z "${_av_kmod}" ] || { AB_PLUGINS_REASON="plugin-key-duplicate"; return 1; }
                _av_kmod=${_av_v}
                ;;
            feed)
                _av_feeds="${_av_feeds}${_av_v}
"
                ;;
            package)
                _av_pkgs="${_av_pkgs}${_av_v}
"
                ;;
        esac
    done <"${_av_conf}"

    # 1. the contract this file implements
    [ "${_av_api}" = "1" ] || { AB_PLUGINS_REASON="plugin-api-unsupported" ; return 1 ; }
    case "${_av_kind}" in
        source | packages) : ;;
        *) AB_PLUGINS_REASON="plugin-kind-invalid" ; return 1 ;;
    esac
    # An absent `enabled` is an enabled plugin: the fail-closed half of this system is the
    # verdict, and a plugin that was written and never checked contributes nothing anyway.
    _av_enabled=${_av_enabled:-yes}
    case "${_av_enabled}" in
        yes | no) : ;;
        *) AB_PLUGINS_REASON="plugin-enabled-invalid" ; return 1 ;;
    esac
    AB_PLUGINS_KIND=${_av_kind}
    AB_PLUGINS_ENABLED=${_av_enabled}
    # Read by the caller: `plugins check` needs the two permissions and the arch to decide
    # what a shadow or a kernel module means for this plugin, and re-reading the file there
    # would be a second parser to keep in step with this one.
    # shellcheck disable=SC2034
    AB_PLUGINS_ARCH=${_av_arch:-noarch}
    # shellcheck disable=SC2034
    AB_PLUGINS_ALLOW_SHADOW=${_av_shadow:-no}
    # shellcheck disable=SC2034
    AB_PLUGINS_ALLOW_KMOD=${_av_kmod:-no}

    # 2. a declaration with nothing in it is not a plugin
    if [ "${_av_kind}" = "source" ] && [ -z "${_av_feeds}" ]; then
        AB_PLUGINS_REASON="plugin-no-feed"
        return 1
    fi
    if [ "${_av_kind}" = "packages" ] && [ -z "${_av_pkgs}" ]; then
        AB_PLUGINS_REASON="plugin-no-package"
        return 1
    fi

    # 3. every feed: a URL apk can fetch, no kernel-module tree, no architecture segment.
    #    The measured device has a /releases/<ver>/kmods/<build hash>/kmods feed whose packages
    #    are built for one kernel; taking those into the world is how a base upgrade stops
    #    booting, which is why the default is to refuse rather than to warn.
    while IFS= read -r _av_url; do
        [ -n "${_av_url}" ] || continue
        case "${_av_url}" in
            http://?* | https://?*) : ;;
            *) AB_PLUGINS_REASON="plugin-feed-scheme" ; return 1 ;;
        esac
        # A feed is one line in the repositories file apk reads, and apk splits that line on
        # blanks: a declaration with a blank in the URL would hand apk a second source the
        # scheme rule above never judged. `plugin-feed-scheme` is the token for "this is not
        # an address apk can read".
        if _ab_plugins_blank "${_av_url}"; then
            AB_PLUGINS_REASON="plugin-feed-scheme"
            return 1
        fi
        if [ "${AB_PLUGINS_ALLOW_KMOD}" != "yes" ]; then
            case "/${_av_url}/" in
                */kmods/*) AB_PLUGINS_REASON="plugin-feed-kmods" ; return 1 ;;
            esac
        fi
        if [ "${AB_PLUGINS_ARCH}" = "noarch" ]; then
            case "/${_av_url}/" in
                */x86_64/* | */x86_64_*/* | */i386_*/* | */aarch64_*/* | */arm_*/* | */mips*/* | */riscv64*/*)
                    AB_PLUGINS_REASON="plugin-feed-arch"
                    return 1
                    ;;
            esac
        fi
    done <<FEEDS
${_av_feeds}
FEEDS

    # 4. every package: an apk package name, and a kernel module needs the same permission a
    #    kmods feed does.
    #
    #    The name is checked against apk's own set before anything else is said about it,
    #    because a package name is a *word on an `apk add` command line*. `package = -X` is an
    #    option, not a package: the same declaration could carry `--allow-untrusted` or
    #    `--force-broken-world` and hand apk a permission this system's guardrails exist to
    #    withhold. Refusing the shape here is what keeps "what a plugin declares" from turning
    #    into "what a plugin does", and the check covers every `package =` line whatever the
    #    kind, because `plugins apply` reads them all.
    while IFS= read -r _av_pkg; do
        [ -n "${_av_pkg}" ] || continue
        case "${_av_pkg}" in
            [!A-Za-z0-9]* | *[!A-Za-z0-9._+-]*)
                AB_PLUGINS_REASON="plugin-package-invalid"
                return 1
                ;;
        esac
        case "${_av_pkg}" in
            kmod-*)
                if [ "${AB_PLUGINS_ALLOW_KMOD}" != "yes" ]; then
                    AB_PLUGINS_REASON="plugin-package-kmod"
                    return 1
                fi
                ;;
        esac
    done <<PKGS
${_av_pkgs}
PKGS

    # 5. the key: this system never imports one, it only refuses to enable a plugin whose key
    #    is not where apk will look for it.
    if [ -n "${_av_key}" ]; then
        case "${_av_key}" in
            /etc/apk/keys/?*) : ;;
            *) AB_PLUGINS_REASON="plugin-key-outside" ; return 1 ;;
        esac
        _av_site=$(_ab_plugins_root_of "${_av_root}")
        if [ ! -f "${_av_site}${_av_key}" ]; then
            AB_PLUGINS_REASON="plugin-key-missing"
            return 1
        fi
    fi

    AB_PLUGINS_FEED_COUNT=$(printf '%s' "${_av_feeds}" | grep -c . || true)
    AB_PLUGINS_PACKAGE_COUNT=$(printf '%s' "${_av_pkgs}" | grep -c . || true)
    AB_PLUGINS_FEED_COUNT=${AB_PLUGINS_FEED_COUNT:-0}
    AB_PLUGINS_PACKAGE_COUNT=${AB_PLUGINS_PACKAGE_COUNT:-0}
    return 0
}

# ab_plugins_feeds <root> <label>: the declared URLs in the order the file lists them. Reading
# the file again instead of keeping a cache is what lets a caller ask about a plugin that has
# not been validated (the CLI's `plugins list` does).
ab_plugins_feeds() {
    _af_conf=$(_ab_plugins_conf "$1" "$2")
    [ -f "${_af_conf}" ] || return 0
    sed -n 's/^[[:space:]]*feed[[:space:]]*=[[:space:]]*//p' "${_af_conf}" \
        | sed 's/[[:space:]]*$//' | grep -v '^$' || true
}

ab_plugins_packages() {
    _ap_conf=$(_ab_plugins_conf "$1" "$2")
    [ -f "${_ap_conf}" ] || return 0
    sed -n 's/^[[:space:]]*package[[:space:]]*=[[:space:]]*//p' "${_ap_conf}" \
        | sed 's/[[:space:]]*$//' | grep -v '^$' || true
}

# _ab_plugins_sha256 <file>: the digest the verdict stores. Nothing when the tool is absent -
# and a missing digest reads as `stale`, which keeps the plugin out instead of guessing it in.
_ab_plugins_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }'
        return 0
    fi
    return 1
}

ab_plugins_digest() {
    _ad_conf=$(_ab_plugins_conf "$1" "$2")
    [ -f "${_ad_conf}" ] || return 1
    _ab_plugins_sha256 "${_ad_conf}"
}

# ab_plugins_verdict_state <root> <label>: ok | blocked | stale | never.
#
#    never   nobody has checked this declaration
#    stale   somebody did, and the declaration has changed since
#    ok      the last check admitted it, for exactly this text
#    blocked the last check refused it, for exactly this text
#
# A blocked plugin that has since been edited reads `stale`, not `blocked`: the verdict stopped
# describing the file, and saying otherwise would keep a fixed plugin refused forever.
ab_plugins_verdict_state() {
    _as_root=$1
    _as_label=$2
    _as_file=$(_ab_plugins_verdict "${_as_root}" "${_as_label}")
    if [ ! -f "${_as_file}" ]; then
        printf 'never'
        return 0
    fi
    _as_verdict=$(sed -n 's/^verdict=//p' "${_as_file}" | head -n 1)
    _as_conf=$(sed -n 's/^conf=//p' "${_as_file}" | head -n 1)
    _as_now=$(ab_plugins_digest "${_as_root}" "${_as_label}") || _as_now=""
    if [ -z "${_as_now}" ] || [ "${_as_conf}" != "${_as_now}" ]; then
        printf 'stale'
        return 0
    fi
    case "${_as_verdict}" in
        ok | blocked) printf '%s' "${_as_verdict}" ;;
        *) printf 'stale' ;;
    esac
}

# ab_plugins_verdict_write <root> <label> <verdict> <reason>: record the answer of a check.
# Returns 1 when the plugin directory cannot be written; the caller reports that, it does not
# pretend a check happened.
ab_plugins_verdict_write() {
    _aw_root=$1
    _aw_label=$2
    _aw_verdict=$3
    _aw_reason=${4:-none}
    _aw_dir="$(ab_plugins_dir "${_aw_root}")/${_aw_label}"
    [ -d "${_aw_dir}" ] || return 1
    _aw_digest=$(ab_plugins_digest "${_aw_root}" "${_aw_label}") || return 1
    _aw_now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    {
        printf 'verdict=%s\n' "${_aw_verdict}"
        printf 'reason=%s\n' "${_aw_reason}"
        printf 'checked=%s\n' "${_aw_now}"
        printf 'conf=%s\n' "${_aw_digest}"
    } >"${_aw_dir}/.verdict" 2>/dev/null || return 1
    return 0
}

# ab_plugins_verdict_reason <root> <label>: the token behind the last verdict, or `none`.
ab_plugins_verdict_reason() {
    _ar_file=$(_ab_plugins_verdict "$1" "$2")
    [ -f "${_ar_file}" ] || { printf 'none'; return 0; }
    _ar_reason=$(sed -n 's/^reason=//p' "${_ar_file}" | head -n 1)
    printf '%s' "${_ar_reason:-none}"
}

# ab_plugins_describe <root> <label>: one line, the same keys in the same order for every
# plugin, so `plugins list` is a table and a test can assert a whole row.
ab_plugins_describe() {
    _ade_root=$1
    _ade_label=$2
    if ! ab_plugins_validate "${_ade_root}" "${_ade_label}"; then
        printf 'label=%s kind=- enabled=- checked=invalid reason=%s feeds=0 packages=0' \
            "${_ade_label}" "${AB_PLUGINS_REASON}"
        return 0
    fi
    printf 'label=%s kind=%s enabled=%s checked=%s reason=%s feeds=%s packages=%s' \
        "${_ade_label}" "${AB_PLUGINS_KIND}" "${AB_PLUGINS_ENABLED}" \
        "$(ab_plugins_verdict_state "${_ade_root}" "${_ade_label}")" \
        "$(ab_plugins_verdict_reason "${_ade_root}" "${_ade_label}")" \
        "${AB_PLUGINS_FEED_COUNT}" "${AB_PLUGINS_PACKAGE_COUNT}"
}

# _ab_plugins_contributes <root> <label>: 0 when this plugin's feeds belong in a transaction.
_ab_plugins_contributes() {
    ab_plugins_validate "$1" "$2" || return 1
    [ "${AB_PLUGINS_ENABLED}" = "yes" ] || return 1
    [ "$(ab_plugins_verdict_state "$1" "$2")" = "ok" ] || return 1
    return 0
}

ab_plugins_active_feeds() {
    _aaf_root=$1
    while IFS= read -r _aaf_label; do
        [ -n "${_aaf_label}" ] || continue
        _ab_plugins_contributes "${_aaf_root}" "${_aaf_label}" || continue
        ab_plugins_feeds "${_aaf_root}" "${_aaf_label}"
    done <<LABELS
$(ab_plugins_labels "${_aaf_root}")
LABELS
}

ab_plugins_active_count() {
    _aac_root=$1
    _aac_n=0
    while IFS= read -r _aac_label; do
        [ -n "${_aac_label}" ] || continue
        _ab_plugins_contributes "${_aac_root}" "${_aac_label}" && _aac_n=$((_aac_n + 1))
    done <<LABELS
$(ab_plugins_labels "${_aac_root}")
LABELS
    printf '%s' "${_aac_n}"
}

# ab_plugins_repos_append <root> <out>: the one seam. The file already holds the machine's own
# repository files, in apk's order; the plugin feeds are appended after them, one per line,
# because apk reads a repositories file top to bottom and the base must win a tie.
#
# Labels are appended in sorted order: two machines with the same declarations read the same
# file, which is what makes `plugins repos` usable as evidence.
ab_plugins_repos_append() {
    _ara_root=$1
    _ara_out=$2
    while IFS= read -r _ara_url; do
        [ -n "${_ara_url}" ] || continue
        printf '%s\n' "${_ara_url}" >>"${_ara_out}" 2>/dev/null || return 1
    done <<FEEDS
$(ab_plugins_active_feeds "${_ara_root}")
FEEDS
    return 0
}

# ab_plugins_journal <file> <text...>: one line, best effort. A plugin event that cannot be
# journalled must not fail a transaction: the journal explains a decision, it does not make it.
ab_plugins_journal() {
    _aj_file=$1
    shift
    [ -n "${_aj_file}" ] || return 0
    _aj_dir=${_aj_file%/*}
    [ -d "${_aj_dir}" ] || mkdir -p "${_aj_dir}" 2>/dev/null || return 0
    _aj_now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    printf '%s %s\n' "${_aj_now}" "$*" >>"${_aj_file}" 2>/dev/null || return 0
    return 0
}
