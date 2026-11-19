#!/bin/sh
# release-verify.sh - read a published release back and check it against ac-1.
#
# ac-1 is one sentence with four mechanical claims, and this script is those four
# checks and nothing else. Every check below is annotated with the clause it answers:
#
#   (i)   the tag and VERSION agree
#           the tag `v0.0.9` names `0.0.9`, and the VERSION file *at that tag* says 0.0.9
#   (ii)  the release carries four assets
#           image-install-wan-ssh / payload-<base>.tar / index.txt / SHA256SUMS
#           ac-1 names the first two by their CI artifact names; a published release
#           carries them as `n5105-ab-<base>-install-wan-ssh.img.gz` and
#           `n5105-ab-<base>-upgrade.tar` (scripts/ci/release.sh, docs/install.md), so
#           the label printed below is ac-1's name and `name=` is the file on the release
#   (iii) every line of SHA256SUMS matches the bytes beside it, and the two artifacts
#           ac-1 asks for are among the covered files
#   (iv)  index.txt is an AB-FEED 1 index whose entry for this platform declares
#           `platform 0.0.9` and `base 25.12.2` - and whose payload digest is the one
#           the SHA256SUMS beside it carries, so the two cannot drift
#
# The answer is a block of key=value lines, one per check, so a verdict is greppable
# without reading prose:
#
#   release-verify tag=v0.0.9 repo=owner/name source=release dir=/tmp/release-verify.XXXX
#   release-verify check=tag-version result=pass tag=v0.0.9 version=0.0.9 from=git
#   release-verify check=asset result=pass label=image-install-wan-ssh name=n5105-ab-... size=...
#   release-verify check=sums-entry result=pass name=n5105-ab-25.12.2-upgrade.tar sha256=...
#   release-verify check=index-platform result=pass expected=0.0.9 got=0.0.9
#   release-verify result=pass checks=15 failed=0 skipped=0 tag=v0.0.9
#
# A `result=` value is pass, fail or skip. skip means the check could not be made from
# what was available (for example: the tag is unknown locally, so the VERSION file at it
# cannot be read) and is counted, not hidden: the counts are on the last line.
#
# Usage:
#   release-verify.sh [--tag <tag>] [--dir <path>] [--repo <owner/name>]
#                     [--version <x.y.z>] [--base <x.y.z>]
#                     [--work-dir <path>] [--keep]
#
#   --tag        release to read (default: v + the repository's VERSION file)
#   --dir        verify a directory of already downloaded assets; no network at all
#   --repo       owner/name whose releases are read
#   --version    the VERSION this tag should carry, for a caller that cannot reach git
#                or the repository (a fixture, or a tag that only exists remotely)
#   --base       expected upstream base; default is read from the payload's own name
#   --work-dir   where the download lands (default: a fresh temporary directory)
#   --keep       keep the downloaded assets, so a second run can use --dir
#
# Exit status:
#   0  every check passed
#   1  at least one check failed: this release is not the one ac-1 describes
#   2  usage error, including a tag that cannot be a release of this repository at all
#   3  no verdict: the assets could not be obtained (no network, no gh, download failed,
#      or AB_DRY_RUN=1 without a --dir to look at)
#
# Why a wrong tag is exit 2 and not exit 1. A caller that derives the tag from the wrong
# variable asks about a release that never existed, and the answer comes back as
# `reason=no-such-release` - an ac-1 failure against a release nobody published, which
# reads as a product defect when it is a caller defect. The full round of 2026-11-19 did
# exactly that: it passed the upstream base (v25.12.2 where the repository's VERSION line
# is 0.0.x) and the phase recorded a red release row. A tag whose version belongs to
# another version line is therefore refused before anything is downloaded, with the two
# versions named.
#
# AB_DRY_RUN=1 sends no packet: with --dir the local copy is verified as usual, without
# one the script says what it would fetch and exits 3.

set -u

AB_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=${AB_REPO_ROOT:-$(cd "${AB_SCRIPT_DIR}/../.." && pwd)}

# lib.sh is deliberately not sourced here, unlike its neighbours under scripts/device/.
# That file is the device driver: it carries ssh defaults, boot budgets and slot
# assertions, and this script has no machine on the other end - it reads a directory and,
# in --release mode, gh. What it keeps from lib.sh is the shape: one line per fact,
# `field=value` so a reader can grep it, and a failure line that says which command
# produces the same answer again.

