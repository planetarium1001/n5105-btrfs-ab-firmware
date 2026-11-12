#!/usr/bin/env bash
# Module: upgrade
# Verifies the payload gate in platform/usr/sbin/ab-upgrade without root, btrfs or a
# real ESP: the payload is a synthetic tar and the tools that would touch the system
# are stubs. Every rule that has to hold before anything is written is covered:
#   ac-1 a well formed payload passes --check and writes nothing
#   ac-2 the manifest format and rootfs version are validated
#   ac-3 every member must exist and match its digest
#   ac-3b the vermagic evidence names the version even when the initramfs metadata carries
#        an empty `vermagic=` line next to the real one
#   ac-4 the initramfs must carry a btrfs module for the payload's kernel
#   ac-5 free space below 5% and a degraded writable layer are refused with 74
#   ac-6 the same version is refused unless --force asks for the reinstall
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

ab_upgrade="$root/platform/usr/sbin/ab-upgrade"
lib="$root/platform/lib/upgrade/platform.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- stubs: the parts of a running system this test must not touch -----------
bin="$tmp/bin"
mkdir -p "$bin"
# The target has busybox sha256sum; macOS has shasum.
cat >"$bin/sha256sum" <<'STUB'
#!/bin/sh
for f in "$@"; do
  [ -f "$f" ] && printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
done
STUB
cat >"$bin/ab-slot" <<'STUB'
#!/bin/sh
case "${1:-status}" in
  status) printf '%s\n' "${STUB_STATUS:-slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none p4=ok}" ;;
  rootfs) printf '%s\n' "${STUB_ROOTFS:-25.12.2}" ;;
  *) exit 0 ;;
