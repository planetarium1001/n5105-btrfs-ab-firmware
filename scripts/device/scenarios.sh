#!/bin/sh
# Real-user scenarios S1-S8: does what a person installed, wrote and configured
# survive a version jump, is the software still usable afterwards, did the tools that
# boot the machine travel with the update, does the package source follow the version, and
# what does the machine do when the configuration a user wrote is simply wrong?
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
#                    what apk has, and install-then-remove one small package to prove that
#                    an uninstall leaves nothing behind. A package that cannot be installed
#                    is recorded as unavailable, not as a failure; zero packages AND zero
#                    kmods is a GAP.
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
#   S8  badconfig    four broken configurations -- a network section naming a device that
#                    does not exist, a firewall rule with invalid options (which fw4 warns
#                    about and skips), a truncated docker daemon.json and a package feed that
#                    answers 404. Each one is backed up before it is written, and each one has
#                    to end with the machine still whole, the change refused or visibly
#                    degraded, and the backup back in place, byte for byte.
#
#   scripts/device/scenarios.sh                       # S1..S8
#   scripts/device/scenarios.sh --case S3 --case S4    # the two jumps
#   scripts/device/scenarios.sh --case S6              # the boot toolchain alone
#   scripts/device/scenarios.sh --case S7              # the package source versus the version
#   scripts/device/scenarios.sh --case S8              # four broken configurations and the way back
#   scripts/device/scenarios.sh --resume               # skip cases that already PASS
#   scripts/device/scenarios.sh --dry-run              # print steps and verdicts, touch nothing
#
# Exit status: 0 every selected case PASS, 1 a case FAIL, 2 bad usage, 3 the red line
# stopped the run, 4 a case could not run because a prerequisite or payload is missing (GAP).
#
# Evidence: one run, two names. Each case writes
#
#   <evidence dir>/<UTC stamp>-<case>.log          <- THIS run, never reused
#   <evidence dir>/<case>.log                      <- the LATEST run of that case (alias)
#
# The stamp is the run's UTC instant in the shape the backup directories already use,
# 2026-11-16T19-33-22Z, compacted for the file name to 20261116T193322Z. It has to carry the
# time and not just the date: a case is re-run later the same day after a fix, and a name of
# <date>-<case>.log made the second run truncate the first run's evidence while the backup
# next to it was already stamped to the second -- the first round survived only in the report,
# not on disk. The stamp is also the one this case's own backups are named from (S2, S7, S8),
# so "which run left this file" is one string and not two naming schemes that agree on the
# day and disagree on everything finer. AB_SCEN_STAMP overrides the stamp (the unit tests use
# it to run the same case twice inside one simulated day); unset means the clock. The
# timestamped log is what the --results row names; the stable <case>.log alias is only for a
# reader that wants "whatever ran last" and is replaced by each run. The --results file
# itself is the caller's: its path, and whether a second run appends to it, is unchanged.
#
# Three verdicts, as in matrix.sh, plus one note prefix:
#   PASS  every mechanical judgement held
#   FAIL  data lost, config lost, software gone, mount or service broken, or SSH lost; a
#         package that left files behind after its own uninstall (S1); a hop that landed on
#         package metadata that is not aligned (S3/S4); a broken configuration the machine
#         did not refuse, did not survive, or did not come back from byte for byte (S8)
#   GAP   could not be judged (no payload, no apk, no /data, no S1/S2 state on the machine,
#         or -- in S8 -- not one of the four broken configurations could be written here)
#   note  scenarios also produce findings that are neither: a kmod built for the previous
#         kernel is normal apk behaviour, a package the image does not ship cannot be
#         install-and-removed, and a docker daemon that ignores a file it cannot parse is not
#         broken; but the user has to be told. Those go in the fourth column prefixed
#         FINDING: and never turn a PASS into a FAIL.
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
#     (require_safe_target);
#   * S8 writes a broken configuration only after that class's own backup is on /data, and
#     every class ends with the backup back in place and compared byte for byte; a class
#     whose backup cannot be taken writes nothing at all.
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
# Why S8 breaks the configuration on purpose: every other case in this file asks whether the
# machine keeps what a user put there. This one asks the opposite question, because a person
# with a text editor gets /etc/config/firewall wrong far more often than an upgrade does: is
# a wrong file refused, does the machine stay reachable while it is wrong, and is there a
# recorded way back? The four classes are the four ways a machine can be told something
# untrue -- a network section that names a device nothing has, a firewall rule with invalid
# options, a docker config that is not JSON, and a package feed that answers 404 -- and the
# three things that make the answer worth reading: the refusal (or the visible degradation) is
# witnessed on the machine rather than assumed from an exit status, the machine is still a
# machine afterwards (ab-slot status, boot=ok, esp=ok, data=ok, two ssh answers), and the
# recovery record says where the backup is and who put it back. "Refused" is read per class:
# netifd cannot create a link that is not there, fw4 drops the section it cannot read and the
# rendered ruleset is where that is visible, dockerd stops answering, and apk cannot refresh
# an index that is not there -- the exit status of the tool is never the whole answer.
#
# Why the network class reuses S2's net-apply and net-rollback instead of its own revert: the
# rollback machinery is the one thing here that cannot be re-tested for free. If S8 grew a
# second implementation, the watchdog would be proven by S2 and used by S8, and a bug in the
# used path would be invisible. So the broken section goes through the same three steps --
# backup, machine-scheduled revert, host-issued rollback -- and only the content differs.
#
# Why the firewall class never reloads the broken ruleset: `fw4 check` parses and translates
# without touching the running ruleset, and a bad rule pushed to a live firewall is how a
# test takes its own session away. fw4's fail-safe semantics are the reason the exit status
# is not the witness: on the 25.x line `fw4 check` warns ("option 'dest_port' specifies
# invalid value 'not-a-port'", "skipped due to invalid options") and still exits 0, because
# the tool drops the section instead of rejecting the whole file -- measured for
# dest_port=not-a-port, for target=AB-BOGUS, and for both together; all three answer
# "Ruleset passes nftables check." That is fail-safe, not fail-open: the machine is not
# locked out by a wrong rule. So the witnesses are the two facts that separate "adopted"
# from "refused": the broken rule does *not* appear in the ruleset the file renders to
# (`fw4 print`), and the check output carries the warning that explains the skip -- while
# the check's own rc is recorded as the fact it is (0), never dressed up as a refusal. The
# *restored* config is then reloaded, which is what proves "the configuration is still
# parseable" -- and is itself the second half of the judgement, because a restore that
# cannot be applied is not a restore. A rendered ruleset that contains the rule is a FAIL
# (the tool adopted what it should have dropped); a machine that stops answering is a FAIL;
# a rule that is skipped with a warning is a PASS. An older image may carry fw3 instead,
# which has no `check` subcommand at all: there the rendered ruleset is the only witness and
# the class says so, rather than reading a usage message as a verdict.
#
# Why the docker class accepts "docker is unavailable" as a pass: dockerd refusing to start on
# a file that is not JSON is the daemon protecting the system, and the machine on these images
# is a router with a container tool, not a container host. The class therefore asserts three
# things and no more: the daemon did not come up on the broken file, the router is unaffected,
# and the backup brought the daemon back (or the image has no docker at all, which is a
# FINDING and named as such).
#
# Why `pidof dockerd` is not the docker class's witness, and `docker info` is: procd re-spawns
# a dockerd that died, so `pidof` keeps answering while the daemon is unusable -- measured on
# a truncated daemon.json: restart_rc=0, pidof still returns a pid, and `docker info` answers
# rc=1 with "unable to configure the Docker daemon with file /tmp/dockerd/daemon.json:
# unexpected end of JSON input" in logread. The process existing says nothing; the API
# answering does. The witness therefore has a *timing*: dockerd takes three to four seconds
# after a restart before `docker info` succeeds, and a single call made immediately after the
# restart reads a healthy daemon as broken. `docker info` is asked several times, about a
# second apart (SCEN_S8_DOCKER_TRIES/PAUSE, retried inside the helper so one ssh call is one
# observation), and only a run where every attempt fails counts as the degradation. The
# class then passes if (a) the daemon stays unusable while the file is broken but the machine
# is otherwise whole, or (b) the daemon tolerated the file -- recorded as a FINDING -- and
# re-answering after the restore with the same image count is what "it came back" means; a
# daemon that is still unusable after the restore is a FAIL.
#
# Why the 404 class proves the restore with a second apk update: one failed fetch says nothing
# about whether the feed list or the network is at fault. Only a run where the bogus list fails
# and the machine's own list succeeds tells the two apart; when both fail, the machine cannot
# reach its feeds from here and the class records that it could not judge instead of claiming
# the 404 was witnessed.
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

CASES_ALL="S1 S2 S3 S4 S5 S6 S7 S8"

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
# The apk-lock token of the last need_apk_lock call: what the row says about a machine that
# was still moving its packages when the case asked it to install something.
APK_LOCK_NOTE=""
SCEN_CMD=""
# The UTC instant this case is named after (2026-11-16T19-33-22Z). It names the evidence log
# and every backup the case takes, so one string answers "which run left this behind". The
# name is fixed once per case in scen_case(); AB_SCEN_STAMP overrides the clock.
SCEN_STAMP=""
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
# S1's second half (R5): one package that is not installed, installed, run once, and removed
# again. Several names long for the same reason as above, and never a package the machine
# already has -- the cycle refuses to remove one (see cmd_pkgcycle), because uninstalling
# something the user installed in order to prove a test would be a test that damages the
# machine it measures.
SCEN_PKGCYCLE=${AB_SCEN_PKGCYCLE:-"nano less jq"}
# S8 writes four broken configurations. The device and the proto are chosen so that nothing
# on the machine can ever answer to them: netifd cannot create a link that is not there, and
# no package implements a proto called ab-scen-badproto, so the section is refused instead of
# being half-applied. The name is deliberately not the management interface's.
SCEN_S8_UCI=${AB_SCEN_S8_UCI:-abscenbad}
SCEN_S8_BADNET_DEV=${AB_SCEN_S8_BADNET_DEV:-ab-scen-nosuch0}
SCEN_S8_BADNET_PROTO=${AB_SCEN_S8_BADNET_PROTO:-ab-scen-badproto}
# The docker config S8 truncates. It is a file the image ships once docker is enabled; when it
# is absent there is nothing to break, and the class says so instead of inventing one.
SCEN_S8_DOCKER=${AB_SCEN_S8_DOCKER:-/etc/docker/daemon.json}
# How often, and how far apart, the docker class asks `docker info`. dockerd needs three to
# four seconds after a restart before its API answers, so a single call reads a healthy
# daemon as a broken one (measured: restart_rc=0 and pidof answering while docker info is
# still rc=1). Four tries a second apart covers that window without hiding a daemon that is
# really gone.
SCEN_S8_DOCKER_TRIES=${AB_SCEN_S8_DOCKER_TRIES:-4}
SCEN_S8_DOCKER_PAUSE=${AB_SCEN_S8_DOCKER_PAUSE:-1}
# The feed that answers 404: a release path that does not exist on the mirror the releases
# come from. A closed port would be indistinguishable from a machine with no network, and
# telling those two apart is the whole point of the second apk update in that class.
SCEN_S8_BADFEED=${AB_SCEN_S8_BADFEED:-${SCEN_S7_FEED_BASE}/releases/0.0.0-ab-404/packages/x86_64/packages/packages.adb}

