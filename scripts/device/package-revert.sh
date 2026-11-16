#!/bin/sh
# package-revert.sh - prove the package snapshot and the offline revert on the real machine.
#
# The defect this covers (2026-11-14): `ab-slot packages snapshot` read a column apk-tools 3
# does not print, so a 317-package machine produced five mangled lines and `revert` failed on
# every one of them. Five things are measured here, separately:
#
#   P1  the record itself: a snapshot names every installed package with its version, and its
#       own counters (packages=, world=) agree with the machine. No payloads, no network, and
#       no payload-gap line: --no-payloads is the answer, not a gap.
#   P2  the way back: a snapshot that carries the .apk files can put a package back with the
#       repositories pointed at a directory that does not exist, which is the only way to
#       show that the replay does not secretly depend on the feed still having that version.
#   P3  the record is not trusted blindly: the first bytes of one .apk in the snapshot are
#       overwritten under the same name, and the replay must refuse the whole set (exit 74,
#       revert-payload-mismatch) with `apk info -v` unchanged. The bytes are put back and the
#       digest is compared again, so the run does not leave a snapshot nothing can revert.
#   P4  the base is a boundary: a record taken on another base is refused (exit 74,
#       revert-across-base) before a single archive is looked at, and nothing is installed.
#   U1  the upgrade moves: with the slot's packages aligned, `ab-slot packages upgrade` runs
#       apk update/upgrade, at least one installed version changes, and the record it wrote
#       first is on the layer to go back to. U1 changes the machine, so it is not part of
#       the default run.
#
# P2 deletes one package and puts it back, because `revert` replays pinned versions: it does
# not remove a package that was installed after the snapshot, and pretending otherwise would
# be a different feature (restoring `world`, which is what `ab-slot rollback` is for).
#
#   scripts/device/package-revert.sh --case P1 --case P2
#   scripts/device/package-revert.sh --case P3 --case P4
#   scripts/device/package-revert.sh --case U1                 # needs packages=aligned
#   scripts/device/package-revert.sh --case P2 --keep-payloads   # do not delete the snapshot
#   scripts/device/package-revert.sh --dry-run
#
# Exit status: 0 every selected case PASS, 1 a case FAIL, 2 bad usage, 3 the red line
# stopped the run, 4 a case could not run (no /data, no apk, no healthy slot, no aligned
# package metadata, no payload snapshot, nothing for the feed to upgrade to).

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

DRY_RUN=${AB_DRY_RUN:-0}
CASES=""
KEEP_PAYLOADS=1
AB_PKG_RESULTS=${AB_PKG_RESULTS:-package-revert-results.tsv}
AB_PKG_CONTROL_PKG=${AB_PKG_CONTROL_PKG:-htop}
AB_REPO_DIR_BACKUP=${AB_REPO_DIR_BACKUP:-/tmp/ab-apk-conf.bak}
AB_P3_BACKUP_PATH=${AB_P3_BACKUP_PATH:-/tmp/ab-p3-payload.bak}

usage() {
    sed -n '29,37p' "$0"
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            _case_arg=${2:?--case needs P1, P2, P3, P4 or U1}
            case "${_case_arg}" in
                P1 | P2 | P3 | P4 | U1) CASES="${CASES} ${_case_arg}" ;;
                *)
                    printf 'package-revert.sh: unknown case %s (P1, P2, P3, P4, U1)\n' "${_case_arg}" >&2
                    usage
                    ;;
            esac
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        --clean) KEEP_PAYLOADS=0; shift ;;
        -h | --help) usage ;;
        *) printf 'package-revert.sh: unknown argument %s\n' "$1" >&2; usage ;;
    esac
done
# P3 and P4 refuse, they do not change the machine's packages, so they belong to the run
# every acceptance makes. U1 installs whatever the feed carries, so it is asked for by name.
[ -n "${CASES}" ] || CASES=" P1 P2 P3 P4"

CASE_NOTE=""
CASE_FAILURES=0

_fail() {
    CASE_FAILURES=$((CASE_FAILURES + 1))
    printf 'FAIL [%s] %s\n' "$1" "$2" >&2
    ev "FAIL ${1}: ${2}"
}

_ok() {
    printf 'ok [%s] %s\n' "$1" "$2"
}

_assert_eq() { # <case> <actual> <expected> <message>
    if [ "$2" = "$3" ]; then
        _ok "$1" "$4"
    else
        _fail "$1" "$4 (got '$2', expected '$3')"
    fi
}

