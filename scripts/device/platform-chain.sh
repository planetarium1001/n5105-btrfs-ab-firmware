#!/bin/sh
# platform-chain.sh - the platform-only chain (ac-10): one base, four of our releases.
#
# matrix-round2 walks a machine across *bases*; this chain walks it across *this
# project's own layer* and asks the one question ac-10 is about: does a payload that keeps
# the base change nothing but the platform?
#
#   1. P11  payload-0.0.11.tar  0.0.10 -> 0.0.11  on 25.12.2
#   2. P12  payload-0.0.12.tar  0.0.11 -> 0.0.12  on 25.12.2
#   3. P13  payload-0.0.13.tar  0.0.12 -> 0.0.13  on 25.12.2
#
#   scripts/device/platform-chain.sh                       # the whole chain
#   scripts/device/platform-chain.sh --only P12            # one hop
#   scripts/device/platform-chain.sh --from-version 0.0.12 # resume at the hop that leaves 0.0.12
#   scripts/device/platform-chain.sh --resume              # skip the PASS rows whose predecessors are all PASS
#   scripts/device/platform-chain.sh --dry-run             # print the chain, touch nothing
#
# Positioning. Every hop declares the platform it starts from, and the machine has to be
# there. full-test.sh runs matrix, matrix-rise and scenarios before this chain and leaves
# the device on whichever platform their last case landed on; round 3 measured this chain
# starting at 0.0.13 while P11 declares 0.0.10, and the row said "chain broken" instead of
# naming the missing step. The chain now reads the running platform before its first hop
# and, when that is not the platform the selected chain starts from, installs
# <payload-dir>/payload-<start>.tar once to bring the machine there. The move is never
# silent: the first row carries `positioned=<from>-><to>`, the evidence log carries the
# same line, and a positioning hop that does not land healthy FAILs the run instead of
# letting the first hop describe a machine that never existed. The payload is named by the
# version, not by a case, and when it is absent the run records a GAP naming the file
# rather than walking a chain from the wrong line. This is matrix-round2's position_run
# with the base pinned to BASE_VERSION, because a platform-only hop may not move the base.
#
# Three groups are judged on every hop, and a hop is PASS only when all three hold:
#
#   A PLATFORM must move   generation, /etc/platform-release (version, upstream, digest) and
#                          the three CLIs (ab-slot, ab-upgrade, ab-packages) --version say
#                          the payload's platform version.
#   B BASE must not move   DISTRIB_RELEASE, the running kernel, and the three pins in
#                          /etc/apk/world (kernel, base-files, libc: the set the aligner
#                          aligns, platform/lib/upgrade/packages.sh AB_PACKAGES_PINS).
#   C USER must not move   every /etc/config/* file plus the /data marker (sha256), the
#                          user's own /etc/apk/world lines, the installed package set, and
#                          every sample in that set, by name.
#
# Why the three are judged and not merely recorded: matrix-round2 writes config and package
# drift into the row and judges only the six status fields, because ac-6 asks whether a hop
# commits. Here the drift *is* the question, so a hop that moves a config file is red even
# though it booted fine. That is not hypothetical: round 2 recorded
# `config-drift=1 change(s)` on its own P1 hop on a v0.0.10 image, and this chain is the
# place where that becomes a verdict instead of a footnote.
#
# The identity file is /etc/platform-release, not the /etc/ab-platform-release the design
# note for this task names: the payloads and platform/lib/ab-version.sh both carry
# /etc/platform-release (measured with `tar -tf` on payload-0.0.12.tar and read off
# platform/etc/platform-release), and a driver that read the other path would report every
# hop as "the platform did not move". AB_PC_RELEASE overrides it. The file is captured
# whole and hashed, rather than queried three times through `ab-version.sh`: the digest the
# chain compares is then the bytes a reader can also look at.
#
# ab-packages and the older payloads. Measured 2026-11-19 with `tar -tf` on the payloads in
# payloads/: the platform layer of 0.0.10, 0.0.11 and 0.0.12 carries ab-slot, ab-upgrade,
# ab-backup, ab-restore, btrfs and btrfsck -- no ab-packages. It is in this tree now, so
# 0.0.13 is the hop that carries it. Requiring the command on every hop would therefore
# report two false failures on the two hops that predate it. What is asserted instead:
#   * ab-slot and ab-upgrade are required everywhere (every payload of this line has them);
#   * a tool that is absent while the payload demonstrably carries it is a FAIL - the layer
#     did not install what it shipped;
#   * a tool that is absent and is *not* in the payload's layer is recorded as
#     `absent-in-payload` and not judged, which is the truth about 0.0.10..0.0.12.
# "The payload demonstrably carries it" is read out of the payload itself, offline: the
# payload wraps platform.tar, so its member list is the layer's file list. A payload that is
# not a readable tar (a placeholder in the driver's own test) answers "unknown" and the
# absent branch stays a note instead of guessing.
#
# Incompatibility is a GAP, not a forced install. When `ab-upgrade --check` exits non-zero
# with a readable `reason=`, this machine and this payload disagree and the hop is recorded
# as GAP with the reason named - never reinstalled with --force, because a forced install
# would write a slot precisely to hide the disagreement. matrix-round2 spends --force on
# `payload-already-installed` because round 1 measured that on a v0.0.10 image; here the
# same refusal means the chain was started on a release whose guard compares the base only,
# and the GAP note says so.
#
# Direction is computed, not read off a name: the platform move comes from ab_version_cmp
# (platform/lib/ab-version.sh), the base move is 25.12.2 -> 25.12.2 by construction, and a
# hop that lands on the wrong platform is red on `platform-version`, not retold in a note.
#
# Exit status: 0 every selected hop PASS, 1 a FAIL, 2 usage, 3 the red line stopped the run
# (no committed slot that booted and mounted the ESP cleanly), 4 a GAP (a payload that is
# not there, or one this machine refuses).
#
# `--dry-run` prints the chain, the positioning step and every hop's three groups without
# sending one ssh, and creates no results row and no evidence directory.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT

# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

# The config verifier is shared (unit 01) and is the same comparator matrix-round2 uses: a
# second snapshot/diff implementation is how two drivers start disagreeing about what "the
# config moved" means.
# shellcheck source=tests/lib/device_config.sh
. "${AB_DEVCFG_LIB:-${AB_REPO_ROOT}/tests/lib/device_config.sh}"

# Version ordering, so the direction of a hop is computed from the numbers.
# shellcheck source=platform/lib/ab-version.sh
. "${AB_VERSION_LIB:-${AB_REPO_ROOT}/platform/lib/ab-version.sh}"

# --------------------------------------------------------------------------- #
# Defaults and arguments
# --------------------------------------------------------------------------- #

# The chain, as steps. One machine walks it in this order; --only picks one hop out of it
# and --from-version resets the start.
CHAIN=${AB_PC_CHAIN:-"P11 P12 P13"}

# The base every payload of this chain carries. A hop is expected to keep it, and a hop
# that lands on another base is red on `base-rootfs` / `base-position`.
BASE_VERSION=${AB_PC_BASE:-25.12.2}
PAYLOAD_DIR=${AB_PAYLOAD_DIR:-payloads}
RESULTS=${AB_RESULTS:-results.tsv}
EVIDENCE_DIR=${AB_PC_EVIDENCE_DIR:-}
RELEASE_PATH=${AB_PC_RELEASE:-/etc/platform-release}
CONFIG_DIR=${AB_PC_CONFIG_DIR:-/etc/config}
MARKER_PATH=${AB_MARKER_PATH:-/data/ab-matrix.marker}

# The three CLIs this chain judges, and the two every payload of this line carries. See the
# header: ab-packages arrives with 0.0.13, so it is judged when it is there (or when the
# payload ships it) and recorded otherwise.
TOOLS=${AB_PC_TOOLS:-"ab-slot ab-upgrade ab-packages"}
TOOLS_REQUIRED=${AB_PC_TOOLS_REQUIRED:-"ab-slot ab-upgrade"}

# The pins the aligner owns, by their names in /etc/apk/world. Kept as a list here so the
# failure line can name the one that moved; the definition of record is
# AB_PACKAGES_PINS in platform/lib/upgrade/packages.sh.
PINS=${AB_PC_PINS:-"kernel base-files libc"}

PAYLOAD_SPECS=${AB_PC_PAYLOAD_SPECS:-}

ONLY_CASE=""
FROM_VERSION=""
DRY_RUN=0
RESUME=0
CASE_NOTE=""
STATUS_LINE=""
HOP_FAILED=0
# The chain start's positioning move, written into the first result row. Empty means the
# machine was already on the selected chain's starting platform, which is the common case
# inside a healthy phase order.
POSITIONED=""