usage() {
    cat <<'USAGE'
usage: scenarios.sh [--case S1..S8]... [--payload-dir DIR] [--results FILE]
                    [--evidence-dir DIR] [--resume] [--dry-run]

  --case S1..S8      case to run, repeatable; default is all eight
  --payload-dir DIR  directory holding payload-<version>.tar (default: payloads)
  --results FILE     results.tsv to append to (default: results.tsv)
  --evidence-dir DIR evidence directory (default: <results dir>/evidence)
  --resume           skip a case that already has a PASS row in the results file
  --dry-run          print the steps and the verdict rules, then exit; no ssh call is made
  --render-helper F  write the remote helper to F and exit (used by the unit tests)

  S1 preinstall  S2 userdata  S3 up  S4 down  S5 abi  S6 boottools  S7 releasefeeds
  S8 badconfig
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

# need_apk_lock <what>: wait, bounded, for the machine's apk database lock before a step that
# runs apk, and turn a timeout into this case's own GAP note.
#
# The product moves the installed packages onto a new base with one `apk upgrade` in a
# background worker right after a hop, and that transaction holds the apk database lock for
# minutes. A driver that calls apk in that window gets `ERROR: Unable to lock database` and
# nothing about the package was measured - which is how one locked database turned S1 into a
# GAP and S3/S4/S5 into "run --case S1 first" (round 7, 2026-11-19). Waiting is what the user
# does too; forcing or deleting the lock would hide the machine's real state.
#
# Returns 0 when apk can run now (or when nobody can tell, so apk's own answer decides), and
# 2 when the lock was still held at the bound: the caller returns 2 as well, so the case lands
# as GAP naming the seconds instead of as "the feed is broken". The seconds also go into the
# note of a case that waited successfully, because "this run spent 40 s waiting for the
# machine" is what tells a reader the hop was still following packages.
need_apk_lock() {
    _nl_what=${1:-apk}
    if _nl=$(dev_wait_apk_lock); then
        # The wait runs in a subshell here, so the token is what carries the number back.
        APK_LOCK_NOTE=${_nl}
        ev "apk-lock ${_nl_what}: ${_nl}"
        return 0
    fi
    APK_LOCK_NOTE=${_nl}
    CASE_NOTE="the apk database lock was still held after ${AB_APK_LOCK_WAIT}s (bounded wait, ${_nl}), so ${_nl_what} could not run and nothing about the packages was measured: the machine is moving its installed packages onto the base it booted"
    ev "${CASE_NOTE}"
    return 2
}

# apk_lock_suffix: the waited tokens for a case note, empty when the lock was free.
# A zero-second wait is left out on purpose - most cases have nothing to wait for, and a row
# that always ends in `apk-lock-waited=0s` teaches a reader to skip the token that matters on
# the run where the machine was busy for a minute.
apk_lock_suffix() {
    _kls=$(printf '%s' "${APK_LOCK_NOTE:-}" | sed -n 's/^apk-lock-waited=\([0-9][0-9]*\)s .*/\1/p')
    case "${_kls}" in
        '' | 0) return 0 ;;
    esac
    printf ', %s' "${APK_LOCK_NOTE}"
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

# _apk_err_lines <prefix> <text>: apk's own explanation, one line at a time.
# `apk add` answers a solver failure with `ERROR: unable to select packages:` on the first
# line and the cause on the lines beneath it (`breaks: world[kernel=...]`, `required by:`).
# A caller that keeps only the first line records "no" and throws the reason away, which is
# how a gap stops being self-evident: an operator reading the evidence cannot tell a feed
# that lacks the package from a world file pinned to a kernel the feeds do not serve. Every
# line is therefore printed for the host to keep, capped because a solver failure on a large
# world can run long.
_apk_err_lines() {
    printf '%s\n' "${2:-}" | tr -d '\r' | awk -v p="${1}" -v cap="${3:-20}" '
        NF {
            n++
            if (n > cap) exit
            printf "%s line=%d %s\n", p, n, substr($0, 1, 400)
        }'
}

# cmd_pkginstall <pkg>: one package, one verdict. A package the repositories do not have
# is reported as unavailable with its exit status and the first error line -- the user's
# request is "record it and keep going", not "abort the batch". Every further line apk
# wrote follows as its own `pkgerr` record, because the first line names the failure and
# the lines after it say why.
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
    _apk_err_lines "pkgerr pkg=${_pkg}" "${_out}"
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

# cmd_pkgcycle <pkg> <listfile>: install one package the machine does not have, run it once,
# write down the files apk says it owns, and remove it again -- then report what is left.
# R5's "clean after uninstall" is the question, and it is three questions, so all three
# witnesses are printed and the host compares them:
#   * after_del / del_rc  does apk still know the package (`apk info -e` must fail);
#   * files_left          do the files it owned still exist;
#   * world_before/after  is /etc/apk/world back to the line count it had before.
# A package that is already installed is not touched at all: removing something the user
# installed in order to prove a point would be a test that damages the machine it measures,
# so the cycle refuses and reports before=yes, and the host picks the next name.
cmd_pkgcycle() {
    _cy_pkg=$1
    _cy_list=${2:-/tmp/ab-scen-pkgcycle.list}
    _cy_before=no
    apk info -e "${_cy_pkg}" >/dev/null 2>&1 && _cy_before=yes
    if [ "${_cy_before}" = yes ]; then
        say "pkgcycle pkg=${_cy_pkg} before=yes skipped=yes"
        return 0
    fi
    _cy_world_before=$(wc -l </etc/apk/world 2>/dev/null | tr -d ' ')
    [ -n "${_cy_world_before}" ] || _cy_world_before=0
    _cy_add=$(apk add --no-cache "${_cy_pkg}" 2>&1)
    _cy_add_rc=$?
    _cy_mid=no
    apk info -e "${_cy_pkg}" >/dev/null 2>&1 && _cy_mid=yes
    : >"${_cy_list}"
    apk info -L "${_cy_pkg}" >"${_cy_list}" 2>/dev/null
    _cy_files=$(grep '^/' "${_cy_list}" 2>/dev/null | grep -v '/$' | wc -l | tr -d ' ')
    # The command that proves the binary runs is the package's own first file in a bin
    # directory: a package with no such file is reported as exec=none, which is a fact about
    # the package, not a failure of the cycle.
    _cy_exe=$(grep -E '^/(usr/)?s?bin/' "${_cy_list}" 2>/dev/null | grep -v '/$' | head -n 1)
    _cy_exec=na
    if [ -n "${_cy_exe}" ] && [ -x "${_cy_exe}" ]; then
        "${_cy_exe}" --version >/dev/null 2>&1
        _cy_exec=$?
    fi
    _cy_del=$(apk del "${_cy_pkg}" 2>&1)
    _cy_del_rc=$?
    _cy_after=no
    apk info -e "${_cy_pkg}" >/dev/null 2>&1 && _cy_after=yes
    _cy_left=0
    for _cy_f in $(grep '^/' "${_cy_list}" 2>/dev/null | grep -v '/$'); do
        [ -e "${_cy_f}" ] && _cy_left=$((_cy_left + 1))
    done
    _cy_world_after=$(wc -l </etc/apk/world 2>/dev/null | tr -d ' ')
    [ -n "${_cy_world_after}" ] || _cy_world_after=0
    say "pkgcycle pkg=${_cy_pkg} before=${_cy_before} add_rc=${_cy_add_rc} after_add=${_cy_mid} exec=${_cy_exe:-none} exec_rc=${_cy_exec} files=${_cy_files} del_rc=${_cy_del_rc} after_del=${_cy_after} files_left=${_cy_left} world_before=${_cy_world_before} world_after=${_cy_world_after} list=${_cy_list}"
    if [ "${_cy_add_rc}" -ne 0 ]; then
        say "pkgcycle_err=$(printf '%s\n' "${_cy_add}" | sed -n '1p' | tr -d '\r' | cut -c1-80)"
        # Same reason as cmd_pkginstall: the first line names the failure, the lines below it
        # name the cause. A cycle name the feeds cannot solve is measured as unavailable, and
        # the evidence has to say which feed or pin refused it.
        _apk_err_lines "pkgcycle_err_line pkg=${_cy_pkg}" "${_cy_add}"
    fi
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

# cmd_hash_file <path>...: one digest per path, in the order asked, with the tool named.
# The restore comparison asks for the backup and the file it was copied back to: two digests
# from the same tool on the same machine are what "byte-identical" means there, and they cost
# one ssh call rather than a whole file travelling back over the connection.
cmd_hash_file() {
    _hf_tool=$(hash_tool)
    for _hf_f in "$@"; do
        say "hash-file tool=${_hf_tool} file=${_hf_f} sum=$(hash_of "${_hf_f}")"
    done
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

# badcfg_need <count> <usage> <argument>...: the arguments after the class name are
# mandatory, and a missing one is a usage error -- never a default value. The helper runs
# under `set -u`, so a branch that reads $3 when only $2 was passed aborts the whole script
# with "3: parameter not set": stdout ends up empty and the host can only read that as "the
# helper is unavailable", which is how a caller bug in this very function was once filed as
# a device defect. The class name is already consumed by the dispatcher, so the first
# class-specific argument is $1 here.
badcfg_need() {
    _bn_want=$1
    _bn_usage=$2
    shift 2
    [ "$#" -ge "${_bn_want}" ] || {
        say "badcfg=${_bc_cls} rc=2 err=usage want=${_bn_usage} got=$#"
        return 2
    }
    for _bn_arg in "$@"; do
        [ -n "${_bn_arg}" ] || {
            say "badcfg=${_bc_cls} rc=2 err=usage empty-argument want=${_bn_usage}"
            return 2
        }
    done
    return 0
}

# cmd_badcfg <class> ...: write one broken configuration (S8) and report what the machine
# records about it. Nothing is reloaded here: the network class is reloaded by net-apply (the
# same call S2 makes, watchdog included) and the other classes are only *read*, because a
# broken ruleset or a broken daemon config pushed live is how a test takes its own session
# away. Every class prints one `badcfg=` line; the host compares the values in it.
#   network <name> <device> <proto>  an interface naming a link that does not exist
#   firewall <name>                  a rule whose destination port and target are wrong
#   docker <path>                    a daemon.json that is not JSON
#   apk <path> <url>                 a feed list naming a release that is not there
# The class name is shifted off by the dispatcher before this function is called, so each
# branch indexes from $1 and checks its own arity: `badcfg docker <path>` must never be read
# as if the path were the third argument.
# The paths come from the host, not from the helper's environment: the helper is a separate
# script run through ssh, so a variable set on the host never reaches it.
cmd_badcfg() {
    _bc_cls=${1:-}
    [ -n "${_bc_cls}" ] || { say "badcfg=none rc=2 err=usage class-required"; return 2; }
    shift
    case "${_bc_cls}" in
        network)
            badcfg_need 3 "network <name> <device> <proto>" "$@" || return 2
            _bc_name=$1
            _bc_dev=$2
            _bc_proto=$3
            uci set "network.${_bc_name}=interface" 2>/dev/null
            uci set "network.${_bc_name}.device=${_bc_dev}" 2>/dev/null
            uci set "network.${_bc_name}.proto=${_bc_proto}" 2>/dev/null
            uci set "network.${_bc_name}.auto=1" 2>/dev/null
            uci commit network 2>/dev/null
            _bc_rc=$?
            # The uci file itself has to stay readable: a rule can be wrong and the
            # configuration still parse, and those two are different claims.
            uci -q show network >/dev/null 2>&1
            _bc_parse=$?
            say "badcfg=network name=${_bc_name} device=$(uci -q get "network.${_bc_name}.device" 2>/dev/null) proto=$(uci -q get "network.${_bc_name}.proto" 2>/dev/null) commit_rc=${_bc_rc} parse=${_bc_parse}"
            ;;
        firewall)
            badcfg_need 1 "firewall <name>" "$@" || return 2
            _bc_name=$1
            # `uci add` prints the section name it made; the host uses it after the restore
            # to ask whether the rule is really gone.
            _bc_sec=$(uci add firewall rule 2>/dev/null)
            uci set "firewall.${_bc_sec}.name=${_bc_name}" 2>/dev/null
            uci set "firewall.${_bc_sec}.src=lan" 2>/dev/null
            uci set "firewall.${_bc_sec}.dest_port=not-a-port" 2>/dev/null
            uci set "firewall.${_bc_sec}.target=AB-BOGUS" 2>/dev/null
            uci commit firewall 2>/dev/null
            _bc_rc=$?
            uci -q show firewall >/dev/null 2>&1
            _bc_parse=$?
            say "badcfg=firewall name=${_bc_name} sec=${_bc_sec:-none} dest_port=$(uci -q get "firewall.${_bc_sec}.dest_port" 2>/dev/null) target=$(uci -q get "firewall.${_bc_sec}.target" 2>/dev/null) commit_rc=${_bc_rc} parse=${_bc_parse}"
            ;;
        docker)
            badcfg_need 1 "docker <path>" "$@" || return 2
            _bc_path=$1
            mkdir -p "$(dirname "${_bc_path}")" 2>/dev/null
            printf '{\n  "log-driver": "json-file",\n  "log-opts": {\n' >"${_bc_path}"
            _bc_rc=$?
            say "badcfg=docker file=${_bc_path} write_rc=${_bc_rc} bytes=$(wc -c <"${_bc_path}" 2>/dev/null | tr -d ' ')"
            ;;
        apk)
            badcfg_need 2 "apk <path> <url>" "$@" || return 2
            _bc_path=$1
            _bc_url=$2
            mkdir -p "$(dirname "${_bc_path}")" 2>/dev/null
            printf '%s\n' "${_bc_url}" >"${_bc_path}"
            _bc_rc=$?
            say "badcfg=apk file=${_bc_path} write_rc=${_bc_rc} feeds=${_bc_url}"
            ;;
        *)
            say "badcfg=${_bc_cls:-none} rc=2 err=unknown-class"
            return 1
            ;;
    esac
    return 0
}

