#!/usr/bin/env bash
# Daily heartbeat tag: the cheapest proof that the scheduled workflow is still alive.
#
# GitHub disables a scheduled workflow in a public repository after 60 days without
# activity. The auto-release workflow only does something when upstream publishes, so a
# quiet upstream quarter would silently switch the pipeline off. A tag that no release
# is built from keeps the repository active, which is the only reason this script
# exists.
#
# Rules:
#   * the tag is `heartbeat-YYYYMM` for the month of --now (default: today, UTC)
#   * it is created only when the newest of (last heartbeat tag, last formal release tag,
#     last commit touching the pin) is at least CI_HEARTBEAT_INTERVAL_DAYS days old
#   * no baseline at all means "due": the first heartbeat must be able to happen
#   * an existing `heartbeat-YYYYMM` makes the run a no-op with `reason=already-tagged`,
#     so re-running the same month is idempotent: no second tag and no error
#   * `heartbeat-` never matches `^v`, which is the release trigger. The name is asserted
#     below rather than left to the reader of this comment, because a tag that matched
#     `v*` would publish a firmware release built from nothing.
#
# The script only creates the tag; pushing is the workflow's decision. A tag pushed with
# GITHUB_TOKEN starts no workflow run, and the blast radius of a tag push belongs in YAML
# where it can be reviewed.
#
# Usage: heartbeat-tag.sh [--now YYYY-MM-DD] [--dry-run]
#
# Inputs (environment):
#   CI_HEARTBEAT_INTERVAL_DAYS  minimum gap in days (default: 50)
#   CI_REPO_ROOT                repository to inspect and tag (default: this checkout)
#   CI_TMP_ROOT, GITHUB_OUTPUT, CI_OUTPUT_ENV
#                         scratch directory and output channels
#
# Outputs:
#   action      created | would-create | skipped
#   tag         the tag name for the month of --now
#   days_since  days since the baseline, empty when there is no baseline
#   reason      already-tagged | too-soon | first-heartbeat | due

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init heartbeat

usage() {
    cat <<'USAGE'
usage: heartbeat-tag.sh [--now YYYY-MM-DD] [--dry-run]

  --now       the date the heartbeat is judged against (default: today, UTC)
  --dry-run   report what would happen without creating a tag
USAGE
}

# to_epoch <YYYY-MM-DD>: milliseconds are not needed, but the GNU and BSD spellings of
# "parse a date" differ, and this script runs on both a laptop and a runner.
to_epoch() {
    local date_arg="$1"
    if date -u -d "${date_arg}" +%s >/dev/null 2>&1; then
        date -u -d "${date_arg}" +%s
        return 0
    fi
    date -u -j -f '%Y-%m-%d' "${date_arg}" +%s
}

interval="${CI_HEARTBEAT_INTERVAL_DAYS:-50}"
now_arg=""
dry_run="false"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --now)
            [ "$#" -ge 2 ] || ci_die "--now needs a date (YYYY-MM-DD)"
            now_arg="$2"
            shift 2
            ;;
        --now=*)
            now_arg="${1#--now=}"
            shift
            ;;
        --dry-run)
            dry_run="true"
            shift
            ;;
        -h | --help | help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            ci_die "unknown argument: $1"
            ;;
    esac
done

ci_match "${interval}" '^[0-9]+$' "CI_HEARTBEAT_INTERVAL_DAYS"

repo="${CI_REPO_ROOT}"
if ! git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1; then
    ci_die "not a git repository: ${repo}"
fi

now_date="${now_arg:-$(date -u +%Y-%m-%d)}"
ci_match "${now_date}" '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' "--now date"

# The month decides the name, so a run on any day of the month is the same heartbeat.
tag="heartbeat-${now_date:0:4}${now_date:5:2}"
ci_match "${tag}" '^heartbeat-[0-9]{6}$' "heartbeat tag name"

# Hard assertion, not just the comment at the top: release.yml triggers on `v*`, so a
# heartbeat that matched that pattern would be published as a firmware release.
if printf '%s\n' "${tag}" | grep -Eq '^v'; then
    ci_die "heartbeat tag '${tag}' matches ^v, which would trigger the release workflow"
fi