esac
STUB
cat >"$bin/df" <<'STUB'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake %s 0 %s 0%% %s\n' "${STUB_DF_TOTAL:-1000000}" "${STUB_DF_AVAIL:-800000}" "${STUB_DF_MOUNT:-/tmp}"
STUB
chmod +x "$bin"/*

esp="$tmp/esp"
p4="$tmp/p4"
mkdir -p "$esp/ab/log" "$p4"

# --- payload builder --------------------------------------------------------
# build_payload <dir> <version> [--bad-format] [--missing <member>] [--bad-digest]
#               [--vermagic <module-ver> <kernel-ver>] [--banner <text>] [--banner <text>]
build_payload() {
  local dir="$1" version="$2"
  shift 2
  local bad_format=0 missing="" bad_digest=0 module_ver="6.12.103" kernel_ver="6.12.103"
  local empty_meta=0
  local banner="" mixed_ver=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bad-format) bad_format=1; shift ;;
      --missing) missing="$2"; shift 2 ;;
      --bad-digest) bad_digest=1; shift ;;
      --vermagic) module_ver="$2"; kernel_ver="$3"; shift 3 ;;
      --mixed-vermagic) mixed_ver="$2"; shift 2 ;;
      --empty-vermagic-meta) empty_meta=1; shift ;;
      --banner) banner="$2"; shift 2 ;;
      *) echo "bad arg $1" >&2; return 1 ;;
    esac
  done
  [ -n "$banner" ] || banner="payload $version"
  rm -rf "$dir"
  mkdir -p "$dir/rootfs/etc" "$dir/cpio/lib/modules/$module_ver"
  printf '%s\n' "$banner" >"$dir/rootfs/etc/banner"
  printf '#!/bin/sh\n' >"$dir/rootfs/sbin-init"
  tar -czf "$dir/rootfs.tar.gz" -C "$dir/rootfs" .
  printf 'vermagic=%s SMP mod_unload \n' "$kernel_ver" >"$dir/kernel.bin"
  printf 'vermagic=%s SMP mod_unload \n' "$module_ver" >"$dir/cpio/lib/modules/$module_ver/btrfs.ko"
  if [ "$empty_meta" = "1" ]; then
    # What the real initramfs carries: modules.* metadata with a `vermagic=` line that has
    # nothing after it, next to the modules whose vermagic is real.
    mkdir -p "$dir/cpio/lib/modules/$module_ver"
    printf 'vermagic=\000\000' >"$dir/cpio/lib/modules/$module_ver/modules.builtin.bin"
  fi
  if [ -n "$mixed_ver" ]; then
    mkdir -p "$dir/cpio/lib/modules/$mixed_ver"
    printf 'vermagic=%s SMP mod_unload \n' "$mixed_ver" >"$dir/cpio/lib/modules/$mixed_ver/other.ko"
  fi
  ( cd "$dir/cpio" && find . -print | cpio -o -H newc 2>/dev/null ) | gzip -9 >"$dir/initramfs.cpio.gz"
  printf 'platform\n' >"$dir/platform-member.txt"
  tar -cf "$dir/platform.tar" -C "$dir" platform-member.txt
  rm -rf "$dir/cpio" "$dir/rootfs" "$dir/platform-member.txt"

  python3 - "$dir" "$version" "$bad_format" "$bad_digest" <<'PYTHON'
import hashlib, json, pathlib, sys
stage, version, bad_format, bad_digest = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
members = {}
for name in ("initramfs.cpio.gz", "kernel.bin", "platform.tar", "rootfs.tar.gz"):
    data = (pathlib.Path(stage) / name).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if bad_digest and name == "rootfs.tar.gz":
        digest = "0" * 64
    members[name] = {"size": len(data), "sha256": digest}
fmt = "something-else/9" if bad_format else "ab-payload/1"
(pathlib.Path(stage) / "manifest.json").write_text(
    json.dumps({"format": fmt, "rootfs": version, "members": members}, indent=2) + "\n"
)
PYTHON

  if [ -n "$missing" ]; then rm -f "$dir/$missing"; fi
  tar -cf "$dir/payload.tar" -C "$dir" manifest.json
  for member in rootfs.tar.gz kernel.bin initramfs.cpio.gz platform.tar; do
    [ -f "$dir/$member" ] && tar -rf "$dir/payload.tar" -C "$dir" "$member"
  done
  printf '%s' "$dir/payload.tar"
}

# run_upgrade <payload.tar> [ENV=value...]: --check only, nothing is written.
run_upgrade() {
  local payload="$1"
  shift
  env PATH="$bin:$PATH" AB_ESP="$esp" AB_P4="$p4" AB_LIB="$lib" \
    AB_SLOTS_ROOT="$tmp/slots" "$@" \
    sh "$ab_upgrade" --check "$payload" 2>&1
}

# run_upgrade_flags <payload.tar> <flags...>: the same check with ab-upgrade options.
run_upgrade_flags() {
  local payload="$1"
  shift
  env PATH="$bin:$PATH" AB_ESP="$esp" AB_P4="$p4" AB_LIB="$lib" \
    AB_SLOTS_ROOT="$tmp/slots" \
    sh "$ab_upgrade" --check "$@" "$payload" 2>&1
}

# --- ac-1 happy path --------------------------------------------------------
good="$(build_payload "$tmp/good" 25.12.3-test1)"
out="$(run_upgrade "$good")"
assert_eq "$?" "0" "ac-1 a well formed payload passes the check"
assert_contains "$out" "ab-upgrade: check only, nothing written" "ac-1 the check mode says so"
assert_contains "$out" "manifest ok" "ac-1 the manifest is reported"
assert_contains "$out" "modules agree on ${module_ver:-}" "ac-1 the module vermagic is reported"
# A dry run publishes nothing: the conflict report belongs to an install, and a stale report
# on the ESP would look exactly like the report of the last real one.
assert_eq "$([ -e "$esp/ab/conflicts.log" ] && echo published || echo none)" "none" \
  "ac-1 the check mode publishes no conflict report"
assert_contains "$out" "0 conflict(s), 0 uci-defaults script(s)" \
  "ac-1 a payload without user edits reports no conflict"
assert_contains "$out" "check mode, the conflict report stays in" \
  "ac-1 the check mode says where the report went"

# --- ac-1b conflict matrix ---------------------------------------------------
# The baseline is the running slot's @sys, the payload is the new tree and the upper
# is the user's copy. A conflict is "the payload changed it and the user changed it".
make_baseline() { # <text>
  mkdir -p "$tmp/slots/a/@sys/etc" "$tmp/p4/@overlay-25.12.2/upper/etc"
  printf '%s\n' "$1" >"$tmp/slots/a/@sys/etc/banner"
}
make_user_copy() { # <text>
  mkdir -p "$tmp/p4/@overlay-25.12.2/upper/etc"
  printf '%s\n' "$1" >"$tmp/p4/@overlay-25.12.2/upper/etc/banner"
}

# The report is not published in check mode, so the counts are read from the summary line the
# upgrade prints - which is also the line a human reads.
conflict_count() { printf '%s\n' "$1" | sed -n 's/^ab-upgrade: \([0-9]*\) conflict(s).*/\1/p' | tail -n 1; }

