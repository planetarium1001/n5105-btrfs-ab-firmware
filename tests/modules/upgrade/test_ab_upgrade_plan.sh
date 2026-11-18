#!/usr/bin/env bash
# Module: upgrade
# The plan the installer shows before it writes a slot: section `5b. The package plan` of
# platform/usr/sbin/ab-upgrade, the gate and the prefetch it drives, and the one question
# from platform/lib/ab-plan.sh (design.md §5-§8, task 20261118-02).
#
# The section sits between the conflict report and the first slot write, and that position is
# the whole contract: the staging tree, the gate, the block and the question are predictions
# made under /tmp, and nothing outside /tmp may be written until the question came back 0.
# This test drives the real ab-upgrade end to end against a stand-in machine (the same one
# tests/modules/upgrade/test_apk_align.sh builds) and a stub apk, so what is asserted is the
# wording, the exit codes and the files a device would see - not a library in isolation.
#
#   ac-4  no terminal and no --yes: `refused, reason=noninteractive`, exit 74, and nothing
#         written - no record on the ESP, no slot layer, no question in the log
#   ac-3  the block is rendered (Update / Packages / Config); with --yes the answer is
#         already given, so the block is still shown but the question is not asked
#   ac-6  after a follow was accepted the bodies are prefetched into the staging cache and
#         the run says so, before the slot is written
#   ac-1  --system-only writes `follow=never` instead of `follow=pending`, asks nothing and
#         prefetches nothing: the record must not promise a follow the user declined
#   ac-4  `n` leaves with `declined, nothing was written` and exit 0 - a refusal is not a
#         failure of the machine
#   ac-4  an empty Enter is not an answer: the same line is printed again and the `y` that
#         follows still installs
#   compat a payload built before this release carries no lib/ab-plan.sh: the whole section
#         is skipped, says so, and the install proceeds without any new flag
#   ac-6  --no-prefetch still records the follow as owed and downloads nothing; --dry-run
#         (= --check) writes neither a record nor a staged cache at all
#
# Everything here is offline: `apk` is a stub in $bin, so the gate's `update`/`--simulate
# upgrade`/`policy` and the prefetch's `fetch` cannot reach a feed even by accident.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

packages_lib="$root/platform/lib/upgrade/packages.sh"
plan_lib="$root/platform/lib/ab-plan.sh"
platform_sh="$root/platform/lib/upgrade/platform.sh"
ab_upgrade="$root/platform/usr/sbin/ab-upgrade"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for required in "$packages_lib" "$plan_lib" "$platform_sh" "$ab_upgrade"; do
  [ -f "$required" ] || {
    printf 'not ok 1 - %s exists\n' "${required#"$root"/}" >&2
    printf '    missing %s\n' "$required" >&2
    exit 1
  }
done

