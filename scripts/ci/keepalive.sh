#!/bin/sh
# Monthly keepalive: one line in .github/keepalive.log proves the scheduled watch is alive.
#
# GitHub disables a scheduled workflow in a public repository after 60 days without
# repository activity, and the auto-release workflow only does something when upstream
# publishes - a quiet upstream quarter would silently switch the pipeline off. The
# keepalive is the activity that keeps it on.
#
# Why a log line instead of a tag: a commit on the default branch is the strongest in-repo
# activity signal there is, it is readable, and it can be audited. The heartbeat tag this
# replaced was invisible in the history and its effect on the 60-day rule was never proved.
# The log is deliberately boring: one line per month, nothing a reader has to interpret.
#
# Rules:
#   * the baseline is the default branch's last commit (`git log -1 --format=%ct`), so any
#     push - a release, a pin bump, a documentation fix - already counts as activity
#   * the line is appended only when the baseline is at least CI_KEEPALIVE_INTERVAL_DAYS
#     (default 25) days old; below that the script answers `action=skipped` and writes
#     nothing at all, so a quiet repository does not grow a line per day
#   * re-running on the same day, or against the same commit, is a no-op: the log already
#     names it and a second line would only make the file longer
#   * the script never commits or pushes; the workflow owns that, because the blast radius
#     of a push belongs in YAML where it can be reviewed
#
# Usage: keepalive.sh run [--now YYYY-MM-DD] [--dry-run]
#
# Inputs (environment):
#   CI_KEEPALIVE_INTERVAL_DAYS  minimum gap in days (default: 25)
#   CI_REPO_ROOT                repository to inspect and append to (default: this checkout)
#   GITHUB_OUTPUT, CI_OUTPUT_ENV
#                               output channels, as scripts/ci/lib.sh spells them
#
# Outputs:
#   action      created | would-create | skipped
#   days_since  whole days between the baseline commit and the judged instant
#   last_commit the baseline commit sha
#   line        the line that was (or would be) appended, empty when skipped
#   reason      due | too-soon | already-logged-today | already-recorded
#
# This file is POSIX sh on purpose: it runs on the runner (dash as /bin/sh) and on a
# laptop, and the suite's portability guard parses it with dash. That is also why it does
# not source scripts/ci/lib.sh, which is bash.

set -eu

CI_KEEPALIVE_DEFAULT_INTERVAL_DAYS=25
CI_KEEPALIVE_LOG_REL=".github/keepalive.log"

keepalive_script_dir=$(cd "$(dirname "$0")" && pwd)

ka_log() {
    printf '[keepalive] %s\n' "$*"
}

ka_die() {
    printf '[keepalive] ERROR: %s\n' "$*" >&2
    exit 1
}

# ka_emit <name> <value>: publish one output on every channel that is configured, and on
# stdout when none is. Same contract as ci_emit_output in lib.sh, so the workflow and a
# local reproduction read the same keys.
ka_emit() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT}"
    fi
    if [ -n "${CI_OUTPUT_ENV:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >>"${CI_OUTPUT_ENV}"
    fi
    if [ -z "${GITHUB_OUTPUT:-}" ] && [ -z "${CI_OUTPUT_ENV:-}" ]; then
        printf '%s=%s\n' "$1" "$2"
    fi
}

ka_usage() {
    cat <<'USAGE'
usage: keepalive.sh run [--now YYYY-MM-DD] [--dry-run]

  --now       the date this run is judged at, UTC (default: today); also the date the
              appended line carries, so a test can pin the whole decision
  --dry-run   report what would happen without touching the log
USAGE
}

# ka_epoch_of_date <YYYY-MM-DD>: seconds since the epoch at 00:00:00 UTC.
# GNU date and BSD date spell "parse a date" differently and neither accepts the other's
# form, so both are tried and the first one that answers wins. This runs on a laptop and
# on a runner.
ka_epoch_of_date() {
    if date -u -d "$1" +%s >/dev/null 2>&1; then
        date -u -d "$1" +%s
    else
        date -u -j -f '%Y-%m-%d' "$1" +%s
    fi
}

ka_interval="${CI_KEEPALIVE_INTERVAL_DAYS:-${CI_KEEPALIVE_DEFAULT_INTERVAL_DAYS}}"
ka_now_date=""
ka_dry_run="false"
ka_command=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        run | --help | -h | help)
            # `run` is the only subcommand; the help spellings are accepted because a
            # person types them before reading the header.
            if [ "$1" = "run" ]; then
                ka_command="run"
            else
                ka_usage
                exit 0
            fi
            shift
            ;;
        --now)
            [ "$#" -ge 2 ] || ka_die "--now needs a date (YYYY-MM-DD)"
            ka_now_date="$2"
            shift 2
            ;;
        --now=*)
            ka_now_date="${1#--now=}"
            shift
            ;;
        --dry-run)
            ka_dry_run="true"
            shift
            ;;
        *)
            ka_usage >&2
            ka_die "unknown argument: $1"
            ;;
    esac
