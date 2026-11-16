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
#   scripts/device/feed-install.sh --case pin        # ac-3 only: hold this machine, then release it
#   scripts/device/feed-install.sh                   # check and install, in that order
#   scripts/device/feed-install.sh --case all        # check, pin, install - the pin needs a candidate
#   scripts/device/feed-install.sh --expect 0.0.12   # the candidate this run expects (default 0.0.10)
#   AB_EXPECT=0.0.12 scripts/device/feed-install.sh  # the same, for a caller that sets an environment
#   scripts/device/feed-install.sh --feed-url https://mirror.example/n5105/feed/v1
#   scripts/device/feed-install.sh --release-base https://gh-proxy.com/https://github.com
#   scripts/device/feed-install.sh --index-file /tmp/index.txt   # no host network
#   AB_PAYLOAD_DIR=payloads scripts/device/feed-install.sh --case pin  # the payload it installs
#   AB_DRY_RUN=1 scripts/device/feed-install.sh      # print the steps, touch nothing
#
# --expect is the candidate the run expects: the flag wins, AB_EXPECT is the same knob for a
# caller that assembles an environment instead of a command line, and 0.0.10 is the default.
# The pin case pins the release one patch below the candidate (0.0.12 -> 0.0.11), because a
# pin equal to the candidate installs normally and would pass its judgements for free.
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
#   ok [ac-3] ab-upgrade --feed --yes exit=74 while UPDATE_PIN=0.0.11 held the machine
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
# Where a payload for the version under test is looked for on this host. The pin case is the
# only case that needs one: it installs a named file while the pin is set, which is how the
# "the pin never reaches the explicit payload path" judgement is made against the real CLI.
AB_PAYLOAD_DIR=${AB_PAYLOAD_DIR:-payloads}
DRY_RUN=${AB_DRY_RUN:-0}

expect=${AB_EXPECT:-0.0.10}
conf=/etc/ab/update.conf
feed_url=""
release_base=""
index_file=""
cases=""

usage() {
    sed -n '10,26p' "$0"
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            # The acceptance names are accepted as aliases, so a token copied out of a red
            # row (`ac-3`, `ac-13`) is the same request as the case name the driver uses.
            case "${2:-}" in
                check | ac-12) cases=check ;;
                install | ac-13) cases=install ;;
                pin | ac-3) cases=pin ;;
                both) cases=both ;;
                all) cases=all ;;
                *) printf 'feed-install.sh: --case takes check, install, pin, both or all\n' >&2; usage ;;
            esac
            shift 2
            ;;
        --expect) expect=${2:?--expect needs a platform version}; shift 2 ;;
        --conf) conf=${2:?--conf needs a path}; shift 2 ;;
        --feed-url) feed_url=${2:?--feed-url needs a url}; shift 2 ;;
        --release-base) release_base=${2:?--release-base needs a url}; shift 2 ;;
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

# _release_field <KEY>: one value of the running slot's /etc/platform-release, empty when
# the file or the key is missing. One reader, because PLATFORM_VERSION (which must move) and
# UPSTREAM_VERSION (which must not) are read off the same file and have to be read the same way.
_release_field() {
    _out=$(dev_ssh 'cat /etc/platform-release 2>/dev/null' 2>/dev/null) || _out=""
    printf '%s\n' "${_out}" | sed -n "s/^${1:?_release_field needs a key}=//p" | head -n 1
}