# --------------------------------------------------------------------------- #
# payload
# --------------------------------------------------------------------------- #
# build_payload <dir> <version> [--no-plan-lib]
#
# A payload shaped like the one `scripts/build-payload.sh` produces: the target base's world
# and feed list in rootfs.tar.gz (that is where the gate reads the pins and the feeds from),
# a kernel, an initramfs, and a platform layer carrying the libraries this release adds. The
# two plan libraries travel *in the payload* because that is the rule the section implements:
# the payload decides whether a plan exists, so that an install can never run a renderer the
# payload was not built against.
build_payload() { # <dir> <version> [--no-plan-lib]
  local dir="$1" version="$2" with_plan=1
  [ "${3:-}" = "--no-plan-lib" ] && with_plan=0
  rm -rf "$dir"
  mkdir -p "$dir/rootfs/sbin" "$dir/rootfs/etc/apk/repositories.d" \
    "$dir/cpio/lib/modules/6.12.87" "$dir/platform/lib/upgrade" "$dir/platform/lib" \
    "$dir/platform/usr/sbin"
  printf '#!/bin/sh\n' >"$dir/rootfs/sbin/init"
  chmod +x "$dir/rootfs/sbin/init"
  # The target base pins the kernel this release was built for; that pin is what the
  # staging aligner moves the user's world to.
  printf 'busybox\nkernel=6.12.87~bd81971a8c-r1\nluci\n' >"$dir/rootfs/etc/apk/world"
  # The feed list the base ships: repositories.d/*.list is what apk-tools 3 reads, and the
  # kmods segment in it is the only place the target's kernel build hash comes from.
  cat >"$dir/rootfs/etc/apk/repositories.d/distfeeds.list" <<FEEDS
https://downloads.immortalwrt.org/releases/${version}/targets/x86/64/packages/packages.adb
https://downloads.immortalwrt.org/releases/${version}/targets/x86/64/kmods/6.12.87-1-bd81971a8c/packages.adb
FEEDS
  tar -czf "$dir/rootfs.tar.gz" -C "$dir/rootfs" .
  printf 'vermagic=6.12.87 SMP mod_unload \n' >"$dir/kernel.bin"
  printf 'vermagic=6.12.87 SMP mod_unload \n' >"$dir/cpio/lib/modules/6.12.87/btrfs.ko"
  ( cd "$dir/cpio" && find . -print | cpio -o -H newc 2>/dev/null ) | gzip -9 >"$dir/initramfs.cpio.gz"
  cp "$packages_lib" "$dir/platform/lib/upgrade/packages.sh"
  # The plan renderer and the question are a second library on purpose (design.md §6): a
  # payload that carries only the aligner is a payload from before this change, and case 6
  # builds exactly that one.
  [ "$with_plan" = "1" ] && cp "$plan_lib" "$dir/platform/lib/ab-plan.sh"
  : >"$dir/platform/usr/sbin/btrfs"
  chmod +x "$dir/platform/usr/sbin/btrfs"
  tar -cf "$dir/platform.tar" -C "$dir/platform" .
  python3 - "$dir" "$version" <<'PYTHON'
import hashlib, json, pathlib, sys
stage = pathlib.Path(sys.argv[1])
members = {}
for name in ("initramfs.cpio.gz", "kernel.bin", "platform.tar", "rootfs.tar.gz"):
    data = (stage / name).read_bytes()
    members[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
(stage / "manifest.json").write_text(
    json.dumps({"format": "ab-payload/1", "rootfs": sys.argv[2], "members": members,
                "bootloader": None}, indent=2, sort_keys=True) + "\n")
PYTHON
  rm -rf "$dir/rootfs" "$dir/cpio" "$dir/platform"
  tar -cf "$dir/payload.tar" -C "$dir" manifest.json
  for member in rootfs.tar.gz kernel.bin initramfs.cpio.gz platform.tar; do
    tar -rf "$dir/payload.tar" -C "$dir" "$member"
  done
  printf '%s' "$dir/payload.tar"
}

payload_plan="$(build_payload "$tmp/payload-plan" 25.12.0)"
payload_old="$(build_payload "$tmp/payload-old" 25.12.0 --no-plan-lib)"

# --------------------------------------------------------------------------- #
# stand-in machine
# --------------------------------------------------------------------------- #
# One ESP, one writable partition, slot b and the stubs ab-upgrade needs. `mk_machine`
# rebuilds all of it, so no case inherits the record, the layer or the staged cache a
# previous case left behind - which is what "nothing was written" has to mean.
esp="$tmp/m/esp"
p4="$tmp/m/p4"
slots="$tmp/m/slots"
bin="$tmp/m/bin"
# The staging root the plan section builds under /tmp. See the note in `run_upgrade`.
stage="$tmp/stage"

mk_machine() {
  rm -rf "$tmp/m" "$stage"
  mkdir -p "$esp/ab/log" "$p4/@overlay-25.12.2/upper/etc/apk/repositories.d" \
    "$slots/b/@sys/sbin" "$slots/b/@sys/etc/apk" "$slots/b/@platform" "$bin"
  printf '#!/bin/sh\n' >"$slots/b/@sys/sbin/init"
  chmod +x "$slots/b/@sys/sbin/init"
  printf '{"generation":1,"committed":"a","pending":null,"slots":{"a":{"rootfs":"25.12.2","upper":"@overlay-25.12.2"},"b":{"rootfs":"25.12.2","upper":"@overlay-25.12.2"}}}\n' \
    >"$esp/ab/state.json"
  # The running slot's writable layer is a snapshot of the release it runs: its world pins
  # the kernel the machine boots today, and its copy of the base's feed file names that
  # release. Both are what the staging aligner has to move before the gate may judge it.
  printf 'busybox\nkernel=6.12.103~ff11223344-r1\nluci\nhtop\n' \
    >"$p4/@overlay-25.12.2/upper/etc/apk/world"
  cat >"$p4/@overlay-25.12.2/upper/etc/apk/repositories.d/distfeeds.list" <<'FEEDS'
https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/packages/packages.adb
https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/kmods/6.12.103-1-ff11/packages.adb
FEEDS

  cat >"$bin/sha256sum" <<'STUB'
#!/bin/sh
for f in "$@"; do
  [ -f "$f" ] && printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
done
STUB
  # ab-slot owns the state file; these answers are the ones the run reads back.
  cat >"$bin/ab-slot" <<'STUB'
#!/bin/sh
case "${1:-status}" in
  status) printf '%s\n' "slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none p4=ok" ;;
  rootfs) printf '%s\n' "25.12.2" ;;
  next) printf '%s\n' "next=b" ;;
  *) exit 0 ;;