# cmd_fw_witness <tool> <marker>...: what the firewall tool says about the file, without
# pushing it live. Three facts, and the last one is the one that decides adoption:
#   fw-check tool=<tool> rc=<rc> lines=<n>   and one fw-check-out= line per output line
#   fw-print tool=<tool> rc=<rc> lines=<n>   the ruleset the configuration renders to
#   fw-print-marker marker=<m> hits=<n>      whether <m> appears in that ruleset
# fw4 on the 25.x line warns about an invalid uci option and *skips the section*: the check
# still exits 0 and the rendered ruleset simply does not contain the rule (measured for
# dest_port=not-a-port, for target=AB-BOGUS, and for both together). The exit status
# therefore says nothing about whether a rule was adopted, and the print is the witness.
cmd_fw_witness() {
    _fw_tool=${1:-}
    [ -n "${_fw_tool}" ] || { say "fw-witness rc=2 err=usage tool-required"; return 2; }
    shift
    _fw_chk_file=/tmp/ab-scen-fw-check.out
    _fw_pr_file=/tmp/ab-scen-fw-print.out
    _fw_pr_err=/tmp/ab-scen-fw-print.err
    "${_fw_tool}" check >"${_fw_chk_file}" 2>&1
    _fw_chk_rc=$?
    say "fw-check tool=${_fw_tool} rc=${_fw_chk_rc} lines=$(wc -l <"${_fw_chk_file}" 2>/dev/null | tr -d ' ')"
    # The warning is the evidence, so the output travels with it; the cap keeps a tool
    # that prints a whole translation table from filling the ssh answer.
    sed -n '1,20p' "${_fw_chk_file}" 2>/dev/null | sed -e 's/^/fw-check-out=/'
    # stdout is the rendered ruleset and stderr is the warnings: they are kept apart, because
    # a warning that happens to name the broken value must not be mistaken for the rule being
    # present in the ruleset.
    "${_fw_tool}" print >"${_fw_pr_file}" 2>"${_fw_pr_err}"
    _fw_pr_rc=$?
    say "fw-print tool=${_fw_tool} rc=${_fw_pr_rc} lines=$(wc -l <"${_fw_pr_file}" 2>/dev/null | tr -d ' ') warned=$(wc -l <"${_fw_pr_err}" 2>/dev/null | tr -d ' ')"
    for _fw_m in "$@"; do
        _fw_hits=$(grep -c -F -- "${_fw_m}" "${_fw_pr_file}" 2>/dev/null)
        [ -n "${_fw_hits}" ] || _fw_hits=0
        say "fw-print-marker marker=${_fw_m} hits=${_fw_hits}"
    done
    return 0
}

# cmd_dockerinfo <tries> <pause>: ask the daemon whether it is really serving, more than
# once. dockerd needs three to four seconds after a restart before its API answers, so a
# single `docker info` right after the restart reads a healthy daemon as broken (measured on
# the 25.x line: restart_rc=0, pidof still answers, docker info rc=1 for a few seconds and
# then rc=0; the log says "unexpected end of JSON input" in between). The retries live here
# so the host makes one ssh call per observation instead of four.
# One line per attempt, then one summary line the host judges:
#   docker-info attempts=<n> up=yes|no rc=<last rc> images=<count|na>
cmd_dockerinfo() {
    _di_tries=${1:-4}
    _di_pause=${2:-1}
    _di_n=0
    _di_rc=1
    _di_out=/tmp/ab-scen-dockerinfo.out
    while [ "${_di_n}" -lt "${_di_tries}" ]; do
        _di_n=$((_di_n + 1))
        docker info >"${_di_out}" 2>&1
        _di_rc=$?
        say "docker-info attempt=${_di_n} rc=${_di_rc} out=$(sed -n '1p' "${_di_out}" 2>/dev/null | cut -c1-100)"
        [ "${_di_rc}" -eq 0 ] && break
        [ "${_di_n}" -lt "${_di_tries}" ] && sleep "${_di_pause}"
    done
    _di_up=no
    [ "${_di_rc}" -eq 0 ] && _di_up=yes
    # The image count is what "the daemon came back" means beyond "it answers": a daemon
    # that starts empty is a daemon the class did not restore. Counted only while it is up;
    # `docker images -q` against a dead daemon prints nothing and would read as "zero".
    _di_imgs=na
    if [ "${_di_up}" = yes ]; then
        _di_imgs=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
        [ -n "${_di_imgs}" ] || _di_imgs=na
    fi
    say "docker-info attempts=${_di_n} up=${_di_up} rc=${_di_rc} images=${_di_imgs}"
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
[ -n "${_cmd}" ] || { say "usage: ab-scen-helper.sh <probe|mkdirs|pkginstall|pkgsnap|pkgcheck|pkgcycle|kmodcheck|exec|seed|hash|hash-file|tartest|cfg-*|badcfg|fw-witness|docker-info|net-*|overlay-probe|svc-cycle|boottools>"; exit 2; }
shift
case "${_cmd}" in
    probe) cmd_probe ;;
    mkdirs) cmd_mkdirs "$@" ;;
    pkginstall) cmd_pkginstall "$@" ;;
    pkgsnap) cmd_pkgsnap "$@" ;;
    pkgcheck) cmd_pkgcheck "$@" ;;
    pkgcycle) cmd_pkgcycle "$@" ;;
    kmodcheck) cmd_kmodcheck "$@" ;;
    exec) cmd_exec "$@" ;;
    seed) cmd_seed "$@" ;;
    hash) cmd_hash "$@" ;;
    hash-file) cmd_hash_file "$@" ;;
    tartest) cmd_tartest "$@" ;;
    cfg-backup) cmd_cfg_backup "$@" ;;
    cfg-write) cmd_cfg_write "$@" ;;
    cfg-system) cmd_cfg_system "$@" ;;
    cfg-net) cmd_cfg_net "$@" ;;
    cfg-fw) cmd_cfg_fw "$@" ;;
    cfg-read) cmd_cfg_read "$@" ;;
    badcfg) cmd_badcfg "$@" ;;
    fw-witness) cmd_fw_witness "$@" ;;
    docker-info) cmd_dockerinfo "$@" ;;
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

# pkg_apk_why <label> <helper output>: every line apk wrote about a package it refused,
# copied into the evidence. The `pkg=` line carries the first line only, and on this image
# the first line is `ERROR: unable to select packages:` with the cause (`breaks:
# world[kernel=...]`, `required by:`) on the lines below it. Losing those lines is what
# turned a stale-payload gap into an unexplainable one in the first full run: the record
# said rc=99 and could not be shown to be the pin rather than a package that is not there.
pkg_apk_why() {
    _pw_label=${1:?pkg_apk_why needs a label}
    printf '%s\n' "${2:-}" \
        | sed -n -e "s/^pkgerr /pkg ${_pw_label}: /p" \
            -e "s/^pkgcycle_err_line /pkgcycle ${_pw_label}: /p" \
        | while IFS= read -r _pw_line; do
            ev "${_pw_line}"
        done
}

# pkg_apk_reason <helper output>: the line apk wrote that names the cause, for the row's
# own note. Empty when apk did not write one, so a note falls back to the first line.
pkg_apk_reason() {
    printf '%s\n' "${1:-}" \
        | sed -n -e 's/^pkgerr pkg=[^ ]* line=[0-9]* //p' \
            -e 's/^pkgcycle_err_line pkg=[^ ]* line=[0-9]* //p' \
        | grep -m 1 -E 'breaks:|required by:|conflict|not found' || :
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
    # The machine may still be moving its own packages onto the base it booted, and that
    # transaction holds the apk database lock for minutes: the first apk call of this case is
    # where a locked database used to cost the whole round (S1 GAP, then S3/S4/S5 "run S1
    # first"). The wait is bounded and its number lands in the row.
    need_apk_lock "the S1 package batch" || return 2

    _kver=$(kv "${PROBE}" kver)
    _stamp=${SCEN_STAMP}
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
        _pkg_out=$(scen pkginstall "${_p}" 2>/dev/null)
        _line=$(printf '%s\n' "${_pkg_out}" | grep '^pkg=' | head -n 1)
        _state=$(kv "${_line}" state)
        _rc=$(printf '%s\n' "${_line}" | sed -n 's/.* rc=\([^ ]*\).*/\1/p')
        _ver=$(printf '%s\n' "${_line}" | sed -n 's/.* version=\([^ ]*\).*/\1/p')
        _err=$(printf '%s\n' "${_line}" | sed -n 's/.* err=\(.*\)$/\1/p' | cut -c1-60)
        # The cause apk wrote below its first line, for the row's note: `rc=99` alone does
        # not say whether the feed lacks the package or the world file pins a kernel the
        # feed does not serve.
        _why=$(pkg_apk_reason "${_pkg_out}" | cut -c1-160)
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
                _unavailable="${_unavailable}${_p}(rc=${_rc:-?}:${_why:-${_err:-no-error-line}}) "
                printf 'unavailable\t%s\t%s\t%s\n' "${_p}" "${_rc:-?}" "${_err:-no-error-line}" >>"${probefile}"
                ev "preinstall ${_p}: unavailable rc=${_rc:-?} ${_err:-no error line}"
                pkg_apk_why "${_p}" "${_pkg_out}"
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

    # R5's other half: an install-then-remove has to leave nothing behind. The cycle runs on
    # a package this machine does not have yet (cmd_pkgcycle refuses a package that is
    # installed, because removing one the user put there would damage the machine it
    # measures), and every witness is compared here rather than on the machine: the package
    # record, the files apk said it owned, and the line count of /etc/apk/world.
    _cy_pkg=""
    _cy_line=""
    _cy_err=""
    _cy_why=""
    for _p in ${SCEN_PKGCYCLE}; do
        _cy_out=$(scen pkgcycle "${_p}" "${SCEN_EVIDENCE}/pkgcycle-${_p}.list" 2>/dev/null)
        _line=$(printf '%s\n' "${_cy_out}" | grep '^pkgcycle ' | head -n 1)
        [ -n "${_line}" ] || continue
        _cy_err=$(printf '%s\n' "${_cy_out}" | sed -n 's/^pkgcycle_err=//p' | head -n 1)
        _cy_why=$(pkg_apk_reason "${_cy_out}" | cut -c1-160)
        if [ "$(kv "${_line}" skipped)" = "yes" ]; then
            ev "pkgcycle ${_p}: already installed on this machine, so a cycle would not prove an uninstall; trying the next name"
            continue
        fi
        if [ "$(kv "${_line}" after_add)" != "yes" ]; then
            ev "pkgcycle ${_p}: could not be installed (rc=$(kv "${_line}" add_rc): ${_cy_why:-${_cy_err:-no error line}}), so it cannot prove an uninstall"
            pkg_apk_why "${_p}" "${_cy_out}"
        fi
        _cy_pkg=${_p}
        _cy_line=${_line}
        # A name the feeds do not serve is remembered and the next one is tried: the list is
        # several names long because an image may carry a feed set that lacks one of them, and
        # the uninstall is still measurable with another.
        [ "$(kv "${_line}" after_add)" = "yes" ] || continue
        break
    done
    if [ -z "${_cy_pkg}" ]; then
        # Nothing to cycle with is a fact about the image, not a broken machine: the same rule
        # the batch above follows for a package the repositories do not have.
        _finding "no package from '${SCEN_PKGCYCLE}' could be installed and removed again (all already installed, or none available), so the uninstall half of R5 was not measured"
        _cy_outcome="not measured"
        printf 'pkgcycle\tnone\tnot-installed\n' >>"${probefile}"
    elif [ "$(kv "${_cy_line}" after_add)" != "yes" ]; then
        _finding "${_cy_pkg} could not be installed for the install-then-remove cycle (rc=$(kv "${_cy_line}" add_rc): ${_cy_why:-${_cy_err:-no error line}}), so the uninstall half of R5 was not measured"
        _cy_outcome="${_cy_pkg} unavailable"
        printf 'pkgcycle\t%s\tunavailable\n' "${_cy_pkg}" >>"${probefile}"
    else
        # The install worked, so the uninstall is judged: three independent witnesses, each
        # failing on its own. A package that apk no longer knows but whose files survive is
        # exactly the residue R5 asks about.
        [ "$(kv "${_cy_line}" del_rc)" = "0" ] \
            || _fail "${_case}" "pkgcycle ${_cy_pkg}: apk del exited $(kv "${_cy_line}" del_rc)"
        [ "$(kv "${_cy_line}" after_del)" = "no" ] \
            || _fail "${_case}" "pkgcycle ${_cy_pkg}: apk info -e still answers after apk del, so the package is still recorded as installed"
        [ "$(kv "${_cy_line}" files_left)" = "0" ] \
            || _fail "${_case}" "pkgcycle ${_cy_pkg}: $(kv "${_cy_line}" files_left) of the $(kv "${_cy_line}" files) file(s) apk listed are still on disk after the uninstall"
        [ "$(kv "${_cy_line}" world_before)" = "$(kv "${_cy_line}" world_after)" ] \
            || _fail "${_case}" "pkgcycle ${_cy_pkg}: /etc/apk/world has $(kv "${_cy_line}" world_after) line(s) after the uninstall, it had $(kv "${_cy_line}" world_before) before"
        case "$(kv "${_cy_line}" exec_rc)" in
            0) ev "pkgcycle ${_cy_pkg}: installed, $(kv "${_cy_line}" exec) --version ran, $(kv "${_cy_line}" files) file(s) listed, removed cleanly (world $(kv "${_cy_line}" world_before) -> $(kv "${_cy_line}" world_after))" ;;
            none | na)
                _finding "pkgcycle ${_cy_pkg}: the package has no file in a bin directory, so it could not be executed once (the file and world witnesses still hold)"
                ;;
            *)
                _fail "${_case}" "pkgcycle ${_cy_pkg}: $(kv "${_cy_line}" exec) --version exited $(kv "${_cy_line}" exec_rc) while it was installed"
                ;;
        esac
        _cy_outcome="${_cy_pkg} removed cleanly"
        printf 'pkgcycle\t%s\t%s\n' "${_cy_pkg}" "$(kv "${_cy_line}" after_del)" >>"${probefile}"
    fi

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
    CASE_NOTE="installed ${_ok}/$(printf '%s' "${SCEN_PKGS}" | wc -w | tr -d ' ') (${_pkgs_ok} package(s), ${_kmod_ok} kmod), snapshot ${_snap_n:-0} rows, install-then-remove ${_cy_outcome:-not measured}$(apk_lock_suffix)"
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

    _stamp=${SCEN_STAMP}
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

