#!/bin/sh
# Shared config verifier for the acceptance drivers under scripts/device/.
#
# Four drivers (software samples, version matrix, bad config, full run) all have to
# answer the same three questions -- "is this option still what it was", "did this file
# change across the hop", "did we put the original back" -- so they ask them here
# instead of each writing its own comparison. Sourced, never executed:
#
#   . tests/lib/device_config.sh
#   devcfg_snapshot /tmp/before.tsv /etc/config/openclash /etc/config/dockerd
#   devcfg_snapshot --content /tmp/after.tsv /etc/config/openclash
#   devcfg_diff /tmp/before.tsv /tmp/after.tsv        # added/removed/changed, rc=1 if any
#   devcfg_assert_same AC-4-1 /tmp/before.tsv /tmp/after.tsv ac4.log
#   devcfg_assert_config AC-4-2 ac4.log openclash.config.enable 1
#   devcfg_inject_bad bad1 /etc/config/openclash "$(cat bad.conf)" ./backups
#   devcfg_restore bad1                               # or devcfg_restore_all
#
# Functions
#   plumbing
#     devcfg_exec               <remote command>  one call through the caller's executor
#     devcfg_require_executor   make sure an executor exists, or say how to set one
#     devcfg_sq                 the single-quoted form of a path for the remote shell
#     devcfg_sha256             <file>  sha256 of a local file
#     devcfg_tmpfile            a temporary file name on this host
#   snapshot and compare
#     devcfg_snapshot           <out> [--content] <path>...  path, state, sha256, size
#     devcfg_diff               <snap-a> <snap-b>  added/removed/changed lines, rc 1 if any
#     devcfg_assert_same        <case> <snap-a> <snap-b> [evidence]  diff as a PASS/FAIL row
#   config values
#     devcfg_get                <uci option>  the value, rc 1 when the device has none
#     devcfg_assert_value       <actual> <expected> <case> <label> [evidence]  no row
#     devcfg_assert_config      <case> <evidence> <uci option> <expected>  fetch, assert, row
#   bad config
#     devcfg_inject_bad         <tag> <remote-path> <bad-content> [local-backup-dir]
#                               sets DEVCFG_LAST_RESTORE to the tag
#     devcfg_restore            <tag>  put the original back and verify it
#     devcfg_restore_all        put every registered original back, newest first
#     devcfg_install_restore_trap  restore_all on exit, INT, TERM, HUP
#     devcfg_injections         the live tags, one per line
#   results
#     devcfg_row                <case> <verdict> <evidence> <note>  the row, printed
#     devcfg_record             <case> <verdict> <evidence> <note>  the row, appended
#
# The library never opens a connection. The caller supplies the executor: either a
# command prefix in DEVCFG_EXEC ("ssh -i k root@host", a plain "ssh" is enough) or
# nothing, in which case dev_ssh from scripts/device/lib.sh is used if it is loaded.
# The executor must forward its stdin, the way ssh does, because bad config is written
# through it. DEVCFG_RESULTS (else AB_RESULTS) is where rows are appended.
#
# Exit codes, the same vocabulary the drivers use: 0 ok, 1 difference/failure,
# 2 usage or no executor, 3 the host side lacks a tool or a temporary file.
#
# A snapshot is one TAB separated line per path:
#   <path>  <ok|missing>  <sha256|->  <bytes|->  [<content-copy>]
# A diff is one TAB separated line per difference, sorted, so two runs compare by eye:
#   added    <path> <state>
#   removed  <path> <state>
#   changed  <path> <old sha256|state> <new sha256|state>
# Every failure prints a line that can be pasted back into a shell, because the reader
# of a red case is a person with one device.

# --------------------------------------------------------------------------- #
# Plumbing
# --------------------------------------------------------------------------- #

# The single-quoted form of a path, for the remote shell. A path with a quote in it is
# still a path: the quote is escaped, not dropped.
devcfg_sq() {
    printf "'"
    printf '%s' "${1-}" | sed "s/'/'\\\\''/g"
    printf "'"
}

