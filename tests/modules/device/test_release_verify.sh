#!/usr/bin/env bash
# Module: device
# The release verifier (scripts/device/release-verify.sh) against directories, not a forge.
#
# What is under test is which release the script reads and what it refuses to read:
#   * the tag it derives when the caller names none, which is `v` + the repository's VERSION
#     line and nothing else -- a round that hands it a variable holding the upstream base
#     must not be able to make `v25.12.2` look like this project's release;
#   * a tag whose version sits on another line than the repository's, which is a caller
#     defect and is refused before any download with both versions named (the full round of
#     2026-11-19 recorded exactly that as an ac-1 FAIL, `reason=no-such-release`);
#   * the two callers that legitimately name an older release, which state it with --version
#     or with a tag git can still read, and are not refused.
#
# Every case runs with --dir, so no packet is sent and no gh is needed: a verdict about
# tag handling must be reproducible on a machine with no network at all.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

script="$root/scripts/device/release-verify.sh"
assert_file_exists "$script" "the release verifier exists"
out=$(sh -n "$script" 2>&1)
assert_eq "$?" "0" "the verifier parses under sh, the shell the drivers run with: $out"

# --- the release bytes, as a directory -------------------------------------- #
# One base, one platform version, and the payload digest repeated in index.txt: the shape
# release-verify.sh reads, so a run against it is a real verdict rather than a folder of
# skips.
sha_of() { # <file>
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

make_assets() { # <dir> <platform version>
    local d=$1 pv=$2 size sha_img sha_tar sha_index
    mkdir -p "$d"
    printf 'image bytes\n' >"$d/n5105-ab-25.12.2-install-wan-ssh.img.gz"
    printf 'payload bytes\n' >"$d/n5105-ab-25.12.2-upgrade.tar"
    size=$(wc -c <"$d/n5105-ab-25.12.2-upgrade.tar" | tr -d ' ')
    sha_img=$(sha_of "$d/n5105-ab-25.12.2-install-wan-ssh.img.gz")
    sha_tar=$(sha_of "$d/n5105-ab-25.12.2-upgrade.tar")
    cat >"$d/index.txt" <<EOF
AB-FEED 1
channel stable
entry
platform ${pv}
base 25.12.2
kernel 6.12.103
payload n5105-ab-25.12.2-upgrade.tar
size ${size}
sha256 ${sha_tar}
end
EOF
    sha_index=$(sha_of "$d/index.txt")
    cat >"$d/SHA256SUMS" <<EOF
${sha_img}  n5105-ab-25.12.2-install-wan-ssh.img.gz
${sha_tar}  n5105-ab-25.12.2-upgrade.tar
${sha_index}  index.txt
EOF
}

# A repository root the verifier can read a VERSION from, without touching this checkout.
# AB_REPO_ROOT is the script's own override, which is what makes the derivation testable
# at all: the script derives from the tree it is told about.
make_repo() { # <dir> <version>
    mkdir -p "$1"
    printf '%s\n' "$2" >"$1/VERSION"
}

rv() { # <repo root> [args...]
    local repo=$1
    shift
    AB_REPO_ROOT="$repo" sh "$script" "$@"
}

assets="$tmp/assets"
make_assets "$assets" 0.0.13
repo="$tmp/repo"
make_repo "$repo" 0.0.13

# --- the tag a caller does not name ----------------------------------------- #
# The round's release phase is supposed to hand over nothing when it has no candidate, and
# the script then reads VERSION. This is the assertion that makes the round's own tag
# provable: VERSION=0.0.13 has to produce v0.0.13, not the base of the release it verifies.
out=$(rv "$repo" --dir "$assets" 2>&1)
rc=$?
assert_eq "$rc" "0" "a release directory that matches VERSION verifies without a tag given"
assert_contains "$out" "release-verify tag=v0.0.13 " \
    "the tag is derived from VERSION: 0.0.13 -> v0.0.13"
assert_eq "$(printf '%s\n' "$out" | grep -c 'tag=v25.12.2')" "0" \
    "the derived tag never carries the upstream base"

# The derivation follows the file and not a version baked into the script: a tree whose
# VERSION is another number is read as that number. This is what makes the phase's own
# variable the only thing that can be wrong -- which it was.
repo_other="$tmp/repo-other"
make_repo "$repo_other" 0.0.14
out=$(rv "$repo_other" --dir "$assets" 2>&1)
assert_contains "$out" "release-verify tag=v0.0.14 " \
    "the derived tag follows VERSION rather than a constant in the script"

# --- a tag from another version line is refused ------------------------------ #
# The upstream base read back as a tag: no release of this repository can carry it, so the
# question is not "does the release exist" but "why was this tag derived". Refused as
# usage (exit 2) with both numbers, and no check is made against the bytes.
out=$(rv "$repo" --dir "$assets" --tag v25.12.2 2>&1)
rc=$?
assert_eq "$rc" "2" "a tag naming the upstream base is a usage error, not a release failure"
assert_contains "$out" "result=none reason=tag-not-of-this-repository" \
    "the refusal is a no-verdict, which the round records as GAP and not as a red release"
assert_contains "$out" "tag-version=25.12.2" "the refused tag is named"
assert_contains "$out" "repo-version=0.0.13" "the version this repository is on is named beside it"
assert_eq "$(printf '%s\n' "$out" | grep -c 'check=')" "0" \
    "nothing is judged against the bytes when the tag cannot be this repository's"
# The same tag on a directory that would otherwise pass: the refusal is about the tag, not
# about the assets, so a complete release directory does not turn it green either.
assert_eq "$(printf '%s\n' "$out" | grep -c 'result=pass')" "0" \
    "a matching asset directory does not make a foreign tag pass"

# A tag without the v prefix is left alone: the upstream line tags its own bases in its own
# repository, and this script has nothing to compare there. It is not the case above.
out=$(rv "$repo" --dir "$assets" --tag 25.12.2 2>&1)
rc=$?
assert_eq "$(printf '%s\n' "$out" | grep -c 'reason=tag-not-of-this-repository')" "0" \
    "a tag with no v prefix is not read as one of this repository's release tags"

# --- the two callers that name an older release ------------------------------ #
# A chain that walks earlier hops states the version it expects. That statement is a claim
# the script checks, so the tag is not refused for sitting on its own line.
out=$(rv "$repo" --dir "$assets" --tag v25.12.2 --version 25.12.2 2>&1)
assert_eq "$(printf '%s\n' "$out" | grep -c 'reason=tag-not-of-this-repository')" "0" \
    "an explicit --version is the caller's claim, so the tag is judged against it"

# The shape matrix-round2.sh's REL case uses: an older release of the same line, stated.
out=$(rv "$repo" --dir "$assets" --tag v0.0.12 --version 0.0.12 2>&1)
assert_eq "$(printf '%s\n' "$out" | grep -c 'reason=tag-not-of-this-repository')" "0" \
    "an older release of this line is read, not refused"

# An old tag git can still read is ours, whatever VERSION says today: the project can move
# to a new line and its published releases stay verifiable. Without git this case cannot be
# built, so it is skipped rather than assumed.
if command -v git >/dev/null 2>&1; then
    repo_git="$tmp/repo-git"
    make_repo "$repo_git" 0.0.12
    mkdir -p "$repo_git/.git"
    (
        cd "$repo_git" || exit 1
        git init -q .
        git config user.email test@example.invalid
        git config user.name test
        git add VERSION
        git commit -qm 'v0.0.12'
        git tag v0.0.12
    ) >/dev/null 2>&1
    printf '0.1.0\n' >"$repo_git/VERSION"
    out=$(rv "$repo_git" --dir "$assets" --tag v0.0.12 2>&1)
    assert_eq "$(printf '%s\n' "$out" | grep -c 'reason=tag-not-of-this-repository')" "0" \
        "a tag whose own VERSION git can read is one of this repository's releases"
    out=$(rv "$repo_git" --dir "$assets" --tag v25.12.2 2>&1)
    assert_contains "$out" "reason=tag-not-of-this-repository" \
        "the same tree still refuses a tag that is neither in git nor on its line"
fi

# --- a tree with no VERSION -------------------------------------------------- #
# Nothing to compare against, so nothing is refused: the script says so with exit 2 and the
# reason, rather than deriving a tag from an empty file.
repo_empty="$tmp/repo-empty"
mkdir -p "$repo_empty"
out=$(rv "$repo_empty" --dir "$assets" 2>&1)
rc=$?
assert_eq "$rc" "2" "a tree with no VERSION and no --tag is a usage error"
assert_contains "$out" "no --tag and no VERSION" "the missing file is named"

# --- a preview tag: the publisher's rule, read back -------------------------- #
# release-publish.yml accepts v<X.Y.Z>-rc.<N> over VERSION X.Y.Z: a preview is the same bytes
# with a pre-release suffix on the tag, and it is published as a GitHub pre-release. Until this
# test existed the read-back side compared the two strings for equality, so every preview came
# back as tag-version=fail against a release that had been published correctly - and the round
# that found it (2026-11-20) was told its release was wrong when only the checker was.
repo_prev="$tmp/repo-prev"
make_repo "$repo_prev" 0.1.0
prev_assets="$tmp/assets-prev"
make_assets "$prev_assets" 0.1.0

out=$(rv "$repo_prev" --dir "$prev_assets" --tag v0.1.0-rc.1 --version 0.1.0 2>&1)
rc=$?
assert_eq "$rc" "0" "a preview tag of this version verifies"
assert_contains "$out" "check=tag-version result=pass tag=v0.1.0-rc.1 version=0.1.0" \
    "the preview tag is judged against the base version, as the publisher judges it"
assert_contains "$out" "preview=rc.1" "the row says which preview it is"
assert_contains "$out" "release-verify result=pass checks=" \
    "every other check still passes, so the suffix changes nothing else"

# The suffix is not a wildcard: a preview of a different version is still not this release.
out=$(rv "$repo_prev" --dir "$prev_assets" --tag v0.0.9-rc.1 --version 0.1.0 2>&1)
rc=$?
assert_eq "$rc" "1" "a preview tag of another version fails"
assert_contains "$out" "check=tag-version result=fail tag=v0.0.9-rc.1 version=0.1.0" \
    "... and the row names both versions, so the reader sees which is which"

# A tag with no suffix keeps the rule it always had, and is not called a preview.
out=$(rv "$repo_prev" --dir "$prev_assets" --tag v0.1.0 --version 0.1.0 2>&1)
rc=$?
assert_eq "$rc" "0" "a plain tag of this version still passes"
assert_eq "$(printf '%s\n' "$out" | grep -c 'preview=')" "0" \
    "a plain release is not described as a preview"
out=$(rv "$repo_prev" --dir "$prev_assets" --tag v0.0.9 --version 0.1.0 2>&1)
rc=$?
assert_eq "$rc" "1" "a plain tag of another version still fails"

finish
