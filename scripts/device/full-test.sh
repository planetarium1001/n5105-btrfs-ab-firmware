#!/bin/sh
# full-test.sh - one run of the whole device acceptance suite, in one order, with one verdict.
#
# The drivers next to this file each answer one question and each write their own rows:
#
#   probes.sh          the baseline of a freshly flashed machine
#   feed-install.sh    ac-12/ac-13/ac-3  the feed has a candidate and the machine takes it
#   matrix.sh          M1..M7  does a version jump keep a bootable machine
#   scenarios.sh       S1..S8  does the user's data and software survive it
#   docker-probe.sh    D1  then D2+D3  a real docker payload across the hop
#   software-probe.sh  the community samples install on 25.x and keep their own config
#   badconfig-probe.sh fake and broken configurations, and whether anything else reacted
#   matrix-round2.sh   the platform rise then the base down/up chain, with samples on board
#   package-revert.sh  P1..P4/U1  the package snapshot and the offline way back
#   recovery-probe.sh  R1/B1   a bad version rolls itself back; `ab-slot rollback`
#   power-cut.sh       I1..I2  an interrupted candidate boot is not retried forever
#   release-verify.sh  ac-1    the published release carries what the PRD says
#   evidence-audit.sh  every ac of the PRD is backed by evidence under the name it uses
#
# docker-probe.sh appears twice on purpose: one driver, two windows. D1 takes the baseline
# before the phases that still switch a slot and reboot (package-revert U1, recovery,
# power-cut); D2/D3 judge the same store after them, and both windows name the same snapshot
# directory. It is still one script with --case, not two scripts: the comparator and the
# capture have to be the same code on both sides of the hop or the comparison means nothing.
#
# Run by hand, that is ten commands in an order a person has to remember, ten result files a
# person has to add up, and a preflight nobody runs because the matrix says "unreachable" a
# minute later anyway. This script is the one order and the one verdict:
#
#   scripts/device/full-test.sh --dry-run            # the plan, nothing touched
#   scripts/device/full-test.sh --preflight-only     # is this machine even the one?
#   scripts/device/full-test.sh --yes --task <id>    # the whole suite
#   scripts/device/full-test.sh --yes --from matrix  # continue after probes passed
#   scripts/device/full-test.sh --yes --only M3 --only M4
#   scripts/device/full-test.sh --yes --stop-after scenarios
#
# Per phase it writes two files - results/<phase>.log and results/<phase>.tsv - and the two
# side directories a driver owns: results/docker-snapshots (one snapshot per docker window)
# and results/release (the downloaded release assets ac-1 is judged on):
#
#   results/<phase>.log   everything the phase printed, plus its start/result markers
#   results/<phase>.tsv   rows in the one shape the whole project reads:
#                         case<TAB>verdict<TAB>evidence<TAB>note
#
# The rows are the phase driver's own: every one of them already has a results channel
# (--results, or AB_*_RESULTS), so this script points that channel at its per-phase file
# instead of parsing prose out of the log. Only when a phase exits without a row does the
# orchestrator write one, so "exit 0 and said nothing" can never read as a silent pass.
#
# After the last phase it puts the machine back: software-probe.sh writes its samples into the
# apps' real config files, and only its --cleanup restores them. That sweep is not a phase (no
# --only or --from can select or skip it); it writes results/sweep.log and its own rows file
# results/sweep-driver.tsv, and contributes exactly one row - `sweep`, PASS or GAP, never FAIL -
# because a cleanup that did not finish is a bookkeeping finding, not a product defect.
#
# Verdict (ac-7): the per-phase files are concatenated into results/verdict.tsv, and
#
#   verdict: PASS   no row is FAIL and no row is GAP    (exit 0)
#   verdict: GAP    nothing failed, something was not decided   (exit 1)
#   verdict: FAIL   at least one row is FAIL            (exit 1)
#
# The sweep row takes part in that arithmetic like any other, but it can only ever be a GAP:
# the driver's own rows (including the FAIL it records when it cannot put something back) go to
# results/sweep-driver.tsv, which no phase owns and this file never concatenates.
#
# Exit status: 0 PASS, 1 not PASS, 2 bad usage.
#
# Red lines:
#   * a destructive phase (matrix, recovery, power-cut) writes slots and reboots the
#     device, so it needs --yes or a typed `yes`; a refusal is recorded as GAP, never as
#     a pass;
#   * --dry-run executes nothing at all: no ssh, no mkdir, no results file;
#   * a preflight failure stops the run before a single slot is written. A preflight that
#     cannot confirm the machine is the one under test is a FAIL line, never a skip;
#   * a phase whose script is not installed is a GAP row, not an omission: "we did not
#     ask" and "the machine said yes" must not look the same in the record;
#   * the audit phase is handed this round's task id (--task or AB_TASK_ID). With none it
#     writes a GAP row and says what is missing; it never falls back to the previous
#     round's task id, because auditing a stale record reads as a green audit of this one.
#
# Two phases need a file this host has to have, and both were recorded as GAPs in the round
# of 2026-11-19 for want of one rather than for want of a product:
#
#   package-classes  the local class needs a body no feed offers. --local-apk auto is handed
#                    over unless the operator named a body (AB_PKGCLASS_LOCAL_APK) or a kept
#                    package (AB_PKGCLASS_LOCAL_PKG), so the class is measured instead of
#                    reported as `local:no-body`. See package-classes.sh's header for what
#                    the built body is and is not.
#   matrix2          its REL case reads the v0.0.12 assets offline, and the round never named
#                    a directory: the row said `no asset directory for v0.0.12 (got 'unset')`
#                    on a case that needs no machine at all. --release-dir (or
#                    AB_FULLTEST_RELEASE_DIR) names one, and the default is the directory the
#                    fetch command in that same row fills (see _matrix2_release_dir).

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT

# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

# The order is the acceptance order of ac-7 and it is not negotiable. The dependencies that
# decide it, because a reader will otherwise "fix" it into the list the drivers are named in:
#
#   probes first        the baseline of a machine nobody has touched yet
#   feed-install next   ac-12/ac-13/ac-3 need a machine BELOW the candidate: the feed has to
#                       offer something newer than what runs, and the pin case is about
#                       holding that candidate. matrix and scenarios (also scenarios S1's
#                       pkgcycle and the S3/S4 hops) bring the machine up to the newest
#                       release, so feed-install after them fails on a healthy machine by
#                       construction - the "update" is simply not there any more.
#   docker              D1, the baseline of a real docker payload. It must be taken BEFORE
#                       matrix and scenarios, because those two are the version jumps this
#                       baseline exists to survive: a machine that is already at the newest
#                       release has nothing to jump to, and D2 would answer "no jump" instead
#                       of "the store survived one". D1 pulls real images, starts a container
#                       and a named volume, and commits an image - it writes the docker store
#                       (@docker under /opt/docker) and /tmp, never a slot or the ESP.
#   matrix, scenarios   the version jumps, with the docker payload already in place
#   docker-after        D2 and D3, immediately after the jumps they judge: did the images,
#                       the container's and volume's bytes, and the subvolume identities
#                       survive the upgrade and the downgrade
#   software            the community samples (LuCI theme, software station, proxy app) are
#                       installed HERE and not earlier: they go on the release the jumps
#                       above landed on, which is the state a user actually installs things
#                       on, and installing them before the jumps would make every scenario
#                       row above judge a machine that is no longer the product baseline
#   follow              installs the community sample set and records the baseline the matrix
#                       judges ("still usable after the hop, configuration and data intact");
#                       it writes state on this side, because the machine's /tmp does not
#                       survive the hop it describes. matrix.sh reads it through AB_FOLLOW_STATE.
#   badconfig           right after software, because the broken /etc/config/<app>, the
#                       broken daemon.json and the fake subscription are the samples' own
#                       files: before software there is nothing to break, and after matrix2
#                       a broken configuration would be carried across a boot
#   matrix2             the round-2 chain: platform rise, base down 25.12.2->1->0, base up
#                       0->1->2. It runs last of the three because it is what carries the
#                       samples and their configs across the hops, and because it writes
#                       slots and reboots the machine (it is in DESTRUCTIVE_PHASES)
#   package-revert      P1..P4 (U1 only by name: it upgrades the machine's packages)
#   recovery, power-cut the destructive pair: a bad version rolls back, an interrupted
#                       candidate is not retried for ever
#   release             ac-1 on the published release (no machine involved)
#   audit last          it judges the record every phase above just wrote
#
# R1 (recovery) is the one phase that needs a file this host has to have: a candidate whose
# runtime is broken, so its first boot fails its health check and the machine has to come back
# on the committed slot. The orchestrator names it the way every other driver names a payload -
# <payload-dir>/payload-<expect>.tar - and when that file is not here the row says so, with the
# path, instead of the phase quietly asking the driver for nothing. B1 (`ab-slot rollback`)
# needs no payload and is asked for either way.
#
# docker and docker-after are one script in two windows, not two scripts: D1 writes
# <results>/docker-snapshots/before.snapshot, docker-after reads it and writes after.snapshot
# in the same directory. Neither one switches a slot or reboots.
PHASES="preflight probes feed-install docker follow feed-history matrix rise scenarios docker-after software package-classes badconfig matrix2 platform-chain package-revert recovery power-cut release audit"
# A phase that writes a slot, reboots the machine, or both. docker, docker-after and release
# are deliberately NOT here: docker-probe.sh keeps its images, container, committed image and
# named volume in the docker store (@docker, under /opt/docker) plus logs under /tmp, and it
# writes no slot, no ESP entry and no boot decision; release-verify.sh does not reach a
# machine at all. software and badconfig are not here either: software-probe.sh installs
# packages and writes /etc/config/<app> on the running system, badconfig-probe.sh injects and
# restores those same files, and neither installs a payload, writes a slot or reboots.
# matrix2 IS here: it is the round-2 chain of payload installs, so it writes slots and
# reboots like matrix.sh, and a run without --yes must record a GAP rather than jump.
DESTRUCTIVE_PHASES="matrix rise matrix2 platform-chain recovery power-cut"
# Phases whose "no verdict" exit (3) is a GAP and not a FAIL: the question could not be put
# to the machine or to the network (a dead mirror, an unreachable release, a machine that was
# not in a state the case needs). A GAP is still not a pass, but it must not turn the whole
# round red - PRD risk 3 says a mirror outage is not a defect of this product. matrix,
# scenarios, package-revert, recovery and power-cut keep their own meaning of exit 3 (the red
# line stopped the run) and stay FAIL when they write no row. software, badconfig and matrix2
# are in the same group as matrix: their exit 3 is the red line that stopped the run (a
# 24.x/opkg machine, a sample layer that cannot be installed at all), which is a FAIL of the
# round and not a GAP; a missing precondition is exit 4, which is a GAP for every phase.
GAP_EXIT_PHASES="feed-install docker docker-after release feed-history"
# The probes a caller may name with --only; probes.sh owns these names.
PROBE_NAMES="grow network wan22 key platform adapter initrd packages"

