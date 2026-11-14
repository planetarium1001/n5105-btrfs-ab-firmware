#!/bin/sh
# feed-install.sh - ac-12 and ac-13 on the real machine: ask the feed, then take it.
#
# feed-probe.sh answers "can this machine ask, and what does it say" and is read-only. This
# is the other half: the answer has to be the *right* answer (a candidate, not "current"),
# and then the machine has to actually take it - download, verify size and digest against
# the published index, install into the slot it is not running, reboot, commit - and come
# back running the new version.
#
#   scripts/device/feed-install.sh --case check      # ac-12 only: nothing is written
#   scripts/device/feed-install.sh --case install    # ac-13 only: install whatever is out there
#   scripts/device/feed-install.sh                   # both, in that order
#   scripts/device/feed-install.sh --expect 0.0.10   # pin the candidate this run expects
#   scripts/device/feed-install.sh --feed-url https://mirror.example/n5105/feed/v1
#   scripts/device/feed-install.sh --index-file /tmp/index.txt   # no host network
#   AB_DRY_RUN=1 scripts/device/feed-install.sh      # print the steps, touch nothing
#
# What makes this different from feed-probe.sh, which is where ac-12 was going to be read
# from: the probe prints `source=` and the machine line and exits 0 for *both* "update
# available" (ab-upgrade exit 10) and "nothing to do" (exit 0). Treating 0|10 as success,
# as the probe does, means a machine with no candidate reads as a pass. Here the exit code
# is asserted, the candidate is asserted to be the one ac-12 names, and `status=update` is
# asserted, so "no update" is a red line with the next command in it.
#
# Assertion shape (one line per assertion, `ok`/`FAIL`/`GAP` plus a pasteable next step):
#
#   ok [ac-12] source=release status=update platform_available=0.0.9 exit=10
#   ok [ac-13] payload n5105-ab-25.12.2-upgrade.tar size 23500800 matches the index
#   FAIL [ac-13] the machine still runs 0.0.9 after the commit
#     next: scripts/device/matrix.sh --case M1 --dry-run
#
# Exit status: 0 every assertion held, 1 at least one failed, 2 usage, 3 no verdict (the
# feed could not be reached - GAP, not FAIL: PRD risk 3).

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

AB_FEED_INSTALL_RESULTS=${AB_FEED_INSTALL_RESULTS:-feed-install-results.tsv}
AB_DEVICE_FEED_DIR=${AB_DEVICE_FEED_DIR:-/tmp/ab-feed}
DRY_RUN=${AB_DRY_RUN:-0}

expect="0.0.9"
conf=/etc/ab/update.conf
feed_url=""
index_file=""
cases=""

usage() {
    sed -n '8,20p' "$0"
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            case "${2:-}" in
                check | install | both) cases=${2} ;;
                *) printf 'feed-install.sh: --case takes check, install or both\n' >&2; usage ;;
            esac
            shift 2
            ;;
        --expect) expect=${2:?--expect needs a platform version}; shift 2 ;;
        --conf) conf=${2:?--conf needs a path}; shift 2 ;;
        --feed-url) feed_url=${2:?--feed-url needs a url}; shift 2 ;;
        --index-file) index_file=${2:?--index-file needs a path}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage ;;
        *) printf 'feed-install.sh: unknown argument %s\n' "$1" >&2; usage ;;
    esac
done
[ -n "${cases}" ] || cases=both

CHECKS=0
FAILURES=0
GAPS=0
# Per-case counters: the run-level ones answer "did this run pass", these answer "did this
# case pass", which is what the results row and the == line are about.
CASE_CHECKS=0
CASE_FAILURES=0
CASE_GAPS=0
CASE_STATUS=""   # PASS | FAIL | GAP for the case being run
CASE_NOTE=""

# _ok/_fail/_gap <case> <message> [next command]
# The failure line is the deliverable: what was measured, and the one command that answers
# the question again. A GAP is a verdict the machine could not give - an unreachable
# network is not a broken release (PRD risk 3).
_ok() {
    CHECKS=$((CHECKS + 1))
    CASE_CHECKS=$((CASE_CHECKS + 1))
    printf 'ok [%s] %s\n' "$1" "$2"
    ev "ok ${1}: ${2}"
}

