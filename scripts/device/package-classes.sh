#!/bin/sh
# package-classes.sh - ac-12 and ac-13: three kinds of package, each with its own source,
# carried across a base hop with its fake configuration and its /data marker intact.
#
#   scripts/device/package-classes.sh                    # the whole chain
#   scripts/device/package-classes.sh --only C1          # one hop
#   scripts/device/package-classes.sh --from 2           # resume at C2 (steps 1-2)
#   scripts/device/package-classes.sh --resume           # skip the hops already PASS
#   scripts/device/package-classes.sh --dry-run          # print the chain, touch nothing
#
# A package installed from a feed follows the base by itself, because `apk upgrade` asks the
# new base's own feeds for every world entry. That is true of a package the base ships an
# index for, and it is exactly the case that proves nothing about the other two: a package
# from the user's own source and a package that has no source at all. ac-12 asks whether all
# three survive a hop with their configuration and their /data marker byte-identical, and
# ac-13 asks whether the user's own source is still the same file, still resolvable and still
# able to serve a package nobody installed from it yet. Both are answered from three
# independent sources, so one failure is never masked by the other two:
#
#   class         source                                          installed with
#   distfeeds     /etc/apk/repositories.d/distfeeds.list, the      apk add <pkg>
#                 base's own feed, rewritten by every hop
#   customfeeds   /etc/apk/repositories.d/customfeeds.list, the    apk add --repository <url> <pkg>
#                 user's own source, which the aligner never
#                 rewrites (platform/lib/upgrade/packages.sh:217,445,708)
#   local         an .apk file and nothing else: no feed knows      apk add --allow-untrusted,
#                 the package, and the body is kept in             through `ab-packages replay`
#                 /etc/apk/ab/local/ (platform/lib/ab-pkgs-assets.sh)
#
# What each class has to show after a hop, and why that is its own question
# ------------------------------------------------------------------------
# distfeeds   the record is still installed, the binary still runs (the class's own check
#             command and ERE), and the *new* base's own feed still offers the name - an
#             installed version the new feed has never heard of is the state this chain is
#             here to catch. Whether the version moved is recorded in the row and not
#             judged - `versions=distfeeds:held` or `versions=distfeeds:3.3.0-r1->3.5.3-r0`:
#             the five user-space indexes of 25.12.0/1/2 are byte-identical
#             (research/historical-feeds.md §2), so a held version is the expected answer and
#             a moved one would be the finding.
# customfeeds the file is byte-identical to the baseline (sha256, not "the URL is somewhere
#             in it": what the aligner could do is rewrite a line, and a URL match would not
#             notice), `ab-packages sources` still names that URL as a source of the sample,
#             and a package this chain has not installed yet can still be fetched from that
#             URL *alone* and installed. The last one is done for real - fetch, add,
#             `apk del` - because a source that only answers an index is not a source that
#             can still be installed from; the removal keeps the world of the next hop
#             comparable with the one of this hop, and is recorded.
# local       the apk record is still there, the kept body is still in /etc/apk/ab/local/
#             under the same name and the same sha256, and `ab-packages replay` installs it
#             again with exit 0. Replay is the only criterion that means anything here: apk
#             itself keeps no body (`/var` is a tmpfs, measured 2026-11-18), so "the package
#             is still installed" says nothing about whether it can be installed on the base
#             the machine now runs. A body whose name a feed starts offering is `superseded`
#             by design (ab-pkgs-assets.sh:31) and is not a local package any more; this
#             driver reports that as the store deleting it, not as a chain defect.
#
# Where a local body comes from, and why `auto` exists
# ---------------------------------------------------
# The class needs a body no feed offers, and neither the machine nor the checkout keeps one:
# `/var` is a tmpfs, so an `.apk` installed from a file is gone when the transaction ends
# (measured 2026-11-18). Three ways to supply one, and each says something different:
#
#   --local-apk <file>  an operator's own file. The real thing, and the only form that
#                       proves a body from outside this repository replays.
#   --local-pkg <name>  a body the machine already keeps in /etc/apk/ab/local/, which is the
#                       state of a machine where a local package was installed earlier.
#   --local-apk auto    this driver builds one. It exists because the acceptance round of
#                       2026-11-19 ran this chain with neither and recorded
#                       `local:no-body` as a GAP on every attempt - a row that reads as a
#                       product defect while it is a missing fixture. The body is a real apk
#                       archive in the two-member v2 container apk-tools still reads, so the
#                       proof is still the product's own `apk add --allow-untrusted`, not a
#                       stub. What it cannot prove is that an operator's own file replays;
#                       that is what --local-apk <file> is for.
#
# `auto` is not the default. A bare run keeps answering `local:no-body` and names the flags,
# because "which package is the local sample" is an environment fact this driver must not
# invent behind an operator's back; the orchestrator asks for it explicitly.
#
# World entries, and the one legitimate way one can disappear
# ----------------------------------------------------------
# Every class's entry in /etc/apk/world has to survive the hop. The one recorded exception is
# the follow's own prune: a world entry the target's feeds do not offer poisons every later
# apk transaction on the slot, so the follow drops it and names it in its record
# (platform/lib/upgrade/packages.sh:630, `world_dropped=<n> dropped=<names>`). An entry that
# is gone and named there is recorded as `world_dropped=<name>` and judged no further; one
# that is gone and not named is a FAIL of its class, because nothing on the machine accounts
# for it.
#
# The sample set is installed and marked ONCE, before the first hop, and never re-marked: a
# second mark after a hop would record the post-hop configuration as the truth, which is
# precisely the fact the hop is here to measure. The baseline (versions, the two sha256 values
# per class, the body, the customfeeds bytes) lives on the operator's machine, because /tmp on
# the device is a tmpfs and would be gone exactly when it is needed (the same reason
# follow-probe.sh keeps its state host-side).
#
# What this driver writes on the machine, and how it leaves it
# -----------------------------------------------------------
#   /etc/config/<pkg>                     one `config pkgclass` section per class, appended;
#                                         the file found there is copied once to
#                                         <file>.ab-pkgclass-bak first
#   /data/ab-follow/<pkg>.marker          one marker per class, next to follow-probe.sh's own
#   /etc/apk/ab/local/<name>-<ver>.apk    the kept body of the local class (through ab-packages)
#   /etc/apk/repositories.d/customfeeds.list
#                                         the user's source is added when --customfeed-url names
#                                         one and the file does not carry it yet, inside a
#                                         marked block. It is *not* removed at the end: it is
#                                         the source ac-13 asks about, and the byte-identity
#                                         asserted across every hop is the thing being judged.
#
# Chain and exit status
# ---------------------
#   C1  25.12.0 -> 25.12.1   payload-25.12.1.tar
#   C2  25.12.1 -> 25.12.2   payload-25.12.2.tar
#
# Exit status is matrix-round2.sh's vocabulary, so a caller reading full-test.sh's rows cannot
# tell the chains apart by their exit codes: 0 every selected case PASS, 1 a case FAIL, 2 bad
# usage, 3 the red line stopped the run (no committed slot that booted and mounted the ESP
# cleanly), 4 a case could not run for want of its payload or of its baseline (GAP).
#
# `--dry-run` prints the chain, each hop's expectation and each class's criterion, and sends
# no ssh, creates no evidence directory and writes no row. A GAP is never a pass: a class that
# cannot be installed at all is a finding about the machine's sources, not about the A/B
# machinery, and it is recorded with the command that was run.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT

# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

# Version ordering, so the direction of a hop is computed from the numbers and never read off
# a case name (the same helper matrix.sh, matrix-round2.sh and matrix-rise.sh use).
# shellcheck source=platform/lib/ab-version.sh
. "${AB_VERSION_LIB:-${AB_REPO_ROOT}/platform/lib/ab-version.sh}"

# --------------------------------------------------------------------------- #
# Defaults and arguments
# --------------------------------------------------------------------------- #

# The chain, as steps. One machine walks it in this order; --from resets the start and --only
# picks a single step out of it.
CHAIN=${AB_PKGCLASS_CHAIN:-"C1 C2"}

PAYLOAD_DIR=${AB_PAYLOAD_DIR:-payloads}
RESULTS=${AB_RESULTS:-results.tsv}
EVIDENCE_DIR=${AB_EVIDENCE_DIR:-}

# The baseline: what the three classes were, on the operator's machine. The default is a /tmp
# path for the same reason follow-probe.sh's is: the file has to outlive the reboots it spans,
# and the device's /tmp does not.
STATE=${AB_PKGCLASS_STATE:-/tmp/ab-package-classes-state.tsv}

# Where the three classes live on the machine. Every path is a knob, so the offline test can
# name a tree it owns and a run cannot write outside it; the defaults are the machine's own.
MARKER_DIR=${AB_PKGCLASS_MARKER_DIR:-/data/ab-follow}
CONFIG_DIR=${AB_PKGCLASS_CONFIG_DIR:-/etc/config}
CUSTOMFEEDS=${AB_PKGCLASS_CUSTOMFEEDS:-/etc/apk/repositories.d/customfeeds.list}
WORLD=${AB_PKGCLASS_WORLD:-/etc/apk/world}
ASSETS=${AB_PKGCLASS_ASSETS:-/etc/apk/ab/local}
# The follow's one-line record, read for `dropped=` - the only place the machine says which
# world entries its own prune removed.
RECORD=${AB_PKGCLASS_RECORD:-/boot/ab/packages}
# Where a fetched body and the pushed .apk land on the machine. /tmp is cleared by a reboot,
# so a leftover there cannot outlive the run that made it.
SCRATCH=${AB_PKGCLASS_SCRATCH:-/tmp/ab-pkgclass}

# The three samples. Each one is a knob because "which package" is an environment fact (the
# base's feed, the user's source and the local body all decide it), and the check command is
# a knob for the same reason follow-probe.sh's manifest is: the criterion is per package.
DIST_PKG=${AB_PKGCLASS_DISTFEED_PKG:-htop}
DIST_CHECK=${AB_PKGCLASS_DISTFEED_CHECK:-htop --version}
DIST_EXPECT=${AB_PKGCLASS_DISTFEED_EXPECT:-'^htop [0-9]'}
# The class's sample from the user's own source. jq is in the x86_64 package feed of every
# 25.12 release, so a mirror of any of them can serve it; a source that only carries the
# kmods segment needs both knobs replaced.
CUSTOM_PKG=${AB_PKGCLASS_CUSTOMFEED_PKG:-jq}
# The URL the driver adds to customfeeds.list when the file does not carry it yet. Empty means
# "use whatever the file already names": ac-13's premise is a user who added their own source.
CUSTOM_URL=${AB_PKGCLASS_CUSTOMFEED_URL:-}
# The package the "can still install from that source" proof uses. Installed and removed again
# on every hop, so the world of the next hop is comparable with the one of this hop.
NEW_PKG=${AB_PKGCLASS_NEW_PKG:-tmux}
# The local class. A body no feed offers is what makes it local, so a body has to be supplied:
# --local-apk pushes one, --local-pkg adopts a body already kept in <assets>/, and
# --local-apk auto builds one (see the header). None of them is a default, because a package
# the feeds still offer is `superseded`, not local, and because "which package is the local
# sample" is an environment fact rather than something to invent silently.
LOCAL_PKG=${AB_PKGCLASS_LOCAL_PKG:-}
LOCAL_APK=${AB_PKGCLASS_LOCAL_APK:-}
# Whether --local-pkg was said on the command line, as opposed to inherited from
# AB_PKGCLASS_LOCAL_PKG. The two weigh differently against --local-apk auto: an explicit flag
# that contradicts the built body is an error, while an environment default is a default and
# yields to the flag that was actually typed.
LOCAL_PKG_EXPLICIT=0
# The body `auto` builds. The name and the version are fixed rather than knobs: the store's
# `<name>-<version>.apk` file name is the interface the gate looks bodies up by
# (ab-pkgs-assets.sh:20), and a knob here would be a second place that decides it.
LOCAL_BODY_PKG="ab-pkgclass-local"
LOCAL_BODY_VERSION="1.0.0-r1"
# Where a body came from, for the row: given, kept (already on the machine) or built.
LOCAL_BODY_SOURCE=""

