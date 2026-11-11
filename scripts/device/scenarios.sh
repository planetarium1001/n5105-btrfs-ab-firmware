#!/bin/sh
# Real-user scenarios S1-S7: does what a person installed, wrote and configured
# survive a version jump, is the software still usable afterwards, did the tools that
# boot the machine travel with the update, and does the package source follow the version?
#
# The matrix (matrix.sh, M1-M7) answers "did this jump keep a bootable machine": slot
# fields, boot breadcrumbs, the layer invariant. This driver answers the question the
# user actually asks: I installed packages, wrote files, changed the hostname and a
# firewall rule -- after an upgrade and after a downgrade, is my data there, does my
# software still run, and do the kernel modules still match the kernel?
#
# One case is one question and one verdict:
#
#   S1  preinstall   install a batch of packages (LuCI apps first, one kmod), snapshot
#                    what apk has. A package that cannot be installed is recorded as
#                    unavailable, not as a failure; zero packages AND zero kmods is a GAP.
#   S2  userdata     write files (MiB-sized, a Chinese filename, a tar.gz, two fake
#                    docker image tars, a directory tree) to /data, add a uci config of
#                    our own, change hostname/timezone, add a network section and a
#                    firewall rule -- with a backup first, an SSH liveness check right
#                    after and an automatic rollback when SSH stops answering.
#   S3  up           low -> high (payload-<low>.tar, then payload-<high>.tar) and the
#                    full post-jump judgement: data hashes, config, software, ABI, mounts.
#   S4  down         high -> low, same judgement. The worst direction for /etc/config.
#   S5  abi          the ABI/kmod ledger on the kernel that is running now: which installed
#                    kmods were built for a kernel this machine no longer runs, i.e. what
#                    has to be reinstalled after the change. Findings, never FAIL.
#   S6  boottools    the boot chain versus the payload: the kernel and the initramfs on the
#                    ESP and the tool in the platform layer (btrfs) are byte-identical to
#                    the members of payload-<version>.tar. Read-only, no install, no reboot.
#   S7  releasefeeds each version installed from its own release's feeds, then a jump, then
#                    a version and ABI snapshot diff -- and the feed list's own verdict.
#
#   scripts/device/scenarios.sh                       # S1..S7
#   scripts/device/scenarios.sh --case S3 --case S4    # the two jumps
#   scripts/device/scenarios.sh --case S6              # the boot toolchain alone
#   scripts/device/scenarios.sh --case S7              # the package source versus the version
#   scripts/device/scenarios.sh --resume               # skip cases that already PASS
#   scripts/device/scenarios.sh --dry-run              # print steps and verdicts, touch nothing
#
# Exit status: 0 every selected case PASS, 1 a case FAIL, 2 bad usage, 3 the red line
# stopped the run, 4 a case could not run because a prerequisite or payload is missing (GAP).
#
# Three verdicts, as in matrix.sh, plus one note prefix:
#   PASS  every mechanical judgement held
#   FAIL  data lost, config lost, software gone, mount or service broken, or SSH lost
#   GAP   could not be judged (no payload, no apk, no /data, no S1/S2 state on the machine)
#   note  scenarios also produce findings that are neither: a kmod built for the previous
#         kernel is normal apk behaviour, but the user has to be told. Those go in the
#         fourth column prefixed FINDING: and never turn a PASS into a FAIL.
#
# Red lines, enforced in code:
#   * no committed healthy slot -> the run stops with exit 3 before anything is written
#     (require_healthy_committed, the same rule matrix.sh enforces);
#   * /etc/config/network and /etc/config/firewall are backed up to /data before they are
#     touched, and the backup is a precondition: if it cannot be written, nothing is
#     changed at all;
#   * the network reload is followed immediately by an SSH liveness check; on silence the
#     host rolls back, and the machine has its own watchdog (nohup, scheduled before the
#     reload) that restores the backup unless the host confirms within the grace period;
#   * an install is only ever aimed at the slot the machine is not running
#     (require_safe_target).
#
# Why S6 compares bytes instead of trusting the installer: ab-upgrade is the only writer of
# vmlinuz-<slot>, initrd-<slot> and of the slot's @platform, and platform_copy_rootfs writes
# all three from one payload. A digest that matches that payload therefore proves the boot
# toolchain is the payload's without trusting ab-upgrade's log, its state file or the version
# strings on the machine -- and those three are exactly what a half-finished or mismatched
# install gets wrong. "The slot says 25.12.2" and "the bytes on the ESP are 25.12.2's" are two
# independent statements; S6 is the one place that compares them.
#
# Why a downgrade legitimately leaves tools newer than the rootfs: the boot tools are the
# *payload's*, not the running rootfs's -- the initramfs on the ESP is self-contained and the
# platform layer moves with the slot. A machine built by a newer release can therefore run an
# older rootfs while its /etc/platform-release still says the newer version. That is recorded
# as a FINDING: the user is told which version the tools come from, and nothing is red,
# because nothing is mis-assembled.
#
# Why S7 installs from the release's own feeds instead of from "the newest packages in the
# repository": a matrix run that installs from whatever the machine's sources serve today
# answers "does the current feed set work" and says nothing about what a user got on the day
# they installed release v, or about what the same package looks like after the jump. The
# feed list a release ships is that release's own statement about where its packages live,
# so S7 takes it from the release (it is inside payload-<version>.tar's rootfs.tar.gz and is
# read, never rebuilt -- the kmods directory in it is <kernel>-1-<hash>, a build hash no
# version string can predict) and compares two snapshots taken on either side of the jump.
#
# Why the user-space half of that comparison is expected to show nothing: the three releases
# publish byte-identical indexes for packages/x86_64/packages (sha256 e06121acb3131ece... for
# 25.12.0, 25.12.1 and 25.12.2; htop is 3.5.3-r1 in all three, measured). So "the user-space
# versions a user had on release day" is not a dimension that differs between these releases,
# and S7 keeps that conclusion measured rather than assumed: the diff table names the packages
# that moved, and the user-space ones do not appear in it.
#
# Why the kernel-bound half is the ABI surface: targets/x86/64/packages (the target's own
# libc and kernel packages) and targets/x86/64/kmods/<kernel>-1-<hash> are built per release
# and per kernel, and the three indexes differ (c80d7bcc... for 25.12.0, 9d3953a4... for
# 25.12.1, 0c614677... for 25.12.2; the kmods directories are 6.12.87-1-bd81971a...,
# 6.12.94-1-..., 6.12.103-1-0413601b...). A kmod records the kernel it was built for as a
# package dependency, so `apk info -R` on the kmod is where "built for a kernel this machine
# no longer runs" is visible -- the module file itself is often not even present (the kmods
# this project installs carry configuration stubs only).
#
# Why the feed list has to follow the version, and why that is a FINDING: ab-upgrade treats
# /etc/apk/repositories.d/distfeeds.list as user configuration and keeps it across a jump
# (measured: after a downgrade to 25.12.0 the list still named 6.12.103's kmods index), so
# every install afterwards answers from an index built for a kernel the machine does not run.
# Nothing is broken by that -- the machine boots, the data is there, the old packages still
# work -- so it is recorded as FINDING: the package source did not follow the version, and
# the user is told which index they are on. Turning it red would report a design choice as a
# defect; staying silent would leave the user on the wrong shelf without being told.
#
# Why S7 does not simply declare a red line on the aligned install: the point of reloading
# the running version's feeds and installing from them is to separate two causes. A package
# that cannot be installed from its own version's feed is a package problem; a machine that
# cannot install anything from that feed is a feed problem. S7 therefore tries the kmod its
# own batch installed first (its version genuinely differs per release) and a package that is
# not installed at all second, and only a run where neither install changed anything is red.
# The kmod is allowed to fail on its own: apk's world file keeps pinning the old kernel, and
# `apk add --force-overwrite`, `apk add <pkg>=<version>` and `--force-reinstall` were all
# measured either to conflict (rc=99) or to do nothing silently on this line of releases.
#
# Why a second driver instead of extending matrix.sh: matrix.sh is an executable, not a
# library -- sourcing it would run its main flow. lib.sh owns the primitives (dev_ssh,
# dev_push, dev_install, dev_wait_up, assert_*, record) and both drivers use them; the
# hop skeleton below is the same sequence matrix.sh walks, minus the slot-state cases
# that are not this file's question.
#
# The remote side is one pushed helper (/tmp/ab-scen-helper.sh, rendered from the heredoc
# in scen_helper_render): the guest has no sftp-server, so every capability is a
# subcommand of a plain POSIX shell script that runs with the shell already there.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT

# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

CASES_ALL="S1 S2 S3 S4 S5 S6 S7"

PAYLOAD_DIR=${AB_PAYLOAD_DIR:-payloads}
RESULTS=${AB_RESULTS:-results.tsv}
EVIDENCE_DIR=${AB_EVIDENCE_DIR:-}
WANT_CASES=""
RESUME=0
DRY_RUN=0
CASE_NOTE=""
CASE_FINDINGS=""
CASE_FAILED=0
STATUS_LINE=""
SCEN_CMD=""
RDATA=""
RENDER_HELPER=""

# --------------------------------------------------------------------------- #
# What the scenarios plant, and where
# --------------------------------------------------------------------------- #

# Everything the user wrote lives on the shared partition: /data is the one mount that
# survives a slot change (device-facts.md §5), so it is also where the pre-jump snapshot
# of the world is kept for the cases that run later.
SCEN_DATA_DIR=${AB_SCEN_DATA_DIR:-/data/scen}
SCEN_EVIDENCE=${SCEN_DATA_DIR}/evidence
SCEN_BACKUP=${AB_SCEN_BACKUP:-${SCEN_DATA_DIR}/backup}
SCEN_SEED_DIR=${SCEN_DATA_DIR}/data
SCEN_SEED_TAR=${AB_REMOTE_TMP}/ab-scen-seed.tar
# The helper is pushed to the data partition, not to /tmp: every scenario that jumps a
# version reboots the machine at least once, and a tmpfs helper disappears with the
# reboot. A helper that is gone is not "the data is gone" - see scen() below.
SCEN_HELPER=${AB_SCEN_HELPER:-/data/scen/bin/ab-scen-helper.sh}
# The files the seed tree carries. Kept as a list because the post-jump judgement names
# them one by one when they go missing.
SCEN_DOCKER_TARS=${AB_SCEN_DOCKER_TARS:-"docker-image-alpine.tar docker-image-nginx.tar"}
# LuCI apps first (they are what a user installs from the store), then plain packages and
# one kmod, because a kmod is the package whose ABI question this whole driver exists for.
SCEN_PKGS=${AB_SCEN_PKGS:-"luci-app-attendedsysupgrade luci-app-ttyd curl htop kmod-usb-storage"}
SCEN_UCI=${AB_SCEN_UCI:-abscen}
SCEN_LABEL=${AB_SCEN_LABEL:-ab-scenarios}
SCEN_HOSTNAME=${AB_SCEN_HOSTNAME:-ab-scen-host}
SCEN_TIMEZONE=${AB_SCEN_TIMEZONE:-CST-8}
SCEN_ZONENAME=${AB_SCEN_ZONENAME:-Asia/Shanghai}
# Services that get a stop/start cycle. dropbear and network are deliberately absent:
# stopping either one ends the test session instead of measuring it.
SCEN_SERVICES=${AB_SCEN_SERVICES:-uhttpd}
# Packages that can be executed once to prove the binary still runs. A package outside
# this list is judged by apk info -e plus the existence of its own files.
SCEN_PROBES=${AB_SCEN_PROBES:-"curl:--version htop:--version"}
SCEN_LOW=${AB_SCEN_LOW:-25.12.0}
SCEN_HIGH=${AB_SCEN_HIGH:-25.12.2}
# After the network reload: how many consecutive ssh answers, spaced apart, make the
# change safe. One answer is not enough - an interface that has just come up can accept a
# connection before routing settles, and that single lucky answer is exactly the thing
# this check exists to catch.
SCEN_LIVENESS_OK=${AB_SCEN_LIVENESS_OK:-2}
SCEN_LIVENESS_GAP=${AB_SCEN_LIVENESS_GAP:-2}
SCEN_LIVENESS_DEADLINE=${AB_SCEN_LIVENESS_DEADLINE:-20}
# The machine's own revert deadline, counted from the reload. It has to be longer than
# the liveness check, so a slow-but-alive machine is confirmed in time.
SCEN_ROLLBACK_GRACE=${AB_SCEN_ROLLBACK_GRACE:-90}
# S6 reads three things: the two boot files on the ESP, and the tool that lives in the
# platform layer. Neither path is hard-coded past this point -- the helper resolves the
# names on the machine and prints what it found, because an ESP laid out differently has
# to read as "not found here" rather than as a hash mismatch.
SCEN_ESP_DIR=${AB_SCEN_ESP_DIR:-/boot}
SCEN_PLATFORM_TOOL=${AB_SCEN_PLATFORM_TOOL:-btrfs}
# Which payload the boot chain is compared against. Empty means the version the running
# slot reports, which is the one ab-upgrade wrote it from; naming another version lets a
# downgrade run compare the tools a machine was left with against the payload they came
# from.
SCEN_S6_PAYLOAD=${AB_SCEN_S6_PAYLOAD:-}
# S7 reads the feed list a release ships: /etc/apk/repositories.d/distfeeds.list is where
# apk looks for it, and it is the file ab-upgrade classifies as keep-user, which is the fact
# the case exists to measure. Only the location is configurable; the content is never built
# here (see s7_feeds_render).
SCEN_S7_FEEDS=${AB_SCEN_S7_FEEDS:-/etc/apk/repositories.d/distfeeds.list}
# Where the three feed lines are assembled from when a payload carries no readable rootfs
# feed list at all. It is the shape the release's own file has: one line per index *file*.
SCEN_S7_FEED_BASE=${AB_SCEN_S7_FEED_BASE:-https://downloads.immortalwrt.org}
# The packages a machine certainly does not have yet, used to prove that an aligned feed
# serves a real install. The first one absent from the snapshot is picked; a package that is
# already installed proves nothing, because apk answers rc=0 and changes nothing (measured).
# The list is several names long because an image that already carries nano may not carry jq.
SCEN_S7_FRESH_PKGS=${AB_SCEN_S7_FRESH_PKGS:-"nano less vim jq tmux git"}

usage() {
    cat <<'USAGE'
usage: scenarios.sh [--case S1..S7]... [--payload-dir DIR] [--results FILE]
                    [--evidence-dir DIR] [--resume] [--dry-run]

  --case S1..S7      case to run, repeatable; default is all seven
  --payload-dir DIR  directory holding payload-<version>.tar (default: payloads)
  --results FILE     results.tsv to append to (default: results.tsv)
  --evidence-dir DIR evidence directory (default: <results dir>/evidence)
  --resume           skip a case that already has a PASS row in the results file
  --dry-run          print the steps and the verdict rules, then exit; no ssh call is made
  --render-helper F  write the remote helper to F and exit (used by the unit tests)

  S1 preinstall  S2 userdata  S3 up  S4 down  S5 abi  S6 boottools  S7 releasefeeds
USAGE
}

while [ $# -gt 0 ]; do
    case "${1}" in
        --case)
            WANT_CASES="${WANT_CASES} ${2:?--case needs a value}"
            shift 2
            ;;
        --payload-dir)
            PAYLOAD_DIR=${2:?--payload-dir needs a value}
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
        --render-helper)
            # The remote helper is the one part of this driver a stub ssh cannot execute,
            # so the unit tests render it and check it with `sh -n`. Nothing else uses it.
            RENDER_HELPER=${2:?--render-helper needs a path}
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'scenarios: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "${WANT_CASES}" ] || WANT_CASES=${CASES_ALL}
AB_RESULTS=${RESULTS}
[ -n "${EVIDENCE_DIR}" ] || EVIDENCE_DIR=$(dirname "${AB_RESULTS}")/evidence
AB_EVIDENCE_LOG=""
if [ "${DRY_RUN}" = "1" ]; then
    AB_DRY_RUN=1
fi
export AB_DRY_RUN AB_RESULTS AB_EVIDENCE_LOG AB_SCEN_DATA_DIR

# Scratch for the seed tree, the manifests and the pushed copies. Nothing here outlives
# the case: what must outlive it is on /data and in the evidence directory.
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/ab-scen.XXXXXX") || exit 2
trap 'rm -rf "${_tmp}"' EXIT INT TERM

# --------------------------------------------------------------------------- #
# Red lines (the same two rules matrix.sh enforces, with the same exit status)
# --------------------------------------------------------------------------- #

_red_line() { # <case> <reason>
    printf 'ABORT red-line [%s]: %s\n' "${1:-?}" "${2:-unspecified}" >&2
    printf 'ABORT: the machine has no committed healthy slot to fall back to; nothing else is touched\n' >&2
    ev "ABORT red-line: ${2:-unspecified}"
    exit 3
}

# require_healthy_committed <case>: sets STATUS_LINE, or stops the whole run.
# The line comes back through a variable, not through stdout: a command substitution
# runs in a subshell, and the exit would then only leave the subshell.
require_healthy_committed() {
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

# require_safe_target <case> <status_line>: an install lands on the inactive slot, so the
# running slot must be the committed one and no candidate may be queued.
require_safe_target() {
    _case=${1:-?}
    _line=${2:-}
    _slot=$(status_field "${_line}" slot) || _slot=""
    _committed=$(status_field "${_line}" committed) || _committed=""
    _pending=$(status_field "${_line}" pending) || _pending=""
    [ "${_slot}" = "${_committed}" ] \
        || _red_line "${_case}" "running slot ${_slot:-?} is not the committed slot ${_committed:-?}: an install would overwrite the only healthy slot"
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
        a) printf 'b' ;;
        b) printf 'a' ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------- #
# Verdict bookkeeping
# --------------------------------------------------------------------------- #

# One red judgement is collected, not fatal: the user wants the whole list of what broke,
# not the first item of it. The verdict is the aggregate of CASE_FAILED.
_check() {
    "$@" || CASE_FAILED=1
}

_fail() { # <case> <message>
    CASE_FAILED=1
    AB_ASSERT_FAILURES=$((AB_ASSERT_FAILURES + 1))
    printf 'FAIL %s %s\n' "${1:-?}" "${2:-assertion failed}"
    printf '  status: %s\n' "${AB_STATUS_LINE:-unknown}"
    printf '  evidence: %s\n' "${AB_EVIDENCE_LOG:-none}"
    printf '  rerun: %s\n' "${SCEN_CMD:-./scripts/device/scenarios.sh --case ${1:-?}}"
    ev "FAIL ${1:-?} ${2:-assertion failed}"
}

# _finding <text>: a scenario-specific discovery that is not a failure.
# A kmod built for the kernel the machine ran before the jump is what apk does; the user
# needs to know it and to know what to reinstall, which is why it lands in the note with
# the FINDING: prefix instead of turning the row red.
_finding() {
    if [ -z "${CASE_FINDINGS}" ]; then
        CASE_FINDINGS="FINDING: ${1}"
    else
        CASE_FINDINGS="${CASE_FINDINGS}; FINDING: ${1}"
    fi
    ev "FINDING: ${1}"
}

# --------------------------------------------------------------------------- #
# The remote helper
# --------------------------------------------------------------------------- #