# _release_installed: the platform version the running slot records.
_release_installed() {
    _release_field PLATFORM_VERSION
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
        pin-write-failed)
            _fail "${_case}" "the pin could not be written to the config file (reason=${_reason})" \
                "ls -l /etc/ab/update.conf; df -k /etc"
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
    [ -n "${release_base}" ] && check_cmd="${check_cmd} --release-base '${release_base}'"
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
        printf '%s 6/6 expect slot=committed=<other>, PLATFORM_VERSION=%s, esp=ok, generation +1,\n' \
            "${_case}" "${expect}"
        printf '%s     UPSTREAM_VERSION unchanged, and action=commit in the ring log\n' "${_case}"
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
    before_generation=$(status_field "${before_status}" generation) || before_generation=""
    before_version=$(_release_installed)
    before_upstream=$(_release_field UPSTREAM_VERSION)

    install_cmd="ab-upgrade --feed --yes"
    [ -n "${feed_url}" ] && install_cmd="${install_cmd} --feed-url '${feed_url}'"
    [ -n "${release_base}" ] && install_cmd="${install_cmd} --release-base '${release_base}'"
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
    # boot= and esp= are the two facts a machine cannot claim without evidence (lib.sh, the
    # `status` subcommand): how this boot started, and what the initramfs that started it
    # thought of the ESP. Asserting only boot= leaves a payload whose bootloader write went
    # half-way reporting green, which is the one write a machine cannot undo by itself.
    _assert_eq "${_case}" "esp" "$(status_field "${settled}" esp)" "ok" \
        "ab-slot status; ab-slot log   # esp= is the initramfs's verdict on the ESP it started from"

    # generation is the counter that only grows and it moves when the payload is laid down,
    # not when it commits (measured: 5 -> 6 at install, 6 after the commit boot), so the
    # install under test is exactly one generation per payload.
    case "${before_generation}" in
        '' | *[!0-9]*)
            _fail "${_case}" \
                "generation could not be read before the install (${before_generation:-empty}), so the advance cannot be asserted" \
                "ab-slot status"
            ;;
        *)
            _assert_eq "${_case}" "generation" "$(status_field "${settled}" generation)" \
                "$((before_generation + 1))" \
                "ab-slot status   # one payload laid down advances it by one (before: ${before_generation})"
            ;;
    esac

    version_after=$(_release_installed)
    _assert_eq "${_case}" "PLATFORM_VERSION" "${version_after}" "${expect}" \
        "cat /etc/platform-release   # before this run it was ${before_version:-unknown}"

    # The platform release moves and the base underneath it does not: a same-base update
    # replaces the platform layer and leaves the upstream tree alone, and an UPSTREAM_VERSION
    # that followed it would mean the payload rewrote the tree this case never meant to touch.
    upstream_after=$(_release_field UPSTREAM_VERSION)
    if [ -z "${before_upstream}" ] || [ -z "${upstream_after}" ]; then
        _fail "${_case}" \
            "UPSTREAM_VERSION could not be read on both sides (before='${before_upstream}' after='${upstream_after}')" \
            "cat /etc/platform-release"
    else
        _assert_eq "${_case}" "UPSTREAM_VERSION" "${upstream_after}" "${before_upstream}" \
            "cat /etc/platform-release   # the platform release moves; the base under it must not"
    fi

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

# --------------------------------------------------------------------------- #
# ac-3: the pin holds the automatic path, and only the automatic path
#
# PRD: `ab-upgrade --pin <ver>` 后 `--feed-check` 给 status=pinned 退 0、`--feed` 给 exit 74
# reason=feed-pinned、`--unpin` 后回到 status=update 退 10、pin 期间显式 payload 仍可装、
# 非法 pin 值给 pin-invalid-version. Every one of the five is read off the command an
# operator runs; the config file is read once, to prove the machine was put back the way it
# was. A driver that re-read UPDATE_PIN to decide `status=pinned` would stop testing the
# command it claims to test.
#
# The pin sits below the candidate (and at or above the running release), which is the state
# docs/update.md calls "held": a pin equal to the candidate installs normally, so it would
# pass judgement 2 without proving anything. The case therefore needs a machine one release
# behind and says so, instead of reporting a red row about a release that is fine.
#
# What it leaves behind: nothing pending - the payload it installs is abandoned at once,
# because a pending slot is a machine that switches at the next boot - and no pin, which is
# also the state it refuses to start from. What does stay is the other slot's payload, which
# is a slot write and not a half-install: it is never booted here, the next install (ac-13, or
# the same payload by hand) overwrites it, and `ab-slot gc` reaps the layer once the state
# stops referencing it.
# --------------------------------------------------------------------------- #

# _version_before <MAJOR.MINOR.PATCH>: the release one patch below, or nothing. This project
# ships 0.0.N, so "candidate - 1" is a patch step; a version with no such predecessor (patch
# 0, or anything that is not three numbers) is refused here rather than guessed at.
_version_before() {
    case "${1:-}" in
        '' | *[!0-9.]*) return 1 ;;
    esac
    printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    _vb_patch=$(printf '%s' "$1" | awk -F. '{ print $NF }')
    [ "${_vb_patch}" -gt 0 ] || return 1
    printf '%s.%s\n' "$(printf '%s' "$1" | sed 's/\.[0-9]*$//')" "$((_vb_patch - 1))"
}