esac
STUB
  cat >"$bin/df" <<'STUB'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 1000000 0 800000 0%% /tmp\n'
STUB
  cat >"$bin/btrfs" <<'STUB'
#!/bin/sh
case "${1:-}:${2:-}" in
  subvolume:snapshot) cp -a "$3" "$4" 2>/dev/null || true ;;
  subvolume:create) mkdir -p "$3" ;;
  subvolume:delete)
    shift 2
    for a in "$@"; do [ "$a" = "-C" ] && continue; rm -rf "$a"; done
    ;;
esac
exit 0
STUB
  cat >"$bin/mount" <<'STUB'
#!/bin/sh
exit 0
STUB
  cat >"$bin/ab-partitions.sh" <<'STUB'
# shellcheck shell=sh
ab_find_partition() { printf '%s' "/dev/fake"; }
STUB
  # The stub answers the three questions the gate asks and the one the prefetch asks, in
  # the shapes apk-tools 3 uses (measured 2026-11-18 on apk-tools 3.0.5):
  #   update             -> the index answered
  #   upgrade <names>    -> one `Upgrading <name>` line per name, which is what the solver
  #                         prints and what the prefetch reads the moving set off
  #   policy <name>      -> only the installed database offers it, i.e. a repository
  #                         package (a local one would name no source at all, and the
  #                         gate would attribute it to NO COPY)
  #   fetch -o <dir> ..  -> one body per requested package, which is the evidence the
  #                         prefetch is judged by
  # Nothing here reads or writes the network.
  cat >"$bin/apk" <<'STUB'
#!/bin/sh
applet=""
out=""
names=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root|--cache-dir|--repositories-file|--timeout) shift 2 ;;
    --simulate|-s|--recursive) shift ;;
    -o) out=$2; shift 2 ;;
    -o*) out=${1#-o}; shift ;;
    -*) shift ;;
    update|upgrade|add|fetch|policy|search|info) [ -n "$applet" ] || applet=$1; shift ;;
    *) names="$names $1"; shift ;;
  esac