# hop_packages_reasons <case>: the `packages_reason` values this case's hop may land in.
#
# `none` is the healthy answer on every hop: the aligner wrote its record and had nothing to
# report. S7 is the one case that moves the feed list itself, so on that case's path the
# aligner's honest answer is `network`: it recorded the index refresh it could not do, and
# the list it could not refresh is the one S7 wrote a moment earlier. Round 3 measured this
# and the row read as a product defect on a hop that had committed, switched slots and
# aligned its packages. The allowance is exactly one extra token on one case's path, never a
# class of reasons: `limited` (the metadata is partial, so nothing installs for this kernel),
# `unknown` (no record was written at all) and every other token stay red, because each of
# them says something about the machine that this case does not own.
hop_packages_reasons() {
    case "${1:-}" in
        S7) printf 'none network\n' ;;
        *) printf 'none\n' ;;
    esac
}

# hop_packages_reason <case> <status line>: judge the reason the hop landed in.
# Returns 1 when it is not one this case may land in, having printed the FAIL line.
hop_packages_reason() {
    _hpr_case=${1:?hop_packages_reason needs a case}
    _hpr_reason=$(status_field "${2:-}" packages_reason) || _hpr_reason=""
    for _hpr_allowed in $(hop_packages_reasons "${_hpr_case}"); do
        if [ "${_hpr_reason}" = "${_hpr_allowed}" ]; then
            # An accepted reason that is not `none` is still something the reader has to be
            # able to tell apart from a clean hop, so it is named in the evidence and in the
            # row's note. Without this the row would say PASS beside a reason the plan does
            # not promise, which is the same silent loosening this file avoids elsewhere.
            if [ "${_hpr_reason}" != "none" ]; then
                _finding "packages_reason=${_hpr_reason} (feed was moved by this case): the aligner recorded the index refresh it could not do, and the feed list it could not refresh is this case's own edit, so this is not a defect"
            fi
            return 0
        fi
    done
    _dev_assert_fail "${_hpr_case}" "assert_field packages_reason: expected=none got=${_hpr_reason:-none-absent}"
    return 1
}

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
    # Same promise the plan line makes, and the same comparison matrix.sh runs: the stable
    # fields against the line captured before the payload was pushed (see lib.sh for why the
    # monitored fields are printed but not judged).
    _check ab_status_switch_check "${_before}" "${_booted}" "${_case}"
    _check assert_field boot ok "${_case}"
    _check assert_field esp ok "${_case}"
    _check assert_field pending none "${_case}"
    _check assert_field committed "${_target}" "${_case}"
    _check assert_field slot "${_target}" "${_case}"
    _check assert_match "$(status_field "${_booted}" upper || printf '')" \
        "^@overlay-$(dev_version_re "${_version}")(-r[0-9]+)?\$" "${_case}" upper
    # The package metadata is part of the result of a hop, not a field that merely moves with
    # it: ac-4 asks for `packages=aligned packages_reason=none` after every jump, and a machine
    # left `limited` needs its world file or distfeeds.list fixed before it can install
    # anything again. lib.sh still lists the pair under MONITORED for the *before/after*
    # comparison, which is right -- the movement is not a criterion -- but the value the hop
    # lands in is judged here, and the failure names both fields, so `limited` comes with the
    # reason the aligner recorded.
    # `followed` is accepted beside `aligned`, and it is not a loosening: the product reports
    # it for the same metadata after the follow transaction moved the packages onto the new
    # base, so a jump that carried 168 packages there lands in it. Judging only `aligned` made
    # the strongest possible outcome of a jump read as a failure (round 2: S3/S4/S7 red on a
    # hop that had done exactly what ac-3 asks for). `limited` and `unknown` still fail: the
    # first cannot install anything for its own kernel, the second is no record at all.
    # The reason the hop lands in is judged by hop_packages_reason, which is `none` on every
    # case but S7: S7 moved the feed list itself, so `network` is its own edit reported back
    # and not a defect, while every other reason stays red there too.
    _check assert_field packages aligned "${_case}"
    _check hop_packages_reason "${_case}" "${_booted}"
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
    # Only the 25.x/apk line is in scope; a 24.x or opkg-era payload is refused here, with
    # a line that says so, instead of being installed and judged as if it were ours.
    if ! _line_out=$(require_supported_line "${_to}" "${PAYLOAD_DIR}/payload-${_to}.tar" 2>&1); then
        CASE_NOTE="${_line_out}"
        ev "${_line_out}"
        return 1
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
    _stamp=${SCEN_STAMP}
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
    # The same lock as S1: the hop that positioned this machine may still be following
    # packages. The refresh is what the case is about, so a machine that is still locked is a
    # GAP naming the seconds -- not "this machine cannot reach its own feeds".
    if ! need_apk_lock "the ${_from} feed refresh"; then
        s7_restore_or_warn "${_bakf}"
        return 2
    fi
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
        _pkg_out=$(scen pkginstall "${_p}" 2>/dev/null)
        _line=$(printf '%s\n' "${_pkg_out}" | grep '^pkg=' | head -n 1)
        case "$(kv "${_line}" state)" in
            installed)
                _inst=$((_inst + 1))
                ev "install ${_p}: $(kv "${_line}" version) from ${_from}'s feeds"
                ;;
            *)
                _err=$(printf '%s' "${_line}" | sed -n 's/.* err=//p' | cut -c1-60)
                _why=$(pkg_apk_reason "${_pkg_out}" | cut -c1-160)
                _unavail="${_unavail}${_p}($(kv "${_line}" rc):${_why:-${_err:-no-error-line}}) "
                ev "install ${_p}: unavailable $(kv "${_line}" rc) ${_err:-no error line}"
                pkg_apk_why "${_p}" "${_pkg_out}"
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
            # scen_hop has already named the step that failed, and its wording is kept: this
            # branch catches a jump that really did not commit *and* a jump that committed
            # with one judged field disagreeing. Writing "did not commit" for both made round
            # 3 read a hop that had committed, switched slots and aligned its packages as a
            # broken jump, which sent the diagnosis after the wrong defect.
            CASE_NOTE="the jump to ${_to} was judged red (${CASE_NOTE:-scen_hop recorded no reason}); the feed list was put back"
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
        # The cause is named as a candidate and not as a fact: since the platform layer
        # reads /etc/apk/repositories.d/*.list and rewrites the kmods segment itself
        # (platform/lib/upgrade/packages.sh), a list that did not move says the payload's
        # platform layer did not rewrite it. The first full run read this finding on a
        # payload built from the release before that change, and its wording - "ab-upgrade
        # keeps it as user configuration" - described the old release, so it named a design
        # that no longer exists and hid the real cause behind it.
        _finding "the package source did not follow the version: after the jump to ${_to}, ${SCEN_S7_FEEDS} still names ${_from}'s feeds, so the kmods index in use is $(s7_feed_of "${_after_feeds}" kmods) while the machine runs kernel ${_kver_b}; a payload whose platform layer rewrites repositories.d would have moved it, so the payload or the layer it installed is what to look at"
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
    # Same lock, second time: step 6 runs right after the jump. A feed that could not be
    # refreshed because the machine was busy says so in a GAP instead of failing the case.
    if ! need_apk_lock "the ${_to} feed refresh"; then
        s7_restore_or_warn "${_bakf}"
        return 2
    fi
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
        _pkg_out=$(scen pkginstall "${_p}" 2>/dev/null)
        _line=$(printf '%s\n' "${_pkg_out}" | grep '^pkg=' | head -n 1)
        _state=$(kv "${_line}" state)
        _ver=$(kv "${_line}" version)
        _err=$(printf '%s' "${_line}" | sed -n 's/.* err=//p' | cut -c1-60)
        _why=$(pkg_apk_reason "${_pkg_out}" | cut -c1-160)
        _changed=no
        if [ "${_state}" = "installed" ] && { [ -z "${_before}" ] || [ "${_before}" != "${_ver}" ]; }; then
            _changed=yes
        fi
        ev "aligned install ${_p}: state=${_state} before=${_before:-not-installed} after=${_ver:-none} changed=${_changed} ${_err}"
        pkg_apk_why "${_p}" "${_pkg_out}"
        if [ "${_p}" = "${_kmod_first}" ]; then
            _kmod_state=${_state}
            _kmod_err=${_why:-${_err:-no-error-line}}
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
    CASE_NOTE="${_from}->${_to}: A ${_n_a} / B ${_n_b} installed package(s), diff ${_n_chg} version change(s), ${_n_gone} disappeared, ${_n_new} new (${_n_unchanged:-0} unchanged), kernel ${_kver_a:-?}->${_kver_b:-?}; feeds after the jump ${_feeds_state}; aligned ${_to} feeds install ${_proved} (${_proved_ver:-unknown}); ${SCEN_S7_FEEDS} restored$(apk_lock_suffix)"
    return 0
}

# --------------------------------------------------------------------------- #
# S8: bad configuration -- what the machine does when the file is simply wrong
# --------------------------------------------------------------------------- #

# s8_bak_dir <class> <stamp>: one directory per class, so "which backup" is a path a person
# can type and the recovery record can carry.
s8_bak_dir() {
    printf '%s/badcfg-%s-%s\n' "${SCEN_BACKUP}" "$1" "$2"
}

# s8_backup <class> <bakdir> <file>...: this class's backup, which is its precondition and not
# a step inside it. Returns 1 when the copies did not all land -- the class then writes
# nothing at all, because a broken file with no way back is not a measurement.
s8_backup() {
    _s8b_cls=$1
    _s8b_bak=$2
    shift 2
    _s8b_want=$#
    _s8b_out=$(scen cfg-backup "${_s8b_bak}" "$@" 2>/dev/null)
    _s8b_n=$(kv "${_s8b_out}" backups)
    case "${_s8b_n}" in
        '' | *[!0-9]*) _s8b_n=0 ;;
    esac
    ev "S8 ${_s8b_cls}: backup ${_s8b_n}/${_s8b_want} of '$*' -> ${_s8b_bak}"
    [ "${_s8b_n}" -eq "${_s8b_want}" ] || return 1
    return 0
}

# s8_collect <remote> <local>: the bytes as they were, taken before the class writes over them.
# The restore is judged against this file, never against a claim that a copy "should" be back.
s8_collect() {
    if dev_collect "$1" "$2"; then
        return 0
    fi
    rm -f "$2" 2>/dev/null
    return 1
}

