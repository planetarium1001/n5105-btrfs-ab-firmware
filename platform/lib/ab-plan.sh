#!/bin/sh
# ab-plan.sh - the plan block a base or package change is shown as, and the one question
# that follows it. Sourced by ab-upgrade, ab-packages and anything else that asks a person
# to accept work that touches the running system.
#
# What this file is not: it reads no apk database, no feed, no record file and no slot.
# The block is rendered from data the caller hands over (a plan file), so one renderer
# serves a base switch, a package follow and a replay, and a test can judge the layout
# without a device (design.md §6).
#
# The plan data is one record per line; the first token is the kind:
#
#   section <Name>              start a section (Update / Packages / Config, in that order)
#   row <label> <text>          a field row, `  - label   text`; labels share one column
#   gap <state> <cause>         open a gap group: why these packages are held back
#   member <name> [<version>]   one package the gap holds back
#   effect <text>               what that means for the machine
#   note <text>                 printed after every section as `NOTE: ...`
#   warn <text>                 printed after every section as `WARNING: ...`
#   count <n>                   how many packages the question offers to follow
#
# Empty lines and lines starting with `#` are ignored. <label> and <state> are single
# tokens; everything after them is free text. A record this file does not understand is
# refused rather than skipped: a plan that silently drops data reads as a plan without it.
#
# <state> is an attribution token from design.md §3, not the display word: `stale-abi`,
# `unreachable`, `no-copy`, `gone`, `pinned`. One vocabulary for the record, the plan and the
# log, and the renderer prints the display word (`stale-abi` -> `ABI STALE`, `gone` ->
# `DROPPED`, ...). `local` is accepted for `no-copy` because that is the spelling the record
# writes (`skipped=local:<name>`), and the two must not become two gaps. An unknown token is
# shown uppercased instead of being dropped.
#
# Rendering rules (design.md §6), all of them load-bearing:
#   * W = clamp(${COLUMNS:-80}, 60, 100); COLUMNS, then `tput cols`, then 80.
#   * No line is wider than W. A word longer than the space it has - in practice only a
#     feed URL - keeps both ends and loses its middle, marked `...`, because the prototype
#     in scratch/ printed an 84-column URL on an 80-column terminal (measured 2026-11-18):
#     folding cannot help a single word, so the word has to give somewhere.
#   * A row whose text does not fit moves the text under its label at 6 spaces of indent.
#     A label is never abbreviated and a package name is never cut.
#   * Gap groups are ordered ABI STALE, UNREACHABLE, NO COPY, DROPPED, PINNED whatever
#     order the caller wrote them in, and a group's `(n)` is counted from the members under
#     it, so a header cannot disagree with its own list.
#   * Sections are separated by one blank line, gap groups too.
#   * ASCII only: the console and the serial log are not obliged to render more.
#
# Functions:
#   ab_plan_width                          prints the clamped width for this terminal
#   ab_plan_render <plan-file>             prints the block on stdout; 1 if unusable
#   ab_plan_prompt_text <n>                prints `Proceed and follow <n> packages? [y/N] `
#   ab_plan_answer_accepts <answer>       0 for y Y yes YES Yes, 1 for anything else
#   ab_plan_answer_declines <answer>      0 for n N no NO No, 1 for anything else
#   ab_plan_ask <n> [<mode>]               0 accepted, 10 declined, 74 no terminal
#   ab_plan_present <plan-file> [<mode>]   refuse, then render, then ask; 0/10/74
#
# <mode> is `follow` (the default: ask) or one of the caller's documented escapes - `yes`,
# `system-only`, `no-follow` - which answer without asking. The caller decides why nothing
# is asked; this file only honours it. ab_plan_present takes the number in the question from
# the plan's own `count` record, so the number asked about cannot drift from the number the
# block printed.
#
# Interaction rules (design.md §7). Enter is not an answer - docs/update.md has said so since
# ac-15, and a mis-keyed Enter on a firmware write is expensive - so the accepted set is
# exactly y Y yes YES Yes, the refused set exactly n N no NO No, and every other answer,
# including a bare Enter, reprints the same line without moving on. EOF is a refusal with
# `reason=declined`. A stdin that is not a terminal is refused with `reason=noninteractive`
# before anything is asked, so a script that forgets `--yes` fails loudly instead of hanging
# or accepting. Nothing here writes: every write happens after a 0.
#
# AB_PLAN_ASSUME_TTY=1 lets a test answer on a pipe as if a terminal were attached. Only the
# terminal check reads it - the answer sets are not widened by it, so an environment
# variable cannot talk a machine into an upgrade.