done
printf '%s %s\n' "${applet}" "${names# }" >>"${APK_CALLS:-/dev/null}"
case "${applet}" in
  update) exit 0 ;;
  upgrade)
    # `--simulate` and the real transaction print the same shape on this apk; the prefetch
    # reads the moving set from the solver's answer, so a stub that printed nothing would make
    # every world look current.
    for name in ${names}; do
      printf '(1/1) Upgrading %s (1.0-r1 -> 1.1-r1)\n' "${name}"
    done
    exit 0
    ;;
  policy) printf '%s:\n  lib/apk/db/installed\n' "${names# }"; exit 0 ;;
  fetch)
    for name in ${names}; do
      mkdir -p "${out}" 2>/dev/null || exit 1
      printf 'apk body for %s\n' "${name}" >"${out}/${name}-1.0-r1.apk" || exit 1
    done
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$bin"/*
}

# run_upgrade <stdin-text> <terminal: 0|1> [flags...]: one ab-upgrade run at the stand-in
# machine.
# Leaves RC and OUT (both streams, in order) for the assertions to read.
#
# <stdin-text> is what the person would type, with \n between the lines (`printf %b`); the
# input is always a pipe, and <terminal> decides whether AB_UPGRADE_ASSUME_TTY stands in for
# a tty - that is the only difference between the two paths, because the only thing the
# library checks is `[ -t 0 ]`.
#
# pkg_stage is exported because ab-upgrade reads the staging root from it but never assigns
# it: the plan section uses ${pkg_stage}/sys, /layer and /target, so with the variable unset
# those paths expand to /sys, /layer and /target. Pinning it into the test's own directory is
# what keeps this test off the machine's real root *and* lets the staging tree - which the
# install deletes together with ${work} - be judged after the run. A fix in ab-upgrade that
# assigns the same `${work}/pkgplan` path overrides this and the assertions below would have
# to be pointed at ${work}/pkgplan instead; the defect is in the task's report, not here.
run_upgrade() { # <stdin> <terminal> [flags...]
  local input="$1" term="$2" assume=""
  shift 2
  [ "$term" = "1" ] && assume=1
  OUT=$(printf '%b' "$input" | env \
    PATH="$bin:$PATH" \
    AB_ESP="$esp" AB_P4="$p4" AB_LIB="$platform_sh" \
    AB_PARTITIONS_LIB="$bin/ab-partitions.sh" AB_SLOTS_ROOT="$slots" \
    AB_PACKAGES_FILE="$esp/ab/packages" \
    AB_UPGRADE_ASSUME_TTY="$assume" \
    COLUMNS=80 \
    AB_PACKAGES_GATE_TIMEOUT=10 AB_PACKAGES_PREFETCH_TIMEOUT=10 \
    APK_CALLS="$tmp/m/apk.calls" \
    pkg_stage="$stage" \
    sh "$ab_upgrade" "$payload" "$@" 2>&1)
  RC=$?
  return 0
}

# exists <path>: `present` or `absent`, so a "was it written" assertion fits on one line.
exists() { [ -e "$1" ] && printf 'present' || printf 'absent'; }
layers() { ls -d "$p4"/@overlay-"$1"* 2>/dev/null | wc -l | tr -d ' '; }
prompts() { printf '%s\n' "$OUT" | awk '{ n += gsub(/Proceed and follow/, "") } END { printf "%d", n + 0 }'; }

# =========================================================================== #
# ac-4: no terminal and no --yes is a refusal, and a refusal writes nothing
# =========================================================================== #
# This is the case a script hits: `ab-upgrade payload.tar` from cron, from a CI step or
# through ssh without a pty. It must fail loudly *before* the block is printed and before
# anything is written, because the alternative - hanging on a read, or a bare Enter being
# read as consent - is a firmware write nobody agreed to.
mk_machine
payload="$payload_plan"
run_upgrade '' 0
assert_eq "$RC" "74" \
  "ac-4 a follow with no terminal to ask on exits 74, not 0 and not 1"
assert_contains "$OUT" "refused, reason=noninteractive" \
  "ac-4 the refusal names the reason and points at --yes"
