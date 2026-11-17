#!/usr/bin/env bash
# Module: device
# ac-3 / ac-4: the software sample layer, replayed on a stub machine.
#
# The real probe runs on one machine with one network; everything it has to get right is
# still decidable without either, because the machine is behind `ssh` and the samples behind
# a JSON file. This test replaces `ssh` with a stub that keeps a directory tree and answers
# the twelve commands the driver actually sends - apk, cat, cp, rm, test -f, mkdir -p, a
# download and the LuCI URL - so each of these can be provoked on purpose:
#
#   ac-3  the sample list comes from tests/fixtures/software-samples.json (add a sample to a
#         copy of it and the run has a row for it; delete one and the row is gone)
#   ac-3  one row per sample, and installed / not-installed / no-apk-asset are three
#         different rows: PASS with a version, GAP with a reason token and a rerun command
#   ac-3  PASS needs the post-install facts: the package is listed, the config file is there
#         with the bytes that were sent, and LuCI answers 200
#   ac-3  a 24.x sample is refused by name, and the machine's own 24.x base line stops the run
#   ac-4  --baseline / --compare take a snapshot pair per sample: equal is PASS, a changed
#         byte is FAIL, and the row carries the difference
#   ac-4  the config written for each app is real content - non-ASCII, a blank line, quoting -
#         because a hop that mangles any of those is what the comparison is for
#   ac-4  --cleanup removes the packages, the config and the added source, and the machine is
#         compared with the snapshot taken before the run, not with a memory of it
#
# No device, no network: `ssh` here is a shell script, and the fixture is the repo's own.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

probe="$root/scripts/device/software-probe.sh"
fixture="$root/tests/fixtures/software-samples.json"
dev="$tmp/dev"
calls="$tmp/calls"
results="$tmp/results.tsv"
state="$tmp/state"
evidence="$tmp/evidence"
mkdir -p "$tmp/bin"

# --------------------------------------------------------------------------- #
# The stub machine
#
# One script for `ssh`, interpreting the command it is handed against $STUB_ROOT. It is a
# deliberately dumb interpreter: every command the driver sends is listed here, and anything
# else is recorded in $STUB_CALLS.unhandled, which the assertions below read as "the driver
# sent something this test does not model" - the failure mode a permissive stub hides.
# --------------------------------------------------------------------------- #
cat >"$tmp/bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?}"
cmd=""
for arg in "$@"; do cmd=$arg; done
root=${STUB_ROOT:?}
pkgdir=$root/pkgs
mkdir -p "$pkgdir" 2>/dev/null || true

unq() { printf '%s' "$1" | tr -d "'"; }
fp() { printf '%s%s' "$root" "$1"; }