# _pin_value: UPDATE_PIN as the machine's config carries it; empty when the line is absent.
_pin_value() {
    dev_ssh "sed -n 's/^UPDATE_PIN=//p' '${conf}'" 2>/dev/null | head -n 1
}

# _ab_upgrade <command>: one ab-upgrade invocation on the machine. PIN_OUT is what it said
# (stdout and stderr together), PIN_RC its exit code. The output is echoed with the same
# `| ` prefix the two cases above use, so a red row still carries the machine's own words.
PIN_OUT=""
PIN_RC=0
_ab_upgrade() {
    PIN_OUT=$(dev_ssh "$1" 2>&1)
    PIN_RC=$?
    printf '  $ %s\n' "$1" >&2
    [ -n "${PIN_OUT}" ] && printf '%s\n' "${PIN_OUT}" | sed 's/^/  | /' >&2
    return 0
}

# _pin_field <field>: one field of the `platform=` machine line PIN_OUT carries.
_pin_field() {
    status_field "$(printf '%s\n' "${PIN_OUT}" | grep -E '^platform=' | head -n 1)" \
        "${1:?_pin_field needs a field}"
}

# _pin_reason: the reason of the refusal PIN_OUT carries; empty when it is not a refusal.
_pin_reason() {
    printf '%s\n' "${PIN_OUT}" | sed -n 's/^ab-upgrade: refused, reason=//p' | head -n 1
}

# _pin_say: the sentence the command printed about itself.
_pin_say() {
    printf '%s\n' "${PIN_OUT}" | sed -n 's/^ab-upgrade: //p' | head -n 1
}

# _pin_on_machine <path>: is this file already on the machine? A read, so it says nothing
# about the pin - the case is about what ab-upgrade refuses, not about what is lying around.
_pin_on_machine() {
    dev_ssh "test -f '$1'" >/dev/null 2>&1
}

# _pin_payload: the payload an operator would name while the pin is set - the `ab-upgrade
# <file>` case, which docs/update.md says ignores the pin entirely. Three places hold one, in
# the order this run is likelier to find it: the host's payload directory (pushed the way
# matrix.sh pushes one), a copy an earlier matrix/scenario hop left in /tmp, and the download
# the feed itself kept. Sets _PIN_PAYLOAD_PATH (empty when none of them is there) and
# _PIN_PAYLOAD_WHY, which the GAP line quotes.
_PIN_PAYLOAD_PATH=""
_PIN_PAYLOAD_WHY=""
_pin_payload() {
    _pp_local="${AB_PAYLOAD_DIR}/payload-${expect}.tar"
    _pp_name=""
    _PIN_PAYLOAD_PATH=""
    if [ -f "${_pp_local}" ]; then
        _pp_remote="${AB_REMOTE_TMP}/payload-${expect}.tar"
        if dev_push "${_pp_local}" "${_pp_remote}" >/dev/null 2>&1; then
            _PIN_PAYLOAD_PATH=${_pp_remote}
            return 0
        fi
        _PIN_PAYLOAD_WHY="the payload at ${_pp_local} could not be pushed to ${_pp_remote}"
        return 1
    fi
    # The index is read only here, when there is no local payload to push: it is what names
    # the file the feed kept on the machine, and reading it is a network round trip.
    _pp_name=$(_index_entry "${expect}" 2>/dev/null | sed -n 's/^payload=//p')
    for _pp_there in "${AB_REMOTE_TMP}/payload-${expect}.tar" \
        "${AB_DEVICE_FEED_DIR}/${_pp_name:-n5105-ab-${expect}.tar}"; do
        if _pin_on_machine "${_pp_there}"; then
            _PIN_PAYLOAD_PATH=${_pp_there}
            return 0
        fi
    done
    _PIN_PAYLOAD_WHY="no ${_pp_local} on this host, and none of ${AB_REMOTE_TMP}/payload-${expect}.tar or ${AB_DEVICE_FEED_DIR}/${_pp_name:-n5105-ab-${expect}.tar} is on the machine"
    return 1
}