assert_eq "$(prompts)" "0" \
  "ac-4 and no question is printed: a prompt nobody can answer only fills the log"
assert_eq "$(exists "$esp/ab/packages")" "absent" \
  "ac-4 no packages record was published on the ESP before the answer"
assert_eq "$(layers 25.12.0)" "0" \
  "ac-4 and no target layer was created: the install stopped before the first slot write"

# =========================================================================== #
# ac-3 / ac-6: --yes accepts the block, and the bodies are fetched before the switch
# =========================================================================== #
# The plan is shown even when the answer is already given: the operator asked to be told
# what is about to happen, not only to be asked. That is why --yes suppresses the question
# and not the block, and the survey below is the whole reason the section runs apk at all.
mk_machine
payload="$payload_plan"
run_upgrade '' 0 --yes
assert_eq "$RC" "0" "ac-6 an accepted follow installs the slot"
assert_contains "$OUT" "Packages" \
  "ac-3 the block is rendered before the answer, with its Packages section"
assert_eq "$(prompts)" "0" \
  "ac-4 --yes answers the question, so nothing is asked"
# The staging copy was aligned like the install will be: the preview must describe the
# transaction the first boot runs, not the stale pins the layer still carries.
assert_eq "$(grep '^kernel=' "$stage/layer/etc/apk/world" 2>/dev/null)" \
  "kernel=6.12.87~bd81971a8c-r1" \
  "ac-6 the staged world is pinned to the base the slot will carry"
assert_file_exists "$stage/target/etc/apk/ab/cache/busybox-1.0-r1.apk" \
  "ac-6 the prefetch left the package body in the staging cache the first boot reads"
assert_eq "$(ls "$stage/target/etc/apk/ab/cache" 2>/dev/null | grep -c '\.apk$')" \
  "$(awk 'NF && $0 !~ /^kernel(=|$)/ { n++ } END { printf "%d", n + 0 }' \
    "$stage/target/etc/apk/world" 2>/dev/null)" \
  "ac-6 one body per world entry the follow has to move (the kernel is ab-slot's and is never fetched)"
assert_contains "$OUT" "prefetched" \
  "ac-6 the run says the bodies were prefetched, so a reader of the log needs no cache"
assert_contains "$(cat "$esp/ab/packages" 2>/dev/null)" "follow=pending" \
  "ac-6 an accepted follow is recorded as still owed, so the first boot runs it"

# =========================================================================== #
# ac-1: --system-only is the decision not to follow, and the record must say so
# =========================================================================== #
# `--system-only` (and its spelling `--no-follow`) exists because a broken or unwanted
# package is the normal reason to still take the base. It asks nothing, prefetches nothing,
# and must not leave `follow=pending` behind it: the first boot would then run a follow the
# user just declined, which is the silent behaviour this change exists to remove.
mk_machine
payload="$payload_plan"
run_upgrade '' 0 --system-only
assert_eq "$RC" "0" "ac-1 a system-only switch installs the slot"
assert_eq "$(prompts)" "0" \
  "ac-1 system-only is an answer, so the question is never put"
assert_contains "$(cat "$esp/ab/packages" 2>/dev/null)" "follow=never" \
  "ac-1 the record says no follow is owed"
assert_eq "$(grep -c 'follow=pending' "$esp/ab/packages" 2>/dev/null)" "0" \
  "ac-1 and it does not also promise a pending follow"
assert_eq "$(exists "$stage/target/etc/apk/ab/cache")" "absent" \
  "ac-1 no bodies are prefetched for a follow the user declined"

# =========================================================================== #
# ac-4: `n` declines, and declining is not a failure
# =========================================================================== #
# A person answered the question. That is a decision, not a broken machine, so the run ends
# with 0 and with the documented sentence - the slot, the ESP record and the layer stay as
# they were, which is what makes the prompt safe to try.
mk_machine
payload="$payload_plan"
run_upgrade 'n\n' 1
assert_eq "$RC" "0" "ac-4 declining the follow is not an upgrade failure"
assert_contains "$OUT" "declined, nothing was written" \
  "ac-4 the run says what the answer did"
