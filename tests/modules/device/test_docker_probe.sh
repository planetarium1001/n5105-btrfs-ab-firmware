#!/usr/bin/env bash
# Module: device
# The docker probe (ac-9): D1 baseline, D2 across-the-jump comparison, D3 subvolume identity.
#
# Every test here drives the real script with a recorded snapshot file (AB_DOCKER_INPUT) or
# with --dry-run, so no device is needed. What is exercised is the part that decided wrong in
# an earlier round: the comparison semantics. One test drives the live path through a stub
# `ssh` instead, because a replay-only suite would still pass with the code that turns a
# device's output into a snapshot completely broken.
#
#   ac-9  D1 accepts a baseline whose pulls, container, committed image and volume all hash
#         to the content this run declares, and reports one result row per case
#   ac-9  D2 is green when the image set grew and the artifacts did not change one byte
#   ac-9  D2 is red when an image the baseline saw is gone (subset, not equality)
#   ac-9  D2 is red when a container/image/volume artifact changes - including when the
#         change is a timestamp the baseline did not have
#   ac-9  a comparison between two captures of the same boot is a GAP, not a PASS: nothing
#         about a hop was tested
#   ac-9  a mirror failure is a GAP carrying URL, status and the rerun command, never a FAIL
#   ac-9  a missing or empty baseline block is red: "not compared" must not print as
#         "nothing changed"
#   ac-9  D3 requires data/docker/swap=ok and an unchanged @docker/@data identity
#   ac-9  --dry-run contacts nothing and writes nothing; --selfcheck proves the comparator
#         goes red on tampering
#   ac-9  a live capture is stored as a document that is itself a replayable baseline
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

probe="$root/scripts/device/docker-probe.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------- #
# Fixtures
#
# The declared content is passed in through the script's own environment variables, so the
# expected sha256 is the test's own bytes hashed here: the test proves the grader derives the
# expectation from the content instead of hardcoding a value that a rewrite would match.
# --------------------------------------------------------------------------- #
MARKER_TEXT="test marker unit=ac-9 version=t"
PAYLOAD_TEXT="payload abcdef0123456789 deterministic"
V_MARKER_TEXT="test volume uid=0"
V_UTF8_TEXT="卷内容 UTF-8 test"

export AB_DOCKER_MARKER_TEXT="$MARKER_TEXT"
export AB_DOCKER_PAYLOAD_TEXT="$PAYLOAD_TEXT"
export AB_DOCKER_VOLUME_MARKER_TEXT="$V_MARKER_TEXT"
export AB_DOCKER_VOLUME_UTF8_TEXT="$V_UTF8_TEXT"