case "$cmd" in
    'cat /etc/platform-release'*)
        p=$(unq "${cmd#cat }")
        p=${p%% 2>/dev/null}
        [ -f "$(fp "$p")" ] || exit 1
        cat "$(fp "$p")"
        ;;
    'cat > '*)
        p=$(unq "${cmd#cat > }")
        mkdir -p "$(dirname "$(fp "$p")")" || exit 1
        cat >"$(fp "$p")"
        ;;
    'cat '*)
        p=$(unq "${cmd#cat }")
        p=${p%% 2>/dev/null}
        [ -f "$(fp "$p")" ] || exit 1
        cat "$(fp "$p")"
        ;;
    'test -f '*)
        [ -f "$(fp "$(unq "${cmd#test -f }")")" ]
        ;;
    'mkdir -p '*)
        mkdir -p "$(fp "$(unq "${cmd#mkdir -p }")")"
        ;;
    'cp -a '*)
        rest=${cmd#cp -a }
        src=$(unq "${rest%% *}")
        dst=$(unq "${rest#* }")
        cp -a "$(fp "$src")" "$(fp "$dst")"
        ;;
    'rm -f '*)
        # The only glob the driver uses is the download directory, and it is spelled out here
        # rather than expanded by a shell that would match paths outside the fake root.
        case "$cmd" in
            *'*'*) rm -f "$root"/tmp/ab-swprobe-*.apk ;;
            *)
                for p in ${cmd#rm -f }; do
                    rm -f "$(fp "$(unq "$p")")"
                done
                ;;
        esac
        ;;
    'apk list --installed '*)
        # apk prints `name-version arch {origin} (license)`; the version is what the driver
        # reads back, so the fake package file holds exactly that.
        rest=${cmd#apk list --installed }
        name=$(unq "${rest%% 2>/dev/null}")
        name=${name%% 2>/dev/null}
        if [ -f "$pkgdir/$name" ]; then
            printf '%s-%s x86_64 {feeds/samples} (MIT)\n' "$name" "$(cat "$pkgdir/$name")"
        fi
        ;;
    'apk add --allow-untrusted '*)
        file=$(unq "${cmd#apk add --allow-untrusted }")
        name=$(basename "$file")
        name=${name#ab-swprobe-}
        name=${name%.apk}
        case " ${STUB_INSTALL_FAIL:-} " in
            *" $name "*) exit 1 ;;
        esac
        [ -f "$(fp "$file")" ] || exit 1
        if [ -f "$root/dl/$name" ]; then
            cp "$root/dl/$name" "$pkgdir/$name"
        else
            printf '%s\n' "${STUB_VERSION:-1.0.0-r1}" >"$pkgdir/$name"
        fi
        ;;
    'apk add '*)
        name=$(unq "${cmd#apk add }")
        case " ${STUB_INSTALL_FAIL:-} " in
            *" $name "*) exit 1 ;;
        esac
        # A sample asked for by name only exists when a feed was seeded with it: the fixture's
        # software-store sample has no apk asset at all, and that is a case worth keeping.
        [ -f "$root/feed/$name" ] || exit 1
        cp "$root/feed/$name" "$pkgdir/$name"
        ;;
    'apk del '*)
        rm -f "$pkgdir/$(unq "${cmd#apk del }")"
        ;;
    'apk update')
        exit 0
        ;;
    'curl '*127.0.0.1/*)
        [ "${STUB_NO_CURL:-0}" = "1" ] && exit 127
        printf '%s' "${STUB_UI:-200}"
        ;;
    'uclient-fetch '*127.0.0.1/*)
        [ "${STUB_UI_FAIL:-0}" = "1" ] && exit 1
        exit 0
        ;;
    'uclient-fetch '*)
        [ "${STUB_FETCH_FAIL:-0}" = "1" ] && exit 1
        dest=$(printf '%s\n' "$cmd" | sed -n "s/.*-O '\\([^']*\\)'.*/\\1/p")
        url=$(printf '%s\n' "$cmd" | sed -n "s/.*-O '[^']*' '\\([^']*\\)'.*/\\1/p")
        [ -n "$dest" ] || exit 1
        mkdir -p "$(dirname "$(fp "$dest")")" || exit 1
        : >"$(fp "$dest")"
        # An apk reports the version its own file name carries, so the stub keeps that one and
        # `apk add` below hands it over: the rows are then quotable against the fixture's pins
        # instead of against a constant invented here.
        name=$(basename "$dest")
        name=${name#ab-swprobe-}
        name=${name%.apk}
        version=$(basename "$url")
        version=${version%.apk}
        version=${version#"$name"-}
        mkdir -p "$root/dl"
        printf '%s\n' "$version" >"$root/dl/$name"
        ;;
    *)
        printf '%s\n' "$cmd" >>"${STUB_CALLS:?}.unhandled"
        exit 0
        ;;
esac
STUB
chmod +x "$tmp/bin/ssh"

# new_device <base line>: a machine with a platform-release and nothing else.
new_device() {
    rm -rf "$dev" "$calls" "$calls.unhandled" "$results" "$state" "$evidence"
    mkdir -p "$dev/etc" "$dev/pkgs" "$dev/tmp"
    printf 'PLATFORM_VERSION=0.0.12\nUPSTREAM_VERSION=%s\n' "${1:-25.12.2}" >"$dev/etc/platform-release"
    : >"$calls"
}

# probe_run <args...>: one run of the driver against the stub machine. Output on stdout, the
# driver's own exit status as this function's status.
probe_run() {
    local out rc
    out=$(PATH="$tmp/bin:$PATH" STUB_ROOT="$dev" STUB_CALLS="$calls" AB_KEY="$tmp/key" \
        sh "$probe" --results "$results" --evidence-dir "$evidence" --state-dir "$state" "$@" 2>&1)
    rc=$?
    printf '%s\n' "$out"
    return $rc
}

row_of() { awk -F'\t' -v c="$1" '$1 == c' "$results" 2>/dev/null | tail -n 1; }
verdict_of() { row_of "$1" | cut -f2; }
note_of() { row_of "$1" | cut -f3-; }
rows() { wc -l <"$results" 2>/dev/null | tr -d ' '; }
sha_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

fixture_names=$(python3 - "$fixture" <<'PY'
import json, sys
print("\n".join(s["name"] for s in json.load(open(sys.argv[1]))["samples"]))
PY
)
fixture_count=$(printf '%s\n' "$fixture_names" | wc -l | tr -d ' ')

# =========================================================================== #
# ac-3: the sample layer, one row per sample
# =========================================================================== #
new_device 25.12.2
# The software-store sample is installed by name, so the feed that offers it has to exist for
# the happy path; it is seeded only here, and its absence below is a case of its own.
mkdir -p "$dev/feed"
printf '1.2.3-r1\n' >"$dev/feed/istore"

out=$(probe_run --third-party-url 'https://feed.example.invalid/istore')
rc=$?

assert_eq "$rc" "0" "ac-3 every sample installs on 25.x and the run exits 0"
assert_eq "$(verdict_of SW-machine)" "PASS" "ac-3 the machine's own base line is recorded first"
assert_contains "$(note_of SW-machine)" "base=25.12.2" "ac-3 the row names the base line it ran on"

# Every sample in the fixture has a row, and the count is the fixture's count: a hardcoded
# list in the driver would make one of these two assertions fail on the day the fixture moves.
assert_eq "$(rows)" "$((fixture_count + 2))" "ac-3 one row per sample, plus the machine and the source"
while IFS= read -r name; do
    [ -n "$name" ] || continue
    assert_eq "$(verdict_of "SW-$name")" "PASS" "ac-3 $name installs and passes its post-install facts"
done <<EOF
$fixture_names
EOF

assert_eq "$(verdict_of SW-sources)" "PASS" "ac-3 the third-party feed is one row of its own"
assert_file_exists "$dev/etc/apk/repositories.d/ab-samples.list" \
    "ac-3 the added feed lives in /etc/apk/repositories.d/, device side"
assert_eq "$(cat "$dev/etc/apk/repositories.d/ab-samples.list")" "https://feed.example.invalid/istore" \
    "ac-3 the source file holds the URL and nothing else"
assert_contains "$(note_of SW-luci-app-openclash)" "version=0.48.002" \
    "ac-3 the row records the version the package manager reports"
assert_contains "$(note_of SW-luci-app-openclash)" "config=/etc/config/openclash" \
    "ac-3 the row names the config file the app owns"
assert_contains "$(note_of SW-luci-app-openclash)" "ui=200" \
    "ac-3 the row records that LuCI answered 200"
assert_contains "$(note_of SW-htop)" "config=none" \
    "ac-3 a plain program is not given a config file it never had"

# The evidence a row points at has to exist and hold the command that was run.
row_ev=$(row_of SW-luci-app-openclash | cut -f3)
assert_file_exists "$row_ev" "ac-3 the evidence column names a file that exists"
assert_contains "$(cat "$row_ev" 2>/dev/null)" "uclient-fetch -O" \
    "ac-3 that file holds the install command that ran"
assert_contains "$(cat "$row_ev" 2>/dev/null)" "installed luci-app-openclash-0.48.002" \
    "ac-3 and the version the machine reported afterwards"

# =========================================================================== #
# ac-4: the config written for an app is real content
# =========================================================================== #
cfg="$dev/etc/config/openclash"
assert_file_exists "$cfg" "ac-4 every app sample owns a config file after install"
cfg_body=$(cat "$cfg" 2>/dev/null)
assert_contains "$cfg_body" "社区样本：luci-app-openclash" "ac-4 the config carries non-ASCII text"
assert_contains "$cfg_body" "option title \"订阅 & 规则 \$HOME 100% #1\"" \
    "ac-4 the config carries quoting a shell writer would eat"
assert_eq "$(grep -c '^$' "$cfg" 2>/dev/null)" "1" "ac-4 the config carries a blank line inside the file"
assert_contains "$cfg_body" "	list domain '例子.测试'" \
    "ac-4 the config carries a non-ASCII list value, indented like UCI"
assert_eq "$(note_of SW-luci-app-openclash | sed -n 's/.*sha256=\([0-9a-f]*\).*/\1/p')" \
    "$(sha_of "$cfg" | cut -c1-8)" "ac-4 the row's sha256 is the file the machine holds"

# =========================================================================== #
# ac-3: the three shapes of "not installed", told apart
# =========================================================================== #

# 1. the sample the fixture itself says has no apk asset: asked for by name, absent from the
#    feed, so the row is GAP with the command that failed and the rerun that would answer it.
new_device 25.12.2
probe_run --sample istore >/dev/null
rc=$?
assert_eq "$rc" "4" "ac-3 a GAP alone ends the run with 4, not 0"
assert_eq "$(verdict_of SW-istore)" "GAP" "ac-3 a sample that does not install is never PASS"
assert_contains "$(note_of SW-istore)" "reason=install-failed" "ac-3 the row carries a reason token"
assert_contains "$(note_of SW-istore)" 'rerun="sh scripts/device/software-probe.sh --sample istore"' \
    "ac-3 the row carries the command that reruns it"
istore_ev=$(row_of SW-istore | cut -f3)
assert_contains "$(cat "$istore_ev" 2>/dev/null)" "fixture fallback:" \
    "ac-3 the fixture's own fallback sentence is quoted in the evidence"
assert_contains "$(cat "$istore_ev" 2>/dev/null)" "luci-app-package-manager" \
    "ac-3 ... and names the same-source alternative the fixture chose"

# 2. the download failed: a different token from a failed install, because the reason is what
#    the reader has to act on.
new_device 25.12.2
out=$(STUB_FETCH_FAIL=1 probe_run --sample luci-app-ttyd)
rc=$?
assert_eq "$(verdict_of SW-luci-app-ttyd)" "GAP" "ac-3 a failed download is a GAP"
assert_contains "$(note_of SW-luci-app-ttyd)" "reason=fetch-failed" \
    "ac-3 a failed download and a refused install are different reason tokens"
case "$(cat "$calls")" in
    *"apk add"*) assert_eq "apk-add" "no-apk-add" "ac-3 nothing is installed after a failed download" ;;
    *) assert_eq "no-apk-add" "no-apk-add" "ac-3 nothing is installed after a failed download" ;;