RESULTS_DIR=${AB_FULLTEST_RESULTS:-results}
PAYLOAD_DIR=${AB_FULLTEST_PAYLOAD_DIR:-}
# --allow-stale-payload: go on even though a base payload's platform layer was built from
# other code than this checkout. Preflight refuses that by default, because a payload built
# before a fix was committed installs the old code and makes every jump measure it while the
# round reports on the new version - the 2026-11-19 round lost a full run to exactly that and
# read the result as "the fix did not work". The flag is for the one honest use, reproducing
# what the stale payload does; a run that uses it says so in its preflight row.
ALLOW_STALE_PAYLOAD=${AB_FULLTEST_ALLOW_STALE_PAYLOAD:-0}
# The task this round's evidence is audited against: --task wins, AB_TASK_ID is the same
# knob for a caller that assembles an environment. Empty is allowed and is not a fallback:
# see the audit phase below.
TASK_ID=${AB_TASK_ID:-}
# The candidate the feed is expected to offer (feed-install.sh --expect). Empty means "use
# the driver's own default" - this script does not know which release is under acceptance,
# and a version hardcoded here would keep claiming it long after the release moved on.
EXPECT=${AB_EXPECT:-}
# The release the release phase reads back. Empty means "v + this checkout's VERSION", which
# is right for a tag on the release line and wrong for a preview: a preview is published as
# v0.1.0-rc.2 over VERSION 0.1.0, so the derived tag v0.1.0 names a release that does not
# exist and the phase comes back `no-such-release` about bytes nobody published. The tag is
# stated by whoever starts the round, because this script cannot know which preview is under
# acceptance - and a value hardcoded here would keep claiming it after the next one ships.
RELEASE_TAG=${AB_RELEASE_TAG:-}
FEED_URL=${AB_FEED_URL:-}
# Both docker phases read and write this one directory: D1 leaves before.snapshot, D2/D3
# read it back and write after.snapshot. Overridable, but it must be the SAME value for both
# phases - two directories would leave D2 comparing against nothing.
DOCKER_SNAPSHOT_DIR=${AB_FULLTEST_DOCKER_SNAPSHOT_DIR:-}
# Where matrix2's REL case reads the v0.0.12 release assets. Empty means "use the default
# _matrix2_release_dir computes", which is the directory its own fetch command fills.
RELEASE_ASSET_DIR=${AB_FULLTEST_RELEASE_DIR:-}
FROM_PHASE=""
FROM_INDEX=""
STOP_AFTER=""
STOP_INDEX=""
ONLY_CASES=""
ASSUME_YES=0
DRY_RUN=0
PREFLIGHT_ONLY=0
# --list: print the phases and exit before anything else is decided. It is the one flag that
# answers "which phases exist, in which order" without a plan, a results directory or a
# machine, and it reads the same PHASES string the run loop reads - a second copy of the
# order would be a list that answers for phases the run does not have.
LIST_ONLY=0
# Set by the run loop when R1's payload is not on this host: recovery-probe.sh is then asked
# for the remaining cases only, and R1 is recorded as the GAP it is (see _recovery_payload_gap).
_RECOVERY_SKIP_R1=0

# Below this a phase is not started: an install writes tens of MiB into the inactive
# slot and the payload is kept on /data, so a nearly full disk fails in the middle of a
# transaction instead of before it.
MIN_FREE_MB=${AB_FULLTEST_MIN_FREE_MB:-256}

SKIPPED=0
PHASE_REPORT=""
TSV=""
LOG=""

usage() {
    cat <<'USAGE'
usage: full-test.sh [--list] [--dry-run] [--preflight-only] [--from PHASE]
                    [--stop-after PHASE] [--only CASE]... [--results DIR]
                    [--payload-dir DIR] [--task ID] [--expect VERSION]
                    [--release-tag TAG] [--yes]

  Runs the device acceptance suite in one order:
      preflight probes feed-install docker follow feed-history matrix rise
      scenarios docker-after software package-classes badconfig matrix2
      platform-chain package-revert recovery power-cut release audit

  --help               print this and exit 0
  --list               print the phases in the order they run, one per line, and exit;
                       nothing is executed, no results directory is made and no machine
                       is contacted. This is also the answer to "which phases exist":
                       a phase missing from this list is not registered at all
  --dry-run            print the plan for every phase and exit; nothing is executed
                       against the machine and no results file is written. The payload
                       content gate still reads the payloads' own bytes, through a
                       temporary directory that it removes again
  --preflight-only     run preflight and stop there; its rows are the whole result
  --from PHASE         start at PHASE; every phase before it is skipped
  --only CASE          run only the phases that own CASE; repeatable
                         M1..M7 matrix      S1..S8 scenarios     P1..P4/U1 package-revert
                         D1 docker          D2/D3 docker-after   R1../B1.. recovery
                         I1/I2 power-cut    ac-12/ac-13/ac-3 feed-install
                         verdict/sums/index release              grow/network/... probes
                         (feed-install also takes check, install, pin, both and all)
                       software/badconfig/matrix2/package-classes are named by the phase
                       itself, and so are rise, platform-chain and feed-history
  --stop-after PHASE   stop once PHASE has run
  --results DIR        where <phase>.log, <phase>.tsv, verdict.tsv, summary.txt, the
                       docker snapshots, the release assets and the bad-config defect
                       list (badconfig-defects.tsv) go (default: results)
  --payload-dir DIR    directory holding payload-<version>.tar; preflight refuses to
                       start when it is given and holds no payload-*.tar, and when any
                       payload declares a platform layer other than the one its role
                       requires: a base payload must carry this checkout's VERSION, a
                       platform payload (payload-0.0.NN.tar) the version in its name. A
                       payload built from older code makes every jump measure the old code
                       while the round reports on the new version. The version alone is not
                       enough: a payload built before a fix was committed declares the same
                       version and carries the old file, so every base payload's platform
                       layer is also compared file by file with this checkout's platform/
                       tree, and a difference is a preflight FAIL. matrix,
                       scenarios and matrix2 jump from here, and the recovery phase takes
                       R1's candidate from here as payload-<VERSION>.tar
  --allow-stale-payload
                       go on when a base payload's platform layer was built from other code
                       than this checkout. The preflight row that refuses such a payload is
                       then a PASS that names the flag and the files that differ, so the
                       round's own record says it measured other code than the one under
                       acceptance. The version check is not relaxed by this flag
  --task ID            the task whose evidence the audit phase reads (also AB_TASK_ID).
                       Without one the audit is a GAP row: it will not read the previous
                       round's record just because that id is still around
  --expect VERSION     the candidate the feed is expected to offer (feed-install.sh
                       --expect). It also names the payload R1 installs:
                       payload-<VERSION>.tar. Default: the drivers' own
  --release-tag TAG    the release the release phase reads back (also AB_RELEASE_TAG).
                       Default: v + this checkout's VERSION, which is right on the release
                       line. A preview is published as v0.1.0-rc.2 over VERSION 0.1.0, so a
                       preview round has to name its tag or the phase asks about a release
                       that was never published
  --release-dir DIR    the v0.0.12 assets matrix2's REL case reads (also
                       AB_FULLTEST_RELEASE_DIR). REL needs no machine: it compares a
                       published release's bytes with its own index.txt, so an empty
                       directory is a GAP about a file, not about the product. Default:
                       <payload-dir>/release-v0.0.12, which is what
                       `gh release download v0.0.12 --dir <payload-dir>/release-v0.0.12`
                       fills. The row names the path it was given either way.
  --yes                allow the destructive phases (matrix, rise, matrix2,
                       platform-chain, recovery, power-cut); without it they ask for a
                       typed `yes` and are recorded as GAP when refused. docker,
                       docker-after, release, software, package-classes and badconfig
                       never write a slot and never reboot, so they are not in that set

  A phase that already has only PASS rows in its results file is skipped, so a rerun
  continues where the last one stopped. Remove results/<phase>.tsv to force a phase.

  Verdict: 'verdict: PASS' when no row is FAIL and no row is GAP, 'verdict: GAP' when
  nothing failed but something was not decided, 'verdict: FAIL' otherwise.
  Exit status: 0 only on PASS, 1 otherwise, 2 bad usage.
USAGE
}

# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

# _in_list <word> <list>: is the word one of the space separated list.
_in_list() {
    case " ${2} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

# _phase_index <phase>: its position in the acceptance order, or 1 when it is not a phase.
_phase_index() {
    _pi_n=0
    for _pi_p in ${PHASES}; do
        if [ "${_pi_p}" = "${1}" ]; then
            printf '%s\n' "${_pi_n}"
            return 0
        fi
        _pi_n=$((_pi_n + 1))
    done
    return 1
}

# _phase_script <phase>: the driver that answers this phase, empty for preflight (which
# is this script's own work: nothing else may decide that the machine is reachable).
_phase_script() {
    case "${1}" in
        probes) printf '%s\n' "${DEVICE_DIR}/probes.sh" ;;
        feed-install) printf '%s\n' "${DEVICE_DIR}/feed-install.sh" ;;
        matrix) printf '%s\n' "${DEVICE_DIR}/matrix.sh" ;;
        scenarios) printf '%s\n' "${DEVICE_DIR}/scenarios.sh" ;;
        # One driver, two windows: D1 before the switches that follow this phase, D2/D3 after
        # them. Same script, same snapshot directory, only --case differs.
        docker | docker-after) printf '%s\n' "${DEVICE_DIR}/docker-probe.sh" ;;
        # The round-2 drivers. They are named as they are on disk so that "the phase exists"
        # and "the driver exists" stay one question: a file that is not here is the GAP row
        # the run loop writes, with the path in it.
        software) printf '%s\n' "${DEVICE_DIR}/software-probe.sh" ;;
        # Records what "still usable" will be judged against, before the chain hops the base.
        # matrix.sh reads the same state file through AB_FOLLOW_STATE.
        follow) printf '%s\n' "${DEVICE_DIR}/follow-baseline.sh" ;;
        badconfig) printf '%s\n' "${DEVICE_DIR}/badconfig-probe.sh" ;;
        matrix2) printf '%s\n' "${DEVICE_DIR}/matrix-round2.sh" ;;
        # The three chains this round added. Each is one driver and one verdict like the
        # round-2 ones above, so they are wired the same way.
        rise) printf '%s\n' "${DEVICE_DIR}/matrix-rise.sh" ;;
        platform-chain) printf '%s\n' "${DEVICE_DIR}/platform-chain.sh" ;;
        package-classes) printf '%s\n' "${DEVICE_DIR}/package-classes.sh" ;;
        feed-history) printf '%s\n' "${DEVICE_DIR}/feed-history.sh" ;;
        package-revert) printf '%s\n' "${DEVICE_DIR}/package-revert.sh" ;;
        recovery) printf '%s\n' "${DEVICE_DIR}/recovery-probe.sh" ;;
        power-cut) printf '%s\n' "${DEVICE_DIR}/power-cut.sh" ;;
        release) printf '%s\n' "${DEVICE_DIR}/release-verify.sh" ;;
        audit) printf '%s\n' "${DEVICE_DIR}/evidence-audit.sh" ;;
        *) printf '%s\n' "" ;;
    esac
}