# One capture per boundary. PC_* is "the machine as captured now", PRE_* is "as captured
# after the previous hop" (the hop's own starting point) and BASE_* is "as captured before
# the first hop" (what B and C are compared against). Keeping the three apart is what lets
# a failure say whether the platform moved *this* hop or an earlier one.
PC_PLATFORM=""
PC_UPSTREAM=""
PC_STAGE=""
PC_RELEASE_SHA=""
PC_DISTRIB=""
PC_KERNEL=""
PC_ROOTFS=""
PC_WORLD=""
PC_PINS=""
PC_CFG=""
PC_PKG=""
PC_WORLD_SNAP=""
PC_TOOLS=""
PRE_PLATFORM=""
PRE_ROOTFS=""
PRE_RELEASE_SHA=""
BASE_DISTRIB=""
BASE_KERNEL=""
BASE_PINS=""
BASE_CFG=""
BASE_PKG=""
BASE_WORLD_SNAP=""
BASE_SAMPLES=""

usage() {
    cat <<'USAGE'
usage: platform-chain.sh [--only <case>] [--from-version <v>] [--payload-dir DIR]
                         [--payload <case>=<path>]... [--results FILE]
                         [--evidence-dir DIR] [--resume] [--dry-run]

  --only <case>          walk one hop: P11 P12 P13
  --from-version <v>     start at the hop that leaves this platform version
                         (0.0.10, 0.0.11, 0.0.12; 0.0.13 means there is nothing to walk)
  --payload-dir DIR      where payload-0.0.NN.tar lives (default: payloads)
  --payload C=PATH       use PATH for case C instead of <payload-dir>/payload-<version>.tar
  --results FILE         results.tsv to append to (default: results.tsv)
  --evidence-dir DIR     evidence directory (default: <results dir>/evidence/platform-chain)
  --resume               skip the PASS rows whose predecessors are all PASS
  --dry-run              print the chain and each hop's three groups; no ssh is sent

Before the first hop, a machine that does not run the platform the selected chain starts
from is brought there once with <payload-dir>/payload-<start>.tar. This is the same
same-base platform move the hops themselves make; the first row records
positioned=<from>-><to> (with force=used when the running release refused the payload as
payload-already-installed and the documented --force flag was spent). A missing position
payload is a GAP naming the file; a positioning hop that does not land healthy is a FAIL.

Every hop is judged on three groups:
  A PLATFORM must move   generation / /etc/platform-release / ab-slot|ab-upgrade|ab-packages
  B BASE must not move   DISTRIB_RELEASE / kernel / the kernel, base-files and libc pins
  C USER must not move   /etc/config/* and /data marker sha256 / world lines / packages

Exit: 0 all PASS, 1 a FAIL, 2 usage, 3 red line, 4 GAP (payload missing or refused).
USAGE
}

while [ $# -gt 0 ]; do
    case "${1}" in
        --only)
            ONLY_CASE=${2:?--only needs a value}
            shift 2
            ;;
        --from-version)
            FROM_VERSION=${2:?--from-version needs a value}
            shift 2
            ;;
        --payload-dir)
            PAYLOAD_DIR=${2:?--payload-dir needs a value}
            shift 2
            ;;
        --payload)
            PAYLOAD_SPECS="${PAYLOAD_SPECS} ${2:?--payload needs <case>=<path>}"
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
        --resume)
            RESUME=1
            shift
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
            printf 'platform-chain: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "${ONLY_CASE}" ] && [ -n "${FROM_VERSION}" ]; then
    printf 'platform-chain: --only and --from-version answer different questions; pass one\n' >&2
    exit 2
fi

AB_RESULTS=${RESULTS}
[ -n "${EVIDENCE_DIR}" ] || EVIDENCE_DIR=$(dirname "${AB_RESULTS}")/evidence/platform-chain
AB_EVIDENCE_LOG=""
AB_MATRIX_CMD="$0"

if [ "${DRY_RUN}" = "1" ]; then
    # Belt and braces: the planner only prints, and every ssh helper refuses anyway.
    AB_DRY_RUN=1
fi
export AB_DRY_RUN AB_RESULTS AB_EVIDENCE_LOG AB_MATRIX_CMD

# --------------------------------------------------------------------------- #
# The step table
#
# One function per fact, so a hop is described once and both the plan and the assertions
# read that description. Adding a step means adding it here and to CHAIN; nothing else in
# this file names a platform version.
# --------------------------------------------------------------------------- #

case_from_platform() {
    case "${1}" in
        P11) printf '0.0.10\n' ;;
        P12) printf '0.0.11\n' ;;
        P13) printf '0.0.12\n' ;;
        *) return 1 ;;
    esac
}

case_to_platform() {
    case "${1}" in
        P11) printf '0.0.11\n' ;;
        P12) printf '0.0.12\n' ;;
        P13) printf '0.0.13\n' ;;
        *) return 1 ;;
    esac
}

case_payload() { # the payload file the hop carries, in PAYLOAD_DIR
    case "${1}" in
        P11) printf 'payload-0.0.11.tar\n' ;;
        P12) printf 'payload-0.0.12.tar\n' ;;
        P13) printf 'payload-0.0.13.tar\n' ;;
        *) return 1 ;;
    esac
}

case_step() { # 1-based position in the chain
    _cs_i=0
    for _cs_c in ${CHAIN}; do
        _cs_i=$((_cs_i + 1))
        if [ "${_cs_c}" = "${1}" ]; then
            printf '%s\n' "${_cs_i}"
            return 0
        fi
    done
    return 1
}

# chain_versions: the platform versions a chain may start from, plus the one it ends on.
chain_versions() {
    _cv_out=""
    for _cv_c in ${CHAIN}; do
        _cv_from=$(case_from_platform "${_cv_c}") || continue
        _cv_last=$(case_to_platform "${_cv_c}") || continue
        case " ${_cv_out} " in
            *" ${_cv_from} "*) : ;;
            *) _cv_out="${_cv_out} ${_cv_from}" ;;
        esac
    done
    printf '%s %s\n' "${_cv_out# }" "${_cv_last}"
}

# platform_direction <from> <to>: up, down or same - computed, never read off a name.
# ab_version_cmp prints 1 when its first argument is the newer one, so a "from" that is
# newer than its "to" is a hop down.
platform_direction() {
    if ! _pd_cmp=$(ab_version_cmp "${1:-}" "${2:-}" 2>/dev/null); then
        printf 'unknown\n'
        return 0
    fi
    case "${_pd_cmp}" in
        1) printf 'down\n' ;;
        -1) printf 'up\n' ;;
        *) printf 'same\n' ;;
    esac
}

# hop_expect <case>: the one description of what the hop must do and end in.
# hop_expect_value <case> <key> reads a field out of it, so an assertion cannot promise
# something the plan does not print.
hop_expect() {
    _he_c=${1:?hop_expect needs a case}
    _he_step=$(case_step "${_he_c}") || return 2
    _he_total=$(printf '%s\n' ${CHAIN} | wc -l | tr -d ' ')
    _he_from=$(case_from_platform "${_he_c}") || return 2
    _he_to=$(case_to_platform "${_he_c}") || return 2
    printf 'step=%s/%s kind=platform base=%s->%s base-direction=same platform=%s->%s platform-direction=%s payload=%s\n' \
        "${_he_step}" "${_he_total}" "${BASE_VERSION}" "${BASE_VERSION}" \
        "${_he_from}" "${_he_to}" "$(platform_direction "${_he_from}" "${_he_to}")" \
        "$(case_payload "${_he_c}")"
}

hop_expect_value() { # <case> <key>
    hop_expect "${1}" | tr ' ' '\n' | sed -n "s/^${2:?hop_expect_value needs a key}=//p" | head -n 1
}

# --------------------------------------------------------------------------- #
# Where a hop's payload comes from, and that it is the payload this hop describes
# --------------------------------------------------------------------------- #

payload_override() { # <case>: the --payload C=PATH the caller gave, if any
    for _po_spec in ${PAYLOAD_SPECS}; do
        case "${_po_spec}" in
            "$1="*) printf '%s\n' "${_po_spec#*=}"; return 0 ;;
        esac
    done
    return 1
}

hop_payload_path() { # <case>
    if _hp_ov=$(payload_override "${1}"); then
        printf '%s\n' "${_hp_ov}"
        return 0
    fi
    _hp_name=$(case_payload "${1}") || return 1
    printf '%s/%s\n' "${PAYLOAD_DIR}" "${_hp_name}"
}

# check_payload_line <case> <path>: refuse a payload this hop may not carry, before anything
# is written. A base payload (25.x) on a platform hop would install a rootfs nobody in this
# chain described, and a payload named for another platform release would install a layer
# the hop's expectations do not describe; both are a mistake in the invocation, not a
# product defect, so they are refused with no ssh.
check_payload_line() {
    _cpl_c=${1:?check_payload_line needs a case}
    _cpl_p=${2:?check_payload_line needs a payload path}
    _cpl_name=${_cpl_p##*/}
    _cpl_v=$(printf '%s\n' "${_cpl_name}" \
        | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[^0-9]*$/\1/p')
    if [ -z "${_cpl_v}" ]; then
        printf 'unsupported payload name: %s carries no version this chain can read (want payload-<version>.tar)\n' \
            "${_cpl_name}"
        return 1
    fi
    case "${_cpl_v}" in
        0.*)
            if [ "$(case_to_platform "${_cpl_c}")" != "${_cpl_v}" ]; then
                printf 'unsupported payload line: %s is platform %s, but %s installs %s; the field a reader trusts would name the wrong release\n' \
                    "${_cpl_name}" "${_cpl_v}" "${_cpl_c}" "$(case_to_platform "${_cpl_c}")"
                return 1
            fi
            printf 'supported platform payload: %s\n' "${_cpl_v}"
            ;;
        *)
            # A base payload is never this chain's payload, however plausible its version
            # line: every hop here keeps the base and installs the platform on top of it.
            printf 'unsupported payload line: %s is a base payload (%s), but every hop of this chain installs a platform layer on a fixed base of %s\n' \
                "${_cpl_name}" "${_cpl_v}" "${BASE_VERSION}"
            return 1
            ;;
    esac
}