usage() {
    cat <<'USAGE'
usage: release-verify.sh [--tag <tag>] [--dir <path>] [--repo <owner/name>]
                         [--version <x.y.z>] [--base <x.y.z>]
                         [--work-dir <path>] [--keep]

  --tag        release to read (default: v + the repository's VERSION file)
  --dir        verify a directory of already downloaded assets; no network
  --repo       owner/name whose releases are read
  --version    the VERSION this tag should carry, when git cannot answer
  --base       expected upstream base (default: read from the payload's own name)
  --work-dir   where the download lands (default: a fresh temporary directory)
  --keep       keep the downloaded assets

Exit: 0 every check passed, 1 at least one failed, 2 usage (including a tag from another
      version line), 3 no verdict (no assets).
USAGE
}

tag=""
assets_dir=""
repo=${AB_RELEASE_REPO:-planetarium1001/n5105-btrfs-ab-firmware}
want_version=""
want_base=""
work=""
keep=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag) tag=${2:?--tag needs a value}; shift 2 ;;
        --dir) assets_dir=${2:?--dir needs a value}; shift 2 ;;
        --repo) repo=${2:?--repo needs a value}; shift 2 ;;
        --version) want_version=${2:?--version needs a value}; shift 2 ;;
        --base) want_base=${2:?--base needs a value}; shift 2 ;;
        --work-dir) work=${2:?--work-dir needs a value}; shift 2 ;;
        --keep) keep=1; shift ;;
        -h | --help | help) usage; exit 0 ;;
        *)
            printf 'release-verify: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "${tag}" ]; then
    if [ ! -f "${AB_REPO_ROOT}/VERSION" ]; then
        printf 'release-verify: no --tag and no VERSION at %s\n' "${AB_REPO_ROOT}/VERSION" >&2
        exit 2
    fi
    tag="v$(tr -d '[:space:]' <"${AB_REPO_ROOT}/VERSION")"
fi

# rv_line_of <version>: the major.minor of a version, or empty when it is not x.y.z.
rv_line_of() {
    printf '%s\n' "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\)\.[0-9][0-9]*$/\1/p'
}

# A tag this repository could not have produced is a caller defect, not a release defect.
#
# This project's release tags are `v` + the VERSION line. An upstream base is a different
# number on a different line, and reading it back as a tag asks the forge about a release
# that was never published; the answer, `reason=no-such-release`, lands in the round as an
# ac-1 failure and was read as a product defect on 2026-11-19. The two versions are
# therefore compared before anything is downloaded, and a tag from another line is refused
# with both of them named.
#
# Two callers legitimately name an older release: a chain that walks earlier hops, and an
# operator reading a published release back. Both state what the tag should carry with
# --version, and that statement is the claim this script checks; without it, git is asked
# which VERSION the tag itself carries, so an old tag still on another line is recognised
# as ours instead of refused. A tag without the `v` prefix is left alone: the upstream line
# tags its own bases in its own repository, and this script has nothing to compare there.
if [ -z "${want_version}" ] && [ -f "${AB_REPO_ROOT}/VERSION" ]; then
    repo_version=$(tr -d '[:space:]' <"${AB_REPO_ROOT}/VERSION")
    tag_version=""
    case "${tag}" in
        v*) tag_version=${tag#v} ;;
    esac
    repo_line=$(rv_line_of "${repo_version}")
    tag_line=$(rv_line_of "${tag_version}")
    if [ -n "${repo_line}" ] && [ -n "${tag_line}" ] && [ "${repo_line}" != "${tag_line}" ] &&
        ! git -C "${AB_REPO_ROOT}" show "${tag}:VERSION" >/dev/null 2>&1; then
        printf 'release-verify: %s names version %s, while this repository is on the %s line (VERSION=%s)\n' \
            "${tag}" "${tag_version}" "${repo_line}" "${repo_version}" >&2
        printf 'release-verify: a release tag here is v + VERSION, so an upstream base is not a tag of this repository; pass --tag v%s, or --version %s when %s really is a release of an older line\n' \
            "${repo_version}" "${tag_version}" "${tag}" >&2
        printf 'release-verify result=none reason=tag-not-of-this-repository tag=%s tag-version=%s repo-version=%s\n' \
            "${tag}" "${tag_version}" "${repo_version}"
        exit 2
    fi
fi

source_kind=release
if [ -n "${assets_dir}" ]; then
    if [ ! -d "${assets_dir}" ]; then
        printf 'release-verify: --dir is not a directory: %s\n' "${assets_dir}" >&2
        exit 2
    fi
    source_kind=dir
fi

# --------------------------------------------------------------------------- #
# The one line per check this script exists to print
# --------------------------------------------------------------------------- #

rv_checks=0
rv_failures=0
rv_skips=0

# rv_ev <text>: one timestamped line in the open evidence log, when there is one.
# Same variable and same line shape as lib.sh's `ev`, so a driver run that sets
# AB_EVIDENCE_LOG collects both kinds of evidence into the same file.
rv_ev() {
    [ -n "${AB_EVIDENCE_LOG:-}" ] || return 0
    printf '%s release-verify %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"${AB_EVIDENCE_LOG}"
}

rv_line() { # <check> <result> [detail]
    rv_checks=$((rv_checks + 1))
    if [ -n "${3:-}" ]; then
        printf 'release-verify check=%s result=%s %s\n' "$1" "$2" "$3"
    else
        printf 'release-verify check=%s result=%s\n' "$1" "$2"
    fi
    case "$2" in
        fail)
            rv_failures=$((rv_failures + 1))
            rv_ev "FAIL check=$1 ${3:-}"
            ;;
        skip) rv_skips=$((rv_skips + 1)); rv_ev "skip check=$1 ${3:-}" ;;
        *) rv_ev "pass check=$1 ${3:-}" ;;
    esac
}