# s8_restore_ok <target> <backup on the machine> <local original>: put the backup back and
# compare what the machine has afterwards with the bytes collected before the class started.
# Copying is not proof; the comparison is (the same rule s7_restore follows).
s8_restore_ok() {
    _s8r_cp=$(scen exec cp "$2" "$1" 2>/dev/null | grep '^cmd=' | head -n 1)
    if [ "$(kv "${_s8r_cp}" rc)" != "0" ]; then
        ev "S8 restore: cp $2 $1 failed (${_s8r_cp:-no answer}); put it back by hand"
        return 1
    fi
    # Two independent comparisons, because "the backup came back" and "the bytes that were
    # there came back" are not the same claim: the machine hashes the backup against the file
    # it was copied to (same tool, same machine, one ssh call), and the host compares the
    # collected file with the bytes collected before the class started changing anything.
    _s8r_h=$(scen hash-file "$2" "$1" 2>/dev/null)
    _s8r_sum_bak=$(printf '%s\n' "${_s8r_h}" | sed -n 's/.* sum=\([^ ]*\).*/\1/p' | sed -n '1p')
    _s8r_sum_file=$(printf '%s\n' "${_s8r_h}" | sed -n 's/.* sum=\([^ ]*\).*/\1/p' | sed -n '2p')
    _s8r_tool=$(kv "$(printf '%s\n' "${_s8r_h}" | head -n 1)" tool)
    if [ -n "${_s8r_sum_bak}" ] && [ -n "${_s8r_sum_file}" ] \
        && [ "${_s8r_sum_bak}" != "none" ] && [ "${_s8r_sum_file}" != "none" ]; then
        if [ "${_s8r_sum_bak}" != "${_s8r_sum_file}" ]; then
            ev "S8 restore: $1 does not match the backup by ${_s8r_tool} (${_s8r_sum_file} vs ${_s8r_sum_bak})"
            return 1
        fi
        ev "S8 restore: $1 matches ${2} by ${_s8r_tool} (${_s8r_sum_file})"
    else
        # No digest tool on the machine: the host-side comparison below is the reduction,
        # and the fact that the machine could not hash is said out loud.
        ev "S8 restore: no digest tool on the machine (hash=${_s8r_tool:-none}), so the comparison is host-side only"
    fi
    if ! dev_collect "$1" "$3.after"; then
        ev "S8 restore: $1 is not readable after the restore"
        return 1
    fi
    cmp -s "$3" "$3.after"
}

# s8_record <class> <backup> <restored-by> <outcome>: one row of the recovery record.
# "Which file, where the copy is, who put it back" is the deliverable of this case, and it is
# a file on the machine's /data rather than a line in a log that dies with the run.
s8_record() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"${_tmp}/s8-classes.tsv"
    ev "S8 $1: backup=$2 restored_by=$3 outcome=$4"
}

# s8_notjudged <class> <bakdir> <reason> [restored-by]: the class could not be judged on this
# machine. A FINDING and a row in the record -- never a silent pass, and never a FAIL for a
# file the image simply does not have.
s8_notjudged() {
    _finding "S8 $1: not judged: $3"
    s8_record "$1" "${2:--}" "${4:-none}" "not-judged: $3"
    _s8_skipped=$((_s8_skipped + 1))
    _s8_skipped_names="${_s8_skipped_names}$1 "
}

# s8_intact <class>: the machine is still a machine while the configuration is broken.
# ab-slot status readable, boot=ok, esp=ok and data=ok on it (the user's data is still
# mounted), and two consecutive ssh answers (ssh_alive) -- "ssh answered once" is exactly the
# reading that hides a half-applied change. The package fields are printed as facts and not
# judged here: S8's question is whether the machine survives a wrong file, and
# `packages=limited` is a degradation ab-slot records, not a crash. What a jump leaves behind
# is a different question, asked in scen_hop.
s8_intact() {
    _s8i_cls=$1
    _s8i_line=$(dev_status) || _s8i_line=""
    if [ -z "${_s8i_line}" ]; then
        _fail "${_case}" "${_s8i_cls}: ab-slot status is unreadable while the broken configuration is in place"
        return 1
    fi
    AB_STATUS_LINE=${_s8i_line}
    _check assert_field boot ok "${_case}"
    _check assert_field esp ok "${_case}"
    _check assert_field data ok "${_case}"
    if ! ssh_alive; then
        _fail "${_case}" "${_s8i_cls}: ssh stopped answering while the broken configuration was in place"
        return 1
    fi
    ev "S8 ${_s8i_cls}: machine intact -- boot=$(status_field "${_s8i_line}" boot || printf '?') esp=$(status_field "${_s8i_line}" esp || printf '?') data=$(status_field "${_s8i_line}" data || printf '?') packages=$(status_field "${_s8i_line}" packages || printf '?') packages_reason=$(status_field "${_s8i_line}" packages_reason || printf '?')"
    return 0
}

# s8_net <stamp>: the network class. A section naming a device nothing has, with a proto
# nothing implements. It is reloaded through S2's net-apply -- backup, machine-scheduled revert,
# reload -- so the rollback machinery under test is the one that is used, and the host-side
# net-rollback closes it. Two outcomes are accepted (the reload refused, or applied with the
# section never coming up); neither counts unless the session survives and the file goes back.
s8_net() {
    _cls=network
    _s8_outcome="network: refused or degraded, restored"
    _bak=$(s8_bak_dir network "$1")
    _orig="${_tmp}/s8-network-original"
    if ! s8_backup "${_cls}" "${_bak}" /etc/config/network /etc/config/firewall /etc/config/system; then
        s8_notjudged "${_cls}" "${_bak}" "/etc/config/{network,firewall,system} could not be backed up, so nothing was broken"
        return 2
    fi
    if ! s8_collect /etc/config/network "${_orig}"; then
        s8_notjudged "${_cls}" "${_bak}" "/etc/config/network is not readable on this machine"
        return 2
    fi

    _bad=$(scen badcfg network "${SCEN_S8_UCI}net" "${SCEN_S8_BADNET_DEV}" "${SCEN_S8_BADNET_PROTO}" 2>/dev/null | grep '^badcfg=' | head -n 1)
    case "${_bad}" in
        *commit_rc=0*) ev "S8 network: broken section written -- ${_bad}" ;;
        *) _fail "${_case}" "network: the broken section did not commit (${_bad:-no answer})" ;;
    esac
    # A rule can be wrong and the file still parse; those are two different claims and only
    # the second one is about the configuration system rather than about netifd.
    [ "$(kv "${_bad}" parse)" = "0" ] \
        || _fail "${_case}" "network: /etc/config/network stopped parsing after the broken section (parse=$(kv "${_bad}" parse))"

    _ap=$(scen net-apply "${_bak}" "${SCEN_ROLLBACK_GRACE}" 2>/dev/null \
        | grep -E '^(watchdog|net-reload)(=|[[:space:]])')
    if ! printf '%s\n' "${_ap}" | grep -q '^watchdog='; then
        _fail "${_case}" "network: the reload step reported no watchdog line, so no revert could have been scheduled"
        if ! s8_restore_ok /etc/config/network "${_bak}/_etc_config_network.bak" "${_orig}"; then
            _fail "${_case}" "network: /etc/config/network is not byte-identical to ${_bak}/_etc_config_network.bak after the restore"
        fi
        s8_record "${_cls}" "${_bak}" "host" "the reload step answered no watchdog line"
        return 1
    fi
    if [ "$(kv "${_ap}" watchdog)" = "no" ]; then
        # The helper wrote the file and did not reload it (see cmd_net_apply): the machine
        # never saw the broken section, so this class measured nothing. The backup goes back
        # and the skipped half is said out loud.
        if s8_restore_ok /etc/config/network "${_bak}/_etc_config_network.bak" "${_orig}"; then
            ev "S8 network: /etc/config/network restored from ${_bak}"
        else
            _fail "${_case}" "network: /etc/config/network is not byte-identical to ${_bak}/_etc_config_network.bak after the restore"
        fi
        s8_notjudged "${_cls}" "${_bak}" "this image has neither setsid nor start-stop-daemon, so the machine cannot schedule its own revert; the section was written and never reloaded" "host"
        return 2
    fi
    _reload_rc=$(printf '%s\n' "${_ap}" | sed -n 's/^net-reload rc=\([^ ]*\).*/\1/p')
    ev "S8 network: reload step -- $(printf '%s' "${_ap}" | tr '\n' ' ')"

    # The refusal witness is not net-reload's exit status: `ubus call network reload` answers 0
    # whatever the sections say (measured on this line of releases). What a machine that
    # refused the section cannot have is a link that does not exist, so the device is asked
    # for by name.
    _lk=$(scen exec ip link show "${SCEN_S8_BADNET_DEV}" 2>/dev/null | grep '^cmd=' | head -n 1)
    _lk_rc=$(kv "${_lk}" rc)
    if [ -z "${_lk_rc}" ] || [ "${_lk_rc}" = "127" ]; then
        # No answer is not a refusal, and neither is "this image has no ip": a witness that
        # did not run proves nothing, and the ssh check below decides this class instead.
        _finding "S8 network: the refusal could not be witnessed ('ip link show ${SCEN_S8_BADNET_DEV}' answered rc=${_lk_rc:-none}); the section's effect was not measured"
    elif [ "${_lk_rc}" = "0" ]; then
        _fail "${_case}" "network: ${SCEN_S8_BADNET_DEV} exists after the reload, so the machine created a link nothing has instead of refusing the section"
        _s8_outcome="network: ${SCEN_S8_BADNET_DEV} came up, the section was adopted instead of refused"
    else
        ev "S8 network: refused or ignored -- ${SCEN_S8_BADNET_DEV} was never created (ip link rc=${_lk_rc}, reload rc=${_reload_rc:-?})"
    fi

    if ! ssh_alive; then
        _fail "${_case}" "network: ssh stopped answering after the broken section was reloaded; the machine restores ${_bak} within ${SCEN_ROLLBACK_GRACE}s or the host does it now"
        _s8_outcome="network: ssh lost after the reload, rolled back from ${_bak}"
        _rb=$(scen net-rollback "${_bak}" 2>/dev/null | grep -E '^(restore=|rollback=)')
        if [ -n "${_rb}" ]; then
            ev "S8 network: host rollback -- $(printf '%s' "${_rb}" | tr '\n' ' ')"
        else
            ev "S8 network: host rollback could not reach the machine; the watchdog restores ${_bak} within ${SCEN_ROLLBACK_GRACE}s"
        fi
        if dev_wait_up_after plain; then
            ev "the machine answers ssh again after the rollback"
        else
            ev "the machine did not answer within ${AB_WAIT_UP}s after the rollback"
        fi
        machine_unreachable_mark
        s8_record "${_cls}" "${_bak}" "machine watchdog and host rollback" "ssh lost after the reload"
        return 1
    fi
    ev "S8 network: ssh answered ${SCEN_LIVENESS_OK} times after the reload of the broken section"

    # Back to the bytes that were there. net-rollback is the host-issued revert (it also
    # confirms the machine's scheduled one away); the comparison is what makes it a restore.
    _rb=$(scen net-rollback "${_bak}" 2>/dev/null | grep -E '^(restore=|rollback=)')
    ev "S8 network: host rollback -- $(printf '%s' "${_rb}" | tr '\n' ' ')"
    if s8_restore_ok /etc/config/network "${_bak}/_etc_config_network.bak" "${_orig}"; then
        ev "S8 network: /etc/config/network is byte-identical to ${_bak}/_etc_config_network.bak again"
        s8_record "${_cls}" "${_bak}" "host (net-rollback; the machine's scheduled revert was confirmed away)" "refused or degraded, restored byte for byte"
    else
        _fail "${_case}" "network: /etc/config/network is not byte-identical to ${_bak}/_etc_config_network.bak after the restore"
        _s8_outcome="network: the restore is not byte-identical to ${_bak}"
        s8_record "${_cls}" "${_bak}" "host (incomplete)" "restore is not byte-identical to the backup"
    fi
    s8_intact "${_cls}" || return 1
    return 0
}