# _phase_owns <phase> <case>: does --only CASE belong to this phase.
# The tokens are the drivers' own case names, so a caller who has just read a red row
# (`rerun: matrix.sh --case M3`) can ask for exactly that case. feed-install also accepts
# the acceptance names as aliases (ac-12/ac-3), which is how a row names its case.
_phase_owns() {
    case "${1}" in
        probes) _in_list "${2}" "${PROBE_NAMES}" ;;
        matrix) case "${2}" in M[0-9]) return 0 ;; esac; return 1 ;;
        # S[0-9] covers S8 (the four broken configurations) as well as S1..S7.
        scenarios) case "${2}" in S[0-9]) return 0 ;; esac; return 1 ;;
        # P[0-9] covers P3 (payload tampering) and P4 (cross-base); U1 is a name of its own
        # because it changes the machine's packages and is never part of the default set.
        package-revert) case "${2}" in P[0-9] | U1) return 0 ;; esac; return 1 ;;
        recovery) case "${2}" in R[0-9] | B[0-9]) return 0 ;; esac; return 1 ;;
        power-cut) case "${2}" in I[0-9]) return 0 ;; esac; return 1 ;;
        # D1 is the baseline and belongs to the segment before the switches; D2 and D3 are
        # judged after them. --only D1 must not run docker-after and vice versa.
        docker) case "${2}" in D1) return 0 ;; esac; return 1 ;;
        docker-after) case "${2}" in D2 | D3) return 0 ;; esac; return 1 ;;
        feed-install)
            case "${2}" in ac-12 | ac-13 | ac-3 | check | install | pin | both | all) return 0 ;; esac
            return 1
            ;;
        # release-verify.sh prints one line per check; these are the clauses of ac-1 plus the
        # phase name itself, so `--only release` (and any single clause) selects it.
        release) case "${2}" in verdict | sums | index | release) return 0 ;; esac; return 1 ;;
        # The three round-2 phases are selected by their own name and nothing else. Their
        # case vocabularies (sample names, injection names, hop names) belong to the drivers,
        # and a second copy here would be a list that drifts from the one the driver reads;
        # `--only software` asks for the whole phase, which is what a caller who read a red
        # row in software.tsv needs. matrix2's own --from/--only stay available on the driver
        # itself, whose rerun line the row carries.
        software | badconfig | matrix2) [ "${2}" = "${1}" ] ;;
        # The chains this round added, selected by their phase name alone for the same
        # reason: their case vocabularies belong to the drivers.
        rise | platform-chain | package-classes | feed-history) [ "${2}" = "${1}" ] ;;
        *) return 1 ;;
    esac
}

# _phase_selected_cases <phase>: the --only tokens this phase owns, space separated.
_phase_selected_cases() {
    _psc_out=""
    for _psc_c in ${ONLY_CASES}; do
        _phase_owns "${1}" "${_psc_c}" && _psc_out="${_psc_out} ${_psc_c}"
    done
    printf '%s' "${_psc_out}"
}

# _phase_wanted <phase>: 0 when the phase is in the run at all under --only.
# preflight and audit are the frame of every run: a case selected with --only is still
# judged on a machine that was checked first, and still lands in an audited record.
_phase_wanted() {
    [ -n "${ONLY_CASES}" ] || return 0
    case "${1}" in
        preflight | audit) return 0 ;;
    esac
    for _pw_c in ${ONLY_CASES}; do
        _phase_owns "${1}" "${_pw_c}" && return 0
    done
    return 1
}

# _feed_case_args <tokens>: feed-install.sh takes one --case value, not a list, so the
# selected tokens are folded into the single value that asks for them. The combinations with
# no value of their own (check+pin, install+pin) become `all`, which is the driver's own
# documented order check -> pin -> install; running a superset is the only honest choice when
# the driver cannot be asked for that pair, and the plan prints the value so it is visible.
_feed_case_args() {
    _fca_check=0
    _fca_install=0
    _fca_pin=0
    _fca_all=0
    for _fca_t in $1; do
        case "${_fca_t}" in
            ac-12 | check) _fca_check=1 ;;
            ac-13 | install) _fca_install=1 ;;
            ac-3 | pin) _fca_pin=1 ;;
            all) _fca_all=1 ;;
            both) _fca_check=1; _fca_install=1 ;;
        esac
    done
    if [ "${_fca_all}" = 1 ] || { [ "${_fca_check}" = 1 ] && [ "${_fca_install}" = 1 ] && [ "${_fca_pin}" = 1 ]; }; then
        printf 'all'
    elif [ "${_fca_check}" = 1 ] && [ "${_fca_install}" = 1 ]; then
        printf 'both'
    elif [ "${_fca_pin}" = 1 ] && { [ "${_fca_check}" = 1 ] || [ "${_fca_install}" = 1 ]; }; then
        printf 'all'
    elif [ "${_fca_check}" = 1 ]; then
        printf 'check'
    elif [ "${_fca_install}" = 1 ]; then
        printf 'install'
    elif [ "${_fca_pin}" = 1 ]; then
        printf 'pin'
    fi
}

# _checkout_version: the version this checkout declares, empty when it declares none.
# One reader for the two places that need it (the payload platform check and the release
# tag), so "which version is this repository" cannot be answered two ways in one run.
_checkout_version() {
    _cv=$(sed -n '1p' "${AB_REPO_ROOT}/VERSION" 2>/dev/null)
    _cv=$(printf '%s' "${_cv}" | sed 's/[[:space:]]*$//')
    [ -n "${_cv}" ] || return 1
    printf '%s\n' "${_cv}"
}

# _release_tag: the tag of the release this round accepts - `v` + the checkout's VERSION.
#
# The release phase reads a published release of this project, and the number that names it
# is the checkout's own. It is deliberately not derived from --expect: that value is the
# candidate the feed offers and the payload R1 installs, and a round that starts on the
# upstream 25.12.2 base names it as 25.12.2 while the release under acceptance is v0.0.13.
# Measured 2026-11-19: `v25.12.2` was asked for, the driver answered `no-such-release`, and
# the row read as a defect of a release that had nothing wrong with it.
_release_tag() {
    if [ -n "${RELEASE_TAG}" ]; then
        printf '%s\n' "${RELEASE_TAG}"
        return 0
    fi
    _rt_version=$(_checkout_version) || return 1
    printf 'v%s\n' "${_rt_version}"
}

# _release_staged_dir: the payload directory, when it is also a release asset directory.
# release-verify.sh has no --payload-dir: its offline switch is --dir, and that directory has
# to hold the release's own assets (index.txt, SHA256SUMS, the image and the payload). A
# directory of payload-*.tar alone is NOT one of those, and pointing --dir at it would make
# every asset check skip - a GAP on every run, for a reason that is not the release. So the
# flag is handed over only when the directory actually carries release assets.
_release_staged_dir() {
    [ -n "${PAYLOAD_DIR}" ] || return 1
    [ -d "${PAYLOAD_DIR}" ] || return 1
    [ -f "${PAYLOAD_DIR}/index.txt" ] || [ -f "${PAYLOAD_DIR}/SHA256SUMS" ] || return 1
    printf '%s\n' "${PAYLOAD_DIR}"
}

# _matrix2_release_dir: where matrix2's REL case reads the v0.0.12 release assets.
#
# REL is the one case of the whole run that needs no machine: it compares a published
# release's bytes with the index.txt that release publishes. It was still a GAP on every
# attempt of the 2026-11-19 round, because nothing ever named a directory - `no asset
# directory for v0.0.12 (got 'unset')` on a case that cannot fail for want of a device.
#
# The default is the directory the fetch command in that row fills, so the row's advice and
# this default are one answer instead of two: `gh release download v0.0.12 --dir
# <payloads>/release-v0.0.12`. It sits beside the payloads because both are downloaded
# build artifacts (payloads/.gitignore'd, payloads/README.md), and because the v0.0.12
# payload inside it is the same layer payload-0.0.12.tar carries.
#
# The path is passed whether or not it exists: a directory that is not there yet is a fact
# the driver reports with the path in it, which is a better GAP than one about `unset`.
_matrix2_release_dir() {
    if [ -n "${RELEASE_ASSET_DIR}" ]; then
        printf '%s\n' "${RELEASE_ASSET_DIR}"
        return 0
    fi
    printf '%s/release-v0.0.12\n' "${PAYLOAD_DIR:-payloads}"
}

# _package_classes_local_args: how the local class of the three-class chain is supplied.
#
# The driver answers `local:no-body` and names the flags when nothing supplies a body, which
# is right for an operator standing in front of the machine: "which package is the local
# sample" is an environment fact. A round, though, has to measure the class rather than
# report the fixture it did not bring, so this script asks the driver to build one.
#
# An operator's own body wins, and is left to the driver: AB_PKGCLASS_LOCAL_APK and
# AB_PKGCLASS_LOCAL_PKG are the driver's own knobs, and a value there means somebody has
# already answered the question. Passing --local-apk auto over it would replace a real
# operator body with a fixture and quietly weaken the proof.
_package_classes_local_args() {
    if [ -n "${AB_PKGCLASS_LOCAL_APK:-}" ] || [ -n "${AB_PKGCLASS_LOCAL_PKG:-}" ]; then
        return 0
    fi
    printf -- '--local-apk auto '
}

# _recovery_cases <selected>: the R1/B1 tokens the recovery phase will run, with the
# driver's own default (R1 B1) spelled out. Which cases this phase covers has to have one
# answer here, because the payload below is required by R1 alone: a phase that reads its case
# list in two places would one day skip R1 for a payload B1 does not need.
_recovery_cases() {
    _rc_sel=$(printf '%s' "${1:-}" | sed 's/^ *//; s/ *$//')
    if [ -z "${_rc_sel}" ]; then
        printf 'R1 B1'
        return 0
    fi
    printf '%s' "${_rc_sel}"
}

# _recovery_drop_r1 <cases>: the same list without R1.
_recovery_drop_r1() {
    _rdr_out=""
    for _rdr_c in ${1:-}; do
        [ "${_rdr_c}" = "R1" ] || _rdr_out="${_rdr_out}${_rdr_out:+ }${_rdr_c}"
    done
    printf '%s' "${_rdr_out}"
}

# _recovery_payload: the candidate R1 installs, by the convention the other drivers already
# share - payloads/payload-<version>.tar with the version this round accepts (--expect or
# AB_EXPECT, the same knob feed-install.sh --expect and the release phase read). Empty when no
# version was named: a path built around an empty version (payloads/payload-.tar) would be a
# GAP about the wrong thing, and "no version was named" is answered in _recovery_payload_gap.
_recovery_payload() {
    [ -n "${EXPECT}" ] || return 1
    printf '%s\n' "${PAYLOAD_DIR:-payloads}/payload-${EXPECT}.tar"
    return 0
}

# _recovery_payload_gap: why R1 cannot be put to the machine this round, empty when it can.
# The path is part of the reason on purpose. "no payload" on its own sends the reader to the
# driver's own default, and the driver's default is the same directory with a version in it -
# the one thing the reason has to name is the file this orchestration meant.
_recovery_payload_gap() {
    if [ -z "${EXPECT}" ]; then
        printf '%s' "R1 has no candidate to install: no --expect and no AB_EXPECT, so the payloads/payload-<version>.tar convention names nothing; pass --expect <version> (or queue a candidate on the machine and run recovery-probe.sh --case R1 --installed)"
        return 0
    fi
    _rpg_file=$(_recovery_payload) || return 0
    if [ ! -f "${_rpg_file}" ]; then
        printf '%s' "R1 has no candidate to install: ${_rpg_file} is not on this host; put payload-${EXPECT}.tar there, or pass --payload-dir <dir> holding it"
        return 0
    fi
    return 0
}