# scen_helper_render <outfile>: write the helper that is pushed to the machine.
# Plain POSIX sh on purpose: BusyBox ash has no arrays, no [[ ]] and no local in every
# build, and the guest image has no python to fall back on. Every subcommand prints
# `key=value` tokens the host parses; nothing here decides a verdict.
scen_helper_render() {
    cat >"${1}" <<'AB_SCEN_HELPER_EOF'
#!/bin/sh
# ab-scenarios remote helper. Pushed by scripts/device/scenarios.sh; not a command the
# user runs. Every subcommand prints key=value lines and exits 0 unless the host has to
# read a non-zero status from a line it printed.
set -u

say() { printf '%s\n' "$*"; }

hash_tool() {
    if command -v sha256sum >/dev/null 2>&1; then printf 'sha256sum\n'
    elif command -v md5sum >/dev/null 2>&1; then printf 'md5sum\n'
    else printf 'none\n'; fi
}

# hash_of <file>: one file's digest, or "none" when there is no file or no tool.
# The tool's name is not written into the line: the host reads hash= from probe and
# refuses a machine that cannot produce sha256, because the payload manifest records
# sha256 and two different algorithms cannot be compared.
hash_of() {
    _ht=$(hash_tool)
    if [ "${_ht}" = none ] || [ ! -f "$1" ]; then printf 'none\n'; return 0; fi
    "${_ht}" "$1" 2>/dev/null | awk '{print $1}'
}

# pkgver <pkg>: the version string apk records, or "unknown".
# apk-tools 2 answers `apk info -v <pkg>`, apk-tools 3 answers `apk list --installed`,
# and the guest image is the only place that decides which one it has.
pkgver() {
    _pv_name=$1
    # apk-tools 3 prints the package *description* for `apk info -v <name>`, which reads as
    # a version to any caller that only looks for a non-empty line. The installed index is
    # the only output that always starts with <name>-<version>, so it is asked first; the
    # `apk info` form stays as the apk-tools 2 fallback.
    _v=$(apk list --installed "${_pv_name}" 2>/dev/null | head -n 1 | awk '{print $1}')
    case "${_v}" in
        "${_pv_name}-"*) ;;
        *) _v=$(apk info -v "${_pv_name}" 2>/dev/null | head -n 1) ;;
    esac
    case "${_v}" in
        ""|*:*) _v=unknown ;;
    esac
    printf '%s\n' "${_v}"
}

cmd_probe() {
    say "kver=$(uname -r)"
    say "kernel_dirs=$(ls -1 /lib/modules 2>/dev/null | wc -l | tr -d ' ')"
    if command -v apk >/dev/null 2>&1; then say "apk=yes"; else say "apk=no"; fi
    if grep -q ' /data ' /proc/mounts 2>/dev/null; then say "data=mounted"; else say "data=missing"; fi
    if grep -q ' /mnt/p4 ' /proc/mounts 2>/dev/null; then say "p4=mounted"; else say "p4=missing"; fi
    say "hash=$(hash_tool)"
    say "helper=1"
}

cmd_mkdirs() {
    for _d in "$@"; do
        if mkdir -p "${_d}" 2>/dev/null; then say "mkdir=${_d} ok=yes"; else say "mkdir=${_d} ok=no"; fi
    done
}

# cmd_pkginstall <pkg>: one package, one verdict. A package the repositories do not have
# is reported as unavailable with its exit status and the first error line -- the user's
# request is "record it and keep going", not "abort the batch".
cmd_pkginstall() {
    _pkg=$1
    _out=$(apk add --no-cache "${_pkg}" 2>&1)
    _rc=$?
    if [ "${_rc}" -eq 0 ] && apk info -e "${_pkg}" >/dev/null 2>&1; then
        say "pkg=${_pkg} state=installed rc=${_rc} version=$(pkgver "${_pkg}")"
        return 0
    fi
    _first=$(printf '%s\n' "${_out}" | sed -n '1p' | tr -d '\r')
    say "pkg=${_pkg} state=unavailable rc=${_rc} err=${_first}"
    return 0
}

# cmd_pkgsnap <outfile>: the full installed set, so "what did the user have" is a file and
# not a memory. apk-tools 2 and 3 answer different questions; both are accepted.
cmd_pkgsnap() {
    _out=$1
    if apk info -v >"${_out}" 2>/dev/null; then
        :
    elif apk list --installed >"${_out}" 2>/dev/null; then
        :
    else
        say "snap=${_out} count=0 tool=none"
        return 1
    fi
    say "snap=${_out} count=$(wc -l <"${_out}" | tr -d ' ')"
}

# cmd_pkgcheck <pkg>: is it still installed, and do its own files still exist.
# `apk info -e` is the package database; the file list is what the user notices. A
# package can be present and still have none of its files, which is the interesting case.
cmd_pkgcheck() {
    _pkg=$1
    _present=no
    apk info -e "${_pkg}" >/dev/null 2>&1 && _present=yes
    _file=none
    _fileok=na
    _list=$(apk info -L "${_pkg}" 2>/dev/null | grep '^/' | grep -v '/$' | head -n 20)
    if [ -n "${_list}" ]; then
        _fileok=no
        for _f in ${_list}; do
            if [ -e "${_f}" ]; then _file=${_f}; _fileok=yes; break; fi
        done
        [ "${_fileok}" = yes ] || _file=$(printf '%s\n' "${_list}" | head -n 1)
    fi
    say "pkg=${_pkg} present=${_present} version=$(pkgver "${_pkg}") file=${_file} fileok=${_fileok}"
}

# cmd_kmodcheck <kmod>: is this kernel module still built for the running kernel.
# Two independent witnesses, because either one can be missing on a given apk build:
#   * the /lib/modules/<ver>/ directory the package's own files land in;
#   * the kernel dependency apk recorded for the package.
# state=match   both witnesses agree with uname -r (or are absent)
# state=stale   a witness names a kernel the machine no longer runs
# state=missing the package is gone
# state=unknown apk reported neither, so the host records a FINDING instead of a guess
cmd_kmodcheck() {
    _kmod=$1
    _kver=$(uname -r)
    if ! apk info -e "${_kmod}" >/dev/null 2>&1; then
        say "kmod=${_kmod} state=missing kver=${_kver} version=none modver=none depver=none"
        return 0
    fi
    _version=$(pkgver "${_kmod}")
    _modver=$(apk info -L "${_kmod}" 2>/dev/null | grep '^/lib/modules/' | head -n 1 \
        | sed -e 's|^/lib/modules/||' -e 's|/.*$||')
    [ -n "${_modver}" ] || _modver=none
    _depver=$(apk info -R "${_kmod}" 2>/dev/null | grep 'kernel' | head -n 1 \
        | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    [ -n "${_depver}" ] || _depver=none
    _state=match
    case "${_modver}" in
        none) : ;;
        *) [ "${_modver}" = "${_kver}" ] || _state=stale ;;
    esac
    case "${_depver}" in
        none) : ;;
        *) [ "${_depver}" = "${_kver}" ] || _state=stale ;;
    esac
    if [ "${_modver}" = none ] && [ "${_depver}" = none ]; then _state=unknown; fi
    say "kmod=${_kmod} state=${_state} kver=${_kver} version=${_version} modver=${_modver} depver=${_depver}"
}

# cmd_exec <cmd...>: run one command and report its exit status plus the first output line.
cmd_exec() {
    "$@" >/tmp/ab-scen-exec.out 2>&1
    _rc=$?
    say "cmd=$* rc=${_rc} out=$(sed -n '1p' /tmp/ab-scen-exec.out | cut -c1-80)"
    rm -f /tmp/ab-scen-exec.out
}

# cmd_seed <tar> <dest>: unpack the user's files. One push instead of ten, and the tree
# keeps its Chinese filenames because tar carries them as bytes.
cmd_seed() {
    _tar=$1
    _dest=$2
    if [ ! -f "${_tar}" ]; then say "seed=${_dest} rc=1 err=no-payload"; return 1; fi
    mkdir -p "${_dest}" 2>/dev/null || { say "seed=${_dest} rc=1 err=mkdir"; return 1; }
    _out=$(tar -xf "${_tar}" -C "${_dest}" 2>&1)
    _rc=$?
    say "seed=${_dest} rc=${_rc} files=$(find "${_dest}" -type f 2>/dev/null | wc -l | tr -d ' ') dirs=$(find "${_dest}" -type d 2>/dev/null | wc -l | tr -d ' ')"
    [ "${_rc}" -eq 0 ] || say "seed_err=$(printf '%s\n' "${_out}" | sed -n '1p')"
    return 0
}

# cmd_hash <dir>: the manifest the post-jump judgement diffs against.
# Relative paths sorted in the C locale, so two runs describe the same tree the same way.
cmd_hash() {
    _dir=$1
    _tool=$(hash_tool)
    say "tool=${_tool}"
    say "files=$(find "${_dir}" -type f 2>/dev/null | wc -l | tr -d ' ')"
    say "dirs=$(find "${_dir}" -type d 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${_tool}" = none ]; then say "hash=none"; return 1; fi
    if [ ! -d "${_dir}" ]; then say "hash=nodir"; return 1; fi
    ( cd "${_dir}" || exit 1
      find . -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r _f; do
          _h=$("${_tool}" "${_f}" 2>/dev/null | awk '{print $1}')
          [ -n "${_h}" ] || _h=none
          printf 'H %s %s\n' "${_h}" "${_f#./}"
      done )
}

# cmd_tartest <file>...: a tar a user keeps must still be readable as a tar.
cmd_tartest() {
    for _f in "$@"; do
        tar -tf "${_f}" >/dev/null 2>&1
        _rc=$?
        _n=$(tar -tf "${_f}" 2>/dev/null | wc -l | tr -d ' ')
        say "tar=${_f} rc=${_rc} members=${_n}"
    done
}

# cmd_cfg_backup <bakdir> <file>...: the rollback path, written before anything changes.
# A file naming a copy that does not exist is worse than no backup at all, so every copy
# is reported and the host refuses to go on unless all three land.
cmd_cfg_backup() {
    _bak=$1
    shift
    mkdir -p "${_bak}" 2>/dev/null || { say "backup=none ok=no"; return 1; }
    _ok=0
    for _f in "$@"; do
        _b=$(printf '%s\n' "${_f}" | sed -e 's|^/|_|' -e 's|/|_|g')
        if cp "${_f}" "${_bak}/${_b}.bak" 2>/dev/null; then
            _ok=$((_ok + 1))
            say "backup=${_f} -> ${_bak}/${_b}.bak ok=yes"
        else
            say "backup=${_f} ok=no"
        fi
    done
    say "backups=${_ok} of=$#"
}

# cmd_cfg_write <uci-name> <label>: a configuration file of the user's own.
# Written as a real uci file and committed, because the judgement after the jump is
# `uci get <name>.marker.label` and not "the file is still 200 bytes long".
cmd_cfg_write() {
    _u=$1
    _label=$2
    cat >"/etc/config/${_u}" <<UCI_EOF
config scenario 'marker'
	option label '${_label}'
	option stamp '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
UCI_EOF
    uci commit "${_u}" 2>/dev/null
    _rc=$?
    say "cfg=${_u} commit_rc=${_rc} label=$(uci -q get "${_u}.marker.label" 2>/dev/null)"
}

# cmd_cfg_system <hostname> <timezone> <zonename>: two settings a user really changes.
cmd_cfg_system() {
    uci set "system.@system[0].hostname=$1" 2>/dev/null
    uci set "system.@system[0].timezone=$2" 2>/dev/null
    uci set "system.@system[0].zonename=$3" 2>/dev/null
    uci commit system 2>/dev/null
    _rc=$?
    hostname "$1" 2>/dev/null || true
    say "system commit_rc=${_rc} hostname=$(uci -q get system.@system[0].hostname 2>/dev/null) timezone=$(uci -q get system.@system[0].timezone 2>/dev/null) zonename=$(uci -q get system.@system[0].zonename 2>/dev/null) running=$(hostname 2>/dev/null)"
}

# cmd_cfg_net <uci-name>: one extra interface section, the shape LuCI writes.
# proto=none, auto=0, no device: it cannot take the management interface down, which is
# the point -- the scenario has to be able to survive its own user.
cmd_cfg_net() {
    _u=$1
    if uci -q get "network.${_u}" >/dev/null 2>&1; then
        # A scenario has to survive being run twice: the reuse path reports the same keys
        # as the fresh one, because the host judges the same keys either way.
        say "net=${_u} already=yes reused=yes proto=$(uci -q get "network.${_u}.proto") auto=$(uci -q get "network.${_u}.auto")"
        return 0
    fi
    uci set "network.${_u}=interface" 2>/dev/null || { say "net=${_u} set=no"; return 1; }
    uci set "network.${_u}.proto=none" 2>/dev/null
    uci set "network.${_u}.auto=0" 2>/dev/null
    uci commit network 2>/dev/null
    _rc=$?
    say "net=${_u} proto=$(uci -q get "network.${_u}.proto") commit_rc=${_rc}"
}

# cmd_cfg_fw <name>: one firewall rule. Port 9 (discard) from lan and nothing else: a rule
# that is visibly a rule and cannot reach the port this session runs on.
cmd_cfg_fw() {
    _name=$1
    _sec=$(uci -q show firewall 2>/dev/null \
        | sed -n "s/^firewall\.\([^.]*\)\.name='\{0,1\}${_name}'\{0,1\}\$/\1/p" | head -n 1)
    if [ -n "${_sec}" ]; then
        # Same reason as cmd_cfg_net: a reused rule has to answer with the fields the
        # fresh path answers with, otherwise a second run of S2 reads as a failed commit.
        say "fwrule=${_name} already=yes reused=yes sec=${_sec} target=$(uci -q get "firewall.${_sec}.target") src=$(uci -q get "firewall.${_sec}.src") proto=$(uci -q get "firewall.${_sec}.proto") dest_port=$(uci -q get "firewall.${_sec}.dest_port")"
        return 0
    fi
    uci add firewall rule >/dev/null 2>&1 || { say "fwrule=${_name} add=no"; return 1; }
    uci set "firewall.@rule[-1].name=${_name}" 2>/dev/null
    uci set "firewall.@rule[-1].src=lan" 2>/dev/null
    uci set "firewall.@rule[-1].proto=tcp" 2>/dev/null
    uci set "firewall.@rule[-1].dest_port=9" 2>/dev/null
    uci set "firewall.@rule[-1].target=DROP" 2>/dev/null
    uci commit firewall 2>/dev/null
    _rc=$?
    say "fwrule=${_name} target=$(uci -q get "firewall.@rule[-1].target" 2>/dev/null) commit_rc=${_rc}"
}

# cmd_net_apply <bakdir> <grace>: the destructive half of S2.
# The machine schedules its own revert *before* it reloads, because the host cannot send
# the rollback command over the connection the reload might have just broken. The host
# confirms with cmd_net_confirm as soon as ssh answers again; without that confirmation
# the backup is restored after <grace> seconds.
cmd_net_apply() {
    _bak=$1
    _grace=$2
    rm -f /tmp/ab-scen-net.ok
    # The rollback body is a small file rather than a quoted one-liner: a scheduler plus
    # a shell -c plus a quoted path is where this kind of thing usually goes wrong.
    _wd=/tmp/ab-scen-net-watchdog.sh
    {
        printf '#!/bin/sh\n'
        printf 'sleep %s\n' "${_grace}"
        printf '[ -f /tmp/ab-scen-net.ok ] && exit 0\n'
        printf 'cp %s/_etc_config_network.bak /etc/config/network 2>/dev/null\n' "${_bak}"
        printf 'cp %s/_etc_config_firewall.bak /etc/config/firewall 2>/dev/null\n' "${_bak}"
        printf '/etc/init.d/network reload >/dev/null 2>&1\n'
        printf 'logger -t ab-scen "network rolled back: no confirmation within %ss"\n' "${_grace}"
    } >"${_wd}"
    chmod +x "${_wd}"
    # The revert has to outlive the connection the reload is about to break, and the image
    # ships no nohup: setsid detaches the child from the session that ssh kills, and
    # start-stop-daemon -b is the busybox-side equivalent. A watchdog that cannot be
    # scheduled means the change must not be applied at all, which is the last branch.
    _wd_how=none
    if command -v setsid >/dev/null 2>&1; then
        setsid "${_wd}" >>/tmp/ab-scen-net-watchdog.log 2>&1 &
        _wd_how=setsid
    elif command -v start-stop-daemon >/dev/null 2>&1; then
        start-stop-daemon -S -b -x /bin/sh -- -c "exec ${_wd}" >>/tmp/ab-scen-net-watchdog.log 2>&1
        _wd_how=start-stop-daemon
    fi
    if [ "${_wd_how}" != "none" ]; then
        say "watchdog=yes how=${_wd_how} grace=${_grace} confirm=/tmp/ab-scen-net.ok"
    else
        # Without a way to schedule the revert, applying the change would be a step the
        # machine cannot come back from on its own. The file is written and not applied.
        say "watchdog=no grace=${_grace} confirm=/tmp/ab-scen-net.ok"
        say "net-reload rc=skipped"
        return 0
    fi
    if command -v ubus >/dev/null 2>&1; then
        ubus call network reload >/dev/null 2>&1
        _rc=$?
    else
        /etc/init.d/network reload >/dev/null 2>&1
        _rc=$?
    fi
    say "net-reload rc=${_rc}"
}

# cmd_net_confirm: the host saw the machine answer, so the scheduled revert must not fire.
cmd_net_confirm() {
    : >/tmp/ab-scen-net.ok
    say "confirm=ok"
}

# cmd_net_rollback <bakdir>: the host-issued rollback, used when ssh still answers
# (a reload that broke one thing but not the session) and as a second chance when the
# watchdog has already fired.
cmd_net_rollback() {
    _bak=$1
    : >/tmp/ab-scen-net.ok
    _n=0
    for _c in network firewall system; do
        if [ -f "${_bak}/_etc_config_${_c}.bak" ]; then
            cp "${_bak}/_etc_config_${_c}.bak" "/etc/config/${_c}" 2>/dev/null && _n=$((_n + 1))
            say "restore=/etc/config/${_c}"
        fi
    done
    /etc/init.d/network reload >/dev/null 2>&1
    say "rollback=done restored=${_n}"
}

# cmd_cfg_read <uci-name>: everything the judgement compares, read fresh.
cmd_cfg_read() {
    _u=$1
    say "abscen=$(uci -q get "${_u}.marker.label" 2>/dev/null)"
    say "hostname=$(uci -q get system.@system[0].hostname 2>/dev/null)"
    say "timezone=$(uci -q get system.@system[0].timezone 2>/dev/null)"
    say "zonename=$(uci -q get system.@system[0].zonename 2>/dev/null)"
    _sec=no
    [ "$(uci -q get "network.${_u}.proto" 2>/dev/null)" = none ] && _sec=yes
    say "netsec=${_sec}"
    if uci -q show firewall 2>/dev/null | grep -q "abscen"; then say "fwrule=yes"; else say "fwrule=no"; fi
}

# cmd_overlay_probe: the writable layer still takes a write.
# /overlay is the OpenWrt convention; a machine that mounts it elsewhere is judged by its
# root filesystem, which is the same overlay seen from the other side.
cmd_overlay_probe() {
    if [ -d /overlay ]; then _t=/overlay; else _t=/; fi
    _f="${_t}/.ab-scen-probe.$$"
    if printf 'probe\n' >"${_f}" 2>/dev/null; then
        rm -f "${_f}" 2>/dev/null
        say "target=${_t} write=rw"
    else
        say "target=${_t} write=ro"
    fi
}

# cmd_svc_cycle <name>: stop then start, in that order, so a broken service is named and
# the machine is left with the service running.
cmd_svc_cycle() {
    _s=$1
    if [ ! -x "/etc/init.d/${_s}" ]; then
        say "svc=${_s} state=absent stop=na start=na"
        return 0
    fi
    "/etc/init.d/${_s}" stop >/dev/null 2>&1
    _rc1=$?
    "/etc/init.d/${_s}" start >/dev/null 2>&1
    _rc2=$?
    say "svc=${_s} state=present stop=${_rc1} start=${_rc2}"
}

# esp_names <kernel|initrd> <slot>: the names the ESP may carry a boot file under.
# ab-upgrade writes vmlinuz-<slot> and initrd-<slot>; the alternatives are here so an
# image built by hand reads as "this name is not on the ESP" (the listing is printed for
# exactly that) instead of as a digest mismatch against a file the case never looked at.
esp_names() {
    case "$1" in
        kernel) printf 'vmlinuz-%s Image-%s bzImage-%s\n' "$2" "$2" "$2" ;;
        initrd) printf 'initrd-%s initramfs-%s initrd.img-%s\n' "$2" "$2" "$2" ;;
        *) return 1 ;;
    esac
}

