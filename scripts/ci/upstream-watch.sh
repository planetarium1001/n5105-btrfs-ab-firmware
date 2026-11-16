#!/usr/bin/env bash
# Upstream watch: discover the newest formal ImmortalWrt release, move the pin, and
# render the two bodies the daily workflow posts (auto-PR and failure issue).
#
# The discovery rule is the whole point of this script. The mirror's `releases/` index
# lists formal releases, release candidates, betas and `SNAPSHOT` side by side, and only
# an exact `X.Y.Z` directory is a release this platform can build from: a candidate or a
# snapshot produces an image nobody can reproduce a month later. Releases below upstream
# major 25 are dropped as well - the initramfs-tools lock and the kmods directory layout
# this pipeline verifies only exist from 25 on, so a 24.x branch can never be a base.
#
# Subcommands:
#   detect                     newest formal release vs. the pin, plus the candidate list
#   merge-state                the merge/tag state a failed or resumed run continues from
#   pin <version>              move .github/upstream-pin.conf to <version>
#   pr-body --out <file>       render the body of the automatic pull request
#   issue-body --out <file>    render the body of the failure issue
#
# Inputs (environment):
#   CI_UPSTREAM_INDEX     local copy of the `releases/` index (tests; skips the download)
#   CI_UPSTREAM_BASE      mirror root (default: https://downloads.immortalwrt.org)
#   CI_UPSTREAM_VERSION   version for `pin` / `merge-state`; also the release being recovered
#   CI_UPSTREAM_PIN_FILE  pin file (default: .github/upstream-pin.conf)
#   CI_WORK_DIR           scratch directory (default: $CI_TMP_ROOT/upstream-watch)
#   CI_MIN_UPSTREAM_MAJOR lowest supported upstream major (default: 25)
#   CI_FORCE_VERSION      rehearsal only: treat this formal release as the new one, even
#                         when the index has something newer (validated like the pin).
#                         When CI_RESUME is set it is the release being resumed, and it is
#                         required: a recovery never re-discovers what it is recovering.
#   CI_RESUME             empty (discover), or `merge` / `publish`: the stage a recovery
#                         dispatch continues from. Non-empty skips discovery and the
#                         "already the pin; nothing to rehearse" refusal.
#   CI_BASE               base branch whose pin and merge commit are inspected (default: main)
#   CI_PR                 pull request number, when the run still has one
#   CI_REMOTE_URL         git remote to read the tag state from; empty reads the local tags
#                         (the checkout fetches them, so no network is needed here)
#   CI_MATRIX_CANDIDATES, CI_MATRIX_GAPS, CI_RUN_URL, CI_AUTO_FAILED_STAGE,
#   CI_AUTO_REASON, CI_LOG_ARTIFACT, CI_PREVIOUS_PIN, CI_CURRENT_PIN, CI_MODE,
#   CI_RESUME_STAGE, CI_PIN_IN_BASE, CI_MERGED_SHA, CI_TAG_EXISTS, CI_TAG_SHA
#                         values rendered into pr-body / issue-body
#   GITHUB_OUTPUT, CI_OUTPUT_ENV
#                         where ci_emit_output writes
#
# Outputs:
#   detect:  changed, version, current_pin, latest_formal, formal_versions,
#            mode, resume_stage, pin_in_base, merged_sha, tag_exists, tag_sha
#   merge-state: pin_in_base, merged_sha, tag_exists, tag_sha, skip_merge, skip_tag
#   pin:     previous_pin, pinned_version, pin_file
#
# The merge state is the contract a failed run is recovered with. `merged_sha` is the
# merge commit the version's squash landed on, `tag_sha` the commit the remote tag points
# at (the peeled commit for an annotated tag). A tag that points anywhere else is a hard
# failure: tags are immutable here, and a force push would silently republish a release.
#
# The pin is written by ci_write_upstream_pin (scripts/ci/lib.sh) and by nothing else.
# This script never edits the pin file itself: one writer is what keeps the pin and the
# three derived locks from disagreeing about which upstream release they describe.

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init upstream-watch

CI_MIN_UPSTREAM_MAJOR="${CI_MIN_UPSTREAM_MAJOR:-25}"

usage() {
    cat <<'USAGE'
usage: upstream-watch.sh <subcommand>

  detect                     find the newest formal upstream release, compare it to the pin
  merge-state                report the pin, merge commit and tag state of one release
  pin <version>              move the pin to <version> (also reads CI_UPSTREAM_VERSION)
  pr-body --out <file>       render the automatic pull-request body
  issue-body --out <file>    render the failure-issue body
USAGE
}

