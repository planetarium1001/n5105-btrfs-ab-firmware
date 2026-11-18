#!/usr/bin/env bash
# Module: device
# ac-9: one release's own package feeds, probed and judged without a device.
#
# The rise chain (25.12.0 -> 25.12.1 -> 25.12.2) installs community packages at every hop,
# and each hop needs the package source of *the release it is on*: the kmods directory is
# named after that release's kernel (<kernel>-1-<build hash>), so a feed list pointed at
# another release answers 404 for exactly the packages the hop exists to install. This file
# is the offline half of that: the answers are replayed by a stub fetcher, so the verdicts
#
#   ac-9  seven fetchable apk indexes are a PASS, and the list that is printed is the seven
#         URLs a machine would be given;
#   ac-9  one index that answers 404 is a FAIL that names the feed;
#   ac-9  a 200 that is not an index (an anti-bot page) is a FAIL, never a PASS;
#   ac-9  a workstation without a fetcher - or one whose every URL went unanswered - is a
#         GAP: nothing was asked, so nothing may be blamed;
#   ac-9  the kmods segment is read from the release's own directory page and never
#         assembled, and a page that lists none or several is a GAP with kmod=unknown and
#         --kmod as the way out;
#   ac-9  --dry-run prints the URLs and contacts nothing at all.
#
# The stub `curl` is the whole network: it maps a URL to a status and a body. Nothing here
# reaches the internet, and no device is touched - the driver has no ssh in it.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

probe="$root/scripts/device/feed-history.sh"
stub_bin="$tmp/bin"
calls="$tmp/calls"
mkdir -p "$stub_bin"
: >"$calls"

MIRROR="https://mirror.test"
RELEASE="25.12.0"
# The kmods directory 25.12.0 really has (measured 2026-11-19). It is the value a stub page
# carries, and the string every assertion about "the segment was read" looks for.
SEGMENT="6.12.87-1-bd81971a1c3f0490e17f340fe09229ea"

cat >"$stub_bin/curl" <<'STUB'
#!/bin/sh
# The fetcher, answered from the environment. Every case in this file is a replayed answer:
# a status, a body, or nothing at all.
body=""
prev=""
for arg in "$@"; do
    case "${prev}" in
        -o) body=${arg} ;;
    esac
    prev=${arg}
done
url=""
for arg in "$@"; do url=${arg}; done
printf '%s\n' "${url}" >>"${STUB_CALLS:?}"

code=200
if [ -n "${STUB_BAD_URL:-}" ]; then
    case "${url}" in
        *"${STUB_BAD_URL}"*) code=${STUB_BAD_CODE:-404} ;;
    esac
fi
if [ -n "${STUB_CODE:-}" ]; then
    code=${STUB_CODE}
fi
if [ -n "${body}" ]; then
    :
else
    body=/dev/null
fi
case "${url}" in
    */kmods/)
        if [ -n "${STUB_KMODS_DIR_CODE:-}" ]; then
            code=${STUB_KMODS_DIR_CODE}
        fi
        if [ -n "${STUB_KMODS_BODY:-}" ]; then
            page=${STUB_KMODS_BODY}
        else
            page="<a href=\"${STUB_SEGMENT}/\">${STUB_SEGMENT}/</a>"
        fi
        printf '%s\n' "${page}" >"${body}"
        ;;
    *)
        if [ -n "${STUB_HTML_URL:-}" ]; then
            case "${url}" in
                *"${STUB_HTML_URL}"*) printf '<html>are you a robot</html>\n' >"${body}" ;;
                *) printf 'ADBd\000\000\000\000' >"${body}" ;;
            esac
        else
            printf 'ADBd\000\000\000\000' >"${body}"
        fi
        ;;
esac
if [ "${code}" = "000" ]; then
    # What curl does on a timeout: no code on stdout, a non-zero status on the way out.
    printf '000'
    exit 28
fi
printf '%s' "${code}"
STUB
chmod +x "$stub_bin/curl"