# esp_member <esp dir> <kernel|initrd> <slot>: the first of those names that exists.
esp_member() {
    for _em_n in $(esp_names "$2" "$3"); do
        if [ -f "$1/${_em_n}" ]; then printf '%s\n' "$1/${_em_n}"; return 0; fi
    done
    printf 'none\n'
}

# ledger_tool <name> [args...]: one line for the ledger, absent tools included.
# The ledger is read by a person ("which busybox is this, which sfdisk"), so the version
# line is passed through whole and nothing here decides anything.
ledger_tool() {
    _lt=$1
    shift
    if ! command -v "${_lt}" >/dev/null 2>&1; then
        say "ledger: ${_lt} absent"
        return 0
    fi
    _lv=$("${_lt}" "$@" 2>&1 | sed -n '1p' | tr -d '\r')
    [ -n "${_lv}" ] || _lv="no-version-line"
    say "ledger: ${_lt} ${_lv}"
}

# cmd_boottools <slot> <esp dir>: the boot chain as it stands on this machine, read-only.
# Three groups of facts, none of them a verdict:
#   * the two boot files the ESP carries for the running slot, hashed;
#   * the tool that lives in the platform layer (btrfs by default), hashed and run once --
#     the exit status matters, because a tool that is present and does not run is the
#     failure mode that leaves a slot unable to finish its boot;
#   * the ledger: the platform layer's own release file (which payload wrote these tools)
#     and the version strings of the tools that answer on this image.
# The platform layer is a lower layer of the merged root, so /usr/sbin/btrfs is the
# layer's file: the payload build keeps btrfs out of the upstream rootfs on purpose, so
# the merged path is the platform's. When an earlier --check left the slot mounted, the
# slot's own @platform answers instead and tool_source says so.
cmd_boottools() {
    _slot=$1
    _esp=$2
    say "esp=${_esp}"
    say "esp_list=$(ls -1 "${_esp}" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    for _role in kernel initrd; do
        _bp=$(esp_member "${_esp}" "${_role}" "${_slot}")
        say "${_role}_path=${_bp}"
        say "${_role}_sha=$(hash_of "${_bp}")"
    done

    _bt=${AB_SCEN_TOOL:-btrfs}
    _src=merged
    _tp=none
    if [ -f "/mnt/slots/${_slot}/@platform/usr/sbin/${_bt}" ]; then
        _tp="/mnt/slots/${_slot}/@platform/usr/sbin/${_bt}"
        _src=slot-mount
    else
        _tp=$(command -v "${_bt}" 2>/dev/null) || _tp=""
        [ -n "${_tp}" ] || _tp=none
    fi
    say "tool=${_bt}"
    say "tool_source=${_src}"
    say "tool_path=${_tp}"
    say "tool_sha=$(hash_of "${_tp}")"
    if [ "${_tp}" = none ]; then
        say "tool_rc=127"
        say "tool_version="
        say "tool_err=not-on-this-machine"
    else
        _ov=$("${_tp}" --version 2>&1)
        _orc=$?
        say "tool_rc=${_orc}"
        say "tool_version=$(printf '%s\n' "${_ov}" | sed -n '1p' | tr -d '\r' | cut -c1-120)"
        if [ "${_orc}" -eq 0 ]; then
            say "tool_err="
        else
            say "tool_err=$(printf '%s\n' "${_ov}" | tr '\n' ' ' | tr -d '\r' | cut -c1-160)"
        fi
    fi

    _rel=none
    for _rf in "/mnt/slots/${_slot}/@platform/etc/platform-release" /etc/platform-release; do
        if [ -f "${_rf}" ]; then _rel=${_rf}; break; fi
    done
    say "release_path=${_rel}"
    if [ "${_rel}" = none ]; then
        say "release="
    else
        say "release=$(tr '\n' ' ' <"${_rel}" 2>/dev/null | tr -d '\r')"
    fi

    ledger_tool busybox
    ledger_tool sfdisk --version
    ledger_tool partx --version
    ledger_tool "${_bt}" --version
}

_cmd=${1:-}
[ -n "${_cmd}" ] || { say "usage: ab-scen-helper.sh <probe|mkdirs|pkginstall|pkgsnap|pkgcheck|kmodcheck|exec|seed|hash|tartest|cfg-*|net-*|overlay-probe|svc-cycle|boottools>"; exit 2; }
shift
case "${_cmd}" in
    probe) cmd_probe ;;
    mkdirs) cmd_mkdirs "$@" ;;
    pkginstall) cmd_pkginstall "$@" ;;
    pkgsnap) cmd_pkgsnap "$@" ;;
    pkgcheck) cmd_pkgcheck "$@" ;;
    kmodcheck) cmd_kmodcheck "$@" ;;
    exec) cmd_exec "$@" ;;
    seed) cmd_seed "$@" ;;
    hash) cmd_hash "$@" ;;
    tartest) cmd_tartest "$@" ;;
    cfg-backup) cmd_cfg_backup "$@" ;;
    cfg-write) cmd_cfg_write "$@" ;;
    cfg-system) cmd_cfg_system "$@" ;;
    cfg-net) cmd_cfg_net "$@" ;;
    cfg-fw) cmd_cfg_fw "$@" ;;
    cfg-read) cmd_cfg_read "$@" ;;
    net-apply) cmd_net_apply "$@" ;;
    net-confirm) cmd_net_confirm ;;
    net-rollback) cmd_net_rollback "$@" ;;
    overlay-probe) cmd_overlay_probe ;;
    svc-cycle) cmd_svc_cycle "$@" ;;
    boottools) cmd_boottools "$@" ;;
    *)
        say "helper: unknown subcommand: ${_cmd}"
        exit 2
        ;;
esac
AB_SCEN_HELPER_EOF
}

# scen <helper args...>: run one helper subcommand on the machine.
# Arguments are joined with spaces, so a caller with a command to run passes it unquoted
# (`scen exec ${_cmd}`) exactly the way it wants it split.
# The flag is a file, not a variable: scen() is almost always called inside $(...), and a
# variable set in that subshell never reaches the code that decides the verdict.
SCEN_DRIVER_ERROR_FILE=""

driver_error_mark() {
    [ -n "${SCEN_DRIVER_ERROR_FILE}" ] || return 0
    : >"${SCEN_DRIVER_ERROR_FILE}"
}

# machine_unreachable_mark/seen: the opposite of a driver error. The reload broke the
# connection to a machine that is still running; that is the fact the case exists to
# report, so it must not be rewritten as "the helper did not answer".
machine_unreachable_mark() {
    [ -n "${SCEN_DRIVER_ERROR_FILE}" ] || return 0
    : >"${SCEN_DRIVER_ERROR_FILE}.ssh-lost"
}

machine_unreachable_seen() {
    [ -n "${SCEN_DRIVER_ERROR_FILE}" ] && [ -f "${SCEN_DRIVER_ERROR_FILE}.ssh-lost" ]
}

driver_error_seen() {
    [ -n "${SCEN_DRIVER_ERROR_FILE}" ] && [ -f "${SCEN_DRIVER_ERROR_FILE}" ]
}

scen() {
    _line="sh ${SCEN_HELPER}"
    for _a in "$@"; do
        _line="${_line} ${_a}"
    done
    _out=$(dev_ssh "${_line}")
    _rc=$?
    # An empty answer means the helper is not on the machine, not that the machine has
    # nothing to say. Judging the second as if it were the first is how a driver bug gets
    # written down as a device defect, so it is recorded as a driver error and the case
    # stops judging.
    if [ "${_rc}" -ne 0 ] || [ -z "${_out}" ]; then
        driver_error_mark
        ev "driver-error=helper-unavailable rc=${_rc} helper=${SCEN_HELPER} args=$*"
        return 1
    fi
    printf '%s\n' "${_out}"
}

# pull <remote path>: read a file off the machine into RDATA; 0 when it exists and is not
# empty, 1 when it does not.
pull() {
    if _txt=$(dev_ssh "cat ${1}" 2>/dev/null) && [ -n "${_txt}" ]; then
        RDATA=${_txt}
        return 0
    fi
    RDATA=""
    return 1
}

# kv <text> <key>: the value of a key=value token, anywhere in the text.
# One line of helper output carries several facts (`pkg=curl state=installed rc=0 ...`), so
# this searches tokens rather than line starts -- which is exactly what lib.sh's
# status_field does for `ab-slot status`, and repeating that logic is how the two parsers
# would drift apart.
kv() {
    status_field "${1:-}" "${2:?kv needs a key}" 2>/dev/null
}

push_helper() {
    scen_helper_render "${_tmp}/ab-scen-helper.sh" || return 1
    dev_ssh "mkdir -p $(dirname "${SCEN_HELPER}")" >/dev/null 2>&1
    if dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_tmp}/ab-scen-helper.sh" "${SCEN_HELPER}" >/dev/null; then
        ev "helper pushed: ${SCEN_HELPER}"
        return 0
    fi
    # Losing the persistent path costs a re-push per reboot, not the run.
    SCEN_HELPER="${AB_REMOTE_TMP}/ab-scen-helper.sh"
    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_tmp}/ab-scen-helper.sh" "${SCEN_HELPER}" >/dev/null \
        || { ev "helper push failed: ${SCEN_HELPER}"; return 1; }
    ev "helper pushed to the scratch path instead: ${SCEN_HELPER}"
    return 0
}

# probe_machine: fills PROBE with the key=value facts of the machine at hand.
PROBE=""
probe_machine() {
    PROBE=$(scen probe 2>/dev/null) || PROBE=""
    [ -n "${PROBE}" ] || return 1
    ev "probe: $(printf '%s' "${PROBE}" | tr '\n' ' ')"
    return 0
}

# ssh_alive: is the machine still usable, not just reachable once.
#
# An address that has just come up answers before routing settles, so a single success
# says nothing; the check therefore asks for consecutive answers spaced by a gap, and
# every answer also has to come from a login that can still read ab-slot (a machine whose
# ssh survives but whose tooling cannot answer is not a machine anyone can recover).
ssh_alive() {
    _deadline=$(( $(date +%s) + ${SCEN_LIVENESS_DEADLINE} ))
    _streak=0
    while :; do
        if dev_ssh "ab-slot status" >/dev/null 2>&1; then
            _streak=$((_streak + 1))
            [ "${_streak}" -ge "${SCEN_LIVENESS_OK}" ] && return 0
        else
            _streak=0
        fi
        [ "$(date +%s)" -lt "${_deadline}" ] || return 1
        sleep "${SCEN_LIVENESS_GAP}"
    done
}

# _hash_cmp <before> <after>: one line per difference, nothing when the trees agree.
# `changed`/`missing`/`untracked` name the file, because "3 files differ" is not something
# a user can act on.
_hash_cmp() {
    awk '
        FNR == NR {
            if ($1 == "H") { want[$3] = $2; next }
            if ($1 ~ /^(files|dirs)=/) { split($1, kv, "="); bcount[kv[1]] = kv[2] }
            next
        }
        $1 == "H" {
            if (!($3 in want)) { print "untracked " $3; next }
            if (want[$3] != $2) { print "changed " $3 }
            seen[$3] = 1
            next
        }
        $1 ~ /^(files|dirs)=/ { split($1, kv, "="); acount[kv[1]] = kv[2] }
        END {
            for (f in want) if (!(f in seen)) print "missing " f
            for (k in bcount) if (bcount[k] != acount[k]) print "entries " k " before=" bcount[k] " after=" acount[k]
        }
    ' "${1}" "${2}"
}

# _scen_probe_cmd <pkg>: the command that proves one package still runs, if we know one.
# The table is `name:args` and is split on whitespace, so the args must not carry any:
# `curl:curl --version` used to split into `curl:curl` and a stray `--version`, which ran
# the bare program and recorded a usage error as the baseline.
_scen_probe_cmd() {
    for _pair in ${SCEN_PROBES}; do
        case "${_pair}" in
            "${1}:"*) printf '%s %s\n' "${1}" "${_pair#*:}" | sed 's/ *$//'; return 0 ;;
        esac
    done
    return 1
}

# _payload_warn <file>: the missing artifact a dry-run has to name.
_payload_warn() {
    payload_present "${1}" >/dev/null || printf '# warning: %s\n' "$(payload_present "${1}")"
}

# payload_present <name>: is the artifact this case will push actually on disk.
payload_present() {
    [ -f "${PAYLOAD_DIR}/$1" ] && printf '%s\n' "ok" && return 0
    printf 'missing %s\n' "${PAYLOAD_DIR}/$1"
    return 1
}

# --------------------------------------------------------------------------- #
# The seed tree (S2) and what it must contain
# --------------------------------------------------------------------------- #

# _tar_create <archive> <dir>: tar up a directory in a format busybox tar reads.
# macOS bsdtar writes pax extended headers by default; the guest's busybox tar is happiest
# with plain ustar, so the format is pinned where the host tar supports it.
_tar_create() {
    if tar --format=ustar -cf "${1}" -C "${2}" . 2>/dev/null; then return 0; fi
    tar -cf "${1}" -C "${2}" .
}

# build_seed_tree: the user's files, written locally and pushed as one tar.
# Printed: the path of the tar.
build_seed_tree() {
    _root="${_tmp}/seed"
    _stage="${_tmp}/seed-stage"
    rm -rf "${_root}" "${_stage}"
    mkdir -p "${_root}/tree/a/b/c" "${_root}/tree/empty" || return 1

    # MiB-sized files: big enough that a filesystem which quietly stopped carrying the
    # data cannot pass by luck.
    dd if=/dev/urandom of="${_root}/big-1.bin" bs=1024 count=3072 2>/dev/null || return 1
    dd if=/dev/urandom of="${_root}/big-2.bin" bs=1024 count=5120 2>/dev/null || return 1

    # A filename the user's language needs. A tool chain that mangles UTF-8 shows up here
    # and nowhere else.
    printf '中文文件名、内容与空格\n' >"${_root}/中文文件名-测试.txt" || return 1

    # A tar.gz the user keeps, built from a small staged tree.
    mkdir -p "${_stage}/inner" || return 1
    printf 'inner one\n' >"${_stage}/inner/one.txt"
    printf 'inner two\n' >"${_stage}/inner/two.txt"
    printf '备注\n' >"${_stage}/说明.txt"
    ( cd "${_stage}" && tar -czf "${_root}/archive-中文.tar.gz" . ) || return 1

    # Two fake docker image tars. Real tar archives with random blobs inside: the user's
    # question after the jump is "does my image still untar", so they have to be tars.
    for _d in ${SCEN_DOCKER_TARS}; do
        _s="${_stage}/docker-${_d}"
        mkdir -p "${_s}/blobs" || return 1
        dd if=/dev/urandom of="${_s}/blobs/layer.tar" bs=1024 count=1024 2>/dev/null || return 1
        printf '{"fake":"docker-image","name":"%s"}\n' "${_d}" >"${_s}/manifest.json"
        _tar_create "${_root}/${_d}" "${_s}" || return 1
        rm -rf "${_s}"
    done

    printf 'one\n' >"${_root}/tree/a/one.txt"
    printf 'two\n' >"${_root}/tree/a/b/two.txt"
    printf 'deep\n' >"${_root}/tree/a/b/c/deep.txt"

    _tar_create "${_tmp}/seed.tar" "${_root}" || return 1
    printf '%s\n' "${_tmp}/seed.tar"
}

# --------------------------------------------------------------------------- #
# S1: preinstall
# --------------------------------------------------------------------------- #

run_s1() {
    _case=S1
    probefile="${_tmp}/packages.tsv"
    require_healthy_committed "${_case}" || return 1
    AB_STATUS_LINE=${STATUS_LINE}
    push_helper || { CASE_NOTE="helper could not be pushed"; return 1; }
    probe_machine || { CASE_NOTE="the machine did not answer the helper's probe"; return 1; }

    if [ "$(kv "${PROBE}" apk)" != "yes" ]; then
        CASE_NOTE="no apk on this image: nothing to preinstall, the scenario needs an apk system"
        ev "${CASE_NOTE}"
        return 2
    fi
    if [ "$(kv "${PROBE}" data)" != "mounted" ]; then
        CASE_NOTE="/data is not mounted: the snapshot of what was installed has nowhere to live"
        ev "${CASE_NOTE}"
        return 2
    fi

    _kver=$(kv "${PROBE}" kver)
    _stamp=$(dev_stamp | tr ':' '-')
    _mkdirs=$(scen mkdirs "${SCEN_EVIDENCE}" "${SCEN_DATA_DIR}" 2>/dev/null)
    printf '%s\n' "${_mkdirs}" | grep -q 'ok=no' && ev "mkdir problems: $(printf '%s' "${_mkdirs}" | grep 'ok=no' | tr '\n' ' ')"

    {
        printf 'stamp\t%s\n' "${_stamp}"
        printf 'kver\t%s\n' "${_kver}"
        printf 'src\ts1\n'
    } >"${probefile}"

    _ok=0
    _kmod_ok=0
    _pkgs_ok=0
    _bad=0
    _unavailable=""
    for _p in ${SCEN_PKGS}; do
        _line=$(scen pkginstall "${_p}" 2>/dev/null | grep '^pkg=' | head -n 1)
        _state=$(kv "${_line}" state)
        _rc=$(printf '%s\n' "${_line}" | sed -n 's/.* rc=\([^ ]*\).*/\1/p')
        _ver=$(printf '%s\n' "${_line}" | sed -n 's/.* version=\([^ ]*\).*/\1/p')
        _err=$(printf '%s\n' "${_line}" | sed -n 's/.* err=\(.*\)$/\1/p' | cut -c1-60)
        case "${_state}" in
            installed)
                _ok=$((_ok + 1))
                case "${_p}" in
                    kmod-*)
                        _kmod_ok=$((_kmod_ok + 1))
                        printf 'kmod\t%s\t%s\n' "${_p}" "${_ver:-unknown}" >>"${probefile}"
                        ;;
                    *)
                        _pkgs_ok=$((_pkgs_ok + 1))
                        printf 'pkg\t%s\t%s\n' "${_p}" "${_ver:-unknown}" >>"${probefile}"
                        ;;
                esac
                ev "preinstall ${_p}: installed ${_ver:-unknown}"
                ;;
            *)
                _bad=$((_bad + 1))
                _unavailable="${_unavailable}${_p}(rc=${_rc:-?}:${_err:-no-error-line}) "
                printf 'unavailable\t%s\t%s\t%s\n' "${_p}" "${_rc:-?}" "${_err:-no-error-line}" >>"${probefile}"
                ev "preinstall ${_p}: unavailable rc=${_rc:-?} ${_err:-no error line}"
                ;;
        esac
    done

    # The probes: a package that runs now has to run after the jump, so the baseline is
    # taken here and compared in S3/S4 instead of being assumed.
    for _pair in ${SCEN_PROBES}; do
        _p=${_pair%%:*}
        _cmd=$(_scen_probe_cmd "${_p}") || continue
        grep -q "^pkg	${_p}	" "${probefile}" || continue
        _out=$(scen exec ${_cmd} 2>/dev/null | grep '^cmd=' | head -n 1)
        _rc=$(printf '%s\n' "${_out}" | sed -n 's/.* rc=\([^ ]*\).*/\1/p')
        printf 'probe\t%s\t%s\n' "${_p}" "${_rc:-?}" >>"${probefile}"
        ev "probe at preinstall: ${_cmd} rc=${_rc:-?}"
    done

    # The full installed set, as a file: "what did the user have" has to be answerable
    # after the jump without trusting this run's memory.
    _snap=$(scen pkgsnap "${SCEN_EVIDENCE}/apk-snapshot-${_stamp}.txt" 2>/dev/null | grep '^snap=')
    _snap_n=$(kv "${_snap}" count)
    if [ -z "${_snap_n}" ] || [ "${_snap_n}" = "0" ]; then
        _fail "${_case}" "apk snapshot produced no rows: $(printf '%s' "${_snap}")"
    else
        ev "apk snapshot: ${_snap_n} packages -> ${SCEN_EVIDENCE}/apk-snapshot-${_stamp}.txt"
    fi

    # At least one package and one kmod have to be installed, otherwise the later cases
    # would judge an empty machine and call it a pass.
    if [ "${_pkgs_ok}" -eq 0 ] || [ "${_kmod_ok}" -eq 0 ]; then
        CASE_NOTE="installed ${_pkgs_ok} package(s) and ${_kmod_ok} kmod(s); the scenario needs one of each -- unavailable: ${_unavailable:-none}"
        ev "${CASE_NOTE}"
        return 2
    fi

    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${probefile}" "${SCEN_EVIDENCE}/packages.tsv" >/dev/null \
        || { _fail "${_case}" "could not write ${SCEN_EVIDENCE}/packages.tsv"; return 1; }
    pull "${SCEN_EVIDENCE}/packages.tsv" || { _fail "${_case}" "${SCEN_EVIDENCE}/packages.tsv is not readable after the write"; return 1; }

    [ "${CASE_FAILED}" -eq 0 ] || return 1
    CASE_NOTE="installed ${_ok}/$(printf '%s' "${SCEN_PKGS}" | wc -w | tr -d ' ') (${_pkgs_ok} package(s), ${_kmod_ok} kmod), snapshot ${_snap_n:-0} rows"
    [ "${_bad}" -eq 0 ] || CASE_NOTE="${CASE_NOTE}, unavailable: ${_unavailable}"
    return 0
}