esac

# 3. the package manager refused the file the feed served.
new_device 25.12.2
STUB_INSTALL_FAIL='luci-app-ttyd' probe_run --sample luci-app-ttyd >/dev/null
assert_contains "$(note_of SW-luci-app-ttyd)" "reason=install-failed rc=1" \
    "ac-3 a refused apk add is a GAP that names the exit code"

# =========================================================================== #
# ac-3: PASS needs all three post-install facts
# =========================================================================== #
new_device 25.12.2
STUB_UI=500 probe_run --sample luci-app-ttyd >/dev/null
rc=$?
assert_eq "$(verdict_of SW-luci-app-ttyd)" "FAIL" "ac-3 a web UI that does not answer 200 is not a pass"
assert_contains "$(note_of SW-luci-app-ttyd)" "ui=http:500" "ac-3 the row records the code it got"
assert_eq "$rc" "1" "ac-3 one FAIL ends the run with 1"

# The machine may have no curl; uclient-fetch can only say the page answered, and that is
# still enough to keep the row honest.
new_device 25.12.2
STUB_NO_CURL=1 probe_run --sample htop >/dev/null
assert_eq "$(verdict_of SW-htop)" "PASS" "ac-3 the uclient-fetch fallback is used when there is no curl"
assert_contains "$(cat "$calls")" "uclient-fetch -T 10 -O /dev/null" \
    "ac-3 ... and the fallback is the fetch this driver actually ran"