# _phase_args <phase>: the arguments, from the flags each driver already supports.
# Nothing here invents an option: probes takes --probe, the matrix and the scenarios take
# --case/--payload-dir/--results/--evidence-dir, the case drivers take --case,
# docker-probe.sh takes --case/--snapshot-dir, release-verify.sh takes --dir/--tag/
# --work-dir and evidence-audit.sh takes --task.
_phase_args() {
    _pa_sel=$(_phase_selected_cases "${1}")
    case "${1}" in
        probes)
            for _pa_c in ${_pa_sel}; do
                printf '%s %s ' "--probe" "${_pa_c}"
            done
            ;;
        matrix | scenarios)
            for _pa_c in ${_pa_sel}; do
                printf '%s %s ' "--case" "${_pa_c}"
            done
            if [ -n "${PAYLOAD_DIR}" ]; then
                printf '%s %s ' "--payload-dir" "${PAYLOAD_DIR}"
            fi
            printf '%s %s ' "--results" "${TSV}"
            printf '%s %s ' "--evidence-dir" "${RESULTS_DIR}/evidence"
            ;;
        docker | docker-after)
            if [ -z "${_pa_sel}" ]; then
                # The two segments carry different default case sets. docker-probe.sh's own
                # default is D1 D2 D3, and a docker-after that ran D1 would overwrite the
                # baseline it was asked to compare with.
                if [ "${1}" = "docker" ]; then
                    _pa_sel=" D1 "
                else
                    _pa_sel=" D2 D3 "
                fi
            fi
            for _pa_c in ${_pa_sel}; do
                printf '%s %s ' "--case" "${_pa_c}"
            done
            printf '%s %s ' "--snapshot-dir" "${DOCKER_SNAPSHOT_DIR:-${RESULTS_DIR}/docker-snapshots}"
            ;;
        # The chains this round added carry their rows and their evidence the same way the
        # round-2 drivers do: --results is the row channel this script reads back, and the
        # payload directory is handed over only when the round has one, because a driver
        # told about an empty directory would look for a payload that is not there.
        rise | platform-chain | package-classes)
            printf '%s %s ' "--results" "${TSV}"
            printf '%s %s ' "--evidence-dir" "${RESULTS_DIR}/evidence"
            if [ -n "${PAYLOAD_DIR}" ]; then
                printf '%s %s ' "--payload-dir" "${PAYLOAD_DIR}"
            fi
            if [ "${1}" = "package-classes" ]; then
                # The local class is one third of ac-12, and a run that leaves it to the
                # driver's own `local:no-body` answers two thirds of the acceptance item.
                _pa_local=$(_package_classes_local_args)
                [ -n "${_pa_local}" ] && printf '%s' "${_pa_local}"
            fi
            ;;
        feed-history)
            # Its one positional argument is the release to ask about, and the round already
            # has that answer: --expect is what feed-install was told to expect, and an empty
            # --expect means "ask the driver's own default", not "ask about nothing".
            printf '%s %s ' "--results" "${TSV}"
            if [ -n "${EXPECT}" ]; then
                printf '%s ' "${EXPECT}"
            fi
            ;;
        software | follow | badconfig | matrix2)
            # The round-2 drivers take their rows channel as --results, the same flag this
            # script already uses for matrix, scenarios, docker-probe and release-verify, so
            # one phase's rows land in one file and _phase_verdict can read them. Nothing
            # else is invented here: their own defaults cover everything they were written to
            # judge, and an argument this script guessed wrong would be a driver exit 2 that
            # reads like a product defect. Two channels are handed over because the round
            # owns them and the driver cannot guess them: see below.
            printf '%s %s ' "--results" "${TSV}"
            case "${1}" in
                follow)
                    # The baseline this phase writes is the one matrix.sh judges against;
                    # handing over the path is what makes "which file is the baseline" one
                    # answer for the run instead of one per driver.
                    printf '%s %s ' "--state" "${AB_FOLLOW_STATE}"
                    ;;
                badconfig)
                    # "who refused it / who restored it" is a defect candidate, and the
                    # driver drops those when it has no file to write them to. It goes under
                    # the results directory, beside the rows, so one round's candidates are
                    # in one place for the defect list (ac-11) to read.
                    printf '%s %s ' "--defects" "${RESULTS_DIR}/badconfig-defects.tsv"
                    ;;
                matrix2)
                    # matrix2 jumps payload to payload, so it is told where this round keeps
                    # them, exactly like matrix and scenarios. Without the flag it would fall
                    # back to its own default (payloads) and jump from a directory the round
                    # never filled.
                    if [ -n "${PAYLOAD_DIR}" ]; then
                        printf '%s %s ' "--payload-dir" "${PAYLOAD_DIR}"
                    fi
                    # REL reads a published release's own bytes and needs no machine, so the
                    # directory is named here whether or not it has been filled yet: the row
                    # then carries the path and the command that fills it.
                    printf '%s %s ' "--release-dir" "$(_matrix2_release_dir)"
                    ;;
            esac
            ;;
        package-revert | power-cut)
            for _pa_c in ${_pa_sel}; do
                printf '%s %s ' "--case" "${_pa_c}"
            done
            ;;
        recovery)
            # R1's candidate is the payload this round accepts, named the way the other
            # drivers name theirs (payloads/payload-<version>.tar). Without it the driver
            # answers `GAP [R1] no --payload given and --installed is not set`, which is how
            # the rollback evidence of ac-11 once went missing from a whole round: every
            # phase ran, and the orchestration simply never named a file. B1
            # (`ab-slot rollback`) needs no payload, so it is asked for either way.
            _pa_cases=$(_recovery_cases "${_pa_sel}")
            if [ "${_RECOVERY_SKIP_R1}" = "1" ]; then
                _pa_cases=$(_recovery_drop_r1 "${_pa_cases}")
            fi
            for _pa_c in ${_pa_cases}; do
                printf '%s %s ' "--case" "${_pa_c}"
            done
            case " ${_pa_cases} " in
                *" R1 "*)
                    _pa_payload=$(_recovery_payload) || _pa_payload=""
                    if [ -n "${_pa_payload}" ]; then
                        printf '%s %s ' "--payload" "${_pa_payload}"
                    fi
                    ;;
            esac
            ;;
        feed-install)
            # A run that says nothing runs all three cases: ac-3 (the pin) is only provable
            # while the machine is below the candidate, which is exactly the window this
            # phase has (it runs right after probes). The driver's own default, `both`, would
            # leave ac-3 unmeasured in every full run.
            _pa_fc=$(_feed_case_args "${_pa_sel}")
            [ -n "${_pa_fc}" ] || _pa_fc=all
            printf '%s %s ' "--case" "${_pa_fc}"
            if [ -n "${EXPECT}" ]; then
                printf '%s %s ' "--expect" "${EXPECT}"
            fi
            # A feed the caller hosts itself (a mirror under construction, or the release
            # candidate before it is published) is named with AB_FEED_URL. Without it the
            # driver asks the machine's own configured source, which is what a released
            # round should use: the question "does the published feed carry this release"
            # only has one honest answer once the release exists.
            if [ -n "${FEED_URL}" ]; then
                printf '%s %s ' "--feed-url" "${FEED_URL}"
            fi
            ;;
        release)
            _pa_dir=""
            _pa_dir=$(_release_staged_dir) || _pa_dir=""
            if [ -n "${_pa_dir}" ]; then
                printf '%s %s ' "--dir" "${_pa_dir}"
            fi
            # The tag the release phase reads is this project's own release, and the only
            # place that number is written is the checkout's VERSION: `v` + VERSION.
            #
            # --expect is NOT it. --expect is the candidate the feed offers and the payload
            # R1 installs, which this round names as the upstream base (25.12.2), while the
            # release being accepted is v0.0.13. Deriving the tag from --expect asked for
            # `v25.12.2` and the driver answered `no-such-release`: a red row against a
            # release nobody published, on a run where nothing was wrong with the release.
            # The two numbers are different versions of different things and are kept apart.
            _pa_tag=$(_release_tag) || _pa_tag=""
            if [ -n "${_pa_tag}" ]; then
                printf '%s %s ' "--tag" "${_pa_tag}"
            fi
            # Keep the downloaded assets beside the results: they are the evidence for ac-1,
            # and release-verify.sh removes a temporary work directory on exit.
            printf '%s %s ' "--work-dir" "${RESULTS_DIR}/release"
            ;;
        audit)
            if [ -n "${TASK_ID}" ]; then
                printf '%s %s ' "--task" "${TASK_ID}"
            fi
            ;;
    esac
    return 0
}

# _phase_env <phase>: the results channel of a driver that has no --results flag, one
# KEY=VALUE per word (the same space-separated convention as the arguments above; a path with
# a space in it does not survive either). probes.sh, package-revert.sh, recovery-probe.sh,
# power-cut.sh and feed-install.sh each append their own four (or five) column rows through a
# variable of their own, and docker-probe.sh reads the orchestrator's AB_RESULTS.
_phase_env() {
    case "${1}" in
        probes) printf 'AB_PROBE_RESULTS=%s' "${TSV}" ;;
        package-revert) printf 'AB_PKG_RESULTS=%s' "${TSV}" ;;
        recovery) printf 'AB_RECOVERY_RESULTS=%s' "${TSV}" ;;
        power-cut) printf 'AB_POWER_RESULTS=%s' "${TSV}" ;;
        feed-install)
            # AB_PAYLOAD_DIR is how feed-install.sh names the payload the pin case installs;
            # --payload-dir here means the same directory, so the two are pointed at one place.
            printf 'AB_FEED_INSTALL_RESULTS=%s' "${TSV}"
            if [ -n "${PAYLOAD_DIR}" ]; then
                printf ' AB_PAYLOAD_DIR=%s' "${PAYLOAD_DIR}"
            fi
            ;;
        docker | docker-after) printf 'AB_RESULTS=%s' "${TSV}" ;;
        *) printf '' ;;
    esac
}

# _phase_plan <phase>: the one line --dry-run prints for a phase. It is the command that
# would run, so the plan cannot drift away from the run.
_phase_plan() {
    _pp_script=$(_phase_script "${1}")
    if [ "${1}" = "preflight" ]; then
        printf 'internal: key file, ssh reachability, platform identity, free space on %s and /data, payload-dir contents, payload content against the checkout' \
            "${AB_P4_MOUNT}"
        # The content gate is answered here as well as in _preflight: it reads this host's
        # files, so a plan can state its verdict without touching the machine, and a plan
        # that stayed silent about it would hide the stale-payload case until after a slot
        # was written.
        _pp_gate=$(_payload_content_gate_plan)
        [ -n "${_pp_gate}" ] && printf '%s' "${_pp_gate}"
        return 0
    fi
    # An audit with no task id is not a plan to audit anything: it would read the previous
    # round's record. The plan says what was missing instead, and the run records it as GAP.
    if [ "${1}" = "audit" ] && [ -z "${TASK_ID}" ]; then
        printf '%s --task <id> (no task id: pass --task or set AB_TASK_ID; without one this phase is a GAP row, not an audit of the previous round)' \
            "${_pp_script}"
        return 0
    fi
    _pp_args=$(_phase_args "${1}")
    _pp_env=$(_phase_env "${1}")
    if [ ! -f "${_pp_script}" ]; then
        printf '%s%s (script not present, would be recorded GAP)' \
            "${_pp_env:+${_pp_env} }" "${_pp_script}"
        return 0
    fi
    # Whether R1 can run is decided by a file on this host, so the plan can say it before
    # anything is executed: the command is printed as it would run, and the GAP it would
    # produce is named next to it instead of being discovered by the phase.
    _pp_tail=""
    if [ "${1}" = "recovery" ]; then
        _pp_why=$(_recovery_payload_gap)
        [ -n "${_pp_why}" ] && _pp_tail="   # R1 would be a GAP: ${_pp_why}"
    fi
    printf '%s%s%s%s' "${_pp_env:+${_pp_env} }" "${_pp_script}" "${_pp_args:+ ${_pp_args}}" "${_pp_tail}"
}

# --------------------------------------------------------------------------- #
# preflight
# --------------------------------------------------------------------------- #

# The questions a run cannot answer for itself once it has written a slot. Each one is a row
# of its own (`preflight-key`, `preflight-ssh`, ...) so a rerun that skips the section on an
# all-PASS file has really asked every one of them.
_preflight_pass() { # <check> <detail>
    printf 'preflight: ok %s %s\n' "${1}" "${2}"
    AB_RESULTS="${TSV}"
    record "preflight-${1}" PASS "${LOG}" "${2}"
}

_preflight_fail() { # <check> <reason>
    printf 'preflight: FAIL %s\n' "${2}"
    AB_RESULTS="${TSV}"
    record "preflight-${1}" FAIL "${LOG}" "${2}"
    return 1
}

