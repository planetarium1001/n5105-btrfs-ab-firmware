#!/bin/sh
# evidence-audit.sh - is every acceptance criterion backed by a named piece of evidence?
#
# The PRD is the only place an `ac-N` is defined, and every one of them ends with a
# promise: "verify with `evidence:<name>`". That promise is what this script checks, and
# it checks nothing else. It does not judge whether the device did the right thing: it
# asks whether the record the verdict will be written from exists at all, under the name
# the PRD uses.
#
#   scripts/device/evidence-audit.sh                 # the whole table, one line per ac
#   scripts/device/evidence-audit.sh --task <id>     # this round's record, by name
#   scripts/device/evidence-audit.sh --quiet         # only the rows that are not covered
#   scripts/device/evidence-audit.sh --names-only    # ac<TAB>name of what is still open
#   scripts/device/evidence-audit.sh --strict        # evidence no ac names is a failure too
#
# Output, one line per ac, greppable and stable:
#
#   evidence-audit ac-1 status=covered evidence=ac1-release source=file file=ac1-release.md sha256=ok
#   evidence-audit ac-3 status=missing evidence=ac3-grow
#   evidence-audit ac-6 status=mismatch evidence=ac6-packages suspect=ac6-package
#   evidence-audit summary acs=14 covered=3 missing=11 mismatch=0 unchecked=0 absent=0 unused=0
#   evidence-audit result=gaps bad=11
#
# status= values:
#   covered     an evidence item carries the exact name the PRD asks for, and (file
#               evidence) the file is there with the recorded digest
#   missing     nothing carries that name, or the file it names is gone
#   mismatch    the PRD asks for `ac6-packages` and the record carries `ac6-package`: a
#               name that belongs to this ac and is not it, so a verdict citing the PRD's
#               name would cite evidence that does not exist
#   unchecked   the name is there but what it points at cannot be confirmed (no file in
#               the record, a digest that differs, or a command that exited non-zero)
#   absent      the PRD declares no such number, so this ac exists only in the numbering
#
# Exit status:
#   0  every ac is covered, and nothing is mismatch/unchecked/absent (or --strict and an
#      uncited evidence item exists)
#   1  at least one ac is missing/mismatch/unchecked/absent: the "do not write the
#      verdict yet" answer
#   2  the audit could not be made: bad usage, unreadable PRD, no `ac-N evidence:` line
#      parsed
#
# Two record files, one question. `.workflow/tasks/<id>/evidence.jsonl` holds *command*
# evidence (one JSON object per line: name, cmd, exit, work_hash), which is what
# `workflow verify --test` and the evidence hooks append. `.workflow/tasks/<id>/evidence/
# manifest.json` holds *file* evidence (name, file, sha256), which is what
# `workflow task evidence add --name <name>` writes - and that is the one an `ac-N` name is
# normally registered in. Both are read, and `source=from-file` / `source=from-command` says which
# one answered, so nobody has to guess where to look.
#
# A missing record file is not an error: a task that has registered nothing yet audits as
# "every ac missing" and exits 1. An unreadable PRD is an error, because without it there
# is no list to audit.
#
# Read-only by construction: every file here is opened for reading, and neither record file
# is written. Nothing in this script reaches a machine - there is no ssh here at all.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
: "${AB_REPO_ROOT:=$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# The task whose record is audited. There is no way to derive it from the tree: the prd.md
# under .workflow/tasks/ is the only list of acs, and several rounds keep one. So the id comes
# from the caller -- `--task`, else AB_AUDIT_TASK, else AB_TASK_ID (the name full-test.sh and
# the rest of the acceptance scripts use) -- and the last round's id is only the fallback for
# a run that names nothing. A fallback audit is announced on stderr, because a green table
# about another round's record is worse than no table at all.
LAST_ROUND_TASK=20261115-01-real-device-full-acceptance-0-1-0
TASK_ID=${AB_AUDIT_TASK:-${AB_TASK_ID:-${LAST_ROUND_TASK}}}
TASK_ID_IS_DEFAULT=1
if [ -n "${AB_AUDIT_TASK:-}" ] || [ -n "${AB_TASK_ID:-}" ]; then
    TASK_ID_IS_DEFAULT=0