# _ab_plan_digits <value>: strip leading zeroes. `[ 080 -lt 60 ]` is an error in a shell that
# reads bare numbers as octal, and COLUMNS=080 is a legal thing for a terminal to say.
_ab_plan_digits() {
    _abp_d=${1:-}
    while :; do
        case "${_abp_d}" in
            0?*) _abp_d=${_abp_d#0} ;;
            *) break ;;
        esac
    done
    [ -n "${_abp_d}" ] || _abp_d=0
    printf '%s' "${_abp_d}"
}

# ab_plan_width: never narrower than 60, never wider than 100. Below 60 the field rows stop
# fitting and the plan becomes a column of broken lines; above 100 the eye loses the label
# column. Sources are tried in the order the terminal offers them: COLUMNS (an interactive
# shell), then `tput cols` (a script with a tty), then 80.
ab_plan_width() {
    _abp_w=${COLUMNS:-}
    case "${_abp_w}" in
        '' | *[!0-9]*)
            _abp_w=$(tput cols 2>/dev/null) || _abp_w=""
            ;;
    esac
    case "${_abp_w}" in
        '' | *[!0-9]*) _abp_w=80 ;;
    esac
    _abp_w=$(_ab_plan_digits "${_abp_w}")
    [ "${_abp_w}" -lt 60 ] && _abp_w=60
    [ "${_abp_w}" -gt 100 ] && _abp_w=100
    printf '%s' "${_abp_w}"
    return 0
}