# run_probe [VAR=VALUE...] -- <release and flags>: the probe through the stub fetcher. `env`
# rather than a function-level assignment, so a case can add one STUB_* variable to one run
# and the next run cannot inherit it.
probe_args=(--mirror "$MIRROR")
run_probe() {
    env PATH="$stub_bin:$PATH" STUB_CALLS="$calls" STUB_SEGMENT="$SEGMENT" "$@"
}

# repos_block <output>: the lines between the markers - the bytes a person pastes into
# /etc/apk/repositories.d/customfeeds.list.
repos_block() {
    printf '%s\n' "$1" |
        sed -n '/^feed-history repositories begin$/,/^feed-history repositories end$/p' |
        sed -e '1d' -e '$d'
}

# calls_to <pattern>: how many requests the stub was asked for, optionally only the URLs
# matching <pattern>.
calls_to() {
    if [ -n "${1:-}" ]; then
        grep -c "$1" "$calls" || true
    else
        wc -l <"$calls" | tr -d ' '
    fi
}

# --------------------------------------------------------------------------- #
# ac-9: seven indexes that answer are a PASS, and the list is the seven URLs
# --------------------------------------------------------------------------- #
: >"$calls"
out=$(run_probe sh "$probe" "${probe_args[@]}" "$RELEASE")
rc=$?
assert_eq "$rc" "0" "ac-9 seven fetchable indexes are a PASS"
assert_contains "$out" \
    "feed-history verdict=PASS release=25.12.0 kernel=6.12.87 kmod=${SEGMENT} feeds=7/7" \
    "ac-9 the verdict line names the release, its kernel and its kmods directory"
assert_eq "$(calls_to)" "8" \
    "ac-9 six user-land and target indexes, the kmods page and the kmods index were asked"
assert_contains "$(cat "$calls")" "$MIRROR/releases/25.12.0/targets/x86/64/kmods/" \
    "ac-9 the kmods directory page was read, because that is where the segment comes from"
assert_eq "$(calls_to "/kmods/${SEGMENT}/packages.adb")" "1" \
    "ac-9 the kmods index was asked for under the segment the page named"
assert_eq "$(calls_to "/kmods/$")" "1" \
    "ac-9 exactly one listing was read, and it is the release's own targets directory"

block=$(repos_block "$out")
assert_eq "$(printf '%s\n' "$block" | wc -l | tr -d ' ')" "7" \
    "ac-9 the list is the seven indexes: five catalogues, the target's and the kmods"
assert_eq "$(printf '%s\n' "$block" | grep -c "^${MIRROR}/releases/${RELEASE}/" || true)" "7" \
    "ac-9 every line names this release on this mirror"
assert_contains "$block" \
    "$MIRROR/releases/25.12.0/targets/x86/64/kmods/${SEGMENT}/packages.adb" \
    "ac-9 the kmods line is the one directory that differs per release"
assert_contains "$block" "$MIRROR/releases/25.12.0/packages/x86_64/packages/packages.adb" \
    "ac-9 the user-land catalogue the samples come from is in the list"
case "$block" in
    *telephony*) assert_eq "present" "present" "ac-9 the telephony catalogue is in the list" ;;
    *) assert_eq "telephony" "missing" "ac-9 the telephony catalogue is in the list" ;;
esac

# The list is the deliverable, so its own shape is asserted: bare URLs, one per line, no
# verdict words, nothing a feed list would have to strip.
case "$block" in
    *"feed-history"*) assert_eq "markers" "inside-block" "ac-9 the markers are outside the pasteable block" ;;
    *) assert_eq "clean" "clean" "ac-9 the markers are outside the pasteable block" ;;
esac

# --------------------------------------------------------------------------- #
# ac-9: one index missing is a FAIL that names it
# --------------------------------------------------------------------------- #
: >"$calls"
out=$(run_probe STUB_BAD_URL=telephony sh "$probe" "${probe_args[@]}" "$RELEASE")
rc=$?
assert_eq "$rc" "1" "ac-9 an index that answers 404 is a FAIL"
assert_contains "$out" "feed-history feed=telephony http=404 index=http-404" \
    "ac-9 the failing catalogue is named with what it answered"
