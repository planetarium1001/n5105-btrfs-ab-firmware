#!/usr/bin/env bash
# Module: ab
# ac-7: `ab-restore` puts a package back where it came from and nowhere else: @data
#       from `data/`, @docker from `docker/` (a package ab-backup --with-docker produced
#       has to be a package ab-restore can restore), the slot's copy-up config from
#       `etc/config/`, and the bookkeeping from `meta/` into `@data/.ab-restore-meta/` -
#       never onto the ESP. A non-empty
#       @data is refused unless `--force` says the overwrite was meant, `--data-only`
#       touches nothing but @data, and a package whose digest does not match, or whose
#       members would escape the target, is refused before anything is written.
#
# The package is built by ab-backup here, so the two tools are tested against each
# other and not against a fixture that could drift from what ab-backup really writes.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

ab_backup="$root/platform/usr/sbin/ab-backup"
ab_restore="$root/platform/usr/sbin/ab-restore"
ab_slot="$root/platform/usr/sbin/ab-slot"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- a machine ------------------------------------------------------------
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
printf '{"kind": "boot"}\n' >"$esp/ab/image.json"
printf '{"partuuid": {}}\n' >"$esp/ab/device.json"

p4="$tmp/p4"
upper="$p4/@overlay-25.12.3/upper"
mkdir -p "$upper/etc/config" "$p4/.ab"
printf 'config network\n' >"$upper/etc/config/network"
printf 'result=already-full last_lba=250069646\n' >"$p4/.ab/grow"

mkdir -p "$tmp/mnt"
data="$tmp/mnt/data"
docker="$tmp/mnt/docker"
mkdir -p "$data/home/u"
printf 'a\n' >"$data/home/u/a.txt"
mkdir -p "$docker"

cmdline="$tmp/cmdline"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

btrfs_none="/nonexistent/btrfs"

env_common() { # <data dir> <subcommand> <args...>
  _data="$1"
  _sub="$2"
  shift 2
  AB_ESP="$esp" AB_P4="$p4" AB_DATA="$_data" AB_DOCKER="$docker" AB_CMD="$cmdline" \
    AB_BTRFS="$btrfs_none" AB_SLOT_BIN="$ab_slot" sh "$_sub" "$@"
}

# One package, built by ab-backup: the archive and the digest the restore checks.
out="$tmp/out"
mkdir -p "$out"
env_common "$data" "$ab_backup" --out "$out" >/dev/null 2>&1
archive="$(ls "$out"/data-*.tar.gz 2>/dev/null | head -n 1)"
assert_file_exists "$archive" "ac-7 ab-backup produced the package this test restores"

# --- the round trip --------------------------------------------------------
target="$tmp/target"
target_data="$target/data"
mkdir -p "$target_data"

stdout=$(env_common "$target_data" "$ab_restore" "$archive" 2>"$tmp/err-restore")
rc=$?
assert_eq "$rc" "0" "ac-7 a restore into an empty @data succeeds"
assert_eq "$(cat "$target_data/home/u/a.txt" 2>/dev/null)" "a" \
  "ac-7 @data comes back from data/"
assert_eq "$(cat "$upper/etc/config/network" 2>/dev/null)" "config network" \
  "ac-7 the slot's etc/config comes back from etc/config/"
assert_file_exists "$target_data/.ab-restore-meta/state.json" \
  "ac-7 meta/ lands in @data/.ab-restore-meta, not on the ESP"
assert_eq "$(find "$esp" -name 'state.json' -newer "$target_data" 2>/dev/null)" "" \
  "ac-7 the ESP is never written by a restore"
assert_contains "$stdout" "restored=data" "ac-7 the restore reports what it wrote"
assert_contains "$stdout" "restored=etc/config" "ac-7 the config restore is reported"
# The package is unpacked into @data/.ab-restore-stage and moved in from there, because
# this tar has no --strip-components: the staging directory must not survive the run, and
# must not be mistaken for data that came out of the package.
assert_eq "$([ -e "$target_data/.ab-restore-stage" ] && echo present || echo absent)" "absent" \
  "ac-7 the staging directory inside @data is removed"
assert_eq "$(ls -A "$target_data" | sort | tr '\n' ' ')" ".ab-restore-meta home " \
  "ac-7 nothing but the package's own entries and its meta are left in @data"
assert_contains "$(cat "$target_data/.ab-restore-meta/manifest.txt" 2>/dev/null)" \
  "archive=$(basename "$archive")" \
  "ac-7 meta/ carries the manifest of the package that was restored"