# s8_fw <stamp>: the firewall class. A rule whose destination port is not a port and whose
# target is not a target. The broken ruleset is never reloaded -- a bad rule pushed to a live
# firewall is how a test takes its own session away -- so the class asks the tool what the
# file renders to, and judges adoption rather than the tool's exit status:
#   * the rule must NOT appear in the rendered ruleset (`fw4 print`): it was skipped;
#   * the check's output must carry the warning that explains the skip;
#   * the check's rc is recorded as the fact it is (0 on this line), never as a refusal;
#   * the restore must be byte-identical, the restored ruleset must check clean and reload,
#     and the machine must still answer ssh twice.
# A rule that was adopted, or a machine that stopped answering, is a FAIL. The semantics that
# make this the right witness are in the file header (fw4 fails safe: it warns and skips).
s8_fw() {
    _cls=firewall
    _s8_outcome="firewall: skipped by the tool (not adopted), restored"
    _bak=$(s8_bak_dir firewall "$1")
    _orig="${_tmp}/s8-firewall-original"
    if ! s8_backup "${_cls}" "${_bak}" /etc/config/firewall; then
        s8_notjudged "${_cls}" "${_bak}" "/etc/config/firewall could not be backed up, so nothing was broken"
        return 2
    fi
    if ! s8_collect /etc/config/firewall "${_orig}"; then
        s8_notjudged "${_cls}" "${_bak}" "/etc/config/firewall is not readable on this machine"
        return 2
    fi

    _bad=$(scen badcfg firewall "${SCEN_S8_UCI}fw" 2>/dev/null | grep '^badcfg=' | head -n 1)
    case "${_bad}" in
        *commit_rc=0*) ev "S8 firewall: broken rule written -- ${_bad}" ;;
        *) _fail "${_case}" "firewall: the broken rule did not commit (${_bad:-no answer})" ;;
    esac
    [ "$(kv "${_bad}" parse)" = "0" ] \
        || _fail "${_case}" "firewall: /etc/config/firewall stopped parsing after the broken rule (parse=$(kv "${_bad}" parse))"
    _sec=$(kv "${_bad}" sec)

    # The two markers the rendered ruleset would carry if the rule had been adopted: the
    # bogus target, and the name of the section we added (fw4 prints section names as
    # comments on the rules it builds). Neither may appear.
    _markers="AB-BOGUS ${SCEN_S8_UCI}fw"
    _tool=fw4
    _wit=$(scen fw-witness "${_tool}" ${_markers} 2>/dev/null)
    _chk_rc=$(kv "$(printf '%s\n' "${_wit}" | grep '^fw-check ' | head -n 1)" rc)
    # fw3 is what the older images carry; a tool that is not there answers 127, which is how
    # the class knows it cannot witness anything on this machine.
    if [ "${_chk_rc}" = "127" ]; then
        _tool=fw3
        _wit=$(scen fw-witness "${_tool}" ${_markers} 2>/dev/null)
        _chk_rc=$(kv "$(printf '%s\n' "${_wit}" | grep '^fw-check ' | head -n 1)" rc)
    fi
    if [ "${_chk_rc}" = "127" ]; then
        if ! s8_restore_ok /etc/config/firewall "${_bak}/_etc_config_firewall.bak" "${_orig}"; then
            _fail "${_case}" "firewall: /etc/config/firewall is not byte-identical to ${_bak}/_etc_config_firewall.bak after the restore"
        fi
        s8_notjudged "${_cls}" "${_bak}" "this image has neither fw4 nor fw3, so a ruleset cannot be checked without pushing it to the live firewall" "host"
        return 2
    fi

    # The tool's own words. fw4 exits 0 here, so the status is recorded as it is and the
    # warning is what carries the explanation.
    _chk_text=$(printf '%s\n' "${_wit}" | sed -n 's/^fw-check-out=//p' | tr '\n' '|')
    _warn=no
    case "${_chk_text}" in
        *'skipped due to invalid options'* | *'invalid value'* | *'invalid option'*) _warn=yes ;;
    esac
    # fw4 answers `check`; the older fw3 does not (its usage is `{start|stop|flush|restart|
    # print}`), so on such an image there is no warning witness -- only the rendered ruleset.
    _has_check=yes
    [ "${_tool}" = "fw3" ] && _has_check=no
    case "${_chk_text}" in
        *Usage:* | *usage:*) _has_check=no ;;
    esac
    ev "S8 firewall: ${_tool} check rc=${_chk_rc:-none} with the broken rule in the file -- output: ${_chk_text:-none}"

    # Adoption is the rendered ruleset, not the check: `fw4 print` on this line omits a
    # section it skipped and would carry an adopted rule (and its name) if it took one.
    _pr_rc=$(kv "$(printf '%s\n' "${_wit}" | grep '^fw-print ' | head -n 1)" rc)
    _pr_lines=$(kv "$(printf '%s\n' "${_wit}" | grep '^fw-print ' | head -n 1)" lines)
    case "${_pr_lines}" in '' | *[!0-9]*) _pr_lines=0 ;; esac
    _hits=$(printf '%s\n' "${_wit}" | awk -F'hits=' '/^fw-print-marker / { s += $2 } END { print s + 0 }')
    if [ "${_pr_lines}" -eq 0 ] || [ "${_pr_rc}" != "0" ]; then
        # No rendering means adoption could not be witnessed, and a class that cannot see
        # the rule is not allowed to claim it was refused. `fw4 print` exits 0 while it
        # renders (the skipped section only produces a warning), so a non-zero status here
        # is a tool that could not render, not a tool that rejected the file.
        if s8_restore_ok /etc/config/firewall "${_bak}/_etc_config_firewall.bak" "${_orig}"; then
            ev "S8 firewall: /etc/config/firewall restored from ${_bak}"
        else
            _fail "${_case}" "firewall: /etc/config/firewall is not byte-identical to ${_bak}/_etc_config_firewall.bak after the restore"
        fi
        s8_notjudged "${_cls}" "${_bak}" "${_tool} print rendered nothing (rc=${_pr_rc:-none}), so whether the broken rule was adopted could not be witnessed" "host"
        return 2
    fi
    if [ "${_hits}" -gt 0 ]; then
        _fail "${_case}" "firewall: the broken rule is in the rendered ruleset (${_tool} print names ${_markers}), so the tool adopted a rule it should have skipped"
        _s8_outcome="firewall: the broken rule was adopted into the rendered ruleset"
    else
        ev "S8 firewall: the broken rule was not adopted -- ${_tool} print (${_pr_lines} lines) names neither AB-BOGUS nor ${SCEN_S8_UCI}fw"
    fi
    if [ "${_warn}" = yes ]; then
        ev "S8 firewall: ${_tool} warns and skips the rule instead of rejecting the file (check rc=${_chk_rc}; the exit status is not the witness)"
    elif [ "${_has_check}" = yes ]; then
        _finding "S8 firewall: ${_tool} check answered rc=${_chk_rc:-none} without a 'skipped due to invalid options' line, so the rule was dropped without saying why"
    else
        ev "S8 firewall: ${_tool} has no check subcommand, so this image has no warning witness; the rendered ruleset is still what decides adoption"
    fi

    # The restore happens before the "is the machine still whole" verdict is returned: a
    # class that leaves the broken file behind would be a test that damages what it measures.
    _intact=1
    s8_intact "${_cls}" || _intact=0

    # The restore, the rule's absence, and the proof that the restored file still translates.
    _restored=no
    if s8_restore_ok /etc/config/firewall "${_bak}/_etc_config_firewall.bak" "${_orig}"; then
        _restored=yes
        ev "S8 firewall: /etc/config/firewall is byte-identical to ${_bak}/_etc_config_firewall.bak again"
    else
        _fail "${_case}" "firewall: /etc/config/firewall is not byte-identical to ${_bak}/_etc_config_firewall.bak after the restore"
        _s8_outcome="firewall: the restore is not byte-identical to ${_bak}"
    fi
    if [ -n "${_sec}" ] && [ "${_sec}" != none ]; then
        _gone=$(scen exec uci -q get "firewall.${_sec}.dest_port" 2>/dev/null | grep '^cmd=' | head -n 1)
        if [ "$(kv "${_gone}" rc)" = "0" ]; then
            _fail "${_case}" "firewall: the broken rule (${_sec}) is still in the restored configuration"
            _s8_outcome="firewall: the broken rule survived the restore"
        fi
    fi
    if [ "${_has_check}" = yes ]; then
        _chk2=$(scen exec "${_tool}" check 2>/dev/null | grep '^cmd=' | head -n 1)
        if [ "$(kv "${_chk2}" rc)" = "0" ]; then
            ev "S8 firewall: the restored ruleset translates again (${_tool} check rc=0)"
        else
            _fail "${_case}" "firewall: the restored ruleset does not translate (${_tool} check rc=$(kv "${_chk2}" rc): $(printf '%s' "${_chk2}" | sed -n 's/.* out=//p'))"
            _s8_outcome="firewall: the restored ruleset does not translate"
        fi
    else
        _chk2=$(scen exec "${_tool}" print 2>/dev/null | grep '^cmd=' | head -n 1)
        if [ "$(kv "${_chk2}" rc)" = "0" ]; then
            ev "S8 firewall: the restored ruleset renders again (${_tool} print rc=0; this image has no check subcommand)"
        else
            _fail "${_case}" "firewall: the restored ruleset does not render (${_tool} print rc=$(kv "${_chk2}" rc))"
            _s8_outcome="firewall: the restored ruleset does not render"
        fi
    fi
    _rl=$(scen exec /etc/init.d/firewall reload 2>/dev/null | grep '^cmd=' | head -n 1)
    if [ "$(kv "${_rl}" rc)" = "0" ]; then
        ev "S8 firewall: the restored ruleset reloads (rc=0)"
    else
        _fail "${_case}" "firewall: the restored ruleset does not reload (rc=$(kv "${_rl}" rc))"
        _s8_outcome="firewall: the restored ruleset does not reload"
    fi
    s8_record "${_cls}" "${_bak}" "host (cp from the backup, then /etc/init.d/firewall reload)" \
        "not adopted (${_tool} check rc=${_chk_rc:-none} with a warning, the rule absent from ${_tool} print), restored (${_restored})"
    [ "${_intact}" = "1" ] || return 1
    s8_intact "${_cls}" || return 1
    return 0
}