# The three classes, in the order they are installed and judged. Fixed, not a knob: a chain
# that quietly dropped the class a machine cannot serve would look green and cover two thirds
# of ac-12.
CLASSES="distfeeds customfeeds local"

ONLY_CASE=""
FROM_STEP=""
RESUME=0
DRY_RUN=0
BASELINE_MODE=""
BASELINE_REASON=""
CUSTOM_SOURCE=""
CUSTOM_SOURCE_AT_BASELINE=""
CASE_NOTE=""
CLASS_SUMMARY=""
WORLD_DROPPED=""
VERSION_FACT=""
CUSTOMFEEDS_FACT=""
NEWPKG_FACT=""
REPLAY_FACT=""
STATUS_LINE=""
HOP_FAILED=0
_baseline_answer=""
_probe_answer=""
_refresh_answer=""

usage() {
    cat <<'USAGE'
usage: package-classes.sh [--only <case>] [--from <step>] [--resume]
                          [--payload-dir DIR] [--payload <case>=<path>] [--results FILE]
                          [--evidence-dir DIR] [--state FILE]
                          [--distfeed-pkg NAME] [--distfeed-check CMD] [--distfeed-expect ERE]
                          [--customfeed-pkg NAME] [--customfeed-url URL] [--new-pkg NAME]
                          [--local-pkg NAME | --local-apk PATH] [--dry-run]

  --only <case>        walk one step: C1 C2
  --from <step>        start at this step (1..2 or a case id) and walk the rest
  --resume             skip the PASS rows whose predecessors are all PASS
  --payload-dir DIR    where payload-<version>.tar lives (default: payloads)
  --payload C=PATH     use PATH for case C instead of <payload-dir>/payload-<version>.tar
  --results FILE       results.tsv to append to (default: results.tsv)
  --evidence-dir DIR   evidence directory (default: <results dir>/evidence/pkgclass)
  --state FILE         the three classes' baseline (default: /tmp/ab-package-classes-state.tsv)

  --distfeed-pkg NAME      the sample installed from the base's own feed (default htop)
  --distfeed-check CMD     what "still usable" runs on the machine (default: htop --version)
  --distfeed-expect ERE    what that command's output has to match (default: ^htop [0-9])
  --customfeed-pkg NAME    the sample installed from the user's source (default jq)
  --customfeed-url URL     the user's source; added to customfeeds.list when it is not there
  --new-pkg NAME           a package the source has not served yet (default tmux)
  --local-pkg NAME         adopt the body already kept for NAME in /etc/apk/ab/local/
  --local-apk PATH         push this .apk and install it as a local package
  --local-apk auto         build the local class body instead of asking for one
  --dry-run                print the chain and each class's criterion; no ssh is sent

Exit: 0 all PASS, 1 a FAIL, 2 usage, 3 red line, 4 GAP (payload or baseline missing).
USAGE
}

while [ $# -gt 0 ]; do
    case "${1}" in
        --only)
            ONLY_CASE=${2:?--only needs a value}
            shift 2
            ;;
        --from)
            FROM_STEP=${2:?--from needs a value}
            shift 2
            ;;
        --resume)
            RESUME=1
            shift
            ;;
        --payload-dir)
            PAYLOAD_DIR=${2:?--payload-dir needs a value}
            shift 2
            ;;
        --payload)
            PAYLOAD_SPECS="${PAYLOAD_SPECS:-} ${2:?--payload needs <case>=<path>}"
            shift 2
            ;;
        --results)
            RESULTS=${2:?--results needs a value}
            shift 2
            ;;
        --evidence-dir)
            EVIDENCE_DIR=${2:?--evidence-dir needs a value}
            shift 2
            ;;
        --state)
            STATE=${2:?--state needs a value}
            shift 2
            ;;
        --distfeed-pkg)
            DIST_PKG=${2:?--distfeed-pkg needs a name}
            shift 2
            ;;
        --distfeed-check)
            DIST_CHECK=${2:?--distfeed-check needs a command}
            shift 2
            ;;
        --distfeed-expect)
            DIST_EXPECT=${2:?--distfeed-expect needs a pattern}
            shift 2
            ;;
        --customfeed-pkg)
            CUSTOM_PKG=${2:?--customfeed-pkg needs a name}
            shift 2
            ;;
        --customfeed-url)
            CUSTOM_URL=${2:?--customfeed-url needs a URL}
            shift 2
            ;;
        --new-pkg)
            NEW_PKG=${2:?--new-pkg needs a name}
            shift 2
            ;;
        --local-pkg)
            LOCAL_PKG=${2:?--local-pkg needs a name}
            LOCAL_PKG_EXPLICIT=1
            shift 2
            ;;
        --local-apk)
            LOCAL_APK=${2:?--local-apk needs a path}
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'package-classes: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done
PAYLOAD_SPECS=${PAYLOAD_SPECS:-}

# --local-apk auto names its own package, so the plan, the payload preflight and the baseline
# all talk about the same sample before a byte is built.
#
# A --local-pkg *flag* beside it is a usage error rather than a preference: the body that gets
# built carries one name, and a run that said two would install one package and then judge
# another - a `local:no-body` on the second one, which is the GAP this flag exists to remove.
# A name inherited from AB_PKGCLASS_LOCAL_PKG is a default and yields, because the flag that
# was typed is the more recent instruction; the replacement is printed so the run says which
# sample it is actually about.
if [ "${LOCAL_APK}" = "auto" ]; then
    if [ "${LOCAL_PKG_EXPLICIT}" = "1" ] && [ "${LOCAL_PKG}" != "${LOCAL_BODY_PKG}" ]; then
        printf 'package-classes: --local-apk auto builds %s, so --local-pkg %s names a package that body will not install; pass one of them\n' \
            "${LOCAL_BODY_PKG}" "${LOCAL_PKG}" >&2
        exit 2
    fi
    if [ -n "${LOCAL_PKG}" ] && [ "${LOCAL_PKG}" != "${LOCAL_BODY_PKG}" ]; then
        printf 'package-classes: --local-apk auto builds %s, so it replaces the local sample %s from AB_PKGCLASS_LOCAL_PKG\n' \
            "${LOCAL_BODY_PKG}" "${LOCAL_PKG}" >&2
    fi
    LOCAL_PKG=${LOCAL_BODY_PKG}
fi

if [ -n "${ONLY_CASE}" ] && [ -n "${FROM_STEP}" ]; then
    printf 'package-classes: --only and --from answer different questions; pass one\n' >&2
    exit 2
fi

AB_RESULTS=${RESULTS}
[ -n "${EVIDENCE_DIR}" ] || EVIDENCE_DIR=$(dirname "${AB_RESULTS}")/evidence/pkgclass
AB_EVIDENCE_LOG=""
AB_MATRIX_CMD="$0"

if [ "${DRY_RUN}" = "1" ]; then
    # Belt and braces: the planner below only prints, and every ssh helper refuses anyway.
    AB_DRY_RUN=1
fi
export AB_DRY_RUN AB_RESULTS AB_EVIDENCE_LOG AB_MATRIX_CMD

# --------------------------------------------------------------------------- #
# The chain
#
# One function per fact, so a hop is described once and both the plan and the assertions read
# that description. Adding a release means adding it here and to CHAIN; nothing else in this
# file names a base.
# --------------------------------------------------------------------------- #

case_from_rootfs() {
    case "${1}" in
        C1) printf '25.12.0\n' ;;
        C2) printf '25.12.1\n' ;;
        *) return 1 ;;
    esac
}

case_to_rootfs() {
    case "${1}" in
        C1) printf '25.12.1\n' ;;
        C2) printf '25.12.2\n' ;;
        *) return 1 ;;
    esac
}

case_payload() {
    case "${1}" in
        C1) printf 'payload-25.12.1.tar\n' ;;
        C2) printf 'payload-25.12.2.tar\n' ;;
        *) return 1 ;;
    esac
}

case_step() { # 1-based position in the whole chain, so it does not move under --only
    _i=0
    for _c in ${CHAIN}; do
        _i=$((_i + 1))
        if [ "${_c}" = "${1}" ]; then
            printf '%s\n' "${_i}"
            return 0
        fi
    done
    return 1
}

case_total() {
    printf '%s\n' ${CHAIN} | wc -l | tr -d ' '
}

# direction_of <from> <to>: up, down or same-base - computed, never read off a name.
direction_of() {
    if ! _cmp=$(ab_version_cmp "${1:-}" "${2:-}" 2>/dev/null); then
        printf 'unknown\n'
        return 0
    fi
    case "${_cmp}" in
        1) printf 'down\n' ;;
        -1) printf 'up\n' ;;
        *) printf 'same-base\n' ;;
    esac
}

# relation_of <landing> <rollback>: how the slot left behind compares with the one the hop
# lands in.
relation_of() {
    if ! _cmp=$(ab_version_cmp "${1:-}" "${2:-}" 2>/dev/null); then
        printf 'unknown\n'
        return 0
    fi
    case "${_cmp}" in
        1) printf 'older\n' ;;
        -1) printf 'newer\n' ;;
        *) printf 'same\n' ;;
    esac
}

# hop_expect <case>: the one description of what the hop must do and end in.
hop_expect() {
    _c=${1:?hop_expect needs a case}
    _step=$(case_step "${_c}") || return 2
    printf 'step=%s/%s kind=base direction=%s from-rootfs=%s to-rootfs=%s rollback=%s payload=%s classes=%s baseline=record-once\n' \
        "${_step}" "$(case_total)" \
        "$(direction_of "$(case_from_rootfs "${_c}")" "$(case_to_rootfs "${_c}")")" \
        "$(case_from_rootfs "${_c}")" "$(case_to_rootfs "${_c}")" \
        "$(relation_of "$(case_to_rootfs "${_c}")" "$(case_from_rootfs "${_c}")")" \
        "$(case_payload "${_c}")" "$(printf '%s' "${CLASSES}" | tr ' ' ',')"
}

hop_expect_value() { # <case> <key>
    hop_expect "${1}" | tr ' ' '\n' | sed -n "s/^${2:?hop_expect_value needs a key}=//p" | head -n 1
}

# --------------------------------------------------------------------------- #
# The three classes: one source and one criterion each
#
# Described once, here, and read by the planner, the baseline and the assertions alike. A
# class is a name, a package, two paths and a criterion sentence; nothing else in this file
# knows which of the three it is talking about without asking these functions.
# --------------------------------------------------------------------------- #

class_pkg() {
    case "${1}" in
        distfeeds) printf '%s\n' "${DIST_PKG}" ;;
        customfeeds) printf '%s\n' "${CUSTOM_PKG}" ;;
        local) printf '%s\n' "${LOCAL_PKG}" ;;
        *) return 1 ;;
    esac
}

class_config() {
    _cc_pkg=$(class_pkg "${1}") || return 1
    printf '%s/%s\n' "${CONFIG_DIR}" "${_cc_pkg}"
}

class_marker() {
    _cm_pkg=$(class_pkg "${1}") || return 1
    printf '%s/%s.marker\n' "${MARKER_DIR}" "${_cm_pkg}"
}

# class_criterion <class>: the sentence the plan prints and the assertions carry out.
class_criterion() {
    case "${1}" in
        distfeeds)
            printf 'record, `%s` matching /%s/, and the new base feed still offers it\n' \
                "${DIST_CHECK}" "${DIST_EXPECT}"
            ;;
        customfeeds)
            printf 'customfeeds.list byte-identical, `ab-packages sources %s` still names the source, and %s still installs from it alone\n' \
                "${CUSTOM_PKG}" "${NEW_PKG}"
            ;;
        local)
            printf 'record, kept body of %s unchanged in sha256, and `ab-packages replay` exits 0\n' \
                "${LOCAL_PKG:-<local body>}"
            ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------- #
# Red lines
# --------------------------------------------------------------------------- #