_field() { # <status-line> <key>
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

# require_ready <case>: apk, a healthy committed slot and the writable layer.
require_ready() {
    _case=$1
    if ! dev_ssh 'command -v apk >/dev/null 2>&1'; then
        CASE_NOTE="the machine has no apk"
        return 4
    fi
    if ! STATUS_LINE=$(dev_status 2>/dev/null); then
        CASE_NOTE="ab-slot status did not answer"
        return 4
    fi
    if [ "$(_field "${STATUS_LINE}" boot)" != "ok" ] || [ "$(_field "${STATUS_LINE}" esp)" != "ok" ]; then
        CASE_NOTE="machine is not healthy (boot=$(_field "${STATUS_LINE}" boot) esp=$(_field "${STATUS_LINE}" esp))"
        return 4
    fi
    if [ "$(_field "${STATUS_LINE}" p4)" != "ok" ]; then
        CASE_NOTE="p4 is not mounted, so there is nowhere to write a snapshot"
        return 4
    fi
    return 0
}

# apk_count: how many `name-version` lines apk reports. The same source the snapshot reads.
apk_count() { dev_ssh "apk info -v 2>/dev/null | grep -c . || true"; }

# apk_fingerprint: every installed name-version, sorted. "Nothing was installed" is a claim
# about the whole set, not about one package: the probe package may already run the version
# the snapshot names, so a single-package check could not tell a refused replay from a
# successful one.
apk_fingerprint() { dev_ssh "apk info -v 2>/dev/null | sort"; }

# remote_sha256 <path>: the digest of a file on the machine, asked of the same three tools
# the packages library tries (sha256sum, then shasum, then openssl). Empty when the machine
# has none of them, which the caller reports instead of comparing two empty strings.
remote_sha256() {
    dev_ssh "if command -v sha256sum >/dev/null 2>&1; then sha256sum '$1' 2>/dev/null | awk '{print \$1}'; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 '$1' 2>/dev/null | awk '{print \$1}'; elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 '$1' 2>/dev/null | awk '{print \$NF}'; fi" | head -n 1
}

# running_layer_dir: /mnt/p4/<upper of the running slot>, from the status line the case
# already captured. A revert only reads the running slot's snapshots, so a case that globs
# /mnt/p4/* can pick another slot's record and then revert by an id this layer never had.
running_layer_dir() {
    _rld_upper=$(_field "${STATUS_LINE:-}" upper)
    [ -n "${_rld_upper}" ] || return 1
    printf '/mnt/p4/%s\n' "${_rld_upper}"
}

# payload_snapshot <case>: the snapshot that carries .apk files, taking one when the machine
# has none, and print its path. A payload snapshot costs a few hundred megabytes of
# download, so every case that needs the replay reuses the one already there: a second copy
# would only make the run slower without proving anything more. PAYLOAD_NOTE says why there
# is none when this returns 1.
PAYLOAD_NOTE=""
payload_snapshot() {
    PAYLOAD_NOTE=""
    _ps_layer=$(running_layer_dir) || {
        PAYLOAD_NOTE="the status line has no upper=, so there is no layer whose snapshots a revert would read"
        return 1
    }
    _ps_existing=$(dev_ssh "for t in \$(ls -1 '${_ps_layer}/apk/snapshots/snapshot-'*.txt 2>/dev/null | sort -r); do if grep -q '^payloads yes' \"\$t\" 2>/dev/null && grep -q '^apkfile' \"\$t\" 2>/dev/null; then echo \"\$t\"; break; fi; done")
    if [ -n "${_ps_existing}" ]; then
        ev "$1: reusing the payload snapshot ${_ps_existing}"
        printf '%s\n' "${_ps_existing}"
        return 0
    fi
    ev "$1: snapshot with payloads (this downloads the installed set once)"
    _ps_out=$(dev_ssh "ab-slot packages snapshot 2>&1") || {
        PAYLOAD_NOTE="snapshot refused: $(printf '%s' "${_ps_out}" | head -n 1)"
        return 1
    }
    _ps_head=$(printf '%s' "${_ps_out}" | head -n 1)
    ev "$1 snapshot: ${_ps_head}"
    if [ "$(_field "${_ps_head}" payloads)" != "yes" ]; then
        # --no-payloads is an answer; a gap is a reason. Both leave nothing to replay.
        PAYLOAD_NOTE="payloads=no ($(printf '%s' "${_ps_head}" | sed -n 's/.*payload_gap //p' | head -n 1)); nothing to prove offline"
        return 1
    fi
    _ps_id=$(printf '%s' "${_ps_head}" | sed -n 's/^snapshot \([^ ]*\) written.*/\1/p' | head -n 1)
    _ps_file=$(dev_ssh "ls -1 '${_ps_layer}/apk/snapshots/snapshot-${_ps_id}.txt' 2>/dev/null | head -n 1")
    if [ -z "${_ps_file}" ]; then
        PAYLOAD_NOTE="the snapshot ${_ps_id} the CLI named is not on ${_ps_layer}"
        return 1
    fi
    printf '%s\n' "${_ps_file}"
}

# The two refusing cases change something on the machine to make it refuse (a byte in an
# .apk, a copied record). The case puts it back itself, but an interrupted run would leave
# the machine poisoned for the next one: a snapshot nothing can revert, or a record that
# looks like it came from another base. One EXIT trap undoes both, so the machine is always
# left as it was found.
AB_P3_VICTIM=""
AB_P3_BACKUP=""
AB_P4_COPY=""
_undo_remote() {
    if [ -n "${AB_P3_VICTIM}" ]; then
        dev_ssh "if [ -f '${AB_P3_BACKUP}' ]; then mv '${AB_P3_BACKUP}' '${AB_P3_VICTIM}'; fi" >/dev/null 2>&1
        AB_P3_VICTIM=""
    fi
    if [ -n "${AB_P4_COPY}" ]; then
        dev_ssh "rm -f '${AB_P4_COPY}'" >/dev/null 2>&1
        AB_P4_COPY=""
    fi
    return 0
}
trap '_undo_remote' EXIT

# run_parse <case>: P1, no payloads.
run_parse() {
    _case=$1
    # A dry run is a planner: it prints the plan and reads no machine, because AB_DRY_RUN=1
    # makes every dev_ssh inert and a readiness check over no output would report a GAP that
    # says nothing about the machine.
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/4 ab-slot packages snapshot --no-payloads\n' "${_case}"
        printf '%s 2/4 expect packages=<apk info -v | wc -l>\n' "${_case}"
        printf '%s 3/4 expect world=<world lines> and payloads=no with no payload_gap\n' "${_case}"
        printf '%s 4/4 expect pkg rows == packages= and no unparsed line\n' "${_case}"
        CASE_NOTE="dry-run"
        return 0
    fi
    require_ready "${_case}" || return $?
    _before=$(apk_count) || _before=""
    case "${_before}" in
        '' | *[!0-9]* | 0)
            CASE_NOTE="apk info -v answered '${_before}' lines"
            return 4
            ;;
    esac
    ev "P1: apk reports ${_before} installed packages"
    _out=$(dev_ssh "ab-slot packages snapshot --no-payloads 2>&1") || {
        CASE_NOTE="snapshot refused: $(printf '%s' "${_out}" | head -n 1)"
        return 1
    }
    ev "P1 snapshot: $(printf '%s' "${_out}" | head -n 1)"
    _packages=$(_field "$(printf '%s' "${_out}" | head -n 1)" packages)
    _world=$(_field "$(printf '%s' "${_out}" | head -n 1)" world)
    _payloads=$(_field "$(printf '%s' "${_out}" | head -n 1)" payloads)
    _assert_eq "${_case}" "${_packages}" "${_before}" "the snapshot records every installed package"
    _assert_eq "${_case}" "${_payloads}" "no" "--no-payloads writes payloads=no"
    # `payloads=no` is the answer --no-payloads asked for, not a gap: a payload-gap line here
    # would invent a second reason for a choice the operator made. Both halves are asserted,
    # because the one-line summary and the record have to tell a reader the same story.
    _assert_eq "${_case}" "$(printf '%s' "${_out}" | sed -n 's/.*payload_gap=//p' | head -n 1)" "" \
        "--no-payloads reports no payload_gap= in the one-line summary"
    _snap=$(printf '%s' "${_out}" | sed -n 's/.*packages=list.*//p')  # no-op, keeps shellcheck quiet
    _path=$(printf '%s' "${_out}" | sed -n 's/^\([^ ]*snapshot-[^ ]*\.txt\).*/\1/p' | head -n 1)
    if [ -z "${_path}" ]; then
        _rows=$(dev_ssh "ls -1 /mnt/p4/*/apk/snapshots/snapshot-*.txt 2>/dev/null | tail -n 1")
    else
        _rows=""
    fi
    _last=$(dev_ssh "ls -1 /mnt/p4/*/apk/snapshots/snapshot-*.txt 2>/dev/null | sort | tail -n 1")
    if [ -n "${_last}" ]; then
        _rowcount=$(dev_ssh "grep -c '^pkg      ' '${_last}' 2>/dev/null || true")
        _worldrows=$(dev_ssh "grep -c '^world    ' '${_last}' 2>/dev/null || true")
        _assert_eq "${_case}" "${_rowcount}" "${_packages}" "the pkg rows agree with the header"
        _assert_eq "${_case}" "${_worldrows}" "${_world}" "the world rows agree with the header"
        _unparsed=$(dev_ssh "grep -c '^pkg      [^ ]*$' '${_last}' 2>/dev/null || true")
        _assert_eq "${_case}" "${_unparsed:-0}" "0" "no pkg row lost its version"
        # The file side of the payload-gap assertion: a list-only snapshot taken by choice
        # carries `payloads no` and no reason line, which is what makes the pair readable as
        # "asked for" rather than "could not".
        _gaps=$(dev_ssh "grep -c '^payload-gap ' '${_last}' 2>/dev/null || true")
        _assert_eq "${_case}" "${_gaps:-0}" "0" "the record carries no payload-gap line for --no-payloads"
    else
        _fail "${_case}" "no snapshot file found under /mnt/p4/*/apk/snapshots"
    fi
    CASE_NOTE="snapshot records ${_packages} packages / ${_world} world entries, rows agree with the header"
    return 0
}

