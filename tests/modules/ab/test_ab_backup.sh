#!/usr/bin/env bash
# Module: ab
# ac-6: `ab-backup` exports one fixed list and nothing else: the whole of @data, the
#       current slot's overlay upper `etc/config`, and `meta/` (the ESP bookkeeping
#       plus the first-boot growth record). `--with-docker` appends @docker, `--dry-run`
#       prints the same list and writes no file at all, and every archive is written next
#       to its own `.sha256`.
#
# The ESP is a temporary directory, the writable partition is a temporary directory and
# btrfs is a stub, because every rule that matters here is about what goes into the
# archive and what is left untouched on the machine.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

ab_backup="$root/platform/usr/sbin/ab-backup"
ab_slot="$root/platform/usr/sbin/ab-slot"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- a machine: an ESP with the bookkeeping files ---------------------------
esp="$tmp/esp"
mkdir -p "$esp/ab/log"
cat >"$esp/ab/state.json" <<'JSON'
{
  "generation": 2,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
printf '{"kind": "boot", "initramfs": "initramfs-boot"}\n' >"$esp/ab/image.json"
printf '{"partuuid": {"esp": "aaaa"}}\n' >"$esp/ab/device.json"

# --- the writable partition: one layer with copy-up config, the grow record -
p4="$tmp/p4"
upper="$p4/@overlay-25.12.3/upper"
mkdir -p "$upper/etc/config" "$p4/.ab"
printf 'config network\n' >"$upper/etc/config/network"
printf 'config fstab\n' >"$upper/etc/config/fstab"
printf 'result=already-full last_lba=250069646\n' >"$p4/.ab/grow"
printf 'grow log line\n' >"$p4/.ab/grow.log"

# --- the data mounts. The prefix in the archive is the mount's basename, so the
# fixtures carry the names the running system has: /data and /opt/docker.
mkdir -p "$tmp/mnt"
data="$tmp/mnt/data"
docker="$tmp/mnt/docker"
mkdir -p "$data/etc" "$data/home/u"
printf 'hosts\n' >"$data/etc/hosts.txt"
printf 'a\n' >"$data/home/u/a.txt"
mkdir -p "$docker/img"
printf 'image\n' >"$docker/img/x"

cmdline="$tmp/cmdline"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

# btrfs stub: the consistent path snapshots @data read-only, so the archive is taken
# from a copy that does not move while it is being read.
btrfs_ok="$tmp/btrfs-ok"
cat >"$btrfs_ok" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "subvolume snapshot")
    # subvolume snapshot -r <src> <dst>
    cp -a "$4" "$5" || exit 1
    exit 0
    ;;
  "subvolume delete")
    rm -rf "$3" || exit 1
    exit 0
    ;;
  "subvolume list") exit 0 ;;
esac
exit 0
STUB
chmod +x "$btrfs_ok"

run_backup() { # <btrfs> <args...>
  _btrfs="$1"
  shift
  AB_ESP="$esp" AB_P4="$p4" AB_DATA="$data" AB_DOCKER="$docker" AB_CMD="$cmdline" \
    AB_BTRFS="$_btrfs" AB_SLOT_BIN="$ab_slot" sh "$ab_backup" "$@"
}

# --- the default list ------------------------------------------------------
out="$tmp/out"
mkdir -p "$out"
marker="$tmp/marker"
touch "$marker"
stdout=$(run_backup "$btrfs_ok" --out "$out" 2>"$tmp/err-default")
rc=$?
err=$(cat "$tmp/err-default")

