#!/usr/bin/env bash
# Shared POSIX-portability guard: the local half of the "the gate was green where it was
# written and red where it ran" class of CI failure.
#
# Why this exists: `sh` is not the same shell on the machine that writes a script and on
# the machine that runs the gate. On macOS /bin/sh is bash 3.2 in POSIX mode - it parses
# `<<<`, ${BASH_SOURCE[0]}, `set -o pipefail` and ${var/pat/repl} without a word - while
# the Ubuntu runner's /bin/sh is dash, which rejects them. The 2026-11-19 incident was
# exactly that: scripts/device/apk-protection-probe.sh's here-string passed `sh -n` on a
# laptop and the ubuntu-latest runner answered "Syntax error: redirection unexpected" only
# after the push. A second shape found the same day was a ${last/old/new} inside a
# `#!/bin/sh` heredoc handed to `sh` by a test: nothing under scripts/ carried it, so a scan
# of the device scripts alone would have stayed green.
#
# This file is the single definition of the patterns, so the device test, the ci test and
# any future caller cannot drift apart. It is a test helper sourced by bash tests; it is
# not itself linted as sh (it spells every pattern it hunts - a `pipefail` inside a regex
# would match its own file), and it is written to parse under bash 3.2 like every test.
#
# API - all functions take paths, print to stdout and return 0 unless noted:
#   sp_dialect <file>          sh | bash | empty, from the shebang line, not from the suffix
#   sh_files <dir>             every file under <dir> whose shebang names a POSIX sh
#   bashism_hits <file>        "line:text" per non-comment line carrying a bash-only
#                              construct; empty output means clean
#   sh_heredoc_bodies <file>   "file:line:text" per non-comment line of a `#!/bin/sh`
#                              heredoc body (the second incident shape above)
#   shell_portability_check [root]
#                              the whole guard: scan, grade, `dash -n`, bash 3.2 `-n`.
#                              Prints ok/report:/fail:/skip: lines and one summary line;
#                              returns 1 when a graded file is bad, 0 otherwise.
#
# Environment (used by shell_portability_check, and by tests that simulate a host):
#   SHELL_PORTABILITY_DASH   dash binary to parse with. Unset: `dash` from PATH.
#                            "none": the dash parse is skipped with a skip: line.
#   SHELL_PORTABILITY_BASH   the bash to parse bash scripts with, i.e. the bash 3.2 probe.
#                            Unset: /bin/bash, else `bash` from PATH. "none": the parse is
#                            skipped with a skip: line. Any other value is used as given,
#                            which is how a test simulates an old or a new host; a binary
#                            that reports a version other than 3.2 itself answers skip:.
#
# Grading: a violation under scripts/ or tests/ is a failure (those are the files this
# repository owns and CI lints); one under initramfs/ or platform/ is printed as report:
# and does not fail, because those layers are shipped and audited elsewhere. `report:` is
# not a soft pass: it is printed on every run and a reader can grep it. A shell that
# refuses to parse a file is graded the same way as a pattern hit: `dash -n` and the bash
# 3.2 `-n` are gates, not log lines.

# --------------------------------------------------------------------------- #
# The patterns
#
# One entry per construct that is a bashism, chosen so the scan does not fire on the POSIX
# code this repository actually writes:
#   <<<                     here-string, a parse error in dash (the 2026-11-19 incident)
#   BASH_SOURCE             bash-only variable; dash expands it to nothing, and the caller
#                           silently loses its own directory
#   pipefail                `set -o pipefail` is a runtime failure in dash
#   \bdeclare\b             bash builtin, word-bounded so "declares" in prose does not match
#   (^|[^\\])\[\[[[:space:]]  `[[` at the start of a word with a space after it, so neither
#                           the POSIX `[[:space:]]` class nor an awk regex matching a
#                           literal bracket (`\[[ xX]\]`) matches
#   ${var/pat/repl}         bash parameter substitution (the 2026-11-19 heredoc incident)
#   ${var^^} / ${var,,}     bash 4 case conversion: dash parses it and fails at run time
#                           with "Bad substitution", so a `dash -n` check cannot see it
# Deliberately absent: `function` (dash refuses it at parse time, so `dash -n` already
# covers it, while a scan would fire on awk programs), `local` (dash has it), `source` and
# `&>` (a runtime failure in the first case, noisy in strings in the second; their tests
# are the scripts' own tests). Comment lines are skipped everywhere: a comment is allowed
# to name the construct it warns against, which is how the rewritten probe explains itself.
sp_bashism_re='<<<|BASH_SOURCE|pipefail|\bdeclare\b|(^|[^\\])\[\[[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*/[^}]|\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)'