_fail() {
    CHECKS=$((CHECKS + 1))
    CASE_CHECKS=$((CASE_CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    CASE_FAILURES=$((CASE_FAILURES + 1))
    printf 'FAIL [%s] %s\n' "$1" "$2"
    if [ -n "${3:-}" ]; then
        printf '  next: %s\n' "$3"
    fi
    ev "FAIL ${1}: ${2}${3:+ | next: ${3}}"
}

_gap() {
    CHECKS=$((CHECKS + 1))
    CASE_CHECKS=$((CASE_CHECKS + 1))
    GAPS=$((GAPS + 1))
    CASE_GAPS=$((CASE_GAPS + 1))
    printf 'GAP [%s] %s\n' "$1" "$2"
    if [ -n "${3:-}" ]; then
        printf '  next: %s\n' "$3"
    fi
    ev "GAP ${1}: ${2}${3:+ | next: ${3}}"
}

# _assert_eq <case> <label> <actual> <expected> [next]
_assert_eq() {
    if [ "$3" = "$4" ]; then
        _ok "$1" "$2=$3"
        return 0
    fi
    _fail "$1" "$2=$3, expected $4" "${5:-}"
    return 1
}

# _requirement <case> <what>: the machine has to be a committed, healthy machine with no
# candidate queued, or the two phases below mean two things at once.
require_idle_machine() {
    _case=$1
    if ! STATUS_LINE=$(dev_status 2>/dev/null); then
        _gap "${_case}" "ab-slot status did not answer" "AB_HOST=root@192.168.2.49 scripts/device/feed-probe.sh"
        return 1
    fi
    _boot=$(status_field "${STATUS_LINE}" boot) || _boot=""
    _esp=$(status_field "${STATUS_LINE}" esp) || _esp=""
    _pending=$(status_field "${STATUS_LINE}" pending) || _pending=""
    if [ "${_boot}" != "ok" ] || [ "${_esp}" != "ok" ] || [ "${_pending}" != "none" ]; then
        _gap "${_case}" \
            "machine is not idle (boot=${_boot:-?} esp=${_esp:-?} pending=${_pending:-?})" \
            "ab-slot status"
        return 1
    fi
    _ok "${_case}" "machine is idle (committed=$(status_field "${STATUS_LINE}" committed) pending=none)"
    return 0
}

# _release_installed: the platform version the running slot records.
_release_installed() {
    _out=$(dev_ssh 'cat /etc/platform-release 2>/dev/null' 2>/dev/null) || _out=""
    printf '%s\n' "${_out}" | sed -n 's/^PLATFORM_VERSION=//p' | head -n 1
}

# _index_entry <platform>: the `key=value` block of one AB-FEED entry, read from the index
# this run can see. Where that index came from is part of the evidence: --index-file when
# the host has no network, otherwise the feed URL the machine itself printed.
_index_entry() {
    _want=$1
    if [ -n "${index_file}" ]; then
        [ -f "${index_file}" ] || return 1
        _awk_entry "${index_file}" "${_want}"
        return $?
    fi
    [ -n "${FEED_URL_SEEN:-}" ] || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${FEED_URL_SEEN%/}/index.txt" 2>/dev/null | _awk_entry_stdin "${_want}"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O - "${FEED_URL_SEEN%/}/index.txt" 2>/dev/null | _awk_entry_stdin "${_want}"
        return $?
    fi
    return 1
}

# _awk_entry <file> <platform> / _awk_entry_stdin <platform>: the same parse the device's
# ab-feed.sh does (`entry` ... `end`, one `key value` per line), because the question here
# is what *that* reader would say, not what a second grammar thinks.
_awk_entry() {
    awk -v want="$2" '
        function flush() {
            if (plat != "" && plat == want) {
                print "platform=" plat
                print "base=" base
                print "kernel=" kernel
                print "payload=" payload
                print "size=" size
                print "sha256=" sha
            }
            plat = ""; base = ""; kernel = ""; payload = ""; size = ""; sha = ""
        }
        $1 == "entry" { flush(); next }
        $1 == "end" { flush(); next }
        $1 == "platform" { plat = $2; next }
        $1 == "base" { base = $2; next }
        $1 == "kernel" { kernel = $2; next }
        $1 == "payload" { payload = $2; next }
        $1 == "size" { size = $2; next }
        $1 == "sha256" { sha = $2; next }
        END { flush() }
    ' "$1"
}

_awk_entry_stdin() {
    awk -v want="$1" '
        function flush() {
            if (plat != "" && plat == want) {
                print "platform=" plat
                print "base=" base
                print "kernel=" kernel
                print "payload=" payload
                print "size=" size
                print "sha256=" sha
            }
            plat = ""; base = ""; kernel = ""; payload = ""; size = ""; sha = ""
        }
        $1 == "entry" { flush(); next }
        $1 == "end" { flush(); next }
        $1 == "platform" { plat = $2; next }
        $1 == "base" { base = $2; next }
        $1 == "kernel" { kernel = $2; next }
        $1 == "payload" { payload = $2; next }
        $1 == "size" { size = $2; next }
        $1 == "sha256" { sha = $2; next }
        END { flush() }
    '
}

# _classify_refusal <case> <reason>: which refusals are the release's fault, which are this
# machine's, and which are nobody's (no network).
_classify_refusal() {
    _case=$1
    _reason=$2
    case "${_reason}" in
        feed-unreachable)
            _gap "${_case}" "the feed could not be reached (reason=${_reason})" \
                "scripts/device/feed-probe.sh   # then check WAN and the proxy in UPDATE_RELEASE_BASE"
            ;;
        feed-index-missing)
            _fail "${_case}" "the source answered, but not with an AB-FEED index (reason=${_reason})" \
                "scripts/device/release-verify.sh --tag v${expect}   # the release must carry index.txt"
            ;;
        feed-conf-* | platform-release-missing | platform-release-invalid)
            _fail "${_case}" "this machine's own configuration or identity is wrong (reason=${_reason})" \
                "cat /etc/ab/update.conf; cat /etc/platform-release"
            ;;
        feed-pinned)
            _fail "${_case}" "UPDATE_PIN holds this machine (reason=${_reason})" "ab-upgrade --unpin"
            ;;
        feed-would-downgrade)
            _fail "${_case}" "the feed offers something older than this machine (reason=${_reason})" \
                "ab-upgrade --feed-check   # read platform= and platform_available="
            ;;
        feed-no-such-release)
            _fail "${_case}" "the feed names no release to step through (reason=${_reason})" \
                "ab-upgrade --feed-check"
            ;;
        *)
            _fail "${_case}" "the feed refused (reason=${_reason:-unknown})" \
                "ab-upgrade --feed-check; ab-upgrade --feed"
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# ac-12: the machine sees a candidate, and it is the candidate this run expects
#
# PRD: "出厂 /etc/ab/update.conf 下 ab-upgrade --feed-check 输出 source=release 且
# status=update（候选 0.0.9），退出 10". All four parts are asserted separately, because
# each one fails on its own: a wrong source is a config, a wrong candidate is a published
# tag, status=current is "already upgraded", and an exit code of 0 is the probe's mistake.
# --------------------------------------------------------------------------- #

