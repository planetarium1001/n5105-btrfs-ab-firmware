#!/usr/bin/env bash
# Module: ci
# The CI guest assertion is a test artefact, not part of the product.
#
# /s3-post.sh re-checks the composed root, writes probe files into the writable layer and
# powers the machine off when it disagrees. Until now every stage injected it
# unconditionally (ci-assemble.yml and ci-s3.yml listed it in CI_EXTRA_FILES), so the
# image that S3 publishes - the one a machine is flashed with - carried it too.
#
# ac-11 locks the replacement: the hook enters an initramfs only when the build sets
# AB_CI_HOOKS=1. The three assertions below are orthogonal on purpose, and each one is
# checked by running the workflow's own step body against a stub stage script, so what is
# asserted is the behaviour of the shell that GitHub would run and not a text pattern:
#   ac-11a unset   -> the extra-file list carries no /s3-post.sh at all
#   ac-11b AB_CI_HOOKS=1 -> it carries exactly one, and wf.sh is still there
#   ac-11c the injection names initramfs/boot/post.sh as source and /s3-post.sh as the
#          path inside the initramfs, which is the path initramfs/boot/init copies
#
# post.sh is checked here too, because the flag only decides whether the file is there:
#   ac-11d a copy that is called without the initramfs' arguments leaves the boot alone
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

assemble="$root/.github/workflows/ci-assemble.yml"
s3="$root/.github/workflows/ci-s3.yml"
post="$root/initramfs/boot/post.sh"

# step_extract <block|run> <workflow> <step>: the step's own YAML lines, or the body of
# its `run: |` block dedented. The workflows are read as text: no YAML parser is assumed
# to exist on the runner, and a step that stops being found is a test failure rather than
# an empty string.
step_extract() {
    python3 - "$1" "$2" "$3" <<'PY'
import re
import sys

mode, path, name = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines()

start = indent = None
for number, line in enumerate(lines):
    match = re.match(r"^(\s*)- name:\s*" + re.escape(name) + r"\s*$", line)
    if match:
        start, indent = number, len(match.group(1))
        break
if start is None:
    sys.exit(3)  # step not found

block = [lines[start]]
run_indent = None
body = []
for line in lines[start + 1:]:
    stripped = line.strip()
    here_indent = len(line) - len(line.lstrip(" "))
    if stripped.startswith("- ") and here_indent <= indent:
        break  # the next step
    block.append(line)
    if run_indent is None:
        match = re.match(r"^(\s*)run:\s*\|\s*$", line)
        if match:
            run_indent = len(match.group(1))
        continue
    if stripped and here_indent <= run_indent:
        run_indent = None  # the body ended before the step did
        continue
    body.append(line)

if mode == "block":
    sys.stdout.write("\n".join(block) + "\n")
    sys.exit(0)

# `run: |` may be the last key of a step that also ends the file.
if not body:
    sys.exit(4)  # step without a run block
while body and not body[-1].strip():
    body.pop()
common = min(
    (len(line) - len(line.lstrip(" ")) for line in body if line.strip()),
    default=0,
)
sys.stdout.write("\n".join(line[common:] if line.strip() else "" for line in body) + "\n")
PY
}

step_run() { step_extract run "$1" "$2"; }
step_block() { step_extract block "$1" "$2"; }

# step_flag <workflow> <step>: the AB_CI_HOOKS literal the step declares, if it does.
# A step that sets the flag is a CI build whatever the caller's environment says, so the
# behaviour test below applies it exactly as GitHub would.
step_flag() {
    step_block "$1" "$2" \
        | sed -n 's/^[[:space:]]*AB_CI_HOOKS:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' \
        | head -n 1
}

