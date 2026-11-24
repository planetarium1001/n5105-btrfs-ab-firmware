#!/bin/sh
# Schedule health: is the daily upstream watch still enabled?
#
# GitHub disables a scheduled workflow in a public repository after 60 days without
# repository activity. The keepalive line in .github/keepalive.log is how this repository
# tries to stay inside that window, and this script is how a run says out loud when the
# attempt failed: a disabled watch is a silent auto-release outage, and no build, test or
# release step would ever notice it.
#
# It answers one question through the API, and the exit status is the answer:
#   0  state=active    the schedule is on
#   1  state=disabled  it is not: the job fails so the run page says why
#   2  an error        gh, its credentials or the API answered nothing usable
#
# Exit 2 rather than 1 for the error case on purpose: "the watch is disabled" and "we could
# not ask" are different facts, and a red run has to say which one happened.
#
# Usage: schedule-health.sh [--workflow NAME] [--repo OWNER/NAME]
#
# Inputs (environment):
#   GITHUB_REPOSITORY    owner/name, set by Actions; --repo overrides it
#   GH_TOKEN             the credential gh reads (Actions sets it from secrets.GITHUB_TOKEN)
#   GITHUB_STEP_SUMMARY  when set, a disabled schedule also appends a run-page block
#
# This file is POSIX sh on purpose (the runner's /bin/sh is dash, the suite's portability
# guard parses it with dash), which is also why it does not source scripts/ci/lib.sh.

set -eu


sh_log() {
    printf '[schedule-health] %s\n' "$*"
}

sh_error() {
    printf '[schedule-health] ERROR: %s\n' "$*" >&2
}

sh_usage() {
    cat <<'USAGE'
usage: schedule-health.sh [--workflow NAME] [--repo OWNER/NAME]

  --workflow NAME   workflow file name to inspect (default: upstream-watch.yml)
  --repo OWNER/NAME repository to inspect (default: $GITHUB_REPOSITORY)
USAGE
}

sh_workflow="upstream-watch.yml"
sh_repo="${GITHUB_REPOSITORY:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workflow)
            [ "$#" -ge 2 ] || { sh_usage >&2; sh_error "--workflow needs a file name"; exit 2; }
            sh_workflow="$2"
            shift 2
            ;;
        --workflow=*)
            sh_workflow="${1#--workflow=}"
            shift
            ;;
        --repo)
            [ "$#" -ge 2 ] || { sh_usage >&2; sh_error "--repo needs owner/name"; exit 2; }
            sh_repo="$2"
            shift 2
            ;;
        --repo=*)
            sh_repo="${1#--repo=}"
            shift
            ;;
        -h | --help | help)
            sh_usage
            exit 0
            ;;
        *)
            sh_usage >&2
            sh_error "unknown argument: $1"
            exit 2
            ;;
    esac
done

case "${sh_workflow}" in
    '' | */*) sh_error "--workflow takes a file name, not a path: ${sh_workflow}"; exit 2 ;;
esac
case "${sh_repo}" in
    */*/* | /* | */ | '') sh_error "the repository has to be owner/name: ${sh_repo:-<empty>}"; exit 2 ;;
    */*) : ;;
    *) sh_error "the repository has to be owner/name (set GITHUB_REPOSITORY): ${sh_repo}"; exit 2 ;;
esac

if ! command -v gh >/dev/null 2>&1; then
    sh_error "gh is not on PATH; the schedule state is read through the API"
    exit 2
fi

# `--jq .state` asks the API for the one field this check is about. The error output is
# captured with the value so a failure names what gh actually said instead of only "no
# state".
if ! sh_api_state=$(gh api "repos/${sh_repo}/actions/workflows/${sh_workflow}" --jq .state 2>&1); then
    sh_error "gh api failed: $(printf '%s' "${sh_api_state}" | tr '\n' ' ')"
    exit 2
fi

sh_state=$(printf '%s' "${sh_api_state}" | tr -d '[:space:]')
case "${sh_state}" in
    active)
        sh_log "state=active: ${sh_workflow} is enabled in ${sh_repo}"
        printf 'state=%s\n' "${sh_state}"
        exit 0
        ;;
    '')
        sh_error "the API answered no state for ${sh_workflow}"
        exit 2
        ;;
    *)
        # Anything that is not `active` is not running on a schedule: `disabled_inactivity`
        # is the one this repository is exposed to, and treating an unknown value as healthy
        # would hide exactly the case the check exists for.
        printf 'state=%s\n' "disabled"
        sh_error "${sh_workflow} in ${sh_repo} is '${sh_state}', not active: the daily watch does not run"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            {
                printf '## Schedule disabled\n\n'
                printf 'The daily upstream watch (`%s`) is **%s**, so it does not run.\n\n' \
                    "${sh_workflow}" "${sh_state}"
                printf 'A disabled schedule is a silent auto-release outage. Re-enable it:\n\n'
                printf '```sh\n'
                printf 'gh workflow enable %s --repo %s\n' "${sh_workflow}" "${sh_repo}"
                printf '```\n\n'
                printf 'If GitHub disabled it for inactivity, the keepalive line in\n'
                printf '`.github/keepalive.log` is the mechanism that should have prevented it:\n'
                printf 'check that the `keepalive` job of the same workflow is still green.\n'
            } >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null ||
                sh_error "could not append to GITHUB_STEP_SUMMARY"
        fi
        exit 1
        ;;
esac