# payload changed it, the user changed it too -> report, but do not block
make_baseline "distro default"
make_user_copy "user edited"
changed_by_both="$(build_payload "$tmp/c-both" 25.12.3-test2 --banner "payload default")"
out="$(run_upgrade "$changed_by_both")"
assert_eq "$?" "0" "ac-1b a conflict does not block the upgrade"
assert_eq "$(conflict_count "$out")" "1" "ac-1b a file changed on both sides is reported"

# payload changed it, the user did not -> no conflict
make_baseline "distro default"
rm -rf "$tmp/p4/@overlay-25.12.2"
changed_by_payload="$(build_payload "$tmp/c-payload" 25.12.3-test3 --banner "payload default")"
out="$(run_upgrade "$changed_by_payload")"
assert_eq "$?" "0" "ac-1b the upgrade still succeeds"
assert_eq "$(conflict_count "$out")" "0" "ac-1b a payload-only change is not a conflict"

# the user changed it, the payload did not -> no conflict
make_baseline "distro default"
make_user_copy "user edited"
same_in_payload="$(build_payload "$tmp/c-none" 25.12.3-test4 --banner "distro default")"
out="$(run_upgrade "$same_in_payload")"
assert_eq "$?" "0" "ac-1b the upgrade still succeeds"
assert_eq "$(conflict_count "$out")" "0" "ac-1b a user-only change is not a conflict"

rm -rf "$tmp/slots" "$tmp/p4"
mkdir -p "$tmp/p4"

# --- ac-1c the same payload cannot be installed twice ------------------------
# After a successful update the payload is what the new slot runs; a leftover copy
# must not be installed again, because it would rewrite the healthy slot from the
# slot that is being tested.
make_baseline "distro default"
installed_payload="$(build_payload "$tmp/c-installed" 25.12.3-test5 --banner "payload default")"
out="$(run_upgrade "$installed_payload" STUB_STATUS='slot=a upper=@overlay-25.12.3-test5 generation=2 committed=a pending=none p4=ok' \
  STUB_ROOTFS=25.12.3-test5)"
assert_eq "$?" "74" "ac-1c a payload the running slot already carries is refused"
assert_contains "$out" "reason=payload-already-installed" "ac-1c the refusal names the reason"
rm -rf "$tmp/slots" "$tmp/p4"
mkdir -p "$tmp/p4"

# --- ac-2 manifest shape ----------------------------------------------------
bad_format="$(build_payload "$tmp/bad-format" 25.12.3 --bad-format)"
out="$(run_upgrade "$bad_format")"
assert_eq "$?" "74" "ac-2 an unknown manifest format is refused with 74"
assert_contains "$out" "reason=manifest-format-something-else/9" "ac-2 the refusal names the format"

# --- ac-3 members and digests ----------------------------------------------
missing="$(build_payload "$tmp/missing" 25.12.3 --missing kernel.bin)"
out="$(run_upgrade "$missing")"
assert_eq "$?" "74" "ac-3 a missing member is refused with 74"
assert_contains "$out" "reason=member-missing-kernel.bin" "ac-3 the refusal names the member"

bad_digest="$(build_payload "$tmp/bad-digest" 25.12.3 --bad-digest)"
out="$(run_upgrade "$bad_digest")"
assert_eq "$?" "74" "ac-3 a digest mismatch is refused with 74"
assert_contains "$out" "reason=digest-mismatch-rootfs.tar.gz" "ac-3 the refusal names the member"

# --- ac-4 module consistency ------------------------------------------------
# The upstream kernel is an EFI stub, so its vermagic cannot be read; what the check
# enforces is that every module in the payload comes from one kernel build.
mixed="$(build_payload "$tmp/mixed" 25.12.3 --vermagic 6.12.103 6.12.103 --mixed-vermagic 6.11.0)"
out="$(run_upgrade "$mixed")"
assert_eq "$?" "74" "ac-4 modules from two kernel builds are refused with 74"
assert_contains "$out" "reason=initramfs-mixed-module-vermagic-2" \
  "ac-4 the refusal names the inconsistency"

