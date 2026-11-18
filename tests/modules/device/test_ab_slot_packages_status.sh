#!/usr/bin/env bash
# Module: device
# The package state as a person meets it on a running machine: one line from `ab-slot status`,
# two sentences explaining what it means, and the detail behind them from `ab-packages status`.
#
# The record `/boot/ab/packages` is one line (`packages=` / `reason=` / `follow=` / `hint=`), and
# `packages=aligned` alone is the shape that reads like "all good" while the packages have not
# moved at all. ac-9 asks for the pair to be visible together and for the reason to be said in
# words:
#
#   slot=... packages=aligned ... follow=pending reason=network hint=ab-packages update
#   ab-slot: packages were not followed: no usable network
#   ab-slot: retry when it is back: ab-packages update
#
#   ac-1 that pair, and those two sentences, on a machine whose follow could not reach a feed.
#   ac-2 a machine with no record says nothing about a follow: `unknown` is not a claim, and a
#        field that nothing measured must not appear as `follow=none`.
#   ac-3 a followed base says so, and does not print the not-followed sentences.
#   ac-4 every terminal state of the state machine has its own answer: failed (with the reason
#        the record carries), abandoned, and never (the deliberate system-only answer).
#   ac-5 the record names a slot, so a record about another slot is not passed off as this one's
#        follow state.
#   ac-6 `ab-packages status` gives the gap list and when the last attempt was, needs no network
#        and no apk binary, and writes nothing at all.
#   ac-7 the fields that were there before are still there, in the order other readers parse.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

ab_slot="$root/platform/usr/sbin/ab-slot"
ab_packages="$root/platform/usr/sbin/ab-packages"
slot_cfg_lib="$root/platform/lib/ab-slot-cfg.sh"
partitions_lib="$root/platform/lib/ab-partitions.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- a machine: an ESP with a state file, and the mounts it would see --------
esp="$tmp/esp"
mkdir -p "$esp/ab/log" "$esp/boot/grub"
write_state() { # <committed> <pending|none> <gen>
  if [ "$2" = "none" ]; then pending=null; else pending="\"$2\""; fi
  cat >"$esp/ab/state.json" <<JSON
{
  "generation": $3,
  "committed": "$1",
  "pending": $pending,
  "slots": {
    "a": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" },
    "b": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" }
  }
}
JSON
}
write_state a none 3

cmdline="$tmp/cmdline"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"
boot_id_file="$tmp/boot_id"
printf 'boot-1111-2222-3333\n' >"$boot_id_file"
fake_p4="$tmp/p4"
mkdir -p "$fake_p4"
mounts="$tmp/mounts"
cat >"$mounts" <<MOUNTS
/dev/vda1 /boot vfat rw,noatime 0 0
/dev/vda4 ${fake_p4} btrfs rw,noatime 0 0
MOUNTS
stub_di="$tmp/disk-identity.sh"
cat >"$stub_di" <<'STUB'
#!/bin/sh
di_resolve() {
  printf 'disk=%s method=%s\n' "${STUB_DISK:-/dev/sda}" "${STUB_METHOD:-partuuid}"
}
di_parent_disk() {
  printf '%s\n' "$1"
}
STUB
: >"$esp/vmlinuz-a"; : >"$esp/initrd-a"
: >"$esp/vmlinuz-b"; : >"$esp/initrd-b"

record="$esp/ab/packages"

# The stub apk exists only to prove that `ab-packages status` never calls it: a question about a
# broken machine has to be answerable without a package manager that may be the broken part.
bin="$tmp/bin"
mkdir -p "$bin"
calls="$tmp/apk-calls"
: >"$calls"
cat >"$bin/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >>"${APK_CALLS:-/dev/null}"
exit 0
APK
chmod +x "$bin/apk"

slot_status() { # stdout only
  AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="${fake_p4}" AB_MOUNTS="$mounts" \
    AB_SLOT_CFG_LIB="$slot_cfg_lib" AB_PARTITIONS_LIB="$partitions_lib" \
    AB_DISK_IDENTITY_LIB="$stub_di" AB_BOOT_ID_FILE="$boot_id_file" \
    AB_PACKAGES_FILE="$record" \
    sh "$ab_slot" status 2>/dev/null
}