# payload_tools <payload>: the commands the payload's own platform layer carries, one per
# line. Offline, and out of the payload itself: the payload wraps platform.tar, so the layer
# inside it is the file list the install writes. A file that is not a readable tar (a
# placeholder in this driver's test) answers nothing and the caller records "unknown"
# instead of guessing.
payload_tools() {
    _pt_payload=${1:?payload_tools needs a payload path}
    _pt_members=$(tar -xOf "${_pt_payload}" platform.tar 2>/dev/null | tar -tf - 2>/dev/null)
    [ -n "${_pt_members}" ] || return 1
    printf '%s\n' "${_pt_members}" \
        | sed -n 's|^\.\{0,1\}/*usr/sbin/\([a-zA-Z][a-zA-Z0-9_-]*\)$|\1|p' \
        | LC_ALL=C sort -u
}

# --------------------------------------------------------------------------- #
# Red lines
#
# Restated from matrix-round2 rather than shared: that file is a driver, not a library, and
# the two red lines are about this machine, not about a chain. The running slot must be the
# committed one (an install writes the other slot), and boot= and esp= are facts a machine
# cannot claim without evidence.
# --------------------------------------------------------------------------- #

_red_line() { # <case> <reason>
    printf 'ABORT red-line [%s]: %s\n' "${1:-?}" "${2:-unspecified}" >&2
    printf 'ABORT: the machine has no committed healthy slot to fall back to; nothing else is touched\n' >&2
    ev "ABORT red-line: ${2:-unspecified}"
    exit 3
}

require_healthy() {
    _rh_case=${1:-?}
    _rh_line=$(dev_status) || _red_line "${_rh_case}" "ab-slot status is unreadable"
    _rh_boot=$(status_field "${_rh_line}" boot) || _rh_boot=unknown
    _rh_esp=$(status_field "${_rh_line}" esp) || _rh_esp=unknown
    _rh_committed=$(status_field "${_rh_line}" committed) || _rh_committed=""
    case "${_rh_committed}" in
        a | b) : ;;
        *) _red_line "${_rh_case}" "no committed slot (committed='${_rh_committed}')" ;;
    esac
    [ "${_rh_boot}" = "ok" ] || _red_line "${_rh_case}" "boot=${_rh_boot}: the running slot is not proven healthy"
    [ "${_rh_esp}" = "ok" ] || _red_line "${_rh_case}" "esp=${_rh_esp}: the ESP was not proven healthy at boot"
    STATUS_LINE=${_rh_line}
    return 0
}

require_safe_target() { # <case> <status-line>
    _rst_case=${1:-?}
    _rst_line=${2:-}
    _rst_slot=$(status_field "${_rst_line}" slot) || _rst_slot=""
    _rst_committed=$(status_field "${_rst_line}" committed) || _rst_committed=""
    _rst_pending=$(status_field "${_rst_line}" pending) || _rst_pending=""
    if [ "${_rst_slot}" != "${_rst_committed}" ]; then
        _red_line "${_rst_case}" "running slot ${_rst_slot:-?} is not the committed slot ${_rst_committed:-?}: an install would overwrite the only healthy slot"
    fi
    if [ "${_rst_pending}" != "none" ]; then
        printf 'unsafe target [%s]: pending=%s is already queued, resolve it before installing\n' \
            "${_rst_case}" "${_rst_pending:-?}" >&2
        ev "unsafe target: pending=${_rst_pending:-?}"
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
# Assertions this chain adds to lib.sh
#
# lib.sh owns STABLE and IDENTITY (what a switch must not and must move) and STABLE is used
# here as it is. The group ac-10 needs and lib.sh does not is PLATFORM: the one status field
# a *platform-only* hop must move. It is kept in this file on purpose - a second group in
# lib.sh would change what matrix-round2 judges, and that file is not this unit's to change.
# --------------------------------------------------------------------------- #

PLATFORM_STATUS_FIELDS="generation"

# assert_fail <case> <message>: one FAIL line and a status a caller can branch on.
# _dev_assert_fail's own exit status is the status of the evidence append, which is 0 on a
# healthy log, so `[ bad ] || _dev_assert_fail ...` would print FAIL and continue as if
# nothing happened. Every judged check in this file goes through a helper that returns 1.
assert_fail() {
    _dev_assert_fail "${1:-?}" "${2:-assertion failed}"
    return 1
}

# assert_moved <before> <after> <case> <label>: the value must differ.
assert_moved() {
    if [ "${1-}" = "${2-}" ]; then
        assert_fail "${3:-?}" "assert_moved ${4:-value}: did not move (still '${1-}')"
        return 1
    fi
    return 0
}

# block_value <block> <name>: the second column of the line whose first column is <name>.
# A block is `name<TAB>value` lines, which is how the pins are carried around: a line that
# is missing and a line whose value is empty have to stay distinguishable, and a
# space-separated string cannot do that.
block_value() {
    printf '%s\n' "${1:-}" | awk -F'\t' -v n="${2:-}" '$1 == n { print $2; exit }'
}

# world_pin <world> <name>: the whole line that pins one package, empty when absent.
# awk and not an ERE: the pattern is "starts with <name>= or is exactly <name>", and in an
# extended regex the `$` inside that alternation reads as an anchor next to the `=`, which
# silently turns the test into "the line ends with =".
world_pin() {
    printf '%s\n' "${1:-}" | awk -v n="${2:-}" 'index($0, n "=") == 1 || $0 == n { print; exit }'
}

# pins_block <world>: the three pins as a `name<TAB>line` block.
pins_block() {
    _pbk_world=${1:-}
    for _pbk_name in ${PINS}; do
        printf '%s\t%s\n' "${_pbk_name}" "$(world_pin "${_pbk_world}" "${_pbk_name}")"
    done
}

# user_world_snapshot <world> <out>: the lines the *user* owns, written in the snapshot
# format devcfg_diff compares (`<line> ok <line> -`). The three pins are excluded because B
# judges them by name, and a line that moved from one group into the other would otherwise
# be reported twice.
user_world_snapshot() {
    _uws_world=${1:-}
    _uws_out=${2:?user_world_snapshot needs an output path}
    printf '%s\n' "${_uws_world}" \
        | grep -v -E '^(kernel|base-files|libc)(=|$)' \
        | sed '/^$/d' \
        | LC_ALL=C sort \
        | while IFS= read -r _uws_line; do
              printf '%s\tok\t%s\t-\n' "${_uws_line}" "${_uws_line}"
          done >"${_uws_out}"
}

# pc_world_names <world>: the user's own world lines as bare package names. These are the
# samples ac-10 means by "已装样本": what the user asked to be installed, on top of the three
# pins the aligner owns.
pc_world_names() {
    printf '%s\n' "${1:-}" \
        | grep -v -E '^(kernel|base-files|libc)(=|$)' \
        | sed '/^$/d' \
        | sed 's/=.*//' \
        | LC_ALL=C sort -u
}

# package_names <pkg-snapshot>: the name column of an installed-set snapshot.
# The name column of that format is "the package token without its last dash segment"
# (matrix-round2's normalisation: htop-3.5.3-r1 -> htop-3.5.3), so a lookup by package name
# has to accept both an exact name and a name followed by more version segments. That is
# what sample_name_present below does; this function only hands out the column.
package_names() {
    [ -f "${1:?package_names needs a snapshot}" ] || return 1
    cut -f1 "${1}" | sed '/^$/d' | LC_ALL=C sort -u
}

# sample_name_present <names> <sample>: is this package in that name column?
sample_name_present() {
    printf '%s\n' "${1:-}" | awk -v s="${2:?sample_name_present needs a sample}" \
        'index($0, s "-") == 1 || $0 == s { hit = 1; exit } END { exit !hit }'
}

# diff_assert_same <case> <label> <snap-a> <snap-b>: two snapshots, one verdict. Used for
# the three C snapshots (config, world lines, packages), so all three fail in the same shape
# and a reader does not have to learn three.
diff_assert_same() {
    _das_out=$(devcfg_diff "${3-}" "${4-}")
    _das_rc=$?
    case "${_das_rc}" in
        0) return 0 ;;
        1)
            _das_n=$(printf '%s\n' "${_das_out}" | grep -c . | tr -d ' ')
            printf '%s\n' "${_das_out}" | while IFS= read -r _das_line; do
                [ -n "${_das_line}" ] || continue
                ev "${2} drift: ${_das_line}"
            done
            _das_first=$(printf '%s\n' "${_das_out}" | head -n 1)
            assert_fail "${1:-?}" "${2}: ${_das_n} change(s) across the hop, first: ${_das_first}"
            return 1
            ;;
        *)
            assert_fail "${1:-?}" "${2}: the two snapshots could not be compared (devcfg_diff rc=${_das_rc})"
            return 1
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# What the machine says
# --------------------------------------------------------------------------- #