fi
PRD_FILE=""
JSONL_FILE=""
MANIFEST_FILE=""
STRICT=0
QUIET=0
NAMES_ONLY=0
CHECK_SHA=1

say() { printf '%s\n' "$*"; }
die() { printf 'evidence-audit: %s\n' "$1" >&2; exit 2; }

usage() {
    cat <<'USAGE'
usage: evidence-audit.sh [--task <id>] [--root <dir>] [--prd <file>]
                         [--jsonl <file>] [--manifest <file>]
                         [--strict] [--quiet] [--names-only] [--no-sha]

  --task ID       task whose evidence is audited (default: AB_AUDIT_TASK, else AB_TASK_ID,
                  else the previous round's task - announced on stderr, never silent)
  --root DIR      repository root (default: two levels above this script)
  --prd FILE      the PRD that defines the acs (default: <root>/.workflow/tasks/<id>/prd.md)
  --jsonl FILE    command evidence (default: <root>/.workflow/tasks/<id>/evidence.jsonl)
  --manifest FILE file evidence (default: <root>/.workflow/tasks/<id>/evidence/manifest.json)
  --strict        evidence that no ac names also fails the run
  --quiet         print only the rows that are not covered, plus the summary
  --names-only    print "ac-N<TAB>evidence-name" for whatever is not covered, then exit 0
  --no-sha        do not recompute digests (presence only)
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --task) TASK_ID=${2:?--task needs a value}; TASK_ID_IS_DEFAULT=0; shift 2 ;;
        --root) AB_REPO_ROOT=${2:?--root needs a value}; shift 2 ;;
        --prd) PRD_FILE=${2:?--prd needs a value}; shift 2 ;;
        --jsonl) JSONL_FILE=${2:?--jsonl needs a value}; shift 2 ;;
        --manifest) MANIFEST_FILE=${2:?--manifest needs a value}; shift 2 ;;
        --strict) STRICT=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --names-only) NAMES_ONLY=1; shift ;;
        --no-sha) CHECK_SHA=0; shift ;;
        -h | --help | help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

TASK_DIR="${AB_REPO_ROOT}/.workflow/tasks/${TASK_ID}"
[ -n "${PRD_FILE}" ] || PRD_FILE="${TASK_DIR}/prd.md"
[ -n "${JSONL_FILE}" ] || JSONL_FILE="${TASK_DIR}/evidence.jsonl"
[ -n "${MANIFEST_FILE}" ] || MANIFEST_FILE="${TASK_DIR}/evidence/manifest.json"

# A defaulted task id is said out loud, once, on stderr: the caller asked for "the audit" and
# got the previous round's record, which is a fact about the record and not about this round.
if [ "${TASK_ID_IS_DEFAULT}" = "1" ] && [ "${NAMES_ONLY}" != "1" ]; then
    printf 'evidence-audit: no --task/AB_TASK_ID, auditing the previous round: %s\n' "${TASK_ID}" >&2
    printf 'evidence-audit: pass --task <id> (or AB_TASK_ID) to audit this round\n' >&2
fi

[ -f "${PRD_FILE}" ] || die "no PRD at ${PRD_FILE}: there is no list of acs to audit"
[ -r "${PRD_FILE}" ] || die "cannot read ${PRD_FILE}"

# --------------------------------------------------------------------------- #
# Reading the PRD
# --------------------------------------------------------------------------- #