sha_of() { # sha_of <text>: the sha256 of <text> followed by one newline
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s\n' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

bytes_of() { printf '%s\n' "$1" | wc -c | tr -d ' '; }

# after_part <file> <sed-expr>: the second capture of a two-capture fixture with one edit
# applied to it. The `## snapshot after` label is part of the part, because a part without
# its label cannot be split again and the test would then measure the wrong document.
after_part() {
  awk '/^## snapshot after/{f=1} f{print}' "$1" | sed "$2"
}

# before_part <file>: the first capture, label included.
before_part() { awk '/^## snapshot after/{exit} {print}' "$1"; }

# extract_plan <file> <case> <step>: the remote script --dry-run printed, unindented.
# A plan block is indented by four spaces; a 2-space `  assert:`/`  local:` note is not part
# of it, which is why the stop condition is "a line that is not indented by four".
extract_plan() {
  awk -v want="plan $2 step=$3" '
    $0 == want { f = 1; next }
    f && substr($0, 1, 4) == "    " { sub(/^    /, ""); print; next }
    f { f = 0 }
  ' "$1"
}

M_SHA=$(sha_of "$MARKER_TEXT");     M_BYTES=$(bytes_of "$MARKER_TEXT")
P_SHA=$(sha_of "$PAYLOAD_TEXT");    P_BYTES=$(bytes_of "$PAYLOAD_TEXT")
VM_SHA=$(sha_of "$V_MARKER_TEXT");  VM_BYTES=$(bytes_of "$V_MARKER_TEXT")
VU_SHA=$(sha_of "$V_UTF8_TEXT");    VU_BYTES=$(bytes_of "$V_UTF8_TEXT")

# capture_body <label> <generation> <slot> <upper> [extra-image-line] [artifact-sha-override]
capture_body() {
  local label=$1 gen=$2 slot=$3 upper=$4 extra=${5:-} msha=${6:-$M_SHA}
  cat <<BODY
## snapshot $label
## info_workload
mirror=docker.m.daocloud.io
workload_image=docker.m.daocloud.io/library/redis:7-alpine
container=acpt-docker-probe
volume=acpt-docker-probe-vol
commit_image=acpt/docker-probe:baseline
pull=library/redis:7-alpine rc=0 url=https://docker.m.daocloud.io/library/redis:7-alpine http=none why=none attempts=1 digest=sha256:7f7d30b7fdd09467bac58198a1f166dd69789d348d4fe859cccb20e0cf287fbe
pull=library/nginx:alpine rc=0 url=https://docker.m.daocloud.io/library/nginx:alpine http=none why=none attempts=1 digest=sha256:fed7e14be83cbd2661a75cdc5b872d936cf155d46c327084d30b8df19ae88d72
run_rc=0
volume_create_rc=0
volume_write_rc=0
commit_rc=0
## info_capture
captured_utc=2026-11-16T05:24:16Z
mirror=https://docker.m.daocloud.io
## info_device
kernel=6.12.103
platform=0.0.11
upstream=25.12.2
## info_docker_info
server_version=29.6.1
images_count=8
## assert_engine
info_rc=0
run_rm_rc=0
driver=overlay2
data_root=/opt/docker
## assert_slot
data=ok
docker=ok
swap=ok
boot=ok
esp=ok
## subset_images
acpt/docker-probe|baseline|sha256:af9a155e05b86626f32bfb445b5b7fee70f117362045b7246e28b1b0167a0b48|sha256:af9a155e05b86626f32bfb445b5b7fee70f117362045b7246e28b1b0167a0b48
docker.m.daocloud.io/library/nginx|alpine|sha256:fed7e14be83cbd2661a75cdc5b872d936cf155d46c327084d30b8df19ae88d72|sha256:fed7e14be83cbd2661a75cdc5b872d936cf155d46c327084d30b8df19ae88d72
docker.m.daocloud.io/library/redis|7-alpine|sha256:7f7d30b7fdd09467bac58198a1f166dd69789d348d4fe859cccb20e0cf287fbe|sha256:7f7d30b7fdd09467bac58198a1f166dd69789d348d4fe859cccb20e0cf287fbe
${extra}## assert_container_artifact
artifact=marker.txt sha256=$msha bytes=$M_BYTES
artifact=payload.txt sha256=$P_SHA bytes=$P_BYTES
state=ok
## assert_commit_artifact
artifact=marker.txt sha256=$M_SHA bytes=$M_BYTES
artifact=payload.txt sha256=$P_SHA bytes=$P_BYTES
state=ok
## assert_volume
artifact=volume-marker.txt sha256=$VM_SHA bytes=$VM_BYTES
artifact=volume-utf8.txt sha256=$VU_SHA bytes=$VU_BYTES
state=ok
## assert_subvol_identity
subvol=@data id=259 uuid=17c86ea4-6227-3840-bae1-5057e1e0b280
subvol=@docker id=257 uuid=7fcfefc7-afb0-b645-92ca-72c03e8dbc28
## assert_subvol_property
subvol=@data ro=false
subvol=@docker ro=false
## info_status_line
line=slot=$slot upper=$upper generation=$gen committed=$slot pending=none p4=ok data=ok docker=ok swap=ok esp=ok boot=ok packages=aligned packages_reason=none
## info_volumes
acpt-docker-probe-vol
## end
BODY
}

# The two captures of a healthy hop: slot b -> a, generation 5 -> 6.
write_clean() {
  { capture_body before 5 b @overlay-25.12.2-r2
    capture_body after  6 a @overlay-25.12.2-r3 \
      'docker.m.daocloud.io/library/busybox|latest|sha256:newdigest|sha256:newid
'
  } >"$tmp/clean.txt"
}

# run <args...>: the real script, with a tripwire `ssh` first on PATH.
# A replay or a dry run that reached the network would not fail loudly - dev_ssh has
# BatchMode=yes and a timeout - so the tripwire records the attempt and exits 255. Every
# replay test then asserts the file is still empty, which is what "touches no device" means.
mkdir -p "$tmp/emptybin"
cat >"$tmp/emptybin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "ssh $*" >>"${DP_TRIPWIRE:?}"
exit 255
STUB
chmod +x "$tmp/emptybin/ssh"
export DP_TRIPWIRE="$tmp/tripwire"
: >"$DP_TRIPWIRE"
run() { PATH="$tmp/emptybin:$PATH" "$@"; }

# --------------------------------------------------------------------------- #
# ac-9: the comparator has to be awake before any verdict counts
# --------------------------------------------------------------------------- #
out=$(run sh "$probe" --selfcheck 2>&1)
assert_eq "$?" "0" "ac-9 the comparator self-check passes"
assert_contains "$out" "selfcheck unchanged" "ac-9 a pristine pair is green"
assert_contains "$out" "selfcheck grew-image       want=green got=green" "ac-9 an added image is green (subset rule)"
assert_contains "$out" "selfcheck lost-image       want=red" "ac-9 a dropped image is red"
assert_contains "$out" "selfcheck changed-bytes    want=red" "ac-9 a changed artifact is red"
assert_contains "$out" "selfcheck missing-block    want=red" "ac-9 a vanished block is red, not 'nothing changed'"
assert_contains "$out" "selfcheck glued-header     want=red" "ac-9 a glued block header is red"
assert_contains "$out" "selfcheck empty-baseline   want=red" "ac-9 an empty baseline block cannot PASS"
assert_contains "$out" "selfcheck uncompared-block want=red" "ac-9 a block only one side has is red"
assert_contains "$out" "selfcheck result=PASS" "ac-9 the self-check reports its own verdict"

# --------------------------------------------------------------------------- #
# ac-9: --dry-run is a plan - no ssh, no file written
# --------------------------------------------------------------------------- #
mkdir -p "$tmp/dryrun"
(
  cd "$tmp/dryrun" || exit 1
  AB_HOST=root@192.0.2.1 AB_KEY="$tmp/key" sh "$probe" --dry-run \
    >"$tmp/dryrun.out" 2>"$tmp/dryrun.err"
  printf '%s\n' "$?" >"$tmp/dryrun.rc"
)
assert_eq "$(cat "$tmp/dryrun.rc")" "0" "ac-9 --dry-run exits 0"
dry=$(cat "$tmp/dryrun.out")
assert_contains "$dry" "plan D1 step=pull" "ac-9 --dry-run prints the pull plan"
assert_contains "$dry" "plan D1 step=capture" "ac-9 --dry-run prints the capture plan"
assert_contains "$dry" "docker.m.daocloud.io/library/redis:7-alpine" "ac-9 the plan names the mirror image"
assert_contains "$dry" "== D1 plan dry-run" "ac-9 a plan is labelled a plan, not a pass"
assert_contains "$dry" "== D2 plan dry-run" "ac-9 D2 is planned too"
assert_contains "$dry" "== D3 plan dry-run" "ac-9 D3 is planned too"
assert_contains "$dry" "docker-probe result=dry-run" "ac-9 the summary says dry-run"
case "$dry" in
  *"dry-run: ssh"*) assert_eq "ssh attempted" "no ssh in a dry run" "ac-9 --dry-run must not ssh" ;;
  *) assert_eq "no ssh" "no ssh" "ac-9 --dry-run must not ssh" ;;