# --- a non-empty @data is refused -----------------------------------------
printf 'local change\n' >"$target_data/local.txt"
env_common "$target_data" "$ab_restore" "$archive" >/dev/null 2>"$tmp/err-busy"
rc=$?
assert_eq "$rc" "3" "ac-7 a non-empty @data is refused"
assert_contains "$(cat "$tmp/err-busy")" "refuse:" "ac-7 the refusal carries the refuse: prefix"
assert_eq "$(cat "$target_data/local.txt" 2>/dev/null)" "local change" \
  "ac-7 a refused restore changes nothing"

env_common "$target_data" "$ab_restore" "$archive" --force >/dev/null 2>&1
rc=$?
assert_eq "$rc" "0" "ac-7 --force restores over a non-empty @data"
assert_eq "$(cat "$target_data/home/u/a.txt" 2>/dev/null)" "a" \
  "ac-7 --force actually restored the package"

# --- --data-only -----------------------------------------------------------
only="$tmp/only"
only_data="$only/data"
mkdir -p "$only_data"
printf 'old config\n' >"$upper/etc/config/network"
env_common "$only_data" "$ab_restore" "$archive" --data-only >/dev/null 2>&1
rc=$?
assert_eq "$rc" "0" "ac-7 --data-only succeeds"
assert_eq "$(cat "$only_data/home/u/a.txt" 2>/dev/null)" "a" \
  "ac-7 --data-only still restores @data"
assert_eq "$(cat "$upper/etc/config/network" 2>/dev/null)" "old config" \
  "ac-7 --data-only leaves etc/config alone"
assert_eq "$(ls -A "$only_data/.ab-restore-meta" 2>/dev/null)" "" \
  "ac-7 --data-only does not unpack meta/"
assert_eq "$([ -e "$only_data/.ab-restore-stage" ] && echo present || echo absent)" "absent" \
  "ac-7 --data-only removes the staging directory it unpacked into"

# --- a target without room -------------------------------------------------
# The package is unpacked onto @data before it is moved into it, so a target that cannot
# hold both is refused before the first byte is written, not halfway through.
tight="$tmp/tight"
tight_data="$tight/data"
mkdir -p "$tight_data"
AB_AVAIL_KB=1 env_common "$tight_data" "$ab_restore" "$archive" >/dev/null 2>"$tmp/err-room"
rc=$?
assert_eq "$rc" "3" "ac-7 a target without room is refused"
assert_contains "$(cat "$tmp/err-room")" "refuse:" "ac-7 the space refusal says refuse:"
assert_eq "$(ls -A "$tight_data")" "" "ac-7 a refused restore writes nothing at all"
assert_eq "$([ -e "$tight_data/.ab-restore-stage" ] && echo present || echo absent)" "absent" \
  "ac-7 no staging directory is created for a refused restore"

# --- a package that does not match its digest ------------------------------
corrupt="$tmp/corrupt.tar.gz"
cp "$archive" "$corrupt"
printf 'x' >>"$corrupt"
printf 'deadbeef  %s\n' "$corrupt" >"${corrupt}.sha256"
bad="$tmp/bad"
mkdir -p "$bad/data"
env_common "$bad/data" "$ab_restore" "$corrupt" >/dev/null 2>"$tmp/err-digest"
rc=$?
assert_eq "$rc" "3" "ac-7 a package that does not match its .sha256 is refused"
assert_contains "$(cat "$tmp/err-digest")" "refuse:" "ac-7 the digest refusal says refuse:"
assert_eq "$(ls -A "$bad/data")" "" "ac-7 a refused package is not half extracted"

# --- a package that would write outside the targets -----------------------
escape="$tmp/escape"
mkdir -p "$escape"
printf 'payload\n' >"$escape/payload"
tar -czf "$tmp/evil.tar.gz" -C "$escape" payload
payload_members=$(tar -tzf "$tmp/evil.tar.gz" | head -n 1)
cat >"$escape/tar-stub" <<STUB
#!/bin/sh
# A tar that lies about its members: no data/, no etc/config/, no meta/.
printf '%s\n' "${payload_members}"
printf '%s\n' "../escape"
STUB
chmod +x "$escape/tar-stub"
evil="$tmp/evil-target"
mkdir -p "$evil/data"
PATH="$escape:$PATH" AB_TAR="$escape/tar-stub" \
  env_common "$evil/data" "$ab_restore" "$tmp/evil.tar.gz" >/dev/null 2>"$tmp/err-escape"
rc=$?
assert_eq "$rc" "3" "ac-7 a package whose members leave the targets is refused"
assert_contains "$(cat "$tmp/err-escape")" "refuse:" "ac-7 the escape refusal says refuse:"
assert_eq "$(ls -A "$evil/data")" "" "ac-7 nothing is written from a package that was refused"

