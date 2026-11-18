#!/usr/bin/env bash
# Module: upgrade
# The gate: three propositions, judged on the target tree, before the machine is allowed to
# boot it.
#
#   P  pin agreement  - the world the machine will boot with pins what its base pins.
#   S  solvability    - the transaction the first boot would run can be solved at all.
#   L  local packages - a package only the installed database answers for can be replayed, or
#                       the record has to say why not.
#
# Everything is asked of apk against --root <target>, so the answer describes the slot rather
# than the machine running the gate, and the whole judgement writes only its own /tmp directory:
# ac-5 says a judgement that failed leaves nothing behind anywhere else, and this file compares
# the target tree byte for byte to prove it.
#
#   ac-1 the three states: ok (all three passed, nothing held back), blocked (a proposition
#        forbids the follow: pin-mismatch / unsolvable / unreachable), gap (the follow can run
#        but part of it cannot move, or could not be judged).
#   ac-2 the attribution tokens are the ones the plan block and the record spell: gone: (DROPPED
#        - no source offers it), pinned: (PINNED - the pinned version is gone), local: (NO COPY),
#        stale-abi: (ABI STALE).
#   ac-3 the feeds the prediction uses are every feed the target will read, in apk's order -
#        its own repositories.d first, the user's customfeeds included. Passing only the base's
#        file would make every third-party package look like one no source offers.
#   ac-4 P runs before S: a world that pins another release's kernel cannot follow this base, and
#        no index fetch would add anything to that answer.
#   ac-5 nothing outside /tmp is written: not on the ok path, not on a blocked one.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/upgrade/packages.sh"
if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the packages library exists\n' >&2
  printf '    missing %s\n' "$lib" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the trees ---------------------------------------------------------------
# The base tree (@sys) and the target tree (what the machine will boot: the base plus the
# writable layer's world and feeds). They are separate arguments because P compares them.
base="$tmp/sys"
target="$tmp/target"
mkbase() {
  rm -rf "$base" "$target"
  mkdir -p "$base/etc/apk" "$target/etc/apk/repositories.d" "$target/lib/apk/db" \
    "$target/etc/apk/ab/local"
  cat >"$base/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
busybox
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
libc=1.2.5-r5
WORLD
  cat >"$target/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
busybox
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
libc=1.2.5-r5
htop=3.3.0-r1
luci-theme-argon
WORLD
  printf '%s\n' \
    'https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/packages/packages.adb' \
    'https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/packages/packages.adb' \
    >"$target/etc/apk/repositories.d/distfeeds.list"
  # The measured machine's own feed list: only a comment, but apk reads it, so a prediction that
  # leaves it out is a prediction about a machine nobody has.
  printf '# add your custom package feeds here\nhttps://pkgs.example.net/x86_64/packages.adb\n' \
    >"$target/etc/apk/repositories.d/customfeeds.list"
  # The apk database: what is installed, with the dependencies a replay has to respect.
  cat >"$target/lib/apk/db/installed" <<'DB'
C:Q1abc=
P:htop
V:3.3.0-r1
D:so:libc.so.6
DB
  mkpolicy
}

# --- stubs -------------------------------------------------------------------
bin="$tmp/bin"
mkdir -p "$bin"

# The stub answers the way apk-tools 3.0.5 does on the measured machine. Three answers matter:
# `update` (does the index answer), `--simulate upgrade` (can the world be solved, and what does
# apk name when it cannot), and `policy` (which sources offer a package).
cat >"$bin/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >>"${APK_CALLS:-/dev/null}"
applet=""
simulate=0
repos=""
while [ $# -gt 0 ]; do
  arg=$1
  shift
  case "$arg" in
    --repositories-file) repos=${1:-}; shift ;;
    --root|--cache-dir|--timeout|-p) shift ;;
    --simulate|-s) simulate=1 ;;
    update|upgrade|add|fetch|policy|search|info) [ -n "$applet" ] || applet=$arg ;;
    *) entry=$arg ;;
  esac