# Directories that are not the repository, pruned by the find in shell_portability_check:
# build outputs, tool caches, and the workflow store (which carries archived copies of old
# scripts, intentionally full of history). Kept as one list here and spelled out in the find
# call there, so a reader of either place sees the same names.
#
#   .git .workflow .workflow-backup-* .venv node_modules payloads __pycache__ .dsh .out

# --------------------------------------------------------------------------- #
# Inspection
# --------------------------------------------------------------------------- #

# sp_first_line <file>: the shebang line, read with a builtin so a tree walk of a few
# hundred files does not fork a `head` per file. A binary file answers "" or a truncated
# first line, which is all the dialect test needs.
sp_first_line() {
    local line=""
    IFS= read -r line <"${1:-/dev/null}" 2>/dev/null || true
    printf '%s' "${line}"
}

# sp_dialect <file>: the shell the shebang names. A suffix is not evidence: the suite has
# `.sh` files in both dialects and extensionless files in both as well.
sp_dialect() {
    local first
    first="$(sp_first_line "${1:-}")"
    case "${first}" in
        '#!'*'/bin/sh'* | '#!'*'/dash'* | '#!'*'env sh'*) printf 'sh\n' ;;
        '#!'*'bash'*) printf 'bash\n' ;;
        *) printf '\n' ;;
    esac
}

# sh_files <dir>: every file under <dir> whose shebang names POSIX sh, sorted.
sh_files() {
    local dir="${1:-.}" path
    [ -d "${dir}" ] || return 0
    find "${dir}" -type f -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r path; do
        [ "$(sp_dialect "${path}")" = "sh" ] && printf '%s\n' "${path}"
    done
}