# pc_capture_release: /etc/platform-release as the machine reports it, parsed and hashed.
# The digest is taken over the capture as printed here, not over the file's exact bytes:
# the only question it answers is "did this hop change the file", and both sides of that
# comparison go through this function.
pc_capture_release() {
    _pcr_tmp=""
    PC_PLATFORM=""
    PC_UPSTREAM=""
    PC_STAGE=""
    PC_RELEASE_SHA=""
    PC_RELEASE=$(dev_ssh "cat ${RELEASE_PATH}" 2>/dev/null) || PC_RELEASE=""
    [ -n "${PC_RELEASE}" ] || return 1
    PC_PLATFORM=$(printf '%s\n' "${PC_RELEASE}" | sed -n 's/^PLATFORM_VERSION=//p' | head -n 1)
    PC_UPSTREAM=$(printf '%s\n' "${PC_RELEASE}" | sed -n 's/^UPSTREAM_VERSION=//p' | head -n 1)
    PC_STAGE=$(printf '%s\n' "${PC_RELEASE}" | sed -n 's/^PLATFORM_STAGE=//p' | head -n 1)
    _pcr_tmp=$(devcfg_tmpfile) || return 1
    printf '%s\n' "${PC_RELEASE}" >"${_pcr_tmp}"
    PC_RELEASE_SHA=$(devcfg_sha256 "${_pcr_tmp}") || PC_RELEASE_SHA=""
    rm -f "${_pcr_tmp}"
    return 0
}

# pc_capture_base: DISTRIB_RELEASE and the running kernel, in one round trip.
# /etc/os-release first and /etc/openwrt_release second: both are upstream files that carry
# DISTRIB_RELEASE, the images measured on the reference machine have the second, and reading
# both in one sed means the fallback costs nothing. The value comes back quoted
# (DISTRIB_RELEASE='25.12.2'), which is stripped here so a comparison is about the release.
pc_capture_base() {
    _pcb_out=$(dev_ssh 'printf "distrib=%s\n" "$(sed -n "s/^DISTRIB_RELEASE=//p" /etc/os-release /etc/openwrt_release 2>/dev/null | head -n 1)"; printf "kernel=%s\n" "$(uname -r)"' 2>/dev/null) || _pcb_out=""
    PC_DISTRIB=$(printf '%s\n' "${_pcb_out}" | sed -n 's/^distrib=//p' | head -n 1)
    PC_KERNEL=$(printf '%s\n' "${_pcb_out}" | sed -n 's/^kernel=//p' | head -n 1)
    PC_DISTRIB=$(printf '%s' "${PC_DISTRIB}" | tr -d '"'"'")
}

# pc_capture_tools: which of the three CLIs are there, and what each says it is.
# `--version` is answered before either CLI reads a slot, the lock or the ESP (it is the
# identity of the release the machine was built as), so this probe is safe on a machine
# whose upgrade is broken - and it is the only way to ask the *installed* tool rather than
# the release file what version it belongs to.
pc_capture_tools() {
    # PATH is set here and not relied on: a non-login ssh command inherits whatever PATH
    # dropbear hands it, and /usr/sbin is where these three live. Asking "is it present"
    # with the wrong PATH would report a healthy layer as missing a tool.
    _pct_cmd='PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH; for t in '"${TOOLS}"'; do if command -v "$t" >/dev/null 2>&1; then v=$("$t" --version 2>/dev/null); printf "tool=%s state=present platform=%s upstream=%s stage=%s\n" "$t" "$(printf "%s\n" "$v" | sed -n "s/^PLATFORM_VERSION=//p" | head -n 1)" "$(printf "%s\n" "$v" | sed -n "s/^UPSTREAM_VERSION=//p" | head -n 1)" "$(printf "%s\n" "$v" | sed -n "s/^PLATFORM_STAGE=//p" | head -n 1)"; else printf "tool=%s state=absent\n" "$t"; fi; done'
    PC_TOOLS=$(dev_ssh "${_pct_cmd}" 2>/dev/null) || PC_TOOLS=""
}

# pc_tool_line <tool> / pc_tool_field <tool> <field>: read one tool out of that capture.
pc_tool_line() {
    printf '%s\n' "${PC_TOOLS:-}" | grep -E "^tool=$1 " | head -n 1
}

pc_tool_field() {
    _ptf_line=$(pc_tool_line "${1}") || _ptf_line=""
    [ -n "${_ptf_line}" ] || return 1
    printf '%s\n' "${_ptf_line}" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

# pc_config_paths: every file in /etc/config, as the device lists it. Listed per boundary
# rather than fixed up front: a hop that *adds* a config file has to show up as `added`, and
# a list captured once would hide it.
pc_config_paths() {
    dev_ssh "for f in ${CONFIG_DIR}/*; do [ -f \"\$f\" ] && printf '%s\\n' \"\$f\"; done" 2>/dev/null
}

# pc_capture_config <tag>: /etc/config/* plus the data marker, sha256 per file, through the
# shared snapshotter. A missing file is a state it records (an app that is not installed
# owns no config), not an error, so a non-zero rc of 1 is not a failure here.
pc_capture_config() {
    _pcc_tag=${1:?pc_capture_config needs a tag}
    _pcc_paths=$(pc_config_paths) || _pcc_paths=""
    PC_CFG="${EVIDENCE_DIR}/${_pcc_tag}.cfg.tsv"
    # The list is a space separated set of paths read off the machine; splitting it is the
    # point. Every path comes from a glob on one directory, so none of them carries a space.
    # shellcheck disable=SC2086
    devcfg_snapshot "${PC_CFG}" ${_pcc_paths} "${MARKER_PATH}" >/dev/null 2>&1
    _pcc_rc=$?
    [ "${_pcc_rc}" -le 1 ] || ev "config snapshot ${_pcc_tag}: devcfg_snapshot exited ${_pcc_rc}"
}

# pc_capture_packages <tag>: the installed set, in the snapshot format devcfg_diff compares.
#   <name>  ok  <version>  -
# The last dash splits name from version, the same normalisation matrix-round2 writes, so
# both drivers answer "did the package set move" with the same comparator. A package whose
# own name ends in digits still compares against itself because the split is applied to both
# sides identically.
pc_capture_packages() {
    _pcp_tag=${1:?pc_capture_packages needs a tag}
    PC_PKG="${EVIDENCE_DIR}/${_pcp_tag}.pkg.tsv"
    _pcp_raw=$(devcfg_tmpfile) || return 1
    if ! dev_ssh 'apk list --installed 2>/dev/null' >"${_pcp_raw}" 2>/dev/null; then
        rm -f "${_pcp_raw}"
        return 1
    fi
    if [ ! -s "${_pcp_raw}" ]; then
        rm -f "${_pcp_raw}"
        return 1
    fi
    LC_ALL=C awk 'NF {
        name = $1
        sub(/-[^-]*$/, "", name)
        ver = $1
        sub(/^.*-/, "", ver)
        if (name != "" && ver != "" && ver != $1) printf "%s\tok\t%s\t-\n", name, ver
    }' "${_pcp_raw}" | LC_ALL=C sort -u >"${PC_PKG}"
    rm -f "${_pcp_raw}"
    return 0
}

# pc_capture_world: /etc/apk/world once, then both readings of it: the three pins (B) and
# the lines the user owns (C).
pc_capture_world() {
    _pcw_tag=${1:?pc_capture_world needs a tag}
    PC_WORLD=$(dev_ssh 'cat /etc/apk/world' 2>/dev/null) || PC_WORLD=""
    PC_PINS=$(pins_block "${PC_WORLD}")
    PC_WORLD_SNAP="${EVIDENCE_DIR}/${_pcw_tag}.world.tsv"
    user_world_snapshot "${PC_WORLD}" "${PC_WORLD_SNAP}"
}