# _ab_plan_pad <text> <column>: pad to the column, never cut. A label longer than the column
# widens the column instead of losing a character.
_ab_plan_pad() {
    _abp_t=$1
    _abp_c=$2
    [ "${_abp_c}" -lt "${#_abp_t}" ] && _abp_c=${#_abp_t}
    printf '%s%*s' "${_abp_t}" $(( _abp_c - ${#_abp_t} )) ""
    return 0
}

# _ab_plan_word <word> <avail>: the word, or both of its ends with the middle replaced by
# `...`. Only a word that cannot be folded arrives here too long; in a plan that is a feed
# URL, and the whole URL stays available in `ab-packages sources` (design.md §6).
_ab_plan_word() {
    _abp_m=$1
    _abp_a=$2
    if [ "${#_abp_m}" -le "${_abp_a}" ]; then
        printf '%s' "${_abp_m}"
        return 0
    fi
    _abp_keep=$(( _abp_a - 3 ))
    if [ "${_abp_keep}" -lt 4 ]; then
        printf '%s' "$(printf '%s' "${_abp_m}" | cut -c "1-${_abp_a}")"
        return 0
    fi
    _abp_head=$(( (_abp_keep + 1) / 2 ))
    _abp_tail=$(( _abp_keep / 2 ))
    printf '%s...%s' \
        "$(printf '%s' "${_abp_m}" | cut -c "1-${_abp_head}")" \
        "$(printf '%s' "${_abp_m}" | cut -c "$(( ${#_abp_m} - _abp_tail + 1 ))-")"
    return 0
}

# _ab_plan_emit: print the line _ab_plan_fold is building.
_ab_plan_emit() {
    if [ "${_abp_first}" = "1" ]; then
        printf '%s%s\n' "${_abp_prefix}" "${_abp_fold}"
        _abp_first=0
    else
        printf '%*s%s\n' "${_abp_indent}" "" "${_abp_fold}"
    fi
    return 0
}

# _ab_plan_fold <prefix> <indent> <avail> <text>: fold <text> into lines of at most <avail>
# characters. The first line carries <prefix>, continuation lines get <indent> spaces, so a
# wrapped value or cause still reads as one statement instead of starting at the margin.
#
# Globbing is off while the wording is split: plan text contains `*.apk-new`, and the
# working directory of whoever called us is nobody's business here.
_ab_plan_fold() {
    _abp_prefix=$1
    _abp_indent=$2
    _abp_avail=$3
    _abp_text=$4
    [ "${_abp_avail}" -lt 24 ] && _abp_avail=24
    _abp_fold=""
    _abp_first=1
    set -f
    # shellcheck disable=SC2086  # the wording is split on purpose: that is the folding
    for _abp_word in ${_abp_text}; do
        _abp_word=$(_ab_plan_word "${_abp_word}" "${_abp_avail}")
        if [ -z "${_abp_fold}" ]; then
            _abp_fold=${_abp_word}
        elif [ $(( ${#_abp_fold} + 1 + ${#_abp_word} )) -le "${_abp_avail}" ]; then
            _abp_fold="${_abp_fold} ${_abp_word}"
        else
            _ab_plan_emit
            _abp_fold=${_abp_word}
        fi
    done
    set +f
    [ -n "${_abp_fold}" ] && _ab_plan_emit
    return 0
}

# _ab_plan_wrap <indent> <text>: the common case of _ab_plan_fold - a paragraph under an
# indent, with no label on the first line.
_ab_plan_wrap() {
    _abp_ind=$1
    _abp_sp=$(printf '%*s' "${_abp_ind}" "")
    _ab_plan_fold "${_abp_sp}" "${_abp_ind}" $(( AB_PLAN_W - _abp_ind )) "$2"
    return 0
}

# _ab_plan_label <prefix> <text>: `NOTE: text`, continuation under the text rather than at
# the margin, so a two-line NOTE still reads as one note.
_ab_plan_label() {
    _abp_lab=$1
    _ab_plan_fold "${_abp_lab} " 6 $(( AB_PLAN_W - ${#_abp_lab} - 1 )) "$2"
    return 0
}

# _ab_plan_row <label> <text>: `  - label   text` when it fits, otherwise the label on its
# own line and the text folded under it at 6 spaces. Two leading spaces, `- `, the label
# column and three spaces of gap: those 4 + column + 3 characters are the whole budget.
_ab_plan_row() {
    if [ -z "${2:-}" ]; then
        printf '  - %s\n' "$1"
        return 0
    fi
    if [ $(( 4 + AB_PLAN_LW + 3 + ${#2} )) -le "${AB_PLAN_W}" ]; then
        printf '  - %s%*s%s\n' "$(_ab_plan_pad "$1" "${AB_PLAN_LW}")" 3 "" "$2"
    else
        printf '  - %s\n' "$1"
        _ab_plan_wrap 6 "$2"
    fi
    return 0
}

# _ab_plan_state_display <token>: the word the plan shows for a record token. An unknown
# token is shown uppercased with its dashes opened up: a gap that cannot be named is still a
# gap, and hiding it is the lie design.md §3 exists to prevent.
_ab_plan_state_display() {
    case "${1:-}" in
        stale-abi) printf 'ABI STALE' ;;
        unreachable) printf 'UNREACHABLE' ;;
        no-copy | local) printf 'NO COPY' ;;
        gone) printf 'DROPPED' ;;
        pinned) printf 'PINNED' ;;
        *) printf '%s' "${1:-}" | tr 'a-z-' 'A-Z ' ;;
    esac
    return 0
}

# _ab_plan_state_rank <token>: position in the one order the plan is allowed to show
# (design.md §6). Unknown states sort after the five known ones.
_ab_plan_state_rank() {
    case "${1:-}" in
        stale-abi) printf '1' ;;
        unreachable) printf '2' ;;
        no-copy | local) printf '3' ;;
        gone) printf '4' ;;
        pinned) printf '5' ;;
        *) printf '9' ;;
    esac
    return 0
}

# _ab_plan_gap_print <state> <members> <cause> <effects>: one group - the header with its
# cause, then its members, then the consequences. <members> and <effects> are newline
# separated lists of `name version` and of effect sentences; both are printed whole.
_ab_plan_gap_print() {
    _abg_state=$(_ab_plan_state_display "$1")
    _abg_members=$2
    _abg_cause=$3
    _abg_effects=$4
    _abg_n=$(printf '%s\n' "${_abg_members}" | grep -c .)
    _abg_n=${_abg_n:-0}
    _abg_head="${_abg_state}  (${_abg_n})"
    if [ -n "${_abg_cause}" ]; then
        if [ $(( 2 + ${#_abg_head} + 3 + ${#_abg_cause} )) -le "${AB_PLAN_W}" ]; then
            printf '  %s%*s%s\n' "${_abg_head}" 3 "" "${_abg_cause}"
        else
            printf '  %s\n' "${_abg_head}"
            _ab_plan_wrap 6 "${_abg_cause}"
        fi
    else
        printf '  %s\n' "${_abg_head}"
    fi
    printf '%s\n' "${_abg_members}" | grep . | while IFS= read -r _abg_member; do
        _abg_name=${_abg_member%% *}
        _abg_ver=""
        [ "${_abg_member}" = "${_abg_name}" ] || _abg_ver=${_abg_member#"${_abg_name} "}
        if [ -z "${_abg_ver}" ]; then
            printf '    - %s\n' "${_abg_name}"
        elif [ $(( 6 + ${#_abg_name} + 1 + ${#_abg_ver} )) -le "${AB_PLAN_W}" ]; then
            printf '    - %s %s\n' "${_abg_name}" "${_abg_ver}"
        else
            # The name is the identity of the package and is never cut; a version that does
            # not fit follows on its own line, under the name.
            printf '    - %s\n' "${_abg_name}"
            _ab_plan_wrap 8 "${_abg_ver}"
        fi
    done
    printf '%s\n' "${_abg_effects}" | grep . | while IFS= read -r _abg_effect; do
        _ab_plan_wrap 6 "${_abg_effect}"
    done
    return 0
}

# _ab_plan_gap_flush: print the groups collected for the section that just ended, in the one
# order, one blank line between. Groups are collected first and printed here because the
# order is this file's decision, not the caller's: a block whose order depends on the order
# the gate happened to report is a block nobody can compare across two runs.
_ab_plan_gap_flush() {
    _abf_rank=1
    while [ "${_abf_rank}" -le 9 ]; do
        _abf_i=${_abp_sec_first}
        while [ "${_abf_i}" -le "${_abp_gi}" ]; do
            eval "_abf_tok=\${_abp_g${_abf_i}_state}"
            if [ "$(_ab_plan_state_rank "${_abf_tok}")" = "${_abf_rank}" ]; then
                # One blank line between the section's rows and its first group, and
                # between every pair of groups after that.
                printf '\n'
                eval "_abf_members=\${_abp_g${_abf_i}_members}"
                eval "_abf_cause=\${_abp_g${_abf_i}_cause}"
                eval "_abf_effects=\${_abp_g${_abf_i}_effects}"
                _ab_plan_gap_print "${_abf_tok}" "${_abf_members}" "${_abf_cause}" "${_abf_effects}"
            fi
            _abf_i=$(( _abf_i + 1 ))
        done
        _abf_rank=$(( _abf_rank + 1 ))
    done
    _abp_sec_first=$(( _abp_gi + 1 ))
    return 0
}

# _ab_plan_section <name>: close the section before (its gaps, and the blank line that
# belongs to the boundary) and open this one.
_ab_plan_section() {
    _ab_plan_gap_flush
    if [ "${_abp_sections}" = "1" ]; then
        printf '\n'
    fi
    _abp_sections=1
    printf '%s\n' "$1"
    return 0
}

# _ab_plan_note <kind> <text>: NOTE:/WARNING: keep the order the caller wrote them in and
# print after every section, because they summarise the block rather than belong to one.
_ab_plan_note() {
    _abp_notes=$(( _abp_notes + 1 ))
    _abp_v=$1
    eval "_abp_note${_abp_notes}_kind=\${_abp_v}"
    _abp_v=$2
    eval "_abp_note${_abp_notes}_text=\${_abp_v}"
    return 0
}

# _ab_plan_labels <plan-file>: the label column is as wide as the longest label in the whole
# plan, not as wide as the longest label in the current row. That is what makes the column a
# column (design.md §6).
_ab_plan_labels() {
    AB_PLAN_LW=0
    while IFS= read -r _abl_line || [ -n "${_abl_line}" ]; do
        case "${_abl_line%% *}" in
            row)
                _abl_rest=${_abl_line#row}
                _abl_rest=${_abl_rest# }
                _abl_label=${_abl_rest%% *}
                [ "${#_abl_label}" -le "${AB_PLAN_LW}" ] || AB_PLAN_LW=${#_abl_label}
                ;;
        esac
    done <"$1"
    return 0
}

# ab_plan_render <plan-file>: the block. Prints on stdout and returns 1 when the data is not
# a plan this file can render honestly - a missing file, or a record it does not know.
ab_plan_render() {
    _abr_file=${1:-}
    if [ -z "${_abr_file}" ] || [ ! -f "${_abr_file}" ]; then
        printf 'ab-plan: no plan data at %s\n' "${_abr_file:-<none>}" >&2
        return 1
    fi
    AB_PLAN_W=$(ab_plan_width)
    AB_PLAN_COUNT=""
    _ab_plan_labels "${_abr_file}"
    _abp_sections=0
    _abp_gi=0
    _abp_sec_first=1
    _abp_notes=0
    while IFS= read -r _abr_line || [ -n "${_abr_line}" ]; do
        _abr_kind=${_abr_line%% *}
        case "${_abr_kind}" in
            '' | '#'*) continue ;;
        esac
        _abr_args=${_abr_line#"${_abr_kind}"}
        _abr_args=${_abr_args# }
        case "${_abr_kind}" in
            section)
                [ -n "${_abr_args}" ] || continue
                _ab_plan_section "${_abr_args}"
                ;;
            row)
                _abr_label=${_abr_args%% *}
                _abr_text=""
                [ "${_abr_args}" = "${_abr_label}" ] || _abr_text=${_abr_args#"${_abr_label} "}
                _ab_plan_row "${_abr_label}" "${_abr_text}"
                ;;
            gap)
                _abr_tok=${_abr_args%% *}
                if [ -z "${_abr_tok}" ] || [ "${_abr_args}" = "${_abr_tok}" ]; then
                    printf 'ab-plan: a gap needs a state and a cause: %s\n' "${_abr_line}" >&2
                    return 1
                fi
                _abp_gi=$(( _abp_gi + 1 ))
                _abp_v=${_abr_tok}
                eval "_abp_g${_abp_gi}_state=\${_abp_v}"
                _abp_v=${_abr_args#"${_abr_tok} "}
                eval "_abp_g${_abp_gi}_cause=\${_abp_v}"
                # Both fields start out empty and set: a caller may run under `set -u`, and
                # a group without a member or an effect is a gap whose count is 0, not an
                # error.
                _abp_v=""
                eval "_abp_g${_abp_gi}_members=\${_abp_v}"
                eval "_abp_g${_abp_gi}_effects=\${_abp_v}"
                ;;
            member)
                if [ "${_abp_gi}" -lt 1 ]; then
                    printf 'ab-plan: a member before any gap: %s\n' "${_abr_line}" >&2
                    return 1
                fi
                eval "_abp_v=\${_abp_g${_abp_gi}_members}"
                if [ -n "${_abp_v}" ]; then
                    _abp_v="${_abp_v}
${_abr_args}"
                else
                    _abp_v=${_abr_args}
                fi
                eval "_abp_g${_abp_gi}_members=\${_abp_v}"
                ;;
            effect)
                if [ "${_abp_gi}" -lt 1 ]; then
                    printf 'ab-plan: an effect before any gap: %s\n' "${_abr_line}" >&2
                    return 1
                fi
                # The cause lives in the header; an effect is the consequence printed under
                # the members, so it appends to a list of its own even though the fixtures
                # only ever use one.
                eval "_abp_v=\${_abp_g${_abp_gi}_effects}"
                if [ -n "${_abp_v}" ]; then
                    _abp_v="${_abp_v}
${_abr_args}"
                else
                    _abp_v=${_abr_args}
                fi
                eval "_abp_g${_abp_gi}_effects=\${_abp_v}"
                ;;
            note)
                _ab_plan_note "NOTE" "${_abr_args}"
                ;;
            warn)
                _ab_plan_note "WARNING" "${_abr_args}"
                ;;
            count)
                case "${_abr_args}" in
                    '' | *[!0-9]*)
                        printf 'ab-plan: count needs a number: %s\n' "${_abr_line}" >&2
                        return 1
                        ;;
                esac
                AB_PLAN_COUNT=$(_ab_plan_digits "${_abr_args}")
                ;;
            *)
                printf 'ab-plan: unknown plan record: %s\n' "${_abr_line}" >&2
                return 1
                ;;
        esac
    done <"${_abr_file}"
    _ab_plan_gap_flush
    if [ "${_abp_notes}" -gt 0 ]; then
        printf '\n'
        _abr_i=1
        while [ "${_abr_i}" -le "${_abp_notes}" ]; do
            eval "_abr_kind=\${_abp_note${_abr_i}_kind}"
            eval "_abr_text=\${_abp_note${_abr_i}_text}"
            _ab_plan_label "${_abr_kind}:" "${_abr_text}"
            _abr_i=$(( _abr_i + 1 ))
        done
    fi
    return 0
}

# ab_plan_prompt_text <n>: the question, and the only question. The trailing space is part
# of the contract - the answer is typed on the same line.
ab_plan_prompt_text() {
    printf 'Proceed and follow %s packages? [y/N] ' "${1:-0}"
    return 0
}

# ab_plan_answer_accepts / ab_plan_answer_declines: the whole contract of the question.
# `yesterday` is not in the accepted set, which is why this is a case and not a prefix test.
ab_plan_answer_accepts() {
    case "${1:-}" in
        y | Y | yes | YES | Yes) return 0 ;;
    esac
    return 1
}

ab_plan_answer_declines() {
    case "${1:-}" in
        n | N | no | NO | No) return 0 ;;
    esac
    return 1
}

# _ab_plan_terminal: 0 when the question can be asked at all. AB_PLAN_ASSUME_TTY=1 stands in
# for a terminal so the suite can answer on a pipe, and it changes nothing else.
_ab_plan_terminal() {
    [ "${AB_PLAN_ASSUME_TTY:-0}" = "1" ] && return 0
    [ -t 0 ] && return 0
    return 1
}

_ab_plan_refuse_noninteractive() {
    printf 'ab-plan: refused, reason=noninteractive (no terminal; pass --yes to accept)\n'
    return 0
}

# ab_plan_ask <n> [<mode>]: 0 go ahead, 10 declined, 74 nothing to ask on.
#
# The caller must not write anything before a 0. Declining is not an error - a person
# answered - so it has a code of its own instead of being folded into 0 or 1.
ab_plan_ask() {
    _abq_n=${1:-0}
    _abq_mode=${2:-follow}
    case "${_abq_mode}" in
        yes | system-only | no-follow)
            # The three documented ways past the question (design.md §7): --yes accepts
            # everything, --system-only and --no-follow are the decision to take the base
            # and leave the packages alone.
            return 0
            ;;
        *) : ;;   # any other mode asks: asking is never the unsafe choice
    esac
    if ! _ab_plan_terminal; then
        _ab_plan_refuse_noninteractive
        return 74
    fi
    _abq_prompt=$(ab_plan_prompt_text "${_abq_n}")
    while :; do
        printf '%s' "${_abq_prompt}" >&2
        _abq_ans=""
        _abq_eof=0
        IFS= read -r _abq_ans || _abq_eof=1
        if ab_plan_answer_accepts "${_abq_ans}"; then
            return 0
        fi
        ab_plan_answer_declines "${_abq_ans}" && break
        # Anything else - a bare Enter, a word starting with y, a typo - is not an answer:
        # the same line is printed again and the caller is still where it was. At EOF there
        # is nobody left to ask, which is a refusal (design.md §7).
        [ "${_abq_eof}" = "1" ] && break
    done
    printf 'ab-plan: declined, nothing was written reason=declined\n'
    return 10
}

# ab_plan_present <plan-file> [<mode>]: the whole exchange in the order design.md §6/§7 puts
# it in. The refusal comes before the block on purpose: a script that cannot answer should
# not fill a log with a plan it is about to abandon.
ab_plan_present() {
    _abp_pfile=${1:-}
    _abp_pmode=${2:-follow}
    if [ "${_abp_pmode}" = "follow" ] && ! _ab_plan_terminal; then
        _ab_plan_refuse_noninteractive
        return 74
    fi
    ab_plan_render "${_abp_pfile}" || return 1
    if [ -z "${AB_PLAN_COUNT}" ] && [ "${_abp_pmode}" = "follow" ]; then
        printf 'ab-plan: the plan does not say how many packages it follows\n' >&2
        return 1
    fi
    ab_plan_ask "${AB_PLAN_COUNT:-0}" "${_abp_pmode}"
    return $?
}