# --------------------------------------------------------------------------- #
# S2: user data and configuration
# --------------------------------------------------------------------------- #

# require_backup <case> <bakdir> <output>: the backup is a precondition, not a step.
# Nothing in /etc/config is touched unless all three copies are on /data and readable.
require_backup() {
    _case=$1
    _bak=$2
    _out=$3
    _n=$(kv "${_out}" backups)
    case "${_n}" in
        '' | *[!0-9]*)
            CASE_NOTE="the backup of /etc/config reported no count ($(printf '%s' "${_out}" | tr '\n' ' ')): nothing was changed"
            _fail "${_case}" "${CASE_NOTE}"
            return 1
            ;;
    esac
    if [ "${_n}" -ne 3 ]; then
        CASE_NOTE="only ${_n}/3 of /etc/config/{network,firewall,system} could be backed up to ${_bak}: nothing was changed"
        _fail "${_case}" "${CASE_NOTE}"
        return 1
    fi
    ev "backup ok: ${_n}/3 -> ${_bak}"
    return 0
}

run_s2() {
    _case=S2
    require_healthy_committed "${_case}" || return 1
    AB_STATUS_LINE=${STATUS_LINE}
    push_helper || { CASE_NOTE="helper could not be pushed"; return 1; }
    probe_machine || { CASE_NOTE="the machine did not answer the helper's probe"; return 1; }

    if [ "$(kv "${PROBE}" data)" != "mounted" ]; then
        CASE_NOTE="/data is not mounted: the user's data has nowhere to live, so there is nothing to judge"
        ev "${CASE_NOTE}"
        return 2
    fi
    _tk=$(kv "${PROBE}" hash)
    if [ "${_tk}" = "none" ]; then
        CASE_NOTE="the machine has neither sha256sum nor md5sum: the data hashes could not be taken"
        ev "${CASE_NOTE}"
        return 2
    fi

    _stamp=$(dev_stamp | tr ':' '-')
    _kver=$(kv "${PROBE}" kver)
    scen mkdirs "${SCEN_EVIDENCE}" "${SCEN_DATA_DIR}" >/dev/null 2>&1

    # --- data ------------------------------------------------------------- #
    _seed_tar=$(build_seed_tree) || { _fail "${_case}" "the local seed tree could not be built"; return 1; }
    ev "seed tar: $(wc -c <"${_seed_tar}" | tr -d ' ') bytes"
    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_seed_tar}" "${SCEN_SEED_TAR}" >/dev/null \
        || { _fail "${_case}" "the seed tar could not be pushed to ${SCEN_SEED_TAR}"; return 1; }
    _seed=$(scen seed "${SCEN_SEED_TAR}" "${SCEN_SEED_DIR}" 2>/dev/null)
    if [ "$(kv "${_seed}" rc)" != "0" ]; then
        _fail "${_case}" "seeding ${SCEN_SEED_DIR} failed: $(printf '%s' "${_seed}" | tr '\n' ' ')"
        return 1
    fi
    ev "seed: $(printf '%s' "${_seed}" | tr '\n' ' ')"

    # The manifest is taken right after the write and kept in two places: on /data for a
    # later run, and in this run's evidence directory as the copy the jump cannot touch.
    _man=$(scen hash "${SCEN_SEED_DIR}" 2>/dev/null) || _man=""
    if [ -z "${_man}" ] || [ "$(kv "${_man}" files)" = "" ]; then
        _fail "${_case}" "no manifest could be taken of ${SCEN_SEED_DIR}"
        return 1
    fi
    printf '%s\n' "${_man}" >"${_tmp}/data.sha256"
    cp "${_tmp}/data.sha256" "${EVIDENCE_DIR}/scen-data.sha256" 2>/dev/null || true
    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_tmp}/data.sha256" "${SCEN_EVIDENCE}/data.sha256" >/dev/null \
        || { _fail "${_case}" "the manifest could not be written to ${SCEN_EVIDENCE}/data.sha256"; return 1; }
    ev "manifest: files=$(kv "${_man}" files) dirs=$(kv "${_man}" dirs) tool=$(kv "${_man}" tool)"

    # --- configuration: backup first -------------------------------------- #
    _bak="${SCEN_BACKUP}/etc-config-${_stamp}"
    _bout=$(scen cfg-backup "${_bak}" /etc/config/network /etc/config/firewall /etc/config/system 2>/dev/null)
    require_backup "${_case}" "${_bak}" "${_bout}" || return 1

    _cw=$(scen cfg-write "${SCEN_UCI}" "${SCEN_LABEL}-${_stamp}" 2>/dev/null | grep '^cfg=')
    _label=$(kv "${_cw}" label)
    if [ -z "${_label}" ]; then
        _fail "${_case}" "uci get ${SCEN_UCI}.marker.label is empty right after the write: the custom config did not commit"
    elif [ "${_label}" != "${SCEN_LABEL}-${_stamp}" ]; then
        _fail "${_case}" "custom config label: expected=${SCEN_LABEL}-${_stamp} got=${_label}"
    fi
    ev "custom config: ${_cw}"

    _sys=$(scen cfg-system "${SCEN_HOSTNAME}" "${SCEN_TIMEZONE}" "${SCEN_ZONENAME}" 2>/dev/null | grep '^system')
    [ "$(kv "${_sys}" hostname)" = "${SCEN_HOSTNAME}" ] \
        || _fail "${_case}" "hostname did not take: $(printf '%s' "${_sys}" | tr '\n' ' ')"
    [ "$(kv "${_sys}" timezone)" = "${SCEN_TIMEZONE}" ] \
        || _fail "${_case}" "timezone did not take: $(printf '%s' "${_sys}" | tr '\n' ' ')"
    ev "system settings: ${_sys}"

    _net=$(scen cfg-net "${SCEN_UCI}" 2>/dev/null | grep '^net=')
    [ "$(kv "${_net}" proto)" = "none" ] \
        || _fail "${_case}" "network.${SCEN_UCI} did not commit as proto=none: $(printf '%s' "${_net}" | tr '\n' ' ')"
    _fw=$(scen cfg-fw "${SCEN_UCI}-discard" 2>/dev/null | grep '^fwrule=')
    [ "$(kv "${_fw}" target)" = "DROP" ] \
        || _fail "${_case}" "the firewall rule did not commit: $(printf '%s' "${_fw}" | tr '\n' ' ')"
    ev "network section: ${_net}; firewall rule: ${_fw}"

    # --- the destructive half: apply the network config, then check ssh ---- #
    # A successful backup is worthless if nobody can reach the machine, so the liveness
    # check runs immediately and the machine has its own revert scheduled. A machine that
    # cannot schedule one does not apply the change at all -- see cmd_net_apply -- and the
    # skipped half is a FINDING, not a silent pass.
    _ap=$(scen net-apply "${_bak}" "${SCEN_ROLLBACK_GRACE}" 2>/dev/null \
        | grep -E '^(watchdog|net-reload)(=|[[:space:]])')
    # `net-reload rc=0` carries a space, so a `=`-only pattern silently dropped the one
    # line that proves the reload happened. A missing watchdog line is worse: without it
    # the machine never scheduled a way back, so the case must not be read as a pass.
    if ! printf '%s\n' "${_ap}" | grep -q '^watchdog='; then
        _fail "${_case}" "the reload step reported no watchdog line: no revert could have been scheduled"
        return 1
    fi
    ev "network reload: $(printf '%s' "${_ap}" | tr '\n' ' ')"
    if [ "$(kv "${_ap}" watchdog)" = "no" ]; then
        _finding "this image has neither setsid nor start-stop-daemon, so the revert cannot be scheduled: /etc/config/network was written but not applied, and the ssh-liveness half of S2 was skipped"
    elif ssh_alive; then
        scen net-confirm >/dev/null 2>&1
        ev "ssh alive after the network reload; scheduled revert confirmed away"
    else
        _fail "${_case}" "ssh stopped answering after reloading /etc/config/network: rolling back from ${_bak}"
        _recovery="run: ab-slot status; if the machine is back, /etc/config/network was restored from ${_bak}"
        # The host can only roll back if it can still reach the machine; when it cannot,
        # the watchdog the helper scheduled before the reload restores the backup. Both
        # paths are attempted, and the second one needs no answer from the machine.
        _rb=$(scen net-rollback "${_bak}" 2>/dev/null | grep '^rollback=')
        if [ -n "${_rb}" ]; then
            ev "host rollback: ${_rb}"
        else
            ev "host rollback could not reach the machine; the watchdog restores ${_bak} within ${SCEN_ROLLBACK_GRACE}s"
        fi
        if dev_wait_up_after plain; then
            ev "the machine answers ssh again after the rollback"
            _sys_after=$(scen cfg-read "${SCEN_UCI}" 2>/dev/null)
            ev "after rollback: $(printf '%s' "${_sys_after}" | tr '\n' ' ')"
        else
            ev "the machine did not answer within ${AB_WAIT_UP}s after the rollback"
        fi
        machine_unreachable_mark
        CASE_NOTE="ssh lost after applying /etc/config/network; backed up to ${_bak}, rolled back, ${_recovery}"
        return 1
    fi

    # --- read back what has to survive ------------------------------------ #
    _rd=$(scen cfg-read "${SCEN_UCI}" 2>/dev/null) || _rd=""
    if [ "$(kv "${_rd}" abscen)" != "${_label}" ]; then
        _fail "${_case}" "custom uci config read back as '$(kv "${_rd}" abscen)', expected '${_label}'"
    fi
    [ "$(kv "${_rd}" netsec)" = "yes" ] || _fail "${_case}" "network.${SCEN_UCI} is no longer readable right after being written"
    [ "$(kv "${_rd}" fwrule)" = "yes" ] || _fail "${_case}" "the firewall rule is no longer in the configuration right after being written"
    ev "read back: $(printf '%s' "${_rd}" | tr '\n' ' ')"

    # --- the inventory the jump cases judge against ------------------------ #
    {
        printf 'stamp\t%s\n' "${_stamp}"
        printf 'kver\t%s\n' "${_kver}"
        printf 'src\ts2\n'
        printf 'cfg\tabscen\t%s\n' "${_label}"
        printf 'cfg\thostname\t%s\n' "$(kv "${_rd}" hostname)"
        printf 'cfg\ttimezone\t%s\n' "$(kv "${_rd}" timezone)"
        printf 'cfg\tzonename\t%s\n' "$(kv "${_rd}" zonename)"
        printf 'cfg\tnetsec\tyes\n'
        printf 'cfg\tfwrule\tyes\n'
        printf 'name\tnetsec\t%s\n' "${SCEN_UCI}"
        printf 'name\tfwrule\t%s\n' "${SCEN_UCI}-discard"
        printf 'backup\t%s\n' "${_bak}"
        for _s in ${SCEN_SERVICES}; do printf 'svc\t%s\n' "${_s}"; done
        printf 'seed\t%s\n' "${SCEN_SEED_DIR}"
    } >"${_tmp}/config.tsv"
    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_tmp}/config.tsv" "${SCEN_EVIDENCE}/config.tsv" >/dev/null \
        || { _fail "${_case}" "could not write ${SCEN_EVIDENCE}/config.tsv"; return 1; }

    [ "${CASE_FAILED}" -eq 0 ] || return 1
    _applied="ssh alive after the reload"
    [ "$(kv "${_ap}" watchdog)" = "no" ] && _applied="the reload was skipped (no scheduled revert)"
    CASE_NOTE="files=$(kv "${_man}" files) dirs=$(kv "${_man}" dirs) hashed, uci ${SCEN_UCI} + hostname + timezone + net section + firewall rule set, ${_applied}, backup ${_bak}"
    return 0
}

# --------------------------------------------------------------------------- #
# The post-jump judgement, shared by S3 and S4
# --------------------------------------------------------------------------- #

# v_data <case>: every file the user wrote is byte-identical, and the tars still open.
v_data() {
    _case=$1
    if ! pull "${SCEN_EVIDENCE}/data.sha256"; then
        if [ -s "${EVIDENCE_DIR}/scen-data.sha256" ]; then
            cp "${EVIDENCE_DIR}/scen-data.sha256" "${_tmp}/data.before"
            ev "data manifest: the copy on /data is unreadable, using the one collected before the jump"
        else
            _fail "${_case}" "data: no pre-jump manifest anywhere (${SCEN_EVIDENCE}/data.sha256, ${EVIDENCE_DIR}/scen-data.sha256)"
            return 1
        fi
    else
        printf '%s\n' "${RDATA}" >"${_tmp}/data.before"
    fi

    _after=$(scen hash "${SCEN_SEED_DIR}" 2>/dev/null) || _after=""
    if [ -z "${_after}" ] || [ "$(kv "${_after}" files)" = "" ]; then
        _fail "${_case}" "data: ${SCEN_SEED_DIR} could not be hashed after the jump"
        return 1
    fi
    printf '%s\n' "${_after}" >"${_tmp}/data.after"

    _before_tool=$(kv "$(cat "${_tmp}/data.before")" tool)
    _after_tool=$(kv "${_after}" tool)
    if [ "${_before_tool}" != "${_after_tool}" ]; then
        _finding "the machine answered with ${_after_tool} instead of ${_before_tool}; the hashes were compared as text, which is only valid when the tool is the same"
    fi

    _diff=$(_hash_cmp "${_tmp}/data.before" "${_tmp}/data.after" | sort)
    if [ -n "${_diff}" ]; then
        _n=$(printf '%s\n' "${_diff}" | grep -c . | tr -d ' ')
        _names=$(printf '%s\n' "${_diff}" | awk '{print $2}' | tr '\n' ' ')
        _fail "${_case}" "data: ${_n} difference(s) from the pre-jump manifest: ${_names}"
        ev "data diff: $(printf '%s' "${_diff}" | tr '\n' ';')"
    else
        ev "data: $(kv "${_after}" files) file(s), $(kv "${_after}" dirs) dir(s), every hash matches"
    fi

    for _t in ${SCEN_DOCKER_TARS}; do
        _line=$(scen tartest "${SCEN_SEED_DIR}/${_t}" 2>/dev/null | grep '^tar=' | head -n 1)
        _rc=$(printf '%s\n' "${_line}" | sed -n 's/.* rc=\([^ ]*\).*/\1/p')
        _m=$(printf '%s\n' "${_line}" | sed -n 's/.* members=\([^ ]*\).*/\1/p')
        if [ "${_rc:-1}" = "0" ] && [ "${_m:-0}" -gt 0 ]; then
            ev "tar ok: ${_t} ${_m} member(s)"
        else
            _fail "${_case}" "data: ${_t} no longer reads as a tar (rc=${_rc:-?} members=${_m:-0})"
        fi
    done
}

# v_config <case>: the custom uci file, the hostname and the timezone are still the
# user's values. The expected values are the ones S2 recorded on the machine, not this
# run's defaults: a later run has to judge the machine it finds.
v_config() {
    _case=$1
    if ! pull "${SCEN_EVIDENCE}/config.tsv"; then
        _fail "${_case}" "config: ${SCEN_EVIDENCE}/config.tsv is unreadable, so there is nothing to compare against"
        return 1
    fi
    _exp=${RDATA}
    _got=$(scen cfg-read "${SCEN_UCI}" 2>/dev/null) || _got=""
    _bad=0
    for _k in abscen hostname timezone netsec fwrule; do
        _want=$(printf '%s\n' "${_exp}" | awk -F'\t' -v k="${_k}" '$1 == "cfg" && $2 == k {print $3; exit}')
        [ -n "${_want}" ] || continue
        _have=$(kv "${_got}" "${_k}")
        if [ "${_have}" = "${_want}" ]; then
            ev "config ${_k}: ${_have}"
            continue
        fi
        _bad=1
        _fail "${_case}" "config ${_k}: expected=${_want} got=${_have:-empty}"
    done
    _zonename=$(kv "${_got}" zonename)
    ev "config zonename=${_zonename:-empty} (informational)"
    [ "${_bad}" -eq 0 ] || return 1
    return 0
}

# v_software <case>: every package apk had is still there, its own files still exist, and
# a package that ran before still runs.
v_software() {
    _case=$1
    if ! pull "${SCEN_EVIDENCE}/packages.tsv"; then
        _fail "${_case}" "software: ${SCEN_EVIDENCE}/packages.tsv is unreadable, so the installed set is unknown"
        return 1
    fi
    _exp=${RDATA}
    _n=0
    _filemissing=0
    for _p in $(printf '%s\n' "${_exp}" | awk -F'\t' '$1 == "pkg" || $1 == "kmod" {print $2}'); do
        _n=$((_n + 1))
        _line=$(scen pkgcheck "${_p}" 2>/dev/null | grep '^pkg=' | head -n 1)
        _present=$(printf '%s\n' "${_line}" | sed -n 's/.* present=\([^ ]*\).*/\1/p')
        _fileok=$(printf '%s\n' "${_line}" | sed -n 's/.* fileok=\([^ ]*\).*/\1/p')
        _file=$(printf '%s\n' "${_line}" | sed -n 's/.* file=\([^ ]*\).*/\1/p')
        if [ "${_present}" != "yes" ]; then
            _fail "${_case}" "software ${_p}: apk info -e says it is gone after the jump"
            continue
        fi
        case "${_fileok}" in
            yes) ev "software ${_p}: present, ${_file} exists" ;;
            no) _fail "${_case}" "software ${_p}: the package is installed but none of its files exist (first: ${_file:-none})" ;;
            *)
                # apk keeps no file list until its cache has been rebuilt, so this witness
                # is simply absent. Saying so is the point: a silently skipped second
                # witness is how "the files are still there" gets claimed without evidence.
                ev "software ${_p}: present, no file list to check (apk has none for it)"
                _filemissing=$((_filemissing + 1))
                ;;
        esac
    done
    [ "${_n}" -gt 0 ] || _fail "${_case}" "software: the recorded set is empty, nothing was judged"
    [ "${_filemissing}" -eq 0 ] \
        || _finding "software: ${_filemissing} package(s) had no file list, so their files were not checked"

    # The probes: what ran before the jump has to run after it.
    for _pair in ${SCEN_PROBES}; do
        _p=${_pair%%:*}
        _cmd=$(_scen_probe_cmd "${_p}") || continue
        _want_rc=$(printf '%s\n' "${_exp}" | awk -F'\t' -v k="${_p}" '$1 == "probe" && $2 == k {print $3; exit}')
        [ -n "${_want_rc}" ] || continue
        _out=$(scen exec ${_cmd} 2>/dev/null | grep '^cmd=' | head -n 1)
        _rc=$(printf '%s\n' "${_out}" | sed -n 's/.* rc=\([^ ]*\).*/\1/p')
        if [ "${_rc}" = "${_want_rc}" ]; then
            ev "exec ${_cmd}: rc=${_rc} (unchanged)"
        else
            _fail "${_case}" "software ${_p}: '${_cmd}' exited ${_rc:-?} where it exited ${_want_rc} before the jump"
        fi
    done
}