# --------------------------------------------------------------------------- #
# Discovery
# --------------------------------------------------------------------------- #

# formal_releases_desc <index-file> <output-file>
#
# Write every formal release of <index-file> to <output-file>, newest first, one per
# line, and log everything that was dropped. Formal means an exact `X.Y.Z` directory:
# an `-rc`/`-beta` suffix, a two-part version or `SNAPSHOT` is a different artefact line.
# The extraction is kept identical to the copy in scripts/ci/matrix-select.sh, so the
# detection verdict and the matrix candidates describe the same releases; that copy skips
# the major filter below, because there an old release still counts as "available" while
# it can never fill a candidate slot.
formal_releases_desc() {
    local index_file="$1" out_file="$2"
    local work dirs unique versioned ascending raw version major
    work="$(dirname "${out_file}")"
    dirs="${work}/release-dirs.txt"
    unique="${work}/release-dirs-unique.txt"
    versioned="${work}/release-entries.txt"
    ascending="${work}/release-formal-ascending.txt"

    grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' "${index_file}" \
        | sed -e 's/^href="//' -e 's|/"$||' >"${dirs}" || true

    # Candidates and betas sit in the same index; name them once so the run log answers
    # "why not 25.13.0-rc1" without anyone opening the mirror.
    grep -oE 'href="[0-9][^"]*/"' "${index_file}" >"${versioned}" || true
    while IFS= read -r raw; do
        [ -n "${raw}" ] || continue
        raw="${raw#href=\"}"
        raw="${raw%/\"}"
        case "${raw}" in
            *[!0-9.]*) ci_log "ignored non-formal upstream entry ${raw}" ;;
        esac
    done <"${versioned}"

    LC_ALL=C sort -u "${dirs}" >"${unique}"
    : >"${ascending}"
    while IFS= read -r version; do
        [ -n "${version}" ] || continue
        major="${version%%.*}"
        if [ "${major}" -lt "${CI_MIN_UPSTREAM_MAJOR}" ]; then
            ci_log "excluded upstream release ${version}: major ${major} is below ${CI_MIN_UPSTREAM_MAJOR}"
            continue
        fi
        printf '%s\n' "${version}" >>"${ascending}"
    done <"${unique}"

    # Version order, then reversed: the newest formal release is the last line of the
    # ascending list and every consumer of this file wants it first.
    LC_ALL=C sort -uV "${ascending}" \
        | awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }' >"${out_file}"
}

# require_formal_version <version> [label]
#
# The pin goes through the same gate as the detector: one formal release, supported
# major, and never the word `latest` - a pin that says "latest" is a pin that builds a
# different release every morning.
require_formal_version() {
    local version="$1" label="${2:-upstream version}" major
    [ -n "${version}" ] || ci_die "${label} is empty"
    if [ "${version}" = "latest" ]; then
        ci_die "${label} must name one formal release (X.Y.Z), not 'latest'"
    fi
    ci_match "${version}" "${CI_VERSION_RE}" "${label}"
    major="${version%%.*}"
    if [ "${major}" -lt "${CI_MIN_UPSTREAM_MAJOR}" ]; then
        ci_die "${label} ${version} is below the supported upstream major ${CI_MIN_UPSTREAM_MAJOR} (${major}.x)"
    fi
}

