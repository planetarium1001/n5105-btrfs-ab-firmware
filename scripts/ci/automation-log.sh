#!/bin/sh
# Automation audit log: one row per event, appended to .github/automation-log.md.
#
# The keepalive log records that the watch is alive; this file records what the automation
# did, in a form a human reads without opening a run. Two files on purpose: a monthly
# keepalive line must not turn into noise in the table someone reads to answer "which
# releases did CI produce, and what proved them".
#
# Rules:
#   * the header is fixed (`| time | event | detail | result | link |` plus its divider) and
#     is written once, when the file is created; existing rows are never rewritten or
#     reordered, because the file is append-only by contract
#   * the four events are the four things the automation can be held to: a new upstream
#     release was detected and built, a release was published, a platform change landed on
#     main, or a stage of the automatic release failed
#   * `|` inside a cell would split it into two columns, so every cell is escaped to `\|`;
#     a table whose column count silently drifts is worse than no table
#   * a write failure is the caller's to handle: this script exits non-zero and the job
#     that called it reports, so an unwritable log never turns a green build red silently
#
# Usage: automation-log.sh append --event <upstream|release|platform|failure> [options]
#
# Every option, and the result default each event carries, is listed by `--help`: the usage
# block below is the only copy of that list, so a flag cannot read one way here and another
# there.
#
# Inputs (environment):
#   CI_REPO_ROOT       repository root (default: this checkout)
#   CI_AUTOMATION_LOG  path relative to the root (default: .github/automation-log.md)
#
# This file is POSIX sh on purpose (the runner's /bin/sh is dash, the suite's portability
# guard parses it with dash), which is also why it does not source scripts/ci/lib.sh.

set -eu

CI_AUTOMATION_LOG_REL="${CI_AUTOMATION_LOG:-.github/automation-log.md}"

automation_script_dir=$(cd "$(dirname "$0")" && pwd)

al_log() {
    printf '[automation-log] %s\n' "$*"
}

al_die() {
    printf '[automation-log] ERROR: %s\n' "$*" >&2
    exit 2
}

al_usage() {
    cat <<'USAGE'
usage: automation-log.sh append --event <upstream|release|platform|failure> [options]

  --event <type>    upstream | release | platform | failure (required)
  --version <V>     upstream version the row is about
  --old-pin <V>     the pin before this change
  --sha <S>         the commit the row is about
  --subject <text>  the commit subject, or any one-line description
  --assets <N>      number of release assets
  --stage <name>    the failing stage
  --reason <text>   why it failed
  --result <text>   the result cell (defaults: released, published, recorded, failed)
  --link <url>      the run, release or issue to look at (required)
USAGE
}

# al_cell <text>: one table cell, with the pipe escaped and the newlines folded away.
# A cell is one line: the table breaks on the first embedded newline, and a URL or a commit
# subject may carry one only by accident.
al_cell() {
    printf '%s' "$1" | tr '\n\r' '  ' | sed 's/|/\\|/g'
}

# al_header: the file's first two lines. They are the contract the reader and the run
# depend on, so they are written through one literal instead of being assembled.
al_header() {
    printf '| time | event | detail | result | link |\n| --- | --- | --- | --- | --- |\n'
}

# al_now: the row's timestamp, UTC, in the same shape as the keepalive line's.
al_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

al_subcommand=""
al_event=""
al_version=""
al_old_pin=""
al_sha=""
al_subject=""
al_assets=""
al_stage=""
al_reason=""
al_result=""
al_link=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        append)
            al_subcommand="append"
            shift
            ;;
        -h | --help | help)
            al_usage
            exit 0
            ;;
        --event | --version | --old-pin | --sha | --subject | --assets | --stage | --reason | --result | --link)
            [ "$#" -ge 2 ] || al_die "$1 needs a value"
            case "$1" in
                --event) al_event="$2" ;;
                --version) al_version="$2" ;;
                --old-pin) al_old_pin="$2" ;;
                --sha) al_sha="$2" ;;
                --subject) al_subject="$2" ;;
                --assets) al_assets="$2" ;;
                --stage) al_stage="$2" ;;
                --reason) al_reason="$2" ;;
                --result) al_result="$2" ;;
                --link) al_link="$2" ;;
            esac
            shift 2
            ;;
        --event=* | --version=* | --old-pin=* | --sha=* | --subject=* | --assets=* | --stage=* | --reason=* | --result=* | --link=*)
            al_name="${1%%=*}"
            al_value="${1#*=}"
            case "${al_name}" in
                --event) al_event="${al_value}" ;;
                --version) al_version="${al_value}" ;;
                --old-pin) al_old_pin="${al_value}" ;;
                --sha) al_sha="${al_value}" ;;
                --subject) al_subject="${al_value}" ;;
                --assets) al_assets="${al_value}" ;;
                --stage) al_stage="${al_value}" ;;
                --reason) al_reason="${al_value}" ;;
                --result) al_result="${al_value}" ;;
                --link) al_link="${al_value}" ;;
            esac
            shift
            ;;
        *)
            al_usage >&2
            al_die "unknown argument: $1"
            ;;
    esac