run_check() {
    _case=ac-12
    CASE_STATUS=""

    # A dry run is a planner: it prints the plan without reading the machine, because
    # AB_DRY_RUN=1 makes every dev_ssh inert and an assertion over no output would report a
    # red that says nothing about the release.
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/4 ab-upgrade --feed-check on the machine (conf %s)\n' "${_case}" "${conf}"
        printf '%s 2/4 expect exit=10, source=release, status=update, platform_available=%s\n' "${_case}" "${expect}"
        printf '%s 3/4 a refusal of feed-unreachable is a GAP, everything else is a FAIL\n' "${_case}"
        printf '%s 4/4 the installed platform is printed last, so a run on an upgraded machine is visible\n' \
            "${_case}"
        CASE_NOTE="dry-run"
        CASE_STATUS=PASS
        return 0
    fi

    require_idle_machine "${_case}" || {
        CASE_STATUS=GAP
        return 1
    }

    check_cmd="ab-upgrade --feed-check"
    [ -n "${feed_url}" ] && check_cmd="${check_cmd} --feed-url '${feed_url}'"
    out=$(dev_ssh "${check_cmd}" 2>&1)
    rc=$?
    printf '%s\n' "${out}" | sed 's/^/  | /' >&2

    source_line=$(printf '%s\n' "${out}" | grep -E '^source=' | head -n 1)
    machine_line=$(printf '%s\n' "${out}" | grep -E '^platform=' | head -n 1)
    refusal=$(printf '%s\n' "${out}" | grep -E '^ab-upgrade: refused, reason=' | head -n 1)

    if [ "${rc}" -ne 10 ]; then
        case "${rc}" in
            74)
                _classify_refusal "${_case}" "$(printf '%s' "${refusal}" | sed 's/.*reason=//')"
                CASE_STATUS=FAIL
                # A refusal of the network is a GAP even though it arrived as exit 74.
                [ "${CASE_GAPS}" -gt 0 ] && CASE_STATUS=GAP
                return 1
                ;;
            0)
                status=$(status_field "${machine_line}" status) || status=""
                _fail "${_case}" \
                    "the machine has no candidate to report (exit=0 status=${status:-unknown}); ac-12 wants status=update exit=10" \
                    "ab-upgrade --feed-check   # on a machine that already runs ${expect} this is expected: take ac-12 before upgrading"
                ;;
            *)
                _fail "${_case}" "ab-upgrade --feed-check exited ${rc}" "ab-upgrade --feed-check; ab-slot log"
                ;;
        esac
        CASE_STATUS=FAIL
        return 1
    fi
    _ok "${_case}" "ab-upgrade --feed-check exit=10 (a candidate is offered)"

    source=$(status_field "${source_line}" source) || source=""
    FEED_URL_SEEN=$(status_field "${source_line}" feed 2>/dev/null) || FEED_URL_SEEN=""
    if [ -n "${feed_url}" ]; then
        _assert_eq "${_case}" "source" "${source}" "feed" \
            "ab-upgrade --feed-check   # --feed-url was given, so the source is the mirror"
    else
        _assert_eq "${_case}" "source" "${source}" "release" \
            "grep -E '^UPDATE_(SOURCE|RELEASE_REPO)=' /etc/ab/update.conf"
    fi

    available=$(status_field "${machine_line}" platform_available) || available=""
    _assert_eq "${_case}" "platform_available" "${available}" "${expect}" \
        "gh release view --json tagName -q .tagName; ab-upgrade --feed-check"

    status=$(status_field "${machine_line}" status) || status=""
    _assert_eq "${_case}" "status" "${status}" "update" \
        "ab-upgrade --feed-check   # status=current means this machine is already on the newest release"

    base_available=$(status_field "${machine_line}" base_available) || base_available=""
    _ok "${_case}" "console line: platform=$(status_field "${machine_line}" platform) -> ${available} base=${base_available} status=${status}"
    if [ "${CASE_FAILURES}" -gt 0 ]; then
        CASE_STATUS=FAIL
        return 1
    fi
    CASE_STATUS=PASS
    return 0
}