_red_line() { # <case> <reason>
    printf 'ABORT red-line [%s]: %s\n' "${1:-?}" "${2:-unspecified}" >&2
    printf 'ABORT: the machine has no committed healthy slot to fall back to; nothing else is touched\n' >&2
    ev "ABORT red-line: ${2:-unspecified}"
    exit 3
}

# require_healthy <case>: sets STATUS_LINE, or stops the run here. The same two red lines
# matrix.sh, matrix-round2.sh and matrix-rise.sh apply, restated because those files are
# drivers and not a library: the running slot must be the committed one, and both boot= and
# esp= are facts a machine cannot claim without evidence.
require_healthy() {
    _case=${1:-?}
    _line=$(dev_status) || _red_line "${_case}" "ab-slot status is unreadable"
    _boot=$(status_field "${_line}" boot) || _boot=unknown
    _esp=$(status_field "${_line}" esp) || _esp=unknown
    _committed=$(status_field "${_line}" committed) || _committed=""
    case "${_committed}" in
        a | b) : ;;
        *) _red_line "${_case}" "no committed slot (committed='${_committed}')" ;;
    esac
    [ "${_boot}" = "ok" ] || _red_line "${_case}" "boot=${_boot}: the running slot is not proven healthy"
    [ "${_esp}" = "ok" ] || _red_line "${_case}" "esp=${_esp}: the ESP was not proven healthy at boot"
    STATUS_LINE=${_line}
    return 0
}

# require_safe_target <case> <status-line>: an install writes the slot that is not running, so
# the committed layer is only out of reach while the running slot is the committed one.
require_safe_target() {
    _case=${1:-?}
    _line=${2:-}
    _slot=$(status_field "${_line}" slot) || _slot=""
    _committed=$(status_field "${_line}" committed) || _committed=""
    _pending=$(status_field "${_line}" pending) || _pending=""
    if [ "${_slot}" != "${_committed}" ]; then
        _red_line "${_case}" "running slot ${_slot:-?} is not the committed slot ${_committed:-?}: an install would overwrite the only healthy slot"
    fi
    if [ "${_pending}" != "none" ]; then
        printf 'unsafe target [%s]: pending=%s is already queued, resolve it before installing\n' \
            "${_case}" "${_pending:-?}" >&2
        ev "unsafe target: pending=${_pending:-?}"
        return 1
    fi
    return 0
}

other_slot() {
    case "${1}" in
        a) printf 'b\n' ;;
        b) printf 'a\n' ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------- #
# Quoting and small string helpers
# --------------------------------------------------------------------------- #

# _sq <text>: single-quote a value for the remote shell. Paths, package names and URLs are
# pasted into a program that runs on the machine, and a driver that pastes them without
# quoting is one fixture edit away from running somebody else's command there.
_sq() {
    case "${1-}" in
        *"'"*) printf "'%s'" "$(printf '%s' "${1}" | sed "s/'/'\\\\''/g")" ;;
        *) printf "'%s'" "${1-}" ;;
    esac
}

# _short <sha256>: enough of it to compare in a row, not enough to be the baseline.
_short() {
    printf '%s' "${1:-}" | cut -c1-12
}

# _apk_split <path|basename>: `name version` from apk's own archive name, so --local-apk may
# be given without --local-pkg. The last two dashes are the boundary, exactly as
# platform/lib/ab-pkgs-assets.sh reads it (a version starts with a digit).
_apk_split() {
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
    _as_ver=${_as_rest##*-}
    case "${_as_ver}" in
        [0-9]*) ;;
        *) return 1 ;;
    esac
    _as_name=${_as_rest%-*}
    [ -n "${_as_name}" ] || return 1
    printf '%s %s-%s\n' "${_as_name}" "${_as_ver}" "${_as_rev}"
}

