#!/usr/bin/env bash
# Module: ci
# The same-base half of the upgrade gates, graded from facts alone.
#
# The cross gate proves "release N installs over release N-1". It never reads a base or a
# kernel, so a release that moved the upstream base while every slot fact stayed healthy
# would pass it and publish, and the update prompt would keep claiming a patch range was
# covered. This file grades the stage that adds those facts - scripts/ci/release-same-base.sh -
# offline, from fixture directories, with `gh` replaced by a stub:
#
#   ac-5  select: the previous release is the newest published platform release below this
#         one, the image is named from *its* base, and the digest is the one its own
#         SHA256SUMS lists (two releases publish identically named images)
#   ac-5  select: no previous release, an index-less release, a missing SHA256SUMS entry and
#         a tag that disagrees with its index are failures, never skips
#   ac-5  fetch: an asset is accepted only when its bytes hash to the published digest
#   ac-5  judge: the four criteria - same base, same kernel, payload really changed,
#         platform moves forward - each fail on their own fact
#   ac-5  judge: a missing old index, a missing checksum entry and a missing new manifest are
#         reasons, and the verdict is one line a workflow can read
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

script="$root/scripts/ci/release-same-base.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The three real release identities this gate was built against. They are not invented:
# `gh release view v0.0.9/v0.0.10 --json assets` and the two releases' own index.txt are
# what showed that the image file name is the base's, not the platform's, and that it is
# therefore identical in both releases.
asset_old="n5105-ab-25.12.2-install.img.gz"
sha_v09_image="904692ef76d98b23adc0f54ea8e8dcedffb7b1872861ffda7db5d909f840ac31"
sha_v09_payload="b5cab55c9c7f85cf777727e9ff56f18d492a6bbd61e295ea3c0b5848e8715c91"
sha_v10_image="651997b1b0048e517d99fdb9f73ddd555b5de87e8278add5672a9f6b547c4d28"
sha_v10_payload="50d9d2bdbf5b67636966f7f9a51e9b5019502c2ba0979183fc76156a0d784e22"
sha_new_payload="1111111111111111111111111111111111111111111111111111111111111111"

# write_index <file> <platform> <base> <kernel> <payload> <size> <sha256>
write_index() {
  local file=$1 platform=$2 base=$3 kernel=$4 payload=$5 size=$6 sha=$7
  {
    printf 'AB-FEED 1\n'
    printf 'channel   stable\n'
    printf 'generated 2026-11-15T00:00:00Z\n'
    printf 'entry\n'
    printf '  %-8s %s\n' platform "${platform}"
    printf '  %-8s %s\n' base "${base}"
    printf '  %-8s %s\n' kernel "${kernel}"
    printf '  %-8s %s\n' payload "${payload}"
    printf '  %-8s %s\n' size "${size}"
    printf '  %-8s %s\n' sha256 "${sha}"
    printf 'end\n'
  } >"$file"
}

# write_sums <file> <image-sha> <payload-sha>
write_sums() {
  {
    printf '%s  %s\n' "$2" "${asset_old}"
    printf '%s  %s\n' "$3" "n5105-ab-25.12.2-upgrade.tar"
    printf '%s  %s\n' "2222222222222222222222222222222222222222222222222222222222222222" \
      "n5105-ab-25.12.2-install-wan-ssh.img.gz"
  } >"$1"
}

# A release fixture directory: the two files `gh release download` would have fetched.
mk_release() {
  local dir=$1 platform=$2 base=$3 kernel=$4 payload_sha=$5 image_sha=$6
  mkdir -p "$dir"
  write_index "$dir/index.txt" "${platform}" "${base}" "${kernel}" \
    "n5105-ab-${base}-upgrade.tar" 23603200 "${payload_sha}"
  write_sums "$dir/SHA256SUMS" "${image_sha}" "${payload_sha}"
}