# --------------------------------------------------------------------------- #
# ac-13: take it - download, verify size and digest, install into the other slot, commit
#
# PRD: "--feed 从本仓库 release 下载、校验 size/sha256、装到非运行槽并提交，结束后
# PLATFORM_VERSION 为新版本". The device does the verification itself (ab_feed_verify_member
# in platform/lib/ab-feed.sh); what this driver adds is the independent reading of the
# same claim: the size and digest the index declares, compared with the bytes the device
# still has on disk, and the version the machine runs after the commit.
# --------------------------------------------------------------------------- #

run_install() {
    _case=ac-13
    CASE_STATUS=""
    base_available=""

    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/6 ab-upgrade --feed --yes on the machine\n' "${_case}"
        printf '%s 2/6 expect platform_available=%s and "verified, installing"\n' "${_case}" "${expect}"
        printf '%s 3/6 read the payload the machine kept under %s and compare with the index\n' \
            "${_case}" "${AB_DEVICE_FEED_DIR}"
        printf '%s 4/6 expect pending=<other slot> and committed unchanged\n' "${_case}"
        printf '%s 5/6 reboot, wait for 22, wait for boot=ok pending=none\n' "${_case}"
        printf '%s 6/6 expect slot=committed=<other>, PLATFORM_VERSION=%s, and action=commit in the ring log\n' \
            "${_case}" "${expect}"
        CASE_NOTE="dry-run"
        CASE_STATUS=PASS
        return 0
    fi

    require_idle_machine "${_case}" || {
        CASE_STATUS=GAP
        return 1
    }

    before_status=$(dev_status 2>/dev/null) || before_status=""
    before_slot=$(status_field "${before_status}" slot) || before_slot=""
    before_committed=$(status_field "${before_status}" committed) || before_committed=""
    before_version=$(_release_installed)

    install_cmd="ab-upgrade --feed --yes"
    [ -n "${feed_url}" ] && install_cmd="${install_cmd} --feed-url '${feed_url}'"
    out=$(dev_ssh "${install_cmd}" 2>&1)
    rc=$?
    printf '%s\n' "${out}" | sed 's/^/  | /' >&2

    if [ "${rc}" -ne 0 ]; then
        refusal=$(printf '%s\n' "${out}" | grep -E '^ab-upgrade: refused, reason=' | head -n 1)
        case "${rc}" in
            74)
                reason=$(printf '%s' "${refusal}" | sed 's/.*reason=//')
                case "${reason}" in
                    feed-size-mismatch | feed-digest-mismatch)
                        _fail "${_case}" \
                            "the published bytes do not match the index the device downloaded (reason=${reason})" \
                            "scripts/device/release-verify.sh --tag v${expect}"
                        ;;
                    *) _classify_refusal "${_case}" "${reason}" ;;
                esac
                ;;
            *)
                _fail "${_case}" "ab-upgrade --feed exited ${rc}" "ab-upgrade --feed --yes; ab-slot log"
                ;;
        esac
        CASE_STATUS=FAIL
        [ "${CASE_GAPS}" -gt 0 ] && CASE_STATUS=GAP
        return 1
    fi

    # `--feed` on a machine that is already on the newest release says so and exits 0
    # without writing anything. That is not an install, and calling it one is how a green
    # run would be reported for a machine that never moved.
    if printf '%s\n' "${out}" | grep -q '^status=current'; then
        _fail "${_case}" \
            "the machine is already on the newest release (status=current); nothing was installed" \
            "ab-upgrade --feed-check   # take ac-13 on a machine one release behind, before it is upgraded"
        CASE_STATUS=FAIL
        return 1
    fi

    machine_line=$(printf '%s\n' "${out}" | grep -E '^platform=' | head -n 1)
    available=$(status_field "${machine_line}" platform_available) || available=""
    base_available=$(status_field "${machine_line}" base_available) || base_available=""
    _assert_eq "${_case}" "platform_available" "${available}" "${expect}" \
        "gh release view --json tagName -q .tagName"

    if printf '%s\n' "${out}" | grep -qF "verified, installing"; then
        _ok "${_case}" "the device verified the payload itself (size and digest against the index)"
    else
        _fail "${_case}" "the device never said 'verified, installing'" \
            "ab-upgrade --feed --yes   # a refusal names the reason"
    fi

    target=""
    installed_line=$(printf '%s\n' "${out}" | grep -E '^ab-upgrade: installed ' | head -n 1)
    if [ -n "${installed_line}" ]; then
        target=$(printf '%s\n' "${installed_line}" | sed -n 's/.*into slot \([ab]\).*/\1/p')
        _ok "${_case}" "installed into slot ${target:-?}: $(printf '%s' "${installed_line}" | sed 's/^ab-upgrade: //')"
    else
        _fail "${_case}" "no 'installed ... into slot ...' line" "ab-upgrade --feed --yes"
    fi
    if [ -n "${target}" ] && [ "${target}" = "${before_slot}" ]; then
        _fail "${_case}" "the payload went into the running slot ${target}" \
            "ab-slot status   # the installer must write the other slot"
    elif [ -n "${target}" ]; then
        _ok "${_case}" "target slot ${target} is not the running slot ${before_slot}"
    fi

    # The index as an independent reader sees it, and the bytes the machine kept.
    entry=$(_index_entry "${expect}") || entry=""
    if [ -z "${entry}" ]; then
        _gap "${_case}" "the index could not be read on this host, so size/sha256 were not cross-checked" \
            "scripts/device/feed-install.sh --case install --index-file /tmp/index.txt"
    else
        want_size=$(printf '%s\n' "${entry}" | sed -n 's/^size=//p')
        want_sha=$(printf '%s\n' "${entry}" | sed -n 's/^sha256=//p')
        payload_name=$(printf '%s\n' "${entry}" | sed -n 's/^payload=//p')
        measured=$(dev_ssh "f='${AB_DEVICE_FEED_DIR}/${payload_name}'; [ -f \"\$f\" ] && { wc -c <\"\$f\"; sha256sum \"\$f\" 2>/dev/null || shasum -a 256 \"\$f\"; }" 2>/dev/null) || measured=""
        got_size=$(printf '%s\n' "${measured}" | sed -n '1p' | tr -d ' ')
        got_sha=$(printf '%s\n' "${measured}" | sed -n '2p' | awk '{ print $1 }')
        if [ -z "${got_size}" ]; then
            _gap "${_case}" "the machine did not keep ${AB_DEVICE_FEED_DIR}/${payload_name}, so its bytes could not be measured" \
                "AB_FEED_DIR=/data/ab-feed ab-upgrade --feed --yes"
        else
            _assert_eq "${_case}" "payload_size" "${got_size}" "${want_size}" \
                "scripts/device/release-verify.sh --tag v${expect}"
            _assert_eq "${_case}" "payload_sha256" "${got_sha}" "${want_sha}" \
                "scripts/device/release-verify.sh --tag v${expect}"
        fi
    fi

    pending=$(dev_status_field pending 2>/dev/null) || pending=""
    _assert_eq "${_case}" "pending" "${pending}" "${target:-pending-slot}" \
        "ab-slot status   # the install marks the other slot pending for the next boot"
    committed=$(dev_status_field committed 2>/dev/null) || committed=""
    _assert_eq "${_case}" "committed_before_reboot" "${committed}" "${before_committed}" \
        "ab-slot status   # committing is the candidate's own job, after its health check"

    if [ "${CASE_FAILURES}" -gt 0 ]; then
        CASE_STATUS=FAIL
        return 1
    fi

    # The boot that commits. The candidate's own health check decides, not this script:
    # everything asserted afterwards is what the machine wrote about itself.
    dev_reboot >/dev/null 2>&1
    if ! dev_wait_up_after after-install; then
        _fail "${_case}" "the machine did not answer ssh after the commit boot" \
            "scripts/device/flash.sh --help   # a machine that does not come back needs the console"
        CASE_STATUS=FAIL
        return 1
    fi
    settled=$(dev_wait_settled 2>/dev/null) || settled=""
    if [ -z "${settled}" ]; then
        _fail "${_case}" "the machine answered ssh but never settled (boot=ok pending=none)" "ab-slot status"
        CASE_STATUS=FAIL
        return 1
    fi

    _assert_eq "${_case}" "slot" "$(status_field "${settled}" slot)" "${target:-?}" "ab-slot status"
    _assert_eq "${_case}" "committed" "$(status_field "${settled}" committed)" "${target:-?}" "ab-slot status"
    _assert_eq "${_case}" "pending" "$(status_field "${settled}" pending)" "none" "ab-slot status"
    _assert_eq "${_case}" "boot" "$(status_field "${settled}" boot)" "ok" "ab-slot log"

    version_after=$(_release_installed)
    _assert_eq "${_case}" "PLATFORM_VERSION" "${version_after}" "${expect}" \
        "cat /etc/platform-release   # before this run it was ${before_version:-unknown}"

    # The commit line is the machine's own statement that this boot finished and committed
    # (lib.sh searches boot-0.log, boot-1.log and `ab-slot log --prev` in that order, because
    # the ring log may have rotated it away). Its `rootfs=` is the upstream base, not our
    # platform version - ab-commit writes what the slot runs - so the pattern is built from
    # the base the feed itself named, and falls back to the action alone when it did not.
    if [ -n "${base_available}" ]; then
        commit_pattern="stage=commit .*rootfs=$(dev_version_re "${base_available}") .*result=ok action=commit"
    else
        commit_pattern='stage=commit .*result=ok action=commit'
    fi
    if hit=$(boot_mark_find "${commit_pattern}"); then
        _ok "${_case}" "ring log: ${hit}"
    else
        _fail "${_case}" "ring log carries no commit line (${commit_pattern})" \
            "ab-slot log; ab-slot log --prev"
    fi

    if [ "${CASE_FAILURES}" -gt 0 ]; then
        CASE_STATUS=FAIL
        return 1
    fi
    CASE_STATUS=PASS
    return 0
}