detect_cmd() {
    local work index_path formal_list current_pin latest_formal version changed
    local formal_versions line resume resume_version base pin_in_base merged_sha
    local tag_exists tag_sha
    work="${CI_WORK_DIR:-${CI_TMP_ROOT}/upstream-watch}"
    mkdir -p "${work}"
    formal_list="${work}/formal-descending.txt"

    resume="${CI_RESUME:-}"
    case "${resume}" in
        "" | merge | publish) ;;
        *) ci_die "CI_RESUME must be empty, 'merge' or 'publish', got '${resume}'" ;;
    esac

    current_pin="$(ci_upstream_pin_read)"
    base="${CI_BASE:-main}"

    # A recovery is told which release it is recovering: it may not rediscover one, or a
    # resumed run that finds a newer mirror entry would silently rehearse a different
    # version than the one the failed run merged.
    if [ -n "${resume}" ]; then
        resume_version="${CI_FORCE_VERSION:-}"
        [ -n "${resume_version}" ] || ci_die "CI_RESUME=${resume} requires the release being resumed (CI_FORCE_VERSION / the dispatch version input)"
        require_formal_version "${resume_version}" "resumed upstream version"
        ci_log "resume ${resume}: version ${resume_version}, pin ${current_pin}, base ${base}"
        changed="true"
        version="${resume_version}"
        latest_formal=""
        formal_versions=""
        mode="resume"
    else
        if [ -n "${CI_UPSTREAM_INDEX:-}" ]; then
            [ -f "${CI_UPSTREAM_INDEX}" ] || ci_die "upstream index not found: ${CI_UPSTREAM_INDEX}"
            index_path="${CI_UPSTREAM_INDEX}"
            ci_log "index source: ${index_path}"
        else
            index_path="${work}/releases-index.html"
            ci_download "${CI_UPSTREAM_BASE}/releases/" "${index_path}"
        fi

        formal_releases_desc "${index_path}" "${formal_list}"

        latest_formal=""
        formal_versions=""
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            if [ -z "${latest_formal}" ]; then
                latest_formal="${line}"
            fi
            formal_versions="${formal_versions}${formal_versions:+ }${line}"
        done <"${formal_list}"

        ci_log "pin ${current_pin}, newest formal release ${latest_formal:-none}"

        if [ -z "${latest_formal}" ]; then
            ci_warn "the upstream index lists no formal release at ${CI_MIN_UPSTREAM_MAJOR}.x or newer; nothing to release"
            changed="false"
            version="${current_pin}"
        elif [ "${latest_formal}" = "${current_pin}" ]; then
            ci_log "pin already names the newest formal release; no update"
            changed="false"
            version="${current_pin}"
        elif [ "$(printf '%s\n%s\n' "${latest_formal}" "${current_pin}" | LC_ALL=C sort -V | tail -n 1)" != "${latest_formal}" ]; then
            # The pin is newer than anything the index offers: a pruned or lagging mirror, or a
            # pin bumped ahead of the mirror. Adopting it would downgrade the release, so it is
            # reported and nothing happens.
            ci_warn "the pin ${current_pin} is newer than the newest formal release ${latest_formal}; not downgrading"
            changed="false"
            version="${current_pin}"
        else
            ci_log "new formal release ${latest_formal} (pin ${current_pin})"
            changed="true"
            version="${latest_formal}"
        fi

        # A rehearsal names the release it wants to exercise. The value goes through the same
        # gate as the pin (one formal release, supported major), so a dispatch cannot make the
        # pipeline build an rc, a snapshot or a 24.x tree.
        #
        # "Already the pin" is refused *only* on the discovery path: on a recovery that is
        # exactly the state a merge leaves behind, and `resume=merge|publish` is how it gets
        # past this point. The guard is written out rather than left implicit in the enclosing
        # branch so that the refusal and its one exception are read together.
        if [ -n "${CI_FORCE_VERSION:-}" ]; then
            require_formal_version "${CI_FORCE_VERSION}" "forced upstream version"
            if [ -z "${resume}" ] && [ "${CI_FORCE_VERSION}" = "${current_pin}" ]; then
                ci_die "the forced version ${CI_FORCE_VERSION} is already the pin; nothing to rehearse (pass resume=merge or resume=publish to recover a release that already merged)"
            fi
            ci_log "forced upstream version ${CI_FORCE_VERSION} (pin ${current_pin})"
            changed="true"
            version="${CI_FORCE_VERSION}"
        fi
        mode="discover"
    fi

    # The recovery contract reads the same three facts whether this run discovered the
    # release or was sent to recover it. `resume` deliberately does *not* die on
    # "already the pin": that is exactly the state a failure after the merge leaves behind.
    pin_in_base="$(pin_in_base_of "${base}" || true)"
    merged_sha="$(merged_sha_of "${version}" || true)"
    tag_sha="$(tag_sha_of "${version}" || true)"
    tag_exists="false"
    [ -n "${tag_sha}" ] && tag_exists="true"
    [ -z "${merged_sha}" ] || [ "${tag_exists}" = "true" ] || ci_log "tag ${version} not pushed yet"

    ci_emit_output "mode" "${mode}"
    ci_emit_output "resume_stage" "${resume}"
    ci_emit_output "base" "${base}"
    ci_emit_output "pin_in_base" "${pin_in_base}"
    ci_emit_output "merged_sha" "${merged_sha}"
    ci_emit_output "tag_exists" "${tag_exists}"
    ci_emit_output "tag_sha" "${tag_sha}"
    ci_emit_output "changed" "${changed}"
    ci_emit_output "version" "${version}"
    ci_emit_output "current_pin" "${current_pin}"
    ci_emit_output "latest_formal" "${latest_formal}"
    ci_emit_output "formal_versions" "${formal_versions}"
}