# The stub records what the step asked the stage script to inject, and fails on the two
# mistakes the real script would also refuse: an entry without <source>:<dest> and a
# source that does not exist.
mkdir -p "$tmp/scripts/ci"
cat >"$tmp/scripts/ci/initramfs.sh" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "${CI_EXTRA_FILES-}" >"${STUB_OUT:?}"
for spec in ${CI_EXTRA_FILES-}; do
    src="${spec%%:*}"
    dest="${spec#*:}"
    if [ "${src}" = "${spec}" ]; then
        echo "stub: entry without <source>:<dest>: ${spec}" >&2
        exit 1
    fi
    if [ ! -f "${src}" ]; then
        echo "stub: source does not exist: ${src}" >&2
        exit 1
    fi
    [ -n "${dest}" ] || { echo "stub: empty destination in ${spec}" >&2; exit 1; }
done
STUB

# run_step <workflow> <step> <AB_CI_HOOKS value, empty means unset> <tag> -> prints the
# step's recorded CI_EXTRA_FILES; non-zero when the step body itself fails. A flag the
# step declares itself wins over the caller's value, the same precedence GitHub applies to
# step env over job env.
run_step() {
    local workflow="$1" step="$2" flag="$3" tag="$4" body declared
    body="$(step_run "${workflow}" "${step}")" || {
        echo "step not found: ${step} in ${workflow##*/}"
        return 1
    }
    declared="$(step_flag "${workflow}" "${step}")"
    if [ -n "${declared}" ]; then
        flag="${declared}"
    fi
    (
        cd "$tmp" || exit 1
        unset AB_CI_HOOKS
        if [ -n "${flag}" ]; then
            export AB_CI_HOOKS="${flag}"
        fi
        export GITHUB_WORKSPACE="${root}"
        export RUNNER_TEMP="${tmp}/runner"
        export CI_LOG_DIR="${tmp}/logs"
        export GITHUB_OUTPUT="${tmp}/out-${tag}"
        export STUB_OUT="${tmp}/extra-${tag}"
        mkdir -p "${RUNNER_TEMP}" "${CI_LOG_DIR}"
        bash -c "${body}"
    ) || return 1
    cat "${tmp}/extra-${tag}"
}

wf_entry="${root}/initramfs/lib/wf.sh:/lib/wf.sh"
hook_entry="${root}/initramfs/boot/post.sh:/s3-post.sh"

# --------------------------------------------------------------------------- #
# ac-11a: unset means nothing is injected
# --------------------------------------------------------------------------- #

unset_extra="$(run_step "${assemble}" "Build the boot initramfs" "" "assemble-unset")" \
    || unset_extra="<step-failed>"
assert_eq "${unset_extra}" "${wf_entry}" \
    "ac-11a without AB_CI_HOOKS the assemble build injects wf.sh and nothing else"

unset_extra_s3="$(run_step "${s3}" "Build the boot initramfs" "" "s3-unset")" \
    || unset_extra_s3="<step-failed>"
assert_eq "${unset_extra_s3}" "${wf_entry}" \
    "ac-11a without AB_CI_HOOKS S3's production initramfs injects wf.sh and nothing else"

# --------------------------------------------------------------------------- #
# ac-11b: the flag turns the hook on, and only the hook
# --------------------------------------------------------------------------- #

set_extra="$(run_step "${assemble}" "Build the boot initramfs" "1" "assemble-set")" \
    || set_extra="<step-failed>"
assert_eq "${set_extra}" "${wf_entry} ${hook_entry}" \
    "ac-11b AB_CI_HOOKS=1 adds /s3-post.sh to the assemble build"

set_extra_s3="$(run_step "${s3}" "Build the CI assertion initramfs" "" "s3-hooks")" \
    || set_extra_s3="<step-failed>"
assert_eq "${set_extra_s3}" "${wf_entry} ${hook_entry}" \
    "ac-11b S3's assertion build injects /s3-post.sh because that step sets the flag"

assert_eq "$(printf '%s' "${set_extra_s3}" | grep -o ':/s3-post.sh' | wc -l | tr -d ' ')" "1" \
    "ac-11b the hook is injected exactly once"

# --------------------------------------------------------------------------- #
# ac-11c: the injection path is the one the initramfs reads back
# --------------------------------------------------------------------------- #