slot_status_both() { # stdout and stderr together
  AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="${fake_p4}" AB_MOUNTS="$mounts" \
    AB_SLOT_CFG_LIB="$slot_cfg_lib" AB_PARTITIONS_LIB="$partitions_lib" \
    AB_DISK_IDENTITY_LIB="$stub_di" AB_BOOT_ID_FILE="$boot_id_file" \
    AB_PACKAGES_FILE="$record" \
    sh "$ab_slot" status 2>&1
}

pkgs_status() { # stdout and stderr together
  PATH="$bin:$PATH" APK_CALLS="$calls" \
    AB_ESP="$esp" AB_PACKAGES_FILE="$record" AB_PACKAGES_ROOT="$esp" \
    AB_PACKAGES_LIB="$root/platform/lib/upgrade/packages.sh" \
    AB_PKGS_ASSETS_LIB="$root/platform/lib/ab-pkgs-assets.sh" \
    AB_PLAN_LIB="$root/platform/lib/ab-plan.sh" \
    AB_VERSION_LIB="$root/platform/lib/ab-version.sh" \
    sh "$ab_packages" "$@" 2>&1
}

pkgs_line() { # the facts line of ab-packages status, stdout only
  PATH="$bin:$PATH" APK_CALLS="$calls" \
    AB_ESP="$esp" AB_PACKAGES_FILE="$record" AB_PACKAGES_ROOT="$esp" \
    AB_PACKAGES_LIB="$root/platform/lib/upgrade/packages.sh" \
    AB_PKGS_ASSETS_LIB="$root/platform/lib/ab-pkgs-assets.sh" \
    AB_PLAN_LIB="$root/platform/lib/ab-plan.sh" \
    AB_VERSION_LIB="$root/platform/lib/ab-version.sh" \
    sh "$ab_packages" "$@" 2>/dev/null
}

tree_hash() { # every file under the ESP, so "wrote nothing" can be proven
  ( cd "$esp" && find . -type f | sort | while IFS= read -r f; do cksum <"$f"; done ) | cksum
}

field() { # <line> <key>: one field of the status line
  printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

# --- ac-7 the fields that were there before are still there -----------------
# The order matters: `platform/lib/upgrade/platform.sh` and the probes take their fields by
# pattern, so a new field is appended and never inserted.
line=$(slot_status)
assert_matches "$line" \
  '^slot=a upper=@overlay-25\.12\.2 generation=3 committed=a pending=none p4=ok .* boot=unknown esp=unknown packages=unknown packages_reason=unknown$' \
  "ac-7 a machine with no record prints the line it always printed"
assert_eq "$(field "$line" packages)" "unknown" \
  "ac-7 and the package verdict is still readable where it was"

# --- ac-2 no record: nothing is said about a follow -------------------------
rm -f "$record"
out=$(slot_status_both)
assert_eq "$(field "$(slot_status)" follow)" "" \
  "ac-2 with no record there is no follow= field: a follow nothing measured is not reported"
case "$out" in
  *"were not followed"*)
    assert_eq "follow prose without a record" "none" \
      "ac-2 a machine with no record is not told its packages were not followed"
    ;;
  *)
    assert_eq "clean" "clean" "ac-2 and no prose about a follow appears at all"
    ;;
esac

# --- ac-1 the shape ac-9 asks for -------------------------------------------
printf 'packages=aligned reason=network follow=pending upgraded=0 kept=0 skipped=local:htop version=25.12.2 kernel=kernel=6.12.103~abc slot=a hint=ab-packages update\n' \
  >"$record"
line=$(slot_status)
assert_contains "$line" "packages=aligned" "ac-1 the alignment verdict is reported"
assert_contains "$line" "follow=pending reason=network hint=ab-packages update" \
  "ac-1 and the follow state, its reason and the command that retries it, on the same line"
assert_eq "$(field "$line" follow)" "pending" "ac-1 follow= is a field a script can read"
assert_eq "$(field "$line" reason)" "network" "ac-1 reason= carries the record's own token"
assert_eq "$(field "$line" hint)" "ab-packages" \
  "ac-1 hint= starts with the command the record published"
out=$(slot_status_both)
assert_contains "$out" "packages were not followed: no usable network" \
  "ac-1 the first sentence names what did not happen"
assert_contains "$out" "retry when it is back: ab-packages update" \
  "ac-1 the second sentence says what to do about it"