done

[ "${ka_command}" = "run" ] || {
    ka_usage >&2
    ka_die "expected the run subcommand"
}

case "${ka_interval}" in
    '' | *[!0-9]*) ka_die "CI_KEEPALIVE_INTERVAL_DAYS must be a whole number of days: ${ka_interval}" ;;
esac

ka_repo="${CI_REPO_ROOT:-}"
if [ -z "${ka_repo}" ]; then
    ka_repo=$(cd "${keepalive_script_dir}/../.." && pwd)
fi
git -C "${ka_repo}" rev-parse --git-dir >/dev/null 2>&1 ||
    ka_die "not a git repository: ${ka_repo}"

if [ -z "${ka_now_date}" ]; then
    ka_now_date=$(date -u +%Y-%m-%d)
fi
case "${ka_now_date}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) ka_die "invalid --now date (want YYYY-MM-DD): ${ka_now_date}" ;;
esac
ka_now_epoch=$(ka_epoch_of_date "${ka_now_date}") ||
    ka_die "invalid --now date (the host cannot parse it): ${ka_now_date}"
[ -n "${ka_now_epoch}" ] || ka_die "invalid --now date: ${ka_now_date}"

ka_last_commit=$(git -C "${ka_repo}" rev-parse --verify --quiet HEAD) ||
    ka_die "the repository has no commit to measure from: ${ka_repo}"
ka_last_epoch=$(git -C "${ka_repo}" log -1 --format=%ct HEAD) ||
    ka_die "could not read the commit date of ${ka_last_commit}"

ka_days_since=$(((ka_now_epoch - ka_last_epoch) / 86400))
if [ "${ka_days_since}" -lt 0 ]; then
    ka_days_since=0
fi

ka_log_path="${ka_repo}/${CI_KEEPALIVE_LOG_REL}"
ka_last_line=""
if [ -f "${ka_log_path}" ]; then
    ka_last_line=$(sed -n '$p' "${ka_log_path}" 2>/dev/null || true)
fi

# The appended line is the whole record, so its two halves have to be re-readable: the
# date is what the same-day check reads, the sha is what the same-commit check reads.
ka_line="${ka_now_date}T00:00:00Z keepalive last_commit=${ka_last_commit} days_since=${ka_days_since}"

ka_action="skipped"
ka_reason="too-soon"
case "${ka_last_line}" in
    "${ka_now_date}T"*)
        # A line for today already exists. Either the run is a re-run of a successful one
        # or the workflow pushed the commit and the queue fired the run again; appending a
        # second line would make the log say the same thing twice.
        ka_reason="already-logged-today"
        ;;
    *"last_commit=${ka_last_commit} "*)
        # The log already names this commit: the activity it records is this very commit,
        # so waiting for the interval again would keep pushing a line for one event.
        ka_reason="already-recorded"
        ;;
    *)
        if [ "${ka_days_since}" -ge "${ka_interval}" ]; then
            ka_action="created"
            ka_reason="due"
        fi
        ;;
esac

if [ "${ka_action}" = "created" ] && [ "${ka_dry_run}" = "true" ]; then
    ka_action="would-create"
fi

case "${ka_action}" in
    created)
        mkdir -p "$(dirname "${ka_log_path}")"
        # `printf` appends one complete line. A missing trailing newline in a hand-edited
        # log would otherwise glue the new line onto the old one.
        if [ -s "${ka_log_path}" ] && [ "$(tail -c 1 "${ka_log_path}" | wc -l)" -eq 0 ]; then
            printf '\n' >>"${ka_log_path}"
        fi
        printf '%s\n' "${ka_line}" >>"${ka_log_path}"
        ka_log "appended to ${CI_KEEPALIVE_LOG_REL}: ${ka_line}"
        ;;
    would-create)
        ka_log "dry run: would append ${ka_line}"
        ;;
    *)
        ka_log "skipped (${ka_reason}): ${ka_days_since} day(s) since ${ka_last_commit}, interval ${ka_interval}"
        ;;
esac

if [ "${ka_action}" = "skipped" ]; then
    ka_line=""
fi

ka_log "action ${ka_action} (${ka_reason})"
ka_emit "action" "${ka_action}"
ka_emit "days_since" "${ka_days_since}"
ka_emit "last_commit" "${ka_last_commit}"
ka_emit "line" "${ka_line}"
ka_emit "reason" "${ka_reason}"