# --------------------------------------------------------------------------- #
# Merge state
#
# The three facts a failed run is resumed from, and the two skips the merge job is allowed
# to take. Everything here is read-only: it answers "where did this release stop" without
# touching the branch, the pin or a tag.
# --------------------------------------------------------------------------- #

# pin_in_base_of <base>: the pin the base branch carries, or empty when the base branch
# cannot be read. It is the authority on "the merge happened", not the local tree: a
# recovery dispatch is started from the base branch, and the merge job fetches it.
pin_in_base_of() {
    local base="$1" content=""
    [ -n "${base}" ] || return 0
    content="$(git -C "${CI_REPO_ROOT}" show "origin/${base}:.github/upstream-pin.conf" 2>/dev/null || true)"
    if [ -z "${content}" ]; then
        content="$(git -C "${CI_REPO_ROOT}" show "${base}:.github/upstream-pin.conf" 2>/dev/null || true)"
    fi
    [ -n "${content}" ] || return 0
    printf '%s\n' "${content}" | sed -n 's/^UPSTREAM_VERSION=//p' | tail -n 1
}

# merged_sha_of <version>: the commit the version's squash landed on, empty when no pull
# request can be found. `gh pr view --json mergeCommit` is the API's answer; when the run
# has no pull-request number (a recovery dispatch, whose bump job does not re-open one),
# the same number is looked up by the deterministic branch name instead.
#
# CI_MERGED_SHA overrides both: it is how a test (or a fully offline reproduction) supplies
# the fact the API would have answered, and an empty GH_TOKEN skips the API altogether so a
# run without credentials reports "unknown" instead of hanging on a network call.
merged_sha_of() {
    local version="$1" pr="${CI_PR:-}" branch="${CI_BRANCH:-auto/upstream-${1}}" sha=""
    if [ -n "${CI_MERGED_SHA:-}" ]; then
        printf '%s' "${CI_MERGED_SHA}"
        return 0
    fi
    [ -n "${GH_TOKEN:-}" ] || return 0
    if [ -n "${pr}" ] && [ "${pr}" != "null" ]; then
        sha="$(gh pr view "${pr}" --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null || true)"
    fi
    if [ -z "${sha}" ]; then
        sha="$(gh pr list --head "${branch}" --state all --json mergeCommit \
            --jq '[.[] | .mergeCommit.oid // empty][0] // ""' 2>/dev/null || true)"
    fi
    [ "${sha}" != "null" ] || sha=""
    printf '%s' "${sha}"
}

# tag_sha_of <version>: the commit the remote tag points at, peeled for an annotated tag.
# Reading the tag from the remote rather than from the checkout is what separates "this
# run did not fetch it" from "it does not exist"; the workflow fetches tags too, so a local
# repository (a laptop, a test fixture) answers from its own refs without any network.
tag_sha_of() {
    local version="$1" remote="${CI_REMOTE_URL:-}" listing="" sha=""
    if [ -n "${remote}" ]; then
        listing="$(git ls-remote --tags "${remote}" "refs/tags/${version}" "refs/tags/${version}^{}" 2>/dev/null || true)"
        # The peeled line is the commit; the unpeeled line of an annotated tag is the tag object.
        sha="$(printf '%s\n' "${listing}" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
        if [ -z "${sha}" ]; then
            sha="$(printf '%s\n' "${listing}" | awk '$2 !~ /\^\{\}$/ { print $1; exit }')"
        fi
    else
        # `^{commit}` peels an annotated tag; a lightweight tag needs no peeling, and the
        # revision syntax answers for both.
        sha="$(git -C "${CI_REPO_ROOT}" rev-parse --verify --quiet "refs/tags/${version}^{commit}" 2>/dev/null || true)"
    fi
    printf '%s' "${sha}"
}