esac
assert_eq "$(ls -A "$tmp/dryrun" | wc -l | tr -d ' ')" "0" \
  "ac-9 --dry-run writes no results file and no snapshot"
# The plan is built by expanding the same heredocs the real run sends, so a stray
# command substitution in one of them runs on *this* host while printing the plan.
assert_eq "$(cat "$tmp/dryrun.err")" "" \
  "ac-9 --dry-run prints nothing on stderr (no command substitution escapes the heredoc)"

# The two remote scripts must be valid POSIX sh: they are what runs on the machine, and a
# quoting error there is invisible until the device is on the bench.
extract_plan "$tmp/dryrun.out" D1 pull >"$tmp/pull.sh"
extract_plan "$tmp/dryrun.out" D1 capture >"$tmp/capture.sh"
assert_matches "$(wc -l <"$tmp/pull.sh" | tr -d ' ')" '^[1-9][0-9]*$' \
  "ac-9 the pull plan is a non-empty script"
assert_matches "$(wc -l <"$tmp/capture.sh" | tr -d ' ')" '^[1-9][0-9]*$' \
  "ac-9 the capture plan is a non-empty script"
if command -v dash >/dev/null 2>&1; then
  assert_command_ok "ac-9 the remote pull script is valid POSIX sh" dash -n "$tmp/pull.sh"
  assert_command_ok "ac-9 the remote capture script is valid POSIX sh" dash -n "$tmp/capture.sh"
else
  assert_command_ok "ac-9 the remote pull script is valid POSIX sh" sh -n "$tmp/pull.sh"
  assert_command_ok "ac-9 the remote capture script is valid POSIX sh" sh -n "$tmp/capture.sh"
fi
assert_contains "$(cat "$tmp/capture.sh")" "btrfs property get" \
  "ac-9 the capture script really carries the btrfs identity commands"

# The grader reads named blocks, and a renamed block would make it judge nothing while
# still printing a verdict. Every block name the grader asks for has to be printed by the
# script that runs on the machine, and the pull facts have to come from the workload step.
capture_text=$(cat "$tmp/capture.sh")
for block in info_capture info_device info_docker_info assert_engine assert_slot \
             subset_images assert_container_artifact assert_commit_artifact \
             assert_volume assert_subvol_identity assert_subvol_property \
             info_status_line info_images info_volumes info_containers; do
  assert_contains "$capture_text" "## ${block}" \
    "ac-9 the capture script prints the ${block} block the grader reads"