# prd_acs <file>: one `ac-N<TAB>evidence-name` line per acceptance criterion.
#
# Only a bullet that carries a checkbox is an ac: the work-breakdown table further down
# names acs too ("| 01 | ... | ac-1 |"), and counting that row as a second ac-1 would
# report a duplicate where there is only a cross-reference. A bullet without an
# `evidence:` token still counts - that is an ac with no evidence contract, which is a
# finding, not a line to skip.
prd_acs() {
    awk '
        /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*ac-[0-9]+/ {
            line = $0
            ac = ""
            if (match(line, /ac-[0-9]+/)) {
                ac = substr(line, RSTART, RLENGTH)
            }
            name = ""
            if (match(line, /evidence:[A-Za-z0-9._-]+/)) {
                name = substr(line, RSTART + 9, RLENGTH - 9)
            }
            if (ac != "" && !(ac in seen)) {
                seen[ac] = 1
                printf "%s\t%s\n", ac, name
            }
        }
    ' "$1"
}

# prd_max_ac <file>: the highest ac number declared, so a hole can be named as a hole.
prd_max_ac() {
    awk '
        /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*ac-[0-9]+/ {
            if (match($0, /ac-[0-9]+/)) {
                n = substr($0, RSTART + 3, RLENGTH - 3) + 0
                if (n > max) max = n
            }
        }
        END { print max + 0 }
    ' "$1"
}

ACS=$(prd_acs "${PRD_FILE}")
[ -n "${ACS}" ] || die "no 'ac-N ... evidence:<name>' bullet in ${PRD_FILE}: nothing to audit"
AC_MAX=$(prd_max_ac "${PRD_FILE}")
AC_COUNT=$(printf '%s\n' "${ACS}" | grep -c .)

# --------------------------------------------------------------------------- #
# Reading the two record files
# --------------------------------------------------------------------------- #

# json_rows <file>: `name<TAB>file<TAB>sha256<TAB>exit` per object, whatever the layout.
#
# The two record files disagree about shape: manifest.json is one indented object with an
# `items` array, evidence.jsonl is one object per line. Both are cut into one token per
# line first (braces and commas become line breaks), so a single reader handles either.
# Values are split on the double quote, which is what makes this independent of indenting
# and of key order; a value that itself contained a brace or a comma would defeat it, and
# no evidence name, file name or digest does.
json_rows() {
    [ -f "$1" ] || return 0
    awk '
        function flush() {
            if (cur_name != "") {
                printf "%s\t%s\t%s\t%s\n", cur_name, cur_file, cur_sha, cur_exit
            }
            cur_name = ""
            cur_file = ""
            cur_sha = ""
            cur_exit = ""
        }

        function handle(l,   t, np, f, key, val) {
            t = l
            sub(/^[ \t]+/, "", t)
            sub(/[ \t]+$/, "", t)
            if (t == "") return
            if (t == "{") { flush(); return }
            if (t == "}") { flush(); return }
            if (substr(t, 1, 1) == ",") return
            if (substr(t, 1, 1) != "\"") return
            np = split(t, f, "\"")
            if (np < 4) return
            key = f[2]
            val = f[4]
            if (key == "name") cur_name = val
            else if (key == "file") cur_file = val
            else if (key == "sha256") cur_sha = val
            else if (key == "exit") cur_exit = val
        }

        BEGIN { cur_name = ""; cur_file = ""; cur_sha = ""; cur_exit = "" }
        {
            s = $0
            gsub(/\{/, "\n{\n", s)
            gsub(/\}/, "\n}\n", s)
            gsub(/,/, "\n,\n", s)
            n = split(s, parts, "\n")
            for (i = 1; i <= n; i++) handle(parts[i])
        }
        END { flush() }
    ' "$1"
}

FILE_ROWS=$(json_rows "${MANIFEST_FILE}")
CMD_ROWS=$(json_rows "${JSONL_FILE}")
ALL_ROWS="${FILE_ROWS}
${CMD_ROWS}"

# pick <rows> <name>: the first row whose name is exactly <name>.
pick() {
    printf '%s\n' "$1" | awk -F'\t' -v want="$2" '$1 == want { print; exit }'
}

# names_of <rows>: the name column, one per line.
names_of() { printf '%s\n' "$1" | awk -F'\t' 'NF && $1 != "" { print $1 }'; }