# Make sure there is something to run a remote command with. Sets DEVCFG_EXEC when it
# falls back to the loaded dev_ssh, so every later call takes the same path.
devcfg_require_executor() {
    [ -n "${DEVCFG_EXEC:-}" ] && return 0
    if command -v dev_ssh >/dev/null 2>&1; then
        DEVCFG_EXEC=dev_ssh
        return 0
    fi
    printf 'devcfg: no executor: set DEVCFG_EXEC to an ssh prefix or a function, or source scripts/device/lib.sh\n' >&2
    return 2
}

# devcfg_exec <remote command>: run one command over the caller's executor.
# Word splitting of DEVCFG_EXEC is deliberate: it is a command plus a prefix, not a
# single word, and this is the one place where that is true.
devcfg_exec() {
    devcfg_require_executor || return 2
    ${DEVCFG_EXEC} "$1"
}

devcfg_sha256() { # <file>
    [ -f "${1:?devcfg_sha256 needs a file}" ] || return 3
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        printf 'devcfg: no sha256 tool (sha256sum or shasum)\n' >&2
        return 3
    fi
}

devcfg_tmpfile() {
    _dir=${DEVCFG_TMPDIR:-${TMPDIR:-/tmp}}
    [ -d "${_dir}" ] || _dir=/tmp
    mktemp "${_dir}/devcfg.XXXXXX" || return 3
}

# Where the live injections are remembered. One line per injection:
#   <tag>  <remote-path>  <remote-backup>  <original sha256>  <local copy>
devcfg__registry() {
    [ -n "${DEVCFG_STATE_DIR:-}" ] || DEVCFG_STATE_DIR=$(mktemp -d "${DEVCFG_TMPDIR:-${TMPDIR:-/tmp}}/devcfg-state.XXXXXX") || return 3
    [ -d "${DEVCFG_STATE_DIR}" ] || mkdir -p "${DEVCFG_STATE_DIR}" || return 3
    printf '%s/restore.tsv\n' "${DEVCFG_STATE_DIR}"
}

# --------------------------------------------------------------------------- #
# Results
# --------------------------------------------------------------------------- #

# devcfg_row <case> <verdict> <evidence> <note>: the row format the drivers already
# write, printed but not stored. A tab inside a note would shift the columns, so it
# becomes a space -- the same rule scripts/device/lib.sh uses.
devcfg_row() {
    _case=${1:?devcfg_row needs a case}
    _verdict=${2:?devcfg_row needs a verdict}
    _evidence=${3:--}
    _note=${4:-}
    case "${_verdict}" in
        PASS | FAIL | GAP) : ;;
        *)
            printf 'devcfg_row: invalid verdict: %s (want PASS, FAIL or GAP)\n' "${_verdict}" >&2
            return 2
            ;;
    esac
    [ -n "${_evidence}" ] || _evidence=-
    _note=$(printf '%s' "${_note}" | tr '\t\n' '  ')
    printf '%s\t%s\t%s\t%s\n' "${_case}" "${_verdict}" "${_evidence}" "${_note}"
}

# devcfg_record <case> <verdict> <evidence> <note>: append the row where the driver
# keeps its results, so a caller cannot forget the evidence path.
devcfg_record() {
    _target=${DEVCFG_RESULTS:-${AB_RESULTS:-}}
    if [ -z "${_target}" ]; then
        printf 'devcfg_record: no results file (set DEVCFG_RESULTS or AB_RESULTS)\n' >&2
        return 2
    fi
    _row=$(devcfg_row "$@") || return 2
    mkdir -p "$(dirname "${_target}")" 2>/dev/null || true
    printf '%s\n' "${_row}" >>"${_target}"
}

# --------------------------------------------------------------------------- #
# Snapshots
# --------------------------------------------------------------------------- #