# gh_stub <fixture-root>: a stand-in for the GitHub CLI. `release download` copies from the
# fixture root, `release list` answers the tag list - exactly the two calls the stage makes,
# and nothing else: a stub that answered more would hide a call the stage should not make.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "release list")
    cat "${GH_FIXTURE_DIR}/tags.txt"
    ;;
  "release download")
    tag="$3"; shift 3
    dest=""
    patterns=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p) patterns+=("$2"); shift 2 ;;
        -D) dest="$2"; shift 2 ;;
        --clobber) shift ;;
        *) shift ;;
      esac
    done
    [ -n "$dest" ] || { echo "stub: no destination" >&2; exit 2; }
    mkdir -p "$dest"
    for pattern in "${patterns[@]}"; do
      src="${GH_FIXTURE_DIR}/${tag}/${pattern}"
      # gh's own words for a pattern that matches nothing: the stage tells a missing asset
      # apart from a network failure by them, so a stub that invented its own wording would
      # make the distinction untested.
      [ -f "$src" ] || { echo "no assets match the file pattern: ${pattern}" >&2; exit 1; }
      cp "$src" "${dest}/${pattern}"
    done
    ;;
  *)
    echo "stub: unsupported gh invocation: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# run_stage <subcommand> [args...]: the stage with the stub gh, and its answer on stdout.
# The environment is built from scratch so a variable the test sets cannot leak into the
# stage's own defaults (CI_OUTPUT_ENV in particular: the stage writes its outputs there).
run_stage() {
  env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY \
    PATH="$tmp/bin:$PATH" \
    GH_FIXTURE_DIR="$tmp/fx" CI_GH="$tmp/bin/gh" CI_TMP_ROOT="$tmp/ci" \
    CI_OUTPUT_ENV="$tmp/out.env" \
    bash "$script" "$@" 2>&1
}

# ---- select --------------------------------------------------------------- #

# Two published releases whose image file names are identical (both derived from base
# 25.12.2). The newer one wins, and its digest is the one its own SHA256SUMS carries - not
# the older release's, which the same file name would otherwise invite.
fx="$tmp/fx"
mk_release "$fx/v0.0.9" 0.0.9 25.12.2 6.12.103 "${sha_v09_payload}" "${sha_v09_image}"
mk_release "$fx/v0.0.10" 0.0.10 25.12.2 6.12.103 "${sha_v10_payload}" "${sha_v10_image}"
printf 'v0.0.10\nv0.0.9\n' >"$fx/tags.txt"

select_out="$tmp/select"
select_text="$(run_stage select --version 0.0.11 --out "$select_out")"
assert_eq "$?" "0" "ac-5 select finds the previous release"
assert_contains "$select_text" "tag=v0.0.10" \
  "ac-5 the previous release is the newest published platform release below this one"
assert_contains "$select_text" "asset=${asset_old}" \
  "ac-5 the image is named from the release's base, not from its platform version"
assert_contains "$select_text" "sha256=${sha_v10_image}" \
  "ac-5 the digest is the one the selected tag's own SHA256SUMS lists"
assert_eq "$(grep -c 'v0.0.9' "$select_out/SHA256SUMS" 2>/dev/null || true)" "0" \
  "ac-5 the selected release's files are what was downloaded, not an earlier release's"
assert_file_exists "$select_out/index.txt" "ac-5 the index the criteria are graded from is downloaded"
assert_file_exists "$select_out/SHA256SUMS" "ac-5 and so is the checksum file that names the image"

# The outputs are the workflow's interface: the caller must not have to parse the log.
select_outputs="$(cat "$tmp/out.env" 2>/dev/null)"
for key in tag platform base kernel asset sha256 index sums; do
  assert_contains "$select_outputs" "${key}=" "ac-5 select emits ${key} as an output"
done

# `--previous-tag` overrides the search: a caller pinning the release it wants to prove the
# upgrade from is not second-guessed, and the tag is still verified against its own index.
pinned_text="$(run_stage select --version 0.0.11 --previous-tag v0.0.9 --out "$tmp/select-pinned")"
assert_contains "$pinned_text" "tag=v0.0.9" "ac-5 an explicit previous tag is used as given"
assert_contains "$pinned_text" "sha256=${sha_v09_image}" \
  "ac-5 and its digest is the pinned tag's own, not the newest release's"