done
pull_text=$(cat "$tmp/pull.sh")
assert_contains "$pull_text" "## info_workload" \
  "ac-9 the workload step prints the info_workload block the pull grader reads"
assert_contains "$pull_text" "pull=%s rc=%s url=%s http=%s why=%s attempts=%s digest=%s" \
  "ac-9 the pull line carries URL, HTTP status, retry count and digest"
assert_contains "$pull_text" 'run --name "$C"' "ac-9 the workload really starts a container"
assert_contains "$pull_text" 'commit --change' "ac-9 the workload really commits an image"
assert_contains "$pull_text" 'volume create "$V"' "ac-9 the workload really creates a named volume"

assert_eq "$(wc -l <"$DP_TRIPWIRE" | tr -d ' ')" "0" \
  "ac-9 no replay or dry run above touched the network"

# --------------------------------------------------------------------------- #
# ac-9: D1 + D2 + D3 on a healthy hop, from a recorded snapshot
# --------------------------------------------------------------------------- #
write_clean
rm -rf "$tmp/s-clean"
out=$(run sh "$probe" --input "$tmp/clean.txt" --results "$tmp/clean.tsv" \
  --snapshot-dir "$tmp/s-clean" 2>&1)
assert_eq "$?" "0" "ac-9 a healthy recorded hop exits 0"
assert_contains "$out" "ok   [D1] pull library/redis:7-alpine rc=0" "ac-9 D1 reports the real pull with its digest"
assert_contains "$out" "ok   [D1] pull library/nginx:alpine rc=0" "ac-9 D1 reports the second mirror pull"
assert_contains "$out" "matches-declared-content=yes" "ac-9 the artifact matches the content this run declares"
assert_contains "$out" "== D1 PASS" "ac-9 D1 PASSes"
assert_contains "$out" "ok   [D2] subset_images rule=subset kept=3 added=1 unchanged=yes" \
  "ac-9 D2 counts the added image and still passes (only-grows)"
assert_contains "$out" "ok   [D2] assert_container_artifact rule=assert lines=3 unchanged=yes" \
  "ac-9 D2 compares the container artifact byte for byte"
assert_contains "$out" "ok   [D2] assert_commit_artifact rule=assert lines=3 unchanged=yes" \
  "ac-9 D2 compares the file read back out of the committed image"
assert_contains "$out" "ok   [D2] assert_volume rule=assert lines=3 unchanged=yes" \
  "ac-9 D2 compares the named volume"
assert_contains "$out" "ok   [D2] jump generation=5->6 slot=b->a" "ac-9 D2 proves a hop happened"
assert_contains "$out" "== D2 PASS" "ac-9 D2 PASSes"
assert_contains "$out" "ok   [D3] mount docker=ok->ok" "ac-9 D3 asserts docker=ok on both sides"
assert_contains "$out" "ok   [D3] subvol-identity unchanged" "ac-9 D3 asserts the subvolume identity"
assert_contains "$out" "subvol=@docker id=257" "ac-9 D3 names @docker's subvolume id"
assert_contains "$out" "ok   [D3] subvol-property unchanged" "ac-9 D3 asserts the read-only property"
assert_contains "$out" "== D3 PASS" "ac-9 D3 PASSes"
assert_contains "$out" "docker-probe result=pass" "ac-9 the summary says pass"

# The results rows: case<TAB>verdict<TAB>evidence<TAB>note, three of them.
rows=$(cat "$tmp/clean.tsv")
assert_contains "$rows" "D1	PASS	" "ac-9 D1 has a results row with its verdict"
assert_contains "$rows" "D2	PASS	" "ac-9 D2 has a results row"
assert_contains "$rows" "D3	PASS	" "ac-9 D3 has a results row"
assert_eq "$(awk -F'\t' 'NF!=4' "$tmp/clean.tsv" | wc -l | tr -d ' ')" "0" \
  "ac-9 every row has exactly four fields"
assert_file_exists "$tmp/s-clean/before.snapshot" "ac-9 D1 leaves the baseline snapshot on disk"
assert_file_exists "$tmp/s-clean/after.snapshot" "ac-9 D2 leaves the after snapshot on disk"
assert_contains "$(cat "$tmp/s-clean/before.snapshot")" "## snapshot before" \
  "ac-9 the baseline snapshot is a replayable document"

# --------------------------------------------------------------------------- #
# ac-9: an image the baseline saw is gone -> FAIL (subset, not equality)
# --------------------------------------------------------------------------- #
awk '
  /^## snapshot after/ { after = 1 }
  after && /^docker\.m\.daocloud\.io\/library\/nginx\|alpine\|/ { next }
  { print }
' "$tmp/clean.txt" >"$tmp/lost.txt"
rm -rf "$tmp/s-lost"
out=$(run sh "$probe" --case D2 --input "$tmp/lost.txt" --results "$tmp/lost.tsv" \
  --snapshot-dir "$tmp/s-lost" 2>&1)