done
# The prediction has to see every feed the target reads: keep the file the gate built.
if [ -n "${APK_REPOS_SEEN:-}" ] && [ -n "$repos" ] && [ -f "$repos" ]; then
  cat "$repos" >"${APK_REPOS_SEEN}"
fi
case "$applet" in
  update)
    [ -n "${APK_UPDATE_OUT:-}" ] && cat "${APK_UPDATE_OUT}"
    exit "${APK_UPDATE_RC:-0}"
    ;;
  upgrade)
    if [ "$simulate" = "1" ]; then
      [ -n "${APK_SIM_OUT:-}" ] && cat "${APK_SIM_OUT}"
      exit "${APK_SIM_RC:-0}"
    fi
    exit 0
    ;;
  policy)
    if [ -n "${APK_POLICY_DIR:-}" ] && [ -f "${APK_POLICY_DIR}/${entry}" ]; then
      cat "${APK_POLICY_DIR}/${entry}"
      exit 0
    fi
    printf '%s:\n  1.0-r1:\n    lib/apk/db/installed\n    https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/packages/packages.adb\n' "$entry"
    exit 0
    ;;
  *) exit 0 ;;
esac
APK
chmod +x "$bin/apk"
export PATH="$bin:$PATH"
export APK_CALLS="$tmp/apk.calls"
: >"$tmp/apk.calls"

# The offers: htop comes from a feed, luci-theme-argon from the user's own feed. Both are
# recreated by mkbase, so a case that makes one of them local cannot leak into the next.
policy_dir="$tmp/policy"