# ac_name <ac-N>: the evidence name the PRD declares for it, or a marker when the PRD
# does not declare that number at all.
ac_name() {
    printf '%s\n' "${ACS}" | awk -F'\t' -v want="$1" '
        $1 == want { print "DECLARED:" $2; found = 1; exit }
        END { if (!found) print "MISSING-NUMBER" }
    '
}

# digest <file>: sha256, or non-zero when this host has no tool for it.
digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
        return 0
    fi
    return 1
}

# --------------------------------------------------------------------------- #
# The audit
# --------------------------------------------------------------------------- #

if [ "${NAMES_ONLY}" != "1" ]; then
    say "evidence-audit task=${TASK_ID} acs=${AC_COUNT}"
    say "evidence-audit prd=${PRD_FILE}"
    say "evidence-audit jsonl=${JSONL_FILE}"
    say "evidence-audit manifest=${MANIFEST_FILE}"
fi

n_covered=0
n_missing=0
n_mismatch=0
n_unchecked=0
n_absent=0
n_open=0
cited=""

# One pass, in ac order: every number from 1 to the highest declared is either declared
# (and audited) or a hole. The holes are printed where they belong instead of after the
# table, so the output can be read top to bottom as the PRD reads.
i=1
while [ "${i}" -le "${AC_MAX}" ]; do
    ac="ac-${i}"
    i=$((i + 1))

    declared=$(ac_name "${ac}")
    if [ "${declared}" = "MISSING-NUMBER" ]; then
        n_absent=$((n_absent + 1))
        n_open=$((n_open + 1))
        [ "${NAMES_ONLY}" = "1" ] && { printf '%s\t-\n' "${ac}"; continue; }
        say "evidence-audit ${ac} status=absent note=the-prd-declares-no-such-ac"
        continue
    fi
    want=${declared#DECLARED:}

    if [ -z "${want}" ]; then
        n_missing=$((n_missing + 1))
        n_open=$((n_open + 1))
        [ "${NAMES_ONLY}" = "1" ] && { printf '%s\t-\n' "${ac}"; continue; }
        say "evidence-audit ${ac} status=missing evidence=- note=the-prd-declares-no-evidence-name"
        continue
    fi
    cited="${cited}${cited:+,}${want}"

    row=""
    ev_source=""
    row=$(pick "${FILE_ROWS}" "${want}")
    if [ -n "${row}" ]; then
        ev_source=from-file
    else
        row=$(pick "${CMD_ROWS}" "${want}")
        [ -n "${row}" ] && ev_source=from-command
    fi

    if [ -z "${row}" ]; then
        # A name that belongs to this ac and is not it: `ac6-package` for `ac6-packages`,
        # or a file registered under its own stem. Reported as a mismatch rather than a
        # plain miss, because the fix is a rename, not another run on the machine.
        prefix=${want%%-*}
        suspect=$(names_of "${ALL_ROWS}" \
            | awk -v p="${prefix}-" -v w="${want}" 'index($0, p) == 1 && $0 != w { print; exit }')

        if [ -n "${suspect}" ]; then
            n_mismatch=$((n_mismatch + 1))
            n_open=$((n_open + 1))
            [ "${NAMES_ONLY}" = "1" ] && { printf '%s\t%s\n' "${ac}" "${want}"; continue; }
            say "evidence-audit ${ac} status=mismatch evidence=${want} suspect=${suspect}"
            say "evidence-audit hint ${ac}: rename it: ./.workflow/bin/workflow task evidence add <file> --name ${want} --force"
        else
            n_missing=$((n_missing + 1))
            n_open=$((n_open + 1))
            [ "${NAMES_ONLY}" = "1" ] && { printf '%s\t%s\n' "${ac}" "${want}"; continue; }
            say "evidence-audit ${ac} status=missing evidence=${want}"
            say "evidence-audit hint ${ac}: ./.workflow/bin/workflow task evidence add <file> --name ${want}"
        fi
        continue
    fi

    # The name is there. What it points at decides whether it is proof or a label.
    r_file=$(printf '%s\n' "${row}" | cut -f2)
    r_sha=$(printf '%s\n' "${row}" | cut -f3)
    r_exit=$(printf '%s\n' "${row}" | cut -f4)

    verdict=covered
    sha_field=""
    detail=""
    if [ "${ev_source}" = "from-file" ]; then
        path="${TASK_DIR}/evidence/${r_file}"
        if [ -z "${r_file}" ]; then
            verdict=unchecked
            detail="note=the-record-names-no-file"
        elif [ ! -f "${path}" ]; then
            verdict=missing
            detail="note=the-recorded-file-is-gone"
        elif [ "${CHECK_SHA}" != "1" ]; then
            detail="note=sha256-not-checked"
        elif [ -z "${r_sha}" ]; then
            verdict=unchecked
            detail="note=the-record-carries-no-digest"
        elif have=$(digest "${path}"); then
            if [ "${have}" = "${r_sha}" ]; then
                sha_field="sha256=ok"
            else
                verdict=unchecked
                sha_field="recorded_sha256=${r_sha}"
                detail="note=sha256-differs actual=${have}"
            fi
        else
            detail="note=no-sha256-tool-on-this-host"
        fi
    else
        # Command evidence carries an exit code and no file. A non-zero exit is a command
        # that failed, which is not the same thing as evidence that something held.
        if [ -n "${r_exit}" ] && [ "${r_exit}" != "0" ]; then
            verdict=unchecked
            detail="note=the-command-exited-${r_exit}"
        else
            detail="note=command-evidence-only nothing-to-weigh-by-digest"
        fi
    fi

    case "${verdict}" in
        covered) n_covered=$((n_covered + 1)) ;;
        missing) n_missing=$((n_missing + 1)); n_open=$((n_open + 1)) ;;
        unchecked) n_unchecked=$((n_unchecked + 1)); n_open=$((n_open + 1)) ;;
    esac

    if [ "${NAMES_ONLY}" = "1" ]; then
        [ "${verdict}" = "covered" ] || printf '%s\t%s\n' "${ac}" "${want}"
        continue
    fi
    if [ "${QUIET}" = "1" ] && [ "${verdict}" = "covered" ]; then
        continue
    fi
    line="evidence-audit ${ac} status=${verdict} evidence=${want} source=${ev_source}"
    [ -n "${r_file}" ] && line="${line} file=${r_file}"
    [ -n "${sha_field}" ] && line="${line} ${sha_field}"
    [ -n "${detail}" ] && line="${line} ${detail}"
    say "${line}"