assert_eq "$?" "1" "ac-9 a lost image is a FAIL exit"
assert_contains "$out" "FAIL [D2] subset_images drift=subset-lost" \
  "ac-9 a missing image is named subset-lost, not 'content changed'"
assert_contains "$out" "== D2 FAIL" "ac-9 the case row is FAIL"

# --------------------------------------------------------------------------- #
# ac-9: the image name is matched literally - a tag that only shares a substring is not it
#
# The row divider in `docker images --format` is `|`, which grep -E reads as alternation: a
# pattern built from a (repo, tag) pair matched any row that happened to carry the tag. The
# fixture below keeps nginx's digest only under a *different* repository, so a name-based
# check must still go red.
# --------------------------------------------------------------------------- #
# The replacement row carries both `|alpine|` and `sha256:` and a `/library/` prefix, i.e.
# every fragment of the pattern the old alternation-based check would have accepted.
{ capture_body before 5 b @overlay-25.12.2-r2
  after_part "$tmp/clean.txt" \
    's#^docker\.m\.daocloud\.io/library/nginx|alpine|sha256:.*#docker.m.daocloud.io/library/alpine|alpine|sha256:decoy|sha256:decoy#'
} >"$tmp/renamed.txt"
rm -rf "$tmp/s-renamed"
out=$(run sh "$probe" --case D2 --input "$tmp/renamed.txt" --results "$tmp/renamed.tsv" \
  --snapshot-dir "$tmp/s-renamed" 2>&1)
assert_eq "$?" "1" "ac-9 a decoy image that shares tag and digest fragments is a FAIL exit"
assert_contains "$out" "FAIL [D2] images library/nginx:alpine is not in docker images --digests" \
  "ac-9 the image is matched by its whole repo:tag, not by a substring of the row"

# --------------------------------------------------------------------------- #
# ac-9: a timestamp in the artifact -> FAIL, and the verdict is not a silent pass
# --------------------------------------------------------------------------- #
# This is the shape a non-deterministic artifact takes: same file, different bytes. The
# baseline is regenerated with the clean sha so only the after capture differs.
{ capture_body before 5 b @overlay-25.12.2-r2
  capture_body after  6 a @overlay-25.12.2-r3 "" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
} >"$tmp/tampered.txt"
rm -rf "$tmp/s-tampered"
out=$(run sh "$probe" --case D2 --input "$tmp/tampered.txt" --results "$tmp/tampered.tsv" \
  --snapshot-dir "$tmp/s-tampered" 2>&1)
assert_eq "$?" "1" "ac-9 a rewritten artifact is a FAIL exit"
assert_contains "$out" "FAIL [D2] assert_container_artifact marker.txt sha256=deadbeef" \
  "ac-9 the artifact is compared with the declared content, not just with the baseline"
assert_contains "$out" "drift=content" "ac-9 a changed value is named content"

# --------------------------------------------------------------------------- #
# ac-9: two captures of the same boot -> GAP, because no hop was tested
# --------------------------------------------------------------------------- #
{ capture_body before 5 b @overlay-25.12.2-r2
  capture_body after  5 b @overlay-25.12.2-r2
} >"$tmp/nojump.txt"
rm -rf "$tmp/s-nojump"
out=$(run sh "$probe" --case D2 --case D3 --input "$tmp/nojump.txt" \
  --results "$tmp/nojump.tsv" --snapshot-dir "$tmp/s-nojump" 2>&1)
assert_eq "$?" "3" "ac-9 an unmoved machine exits 3 (no verdict), not 0"
assert_contains "$out" "GAP  [D2] jump generation=5->5 slot=b->b" \
  "ac-9 D2 says nothing moved instead of claiming equality"
assert_contains "$out" "GAP  [D3] jump" "ac-9 D3 says the same"
assert_contains "$out" "== D2 GAP" "ac-9 the D2 row is GAP"
case "$out" in
  *"== D2 PASS"*) assert_eq "PASS reported" "GAP reported" "ac-9 an unmoved machine must not PASS" ;;
  *) assert_eq "GAP" "GAP" "ac-9 an unmoved machine must not PASS" ;;
esac

# --------------------------------------------------------------------------- #
# ac-9: the mirror is down -> GAP with URL, status and the rerun command
# --------------------------------------------------------------------------- #
sed 's|^pull=library/redis:7-alpine rc=0 .*|pull=library/redis:7-alpine rc=1 url=https://docker.m.daocloud.io/library/redis:7-alpine http=503 why=http attempts=2 digest=none|' \
  "$tmp/clean.txt" >"$tmp/mirror.txt"