# `aligned` beside `pending` is the pair that used to read like "all good": the human line for the
# verdict must not contradict the two sentences below it.
assert_contains "$out" "packages aligned" "ac-1 the verdict line is still printed"

# --- ac-3 a followed base ---------------------------------------------------
printf 'packages=followed reason=none follow=followed upgraded=3 kept=4 skipped=none version=25.12.2 kernel=kernel=6.12.103~abc slot=a hint=none\n' \
  >"$record"
line=$(slot_status)
assert_eq "$(field "$line" packages)" "followed" \
  "ac-3 a followed base reports followed, not the alignment verdict it grew out of"
assert_contains "$line" "follow=followed reason=none hint=none" \
  "ac-3 and the follow fields say the work is done and nothing is left to run"
out=$(slot_status_both)
assert_contains "$out" "packages followed onto this kernel" \
  "ac-3 the human line explains what followed means"
case "$out" in
  *"were not followed"*)
    assert_eq "prose on a followed base" "none" \
      "ac-3 a followed base is not told its packages were not followed"
    ;;
  *)
    assert_eq "clean" "clean" "ac-3 and no retry sentence appears"
    ;;
esac

# --- ac-4 every terminal state ----------------------------------------------
printf 'packages=aligned reason=apk-1 follow=failed version=25.12.2 kernel=kernel=6.12.103~abc slot=a hint=ab-packages update\n' \
  >"$record"
line=$(slot_status)
assert_contains "$line" "follow=failed reason=apk-1 hint=ab-packages update" \
  "ac-4 a failed transaction keeps its reason beside the state"
out=$(slot_status_both)
assert_contains "$out" "packages were not followed: reason=apk-1" \
  "ac-4 a failure that is not the network is named by its token, not hidden"
assert_contains "$out" "retry: ab-packages update" \
  "ac-4 and the retry is offered without claiming the network is the problem"

printf 'packages=aligned reason=network follow=abandoned version=25.12.2 kernel=kernel=6.12.103~abc slot=a hint=ab-packages update\n' \
  >"$record"
line=$(slot_status)
assert_contains "$line" "follow=abandoned reason=network" \
  "ac-4 an abandoned follow still says why it was abandoned"
assert_contains "$(slot_status_both)" "retry when it is back: ab-packages update" \
  "ac-4 and it is retryable on demand, which is the whole point of not deleting the record"

printf 'packages=aligned reason=none follow=never version=25.12.2 kernel=kernel=6.12.103~abc slot=a hint=none\n' \
  >"$record"
line=$(slot_status)
assert_contains "$line" "follow=never reason=none hint=none" \
  "ac-4 the system-only answer is a state of its own, not a missing value"
out=$(slot_status_both)
assert_contains "$out" "left to the system update on purpose" \
  "ac-4 and it is described as deliberate, so nobody looks for a follow that was never owed"
case "$out" in
  *"were not followed"*)
    assert_eq "prose on a never base" "none" \
      "ac-4 a deliberate answer is not reported as a failure"
    ;;
  *)
    assert_eq "clean" "clean" "ac-4 no retry sentence is printed for it"
    ;;
esac

# --- ac-5 a record that names another slot ----------------------------------
# The record describes one slot. While the other slot still runs, its follow state says nothing
# about this boot - which is `ab-slot status`'s judgement, and it must not be passed off as this
# machine's own.
printf 'packages=aligned reason=network follow=pending version=25.12.3 kernel=kernel=6.12.104~def slot=b hint=ab-packages update\n' \
  >"$record"
line=$(slot_status)
assert_contains "$line" "follow=unknown reason=other-slot hint=none" \
  "ac-5 a record about another slot is not reported as this slot's follow state"
case "$(slot_status_both)" in
  *"were not followed"*)
    assert_eq "prose for another slot" "none" \
      "ac-5 and no sentence claims this machine owes a follow it does not know about"
    ;;
  *)
    assert_eq "clean" "clean" "ac-5 nothing is claimed about a follow for this boot"
    ;;
esac

# An unrecognised token is not a state: the field is a closed set and anything else is unknown.
printf 'packages=aligned reason=none follow=maybe version=25.12.2 kernel=kernel=6.12.103~abc slot=a hint=ab-packages update\n' \
  >"$record"