# pc_capture <tag>: one boundary - every fact the chain compares, plus the rootfs the
# running slot records (the base, read from the slot's own record rather than from a
# version string this driver might have been told).
pc_capture() {
    _pc_tag=${1:?pc_capture needs a tag}
    pc_capture_release || ev "boundary ${_pc_tag}: ${RELEASE_PATH} answered nothing"
    pc_capture_base
    pc_capture_world "${_pc_tag}"
    pc_capture_tools
    pc_capture_config "${_pc_tag}"
    if ! pc_capture_packages "${_pc_tag}"; then
        ev "boundary ${_pc_tag}: apk list --installed answered nothing"
        : >"${PC_PKG}"
    fi
    PC_ROOTFS=$(dev_running_version) || PC_ROOTFS=""
    ev "boundary ${_pc_tag}: platform=${PC_PLATFORM:-none} upstream=${PC_UPSTREAM:-none} stage=${PC_STAGE:-none} release-sha=$(short_sha "${PC_RELEASE_SHA}") base-release=${PC_DISTRIB:-none} kernel=${PC_KERNEL:-none} rootfs=${PC_ROOTFS:-none} pins='$(pins_one_line)'"
    ev "boundary ${_pc_tag}: config=${PC_CFG} packages=${PC_PKG} world=${PC_WORLD_SNAP}"
}

short_sha() {
    printf '%s' "${1:-}" | cut -c1-12
}

pins_one_line() {
    printf '%s\n' "${PC_PINS:-}" | awk -F'\t' 'NF { printf "%s%s", sep, $2; sep = " " }'
}

# pc_pre_from_pc: this boundary is the next hop's starting point.
pc_pre_from_pc() {
    PRE_PLATFORM=${PC_PLATFORM}
    PRE_ROOTFS=${PC_ROOTFS}
    PRE_RELEASE_SHA=${PC_RELEASE_SHA}
}

# pc_base_from_pc: this boundary is what B and C are measured against.
pc_base_from_pc() {
    BASE_DISTRIB=${PC_DISTRIB}
    BASE_KERNEL=${PC_KERNEL}
    BASE_PINS=${PC_PINS}
    BASE_CFG=${PC_CFG}
    BASE_PKG=${PC_PKG}
    BASE_WORLD_SNAP=${PC_WORLD_SNAP}
    # The samples by name, taken once: what ac-10 means by "the installed samples are still
    # there" is this list, and it must not be re-derived from the post-hop machine.
    BASE_SAMPLES=$(pc_world_names "${PC_WORLD}" | tr '\n' ' ')
}

# --------------------------------------------------------------------------- #
# The three groups
# --------------------------------------------------------------------------- #

# assert_platform_moved <case> <to-platform> <payload>
# A: the platform layer moved, and it moved to what the payload carries. The status field
# itself (generation) is judged by the PLATFORM group in the hop, so it is not repeated here.
assert_platform_moved() {
    _apm_case=${1:?assert_platform_moved needs a case}
    _apm_to=${2:?assert_platform_moved needs the platform it installs}
    _apm_payload=${3-}
    _apm_bad=0

    assert_value "${PC_PLATFORM}" "${_apm_to}" "${_apm_case}" platform-version || _apm_bad=1
    assert_value "${PC_UPSTREAM}" "${BASE_VERSION}" "${_apm_case}" platform-upstream || _apm_bad=1
    assert_moved "${PRE_RELEASE_SHA}" "${PC_RELEASE_SHA}" "${_apm_case}" platform-release-sha || _apm_bad=1

    # The tool layer. A tool that the payload's own layer carries has to be on the machine
    # and has to report the payload's identity; see the header for why 0.0.10..0.0.12 do not
    # carry ab-packages and why that is not a failure.
    _apm_carried=$(payload_tools "${_apm_payload}") && _apm_known=1 || _apm_known=0
    for _apm_tool in ${TOOLS}; do
        _apm_state=$(pc_tool_field "${_apm_tool}" state) || _apm_state=absent
        if [ "${_apm_state}" = "present" ]; then
            assert_value "$(pc_tool_field "${_apm_tool}" platform)" "${_apm_to}" \
                "${_apm_case}" "tool-${_apm_tool}-platform" || _apm_bad=1
            assert_value "$(pc_tool_field "${_apm_tool}" upstream)" "${BASE_VERSION}" \
                "${_apm_case}" "tool-${_apm_tool}-upstream" || _apm_bad=1
            continue
        fi
        case " ${TOOLS_REQUIRED} " in
            *" ${_apm_tool} "*)
                assert_fail "${_apm_case}" "tool ${_apm_tool}: required on every payload of this line, but the machine does not have it"
                _apm_bad=1
                continue
                ;;
        esac
        if [ "${_apm_known}" = "1" ] && printf '%s\n' "${_apm_carried}" | grep -qx "${_apm_tool}"; then
            assert_fail "${_apm_case}" "tool ${_apm_tool}: the payload carries it but the layer did not install it (state=absent)"
            _apm_bad=1
            continue
        fi
        if [ "${_apm_known}" = "1" ]; then
            ev "tool ${_apm_tool}: absent-in-payload (this payload's layer does not carry it, nothing to assert)"
        else
            ev "tool ${_apm_tool}: absent; the payload is not a readable tar, so whether it carries the tool is unknown"
        fi
    done
    return "${_apm_bad}"
}

# assert_base_still <case>: B: the base did not move.
assert_base_still() {
    _abs_case=${1:?assert_base_still needs a case}
    _abs_bad=0
    assert_value "${PC_DISTRIB}" "${BASE_DISTRIB}" "${_abs_case}" base-distrib-release || _abs_bad=1
    assert_value "${PC_KERNEL}" "${BASE_KERNEL}" "${_abs_case}" base-kernel || _abs_bad=1
    # One line per pin, so the failure names the pin that moved and shows the whole line
    # (name and version), which is what a reader needs to tell "the aligner rewrote it" from
    # "the payload carried another base".
    for _abs_pin in ${PINS}; do
        _abs_a=$(block_value "${BASE_PINS}" "${_abs_pin}")
        _abs_b=$(block_value "${PC_PINS}" "${_abs_pin}")
        [ "${_abs_a}" = "${_abs_b}" ] && continue
        assert_fail "${_abs_case}" "base pin ${_abs_pin}: expected='${_abs_a}' got='${_abs_b}'"
        _abs_bad=1
    done
    if [ -z "${BASE_DISTRIB}" ]; then
        assert_fail "${_abs_case}" "base-release: no DISTRIB_RELEASE was readable before the hop, so 'unchanged' would prove nothing"
        _abs_bad=1
    fi
    return "${_abs_bad}"
}

# assert_user_still <case>: C: the user layer did not move.
assert_user_still() {
    _aus_case=${1:?assert_user_still needs a case}
    _aus_bad=0
    diff_assert_same "${_aus_case}" "user-config" "${BASE_CFG}" "${PC_CFG}" || _aus_bad=1
    diff_assert_same "${_aus_case}" "user-world" "${BASE_WORLD_SNAP}" "${PC_WORLD_SNAP}" || _aus_bad=1
    # The installed set is judged, not recorded: a package that vanished or moved version
    # across a platform-only hop is exactly the zero-change claim ac-10 makes.
    diff_assert_same "${_aus_case}" "user-packages" "${BASE_PKG}" "${PC_PKG}" || _aus_bad=1
    # And by name, because "the set is equal" and "the samples the user installed are still
    # there" are the same fact only while both snapshots are non-empty: an apk that answers
    # nothing twice would compare equal and prove nothing. A named miss is also a better
    # failure line than a diff of two long lists.
    if ! _aus_now=$(package_names "${PC_PKG}"); then
        assert_fail "${_aus_case}" "user-samples: the installed package set could not be read after the hop"
        _aus_bad=1
    else
        for _aus_sample in ${BASE_SAMPLES}; do
            sample_name_present "${_aus_now}" "${_aus_sample}" && continue
            assert_fail "${_aus_case}" "user-samples: ${_aus_sample} is no longer installed after a platform-only hop"
            _aus_bad=1
        done
    fi
    return "${_aus_bad}"
}

# --------------------------------------------------------------------------- #
# One hop
# --------------------------------------------------------------------------- #

_check() { "$@" || HOP_FAILED=1; }