# No previous release: a failure, with a reason, never a skip. A gate that cannot judge is
# not a pass, and `release.yml` publishes only after the gate is green.
mkdir -p "$tmp/fx-empty"
printf 'v0.0.10\n' >"$tmp/fx-empty/tags.txt"
GH_FIXTURE_DIR="$tmp/fx-empty"
empty_text="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY PATH="$tmp/bin:$PATH" \
  GH_FIXTURE_DIR="$tmp/fx-empty" CI_GH="$tmp/bin/gh" CI_TMP_ROOT="$tmp/ci" \
  CI_OUTPUT_ENV="$tmp/out.env" bash "$script" select --version 0.0.10 --out "$tmp/select-empty" 2>&1)"
assert_eq "$?" "1" "ac-5 a release with nothing below it fails the selector"
assert_contains "$empty_text" "same-base=fail reason=no-previous-platform-release" \
  "ac-5 the failure names the missing previous release"

# An index-less previous release is the state a release is in when the build could not name
# its kernel package. The gate cannot grade a base it cannot read, so this is a failure.
fx_noindex="$tmp/fx-noindex"
mk_release "$fx_noindex/v0.0.10" 0.0.10 25.12.2 6.12.103 "${sha_v10_payload}" "${sha_v10_image}"
rm -f "$fx_noindex/v0.0.10/index.txt"
printf 'v0.0.10\n' >"$fx_noindex/tags.txt"
noindex_text="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY PATH="$tmp/bin:$PATH" \
  GH_FIXTURE_DIR="$fx_noindex" CI_GH="$tmp/bin/gh" CI_TMP_ROOT="$tmp/ci" \
  CI_OUTPUT_ENV="$tmp/out.env" bash "$script" select --version 0.0.11 --out "$tmp/select-noindex" 2>&1)"
assert_eq "$?" "1" "ac-5 a previous release without an index fails the selector"
assert_contains "$noindex_text" "same-base=fail reason=previous-release-has-no-index" \
  "ac-5 the failure names the missing index"

# A release whose SHA256SUMS does not cover the image it published: the digest is the whole
# point of the tag, so the gate refuses rather than booting unverified bytes.
fx_nosums="$tmp/fx-nosums"
mk_release "$fx_nosums/v0.0.10" 0.0.10 25.12.2 6.12.103 "${sha_v10_payload}" "${sha_v10_image}"
printf '%s  n5105-ab-25.12.2-upgrade.tar\n' "${sha_v10_payload}" >"$fx_nosums/v0.0.10/SHA256SUMS"
printf 'v0.0.10\n' >"$fx_nosums/tags.txt"
nosums_text="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY PATH="$tmp/bin:$PATH" \
  GH_FIXTURE_DIR="$fx_nosums" CI_GH="$tmp/bin/gh" CI_TMP_ROOT="$tmp/ci" \
  CI_OUTPUT_ENV="$tmp/out.env" bash "$script" select --version 0.0.11 --out "$tmp/select-nosums" 2>&1)"
assert_eq "$?" "1" "ac-5 a checksum file without the image fails the selector"
assert_contains "$nosums_text" "same-base=fail reason=sums-has-no-entry-for-the-image" \
  "ac-5 the failure names the uncovered asset"

# The tag and the index it shipped under have to agree: the tag is how the asset is fetched
# and the index is how the base is read, so a release that disagrees with itself is not one
# this gate can identify.
fx_mismatch="$tmp/fx-mismatch"
mk_release "$fx_mismatch/v0.0.10" 0.0.9 25.12.2 6.12.103 "${sha_v10_payload}" "${sha_v10_image}"
printf 'v0.0.10\n' >"$fx_mismatch/tags.txt"
mismatch_text="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY PATH="$tmp/bin:$PATH" \
  GH_FIXTURE_DIR="$fx_mismatch" CI_GH="$tmp/bin/gh" CI_TMP_ROOT="$tmp/ci" \
  CI_OUTPUT_ENV="$tmp/out.env" bash "$script" select --version 0.0.11 --out "$tmp/select-mismatch" 2>&1)"
assert_eq "$?" "1" "ac-5 a release whose index disagrees with its tag fails the selector"
assert_contains "$mismatch_text" "same-base=fail reason=tag-and-index-disagree" \
  "ac-5 the failure names the disagreement"

# ---- fetch ---------------------------------------------------------------- #