# v_abi <case>: the kernel module ledger.
# This is the question apk users get wrong every time: a kmod is built for one kernel,
# and a jump that changes the kernel leaves the module installed and unusable. It is not
# a FAIL -- nothing is broken that a reinstall does not fix -- so it is a FINDING that
# names the packages to reinstall.
v_abi() {
    _case=$1
    if ! pull "${SCEN_EVIDENCE}/packages.tsv"; then
        _fail "${_case}" "abi: ${SCEN_EVIDENCE}/packages.tsv is unreadable, so the kmod set is unknown"
        return 1
    fi
    _exp=${RDATA}
    _kver_before=$(printf '%s\n' "${_exp}" | awk -F'\t' '$1 == "kver" {print $2; exit}')
    _kver_now=$(kv "${PROBE}" kver)
    [ -n "${_kver_now}" ] || _kver_now=$(scen probe 2>/dev/null | sed -n 's/^kver=//p')

    _kmods=$(printf '%s\n' "${_exp}" | awk -F'\t' '$1 == "kmod" {print $2}')
    if [ -z "${_kmods}" ]; then
        _finding "no kernel module was installed, so the apk/kmod ABI question could not be answered"
        return 0
    fi

    _reinstall=""
    _matched=""
    for _k in ${_kmods}; do
        _line=$(scen kmodcheck "${_k}" 2>/dev/null | grep '^kmod=' | head -n 1)
        _state=$(kv "${_line}" state)
        _modver=$(kv "${_line}" modver)
        _depver=$(kv "${_line}" depver)
        _version=$(kv "${_line}" version)
        case "${_state}" in
            match)
                _matched="${_matched}${_k} "
                ev "abi ${_k}: matches ${_kver_now} (modver=${_modver} depver=${_depver})"
                ;;
            stale)
                _reinstall="${_reinstall}${_k} "
                _finding "${_k} ${_version} was built for kernel ${_modver}/${_depver} and the machine now runs ${_kver_now}: reinstall it (apk add --force-overwrite ${_k}) or the module will not load"
                ;;
            missing)
                _reinstall="${_reinstall}${_k} "
                _finding "${_k} is no longer installed after the jump: the kernel ABI changed and the package has to be reinstalled"
                ;;
            *)
                _reinstall="${_reinstall}${_k} "
                _finding "${_k}: apk reported neither a module directory nor a kernel dependency, so the match against ${_kver_now} is unknown; check with 'apk info -R ${_k}'"
                ;;
        esac
    done

    # The ledger is two lines: what the kernel did, and what has to be reinstalled because
    # of it. Both are printed whatever the verdict is, because the list is the answer the
    # user came for.
    _changed=0
    if [ -n "${_kver_before}" ] && [ "${_kver_before}" != "${_kver_now}" ]; then
        _changed=1
        ev "abi: kernel ${_kver_before} -> ${_kver_now}"
    else
        ev "abi: kernel unchanged (${_kver_now})"
    fi
    if [ -n "${_reinstall}" ]; then
        ev "abi: reinstall after this jump: ${_reinstall}"
    elif [ "${_changed}" = "1" ]; then
        ev "abi: the kernel changed but every installed kmod still matches it"
    else
        ev "abi: $(printf '%s' "${_matched}" | wc -w | tr -d ' ') kmod(s) matched"
    fi
    return 0
}

# v_platform <case>: the machine around the user's data is still whole.
v_platform() {
    _case=$1
    _line=$(dev_status) || _line=""
    if [ -z "${_line}" ]; then
        _fail "${_case}" "platform: ab-slot status is unreadable after the jump"
        return 1
    fi
    AB_STATUS_LINE=${_line}
    _check assert_field boot ok "${_case}"
    _check assert_field esp ok "${_case}"
    _check assert_field data ok "${_case}"
    _check assert_field p4 ok "${_case}"
    _check assert_field pending none "${_case}"

    _ov=$(scen overlay-probe 2>/dev/null | grep '^target=')
    case "$(kv "${_ov}" write)" in
        rw) ev "overlay: $(kv "${_ov}" target) is writable" ;;
        *) _fail "${_case}" "platform: $(kv "${_ov}" target) is not writable after the jump (${_ov:-no answer})" ;;
    esac

    _svcs=$(pull "${SCEN_EVIDENCE}/config.tsv" && printf '%s\n' "${RDATA}" | awk -F'\t' '$1 == "svc" {print $2}')
    [ -n "${_svcs:-}" ] || _svcs=${SCEN_SERVICES}
    for _s in ${_svcs}; do
        _out=$(scen svc-cycle "${_s}" 2>/dev/null | grep '^svc=' | head -n 1)
        case "${_out}" in
            *state=absent*) ev "service ${_s}: not present on this image" ;;
            *)
                if [ "$(kv "${_out}" stop)" = "0" ] && [ "$(kv "${_out}" start)" = "0" ]; then
                    ev "service ${_s}: stop/start ok"
                else
                    _fail "${_case}" "platform: /etc/init.d/${_s} stop/start failed (${_out})"
                fi
                ;;
        esac
    done
}

# --------------------------------------------------------------------------- #
# The hop (S3/S4): the same skeleton matrix.sh walks
# --------------------------------------------------------------------------- #

# scen_hop <case> <version> <phase>
#   phase=position  bring the machine to the version the case starts in; not a result
#   phase=ladder    the step under test
# Returns 0 ok, 1 failed, 2 payload missing, 20 refused before writing.
scen_hop() {
    _case=$1
    _version=$2
    _phase=$3
    _local="${PAYLOAD_DIR}/payload-${_version}.tar"
    _remote="${AB_REMOTE_TMP}/payload-${_version}.tar"

    if [ ! -f "${_local}" ]; then
        ev "payload missing: ${_local}"
        return 2
    fi

    require_healthy_committed "${_case}" || return 1
    _before=${STATUS_LINE}
    require_safe_target "${_case}" "${_before}" || return 1
    AB_STATUS_LINE=${_before}
    _gen=$(status_field "${_before}" generation) || return 1
    _slot=$(status_field "${_before}" slot) || return 1
    _target=$(other_slot "${_slot}") || return 1

    ev "${_phase} ${_version}: slot ${_slot} generation ${_gen}, target ${_target}"
    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_local}" "${_remote}" >/dev/null || return 1
    dev_capture "${AB_EVIDENCE_LOG}" dev_cleanup_slot_mounts >/dev/null
    ev "pre-check: /mnt/slots/* unmounted; --check may remount them, so their absence is not asserted"

    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ab_check "${_remote}")
    _rc=$?
    case "${_rc}" in
        0) : ;;
        74)
            ev "ab-upgrade --check refused ${_version} (exit 74): $(printf '%s' "${_out}" | grep -m 1 refused || printf 'no refusal line')"
            return 20
            ;;
        *)
            ev "ab-upgrade --check failed for ${_version} with exit ${_rc}"
            return 1
            ;;
    esac

    dev_capture "${AB_EVIDENCE_LOG}" dev_install "${_remote}" >/dev/null || return 1

    _after=$(dev_status) || return 1
    AB_STATUS_LINE=${_after}
    CASE_FAILED=0
    _check assert_field pending "${_target}" "${_case}"
    _check assert_ge "$(status_field "${_after}" generation || printf 0)" "$((_gen + 1))" "${_case}" generation
    [ "${CASE_FAILED}" -eq 0 ] || return 1

    dev_reboot
    if ! dev_wait_up_after after-install; then
        ev "wait_up: no answer within ${AB_WAIT_UP_FIRST}s after reboot (hard cap ${AB_WAIT_UP_HARD}s)"
        return 1
    fi
    # The machine just rebooted; whatever lives on tmpfs is gone. The helper is re-pushed
    # before the first judgement so a missing helper can never read as missing data.
    push_helper || { CASE_NOTE="helper could not be pushed again after the reboot"; return 1; }
    # PROBE carries the kernel the machine booted, so it has to be read again here: a
    # finding that says "the machine now runs <old kernel>" is worse than no finding.
    probe_machine || { CASE_NOTE="the machine did not answer the helper's probe after the reboot"; return 1; }
    if ! _booted=$(dev_wait_settled "${AB_WAIT_SETTLE}"); then
        ev "settle: no status line within ${AB_WAIT_SETTLE}s after the machine answered ssh"
        return 1
    fi
    AB_STATUS_LINE=${_booted}
    CASE_FAILED=0
    _check assert_field boot ok "${_case}"
    _check assert_field esp ok "${_case}"
    _check assert_field pending none "${_case}"
    _check assert_field committed "${_target}" "${_case}"
    _check assert_field slot "${_target}" "${_case}"
    _check assert_match "$(status_field "${_booted}" upper || printf '')" \
        "^@overlay-$(dev_version_re "${_version}")(-r[0-9]+)?\$" "${_case}" upper
    [ "${CASE_FAILED}" -eq 0 ] || return 1
    ev "hop ${_phase}: ${_version} committed on slot ${_target}, generation $((_gen + 1))"
    return 0
}

# require_prereq <case> <file> <what>: the cases after S1/S2 judge state that those cases
# left on the machine. Missing state is a GAP: there is nothing to judge, and guessing is
# worse than saying so.
require_prereq() {
    _case=$1
    _path=$2
    _what=$3
    _hint=${4:-run --case S1 and --case S2 first}
    if pull "${_path}"; then
        return 0
    fi
    CASE_NOTE="${_what} is not on the machine (${_path}): ${_hint}"
    ev "${CASE_NOTE}"
    return 2
}

# run_jump <case> <from> <to>
run_jump() {
    _case=$1
    _from=$2
    _to=$3
    require_healthy_committed "${_case}" || return 1
    AB_STATUS_LINE=${STATUS_LINE}

    if [ ! -f "${PAYLOAD_DIR}/payload-${_to}.tar" ]; then
        CASE_NOTE="no payload for ${_to} at ${PAYLOAD_DIR}/payload-${_to}.tar"
        ev "${CASE_NOTE}"
        return 2
    fi
    require_prereq "${_case}" "${SCEN_EVIDENCE}/packages.tsv" "the preinstall snapshot" || return $?
    require_prereq "${_case}" "${SCEN_EVIDENCE}/config.tsv" "the user configuration record" || return $?
    require_prereq "${_case}" "${SCEN_EVIDENCE}/data.sha256" "the data manifest" || return $?

    push_helper || { CASE_NOTE="helper could not be pushed"; return 1; }
    probe_machine || { CASE_NOTE="the machine did not answer the helper's probe"; return 1; }

    _running=$(dev_running_version) || _running=""
    if [ "${_running}" != "${_from}" ]; then
        ev "positioning: ${_running:-unknown} -> ${_from}"
        scen_hop "${_case}" "${_from}" position
        _pos_rc=$?
        if [ "${_pos_rc}" -ne 0 ] && driver_error_seen; then
            CASE_NOTE="driver error: the scenario helper did not answer while positioning the machine; the case did not start"
            return 1
        fi
        case "${_pos_rc}" in
            0) : ;;
            2) CASE_NOTE="no payload for the start version ${_from}"; return 2 ;;
            *) CASE_NOTE="positioning to ${_from} failed; the case did not start"; return 1 ;;
        esac
    fi

    ev "hop: ${_from} -> ${_to}"
    scen_hop "${_case}" "${_to}" ladder
    _hop_rc=$?
    if [ "${_hop_rc}" -ne 0 ] && driver_error_seen; then
        CASE_NOTE="driver error: the scenario helper did not answer during the jump; the machine was not judged"
        return 1
    fi
    case "${_hop_rc}" in
        0) : ;;
        2) CASE_NOTE="no payload for ${_to}"; return 2 ;;
        20) CASE_NOTE="the jump to ${_to} was refused with exit 74"; return 1 ;;
        *) CASE_NOTE="the jump to ${_to} did not commit"; return 1 ;;
    esac

    # The judgement: every check runs, so one broken thing does not hide the next.
    CASE_FAILED=0
    if driver_error_seen; then
        CASE_NOTE="driver error: the scenario helper did not answer after the reboot; the machine was not judged"
        return 1
    fi
    v_data "${_case}"
    v_config "${_case}"
    v_software "${_case}"
    v_abi "${_case}"
    v_platform "${_case}"
    if driver_error_seen; then
        CASE_NOTE="driver error: the scenario helper stopped answering during the judgement; the machine was not judged"
        return 1
    fi
    [ "${CASE_FAILED}" -eq 0 ] || { CASE_NOTE="the jump to ${_to} committed but the user's state did not survive"; return 1; }

    _files=$(pull "${SCEN_EVIDENCE}/data.sha256" && kv "${RDATA}" files)
    CASE_NOTE="${_from}->${_to} committed, data ${_files:-?} file(s) identical, config/software/services kept"
    return 0
}

# --------------------------------------------------------------------------- #
# S5: the ABI ledger on the kernel that is running now
# --------------------------------------------------------------------------- #

run_s5() {
    _case=S5
    require_healthy_committed "${_case}" || return 1
    AB_STATUS_LINE=${STATUS_LINE}
    require_prereq "${_case}" "${SCEN_EVIDENCE}/packages.tsv" "the preinstall snapshot" "run --case S1 first" || return $?
    push_helper || { CASE_NOTE="helper could not be pushed"; return 1; }
    probe_machine || { CASE_NOTE="the machine did not answer the helper's probe"; return 1; }

    CASE_FAILED=0
    if driver_error_seen; then
        CASE_NOTE="driver error: the scenario helper did not answer; the ledger was not read"
        return 1
    fi
    v_abi "${_case}"
    v_software "${_case}"
    v_platform "${_case}"
    if driver_error_seen; then
        CASE_NOTE="driver error: the scenario helper stopped answering while the ledger was read; the machine was not judged"
        return 1
    fi
    [ "${CASE_FAILED}" -eq 0 ] || { CASE_NOTE="the package set or the machine around it did not survive"; return 1; }

    _kver=$(kv "${PROBE}" kver)
    CASE_NOTE="ledger on kernel ${_kver}: every recorded package present, kmods checked against it"
    return 0
}

# --------------------------------------------------------------------------- #
# S6: does the boot toolchain travel with the update?
# --------------------------------------------------------------------------- #

# host_sha256 <file>: the digest on this side of the cable.
# The machine hashes its own files; the payload members are hashed here, and a laptop
# offers sha256sum, shasum or openssl depending on what it is.
host_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${1}" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${1}" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "${1}" 2>/dev/null | sed 's/.*= *//'
    else
        return 1
    fi
}

# payload_member_get <payload.tar> <member> <outfile>: one member, extracted here.
payload_member_get() {
    tar -xOf "${1}" "${2}" >"${3}" 2>/dev/null || return 1
    [ -s "${3}" ]
}

# payload_member_sha <payload.tar> <member>: the digest the payload's manifest claims.
# Read the same way ab-upgrade reads it (the JSON squeezed to one line, then one sed per
# member): a second, independent JSON parser here could disagree with the installer about
# what the payload says, and the whole point of S6 is comparing two independent statements.
payload_member_sha() {
    _manifest=$(tar -xOf "${1}" manifest.json 2>/dev/null) || return 1
    [ -n "${_manifest}" ] || return 1
    _squeezed=$(printf '%s' "${_manifest}" | tr -d ' \t\r\n')
    _member_re=$(printf '%s' "${2}" | sed 's/\./\\./g')
    printf '%s' "${_squeezed}" | sed -n 's/.*"'"${_member_re}"'":{"sha256":"\([^"]*\)".*/\1/p'
}

# payload_platform_tool_sha <payload.tar> <path>: the digest of one file inside the
# payload's platform.tar, found by the path the machine reported.
# platform.tar is built with `tar -C <dir> .`, so its members are ./usr/sbin/btrfs while
# the machine says /usr/sbin/btrfs; both spellings are accepted and nothing is guessed
# from a suffix match.
payload_platform_tool_sha() {
    _ptar="${_tmp}/s6-platform.tar"
    payload_member_get "${1}" platform.tar "${_ptar}" || return 1
    _want=$(printf '%s' "${2}" | sed 's|^\./||')
    _name=$(tar -tf "${_ptar}" 2>/dev/null \
        | grep -Fx -e "${_want}" -e "./${_want}" | head -n 1)
    [ -n "${_name}" ] || return 1
    tar -xOf "${_ptar}" "${_name}" >"${_tmp}/s6-platform-tool" 2>/dev/null || return 1
    host_sha256 "${_tmp}/s6-platform-tool"
}

# payload_platform_members <payload.tar>: the names inside platform.tar, for a failure
# message that says what the payload does carry instead of only what it lacks.
payload_platform_members() {
    _ptar="${_tmp}/s6-platform.tar"
    payload_member_get "${1}" platform.tar "${_ptar}" || return 1
    tar -tf "${_ptar}" 2>/dev/null | head -n 20
}

# s6_initramfs_members <payload.tar>: the member names inside the payload's initramfs.
# Best effort on purpose: the judgement is the digest comparison above, and this list is
# the ledger a person reads. A host without gzip or cpio says so and the runtime version
# lines from the machine (cmd_boottools) still stand.
s6_initramfs_members() {
    _icpio="${_tmp}/s6-initramfs.cpio.gz"
    payload_member_get "${1}" initramfs.cpio.gz "${_icpio}" || return 1
    command -v gzip >/dev/null 2>&1 || return 1
    command -v cpio >/dev/null 2>&1 || return 1
    gzip -dc "${_icpio}" 2>/dev/null | cpio -it 2>/dev/null | sed 's|^\./||'
}

# _version_gt <a> <b>: is a a newer dotted version than b.
# Field by field as integers. A field that is not a number (a -rN suffix, a tag) answers
# "no": a version that cannot be ordered must never be turned into a statement about
# which side is newer.
_version_gt() {
    _va=$1
    _vb=$2
    while [ -n "${_va}" ] || [ -n "${_vb}" ]; do
        _fa=${_va%%.*}
        _fb=${_vb%%.*}
        case "${_va}" in *.*) _va=${_va#*.} ;; *) _va="" ;; esac
        case "${_vb}" in *.*) _vb=${_vb#*.} ;; *) _vb="" ;; esac
        [ -n "${_fa}" ] || _fa=0
        [ -n "${_fb}" ] || _fb=0
        case "${_fa}" in "" | *[!0-9]*) return 1 ;; esac
        case "${_fb}" in "" | *[!0-9]*) return 1 ;; esac
        [ "${_fa}" -gt "${_fb}" ] && return 0
        [ "${_fa}" -lt "${_fb}" ] && return 1
    done
    return 1
}

# s6_same <case> <label> <path> <got> <want>: one digest comparison, both sides named.
# A missing "want" is not a mismatch: it means the payload's manifest says nothing about
# that member, which is a payload defect and cannot be judged from this side. A missing
# "path" is not a mismatch either -- the file the case was going to hash is not on the ESP
# at all, so the ESP listing from the probe (_bt, set by run_s6) is what the reader needs.
s6_same() {
    if [ -z "${5}" ]; then
        _fail "${1}" "${2}: the payload's manifest records no sha256 for it, so ${3} cannot be checked"
        return 1
    fi
    case "${3}" in
        "" | none)
            _fail "${1}" "${2}: nothing on the ESP answers to it (the probe listed $(kv "${_bt}" esp_list))"
            return 1
            ;;
    esac
    if [ "${4}" = "${5}" ]; then
        ev "${2}: ${3} sha256=${4} is the payload's"
        return 0
    fi
    _fail "${1}" "${2}: ${3} sha256=${4:-none} but the payload says ${5}"
    return 1
}