rm -rf "$tmp/s-mirror"
out=$(run sh "$probe" --case D1 --input "$tmp/mirror.txt" --results "$tmp/mirror.tsv" \
  --snapshot-dir "$tmp/s-mirror" 2>&1)
assert_eq "$?" "3" "ac-9 a dead mirror is exit 3, not a FAIL"
assert_contains "$out" "GAP  [D1] pull library/redis:7-alpine rc=1" "ac-9 the pull failure is a GAP"
assert_contains "$out" "url=https://docker.m.daocloud.io/library/redis:7-alpine" \
  "ac-9 the GAP names the URL it tried"
assert_contains "$out" "http=503" "ac-9 the GAP carries the HTTP status"
assert_contains "$out" "why=http" "ac-9 the GAP classifies the failure"
assert_contains "$out" "attempts=2" "ac-9 the pull was retried once before the GAP"
assert_contains "$out" "next: docker pull docker.m.daocloud.io/library/redis:7-alpine" \
  "ac-9 the GAP carries the command that asks again"
assert_contains "$out" "== D1 GAP" "ac-9 the D1 row is GAP; a network failure is not a product FAIL"
case "$(cat "$tmp/mirror.tsv")" in
  *FAIL*) assert_eq "FAIL row" "no FAIL row" "ac-9 a mirror outage writes no FAIL row" ;;
  *) assert_eq "no FAIL row" "no FAIL row" "ac-9 a mirror outage writes no FAIL row" ;;
esac

# --------------------------------------------------------------------------- #
# ac-9: a comparison with no baseline, and with an empty block, must not pass
# --------------------------------------------------------------------------- #
{ printf '## snapshot after\n'
  capture_body after 6 a @overlay-25.12.2-r3
} >"$tmp/nobase.txt"
rm -rf "$tmp/s-nobase"
out=$(run sh "$probe" --case D2 --input "$tmp/nobase.txt" --results "$tmp/nobase.tsv" \
  --snapshot-dir "$tmp/s-nobase" 2>&1)
assert_eq "$?" "3" "ac-9 D2 without a baseline is exit 3"
assert_contains "$out" "GAP  [D2] baseline no baseline snapshot to compare against" \
  "ac-9 D2 refuses to invent a baseline"

# An empty assert block in the baseline: cmp would call two empty files equal.
awk '
  /^## assert_container_artifact$/ { print; skip = 1; next }
  skip && /^## / { skip = 0 }
  !skip { print }
' "$tmp/clean.txt" >"$tmp/emptyblock.txt"
rm -rf "$tmp/s-empty"
out=$(run sh "$probe" --case D2 --input "$tmp/emptyblock.txt" --results "$tmp/empty.tsv" \
  --snapshot-dir "$tmp/s-empty" 2>&1)
assert_contains "$out" "drift=empty-block" "ac-9 an empty baseline block is named empty-block, never a pass"

# A glued block header: the exact-match parser would silently skip the block.
awk '{ print } /^## snapshot after$/ { }' "$tmp/clean.txt" \
  | sed 's/^## assert_volume$/junk,## assert_volume/' >"$tmp/glued.txt"
rm -rf "$tmp/s-glued"
out=$(run sh "$probe" --case D2 --input "$tmp/glued.txt" --results "$tmp/glued.tsv" \
  --snapshot-dir "$tmp/s-glued" 2>&1)
assert_eq "$?" "1" "ac-9 a broken snapshot is a FAIL exit"
assert_contains "$out" "drift=glued-header" "ac-9 a glued header is reported as structure drift"

# --------------------------------------------------------------------------- #
# ac-9: D3 fails on a moved subvolume id, and on a mount that is not ok
# --------------------------------------------------------------------------- #
{ before_part "$tmp/clean.txt"
  after_part "$tmp/clean.txt" \
    's/^subvol=@docker id=257 uuid=7fcfefc7-afb0-b645-92ca-72c03e8dbc28$/subvol=@docker id=999 uuid=deadbeef-0000-0000-0000-000000000000/'
} >"$tmp/subvol.txt"
rm -rf "$tmp/s-subvol"
out=$(run sh "$probe" --case D3 --input "$tmp/subvol.txt" --results "$tmp/subvol.tsv" \
  --snapshot-dir "$tmp/s-subvol" 2>&1)
assert_eq "$?" "1" "ac-9 a recreated @docker subvolume is a FAIL exit"
assert_contains "$out" "FAIL [D3] subvol-identity drift=content" \
  "ac-9 D3 notices the store was recreated instead of reused"

# docker= gone from the after capture, so the store is not mounted any more
{ before_part "$tmp/clean.txt"
  after_part "$tmp/clean.txt" 's/^docker=ok$/docker=missing/'
} >"$tmp/mount.txt"
rm -rf "$tmp/s-mount"
out=$(run sh "$probe" --case D3 --input "$tmp/mount.txt" --results "$tmp/mount.tsv" \
  --snapshot-dir "$tmp/s-mount" 2>&1)
