#!/bin/sh
# software-probe.sh - the community software layer, one row per sample, on a 25.x machine.
#
# ac-3 asks "do the community samples install at all on 25.x, and where does one not", and
# ac-4 asks "does each app's own configuration survive a version hop". Both questions are
# answered from the same two facts per sample - the package and the config file - so one
# driver owns both halves: the install side (the default action) and the baseline/compare
# pair the device operator calls around every hop.
#
#   software-probe.sh                          # install every sample, one row each
#   software-probe.sh --sample luci-app-ttyd   # one sample, for a rerun of a single GAP
#   software-probe.sh --third-party-url URL    # a feed the samples need, device side only
#   software-probe.sh --baseline hop-1         # what the apps own before a hop
#   software-probe.sh --compare hop-1          # ... and what they own after it
#   software-probe.sh --cleanup                # put the machine back the way it was
#   AB_DRY_RUN=1 software-probe.sh             # print the plan, contact nothing
#
# The sample list is read from tests/fixtures/software-samples.json, never from this file.
# A sample added to the fixture has to show up here without an edit, a sample removed from
# it must not linger in a shell array, and "which samples did we conclude on" has exactly
# one answer - the fixture that ac-3 ships as evidence.
#
# What a row means
# ----------------
#   SW-<name>   PASS|FAIL|GAP   <log>   version=<v> config=<path> sha256=<8> ui=200
#
# PASS needs all three post-install facts: `apk list --installed` names the package (with
# the version recorded in the row), the config file the app owns is present with the content
# this driver wrote, and LuCI answers 200 over loopback. A sample that does not install is
# GAP and never PASS: the row carries a reason token and the command that failed, because
# the reason ("the repo ships no apk asset", "the feed is unreachable") is the finding and
# not this driver's opinion of it.
#
# Why the samples are installed from the fixture's own URLs
# --------------------------------------------------------
# The fixture pins one URL per sample plus a `fallback` sentence for when the pin rots. The
# driver installs what the pin names and, on failure, leaves that `fallback` text in the
# evidence log instead of inventing a second source list here: a fallback taken silently
# would make a row say "installed" about a package nobody recorded.
#
# Where third-party feeds go, and how they leave
# ----------------------------------------------
# Only ever /etc/apk/repositories.d/ (one file, ab-samples.list, written from
# --third-party-url). Nothing is appended to /etc/apk/repositories, no feed is written into
# the image, and `--cleanup` removes the file - or restores the original when one was
# already there - together with the sample packages and the config files this run wrote.
# A direct `.apk` sample needs no feed at all, which is why installing one leaves no source
# behind to clean up.
#
# Only 25.x
# ---------
# 24.x is opkg: another package manager, another kernel-module layout, another firewall, so
# a verdict from it says nothing about this project (the same rule scripts/device/lib.sh
# enforces for payloads). The machine's own base line is checked before anything is
# installed and a machine below 25 stops the run (exit 3); a *sample* pinned to a 24.x path
# is refused with reason=24x-out-of-scope and does not take the other samples down with it.
#
# Exit status: 0 every row PASS, 1 at least one row FAIL, 2 usage, 3 red line (the machine
# or the manifest is not on a 25.x base line), 4 no FAIL but at least one GAP.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"
# shellcheck source=tests/lib/device_config.sh
. "${AB_REPO_ROOT}/tests/lib/device_config.sh"

MANIFEST=${AB_SWPROBE_MANIFEST:-${AB_REPO_ROOT}/tests/fixtures/software-samples.json}
RESULTS=${AB_RESULTS:-software-probe-results.tsv}
EVIDENCE_DIR=${AB_EVIDENCE_DIR:-}
# The state of a run belongs beside that run's rows, not in whatever directory the caller
# happened to be standing in. Defaulting to a bare relative name left software-probe-state/
# in the repository root of a full round, where it showed up as an untracked directory and as
# "changes outside task scope" - a driver's working file refusing a commit it has nothing to
# do with. RESULTS is the row channel full-test.sh already hands over, so its directory is
# the one that is guaranteed to be the round's own.
if [ -n "${AB_SWPROBE_STATE:-}" ]; then
    STATE_DIR=${AB_SWPROBE_STATE}