# run_s6: the boot chain against the payload it is supposed to come from.
# Read-only by construction: three digests and one execution, no install, no reboot, and
# the red line still comes first because even a read of the ESP is not a reason to treat
# a machine without a committed healthy slot as judgeable.
run_s6() {
    _case=S6
    require_healthy_committed "${_case}" || return 1
    AB_STATUS_LINE=${STATUS_LINE}
    _slot=$(status_field "${STATUS_LINE}" slot) || _slot=""
    case "${_slot}" in
        a | b) : ;;
        *)
            _fail "${_case}" "ab-slot status carries no slot: the boot files of the running slot cannot be named"
            return 1
            ;;
    esac

    _running=$(dev_running_version) || _running=""
    if [ -z "${_running}" ]; then
        _fail "${_case}" "ab-slot rootfs answered nothing: the version the boot tools should belong to is unknown"
        return 1
    fi
    _pver=${SCEN_S6_PAYLOAD:-${_running}}
    _payload="${PAYLOAD_DIR}/payload-${_pver}.tar"
    if [ ! -f "${_payload}" ]; then
        CASE_NOTE="no payload for ${_pver} at ${_payload}: the boot chain has nothing to be compared against"
        ev "${CASE_NOTE}"
        return 2
    fi

    push_helper || { CASE_NOTE="helper could not be pushed"; return 1; }
    probe_machine || { CASE_NOTE="the machine did not answer the helper's probe"; return 1; }
    if [ "$(kv "${PROBE}" hash)" != "sha256sum" ]; then
        CASE_NOTE="the machine answers with $(kv "${PROBE}" hash) and not sha256sum: the manifest records sha256, and two algorithms cannot be compared"
        ev "${CASE_NOTE}"
        return 2
    fi

    _bt=$(scen boottools "${_slot}" "${SCEN_ESP_DIR}" 2>/dev/null) || _bt=""
    if [ -z "${_bt}" ]; then
        _fail "${_case}" "the machine did not answer the boot chain probe"
        return 1
    fi
    # The whole answer, ledger lines included: the reader of a red S6 row needs the
    # version strings and the ESP listing, not a summary of them.
    {
        printf '### boottools %s slot=%s esp=%s\n' "$(dev_stamp)" "${_slot}" "${SCEN_ESP_DIR}"
        printf '%s\n' "${_bt}"
    } >>"${AB_EVIDENCE_LOG}"

    # 1. the ESP files against the payload's manifest: the mechanical judgement.
    _ksha=$(payload_member_sha "${_payload}" kernel.bin) || _ksha=""
    _isha=$(payload_member_sha "${_payload}" initramfs.cpio.gz) || _isha=""
    if [ -z "${_ksha}" ] && [ -z "${_isha}" ]; then
        CASE_NOTE="${_payload} carries no readable manifest.json (not a payload tar?), so its boot files cannot be named"
        ev "${CASE_NOTE}"
        return 2
    fi
    _check s6_same "${_case}" "kernel kernel.bin" "$(kv "${_bt}" kernel_path)" "$(kv "${_bt}" kernel_sha)" "${_ksha}"
    _check s6_same "${_case}" "initramfs initramfs.cpio.gz" "$(kv "${_bt}" initrd_path)" "$(kv "${_bt}" initrd_sha)" "${_isha}"

    # 2. the platform layer's tool: hashed against platform.tar and run once.
    _tpath=$(kv "${_bt}" tool_path)
    _tsrc=$(kv "${_bt}" tool_source)
    _trc=$(kv "${_bt}" tool_rc)
    _tver=$(printf '%s\n' "${_bt}" | sed -n 's/^tool_version=//p' | head -n 1)
    if [ -z "${_tpath}" ] || [ "${_tpath}" = none ]; then
        _fail "${_case}" "platform tool ${SCEN_PLATFORM_TOOL}: not on this machine, so the boot-time tooling cannot be the payload's"
    else
        if [ "${_trc}" != "0" ]; then
            # Present but not runnable is worse than missing: the boot hook and the health
            # check call it, and a slot that cannot run it never commits.
            _fail "${_case}" "platform tool ${_tpath} (${_tsrc}): '--version' exited ${_trc:-?}: $(printf '%s\n' "${_bt}" | sed -n 's/^tool_err=//p' | head -n 1)"
        else
            ev "platform tool ${_tpath} (${_tsrc}): ${_tver:-no version line}"
        fi
        _prel=$(printf '%s' "${_tpath}" | sed 's|^/||')
        _psha=$(payload_platform_tool_sha "${_payload}" "${_prel}") || _psha=""
        if [ -z "${_psha}" ]; then
            _fail "${_case}" "the payload's platform.tar carries no ${_prel}, so the tool on this machine is not the payload's: $(payload_platform_members "${_payload}" | tr '\n' ' ')"
        else
            _check s6_same "${_case}" "platform ${_prel}" "${_tpath}" "$(kv "${_bt}" tool_sha)" "${_psha}"
        fi
    fi

    # 3. the ledger: which tools, at which version, and where the tools say they come from.
    _members=$(s6_initramfs_members "${_payload}") || _members=""
    if [ -n "${_members}" ]; then
        _named=$(printf '%s\n' "${_members}" \
            | grep -E '(^|/)(busybox|sfdisk|partx|fdisk|mount|switch_root|ab-[a-z-]+)$' \
            | tr '\n' ' ')
        ev "initramfs of payload-${_pver}.tar: $(printf '%s\n' "${_members}" | grep -c . | tr -d ' ') member(s), boot tools: ${_named:-none from the list}"
    else
        ev "initramfs of payload-${_pver}.tar could not be listed here (no gzip/cpio, or not a cpio.gz): the runtime ledger from the machine stands"
    fi
    _tools_ver=$(printf '%s\n' "${_bt}" | sed -n 's/^release=//p' \
        | sed -n 's/.*UPSTREAM_VERSION=\([A-Za-z0-9._+-]*\).*/\1/p' | head -n 1)
    if [ -z "${_tools_ver}" ]; then
        _finding "the platform layer does not say which release it came from (no UPSTREAM_VERSION in $(kv "${_bt}" release_path)): the boot tools cannot be attributed to a payload"
    elif [ "${_tools_ver}" = "${_running}" ]; then
        ev "boot tools and rootfs both record ${_running}"
    elif _version_gt "${_tools_ver}" "${_running}"; then
        # Not a FAIL, and the reason is the design: the tools belong to the payload, the
        # rootfs belongs to the slot. A downgrade replaces the rootfs while the platform
        # layer that was built by a newer release can still be the one on the ESP and in
        # the layer; the initramfs is self-contained and byte-identical to the payload's
        # (checked above), so nothing is mis-assembled and nothing needs fixing. The user
        # is told once, in one line, which version boots their machine.
        _finding "boot tools come from ${_tools_ver} while the running rootfs is ${_running}"
    else
        ev "boot tools record ${_tools_ver}, the rootfs records ${_running} (tools older than the rootfs; recorded, not judged)"
    fi

    [ "${CASE_FAILED}" -eq 0 ] || {
        CASE_NOTE="the boot chain on slot ${_slot} is not the payload's"
        return 1
    }
    CASE_NOTE="slot ${_slot}: kernel, initramfs and ${SCEN_PLATFORM_TOOL} identical to payload-${_pver}.tar; boot tools from ${_tools_ver:-unknown}, rootfs ${_running}"
    return 0
}

# --------------------------------------------------------------------------- #
# S7: does a release's package source travel with its version
# --------------------------------------------------------------------------- #

# s7_kmods: the kernel modules this case tracks -- the kmod-* members of the S1 batch,
# because a kmod is the package whose ABI question a version jump actually asks.
s7_kmods() {
    for _p in ${SCEN_PKGS}; do
        case "${_p}" in
            kmod-*) printf '%s\n' "${_p}" ;;
        esac
    done
}

# s7_payload_kernel <payload.tar>: the kernel package the payload records, e.g.
# 6.12.103~0413601b1c3f0490e17f340fe09229ea-r1.
# Read the way the rest of the driver reads the manifest (squeezed to one line, one sed per
# field): a second JSON parser here could disagree with the installer about what the payload
# says, and this value is the cross-check for the kmods directory a feed list names.
s7_payload_kernel() {
    _pk_mf=$(tar -xOf "${1}" manifest.json 2>/dev/null) || return 1
    [ -n "${_pk_mf}" ] || return 1
    printf '%s' "${_pk_mf}" | tr -d ' \t\r\n' | sed -n 's/.*"kernel":"\([^"]*\)".*/\1/p'
}

# s7_feeds_render <version> <outfile>: the feed list that version's release ships, as bytes.
# Prints the source it used:
#   rootfs    payload-<version>.tar's rootfs.tar.gz carried
#             /etc/apk/repositories.d/distfeeds.list, which is copied out verbatim
#   manifest  rebuilt from the kernel package the manifest records, because the rootfs could
#             not be unpacked here; that is enough to name the kmods directory
#   none      no payload, or a payload carrying neither, and the case cannot start
# The rootfs is the primary source because the alternative -- assembling URLs from a version
# string -- has to guess the kmods directory name <kernel>-1-<hash>, and the guess would be
# this driver's rather than the release's. The list is also not derived from the version in
# the file name: a release's rootfs can name another release's feeds (25.12.3's names
# 25.12.2's, measured), and that is a fact about the release, not an error to correct.
s7_feeds_render() {
    _fr_v=$1
    _fr_out=$2
    _fr_p="${PAYLOAD_DIR}/payload-${_fr_v}.tar"
    : >"${_fr_out}"
    [ -f "${_fr_p}" ] || { printf 'none\n'; return 1; }

    _fr_tgz="${_tmp}/s7-rootfs-${_fr_v}.tar.gz"
    if payload_member_get "${_fr_p}" rootfs.tar.gz "${_fr_tgz}"; then
        _fr_member=$(tar -tzf "${_fr_tgz}" 2>/dev/null \
            | grep -E '(^|/)etc/apk/repositories\.d/distfeeds\.list$' | head -n 1)
        if [ -n "${_fr_member}" ]; then
            tar -xOf "${_fr_tgz}" "${_fr_member}" >"${_fr_out}" 2>/dev/null
        fi
    fi
    if [ -s "${_fr_out}" ]; then printf 'rootfs\n'; return 0; fi

    _fr_k=$(s7_payload_kernel "${_fr_p}") || _fr_k=""
    if [ -n "${_fr_k}" ]; then
        _fr_kver=${_fr_k%%~*}
        _fr_hash=${_fr_k#*~}
        _fr_hash=${_fr_hash%%-*}
        if [ -n "${_fr_kver}" ] && [ -n "${_fr_hash}" ] && [ "${_fr_hash}" != "${_fr_k}" ]; then
            # One line per index *file*, which is the shape the release's own list has, and
            # exactly the feeds the S1 batch can come from: the store's apps, the plain
            # packages, the target's own packages and the kmods of this payload's kernel.
            {
                printf '%s/releases/%s/packages/x86_64/packages/packages.adb\n' \
                    "${SCEN_S7_FEED_BASE}" "${_fr_v}"
                printf '%s/releases/%s/packages/x86_64/base/packages.adb\n' \
                    "${SCEN_S7_FEED_BASE}" "${_fr_v}"
                printf '%s/releases/%s/packages/x86_64/luci/packages.adb\n' \
                    "${SCEN_S7_FEED_BASE}" "${_fr_v}"
                printf '%s/releases/%s/targets/x86/64/packages/packages.adb\n' \
                    "${SCEN_S7_FEED_BASE}" "${_fr_v}"
                printf '%s/releases/%s/targets/x86/64/kmods/%s-1-%s/packages.adb\n' \
                    "${SCEN_S7_FEED_BASE}" "${_fr_v}" "${_fr_kver}" "${_fr_hash}"
            } >"${_fr_out}"
            printf 'manifest\n'
            return 0
        fi
    fi
    : >"${_fr_out}"
    printf 'none\n'
    return 1
}

# s7_feed_of <feed list> <packages|targets|kmods>: the line of one kind, or "none".
# Matched on the release layout rather than on the host name, so a mirror's list reads the
# same way as the upstream one.
s7_feed_of() {
    case "${2}" in
        packages) _fo_pat='/packages/x86_64/packages/' ;;
        targets) _fo_pat='/targets/x86/64/packages/' ;;
        kmods) _fo_pat='/targets/x86/64/kmods/' ;;
        *)
            printf 'none\n'
            return 1
            ;;
    esac
    _fo_line=$(grep -F "${_fo_pat}" "${1}" 2>/dev/null | head -n 1)
    printf '%s\n' "${_fo_line:-none}"
}

# s7_feeds_write <local feed list>: put those bytes on the machine as its feed list and read
# them back. An unverified write is a write that can silently not have happened, and the whole
# case rests on knowing which list the machine is really using.
s7_feeds_write() {
    _fw_src=$1
    _fw_remote="${AB_REMOTE_TMP}/$(basename "${_fw_src}")"
    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_fw_src}" "${_fw_remote}" >/dev/null || return 1
    _fw_out=$(scen exec cp "${_fw_remote}" "${SCEN_S7_FEEDS}" 2>/dev/null | grep '^cmd=' | head -n 1)
    if [ "$(kv "${_fw_out}" rc)" != "0" ]; then
        ev "feed write failed: ${_fw_out:-no answer}"
        return 1
    fi
    if ! dev_collect "${SCEN_S7_FEEDS}" "${_tmp}/s7-feeds-verify.list"; then
        ev "feed write: ${SCEN_S7_FEEDS} is not readable afterwards"
        return 1
    fi
    if ! cmp -s "${_fw_src}" "${_tmp}/s7-feeds-verify.list"; then
        ev "feed write: ${SCEN_S7_FEEDS} did not take the bytes of ${_fw_src}"
        return 1
    fi
    printf '%s\n' "${_fw_out}"
}

# s7_restore <backup file>: the machine's own feed list back, compared byte for byte with the
# copy taken before the first write. Copying is not proof; the comparison is.
s7_restore() {
    _rs_bf=$1
    _rs_out=$(scen exec cp "${_rs_bf}" "${SCEN_S7_FEEDS}" 2>/dev/null | grep '^cmd=' | head -n 1)
    [ "$(kv "${_rs_out}" rc)" = "0" ] || return 1
    dev_collect "${SCEN_S7_FEEDS}" "${_tmp}/s7-feeds-restored.list" || return 1
    cmp -s "${_tmp}/s7-feeds-original.list" "${_tmp}/s7-feeds-restored.list" || return 1
    return 0
}

# s7_restore_or_warn <backup file>: put the list back and record which of the two happened.
# Used by the paths that stop before step 6 has judged the install: the machine is left with
# its own feeds either way, and a restore that failed is named here rather than implied.
s7_restore_or_warn() {
    if s7_restore "${1}"; then
        ev "feeds restored"
    else
        ev "feeds were NOT restored: put ${1} back by hand"
    fi
}

# s7_installed_version <installed list> <name>: the <name>-<version> token apk printed for
# that package, empty when apk does not have it.
# The name is matched literally and the rest of the token has to start with a digit, so that
# kmod-usb-storage-extras cannot answer for kmod-usb-storage and a package name carrying a
# regex metacharacter is not read as a pattern.
s7_installed_version() {
    awk -v n="${2}" '
        index($1, n "-") == 1 && substr($1, length(n) + 2) ~ /^[0-9]/ { print $1; exit }
    ' "${1}" 2>/dev/null
}

s7_installed_has() {
    [ -n "$(s7_installed_version "${1}" "${2}")" ]
}

# s7_snapshot <a|b> <prefix>: what apk has, in two files.
#   <prefix>.installed  the full installed set exactly as apk printed it
#   <prefix>.tsv        one row per fact: phase, kver, feed, pkg, kmod, installed count
# The packages of the S1 batch are recorded even when nothing about them changed: "htop is
# still 3.5.3-r1" is the answer to "is the user-space side the same on both releases", and a
# snapshot that only carried differences could not say it.
s7_snapshot() {
    _sn_ph=$1
    _sn_pre=$2
    _sn_kver=$(kv "${PROBE}" kver)
    [ -n "${_sn_kver}" ] || _sn_kver=unknown
    _sn_remote="${SCEN_EVIDENCE}/s7-${_sn_ph}-installed.txt"
    _sn_snap=$(scen pkgsnap "${_sn_remote}" 2>/dev/null | grep '^snap=') || _sn_snap=""
    if ! dev_collect "${_sn_remote}" "${_sn_pre}.installed"; then
        ev "snapshot ${_sn_ph}: ${_sn_remote} could not be read back from the machine"
        return 1
    fi
    {
        printf 'phase\t%s\t%s\n' "${_sn_ph}" "$(dev_stamp)"
        printf 'kver\t%s\n' "${_sn_kver}"
        printf 'installed\t%s\tcount=%s\n' "${_sn_remote}" "$(kv "${_sn_snap}" count)"
    } >"${_sn_pre}.tsv"
    if dev_collect "${SCEN_S7_FEEDS}" "${_sn_pre}.feeds"; then
        while IFS= read -r _sn_f; do
            [ -n "${_sn_f}" ] || continue
            printf 'feed\t%s\n' "${_sn_f}"
        done <"${_sn_pre}.feeds" >>"${_sn_pre}.tsv"
    fi
    for _sn_p in ${SCEN_PKGS}; do
        _sn_line=$(scen pkgcheck "${_sn_p}" 2>/dev/null | grep '^pkg=' | head -n 1)
        printf 'pkg\t%s\t%s\tpresent=%s\n' "${_sn_p}" \
            "$(kv "${_sn_line}" version)" "$(kv "${_sn_line}" present)" >>"${_sn_pre}.tsv"
    done
    for _sn_k in $(s7_kmods); do
        _sn_line=$(scen kmodcheck "${_sn_k}" 2>/dev/null | grep '^kmod=' | head -n 1)
        printf 'kmod\t%s\t%s\tmodver=%s\tdepver=%s\tstate=%s\n' "${_sn_k}" \
            "$(kv "${_sn_line}" version)" "$(kv "${_sn_line}" modver)" \
            "$(kv "${_sn_line}" depver)" "$(kv "${_sn_line}" state)" >>"${_sn_pre}.tsv"
    done
    return 0
}

# s7_diff <a-prefix> <b-prefix>: the table, one row per package.
#   version-changed | disappeared | new   from the two full installed sets
#   same                                  for the packages of the S1 batch, always printed
#   unchanged                             one summary row for the rest of the machine
# A package name is the token with the trailing -<version>-r<release> removed; that is the
# only way to compare two apk indexes that spell the version differently, and it needs no
# knowledge of any particular package.
s7_diff() {
    _df_a=$1
    _df_b=$2
    awk '
        function pkgname(s) { sub(/-[0-9][^-]*-r[0-9]+$/, "", s); return s }
        FNR == NR { n = $1; a[pkgname(n)] = n; next }
        { n = $1; b[pkgname(n)] = n }
        END {
            for (k in a) {
                if (!(k in b)) { printf "disappeared\t%s\t%s\t-\n", k, a[k]; continue }
                if (a[k] != b[k]) { printf "version-changed\t%s\t%s\t%s\n", k, a[k], b[k]; continue }
                same++
            }
            for (k in b) if (!(k in a)) printf "new\t%s\t-\t%s\n", k, b[k]
            printf "unchanged\t(all other packages)\t%s\t%s\n", same + 0, same + 0
        }
    ' "${_df_a}.installed" "${_df_b}.installed" | LC_ALL=C sort
    for _df_p in ${SCEN_PKGS}; do
        _df_va=$(awk -F'\t' -v n="${_df_p}" '$1 == "pkg" && $2 == n { print $3 }' "${_df_a}.tsv")
        _df_vb=$(awk -F'\t' -v n="${_df_p}" '$1 == "pkg" && $2 == n { print $3 }' "${_df_b}.tsv")
        if [ "${_df_va}" = "${_df_vb}" ]; then
            printf 'same\t%s\t%s\t%s\n' "${_df_p}" "${_df_va:-none}" "${_df_vb:-none}"
        else
            printf 'version-changed\t%s\t%s\t%s\n' "${_df_p}" "${_df_va:-none}" "${_df_vb:-none}"
        fi
    done
}