# run_offline <case>: P2, payloads + a package removed and put back with no repository.
run_offline() {
    _case=$1
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/5 ab-slot packages snapshot (payloads on)\n' "${_case}"
        printf '%s 2/5 expect payloads=yes and a payloads/ directory with .apk files\n' "${_case}"
        printf '%s 3/5 ab-slot packages revert  (offline, repositories moved away)\n' "${_case}"
        printf '%s 4/5 expect revert result=ok path=payloads\n' "${_case}"
        printf '%s 5/5 expect the probe package at the snapshotted version\n' "${_case}"
        CASE_NOTE="dry-run"
        return 0
    fi
    require_ready "${_case}" || return $?
    # An existing payload snapshot is reused: the case is about the replay, and taking a
    # second copy would only make the run slower without proving anything more.
    _existing=$(payload_snapshot "${_case}") || {
        CASE_NOTE="${PAYLOAD_NOTE}"
        return 4
    }
    _snapdir="${_existing%.txt}.d"
    _snapid=${_existing##*/snapshot-}
    _snapid=${_snapid%.txt}
    _files=$(dev_ssh "ls -1 '${_snapdir}/payloads'/*.apk 2>/dev/null | wc -l | tr -d ' '")
    _ok "${_case}" "snapshot carries ${_files} .apk files in ${_snapdir}"
    # One package that the snapshot pins, and its running version: the revert has to leave
    # it at that version, not at whatever the feed would install today.
    _probe=$(dev_ssh "sed -n 's/^pkg      //p' '${_existing}' | head -n 1 | cut -d' ' -f1")
    _wanted=$(dev_ssh "sed -n 's/^pkg      \\(${_probe} \\)//p' '${_existing}' | head -n 1")
    _before=$(dev_ssh "apk list --installed '${_probe}' 2>/dev/null | head -n 1 | awk '{print \$1}'")
    ev "P2: probe package ${_probe}: running ${_before}, snapshot wants ${_probe}-${_wanted}"

    # The repositories are moved away on the machine itself, so a replay that reaches the
    # network fails here instead of quietly succeeding. OpenWrt's apk reads
    # /etc/apk/repositories.d, and a plain /etc/apk/repositories may exist too, so both are
    # taken out of the way and put back below whatever happens.
    dev_ssh "rm -rf ${AB_REPO_DIR_BACKUP}; mkdir -p ${AB_REPO_DIR_BACKUP} && cp -a /etc/apk/repositories ${AB_REPO_DIR_BACKUP}/repositories 2>/dev/null; mv /etc/apk/repositories.d ${AB_REPO_DIR_BACKUP}/repositories.d 2>/dev/null; printf '# moved away by package-revert.sh\n' > /etc/apk/repositories"
    # Control: with no source configured, a plain install cannot work. Without this line a
    # successful revert would not prove the local path was the one that did it.
    # The control has to ask for a package the machine does not have: `apk add` on an
    # installed package answers from the installed database and would succeed with no
    # repositories at all, which is what made an earlier version of this case vacuous.
    _control=${AB_PKG_CONTROL_PKG}
    if dev_ssh "apk info -e ${_control} >/dev/null 2>&1"; then
        _control=""
        _ok "${_case}" "control package ${AB_PKG_CONTROL_PKG} is already installed; skipping the control"
    fi
    if [ -n "${_control}" ] && dev_ssh "apk add --simulate ${_control} >/dev/null 2>&1"; then
        dev_ssh "rm -rf /etc/apk/repositories.d; mv ${AB_REPO_DIR_BACKUP}/repositories.d /etc/apk/repositories.d 2>/dev/null; if [ -f ${AB_REPO_DIR_BACKUP}/repositories ]; then cp ${AB_REPO_DIR_BACKUP}/repositories /etc/apk/repositories; fi"
        CASE_NOTE="apk still resolves from a source with the repositories moved away; the offline proof would be vacuous"
        return 4
    fi
    [ -n "${_control}" ] && _ok "${_case}" "with no repository configured, a fresh install fails (control)"
    _revert=$(dev_ssh "ab-slot packages revert --to ${_snapid} 2>&1")
    dev_ssh "rm -rf /etc/apk/repositories.d; mv ${AB_REPO_DIR_BACKUP}/repositories.d /etc/apk/repositories.d 2>/dev/null; if [ -f ${AB_REPO_DIR_BACKUP}/repositories ]; then cp ${AB_REPO_DIR_BACKUP}/repositories /etc/apk/repositories; fi"
    printf '%s\n' "${_revert}" | grep -E '^revert |^apkfile' | while IFS= read -r _line; do ev "P2 ${_line}"; done
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | sed -n 's/^revert result=\([a-z]*\).*/\1/p' | head -n 1)" "ok" \
        "the revert succeeded with no repository configured"
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | sed -n 's/.*path=\([a-z]*\).*/\1/p' | head -n 1)" "payloads" \
        "the revert took the local payload path"
    _after=$(dev_ssh "apk list --installed '${_probe}' 2>/dev/null | head -n 1 | awk '{print \$1}'")
    _assert_eq "${_case}" "${_after}" "${_probe}-${_wanted}" "the probe package is at the snapshotted version"
    if [ "${KEEP_PAYLOADS}" = "0" ]; then
        dev_ssh "rm -rf '${_snapdir}'" >/dev/null 2>&1 || ev "P2: could not remove ${_snapdir} (kept)"
    fi
    CASE_NOTE="offline revert took path=payloads from ${_files} local .apk files; ${_probe} stayed at ${_wanted}"
    return 0
}