if [ "${DRY_RUN}" = "1" ]; then
    printf 'feed-install.sh: dry run, expect=%s conf=%s cases=%s\n' "${expect}" "${conf}" "${cases}"
    ev "feed-install dry-run expect=${expect} cases=${cases}"
fi

run_case() {
    _case=$1
    CASE_CHECKS=0
    CASE_FAILURES=0
    CASE_GAPS=0
    CASE_STATUS=""
    case "${_case}" in
        ac-12) run_check ;;
        ac-13) run_install ;;
    esac
    _rc=$?
    _status=${CASE_STATUS:-FAIL}
    if [ "${DRY_RUN}" = "1" ]; then
        # A planner reached no verdict, so it writes no row: the results file is what the
        # Lead reads as evidence, and a PASS in it has to mean a run happened.
        printf '== %s %s %s\n' "${_case}" "${_status}" "${CASE_NOTE:-dry-run}"
        return "${_rc}"
    fi
    mkdir -p "$(dirname "${AB_FEED_INSTALL_RESULTS}")" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\tchecks=%s failures=%s gaps=%s\n' \
        "${_case}" "${_status}" "${AB_HOST}" "${CASE_NOTE:-none}" \
        "${CASE_CHECKS}" "${CASE_FAILURES}" "${CASE_GAPS}" \
        >>"${AB_FEED_INSTALL_RESULTS}"
    printf '== %s %s %s\n' "${_case}" "${_status}" "${CASE_NOTE:-}"
    return "${_rc}"
}