rv_pass() { rv_line "$1" pass "${2:-}"; }
rv_fail() { rv_line "$1" fail "${2:-}"; }
rv_skip() { rv_line "$1" skip "${2:-}"; }

# rv_finish: the verdict, and the exit status a caller branches on.
rv_finish() {
    if [ "${rv_failures}" -gt 0 ]; then
        printf 'release-verify result=fail checks=%s failed=%s skipped=%s tag=%s\n' \
            "${rv_checks}" "${rv_failures}" "${rv_skips}" "${tag}"
        exit 1
    fi
    printf 'release-verify result=pass checks=%s failed=0 skipped=%s tag=%s\n' \
        "${rv_checks}" "${rv_skips}" "${tag}"
    exit 0
}

# rv_no_verdict <reason>: the assets could not be read, so no claim is made about them.
# This is not exit 1 on purpose: an unreachable network is not a broken release.
rv_no_verdict() {
    printf 'release-verify result=none reason=%s tag=%s\n' "$1" "${tag}"
    exit 3
}

rv_size() { wc -c <"$1" | tr -d ' '; }

# rv_sha256 <file>: the digest of one file, with the same two tools flash.sh accepts.
rv_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        return 1
    fi
}

# rv_kv <key=value blob> <key>: one value out of the parsed entry.
rv_kv() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# rv_index_entry <index.txt> <platform>: the key=value block of one entry.
# The device's own parser (platform/lib/ab-feed.sh) reads `entry` ... `end` blocks with
# one `key value` per line and refuses an entry that lacks platform, base or kernel; this
# reads the same shape so a green verdict here means the machine can read it too.
rv_index_entry() {
    awk -v want="$2" '
        function flush() {
            if (plat != "" && plat == want) {
                print "platform=" plat
                print "base=" base
                print "kernel=" kernel
                print "payload=" payload
                print "size=" size
                print "sha256=" sha
            }
            plat = ""; base = ""; kernel = ""; payload = ""; size = ""; sha = ""
        }
        $1 == "entry" { flush(); next }
        $1 == "end" { flush(); next }
        $1 == "platform" { plat = $2; next }
        $1 == "base" { base = $2; next }
        $1 == "kernel" { kernel = $2; next }
        $1 == "payload" { payload = $2; next }
        $1 == "size" { size = $2; next }
        $1 == "sha256" { sha = $2; next }
        END { flush() }
    ' "$1"
}

# --------------------------------------------------------------------------- #
# Where the assets come from
#
# gh is the reader in release mode because a release is a thing this project already
# publishes with it (release-publish.yml); --dir is the same set of checks over a copy
# somebody else made, which is what makes the script usable with no network at all.
# --------------------------------------------------------------------------- #

created_work=0
trap 'if [ "${created_work}" = "1" ] && [ "${keep}" = "0" ]; then rm -rf "${work}"; fi' EXIT
trap 'exit 3' INT TERM

if [ "${source_kind}" = "release" ] && [ "${AB_DRY_RUN:-0}" = "1" ]; then
    printf 'release-verify tag=%s repo=%s source=release planned=gh-release-download\n' \
        "${tag}" "${repo}"
    printf 'dry-run: no packet sent; pass --dir with downloaded assets for a verdict\n' >&2
    exit 3