# _pin_abandon_pending: clear a slot the payload install armed. A pending slot is a machine
# that switches at the next boot, and leaving one behind is the half-installed state this case
# must not produce - so the install step clears it at once, and the restore calls this again as
# the net that catches a path which failed before that point.
_pin_abandon_pending() {
    _pap_status=$(dev_status 2>/dev/null) || _pap_status=""
    _pap_pending=$(status_field "${_pap_status}" pending) || _pap_pending=""
    if [ -z "${_pap_pending}" ] || [ "${_pap_pending}" = "none" ]; then
        return 0
    fi
    _pap_out=$(dev_ssh 'ab-slot abandon' 2>&1)
    _pap_rc=$?
    [ -n "${_pap_out}" ] && printf '%s\n' "${_pap_out}" | sed 's/^/  | /' >&2
    if [ "${_pap_rc}" -eq 0 ]; then
        _ok "${_case}" "slot ${_pap_pending} abandoned: nothing switches slots on the next boot"
    else
        _fail "${_case}" "ab-slot abandon exited ${_pap_rc}; slot ${_pap_pending} is still pending" \
            "ab-slot abandon; ab-slot status"
    fi
}

# _pin_restore: put the machine back the way the case found it, on every path out of the five
# judgements. Nothing may stay pending (see _pin_abandon_pending), and the pin goes away: the
# case refuses to start on a machine that arrived with one, so "unpin" is the state it found.
_pin_restore() {
    _pin_abandon_pending
    _ab_upgrade "ab-upgrade --unpin"
    if [ "${PIN_RC}" -ne 0 ]; then
        _fail "${_case}" "ab-upgrade --unpin exited ${PIN_RC} while restoring the machine (reason=$(_pin_reason))" \
            "ab-upgrade --unpin; grep UPDATE_PIN ${conf}"
    fi
    _pr_pin=$(_pin_value) || _pr_pin=""
    _assert_eq "${_case}" "UPDATE_PIN" "${_pr_pin:-none}" "none" \
        "sed -n 's/^UPDATE_PIN=//p' ${conf}   # the case leaves no pin behind"
    _pr_after=$(dev_status 2>/dev/null) || _pr_after=""
    _assert_eq "${_case}" "pending_after" "$(status_field "${_pr_after}" pending)" "none" "ab-slot status"
    _assert_eq "${_case}" "committed_after" "$(status_field "${_pr_after}" committed)" "${pin_committed}" \
        "ab-slot status   # the pin case never moves the committed slot"
}