assert_contains "$out" "FAIL [D3] mount docker=ok->missing" \
  "ac-9 D3 requires docker=ok on both captures"

# --------------------------------------------------------------------------- #
# ac-9: full-test.sh points a phase's results at AB_RESULTS, and that has to be honoured
# --------------------------------------------------------------------------- #
rm -rf "$tmp/s-orch"
out=$(AB_RESULTS="$tmp/orch.tsv" run sh "$probe" --case D1 --input "$tmp/clean.txt" \
  --snapshot-dir "$tmp/s-orch" 2>&1)
assert_file_exists "$tmp/orch.tsv" "ac-9 the orchestrator's AB_RESULTS is the file that gets the row"
case "$out" in
  *"--results"*) assert_eq "usage" "no usage error" "ac-9 AB_RESULTS alone is enough" ;;
esac
assert_contains "$(cat "$tmp/orch.tsv" 2>/dev/null)" "D1	PASS" \
  "ac-9 the row lands in the orchestrator's TSV"
assert_eq "$(ls "$tmp"/docker-probe-results.tsv 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-9 no second results file is written next to it"

# --------------------------------------------------------------------------- #
# ac-9: --json --dry-run is still only JSON objects
# --------------------------------------------------------------------------- #
mkdir -p "$tmp/jsondry"
out=$(
  cd "$tmp/jsondry" || exit 1
  AB_HOST=root@192.0.2.1 AB_KEY="$tmp/key" sh "$probe" --dry-run --json 2>/dev/null
)
assert_eq "$(printf '%s\n' "$out" | grep -vc '^{')" "0" \
  "ac-9 --json --dry-run prints no human lines"
assert_contains "$out" '"check":"plan"' "ac-9 the plan is a JSON object"
assert_contains "$out" '\n' "ac-9 the plan's script keeps its line breaks as escapes, so it can be pasted back"
assert_eq "$(ls -A "$tmp/jsondry" | wc -l | tr -d ' ')" "0" \
  "ac-9 --json --dry-run writes nothing either"

# The replay runs after the first one must not have reached out either.
assert_eq "$(wc -l <"$DP_TRIPWIRE" | tr -d ' ')" "0" \
  "ac-9 the negative replays never contacted a device"

# --------------------------------------------------------------------------- #
# ac-9: the live path - a reachable device that answers with real-shaped blocks
#
# The replay tests above inject a snapshot document. They would still pass if the code that
# assembles that document from a live device were broken, so one test in this file drives a
# stub `ssh` instead: the stub answers the two remote scripts with the same blocks the real
# machine prints, and D1 has to store them as before.snapshot and judge them.
# --------------------------------------------------------------------------- #
mkdir -p "$tmp/livebin"
cat >"$tmp/livebin/ssh" <<'STUB'
#!/bin/sh
# A stand-in for the device: the last argument is the remote script dev_ssh sent.
last=""
for a in "$@"; do last=$a; done
case "$last" in
  "true") exit 0 ;;
  *"btrfs subvolume show"*) cat "$DP_CAPTURE_BODY"; exit 0 ;;
  *"commit --change"*) cat "$DP_WORKLOAD_BODY"; exit 0 ;;
  "ab-slot status") printf '%s\n' "slot=b upper=@overlay-25.12.2-r2 generation=5 committed=b pending=none"; exit 0 ;;
esac
exit 0
# This stub was forked with the two bodies in the environment; the paths are in
# DP_CAPTURE_BODY and DP_WORKLOAD_BODY.
STUB
chmod +x "$tmp/livebin/ssh"

# The device printouts are the fixture documents without their `## snapshot <label>` line:
# that line is what the caller adds, and it is what makes a stored capture replayable.
# `sed '1d'` was `sed '1{/^## snapshot /d}'` first: that is a GNU idiom and BSD sed
# refuses it, which silently produced an empty device printout on this laptop.
capture_body before 5 b @overlay-25.12.2-r2 | sed '1d' >"$tmp/capture.body"
assert_eq "$(head -1 "$tmp/capture.body")" "## info_workload" \
  "ac-9 (fixture guard) the device printout starts at the first fact block"
awk '/^## info_workload$/{f=1} f && /^## info_capture$/{exit} f{print}' "$tmp/clean.txt" \
  >"$tmp/workload.body"

rm -rf "$tmp/s-live"
out=$(PATH="$tmp/livebin:$PATH" DP_CAPTURE_BODY="$tmp/capture.body" \
  DP_WORKLOAD_BODY="$tmp/workload.body" AB_HOST=root@192.0.2.9 AB_KEY="$tmp/key" \
  sh "$probe" --case D1 --results "$tmp/live.tsv" --snapshot-dir "$tmp/s-live" 2>&1)
