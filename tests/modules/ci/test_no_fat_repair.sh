#!/usr/bin/env bash
# Module: ci
# What the boot environment is not allowed to acquire, and what it has to expose instead.
# The ESP is the only fault surface on this machine that cannot be repaired from the running
# system, so this round makes it observable and nothing else:
#   ac-9 no FAT repair tool enters the boot path - no `dosfstools`, no `fsck.fat`, no
#        `fsck.vfat` anywhere in initramfs/ or in the toolset lockfile - and the read-only
#        verdict the initramfs produces is exposed twice: as one `stage=esp-health` line in
#        the ring log, and as an `esp=` field on the `ab-slot status` line.
#
# The absence is the assertion. A rule that lives in a review comment gets reintroduced the
# next time somebody wants a broken FAT repaired at boot; a test does not.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

# The three names, spelled so that this file can grep for them without matching itself
# (it lives in tests/, which is not scanned, but a later move must not make it lie).
forbidden='dosfstools|fsck\.fat|fsck\.vfat'

# --------------------------------------------------------------------------- #
# ac-9 nothing in the boot path repairs a FAT
# --------------------------------------------------------------------------- #

initramfs_hits="$(grep -rnE "${forbidden}" initramfs/ 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "${initramfs_hits}" "0" \
  "ac-9 initramfs/ carries no FAT repair tool, no reference to one and no wrapper for one"

lock_hits="$(grep -nE "${forbidden}" scripts/ci/initramfs-tools.lock.json 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "${lock_hits}" "0" \
  "ac-9 the initramfs toolset lockfile ships none of them"

# The lockfile is what the build may carry, so it is read as data: the repair tools are not
# packages, are not applets and are not mandated commands.
if command -v python3 >/dev/null 2>&1; then
  lock_report="$(python3 - <<'PY'
import json

with open("scripts/ci/initramfs-tools.lock.json") as handle:
    lock = json.load(handle)

names = {entry.get("name") for entry in lock.get("packages") or [] if isinstance(entry, dict)}
applets = set(lock.get("applets") or [])
required = set(lock.get("required_applets") or [])
banned = {"dosfstools", "fsck.fat", "fsck.vfat", "fsck", "mkfs.fat", "fatlabel"}
print("packages_hit=" + (",".join(sorted(names & banned)) or "none"))
print("applets_hit=" + (",".join(sorted(applets & banned)) or "none"))
print("required_hit=" + (",".join(sorted(required & banned)) or "none"))
PY
)"
  assert_contains "${lock_report}" "packages_hit=none" \
    "ac-9 the lockfile names no FAT repair package"
  assert_contains "${lock_report}" "applets_hit=none" \
    "ac-9 ... and no FAT repair applet"
  assert_contains "${lock_report}" "required_hit=none" \
    "ac-9 ... and does not require one"
else
  printf 'ok - ac-9 python3 unavailable, the lockfile data check is skipped\n'
fi

# The tools the probe actually reaches for are shipped: a probe that calls a program the
# image does not carry is a boot that dies at its first byte.
init_src="$(cat initramfs/boot/init)"
assert_contains "$init_src" '. /lib/esp-health.sh' \
  "ac-9 the init sources the ESP probe"
for applet in dd hexdump dmesg sync; do
  required_line="$(grep -c "\"${applet}\"" scripts/ci/initramfs-tools.lock.json || true)"
  assert_eq "$((required_line > 0))" "1" \
    "ac-9 the probe's ${applet} is in the shipped toolset"
done

# --------------------------------------------------------------------------- #
# ac-9 the verdict is exposed, twice
# --------------------------------------------------------------------------- #
# 1. The ring log: ab-boot republishes the p4 record as one line, the way it already does
#    for the growth result, so a pulled ESP explains the boot on its own.
ab_boot="$(cat platform/etc/init.d/ab-boot)"
assert_contains "${ab_boot}" 'stage=esp-health' \
  "ac-9 ab-boot publishes the verdict as a stage=esp-health line"
assert_contains "${ab_boot}" '.ab/esp-health' \
  "ac-9 ... read from the record the initramfs left on p4"
assert_contains "${ab_boot}" 'log_append "stage=esp-health' \
  "ac-9 ... through the ring log writer, next to the growth line"

# 2. `ab-slot status`: one more field, at the end of the line, where parsers already look
#    for the last token.
ab_slot="$(cat platform/usr/sbin/ab-slot)"
assert_contains "${ab_slot}" 'boot=%s esp=%s' \
  "ac-9 status carries the verdict as an esp= field after boot="
assert_contains "${ab_slot}" 'stage=esp-health' \
  "ac-9 ... read from this boot's ring log, the only file that can answer for this boot"
assert_contains "${ab_slot}" 'esp=ok | esp=dirty | esp=unreadable' \
  "ac-9 ... it passes on the three tokens the probe produces and nothing else"
esp_reader="$(printf '%s\n' "${ab_slot}" | sed -n '/^esp_health_state() {/,/^}/p')"
assert_eq "$(printf '%s\n' "${esp_reader}" | grep -c "printf 'unknown'")" "2" \
  "ac-9 ... and falls back to unknown both when the log is unreadable and when it has no verdict"

# The field is appended, so the existing readers keep working: the upgrade adapter takes
# upper= out of the line by pattern, not by field position.
assert_eq "$(grep -cF 's/^.*upper=\([^ ]*\) .*/\1/p' platform/lib/upgrade/platform.sh)" "1" \
  "ac-9 the upgrade adapter still parses upper= by pattern, so a trailing field is harmless"

finish