# The stub serves fixture bytes; the digest the selector read is what decides whether they
# are the image the release published.
fetch_dir="$tmp/fetch-fx/v0.0.10"
mkdir -p "$fetch_dir"
printf 'the image v0.0.10 published\n' >"$fetch_dir/${asset_old}"
real_sha="$(shasum -a 256 "$fetch_dir/${asset_old}" | cut -d' ' -f1)"

fetch_text="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY PATH="$tmp/bin:$PATH" \
  GH_FIXTURE_DIR="$tmp/fetch-fx" CI_GH="$tmp/bin/gh" CI_TMP_ROOT="$tmp/ci" \
  CI_OUTPUT_ENV="$tmp/fetch.env" bash "$script" fetch \
  --tag v0.0.10 --asset "${asset_old}" --sha256 "${real_sha}" --dest "$tmp/fetch-ok" 2>&1)"
assert_eq "$?" "0" "ac-5 fetch accepts an image that hashes to the published digest"
assert_contains "$fetch_text" "sha256=${real_sha}" "ac-5 and reports the digest it verified"
assert_file_exists "$tmp/fetch-ok/${asset_old}" "ac-5 the image lands where the caller asked"
fetch_outputs="$(cat "$tmp/fetch.env" 2>/dev/null)"
for key in path sha256 size; do
  assert_contains "$fetch_outputs" "${key}=" "ac-5 fetch emits ${key} as an output"
done

# A tag whose bytes are not the digest it published (a re-uploaded asset, a truncated
# download, a wrong release): the gate must not boot it. The file is still written - the
# point is to report what arrived - but the verdict is a failure and the exit status is 1.
truncated_text="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY PATH="$tmp/bin:$PATH" \
  GH_FIXTURE_DIR="$tmp/fetch-fx" CI_GH="$tmp/bin/gh" CI_TMP_ROOT="$tmp/ci" \
  CI_OUTPUT_ENV="$tmp/fetch.env" bash "$script" fetch \
  --tag v0.0.10 --asset "${asset_old}" --sha256 "${sha_v10_image}" --dest "$tmp/fetch-bad" 2>&1)"
assert_eq "$?" "1" "ac-5 fetch refuses bytes that do not hash to the published digest"
assert_contains "$truncated_text" "same-base=fail reason=image-digest-mismatch" \
  "ac-5 the refusal names the digest mismatch"
assert_contains "$truncated_text" "expected=${sha_v10_image}" \
  "ac-5 the refusal states the digest the release published"
assert_contains "$truncated_text" "got=${real_sha}" \
  "ac-5 and the digest of the bytes that arrived"

# An asset the tag does not carry: also a failure with a reason, not an empty success.
missing_text="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY PATH="$tmp/bin:$PATH" \
  GH_FIXTURE_DIR="$tmp/fetch-fx" CI_GH="$tmp/bin/gh" CI_TMP_ROOT="$tmp/ci" \
  CI_OUTPUT_ENV="$tmp/fetch.env" bash "$script" fetch \
  --tag v0.0.10 --asset n5105-ab-99.99.99-install.img.gz \
  --sha256 "${real_sha}" --dest "$tmp/fetch-missing" 2>&1)"
assert_eq "$?" "1" "ac-5 fetch refuses an asset the tag does not carry"
assert_contains "$missing_text" "same-base=fail reason=cannot-download-the-image" \
  "ac-5 the failure names the download, not an empty directory"

# ---- judge: the four criteria --------------------------------------------- #

# judge_facts <dir>: a facts directory that passes every criterion. The old side is v0.0.10's
# real published index and checksums; the new side is a payload from a 0.0.11 build on the
# same base and kernel.
judge_facts() {
  local dir=$1
  mkdir -p "$dir"
  write_index "$dir/old-index.txt" 0.0.10 25.12.2 6.12.103 \
    "n5105-ab-25.12.2-upgrade.tar" 23603200 "${sha_v10_payload}"
  write_sums "$dir/old-SHA256SUMS" "${sha_v10_image}" "${sha_v10_payload}"
  printf '{"format":"ab-payload/1","rootfs":"25.12.2","kernel":"6.12.103~deadbeef-r1","platform":"0.0.11"}\n' \
    >"$dir/new-manifest.json"
  printf '%s\n' "${sha_new_payload}" >"$dir/new-payload.sha256"
  printf '23800000\n' >"$dir/new-payload.size"
  printf '0.0.11\n' >"$dir/new-version"
  printf '25.12.2\n' >"$dir/new-pin"
}