assert_eq "$?" "0" "ac-9 D1 on a live device that answers with real-shaped blocks passes"
assert_contains "$out" "ok   [D1] pull-count pulled=2 of 2" "ac-9 D1 counts the two real pulls"
assert_contains "$out" "== D1 PASS" "ac-9 the live baseline PASSes"
assert_file_exists "$tmp/s-live/before.snapshot" "ac-9 the live baseline is stored where a reader can open it"
assert_contains "$(head -1 "$tmp/s-live/before.snapshot" 2>/dev/null)" "## snapshot before" \
  "ac-9 the stored capture starts with its own snapshot label"
assert_contains "$(cat "$tmp/s-live/before.snapshot" 2>/dev/null)" "## info_workload" \
  "ac-9 the stored capture carries the workload facts the separate remote call collected"

# The stored baseline must itself be a replay input: D2 against it needs no device at all.
rm -rf "$tmp/s-live2"
out=$(run sh "$probe" --case D2 --input "$tmp/s-live/before.snapshot" \
  --results "$tmp/live2.tsv" --snapshot-dir "$tmp/s-live2" 2>&1)
assert_eq "$?" "3" "ac-9 a stored baseline replays, and D2 then reports the missing after capture"

# An unreachable device is a GAP, not a FAIL: the machine is somebody else's problem.
cat >"$tmp/livebin/ssh" <<'STUB'
#!/bin/sh
exit 255
STUB
chmod +x "$tmp/livebin/ssh"
rm -rf "$tmp/s-dead"
out=$(PATH="$tmp/livebin:$PATH" AB_HOST=root@192.0.2.10 AB_KEY="$tmp/key" \
  sh "$probe" --case D1 --results "$tmp/dead.tsv" --snapshot-dir "$tmp/s-dead" 2>&1)
assert_eq "$?" "3" "ac-9 an unreachable machine is exit 3"
assert_contains "$out" "GAP  [D1] device the machine did not answer ssh" \
  "ac-9 an unreachable machine is a GAP, never a product FAIL"

# --------------------------------------------------------------------------- #
# ac-9: AB_DOCKER_INPUT is the replay channel a caller sets, not just --input
# --------------------------------------------------------------------------- #
rm -rf "$tmp/s-env"
out=$(AB_DOCKER_INPUT="$tmp/clean.txt" run sh "$probe" --case D1 --results "$tmp/env.tsv" \
  --snapshot-dir "$tmp/s-env" 2>&1)
assert_eq "$?" "0" "ac-9 AB_DOCKER_INPUT replays without a device"
assert_contains "$out" "replay=$tmp/clean.txt" "ac-9 the run says where the facts came from"
case "$out" in
  *"dry-run: ssh"*) assert_eq "ssh" "no ssh" "ac-9 a replay must not ssh" ;;
  *) assert_eq "no ssh" "no ssh" "ac-9 a replay must not ssh" ;;
esac

# --------------------------------------------------------------------------- #
# ac-9: --json is one object per line and carries the same verdicts
# --------------------------------------------------------------------------- #
rm -rf "$tmp/s-json"
out=$(run sh "$probe" --input "$tmp/clean.txt" --json --results "$tmp/json.tsv" \
  --snapshot-dir "$tmp/s-json" 2>&1)
assert_eq "$?" "0" "ac-9 --json exits 0 on a healthy hop"
assert_contains "$out" '{"case":"D1","verdict":"PASS"' "ac-9 the D1 verdict is a JSON object"
assert_contains "$out" '{"kind":"summary","result":"pass"' "ac-9 the summary is a JSON object"
assert_eq "$(printf '%s\n' "$out" | grep -c '^{' )" \
          "$(printf '%s\n' "$out" | grep -c . )" \
          "ac-9 --json prints only JSON objects"
# same rows as the human run, so the two shapes cannot disagree
assert_eq "$(cut -f1,2 "$tmp/json.tsv" | tr '\n' ',')" \
          "$(cut -f1,2 "$tmp/clean.tsv" | tr '\n' ',')" \
          "ac-9 --json and the human report write the same results rows"

# --------------------------------------------------------------------------- #
# ac-9: the script stays POSIX sh
# --------------------------------------------------------------------------- #
if command -v dash >/dev/null 2>&1; then
  assert_command_ok "ac-9 docker-probe.sh parses under dash" dash -n "$probe"
else
  assert_command_ok "ac-9 docker-probe.sh parses under sh" sh -n "$probe"
fi
case "$(cat "$probe")" in
  *'<<<'*|*'pipefail'*|*'BASH_SOURCE'*)
    assert_eq "bashism" "posix sh" "ac-9 no bash-isms in the device script" ;;
  *) assert_eq "posix sh" "posix sh" "ac-9 no bash-isms in the device script" ;;
esac

finish