# s8_docker <stamp>: the docker class. A daemon.json that is not JSON. The witness is
# `docker info`, never `pidof dockerd`: procd re-spawns a dead dockerd, so the pid survives a
# daemon that cannot serve a single request (measured on a truncated daemon.json: restart
# rc=0, pidof answers, docker info rc=1, logread says "unexpected end of JSON input"). The
# other half of that timing: dockerd needs three to four seconds before the API answers, so
# `docker info` is retried (SCEN_S8_DOCKER_TRIES, a second apart) -- one call right after the
# restart would read a healthy daemon as broken. What is asserted: the daemon keeps failing
# while the file is broken (or tolerated it, which is a FINDING), the router is unaffected,
# and the backup brings the daemon back with the same image count.
s8_docker() {
    _cls=docker
    _s8_outcome="docker: daemon unavailable on the broken file, restored and running"
    _s8d_outcome="daemon unavailable while the file was broken, restored and running again"
    _bak=$(s8_bak_dir docker "$1")
    _orig="${_tmp}/s8-docker-original"
    _bakfile="${_bak}/$(printf '%s' "${SCEN_S8_DOCKER}" | sed -e 's|^/|_|' -e 's|/|_|g').bak"
    if ! s8_backup "${_cls}" "${_bak}" "${SCEN_S8_DOCKER}"; then
        s8_notjudged "${_cls}" "${_bak}" "${SCEN_S8_DOCKER} is not on this machine: docker is not configured here, so there is no daemon config to break"
        return 2
    fi
    _have=$(scen exec command -v dockerd 2>/dev/null | grep '^cmd=' | head -n 1)
    if [ "$(kv "${_have}" rc)" != "0" ]; then
        s8_notjudged "${_cls}" "${_bak}" "dockerd is not installed on this machine, so a broken daemon.json has nothing to fail"
        return 2
    fi
    if ! s8_collect "${SCEN_S8_DOCKER}" "${_orig}"; then
        s8_notjudged "${_cls}" "${_bak}" "${SCEN_S8_DOCKER} is not readable on this machine"
        return 2
    fi

    # Whether the daemon answers *before* anything is broken. One call, no retries: this is
    # the machine's state, not the few seconds after a restart. A daemon that is already
    # unusable cannot witness this class, and blaming the truncated file for it would be a
    # false arrest.
    _base_raw=$(scen docker-info 1 0 2>/dev/null)
    _base=$(printf '%s\n' "${_base_raw}" | grep '^docker-info attempts=' | head -n 1)
    if [ "$(kv "${_base}" up)" != "yes" ]; then
        s8_notjudged "${_cls}" "${_bak}" "docker does not answer 'docker info' before ${SCEN_S8_DOCKER} is touched (${_base:-no answer}), so a failure after the change could not be attributed to it"
        return 2
    fi
    _imgs=$(kv "${_base}" images)
    ev "S8 docker: daemon healthy before the broken file -- ${_base}"

    _bad=$(scen badcfg docker "${SCEN_S8_DOCKER}" 2>/dev/null | grep '^badcfg=' | head -n 1)
    case "${_bad}" in
        *write_rc=0*) ev "S8 docker: truncated daemon.json written -- ${_bad}" ;;
        *) _fail "${_case}" "docker: the truncated daemon.json could not be written (${_bad:-no answer})" ;;
    esac
    _rs=$(scen exec /etc/init.d/dockerd restart 2>/dev/null | grep '^cmd=' | head -n 1)
    if [ "$(kv "${_rs}" rc)" = "127" ]; then
        # The binary is there but nothing can be told to restart it (no init script): the
        # degradation cannot be produced, so the file goes back and the class says so.
        if ! s8_restore_ok "${SCEN_S8_DOCKER}" "${_bakfile}" "${_orig}"; then
            _fail "${_case}" "docker: ${SCEN_S8_DOCKER} is not byte-identical to the backup after the restore"
        fi
        s8_notjudged "${_cls}" "${_bak}" "there is no /etc/init.d/dockerd on this machine, so the daemon cannot be restarted onto the broken file" "host"
        return 2
    fi

    # The witness. Every attempt has to fail for the daemon to count as unusable; the retries
    # are what keeps a daemon that needs a few seconds to answer from being read as broken.
    _brk_raw=$(scen docker-info "${SCEN_S8_DOCKER_TRIES}" "${SCEN_S8_DOCKER_PAUSE}" 2>/dev/null)
    _brk=$(printf '%s\n' "${_brk_raw}" | grep '^docker-info attempts=' | head -n 1)
    if [ "$(kv "${_brk}" up)" = "yes" ]; then
        # The daemon is answering with a file that is not JSON: either this image's init
        # script does not read it, or the parse error is tolerated. Nothing is broken, so
        # nothing is red -- and the fact is reported, because "the daemon ignored it" is
        # worth knowing.
        _finding "S8 docker: the daemon answered 'docker info' with a truncated daemon.json (restart rc=$(kv "${_rs}" rc); attempts=$(kv "${_brk}" attempts), images=$(kv "${_brk}" images)), so the degradation this class looks for could not be witnessed"
        _s8d_outcome="daemon tolerated the broken file (a FINDING, not a degradation)"
    else
        ev "S8 docker: docker info kept failing on the truncated daemon.json (restart rc=$(kv "${_rs}" rc); $(printf '%s' "${_brk_raw}" | tr '\n' ' ')) -- docker is unavailable for as long as the file is broken, the machine is not"
        _s8d_outcome="daemon unavailable while the file was broken, restored and running again"
    fi

    _intact=1
    s8_intact "${_cls}" || _intact=0

    if s8_restore_ok "${SCEN_S8_DOCKER}" "${_bakfile}" "${_orig}"; then
        ev "S8 docker: ${SCEN_S8_DOCKER} is byte-identical to the backup again"
    else
        _fail "${_case}" "docker: ${SCEN_S8_DOCKER} is not byte-identical to the backup after the restore"
        _s8_outcome="docker: the restore is not byte-identical to ${_bak}"
        _s8d_outcome="the restore is not byte-identical to ${_bak}"
    fi

    # "It came back" means the API answers again *and* the images are still there: a daemon
    # that starts empty answered, but it is not the daemon the machine had. The same retry
    # window applies, because this restart has the same three-to-four-second start-up.
    _rs2=$(scen exec /etc/init.d/dockerd restart 2>/dev/null | grep '^cmd=' | head -n 1)
    _aft_raw=$(scen docker-info "${SCEN_S8_DOCKER_TRIES}" "${SCEN_S8_DOCKER_PAUSE}" 2>/dev/null)
    _aft=$(printf '%s\n' "${_aft_raw}" | grep '^docker-info attempts=' | head -n 1)
    if [ "$(kv "${_aft}" up)" != "yes" ]; then
        _fail "${_case}" "docker: docker info still fails after ${SCEN_S8_DOCKER} was restored from the backup (restart rc=$(kv "${_rs2}" rc); ${_aft:-no answer})"
        _s8_outcome="docker: the daemon did not come back after the restore"
        _s8d_outcome="the daemon did not come back after the restore"
    elif [ -n "${_imgs}" ] && [ "${_imgs}" != "na" ] && [ "$(kv "${_aft}" images)" != "${_imgs}" ]; then
        _fail "${_case}" "docker: the image count changed across the class (before=${_imgs} after=$(kv "${_aft}" images)), so the daemon did not come back to what it was"
        _s8_outcome="docker: the daemon came back with a different image set"
        _s8d_outcome="the daemon came back with a different image set"
    else
        ev "S8 docker: docker info answers again after the backup was restored ($(printf '%s' "${_aft}" | tr '\n' ' '))"
    fi
    s8_record "${_cls}" "${_bak}" "host (cp from the backup, then /etc/init.d/dockerd restart)" "${_s8d_outcome}"
    [ "${_intact}" = "1" ] || return 1
    s8_intact "${_cls}" || return 1
    return 0
}

# s8_apk <stamp>: the package-feed class. A feed list naming a release that is not on the
# mirror, so apk's index refresh has to fail while the machine keeps running. The second apk
# update after the restore is what tells "the 404 was witnessed" apart from "this machine
# cannot reach any feed from here": when both fail, the class says it could not judge instead
# of claiming the 404.
s8_apk() {
    _cls=apk
    _s8_outcome="apk: 404 feed failed, the machine's own feed answers again"
    _bak=$(s8_bak_dir apk "$1")
    _orig="${_tmp}/s8-feeds-original"
    if ! s8_backup "${_cls}" "${_bak}" "${SCEN_S7_FEEDS}"; then
        s8_notjudged "${_cls}" "${_bak}" "${SCEN_S7_FEEDS} could not be backed up, so the machine keeps its own feed list"
        return 2
    fi
    if ! s8_collect "${SCEN_S7_FEEDS}" "${_orig}"; then
        s8_notjudged "${_cls}" "${_bak}" "${SCEN_S7_FEEDS} is not readable on this machine"
        return 2
    fi

    _bad=$(scen badcfg apk "${SCEN_S7_FEEDS}" "${SCEN_S8_BADFEED}" 2>/dev/null | grep '^badcfg=' | head -n 1)
    case "${_bad}" in
        *write_rc=0*) ev "S8 apk: 404 feed list written -- ${_bad}" ;;
        *) _fail "${_case}" "apk: the 404 feed list could not be written (${_bad:-no answer})" ;;
    esac
    # A lock error here would read as "the 404 was witnessed", which is the one thing this
    # class must not get wrong, so the machine is waited for first and a machine that stays
    # locked is reported as not judged.
    if ! need_apk_lock "the 404 feed refresh"; then
        s8_notjudged "${_cls}" "${_bak}" "${CASE_NOTE}" "host (cp from the backup)"
        s8_restore_ok "${SCEN_S7_FEEDS}" "${_bak}/$(printf '%s' "${SCEN_S7_FEEDS}" | sed -e 's|^/|_|' -e 's|/|_|g').bak" "${_orig}" || true
        return 2
    fi
    _upd=$(scen exec apk update 2>/dev/null | grep '^cmd=' | head -n 1)
    _badfeed_failed=no
    if [ "$(kv "${_upd}" rc)" = "0" ]; then
        _finding "S8 apk: apk update answered 0 with a feed list naming a release that does not exist, so the 404 could not be witnessed (a cached index, or a mirror that answers anything)"
    else
        _badfeed_failed=yes
        ev "S8 apk: apk update failed on the 404 feed (rc=$(kv "${_upd}" rc): $(printf '%s' "${_upd}" | sed -n 's/.* out=//p'))"
    fi

    # The machine keeps running, which is the other half of the question: ab-slot status stays
    # readable, boot/esp stay ok, and whatever `packages` says is recorded as a fact.
    _intact=1
    s8_intact "${_cls}" || _intact=0

    _restored=no
    if s8_restore_ok "${SCEN_S7_FEEDS}" "${_bak}/$(printf '%s' "${SCEN_S7_FEEDS}" | sed -e 's|^/|_|' -e 's|/|_|g').bak" "${_orig}"; then
        _restored=yes
        ev "S8 apk: ${SCEN_S7_FEEDS} is byte-identical to ${_bak} again"
    else
        _fail "${_case}" "apk: ${SCEN_S7_FEEDS} is not byte-identical to the backup after the restore"
        _s8_outcome="apk: the restore is not byte-identical to ${_bak}"
    fi
    if ! need_apk_lock "the restored-feed refresh"; then
        s8_notjudged "${_cls}" "${_bak}" "${CASE_NOTE}" "host (cp from the backup)"
        return 2
    fi
    _upd2=$(scen exec apk update 2>/dev/null | grep '^cmd=' | head -n 1)
    if [ "$(kv "${_upd2}" rc)" = "0" ]; then
        ev "S8 apk: the machine's own feeds answer again (apk update rc=0) -- the failure was the 404, not the machine"
        s8_record "${_cls}" "${_bak}" "host (cp from the backup)" "apk update failed on the 404 feed, index refresh works again (${_restored})"
    else
        s8_notjudged "${_cls}" "${_bak}" "apk update fails on the restored feed list too (rc=$(kv "${_upd2}" rc)), so a 404 and an unreachable network cannot be told apart from here" "host"
        return 2
    fi
    [ "${_intact}" = "1" ] || return 1
    if [ "${_badfeed_failed}" = no ]; then
        return 2
    fi
    return 0
}

# run_s8: four broken configurations, one verdict.
# The order is the plan's order and it is deliberate: network first (the only class that goes
# through a real reload), then the two services the machine carries, then the package source.
run_s8() {
    _case=S8
    require_healthy_committed "${_case}" || return 1
    AB_STATUS_LINE=${STATUS_LINE}
    push_helper || { CASE_NOTE="helper could not be pushed"; return 1; }
    probe_machine || { CASE_NOTE="the machine did not answer the helper's probe"; return 1; }
    if [ "$(kv "${PROBE}" data)" != "mounted" ]; then
        CASE_NOTE="/data is not mounted: the backups these four classes roll back from have nowhere to live"
        ev "${CASE_NOTE}"
        return 2
    fi
    if [ "$(kv "${PROBE}" apk)" != "yes" ]; then
        CASE_NOTE="no apk on this image: the package-feed half of the case could not be written or refreshed"
        ev "${CASE_NOTE}"
        return 2
    fi

    _stamp=${SCEN_STAMP}
    scen mkdirs "${SCEN_EVIDENCE}" "${SCEN_BACKUP}" >/dev/null 2>&1
    : >"${_tmp}/s8-classes.tsv"
    CASE_FAILED=0
    _s8_judged=0
    _s8_skipped=0
    _s8_skipped_names=""

    # Four classes, and every one of them runs even when an earlier one went red: the user
    # wants the whole list of what a wrong file did, not the first item of it.
    _s8_broke=""
    _s8_ok_names=""
    _s8_rest=""
    for _s8_cls in network firewall docker apk; do
        # The assertion counter, not CASE_FAILED: CASE_FAILED is a flag that is already 1 after
        # the first red class, so comparing it would credit every later class with the earlier
        # class's failure (and with a clean pass, once it is set).
        _s8_failed_before=${AB_ASSERT_FAILURES}
        case "${_s8_cls}" in
            network) s8_net "${_stamp}" ;;
            firewall) s8_fw "${_stamp}" ;;
            docker) s8_docker "${_stamp}" ;;
            apk) s8_apk "${_stamp}" ;;
        esac
        _s8_rc=$?
        if [ "${AB_ASSERT_FAILURES}" -ne "${_s8_failed_before}" ]; then
            # A class can return 0 having already recorded a failed judgement (a restore that
            # did not land, say): its own outcome word is what names it in the note.
            _s8_broke="${_s8_broke}${_s8_outcome}; "
        elif [ "${_s8_rc}" -eq 0 ]; then
            _s8_judged=$((_s8_judged + 1))
            _s8_ok_names="${_s8_ok_names}${_s8_cls} "
        fi
        # A machine that stopped answering has to say so once. Running the other three
        # classes against it would record "the backup could not be taken" three times, which
        # reads as three broken backups rather than as one unreachable machine.
        if machine_unreachable_seen; then
            case "${_s8_cls}" in
                network) _s8_rest="firewall docker apk" ;;
                firewall) _s8_rest="docker apk" ;;
                docker) _s8_rest="apk" ;;
                *) _s8_rest="" ;;
            esac
            ev "S8: the machine stopped answering after the ${_s8_cls} class; not attempted: ${_s8_rest:-none}"
            break
        fi
    done

    # Two copies, for the same reason S2 keeps two: the machine's /data is where a person
    # looks, next to the backups the rows name, and this directory is what survives a machine
    # that stopped answering -- which is exactly when the record matters most.
    cp "${_tmp}/s8-classes.tsv" "${EVIDENCE_DIR}/scen-badcfg-${_stamp}.tsv" 2>/dev/null || true
    if dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_tmp}/s8-classes.tsv" "${SCEN_EVIDENCE}/badcfg-${_stamp}.tsv" >/dev/null; then
        ev "S8 recovery record: ${SCEN_EVIDENCE}/badcfg-${_stamp}.tsv (host copy: ${EVIDENCE_DIR}/scen-badcfg-${_stamp}.tsv)"
    else
        ev "S8 recovery record could not be written to ${SCEN_EVIDENCE}/badcfg-${_stamp}.tsv; the host copy is ${EVIDENCE_DIR}/scen-badcfg-${_stamp}.tsv"
    fi

    if [ "${CASE_FAILED}" -ne 0 ]; then
        CASE_NOTE="$(printf '%s' "${_s8_broke}" | sed 's/; $//')"
        [ -n "${CASE_NOTE}" ] || CASE_NOTE="a broken configuration was not handled"
        [ -z "${_s8_rest}" ] || CASE_NOTE="${CASE_NOTE}; the machine stopped answering, so ${_s8_rest} was not attempted"
        return 1
    fi
    if [ "${_s8_judged}" -eq 0 ]; then
        CASE_NOTE="none of the four broken configurations could be judged on this machine (${_s8_skipped_names:-nothing to break}); nothing was refused and nothing was restored"
        ev "${CASE_NOTE}"
        return 2
    fi
    # The per-class detail is in the log and in the recovery record; the note says how many
    # of the four were judged and where the way back is, which is what the row is for.
    CASE_NOTE="${_s8_judged}/4 broken configuration(s) refused or degraded with the machine intact ($(printf '%s' "${_s8_ok_names}" | sed 's/ $//')), each backed up under $(s8_bak_dir '<class>' "${_stamp}") and restored byte for byte"
    [ "${_s8_skipped}" -eq 0 ] \
        || CASE_NOTE="${CASE_NOTE}; not judged: $(printf '%s' "${_s8_skipped_names}" | sed 's/ $//')"
    return 0
}