now_epoch="$(to_epoch "${now_date}")" || ci_die "invalid --now date: ${now_date}"
ci_log "heartbeat ${tag}, judged at ${now_date} (${now_epoch})"

# --------------------------------------------------------------------------- #
# Baseline: the newest activity that proves someone is still looking at this repo
# --------------------------------------------------------------------------- #

baseline_epoch=""
baseline_source="none"

note_baseline() {
    local epoch="$1" source="$2"
    [ -n "${epoch}" ] || return 0
    if [ -z "${baseline_epoch}" ] || [ "${epoch}" -gt "${baseline_epoch}" ]; then
        baseline_epoch="${epoch}"
        baseline_source="${source}"
    fi
}

# `creatordate` is the commit date for a lightweight tag and the tagger date for an
# annotated one, which is exactly "when this tag was made". `committerdate` looks like the
# right atom and is empty for annotated tags, so it would silently drop the heartbeat that
# this script itself just created.
while IFS=' ' read -r name epoch; do
    [ -n "${name}" ] || continue
    case "${name}" in
        heartbeat-*)
            note_baseline "${epoch}" "heartbeat tag ${name}"
            ;;
        *)
            # A bare `X.Y.Z` tag is one of our releases: the monthly heartbeat only has to
            # bridge the gap when nothing was released either.
            if printf '%s\n' "${name}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
                note_baseline "${epoch}" "release tag ${name}"
            fi
            ;;
    esac
done < <(git -C "${repo}" for-each-ref --format='%(refname:short) %(creatordate:unix)' refs/tags)

# The pin bump is the other moment the repository is known to be alive, and a checkout
# between two releases has activity but no release tag yet.
pin_epoch="$(git -C "${repo}" log -1 --format=%ct -- .github/upstream-pin.conf 2>/dev/null || true)"
note_baseline "${pin_epoch}" "pin commit"

days_since=""
if [ -n "${baseline_epoch}" ]; then
    days_since=$(( (now_epoch - baseline_epoch) / 86400 ))
    if [ "${days_since}" -lt 0 ]; then
        days_since=0
    fi
    ci_log "baseline: ${baseline_source}, ${days_since} days before ${now_date}"
else
    ci_log "no heartbeat, release or pin activity found: the first heartbeat is due"
fi

# --------------------------------------------------------------------------- #
# Decision
# --------------------------------------------------------------------------- #

tag_exists="false"
if git -C "${repo}" rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null; then
    tag_exists="true"
fi

if [ "${tag_exists}" = "true" ]; then
    action="skipped"
    reason="already-tagged"
elif [ -z "${baseline_epoch}" ]; then
    action="created"
    reason="first-heartbeat"
elif [ "${days_since}" -lt "${interval}" ]; then
    action="skipped"
    reason="too-soon"
else
    action="created"
    reason="due"
fi

if [ "${action}" = "created" ] && [ "${dry_run}" = "true" ]; then
    action="would-create"
fi

if [ "${action}" = "created" ]; then
    # An annotated tag needs an identity. The runner image and a bare laptop do not
    # always have one, and a heartbeat must never fail because of it: fall back to the
    # bot identity instead of erroring out on "unable to auto-detect email address".
    user_name="$(git -C "${repo}" config user.name 2>/dev/null || true)"
    user_email="$(git -C "${repo}" config user.email 2>/dev/null || true)"
    user_name="${user_name:-${CI_HEARTBEAT_USER_NAME:-github-actions[bot]}}"
    user_email="${user_email:-${CI_HEARTBEAT_USER_EMAIL:-github-actions[bot]@users.noreply.github.com}}"
    git -C "${repo}" -c "user.name=${user_name}" -c "user.email=${user_email}" \
        tag -a "${tag}" \
        -m "Heartbeat ${now_date}: scheduled upstream-watch is still alive (last activity: ${baseline_source}, ${days_since:-0} days before this heartbeat)."
    ci_log "created annotated tag ${tag} (not pushed; the workflow decides that)"
fi

ci_log "action ${action} (${reason})"
ci_emit_output "action" "${action}"
ci_emit_output "tag" "${tag}"
ci_emit_output "days_since" "${days_since}"
ci_emit_output "reason" "${reason}"