# run_s7: two snapshots of the same machine, one per version, both installed from that
# version's own release feeds.
#
# Six steps, each judged on its own:
#   1. back up the feed list (nothing else is touched until that copy exists)
#   2. write the from version's feed list, apk update, install the S1 batch, snapshot A
#   3. jump to the to version (scen_hop, the same skeleton S3/S4 walk), snapshot B
#   4. diff A against B, one row per package, and the kernel dependency each kmod carries
#   5. read the feed list again: which version's feeds is the machine on now
#   6. align to the to version's feeds, install one thing that really changes, restore the
#      backup and prove the restore
# The verdicts: PASS when both snapshots exist, the table was built, the did-not-follow
# finding was recorded, one aligned install changed something and the feed list is back;
# FAIL when the jump fails (scen_hop's own rule), a snapshot cannot be taken, nothing
# installs from an aligned feed, or the feed list cannot be restored; GAP when a payload is
# missing, the machine has no apk, has no /data to keep the backup on, or cannot reach its
# own release feeds at all.
run_s7() {
    _case=S7
    require_healthy_committed "${_case}" || return 1
    AB_STATUS_LINE=${STATUS_LINE}

    _from=${SCEN_LOW}
    _to=${SCEN_HIGH}
    if [ "${_from}" = "${_to}" ]; then
        CASE_NOTE="the two ends of the jump are the same version (${_from}): there is no across-version comparison to make"
        ev "${CASE_NOTE}"
        return 2
    fi
    _feeds_from="${_tmp}/s7-feeds-${_from}.list"
    _feeds_to="${_tmp}/s7-feeds-${_to}.list"
    _src_from=$(s7_feeds_render "${_from}" "${_feeds_from}") || _src_from=none
    _src_to=$(s7_feeds_render "${_to}" "${_feeds_to}") || _src_to=none
    if [ "${_src_from}" = "none" ]; then
        CASE_NOTE="no feed list for ${_from}: ${PAYLOAD_DIR}/payload-${_from}.tar is missing or carries no readable rootfs feed list, so there is nothing to point the machine at"
        ev "${CASE_NOTE}"
        return 2
    fi
    if [ "${_src_to}" = "none" ]; then
        CASE_NOTE="no feed list for ${_to}: ${PAYLOAD_DIR}/payload-${_to}.tar is missing or carries no readable rootfs feed list, so there is nothing to align to after the jump"
        ev "${CASE_NOTE}"
        return 2
    fi
    ev "feeds source: ${_from} from ${_src_from}, ${_to} from ${_src_to}"
    for _sv in "${_from}" "${_to}"; do
        case "${_sv}" in
            "${_from}") _sv_file=${_feeds_from} ;;
            *) _sv_file=${_feeds_to} ;;
        esac
        ev "feed ${_sv} 1/3 packages: $(s7_feed_of "${_sv_file}" packages)"
        ev "feed ${_sv} 2/3 targets: $(s7_feed_of "${_sv_file}" targets)"
        ev "feed ${_sv} 3/3 kmods: $(s7_feed_of "${_sv_file}" kmods)"
    done

    push_helper || { CASE_NOTE="helper could not be pushed"; return 1; }
    probe_machine || { CASE_NOTE="the machine did not answer the helper's probe"; return 1; }
    if [ "$(kv "${PROBE}" apk)" != "yes" ]; then
        CASE_NOTE="no apk on this image: there is no package source to align or compare"
        ev "${CASE_NOTE}"
        return 2
    fi
    if [ "$(kv "${PROBE}" data)" != "mounted" ]; then
        CASE_NOTE="/data is not mounted: the backup of the feed list has nowhere to live, so the file could not be put back"
        ev "${CASE_NOTE}"
        return 2
    fi
    scen mkdirs "${SCEN_EVIDENCE}" "${SCEN_BACKUP}" >/dev/null 2>&1

    # Position first: "the from version's own feeds" only means something when the machine
    # runs the from version, because its kmods index is built for that kernel.
    _running=$(dev_running_version) || _running=""
    if [ "${_running}" != "${_from}" ]; then
        ev "positioning: ${_running:-unknown} -> ${_from}"
        scen_hop "${_case}" "${_from}" position
        case "$?" in
            0) : ;;
            2)
                CASE_NOTE="no payload for the start version ${_from}"
                ev "${CASE_NOTE}"
                return 2
                ;;
            *)
                CASE_NOTE="positioning to ${_from} failed; the case did not start"
                ev "${CASE_NOTE}"
                return 1
                ;;
        esac
    fi

    # --- 1. the file this case is about ---------------------------------- #
    # Two copies for two different jobs: one on the machine's /data, which a person can put
    # back by hand if the run dies mid-case, and one here, which step 6 compares against so
    # that "restored" is a byte comparison and not a claim.
    if ! dev_collect "${SCEN_S7_FEEDS}" "${_tmp}/s7-feeds-original.list"; then
        CASE_NOTE="${SCEN_S7_FEEDS} is not readable on this machine: there is no feed list to align or restore"
        ev "${CASE_NOTE}"
        return 2
    fi
    _stamp=$(dev_stamp | tr ':' '-')
    _bak="${SCEN_BACKUP}/s7-feeds-${_stamp}"
    _bo=$(scen cfg-backup "${_bak}" "${SCEN_S7_FEEDS}" 2>/dev/null)
    _bakf=$(printf '%s\n' "${_bo}" | sed -n 's/^backup=.* -> \(.*\) ok=yes$/\1/p' | head -n 1)
    if [ "$(kv "${_bo}" backups)" != "1" ] || [ -z "${_bakf}" ]; then
        CASE_NOTE="the feed list could not be backed up ($(printf '%s' "${_bo}" | tr '\n' ' ')): nothing else is changed"
        _fail "${_case}" "${CASE_NOTE}"
        return 1
    fi
    ev "backup: ${SCEN_S7_FEEDS} -> ${_bakf}"

    # --- 2. the from version's own feeds, and the S1 batch --------------- #
    if ! _w=$(s7_feeds_write "${_feeds_from}"); then
        CASE_NOTE="the ${_from} feed list could not be written to ${SCEN_S7_FEEDS}, so the machine keeps the feeds it had"
        _fail "${_case}" "${CASE_NOTE}"
        return 1
    fi
    ev "feeds now ${_from}'s: ${_w}"
    _upd=$(scen exec apk update 2>/dev/null | grep '^cmd=' | head -n 1)
    if [ "$(kv "${_upd}" rc)" != "0" ]; then
        CASE_NOTE="apk update failed on ${_from}'s own feeds (rc=$(kv "${_upd}" rc): $(printf '%s' "${_upd}" | sed -n 's/.* out=//p')): this machine cannot reach its release feeds, so the package source cannot be judged"
        ev "${CASE_NOTE}"
        s7_restore_or_warn "${_bakf}"
        return 2
    fi

    _inst=0
    _unavail=""
    for _p in ${SCEN_PKGS}; do
        _line=$(scen pkginstall "${_p}" 2>/dev/null | grep '^pkg=' | head -n 1)
        case "$(kv "${_line}" state)" in
            installed)
                _inst=$((_inst + 1))
                ev "install ${_p}: $(kv "${_line}" version) from ${_from}'s feeds"
                ;;
            *)
                _err=$(printf '%s' "${_line}" | sed -n 's/.* err=//p' | cut -c1-60)
                _unavail="${_unavail}${_p}($(kv "${_line}" rc):${_err:-no-error-line}) "
                ev "install ${_p}: unavailable $(kv "${_line}" rc) ${_err:-no error line}"
                ;;
        esac
    done
    if [ "${_inst}" -eq 0 ]; then
        CASE_NOTE="not one package of the S1 batch could be installed from ${_from}'s own feeds: unavailable ${_unavail}"
        _fail "${_case}" "${CASE_NOTE}"
        s7_restore_or_warn "${_bakf}"
        return 1
    fi

    if ! s7_snapshot a "${_tmp}/s7-a"; then
        CASE_NOTE="snapshot A (what apk has on ${_from}) could not be taken, so there is nothing to compare against"
        _fail "${_case}" "${CASE_NOTE}"
        s7_restore_or_warn "${_bakf}"
        return 1
    fi
    cp "${_tmp}/s7-a.tsv" "${EVIDENCE_DIR}/s7-snapshot-a.tsv" 2>/dev/null || true
    cp "${_tmp}/s7-a.installed" "${EVIDENCE_DIR}/s7-installed-a.txt" 2>/dev/null || true
    _n_a=$(wc -l <"${_tmp}/s7-a.installed" | tr -d ' ')
    ev "snapshot A: ${_n_a} installed package(s), kver=$(kv "${PROBE}" kver)"

    # --- 3. the jump, then the same snapshot on the other version -------- #
    ev "hop: ${_from} -> ${_to}"
    scen_hop "${_case}" "${_to}" ladder
    case "$?" in
        0) : ;;
        2)
            CASE_NOTE="no payload for ${_to}"
            ev "${CASE_NOTE}"
            s7_restore_or_warn "${_bakf}"
            return 2
            ;;
        20)
            CASE_NOTE="the jump to ${_to} was refused with exit 74; the feed list was put back"
            _fail "${_case}" "${CASE_NOTE}"
            s7_restore_or_warn "${_bakf}"
            return 1
            ;;
        *)
            CASE_NOTE="the jump to ${_to} did not commit; the feed list was put back"
            _fail "${_case}" "${CASE_NOTE}"
            s7_restore_or_warn "${_bakf}"
            return 1
            ;;
    esac
    if driver_error_seen; then
        CASE_NOTE="driver error: the scenario helper did not answer after the reboot; the second snapshot was not taken"
        ev "${CASE_NOTE}"
        s7_restore_or_warn "${_bakf}"
        return 1
    fi
    if ! s7_snapshot b "${_tmp}/s7-b"; then
        CASE_NOTE="snapshot B (what apk has after the jump to ${_to}) could not be taken, so there is nothing to compare against"
        _fail "${_case}" "${CASE_NOTE}"
        s7_restore_or_warn "${_bakf}"
        return 1
    fi
    cp "${_tmp}/s7-b.tsv" "${EVIDENCE_DIR}/s7-snapshot-b.tsv" 2>/dev/null || true
    cp "${_tmp}/s7-b.installed" "${EVIDENCE_DIR}/s7-installed-b.txt" 2>/dev/null || true
    _n_b=$(wc -l <"${_tmp}/s7-b.installed" | tr -d ' ')
    _kver_a=$(awk -F'\t' '$1 == "kver" { print $2 }' "${_tmp}/s7-a.tsv")
    _kver_b=$(awk -F'\t' '$1 == "kver" { print $2 }' "${_tmp}/s7-b.tsv")
    ev "snapshot B: ${_n_b} installed package(s), kver=${_kver_b}"

    # --- 4. the table ---------------------------------------------------- #
    _diff=$(s7_diff "${_tmp}/s7-a" "${_tmp}/s7-b")
    {
        printf '### s7 snapshot diff A(%s kver=%s) vs B(%s kver=%s)\n' \
            "${_from}" "${_kver_a}" "${_to}" "${_kver_b}"
        printf 'status\tpackage\tA\tB\n'
        printf '%s\n' "${_diff}"
    } >>"${AB_EVIDENCE_LOG}"
    _n_chg=$(printf '%s\n' "${_diff}" | grep -c '^version-changed' || true)
    _n_gone=$(printf '%s\n' "${_diff}" | grep -c '^disappeared' || true)
    _n_new=$(printf '%s\n' "${_diff}" | grep -c '^new' || true)
    _n_unchanged=$(printf '%s\n' "${_diff}" | awk -F'\t' '$1 == "unchanged" { print $3 }')
    ev "diff: ${_n_chg} version change(s), ${_n_gone} disappeared, ${_n_new} new, ${_n_unchanged:-0} unchanged"

    # A package of the S1 batch that vanished is recorded here and judged by S3/S4: those
    # cases own "the user's software survived", and S7 owns "the package source follows the
    # version". Two verdicts on one fact would make the row unreadable.
    for _p in $(printf '%s\n' "${_diff}" | awk -F'\t' '$1 == "disappeared" { print $2 }'); do
        case " ${SCEN_PKGS} " in
            *" ${_p} "*) _finding "${_p} is gone from apk's database after the jump: S7 records it, the verdict on it belongs to S3/S4" ;;
        esac
    done

    # The ABI half: a kmod records the kernel it was built for as a package dependency, and
    # that dependency does not move when the machine changes slot. This is the same finding
    # S3/S4/S5 report, here with both sides of the jump in one line.
    _kmod_first=$(s7_kmods | head -n 1)
    _dep_b=""
    for _k in $(s7_kmods); do
        _kver_dep_a=$(awk -F'\t' -v n="${_k}" '$1 == "kmod" && $2 == n { print $5 }' "${_tmp}/s7-a.tsv" | sed 's/^depver=//')
        _dep_b=$(awk -F'\t' -v n="${_k}" '$1 == "kmod" && $2 == n { print $5 }' "${_tmp}/s7-b.tsv" | sed 's/^depver=//')
        _ver_a=$(awk -F'\t' -v n="${_k}" '$1 == "kmod" && $2 == n { print $3 }' "${_tmp}/s7-a.tsv")
        _ver_b=$(awk -F'\t' -v n="${_k}" '$1 == "kmod" && $2 == n { print $3 }' "${_tmp}/s7-b.tsv")
        ev "kmod ${_k}: ${_ver_a:-none} (kernel dependency ${_kver_dep_a:-none}) -> ${_ver_b:-none} (${_dep_b:-none}), running kernel ${_kver_b}"
        if [ -n "${_dep_b}" ] && [ "${_dep_b}" != "${_kver_b}" ]; then
            _finding "${_k} is built for kernel ${_dep_b} and the machine now runs ${_kver_b}: nothing reinstalls it during a jump, and apk's world file keeps pinning the old kernel, so it has to come from the running version's own kmods feed"
        fi
    done

    # --- 5. which version's feeds is the machine on now ------------------ #
    _after_feeds="${_tmp}/s7-feeds-after.list"
    if ! dev_collect "${SCEN_S7_FEEDS}" "${_after_feeds}"; then
        CASE_NOTE="${SCEN_S7_FEEDS} is not readable after the jump, so the feed list this case is about cannot be judged"
        _fail "${_case}" "${CASE_NOTE}"
        return 1
    fi
    if cmp -s "${_after_feeds}" "${_feeds_from}"; then
        _feeds_state="still ${_from}'s"
        _finding "the package source did not follow the version: after the jump to ${_to}, ${SCEN_S7_FEEDS} still names ${_from}'s feeds (ab-upgrade keeps it as user configuration), so the kmods index in use is $(s7_feed_of "${_after_feeds}" kmods) while the machine runs kernel ${_kver_b}"
    elif cmp -s "${_after_feeds}" "${_feeds_to}"; then
        _feeds_state="${_to}'s"
        ev "feeds after the jump: ${SCEN_S7_FEEDS} names ${_to}'s feeds"
    else
        _feeds_state="neither ${_from}'s nor ${_to}'s"
        _finding "the package source did not follow the version: after the jump to ${_to}, ${SCEN_S7_FEEDS} is neither ${_from}'s nor ${_to}'s release list (someone edited it): first line $(sed -n '1p' "${_after_feeds}")"
    fi
    ev "feeds after the jump: ${_feeds_state}"

    # --- 6. the other direction: does an install work at all ------------- #
    # Aligning the feeds to the version now running is what separates "the source was
    # wrong" from "the package is wrong". An install only counts when it changed something:
    # apk answers rc=0 and does nothing for a package it already has (measured), and a
    # verdict built on that rc would be a false PASS.
    if ! _w=$(s7_feeds_write "${_feeds_to}"); then
        CASE_NOTE="the ${_to} feed list could not be written to ${SCEN_S7_FEEDS}, so no install could be aimed at it"
        _fail "${_case}" "${CASE_NOTE}"
        s7_restore_or_warn "${_bakf}"
        return 1
    fi
    ev "feeds now ${_to}'s: ${_w}"
    _upd=$(scen exec apk update 2>/dev/null | grep '^cmd=' | head -n 1)
    if [ "$(kv "${_upd}" rc)" != "0" ]; then
        CASE_NOTE="apk update failed on ${_to}'s own feeds (rc=$(kv "${_upd}" rc)): the aligned feed could not be refreshed"
        _fail "${_case}" "${CASE_NOTE}"
        s7_restore_or_warn "${_bakf}"
        return 1
    fi

    _cands=${_kmod_first}
    for _f in ${SCEN_S7_FRESH_PKGS}; do
        s7_installed_has "${_tmp}/s7-b.installed" "${_f}" && continue
        _cands="${_cands} ${_f}"
        break
    done
    _proved=""
    _proved_ver=""
    _kmod_state=""
    _kmod_err=""
    for _p in ${_cands}; do
        _before=$(s7_installed_version "${_tmp}/s7-b.installed" "${_p}")
        _line=$(scen pkginstall "${_p}" 2>/dev/null | grep '^pkg=' | head -n 1)
        _state=$(kv "${_line}" state)
        _ver=$(kv "${_line}" version)
        _err=$(printf '%s' "${_line}" | sed -n 's/.* err=//p' | cut -c1-60)
        _changed=no
        if [ "${_state}" = "installed" ] && { [ -z "${_before}" ] || [ "${_before}" != "${_ver}" ]; }; then
            _changed=yes
        fi
        ev "aligned install ${_p}: state=${_state} before=${_before:-not-installed} after=${_ver:-none} changed=${_changed} ${_err}"
        if [ "${_p}" = "${_kmod_first}" ]; then
            _kmod_state=${_state}
            _kmod_err=${_err:-no-error-line}
        fi
        if [ "${_changed}" = "yes" ]; then
            _proved=${_p}
            _proved_ver=${_ver}
            break
        fi
    done

    if ! s7_restore "${_bakf}"; then
        CASE_NOTE="${SCEN_S7_FEEDS} could not be restored from ${_bakf}: the machine is left on ${_to}'s feeds and has to be put back by hand"
        _fail "${_case}" "${CASE_NOTE}"
        return 1
    fi
    ev "feeds restored: ${SCEN_S7_FEEDS} is byte-identical to the backup taken in step 1"

    if [ -z "${_proved}" ]; then
        CASE_NOTE="not one package could be installed from ${_to}'s own feeds after aligning them (tried: ${_cands}): the feed is not what fails, an install from it is"
        _fail "${_case}" "${CASE_NOTE}"
        return 1
    fi
    if [ -n "${_kmod_first}" ] && [ "${_proved}" != "${_kmod_first}" ]; then
        _finding "${_kmod_first} was not replaced from ${_to}'s kmods feed (${_kmod_state:-not-tried}: ${_kmod_err:-no error line}) while ${_proved} installed: the world file apk carries still constrains the kernel, so the kmod is served by the aligned feed and refused by the world"
    fi

    [ "${CASE_FAILED}" -eq 0 ] || return 1
    CASE_NOTE="${_from}->${_to}: A ${_n_a} / B ${_n_b} installed package(s), diff ${_n_chg} version change(s), ${_n_gone} disappeared, ${_n_new} new (${_n_unchanged:-0} unchanged), kernel ${_kver_a:-?}->${_kver_b:-?}; feeds after the jump ${_feeds_state}; aligned ${_to} feeds install ${_proved} (${_proved_ver:-unknown}); ${SCEN_S7_FEEDS} restored"
    return 0
}

# --------------------------------------------------------------------------- #
# Cases
# --------------------------------------------------------------------------- #

# scen_case <case>: 0 PASS, 1 FAIL, 2 GAP; the note and the findings land in the globals.
scen_case() {
    _case=$1
    CASE_NOTE=""
    CASE_FINDINGS=""
    CASE_FAILED=0
    mkdir -p "${EVIDENCE_DIR}" || { CASE_NOTE="cannot create ${EVIDENCE_DIR}"; return 1; }
    AB_EVIDENCE_LOG="${EVIDENCE_DIR}/$(date -u +%Y%m%d)-$(printf '%s' "${_case}" | tr 'A-Z' 'a-z').log"
    SCEN_CMD="$0 --case ${_case}"
    export AB_EVIDENCE_LOG SCEN_CMD AB_SCEN_DATA_DIR AB_SCEN_HELPER
    : >"${AB_EVIDENCE_LOG}"
    ev "case=${_case} $(case_label "${_case}")"

    case "${_case}" in
        S1) run_s1 ;;
        S2) run_s2 ;;
        S3) run_jump S3 "${SCEN_LOW}" "${SCEN_HIGH}" ;;
        S4) run_jump S4 "${SCEN_HIGH}" "${SCEN_LOW}" ;;
        S5) run_s5 ;;
        S6) run_s6 ;;
        S7) run_s7 ;;
        *) CASE_NOTE="unknown case"; return 1 ;;
    esac
}