assert_eq "$rc" "0" "ac-6 the default export succeeds"
archive=$(printf '%s\n' "$stdout" | sed -n 's/^backup=//p')
assert_file_exists "$archive" "ac-6 the archive is written"
assert_contains "$archive" "data-" "ac-6 the archive name starts with data-"
listing=$(tar -tzf "$archive" 2>/dev/null)
assert_contains "$listing" "data/etc/hosts.txt" "ac-6 @data is exported in full"
assert_contains "$listing" "data/home/u/a.txt" "ac-6 @data keeps its tree"
assert_contains "$listing" "etc/config/network" "ac-6 the upper's etc/config is exported"
assert_contains "$listing" "etc/config/fstab" "ac-6 every file of the upper's etc/config is exported"
assert_contains "$listing" "meta/state.json" "ac-6 the slot state is exported as meta/"
assert_contains "$listing" "meta/device.json" "ac-6 the device identity is exported as meta/"
assert_contains "$listing" "meta/image.json" "ac-6 the image record is exported as meta/"
assert_contains "$listing" "meta/grow" "ac-6 the first-boot growth record is exported as meta/"
assert_contains "$listing" "meta/grow.log" "ac-6 the growth log is exported as meta/"
assert_contains "$listing" "meta/manifest.txt" "ac-6 the manifest is exported as meta/"
assert_eq "$(printf '%s\n' "$listing" | cut -d/ -f1 | sort -u | tr '\n' ' ')" \
  "data etc meta " "ac-6 no category beyond data, etc/config and meta is exported by default"

# The archive is assembled in a staging root and tarred from there with one -C, so the
# staging root must not appear in the package, and no member may be an absolute path.
assert_eq "$(printf '%s\n' "$listing" | awk '/^@backup/ || /^\.ab-backup/ { n++ } END { print n + 0 }')" \
  "0" "ac-6 the archive carries no staging root of its own"
assert_eq "$(printf '%s\n' "$listing" | awk '/\.ab-backup/ { n++ } END { print n + 0 }')" \
  "0" "ac-6 no member was taken from a staging root inside the output directory"
assert_eq "$(printf '%s\n' "$listing" | awk '/^\// { n++ } END { print n + 0 }')" \
  "0" "ac-6 every member is named relative to the archive root"

assert_file_exists "${archive}.sha256" "ac-6 the archive carries a .sha256"
assert_eq "$(cut -d' ' -f1 "${archive}.sha256")" "$(sha256_of "$archive")" \
  "ac-6 the .sha256 is the digest of the archive"
assert_contains "$stdout" "consistency=snapshot" "ac-6 a read-only snapshot is used when btrfs can"
assert_eq "$(find "$p4" -maxdepth 1 -name '@backup-*' 2>/dev/null)" "" \
  "ac-6 the temporary snapshot is removed afterwards"
assert_eq "$(find "$esp" -newer "$marker" 2>/dev/null)" "" \
  "ac-6 the ESP is never written"
assert_contains "$stdout" "entries data=2 etc=2 docker=0 meta=7" \
  "ac-6 the manifest counts what went in, and no docker category by default"

# --- --with-docker ---------------------------------------------------------
out_docker="$tmp/out-docker"
mkdir -p "$out_docker"
stdout=$(run_backup "$btrfs_ok" --out "$out_docker" --with-docker 2>/dev/null)
archive_docker=$(printf '%s\n' "$stdout" | sed -n 's/^backup=//p')
listing=$(tar -tzf "$archive_docker" 2>/dev/null)
assert_contains "$listing" "docker/img/x" "ac-6 --with-docker appends @docker"
assert_eq "$(printf '%s\n' "$listing" | cut -d/ -f1 | sort -u | tr '\n' ' ')" \
  "data docker etc meta " "ac-6 --with-docker exports exactly four categories"
assert_contains "$stdout" "entries data=2 etc=2 docker=1 meta=7" \
  "ac-6 --with-docker counts the docker entries"

# --- --dry-run writes nothing ---------------------------------------------
out_dry="$tmp/out-dry"
stdout=$(AB_AVAIL_KB=99999999 run_backup "$btrfs_ok" --out "$out_dry" --dry-run 2>"$tmp/err-dry")
rc=$?
assert_eq "$rc" "0" "ac-6 --dry-run succeeds"
assert_eq "$([ -e "$out_dry" ] && echo present || echo absent)" "absent" \
  "ac-6 --dry-run creates no output directory"