# _pin_steps: the five judgements of ac-3, in the order the acceptance names them. Each one
# reads the command's own output and moves the counters, so a step that fails still lets the
# next one be measured instead of hiding four answers behind one red line.
_pin_steps() {
    # 1) --pin, then --feed-check answers status=pinned and exits 0: a held machine is not
    #    nagged (docs/update.md, "Holding a machine on one release").
    _ab_upgrade "ab-upgrade --pin ${pin_ver}"
    if [ "${PIN_RC}" -eq 0 ]; then
        _ok "${_case}" "$(_pin_say) (ab-upgrade --pin ${pin_ver})"
    else
        _fail "${_case}" "ab-upgrade --pin ${pin_ver} exited ${PIN_RC} (reason=$(_pin_reason))" \
            "ab-upgrade --pin ${pin_ver}; grep UPDATE_PIN ${conf}"
    fi
    _ab_upgrade "ab-upgrade --feed-check${pin_flags}"
    if [ "${PIN_RC}" -ne 0 ]; then
        _fail "${_case}" \
            "ab-upgrade --feed-check exited ${PIN_RC} while UPDATE_PIN=${pin_ver} (reason=$(_pin_reason)); a held machine has to answer and exit 0" \
            "ab-upgrade --feed-check; ab-upgrade --unpin"
    else
        _ok "${_case}" "ab-upgrade --feed-check exit=0 while UPDATE_PIN=${pin_ver}"
        _assert_eq "${_case}" "status" "$(_pin_field status)" "pinned" \
            "ab-upgrade --feed-check   # status=update would mean the pin did not take"
        _assert_eq "${_case}" "pin" "$(_pin_field pin)" "${pin_ver}" \
            "ab-upgrade --feed-check   # the line has to name the pin it obeyed"
    fi

    # 2) --feed refuses: exit 74, and feed-pinned is the reason the machine names.
    _ab_upgrade "ab-upgrade --feed --yes${pin_flags}"
    if [ "${PIN_RC}" -eq 74 ]; then
        _ok "${_case}" "ab-upgrade --feed --yes exit=74 while held by the pin"
        _assert_eq "${_case}" "reason" "$(_pin_reason)" "feed-pinned" \
            "ab-upgrade --feed-check   # read platform_available= next to pin="
    elif [ "${PIN_RC}" -eq 0 ]; then
        _fail "${_case}" \
            "ab-upgrade --feed --yes installed while UPDATE_PIN=${pin_ver} held the machine (exit=0); the pin did not stop the automatic path" \
            "ab-slot status; ab-slot abandon   # the case clears whatever this wrote"
    else
        _fail "${_case}" "ab-upgrade --feed --yes exited ${PIN_RC} with the pin set (reason=$(_pin_reason))" \
            "ab-upgrade --feed --yes; ab-slot log"
    fi

    # 3) --unpin puts the automatic path back: status=update and exit 10 again.
    _ab_upgrade "ab-upgrade --unpin"
    if [ "${PIN_RC}" -eq 0 ]; then
        _ok "${_case}" "$(_pin_say) (ab-upgrade --unpin)"
    else
        _fail "${_case}" "ab-upgrade --unpin exited ${PIN_RC} (reason=$(_pin_reason))" "ab-upgrade --unpin"
    fi
    _ab_upgrade "ab-upgrade --feed-check${pin_flags}"
    if [ "${PIN_RC}" -ne 10 ]; then
        _fail "${_case}" \
            "ab-upgrade --feed-check exited ${PIN_RC} after --unpin (status=$(_pin_field status), reason=$(_pin_reason)); the automatic path has to come back" \
            "ab-upgrade --feed-check; grep UPDATE_PIN ${conf}"
    else
        _ok "${_case}" "ab-upgrade --feed-check exit=10 again after --unpin"
        _assert_eq "${_case}" "status" "$(_pin_field status)" "update" \
            "ab-upgrade --feed-check   # status=pinned would mean the pin outlived --unpin"
    fi

    # 4) The pin never reaches the explicit payload path: a named file still installs. The
    #    pin is set again first, because that is the state this judgement is about.
    _ab_upgrade "ab-upgrade --pin ${pin_ver}"
    if [ "${PIN_RC}" -ne 0 ]; then
        _fail "${_case}" \
            "the pin could not be set again for the payload judgement (exit=${PIN_RC} reason=$(_pin_reason))" \
            "ab-upgrade --pin ${pin_ver}"
    fi
    _pin_payload
    if [ -z "${_PIN_PAYLOAD_PATH}" ]; then
        _gap "${_case}" "no payload to name while the pin is set (${_PIN_PAYLOAD_WHY})" \
            "AB_PAYLOAD_DIR=payloads scripts/device/feed-install.sh --case pin --expect ${expect}"
    else
        _ab_upgrade "ab-upgrade ${_PIN_PAYLOAD_PATH}"
        case "${PIN_RC}" in
            0)
                _ok "${_case}" "ab-upgrade ${_PIN_PAYLOAD_PATH} exit=0 with UPDATE_PIN=${pin_ver} set"
                _pin_target=$(printf '%s\n' "${PIN_OUT}" | grep -E '^ab-upgrade: installed ' | head -n 1 |
                    sed -n 's/.*into slot \([ab]\).*/\1/p')
                if [ -z "${_pin_target}" ]; then
                    _fail "${_case}" "no 'installed ... into slot ...' line while pinned" \
                        "ab-upgrade ${_PIN_PAYLOAD_PATH}; ab-slot status"
                elif [ "${_pin_target}" = "${pin_slot}" ]; then
                    _fail "${_case}" "the payload went into the running slot ${_pin_target}" "ab-slot status"
                else
                    _ok "${_case}" "installed into slot ${_pin_target}, not the running slot ${pin_slot}"
                    _assert_eq "${_case}" "pending" "$(dev_status_field pending 2>/dev/null)" \
                        "${_pin_target}" \
                        "ab-slot status   # the install arms that slot; the case abandons it before it ends"
                    # Armed for at most the length of these two commands: nothing may be left
                    # that would boot the other slot on a power cut or an operator reboot.
                    _pin_abandon_pending
                fi
                ;;
            74)
                _pin_why=$(_pin_reason)
                case "${_pin_why}" in
                    payload-*)
                        _gap "${_case}" \
                            "the machine refused the payload this host named (reason=${_pin_why}); the pin itself never came into it" \
                            "AB_PAYLOAD_DIR=payloads scripts/device/feed-install.sh --case pin --expect ${expect}"
                        ;;
                    *)
                        _fail "${_case}" "ab-upgrade ${_PIN_PAYLOAD_PATH} was refused (reason=${_pin_why})" \
                            "ab-upgrade ${_PIN_PAYLOAD_PATH}; ab-slot log"
                        ;;
                esac
                ;;
            *)
                _fail "${_case}" "ab-upgrade ${_PIN_PAYLOAD_PATH} exited ${PIN_RC} with the pin set" \
                    "ab-upgrade ${_PIN_PAYLOAD_PATH}; ab-slot log"
                ;;
        esac
    fi

    # 5) A pin value that is not MAJOR.MINOR.PATCH is refused, and the refusal leaves the pin
    #    it found alone (docs/update.md lists pin-invalid-version).
    _ab_upgrade "ab-upgrade --pin 1.2"
    if [ "${PIN_RC}" -eq 74 ]; then
        _ok "${_case}" "ab-upgrade --pin 1.2 exit=74"
        _assert_eq "${_case}" "reason" "$(_pin_reason)" "pin-invalid-version" \
            "ab-upgrade --pin 1.2   # docs/update.md, the refusal table"
    else
        _fail "${_case}" "ab-upgrade --pin 1.2 exited ${PIN_RC}, expected exit 74 pin-invalid-version" \
            "ab-upgrade --pin 1.2"
    fi
    _pin_held=$(_pin_value) || _pin_held=""
    _assert_eq "${_case}" "UPDATE_PIN_after_refusal" "${_pin_held:-none}" "${pin_ver}" \
        "sed -n 's/^UPDATE_PIN=//p' ${conf}   # a refused pin must not touch the pin it found"
    return 0
}