assert_contains "$out" "feed-history verdict=FAIL release=25.12.0" \
    "ac-9 the verdict is FAIL"
assert_contains "$out" "reason=telephony=http-404" \
    "ac-9 the verdict line carries the reason, not only the count"
assert_contains "$out" "feeds=6/7" "ac-9 the verdict counts the one that did not answer"
assert_eq "$(repos_block "$out" | wc -l | tr -d ' ')" "7" \
    "ac-9 the list is still printed on a FAIL: the other six URLs are what the run found"

# A 200 that is not an index is the measured anti-bot failure mode. It must not pass.
: >"$calls"
out=$(run_probe STUB_HTML_URL=packages/x86_64/routing sh "$probe" "${probe_args[@]}" "$RELEASE")
rc=$?
assert_eq "$rc" "1" "ac-9 a 200 that carries HTML instead of an index is a FAIL"
assert_contains "$out" "feed-history feed=routing http=200 index=not-an-index" \
    "ac-9 the answer is recorded as a status and as what the body was"
assert_contains "$out" "reason=routing=not-an-index" \
    "ac-9 and the reason says the body was not an index"

# The kmods index itself missing: the directory was listed, the index under it is not there.
: >"$calls"
out=$(run_probe STUB_BAD_URL="/kmods/${SEGMENT}/" sh "$probe" "${probe_args[@]}" "$RELEASE")
rc=$?
assert_eq "$rc" "1" "ac-9 a kmods index that answers 404 is a FAIL"
assert_contains "$out" "feed-history feed=kmods http=404 index=http-404" \
    "ac-9 the kmods feed is named like every other one"

# --------------------------------------------------------------------------- #
# ac-9: nothing was asked, so nothing is blamed
# --------------------------------------------------------------------------- #
: >"$calls"
out=$(run_probe AB_FH_CURL="$tmp/no-such-fetcher" sh "$probe" "${probe_args[@]}" "$RELEASE")
rc=$?
assert_eq "$rc" "4" "ac-9 a workstation with no fetcher is a GAP"
assert_contains "$out" "feed-history verdict=GAP" "ac-9 the verdict is GAP, not FAIL"
assert_contains "$out" "reason=no-fetch-tool" "ac-9 the gap names the missing tool"
assert_eq "$(calls_to)" "0" "ac-9 no URL was asked for, because there was nothing to ask with"

# Every URL unanswered is the network, not the release. A GAP, and the run stops before it
# pretends the kmods directory was judged.
: >"$calls"
out=$(run_probe STUB_CODE=000 sh "$probe" "${probe_args[@]}" "$RELEASE")
rc=$?
assert_eq "$rc" "4" "ac-9 a network that answers nothing is a GAP"
assert_contains "$out" "feed-history verdict=GAP release=25.12.0 kernel=unknown kmod=unknown feeds=0/6 reason=no-network" \
    "ac-9 the why is in the verdict line"
assert_eq "$(calls_to "/kmods/")" "0" \
    "ac-9 the kmods page is not read when the network already answered nothing"

# --------------------------------------------------------------------------- #
# ac-9: the kmods segment is read, and cannot be guessed
# --------------------------------------------------------------------------- #
# A page that answers 200 and lists no segment: an autoindex switched off, or a proxy that
# ate the body. The driver must say it does not know, not assemble something plausible.
: >"$calls"
out=$(run_probe STUB_KMODS_BODY="<html><title>Index of /kmods</title></html>" \
    sh "$probe" "${probe_args[@]}" "$RELEASE")
rc=$?
assert_eq "$rc" "4" "ac-9 a listing that names no segment is a GAP"
assert_contains "$out" "feed-history feed=kmods-dir http=200 segments=0" \
    "ac-9 the page and what it named are recorded"
assert_contains "$out" "kmod=unknown" "ac-9 the verdict line says the segment is unknown"
assert_contains "$out" "reason=kmods-listing-unreadable" "ac-9 the reason names the listing"
assert_eq "$(repos_block "$out" | wc -l | tr -d ' ')" "6" \
    "ac-9 the kmods line is left out rather than written with a placeholder"