# _payload_platform <tar>: the platform version the payload's own manifest declares, empty
# when the tar carries no readable one.
#
# The manifest is the only offline statement of which code layer a payload installs, and it
# is what this check has to read: the slot is written later, on the machine, from bytes this
# host has not unpacked yet. Both member spellings are tried because archives differ on
# whether they store "manifest.json" or "./manifest.json", and reading the wrong spelling
# would look like a payload without a manifest.
_payload_platform() {
    _plp_tar=${1:?}
    _plp_doc=""
    for _plp_member in manifest.json ./manifest.json; do
        if _plp_doc=$(tar -xOf "${_plp_tar}" "${_plp_member}" 2>/dev/null); then
            break
        fi
        _plp_doc=""
    done
    [ -n "${_plp_doc}" ] || return 0
    printf '%s\n' "${_plp_doc}" \
        | sed -n 's/^[[:space:]]*"platform":[[:space:]]*"\([^"]*\)".*$/\1/p' \
        | head -n 1
}

# _payload_name_version <file>: the version the file name carries, empty when it carries
# none. The same shape matrix-rise.sh reads a payload name for, so "which version is this
# file" has one answer across the drivers.
_payload_name_version() {
    printf '%s\n' "${1##*/}" \
        | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[^0-9]*$/\1/p' \
        | head -n 1
}

# _payload_platform_mismatches <dir> <checkout-version>: one clause per payload that does not
# declare the platform its role requires, empty when every payload agrees.
#
# What this prevents: a payload built before the code under acceptance installs the old
# platform layer, so the run measures the old code while reporting on the new version. The
# symptoms are red rows that read as product defects - measured 2026-11-19, three payloads
# carried platform 0.0.12 while the checkout was 0.0.13, the installed layer's aligner did
# not know the feed layout of the image it was jumped into, no feed was rewritten, and every
# jump ended in `apk ... rc=99`.
#
# The expected value depends on the payload's role, because the two roles have different
# truths:
#   * a base payload (payload-25.12.N.tar) is the product build installed into the slot, so
#     it must carry this checkout's VERSION - that is the code being accepted;
#   * a platform payload (payload-0.0.NN.tar) is one hop of the platform chain, whose point
#     is to move an older layer forward, so it must carry the version its name claims.
#     Requiring VERSION there would forbid the chain instead of checking it.
# A payload whose name carries no version is not a candidate for either role - no driver
# builds a payload name from a version, and payload-bad.tar exists to be refused by the
# machine - so it is counted by the caller and not judged here.
_payload_platform_mismatches() {
    _ppm_dir=${1:?}
    # Not `:?`: an empty expected version is answered by the caller before it gets here, and
    # a `:?` inside a `$(...)` would only end the subshell, leaving an empty result that
    # reads exactly like "every payload agrees".
    _ppm_want=${2-}
    _ppm_bad=""
    for _ppm_f in "${_ppm_dir}"/payload-*.tar; do
        [ -f "${_ppm_f}" ] || continue
        _ppm_name=${_ppm_f##*/}
        _ppm_named=$(_payload_name_version "${_ppm_f}")
        [ -n "${_ppm_named}" ] || continue
        _ppm_expect=${_ppm_want}
        case "${_ppm_named}" in
            0.*) _ppm_expect=${_ppm_named} ;;
        esac
        _ppm_declared=$(_payload_platform "${_ppm_f}")
        if [ -z "${_ppm_declared}" ]; then
            _ppm_bad="${_ppm_bad}${_ppm_bad:+; }${_ppm_name} declares no readable manifest.platform, want ${_ppm_expect}"
        elif [ "${_ppm_declared}" != "${_ppm_expect}" ]; then
            _ppm_bad="${_ppm_bad}${_ppm_bad:+; }${_ppm_name} declares platform ${_ppm_declared}, want ${_ppm_expect}"
        fi
    done
    [ -z "${_ppm_bad}" ] || printf '%s\n' "${_ppm_bad}"
}

# _payload_layer_files <repo-root>: the platform source files a base payload must carry
# unchanged, one path per line, relative to platform/.
#
# The list is derived from the checkout rather than written out here, so a file added to the
# platform tree is covered by the gate the moment it exists. One path is excluded:
# etc/platform-release, which assemble.sh renders at build time from VERSION, the upstream
# label and the stage name. Comparing a rendered file would report a difference on every
# payload, which is how a gate teaches its reader to ignore it. The other generated paths
# (etc/net-defaults.conf, etc/ab/update.conf, the protected-path list, the etc/rc.d links)
# are not in the source tree at all, so they never reach this list.
_payload_layer_files() {
    _plf_root=${1:?}
    [ -d "${_plf_root}/platform" ] || return 0
    ( cd "${_plf_root}/platform" && find . -type f | sed 's|^\./||' | sort ) \
        | while IFS= read -r _plf_rel; do
            case "${_plf_rel}" in
                etc/platform-release) continue ;;
            esac
            printf '%s\n' "${_plf_rel}"
        done
}