# position_run <case> <to-platform>: bring the machine onto the platform the selected
# chain starts from, before the first hop is judged.
#
# This is not a result: the chain's question is the hop that follows. It is walked as a
# full transaction and judged on what a healthy platform move must leave (boot=ok esp=ok
# pending=none, the target committed, the base unchanged, the release file naming the
# target), because a half-done positioning hop would make every later row a lie. The
# payload is named by platform version, not by case, so it also serves --from-version and
# --only, whose first hop starts from another version. It is the same-base platform move
# the chain's own hops make; matrix-round2's position_run is the model.
#
# The refusal. A release whose platform-only guard compares the base alone answers
# payload-already-installed (exit 74) for a payload on the base it already runs - exactly
# this move, because positioning keeps the base. matrix-round2 spends --force on that
# refusal because round 1 measured it; here the same flag is spent for the same reason and
# the evidence says so. A refusal for any other reason is not walked past: it is a FAIL
# naming the reason, because forcing an unexplained refusal would hide the disagreement
# the chain exists to find.
#
# Returns 0 positioned, 1 failed, 2 no payload.
position_run() {
    _pos_case=${1:?position_run needs a case}
    _pos_to=${2:?position_run needs a target platform}
    _pos_local="${PAYLOAD_DIR}/payload-${_pos_to}.tar"
    if [ ! -f "${_pos_local}" ]; then
        ev "positioning: no payload at ${_pos_local}"
        return 2
    fi

    require_healthy "${_pos_case}" || return 1
    _pos_before=${STATUS_LINE}
    AB_STATUS_LINE=${_pos_before}
    require_safe_target "${_pos_case}" "${_pos_before}" || return 1
    _pos_gen=$(status_field "${_pos_before}" generation) || _pos_gen=0
    _pos_slot=$(status_field "${_pos_before}" slot) || _pos_slot=""
    _pos_target=$(other_slot "${_pos_slot}") || return 1
    _pos_running=${PC_PLATFORM:-}

    ev "positioning: ${_pos_running:-unknown} -> ${_pos_to}; slot ${_pos_slot}, target ${_pos_target}, generation ${_pos_gen}"
    _pos_remote="${AB_REMOTE_TMP}/${_pos_local##*/}"
    dev_ssh 'ab-slot gc' >/dev/null 2>&1 || ev "gc reported problems (not a positioning failure)"
    if ! dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_pos_local}" "${_pos_remote}" >/dev/null; then
        ev "positioning: the payload could not be pushed to ${_pos_remote}"
        return 1
    fi
    dev_capture "${AB_EVIDENCE_LOG}" dev_cleanup_slot_mounts >/dev/null
    ev "pre-check: /mnt/slots/* unmounted; --check may remount them, so their absence is not asserted"

    _pos_force=0
    _pos_out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ab_check "${_pos_remote}")
    _pos_rc=$?
    case "${_pos_rc}" in
        0) : ;;
        74)
            case "${_pos_out}" in
                *payload-already-installed*)
                    _pos_force=1
                    ev "positioning: refused with exit 74 payload-already-installed; installing with --force, the flag the refusal names"
                    ;;
                *)
                    ev "positioning: refused with exit 74 for another reason: $(printf '%s\n' "${_pos_out}" | grep -m 1 'refused' || printf 'no refusal line')"
                    return 1
                    ;;
            esac
            ;;
        *)
            ev "positioning: ab-upgrade --check exited ${_pos_rc}: $(printf '%s\n' "${_pos_out}" | tail -n 1)"
            return 1
            ;;
    esac

    if [ "${_pos_force}" = "1" ]; then
        _pos_out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ssh "ab-upgrade --yes --force ${_pos_remote}")
    else
        _pos_out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_install "${_pos_remote}")
    fi
    if [ "$?" -ne 0 ]; then
        ev "positioning: ab-upgrade did not install ${_pos_to}: $(printf '%s\n' "${_pos_out}" | tail -n 1)"
        return 1
    fi

    _pos_armed=$(dev_capture "${AB_EVIDENCE_LOG}" dev_status) || {
        ev "positioning: ab-slot status is unreadable after the install"
        return 1
    }
    AB_STATUS_LINE=${_pos_armed}
    HOP_FAILED=0
    _check assert_field pending "${_pos_target}" "${_pos_case}"
    _check assert_ge "$(status_field "${_pos_armed}" generation || printf 0)" "$((_pos_gen + 1))" "${_pos_case}" generation
    [ "${HOP_FAILED}" -eq 0 ] || return 1

    dev_reboot
    if ! dev_wait_up_after after-install; then
        ev "positioning: no ssh answer within ${AB_WAIT_UP_FIRST}s after the reboot"
        return 1
    fi
    if ! _pos_booted=$(dev_capture "${AB_EVIDENCE_LOG}" dev_wait_settled "${AB_WAIT_SETTLE}"); then
        ev "positioning: no status line within ${AB_WAIT_SETTLE}s after the machine answered ssh"
        return 1
    fi
    AB_STATUS_LINE=${_pos_booted}
    HOP_FAILED=0
    _check assert_field boot ok "${_pos_case}"
    _check assert_field esp ok "${_pos_case}"
    _check assert_field pending none "${_pos_case}"
    _check assert_field committed "${_pos_target}" "${_pos_case}"
    _check assert_field packages aligned "${_pos_case}"
    _pos_rootfs=$(dev_running_version) || _pos_rootfs=""
    _check assert_value "${_pos_rootfs}" "${BASE_VERSION}" "${_pos_case}" positioned-base
    if pc_capture_release; then
        _check assert_value "${PC_PLATFORM}" "${_pos_to}" "${_pos_case}" positioned-platform
    else
        _check assert_fail "${_pos_case}" "${RELEASE_PATH} answered nothing after the positioning hop"
    fi
    [ "${HOP_FAILED}" -eq 0 ] || return 1
    # `_pos_force` is always set (0 or 1), so it cannot be tested with `${_pos_force:+...}`:
    # that form expands for "0" as well and would claim --force on every positioning move.
    _pos_force_note=""
    [ "${_pos_force}" = "1" ] && _pos_force_note=" (force=used)"
    ev "positioned: ${_pos_running:-unknown} -> ${_pos_to}, committed ${_pos_target}, generation ${_pos_gen}->$(status_field "${_pos_booted}" generation || printf '?')${_pos_force_note}"
    return 0
}