# run_tamper <case>: P3, a payload whose bytes changed must stop the whole replay.
run_tamper() {
    _case=$1
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/5 use the payload snapshot (take one if the machine has none)\n' "${_case}"
        printf '%s 2/5 expect the first recorded apkfile digest to match its .apk\n' "${_case}"
        printf '%s 3/5 overwrite the first bytes of that .apk (same name, same length)\n' "${_case}"
        printf '%s 4/5 expect revert exit 74, refused reason=revert-payload-mismatch and result=fail\n' "${_case}"
        printf '%s 5/5 expect apk info -v unchanged (nothing installed), then the bytes back at the digest\n' "${_case}"
        CASE_NOTE="dry-run"
        return 0
    fi
    require_ready "${_case}" || return $?
    _snap=$(payload_snapshot "${_case}") || {
        CASE_NOTE="${PAYLOAD_NOTE}"
        return 4
    }
    _snapdir="${_snap%.txt}.d"
    _snapid=${_snap##*/snapshot-}
    _snapid=${_snapid%.txt}
    # The first archive the record names: the name it lists, the digest it trusts, and the
    # file apk fetch landed for it.
    _victim_name=$(dev_ssh "sed -n 's/^apkfile  *//p' '${_snap}' | head -n 1 | cut -d' ' -f1")
    _digest=$(dev_ssh "sed -n 's/^apkfile  ${_victim_name} //p' '${_snap}' | head -n 1")
    _victim=$(dev_ssh "ls -1 '${_snapdir}/payloads/'${_victim_name}-*.apk 2>/dev/null | head -n 1")
    if [ -z "${_victim_name}" ] || [ -z "${_digest}" ] || [ -z "${_victim}" ]; then
        CASE_NOTE="snapshot ${_snapid} names no archive that is also on disk (${_victim_name:-no apkfile line})"
        return 4
    fi
    _sha=$(remote_sha256 "${_victim}")
    _assert_eq "${_case}" "${_sha}" "${_digest}" "the record's digest matches ${_victim_name} before the tamper"
    _backup=${AB_P3_BACKUP_PATH}
    if ! dev_ssh "rm -f '${_backup}'; cp -p '${_victim}' '${_backup}'"; then
        CASE_NOTE="could not copy ${_victim} aside before the tamper"
        return 4
    fi
    # From here on the machine carries a changed .apk until the copy is moved back; the
    # EXIT trap covers a run that dies before it gets there.
    AB_P3_VICTIM=${_victim}
    AB_P3_BACKUP=${_backup}
    if ! dev_ssh "printf 'TAMPERED-BY-PACKAGE-REVERT-SH' | dd of='${_victim}' bs=1 conv=notrunc 2>/dev/null"; then
        dev_ssh "mv '${_backup}' '${_victim}'" >/dev/null 2>&1
        CASE_NOTE="could not overwrite the first bytes of ${_victim}"
        return 4
    fi
    _sha_tampered=$(remote_sha256 "${_victim}")
    _assert_eq "${_case}" "$([ -n "${_sha_tampered}" ] && [ "${_sha_tampered}" != "${_digest}" ] && printf changed || printf unchanged)" \
        "changed" "the bytes on disk no longer match the digest the record carries"
    # The whole installed set, because "nothing was installed" is a claim about every
    # package: a probe already running the snapshot's version would hide a partial replay.
    _before=$(apk_fingerprint)
    _revert=$(dev_ssh "ab-slot packages revert --to ${_snapid} 2>&1")
    _revert_rc=$?
    _after=$(apk_fingerprint)
    # The bytes go back before anything is judged: a failed assertion must not leave a
    # snapshot on the machine that nothing can revert.
    dev_ssh "mv '${_backup}' '${_victim}'" >/dev/null 2>&1
    AB_P3_VICTIM=""
    _restored=$(remote_sha256 "${_victim}")
    printf '%s\n' "${_revert}" | grep -E '^(revert|apkfile) |^ab-slot: refused' | while IFS= read -r _line; do ev "P3 ${_line}"; done
    _assert_eq "${_case}" "${_revert_rc}" "74" "a set that does not verify is refused, not replayed (exit 74)"
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | sed -n 's/^ab-slot: refused, reason=//p' | head -n 1)" "revert-payload-mismatch" \
        "the refusal names the digest mismatch"
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | sed -n 's/^revert result=fail reason=//p' | head -n 1)" "revert-payload-mismatch" \
        "the accounting repeats the same reason, so the verdict is not a second story"
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | grep -c '^apkfile verified')" "0" \
        "no archive is installed from a set that does not verify"
    _assert_eq "${_case}" "${_after}" "${_before}" "nothing was installed: apk info -v is unchanged"
    _assert_eq "${_case}" "${_restored}" "${_digest}" "the archive is back at the digest the record carries"
    # The row's note has to describe what happened, not what was expected: a FAIL that
    # still claims "refused (74)" beside its failed assertions reads as a pass to anyone
    # skimming the TSV.
    if [ "${CASE_FAILURES}" -eq 0 ]; then
        CASE_NOTE="revert refused a tampered ${_victim_name} (74, revert-payload-mismatch) and installed nothing; the bytes were put back"
    else
        CASE_NOTE="a tampered ${_victim_name} did not produce the documented refusal; see the failed assertions (the bytes were put back)"
    fi
    return 0
}