run_pin() {
    _case=ac-3
    CASE_STATUS=""
    pin_ver=""
    pin_flags=""
    pin_committed=""
    pin_slot=""
    pin_ver=$(_version_before "${expect}") || pin_ver=""

    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/5 ab-upgrade --pin %s, then ab-upgrade --feed-check: expect status=pinned pin=%s exit=0\n' \
            "${_case}" "${pin_ver:-?}" "${pin_ver:-?}"
        printf '%s 2/5 ab-upgrade --feed --yes: expect exit=74 reason=feed-pinned\n' "${_case}"
        printf '%s 3/5 ab-upgrade --unpin, then ab-upgrade --feed-check: expect status=update exit=10\n' "${_case}"
        printf '%s 4/5 ab-upgrade --pin %s, then ab-upgrade %s/payload-%s.tar: it has to install into the other slot\n' \
            "${_case}" "${pin_ver:-?}" "${AB_PAYLOAD_DIR}" "${expect}"
        printf '%s 5/5 ab-upgrade --pin 1.2: expect exit=74 reason=pin-invalid-version\n' "${_case}"
        printf '%s     restore: abandon whatever the payload armed, then ab-upgrade --unpin\n' "${_case}"
        CASE_NOTE="dry-run"
        CASE_STATUS=PASS
        return 0
    fi

    require_idle_machine "${_case}" || {
        CASE_STATUS=GAP
        return 1
    }

    if [ -z "${pin_ver}" ]; then
        _fail "${_case}" \
            "no release can be named below ${expect}, so nothing can hold the candidate (--expect must be MAJOR.MINOR.PATCH with a patch above 0)" \
            "scripts/device/feed-install.sh --case pin --expect 0.0.12"
        CASE_STATUS=FAIL
        return 1
    fi

    # A machine that arrives pinned is not the state this case was written for: it would have
    # to guess whether to put the pin back, and its "after --unpin" judgement would be about
    # somebody else's pin. Say so, with the command that clears it, instead of reporting a
    # red row against the release.
    pin_before=$(_pin_value) || pin_before=""
    if [ -n "${pin_before}" ]; then
        _gap "${_case}" \
            "this machine already carries UPDATE_PIN=${pin_before}; the case starts unpinned so its unpin judgement is its own" \
            "ab-upgrade --unpin   # then run the case again"
        CASE_STATUS=GAP
        return 1
    fi

    pin_slot=$(status_field "${STATUS_LINE}" slot) || pin_slot=""
    pin_committed=$(status_field "${STATUS_LINE}" committed) || pin_committed=""
    [ -n "${feed_url}" ] && pin_flags="${pin_flags} --feed-url '${feed_url}'"
    [ -n "${release_base}" ] && pin_flags="${pin_flags} --release-base '${release_base}'"

    # The source has to offer something above the running release, or status=pinned cannot be
    # told from status=current and the pin is tested against nothing at all.
    _ab_upgrade "ab-upgrade --feed-check${pin_flags}"
    case "${PIN_RC}" in
        10) : ;;
        74)
            _classify_refusal "${_case}" "$(_pin_reason)"
            CASE_STATUS=FAIL
            [ "${CASE_GAPS}" -gt 0 ] && CASE_STATUS=GAP
            return 1
            ;;
        *)
            _fail "${_case}" \
                "the feed offers nothing above what this machine runs (exit=${PIN_RC} status=$(_pin_field status)); the pin case needs a machine one release behind" \
                "scripts/device/feed-install.sh --case pin   # before --case install, on a machine below ${expect}"
            CASE_STATUS=FAIL
            return 1
            ;;
    esac
    _ok "${_case}" "precondition: a candidate is offered (platform_available=$(_pin_field platform_available))"
    _assert_eq "${_case}" "platform_available" "$(_pin_field platform_available)" "${expect}" \
        "gh release view --json tagName -q .tagName; ab-upgrade --feed-check"
    # The index the payload fallback reads is the source the machine just reported, recorded
    # the same way ac-12 records it.
    FEED_URL_SEEN=$(status_field "$(printf '%s\n' "${PIN_OUT}" | grep -E '^source=' | head -n 1)" feed) || FEED_URL_SEEN=""

    _pin_steps
    _pin_restore

    if [ "${CASE_FAILURES}" -gt 0 ]; then
        CASE_STATUS=FAIL
        return 1
    fi
    if [ "${CASE_GAPS}" -gt 0 ]; then
        CASE_STATUS=GAP
        return 1
    fi
    CASE_NOTE="pin ${pin_ver} held the automatic path and released it; committed ${pin_committed:-?} never moved"
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
        ac-3) run_pin ;;
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