# _name_ok <package name>: the shape that may be pasted into a remote command and into a
# world-entry regex. A package name outside it is a usage error, not something to escape.
_name_ok() {
    case "${1:-}" in
        '' | *[!a-z0-9._+-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# --------------------------------------------------------------------------- #
# The remote half
#
# One program per mode, generated here and sent over stdin (dropbear closes a connection for a
# command line past its limit; follow-probe.sh measured that). Every mode measures facts and
# prints them; the host judges them. Nothing on the machine decides a verdict, so a machine
# without grep, without sed and without a `case` it likes still answers the same questions.
#
# Three modes:
#   baseline  install the three samples from their own sources, write the fake config and the
#             /data marker, add the user's source when it was named, print the facts
#   probe     read-only: the facts of the three classes as the machine is now
#   refresh   the two proofs that need a transaction: a new package from the user's source,
#             and a replay of the kept body
#
# The fact line of a class, tab separated, is the same in baseline and probe:
#   class pkg version installed config config_sha256 marker marker_sha256 world sources body body_sha256 check_rc check_out
# The baseline prints one extra line per class and four meta lines:
#   install  class state rc detail
#   meta     customfeeds_sha256 custom_source world assets config_dir marker_dir
# --------------------------------------------------------------------------- #

_remote_preamble() {
    printf 'set -u\n'
    printf 'WORLD=%s\n' "$(_sq "${WORLD}")"
    printf 'ASSETS=%s\n' "$(_sq "${ASSETS}")"
    printf 'RECORD=%s\n' "$(_sq "${RECORD}")"
    printf 'SCRATCH=%s\n' "$(_sq "${SCRATCH}")"
    printf 'BAKSFX=.ab-pkgclass-bak\n'
    cat <<'REMOTE'
_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
_ver() { apk list --installed "$1" 2>/dev/null | head -1 | awk '{print $1}'; }
_src() { ab-packages sources "$1" 2>/dev/null | tr '\n' ';'; }
_world() {
    if grep -qE "^$1(=|$)" "$WORLD" 2>/dev/null; then printf present; else printf absent; fi
}
_body() { # <pkg>: the kept body apk's own glob names, or empty
    _b_out=""
    for _b_f in "$ASSETS/$1-"*.apk; do
        [ -f "$_b_f" ] || continue
        _b_out=$_b_f
    done
    printf '%s' "$_b_out"
}
# _mark: the fake configuration and the /data marker of one class. Appended, never rewritten:
# the file found here is copied to <file>.ab-pkgclass-bak first, and the section this driver
# owns is stripped by name before it is written again, so a second run replaces its own lines
# and leaves everything else in the file alone. awk and mv instead of `sed -i`: the same
# program has to run on busybox and on the laptop the offline test runs it on.
_mark() {
    mstate=failed
    ms=$(printf 'ab-pkgclass:%s:v1' "$cls" | sha256sum | awk '{print $1}')
    cdir=${cfg%/*}
    mkdir -p "$cdir" 2>/dev/null || return 0
    [ -f "$cfg" ] || : >"$cfg" 2>/dev/null || return 0
    [ -f "$cfg$BAKSFX" ] || cp "$cfg" "$cfg$BAKSFX" 2>/dev/null || :
    awk '!/^config pkgclass / && !/^[[:space:]]*option ab_marker /' "$cfg" \
        >"$cfg.ab-pkgclass.$$" 2>/dev/null || { rm -f "$cfg.ab-pkgclass.$$"; return 0; }
    mv "$cfg.ab-pkgclass.$$" "$cfg" 2>/dev/null || { rm -f "$cfg.ab-pkgclass.$$"; return 0; }
    printf "config pkgclass '%s'\n\toption ab_marker '%s'\n" "$cls" "$ms" >>"$cfg" 2>/dev/null || return 0
    mdir=${mk%/*}
    mkdir -p "$mdir" 2>/dev/null || return 0
    printf 'pkg=%s\nclass=%s\n' "$pkg" "$cls" >"$mk" 2>/dev/null || return 0
    mstate=ok
    return 0
}
# _facts: one class, one line, exactly the columns the host judges. The check command is the
# class's own (distfeeds runs it); every other class's criterion is a fact about the record,
# the file and the source, and a command of its own would be a second opinion about "usable".
_facts() {
    v=$(_ver "$pkg")
    [ -n "$v" ] && v=${v#"$pkg"-}
    ins=no
    [ -n "$v" ] && ins=yes
    csha=$(_sha "$cfg")
    msha=$(_sha "$mk")
    w=$(_world "$pkg")
    src=$(_src "$pkg")
    bod=$(_body "$pkg")
    bsha=""
    [ -n "$bod" ] && bsha=$(_sha "$bod")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$cls" "$pkg" "$v" "$ins" "$cfg" "$csha" "$mk" "$msha" "$w" "${src:--}" \
        "${bod:--}" "${bsha:--}" "$crc" "$(printf '%s' "$cout" | tr '\n\t' '  ' | cut -c1-240)"
}
REMOTE
}

# _remote_baseline_block <class>: install this class from its own source, then mark it.
_remote_baseline_block() {
    _rb_cls=${1:?}
    _rb_pkg=$(class_pkg "${_rb_cls}") || return 1
    printf 'cls=%s\n' "$(_sq "${_rb_cls}")"
    printf 'pkg=%s\n' "$(_sq "${_rb_pkg}")"
    printf 'cfg=%s\n' "$(_sq "$(class_config "${_rb_cls}")")"
    printf 'mk=%s\n' "$(_sq "$(class_marker "${_rb_cls}")")"
    printf 'crc=0\ncout=""\nistate=installed\nirc=0\niout=""\n'
    case "${_rb_cls}" in
        distfeeds)
            printf 'iout=$(apk add "$pkg" 2>&1) || irc=$?\n'
            ;;
        customfeeds)
            # --repository and not the plain list: the point of this class is that the package
            # came from the user's source, and the base's own feed may offer the same name.
            printf '[ -n "$csrc" ] || { irc=1; iout="no custom source in the repositories.d file"; }\n'
            printf '[ "$irc" = 0 ] && { iout=$(apk add --repository "$csrc" "$pkg" 2>&1) || irc=$?; }\n'
            ;;
        local)
            # A body no feed offers is what makes a package local. `ab-packages replay` keeps
            # the body and installs it with apk add --allow-untrusted in one call, which is
            # the product's own path for a local package.
            if [ -n "${LOCAL_REMOTE_BODY:-}" ]; then
                printf 'iout=$(ab-packages replay --yes %s 2>&1) || irc=$?\n' "$(_sq "${LOCAL_REMOTE_BODY}")"
            else
                printf 'if bod=$(_body "$pkg"); [ -n "$bod" ]; then\n'
                printf '    istate=adopted\n'
                printf '    iout=$(ab-packages replay --yes "$bod" 2>&1) || irc=$?\n'
                printf 'else\n'
                printf '    istate=no-body; irc=1; iout="no kept body for $pkg in $ASSETS"\n'
                printf 'fi\n'
            fi
            ;;
    esac
    printf '[ "$irc" = 0 ] || istate=install-failed\n'
    printf '_mark\n'
    printf '[ "$mstate" = ok ] || istate=%s\n' "mark-failed"
    printf 'case "$cls" in\n'
    printf '    distfeeds) cout=$( { %s\n} 2>&1 ) || crc=$? ;;\n' "${DIST_CHECK}"
    printf 'esac\n'
    printf '_facts\n'
    printf 'printf "install\\t%%s\\t%%s\\t%%s\\t%%s\\n" "$cls" "$istate" "$irc" "$(printf "%%s" "$iout" | tr "\\n\\t" "  " | cut -c1-240)"\n'
}

# _remote_probe_block <class>: the same facts, read-only.
_remote_probe_block() {
    _rp_cls=${1:?}
    _rp_pkg=$(class_pkg "${_rp_cls}") || return 1
    printf 'cls=%s\n' "$(_sq "${_rp_cls}")"
    printf 'pkg=%s\n' "$(_sq "${_rp_pkg}")"
    printf 'cfg=%s\n' "$(_sq "$(class_config "${_rp_cls}")")"
    printf 'mk=%s\n' "$(_sq "$(class_marker "${_rp_cls}")")"
    printf 'crc=0\ncout=""\n'
    printf 'case "$cls" in\n'
    printf '    distfeeds) cout=$( { %s\n} 2>&1 ) || crc=$? ;;\n' "${DIST_CHECK}"
    printf 'esac\n'
    printf '_facts\n'
}

# _remote_refresh_block <class>: the two proofs that need a transaction. The customfeeds proof
# installs a package the source has not served yet and removes it again, so the world the next
# hop sees is the one this hop saw; the local proof replays the kept body.
_remote_refresh_block() {
    _rr_cls=${1:?}
    case "${_rr_cls}" in
        customfeeds)
            printf 'cls=customfeeds\n'
            printf 'pkg=%s\n' "$(_sq "${NEW_PKG}")"
            printf 'url=%s\n' "$(_sq "${CUSTOM_SOURCE}")"
            cat <<'REMOTE'
pre=no
apk info -e "$pkg" >/dev/null 2>&1 && pre=yes
mkdir -p "$SCRATCH" 2>/dev/null || :
rc=0
iout=$(apk fetch --repository "$url" -o "$SCRATCH" "$pkg" 2>&1) || rc=$?
bod=""
for f in "$SCRATCH/$pkg-"*.apk; do [ -f "$f" ] || continue; bod=$f; done
inst=no
del=skipped
if [ "$rc" = 0 ] && [ -n "$bod" ]; then
    rc=0
    iout=$(apk add --allow-untrusted "$bod" 2>&1) || rc=$?
    apk info -e "$pkg" >/dev/null 2>&1 && inst=yes
    if [ "$pre" = yes ]; then
        del=preexisting
    elif [ "$inst" = yes ]; then
        if apk del "$pkg" >/dev/null 2>&1; then del=removed; else del=failed; fi
    fi
fi
printf 'refresh\t%s\tnewpkg\t%s\t%s\t%s\t%s\t%s\n' "customfeeds" "$rc" "$inst" "$del" "$pre" \
    "$(printf '%s' "$iout" | tr '\n\t' '  ' | cut -c1-240)"
REMOTE
            ;;
        local)
            printf 'cls=local\n'
            printf 'pkg=%s\n' "$(_sq "${LOCAL_PKG}")"
            cat <<'REMOTE'
rc=1
result=none
okept=0
failed=0
bod=$(_body "$pkg")
if [ -n "$bod" ]; then
    rc=0
    iout=$(ab-packages replay --yes "$bod" 2>&1) || rc=$?
    result=$(printf '%s\n' "$iout" | sed -n 's/^replay result=\([a-z]*\).*/\1/p' | tail -n 1)
    okept=$(printf '%s\n' "$iout" | sed -n 's/.* ok=\([0-9]*\).*/\1/p' | tail -n 1)
    failed=$(printf '%s\n' "$iout" | sed -n 's/.* failed=\([0-9]*\).*/\1/p' | tail -n 1)
else
    iout="no kept body for $pkg in $ASSETS"
fi
printf 'refresh\t%s\treplay\t%s\t%s\t%s\t%s\t%s\n' "local" "$rc" "${result:-none}" \
    "${okept:-0}" "${failed:-0}" \
    "$(printf '%s' "$iout" | tr '\n\t' '  ' | cut -c1-240)"
REMOTE
            ;;
        *)
            return 0
            ;;
    esac
}

_remote_script() { # <baseline|probe|refresh>
    _rs_mode=${1:?}
    _remote_preamble
    case "${_rs_mode}" in
        baseline)
            # The user's source first: the customfeeds class installs from it, and adding it
            # is what turns "the file names something" into "apk can read it".
            printf 'csrc=%s\n' "$(_sq "${CUSTOM_URL}")"
            printf 'cf=%s\n' "$(_sq "${CUSTOMFEEDS}")"
            # The two markers carry no angle brackets on purpose: the block is matched by exact
            # string equality, and the repository's POSIX scan refuses a `<<<` outside a
            # comment (tests/modules/device/test_device_scripts_posix.sh), so a marker spelled
            # with arrows would make this file unscannable for the sake of decoration.
            cat <<'REMOTE'
_add_source() {
    if [ -n "$csrc" ]; then
        if grep -qxF "$csrc" "$cf" 2>/dev/null; then
            printf 'source=preexisting\n'
            return 0
        fi
    else
        csrc=$(sed -n 's/[[:space:]]*$//;/^[[:space:]]*#/d;/^[[:space:]]*$/d;p' "$cf" 2>/dev/null | head -n 1)
        if [ -n "$csrc" ]; then
            printf 'source=preexisting\n'
            return 0
        fi
        printf 'source=none\n'
        return 1
    fi
    mkdir -p "${cf%/*}" 2>/dev/null || { printf 'source=unwritable\n'; return 1; }
    [ -f "$cf" ] || : >"$cf" 2>/dev/null || { printf 'source=unwritable\n'; return 1; }
    awk -v b='# ab-pkgclass source begin' -v e='# ab-pkgclass source end' '
        $0 == b { inside = 1; next }
        $0 == e { inside = 0; next }
        !inside { print }
    ' "$cf" >"$cf.ab-pkgclass.$$" 2>/dev/null || { printf 'source=unwritable\n'; return 1; }
    mv "$cf.ab-pkgclass.$$" "$cf" 2>/dev/null || { printf 'source=unwritable\n'; return 1; }
    printf '%s\n%s\n%s\n' '# ab-pkgclass source begin' "$csrc" '# ab-pkgclass source end' >>"$cf" 2>/dev/null ||
        { printf 'source=unwritable\n'; return 1; }
    if iout=$(apk update 2>&1); then
        printf 'source=added\n'
    else
        printf 'source=added-unindexed %s\n' "$(printf '%s' "$iout" | tr '\n' ' ' | cut -c1-120)"
    fi
    return 0
}
_ret=$(_add_source)
printf 'meta\tcustom_source\t%s\n' "${csrc:--}"
printf 'meta\tcustomfeeds_sha256\t%s\n' "$(_sha "$cf")"
printf 'meta\tsource_state\t%s\n' "${_ret#source=}"
REMOTE
            ;;
        probe | refresh) : ;;
    esac
    if [ "${_rs_mode}" = "baseline" ]; then
        for _rs_cls in ${CLASSES}; do
            _remote_baseline_block "${_rs_cls}" || return 1
        done
        printf 'printf "meta\\tworld\\t%%s\\n" %s\n' "$(_sq "${WORLD}")"
        printf 'printf "meta\\tassets\\t%%s\\n" %s\n' "$(_sq "${ASSETS}")"
        printf 'printf "meta\\tconfig_dir\\t%%s\\n" %s\n' "$(_sq "${CONFIG_DIR}")"
        printf 'printf "meta\\tmarker_dir\\t%%s\\n" %s\n' "$(_sq "${MARKER_DIR}")"
        printf 'printf "meta\\tdropped\\t%%s\\n" "$(sed -n "s/.* dropped=\\([^ ]*\\).*/\\1/p" %s 2>/dev/null | tail -n 1)"\n' \
            "$(_sq "${RECORD}")"
        return 0
    fi
    for _rs_cls in ${CLASSES}; do
        if [ "${_rs_mode}" = "probe" ]; then
            _remote_probe_block "${_rs_cls}" || return 1
        else
            _remote_refresh_block "${_rs_cls}" || return 1
        fi
    done
    if [ "${_rs_mode}" = "probe" ]; then
        # The file's bytes are a fact of the probe as well: the baseline's hash says what the
        # list was, and this one says what it is now. Without both, a hop could only report
        # "the class failed" instead of "the file moved".
        printf 'printf "meta\\tcustomfeeds_sha256\\t%%s\\n" "$(_sha %s)"\n' "$(_sq "${CUSTOMFEEDS}")"
        printf 'printf "meta\\tdropped\\t%%s\\n" "$(sed -n "s/.* dropped=\\([^ ]*\\).*/\\1/p" %s 2>/dev/null | tail -n 1)"\n' \
            "$(_sq "${RECORD}")"
    fi
}

# _ask <mode>: run one remote script, in one ssh call, and keep its answer.
#   0 answered, 1 no answer or a script that ran and failed (the two are reported differently).
_ask() {
    _ask_mode=${1:?}
    _ask_tmp=$(mktemp) || return 1
    if ! _remote_script "${_ask_mode}" >"${_ask_tmp}"; then
        printf 'package-classes: the %s script could not be written\n' "${_ask_mode}" >&2
        rm -f "${_ask_tmp}"
        return 1
    fi
    _out=$(dev_ssh 'sh -s' <"${_ask_tmp}")
    _ask_rc=$?
    rm -f "${_ask_tmp}"
    if [ "${_ask_rc}" -ne 0 ]; then
        printf 'package-classes: the %s script exited %s: %s\n' \
            "${_ask_mode}" "${_ask_rc}" "$(printf '%s\n' "${_out}" | head -n 1)" >&2
        return 1
    fi
    case "${_ask_mode}" in
        baseline) _baseline_answer=${_out} ;;
        probe) _probe_answer=${_out} ;;
        refresh) _refresh_answer=${_out} ;;
    esac
    return 0
}

# _row_of <answer> <first> [<second>]: the line whose first field is <first> and, when a
# second is given, whose second field is <second>. The three answers (baseline, probe,
# refresh) are kept apart in three variables: a probe that overwrote its own facts with the
# refresh's would judge the machine this driver changed instead of the one the hop landed on.
_row_of() {
    if [ -n "${3:-}" ]; then
        printf '%s\n' "${1:-}" | awk -F'\t' -v a="${2}" -v b="${3}" '$1 == a && $2 == b { print; exit }'
    else
        printf '%s\n' "${1:-}" | awk -F'\t' -v a="${2}" '$1 == a { print; exit }'
    fi
}

_meta_of() { # <answer> <key>
    printf '%s\n' "${1:-}" | awk -F'\t' -v k="${2}" '$1 == "meta" && $2 == k { print $3; exit }'
}

_probe_row() { # <cls>: the class's probe facts into _f1 .. _f14
    _pr_line=$(_row_of "${_probe_answer:-}" "${1}")
    [ -n "${_pr_line}" ] || return 1
    _split "${_pr_line}"
}

_install_row() { # <cls>: the class's install facts from the baseline answer
    _ir_line=$(_row_of "${_baseline_answer:-}" install "${1}")
    [ -n "${_ir_line}" ] || return 1
    _split "${_ir_line}"
}

_refresh_row() { # <cls>: the class's refresh facts into _f1 .. _f8
    _rr_line=$(_row_of "${_refresh_answer:-}" refresh "${1}")
    [ -n "${_rr_line}" ] || return 1
    _split "${_rr_line}"
}

_probe_meta() {
    _meta_of "${_probe_answer:-}" "${1:?}"
}

# _split <line>: tab separated fields into _f1 .. _f14. Parameter expansion and not `read`:
# IFS treats a tab as whitespace, so `read` collapses the empty field a not-installed package
# leaves where its version would be, and the row shifts one column left (the contract test of
# follow-probe.sh caught exactly that on 2026-11-18).
_split() {
    _rest=${1-}
    _f1=""
    _f2=""
    _f3=""
    _f4=""
    _f5=""
    _f6=""
    _f7=""
    _f8=""
    _f9=""
    _f10=""
    _f11=""
    _f12=""
    _f13=""
    _f14=""
    _i=0
    while [ "${_i}" -lt 14 ]; do
        _i=$((_i + 1))
        case "${_rest}" in
            *"	"*)
                _pop=${_rest%%	*}
                _rest=${_rest#*	}
                ;;
            *)
                _pop=${_rest}
                _rest=""
                ;;
        esac
        case "${_i}" in
            1) _f1=${_pop} ;;
            2) _f2=${_pop} ;;
            3) _f3=${_pop} ;;
            4) _f4=${_pop} ;;
            5) _f5=${_pop} ;;
            6) _f6=${_pop} ;;
            7) _f7=${_pop} ;;
            8) _f8=${_pop} ;;
            9) _f9=${_pop} ;;
            10) _f10=${_pop} ;;
            11) _f11=${_pop} ;;
            12) _f12=${_pop} ;;
            13) _f13=${_pop} ;;
            14) _f14=${_pop} ;;
        esac
    done
}