fi

if [ "${source_kind}" = "release" ]; then
    if ! command -v gh >/dev/null 2>&1; then
        printf 'release-verify: gh is not installed; pass --dir with the assets downloaded by hand\n' >&2
        exit 3
    fi
    if [ -n "${work}" ]; then
        mkdir -p "${work}" || exit 3
    else
        work=$(mktemp -d "${TMPDIR:-/tmp}/release-verify.XXXXXX") || exit 3
        created_work=1
    fi
    assets_dir=${work}
fi

printf 'release-verify tag=%s repo=%s source=%s dir=%s\n' \
    "${tag}" "${repo}" "${source_kind}" "${assets_dir}"

if [ "${source_kind}" = "release" ]; then
    # A release that is not there, or is still a draft, is an ac-1 failure and not a
    # harness problem: ac-1 is about a published release.
    view=$(gh release view "${tag}" --repo "${repo}" \
        --json tagName,isDraft --jq '[(.tagName),((.isDraft)|tostring)]|join(" ")' 2>/dev/null) || view=""
    if [ -z "${view}" ]; then
        rv_fail release "tag=${tag} repo=${repo} reason=no-such-release"
        rv_finish
    fi
    case "${view##* }" in
        false) rv_pass release "tag=${tag} repo=${repo} draft=false" ;;
        *) rv_fail release "tag=${tag} repo=${repo} draft=${view##* }" ;;
    esac
    if ! gh release download "${tag}" --repo "${repo}" --dir "${assets_dir}" --clobber >/dev/null 2>&1; then
        rv_no_verdict download-failed
    fi
else
    rv_skip release "reason=offline-dir dir=${assets_dir}"
fi

# --------------------------------------------------------------------------- #
# ac-1 (i): the tag and VERSION agree
#
# The VERSION at the tag, not the one in the working tree: a release publishes what the
# tag carries, and a working tree on 0.0.9 says nothing about what v0.0.8 published.
# --------------------------------------------------------------------------- #

expected_version=""
version_from=""
if [ -n "${want_version}" ]; then
    expected_version=${want_version}
    version_from=option
elif have=$(git -C "${AB_REPO_ROOT}" show "${tag}:VERSION" 2>/dev/null); then
    expected_version=$(printf '%s' "${have}" | tr -d '[:space:]')
    version_from=git
elif [ "${source_kind}" = "release" ] &&
    have=$(gh api "repos/${repo}/contents/VERSION?ref=${tag}" \
        -H 'Accept: application/vnd.github.raw' 2>/dev/null); then
    expected_version=$(printf '%s' "${have}" | tr -d '[:space:]')
    version_from=repository-at-tag
fi

case "${tag}" in
    v*)
        if [ -z "${expected_version}" ]; then
            rv_skip tag-version "tag=${tag} reason=version-unreadable"
        elif [ "${tag#v}" = "${expected_version}" ]; then
            rv_pass tag-version "tag=${tag} version=${expected_version} from=${version_from}"
        else
            rv_fail tag-version "tag=${tag} version=${expected_version} from=${version_from}"
        fi
        ;;
    *)
        # The upstream line tags a base (`25.13.0`), so the tag names no VERSION and
        # there is nothing here to compare. ac-1 is about the v line.
        rv_skip tag-version "tag=${tag} reason=tag-carries-no-v"
        ;;
esac

# --------------------------------------------------------------------------- #
# The upstream base this release is named after
#
# ac-1 spells the payload `payload-25.12.2.tar`, so the base is part of the assertion.
# Default: the base in the payload's own file name, which is also what the index has to
# repeat. A directory holding two different bases is ambiguous and refused rather than
# guessed at.
# --------------------------------------------------------------------------- #

expected_base=""
base_state=""
if [ -n "${want_base}" ]; then
    expected_base=${want_base}
else
    bases=""
    for f in "${assets_dir}"/n5105-ab-*.tar "${assets_dir}"/n5105-ab-*.img.gz; do
        [ -f "${f}" ] || continue
        name=${f##*/}
        case "${name}" in
            n5105-ab-*-upgrade.tar) base=${name#n5105-ab-}; base=${base%-upgrade.tar} ;;
            n5105-ab-*-install-wan-ssh.img.gz)
                base=${name#n5105-ab-}
                base=${base%-install-wan-ssh.img.gz}
                ;;
            n5105-ab-*-install.img.gz) base=${name#n5105-ab-}; base=${base%-install.img.gz} ;;
            *) continue ;;
        esac
        [ -n "${base}" ] || continue
        case " ${bases} " in
            *" ${base} "*) : ;;
            *) bases="${bases} ${base}" ;;
        esac
    done
    bases=${bases# }
    case "${bases}" in
        "") base_state=none ;;
        *" "*) base_state=ambiguous ;;
        *) expected_base=${bases} ;;
    esac