# _payload_platform_member <platform.tar> <rel>: one file out of a payload's platform layer.
# Both member spellings are tried because an archive may store "etc/init.d/ab-boot" or
# "./etc/init.d/ab-boot", and reading the wrong one would look like a file the payload does
# not carry.
_payload_platform_member() {
    _ppmem_tar=${1:?}
    _ppmem_rel=${2:?}
    for _ppmem_member in "./${_ppmem_rel}" "${_ppmem_rel}"; do
        if tar -xOf "${_ppmem_tar}" "${_ppmem_member}" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# _payload_content_mismatches <dir> <repo-root>: one clause per base payload whose platform
# layer differs from this checkout's platform/ tree, empty when every base payload agrees.
#
# Why this exists beside _payload_platform_mismatches: the manifest's platform version is a
# label, and a label can be right while the bytes behind it are old. Measured 2026-11-19:
# three payloads declared platform 0.0.13 and the checkout was 0.0.13, so the version gate
# passed them, but their platform.tar had been built at 07:06 while the two fixes the round
# existed for were committed at 15:30. The round then measured the old code and reported the
# fixed defects as still broken - the worst outcome this suite can produce, because it sends
# someone to repair something that already works.
#
# Only base payloads are judged. A platform payload (payload-0.0.NN.tar) is one hop of the
# chain whose whole point is to carry an older layer forward, so holding it to the current
# tree would forbid the chain instead of checking it.
#
# The comparison is file by file over _payload_layer_files, not over the whole tar: the
# build renders files and creates links, and a byte-for-byte tar comparison would report
# those expected differences as staleness.
_payload_content_mismatches() {
    _pcm_dir=${1:?}
    _pcm_root=${2:?}
    _pcm_bad=""
    # The path list goes through a file rather than a variable: `for p in ${list}` would
    # split on IFS *and* glob-expand each word, so a file name containing a `*` would compare
    # something other than the file it names. A `while read` over a file splits on newlines
    # only and runs in this shell, so the differences it finds survive the loop.
    _pcm_work=$(mktemp -d "${TMPDIR:-/tmp}/ab-fulltest-payload.XXXXXX" 2>/dev/null) || {
        # Fail closed, not open: a gate that cannot read the payloads must not answer
        # "every base payload agrees". The caller treats any output as a refusal, so this
        # sentence is what the operator sees instead of a silent pass.
        printf '%s\n' "the payload content gate could not run: cannot create a temporary directory under ${TMPDIR:-/tmp}, so the payloads' code cannot be compared with ${_pcm_root}/platform"
        return 0
    }
    _payload_layer_files "${_pcm_root}" >"${_pcm_work}/files"
    if [ ! -s "${_pcm_work}/files" ]; then
        rm -rf "${_pcm_work}"
        return 0
    fi
    for _pcm_f in "${_pcm_dir}"/payload-*.tar; do
        [ -f "${_pcm_f}" ] || continue
        _pcm_name=${_pcm_f##*/}
        _pcm_named=$(_payload_name_version "${_pcm_f}")
        [ -n "${_pcm_named}" ] || continue
        case "${_pcm_named}" in
            0.*) continue ;;
        esac
        if ! tar -xOf "${_pcm_f}" platform.tar >"${_pcm_work}/platform.tar" 2>/dev/null ||
            [ ! -s "${_pcm_work}/platform.tar" ]; then
            _pcm_bad="${_pcm_bad}${_pcm_bad:+; }${_pcm_name} carries no readable platform.tar, so the code it installs cannot be compared with ${_pcm_root}/platform"
            continue
        fi
        _pcm_diff=""
        while IFS= read -r _pcm_rel; do
            [ -n "${_pcm_rel}" ] || continue
            _pcm_repo="${_pcm_root}/platform/${_pcm_rel}"
            [ -f "${_pcm_repo}" ] || continue
            _pcm_bytes=$(wc -c <"${_pcm_repo}" | tr -d ' ')
            if ! _payload_platform_member "${_pcm_work}/platform.tar" "${_pcm_rel}" \
                >"${_pcm_work}/member" 2>/dev/null; then
                _pcm_diff="${_pcm_diff}${_pcm_diff:+, }${_pcm_rel} (missing from the payload, checkout has ${_pcm_bytes} bytes)"
                continue
            fi
            _pcm_seen=$(wc -c <"${_pcm_work}/member" | tr -d ' ')
            if [ "${_pcm_seen}" = "${_pcm_bytes}" ] && cmp -s "${_pcm_work}/member" "${_pcm_repo}"; then
                continue
            fi
            # The line where the two files part is what a reader needs to see that this is
            # old code and not a different build of the same file. cmp states it for free,
            # but it states "EOF on" instead when one file is a prefix of the other - which
            # is the usual shape of a stale file, because a fix adds code to the end - so
            # both answers are turned into a sentence.
            #
            # Whether one file is a prefix is decided here, from the bytes, and never from
            # cmp's own EOF sentence: GNU cmp appends ", in line N" to it ("cmp: EOF on x
            # after byte 12, in line 2") and BSD cmp does not ("cmp: EOF on x"), so reading
            # the line number out of that message made the same two files a line difference
            # on the CI runner and a truncated file on the laptop. The sentence this gate
            # prints may not depend on which cmp the host happens to install.
            if [ "${_pcm_seen}" -lt "${_pcm_bytes}" ] \
                && head -c "${_pcm_seen}" "${_pcm_repo}" | cmp -s "${_pcm_work}/member" -; then
                _pcm_where=", the payload's copy ends before the checkout's goes on"
            elif [ "${_pcm_seen}" -gt "${_pcm_bytes}" ] \
                && head -c "${_pcm_bytes}" "${_pcm_work}/member" | cmp -s - "${_pcm_repo}"; then
                _pcm_where=", the payload's copy goes on past the checkout's end"
            else
                # The two files part inside the length they share, where "differ: char N,
                # line M" is the one message POSIX fixes for both implementations.
                _pcm_line=$(cmp "${_pcm_work}/member" "${_pcm_repo}" 2>&1 \
                    | sed -n 's/.*line \([0-9][0-9]*\).*/\1/p' | head -n 1)
                if [ -n "${_pcm_line}" ]; then
                    _pcm_where=", first difference at line ${_pcm_line}"
                else
                    _pcm_where=", same size, different bytes"
                fi
            fi
            _pcm_diff="${_pcm_diff}${_pcm_diff:+, }${_pcm_rel} (payload ${_pcm_seen} bytes, checkout ${_pcm_bytes} bytes${_pcm_where})"
        done <"${_pcm_work}/files"
        if [ -n "${_pcm_diff}" ]; then
            _pcm_bad="${_pcm_bad}${_pcm_bad:+; }${_pcm_name} carries a platform layer built from other code: ${_pcm_diff}"
        fi
    done
    rm -rf "${_pcm_work}"
    [ -z "${_pcm_bad}" ] || printf '%s\n' "${_pcm_bad}"
}

# _payload_content_gate_plan: what the content gate would decide, for --dry-run.
#
# The gate is the one preflight question that reads this host's files instead of the
# machine's, so a dry run can answer it without executing anything - and it must: a plan that
# said only "payload-dir contents" would hide the exact stale-payload case the gate exists
# for, and the operator would learn about it after the slots were written.
_payload_content_gate_plan() {
    _pcg_dir=${PAYLOAD_DIR:-payloads}
    [ -d "${_pcg_dir}" ] || return 0
    _pcg_bad=$(_payload_content_mismatches "${_pcg_dir}" "${AB_REPO_ROOT}")
    if [ -z "${_pcg_bad}" ]; then
        printf ' (payload content vs checkout: ok)'
    elif [ "${ALLOW_STALE_PAYLOAD}" = "1" ]; then
        printf ' (payload content vs checkout: STALE, allowed by --allow-stale-payload: %s)' "${_pcg_bad}"
    else
        printf ' (payload content vs checkout: STALE, preflight would FAIL: %s)' "${_pcg_bad}"
    fi
}

_preflight() {
    # 1. the key. BatchMode=yes means a missing key is a wall, not a prompt, so it is
    #    answered here instead of as "the machine is down" three phases later.
    if [ ! -e "${AB_KEY}" ]; then
        _preflight_fail key "key file missing: ${AB_KEY}"
        return 1
    fi
    if [ ! -r "${AB_KEY}" ]; then
        _preflight_fail key "key file not readable: ${AB_KEY}"
        return 1
    fi
    _preflight_pass key "key=${AB_KEY}"

    # 2. the machine. dev_ssh carries the ssh options every driver uses (BatchMode,
    #    IdentitiesOnly, no ControlMaster), so this is the same hop the phases make.
    if ! dev_ssh true >/dev/null 2>&1; then
        _preflight_fail ssh "device unreachable over ssh: ${AB_HOST} (key ${AB_KEY})"
        return 1
    fi
    _preflight_pass ssh "host=${AB_HOST}"

    # 3. the platform identity. A reachable machine that is not this project's image
    #    produces red rows that look like product defects, so the version is read first.
    _pf_plat=$(dev_ssh 'cat /etc/platform-release 2>/dev/null || cat /etc/os-release 2>/dev/null' 2>/dev/null | head -n 20)
    _pf_ver=""
    if [ -n "${_pf_plat}" ]; then
        _pf_ver=$(printf '%s\n' "${_pf_plat}" | sed -n 's/^PLATFORM_VERSION=//p' | head -n 1)
        if [ -z "${_pf_ver}" ]; then
            _pf_ver=$(printf '%s\n' "${_pf_plat}" | sed -n 's/^VERSION_ID=//p' | head -n 1 | tr -d '"')
        fi
    fi
    if [ -z "${_pf_plat}" ] || [ -z "${_pf_ver}" ]; then
        _preflight_fail platform "platform identity unreadable on ${AB_HOST}: neither /etc/platform-release nor /etc/os-release names a version"
        return 1
    fi
    _preflight_pass platform "platform=${_pf_ver}"

    # 4. the two partitions the phases write into. /mnt/p4 holds the overlay layers and
    #    /data holds the payloads and the user's files; a phase that starts on a full disk
    #    fails inside a transaction instead of before it.
    _pf_df=$(dev_ssh "df -Pk ${AB_P4_MOUNT} /data" 2>/dev/null)
    _pf_free_report=""
    for _pf_m in "${AB_P4_MOUNT}" /data; do
        _pf_free=$(printf '%s\n' "${_pf_df}" \
            | awk -v m="${_pf_m}" 'NR > 1 && $NF == m { printf "%d", $4 / 1024 }')
        if [ -z "${_pf_free}" ]; then
            _preflight_fail disk "no free space reported for ${_pf_m} (df -Pk ${AB_P4_MOUNT} /data gave no line for it)"
            return 1
        fi
        if [ "${_pf_free}" -lt "${MIN_FREE_MB}" ]; then
            _preflight_fail disk "${_pf_m} has ${_pf_free} MiB free, the phases need ${MIN_FREE_MB} MiB"
            return 1
        fi
        _pf_free_report="${_pf_free_report}${_pf_free_report:+,}${_pf_m}:${_pf_free}MiB"
    done
    _preflight_pass disk "${_pf_free_report}"

    # 5. the payloads: where they are, and which platform each one declares.
    #
    #    Without --payload-dir the phases fall back to their own default (payloads), so the
    #    directory judged here is the one they will read, not only the one that was named: a
    #    gate that looked at an empty string while the matrix installed payloads/ would never
    #    fire on the run it was written for.
    if [ -n "${PAYLOAD_DIR}" ] && [ ! -d "${PAYLOAD_DIR}" ]; then
        _preflight_fail payload "payload-dir does not exist: ${PAYLOAD_DIR}"
        return 1
    fi
    _pf_dir=${PAYLOAD_DIR:-payloads}
    _pf_n=0
    if [ -d "${_pf_dir}" ]; then
        for _pf_f in "${_pf_dir}"/payload-*.tar; do
            [ -f "${_pf_f}" ] || continue
            _pf_n=$((_pf_n + 1))
        done
    fi
    if [ -n "${PAYLOAD_DIR}" ] && [ "${_pf_n}" -eq 0 ]; then
        _preflight_fail payload "payload-dir holds no payload-*.tar: ${PAYLOAD_DIR}"
        return 1
    fi
    _pf_want=$(_checkout_version) || _pf_want=""
    if [ "${_pf_n}" -gt 0 ] && [ -z "${_pf_want}" ]; then
        _preflight_fail payload "the checkout declares no VERSION (${AB_REPO_ROOT}/VERSION), so no payload can be judged against the code under acceptance"
        return 1
    fi
    _pf_plat_bad=""
    _pf_plat_note=""
    if [ "${_pf_n}" -gt 0 ]; then
        _pf_plat_bad=$(_payload_platform_mismatches "${_pf_dir}" "${_pf_want}")
        _pf_plat_note=" platforms=ok"
    fi
    if [ -n "${_pf_plat_bad}" ]; then
        _preflight_fail payload-platform "${_pf_plat_bad}; rebuild the payload from this checkout (scripts/ci/assemble.sh) before accepting anything with it. A payload built from older code makes every jump measure the old code while the round reports on ${_pf_want}"
        return 1
    fi

    # 6. the payloads' content, not only the version they declare. The version gate above
    #    cannot see a payload built before a fix was committed: the manifest still says the
    #    right platform, and the tar still carries the old file. This compares the platform
    #    layer inside every base payload with the checkout's own platform/ tree, and refuses
    #    the run when they differ, because a round that installs other code than the one
    #    under acceptance reports its red rows as product defects.
    _pf_content_note=""
    if [ "${_pf_n}" -gt 0 ]; then
        _pf_content_bad=$(_payload_content_mismatches "${_pf_dir}" "${AB_REPO_ROOT}")
        if [ -n "${_pf_content_bad}" ]; then
            if [ "${ALLOW_STALE_PAYLOAD}" = "1" ]; then
                _pf_content_note=" content=stale-allowed-by---allow-stale-payload"
                _preflight_pass payload-content \
                    "--allow-stale-payload: ${_pf_content_bad}. The round goes on and its rows say it measured other code than ${_pf_want}"
            else
                _preflight_fail payload-content \
                    "${_pf_content_bad}; rebuild the payloads from this checkout before accepting anything with them - payloads/rebuild-base-payloads.sh replaces only the platform layer and keeps rootfs, kernel, initramfs and bootloader byte for byte - or pass --allow-stale-payload to run anyway and record that the round measured other code. A payload built before a fix was committed installs the old code, so the fixed defect reads as still broken"
                return 1
            fi
        else
            _pf_content_note=" content=ok"
            _preflight_pass payload-content "every base payload carries this checkout's platform layer"
        fi
    fi
    if [ -n "${PAYLOAD_DIR}" ]; then
        _preflight_pass payload "payload-dir=${PAYLOAD_DIR} files=${_pf_n}${_pf_plat_note}${_pf_content_note}"
    else
        _preflight_pass payload "no --payload-dir given; the phases use their own default (payloads) files=${_pf_n}${_pf_plat_note}${_pf_content_note}"
    fi

    printf 'preflight: ok\n'
    return 0
}

# --------------------------------------------------------------------------- #
# Running one phase
# --------------------------------------------------------------------------- #

# _phase_run <phase>: the phase's process. Its stdout and stderr are the caller's.
_phase_run() {
    if [ "${1}" = "preflight" ]; then
        _preflight
        return $?
    fi
    _pr_script=$(_phase_script "${1}")
    _pr_args=$(_phase_args "${1}")
    _pr_env=$(_phase_env "${1}")
    (
        # The results channel is exported in a subshell so a value with spaces survives
        # the round trip (the arguments themselves are space separated, which is the
        # repo's own convention). A phase may set more than one variable: feed-install
        # needs its results file and the payload directory the pin case installs from.
        for _pr_assign in ${_pr_env}; do
            case "${_pr_assign}" in
                *"="*)
                    export "${_pr_assign%%=*}=${_pr_assign#*=}"
                    ;;
            esac
        done
        # shellcheck disable=SC2086
        set -- ${_pr_args}
        "${_pr_script}" "$@"
    )
}

# _normalize_tsv <file>: keep the four columns of the project's row shape.
# recovery-probe.sh and feed-install.sh append a fifth `checks=.. failures=.. gaps=..`
# column; the counters are already in the log, and verdict.tsv has to stay one shape.
_normalize_tsv() {
    [ -s "${1}" ] || return 0
    if awk -F'\t' 'NF > 4 { wide = 1 } END { exit !wide }' "${1}"; then
        awk -F'\t' 'BEGIN { OFS = "\t" } { print $1, $2, $3, $4 }' "${1}" >"${1}.tmp" \
            && mv "${1}.tmp" "${1}"
    fi
    return 0
}

# _audit_rows: the audit phase writes no results file of its own, so its verdict is read
# off the two summary lines it prints. Missing evidence is a GAP and not a FAIL: nothing
# about the machine was judged, the record is incomplete.
#
# The patterns are open-ended on purpose: evidence-audit.sh prints `result=covered` on one
# line and `result=gaps open=<n>` on the other, so a pattern anchored at the end of the line
# (`*result=gaps)`) matches neither and every incomplete record would fall through to
# _ensure_rows as a FAIL. That is the one mistake this phase must not make: "the record is
# incomplete" and "the machine is broken" are different verdicts.
_audit_rows() { # <exit status>
    _ar_sum=$(grep '^evidence-audit summary' "${LOG}" 2>/dev/null | head -n 1)
    _ar_res=$(grep '^evidence-audit result=' "${LOG}" 2>/dev/null | head -n 1)
    case "${_ar_res}" in
        *result=covered*)
            AB_RESULTS="${TSV}"
            record audit PASS "${LOG}" "${_ar_sum:-every ac carries its evidence}"
            ;;
        *result=gaps*)
            AB_RESULTS="${TSV}"
            record audit GAP "${LOG}" "${_ar_sum:-evidence-audit reports acs whose evidence is not named}"
            ;;
        *)
            # No result line at all. Exit 2 is evidence-audit.sh's "the audit could not be
            # made" (no PRD for that task id, or a PRD with no ac bullet): a record problem,
            # so a GAP and not a FAIL - this round's machine was never judged either way.
            if [ "${1:-}" = "2" ]; then
                AB_RESULTS="${TSV}"
                record audit GAP "${LOG}" \
                    "exit 2: the audit could not be made - evidence-audit.sh found no PRD (or no ac bullet) for task ${TASK_ID}; the id may be wrong, the record may not exist"
            fi
            ;;
    esac
    return 0
}