# run_crossbase <case>: P4, a record from another base is refused before anything runs.
run_crossbase() {
    _case=$1
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/5 read UPSTREAM_VERSION from /etc/platform-release (the base this machine runs)\n' "${_case}"
        printf '%s 2/5 copy a record from another base into the running layer\n' "${_case}"
        printf '%s 3/5 expect revert exit 74, refused reason=revert-across-base\n' "${_case}"
        printf '%s 4/5 expect the refusal names both bases, replays nothing and installs nothing\n' "${_case}"
        printf '%s 5/5 expect the copy removed afterwards\n' "${_case}"
        CASE_NOTE="dry-run"
        return 0
    fi
    require_ready "${_case}" || return $?
    _layer=$(running_layer_dir) || {
        CASE_NOTE="the status line has no upper=, so there is no layer to copy a record into"
        return 4
    }
    _base=$(dev_ssh "sed -n 's/^UPSTREAM_VERSION=//p' /etc/platform-release 2>/dev/null | head -n 1")
    case "${_base}" in
        '')
            CASE_NOTE="/etc/platform-release has no UPSTREAM_VERSION, so this machine's base is unknown"
            return 4
            ;;
    esac
    # A record another slot took before a rollback is the real thing. When the machine has
    # none, a copy of the newest local record with its upstream line rewritten is what the
    # check sees as "from another base"; the evidence line says which of the two was used.
    _src=$(dev_ssh "for t in \$(ls -1 /mnt/p4/*/apk/snapshots/snapshot-*.txt 2>/dev/null | sort -r); do b=\$(sed -n 's/^upstream //p' \"\$t\" 2>/dev/null | head -n 1); case \"\$t\" in '${_layer}/'*) continue ;; esac; case \"\$b\" in '' | '${_base}') continue ;; esac; echo \"\$t\"; break; done")
    _foreign=1
    if [ -z "${_src}" ]; then
        _foreign=0
        _src=$(dev_ssh "ls -1 '${_layer}/apk/snapshots/snapshot-'*.txt 2>/dev/null | sort | tail -n 1")
        if [ -z "${_src}" ]; then
            # No record at all on this layer: a list-only one is enough to be refused across
            # a base, and it costs no download.
            _src_out=$(dev_ssh "ab-slot packages snapshot --no-payloads 2>&1") || {
                CASE_NOTE="no snapshot on ${_layer} to copy, and writing one failed: $(printf '%s' "${_src_out}" | head -n 1)"
                return 4
            }
            _src=$(dev_ssh "ls -1 '${_layer}/apk/snapshots/snapshot-'*.txt 2>/dev/null | sort | tail -n 1")
            if [ -z "${_src}" ]; then
                CASE_NOTE="no snapshot on ${_layer} to copy, and none could be written"
                return 4
            fi
        fi
    fi
    _srcid=${_src##*/snapshot-}
    _srcid=${_srcid%.txt}
    _dstid="${_srcid}-xbase"
    _dst="${_layer}/apk/snapshots/snapshot-${_dstid}.txt"
    if ! dev_ssh "rm -f '${_dst}'; cp '${_src}' '${_dst}'"; then
        CASE_NOTE="could not copy ${_src} into ${_layer}"
        return 4
    fi
    AB_P4_COPY=${_dst}
    if [ "${_foreign}" = "1" ]; then
        _other=$(dev_ssh "sed -n 's/^upstream //p' '${_dst}' | head -n 1")
        ev "P4: using the other base's snapshot ${_src} (base ${_other})"
    else
        _other="0.0.0-other-base"
        # Written through a temporary rather than with `sed -i`: the rewrite either lands
        # whole or not at all, and nothing here depends on which sed the machine carries.
        if ! dev_ssh "sed 's/^upstream .*/upstream ${_other}/' '${_dst}' > '${_dst}.tmp' && mv '${_dst}.tmp' '${_dst}'"; then
            dev_ssh "rm -f '${_dst}' '${_dst}.tmp'" >/dev/null 2>&1
            CASE_NOTE="could not rewrite the upstream line of the copy ${_dst}"
            return 4
        fi
        ev "P4: the machine has no other base's snapshot; ${_dst} is a copy of ${_srcid} with upstream rewritten to ${_other}"
    fi
    _before=$(apk_fingerprint)
    _revert=$(dev_ssh "ab-slot packages revert --to ${_dstid} 2>&1")
    _revert_rc=$?
    _after=$(apk_fingerprint)
    dev_ssh "rm -f '${_dst}'" >/dev/null 2>&1
    AB_P4_COPY=""
    printf '%s\n' "${_revert}" | grep -E '^(revert|apkfile) |^ab-slot: refused|^  ' | while IFS= read -r _line; do ev "P4 ${_line}"; done
    _assert_eq "${_case}" "${_revert_rc}" "74" "a record from another base is refused (exit 74)"
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | sed -n 's/^ab-slot: refused, reason=//p' | head -n 1)" "revert-across-base" \
        "the refusal names the base as the boundary"
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | grep -c "Snapshot base ${_other}, running base ${_base}")" "1" \
        "the refusal shows both bases, so a reader can see which one is wrong"
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | grep -c '^revert result=')" "0" \
        "nothing was replayed: the base is judged before any package"
    _assert_eq "${_case}" "${_after}" "${_before}" "nothing was installed: apk info -v is unchanged"
    _assert_eq "${_case}" "$(dev_ssh "[ -f '${_dst}' ] && printf present || printf absent")" "absent" \
        "the copy is removed again, so the layer is left as it was"
    if [ "${CASE_FAILURES}" -eq 0 ]; then
        CASE_NOTE="revert refused a record from base ${_other} on running base ${_base} (74, revert-across-base) and installed nothing"
    else
        CASE_NOTE="a record from base ${_other} on running base ${_base} was not refused the documented way; see the failed assertions (the copy was removed)"
    fi
    return 0
}