# Two segments: the release shipped more than one kernel, and choosing one here would be a
# guess. GAP, with both named and --kmod as the way to settle it.
: >"$calls"
two_segments='<a href="6.12.87-1-bd81971a1c3f0490e17f340fe09229ea/">a</a><a href="6.12.94-1-0413601b1c3f0490e17f340fe09229ea/">b</a>'
out=$(run_probe STUB_KMODS_BODY="$two_segments" sh "$probe" "${probe_args[@]}" "$RELEASE")
rc=$?
assert_eq "$rc" "4" "ac-9 a page naming two segments is a GAP, not a coin flip"
assert_contains "$out" "feed-history feed=kmods-dir http=200 segments=2" \
    "ac-9 the count of what the page named is recorded"
assert_contains "$out" "reason=kmods-ambiguous" "ac-9 the reason names the ambiguity"

# --kmod is how a caller who knows settles it - and it costs no listing request at all.
: >"$calls"
other_segment="6.12.94-1-0413601b1c3f0490e17f340fe09229ea"
out=$(run_probe sh "$probe" "${probe_args[@]}" "$RELEASE" --kmod "$other_segment")
rc=$?
assert_eq "$rc" "0" "ac-9 --kmod is enough to complete the list"
assert_contains "$out" "feed-history kmods-segment=${other_segment} source=--kmod" \
    "ac-9 the run says the segment came from the caller"
assert_eq "$(calls_to "/kmods/$")" "0" \
    "ac-9 the listing is not read when the segment was given"
assert_contains "$out" \
    "$MIRROR/releases/25.12.0/targets/x86/64/kmods/${other_segment}/packages.adb" \
    "ac-9 the list carries the segment it was given"

# A release with no kmods directory at all is not a gap in this probe: the release publishes
# no kernel modules, so the chain cannot install them there.
: >"$calls"
out=$(run_probe STUB_KMODS_DIR_CODE=404 sh "$probe" "${probe_args[@]}" "$RELEASE")
rc=$?
assert_eq "$rc" "1" "ac-9 a release whose kmods directory is missing is a FAIL"
assert_contains "$out" "reason=kmods-dir-http-404" "ac-9 the reason is the directory, not the page"

# --------------------------------------------------------------------------- #
# ac-9: the plan
# --------------------------------------------------------------------------- #
: >"$calls"
out=$(run_probe AB_FH_CURL="$tmp/no-such-fetcher" sh "$probe" "${probe_args[@]}" "$RELEASE" --dry-run)
rc=$?
assert_eq "$rc" "0" "ac-9 --dry-run succeeds even with no fetcher, because it contacts nothing"
assert_eq "$(calls_to)" "0" "ac-9 --dry-run made no request"

# ... and again with a fetcher that would answer: the stub is on PATH and still not called.
# The first assertion above cannot distinguish "did not call" from "had nothing to call".
: >"$calls"
run_probe sh "$probe" "${probe_args[@]}" "$RELEASE" --dry-run >/dev/null
assert_eq "$(calls_to)" "0" "ac-9 --dry-run does not call a fetcher that is right there"
assert_contains "$out" "feed-history dry-run feed=kmods-dir url=${MIRROR}/releases/25.12.0/targets/x86/64/kmods/" \
    "ac-9 the plan names the page the segment would be read from"
assert_contains "$out" "feed-history dry-run feed=kmods url=${MIRROR}/releases/25.12.0/targets/x86/64/kmods/<segment>/packages.adb" \
    "ac-9 the plan does not invent a segment"
assert_contains "$out" "feed-history dry-run verdict=none" \
    "ac-9 a plan says it has no verdict"
assert_eq "$(repos_block "$out" | wc -l | tr -d ' ')" "0" \
    "ac-9 a plan prints no feed list, because a URL list without a verdict is not one"

# --------------------------------------------------------------------------- #
# ac-9: the artefacts a caller consumes
# --------------------------------------------------------------------------- #
: >"$calls"
repos_file="$tmp/customfeeds.list"
results="$tmp/results.tsv"
evidence="$tmp/evidence"
out=$(run_probe sh "$probe" "${probe_args[@]}" "$RELEASE" --repos "$repos_file" \
    --results "$results" --evidence-dir "$evidence")