assert_eq "$(field "$(slot_status)" follow)" "unknown" \
  "ac-5 a follow token this state machine cannot produce reads as unknown"

# --- ac-6 ab-packages status: the gaps and the last attempt ------------------
# The record below is what a machine looks like after a follow that left three holes: a local
# package with no kept body, a local package built against another kernel, and a pinned entry.
printf 'packages=aligned reason=network follow=pending upgraded=0 kept=0 skipped=local:htop,stale-abi:luci-app-x,pinned:busybox cache=0 version=25.12.2 kernel=kernel=6.12.103~abc slot=a hint=ab-packages update\n' \
  >"$record"
mkdir -p "$esp/etc/apk/ab/local"
printf 'kept body\n' >"$esp/etc/apk/ab/local/luci-app-x-1.0-r1.apk"
printf 'superseded name=luci-app-x version=0.9-r1 source=customfeeds at=1\n' \
  >"$esp/etc/apk/ab/local/superseded"
touch -t 202601010000.00 "$record"
record_mtime=$(stat -c %Y "$record" 2>/dev/null || stat -f %m "$record")

: >"$calls"
before_hash=$(tree_hash)
out=$(pkgs_status status)
rc=$?
after_hash=$(tree_hash)
assert_eq "$rc" "0" "ac-6 ab-packages status succeeds on a machine with a broken follow"
assert_eq "$after_hash" "$before_hash" "ac-6 a question writes nothing, not even a timestamp"
assert_eq "$(wc -l <"$calls" | tr -d ' ')" "0" \
  "ac-6 and it asks no package manager: status has to work when apk is the broken part"

line=$(pkgs_line status | head -n 1)
assert_contains "$line" "packages=aligned" "ac-6 the facts line carries the record's state"
assert_contains "$line" "follow=pending reason=network" "ac-6 and the follow state with its reason"
assert_contains "$line" "hint=ab-packages update" "ac-6 and the retry the record published"
assert_eq "$(field "$line" last-attempt)" "$record_mtime" \
  "ac-6 the time of the last attempt is the record's own write time"
assert_matches "$(pkgs_line status | sed -n 2p)" '^assets=[0-9]+ assets-bytes=[0-9]+ superseded=[0-9]+ cache-files=' \
  "ac-6 the second line reports the kept bodies and the cache, not a guess"
assert_contains "$out" "htop: no body was kept" \
  "ac-6 the gap list says which package has no body and why that matters"
assert_contains "$out" "replay <file.apk>" \
  "ac-6 and how to keep one next time"
assert_contains "$out" "luci-app-x: built against another kernel" \
  "ac-6 a body that cannot be replayed on this kernel is named as such"
assert_contains "$out" "busybox: pinned in the world" \
  "ac-6 a pinned entry is explained instead of being counted as a failure"
assert_contains "$out" "last attempt" "ac-6 the age of the last attempt is printed in words"
assert_contains "$out" "superseded name=luci-app-x" \
  "ac-6 and a body a feed took back over is still readable after it was deleted"
assert_contains "$out" "still owed - retry with: ab-packages update" \
  "ac-6 the hint is repeated as the one action left"

# --- ac-6 no record at all ---------------------------------------------------
rm -f "$record"
line=$(pkgs_line status | head -n 1)
assert_contains "$line" "packages=unknown follow=unknown reason=unknown" \
  "ac-6 with no record every answer is unknown, never a plausible default"
assert_contains "$line" "last-attempt=unknown" \
  "ac-6 and the last attempt is unknown rather than 'never'"
assert_contains "$(pkgs_status status)" "no record" \
  "ac-6 the human line says there is no record instead of inventing one"

# --- ac-6 the two commands agree on the same record -------------------------
printf 'packages=aligned reason=network follow=pending upgraded=0 kept=0 skipped=local:htop version=25.12.2 kernel=kernel=6.12.103~abc slot=a hint=ab-packages update\n' \
  >"$record"
slot_follow=$(field "$(slot_status)" follow)
pkgs_follow=$(field "$(pkgs_line status | head -n 1)" follow)
assert_eq "$pkgs_follow" "$slot_follow" \
  "ac-6 the follow state is the same field read by both commands, not two opinions"
assert_eq "$(field "$(pkgs_line status | head -n 1)" reason)" "$(field "$(slot_status)" reason)" \
  "ac-6 and so is the reason"

finish