# hop_run <case>: 0 PASS, 1 FAIL, 2 GAP (payload missing, or refused with a readable reason).
hop_run() {
    _case=${1:?hop_run needs a case}
    CASE_NOTE=""
    AB_EVIDENCE_LOG="${EVIDENCE_DIR}/${_case}.log"
    AB_MATRIX_CMD="$0 --only ${_case}"
    export AB_EVIDENCE_LOG AB_MATRIX_CMD
    : >"${AB_EVIDENCE_LOG}"

    _local=$(hop_payload_path "${_case}") || {
        CASE_NOTE="no payload name for ${_case}"
        return 2
    }
    if [ ! -f "${_local}" ]; then
        CASE_NOTE="no payload at ${_local} (build it, or pass --payload ${_case}=<path>)"
        ev "${CASE_NOTE}"
        return 2
    fi

    _from=$(case_from_platform "${_case}") || return 1
    _to=$(case_to_platform "${_case}") || return 1

    require_healthy "${_case}" || return 1
    _before=${STATUS_LINE}
    AB_STATUS_LINE=${_before}
    require_safe_target "${_case}" "${_before}" || return 1
    _gen=$(status_field "${_before}" generation) || _gen=0
    _slot=$(status_field "${_before}" slot) || _slot=""
    _target=$(other_slot "${_slot}") || return 1

    # The hop starts where the previous boundary left the machine: the platform the running
    # slot names and the base it runs. A machine that is somewhere else is a chain that was
    # started in the wrong place, which is a FAIL with the flag that fixes it - not a GAP,
    # because nothing about the payload is in doubt.
    HOP_FAILED=0
    _check assert_value "${PRE_PLATFORM}" "${_from}" "${_case}" platform-position
    _check assert_value "${PRE_ROOTFS:-}" "${BASE_VERSION}" "${_case}" base-position
    if [ "${HOP_FAILED}" -ne 0 ]; then
        CASE_NOTE="chain broken: the machine runs platform ${PRE_PLATFORM:-unknown} on ${PRE_ROOTFS:-unknown}, this hop starts from ${_from} on ${BASE_VERSION}; rerun with --from-version ${PRE_PLATFORM:-<version>}"
        ev "${CASE_NOTE}"
        return 1
    fi
    ev "hop ${_case}: platform ${_from} -> ${_to} on base ${BASE_VERSION}; slot ${_slot}, target ${_target}, generation ${_gen}"

    _remote="${AB_REMOTE_TMP}/${_local##*/}"
    dev_ssh 'ab-slot gc' >/dev/null 2>&1 || ev "gc reported problems (not a hop failure)"
    if ! dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_local}" "${_remote}" >/dev/null; then
        CASE_NOTE="the payload could not be pushed to ${_remote}"
        ev "${CASE_NOTE}"
        return 1
    fi
    # ab-upgrade --check is not read-only: it publishes ab/conflicts.log on the ESP and may
    # leave p2/p3 mounted under /mnt/slots/<slot>. The hop therefore starts from a clean
    # mount state and says so; nothing later asserts those mounts are absent, because they
    # legitimately reappear.
    dev_capture "${AB_EVIDENCE_LOG}" dev_cleanup_slot_mounts >/dev/null
    ev "pre-check: /mnt/slots/* unmounted; --check may remount them, so their absence is not asserted"

    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ab_check "${_remote}")
    _rc=$?
    if [ "${_rc}" -ne 0 ]; then
        # A readable reason means the payload and this machine disagree - a state of the
        # world this chain records and names, never an install to force past.
        _reason=$(printf '%s\n' "${_out}" | sed -n 's/.*reason=\([a-zA-Z0-9_-]*\).*/\1/p' | head -n 1)
        if [ -n "${_reason}" ]; then
            _hint=$(printf '%s\n' "${_out}" | grep -m 1 -E '^(Next:|  Next:)' || printf '')
            CASE_NOTE="this hop could not be walked: ab-upgrade --check exited ${_rc} with reason=${_reason}"
            case "${_reason}" in
                payload-already-installed)
                    CASE_NOTE="${CASE_NOTE}; the running release guards on the base alone, so this payload is refused on its own base. Pre-position the machine on 0.0.12 or later (whose guard compares the platform too), then rerun with --from-version 0.0.12; --force is deliberately not spent here"
                    ;;
                *)
                    [ -n "${_hint}" ] && CASE_NOTE="${CASE_NOTE}; ${_hint#*Next: }"
                    ;;
            esac
            ev "${CASE_NOTE}"
            return 2
        fi
        CASE_NOTE="ab-upgrade --check exited ${_rc} without a reason= line: $(printf '%s\n' "${_out}" | tail -n 1)"
        ev "${CASE_NOTE}"
        return 1
    fi

    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_install "${_remote}")
    if [ "$?" -ne 0 ]; then
        CASE_NOTE="ab-upgrade did not install ${_to}: $(printf '%s\n' "${_out}" | tail -n 1)"
        ev "${CASE_NOTE}"
        return 1
    fi

    _armed=$(dev_capture "${AB_EVIDENCE_LOG}" dev_status) || {
        CASE_NOTE="ab-slot status is unreadable after the install"
        ev "${CASE_NOTE}"
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
    AB_STATUS_LINE=${_booted}

    # One boundary, then the three groups against it. The capture comes first so a red
    # group is judged on what the machine says now, not on what a previous line said.
    pc_capture "post-${_case}"

    HOP_FAILED=0
    # The groups lib.sh defines: what must not move across a switch, and what must.
    _check ab_status_switch_check "${_before}" "${_booted}" "${_case}"
    _check assert_field boot ok "${_case}"
    _check assert_field esp ok "${_case}"
    _check assert_field pending none "${_case}"
    _check assert_field committed "${_target}" "${_case}"
    _check assert_field packages aligned "${_case}"
    _check assert_value "${PC_ROOTFS}" "${BASE_VERSION}" "${_case}" base-rootfs
    _check assert_match "$(status_field "${_booted}" upper || printf '')" \
        "^@overlay-$(dev_version_re "${BASE_VERSION}")(-r[0-9]+)?\$" "${_case}" upper
    # The one field PLATFORM adds to lib.sh's two groups.
    for _pfield in ${PLATFORM_STATUS_FIELDS}; do
        _check assert_ge "$(status_field "${_booted}" "${_pfield}" || printf 0)" \
            "$((_gen + 1))" "${_case}" "platform-${_pfield}"
    done

    _check assert_platform_moved "${_case}" "${_to}" "${_local}"
    _check assert_base_still "${_case}"
    _check assert_user_still "${_case}"
    _sha_before=${PRE_RELEASE_SHA}
    pc_pre_from_pc

    _gen_now=$(status_field "${_booted}" generation) || _gen_now="?"
    if [ "${HOP_FAILED}" -eq 0 ]; then
        CASE_NOTE="hop ok: platform ${_from}->${_to}, base ${BASE_VERSION} unchanged, generation ${_gen}->${_gen_now}, release-sha $(short_sha "${_sha_before}")->$(short_sha "${PC_RELEASE_SHA}"), tools=$(tools_summary), samples=$(sample_count) present, config-drift=none pkg-drift=none world-drift=none"
        ev "${CASE_NOTE}"
        return 0
    fi
    # The evidence lines are timestamped, so the case name is matched anywhere in the line.
    _first_fail=$(grep -m 1 "FAIL ${_case} " "${AB_EVIDENCE_LOG}" 2>/dev/null) || _first_fail=""
    CASE_NOTE="assertions failed on this hop: ${_first_fail#FAIL ${_case} }; the chain stops here (config/packages/world: see ${AB_EVIDENCE_LOG})"
    ev "${CASE_NOTE}"
    return 1
}

# sample_count: how many of the user's samples were required, for the PASS note. The number
# is the baseline list, so a reader can see the claim was not vacuous.
sample_count() {
    printf '%s' "${BASE_SAMPLES}" | wc -w | tr -d ' '
}

# tools_summary: which CLI answered with the payload's own version, for the PASS note.
# A tool that is not there is named as such rather than silently left out.
tools_summary() {
    _ts_out=""
    for _ts_tool in ${TOOLS}; do
        _ts_state=$(pc_tool_field "${_ts_tool}" state) || _ts_state=absent
        if [ "${_ts_state}" = "present" ]; then
            _ts_out="${_ts_out} ${_ts_tool}=$(pc_tool_field "${_ts_tool}" platform)"
        else
            _ts_out="${_ts_out} ${_ts_tool}=absent"
        fi
    done
    printf '%s' "${_ts_out# }"
}

# --------------------------------------------------------------------------- #
# Selection and the plan
# --------------------------------------------------------------------------- #

select_cases() {
    if [ -n "${ONLY_CASE}" ]; then
        case_step "${ONLY_CASE}" >/dev/null || {
            printf 'platform-chain: unknown case: %s (want one of: %s)\n' "${ONLY_CASE}" "${CHAIN}" >&2
            return 2
        }
        printf '%s\n' "${ONLY_CASE}"
        return 0
    fi
    if [ -z "${FROM_VERSION}" ]; then
        printf '%s\n' "${CHAIN}"
        return 0
    fi
    _sc_last=$(printf '%s\n' ${CHAIN} | tail -n 1)
    # --from-version names the platform the machine already runs. The version the chain ends
    # on is a valid start too, and it means "there is nothing left to walk" - not an error:
    # a resumed run whose last hop passed must be able to say so and exit 0.
    if [ "${FROM_VERSION}" = "$(case_to_platform "${_sc_last}")" ]; then
        return 0
    fi
    _sc_started=0
    _sc_out=""
    for _sc_c in ${CHAIN}; do
        if [ "${_sc_started}" = "0" ]; then
            if [ "$(case_from_platform "${_sc_c}")" = "${FROM_VERSION}" ]; then
                _sc_started=1
            else
                continue
            fi
        fi
        _sc_out="${_sc_out} ${_sc_c}"
    done
    if [ "${_sc_started}" = "0" ]; then
        printf 'platform-chain: --from-version %s is not a platform this chain leaves (want one of: %s)\n' \
            "${FROM_VERSION}" "$(chain_versions)" >&2
        return 2
    fi
    printf '%s\n' "${_sc_out# }"
}