judge() { bash "$script" judge --dir "$1" 2>&1; }

good="$tmp/judge-good"
judge_facts "$good"
good_text="$(judge "$good")"
assert_eq "$?" "0" "ac-5 judge completes on a same-base fixture"
assert_contains "$good_text" "same-base=ok" "ac-5 a same-base upgrade grades ok"
for criterion in base kernel payload-differs platform-advances; do
  assert_contains "$good_text" "same-base-check ${criterion}=ok" \
    "ac-5 the ok verdict names ${criterion} as graded and passed"
done
assert_contains "$good_text" "old=0.0.10 new=0.0.11" "ac-5 the verdict names both platform versions"

# 1. The base moved. The old image runs a different upstream base than this release pins;
#    the "patch range" the update prompt claims no longer covers this upgrade. The payload
#    name and its digest stay the same on purpose: the base is the one fact under test, and
#    a fixture that changed two things would not say which criterion fired.
base="$tmp/judge-base"
judge_facts "$base"
write_index "$base/old-index.txt" 0.0.10 25.12.1 6.12.103 \
  "n5105-ab-25.12.2-upgrade.tar" 23603200 "${sha_v10_payload}"
assert_contains "$(judge "$base")" "same-base=fail reason=base-is-not-the-pin" \
  "ac-5 an old release on another base fails the same-base gate"

# 2. The kernel moved while the base did not: the packages of the candidate slot are
#    modules for a kernel the old image did not run, which is a different claim entirely.
kernel="$tmp/judge-kernel"
judge_facts "$kernel"
printf '{"format":"ab-payload/1","rootfs":"25.12.2","kernel":"6.12.104~deadbeef-r1","platform":"0.0.11"}\n' \
  >"$kernel/new-manifest.json"
assert_contains "$(judge "$kernel")" "same-base=fail reason=kernel-is-not-the-payload-kernel" \
  "ac-5 a payload built for another kernel fails the same-base gate"

# 3. The payload digest did not move: the "new" artifact is the old one, so the install
#    proves nothing about a patch range whatever the slot state says.
payload="$tmp/judge-payload"
judge_facts "$payload"
printf '%s\n' "${sha_v10_payload}" >"$payload/new-payload.sha256"
assert_contains "$(judge "$payload")" "same-base=fail reason=payload-digest-did-not-change" \
  "ac-5 a payload identical to the previous release's fails the same-base gate"

# 4. The platform version did not move forward (here: it moved backwards). A downgrade is
#    not the upgrade the gate exists to prove.
downgrade="$tmp/judge-downgrade"
judge_facts "$downgrade"
printf '0.0.9\n' >"$downgrade/new-version"
assert_contains "$(judge "$downgrade")" "same-base=fail reason=platform-did-not-advance" \
  "ac-5 a platform version that does not move forward fails the same-base gate"

# The comparison is numeric, segment by segment: 0.0.10 is after 0.0.9, which a string sort
# would get backwards - and a string compare here would call a forward release a downgrade.
ordering="$tmp/judge-ordering"
judge_facts "$ordering"
write_index "$ordering/old-index.txt" 0.0.9 25.12.2 6.12.103 \
  "n5105-ab-25.12.2-upgrade.tar" 23603200 "${sha_v09_payload}"
write_sums "$ordering/old-SHA256SUMS" "${sha_v09_image}" "${sha_v09_payload}"
printf '0.0.10\n' >"$ordering/new-version"
assert_contains "$(judge "$ordering")" "same-base-check platform-advances=ok old=0.0.9 new=0.0.10" \
  "ac-5 0.0.10 comes after 0.0.9, as numbers rather than as strings"

# ---- judge: the deficiencies that are reasons, not crashes ----------------- #