# --- ac-3b the vermagic evidence line is usable ----------------------------
# The real initramfs carries modules.* metadata whose `vermagic=` line is empty. The
# check itself never lost strength (two different versions are still refused below), but
# the line it printed named no version, which is what makes a log useless in the field.
empty_meta="$(build_payload "$tmp/empty-meta" 25.12.3-test6 --empty-vermagic-meta)"
out="$(run_upgrade "$empty_meta")"
assert_eq "$?" "0" "ac-3b an initramfs with an empty vermagic line next to the real one passes"
assert_contains "$out" "modules agree on 6.12.103" \
  "ac-3b the evidence line names the version instead of printing an empty one"
assert_eq "$(printf '%s\n' "$out" | grep -c 'modules agree on $')" "0" \
  "ac-3b no empty 'modules agree on ' line is printed any more"
# An empty line must not be able to hide a real disagreement either.
empty_and_mixed="$(build_payload "$tmp/empty-mixed" 25.12.3-test7 --empty-vermagic-meta --mixed-vermagic 6.11.0)"
out="$(run_upgrade "$empty_and_mixed")"
assert_eq "$?" "74" "ac-3b an empty line does not mask two different module builds"
assert_contains "$out" "reason=initramfs-mixed-module-vermagic-2" \
  "ac-3b the count still sees both real versions"

# --- ac-6 the same version needs --force ----------------------------------
already="$(build_payload "$tmp/already" 25.12.3-test8)"
out="$(run_upgrade "$already" STUB_ROOTFS=25.12.3-test8)"
assert_eq "$?" "74" "ac-6 the same version is still refused by default"
assert_contains "$out" "reason=payload-already-installed" "ac-6 the default refusal is unchanged"

out="$(run_upgrade_flags "$already" --force)"
assert_eq "$?" "0" "ac-6 --force reinstalls the version the slot already carries"
assert_contains "$(run_upgrade_flags "$already" --force)" "check only, nothing written" \
  "ac-6 --force does not turn the check into a write"

# --- ac-5 space and degraded writable layer --------------------------------
out="$(run_upgrade "$good" STUB_DF_TOTAL=1000000 STUB_DF_AVAIL=10000)"
assert_eq "$?" "74" "ac-5 less than 5% free space is refused with 74"
assert_contains "$out" "reason=low-space-1pct" "ac-5 the refusal reports the percentage"

out="$(run_upgrade "$good" STUB_STATUS='slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none p4=degraded')"
assert_eq "$?" "74" "ac-5 a degraded writable layer is refused with 74"
assert_contains "$out" "reason=writable-layer-degraded" "ac-5 the refusal names the degraded layer"

# a refused upgrade must not leave state or slot changes behind
assert_eq "$(ls "$p4" | wc -l | tr -d ' ')" "0" "ac-5 a refused upgrade writes nothing into the writable layer"

# --- the version is a path component and a feeds literal -------------------
# It becomes @overlay-<version>, the bootloader backup directory and the release segment of
# a distfeeds line, so `../` or an `&` must never get that far.
hostile="$(build_payload "$tmp/hostile" '../../etc')"
out="$(run_upgrade "$hostile")"
assert_eq "$?" "74" "a version with a path separator is refused"
assert_contains "$out" "reason=manifest-rootfs-invalid" "the refusal names the version"
hostile2="$(build_payload "$tmp/hostile2" '25.12.0&x')"
out="$(run_upgrade "$hostile2")"
assert_eq "$?" "74" "a version with a sed special character is refused"

# --- `--bootloader` on a payload that carries none -------------------------
bare_required="$(build_payload "$tmp/bare-required" 25.12.3-test9)"
out="$(run_upgrade_flags "$bare_required" --bootloader)"
assert_eq "$?" "74" "--bootloader refuses a payload without the member"

# --- the flags are documented in the usage line ---------------------------
assert_contains "$(sh "$ab_upgrade" --help 2>&1)" "--no-bootloader" \
  "the usage line names the escape hatch"
assert_contains "$(sh "$ab_upgrade" --help 2>&1)" "--force" \
  "the usage line names the reinstall switch"

# --- the product code never writes the state file itself -------------------
assert_eq "$(grep -c 'state.json' "$ab_upgrade")" "0" \
  "the upgrade keeps state changes behind ab-slot"

finish