elif [ -n "${RESULTS:-}" ]; then
    STATE_DIR=${RESULTS%/*}/software-state
else
    STATE_DIR=software-probe-state
fi
DRY_RUN=${AB_DRY_RUN:-0}

# The one file this driver is allowed to add to the device's source list.
SOURCES_PATH=/etc/apk/repositories.d/ab-samples.list
# The suffix of the copies taken beside the files this run touches: one name, so a leftover
# is recognisable on a machine somebody else is looking at.
BAK_SUFFIX=.swprobe-bak
# Where a pinned .apk is fetched to before it is installed. /tmp is cleared by a reboot, so a
# leftover there cannot outlive the run that made it, and --cleanup removes it anyway.
DOWNLOAD_DIR=/tmp
# Field separator of the manifest dump and of every state file. A literal tab, spelled once.
TAB=$(printf '\t')

ACTION=install
ACTION_SET=0
TAG=""
WANT_SAMPLES=""
THIRD_PARTY_URLS=""
CHECKS=0
FAILURES=0
GAPS=0
_manifest_records=""

usage() {
    cat <<'USAGE'
usage: software-probe.sh [--sample NAME]... [--manifest FILE] [--results FILE]
                         [--evidence-dir DIR] [--state-dir DIR]
                         [--third-party-url URL]... [--baseline TAG | --compare TAG]
                         [--cleanup] [--dry-run]

  --sample NAME        only this sample, repeatable; default is every sample in the manifest
  --manifest FILE      the sample list (default tests/fixtures/software-samples.json)
  --results FILE       results TSV to append to (default $AB_RESULTS, else results.tsv)
  --evidence-dir DIR   where the per-case logs go (default <results dir>/evidence)
  --state-dir DIR      what --baseline wrote and --cleanup needs (default software-probe-state)
  --third-party-url URL
                       a feed the samples need; written device side only, to
                       /etc/apk/repositories.d/ab-samples.list, and removed by --cleanup
  --baseline TAG       record the apps' config and versions before a hop
  --compare TAG        compare them with what they are now, after the hop
  --cleanup            remove the samples, their config and the added source
  --dry-run            print the plan; no ssh call, no result file, no row

Exit status: 0 every row PASS, 1 a row FAIL, 2 usage, 3 not a 25.x machine, 4 a GAP.
USAGE
}

# _one_action <flag>: one action per run. --baseline hop-1 --cleanup would have to mean
# something, and the only thing it could mean is "whichever the loop saw last", so it is a
# usage error instead.
_one_action() {
    if [ "${ACTION_SET}" -eq 1 ]; then
        printf 'software-probe.sh: one action per run: %s after --%s\n' "${1}" "${ACTION}" >&2
        return 1
    fi
    ACTION_SET=1
    return 0
}

while [ "$#" -gt 0 ]; do
    case "${1}" in
        --sample)
            WANT_SAMPLES="${WANT_SAMPLES}${2:?--sample needs a name}
"
            shift 2
            ;;
        --manifest)
            MANIFEST=${2:?--manifest needs a file}
            shift 2
            ;;
        --results)
            RESULTS=${2:?--results needs a file}
            shift 2
            ;;
        --evidence-dir)
            EVIDENCE_DIR=${2:?--evidence-dir needs a directory}
            shift 2
            ;;
        --state-dir)
            STATE_DIR=${2:?--state-dir needs a directory}
            shift 2
            ;;
        --third-party-url)
            THIRD_PARTY_URLS="${THIRD_PARTY_URLS}${2:?--third-party-url needs a URL}
"
            shift 2
            ;;
        --baseline)
            _one_action "${1:?}" || exit 2
            ACTION=baseline
            TAG=${2:?--baseline needs a tag}
            shift 2
            ;;
        --compare)
            _one_action "${1:?}" || exit 2
            ACTION=compare
            TAG=${2:?--compare needs a tag}
            shift 2
            ;;
        --cleanup)
            _one_action "${1:?}" || exit 2
            ACTION=cleanup
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            ACTION=help
            shift
            ;;
        *)
            printf 'software-probe.sh: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "${ACTION}" = "help" ]; then
    usage
    exit 0
fi
if [ "${ACTION}" != "install" ] && [ -n "${WANT_SAMPLES}" ]; then
    printf 'software-probe.sh: --sample belongs with the install action, not with --%s\n' \
        "${ACTION}" >&2
    exit 2
fi

AB_RESULTS=${RESULTS}
DEVCFG_RESULTS=${RESULTS}
AB_EVIDENCE_LOG=""
export AB_RESULTS DEVCFG_RESULTS AB_EVIDENCE_LOG
# The one command a red row tells the reader to run. devcfg_record and devcfg_assert_same
# print it verbatim, so it has to be the driver that produced the row.
AB_MATRIX_CMD="sh ${DEVICE_DIR}/software-probe.sh"
export AB_MATRIX_CMD
if [ "${DRY_RUN}" = "1" ]; then
    # Belt and braces: the plan below never calls, and every ssh helper refuses anyway.
    AB_DRY_RUN=1
    export AB_DRY_RUN
fi

if [ "${DRY_RUN}" != "1" ]; then
    [ -n "${EVIDENCE_DIR}" ] || EVIDENCE_DIR=$(dirname "${RESULTS}")/evidence
    mkdir -p "${EVIDENCE_DIR}" 2>/dev/null || EVIDENCE_DIR=""
fi

# --------------------------------------------------------------------------- #
# Rows
# --------------------------------------------------------------------------- #

# _record <case> <verdict> <evidence> <note>: one row, counted, written through the shared
# library so the format and the verdict vocabulary are the ones every driver uses.
_record() {
    CHECKS=$((CHECKS + 1))
    case "${2}" in
        FAIL) FAILURES=$((FAILURES + 1)) ;;
        GAP) GAPS=$((GAPS + 1)) ;;
        *) : ;;
    esac
    devcfg_record "$@"
}

# _count_recorded <case>: a helper that records its own row (devcfg_assert_same) cannot be
# counted on the way in, so read the verdict back. Rows are append-only and this run writes
# the last one for its case.
_count_recorded() {
    _cr_verdict=$(awk -F'\t' -v c="${1}" '$1 == c { v = $2 } END { if (v != "") print v }' \
        "${RESULTS}" 2>/dev/null)
    CHECKS=$((CHECKS + 1))
    case "${_cr_verdict}" in
        FAIL) FAILURES=$((FAILURES + 1)) ;;
        GAP) GAPS=$((GAPS + 1)) ;;
        *) : ;;
    esac
}

# _evidence <case>: the log this case's row points at, created on demand so a row never
# names a file that does not exist. A dry run is a plan, so it names none.
_evidence() {
    if [ "${DRY_RUN}" = "1" ] || [ -z "${EVIDENCE_DIR}" ]; then
        printf '%s' "-"
        return 0
    fi
    mkdir -p "${EVIDENCE_DIR}" 2>/dev/null &&
        : >>"${EVIDENCE_DIR}/${1}.log" 2>/dev/null || {
        printf '%s' "-"
        return 0
    }
    printf '%s' "${EVIDENCE_DIR}/${1}.log"
}

# _log <evidence> <text...>: what the reader of a row needs and the row has no room for -
# the command that ran, what it answered, the fixture's own fallback sentence.
_log() {
    _lg_ev=${1:-}
    shift || true
    [ -n "${_lg_ev}" ] && [ "${_lg_ev}" != "-" ] || return 0
    printf '%s\n' "$@" >>"${_lg_ev}" 2>/dev/null || true
}

_finish() {
    printf 'software-probe rows=%s failed=%s gaps=%s\n' "${CHECKS}" "${FAILURES}" "${GAPS}"
    if [ "${FAILURES}" -gt 0 ]; then
        return 1
    fi
    if [ "${GAPS}" -gt 0 ]; then
        return 4
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# The manifest
# --------------------------------------------------------------------------- #

# _manifest_dump [file]: the manifest as flat records, one per line:
#   meta    <key>   <value>              (schema, updated, version_line)
#   sample  <name>  <kind>  <url>  <fetched_at>  <fallback>
#
# A flat reader in awk and not a dependency on python3, because this driver runs where only
# the repo is; see the shape it reads in tests/fixtures/software-samples.json. Non-string
# members are ignored except at the top level, where the schema number is still a fact.
_manifest_dump() {
    LC_ALL=C awk '
        function unesc(e) {
            if (e == "n") return "\n"
            if (e == "t") return "\t"
            if (e == "r") return "\r"
            return e
        }
        function flush_sample() {
            if (objname != "") printf "sample\t%s\t%s\t%s\t%s\t%s\n", objname, objkind, objurl, objfetched, objfallback
            objname = ""
            objkind = ""
            objurl = ""
            objfetched = ""
            objfallback = ""
        }
        { text = text $0 "\n" }
        END {
            n = length(text)
            i = 1
            depth = 0
            inobj = 0
            objdepth = 0
            arrdepth = -1
            key = ""
            while (i <= n) {
                c = substr(text, i, 1)
                if (c == "\"") {
                    str = ""
                    i++
                    while (i <= n) {
                        ch = substr(text, i, 1)
                        if (ch == "\\") {
                            str = str unesc(substr(text, i + 1, 1))
                            i += 2
                            continue
                        }
                        if (ch == "\"") {
                            i++
                            break
                        }
                        str = str ch
                        i++
                    }
                    j = i
                    while (j <= n) {
                        d = substr(text, j, 1)
                        if (d == " " || d == "\t" || d == "\n" || d == "\r") {
                            j++
                            continue
                        }
                        break
                    }
                    if (substr(text, j, 1) == ":") {
                        key = str
                    } else {
                        if (inobj) {
                            if (key == "name") objname = str
                            else if (key == "kind") objkind = str
                            else if (key == "source_url") objurl = str
                            else if (key == "fetched_at") objfetched = str
                            else if (key == "fallback") objfallback = str
                        } else if (depth == 1) {
                            printf "meta\t%s\t%s\n", key, str
                        }
                        key = ""
                    }
                    continue
                }
                if (c == "{") {
                    depth++
                    if (arrdepth >= 0 && depth == arrdepth + 1) {
                        flush_sample()
                        inobj = 1
                        objdepth = depth
                    }
                    i++
                    continue
                }
                if (c == "[") {
                    depth++
                    if (key == "samples") arrdepth = depth
                    i++
                    continue
                }
                if (c == "}" || c == "]") {
                    if (inobj && depth == objdepth) {
                        flush_sample()
                        inobj = 0
                    }
                    if (arrdepth >= 0 && depth == arrdepth && c == "]") arrdepth = -1
                    depth--
                    i++
                    continue
                }
                if (!inobj && depth == 1 && (c ~ /[0-9]/ || c == "-")) {
                    num = ""
                    while (i <= n) {
                        d = substr(text, i, 1)
                        if (d ~ /[0-9.-]/) {
                            num = num d
                            i++
                        } else {
                            break
                        }
                    }
                    printf "meta\t%s\t%s\n", key, num
                    key = ""
                    continue
                }
                i++
            }
            flush_sample()
        }
    ' "${1:-${MANIFEST}}"
}

# _manifest_meta <key>: one top-level value, or nothing.
_manifest_meta() {
    awk -F"${TAB}" -v k="${1}" '$1 == "meta" && $2 == k { print $3; exit }' \
        "${_manifest_records}" 2>/dev/null
}

# _want <name>: is this sample one the caller asked for? An empty --sample list means all.
_want() {
    [ -n "${WANT_SAMPLES}" ] || return 0
    printf '%s\n' "${WANT_SAMPLES}" | grep -qx "${1}"
}

# _load_manifest: read the fixture into _manifest_records, and fail with one sentence when it
# cannot be read or names no samples. A --sample the fixture does not hold is a typo, not an
# empty run: say so instead of printing "rows=0 failed=0" and letting the reader believe the
# sample passed.
_load_manifest() {
    if [ ! -f "${MANIFEST}" ]; then
        printf 'software-probe: %s: no such manifest\n' "${MANIFEST}" >&2
        return 1
    fi
    _manifest_records=$(devcfg_tmpfile) || return 1
    _manifest_dump "${MANIFEST}" >"${_manifest_records}" || return 1
    _lm_count=$(awk -F"${TAB}" '$1 == "sample"' "${_manifest_records}" | wc -l | tr -d ' ')
    if [ "${_lm_count}" -eq 0 ]; then
        printf 'software-probe: %s: the manifest names no samples\n' "${MANIFEST}" >&2
        return 1
    fi
    if [ -n "${WANT_SAMPLES}" ]; then
        _lm_known=$(awk -F"${TAB}" '$1 == "sample" { print $2 }' "${_manifest_records}")
        while IFS= read -r _lm_name; do
            [ -n "${_lm_name}" ] || continue
            if ! printf '%s\n' "${_lm_known}" | grep -qx "${_lm_name}"; then
                printf 'software-probe: --sample %s: not in %s\n' "${_lm_name}" "${MANIFEST}" >&2
                return 2
            fi
        done <<EOF
${WANT_SAMPLES}
EOF
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# The device, as this driver uses it
# --------------------------------------------------------------------------- #

# _machine_base: the base line the machine runs, read from platform-release. Empty means the
# file is not there, which for a machine that answers ssh is itself a finding.
_machine_base() {
    devcfg_exec 'cat /etc/platform-release 2>/dev/null' 2>/dev/null |
        sed -n 's/^UPSTREAM_VERSION=//p' | head -n 1
}

# _ui_code: the HTTP code LuCI answers with on loopback. curl when the machine has it
# (`-w %{http_code}` is the only way to see the code); otherwise uclient-fetch, which can
# only say whether the page answered - 200 when it did, 000 when it did not.
_ui_code() {
    # Deliberately `/` and not `/cgi-bin/luci/`: measured on the n5105 on 2026-11-17, uhttpd
    # answers 200 on `/` and 403 on `/cgi-bin/luci/` on a healthy machine, so a probe that
    # asked for the CGI path called every working sample a failure (`ui=http:403`). The
    # question here is "is the web UI served at all", and the front page answers exactly that.
    _uc=$(devcfg_exec "curl -s -o /dev/null -w '%{http_code}' --max-time 10 'http://127.0.0.1/'" 2>/dev/null) || _uc=""
    _uc=$(printf '%s' "${_uc}" | tr -d ' \t\r\n')
    _uc=$(printf '%s' "${_uc}" | sed -n 's/.*\([1-5][0-9][0-9]\)$/\1/p')
    if [ -n "${_uc}" ]; then
        printf '%s' "${_uc}"
        return 0
    fi
    if devcfg_exec "uclient-fetch -T 10 -O /dev/null 'http://127.0.0.1/'" >/dev/null 2>&1; then
        printf '200'
    else
        printf '000'
    fi
}

# _installed_version <package>: what `apk list --installed` says, or nothing when the
# package is not there. The version is the package's first field minus its name, which is how
# apk prints it: `luci-app-ttyd-26.298.29275~c84adb9 x86_64 {feeds/luci} ...`.
_installed_version() {
    devcfg_exec "apk list --installed $(devcfg_sq "${1}") 2>/dev/null" 2>/dev/null |
        awk -v p="${1}" '$1 ~ ("^" p "-") { v = $1; sub("^" p "-", "", v); print v; exit }'
}

# _app_of <sample>: the config file's stem, from the package name the manifest uses.
# `luci-app-openclash` owns /etc/config/openclash and `luci-theme-argon` owns
# /etc/config/argon; the prefix is dropped and nothing else is guessed.
_app_of() {
    case "${1}" in
        luci-app-*) printf '%s' "${1#luci-app-}" ;;
        luci-theme-*) printf '%s' "${1#luci-theme-}" ;;
        *) printf '%s' "${1}" ;;
    esac
}

# _has_config <name> <kind>: does this sample own a UCI config file? The name says it for the
# two LuCI families; the kind catches a store or an app that is not named that way. A plain
# program (htop) or a kernel module owns no config, and inventing /etc/config/htop would test
# this driver instead of the product: those samples are held to the package half of ac-3, and
# their ac-4 statement is "same version after the hop".
_has_config() {
    case "${1}" in
        luci-app-* | luci-theme-*) return 0 ;;
    esac
    case "${2}" in
        luci-theme | software-store | proxy-app) return 0 ;;
        *) return 1 ;;
    esac
}

# _fetch_sample <name> <url>: download a pinned .apk onto the machine. Fetching and adding are
# two calls on purpose: "the feed is unreachable" and "apk refused the package" are different
# reason tokens in the row, and a single `&&` chain would collapse them.
_fetch_sample() {
    devcfg_exec "uclient-fetch -T 60 -O $(devcfg_sq "${DOWNLOAD_DIR}/ab-swprobe-${1}.apk") $(devcfg_sq "${2}")" \
        >/dev/null 2>&1
}

# _add_sample <name> <url>: the install itself. A pinned .apk is installed as a file, so no
# source is added for it and nothing has to be removed later; a sample without one is asked
# for by name from the feeds that are configured, which is where --third-party-url matters.
_add_sample() {
    case "${2}" in
        *.apk) devcfg_exec "apk add --allow-untrusted $(devcfg_sq "${DOWNLOAD_DIR}/ab-swprobe-${1}.apk")" >/dev/null 2>&1 ;;
        *) devcfg_exec "apk add $(devcfg_sq "${1}")" >/dev/null 2>&1 ;;
    esac
}

# _remove_sample <name>: apk del, best effort - a package that is already gone is the state
# cleanup wants, not an error to report.
_remove_sample() {
    devcfg_exec "apk del $(devcfg_sq "${1}")" >/dev/null 2>&1 || true
}

# _add_sources <urls>: write the added feed to the one place a source may be written. The
# original file, if there is one, is copied first and its name recorded, so --cleanup can
# restore rather than delete somebody else's list.
_add_sources() {
    [ -n "${THIRD_PARTY_URLS}" ] || return 0
    _as_ev=$(_evidence "SW-sources")
    _as_dir=$(dirname "${SOURCES_PATH}")
    if ! devcfg_exec "mkdir -p $(devcfg_sq "${_as_dir}")" >/dev/null 2>&1; then
        _log "${_as_ev}" "mkdir -p ${_as_dir} failed"
        _record "SW-sources" GAP "${_as_ev}" "reason=no-source-dir path=${SOURCES_PATH}"
        return 4
    fi
    _as_had=no
    if devcfg_exec "test -f $(devcfg_sq "${SOURCES_PATH}")" >/dev/null 2>&1; then
        if devcfg_exec "cp -a $(devcfg_sq "${SOURCES_PATH}") $(devcfg_sq "${SOURCES_PATH}${BAK_SUFFIX}")" \
            >/dev/null 2>&1; then
            _as_had=yes
        else
            _log "${_as_ev}" "the original ${SOURCES_PATH} could not be copied; nothing was written"
            _record "SW-sources" GAP "${_as_ev}" "reason=source-backup-failed path=${SOURCES_PATH}"
            return 4
        fi
    fi
    if ! printf '%s' "${THIRD_PARTY_URLS}" | devcfg_exec "cat > $(devcfg_sq "${SOURCES_PATH}")"; then
        _log "${_as_ev}" "writing ${SOURCES_PATH} failed"
        _record "SW-sources" GAP "${_as_ev}" "reason=source-write-failed path=${SOURCES_PATH}"
        return 4
    fi
    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    # The same four columns as written.tsv - path, sha256, whether an original was there, the
    # copy beside it - so one loop in --cleanup can undo both.
    printf '%s\t%s\t%s\t%s\n' "${SOURCES_PATH}" "-" "${_as_had}" "${SOURCES_PATH}${BAK_SUFFIX}" \
        >>"${STATE_DIR}/sources.tsv"
    # apk needs its index refreshed before a feed it has not seen can answer. A failure here
    # is not fatal: a sample that then cannot be found is already a GAP with its own command.
    devcfg_exec 'apk update' >/dev/null 2>&1 ||
        _log "${_as_ev}" "apk update failed after the source was written"
    _log "${_as_ev}" "source=${SOURCES_PATH} had_original=${_as_had}" "urls:" "${THIRD_PARTY_URLS}"
    _record "SW-sources" PASS "${_as_ev}" "path=${SOURCES_PATH} had_original=${_as_had}"
    return 0
}

# --------------------------------------------------------------------------- #
# Config: a real one per app, written through the executor, in a file the run can undo
# --------------------------------------------------------------------------- #

# _config_body <app> <sample>: the content of the config file. Three things are in it because
# a version hop is exactly what damages them: non-ASCII text, a blank line inside the file,
# and quoting (`$`, `%`, `#`, `&`) that a shell-based writer would eat. It is a file the app
# would accept and not a byte pattern: a config the app rejects would make the hop's
# comparison meaningless.
_config_body() {
    sed -e "s/@APP@/${1}/g" -e "s/@NAME@/${2}/g" <<'BODY'
config @APP@ 'main'
	option enabled '1'
	option note '社区样本：@NAME@（跳跃前写入）'

	option title "订阅 & 规则 $HOME 100% #1"
	list domain 'example.com'
	list domain '例子.测试'
	option path '/tmp/规则 目录/key.conf'
BODY
}

# _config_write <app> <sample>: put the body on the machine and verify what landed. The
# original, when there is one, is copied beside it before the write and the name recorded, so
# --cleanup restores it instead of deleting a file the product shipped.
#
# Sets _config_path and _config_sha on success. Returns 1 when the file the machine holds is
# not the file that was sent - which is a finding about the machine, so the caller records it
# as FAIL rather than retrying.
_config_write() {
    _cw_path="/etc/config/${1}"
    _cw_tmp=$(devcfg_tmpfile) || return 3
    _config_body "${1}" "${2}" >"${_cw_tmp}" || return 3
    _cw_sha=$(devcfg_sha256 "${_cw_tmp}") || return 3

    _cw_had=no
    if devcfg_exec "test -f $(devcfg_sq "${_cw_path}")" >/dev/null 2>&1; then
        if ! devcfg_exec "cp -a $(devcfg_sq "${_cw_path}") $(devcfg_sq "${_cw_path}${BAK_SUFFIX}")" \
            >/dev/null 2>&1; then
            rm -f "${_cw_tmp}"
            return 1
        fi
        _cw_had=yes
    fi
    if ! devcfg_exec "cat > $(devcfg_sq "${_cw_path}")" <"${_cw_tmp}"; then
        rm -f "${_cw_tmp}"
        return 1
    fi
    # What landed, not what was sent: the executor may be a stub, a pipe without sftp, or a
    # full disk, and all three look like success at the write end.
    _cw_now=$(devcfg_tmpfile) || {
        rm -f "${_cw_tmp}"
        return 3
    }
    if ! devcfg_exec "cat $(devcfg_sq "${_cw_path}")" >"${_cw_now}" 2>/dev/null; then
        rm -f "${_cw_tmp}" "${_cw_now}"
        return 1
    fi
    _cw_got=$(devcfg_sha256 "${_cw_now}")
    rm -f "${_cw_tmp}" "${_cw_now}"
    [ "${_cw_got}" = "${_cw_sha}" ] || return 1

    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\n' "${_cw_path}" "${_cw_sha}" "${_cw_had}" "${_cw_path}${BAK_SUFFIX}" \
        >>"${STATE_DIR}/written.tsv"
    _config_path=${_cw_path}
    _config_sha=${_cw_sha}
    return 0
}

# _pre_snapshot <app>...: the product as this run found it. Taken once - the first pre.tsv is
# the true original - and compared against after --cleanup, which is the only definition of
# "back the way it was" that does not depend on somebody remembering.
_pre_snapshot() {
    [ -f "${STATE_DIR}/pre.tsv" ] && return 0
    mkdir -p "${STATE_DIR}" 2>/dev/null || return 0
    _ps_paths="${SOURCES_PATH}"
    for _ps_app in "$@"; do
        _ps_paths="${_ps_paths} /etc/config/${_ps_app}"
    done
    # Missing files are the normal starting state (an app that is not installed has no
    # config) and the snapshot records them as missing rather than hiding them.
    # shellcheck disable=SC2086
    devcfg_snapshot "${STATE_DIR}/pre.tsv" ${_ps_paths} >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------- #
# Actions
# --------------------------------------------------------------------------- #

# _install_sample <name> <kind> <url> <fallback>: one row for one sample.
_install_sample() {
    _is_name=${1}
    _is_kind=${2}
    _is_url=${3}
    _is_fallback=${4:-}
    _is_case="SW-${_is_name}"
    _is_app=$(_app_of "${_is_name}")

    if [ "${DRY_RUN}" = "1" ]; then
        case "${_is_url}" in
            *.apk)
                printf 'software-probe: dry-run sample=%s install="uclient-fetch -O %s/ab-swprobe-%s.apk %s; apk add --allow-untrusted %s/ab-swprobe-%s.apk"\n' \
                    "${_is_name}" "${DOWNLOAD_DIR}" "${_is_name}" "${_is_url}" "${DOWNLOAD_DIR}" "${_is_name}"
                ;;
            *)
                printf 'software-probe: dry-run sample=%s install="apk add %s" (from the configured feeds)\n' \
                    "${_is_name}" "${_is_name}"
                ;;
        esac
        if _has_config "${_is_name}" "${_is_kind}"; then
            printf 'software-probe: dry-run sample=%s config=/etc/config/%s (real content, with non-ASCII and quoting)\n' \
                "${_is_name}" "${_is_app}"
            printf 'software-probe: dry-run sample=%s assert="apk list --installed %s; /etc/config/%s; LuCI 200"\n' \
                "${_is_name}" "${_is_name}" "${_is_app}"
        else
            printf 'software-probe: dry-run sample=%s config=none (kind=%s owns no UCI config)\n' \
                "${_is_name}" "${_is_kind}"
            printf 'software-probe: dry-run sample=%s assert="apk list --installed %s; LuCI 200"\n' \
                "${_is_name}" "${_is_name}"
        fi
        return 0
    fi

    _is_ev=$(_evidence "${_is_case}")

    # 24.x is out of scope for the whole round (ac-3), so a sample pinned to it is refused
    # here, by name, and the rest of the samples still run: one rotted entry must not take the
    # sample layer down.
    case "${_is_url}" in
        *.ipk | */releases/24* | *24.*/*)
            _log "${_is_ev}" "sample=${_is_name} url=${_is_url}" \
                "refused: 24.x is opkg, its conclusions do not transfer to the 25.x/apk line (ac-3)"
            _record "${_is_case}" GAP "${_is_ev}" \
                "reason=24x-out-of-scope url=${_is_url} note=drop it from the fixture or re-pin it to 25.x"
            return 0
            ;;
    esac

    _log "${_is_ev}" "sample=${_is_name} kind=${_is_kind} url=${_is_url}"
    _is_rc=0
    case "${_is_url}" in
        *.apk)
            _is_cmd="uclient-fetch -O ${DOWNLOAD_DIR}/ab-swprobe-${_is_name}.apk ${_is_url}"
            _fetch_sample "${_is_name}" "${_is_url}" || _is_rc=$?
            if [ "${_is_rc}" -ne 0 ]; then
                _log "${_is_ev}" "fetch failed rc=${_is_rc}: ${_is_cmd}"
                _log "${_is_ev}" "fixture fallback: ${_is_fallback:-none}"
                _record "${_is_case}" GAP "${_is_ev}" \
                    "reason=fetch-failed rc=${_is_rc} cmd=\"${_is_cmd}\" rerun=\"sh scripts/device/software-probe.sh --sample ${_is_name}\""
                return 0
            fi
            _log "${_is_ev}" "fetched: ${_is_cmd}"
            _is_cmd="apk add --allow-untrusted ${DOWNLOAD_DIR}/ab-swprobe-${_is_name}.apk"
            _add_sample "${_is_name}" "${_is_url}" || _is_rc=$?
            ;;
        *)
            _is_cmd="apk add ${_is_name}"
            _add_sample "${_is_name}" "${_is_url}" || _is_rc=$?
            ;;
    esac
    if [ "${_is_rc}" -ne 0 ]; then
        # Not a product failure and not a pass: the sample could not be put on the machine, and
        # the reason is what the row has to carry.
        _log "${_is_ev}" "install failed rc=${_is_rc}: ${_is_cmd}"
        _log "${_is_ev}" "fixture fallback: ${_is_fallback:-none}"
        _record "${_is_case}" GAP "${_is_ev}" \
            "reason=install-failed rc=${_is_rc} cmd=\"${_is_cmd}\" rerun=\"sh scripts/device/software-probe.sh --sample ${_is_name}\""
        return 0
    fi

    _is_version=$(_installed_version "${_is_name}")
    if [ -z "${_is_version}" ]; then
        _log "${_is_ev}" "${_is_cmd} returned 0, but apk list --installed ${_is_name} names nothing"
        _record "${_is_case}" GAP "${_is_ev}" \
            "reason=not-listed cmd=\"${_is_cmd}\" rerun=\"sh scripts/device/software-probe.sh --sample ${_is_name}\""
        return 0
    fi
    # Both commands stay in the log: ac-3 asks for the command per sample, and a reader who
    # wants to reproduce one sample needs the download as well as the add.
    _log "${_is_ev}" "command: ${_is_cmd}"
    _log "${_is_ev}" "installed ${_is_name}-${_is_version}"

    _is_config=none
    _is_sha=-
    if _has_config "${_is_name}" "${_is_kind}"; then
        _config_path=""
        _config_sha=""
        if ! _config_write "${_is_app}" "${_is_name}"; then
            _log "${_is_ev}" "the config write did not land as written: /etc/config/${_is_app}"
            _record "${_is_case}" FAIL "${_is_ev}" \
                "reason=config-write version=${_is_version} config=/etc/config/${_is_app} rerun=\"sh scripts/device/software-probe.sh --sample ${_is_name}\""
            return 0
        fi
        _is_config=${_config_path}
        _is_sha=$(printf '%s' "${_config_sha}" | cut -c1-8)
        _log "${_is_ev}" "config=${_config_path} sha256=${_config_sha}" \
            "body: non-ASCII, a blank line and quoting, so a hop that mangles any of them shows"
    fi

    _is_ui=$(_ui_code)
    if [ "${_is_ui}" != "200" ]; then
        _log "${_is_ev}" "LuCI answered ${_is_ui} over loopback after installing ${_is_name}"
        _record "${_is_case}" FAIL "${_is_ev}" \
            "reason=ui-not-200 ui=http:${_is_ui} version=${_is_version} config=${_is_config}"
        return 0
    fi

    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "${_is_name}" "${_is_version}" "${_is_url}" >>"${STATE_DIR}/installed.tsv"
    _record "${_is_case}" PASS "${_is_ev}" \
        "version=${_is_version} config=${_is_config} sha256=${_is_sha} ui=200"
    return 0
}

# _each_sample <callback>: walk the manifest's samples the caller asked for, one line at a
# time, in the order the fixture lists them.
_each_sample() {
    while IFS="${TAB}" read -r _es_tag _es_name _es_kind _es_url _es_fetched _es_fallback; do
        [ "${_es_tag}" = "sample" ] || continue
        _want "${_es_name}" || continue
        # `< /dev/null` on purpose: the action runs ssh, and ssh reads stdin - which is the
        # here-document below. Without this, the first sample swallowed the rest of the list and
        # a six-sample run reported one (measured on the n5105, 2026-11-17).
        "$@" "${_es_name}" "${_es_kind}" "${_es_url}" "${_es_fallback}" </dev/null
    done <<EOF
$(cat "${_manifest_records}")
EOF
}

# _action_install: the whole sample layer, one row per sample, with the red line check first.
_action_install() {
    if [ "${DRY_RUN}" = "1" ]; then
        # A plan is not a measurement: it reads no machine line and writes no row, it only says
        # what would be done, so a reviewer can see the sample list without a device.
        printf 'software-probe: dry-run machine="cat /etc/platform-release" (UPSTREAM_VERSION must be 25.x, else exit 3)\n'
        [ -n "${THIRD_PARTY_URLS}" ] &&
            printf 'software-probe: dry-run source=%s urls=%s\n' "${SOURCES_PATH}" "$(printf '%s' "${THIRD_PARTY_URLS}" | tr '\n' ' ')"
        _each_sample _install_sample
        return 0
    fi
    _ai_ev=$(_evidence "SW-machine")
    _ai_base=$(_machine_base)
    if [ -z "${_ai_base}" ]; then
        _log "${_ai_ev}" "cat /etc/platform-release answered nothing, or holds no UPSTREAM_VERSION"
        _record "SW-machine" GAP "${_ai_ev}" "reason=no-base-line"
        return 4
    fi
    _log "${_ai_ev}" "base=${_ai_base}"
    case "${_ai_base%%.*}" in
        '' | *[!0-9]*)
            _record "SW-machine" GAP "${_ai_ev}" "reason=unreadable-base base=${_ai_base}"
            return 4
            ;;
    esac
    if [ "${_ai_base%%.*}" -lt 25 ]; then
        printf 'software-probe: %s is below 25; this project covers only the 25.x/apk line (24.x is opkg-era and out of scope)\n' \
            "${_ai_base}" >&2
        _log "${_ai_ev}" "refused: base=${_ai_base} is below 25"
        _record "SW-machine" GAP "${_ai_ev}" "reason=line-below-25 base=${_ai_base}"
        return 3
    fi
    _record "SW-machine" PASS "${_ai_ev}" "base=${_ai_base}"

    # The product as found, before the first thing this run changes.
    _ai_apps=""
    _ai_names=$(awk -F"${TAB}" '$1 == "sample" { print $2 "\t" $3 }' "${_manifest_records}")
    while IFS="${TAB}" read -r _ai_name _ai_kind; do
        [ -n "${_ai_name}" ] || continue
        _want "${_ai_name}" || continue
        _has_config "${_ai_name}" "${_ai_kind}" && _ai_apps="${_ai_apps} $(_app_of "${_ai_name}")"
    done <<EOF
${_ai_names}
EOF
    # shellcheck disable=SC2086
    _pre_snapshot ${_ai_apps}

    _add_sources || true

    _each_sample _install_sample
    return 0
}

# _installed_version_before <versions-file> <name>: the version a baseline recorded.
_installed_version_before() {
    awk -F"${TAB}" -v n="${2}" '$1 == n { print $2; exit }' "${1}" 2>/dev/null
}

# _baseline_sample <name> <kind> <url> <fallback>: one sample's baseline.
_baseline_sample() {
    _bs_version=$(_installed_version "${1}")
    if [ -z "${_bs_version}" ]; then
        _record "SW-${1}-base@${TAG}" GAP "${_bl_ev}" \
            "reason=not-installed note=install the samples before taking a baseline"
        return 0
    fi
    printf '%s\t%s\n' "${1}" "${_bs_version}" >>"${_bl_dir}/versions.tsv"
    if ! _has_config "${1}" "${2}"; then
        _record "SW-${1}-base@${TAG}" PASS "${_bl_ev}" "version=${_bs_version} config=none kind=${2}"
        return 0
    fi
    _bs_app=$(_app_of "${1}")
    if devcfg_snapshot "${_bl_dir}/${1}.tsv" "/etc/config/${_bs_app}"; then
        _record "SW-${1}-base@${TAG}" PASS "${_bl_ev}" \
            "version=${_bs_version} config=/etc/config/${_bs_app}"
    else
        _record "SW-${1}-base@${TAG}" GAP "${_bl_ev}" \
            "reason=config-missing version=${_bs_version} config=/etc/config/${_bs_app}"
    fi
    return 0
}

# _action_baseline: what each installed sample owns right now. The snapshot files are the only
# thing --compare needs, so they live in the state directory and are named after the hop.
_action_baseline() {
    _bl_dir="${STATE_DIR}/base-${TAG}"
    if [ "${DRY_RUN}" = "1" ]; then
        _each_sample _baseline_dry
        return 0
    fi
    _bl_ev=$(_evidence "SW-baseline-${TAG}")
    _log "${_bl_ev}" "baseline tag=${TAG} dir=${_bl_dir}"
    if ! mkdir -p "${_bl_dir}" 2>/dev/null; then
        _record "SW-baseline-${TAG}" GAP "${_bl_ev}" "reason=no-state-dir dir=${_bl_dir}"
        return 4
    fi
    : >"${_bl_dir}/versions.tsv"
    _each_sample _baseline_sample
    return 0
}

# _baseline_dry: the plan for --baseline, printed without touching the machine.
_baseline_dry() {
    printf 'software-probe: dry-run baseline sample=%s tag=%s config=%s version (snapshot pair for --compare)\n' \
        "${1}" "${TAG}" "$(if _has_config "${1}" "${2}"; then printf '/etc/config/%s' "$(_app_of "${1}")"; else printf none; fi)"
    return 0
}

# _compare_sample <name> <kind> <url> <fallback>: one sample's ac-4 statement after a hop.
_compare_sample() {
    _cs_version=$(_installed_version "${1}")
    _cs_base=$(_installed_version_before "${_cp_dir}/versions.tsv" "${1}")
    if [ -z "${_cs_version}" ]; then
        _record "SW-${1}-pkg@${TAG}" GAP "${_cp_ev}" \
            "reason=not-installed base=${_cs_base:--} rerun=\"sh scripts/device/software-probe.sh --sample ${1}\""
    elif [ "${_cs_version}" = "${_cs_base}" ]; then
        _record "SW-${1}-pkg@${TAG}" PASS "${_cp_ev}" "version=${_cs_version}"
    else
        _log "${_cp_ev}" "${1}: version ${_cs_base:--} -> ${_cs_version} across the hop"
        _record "SW-${1}-pkg@${TAG}" FAIL "${_cp_ev}" \
            "reason=version-changed base=${_cs_base:--} now=${_cs_version}"
    fi
    _has_config "${1}" "${2}" || return 0
    _cs_app=$(_app_of "${1}")
    if [ ! -f "${_cp_dir}/${1}.tsv" ]; then
        _record "SW-${1}-config@${TAG}" GAP "${_cp_ev}" \
            "reason=no-baseline-file config=/etc/config/${_cs_app}"
        return 0
    fi
    devcfg_snapshot "${_cp_now_dir}/${1}.tsv" "/etc/config/${_cs_app}" >/dev/null 2>&1 || true
    _cs_out=$(devcfg_assert_same "SW-${1}-config@${TAG}" \
        "${_cp_dir}/${1}.tsv" "${_cp_now_dir}/${1}.tsv" "${_cp_ev}" 2>&1) || true
    _count_recorded "SW-${1}-config@${TAG}"
    if [ -n "${_cs_out}" ]; then
        # devcfg_assert_same prints the differing lines and the rerun to stdout, because its
        # reader is a person at a terminal. A report reads the file the row points at, so the
        # same lines are kept there too.
        printf '%s\n' "${_cs_out}"
        _log "${_cp_ev}" "${_cs_out}"
    fi
    return 0
}

# _action_compare: ac-4, per sample, after a hop. The config is compared as a snapshot pair
# through the shared devcfg_diff (value-for-value by sha256, and the differing lines are
# printed on failure), and the package as "still installed, still this version" - which is the
# only ac-4 statement a sample without a config file can make.
_action_compare() {
    _cp_dir="${STATE_DIR}/base-${TAG}"
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'software-probe: dry-run compare tag=%s against=%s (config snapshot diff + package version per sample)\n' \
            "${TAG}" "${_cp_dir}"
        return 0
    fi
    _cp_ev=$(_evidence "SW-compare-${TAG}")
    _log "${_cp_ev}" "compare tag=${TAG} against ${_cp_dir}"
    if [ ! -d "${_cp_dir}" ]; then
        _record "SW-compare-${TAG}" GAP "${_cp_ev}" \
            "reason=no-baseline dir=${_cp_dir} note=run --baseline ${TAG} before the hop"
        return 4
    fi
    _cp_now_dir="${STATE_DIR}/now-${TAG}"
    mkdir -p "${_cp_now_dir}" 2>/dev/null || true
    _each_sample _compare_sample
    return 0
}

# _action_cleanup: put the machine back the way the run found it. Packages, config files, the
# added source, and the downloaded .apk files; then the pre-run snapshot is compared with what
# is there now, because "I removed the file" and "the machine is as it was" are different
# claims and the second one is the one that matters.
_action_cleanup() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'software-probe: dry-run cleanup state=%s ("apk del" the samples, restore or remove their config, remove %s)\n' \
            "${STATE_DIR}" "${SOURCES_PATH}"
        return 0
    fi
    _cl_ev=$(_evidence "SW-cleanup")
    if [ ! -f "${STATE_DIR}/pre.tsv" ]; then
        _record "SW-cleanup" GAP "${_cl_ev}" \
            "reason=no-state dir=${STATE_DIR} note=nothing is known to have been changed by this driver"
        return 4
    fi

    # 1. the packages
    _cl_left=""
    _cl_count=0
    if [ -f "${STATE_DIR}/installed.tsv" ]; then
        while IFS="${TAB}" read -r _cl_name _cl_version _cl_url; do
            [ -n "${_cl_name}" ] || continue
            _cl_count=$((_cl_count + 1))
            _remove_sample "${_cl_name}"
            _cl_still=$(_installed_version "${_cl_name}")
            [ -z "${_cl_still}" ] || _cl_left="${_cl_left} ${_cl_name}"
        done <"${STATE_DIR}/installed.tsv"
    fi
    devcfg_exec "rm -f ${DOWNLOAD_DIR}/ab-swprobe-*.apk" >/dev/null 2>&1 || true
    if [ -z "${_cl_left}" ]; then
        _record "SW-cleanup-pkg" PASS "${_cl_ev}" "removed=${_cl_count}"
    else
        _log "${_cl_ev}" "still installed after apk del:${_cl_left}"
        _record "SW-cleanup-pkg" FAIL "${_cl_ev}" "reason=still-installed packages=${_cl_left# }"
    fi

    # 2. the config files and the source file: restore what was there, remove what this run
    # created, and delete the copies either way.
    for _cl_list in written.tsv sources.tsv; do
        [ -f "${STATE_DIR}/${_cl_list}" ] || continue
        while IFS="${TAB}" read -r _cl_path _cl_sha _cl_had _cl_bak; do
            [ -n "${_cl_path}" ] || continue
            if [ "${_cl_had}" = "yes" ]; then
                devcfg_exec "cp -a $(devcfg_sq "${_cl_bak}") $(devcfg_sq "${_cl_path}")" >/dev/null 2>&1 ||
                    _log "${_cl_ev}" "restore failed: ${_cl_bak} -> ${_cl_path}"
            else
                devcfg_exec "rm -f $(devcfg_sq "${_cl_path}")" >/dev/null 2>&1 ||
                    _log "${_cl_ev}" "remove failed: ${_cl_path}"
            fi
            devcfg_exec "rm -f $(devcfg_sq "${_cl_bak}")" >/dev/null 2>&1 || true
        done <"${STATE_DIR}/${_cl_list}"
    done

    # 3. is the machine where it was? The paths come from the pre-run snapshot, so a file this
    # run never touched is not compared by accident.
    _cl_paths=$(cut -f1 "${STATE_DIR}/pre.tsv")
    # shellcheck disable=SC2086
    devcfg_snapshot "${STATE_DIR}/post.tsv" ${_cl_paths} >/dev/null 2>&1 || true
    _cl_out=$(devcfg_assert_same "SW-cleanup" "${STATE_DIR}/pre.tsv" "${STATE_DIR}/post.tsv" \
        "${_cl_ev}" 2>&1) || true
    _count_recorded "SW-cleanup"
    if [ -n "${_cl_out}" ]; then
        printf '%s\n' "${_cl_out}"
        _log "${_cl_ev}" "${_cl_out}"
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

_load_manifest || _load_rc=$?
case "${_load_rc:-0}" in
    0) : ;;
    2) exit 2 ;;
    *)
        printf 'software-probe: the sample manifest could not be read; nothing was probed\n' >&2
        exit 4
        ;;
esac

_line=$(_manifest_meta "version_line")
if [ "${_line}" != "25.x" ]; then
    # A manifest that is not pinned to the 25.x line would produce rows whose conclusions the
    # rest of the round cannot use, which is a red line rather than a warning.
    printf 'software-probe: %s: version_line=%s, this round covers 25.x only\n' \
        "${MANIFEST}" "${_line:-missing}" >&2
    if [ "${DRY_RUN}" != "1" ]; then
        _record "SW-manifest" GAP "$(_evidence "SW-manifest")" \
            "reason=line-out-of-scope version_line=${_line:-missing} manifest=${MANIFEST}"
    fi
    exit 3
fi

echo "software-probe start manifest=${MANIFEST} action=${ACTION} dry_run=${DRY_RUN}"

_ai_rc=0
case "${ACTION}" in
    install) _action_install || _ai_rc=$? ;;
    baseline) _action_baseline || _ai_rc=$? ;;
    compare) _action_compare || _ai_rc=$? ;;
    cleanup) _action_cleanup || _ai_rc=$? ;;
    *) usage >&2; exit 2 ;;
esac

if [ "${DRY_RUN}" = "1" ]; then
    printf 'software-probe: dry run, nothing was contacted and no row was written\n'
    exit "${_ai_rc}"
fi

_finish
_rc=$?
[ "${_ai_rc}" -eq 3 ] && exit 3
exit "${_rc}"