# plan_case <case>: what the hop will do, printed and not done.
plan_case() {
    _pc_case=${1:?plan_case needs a case}
    printf '# %s %s\n' "${_pc_case}" "$(hop_expect "${_pc_case}")"
    _pc_local=$(hop_payload_path "${_pc_case}") || return 1
    if [ ! -f "${_pc_local}" ]; then
        printf '# warning: no payload at %s; the run would record GAP\n' "${_pc_local}"
    fi
    _pc_from=$(case_from_platform "${_pc_case}")
    _pc_to=$(case_to_platform "${_pc_case}")
    printf '%s status (red line: a committed slot, boot=ok, esp=ok, pending=none; platform-position=%s)\n' \
        "${_pc_case}" "${_pc_from}"
    printf '%s gc\n' "${_pc_case}"
    printf '%s push %s -> %s/%s\n' "${_pc_case}" "${_pc_local}" "${AB_REMOTE_TMP}" "${_pc_local##*/}"
    printf '%s check %s/%s expect=exit-0; exit-74 with a reason= line is a GAP naming the reason, never a forced install\n' \
        "${_pc_case}" "${AB_REMOTE_TMP}" "${_pc_local##*/}"
    printf '%s install %s/%s\n' "${_pc_case}" "${AB_REMOTE_TMP}" "${_pc_local##*/}"
    printf '%s reboot, then wait_up %ss, then settle until boot=ok pending=none\n' \
        "${_pc_case}" "${AB_WAIT_UP_FIRST}"
    printf '%s assert boot=ok esp=ok pending=none committed=<the slot that is not running> packages=aligned base-rootfs=%s upper=@overlay-%s(-rN)?\n' \
        "${_pc_case}" "${BASE_VERSION}" "${BASE_VERSION}"
    printf '%s A platform must move: %s>=+1, %s PLATFORM_VERSION=%s UPSTREAM_VERSION=%s, its sha256 changes, and %s --version print the same %s\n' \
        "${_pc_case}" "${PLATFORM_STATUS_FIELDS}" "${RELEASE_PATH}" "${_pc_to}" "${BASE_VERSION}" \
        "${TOOLS}" "${_pc_to}"
    printf '%s B base must not move: DISTRIB_RELEASE, uname -r and the /etc/apk/world pins (%s) equal the values captured before the first hop\n' \
        "${_pc_case}" "${PINS}"
    printf '%s C user must not move: every %s/* file and %s sha256, the world lines the user owns, the installed package set and every sample named in it\n' \
        "${_pc_case}" "${CONFIG_DIR}" "${MARKER_PATH}"
    printf '%s assert the stable fields did not move: %s\n' "${_pc_case}" "${AB_STATUS_FIELDS_STABLE}"
    printf '%s record\n' "${_pc_case}"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

SELECTED=$(select_cases) || exit 2

if [ "${RESUME}" = "1" ]; then
    # A chain is only resumable at a point it actually reached, so a PASS row is skipped
    # only while every hop before it is PASS too: skipping a hole would walk a later hop on
    # a machine that never made the earlier one, and the platform-position assertion would
    # then report a machine that is fine as red.
    _kept=""
    _skip=1
    for _case in ${SELECTED}; do
        if [ "${_skip}" = "1" ] && record_passed "${_case}"; then
            printf 'resume: %s already has a PASS row in %s, skipped\n' "${_case}" "${AB_RESULTS}"
            continue
        fi
        _skip=0
        _kept="${_kept} ${_case}"
    done
    SELECTED=${_kept# }
fi

if [ -z "${SELECTED}" ]; then
    printf 'platform-chain: nothing to walk (--resume skipped every selected hop, or the chain already ends at %s)\n' \
        "$(chain_versions | awk '{ print $NF }')"
    exit 0
fi

if [ "${DRY_RUN}" = "1" ]; then
    # The plan cannot know the running platform without an ssh call, so the positioning
    # step is printed as the conditional move it is: the operator standing in front of the
    # machine has to see that the chain may move it before it walks any hop.
    _plan_start=$(case_from_platform "${SELECTED%% *}") || exit 2
    printf '# position start: if the machine is not on platform %s, install %s/payload-%s.tar once and record positioned=<from>->%s in the first row; a machine already there is not touched, and a missing payload there is a GAP naming %s/payload-%s.tar\n' \
        "${_plan_start}" "${PAYLOAD_DIR}" "${_plan_start}" "${_plan_start}" "${PAYLOAD_DIR}" "${_plan_start}"
    for _case in ${SELECTED}; do
        plan_case "${_case}" || exit 2
    done
    exit 0
fi

# Every hop writes its evidence before it decides anything, so the directory is made once.
mkdir -p "${EVIDENCE_DIR}" || {
    printf 'platform-chain: cannot create %s\n' "${EVIDENCE_DIR}" >&2
    exit 2
}

# The payloads are judged before the machine is touched: a missing file, a base payload on a
# platform hop or a payload named for another platform release is a state of the *run*, and
# discovering it after a boot would look like a product defect and would have cost the
# machine a hop it did not need.
for _case in ${SELECTED}; do
    _p=$(hop_payload_path "${_case}") || {
        record "${_case}" FAIL - "no payload name for ${_case}"
        printf '   %s: no payload name\n' "${_case}"
        exit 1
    }
    if [ ! -f "${_p}" ]; then
        _note="no payload at ${_p} (build it, or pass --payload ${_case}=<path>)"
        record "${_case}" GAP - "${_note}"
        printf '== %s (refused before any machine was touched)\n' "${_case}"
        printf '   %s: %s\n' "${_case}" "${_note}"
        exit 4
    fi
    if ! _msg=$(check_payload_line "${_case}" "${_p}" 2>&1); then
        record "${_case}" FAIL - "${_msg}"
        printf '== %s (refused before any machine was touched)\n' "${_case}"
        printf '   %s: %s\n' "${_case}" "${_msg}"
        exit 1
    fi
done

AB_EVIDENCE_LOG="${EVIDENCE_DIR}/00-baseline.log"
AB_MATRIX_CMD="$0"
export AB_EVIDENCE_LOG AB_MATRIX_CMD
: >"${AB_EVIDENCE_LOG}"

# Baseline: the chain may only start from a machine that can fall back, and this is what B
# and C are measured against. The dir the baseline needs is made before the first ssh, so a
# red line does not leave a half written snapshot behind.
mkdir -p "${EVIDENCE_DIR}" 2>/dev/null || true
require_healthy "${SELECTED%% *}"
# lib.sh's assertions read the captured line out of AB_STATUS_LINE instead of paying for a
# second `ab-slot status`, so the baseline line is published there and printed from there:
# one value, and the evidence shows exactly what the assertions will judge against.
AB_STATUS_LINE=${STATUS_LINE}

# The chain starts on the platform the selected chain declares, and the full-test phase
# order does not guarantee that the machine is there: matrix, rise and scenarios run before
# this stage and leave it on whatever their last hop landed on. Read the running platform
# from the machine (this is the one fact a run cannot know offline) and get onto the chain's
# line before the baseline is captured, so B and C are measured against the state the chain
# actually starts in. The move is recorded in the first row and in the evidence; a payload
# that is not there is the named GAP, and a positioning hop that does not land is a FAIL -
# walking the chain from the wrong line is the one thing this must never do quietly.
_chain_start=$(case_from_platform "${SELECTED%% *}") || {
    printf 'platform-chain: cannot read the starting platform of %s\n' "${SELECTED%% *}" >&2
    exit 2
}
pc_capture_release || ev "baseline: ${RELEASE_PATH} answered nothing"
_chain_running=${PC_PLATFORM:-}
if [ "${_chain_running}" != "${_chain_start}" ]; then
    _position_payload="${PAYLOAD_DIR}/payload-${_chain_start}.tar"
    printf 'platform-chain: positioning: the machine runs platform %s, the chain starts on %s (%s)\n' \
        "${_chain_running:-unknown}" "${_chain_start}" "${_position_payload}"
    position_run "${SELECTED%% *}" "${_chain_start}"
    case "$?" in
        0)
            POSITIONED="${_chain_running:-unknown}->${_chain_start}"
            if [ "${_pos_force:-0}" = "1" ]; then
                POSITIONED="${POSITIONED} force=used"
            fi
            # The positioning hop was judged healthy by position_run; re-read the status once
            # so the baseline line is the post-move machine, not the one it replaced.
            require_healthy "${SELECTED%% *}"
            AB_STATUS_LINE=${STATUS_LINE}
            ;;
        2)
            CASE_NOTE="no positioning payload at ${_position_payload}: the machine runs platform ${_chain_running:-unknown} and this chain starts on ${_chain_start}; pre-position the machine by hand or put the payload in ${PAYLOAD_DIR}"
            record "${SELECTED%% *}" GAP - "${CASE_NOTE}"
            printf '== %s (positioning)\n' "${SELECTED%% *}"
            printf '   %s: %s\n' "${SELECTED%% *}" "${CASE_NOTE}"
            exit 4
            ;;
        *)
            CASE_NOTE="positioning to platform ${_chain_start} failed; the chain did not start (the machine ran platform ${_chain_running:-unknown}). The evidence names the step that failed; $0 --from-version ${_chain_running:-<version>} can start the chain where the machine really is once that platform is on its line"
            record "${SELECTED%% *}" FAIL "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            printf '== %s (positioning)\n' "${SELECTED%% *}"
            printf '   %s: %s\n' "${SELECTED%% *}" "${CASE_NOTE}"
            exit 1
            ;;
    esac
fi
ev "baseline: ${AB_STATUS_LINE}"
pc_capture base
pc_pre_from_pc
pc_base_from_pc
if [ -z "${BASE_CFG}" ] || [ -z "${BASE_PKG}" ]; then
    printf 'platform-chain: the baseline could not be captured (%s, %s)\n' "${BASE_CFG:-none}" "${BASE_PKG:-none}" >&2
    exit 1
fi

_passed=0
_failed=0
_gapped=0

for _case in ${SELECTED}; do
    printf '== %s %s\n' "${_case}" \
        "kind=platform platform=$(hop_expect_value "${_case}" platform) base=$(hop_expect_value "${_case}" base)"
    hop_run "${_case}"
    _rc=$?
    # The chain start's positioning move is a fact about this run, not about the hop, so it
    # rides on the first row - the only row that can carry it without pretending a later hop
    # moved the machine - and is cleared after it is recorded. Silence here is the one thing
    # the run may not do: a reader of the rows has to see that the machine was moved first.
    if [ -n "${POSITIONED}" ]; then
        CASE_NOTE="${CASE_NOTE}; positioned=${POSITIONED}"
        POSITIONED=""
    fi
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

printf '\nplatform-chain: passed=%s failed=%s gap=%s results=%s\n' \
    "${_passed}" "${_failed}" "${_gapped}" "${AB_RESULTS}"
[ "${_failed}" -eq 0 ] || exit 1
[ "${_gapped}" -eq 0 ] || exit 4
exit 0