# gate <target> <sys>: run the gate in its own shell and print its whole verdict.
gate() {
  AB_PACKAGES_GATE_TMP="$tmp/gate-tmp" APK_REPOS_SEEN="$tmp/repos.seen" sh -c '
    . "$1"
    shift
    ab_packages_gate "$@"
    printf "rc=%s state=%s reason=%s S=%s P=%s L=%s index=%s world=%s skipped=[%s] blocked=[%s]\n" \
      "$?" "${AB_PACKAGES_GATE_STATE}" "${AB_PACKAGES_GATE_REASON}" "${AB_PACKAGES_GATE_S}" \
      "${AB_PACKAGES_GATE_P}" "${AB_PACKAGES_GATE_L}" "${AB_PACKAGES_GATE_INDEX}" \
      "${AB_PACKAGES_GATE_WORLD}" "${AB_PACKAGES_GATE_SKIPPED}" "${AB_PACKAGES_GATE_BLOCKED}"
  ' _ "$lib" "$target" "$base" 2>"$tmp/gate.err"
}
reset_calls() { : >"$tmp/apk.calls"; : >"$tmp/repos.seen"; }
mkdir -p "$tmp/gate-tmp"
mkpolicy() {
  mkdir -p "$policy_dir"
  rm -f "$policy_dir"/*
  cat >"$policy_dir/htop" <<'POLICY'
htop:
  3.5.3-r1:
    lib/apk/db/installed
    https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/packages/packages.adb
POLICY
  cat >"$policy_dir/luci-theme-argon" <<'POLICY'
luci-theme-argon:
  26.249.1-r1:
    lib/apk/db/installed
    https://pkgs.example.net/x86_64/packages.adb
POLICY
}
mkpolicy
export APK_POLICY_DIR="$policy_dir"

# Every file under a tree with its digest: "nothing was written" compares two of these.
snapshot_tree() {
  ( cd "$1" && find . -type f | sort | while IFS= read -r f; do
      printf '%s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"
    done )
}

# =========================================================================== #
# ac-1/ac-2: everything the world names can follow
# =========================================================================== #

mkbase
reset_calls
before="$(snapshot_tree "$target")"
out="$(gate)"
assert_contains "$out" "rc=0 state=ok reason=none S=ok P=ok L=ok" \
  "ac-1 a world whose packages all follow is ok, and all three propositions say so"
assert_contains "$out" "index=ok" "ac-1 the index answered, and that is recorded"
assert_contains "$out" "world=upper" "ac-1 the pins were read from the world the machine boots"
assert_contains "$out" "skipped=[]" "ac-1 a clean world has no attribution to report"
assert_contains "$out" "blocked=[]" "ac-1 and nothing apk could not select"
assert_eq "$(snapshot_tree "$target")" "$before" \
  "ac-5 the judgement did not write one byte inside the target tree"
assert_eq "$(ls -A "$tmp/gate-tmp" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-5 and its own /tmp scratch directory is gone when it returns"

# The question was asked of the target, not of the machine running the gate, and the index it
# built lives in /tmp.
assert_contains "$(sed -n '1p' "$tmp/apk.calls")" "--root $target --cache-dir $tmp/gate-tmp/ab-gate." \
  "ac-1 apk ran against --root <target> with its cache in the gate's /tmp"
assert_contains "$(sed -n '1p' "$tmp/apk.calls")" "--repositories-file $tmp/gate-tmp/ab-gate." \
  "ac-1 and with the feed set the gate built, not the machine's"
assert_eq "$(sed -n '1p' "$tmp/apk.calls" | grep -c ' update$' || true)" "1" \
  "ac-1 the index is refreshed first: a fresh boot has no apk index"
assert_contains "$(sed -n '2p' "$tmp/apk.calls")" "--simulate upgrade" \
  "ac-1 then the transaction the first boot would run, simulated"

# ac-3: both feeds the target reads are in the prediction, the user's own list included.
assert_contains "$(cat "$tmp/repos.seen")" "downloads.immortalwrt.org/releases/25.12.2" \
  "ac-3 the base's own feeds are part of the prediction"
assert_contains "$(cat "$tmp/repos.seen")" "https://pkgs.example.net/x86_64/packages.adb" \
  "ac-3 and so is the user's own feed: without it every third-party package would look gone"
assert_eq "$(cat "$tmp/repos.seen")" \
  "$(cat "$target/etc/apk/repositories.d/customfeeds.list" "$target/etc/apk/repositories.d/distfeeds.list")" \
  "ac-3 the prediction is exactly the file set apk reads, in apk's own order"

# =========================================================================== #
# ac-4: P before S
# =========================================================================== #
# The world pins the release the machine is leaving. That cannot be solved into this base, and
# the answer costs two file reads: no index fetch is spent on a machine that cannot follow.
mkbase
printf 'kernel=6.12.87~bd81971a8c-r1\nbase-files=1933~f20c1d4e5f60\nlibc=1.2.5-r4\n' \
  >"$target/etc/apk/world"
reset_calls
out="$(gate)"
assert_contains "$out" "rc=1 state=blocked reason=pin-mismatch" \
  "ac-4 a world pinning another release is blocked before anything is fetched"
assert_contains "$out" "P=blocked" "ac-4 the proposition that failed is named"
assert_contains "$out" "S=skipped" "ac-4 and the ones behind it were not asked"
assert_eq "$(grep -c '' "$tmp/apk.calls")" "0" \
  "ac-4 no apk was run at all"
assert_contains "$(cat "$tmp/gate.err")" "kernel" "ac-4 the reason names the pin that disagrees"

# Two pins for one name is the same answer: nobody can say which of them the machine should be.
mkbase
printf 'kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1\nkernel=6.11.5~dead-r1\n' \
  >"$target/etc/apk/world"
reset_calls
out="$(gate)"
assert_contains "$out" "state=blocked reason=pin-mismatch" \
  "ac-4 two pins for one name block the gate"

# =========================================================================== #
# ac-2: S, and the two shapes apk names differently
# =========================================================================== #
# A package no source offers: DROPPED in the plan block, `gone:` in the record.
mkbase
printf 'ERROR: unable to select packages:\n  luci-theme-argon (no such package):\n    required by: world[luci-theme-argon]\n' \
  >"$tmp/sim.gone"
reset_calls
out="$(APK_SIM_RC=1 APK_SIM_OUT="$tmp/sim.gone" gate)"
assert_contains "$out" "rc=1 state=blocked reason=unsolvable" \
  "ac-1 an unsolvable world blocks the follow"
assert_contains "$out" "S=blocked" "ac-2 and it is the solvability proposition that said so"
assert_contains "$out" "skipped=[gone:luci-theme-argon]" \
  "ac-2 the token is the one the plan block and the record share"
assert_contains "$out" "blocked=[luci-theme-argon]" "ac-2 and the entry itself is named"
assert_contains "$(cat "$tmp/gate.err")" "luci-theme-argon" \
  "ac-2 the operator sees what could not be selected, without reading the record"

# A pin whose version is gone: the package exists, the version does not - PINNED, not DROPPED.
mkbase
printf 'ERROR: unable to select packages:\n  htop-3.5.3-r1:\n    breaks: world[htop=3.3.0-r1]\n' \
  >"$tmp/sim.pinned"
out="$(APK_SIM_RC=1 APK_SIM_OUT="$tmp/sim.pinned" gate)"
assert_contains "$out" "state=blocked reason=unsolvable" "ac-2 an unavailable pin blocks too"
assert_contains "$out" "skipped=[pinned:htop]" \
  "ac-2 but its token is pinned:, because the package is there and its version is not"

# An index that never answered and a solver that says nothing usable: the network is the
# condition, and `unreachable` is the token the plan block renders as UNREACHABLE.
mkbase
printf 'ERROR: Failed to open APK database: No such file or directory\n' >"$tmp/sim.net"
out="$(APK_UPDATE_RC=1 APK_UPDATE_OUT="$tmp/sim.net" APK_SIM_RC=1 APK_SIM_OUT="$tmp/sim.net" gate)"
assert_contains "$out" "state=blocked reason=unreachable" \
  "ac-2 an index that cannot be fetched is a network answer, not a broken world"
assert_contains "$out" "index=failed" "ac-2 and the index status is recorded"

# A failed index refresh is not fatal on its own: a cache that already carried the index still
# answers, and the verdict is the solver's.
mkbase
out="$(APK_UPDATE_RC=1 APK_UPDATE_OUT="$tmp/sim.net" gate)"
assert_contains "$out" "rc=0 state=ok" \
  "ac-1 an index refresh that failed does not decide anything by itself"
assert_contains "$out" "index=failed" "ac-1 but it is visible in the verdict"

# =========================================================================== #
# ac-2: L, the local packages
# =========================================================================== #
# The four local packages on the measured machine are exactly this shape: only the installed
# database answers for them, and no .apk body was ever kept.
mkbase
cat >"$policy_dir/luci-theme-argon" <<'POLICY'
luci-theme-argon:
  26.249.1-r1:
    lib/apk/db/installed
POLICY
out="$(gate)"
assert_contains "$out" "rc=2 state=gap" \
  "ac-1 a follow with a hole in it is a gap, not a block: it can still run"
assert_contains "$out" "S=ok P=ok L=ok" \
  "ac-2 the three propositions all passed: the hole is in what can be moved"
assert_contains "$out" "skipped=[local:luci-theme-argon]" \
  "ac-2 a local package with no body kept is NO COPY"

# With a body kept, the package is replayable... unless it was built for another kernel.
cp /dev/null "$target/etc/apk/ab/local/luci-theme-argon-26.249.1-r1.apk"
out="$(gate)"
assert_contains "$out" "rc=0 state=ok" "ac-2 a local package with its body kept is followable"
assert_contains "$out" "skipped=[]" "ac-2 and needs no token"

# A kmod-style local package whose dependency names another kernel cannot be replayed: the
# module would not load, which is worse than the one already installed.
mkbase
cat >>"$target/lib/apk/db/installed" <<'DB'
P:kmod-usb-storage
V:6.12.87-r1
D:kernel=6.12.87~bd81971a8c-r1
DB
printf 'kmod-usb-storage\n' >>"$target/etc/apk/world"
printf 'kmod-usb-storage:\n  lib/apk/db/installed\n' >"$policy_dir/kmod-usb-storage"
: >"$target/etc/apk/ab/local/kmod-usb-storage-6.12.87-r1.apk"
out="$(gate)"
assert_contains "$out" "state=gap" "ac-2 a kernel-bound local package is a gap"
assert_contains "$out" "skipped=[stale-abi:kmod-usb-storage]" \
  "ac-2 and its token says why it cannot be replayed"
assert_contains "$out" "L=ok" "ac-2 the proposition still passed: it could be decided"

# A kernel-bound local package whose dependency names *this* kernel is replayable.
mkbase
printf '6.12.103~0413601b1c3f0490e17f340fe09229ea-r1\n' >/dev/null
cat >>"$target/lib/apk/db/installed" <<'DB'
P:kmod-usb-storage
V:6.12.103-r1
D:kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
DB
printf 'kmod-usb-storage\n' >>"$target/etc/apk/world"
printf 'kmod-usb-storage:\n  lib/apk/db/installed\n' >"$policy_dir/kmod-usb-storage"
: >"$target/etc/apk/ab/local/kmod-usb-storage-6.12.103-r1.apk"
out="$(gate)"
assert_contains "$out" "rc=0 state=ok" \
  "ac-2 a body built for this base's kernel is replayable"
assert_contains "$out" "skipped=[]" "ac-2 and needs no token"

# =========================================================================== #
# ac-1: what cannot be judged is a gap, never a pass
# =========================================================================== #
mkbase
minbin="$tmp/minbin"
mkdir -p "$minbin"
for tool in sed awk grep cat rm mkdir ls head tail tr sort wc sleep; do
  found=$(command -v "$tool" 2>/dev/null) && ln -sf "$found" "$minbin/$tool"
done
# /bin/sh by absolute path: with the sanitized PATH a bare `sh` would not be found by anything
# that resolves it through PATH.
out="$(PATH="$minbin" AB_PACKAGES_GATE_TMP="$tmp/gate-tmp" /bin/sh -c '
  . "$1"; ab_packages_gate "$2" "$3"
  printf "rc=%s state=%s reason=%s\n" "$?" "${AB_PACKAGES_GATE_STATE}" "${AB_PACKAGES_GATE_REASON}"' \
  _ "$lib" "$target" "$base" 2>/dev/null)"
assert_contains "$out" "reason=no-apk" "ac-1 without apk the gate cannot judge, and says so"

# No world at all: nothing to judge, and the next boot has nothing to follow either.
rm -rf "$tmp/empty"
mkdir -p "$tmp/empty"
out="$(AB_PACKAGES_GATE_TMP="$tmp/gate-tmp" sh -c '
  . "$1"; ab_packages_gate "$2" "$2"
  printf "rc=%s state=%s reason=%s\n" "$?" "${AB_PACKAGES_GATE_STATE}" "${AB_PACKAGES_GATE_REASON}"' \
  _ "$lib" "$tmp/empty" 2>/dev/null)"
assert_contains "$out" "rc=2 state=gap reason=no-world" \
  "ac-1 a tree with no world is a gap, not a pass"

# No feeds: there is nothing to predict a transaction against.
mkbase
rm -rf "$target/etc/apk/repositories.d" "$base/etc/apk/repositories.d"
out="$(gate)"
assert_contains "$out" "state=gap reason=no-feeds" \
  "ac-1 a target with no feed cannot be predicted, and says so"

# =========================================================================== #
# ac-5: the gate never touches the tree it is judging
# =========================================================================== #
mkbase
mkbase_local() { :; }
: >"$target/etc/apk/ab/local/luci-theme-argon-26.249.1-r1.apk"
printf 'luci-theme-argon:\n  lib/apk/db/installed\n' >"$policy_dir/luci-theme-argon"
before="$(snapshot_tree "$target")"
before_base="$(snapshot_tree "$base")"
for scenario in ok gap blocked; do
  case "$scenario" in
    ok) reset_calls; gate >/dev/null ;;
    gap) reset_calls; gate >/dev/null ;;
    blocked) reset_calls; APK_SIM_RC=1 APK_SIM_OUT="$tmp/sim.net" gate >/dev/null ;;
  esac
  assert_eq "$(snapshot_tree "$target")" "$before" \
    "ac-5 the ${scenario} judgement left the target tree byte for byte as it was"
  assert_eq "$(snapshot_tree "$base")" "$before_base" \
    "ac-5 and the base tree as well"
done

finish