# =========================================================================== #
# ac-4: --baseline then --compare, equal and drifted
# =========================================================================== #
new_device 25.12.2
mkdir -p "$dev/etc/config" "$dev/feed"
printf '1.2.3-r1\n' >"$dev/feed/istore"
# A config the product itself shipped, so the run has something to copy aside and put back.
printf 'config argon\n\toption mode "original"\n' >"$dev/etc/config/argon"
probe_run --third-party-url 'https://feed.example.invalid/samples' >/dev/null
assert_eq "$(verdict_of SW-luci-theme-argon)" "PASS" "ac-4 the sample is installed before the baseline"
# the config the product shipped is not lost: it is copied beside it, and --cleanup puts it back
assert_file_exists "$dev/etc/config/argon.swprobe-bak" \
    "ac-4 an existing config is copied beside itself before this driver writes"

probe_run --baseline hop-1 >/dev/null
rc=$?
assert_eq "$rc" "0" "ac-4 a baseline taken on a healthy machine passes"
assert_eq "$(verdict_of 'SW-luci-theme-argon-base@hop-1')" "PASS" "ac-4 the theme's config is snapshotted"
assert_eq "$(verdict_of 'SW-htop-base@hop-1')" "PASS" "ac-4 a sample without a config is recorded by version"
assert_file_exists "$state/base-hop-1/luci-theme-argon.tsv" "ac-4 the snapshot is a file the next hop can read"
assert_contains "$(cat "$state/base-hop-1/versions.tsv")" "htop" \
    "ac-4 the baseline records the version each sample had"

