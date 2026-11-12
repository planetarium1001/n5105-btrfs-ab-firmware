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
#   pin <version>              move .github/upstream-pin.conf to <version>
#   pr-body --out <file>       render the body of the automatic pull request
#   issue-body --out <file>    render the body of the failure issue
#
# Inputs (environment):
#   CI_UPSTREAM_INDEX     local copy of the `releases/` index (tests; skips the download)
#   CI_UPSTREAM_BASE      mirror root (default: https://downloads.immortalwrt.org)
#   CI_UPSTREAM_VERSION   version for `pin` when it is not passed as an argument
#   CI_UPSTREAM_PIN_FILE  pin file (default: .github/upstream-pin.conf)
#   CI_WORK_DIR           scratch directory (default: $CI_TMP_ROOT/upstream-watch)
#   CI_MIN_UPSTREAM_MAJOR lowest supported upstream major (default: 25)
#   CI_FORCE_VERSION      rehearsal only: treat this formal release as the new one, even
#                         when the index has something newer (validated like the pin)
#   CI_MATRIX_CANDIDATES, CI_MATRIX_GAPS, CI_RUN_URL, CI_AUTO_FAILED_STAGE,
#   CI_AUTO_REASON, CI_LOG_ARTIFACT, CI_PREVIOUS_PIN, CI_CURRENT_PIN
#                         values rendered into pr-body / issue-body
#   GITHUB_OUTPUT, CI_OUTPUT_ENV
#                         where ci_emit_output writes
#
# Outputs:
#   detect:  changed, version, current_pin, latest_formal, formal_versions
#   pin:     previous_pin, pinned_version, pin_file
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
    local formal_versions line
    work="${CI_WORK_DIR:-${CI_TMP_ROOT}/upstream-watch}"
    mkdir -p "${work}"
    formal_list="${work}/formal-descending.txt"

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

    current_pin="$(ci_upstream_pin_read)"
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
    if [ -n "${CI_FORCE_VERSION:-}" ]; then
        require_formal_version "${CI_FORCE_VERSION}" "forced upstream version"
        if [ "${CI_FORCE_VERSION}" = "${current_pin}" ]; then
            ci_die "the forced version ${CI_FORCE_VERSION} is already the pin; nothing to rehearse"
        fi
        ci_log "forced upstream version ${CI_FORCE_VERSION} (pin ${current_pin})"
        changed="true"
        version="${CI_FORCE_VERSION}"
    fi

    ci_emit_output "changed" "${changed}"
    ci_emit_output "version" "${version}"
    ci_emit_output "current_pin" "${current_pin}"
    ci_emit_output "latest_formal" "${latest_formal}"
    ci_emit_output "formal_versions" "${formal_versions}"
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
    [ -n "${candidates}" ] || candidates="无（索引里没有更早的正式版）"
    gap="${CI_MATRIX_GAPS:-}"
    case "${gap}" in
        "" | 0) gap="无" ;;
    esac
    run_url="${CI_RUN_URL:-未记录}"

    {
        printf '# 上游 %s（pin %s → %s）\n' "${version}" "${previous_pin}" "${version}"
        printf '\n'
        printf '本 PR 由每日 cron 自动创建：`upstream-watch.yml` 在同一个 run 里构建、复验、合并、\n'
        printf '打 tag 并发布，人工只负责事后 review 这次 squash 提交。\n'
        printf '\n'
        printf '## 改动\n'
        printf '\n'
        printf '| 文件 | 本次写入 |\n'
        printf '| --- | --- |\n'
        printf '| `.github/upstream-pin.conf` | `UPSTREAM_VERSION=%s` → `UPSTREAM_VERSION=%s` |\n' \
            "${previous_pin}" "${version}"
        printf '| `scripts/ci/kmod-closure.json` | 派生为 upstream `%s` 的 kmod 闭包 |\n' "${version}"
        printf '| `scripts/ci/runtime-closure.json` | 派生为 upstream `%s` 的运行时闭包 |\n' "${version}"
        printf '| `scripts/ci/initramfs-tools.lock.json` | 派生为 upstream `%s` 的 initramfs-tools 锁 |\n' "${version}"
        printf '\n'
        printf '改动集合只有上面四个文件。`merge` 阶段的 diff 守卫对越界改动直接失败，所以\n'
        printf '构建所用的输入和合并进去的输入是同一份。\n'
        printf '\n'
        printf '## 矩阵候选\n'
        printf '\n'
        printf '`%s`\n' "${candidates}"
        printf '\n'
        printf '缺口：%s\n' "${gap}"
        printf '\n'
        printf '## 运行\n'
        printf '\n'
        printf -- '- run: %s\n' "${run_url}"
        printf '\n'
        printf '## 回滚\n'
        printf '\n'
        printf '删除 `auto/upstream-%s` 分支并 revert 这次 squash 提交即可回到上一个 pin；\n' "${version}"
        printf 'tag 与 release 按版本号删除即可撤销发布。\n'
    } >"${out}"
    ci_log "pr body: ${out}"
}

issue_body_cmd() {
    local out version stage reason run_url artifact
    out="$(parse_out_arg issue-body "$@")"
    version="${CI_UPSTREAM_VERSION:-${CI_PINNED_VERSION:-}}"
    if [ -z "${version}" ]; then
        version="$(ci_upstream_pin_read)"
    fi
    stage="${CI_AUTO_FAILED_STAGE:-unknown stage}"
    reason="${CI_AUTO_REASON:-见 run 日志}"
    run_url="${CI_RUN_URL:-未记录}"
    artifact="${CI_LOG_ARTIFACT:-ci-logs}"

    {
        printf '# [auto-release] 上游 %s 自动发布失败\n' "${version}"
        printf '\n'
        printf '| 项 | 值 |\n'
        printf '| --- | --- |\n'
        printf '| 上游版本 | `%s` |\n' "${version}"
        printf '| 失败 job | `%s` |\n' "${stage}"
        printf '| 原因 | %s |\n' "${reason}"
        printf '| run | %s |\n' "${run_url}"
        printf '| 日志 artifact | `%s` |\n' "${artifact}"
        printf '\n'
        printf '本次 run 已经停止：**未合并、未打 tag、未发布**。分支 `auto/upstream-%s` 与 PR\n' "${version}"
        printf '保持打开，pin 未改动，下一天的 cron 会重新检测同一个版本；修好失败的 stage 后，\n'
        printf '同一条 Issue（标题固定）会被下一次失败更新，而不是每天新增一条。\n'
    } >"${out}"
    ci_log "issue body: ${out}"
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