# No old index at all: the gate has nothing to grade the base from.
missing="$tmp/judge-missing-index"
judge_facts "$missing"
rm -f "$missing/old-index.txt"
assert_contains "$(judge "$missing")" "same-base=fail reason=old-index-missing" \
  "ac-5 a missing previous index is a reason"

# A checksum file whose payload line disagrees with the index beside it: one of the two is
# stale, and the gate cannot tell which - so it refuses both.
badsums="$tmp/judge-bad-sums"
judge_facts "$badsums"
printf '%s  n5105-ab-25.12.2-upgrade.tar\n' \
  "3333333333333333333333333333333333333333333333333333333333333333" >"$badsums/old-SHA256SUMS"
assert_contains "$(judge "$badsums")" "same-base=fail reason=old-sha256sums-do-not-match-the-index" \
  "ac-5 an old checksum file that disagrees with its index is a reason"

# The new payload's manifest is what names the kernel the candidate ships.
nomanifest="$tmp/judge-no-manifest"
judge_facts "$nomanifest"
rm -f "$nomanifest/new-manifest.json"
assert_contains "$(judge "$nomanifest")" "same-base=fail reason=new-payload-manifest-missing" \
  "ac-5 a new payload without a manifest is a reason"

# Missing SHA256SUMS for the previous release, which is the state of any release published
# before the gate existed: still a failure, because the image cannot be verified.
nosums_judge="$tmp/judge-no-sums"
judge_facts "$nosums_judge"
rm -f "$nosums_judge/old-SHA256SUMS"
assert_contains "$(judge "$nosums_judge")" "same-base=fail reason=old-sha256sums-missing" \
  "ac-5 a previous release without checksums is a reason"

# The payload's identity can be measured from the artifact itself: a caller that hands over
# the tar cannot state a digest the bytes do not have, and the manifest is read out of it.
tar_dir="$tmp/judge-tar"
mkdir -p "$tar_dir"
write_index "$tar_dir/old-index.txt" 0.0.10 25.12.2 6.12.103 \
  "n5105-ab-25.12.2-upgrade.tar" 23603200 "${sha_v10_payload}"
write_sums "$tar_dir/old-SHA256SUMS" "${sha_v10_image}" "${sha_v10_payload}"
printf '0.0.11\n' >"$tar_dir/new-version"
printf '25.12.2\n' >"$tar_dir/new-pin"
payload_stage="$tmp/judge-tar-payload"
mkdir -p "$payload_stage"
printf 'a kernel for 6.12.103\n' >"$payload_stage/kernel.bin"
printf 'an initramfs\n' >"$payload_stage/initramfs.cpio.gz"
printf '{"format":"ab-payload/1","rootfs":"25.12.2","kernel":"6.12.103~deadbeef-r1","platform":"0.0.11"}\n' \
  >"$payload_stage/manifest.json"
tar -cf "$tmp/judge-new-payload.tar" -C "$payload_stage" manifest.json kernel.bin initramfs.cpio.gz
tar_text="$(bash "$script" judge --dir "$tar_dir" --new-payload "$tmp/judge-new-payload.tar" 2>&1)"
assert_contains "$tar_text" "same-base=ok" \
  "ac-5 judge measures the new payload's identity from the artifact it is given"
assert_contains "$tar_text" "kernel=6.12.103" \
  "ac-5 the kernel comes from the manifest inside the payload tar"

# ---- the verdict is one line, and it is always printed -------------------- #

# A workflow reads one line per criterion and one verdict; a failure that printed nothing
# would leave the gate red with no fact attached, which is the failure mode the cross stage
# already paid for (run 43588155580).
for case_dir in "$good" "$base" "$kernel" "$payload" "$downgrade" "$missing"; do
  lines="$(bash "$script" judge --dir "$case_dir" 2>&1 | grep -c '^same-base=' || true)"
  assert_eq "${lines}" "1" "ac-5 $(basename "$case_dir") prints exactly one same-base verdict line"
done

# It never exits non-zero on a graded failure: the verdict is the interface, exactly as in
# cross-upgrade.sh, so a caller that captures stdout still gets the reason.
bash "$script" judge --dir "$base" >/dev/null 2>&1
assert_eq "$?" "0" "ac-5 a graded same-base failure still exits 0, so its verdict is readable"

finish