# --------------------------------------------------------------------------- #
# The baseline on the operator's machine
# --------------------------------------------------------------------------- #

_state_meta() { # <key>: one field of the state file's first line
    [ -f "${STATE}" ] || return 1
    _sm_line=$(sed -n '1p' "${STATE}")
    printf '%s\n' "${_sm_line}" | tr ' ' '\n' | sed -n "s/^${1}=//p" | head -n 1
}

_baseline_present() {
    [ -f "${STATE}" ] && grep -q '^distfeeds	' "${STATE}"
}

_baseline_row() { # <cls>: the state row into _f1 .. _f12
    [ -f "${STATE}" ] || return 1
    _br_line=$(awk -F'\t' -v n="${1}" '$1 == n { print; exit }' "${STATE}")
    [ -n "${_br_line}" ] || return 1
    _split "${_br_line}"
}

# _dropped_has <dropped-list> <name>: the follow's record names <name> among the world entries
# its prune removed. The list is comma separated and an item may be `name` or `name=version`;
# awk and not a `while read` loop, because the last item of a line read without a trailing
# newline loses its body to the loop's own condition.
_dropped_has() {
    printf '%s\n' "${1:-}" | awk -v n="${2:?}" -F',' '{
        found = 0
        for (i = 1; i <= NF; i++) {
            item = $i
            sub(/=.*/, "", item)
            if (item == n) found = 1
        }
    } END { exit !found }'
}

# --------------------------------------------------------------------------- #
# The local class's body, when the run has to supply one
#
# `--local-apk auto` builds a package the feeds do not offer, so that the local class is
# measured instead of reported as a missing fixture. Everything below runs on the operator's
# machine and writes nothing on the device: the built file is pushed the way any other body
# is, and from that point the class is judged by the product's own `ab-packages replay`.
# --------------------------------------------------------------------------- #

# _host_sha256 <file>: the digest of a file on this machine. The device's busybox calls the
# tool sha256sum and a laptop may only have shasum; which one runs is not part of the claim,
# so the same fallback tests/modules/device/test_package_classes.sh uses is used here.
_host_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${1}" | cut -d' ' -f1
    else
        shasum -a 256 "${1}" | cut -d' ' -f1
    fi
}

# _local_body_target: where a built body lands. A temporary directory rather than the
# checkout: the file is a fixture this driver can rebuild in a second, and a body inside the
# tree would be a package the repository has to keep explaining for ever.
_local_body_target() {
    _lbt_dir=${TMPDIR:-/tmp}
    _lbt_dir=${_lbt_dir%/}
    printf '%s/ab-pkgclass-local/%s-%s.apk\n' "${_lbt_dir}" "${LOCAL_BODY_PKG}" "${LOCAL_BODY_VERSION}"
}

# _tar_ustar <archive> <dir> <member>...: one tar the apk v2 reader can follow.
#
# The format is asked for by name because that reader parses ustar headers, and the ownership
# because the archive's uid is the uid apk installs. Both are preferences and not
# requirements: a tar that refuses the flags still produces a body apk accepts, so the plain
# form is the fallback rather than a failure.
_tar_ustar() {
    _tu_archive=${1:?}
    _tu_dir=${2:?}
    shift 2
    if tar --format=ustar --owner=0 --group=0 -cf "${_tu_archive}" -C "${_tu_dir}" "$@" 2>/dev/null; then
        return 0
    fi
    tar -cf "${_tu_archive}" -C "${_tu_dir}" "$@"
}

# _local_body_build: build the local class's body and print its path.
#
# The container is the two-member form apk-tools 3.0.5 still reads as a v2 package: a gzip
# member holding a tar with `.PKGINFO`, immediately followed by a gzip member holding the
# files. Three details are not decoration, and all three were measured on the device on
# 2026-11-19 with `apk add --simulate --allow-untrusted --force-non-repository`:
#
#   * the control member carries NO end-of-archive terminator. The reader parses both members
#     as one tar stream, so a zero block pair after `.PKGINFO` ends the archive before the data
#     member is reached and apk answers `unexpected end of file`. A tar writer always adds
#     that terminator and pads to a whole record, so the member is cut at the end of
#     `.PKGINFO`'s own data.
#   * `datahash` is the sha256 of the *compressed* data member, which is what the reader
#     compares when that member ends.
#   * the data member keeps the writer's terminator: it ends the stream, and the reader stops
#     there on end of file.
#
# A body that is one gzip member instead of two fails differently and less obviously: the
# reader sees a non-hidden name while the control block is still open and answers `v2 package
# format error`. Both are asserted below, so a body this function returns has been read back
# at the offsets it claims rather than assumed to be right.
_local_body_build() {
    _lb_out=$(_local_body_target)
    _lb_dir=${_lb_out%/*}
    _lb_work=${_lb_dir}/build
    for _lb_tool in tar gzip; do
        if ! command -v "${_lb_tool}" >/dev/null 2>&1; then
            printf 'package-classes: %s is not on this machine, so --local-apk auto cannot build a body\n' \
                "${_lb_tool}" >&2
            return 1
        fi
    done
    rm -rf "${_lb_work}"
    mkdir -p "${_lb_work}/data/usr/bin" "${_lb_work}/control" || return 1

    # What the body installs. One program and no configuration file: the fake configuration
    # and the /data marker ac-12 asks about are written by this driver, so a package that
    # shipped the same path would turn its own copy into an `.apk-new` beside the file being
    # measured and blur which one the hop kept.
    cat >"${_lb_work}/data/usr/bin/${LOCAL_BODY_PKG}" <<PROGRAM
#!/bin/sh
# The local class sample: a program that came from a file, not from a feed.
printf '%s\n' "${LOCAL_BODY_PKG}"
PROGRAM
    chmod 0755 "${_lb_work}/data/usr/bin/${LOCAL_BODY_PKG}"
    # A fixed timestamp keeps the body reproducible: two runs of this driver on the same
    # machine produce the same bytes, so a sha256 in a row can be compared across rounds.
    # The directories are touched as well as the file: a tar records a directory's mtime, so
    # leaving those at "now" would make every run a different archive.
    touch -t 202601010000 "${_lb_work}/data/usr/bin/${LOCAL_BODY_PKG}" \
        "${_lb_work}/data/usr/bin" "${_lb_work}/data/usr" || :

    _tar_ustar "${_lb_work}/data.tar" "${_lb_work}/data" usr || return 1
    gzip -n -9 -c "${_lb_work}/data.tar" >"${_lb_work}/data.tar.gz" || return 1
    _lb_datahash=$(_host_sha256 "${_lb_work}/data.tar.gz")

    cat >"${_lb_work}/control/.PKGINFO" <<PKGINFO
pkgname = ${LOCAL_BODY_PKG}
pkgver = ${LOCAL_BODY_VERSION}
arch = x86_64
pkgdesc = acceptance fixture: the local class sample, a package no feed offers
url = https://example.invalid/n5105-btrfs-ab-firmware
license = MIT
size = 4096
builddate = 1767225600
datahash = ${_lb_datahash}
PKGINFO
    touch -t 202601010000 "${_lb_work}/control/.PKGINFO" || :

    _tar_ustar "${_lb_work}/control.tar" "${_lb_work}/control" .PKGINFO || return 1
    _lb_size=$(wc -c <"${_lb_work}/control/.PKGINFO" | tr -d ' ')
    _lb_len=$((512 + ((_lb_size + 511) / 512) * 512))
    head -c "${_lb_len}" "${_lb_work}/control.tar" >"${_lb_work}/control.trim.tar" || return 1

    # The cut is checked rather than trusted, and in both directions: a writer that laid
    # `.PKGINFO` out differently (an extended header, a different block size) would be cut in
    # the wrong place, and the machine would then answer with a format error that reads like a
    # defect of the product. The last block must not be all NUL (the cut landed on data), and
    # the first eight bytes must be the name field's content.
    #
    # Eight bytes and not nine: the tar name field is padded, so a ninth byte would be the NUL
    # that terminates `.PKGINFO` and reading it into a shell variable would drop it.
    if [ "$(tail -c 512 "${_lb_work}/control.trim.tar" | tr -d '\000' | wc -c | tr -d ' ')" = "0" ]; then
        printf 'package-classes: the control member was cut inside padding, so this tar writer does not lay the file out the way --local-apk auto expects; pass --local-apk <file> with a body built elsewhere\n' >&2
        return 1
    fi
    if [ "$(head -c 8 "${_lb_work}/control.trim.tar")" != ".PKGINFO" ]; then
        printf 'package-classes: the control member does not start with .PKGINFO; pass --local-apk <file> with a body built elsewhere\n' >&2
        return 1
    fi

    gzip -n -9 -c "${_lb_work}/control.trim.tar" >"${_lb_work}/control.tar.gz" || return 1
    cat "${_lb_work}/control.tar.gz" "${_lb_work}/data.tar.gz" >"${_lb_out}.tmp" || return 1
    mv "${_lb_out}.tmp" "${_lb_out}" || return 1
    # The facts go to stderr and the path to stdout: a caller that captured both would capture
    # the log line into a file name.
    printf 'package-classes: built the local class body %s (%s bytes, sha256 %s)\n' \
        "${_lb_out}" "$(wc -c <"${_lb_out}" | tr -d ' ')" "$(_host_sha256 "${_lb_out}")" >&2
    printf '%s\n' "${_lb_out}"
}

# ensure_baseline <case>: the three classes as they were before the first hop.
#   0 a baseline exists (recorded now or inherited), 2 it cannot be established here.
ensure_baseline() {
    _eb_case=${1:?ensure_baseline needs a case}
    if _baseline_present; then
        BASELINE_MODE=existing
        # The source the inherited baseline was recorded against: the file's own first source
        # is the answer when the state does not carry one, and it is recorded either way, so a
        # later hop cannot judge the class against an empty needle.
        CUSTOM_SOURCE=$(_state_meta custom_source)
        case "${CUSTOM_SOURCE}" in
            '' | -) CUSTOM_SOURCE=$(_first_source_in_file) ;;
        esac
        CUSTOM_SOURCE_AT_BASELINE=${CUSTOM_SOURCE}
        if [ -z "${CUSTOM_SOURCE_AT_BASELINE}" ]; then
            printf 'baseline: %s records the three classes but names no user source, and %s has none either: ac-13 cannot be judged\n' \
                "${STATE}" "${CUSTOMFEEDS}" >&2
            BASELINE_REASON="customfeeds:no-source"
            return 2
        fi
        printf 'baseline: %s already records the three classes; not re-recorded (re-marking would re-baseline what this hop measures); source=%s\n' \
            "${STATE}" "${CUSTOM_SOURCE_AT_BASELINE}"
        ev "baseline existing ${STATE} source=${CUSTOM_SOURCE_AT_BASELINE}"
        return 0
    fi
    # The local body: a file this run pushes, one the machine already keeps, or one this run
    # builds. None exists without saying so, because a package the feeds still offer is
    # superseded and not local.
    _eb_local_file=""
    _eb_local_state="none"
    if [ "${LOCAL_APK}" = "auto" ]; then
        _eb_built=$(_local_body_build) || {
            printf 'baseline: the local class body could not be built; pass --local-apk <file> with one built elsewhere\n' >&2
            BASELINE_REASON="local:body-not-built"
            return 2
        }
        LOCAL_APK=${_eb_built}
        LOCAL_BODY_SOURCE="built"
    fi
    if [ -n "${LOCAL_APK}" ]; then
        if [ ! -f "${LOCAL_APK}" ]; then
            printf 'baseline: no local body at %s\n' "${LOCAL_APK}" >&2
            BASELINE_REASON="local:no-body"
            return 2
        fi
        if [ -z "${LOCAL_PKG}" ]; then
            LOCAL_PKG=$(_apk_split "${LOCAL_APK}") || {
                printf 'baseline: %s does not follow apk naming (name-<version>-r<rev>.apk); pass --local-pkg\n' \
                    "${LOCAL_APK}" >&2
                BASELINE_REASON="local:apk-name-unreadable"
                return 2
            }
            LOCAL_PKG=${LOCAL_PKG%% *}
        fi
        _eb_local_file="${SCRATCH}/${LOCAL_APK##*/}"
        if ! dev_push "${LOCAL_APK}" "${_eb_local_file}" >/dev/null; then
            printf 'baseline: the local body could not be pushed to %s\n' "${_eb_local_file}" >&2
            BASELINE_REASON="local:body-unpushed"
            return 2
        fi
        _eb_local_state="pushed"
        [ -n "${LOCAL_BODY_SOURCE}" ] || LOCAL_BODY_SOURCE="given"
    fi
    if [ -z "${LOCAL_PKG}" ]; then
        printf 'baseline: the local class needs a body no feed offers: pass --local-apk <file>, --local-pkg <name> for a body already kept in %s, or --local-apk auto to build one\n' \
            "${ASSETS}" >&2
        BASELINE_REASON="local:no-body"
        return 2
    fi
    LOCAL_REMOTE_BODY=${_eb_local_file}
    ev "baseline: installing the three classes (distfeeds=${DIST_PKG} customfeeds=${CUSTOM_PKG} local=${LOCAL_PKG}, local-body=${_eb_local_state}, local-body-source=${LOCAL_BODY_SOURCE:-kept})"
    if ! _ask baseline; then
        BASELINE_REASON="baseline:no-answer"
        return 2
    fi
    printf '%s\n' "${_baseline_answer}" | sed 's/^/  baseline: /' | tr '\t' ' '
    _eb_csha=$(_meta_of "${_baseline_answer:-}" customfeeds_sha256)
    _eb_csrc=$(_meta_of "${_baseline_answer:-}" custom_source)
    _eb_source=$(_meta_of "${_baseline_answer:-}" source_state)
    case "${_eb_csrc}" in
        '' | -)
            printf 'baseline: no source in %s and none named by --customfeed-url: ac-13 cannot be judged\n' \
                "${CUSTOMFEEDS}" >&2
            BASELINE_REASON="customfeeds:no-source"
            ev "baseline: no custom source"
            return 2
            ;;
    esac
    # A source that was just added and could not be indexed means the source is unreachable
    # now; that is a fact about the network, not about the machine's packages.
    case "${_eb_source}" in
        *unindexed*)
            printf 'baseline: the user source was added but apk could not index it (%s)\n' "${_eb_source}" >&2
            ev "baseline: custom source unindexed ${_eb_source}"
            BASELINE_REASON="customfeeds:source-unindexed"
            return 2
            ;;
    esac
    CUSTOM_SOURCE=${_eb_csrc}
    CUSTOM_SOURCE_AT_BASELINE=${_eb_csrc}
    # Every class has to have installed and marked; one that did not is a gap, and the row
    # names which one - the other two are not a substitute.
    _eb_bad=""
    for _eb_cls in ${CLASSES}; do
        if ! _install_row "${_eb_cls}"; then
            _eb_bad="${_eb_bad} ${_eb_cls}:no-answer"
            continue
        fi
        case "${_f3:-}" in
            installed | adopted) : ;;
            *) _eb_bad="${_eb_bad} ${_eb_cls}:${_f3:-failed}" ;;
        esac
    done
    if [ -n "${_eb_bad}" ]; then
        printf 'baseline: the samples could not all be installed:%s (see the rows above)\n' "${_eb_bad}" >&2
        BASELINE_REASON="baseline:install$(printf '%s' "${_eb_bad}" | tr ' ' ',')"
        ev "baseline: install gap${_eb_bad}"
        return 2
    fi
    if ! _baseline_write "${_eb_csha}" "${_eb_csrc}"; then
        printf 'baseline: cannot write the baseline to %s\n' "${STATE}" >&2
        BASELINE_REASON="baseline:unwritable"
        return 2
    fi
    BASELINE_MODE=created
    ev "baseline created ${STATE} custom_source=${_eb_csrc} customfeeds_sha256=$(_short "${_eb_csha}")"
    return 0
}