_rc_all=0
case "${cases}" in
    check) run_case ac-12 || _rc_all=1 ;;
    install) run_case ac-13 || _rc_all=1 ;;
    both)
        run_case ac-12 || _rc_all=1
        if [ "${CASE_STATUS}" = "GAP" ]; then
            # ac-13 needs the same feed ac-12 could not read. Reporting a second, derived
            # failure would put a red line next to a release that may be perfectly fine.
            printf 'note [ac-13] skipped: ac-12 read no feed (%s)\n' "${CASE_NOTE:-no verdict}"
            CASE_GAPS=$((CASE_GAPS + 1))
            GAPS=$((GAPS + 1))
            printf 'ac-13\tGAP\t%s\tskipped, ac-12 could not read the feed\n' "${AB_HOST}" \
                >>"${AB_FEED_INSTALL_RESULTS}"
            printf '== ac-13 GAP skipped (ac-12 gave no verdict)\n'
        else
            run_case ac-13 || _rc_all=1
        fi
        ;;
esac

if [ "${DRY_RUN}" = "1" ]; then
    # Nothing was asserted against a machine, so nothing is claimed about one.
    printf 'feed-install result=dry-run checks=0 failed=0 gaps=0 expect=%s\n' "${expect}"
    exit 0
fi
if [ "${FAILURES}" -gt 0 ]; then
    printf 'feed-install result=fail checks=%s failed=%s gaps=%s expect=%s\n' \
        "${CHECKS}" "${FAILURES}" "${GAPS}" "${expect}"
    exit 1
fi
if [ "${GAPS}" -gt 0 ]; then
    printf 'feed-install result=gap checks=%s failed=0 gaps=%s expect=%s reason=network\n' \
        "${CHECKS}" "${GAPS}" "${expect}"
    exit 3
fi
printf 'feed-install result=pass checks=%s failed=0 gaps=0 expect=%s\n' "${CHECKS}" "${expect}"
exit 0