# --- a missing package ----------------------------------------------------
env_common "$evil/data" "$ab_restore" "$tmp/does-not-exist.tar.gz" >/dev/null 2>"$tmp/err-missing"
rc=$?
assert_eq "$rc" "3" "ac-7 a package that is not there is refused"

# --- a package with docker/ ------------------------------------------------
# ab-backup --with-docker writes docker/ (ac-6). A package the tool produces has to be a
# package the tool can restore, so docker/ goes back to @docker - and only there.
env_docker() { # <data dir> <docker dir> <subcommand> <args...>
  _d="$1"
  _dk="$2"
  _sub="$3"
  shift 3
  AB_ESP="$esp" AB_P4="$p4" AB_DATA="$_d" AB_DOCKER="$_dk" AB_CMD="$cmdline" \
    AB_BTRFS="$btrfs_none" AB_SLOT_BIN="$ab_slot" sh "$_sub" "$@"
}

docker_src="$tmp/dock-src"
mkdir -p "$docker_src/img"
printf 'image\n' >"$docker_src/img/x"
out_docker="$tmp/out-docker"
mkdir -p "$out_docker"
env_docker "$data" "$docker_src" "$ab_backup" --out "$out_docker" --with-docker >/dev/null 2>&1
archive_docker="$(ls "$out_docker"/data-*.tar.gz 2>/dev/null | head -n 1)"
assert_file_exists "$archive_docker" "ac-7 ab-backup --with-docker produced the package"
assert_contains "$(tar -tzf "$archive_docker" 2>/dev/null)" "docker/img/x" \
  "ac-7 the package really carries docker/"

dock_data="$tmp/dock-data"
dock_home="$tmp/dock-home"
mkdir -p "$dock_data" "$dock_home"
stdout=$(env_docker "$dock_data" "$dock_home" "$ab_restore" "$archive_docker" 2>"$tmp/err-docker")
rc=$?
assert_eq "$rc" "0" "ac-7 a package with docker/ is restored"
assert_eq "$(cat "$dock_home/img/x" 2>/dev/null)" "image" "ac-7 docker/ comes back into @docker"
assert_contains "$stdout" "restored=docker path=$dock_home entries=1" \
  "ac-7 the docker restore names @docker and what went in"
assert_eq "$([ -e "$dock_home/.ab-restore-stage" ] && echo present || echo absent)" "absent" \
  "ac-7 the staging directory inside @docker is removed"
assert_eq "$(ls -A "$dock_home" | sort | tr '\n' ' ')" "img " \
  "ac-7 nothing but the package's docker entries is left in @docker"

# --data-only restores data/ and nothing else: docker/ is not touched, and says so.
only_docker="$tmp/only-docker"
mkdir -p "$only_docker"
printf 'local image\n' >"$only_docker/local.tar"
only_data2="$tmp/only-data2"
mkdir -p "$only_data2"
stdout=$(env_docker "$only_data2" "$only_docker" "$ab_restore" "$archive_docker" --data-only 2>/dev/null)
rc=$?
assert_eq "$rc" "0" "ac-7 --data-only succeeds on a package with docker/"
assert_eq "$(cat "$only_data2/home/u/a.txt" 2>/dev/null)" "a" \
  "ac-7 --data-only still restores @data from that package"
assert_contains "$stdout" "restored=docker skipped" \
  "ac-7 --data-only says that docker/ was skipped"
assert_eq "$(ls -A "$only_docker" | sort | tr '\n' ' ')" "local.tar " \
  "ac-7 --data-only leaves @docker exactly as it was"

# A docker/ category with nowhere to go is refused, not dropped.
missing_docker="$tmp/missing-docker"
lock_data="$tmp/lock-data"
mkdir -p "$lock_data"
env_docker "$lock_data" "$missing_docker" "$ab_restore" "$archive_docker" >/dev/null 2>"$tmp/err-nodocker"
rc=$?
assert_eq "$rc" "3" "ac-7 docker/ with no @docker mount is refused"
assert_contains "$(cat "$tmp/err-nodocker")" "refuse:" "ac-7 the missing @docker refusal says refuse:"
assert_contains "$(cat "$tmp/err-nodocker")" "@docker" "ac-7 the refusal names @docker"
assert_eq "$(ls -A "$lock_data")" "" "ac-7 a refused restore writes nothing at all"
assert_eq "$([ -e "$missing_docker" ] && echo present || echo absent)" "absent" \
  "ac-7 no @docker staging directory is created for a refused restore"

finish