_baseline_write() { # <customfeeds-sha> <custom-source>
    _bw_csha=${1:-}
    _bw_csrc=${2:-}
    _bw_tmp="${STATE}.tmp.$$"
    mkdir -p "$(dirname "${STATE}")" 2>/dev/null || return 1
    {
        printf '# package-classes state schema=1 customfeeds=%s customfeeds_sha256=%s custom_source=%s world=%s assets=%s config_dir=%s marker_dir=%s\n' \
            "${CUSTOMFEEDS}" "${_bw_csha}" "${_bw_csrc}" "${WORLD}" "${ASSETS}" "${CONFIG_DIR}" "${MARKER_DIR}"
        printf '# columns=class,pkg,version,installed,config,config_sha256,marker,marker_sha256,world,sources,body,body_sha256\n'
        for _bw_cls in ${CLASSES}; do
            _bw_line=$(_row_of "${_baseline_answer:-}" "${_bw_cls}")
            [ -n "${_bw_line}" ] || continue
            _split "${_bw_line}"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${_f1}" "${_f2}" "${_f3}" "${_f4}" "${_f5}" "${_f6}" \
                "${_f7}" "${_f8}" "${_f9}" "${_f10}" "${_f11}" "${_f12}"
        done
    } >"${_bw_tmp}" 2>/dev/null || {
        rm -f "${_bw_tmp}"
        return 1
    }
    mv "${_bw_tmp}" "${STATE}" 2>/dev/null || {
        rm -f "${_bw_tmp}"
        return 1
    }
    return 0
}

# --------------------------------------------------------------------------- #
# Judging the three classes
# --------------------------------------------------------------------------- #

_check() { "$@" || HOP_FAILED=1; }

# _class_fail <case> <class> <reason> <detail>: one FAIL line a person can act on. The verdict
# token is appended once per class, by _judge_class, and not here: a class that fails three
# checks is still one class, and a row reading `local:fail,local:fail,local:fail` would look
# like three broken things.
_class_fail() {
    _cf_case=${1:-?}
    _cf_cls=${2:-?}
    _cf_reason=${3:-failed}
    _cf_detail=${4:-}
    _dev_assert_fail "${_cf_case}" "class=${_cf_cls} reason=${_cf_reason} detail=${_cf_detail}"
    ev "class ${_cf_cls} verdict=fail reason=${_cf_reason} detail=${_cf_detail}"
}

# _judge_class <case> <class>: one class, every criterion of its own, and nothing borrowed
# from the other two. Returns 0 pass, 1 fail (already reported as a FAIL line).
_judge_class() {
    _jc_case=${1:?}
    _jc_cls=${2:?}
    if ! _probe_row "${_jc_cls}"; then
        _class_fail "${_jc_case}" "${_jc_cls}" no-answer "the ${_jc_cls} probe printed no facts"
        return 1
    fi
    _now_ver=${_f3}
    _now_ins=${_f4}
    _now_csha=${_f6}
    _now_msha=${_f8}
    _now_world=${_f9}
    _now_src=${_f10}
    _now_body=${_f11}
    _now_bsha=${_f12}
    _now_crc=${_f13}
    _now_cout=${_f14}
    if ! _baseline_row "${_jc_cls}"; then
        _class_fail "${_jc_case}" "${_jc_cls}" no-baseline "the state file has no row for ${_jc_cls}"
        return 1
    fi
    _b_ver=${_f3}
    _b_csha=${_f6}
    _b_msha=${_f8}
    _b_body=${_f11}
    _b_bsha=${_f12}

    _jc_bad=0
    # 1) The record. This is the fact every class shares: an installed package apk no longer
    #    knows about is gone whatever else is true.
    if [ "${_now_ins}" != "yes" ]; then
        _class_fail "${_jc_case}" "${_jc_cls}" not-installed "apk has no record of $(class_pkg "${_jc_cls}")"
        _jc_bad=1
    fi
    # 2) The fake configuration and the /data marker, byte for byte.
    if [ "${_now_csha}" != "${_b_csha}" ]; then
        _class_fail "${_jc_case}" "${_jc_cls}" config-changed \
            "config=${_f5} baseline=$(_short "${_b_csha}") now=$(_short "${_now_csha}")"
        _jc_bad=1
    fi
    if [ "${_now_msha}" != "${_b_msha}" ]; then
        _class_fail "${_jc_case}" "${_jc_cls}" data-lost \
            "marker=${_f7} baseline=$(_short "${_b_msha}") now=$(_short "${_now_msha}")"
        _jc_bad=1
    fi
    # 3) The world entry, unless the follow's own prune is what removed it.
    if [ "${_now_world}" != "present" ]; then
        if _dropped_has "$(_probe_meta dropped)" "$(class_pkg "${_jc_cls}")"; then
            WORLD_DROPPED="${WORLD_DROPPED:+${WORLD_DROPPED},}$(class_pkg "${_jc_cls}")"
            ev "class ${_jc_cls}: world entry dropped by the follow's prune (recorded, not judged)"
        else
            _class_fail "${_jc_case}" "${_jc_cls}" world-lost \
                "$(class_pkg "${_jc_cls}") is not in ${WORLD} and the follow's record does not name it"
            _jc_bad=1
        fi
    fi
    # 4) The version, recorded for every class: a version that changed tells a reader the
    #    package followed; one that held is the expected answer for the user-space feeds.
    if [ "${_now_ver}" = "${_b_ver}" ]; then
        VERSION_FACT="${VERSION_FACT:+${VERSION_FACT},}${_jc_cls}:held"
    else
        VERSION_FACT="${VERSION_FACT:+${VERSION_FACT},}${_jc_cls}:${_b_ver:--}->${_now_ver:--}"
    fi

    case "${_jc_cls}" in
        distfeeds)
            # 5a) Still usable, by the class's own check.
            if [ "${_now_crc}" != "0" ]; then
                _class_fail "${_jc_case}" "${_jc_cls}" check-crashed \
                    "check=${DIST_CHECK} rc=${_now_crc} out=$(_short "${_now_cout}")"
                _jc_bad=1
            elif ! printf '%s\n' "${_now_cout}" | grep -Eq "${DIST_EXPECT}"; then
                _class_fail "${_jc_case}" "${_jc_cls}" unusable \
                    "expect=\"${DIST_EXPECT}\" out=$(_short "${_now_cout}")"
                _jc_bad=1
            fi
            # 5b) The new base's own feed still offers it. An installed package the running
            #     base's feed has never heard of is the state this chain exists to catch.
            if ! _sources_kind "${_now_src}" feed; then
                _class_fail "${_jc_case}" "${_jc_cls}" feed-no-longer-offers \
                    "ab-packages sources $(class_pkg "${_jc_cls}") = ${_now_src:--}"
                _jc_bad=1
            fi
            ;;
        customfeeds)
            # 5a) The file itself, byte for byte. The aligner rewrites the feeds it owns and
            #     leaves customfeeds.list alone; a line rewritten there is what this catches.
            _jc_b_csha=$(_state_meta customfeeds_sha256)
            _jc_n_csha=$(_probe_meta customfeeds_sha256)
            if [ "${_jc_n_csha}" != "${_jc_b_csha}" ]; then
                _class_fail "${_jc_case}" "${_jc_cls}" customfeeds-rewritten \
                    "file=${CUSTOMFEEDS} baseline=$(_short "${_jc_b_csha}") now=$(_short "${_jc_n_csha}")"
                _jc_bad=1
                CUSTOMFEEDS_FACT="rewritten"
            else
                CUSTOMFEEDS_FACT="unchanged"
            fi
            # 5b) The source is still named as a source of the sample.
            if ! _sources_url "${_now_src}" customfeeds "${CUSTOM_SOURCE_AT_BASELINE}"; then
                _class_fail "${_jc_case}" "${_jc_cls}" source-gone \
                    "ab-packages sources $(class_pkg "${_jc_cls}") no longer names ${CUSTOM_SOURCE_AT_BASELINE}: ${_now_src:--}"
                _jc_bad=1
            fi
            # 5c) A package nobody installed from that source yet still installs from it.
            if ! _refresh_row customfeeds; then
                _class_fail "${_jc_case}" "${_jc_cls}" no-refresh-answer \
                    "the refresh script printed no customfeeds line"
                _jc_bad=1
            else
                _jr_rc=${_f4}
                _jr_inst=${_f5}
                _jr_del=${_f6}
                NEWPKG_FACT="${NEW_PKG}:install=${_jr_inst},del=${_jr_del}"
                if [ "${_jr_rc}" != "0" ] || [ "${_jr_inst}" != "yes" ]; then
                    _class_fail "${_jc_case}" "${_jc_cls}" cannot-install-new \
                        "new=${NEW_PKG} rc=${_jr_rc} install=${_jr_inst} detail=$(_short "${_f8}")"
                    _jc_bad=1
                fi
            fi
            ;;
        local)
            # 5a) The kept body is where the gate looks for it, and it is the body the
            #     baseline kept: same path, same sha256.
            if [ "${_now_body}" = "-" ] || [ -z "${_now_body}" ]; then
                _class_fail "${_jc_case}" "${_jc_cls}" body-missing \
                    "no ${ASSETS}/$(class_pkg "${_jc_cls}")-*.apk"
                _jc_bad=1
            elif [ "${_now_bsha}" != "${_b_bsha}" ] || [ "${_now_body}" != "${_b_body}" ]; then
                _class_fail "${_jc_case}" "${_jc_cls}" body-changed \
                    "body=$(_short "${_b_body}")->$(_short "${_now_body}") sha=$(_short "${_b_bsha}")->$(_short "${_now_bsha}")"
                _jc_bad=1
            fi
            # 5b) Replay: the only fact that says the package can still be installed on the
            #     base the machine now runs.
            if ! _refresh_row local; then
                _class_fail "${_jc_case}" "${_jc_cls}" no-replay-answer \
                    "the refresh script printed no local line"
                _jc_bad=1
            else
                _jr_rc=${_f4}
                _jr_result=${_f5}
                _jr_failed=${_f7}
                REPLAY_FACT="result=${_jr_result},failed=${_jr_failed}"
                if [ "${_jr_rc}" != "0" ] || [ "${_jr_result}" = "failed" ] || [ "${_jr_failed:-0}" != "0" ]; then
                    _class_fail "${_jc_case}" "${_jc_cls}" replay-failed \
                        "replay result=${_jr_result} failed=${_jr_failed} rc=${_jr_rc}"
                    _jc_bad=1
                fi
            fi
            ;;
    esac
    if [ "${_jc_bad}" -ne 0 ]; then
        CLASS_SUMMARY="${CLASS_SUMMARY} ${_jc_cls}:fail"
        return 1
    fi
    CLASS_SUMMARY="${CLASS_SUMMARY} ${_jc_cls}:pass"
    ev "class ${_jc_cls} verdict=pass version=${_now_ver:-none} world=${_now_world} sources=${_now_src}"
    return 0
}