# bashism_hits <file>: one "line:text" per non-comment line carrying a bash-only construct.
# Empty output means the file is clean by this scan; that is the pass condition callers use.
bashism_hits() {
    local file="${1:?bashism_hits requires a file}"
    grep -nE "${sp_bashism_re}" "${file}" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# sh_heredoc_bodies <file>: print the non-comment lines of every heredoc body whose first
# line is `#!/bin/sh`, as "file:line:text". A heredoc is a program of its own: it runs under
# dash on the runner whatever the file carrying it says, and the file around it is often a
# bash script that may use every bashism. Only the body is printed, with its line number in
# the carrying file, so a caller can report the exact place to look.
sh_heredoc_bodies() {
    awk '
        state == 0 && /<<[-]?["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?:?$/ {
            tag = $0
            sub(/.*<<[-]?"?/, "", tag)
            sub(/["'"'"'].*/, "", tag)
            body = 0
            state = 1
            next
        }
        state == 1 {
            if ($0 == tag) { state = 0; next }
            if (body == 0) {
                if ($0 ~ /^#![ \t]*\/bin\/sh/) body = 1
                else { state = 0; next }
                next
            }
            # A comment is allowed to name what it warns against.
            if ($0 !~ /^[ \t]*#/) print FILENAME ":" FNR ":" $0
            next
        }
    ' "${1:?sh_heredoc_bodies requires a file}"
}

# --------------------------------------------------------------------------- #
# Host probing
# --------------------------------------------------------------------------- #

# sp_version_of <binary>: a one-line version string, or "version unknown". dash has no
# --version on Debian/Ubuntu or on macOS, so the probe falls back to the variables the
# shell itself exports, then to the package manager. It never fails the caller: the version
# string is for the log, not a gate.
sp_version_of() {
    local bin="${1:?sp_version_of requires a binary}" out=""
    out="$("${bin}" --version 2>/dev/null | head -n 1 || true)"
    case "${out}" in
        *[Ii]llegal* | *[Ii]nvalid* | *[Nn]ot*[Ff]ound*) out="" ;;
    esac
    if [ -z "${out}" ]; then
        out="$("${bin}" -c 'printf "%s" "${BASH_VERSION:-}${DASH_VERSION:-}"' 2>/dev/null || true)"
    fi
    # Only a shell that is a dash has its version in the dash package. Asking dpkg for it
    # when the binary is a bash would label bash with a dash version.
    case "${bin##*/}" in
        dash | sh)
            if [ -z "${out}" ] && command -v dpkg-query >/dev/null 2>&1; then
                out="$(dpkg-query -W -f='${Version}' dash 2>/dev/null || true)"
            fi
            ;;
    esac
    printf '%s\n' "${out:-version unknown}"
}

# sp_version_number <version string>: the numeric part, for comparing a bash against 3.2.
sp_version_number() {
    printf '%s' "${1:-}" | sed -n 's/.*[Vv]ersion \([0-9][0-9.]*\).*/\1/p'
}

# --------------------------------------------------------------------------- #
# Grading helpers
# --------------------------------------------------------------------------- #

# sp_grade <repo-relative path>: fail for the files this repository owns, report for the
# shipped layers (see the header).
sp_grade() {
    case "${1:-}" in
        scripts/* | tests/*) printf 'fail\n' ;;
        *) printf 'report\n' ;;
    esac
}

# sp_note <grade> <repo-relative path> <line> <text>: print one violation and count it.
# The counters are globals (_sp_failures, _sp_reports) because the caller is a loop in the
# same shell: subshell counters would never come back.
sp_note() {
    local grade="$1" rel="$2" line="$3" text="${4:-}"
    if [ "${grade}" = "fail" ]; then
        _sp_failures=$((_sp_failures + 1))
        printf 'fail: %s:%s: %s\n' "${rel}" "${line}" "${text}"
    else
        _sp_reports=$((_sp_reports + 1))
        printf 'report: %s:%s: %s\n' "${rel}" "${line}" "${text}"
    fi
}

# sp_scan_text <grade> <rel> <hits>: turn `bashism_hits` output into graded lines. A hit is
# "line:text"; both halves survive because only the first colon is split on.
sp_scan_text() {
    local grade="$1" rel="$2" hits="$3" entry line text
    [ -n "${hits}" ] || return 0
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        line="${entry%%:*}"
        text="${entry#*:}"
        sp_note "${grade}" "${rel}" "${line}" "bash-only construct: ${text}"
    done <<<"${hits}"
}

# sp_sh_linted_mismatches <root>: the files scripts/ci/verify.sh lints with the sh shell
# (its init_scripts list) that declare a different interpreter. The list mirrors that
# section of verify.sh on purpose: the guard has to check the files the gate reads as sh,
# and the test asserts these directories still appear in verify.sh.
sp_sh_linted_mismatches() {
    local root="${1:-.}" module path first
    {
        find "${root}/initramfs" -type f ! -name '*.md' 2>/dev/null
        find "${root}/platform" -type f ! -name '*.md' ! -name 'platform-release' 2>/dev/null
        find "${root}/scripts/device" -maxdepth 1 -type f -name '*.sh' 2>/dev/null
        for module in image ab upgrade runtime release; do
            find "${root}/tests/modules/${module}" -maxdepth 1 -type f -name '*.sh' 2>/dev/null \
                | while IFS= read -r path; do
                    case "$(sp_first_line "${path}")" in
                        *bash*) ;;
                        *) printf '%s\n' "${path}" ;;
                    esac
                done
        done
    } | LC_ALL=C sort | while IFS= read -r path; do
        first="$(sp_first_line "${path}")"
        case "${first}" in
            '#!'*) [ "$(sp_dialect "${path}")" = "sh" ] || printf '%s\n' "${path}" ;;
        esac
    done
}

# --------------------------------------------------------------------------- #
# The whole guard
# --------------------------------------------------------------------------- #

shell_portability_check() {
    local root="${1:-.}"
    root="$(cd "${root}" 2>/dev/null && pwd)" || {
        printf 'fail: %s: not a directory\n' "${1:-.}"
        return 1
    }
    _sp_failures=0
    _sp_reports=0
    local skips=0 sh_count=0 bash_count=0
    local rel dialect path hits bodies ds entry line text
    local dash_bin bash_bin dash_version bash_version bash_number verdict
    local dash_resolved bash_resolved
    local sh_list="" bash_list=""

    # A wrong root used to print a clean summary: the scan found nothing, so nothing was
    # wrong. Name it instead of blessing it.
    if [ ! -d "${root}/scripts" ] && [ ! -d "${root}/tests" ] \
        && [ ! -d "${root}/initramfs" ] && [ ! -d "${root}/platform" ]; then
        printf 'fail: %s: no scripts/, tests/, initramfs/ or platform/ under this root\n' "${root}"
        return 1
    fi

    # ----------------------------------------------------------------------- #
    # 1. Read the tree: every file whose shebang names a shell. The pruned names are not
    #    the repository (see "Directories that are not the repository" above), so a green
    #    run means the files this repository ships were scanned.
    # ----------------------------------------------------------------------- #
    while IFS=$'\t' read -r dialect path; do
        [ -n "${path}" ] || continue
        rel="${path#"${root}"/}"
        verdict="$(sp_grade "${rel}")"
        if [ "${dialect}" = "sh" ]; then
            sh_count=$((sh_count + 1))
            sh_list="${sh_list}${path}
"
            hits="$(bashism_hits "${path}")"
            sp_scan_text "${verdict}" "${rel}" "${hits}"
        else
            bash_count=$((bash_count + 1))
            bash_list="${bash_list}${path}
"
            bodies="$(sh_heredoc_bodies "${path}")"
            [ -n "${bodies}" ] || continue
            # Only a body line carrying one of the patterns is a violation: the body is a sh
            # program, and most of it is ordinary POSIX sh.
            bodies="$(printf '%s\n' "${bodies}" | grep -E "${sp_bashism_re}" || true)"
            [ -n "${bodies}" ] || continue
            while IFS= read -r entry; do
                [ -n "${entry}" ] || continue
                # entries are "file:line:text"; the file is the one being scanned.
                ds="${entry#"${path}":}"
                line="${ds%%:*}"
                text="${ds#*:}"
                sp_note "${verdict}" "${rel}" "${line}" "bash-only construct in a sh heredoc: ${text}"
            done <<<"${bodies}"
        fi
    done < <(
        # `find` prunes the directories that are not the repository; the loop then asks each
        # remaining file for its shebang. Tab-separated so a path may hold spaces.
        find "${root}" \
            \( -name .git -o -name .workflow -o -name '.workflow-backup-*' -o -name .venv \
                -o -name node_modules -o -name payloads -o -name __pycache__ -o -name .dsh \
                -o -name .out \) -prune \
            -o -type f -print 2>/dev/null \
            | LC_ALL=C sort \
            | while IFS= read -r candidate; do
                candidate_dialect="$(sp_dialect "${candidate}")"
                [ -n "${candidate_dialect}" ] && printf '%s\t%s\n' "${candidate_dialect}" "${candidate}"
            done
    )

    # ----------------------------------------------------------------------- #
    # 2. `dash -n` on every sh file: this is the CI dialect, so it gates the files this
    #    repository owns. Where dash is missing the check says so instead of pretending.
    # ----------------------------------------------------------------------- #
    dash_bin="${SHELL_PORTABILITY_DASH:-}"
    if [ "${dash_bin}" = "none" ]; then
        dash_bin=""
        skips=$((skips + 1))
        printf 'skip: SHELL_PORTABILITY_DASH=none; dash -n did not run\n'
    elif [ -z "${dash_bin}" ]; then
        dash_bin="$(command -v dash 2>/dev/null || true)"
        if [ -z "${dash_bin}" ]; then
            skips=$((skips + 1))
            printf 'skip: dash not found; dash -n did not run (set SHELL_PORTABILITY_DASH)\n'
        fi
    else
        # A bare name ("dash") is resolved through PATH like the auto-detected one, so the
        # log line and the -x test below see the binary, not a word.
        dash_resolved="$(command -v "${dash_bin}" 2>/dev/null || true)"
        [ -z "${dash_resolved}" ] || dash_bin="${dash_resolved}"
    fi
    if [ -n "${dash_bin}" ] && [ ! -x "${dash_bin}" ]; then
        _sp_failures=$((_sp_failures + 1))
        printf 'fail: %s: the dash binary is not executable\n' "${dash_bin}"
        dash_bin=""
    fi
    if [ -n "${dash_bin}" ]; then
        dash_version="$(sp_version_of "${dash_bin}")"
        printf 'sh: %s (%s)\n' "${dash_bin}" "${dash_version}"
        while IFS= read -r path; do
            [ -n "${path}" ] || continue
            rel="${path#"${root}"/}"
            verdict="$(sp_grade "${rel}")"
            hits="$("${dash_bin}" -n "${path}" 2>&1)" || \
                sp_note "${verdict}" "${rel}" 1 \
                    "dash -n rejected this file: $(printf '%s\n' "${hits}" | head -n 1)"
        done <<<"${sh_list}"
    fi

    # ----------------------------------------------------------------------- #
    # 3. bash 3.2 `-n` on every bash file, when this host's bash is that old.
    #
    #    `#!/usr/bin/env bash` promises the file parses under the bash the reader has, and
    #    on macOS that is /bin/bash 3.2: a construct bash 4+ accepts - a here-document
    #    inside $( ), a `;;&` case arm, `&>>` - is a syntax error, and it is a syntax error
    #    for the whole file, reported on whatever token the parser tripped over. CI's
    #    own bash is 5.x, so the runner would never say so: this half of the guard is the
    #    one that runs on the laptop, and it is graded like the rest of the scan (fail under
    #    scripts/ or tests/, report under the shipped layers) instead of being prose in the
    #    log. Where the host bash is newer than 3.2 the question cannot be answered here,
    #    and the skip: line says exactly that; the same line appears when the probe is
    #    turned off or the binary is missing.
    # ----------------------------------------------------------------------- #
    bash_bin="${SHELL_PORTABILITY_BASH:-}"
    if [ "${bash_bin}" = "none" ]; then
        bash_bin=""
        skips=$((skips + 1))
        printf 'skip: SHELL_PORTABILITY_BASH=none; bash -n did not run\n'
    elif [ -z "${bash_bin}" ]; then
        if [ -x /bin/bash ]; then
            bash_bin=/bin/bash
        else
            bash_bin="$(command -v bash 2>/dev/null || true)"
        fi
        if [ -z "${bash_bin}" ]; then
            skips=$((skips + 1))
            printf 'skip: bash not found; bash -n did not run\n'
        fi
    else
        bash_resolved="$(command -v "${bash_bin}" 2>/dev/null || true)"
        [ -z "${bash_resolved}" ] || bash_bin="${bash_resolved}"
    fi
    # A nameless probe is a skip: line; a named one that cannot run is a failure, because
    # it was asked for and did not happen (same rule as the dash binary above).
    if [ -n "${bash_bin}" ] && [ ! -x "${bash_bin}" ]; then
        _sp_failures=$((_sp_failures + 1))
        printf 'fail: %s: the bash binary is not executable\n' "${bash_bin}"
        bash_bin=""
    fi
    if [ -n "${bash_bin}" ]; then
        bash_version="$(sp_version_of "${bash_bin}")"
        bash_number="$(sp_version_number "${bash_version}")"
        case "${bash_number}" in
            3.2*)
                printf 'bash: %s (%s)\n' "${bash_bin}" "${bash_number}"
                while IFS= read -r path; do
                    [ -n "${path}" ] || continue
                    rel="${path#"${root}"/}"
                    verdict="$(sp_grade "${rel}")"
                    hits="$("${bash_bin}" -n "${path}" 2>&1)" || \
                        sp_note "${verdict}" "${rel}" 1 \
                            "bash 3.2 cannot parse this file: $(printf '%s\n' "${hits}" | head -n 1)"
                done <<<"${bash_list}"
                ;;
            *)
                skips=$((skips + 1))
                printf 'skip: system bash is %s, not 3.2; bash -n did not run\n' "${bash_version}"
                ;;
        esac
    fi

    # ----------------------------------------------------------------------- #
    # 4. Shebang and lint dialect agree: a file the gate lints as sh must say sh.
    # ----------------------------------------------------------------------- #
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        rel="${path#"${root}"/}"
        sp_note "$(sp_grade "${rel}")" "${rel}" 1 \
            "shebang '$(sp_first_line "${path}")' but verify.sh lints this file with the sh shell"
    done < <(sp_sh_linted_mismatches "${root}")

    # ----------------------------------------------------------------------- #
    # 5. One verdict line a human (and a test) can grep.
    # ----------------------------------------------------------------------- #
    if [ "${_sp_failures}" -gt 0 ]; then
        printf 'shell portability: fail (%s sh file(s), %s bash file(s), %s report(s), %s skip(s), %s failure(s))\n' \
            "${sh_count}" "${bash_count}" "${_sp_reports}" "${skips}" "${_sp_failures}"
        return 1
    fi
    printf 'shell portability: ok (%s sh file(s), %s bash file(s), %s report(s), %s skip(s))\n' \
        "${sh_count}" "${bash_count}" "${_sp_reports}" "${skips}"
    return 0
}