merge_state_cmd() {
    local version="${1:-${CI_UPSTREAM_VERSION:-}}" base="${CI_BASE:-main}"
    local pin_in_base merged_sha tag_sha tag_exists skip_merge skip_tag
    [ -n "${version}" ] || ci_die "merge-state requires a version (argument or CI_UPSTREAM_VERSION)"
    require_formal_version "${version}" "upstream version"

    pin_in_base="$(pin_in_base_of "${base}" || true)"
    merged_sha="$(merged_sha_of "${version}" || true)"
    tag_sha="$(tag_sha_of "${version}" || true)"
    tag_exists="false"
    [ -n "${tag_sha}" ] && tag_exists="true"

    # skip-merge: base already pins this version, so the squash landed and merging again
    # would either fail or re-merge the same change.
    skip_merge="false"
    [ "${pin_in_base}" = "${version}" ] && skip_merge="true"

    # skip-tag: the tag exists and names the merge commit, which makes a re-run idempotent.
    # A tag that exists and names anything else is a hard failure here: tags are immutable
    # in this repository and a force push would republish a release nobody rebuilt.
    skip_tag="false"
    if [ "${tag_exists}" = "true" ]; then
        if [ -z "${merged_sha}" ]; then
            ci_warn "tag ${version} is already pushed as ${tag_sha}, but no merge commit is known; leaving the tag alone"
            skip_tag="true"
        elif [ "${tag_sha}" = "${merged_sha}" ]; then
            ci_log "tag ${version} already names the merge commit ${merged_sha}"
            skip_tag="true"
        else
            ci_die "tag ${version} points at ${tag_sha}, not at the merge commit ${merged_sha}: tags are immutable, refusing to force one"
        fi
    fi

    ci_log "merge state: base pin ${pin_in_base:-<unreadable>}, merge commit ${merged_sha:-<unknown>}, tag ${version} exists=${tag_exists} sha=${tag_sha:-<none>}"
    ci_emit_output "pin_in_base" "${pin_in_base}"
    ci_emit_output "merged_sha" "${merged_sha}"
    ci_emit_output "tag_exists" "${tag_exists}"
    ci_emit_output "tag_sha" "${tag_sha}"
    ci_emit_output "skip_merge" "${skip_merge}"
    ci_emit_output "skip_tag" "${skip_tag}"
}

# --------------------------------------------------------------------------- #
# Pin
# --------------------------------------------------------------------------- #

pin_cmd() {
    local version="${1:-${CI_UPSTREAM_VERSION:-}}" previous_pin
    [ -n "${version}" ] || ci_die "pin requires a version (argument or CI_UPSTREAM_VERSION)"
    require_formal_version "${version}" "upstream version"
    previous_pin="$(ci_upstream_pin_read)"
    if [ "${previous_pin}" = "${version}" ]; then
        ci_log "pin already at ${version}"
    fi
    # The only write path: lib.sh owns the file format, the comment block and the atomic
    # replace, and it is the single place the rest of the tree reads the value from.
    ci_write_upstream_pin "${version}"
    ci_emit_output "previous_pin" "${previous_pin}"
    ci_emit_output "pinned_version" "${version}"
    ci_emit_output "pin_file" "$(ci_upstream_pin_file)"
}

# --------------------------------------------------------------------------- #
# Rendered bodies
# --------------------------------------------------------------------------- #

# body_out <subcommand> [arguments...]: parse the --out destination of a body renderer.
parse_out_arg() {
    local sub="$1" out="" arg
    shift
    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "${arg}" in
            --out)
                [ "$#" -ge 2 ] || ci_die "${sub}: --out needs a file"
                out="$2"
                shift 2
                ;;
            --out=*)
                out="${arg#--out=}"
                shift
                ;;
            *)
                ci_die "${sub}: unknown argument '${arg}'"
                ;;
        esac
    done
    [ -n "${out}" ] || ci_die "${sub} requires --out <file>"
    printf '%s\n' "${out}"
}