assert_contains "$OUT" "Proceed and follow" \
  "ac-4 and the question really was asked before the decline"
assert_eq "$(exists "$esp/ab/packages")" "absent" \
  "ac-4 a decline publishes no record"
assert_eq "$(layers 25.12.0)" "0" \
  "ac-4 a decline writes no slot layer"

# =========================================================================== #
# compat: a payload from before this release carries no plan, and still installs
# =========================================================================== #
# The two libraries come out of the payload, so a payload built by an older release carries
# only the aligner. The section must then skip itself and say so - rendering a block whose
# counts nobody computed would be the guess this project keeps paying for - and the install
# must go through exactly as before, with no new flag to learn.
mk_machine
payload="$payload_old"
run_upgrade '' 0
assert_eq "$RC" "0" "compat a payload without the plan library still installs"
assert_contains "$OUT" "carries no package plan" \
  "compat the run says why no block was shown"
assert_eq "$(prompts)" "0" \
  "compat and nothing is asked, because there is no count to ask about"
assert_eq "$(layers 25.12.0)" "1" \
  "compat the slot is written exactly as before"

# =========================================================================== #
# ac-6: --no-prefetch keeps the follow, and leaves the download to the first boot
# =========================================================================== #
# The bodies are a convenience, not part of the verdict: a machine that meets the follow
# without the download - a metered link, an operator who wants the slot written now - must
# still get `follow=pending`, and the record's fallback (the network at first boot) is what
# picks it up. A flag that silently turned the follow off would be a machine that never
# updates its packages.
mk_machine
payload="$payload_plan"
run_upgrade '' 0 --yes --no-prefetch
assert_eq "$RC" "0" "ac-6 --no-prefetch still installs the slot"
assert_eq "$(exists "$stage/target/etc/apk/ab/cache")" "absent" \
  "ac-6 --no-prefetch downloads nothing"
assert_contains "$(cat "$esp/ab/packages" 2>/dev/null)" "follow=pending" \
  "ac-6 and the follow is still owed, so the first boot uses the network"

# =========================================================================== #
# ac-4: --dry-run is --check, and neither reaches the plan or the slot
# =========================================================================== #
# `--dry-run` is the name an operator reaches for first, and it must mean exactly what
# `--check` means: validate, print, write nothing - including no staging cache and no
# record. A dry run that quietly prefetched would be a dry run that used the network.
mk_machine
payload="$payload_plan"
run_upgrade '' 0 --dry-run
assert_eq "$RC" "0" "ac-4 --dry-run ends with 0 like --check"
assert_contains "$OUT" "check only, nothing written" \
  "ac-4 and says it wrote nothing"
assert_eq "$(exists "$esp/ab/packages")$(exists "$stage")" "absentabsent" \
  "ac-4 a dry run publishes no record and stages nothing"

# =========================================================================== #
# ac-4: an empty Enter does not advance, a `y` after it does
# =========================================================================== #
# Enter is the cheapest key on a console and the most expensive misunderstanding on a
# firmware write, so the answer set is closed: y/Y/yes/YES/Yes accept, n/N/no/NO/No decline,
# and everything else - a bare Enter included - reprints the same line without moving on.
# The `y` on the second line is what proves the loop really resumed instead of advancing on
# the Enter or giving up on it.
mk_machine
payload="$payload_plan"
run_upgrade '\ny\n' 1
assert_eq "$RC" "0" "ac-4 the question was answered on the second try"
assert_eq "$(prompts)" "2" \
  "ac-4 the empty Enter reprinted the same question instead of answering it"
assert_eq "$(layers 25.12.0)" "1" \
  "ac-4 and the y that followed still accepted the install"

finish