assert_eq "$?" "0" "ac-9 --repos and --results do not change the verdict"
assert_file_exists "$repos_file" "ac-9 the feed list was written where it was asked for"
assert_eq "$(wc -l <"$repos_file" | tr -d ' ')" "7" \
    "ac-9 the file carries one URL per line and nothing else"
assert_contains "$(cat "$repos_file")" \
    "$MIRROR/releases/25.12.0/targets/x86/64/kmods/${SEGMENT}/packages.adb" \
    "ac-9 the written list names the release's own kmods directory"
case "$(cat "$repos_file")" in
    *"feed-history"*) assert_eq "clean" "marked" "ac-9 the written list carries no markers" ;;
    *) assert_eq "clean" "clean" "ac-9 the written list carries no markers" ;;
esac

assert_file_exists "$results" "ac-9 a results row was written"
row=$(cat "$results")
assert_contains "$row" "FH-25.12.0" "ac-9 the row is named after the release"
assert_contains "$row" "PASS" "ac-9 the row carries the verdict"
assert_contains "$row" "feeds=7/7" "ac-9 the row carries the count"
assert_file_exists "$evidence/FH-25.12.0.log" "ac-9 the evidence log is named after the release"
assert_contains "$(cat "$evidence/FH-25.12.0.log")" "feed-history verdict=PASS" \
    "ac-9 the log holds the verdict a reader comes back for"

# --json: one object, one line, and the same facts a parser needs.
: >"$calls"
out=$(run_probe sh "$probe" "${probe_args[@]}" "$RELEASE" --json)
rc=$?
assert_eq "$rc" "0" "ac-9 --json keeps the verdict and the exit status"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" \
    "ac-9 --json prints one object on one line"
assert_contains "$out" '"verdict":"PASS"' "ac-9 the object carries the verdict"
assert_contains "$out" "\"kmod\":\"${SEGMENT}\"" "ac-9 the object carries the segment"
assert_contains "$out" '"feeds":[' "ac-9 the object carries every answer"
assert_contains "$out" '"repositories":[' "ac-9 the object carries the feed list"
if command -v python3 >/dev/null 2>&1; then
    assert_command_ok "ac-9 the object parses as JSON" \
        python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out"
fi

# --------------------------------------------------------------------------- #
# ac-9: usage is a usage error, before anything is fetched
# --------------------------------------------------------------------------- #
: >"$calls"
run_probe sh "$probe" "${probe_args[@]}" >/dev/null 2>&1
assert_eq "$?" "2" "ac-9 a run with no release is a usage error"
run_probe sh "$probe" "${probe_args[@]}" "$RELEASE" --nonsense >/dev/null 2>&1
assert_eq "$?" "2" "ac-9 an unknown flag is a usage error"
run_probe sh "$probe" --mirror "ftp://mirror.test" "$RELEASE" >/dev/null 2>&1
assert_eq "$?" "2" "ac-9 a mirror that is not http(s) is a usage error"
run_probe sh "$probe" "${probe_args[@]}" "$RELEASE" --timeout soon >/dev/null 2>&1
assert_eq "$?" "2" "ac-9 a timeout that is not a number is a usage error"
run_probe sh "$probe" "${probe_args[@]}" "$RELEASE" --dry-run --json >/dev/null 2>&1
assert_eq "$?" "2" "ac-9 --json needs a verdict, so --dry-run and --json is a usage error"
assert_eq "$(calls_to)" "0" "ac-9 a usage error fetched nothing"

# A mirror given with a trailing slash is the same mirror, not a URL with a double slash.
: >"$calls"
out=$(run_probe sh "$probe" --mirror "${MIRROR}/" "$RELEASE")
assert_contains "$out" "feed-history release=25.12.0 mirror=${MIRROR} " \
    "ac-9 a trailing slash on the mirror is normalised away"
assert_eq "$(calls_to "//releases")" "0" "ac-9 no URL carries a doubled slash"

finish