assert_file_exists "$root/initramfs/boot/post.sh" \
    "ac-11c the injected source exists"
assert_contains "${set_extra_s3}" "${root}/initramfs/boot/post.sh:/s3-post.sh" \
    "ac-11c the hook is injected from initramfs/boot/post.sh as /s3-post.sh"
hook_dest="$(printf '%s\n' "${set_extra_s3}" | tr ' ' '\n' \
    | sed -n 's|^.*/initramfs/boot/post\.sh:\(.*\)$|\1|p')"
assert_eq "${hook_dest}" "/s3-post.sh" \
    "ac-11c the destination inside the initramfs is exactly /s3-post.sh"
# initramfs/boot/init copies /s3-post.sh inside the initramfs; a different destination
# here would leave that copy failing with `|| wf_fail`, i.e. a boot that powers off.
assert_contains "$(cat "$root/initramfs/boot/init")" "/s3-post.sh" \
    "ac-11c the boot init reads the same path the injection writes"

# --------------------------------------------------------------------------- #
# ac-11d: a leftover copy does not act as the probe
# --------------------------------------------------------------------------- #

# The initramfs always passes <slot> <upper> <boot>. Anything else - a person typing the
# name, an init that runs whatever it finds, a copy left in an image - must not write a
# probe file, must not print a judge line and must not power the machine off. poweroff is
# stubbed so a regression is a failed assertion instead of a switched-off test machine.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/poweroff" <<'STUB'
#!/usr/bin/env bash
printf 'poweroff\n' >>"${STUB_POWEROFF_LOG:?}"
exit 1
STUB
chmod 0755 "$tmp/bin/poweroff"

call_without_arguments() {
    local tag="$1"
    shift
    (
        cd "$tmp" || exit 1
        export PATH="${tmp}/bin:${PATH}"
        export STUB_POWEROFF_LOG="${tmp}/poweroff-${tag}.log"
        bash "${post}" "$@"
    )
}

out="$(call_without_arguments "noargs")"
rc=$?
assert_eq "${rc}" "0" "ac-11d a call without arguments exits 0, the boot is unchanged"
assert_eq "$(printf '%s\n' "${out}" | grep -c 'S3-RESULT')" "0" \
    "ac-11d and prints no judge line for a boot it did not assert"
assert_contains "${out}" "not the CI probe entry" \
    "ac-11d and says why it did nothing"
assert_eq "$(cat "${tmp}/poweroff-noargs.log" 2>/dev/null || true)" "" \
    "ac-11d and never powers the machine off"
# The writable-layer probe is the thing that must not happen on a real machine, so the
# guard is checked structurally as well: it has to precede the first probe file.
assert_eq "$(awk '/not the CI probe entry/ { print "guard" } /^probe=/ { print "probe" }' "${post}" \
    | head -n 1)" "guard" \
    "ac-11d the entry guard sits above the first probe file in post.sh"

out="$(call_without_arguments "slot-only" "a")"
rc=$?
assert_eq "${rc}" "0" "ac-11d a call with a slot but no layer also exits 0"
assert_eq "$(printf '%s\n' "${out}" | grep -c 'S3-RESULT')" "0" \
    "ac-11d and prints no judge line"
assert_eq "$(cat "${tmp}/poweroff-slot-only.log" 2>/dev/null || true)" "" \
    "ac-11d and never powers the machine off"

# --------------------------------------------------------------------------- #
# The flag is declared where the injection is decided
# --------------------------------------------------------------------------- #

assert_contains "$(cat "${assemble}")" "AB_CI_HOOKS" \
    "ac-11 the assemble workflow names the flag that enables CI hooks"
assert_contains "$(cat "${s3}")" 'AB_CI_HOOKS: "1"' \
    "ac-11 S3 enables it explicitly on the assertion build only"
assert_eq "$(grep -c 'CI_EXTRA_FILES: ' "${assemble}" "${s3}" | grep -c ':0$')" "2" \
    "ac-11 neither workflow injects through a step-level CI_EXTRA_FILES list any more"

finish