# _skip_case <case> <why>: a case that could not run, recorded with a reason instead of a
# verdict - the same row shape the ac-13 skip under `both` has always written, so the results
# file still has one row per case and no PASS means "nothing was measured".
_skip_case() {
    printf 'note [%s] %s\n' "$1" "$2"
    CASE_GAPS=$((CASE_GAPS + 1))
    GAPS=$((GAPS + 1))
    mkdir -p "$(dirname "${AB_FEED_INSTALL_RESULTS}")" 2>/dev/null || true
    printf '%s\tGAP\t%s\t%s\n' "$1" "${AB_HOST}" "$2" >>"${AB_FEED_INSTALL_RESULTS}"
    printf '== %s GAP %s\n' "$1" "$2"
}

_rc_all=0
case "${cases}" in
    check) run_case ac-12 || _rc_all=1 ;;
    install) run_case ac-13 || _rc_all=1 ;;
    pin) run_case ac-3 || _rc_all=1 ;;
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
    all)
        # The order is fixed by what each case needs: ac-3 pins a machine that still has a
        # candidate, and ac-13 is the case that takes the candidate away. Both read the feed
        # ac-12 reads, so a GAP there skips them instead of inventing two derived red rows.
        run_case ac-12 || _rc_all=1
        _all_feed=${CASE_STATUS:-FAIL}
        for _all_case in ac-3 ac-13; do
            if [ "${_all_feed}" = "GAP" ]; then
                _skip_case "${_all_case}" "skipped, ac-12 could not read the feed"
            else
                run_case "${_all_case}" || _rc_all=1
            fi
        done
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