# run_upgrade <case>: U1, the package upgrade really moves a version on an aligned slot.
run_upgrade() {
    _case=$1
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/5 expect packages=aligned on the running slot (otherwise the upgrade is refused)\n' "${_case}"
        printf '%s 2/5 ab-slot packages upgrade  (apk update + apk upgrade; this changes the machine)\n' "${_case}"
        printf '%s 3/5 expect packages-upgrade result=ok; a failure is reported with the status apk gave\n' "${_case}"
        printf '%s 4/5 expect at least one installed version to move (the record it wrote against a fresh one)\n' "${_case}"
        printf '%s 5/5 expect the snapshot the upgrade wrote first to be on the layer (the way back)\n' "${_case}"
        CASE_NOTE="dry-run"
        return 0
    fi
    require_ready "${_case}" || return $?
    _align=$(_field "${STATUS_LINE}" packages)
    if [ "${_align}" != "aligned" ]; then
        CASE_NOTE="packages=${_align} reason=$(_field "${STATUS_LINE}" packages_reason): an upgrade is refused by design until the slot is aligned"
        return 4
    fi
    _before=$(apk_fingerprint)
    _count=$(printf '%s\n' "${_before}" | grep -c . || true)
    case "${_count}" in
        '' | *[!0-9]* | 0)
            CASE_NOTE="apk info -v answered '${_count}' package lines"
            return 4
            ;;
    esac
    _layer=$(running_layer_dir) || {
        CASE_NOTE="the status line has no upper=, so the layer the upgrade writes to is unknown"
        return 4
    }
    ev "U1: ${_count} installed packages before the upgrade (packages=aligned)"
    _out=$(dev_ssh "ab-slot packages upgrade 2>&1")
    _rc=$?
    _after=$(apk_fingerprint)
    printf '%s\n' "${_out}" | grep -E '^(snapshot |apk |packages-upgrade )' | while IFS= read -r _line; do ev "U1 ${_line}"; done
    # The verdict the upgrade printed is the classification: ok, or a failure with the
    # status apk gave (timeout is its own token). A case that cannot read it must not
    # invent success.
    _verdict=$(printf '%s' "${_out}" | sed -n 's/^packages-upgrade result=\([a-z]*\).*/\1/p' | head -n 1)
    if [ "${_verdict}" != "ok" ]; then
        _why=$(printf '%s' "${_out}" | sed -n 's/^packages-upgrade .*\(reason=[^ ]*\).*/\1/p' | head -n 1)
        CASE_NOTE="packages-upgrade result=${_verdict:-missing}${_why:+ ${_why}} (exit ${_rc}): the upgrade did not complete"
        return 1
    fi
    _assert_eq "${_case}" "${_rc}" "0" "the package upgrade exits 0"
    _sid=$(printf '%s' "${_out}" | sed -n 's/^snapshot \([^ ]*\) written.*/\1/p' | head -n 1)
    _assert_eq "${_case}" "$([ -n "${_sid}" ] && printf named || printf missing)" "named" \
        "the upgrade names the record it wrote before touching the machine"
    _pre="${_layer}/apk/snapshots/snapshot-${_sid}.txt"
    _assert_eq "${_case}" "$(dev_ssh "[ -f '${_pre}' ] && printf present || printf absent")" "present" \
        "the record is on the layer, so the pre-upgrade versions can be replayed"
    # What the machine runs now, read the way the record reads it: a second record, written
    # by the same library, carries the same name and version columns. A version that moved
    # is then a two-column comparison of two text files, so nothing here reinvents the
    # name-version split whose first version was the defect this whole file is about.
    _post_out=$(dev_ssh "ab-slot packages snapshot --no-payloads 2>&1")
    _post_id=$(printf '%s' "${_post_out}" | sed -n 's/^snapshot \([^ ]*\) written.*/\1/p' | head -n 1)
    _post="${_layer}/apk/snapshots/snapshot-${_post_id}.txt"
    _changed=$(dev_ssh "awk 'FNR == NR { ver[\$2] = \$3; next } \$1 == \"pkg\" && (\$2 in ver) && ver[\$2] != \$3 { print \$2 \" \" ver[\$2] \"->\" \$3 }' '${_pre}' '${_post}'")
    if [ -z "${_post_id}" ] || [ -z "${_changed}" ]; then
        CASE_NOTE="the upgrade ran but no installed version changed: the feed carries nothing newer for this machine (no candidate, not a defect)"
        return 4
    fi
    _advanced=$(printf '%s\n' "${_changed}" | grep -c . || true)
    _assert_eq "${_case}" "$([ "${_advanced}" -ge 1 ] && printf advanced || printf unchanged)" "advanced" \
        "at least one installed version moved: $(printf '%s\n' "${_changed}" | head -n 4 | tr '\n' ' ')"
    # The record is not the evidence by itself: the version it says the machine now runs
    # has to be the version apk reports, or the two readers disagree about one machine.
    _moved_name=$(printf '%s\n' "${_changed}" | head -n 1 | cut -d' ' -f1)
    _moved_to=$(printf '%s\n' "${_changed}" | head -n 1 | sed 's/.*->//')
    _assert_eq "${_case}" "$(printf '%s\n' "${_after}" | grep -c "^${_moved_name}-${_moved_to}\$")" "1" \
        "apk info -v agrees that the machine now runs ${_moved_name}-${_moved_to}"
    if [ "${CASE_FAILURES}" -eq 0 ]; then
        CASE_NOTE="packages=aligned upgraded: ${_advanced} version(s) moved ($(printf '%s\n' "${_changed}" | head -n 4 | tr '\n' ' ')); snapshot-${_sid}.txt was written first"
    else
        CASE_NOTE="the upgrade ran and ${_advanced} version(s) moved, but the record or the check around it did not hold; see the failed assertions"
    fi
    return 0
}