assert_contains "$stdout" "plan=data" "ac-6 --dry-run prints the @data entry"
assert_contains "$stdout" "plan=etc/config" "ac-6 --dry-run prints the etc/config entry"
assert_contains "$stdout" "would-write=" "ac-6 --dry-run names the archive it would write"
assert_eq "$(find "$p4" "$tmp" -maxdepth 2 \( -name '@backup-*' -o -name '.ab-backup.*' \) 2>/dev/null)" "" \
  "ac-6 --dry-run creates no staging root"

# --- --plain ---------------------------------------------------------------
out_plain="$tmp/out-plain"
mkdir -p "$out_plain"
stdout=$(run_backup "$btrfs_ok" --out "$out_plain" --plain 2>/dev/null)
archive_plain=$(printf '%s\n' "$stdout" | sed -n 's/^backup=//p')
assert_matches "$archive_plain" '\.tar$' "ac-6 --plain writes an uncompressed .tar"
assert_contains "$(tar -tf "$archive_plain" 2>/dev/null)" "data/etc/hosts.txt" \
  "ac-6 the plain archive carries the same list"

# --- a machine without btrfs: direct tar, and it says so -------------------
out_live="$tmp/out-live"
mkdir -p "$out_live"
stdout=$(run_backup "/nonexistent/btrfs" --out "$out_live" 2>"$tmp/err-live")
rc=$?
assert_eq "$rc" "0" "ac-6 a missing btrfs tool does not fail the backup"
assert_contains "$stdout" "consistency=live" "ac-6 the export falls back to the live tree"
assert_contains "$(cat "$tmp/err-live")" "warn:" \
  "ac-6 the fallback is announced, not silent: it is not a point-in-time copy"
assert_eq "$(find "$p4" -maxdepth 1 -name '@backup-*' 2>/dev/null)" "" \
  "ac-6 the copied staging root is removed afterwards too"

# --- a tar that fails: no half package, and nothing left in the staging root ------
out_broken="$tmp/out-broken"
mkdir -p "$out_broken"
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
printf '#!/bin/sh\nexit 1\n' >"$fakebin/tar"
chmod +x "$fakebin/tar"
PATH="$fakebin:$PATH" AB_ESP="$esp" AB_P4="$p4" AB_DATA="$data" AB_DOCKER="$docker" \
  AB_CMD="$cmdline" AB_BTRFS="$btrfs_ok" AB_SLOT_BIN="$ab_slot" \
  sh "$ab_backup" --out "$out_broken" >/dev/null 2>"$tmp/err-tar"
rc=$?
assert_eq "$rc" "1" "ac-6 a failing tar fails the export"
assert_eq "$(ls -A "$out_broken")" "" "ac-6 a failing tar leaves no half written package"
assert_eq "$(find "$p4" -maxdepth 1 -name '@backup-*' 2>/dev/null)" "" \
  "ac-6 a failing tar still takes its staging root back"

# --- refusals: no half written package ------------------------------------
out_full="$tmp/out-full"
mkdir -p "$out_full"
AB_AVAIL_KB=1 run_backup "$btrfs_ok" --out "$out_full" >/dev/null 2>"$tmp/err-space"
rc=$?
assert_eq "$rc" "3" "ac-6 an archive that cannot fit is refused"
assert_contains "$(cat "$tmp/err-space")" "refuse:" "ac-6 the refusal carries the refuse: prefix"
assert_eq "$(ls -A "$out_full")" "" "ac-6 a refused export leaves no partial package"

AB_ESP="$esp" AB_P4="$p4" AB_DATA="$tmp/absent/data" AB_DOCKER="$docker" AB_CMD="$cmdline" \
  AB_BTRFS="$btrfs_ok" AB_SLOT_BIN="$ab_slot" \
  sh "$ab_backup" --out "$out_full" >/dev/null 2>"$tmp/err-nodata"
rc=$?
assert_eq "$rc" "3" "ac-6 a missing @data mount is refused"
assert_contains "$(cat "$tmp/err-nodata")" "refuse:" "ac-6 the missing mount names itself as a refusal"

finish