# _release_rows <exit status>: release-verify.sh writes no results file either - it prints
# one `release-verify check=... result=...` line per ac-1 clause and one final
# `release-verify result=pass|fail|none` line. That last line is the row.
#
# result=none is GAP, not FAIL: the assets could not be obtained (no network, no gh, a
# download that failed), and PRD risk 3 says that is not a defect of this product. A FAIL
# here is the release itself: a missing/draft tag, a digest that does not match, an index
# that claims another platform.
_release_rows() {
    _rr_res=$(grep '^release-verify result=' "${LOG}" 2>/dev/null | tail -n 1)
    _rr_checks=$(grep -c '^release-verify check=' "${LOG}" 2>/dev/null)
    AB_RESULTS="${TSV}"
    case "${_rr_res}" in
        *result=pass*)
            record release PASS "${LOG}" "${_rr_res} checks=${_rr_checks}"
            ;;
        *result=fail*)
            record release FAIL "${LOG}" "${_rr_res} checks=${_rr_checks}"
            ;;
        *result=none*)
            record release GAP "${LOG}" "${_rr_res}: the assets could not be obtained, so no clause of ac-1 was judged"
            ;;
        *)
            record release GAP "${LOG}" \
                "exit ${1}: no 'release-verify result=' line in ${LOG}, so the release was never judged"
            ;;
    esac
    return 0
}

# _ensure_rows <phase> <exit status>: a phase that wrote no row gets one here.
# "exit 0 and said nothing" must not be readable as a pass: the row says how the phase
# ended, and the note says that no case-level row came with it.
_ensure_rows() {
    [ -s "${TSV}" ] && return 0
    AB_RESULTS="${TSV}"
    case "${2}" in
        0) record "${1}" PASS - "exit 0, no per-case row was written" ;;
        3)
            # For the phases whose exit 3 is "the question could not be put" (a dead mirror,
            # an unreachable release) this is a GAP, never a FAIL. The others use exit 3 for
            # the red line that stopped a destructive run, which stays a FAIL.
            if _in_list "${1}" "${GAP_EXIT_PHASES}"; then
                record "${1}" GAP - "exit 3: nothing was decided (network, assets or a precondition), no per-case row was written"
            else
                record "${1}" FAIL - "exit 3: the phase stopped before writing a row"
            fi
            ;;
        4) record "${1}" GAP - "exit 4: the phase could not run (missing precondition)" ;;
        *) record "${1}" FAIL - "exit ${2}: the phase failed before writing a row" ;;
    esac
    return 0
}

# _phase_verdict <tsv>: the worst row of a phase file.
_phase_verdict() {
    if [ ! -s "${1}" ]; then
        printf 'GAP'
        return 0
    fi
    if awk -F'\t' '$2 == "FAIL" { f = 1 } END { exit !f }' "${1}"; then
        printf 'FAIL'
    elif awk -F'\t' '$2 == "GAP" { g = 1 } END { exit !g }' "${1}"; then
        printf 'GAP'
    else
        printf 'PASS'
    fi
}

# _already_pass <tsv>: every row PASS, so this phase has nothing left to prove.
# A file holding a FAIL or a GAP is not a reason to skip: the phase runs again.
_already_pass() {
    [ -s "${1}" ] || return 1
    awk -F'\t' '$2 != "PASS" { bad = 1 } END { exit bad }' "${1}"
}

# _confirm_destructive <phase>: a destructive phase needs a yes a person typed.
# Refusing is allowed and is recorded as GAP: the run then continues with the phases that
# only read the machine.
_confirm_destructive() {
    _cd_is=0
    for _cd_p in ${DESTRUCTIVE_PHASES}; do
        [ "${_cd_p}" = "${1}" ] && _cd_is=1
    done
    [ "${_cd_is}" = 1 ] || return 0
    [ "${ASSUME_YES}" = 1 ] && return 0
    printf '%s writes slots and reboots %s. type yes to continue: ' "${1}" "${AB_HOST}" >&2
    _cd_answer=""
    IFS= read -r _cd_answer || _cd_answer=""
    [ "${_cd_answer}" = "yes" ]
}

_phase_start() { # <phase>
    mkdir -p "${RESULTS_DIR}" || return 1
    printf 'phase %s: start\n' "${1}"
    printf '### phase %s start %s\n' "${1}" "$(dev_stamp)" >>"${LOG}"
    return 0
}

_phase_done() { # <phase> <result>
    _pd_rows=0
    if [ -s "${TSV}" ]; then
        _pd_rows=$(awk -F'\t' 'END { printf "%d", NR }' "${TSV}")
    fi
    printf 'phase %s: %s\n' "${1}" "${2}"
    printf '### phase %s result=%s rows=%s %s\n' "${1}" "${2}" "${_pd_rows}" "$(dev_stamp)" >>"${LOG}"
    PHASE_REPORT="${PHASE_REPORT}${1} ${2} rows=${_pd_rows}
"
}

_skip() { # <phase> <reason>
    SKIPPED=$((SKIPPED + 1))
    printf 'phase %s: skipped\n' "${1}"
    printf '  %s\n' "${2}"
    PHASE_REPORT="${PHASE_REPORT}${1} skipped: ${2}
"
}

# --------------------------------------------------------------------------- #
# The verdict
# --------------------------------------------------------------------------- #

_count_rows() { # <tsv> <verdict>
    [ -s "${1}" ] || {
        printf '0'
        return 0
    }
    awk -F'\t' -v v="${2}" '$2 == v { n++ } END { printf "%d", n }' "${1}"
}

# _sweep_run: put the machine back after the last judged phase, and record what happened.
#
# software-probe.sh writes its samples into the apps' *real* config files (/etc/config/argon
# and friends) and keeps the bookkeeping it needs to undo that under <results>/software-state.
# Only its own --cleanup restores them, and until this function existed nothing ever called it:
# the 2026-11-20 round finished with a fixture in /etc/config/argon, the theme page could not
# read `argon.@global[0]`, and the failure read as a product defect while it was this round's
# own leftover.
#
# It runs here - after the last phase, before the verdict - and not between hops, because
# restoring between hops would make "the config survived the hop" a statement about a file that
# had already been put back.
#
# The driver's own rows go to sweep-driver.tsv, which no phase owns and the verdict never
# reads. That is deliberate: --cleanup records FAIL when it could not put something back, and
# a FAIL there would turn the whole round red over a bookkeeping failure. The round learns one
# row from this function - PASS when the machine is demonstrably back, GAP (naming what is
# still dirty) when it is not - and never FAIL, because "the product is broken" and "the
# cleanup did not finish" are different findings.
_sweep_run() {
    # Both files are this run's answer, not a history. A round may be continued in the same
    # results directory (that is what --from and the "already PASS, skip" rule are for), so an
    # earlier sweep row must not be re-read into this verdict, and an earlier driver FAIL row
    # must not keep this sweep at GAP after the machine came back clean.
    mkdir -p "${RESULTS_DIR}" 2>/dev/null || true
    : >"${RESULTS_DIR}/sweep.tsv"
    : >"${RESULTS_DIR}/sweep-driver.tsv"
    _sw_state="${RESULTS_DIR}/software-state"
    _sw_pending=0
    for _sw_l in "${_sw_state}/written.tsv" "${_sw_state}/sources.tsv"; do
        [ -s "${_sw_l}" ] && _sw_pending=1
    done
    if [ "${_sw_pending}" -eq 0 ]; then
        printf '  sweep: nothing is holding a fixture (%s has no pending change)\n' "${_sw_state}"
        return 0
    fi
    _sw_driver=$(_phase_script software)
    if [ ! -f "${_sw_driver}" ]; then
        AB_RESULTS="${RESULTS_DIR}/sweep.tsv"
        record sweep GAP - "reason=no-driver driver=${_sw_driver} changed=${_sw_state}/written.tsv"
        printf '  sweep: GAP, the software driver is not installed at %s\n' "${_sw_driver}"
        return 0
    fi
    sh "${_sw_driver}" --cleanup --results "${RESULTS_DIR}/sweep-driver.tsv" \
        >"${RESULTS_DIR}/sweep.log" 2>&1
    _sw_rc=$?
    _sw_dirty=$(_sweep_dirty_note)
    _sw_fails=0
    if [ -f "${RESULTS_DIR}/sweep-driver.tsv" ]; then
        _sw_fails=$(awk -F'	' '$2 == "FAIL" { n += 1 } END { print n + 0 }' \
            "${RESULTS_DIR}/sweep-driver.tsv")
    fi
    AB_RESULTS="${RESULTS_DIR}/sweep.tsv"
    if [ "${_sw_rc}" -eq 0 ] && [ "${_sw_fails}" -eq 0 ] && [ "${_sw_dirty}" = "left-dirty=none" ]; then
        record sweep PASS "${RESULTS_DIR}/sweep.log" "cleanup exit 0 ${_sw_dirty}"
        printf '  sweep: the software driver put the machine back\n'
    else
        _sw_why="exit=${_sw_rc}"
        [ "${_sw_fails}" -eq 0 ] || _sw_why="${_sw_why} failed-rows=${_sw_fails}"
        record sweep GAP "${RESULTS_DIR}/sweep.log" \
            "reason=cleanup-incomplete ${_sw_why} ${_sw_dirty:-left-dirty=unknown} changed=${_sw_state}/written.tsv"
        printf '  sweep: GAP, the cleanup did not confirm a clean machine (%s)\n' "${_sw_why}"
    fi
    return 0
}

# _sweep_dirty_note: the driver's own left-dirty line, so the row answers "what is still
# holding a fixture" without the reader opening the log. `left-dirty=none` is also the third
# condition of a PASS: a driver that exits 0 while naming a file has not put the machine back.
_sweep_dirty_note() {
    _sdn=$(sed -n 's/^left-dirty=\(.*\)$/left-dirty=\1/p' "${RESULTS_DIR}/sweep.log" 2>/dev/null |
        tail -n 1)
    printf '%s' "${_sdn}"
}

_write_verdict() {
    mkdir -p "${RESULTS_DIR}" || return 1
    : >"${RESULTS_DIR}/verdict.tsv"
    for _wv_p in ${PHASES}; do
        [ -f "${RESULTS_DIR}/${_wv_p}.tsv" ] || continue
        cat "${RESULTS_DIR}/${_wv_p}.tsv" >>"${RESULTS_DIR}/verdict.tsv"
    done
    # The sweep is not a phase (no --only or --from may select or skip it), so it is appended
    # here rather than found in the loop above. It is last on purpose: it is the round's last
    # action, and a reader of verdict.tsv should see it after every judged row.
    [ -f "${RESULTS_DIR}/sweep.tsv" ] && cat "${RESULTS_DIR}/sweep.tsv" >>"${RESULTS_DIR}/verdict.tsv"
    _wv_passed=$(_count_rows "${RESULTS_DIR}/verdict.tsv" PASS)
    _wv_failed=$(_count_rows "${RESULTS_DIR}/verdict.tsv" FAIL)
    _wv_gap=$(_count_rows "${RESULTS_DIR}/verdict.tsv" GAP)

    _wv_verdict=PASS
    if [ "${_wv_failed}" -gt 0 ]; then
        _wv_verdict=FAIL
    elif [ "${_wv_gap}" -gt 0 ]; then
        _wv_verdict=GAP
    fi

    {
        printf 'passed=%s failed=%s gap=%s skipped=%s\n' \
            "${_wv_passed}" "${_wv_failed}" "${_wv_gap}" "${SKIPPED}"
        printf '%s' "${PHASE_REPORT}"
        printf 'verdict: %s\n' "${_wv_verdict}"
    } >"${RESULTS_DIR}/summary.txt"

    printf 'full-test: results=%s passed=%s failed=%s gap=%s skipped=%s\n' \
        "${RESULTS_DIR}" "${_wv_passed}" "${_wv_failed}" "${_wv_gap}" "${SKIPPED}"
    printf 'verdict: %s\n' "${_wv_verdict}"
    printf 'full-test: rows in %s, summary in %s\n' \
        "${RESULTS_DIR}/verdict.tsv" "${RESULTS_DIR}/summary.txt"

    [ "${_wv_verdict}" = "PASS" ]
}