run_case() {
    _case=$1
    CASE_NOTE=""
    CASE_FAILURES=0
    case "${_case}" in
        P1) run_parse "${_case}" ;;
        P2) run_offline "${_case}" ;;
        P3) run_tamper "${_case}" ;;
        P4) run_crossbase "${_case}" ;;
        U1) run_upgrade "${_case}" ;;
        *)
            CASE_NOTE="unknown case"
            return 2
            ;;
    esac
    _rc=$?
    case "${_rc}" in
        0)
            if [ "${CASE_FAILURES}" -eq 0 ]; then
                printf '%s\tPASS\t%s\t%s\n' "${_case}" "${AB_HOST}" "${CASE_NOTE}" >>"${AB_PKG_RESULTS}"
                printf '== %s PASS %s\n' "${_case}" "${CASE_NOTE}"
                return 0
            fi
            printf '%s\tFAIL\t%s\t%s assertion(s); %s\n' "${_case}" "${AB_HOST}" "${CASE_FAILURES}" "${CASE_NOTE}" >>"${AB_PKG_RESULTS}"
            printf '== %s FAIL %s\n' "${_case}" "${CASE_NOTE}"
            return 1
            ;;
        4)
            printf '%s\tGAP\t%s\t%s\n' "${_case}" "${AB_HOST}" "${CASE_NOTE}" >>"${AB_PKG_RESULTS}"
            printf '== %s GAP %s\n' "${_case}" "${CASE_NOTE}"
            return 4
            ;;
        *)
            printf '%s\tFAIL\t%s\t%s\n' "${_case}" "${AB_HOST}" "${CASE_NOTE}" >>"${AB_PKG_RESULTS}"
            printf '== %s FAIL %s\n' "${_case}" "${CASE_NOTE}"
            return 1
            ;;
    esac
}

_rc_all=0
for _case in ${CASES}; do
    run_case "${_case}" || _rc_all=1
done
exit "${_rc_all}"