fi

case "${base_state}" in
    none) rv_fail base "reason=no-payload-name dir=${assets_dir}" ;;
    ambiguous) rv_fail base "reason=ambiguous names=$(printf '%s' "${bases}" | tr ' ' ',')" ;;
    *)
        if [ -n "${expected_base}" ]; then
            if [ -n "${want_base}" ]; then
                rv_pass base "base=${expected_base} from=option"
            else
                rv_pass base "base=${expected_base} from=asset-name"
            fi
        fi
        ;;
esac

image_name=""
payload_name=""
if [ -n "${expected_base}" ]; then
    image_name="n5105-ab-${expected_base}-install-wan-ssh.img.gz"
    payload_name="n5105-ab-${expected_base}-upgrade.tar"
fi

printf 'release-verify target platform=%s base=%s\n' \
    "${expected_version:-unknown}" "${expected_base:-unknown}"

# --------------------------------------------------------------------------- #
# ac-1 (ii): the four assets are on the release
#
# The label is ac-1's name and the name is the file, because the two differ for the first
# two: `image-install-wan-ssh` is the CI artifact folder, and the published asset carries
# the upstream base in its name so a machine can tell two bases apart.
# --------------------------------------------------------------------------- #

rv_asset() { # <label> <file name>
    if [ -f "${assets_dir}/$2" ]; then
        rv_pass asset "label=$1 name=$2 size=$(rv_size "${assets_dir}/$2")"
        return 0
    fi
    rv_fail asset "label=$1 name=$2 reason=missing"
    return 1
}

if [ -n "${image_name}" ]; then
    rv_asset image-install-wan-ssh "${image_name}"
    rv_asset "payload-${expected_base}.tar" "${payload_name}"
else
    # Without a base there is no name to look for; the four labels are still printed so a
    # reader sees which of ac-1's claims could not be made.
    rv_skip asset "label=image-install-wan-ssh reason=base-unknown"
    rv_skip asset "label=payload-<base>.tar reason=base-unknown"
fi
rv_asset index.txt index.txt
rv_asset SHA256SUMS SHA256SUMS

# --------------------------------------------------------------------------- #
# ac-1 (iii): SHA256SUMS matches the bytes beside it
#
# Every line is checked, not only the two files ac-1 names: a checksum file with one
# wrong line is a checksum file nobody can use. The two ac-1 artifacts additionally have
# to be *covered*, because a file that ships without a line is the same as an unverified
# one.
# --------------------------------------------------------------------------- #