pr_body_cmd() {
    local out version previous_pin candidates gap run_url
    out="$(parse_out_arg pr-body "$@")"
    version="${CI_UPSTREAM_VERSION:-${CI_PINNED_VERSION:-}}"
    [ -n "${version}" ] || ci_die "pr-body requires CI_UPSTREAM_VERSION"
    # After `pin` the file already holds the new value, so the previous one has to come
    # from the step outputs: `detect` emits current_pin, `pin` emits previous_pin.
    previous_pin="${CI_PREVIOUS_PIN:-${CI_CURRENT_PIN:-}}"
    if [ -z "${previous_pin}" ]; then
        previous_pin="$(ci_upstream_pin_read)"
    fi
    candidates="${CI_MATRIX_CANDIDATES:-}"
    [ -n "${candidates}" ] || candidates="none (the index lists no earlier formal release)"
    gap="${CI_MATRIX_GAPS:-}"
    case "${gap}" in
        "" | 0) gap="none" ;;
    esac
    run_url="${CI_RUN_URL:-not recorded}"

    {
        printf '# Upstream %s (pin %s -> %s)\n' "${version}" "${previous_pin}" "${version}"
        printf '\n'
        printf 'Created by the daily upstream-watch run, which built this commit, merged it, tagged it\n'
        printf 'and published the release in the same run. Review the squash commit afterwards;\n'
        printf 'nothing waits on you.\n'
        printf '\n'
        printf '## Changes\n'
        printf '\n'
        printf '| file | written this run |\n'
        printf '| --- | --- |\n'
        printf '| `.github/upstream-pin.conf` | `UPSTREAM_VERSION=%s` -> `UPSTREAM_VERSION=%s` |\n' \
            "${previous_pin}" "${version}"
        printf '| `scripts/ci/kmod-closure.json` | kernel module closure, derived for `%s` |\n' \
            "${version}"
        printf '| `scripts/ci/runtime-closure.json` | runtime closure, derived for `%s` |\n' \
            "${version}"
        printf '| `scripts/ci/initramfs-tools.lock.json` | initramfs-tools lock, derived for `%s` |\n' \
            "${version}"
        printf '\n'
        printf 'Exactly these four files change. The `merge` job fails on any diff outside them, so\n'
        printf 'the inputs that were built are the inputs that were merged.\n'
        printf '\n'
        printf '## Matrix candidates\n'
        printf '\n'
        printf '`%s`\n' "${candidates}"
        printf '\n'
        printf 'Gap: %s\n' "${gap}"
        printf '\n'
        printf '## Run\n'
        printf '\n'
        printf '%s\n' "${run_url}"
        printf '\n'
        printf '## Rollback\n'
        printf '\n'
        printf 'Revert the squash commit to restore the previous pin; the `auto/upstream-%s`\n' \
            "${version}"
        printf 'branch can be deleted.\n'
    } >"${out}"
    ci_log "pr body: ${out}"
}