# --------------------------------------------------------------------------- #
# Cases
# --------------------------------------------------------------------------- #

# scen_run_stamp: the UTC instant this run is named after, in the shape the backup
# directories already use (2026-11-16T19-33-22Z). AB_SCEN_STAMP makes it injectable, which
# is how the unit tests run the same case twice inside one UTC day; unset means the clock.
scen_run_stamp() {
    if [ -n "${AB_SCEN_STAMP:-}" ]; then
        printf '%s\n' "${AB_SCEN_STAMP}"
    else
        dev_stamp | tr ':' '-'
    fi
}

# scen_case <case>: 0 PASS, 1 FAIL, 2 GAP; the note and the findings land in the globals.
scen_case() {
    _case=$1
    CASE_NOTE=""
    CASE_FINDINGS=""
    CASE_FAILED=0
    APK_LOCK_NOTE=""
    mkdir -p "${EVIDENCE_DIR}" || { CASE_NOTE="cannot create ${EVIDENCE_DIR}"; return 1; }
    # One stamp per case, to the second: the log name and this case's backup directory names
    # are derived from the same instant, so a re-run later the same day cannot collide with
    # the earlier one (the defect this naming exists to prevent: <date>-<case>.log was
    # truncated by the day's second run while its backups were already time-stamped).
    SCEN_STAMP=$(scen_run_stamp)
    _case_slug=$(printf '%s' "${_case}" | tr 'A-Z' 'a-z')
    AB_EVIDENCE_LOG="${EVIDENCE_DIR}/$(printf '%s' "${SCEN_STAMP}" | tr -d '-')-${_case_slug}.log"
    SCEN_CMD="$0 --case ${_case}"
    export AB_EVIDENCE_LOG SCEN_CMD AB_SCEN_DATA_DIR AB_SCEN_HELPER
    : >"${AB_EVIDENCE_LOG}"
    # <case>.log is a stable alias for the most recent run of the case: same inode where the
    # filesystem allows a hard link, a relative symlink otherwise, and simply absent when
    # neither works. Either way the timestamped name above is untouched and is what the
    # results row names; the alias says "latest", the timestamp says "this run".
    AB_EVIDENCE_LATEST="${EVIDENCE_DIR}/${_case_slug}.log"
    rm -f "${AB_EVIDENCE_LATEST}" 2>/dev/null || true
    ln "${AB_EVIDENCE_LOG}" "${AB_EVIDENCE_LATEST}" 2>/dev/null \
        || ln -s "$(basename "${AB_EVIDENCE_LOG}")" "${AB_EVIDENCE_LATEST}" 2>/dev/null || true
    ev "case=${_case} $(case_label "${_case}")"

    case "${_case}" in
        S1) run_s1 ;;
        S2) run_s2 ;;
        S3) run_jump S3 "${SCEN_LOW}" "${SCEN_HIGH}" ;;
        S4) run_jump S4 "${SCEN_HIGH}" "${SCEN_LOW}" ;;
        S5) run_s5 ;;
        S6) run_s6 ;;
        S7) run_s7 ;;
        S8) run_s8 ;;
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
        S8) printf 'badconfig: network, firewall, docker daemon.json and a 404 package feed, each backed up, judged and restored\n' ;;
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
                printf '%s pkg-install %s expect=installed|unavailable (unavailable is recorded with rc, the first error line and every line apk wrote after it -- `breaks: world[kernel=...]` is what makes a gap self-evident -- never a failure)\n' "${_case}" "${_p}"
            done
            printf '%s pkg-snapshot %s/apk-snapshot-<stamp>.txt expect=count>0 (apk info -v, else apk list --installed)\n' "${_case}" "${SCEN_EVIDENCE}"
            printf '%s pkg-version <every installed package> -> %s/packages.tsv expect=one row per package and per kmod\n' "${_case}" "${SCEN_EVIDENCE}"
            printf '%s probe-baseline <%s> expect=rc recorded for comparison after the jump\n' \
                "${_case}" "$(for _p in ${SCEN_PROBES}; do _scen_probe_cmd "${_p%%:*}" || true; done | tr '\n' ',' | sed 's/,$//')" 
            for _p in ${SCEN_PKGCYCLE}; do
                printf '%s pkg-cycle %s expect=refused when %s is already installed (a package the user has is never removed), else add, run it once, apk info -L, apk del\n' "${_case}" "${_p}" "${_p}"
            done
            printf '%s pkg-cycle assert expect=after_del=no (apk info -e fails), files_left=0, /etc/apk/world line count back to before; an unavailable package is a FINDING, the residue is a FAIL\n' "${_case}"
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
            ab_status_switch_expect "${_case}" "<other>" "${_to}" "1/1"
            printf '%s data sha256 %s expect=0 changed/missing/untracked/entries lines against the pre-jump manifest (each offender is named)\n' "${_case}" "${SCEN_SEED_DIR}"
            printf '%s data tars %s expect=tar -tf exits 0 with members>0\n' "${_case}" "${SCEN_DOCKER_TARS}"
            printf '%s config uci %s + hostname + timezone + net section + firewall rule expect=the values S2 recorded\n' "${_case}" "${SCEN_UCI}"
            printf '%s software apk info -e <every recorded package> expect=present, and every package with files has at least one of them\n' "${_case}"
            printf '%s software exec <curl, htop> expect=the same exit status as the baseline taken in S1\n' "${_case}"
            printf '%s abi kmod vs uname -r expect=match is silent, stale/missing/unknown is a FINDING: naming what to reinstall (never FAIL)\n' "${_case}"
            printf '%s hop-packages assert packages=aligned packages_reason=none expect=PASS; packages=followed is the same metadata after the follow transaction moved the packages onto this base and is accepted too, a machine left limited names the reason the aligner recorded, and unknown means no record was written (this is judged, not reported)\n' "${_case}"
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
            # The plan has to print what the hop is judged on, including the one allowance
            # this case's path makes: this case moved the feed list itself, so the aligner
            # reporting `network` afterwards is this case's own edit coming back, not a defect.
            printf '%s 3/6 hop-packages assert packages=aligned packages_reason=none|network expect=PASS; network is accepted on this case alone because this case moved the feed list, and it is named in the note as the case'"'"'s own edit. limited, unknown and every other token are still judged red\n' "${_case}"
            printf '%s 3/6 snapshot B expect=the same two files on the version now running\n' "${_case}"
            printf '%s 4/6 diff A vs B expect=one row per package (version-changed|disappeared|new|same) and each kmod with the kernel dependency it carries against the running kernel\n' "${_case}"
            printf '%s 5/6 read %s expect=equal to the %s bytes -> FINDING: the package source did not follow the version (never FAIL); equal to the %s bytes -> recorded, no finding\n' \
                "${_case}" "${SCEN_S7_FEEDS}" "${_s7_from}" "${_s7_to}"
            printf '%s 6/6 align the %s feeds, apk update, install %s then a package that was not installed expect=one install that really changed something, else FAIL\n' \
                "${_case}" "${_s7_to}" "${_s7_kmod:-<kmod>}"
            printf '%s 6/6 restore %s from the backup expect=byte-identical to step 1, else FAIL\n' "${_case}" "${SCEN_S7_FEEDS}"
            printf '%s record\n' "${_case}"
            ;;
        S8)
            _s8_bak_root="${SCEN_BACKUP}/badcfg-<class>-<stamp>"
            printf '# case S8 badconfig: four broken configurations, each with a way back\n'
            printf '%s status expect=committed slot with boot=ok esp=ok (else the run aborts with exit 3)\n' "${_case}"
            printf '%s helper push %s -> %s\n' "${_case}" "ab-scen-helper.sh" "${SCEN_HELPER}"
            printf '%s probe expect=data=mounted (the backups live on it) and apk=yes (the feed class rewrites the feed list)\n' "${_case}"
            printf '%s 1/4 network cfg-backup /etc/config/{network,firewall,system} -> %s expect=3 of 3, else nothing is written\n' "${_case}" "${_s8_bak_root}"
            printf '%s 1/4 network badcfg %snet device=%s proto=%s expect=the section commits and the file still parses\n' \
                "${_case}" "${SCEN_S8_UCI}" "${SCEN_S8_BADNET_DEV}" "${SCEN_S8_BADNET_PROTO}"
            printf '%s 1/4 network net-apply expect=a revert watchdog scheduled before the reload, then the reload (the same call S2 makes)\n' "${_case}"
            printf '%s 1/4 network refusal expect=%s was never created (ip link fails) -- ubus answers 0 whatever the sections say, so the device is the witness\n' "${_case}" "${SCEN_S8_BADNET_DEV}"
            printf '%s 1/4 network ssh-liveness expect=ssh answers; on silence: rollback and FAIL (the machine restores itself if the host cannot reach it)\n' "${_case}"
            printf '%s 1/4 network restore expect=/etc/config/network byte-identical to the backup after net-rollback, boot=ok esp=ok still\n' "${_case}"
            printf '%s 2/4 firewall cfg-backup /etc/config/firewall -> %s expect=1 of 1, else nothing is written\n' "${_case}" "${_s8_bak_root}"
            printf '%s 2/4 firewall badcfg %sfw dest_port=not-a-port target=AB-BOGUS expect=commits, the file still parses\n' "${_case}" "${SCEN_S8_UCI}"
            printf '%s 2/4 firewall refusal expect=fw4 check warns ("skipped due to invalid options") and exits 0 -- that rc is recorded as-is, not as a refusal; the rule must be absent from fw4 print (not adopted); a rule that does appear there is a FAIL\n' "${_case}"
            printf '%s 2/4 firewall restore expect=byte-identical, the rule gone, and the restored ruleset passes fw4 check and reloads (that is what "still parseable" means)\n' "${_case}"
            printf '%s 3/4 docker cfg-backup %s -> %s expect=1 of 1; absent means docker is not configured here and the class is a FINDING, not a FAIL\n' "${_case}" "${SCEN_S8_DOCKER}" "${_s8_bak_root}"
            printf '%s 3/4 docker badcfg %s expect=a truncated file; docker info (not pidof) is the witness, retried %s times %ss apart because dockerd needs seconds to answer, and ab-slot status and ssh stay unaffected\n' "${_case}" "${SCEN_S8_DOCKER}" "${SCEN_S8_DOCKER_TRIES}" "${SCEN_S8_DOCKER_PAUSE}"
            printf '%s 3/4 docker restore expect=byte-identical, then docker info rc=0 again with the same image count; a daemon that answered all along is a FINDING\n' "${_case}"
            printf '%s 4/4 apk cfg-backup %s -> %s expect=1 of 1, else nothing is written\n' "${_case}" "${SCEN_S7_FEEDS}" "${_s8_bak_root}"
            printf '%s 4/4 apk badcfg %s expect=a feed list naming a release that does not exist\n' "${_case}" "${SCEN_S8_BADFEED}"
            printf '%s 4/4 apk apk update expect=non-zero on the 404 feed while ab-slot status stays readable, boot=ok esp=ok and the machine keeps running\n' "${_case}"
            printf '%s 4/4 apk restore expect=byte-identical, then apk update rc=0 again -- that second update is what tells the 404 apart from an unreachable network\n' "${_case}"
            printf '%s record expect=%s/badcfg-<stamp>.tsv: one row per class with the backup and who restored it\n' "${_case}" "${SCEN_EVIDENCE}"
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