case_label() {
    case "${1}" in
        S1) printf 'preinstall: packages and kmods, snapshotted\n' ;;
        S2) printf 'userdata: files, uci config, hostname, timezone, net section, firewall rule\n' ;;
        S3) printf 'up: %s -> %s, then judge data/config/software/abi/mounts\n' "${SCEN_LOW}" "${SCEN_HIGH}" ;;
        S4) printf 'down: %s -> %s, same judgement\n' "${SCEN_HIGH}" "${SCEN_LOW}" ;;
        S5) printf 'abi: kernel module ledger on the running kernel\n' ;;
        S6) printf 'boottools: ESP kernel/initramfs and the platform layer tool against the payload\n' ;;
        S7) printf 'releasefeeds: %s and %s each from its own release feeds, version and ABI snapshot diff\n' "${SCEN_LOW}" "${SCEN_HIGH}" ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------- #
# Plan (--dry-run)
# --------------------------------------------------------------------------- #

# Every line is "<case> <step> <action> expect=<verdict rule>", so a reader can check the
# judgement before a machine is touched.
plan_case() {
    _case=$1
    case "${_case}" in
        S1)
            printf '# case S1 preinstall: %s\n' "${SCEN_PKGS}"
            printf '%s status expect=committed slot with boot=ok esp=ok (else the run aborts with exit 3)\n' "${_case}"
            printf '%s helper push %s -> %s\n' "${_case}" "ab-scen-helper.sh" "${SCEN_HELPER}"
            printf '%s probe expect=apk=yes (else GAP: not an apk system), data=mounted (else GAP)\n' "${_case}"
            for _p in ${SCEN_PKGS}; do
                printf '%s pkg-install %s expect=installed|unavailable (unavailable is recorded with rc and the first error line, never a failure)\n' "${_case}" "${_p}"
            done
            printf '%s pkg-snapshot %s/apk-snapshot-<stamp>.txt expect=count>0 (apk info -v, else apk list --installed)\n' "${_case}" "${SCEN_EVIDENCE}"
            printf '%s pkg-version <every installed package> -> %s/packages.tsv expect=one row per package and per kmod\n' "${_case}" "${SCEN_EVIDENCE}"
            printf '%s probe-baseline <%s> expect=rc recorded for comparison after the jump\n' \
                "${_case}" "$(for _p in ${SCEN_PROBES}; do _scen_probe_cmd "${_p%%:*}" || true; done | tr '\n' ',' | sed 's/,$//')" 
            printf '%s assert installed>=1 package and>=1 kmod expect=PASS, else GAP with the per-package reason\n' "${_case}"
            printf '%s record\n' "${_case}"
            ;;
        S2)
            printf '# case S2 userdata: %s\n' "${SCEN_DATA_DIR}"
            printf '%s status expect=committed slot with boot=ok esp=ok (else the run aborts with exit 3)\n' "${_case}"
            printf '%s helper push %s -> %s\n' "${_case}" "ab-scen-helper.sh" "${SCEN_HELPER}"
            printf '%s probe expect=data=mounted and hash!=none (else GAP: no place or no tool for the manifest)\n' "${_case}"
            printf '%s seed %s expect=rc=0, 9 files (2 x MiB, a Chinese filename, a tar.gz, 2 fake docker tars) in a tree of 5 directories\n' "${_case}" "${SCEN_SEED_DIR}"
            printf '%s manifest hash %s -> %s/data.sha256 expect=files/dirs counts and one hash per file\n' "${_case}" "${SCEN_SEED_DIR}" "${SCEN_EVIDENCE}"
            printf '%s cfg-backup /etc/config/{network,firewall,system} -> %s/etc-config-<stamp> expect=3 of 3, else nothing is changed at all\n' "${_case}" "${SCEN_BACKUP}"
            printf '%s cfg-write /etc/config/%s expect=uci get %s.marker.label returns the label\n' "${_case}" "${SCEN_UCI}" "${SCEN_UCI}"
            printf '%s cfg-system hostname=%s timezone=%s expect=uci get system.@system[0].hostname/timezone\n' "${_case}" "${SCEN_HOSTNAME}" "${SCEN_TIMEZONE}"
            printf '%s cfg-net network.%s proto=none auto=0 expect=committed, cannot take the management interface down\n' "${_case}" "${SCEN_UCI}"
            printf '%s cfg-fw %s-discard src=lan proto=tcp dest_port=9 target=DROP expect=committed (port 9, never the session port)\n' "${_case}" "${SCEN_UCI}"
            printf '%s net-apply expect=a revert watchdog scheduled before the reload, then ubus call network reload\n' "${_case}"
            printf '%s ssh-liveness after the reload expect=ssh answers; on silence: rollback from the backup, then FAIL (the machine restores itself if the host cannot reach it)\n' "${_case}"
            printf '%s cfg-read expect=abscen/hostname/timezone/netsec/fwrule as written\n' "${_case}"
            printf '%s inventory -> %s/config.tsv expect=the values the jump cases compare against\n' "${_case}" "${SCEN_EVIDENCE}"
            printf '%s record\n' "${_case}"
            ;;
        S3 | S4)
            if [ "${_case}" = "S3" ]; then
                _from=${SCEN_LOW}
                _to=${SCEN_HIGH}
            else
                _from=${SCEN_HIGH}
                _to=${SCEN_LOW}
            fi
            _payload_warn "payload-${_from}.tar"
            _payload_warn "payload-${_to}.tar"
            printf '# case %s %s: %s->%s\n' "${_case}" "$(case_label "${_case}" | cut -d: -f1)" "${_from}" "${_to}"
            printf '%s status expect=committed slot with boot=ok esp=ok (else the run aborts with exit 3)\n' "${_case}"
            printf '%s helper push %s -> %s\n' "${_case}" "ab-scen-helper.sh" "${SCEN_HELPER}"
            printf '%s prereq %s/{packages,config}.tsv data.sha256 expect=readable, else GAP (run --case S1 --case S2 first)\n' "${_case}" "${SCEN_EVIDENCE}"
            printf '%s position %s (only when the machine runs something else)\n' "${_case}" "${_from}"
            printf '%s 1/1 unmount /mnt/slots/a /mnt/slots/b (left behind by an earlier --check; their absence is deliberately not asserted)\n' "${_case}"
            printf '%s 1/1 push %s/payload-%s.tar -> %s/payload-%s.tar\n' "${_case}" "${PAYLOAD_DIR}" "${_to}" "${AB_REMOTE_TMP}" "${_to}"
            printf '%s 1/1 check %s/payload-%s.tar expect=0 (exit 74 is a failed step here)\n' "${_case}" "${AB_REMOTE_TMP}" "${_to}"
            printf '%s 1/1 install %s/payload-%s.tar\n' "${_case}" "${AB_REMOTE_TMP}" "${_to}"
            printf '%s 1/1 reboot\n' "${_case}"
            printf '%s 1/1 wait_up %s (first boot of a new rootfs; hard cap %s)\n' "${_case}" "${AB_WAIT_UP_FIRST}" "${AB_WAIT_UP_HARD}"
            printf '%s 1/1 settle until boot=ok pending=none (%s s left of the cap)\n' "${_case}" "${AB_WAIT_SETTLE}"
            printf '%s 1/1 status\n' "${_case}"
            printf '%s 1/1 assert boot=ok esp=ok committed=<other> pending=none generation>=+1 upper=@overlay-%s(-rN)?\n' "${_case}" "${_to}"
            printf '%s data sha256 %s expect=0 changed/missing/untracked/entries lines against the pre-jump manifest (each offender is named)\n' "${_case}" "${SCEN_SEED_DIR}"
            printf '%s data tars %s expect=tar -tf exits 0 with members>0\n' "${_case}" "${SCEN_DOCKER_TARS}"
            printf '%s config uci %s + hostname + timezone + net section + firewall rule expect=the values S2 recorded\n' "${_case}" "${SCEN_UCI}"
            printf '%s software apk info -e <every recorded package> expect=present, and every package with files has at least one of them\n' "${_case}"
            printf '%s software exec <curl, htop> expect=the same exit status as the baseline taken in S1\n' "${_case}"
            printf '%s abi kmod vs uname -r expect=match is silent, stale/missing/unknown is a FINDING: naming what to reinstall (never FAIL)\n' "${_case}"
            printf '%s platform mounts expect=boot=ok esp=ok data=ok p4=ok pending=none, overlay writable\n' "${_case}"
            printf '%s platform services %s expect=/etc/init.d/<svc> stop and start both exit 0\n' "${_case}" "${SCEN_SERVICES}"
            printf '%s record\n' "${_case}"
            ;;
        S5)
            printf '# case S5 abi: the ledger on the running kernel\n'
            printf '%s status expect=committed slot with boot=ok esp=ok (else the run aborts with exit 3)\n' "${_case}"
            printf '%s helper push %s -> %s\n' "${_case}" "ab-scen-helper.sh" "${SCEN_HELPER}"
            printf '%s prereq %s/packages.tsv expect=readable, else GAP (run --case S1 first)\n' "${_case}" "${SCEN_EVIDENCE}"
            printf '%s abi kmodcheck <every recorded kmod> expect=state=match silent, stale/missing/unknown -> FINDING: with the version and the kernel it was built for\n' "${_case}"
            printf '%s abi kernel expect=the kernel S1 recorded vs uname -r now, and the list of packages to reinstall when they differ\n' "${_case}"
            printf '%s software apk info -e + exec probes expect=present and the same exit status as the S1 baseline\n' "${_case}"
            printf '%s platform mounts and services expect=boot=ok esp=ok data=ok p4=ok, overlay writable, stop/start exit 0\n' "${_case}"
            printf '%s record\n' "${_case}"
            ;;
        S6)
            # The dry run cannot know the running version without an ssh call, so the
            # payload is named as the placeholder it is; a version named in the environment
            # is checked on disk, which is the one thing a plan can do for it.
            if [ -n "${SCEN_S6_PAYLOAD}" ]; then
                _payload_warn "payload-${SCEN_S6_PAYLOAD}.tar"
                _pname="${PAYLOAD_DIR}/payload-${SCEN_S6_PAYLOAD}.tar"
            else
                _pname="${PAYLOAD_DIR}/payload-<ab-slot rootfs>.tar"
            fi
            printf '# case S6 boottools: does the boot toolchain travel with the update?\n'
            printf '%s status expect=committed slot with boot=ok esp=ok (else the run aborts with exit 3)\n' "${_case}"
            printf '%s helper push %s -> %s\n' "${_case}" "ab-scen-helper.sh" "${SCEN_HELPER}"
            printf '%s probe expect=hash=sha256sum (else GAP: the manifest records sha256)\n' "${_case}"
            printf '%s boottools <running slot> expect=%s listed, vmlinuz-<slot>/initrd-<slot> resolved, %s found in the platform layer\n' \
                "${_case}" "${SCEN_ESP_DIR}" "${SCEN_PLATFORM_TOOL}"
            printf '%s use payload %s expect=present, else GAP (default is the version ab-slot rootfs reports; AB_SCEN_S6_PAYLOAD names another)\n' \
                "${_case}" "${_pname}"
            printf '%s assert sha256(<esp>/vmlinuz-<slot>) == manifest kernel.bin expect=PASS, else FAIL naming the file and both digests\n' "${_case}"
            printf '%s assert sha256(<esp>/initrd-<slot>) == manifest initramfs.cpio.gz expect=PASS, else FAIL naming the file and both digests\n' "${_case}"
            printf '%s assert sha256(<platform layer>/usr/sbin/%s) == platform.tar member expect=PASS, else FAIL; tool present but --version failing is also FAIL (the stderr line is recorded)\n' \
                "${_case}" "${SCEN_PLATFORM_TOOL}"
            printf '%s ledger initramfs members + busybox/sfdisk/partx/%s --version + platform-release expect=printed as facts, nothing judged on them\n' \
                "${_case}" "${SCEN_PLATFORM_TOOL}"
            printf '%s version relation expect=same version is silent; tools newer than the rootfs -> FINDING: boot tools come from <payload> while the running rootfs is <running> (never FAIL)\n' "${_case}"
            printf '%s record\n' "${_case}"
            ;;
        S7)
            # The three feed lines each version will be given, taken out of the release
            # itself: a plan that cannot name them has not found the release it plans on.
            _s7_from=${SCEN_LOW}
            _s7_to=${SCEN_HIGH}
            _s7_kmod=$(s7_kmods | head -n 1)
            _payload_warn "payload-${_s7_from}.tar"
            _payload_warn "payload-${_s7_to}.tar"
            printf '# case S7 releasefeeds: %s and %s, each installed from its own release feeds\n' \
                "${_s7_from}" "${_s7_to}"
            printf '%s status expect=committed slot with boot=ok esp=ok (else the run aborts with exit 3)\n' "${_case}"
            for _s7_v in "${_s7_from}" "${_s7_to}"; do
                _s7_file="${_tmp}/s7-plan-${_s7_v}.list"
                if s7_feeds_render "${_s7_v}" "${_s7_file}" >/dev/null 2>&1; then
                    printf '%s feeds 1/3 %s (from payload-%s.tar)\n' "${_case}" "$(s7_feed_of "${_s7_file}" packages)" "${_s7_v}"
                    printf '%s feeds 2/3 %s (from payload-%s.tar)\n' "${_case}" "$(s7_feed_of "${_s7_file}" targets)" "${_s7_v}"
                    printf '%s feeds 3/3 %s (from payload-%s.tar)\n' "${_case}" "$(s7_feed_of "${_s7_file}" kmods)" "${_s7_v}"
                else
                    printf '%s feeds 1/3 unknown (%s: no payload, or its rootfs carries no feed list)\n' "${_case}" "${_s7_v}"
                    printf '%s feeds 2/3 unknown (%s)\n' "${_case}" "${_s7_v}"
                    printf '%s feeds 3/3 unknown (%s)\n' "${_case}" "${_s7_v}"
                fi
            done
            printf '%s feeds-source expect=%s read out of payload-<version>.tar rootfs.tar.gz and never rebuilt (the kmods directory <kernel>-1-<hash> is a build hash), else GAP\n' \
                "${_case}" "${SCEN_S7_FEEDS}"
            printf '%s helper push %s -> %s\n' "${_case}" "ab-scen-helper.sh" "${SCEN_HELPER}"
            printf '%s probe expect=apk=yes and data=mounted (else GAP: no package source, or nowhere to keep the backup)\n' "${_case}"
            printf '%s position %s (only when the machine runs something else: the from version has to be the running one, its kmods index is built for that kernel)\n' \
                "${_case}" "${_s7_from}"
            printf '%s 1/6 backup %s -> %s/s7-feeds-<stamp> expect=1 of 1, else FAIL and nothing else is changed\n' \
                "${_case}" "${SCEN_S7_FEEDS}" "${SCEN_BACKUP}"
            printf '%s 2/6 write the %s feed list, apk update expect=rc=0 (a machine that cannot reach its own release feeds is a GAP, and the list is put back)\n' \
                "${_case}" "${_s7_from}"
            printf '%s 2/6 install %s expect=each package recorded from the %s feeds; zero installed is a FAIL\n' \
                "${_case}" "${SCEN_PKGS}" "${_s7_from}"
            printf '%s 2/6 snapshot A expect=apk list --installed plus the version of every package and the kernel dependency (apk info -R) of every kmod\n' "${_case}"
            printf '%s 3/6 hop %s -> %s expect=committed on the other slot, generation+1, upper=@overlay-%s (scen_hop'"'"'s own rule)\n' \
                "${_case}" "${_s7_from}" "${_s7_to}" "${_s7_to}"
            printf '%s 3/6 snapshot B expect=the same two files on the version now running\n' "${_case}"
            printf '%s 4/6 diff A vs B expect=one row per package (version-changed|disappeared|new|same) and each kmod with the kernel dependency it carries against the running kernel\n' "${_case}"
            printf '%s 5/6 read %s expect=equal to the %s bytes -> FINDING: the package source did not follow the version (never FAIL); equal to the %s bytes -> recorded, no finding\n' \
                "${_case}" "${SCEN_S7_FEEDS}" "${_s7_from}" "${_s7_to}"
            printf '%s 6/6 align the %s feeds, apk update, install %s then a package that was not installed expect=one install that really changed something, else FAIL\n' \
                "${_case}" "${_s7_to}" "${_s7_kmod:-<kmod>}"
            printf '%s 6/6 restore %s from the backup expect=byte-identical to step 1, else FAIL\n' "${_case}" "${SCEN_S7_FEEDS}"
            printf '%s record\n' "${_case}"
            ;;
        *)
            return 1
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

if [ -n "${RENDER_HELPER}" ]; then
    scen_helper_render "${RENDER_HELPER}" || exit 1
    exit 0
fi

if [ "${DRY_RUN}" = "1" ]; then
    for _case in ${WANT_CASES}; do
        plan_case "${_case}" || {
            printf 'scenarios: unknown case: %s\n' "${_case}" >&2
            exit 2
        }
    done
    exit 0
fi

_passed=0
_failed=0
_gapped=0
_skipped=0
for _case in ${WANT_CASES}; do
    if ! case_label "${_case}" >/dev/null; then
        printf 'scenarios: unknown case: %s\n' "${_case}" >&2
        exit 2
    fi
    if [ "${RESUME}" = "1" ] && record_passed "${_case}"; then
        printf '%s: already PASS in %s, skipped\n' "${_case}" "${AB_RESULTS}"
        _skipped=$((_skipped + 1))
        continue
    fi
    printf '== %s %s' "${_case}" "$(case_label "${_case}")"
    SCEN_DRIVER_ERROR_FILE="${EVIDENCE_DIR}/driver-error.flag"
    rm -f "${SCEN_DRIVER_ERROR_FILE}" "${SCEN_DRIVER_ERROR_FILE}.ssh-lost"
    scen_case "${_case}"
    _rc=$?
    # A case that never reached the machine is a driver failure, whatever the case itself
    # was about to say. Keeping the case's own wording here is how "the helper was not
    # there" gets filed as "the user's data is gone".
    # Only the notes that mean "nothing was judged" are rewritten: a machine that really did
    # stop answering after the reload has already said so in its own words, and replacing
    # that with a driver error would hide the one fact the case exists to report.
    if driver_error_seen && ! machine_unreachable_seen && [ "${_rc}" -ne 0 ]; then
        CASE_NOTE="driver error: the scenario helper did not answer (helper-unavailable); the machine was not judged"
        _rc=1
    fi
    # The finding prefix is part of the note, not a verdict: a row can be PASS and still
    # carry what the user has to do about their kernel modules.
    _note=${CASE_NOTE}
    if [ -n "${CASE_FINDINGS}" ]; then
        if [ -n "${_note}" ]; then
            _note="${CASE_FINDINGS}; ${_note}"
        else
            _note=${CASE_FINDINGS}
        fi
    fi
    case "${_rc}" in
        0)
            record "${_case}" PASS "${AB_EVIDENCE_LOG}" "${_note}"
            _passed=$((_passed + 1))
            ;;
        2)
            record "${_case}" GAP "${AB_EVIDENCE_LOG}" "${_note}"
            _gapped=$((_gapped + 1))
            ;;
        *)
            record "${_case}" FAIL "${AB_EVIDENCE_LOG}" "${_note}"
            _failed=$((_failed + 1))
            ;;
    esac
    printf '   %s: %s (%s)\n' "${_case}" "${_note}" "${AB_EVIDENCE_LOG}"
done

printf '\nscenarios: passed=%s failed=%s gap=%s skipped=%s assertions-failed=%s results=%s\n' \
    "${_passed}" "${_failed}" "${_gapped}" "${_skipped}" "${AB_ASSERT_FAILURES}" "${AB_RESULTS}"
[ "${_failed}" -eq 0 ] || exit 1
[ "${_gapped}" -eq 0 ] || exit 4