done

[ "${al_subcommand}" = "append" ] || {
    al_usage >&2
    al_die "expected the append subcommand"
}

case "${al_event}" in
    upstream | release | platform | failure) : ;;
    '')
        al_usage >&2
        al_die "an event is required: upstream, release, platform or failure"
        ;;
    *)
        # A typo in the event is not a row with a new event name: it is a bug in the caller,
        # and the four names above are the whole vocabulary of this table.
        al_die "unknown event '${al_event}': expected upstream, release, platform or failure"
        ;;
esac

[ -n "${al_link}" ] || al_die "--link is required: a row nobody can follow is not an audit row"

if [ -n "${al_assets}" ]; then
    case "${al_assets}" in
        *[!0-9]*) al_die "--assets must be a whole number: ${al_assets}" ;;
    esac
fi

# The detail column is per event, and it is built from the fields the event actually has:
# a release row with a commit subject in it would be a field nobody put there.
al_detail=""
case "${al_event}" in
    upstream)
        al_detail="version ${al_version:-unknown}"
        if [ -n "${al_old_pin}" ]; then
            al_detail="${al_detail} (pin ${al_old_pin} -> ${al_version:-unknown})"
        fi
        [ -z "${al_subject}" ] || al_detail="${al_detail}: ${al_subject}"
        [ -n "${al_result}" ] || al_result="released"
        ;;
    release)
        al_detail="version ${al_version:-unknown}"
        if [ -n "${al_assets}" ]; then
            al_detail="${al_detail}, ${al_assets} asset(s)"
        fi
        [ -n "${al_result}" ] || al_result="published"
        ;;
    platform)
        al_detail="${al_sha:-unknown commit}"
        [ -z "${al_subject}" ] || al_detail="${al_detail}: ${al_subject}"
        [ -n "${al_result}" ] || al_result="recorded"
        ;;
    failure)
        al_detail="stage ${al_stage:-unknown}"
        [ -z "${al_reason}" ] || al_detail="${al_detail}: ${al_reason}"
        [ -n "${al_result}" ] || al_result="failed"
        ;;
esac

al_root="${CI_REPO_ROOT:-}"
if [ -z "${al_root}" ]; then
    al_root=$(cd "${automation_script_dir}/../.." && pwd)
fi
[ -d "${al_root}" ] || al_die "repository root does not exist: ${al_root}"

al_log_path="${al_root}/${CI_AUTOMATION_LOG_REL}"
mkdir -p "$(dirname "${al_log_path}")"
if [ ! -f "${al_log_path}" ] || [ ! -s "${al_log_path}" ]; then
    al_header >"${al_log_path}"
    al_log "created ${CI_AUTOMATION_LOG_REL} with its header"
fi

if [ -s "${al_log_path}" ] && [ "$(tail -c 1 "${al_log_path}" | wc -l)" -eq 0 ]; then
    printf '\n' >>"${al_log_path}"
fi

al_row="| $(al_cell "$(al_now)") | $(al_cell "${al_event}") | $(al_cell "${al_detail}") | $(al_cell "${al_result}") | $(al_cell "${al_link}") |"
printf '%s\n' "${al_row}" >>"${al_log_path}"
al_log "appended ${al_event} row to ${CI_AUTOMATION_LOG_REL}"
printf '%s\n' "${al_row}"