# devcfg_snapshot <out> [--content] <path>...
# Reads each path through the executor and records what the device answered. --content
# also keeps a local copy next to the snapshot, named in the fifth column, because
# "changed" is not actionable without the two versions to look at.
# A missing file is normal (an app that is not installed has no config) and is recorded
# rather than hidden; it is still a difference when two snapshots disagree about it.
# rc: 0 every path read, 1 at least one missing, 2 usage/executor, 3 host-side tool.
devcfg_snapshot() {
    _content=0
    if [ "${1:-}" = "--content" ]; then
        _content=1
        shift
    fi
    _out=${1:-}
    if [ -z "${_out}" ] || [ $# -lt 2 ]; then
        printf 'devcfg_snapshot: usage: devcfg_snapshot <out-file> [--content] <path>...\n' >&2
        return 2
    fi
    shift
    devcfg_require_executor || return 2
    mkdir -p "$(dirname "${_out}")" 2>/dev/null || true
    : >"${_out}" || return 3
    _cdir=""
    if [ "${_content}" -eq 1 ]; then
        _cdir="${_out}.content"
        mkdir -p "${_cdir}" || return 3
    fi
    _i=0
    _rc=0
    for _p in "$@"; do
        _i=$((_i + 1))
        _tmp=$(devcfg_tmpfile) || return 3
        if devcfg_exec "cat $(devcfg_sq "${_p}")" >"${_tmp}" 2>/dev/null; then
            _sha=$(devcfg_sha256 "${_tmp}") || _rc=3
            _size=$(wc -c <"${_tmp}" | tr -d ' ')
            printf '%s\tok\t%s\t%s' "${_p}" "${_sha}" "${_size}" >>"${_out}"
            if [ -n "${_cdir}" ]; then
                _name=$(printf '%03d' "${_i}")
                cp "${_tmp}" "${_cdir}/${_name}" || _rc=3
                printf '\t%s' "${_name}" >>"${_out}"
            fi
        else
            printf '%s\tmissing\t-\t-' "${_p}" >>"${_out}"
            [ -n "${_cdir}" ] && printf '\t-' >>"${_out}"
            [ "${_rc}" -eq 0 ] && _rc=1
        fi
        printf '\n' >>"${_out}"
        rm -f "${_tmp}"
    done
    return "${_rc}"
}

# devcfg_diff <snapshot-a> <snapshot-b>: what moved between the two.
# Prints one line per difference and returns 1 when there is one, 0 when there is not,
# 2 when the arguments are not two snapshots. Sorted, so a diff can be pasted into a
# report and compared against the previous run.
devcfg_diff() {
    _a=${1:-}
    _b=${2:-}
    if [ ! -f "${_a}" ] || [ ! -f "${_b}" ]; then
        printf 'devcfg_diff: two snapshot files are needed (got %s, %s)\n' "${_a:--}" "${_b:--}" >&2
        return 2
    fi
    _out=$(
        {
            printf '###A\n'
            cat "${_a}"
            printf '###B\n'
            cat "${_b}"
        } | awk -F'\t' '
            $0 ~ /^###[AB]$/ { side = substr($0, 4, 1); next }
            side == "A" { state[$1] = $2; hash[$1] = $3; next }
            side == "B" {
                seen[$1] = 1
                if (!($1 in state)) printf "added\t%s\t%s\n", $1, $2
                else if (state[$1] != $2) printf "changed\t%s\t%s\t%s\n", $1, state[$1], $2
                else if (hash[$1] != $3) printf "changed\t%s\t%s\t%s\n", $1, hash[$1], $3
            }
            END { for (p in state) if (!(p in seen)) printf "removed\t%s\t%s\n", p, state[p] }
        ' | sort
    )
    [ -n "${_out}" ] || return 0
    printf '%s\n' "${_out}"
    return 1
}

# devcfg_assert_same <case> <snapshot-a> <snapshot-b> [evidence]
# The ac-4 question in one call: the config the app owned before the hop is the config
# it owns after it. Records PASS or FAIL, prints the differences on failure.
devcfg_assert_same() {
    _case=${1:?devcfg_assert_same needs a case}
    if [ $# -lt 3 ]; then
        printf 'devcfg_assert_same: usage: devcfg_assert_same <case> <snap-a> <snap-b> [evidence]\n' >&2
        return 2
    fi
    _ev=${4:--}
    _out=$(devcfg_diff "$2" "$3")
    _rc=$?
    if [ "${_rc}" -eq 0 ]; then
        devcfg_record "${_case}" PASS "${_ev}" "no config difference"
        return 0
    fi
    if [ "${_rc}" -ne 1 ]; then
        devcfg_record "${_case}" GAP "${_ev}" "snapshot unreadable"
        return "${_rc}"
    fi
    printf 'FAIL %s devcfg_assert_same: config moved between the two snapshots\n' "${_case}"
    printf '%s\n' "${_out}" | while IFS= read -r _line; do
        printf '  %s\n' "${_line}"
    done
    printf '  rerun: %s\n' "${AB_MATRIX_CMD:-devcfg_diff $2 $3}"
    devcfg_record "${_case}" FAIL "${_ev}" "$(printf '%s' "${_out}" | tr '\n' ' ')"
    return 1
}

# --------------------------------------------------------------------------- #
# Config values
# --------------------------------------------------------------------------- #

# devcfg_get <uci option path>: the value the device reports, without the trailing
# newline. rc 1 when uci has nothing to say (an option an app never created), 2 when
# there is no executor -- a caller must not read "no machine" as "option missing".
devcfg_get() {
    _opt=${1:?devcfg_get needs a uci option path}
    devcfg_require_executor || return 2
    _val=$(devcfg_exec "uci -q get $(devcfg_sq "${_opt}")" 2>/dev/null) || return 1
    printf '%s' "${_val}"
}

# devcfg_assert_value <actual> <expected> <case> <label> [evidence]
# The low-level comparison: no fetch, no row, so a caller that already has the value
# (after a reboot, after a restore) can still use the same failure line.
devcfg_assert_value() {
    _actual=${1-}
    _want=${2-}
    _case=${3:-?}
    _label=${4:-value}
    _ev=${5:-${AB_EVIDENCE_LOG:-}}
    [ "${_actual}" = "${_want}" ] && return 0
    printf 'FAIL %s devcfg_assert_value %s: expected=%s got=%s\n' "${_case}" "${_label}" "${_want}" "${_actual}"
    printf '  evidence: %s\n' "${_ev:--}"
    printf '  rerun: %s\n' "${AB_MATRIX_CMD:-./scripts/device/badconfig-probe.sh --case ${_case}}"
    [ -n "${_ev}" ] && printf '%s: FAIL %s %s expected=%s got=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_case}" "${_label}" "${_want}" "${_actual}" >>"${_ev}" 2>/dev/null
    return 1
}

# devcfg_assert_config <case> <evidence> <uci option> <expected>
# Fetch, compare, record. This is the ac-4/ac-5 workhorse: an app's own setting is
# asserted by its value, not by a hash, so a reordered config file is not a failure.
devcfg_assert_config() {
    _case=${1:?devcfg_assert_config needs a case}
    _ev=${2:--}
    _opt=${3:?devcfg_assert_config needs a uci option path}
    _want=${4-}
    _got=$(devcfg_get "${_opt}")
    _getrc=$?
    if [ "${_getrc}" -eq 2 ]; then
        printf 'GAP %s devcfg_assert_config %s: no executor, the option was never read\n' "${_case}" "${_opt}"
        devcfg_record "${_case}" GAP "${_ev}" "no executor: ${_opt} not read"
        return 4
    fi
    if [ "${_getrc}" -ne 0 ]; then
        printf 'FAIL %s devcfg_assert_config %s: uci -q get %s answered nothing\n' "${_case}" "${_opt}" "${_opt}"
        printf '  evidence: %s\n' "${_ev}"
        printf '  rerun: %s\n' "${AB_MATRIX_CMD:-./scripts/device/badconfig-probe.sh --case ${_case}}"
        devcfg_record "${_case}" FAIL "${_ev}" "uci -q get ${_opt} answered nothing"
        return 1
    fi
    if [ "${_got}" = "${_want}" ]; then
        devcfg_record "${_case}" PASS "${_ev}" "${_opt}=${_got}"
        return 0
    fi
    devcfg_assert_value "${_got}" "${_want}" "${_case}" "${_opt}" "${_ev}" || true
    devcfg_record "${_case}" FAIL "${_ev}" "${_opt} expected=${_want} got=${_got}"
    return 1
}

# --------------------------------------------------------------------------- #
# Bad config: inject, and be able to put it back
# --------------------------------------------------------------------------- #

# devcfg_inject_bad <tag> <remote-path> <bad-content> [local-backup-dir]
# The order is the point. Read the original, copy it on the device, register the
# restore, and only then overwrite. So there is no window in which a bad config exists
# without a way back -- not when the write fails, not when the write silently lands
# wrong (both are verified), and not when the calling script dies (devcfg_install_
# restore_trap and devcfg_restore_all cover that). The restore command is printed as
# soon as it exists, before the file is touched.
devcfg_inject_bad() {
    _tag=${1:-}
    _path=${2:-}
    _bad=${3-}
    _lbdir=${4:-}
    if [ -z "${_tag}" ] || [ -z "${_path}" ]; then
        printf 'devcfg_inject_bad: usage: devcfg_inject_bad <tag> <remote-path> <bad-content> [backup-dir]\n' >&2
        return 2
    fi
    case "${_tag}" in
        *[!A-Za-z0-9._-]*)
            printf 'devcfg_inject_bad: tag must be [A-Za-z0-9._-]: %s\n' "${_tag}" >&2
            return 2
            ;;
    esac
    devcfg_require_executor || return 2
    _q=$(devcfg_sq "${_path}")
    _bk="${_path}.devcfg-bak-${_tag}"
    _qbk=$(devcfg_sq "${_bk}")
    _reg=$(devcfg__registry) || return 3

    # 1. the original, as the device has it now
    _orig=$(devcfg_tmpfile) || return 3
    if ! devcfg_exec "cat ${_q}" >"${_orig}" 2>/dev/null; then
        printf 'devcfg_inject_bad: %s: cannot read the original, nothing was changed\n' "${_path}" >&2
        rm -f "${_orig}"
        return 1
    fi
    _orig_sha=$(devcfg_sha256 "${_orig}") || { rm -f "${_orig}"; return 3; }

    # 2. a copy on the device, before the file is touched
    if ! devcfg_exec "cp -a ${_q} ${_qbk}"; then
        printf 'devcfg_inject_bad: %s: backup failed, nothing was changed\n' "${_path}" >&2
        rm -f "${_orig}"
        return 1
    fi

    # 3. registered before the overwrite: from here on, restore always has a way back
    printf '%s\t%s\t%s\t%s\t%s\n' "${_tag}" "${_path}" "${_bk}" "${_orig_sha}" "${_orig}" >>"${_reg}"
    if [ -n "${_lbdir}" ]; then
        mkdir -p "${_lbdir}" 2>/dev/null && cp "${_orig}" "${_lbdir}/${_tag}.orig" 2>/dev/null
    fi
    DEVCFG_LAST_RESTORE="${_tag}"
    printf 'devcfg: injected tag=%s into %s (backup %s, sha256 %s)\n' \
        "${_tag}" "${_path}" "${_bk}" "${_orig_sha}"
    printf 'devcfg: restore command: cp -a %s %s   (or: devcfg_restore %s)\n' \
        "${_qbk}" "${_q}" "${_tag}"

    # 4. the bad content, through the executor's stdin
    _badfile=$(devcfg_tmpfile) || { devcfg_restore "${_tag}" || true; return 3; }
    printf '%s' "${_bad}" >"${_badfile}"
    _bad_sha=$(devcfg_sha256 "${_badfile}") || { rm -f "${_badfile}"; devcfg_restore "${_tag}" || true; return 3; }
    if ! printf '%s' "${_bad}" | devcfg_exec "cat > ${_q}"; then
        printf 'devcfg_inject_bad: %s: the write failed; restoring the original\n' "${_path}" >&2
        rm -f "${_badfile}"
        devcfg_restore "${_tag}" || true
        return 1
    fi

    # 5. what landed, not what was sent
    _now=$(devcfg_tmpfile) || { rm -f "${_badfile}"; devcfg_restore "${_tag}" || true; return 3; }
    if ! devcfg_exec "cat ${_q}" >"${_now}" 2>/dev/null || [ "$(devcfg_sha256 "${_now}")" != "${_bad_sha}" ]; then
        printf 'devcfg_inject_bad: %s: the device does not hold the injected content; restoring the original\n' "${_path}" >&2
        rm -f "${_badfile}" "${_now}"
        devcfg_restore "${_tag}" || true
        return 1
    fi
    rm -f "${_badfile}" "${_now}"
    return 0
}

# devcfg_restore <tag>: put the registered original back and verify the hash.
# Idempotent: a tag that is not registered is already back, so a second call (from a
# trap, after a manual restore) is not an error. A failed restore keeps the entry, so
# a caller can retry instead of losing the backup.
devcfg_restore() {
    _tag=${1:-}
    if [ -z "${_tag}" ]; then
        printf 'devcfg_restore: usage: devcfg_restore <tag>\n' >&2
        return 2
    fi
    devcfg_require_executor || return 2
    _reg=$(devcfg__registry) || return 3
    [ -f "${_reg}" ] || return 0
    _line=$(awk -F'\t' -v t="${_tag}" '$1 == t { print; exit }' "${_reg}")
    [ -n "${_line}" ] || return 0
    _path=$(printf '%s\n' "${_line}" | cut -f2)
    _bk=$(printf '%s\n' "${_line}" | cut -f3)
    _sha=$(printf '%s\n' "${_line}" | cut -f4)
    _local=$(printf '%s\n' "${_line}" | cut -f5)
    _q=$(devcfg_sq "${_path}")
    _qbk=$(devcfg_sq "${_bk}")

    if ! devcfg_exec "cp -a ${_qbk} ${_q}"; then
        printf 'devcfg_restore: %s: restore command failed; the backup is kept at %s\n' "${_path}" "${_bk}" >&2
        printf 'devcfg: retry with: cp -a %s %s\n' "${_qbk}" "${_q}" >&2
        return 1
    fi
    _now=$(devcfg_tmpfile) || return 3
    if ! devcfg_exec "cat ${_q}" >"${_now}" 2>/dev/null || [ "$(devcfg_sha256 "${_now}")" != "${_sha}" ]; then
        printf 'devcfg_restore: %s: the restored file does not hash to %s; the backup is kept\n' \
            "${_path}" "${_sha}" >&2
        rm -f "${_now}"
        return 1
    fi
    rm -f "${_now}"
    devcfg_exec "rm -f ${_qbk}" || true
    _rest=$(devcfg_tmpfile) || return 3
    awk -F'\t' -v t="${_tag}" '$1 != t' "${_reg}" >"${_rest}" && cat "${_rest}" >"${_reg}"
    rm -f "${_rest}"
    rm -f "${_local}" 2>/dev/null || true
    printf 'devcfg: restored tag=%s %s (sha256 %s)\n' "${_tag}" "${_path}" "${_sha}"
    return 0
}

# devcfg_restore_all: every live injection, newest first, so nested injections of the
# same file come back in the reverse order they were taken. Prints what it restored.
devcfg_restore_all() {
    _reg=$(devcfg__registry 2>/dev/null) || return 0
    [ -f "${_reg}" ] || return 0
    [ -s "${_reg}" ] || return 0
    _tags=$(awk -F'\t' '{ a[NR] = $1 } END { for (i = NR; i > 0; i--) print a[i] }' "${_reg}")
    _rc=0
    while IFS= read -r _t; do
        [ -n "${_t}" ] || continue
        devcfg_restore "${_t}" || _rc=1
    done <<EOF
${_tags}
EOF
    return "${_rc}"
}

# devcfg_install_restore_trap: the last line of defence. A driver that dies between an
# injection and its restore -- a red line, a signal, a bad case file -- still puts the
# original back, because the restore was registered before the file was touched.
devcfg_install_restore_trap() {
    trap 'devcfg_restore_all' 0
    trap 'devcfg_restore_all; exit 130' INT
    trap 'devcfg_restore_all; exit 143' TERM
    trap 'devcfg_restore_all; exit 129' HUP
}

# devcfg_injections: the tags still waiting to be restored, one per line.
devcfg_injections() {
    _reg=$(devcfg__registry 2>/dev/null) || return 0
    [ -f "${_reg}" ] || return 0
    cut -f1 "${_reg}"
}