# --------------------------------------------------------------------------- #
# Arguments
# --------------------------------------------------------------------------- #

while [ $# -gt 0 ]; do
    case "${1}" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --preflight-only)
            PREFLIGHT_ONLY=1
            shift
            ;;
        --list)
            LIST_ONLY=1
            shift
            ;;
        --from)
            FROM_PHASE=${2:?--from needs a phase}
            shift 2
            ;;
        --stop-after)
            STOP_AFTER=${2:?--stop-after needs a phase}
            shift 2
            ;;
        --only)
            ONLY_CASES="${ONLY_CASES} ${2:?--only needs a case, e.g. M3}"
            shift 2
            ;;
        --results)
            RESULTS_DIR=${2:?--results needs a directory}
            shift 2
            ;;
        --payload-dir)
            PAYLOAD_DIR=${2:?--payload-dir needs a directory}
            shift 2
            ;;
        --allow-stale-payload)
            ALLOW_STALE_PAYLOAD=1
            shift
            ;;
        --task)
            TASK_ID=${2:?--task needs a task id, e.g. 20261116-12-pre-release-acceptance-0-0-12}
            shift 2
            ;;
        --expect)
            EXPECT=${2:?--expect needs a version, e.g. 0.0.12}
            shift 2
            ;;
        --release-dir)
            RELEASE_ASSET_DIR=${2:?--release-dir needs a directory}
            shift 2
            ;;
        --release-tag)
            RELEASE_TAG=${2:?--release-tag needs a tag, e.g. v0.1.0-rc.2}
            shift 2
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'full-test: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# --list is answered before any of the window rules: it has no window, no results directory
# and no machine. It also has to come before --from/--stop-after validation, because a caller
# who only wants to see the order has not named a phase yet.
if [ "${LIST_ONLY}" = 1 ]; then
    for _list_phase in ${PHASES}; do
        printf '%s\n' "${_list_phase}"
    done
    exit 0
fi

# --preflight-only is --stop-after preflight, so there is one window rule and not two.
if [ "${PREFLIGHT_ONLY}" = 1 ]; then
    if [ -n "${STOP_AFTER}" ] && [ "${STOP_AFTER}" != "preflight" ]; then
        printf 'full-test: --preflight-only and --stop-after %s contradict each other\n' "${STOP_AFTER}" >&2
        exit 2
    fi
    STOP_AFTER=preflight
fi

if [ -n "${FROM_PHASE}" ]; then
    if ! FROM_INDEX=$(_phase_index "${FROM_PHASE}"); then
        printf 'full-test: --from: not a phase: %s (want one of: %s)\n' "${FROM_PHASE}" "${PHASES}" >&2
        exit 2
    fi
fi

if [ -n "${STOP_AFTER}" ]; then
    if ! STOP_INDEX=$(_phase_index "${STOP_AFTER}"); then
        printf 'full-test: --stop-after: not a phase: %s (want one of: %s)\n' "${STOP_AFTER}" "${PHASES}" >&2
        exit 2
    fi
fi

if [ -n "${FROM_INDEX}" ] && [ -n "${STOP_INDEX}" ] && [ "${FROM_INDEX}" -gt "${STOP_INDEX}" ]; then
    printf 'full-test: --from %s comes after --stop-after %s, so no phase would run\n' \
        "${FROM_PHASE}" "${STOP_AFTER}" >&2
    exit 2
fi

# A --only token no phase owns is a typo, and a typo that skips everything would read as
# a green run over nothing.
if [ -n "${ONLY_CASES}" ]; then
    for _arg_c in ${ONLY_CASES}; do
        _arg_own=0
        for _arg_p in ${PHASES}; do
            _phase_owns "${_arg_p}" "${_arg_c}" && _arg_own=1
        done
        if [ "${_arg_own}" = 0 ]; then
            printf 'full-test: --only: no phase owns case: %s\n' "${_arg_c}" >&2
            printf 'full-test: cases are M1..M7, S1..S8, P1..P4, U1, R*, B*, I*, D1, D2, D3,\n' >&2
            printf 'full-test: ac-3/pin, ac-12/check, ac-13/install, both, all, release/verdict/sums/index, %s,\n' \
                "${PROBE_NAMES}" >&2
            printf 'full-test: and the round-2 phases by their own name: software, badconfig, matrix2\n' >&2
            exit 2
        fi
    done
fi

# --------------------------------------------------------------------------- #
# The run
# --------------------------------------------------------------------------- #

if [ "${DRY_RUN}" = "1" ]; then
    # Belt and braces: nothing below the plan is reached, and every ssh helper would
    # refuse anyway.
    AB_DRY_RUN=1
    export AB_DRY_RUN
    printf 'plan: results=%s payload-dir=%s yes=%s\n' \
        "${RESULTS_DIR}" "${PAYLOAD_DIR:-default}" "${ASSUME_YES}"
    if [ -n "${FROM_PHASE}" ]; then
        printf 'plan: --from %s\n' "${FROM_PHASE}"
    fi
    if [ -n "${STOP_AFTER}" ]; then
        printf 'plan: --stop-after %s\n' "${STOP_AFTER}"
    fi
    printf 'plan: --only %s\n' "${ONLY_CASES:-all cases}"
fi

_run_i=0
# The sample baseline lives on this side of the wire: the machine's /tmp does not survive the
# hop that this file judges. matrix.sh reads the same path through AB_FOLLOW_STATE, so "which
# file is the baseline" has one answer for the whole run instead of one per phase.
AB_FOLLOW_STATE=${AB_FOLLOW_STATE:-${RESULTS_DIR}/follow-state.tsv}
export AB_FOLLOW_STATE

for _run_phase in ${PHASES}; do
    TSV="${RESULTS_DIR}/${_run_phase}.tsv"
    LOG="${RESULTS_DIR}/${_run_phase}.log"
    _run_idx=${_run_i}
    _run_i=$((_run_i + 1))

    if [ -n "${FROM_INDEX}" ] && [ "${_run_idx}" -lt "${FROM_INDEX}" ]; then
        _skip "${_run_phase}" "before --from ${FROM_PHASE}"
        continue
    fi
    if [ -n "${STOP_INDEX}" ] && [ "${_run_idx}" -gt "${STOP_INDEX}" ]; then
        _skip "${_run_phase}" "after --stop-after ${STOP_AFTER}"
        continue
    fi
    if ! _phase_wanted "${_run_phase}"; then
        _skip "${_run_phase}" "no case selected by --only"
        continue
    fi
    if [ "${DRY_RUN}" != "1" ] && _already_pass "${TSV}"; then
        _skip "${_run_phase}" "already PASS in ${TSV}"
        continue
    fi
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'phase %s: plan %s\n' "${_run_phase}" "$(_phase_plan "${_run_phase}")"
        continue
    fi

    mkdir -p "${RESULTS_DIR}" || {
        printf 'full-test: cannot create results directory: %s\n' "${RESULTS_DIR}" >&2
        exit 1
    }
    _phase_start "${_run_phase}" || exit 1

    _run_script=$(_phase_script "${_run_phase}")
    if [ "${_run_phase}" != "preflight" ] && [ ! -f "${_run_script}" ]; then
        AB_RESULTS="${TSV}"
        record "${_run_phase}" GAP - "script not present: ${_run_script}"
        printf '  script not present: %s\n' "${_run_script}"
        _phase_done "${_run_phase}" "GAP"
        continue
    fi

    if ! _confirm_destructive "${_run_phase}"; then
        AB_RESULTS="${TSV}"
        record "${_run_phase}" GAP - "destructive phase not confirmed (pass --yes)"
        printf '  not confirmed: pass --yes to let %s write slots\n' "${_run_phase}"
        _phase_done "${_run_phase}" "GAP"
        continue
    fi

    # The audit is the one phase that reads this round's bookkeeping instead of the machine,
    # so it needs to be told which round. With no id it is not run at all: evidence-audit.sh
    # has a task id of its own (last round's), and auditing that would print a green table
    # about a record nobody is asking about.
    if [ "${_run_phase}" = "audit" ] && [ -z "${TASK_ID}" ]; then
        AB_RESULTS="${TSV}"
        record audit GAP - \
            "no task id: pass --task <id> or set AB_TASK_ID. Without one the audit would read the previous round's task (evidence-audit.sh --task default), so nothing was audited here"
        printf '  no task id: pass --task <id> or set AB_TASK_ID\n'
        _phase_done audit "GAP"
        continue
    fi

    # R1's candidate is a payload on this host, and this is the last place that knows WHICH
    # file the round meant. When it is not there, R1 is not handed to the driver: the
    # driver's own GAP ("no --payload given and --installed is not set") is true but does not
    # say which path is missing, and that is the part a reader can act on. B1 needs no
    # payload, so the driver is still asked for it rather than losing a case that can run.
    if [ "${_run_phase}" = "recovery" ]; then
        _run_r1=0
        _run_rec_cases=$(_recovery_cases "$(_phase_selected_cases recovery)")
        case " ${_run_rec_cases} " in
            *" R1 "*) _run_r1=1 ;;
        esac
        _run_payload_why=$(_recovery_payload_gap)
        if [ "${_run_r1}" = "1" ] && [ -n "${_run_payload_why}" ]; then
            AB_RESULTS="${TSV}"
            record R1 GAP - "${_run_payload_why}"
            printf '  R1 not run: %s\n' "${_run_payload_why}"
            _RECOVERY_SKIP_R1=1
            if [ -z "$(_recovery_drop_r1 "${_run_rec_cases}")" ]; then
                _phase_done recovery "$(_phase_verdict "${TSV}")"
                continue
            fi
        fi
    fi

    _run_rcfile="${RESULTS_DIR}/.${_run_phase}.rc"
    {
        _phase_run "${_run_phase}" 2>&1
        printf '%s\n' "$?" >"${_run_rcfile}"
    } | tee -a "${LOG}"
    _run_rc=$(cat "${_run_rcfile}" 2>/dev/null || printf '1')
    rm -f "${_run_rcfile}"

    _normalize_tsv "${TSV}"
    # Two phases judge something other than a results file: audit reads its own summary
    # line and release reads `release-verify result=`. Everything else wrote its rows
    # itself, and _ensure_rows below only speaks when one of them did not.
    if [ ! -s "${TSV}" ]; then
        case "${_run_phase}" in
            audit) _audit_rows "${_run_rc}" ;;
            release) _release_rows "${_run_rc}" ;;
        esac
    fi
    _ensure_rows "${_run_phase}" "${_run_rc}"
    _run_result=$(_phase_verdict "${TSV}")
    _phase_done "${_run_phase}" "${_run_result}"

    if [ "${_run_phase}" = "preflight" ] && [ "${_run_result}" != "PASS" ]; then
        # Everything after preflight assumes a reachable machine that is the one under
        # test; running it on a machine nobody could confirm is how a red preflight turns
        # into a page of unrelated reds.
        printf 'full-test: preflight did not pass, the run stops here\n' >&2
        printf 'full-test: fix the line above, then rerun with --from %s\n' "${FROM_PHASE:-preflight}" >&2
        break
    fi
done

if [ "${DRY_RUN}" = "1" ]; then
    printf 'plan: nothing was executed and no file was written (--dry-run)\n'
    exit 0
fi

_sweep_run

_write_verdict
exit $?