probe_run --compare hop-1 >/dev/null
rc=$?
assert_eq "$rc" "0" "ac-4 a hop that changed nothing compares equal"
assert_eq "$(verdict_of 'SW-luci-theme-argon-config@hop-1')" "PASS" \
    "ac-4 the theme's config is unchanged across the hop"
assert_eq "$(verdict_of 'SW-htop-pkg@hop-1')" "PASS" "ac-4 the plain program is still installed at its version"

# ... and now the hop that mangles one byte of the app's own config
printf '\n# hop-1 dropped this comment\n' >>"$dev/etc/config/argon"
probe_run --compare hop-1 >/dev/null
rc=$?
assert_eq "$(verdict_of 'SW-luci-theme-argon-config@hop-1')" "FAIL" \
    "ac-4 a config that moved across the hop is a FAIL, judged as it is"
assert_eq "$rc" "1" "ac-4 the FAIL reaches the exit status"
assert_contains "$(note_of 'SW-luci-theme-argon-config@hop-1')" "changed" \
    "ac-4 the row says what moved rather than that something did"
assert_contains "$(cat "$(row_of 'SW-luci-theme-argon-config@hop-1' | cut -f3)" 2>/dev/null)" \
    "FAIL SW-luci-theme-argon-config@hop-1" \
    "ac-4 the evidence log holds the failing comparison, not a summary of it"

# A baseline taken before the samples are installed records GAPs, not versions of nothing.
new_device 25.12.2
probe_run --baseline hop-0 >/dev/null
assert_eq "$?" "4" "ac-4 a baseline with nothing installed is a GAP"
assert_contains "$(note_of 'SW-htop-base@hop-0')" "reason=not-installed" \
    "ac-4 ... and the row says the sample was not there to be recorded"

# A comparison with no baseline is a GAP, not a pass over an empty set.
new_device 25.12.2
probe_run --compare hop-9 >/dev/null
rc=$?
assert_eq "$rc" "4" "ac-4 comparing against a baseline that was never taken is a GAP"
assert_contains "$(note_of SW-compare-hop-9)" "reason=no-baseline" \
    "ac-4 ... and the row says which baseline is missing"

# =========================================================================== #
# ac-4: --cleanup puts the machine back
# =========================================================================== #
new_device 25.12.2
mkdir -p "$dev/etc/config"
printf 'config argon\n\toption mode "original"\n' >"$dev/etc/config/argon"
argon_orig=$(sha_of "$dev/etc/config/argon")
mkdir -p "$dev/etc/apk/repositories.d"
printf 'https://somebody-elses.example.invalid/feed\n' >"$dev/etc/apk/repositories.d/ab-samples.list"
sources_orig=$(sha_of "$dev/etc/apk/repositories.d/ab-samples.list")
mkdir -p "$dev/feed"
printf '1.2.3-r1\n' >"$dev/feed/istore"