sums="${assets_dir}/SHA256SUMS"
if [ -f "${sums}" ]; then
    entries=0
    while read -r digest name; do
        case "${digest}" in
            '' | '#'*) continue ;;
        esac
        name=${name#\*}
        name=${name#./}
        digest=$(printf '%s' "${digest}" | tr 'A-F' 'a-f')
        if [ -z "${name}" ]; then
            rv_fail sums-entry "line=${digest} reason=no-name"
            continue
        fi
        if [ "${#digest}" -ne 64 ]; then
            rv_fail sums-entry "name=${name} reason=not-a-sha256 digest=${digest}"
            continue
        fi
        entries=$((entries + 1))
        if [ ! -f "${assets_dir}/${name}" ]; then
            rv_fail sums-entry "name=${name} reason=missing-file"
            continue
        fi
        got=$(rv_sha256 "${assets_dir}/${name}") || rv_no_verdict no-sha256-tool
        if [ "${got}" = "${digest}" ]; then
            rv_pass sums-entry "name=${name} sha256=${got}"
        else
            rv_fail sums-entry "name=${name} expected=${digest} got=${got}"
        fi
    done <"${sums}"

    if [ "${entries}" -eq 0 ]; then
        rv_fail sums-file "reason=no-entries file=${sums}"
    else
        rv_pass sums-file "entries=${entries}"
    fi

    for required in "${image_name}" "${payload_name}"; do
        [ -n "${required}" ] || continue
        if awk -v f="${required}" '
            $2 == f || $2 == "*" f { found = 1 }
            END { exit(found ? 0 : 1) }
        ' "${sums}"; then
            rv_pass sums-coverage "name=${required}"
        else
            rv_fail sums-coverage "name=${required} reason=not-listed"
        fi
    done
else
    rv_skip sums-entry "reason=SHA256SUMS-missing"
    rv_skip sums-coverage "reason=SHA256SUMS-missing"
fi

# --------------------------------------------------------------------------- #
# ac-1 (iv): index.txt declares platform / base for this release
#
# Three answers: it is an AB-FEED 1 index at all, the entry for this platform says the
# version and base ac-1 asks for, and that entry's payload digest is the one the
# SHA256SUMS beside it carries - a feed entry that points at other bytes than the release
# publishes is not a release that stands.
# --------------------------------------------------------------------------- #

index="${assets_dir}/index.txt"
if [ -f "${index}" ]; then
    head_line=$(awk '/^[[:space:]]*$/ { next } /^[[:space:]]*#/ { next } { print; exit }' "${index}")
    head_safe=$(printf '%s' "${head_line}" | tr ' ' '_')
    feed_version=$(printf '%s' "${head_line}" | awk '$1 == "AB-FEED" { print $2 }')
    case "${feed_version:-}" in
        1) rv_pass index-header "feed=AB-FEED version=1" ;;
        '') rv_fail index-header "reason=not-an-ab-feed-index first-line=${head_safe:-empty}" ;;
        *) rv_fail index-header "feed=AB-FEED version=${feed_version} expected=1" ;;
    esac

    if [ -z "${expected_version}" ]; then
        rv_skip index-platform "reason=platform-unknown"
        rv_skip index-base "reason=platform-unknown"
        rv_skip index-kernel "reason=platform-unknown"
        rv_skip index-payload "reason=platform-unknown"
    else
        entry=$(rv_index_entry "${index}" "${expected_version}")
        if [ -z "${entry}" ]; then
            rv_fail index-platform "expected=${expected_version} got=none reason=no-entry"
            rv_skip index-base "reason=no-entry"
            rv_skip index-kernel "reason=no-entry"
            rv_skip index-payload "reason=no-entry"
        else
            rv_pass index-platform "expected=${expected_version} got=$(rv_kv "${entry}" platform)"

            got_base=$(rv_kv "${entry}" base)
            if [ -z "${expected_base}" ]; then
                rv_skip index-base "base=${got_base:-none} reason=base-unknown"
            elif [ "${got_base}" = "${expected_base}" ]; then
                rv_pass index-base "expected=${expected_base} got=${got_base}"
            else
                rv_fail index-base "expected=${expected_base} got=${got_base:-none}"
            fi

            # kernel is not in ac-1's sentence, but ab-feed.sh refuses an entry without
            # it, so an index that omits it is not an index a machine can read.
            got_kernel=$(rv_kv "${entry}" kernel)
            if [ -n "${got_kernel}" ]; then
                rv_pass index-kernel "kernel=${got_kernel}"
            else
                rv_fail index-kernel "reason=no-kernel ab-feed.sh-refuses-entry"
            fi

            index_payload=$(rv_kv "${entry}" payload)
            index_sha=$(rv_kv "${entry}" sha256)
            index_size=$(rv_kv "${entry}" size)
            if [ -z "${index_payload}" ]; then
                rv_fail index-payload "reason=no-payload-name"
            elif [ ! -f "${assets_dir}/${index_payload}" ]; then
                rv_fail index-payload "payload=${index_payload} reason=missing-asset"
            else
                asset_sha=$(rv_sha256 "${assets_dir}/${index_payload}") || rv_no_verdict no-sha256-tool
                asset_size=$(rv_size "${assets_dir}/${index_payload}")
                if [ "${index_sha}" = "${asset_sha}" ] && [ "${index_size}" = "${asset_size}" ]; then
                    rv_pass index-payload "payload=${index_payload} size=${asset_size} sha256=${asset_sha}"
                else
                    rv_fail index-payload "payload=${index_payload} index-sha256=${index_sha:-none} asset-sha256=${asset_sha} index-size=${index_size:-none} asset-size=${asset_size}"
                fi
            fi
        fi
    fi
else
    rv_skip index-header "reason=index.txt-missing"
    rv_skip index-platform "reason=index.txt-missing"
    rv_skip index-base "reason=index.txt-missing"
    rv_skip index-kernel "reason=index.txt-missing"
    rv_skip index-payload "reason=index.txt-missing"
fi

rv_finish