issue_body_cmd() {
    local out version stage reason run_url artifact pin
    local mode resume_stage pin_in_base merged_sha tag_exists tag_sha post_merge
    out="$(parse_out_arg issue-body "$@")"
    version="${CI_UPSTREAM_VERSION:-${CI_PINNED_VERSION:-}}"
    if [ -z "${version}" ]; then
        version="$(ci_upstream_pin_read)"
    fi
    stage="${CI_AUTO_FAILED_STAGE:-unknown}"
    reason="${CI_AUTO_REASON:-see the run log}"
    run_url="${CI_RUN_URL:-not recorded}"
    artifact="${CI_LOG_ARTIFACT:-ci-logs}"
    pin="$(ci_upstream_pin_read)"
    mode="${CI_MODE:-discover}"
    resume_stage="${CI_RESUME_STAGE:-}"
    pin_in_base="${CI_PIN_IN_BASE:-}"
    merged_sha="${CI_MERGED_SHA:-}"
    tag_exists="${CI_TAG_EXISTS:-false}"
    tag_sha="${CI_TAG_SHA:-}"

    # Two recovery scripts, because the reversible half of the run has two halves. Before
    # the merge the pin still names the old release and the only fix is to re-run; after
    # the merge the pin has moved and the tag may already be pushed, and a re-run must not
    # pretend it can start over.
    post_merge="false"
    if [ "${pin_in_base}" = "${version}" ] || [ "${tag_exists}" = "true" ]; then
        post_merge="true"
    fi

    # No heading: the issue title is `[auto-release] <version>` and is also the key that
    # keeps one issue per version, so repeating the version here would say it twice.
    {
        printf 'The daily run detected upstream `%s` (pin `%s`) and could not finish.\n' \
            "${version}" "${pin}"
        if [ "${post_merge}" = "true" ]; then
            printf 'The merge has already happened: it is **not** safe to assume nothing was touched.\n'
        else
            printf 'Nothing was merged, tagged or published.\n'
        fi
        printf '\n'
        printf '| field | value |\n'
        printf '| --- | --- |\n'
        printf '| stage | `%s` |\n' "${stage}"
        printf '| reason | %s |\n' "${reason}"
        printf '| run | %s |\n' "${run_url}"
        printf '| artifact | `%s` |\n' "${artifact}"
        printf '| mode | `%s` |\n' "${mode}"
        if [ -n "${resume_stage}" ]; then
            printf '| resume stage | `%s` |\n' "${resume_stage}"
        fi
        printf '| base pin | `%s` |\n' "${pin_in_base:-unreadable}"
        printf '| merge commit | `%s` |\n' "${merged_sha:-unknown}"
        printf '| tag pushed | `%s`%s |\n' "${tag_exists}" \
            "${tag_sha:+ at \`${tag_sha}\`}"
        printf '\n'

        if [ "${post_merge}" = "true" ]; then
            printf '## Recovery: the merge already happened\n'
            printf '\n'
            printf 'The squash landed on `%s` and the base branch pins `%s`, so a plain\n' \
                "${merged_sha:-the base branch}" "${version}"
            printf 're-run cannot start over. Pick one of the two scripts below; both are\n'
            printf 'idempotent, so repeating a step that already succeeded is safe.\n'
            printf '\n'
            printf '**Script A - finish the release.** Keep the merge and the tag, re-run only the\n'
            printf 'publishing half. This is the right choice when only `publish` failed.\n'
            printf '\n'
            printf '```\ngh workflow run upstream-watch.yml -f version=%s -f resume=publish\n```\n' \
                "${version}"
            printf '\n'
            printf 'It skips discovery, reuses the merged pin and the pushed tag, and does not\n'
            printf 'merge or tag again. Safe to repeat: the tag is compared with the merge\n'
            printf 'commit, and an existing tag that names a different commit fails hard rather\n'
            printf 'than being moved.\n'
            printf '\n'
            printf '**Script B - start over.** Only when the merge itself has to be redone (the\n'
            printf 'squash is wrong, or the tag must be replaced). Delete the tag first, revert the\n'
            printf 'squash, then dispatch a normal run:\n'
            printf '\n'
            printf '```\ngh release delete %s --yes --cleanup-tag\n' "${version}"
            printf 'git revert --no-edit %s\n' "${merged_sha:-<the squash commit>}"
            printf 'gh workflow run upstream-watch.yml -f version=%s\n' "${version}"
            printf '```\n'
            printf '\n'
            printf 'Deleting a published tag is a deliberate, manual act: this workflow never\n'
            printf 'deletes or force-pushes a tag, and `resume=merge` refuses a tag that exists.\n'
        else
            printf '## Recovery: nothing was merged yet\n'
            printf '\n'
            printf 'The base branch still pins `%s` (it has not moved to `%s`), so the run can be\n' \
                "${pin}" "${version}"
            printf 'repeated from the start. A recovery dispatch does not rediscover the release\n'
            printf 'and does not refuse because the version was already the pin.\n'
            printf '\n'
            printf '```\ngh workflow run upstream-watch.yml -f version=%s -f resume=merge\n```\n' \
                "${version}"
            printf '\n'
            printf 'Idempotency: the branch push uses `--force-with-lease`, the lockfiles steps are\n'
            printf 'no-ops when they already describe the release, and the merge stops when the base\n'
            printf 'branch already carries the pin.\n'
        fi
        printf '\n'
        printf '## Next\n'
        printf '\n'
        printf '1. Open the run and read the failing stage log.\n'
        printf '2. Fix the cause (a code fix lands on `%s` before the recovery dispatch).\n' "${GITHUB_REF_NAME:-main}"
        printf '3. Run the recovery script above; then re-check the issue and close it.\n'
    } >"${out}"
    ci_log "issue body: ${out} (post_merge=${post_merge})"
}

# --------------------------------------------------------------------------- #
# Entry
# --------------------------------------------------------------------------- #

subcommand="${1:-}"
if [ "$#" -gt 0 ]; then
    shift
fi

case "${subcommand}" in
    detect) detect_cmd "$@" ;;
    merge-state) merge_state_cmd "$@" ;;
    pin) pin_cmd "$@" ;;
    pr-body) pr_body_cmd "$@" ;;
    issue-body) issue_body_cmd "$@" ;;
    -h | --help | help) usage ;;
    "")
        usage >&2
        ci_die "upstream-watch.sh requires a subcommand"
        ;;
    *)
        usage >&2
        ci_die "unknown subcommand: ${subcommand}"
        ;;
esac

ci_log "upstream-watch ${subcommand} finished"