probe_run --third-party-url 'https://feed.example.invalid/samples' >/dev/null
rc=$?
assert_eq "$rc" "0" "ac-4 the run under test installed and passed"
assert_eq "$(cat "$dev/etc/apk/repositories.d/ab-samples.list")" \
    "https://feed.example.invalid/samples" "ac-4 the run did replace the source list it found"
assert_eq "$(verdict_of SW-sources)" "PASS" "ac-4 the replaced source list is recorded"

probe_run --cleanup >/dev/null
rc=$?
assert_eq "$rc" "0" "ac-4 cleanup on a run with nothing failed exits 0"
assert_eq "$(verdict_of SW-cleanup)" "PASS" \
    "ac-4 the machine matches the snapshot taken before the run"
assert_eq "$(verdict_of SW-cleanup-pkg)" "PASS" "ac-4 every installed sample was removed"
assert_eq "$(ls "$dev/pkgs" 2>/dev/null | wc -l | tr -d ' ')" "0" "ac-4 no sample package is left installed"
assert_eq "$(sha_of "$dev/etc/config/argon")" "$argon_orig" \
    "ac-4 a config the product shipped is byte-for-byte the one it had"
assert_eq "$(sha_of "$dev/etc/apk/repositories.d/ab-samples.list")" "$sources_orig" \
    "ac-4 a source list that was there before the run is back"
assert_eq "$(ls "$dev/etc/config" | grep -c 'swprobe-bak' || true)" "0" \
    "ac-4 no backup copy of this driver's is left behind"
assert_eq "$(ls "$dev/tmp" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "ac-4 the downloaded apk files are gone"
case "$(cat "$calls.unhandled" 2>/dev/null)" in
    "") assert_eq "clean" "clean" "ac-3 the stub saw only commands this test models" ;;
    *) assert_eq "$(cat "$calls.unhandled")" "" "ac-3 the stub saw only commands this test models" ;;
esac

# The files this run created are gone, so a config-less sample leaves nothing behind either.
assert_eq "$(ls "$dev/etc/config" 2>/dev/null | grep -c 'openclash' || true)" "0" \
    "ac-4 a config file the run created is removed, not left for the product to trip over"

# =========================================================================== #
# ac-3: 24.x, refused by name; the machine's own line is a red line
# =========================================================================== #
cat >"$tmp/manifest-24x.json" <<'JSON'
{
  "schema": 1,
  "updated": "2026-11-17",
  "version_line": "25.x",
  "samples": [
    {
      "name": "luci-app-oldopkg",
      "kind": "proxy-app",
      "source_url": "https://downloads.immortalwrt.org/releases/24.10.0/packages/x86_64/luci/luci-app-oldopkg_1.0_all.ipk",
      "fetched_at": "2026-11-17",
      "why": "a 24.x sample, kept only to prove the driver refuses it",
      "fallback": "none: 24.x is out of scope"
    },
    {
      "name": "luci-app-ttyd",
      "kind": "feed-control",
      "source_url": "https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/luci/luci-app-ttyd-26.298.29275~c84adb9.apk",
      "fetched_at": "2026-11-17",
      "why": "a 25.x control sample that has to keep running",
      "fallback": "none"
    }
  ]
}
JSON
new_device 25.12.2
probe_run --manifest "$tmp/manifest-24x.json" >/dev/null
rc=$?
assert_eq "$(verdict_of SW-luci-app-oldopkg)" "GAP" "ac-3 a 24.x sample is refused, not installed"
assert_contains "$(note_of SW-luci-app-oldopkg)" "reason=24x-out-of-scope" \
    "ac-3 ... with the reason that says why the conclusion would not transfer"
assert_eq "$(verdict_of SW-luci-app-ttyd)" "PASS" \
    "ac-3 the rest of the sample layer still runs after one entry is refused"
assert_eq "$rc" "4" "ac-3 the refused sample is a GAP, not a FAIL"

# The machine itself, on a 24.x base line, is a red line: it stops before anything is installed.
new_device 24.10.0
out=$(probe_run)
rc=$?
assert_eq "$rc" "3" "ac-3 a machine below 25 stops the run instead of producing rows"
assert_contains "$out" "below 25" "ac-3 ... and says why on stderr"
assert_contains "$(note_of SW-machine)" "reason=line-below-25" "ac-3 ... and records the base line it refused"
case "$(cat "$calls")" in
    *"apk add"*) assert_eq "installed" "nothing-installed" "ac-3 a refused machine is not written to" ;;
    *) assert_eq "nothing-installed" "nothing-installed" "ac-3 a refused machine is not written to" ;;