# `ab-packages sources <name>` prints one `package=<n> source=<kind> [url=<url>]` line per
# source, joined with `;` on the machine. Matching is by substring and not by pattern, because
# a URL is full of characters a pattern would read as syntax:
#   _sources_kind  some source of this kind offers the name - the distfeeds class, whose URL
#                  is the base's own and changes with every hop
#   _sources_url   this exact source offers it - the customfeeds class, whose URL must not move
_sources_kind() {
    case "${1:-}" in
        *"source=${2:?} url="*) return 0 ;;
    esac
    return 1
}

_sources_url() {
    case "${1:-}" in
        *"source=${2:?} url=${3:?}"*) return 0 ;;
    esac
    return 1
}

# --------------------------------------------------------------------------- #
# One hop
# --------------------------------------------------------------------------- #

# _preflight <case> <verdict> <note>: a row for a case that was refused before any machine was
# touched, so a missing payload never looks like a broken machine.
_preflight() {
    printf '== %s (refused before any machine was touched)\n' "${1}"
    record "${1}" "${2}" - "${3}"
    printf '   %s: %s\n' "${1}" "${3}"
}

# hop_payload_path <case>: the payload file this hop carries.
payload_override() {
    for _po_spec in ${PAYLOAD_SPECS}; do
        case "${_po_spec}" in
            "$1="*) printf '%s\n' "${_po_spec#*=}"; return 0 ;;
        esac
    done
    return 1
}

hop_payload_path() {
    if _po_ov=$(payload_override "${1}"); then
        printf '%s\n' "${_po_ov}"
        return 0
    fi
    _po_name=$(case_payload "${1}") || return 1
    printf '%s/%s\n' "${PAYLOAD_DIR}" "${_po_name}"
}

# check_payload_line <case> <path>: refuse a payload this chain may not walk. The same rule
# matrix-round2.sh and matrix-rise.sh apply, restated because those files are drivers and not
# a library: 24.x is opkg-era, and a payload named after a platform release (0.0.x) is a
# platform hop, not a base hop.
check_payload_line() {
    _cp_name=${2##*/}
    _cp_v=$(printf '%s\n' "${_cp_name}" \
        | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[^0-9]*$/\1/p')
    if [ -z "${_cp_v}" ]; then
        printf 'unsupported payload name: %s carries no version this chain can read (want payload-<version>.tar)\n' \
            "${_cp_name}"
        return 1
    fi
    case "${_cp_v}" in
        0.*)
            printf 'unsupported payload line: %s is a platform payload, but %s is a base hop\n' \
                "${_cp_v}" "${1}"
            return 1
            ;;
        *) require_supported_line "${_cp_v}" "${2}" ;;
    esac
}

# hop_run <case>: 0 PASS, 1 FAIL, 2 GAP.
hop_run() {
    _case=${1:?hop_run needs a case}
    CASE_NOTE=""
    CLASS_SUMMARY=""
    WORLD_DROPPED=""
    VERSION_FACT=""
    CUSTOMFEEDS_FACT=""
    NEWPKG_FACT=""
    REPLAY_FACT=""
    HOP_FAILED=0
    AB_EVIDENCE_LOG="${EVIDENCE_DIR}/${_case}.log"
    AB_MATRIX_CMD="$0 --only ${_case}"
    export AB_EVIDENCE_LOG AB_MATRIX_CMD
    : >"${AB_EVIDENCE_LOG}"

    _local=$(hop_payload_path "${_case}") || {
        CASE_NOTE="no payload name for ${_case}"
        return 2
    }
    if [ ! -f "${_local}" ]; then
        CASE_NOTE="no payload at ${_local}"
        ev "${CASE_NOTE}"
        return 2
    fi

    _from=$(case_from_rootfs "${_case}") || return 1
    _to=$(case_to_rootfs "${_case}") || return 1
    _dir=$(direction_of "${_from}" "${_to}")

    require_healthy "${_case}" || return 1
    _before=${STATUS_LINE}
    AB_STATUS_LINE=${_before}
    require_safe_target "${_case}" "${_before}" || return 1
    _gen=$(status_field "${_before}" generation) || _gen=0
    _slot=$(status_field "${_before}" slot) || _slot=""
    _target=$(other_slot "${_slot}") || return 1
    _running=$(dev_running_version) || _running=""
    if ! assert_value "${_running}" "${_from}" "${_case}" "chain-position"; then
        CASE_NOTE="chain broken: the machine runs ${_running:-unknown}, this hop starts from ${_from}; rerun with --from <the step this machine is at>"
        ev "${CASE_NOTE}"
        return 1
    fi
    ev "hop ${_case}: ${_from} -> ${_to} (${_dir}); slot ${_slot}, target ${_target}, generation ${_gen}"

    _remote="${AB_REMOTE_TMP}/${_local##*/}"
    dev_ssh 'ab-slot gc' >/dev/null 2>&1 || ev "gc reported problems (not a hop failure)"
    if ! dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_local}" "${_remote}" >/dev/null; then
        CASE_NOTE="the payload could not be pushed to ${_remote}"
        ev "${CASE_NOTE}"
        return 1
    fi
    dev_capture "${AB_EVIDENCE_LOG}" dev_cleanup_slot_mounts >/dev/null
    ev "pre-check: /mnt/slots/* unmounted; --check may remount them, so their absence is not asserted"

    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ab_check "${_remote}")
    _rc=$?
    case "${_rc}" in
        0) ;;
        74)
            CASE_NOTE="ab-upgrade --check refused a cross-base payload (exit 74): $(printf '%s\n' "${_out}" | grep -m 1 'refused' || printf 'no refusal line')"
            ev "${CASE_NOTE}"
            return 1
            ;;
        *)
            CASE_NOTE="ab-upgrade --check exited ${_rc}: $(printf '%s\n' "${_out}" | tail -n 1)"
            ev "${CASE_NOTE}"
            return 1
            ;;
    esac
    if ! _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_install "${_remote}"); then
        CASE_NOTE="ab-upgrade did not install ${_to}"
        ev "${CASE_NOTE}"
        return 1
    fi
    _armed=$(dev_capture "${AB_EVIDENCE_LOG}" dev_status) || {
        CASE_NOTE="ab-slot status is unreadable after the install"
        return 1
    }
    AB_STATUS_LINE=${_armed}
    HOP_FAILED=0
    _check assert_field pending "${_target}" "${_case}"
    _check assert_ge "$(status_field "${_armed}" generation || printf 0)" "$((_gen + 1))" "${_case}" generation
    if [ "${HOP_FAILED}" -ne 0 ]; then
        CASE_NOTE="the install did not arm slot ${_target} (pending/generation)"
        ev "${CASE_NOTE}"
        return 1
    fi

    dev_reboot
    if ! dev_wait_up_after after-install; then
        CASE_NOTE="no ssh answer within ${AB_WAIT_UP_FIRST}s after the reboot"
        ev "${CASE_NOTE}"
        return 1
    fi
    if ! _booted=$(dev_capture "${AB_EVIDENCE_LOG}" dev_wait_settled "${AB_WAIT_SETTLE}"); then
        CASE_NOTE="no status line within ${AB_WAIT_SETTLE}s after the machine answered ssh"
        ev "${CASE_NOTE}"
        return 1
    fi
    # shellcheck disable=SC2034 # read by the assert_* helpers in lib.sh
    AB_STATUS_LINE=${_booted}

    HOP_FAILED=0
    _check ab_status_switch_check "${_before}" "${_booted}" "${_case}"
    _check assert_field boot ok "${_case}"
    _check assert_field esp ok "${_case}"
    _check assert_field pending none "${_case}"
    _check assert_field committed "${_target}" "${_case}"
    _check assert_field packages aligned "${_case}"
    _check assert_ge "$(status_field "${_booted}" generation || printf 0)" "$((_gen + 1))" "${_case}" generation
    _running_now=$(dev_running_version) || _running_now=""
    _check assert_value "${_running_now}" "${_to}" "${_case}" rootfs
    _check assert_value "$(direction_of "${_from}" "${_running_now}")" "${_dir}" "${_case}" direction
    _check assert_match "$(status_field "${_booted}" upper || printf '')" \
        "^@overlay-$(dev_version_re "${_to}")(-r[0-9]+)?\$" "${_case}" upper
    if [ "${HOP_FAILED}" -ne 0 ]; then
        _first_fail=$(grep -m 1 "FAIL ${_case} " "${AB_EVIDENCE_LOG}" 2>/dev/null) || _first_fail=""
        CASE_NOTE="assertions failed on this hop: $(printf '%s\n' "${_first_fail}" | sed 's/^FAIL [^ ]* //'); the chain stops here"
        ev "${CASE_NOTE}"
        return 1
    fi

    # The classes, read-only first: the probe must describe the machine the hop landed on,
    # before this driver's own transactions (the replay, the new package) change it.
    if ! _ask probe; then
        CASE_NOTE="the class probe did not answer; ac-12/ac-13 were not measured on this hop"
        ev "${CASE_NOTE}"
        return 2
    fi
    printf '%s\n' "${_probe_answer}" | sed 's/^/  probe: /' | tr '\t' ' '
    ev "probe: $(printf '%s' "${_probe_answer}" | tr '\n' '|' | cut -c1-4000)"
    if ! _ask refresh; then
        CASE_NOTE="the refresh script did not answer (the new package and the replay were not measured)"
        ev "${CASE_NOTE}"
        return 2
    fi
    printf '%s\n' "${_refresh_answer}" | sed 's/^/  refresh: /' | tr '\t' ' '
    ev "refresh: $(printf '%s' "${_refresh_answer}" | tr '\n' '|' | cut -c1-2000)"

    # The customfeeds file's sha256 comes from the probe's meta line; the baseline's from the
    # state. _judge_class reads both, so nothing here has to carry it.
    HOP_FAILED=0
    for _cls in ${CLASSES}; do
        _check _judge_class "${_case}" "${_cls}"
    done

    _gen_now=$(status_field "${_booted}" generation) || _gen_now="?"
    _pkg_now=$(status_field "${_booted}" packages) || _pkg_now="?"
    _base_fact="base ${_from}->${_to} (${_dir}), committed ${_target}, generation ${_gen}->${_gen_now}, packages=${_pkg_now}"
    _class_fact="classes=$(printf '%s' "${CLASS_SUMMARY}" | sed 's/^ //' | tr ' ' ',')"
    _tail_fact="${_class_fact}; customfeeds-list=${CUSTOMFEEDS_FACT:-unmeasured}; new=${NEWPKG_FACT:-none}; replay=${REPLAY_FACT:-none}; world_dropped=${WORLD_DROPPED:-none}; versions=${VERSION_FACT:-unknown}"

    if [ "${HOP_FAILED}" -ne 0 ]; then
        _first_fail=$(grep -m 1 "FAIL ${_case} " "${AB_EVIDENCE_LOG}" 2>/dev/null) || _first_fail=""
        CASE_NOTE="assertions failed on this hop: $(printf '%s\n' "${_first_fail}" | sed 's/^FAIL [^ ]* //'); ${_base_fact}; ${_tail_fact}"
        ev "${CASE_NOTE}"
        return 1
    fi
    CASE_NOTE="${_base_fact}; ${_tail_fact}"
    ev "hop ${_case} ok: ${CASE_NOTE}"
    return 0
}