done

# Evidence no ac names. Not a failure by default: a task runs commands for its own sake.
# --strict makes it one, because a record nobody cites is usually a name typed by hand.
unused=""
for n in $(names_of "${ALL_ROWS}" | sort -u); do
    case ",${cited}," in
        *",${n},"*) : ;;
        *) unused="${unused}${unused:+,}${n}" ;;
    esac
done
n_unused=0
if [ -n "${unused}" ]; then
    n_unused=$(printf '%s\n' "${unused}" | tr ',' '\n' | grep -c .)
fi

n_bad=${n_open}
if [ "${STRICT}" = "1" ]; then
    n_bad=$((n_bad + n_unused))
    [ "${NAMES_ONLY}" = "1" ] || [ "${n_unused}" -eq 0 ] \
        || say "evidence-audit strict: ${n_unused} evidence item(s) no ac names: ${unused}"
fi

[ "${NAMES_ONLY}" = "1" ] && exit 0

say "evidence-audit summary acs=${AC_COUNT} covered=${n_covered} missing=${n_missing} mismatch=${n_mismatch} unchecked=${n_unchecked} absent=${n_absent} unused=${n_unused}"

if [ "${n_bad}" -gt 0 ]; then
    say "evidence-audit result=gaps open=${n_bad}"
    say "evidence-audit next: an ac whose evidence is not named cannot be cited by the verdict;"
    say "evidence-audit next: the rows above are that list, in the PRD's own order"
    exit 1
fi

say "evidence-audit result=covered"
exit 0