esac

# A manifest that is not pinned to 25.x is the same red line, before the machine is read.
sed 's/"version_line": "25.x"/"version_line": "24.x"/' "$fixture" >"$tmp/manifest-24-line.json"
new_device 25.12.2
probe_run --manifest "$tmp/manifest-24-line.json" >/dev/null
rc=$?
assert_eq "$rc" "3" "ac-3 a manifest pinned to 24.x stops the run"
assert_contains "$(note_of SW-manifest)" "reason=line-out-of-scope" \
    "ac-3 ... and the row names the manifest as the cause"

# A sample added to the fixture appears without touching the driver: the list is data.
cat >"$tmp/manifest-one.json" <<'JSON'
{
  "schema": 1,
  "version_line": "25.x",
  "samples": [
    {
      "name": "sample-only-in-this-fixture",
      "kind": "feed-control",
      "source_url": "https://example.invalid/sample-only-in-this-fixture-1.0.apk",
      "fetched_at": "2026-11-17",
      "why": "proves the driver reads the list instead of holding one",
      "fallback": "none"
    }
  ]
}
JSON
new_device 25.12.2
probe_run --manifest "$tmp/manifest-one.json" >/dev/null
assert_eq "$(verdict_of SW-sample-only-in-this-fixture)" "PASS" \
    "ac-3 a sample only present in the manifest is installed, so nothing is hardcoded"
assert_eq "$(rows)" "2" "ac-3 that run has exactly the machine row and the one sample"

# =========================================================================== #
# --dry-run: a plan is not a measurement
# =========================================================================== #
new_device 25.12.2
out=$(probe_run --dry-run)
rc=$?
assert_eq "$rc" "0" "ac-3 a dry run exits 0"
assert_contains "$out" "dry-run sample=luci-theme-argon install=" "ac-3 the plan names what would be installed"
assert_contains "$out" "dry-run sample=htop config=none" "ac-3 the plan says which samples own a config"
assert_contains "$out" "no row was written" "ac-3 the plan says so itself"
assert_eq "$(cat "$calls")" "" "ac-3 a dry run opens no connection"
assert_eq "$(ls "$results" 2>/dev/null | wc -l | tr -d ' ')" "0" "ac-3 a dry run creates no results file"
assert_eq "$(ls -d "$evidence" 2>/dev/null | wc -l | tr -d ' ')" "0" "ac-3 a dry run creates no evidence directory"
assert_eq "$(ls -d "$state" 2>/dev/null | wc -l | tr -d ' ')" "0" "ac-3 a dry run creates no state"

# =========================================================================== #
# Usage, and the row format itself
# =========================================================================== #
new_device 25.12.2
probe_run --nonsense >/dev/null 2>&1
assert_eq "$?" "2" "ac-3 an unknown argument is a usage error"
probe_run --sample nosuchsample >/dev/null 2>&1
assert_eq "$?" "2" "ac-3 a sample the manifest does not hold is a typo, not an empty run"
probe_run --compare hop-1 --sample luci-app-ttyd >/dev/null 2>&1
assert_eq "$?" "2" "ac-3 --sample belongs to the install action"
probe_run --baseline hop-1 --cleanup >/dev/null 2>&1
assert_eq "$?" "2" "ac-4 two actions in one run is a usage error, not a silent last-wins"
probe_run --cleanup >/dev/null 2>&1
assert_eq "$?" "4" "ac-4 cleanup with no state to undo is a GAP"

new_device 25.12.2
probe_run --sample htop >/dev/null
bad_format=$(awk -F'\t' 'NF != 4 || ($2 != "PASS" && $2 != "FAIL" && $2 != "GAP") { print }' "$results")
assert_eq "$bad_format" "" "ac-3 every row is case, verdict, evidence, note and a known verdict"
assert_eq "$(row_of SW-htop | cut -f3 | grep -c '/')" "1" \
    "ac-3 the evidence column is a path, not a sentence"

finish