# --------------------------------------------------------------------------- #
# Selection, and the plan
# --------------------------------------------------------------------------- #

select_cases() {
    _sel=""
    for _c in ${CHAIN}; do
        _sel="${_sel} ${_c}"
    done
    _sel=${_sel# }
    if [ -n "${ONLY_CASE}" ]; then
        case_step "${ONLY_CASE}" >/dev/null || {
            printf 'package-classes: unknown case: %s (want one of: %s)\n' "${ONLY_CASE}" "${CHAIN}" >&2
            return 2
        }
        _sel=${ONLY_CASE}
    elif [ -n "${FROM_STEP}" ]; then
        _started=0
        _out=""
        for _c in ${_sel}; do
            if [ "${_started}" = "0" ]; then
                if [ "${FROM_STEP}" = "$(case_step "${_c}")" ] || [ "${FROM_STEP}" = "${_c}" ]; then
                    _started=1
                else
                    continue
                fi
            fi
            _out="${_out} ${_c}"
        done
        if [ "${_started}" = "0" ]; then
            printf 'package-classes: --from %s is not a step of the chain (%s)\n' "${FROM_STEP}" "${CHAIN}" >&2
            return 2
        fi
        _sel=${_out# }
    fi
    if [ "${RESUME}" = "1" ]; then
        # A chain is only resumable at a point it actually reached: a PASS row is skipped only
        # while every row before it is PASS too.
        _out=""
        _skip=1
        for _c in ${_sel}; do
            if [ "${_skip}" = "1" ] && record_passed "${_c}"; then
                printf 'package-classes: resume: %s already has a PASS row in %s, skipped\n' \
                    "${_c}" "${AB_RESULTS}" >&2
                continue
            fi
            _skip=0
            _out="${_out} ${_c}"
        done
        _sel=${_out# }
    fi
    printf '%s\n' "${_sel}"
}

plan_case() { # <case>: what the hop will do, printed and not done.
    _case=${1:?plan_case needs a case}
    printf '# %s %s\n' "${_case}" "$(hop_expect "${_case}")"
    _local=$(hop_payload_path "${_case}") || return 1
    if [ ! -f "${_local}" ]; then
        printf '# warning: no payload at %s; the run would record GAP\n' "${_local}"
    fi
    # The baseline is recorded once, by the first hop of the run: a plan that repeated the
    # install on every hop would describe a chain that re-marks what it is here to measure.
    if _baseline_present; then
        printf '%s baseline: %s is there; the three classes are not re-marked\n' "${_case}" "${STATE}"
    elif [ "${_case}" = "${SELECTED%% *}" ]; then
        # A body this run builds is named as such: a plan that printed the string `auto` would
        # leave the reader to guess whether a file exists yet.
        if [ "${LOCAL_APK}" = "auto" ]; then
            _plan_local="a body this run builds (${LOCAL_BODY_PKG}-${LOCAL_BODY_VERSION}.apk, no feed offers it)"
        else
            _plan_local=${LOCAL_APK:-a body kept in ${ASSETS}/}
        fi
        printf '%s baseline: install %s from distfeeds.list, %s from %s, and the local class from %s; write %s and %s; record sha256 into %s\n' \
            "${_case}" "${DIST_PKG}" "${CUSTOM_PKG}" \
            "${CUSTOM_URL:-the first source in ${CUSTOMFEEDS}}" \
            "${_plan_local}" \
            "${CONFIG_DIR}/<pkg>" "${MARKER_DIR}/<pkg>.marker" "${STATE}"
    else
        printf '%s baseline: recorded by the first hop of this run, not again here\n' "${_case}"
    fi
    printf '%s status (red line: a committed slot, boot=ok, esp=ok, pending=none)\n' "${_case}"
    printf '%s gc\n' "${_case}"
    printf '%s push %s -> %s/%s\n' "${_case}" "${_local}" "${AB_REMOTE_TMP}" "${_local##*/}"
    printf '%s check %s/%s expect=exit-0, any refusal is a FAIL (no hop of this chain is same-base)\n' \
        "${_case}" "${AB_REMOTE_TMP}" "${_local##*/}"
    printf '%s install %s/%s\n' "${_case}" "${AB_REMOTE_TMP}" "${_local##*/}"
    printf '%s reboot, then wait_up %ss, then settle until boot=ok pending=none\n' \
        "${_case}" "${AB_WAIT_UP_FIRST}"
    printf '%s assert boot=ok esp=ok pending=none committed=<the slot that is not running> generation>=+1 packages=aligned rootfs=%s upper=@overlay-%s(-rN)? direction=%s\n' \
        "${_case}" "$(case_to_rootfs "${_case}")" "$(case_to_rootfs "${_case}")" \
        "$(hop_expect_value "${_case}" direction)"
    printf '%s assert the stable fields did not move: %s\n' "${_case}" "${AB_STATUS_FIELDS_STABLE}"
    for _cls in ${CLASSES}; do
        printf '%s class %s: %s\n' "${_case}" "${_cls}" "$(class_criterion "${_cls}")"
    done
    printf '%s assert every class: config and /data marker sha256 unchanged, world entry present (a pruned one is recorded as world_dropped)\n' \
        "${_case}"
    printf '%s record\n' "${_case}"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

# The sample names travel into a remote command line and into a world-entry regex, so their
# shape is a usage error rather than something to escape.
for _pn in "${DIST_PKG}" "${CUSTOM_PKG}" "${NEW_PKG}" "${LOCAL_PKG}"; do
    [ -n "${_pn}" ] || continue
    if ! _name_ok "${_pn}"; then
        printf 'package-classes: not an apk package name: %s\n' "${_pn}" >&2
        exit 2
    fi
done

SELECTED=$(select_cases) || exit 2

if [ "${DRY_RUN}" = "1" ]; then
    printf '# run chain="%s" resume=%s results=%s state=%s marker-dir=%s customfeeds=%s\n' \
        "${SELECTED}" "${RESUME}" "${AB_RESULTS}" "${STATE}" "${MARKER_DIR}" "${CUSTOMFEEDS}"
    printf '# classes: %s\n' "${CLASSES}"
    for _case in ${SELECTED}; do
        plan_case "${_case}" || exit 2
    done
    exit 0
fi

if [ -z "${SELECTED}" ]; then
    printf 'package-classes: nothing to walk: every hop of "%s" already has a PASS row in %s\n' \
        "${CHAIN}" "${AB_RESULTS}"
    exit 0
fi

mkdir -p "${EVIDENCE_DIR}" || {
    printf 'package-classes: cannot create %s\n' "${EVIDENCE_DIR}" >&2
    exit 2
}

# The payloads are judged before the machine is touched: a 24.x payload or a platform payload
# on a base hop is a scope violation, and discovering it after a failed boot would look like a
# product defect.
for _case in ${SELECTED}; do
    _p=$(hop_payload_path "${_case}") || {
        _preflight "${_case}" FAIL "no payload name for ${_case}"
        exit 1
    }
    if [ ! -f "${_p}" ]; then
        _preflight "${_case}" GAP "no payload at ${_p} (build it, or pass --payload ${_case}=<path>)"
        exit 4
    fi
    if ! _msg=$(check_payload_line "${_case}" "${_p}" 2>&1); then
        _preflight "${_case}" FAIL "${_msg}"
        exit 1
    fi
done

# The baseline runs before the first hop and after the red line: a machine with no committed
# slot has nothing to fall back to, and recording samples on it would be work done on a
# machine that cannot commit the hop anyway.
AB_EVIDENCE_LOG="${EVIDENCE_DIR}/00-baseline.log"
AB_MATRIX_CMD="$0"
export AB_EVIDENCE_LOG AB_MATRIX_CMD
: >"${AB_EVIDENCE_LOG}"
_first=${SELECTED%% *}
require_healthy "${_first}"
ev "run chain=\"${SELECTED}\" classes=${CLASSES} customfeeds=${CUSTOMFEEDS} state=${STATE}"
ev "baseline: ${STATUS_LINE}"
ensure_baseline "${_first}"
_bl_rc=$?
if [ "${_bl_rc}" -ne 0 ]; then
    _preflight "${_first}" GAP "the three-class baseline could not be established (${BASELINE_REASON:-baseline:unknown}): see the lines above; nothing was hopped"
    exit 4
fi
printf 'package-classes: baseline %s (%s), classes %s, chain %s\n' \
    "${BASELINE_MODE}" "${STATE}" "${CLASSES}" "${SELECTED}"

_passed=0
_failed=0
_gapped=0

for _case in ${SELECTED}; do
    printf '== %s %s\n' "${_case}" \
        "kind=base direction=$(hop_expect_value "${_case}" direction) $(hop_expect_value "${_case}" from-rootfs)->$(hop_expect_value "${_case}" to-rootfs)"
    hop_run "${_case}"
    _rc=$?
    case "${_rc}" in
        0)
            record "${_case}" PASS "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _passed=$((_passed + 1))
            ;;
        2)
            record "${_case}" GAP "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _gapped=$((_gapped + 1))
            printf '   %s: %s\n' "${_case}" "${CASE_NOTE}"
            break
            ;;
        *)
            record "${_case}" FAIL "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _failed=$((_failed + 1))
            printf '   %s: %s\n' "${_case}" "${CASE_NOTE}"
            break
            ;;
    esac
    printf '   %s: %s (%s)\n' "${_case}" "${CASE_NOTE}" "${AB_EVIDENCE_LOG}"
done

printf '\npackage-classes: passed=%s failed=%s gap=%s results=%s state=%s\n' \
    "${_passed}" "${_failed}" "${_gapped}" "${AB_RESULTS}" "${STATE}"
[ "${_failed}" -eq 0 ] || exit 1
[ "${_gapped}" -eq 0 ] || exit 4
exit 0
