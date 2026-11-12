#!/usr/bin/env bash
# Module: ci
# Guards scripts/ci/release-preflight.sh (ac-17): a release is only published when the
# image's own record, the payload manifest and the tag agree on one upstream version, the
# platform version still matches the shipped VERSION file, and the payload carries a
# bootloader (boot.tar with grub.cfg and a GRUB core) whose digests are the digests of the
# bytes in the tar.
#
# The fixture is built here, in a temporary directory: a real payload tar whose members
# carry digests computed from the bytes on disk, and a real boot.tar holding the ESP tree
# (EFI/BOOT/BOOTX64.EFI, boot/grub/grub.cfg, a GRUB module). Nothing is hand-written, so a
# digest cannot drift from the bytes it claims to describe, and every refusal below is
# produced by changing exactly one thing about an otherwise passing release.
#
# Offline by construction: the script only reads paths, so no mount, no gunzip and no
# network is involved.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

preflight="$root/scripts/ci/release-preflight.sh"
grub_cfg_fixture="$here/fixtures/release-preflight/grub.cfg"

upstream=25.13.0
platform=9.9.9

# --------------------------------------------------------------------------- #
# Fixture
# --------------------------------------------------------------------------- #

# digest_of <file>: the sha256 the manifest is expected to record for those bytes.
digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# pack_boot_tar <dir>: the bootloader member, built from the ESP tree in <dir>/tree, the
# layout esp-prepare.sh takes from the upstream combined-EFI image.
pack_boot_tar() {
  tar -cf "$1/stage/boot.tar" -C "$1/tree" .
}

# repack <dir> [<rootfs-version>]: recompute every digest from the bytes in <dir>/stage and
# rebuild the payload tar. Each scenario starts from a coherent release and changes one
# thing; re-packing keeps the digests honest, so the change under test is the only reason
# the preflight can have to refuse.
repack() {
  local dir="$1" rootfs="${2:-}"
  python3 - "$dir/stage" "$rootfs" <<'PYTHON'
import hashlib
import json
import pathlib
import sys

stage = pathlib.Path(sys.argv[1])
rootfs = sys.argv[2]
manifest = stage / "manifest.json"
old = json.loads(manifest.read_text(encoding="utf-8")) if manifest.exists() else {}
if not rootfs:
    rootfs = old.get("rootfs", "")
members = {}
for name in ("boot.tar", "initramfs.cpio.gz", "kernel.bin", "platform.tar", "rootfs.tar.gz"):
    path = stage / name
    if not path.is_file():
        continue
    data = path.read_bytes()
    members[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
doc = {"format": old.get("format", "ab-payload/1"), "rootfs": rootfs, "members": members}
manifest.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYTHON
  tar -cf "$dir/payload.tar" -C "$dir/stage" \
    manifest.json boot.tar rootfs.tar.gz kernel.bin initramfs.cpio.gz platform.tar
}

# make_release <dir> <upstream-version> <platform-version>: one complete, self-consistent
# release input tree: the mounted partition 1 (<dir>/image/ab/image.json), the shipped
# VERSION file, and a payload tar with its five members and a manifest over them.
make_release() {
  local dir="$1" upstream="$2" platform="$3"
  mkdir -p "$dir/image/ab" "$dir/stage" "$dir/tree/EFI/BOOT" \
    "$dir/tree/boot/grub/x86_64-efi" "$dir/rootfs/etc" "$dir/platform/etc"

  cp "$grub_cfg_fixture" "$dir/tree/boot/grub/grub.cfg"
  printf 'stub EFI loader: the preflight reads names, not bytes\n' \
    >"$dir/tree/EFI/BOOT/BOOTX64.EFI"
  printf 'stub GRUB module\n' >"$dir/tree/boot/grub/x86_64-efi/normal.mod"

  printf 'banner for %s\n' "$upstream" >"$dir/rootfs/etc/banner"
  tar -czf "$dir/stage/rootfs.tar.gz" -C "$dir/rootfs" .
  printf 'kernel for %s\n' "$upstream" >"$dir/stage/kernel.bin"
  printf 'initramfs for %s\n' "$upstream" >"$dir/stage/initramfs.cpio.gz"
  printf 'PLATFORM_VERSION=%s\n' "$platform" >"$dir/platform/etc/platform-release"
  tar -cf "$dir/stage/platform.tar" -C "$dir/platform" .
  pack_boot_tar "$dir"

  # The record image-identity.sh writes onto the ESP, in the same shape.
  cat >"$dir/image/ab/image.json" <<JSON
{
  "kind": "boot",
  "init_script": "S3 boot init",
  "platform_version": "${platform}",
  "upstream_version": "${upstream}",
  "created_at": "2026-11-12T00:00:00Z"
}
JSON
  printf '%s\n' "$platform" >"$dir/VERSION"

  repack "$dir" "$upstream"
}

# json_edit <file> set <key> <value>
# json_edit <file> member-digest <member> <sha256>
# json_edit <file> drop-member <member>
json_edit() {
  python3 - "$@" <<'PYTHON'
import json
import sys

path, mode = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    doc = json.load(handle)
if mode == "set":
    doc[sys.argv[3]] = sys.argv[4]
elif mode == "member-digest":
    doc["members"][sys.argv[3]]["sha256"] = sys.argv[4]
elif mode == "drop-member":
    del doc["members"][sys.argv[3]]
else:
    raise SystemExit("unknown mode: %s" % mode)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")
PYTHON
}

# run_preflight <dir> [args...]: run the script against one fixture and keep the exit code
# and both streams, so every assertion below reads the same three values.
run_preflight() {
  local dir="$1"
  shift
  rm -f "$tmp/out.env"
  env CI_TMP_ROOT="$tmp/ci" CI_OUTPUT_ENV="$tmp/out.env" \
    bash "$preflight" \
    --image-dir "$dir/image" \
    --payload-manifest "$dir/stage/manifest.json" \
    --payload-tar "$dir/payload.tar" \
    "$@" >"$tmp/stdout" 2>"$tmp/stderr"
  code=$?
  out=$(cat "$tmp/stdout")
  err=$(cat "$tmp/stderr")
}

# output_of <key>: one published output of the last run.
output_of() {
  sed -n "s/^$1=//p" "$tmp/out.env" 2>/dev/null | tail -n 1
}

assert_file_exists "$preflight" "ac-17 the preflight script exists"

# --------------------------------------------------------------------------- #
# ac-17: a coherent release passes, and says what it proved
# --------------------------------------------------------------------------- #

make_release "$tmp/ok" "$upstream" "$platform"
run_preflight "$tmp/ok" --tag "$upstream" --version-file "$tmp/ok/VERSION"

assert_eq "$code" "0" "ac-17 a coherent image, payload and tag pass the preflight"
assert_contains "$out" "1/7 image kind is boot" "ac-17 the passing run reports the image check first"
assert_contains "$out" "7/7" "ac-17 the passing run reaches the version check"
assert_contains "$out" "preflight passed" "ac-17 the passing run says so"
assert_file_exists "$tmp/out.env" "ac-17 a passing preflight publishes its outputs"
assert_eq "$(output_of tag)" "$upstream" "ac-17 the preflight publishes the tag it checked"
assert_eq "$(output_of upstream_version)" "$upstream" "ac-17 the preflight publishes the upstream version"
assert_eq "$(output_of platform_version)" "$platform" \
  "ac-17 the platform version comes from the version file when no flag is given"
assert_eq "$(output_of bootloader_member)" "boot.tar" \
  "ac-17 the preflight names the bootloader member it proved"
assert_eq "$(output_of payload_manifest_sha256)" "$(digest_of "$tmp/ok/stage/manifest.json")" \
  "ac-17 the preflight publishes the digest of the manifest it read"
assert_eq "$err" "" "ac-17 a passing preflight writes nothing to stderr"

# The explicit flag is accepted too, and still has to agree with the shipped file.
run_preflight "$tmp/ok" --tag "$upstream" --platform-version "$platform" \
  --version-file "$tmp/ok/VERSION"
assert_eq "$code" "0" "ac-17 an explicit --platform-version passes when VERSION agrees"
assert_eq "$(output_of platform_version)" "$platform" \
  "ac-17 an explicit --platform-version wins over the file it is compared with"

# --------------------------------------------------------------------------- #
# ac-17: the image's own record decides whether it may be published
# --------------------------------------------------------------------------- #

cp -a "$tmp/ok" "$tmp/probe-image"
json_edit "$tmp/probe-image/image/ab/image.json" set kind probe
run_preflight "$tmp/probe-image" --tag "$upstream" --version-file "$tmp/probe-image/VERSION"
assert_eq "$code" "1" "ac-17 an image whose kind is probe is refused"
assert_contains "$err" "release-preflight: " "ac-17 a refusal reason carries the script's prefix"
assert_contains "$err" "kind is 'probe'" "ac-17 the refusal names the kind it found"
assert_eq "$(printf '%s' "$out" | grep -c 'release-preflight: ')" "0" \
  "ac-17 the reasons go to stderr, not to the stage log"

cp -a "$tmp/ok" "$tmp/no-upstream"
python3 - "$tmp/no-upstream/image/ab/image.json" <<'PYTHON'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    doc = json.load(handle)
doc.pop("upstream_version", None)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")
PYTHON
run_preflight "$tmp/no-upstream" --tag "$upstream" --version-file "$tmp/no-upstream/VERSION"
assert_eq "$code" "1" "ac-17 an image identity without upstream_version is refused"
assert_contains "$err" "carries no upstream_version" "ac-17 the refusal says which field is missing"

# --------------------------------------------------------------------------- #
# ac-17: the payload has to describe itself as the format we consume
# --------------------------------------------------------------------------- #

cp -a "$tmp/ok" "$tmp/bad-format"
json_edit "$tmp/bad-format/stage/manifest.json" set format ab-payload/0
run_preflight "$tmp/bad-format" --tag "$upstream" --version-file "$tmp/bad-format/VERSION"
assert_eq "$code" "1" "ac-17 a payload manifest of another format is refused"
assert_contains "$err" "ab-payload/0" "ac-17 the refusal names the format it found"
assert_contains "$err" "ab-payload/1" "ac-17 the refusal names the format it expects"

cp -a "$tmp/ok" "$tmp/no-kernel"
json_edit "$tmp/no-kernel/stage/manifest.json" drop-member kernel.bin
run_preflight "$tmp/no-kernel" --tag "$upstream" --version-file "$tmp/no-kernel/VERSION"
assert_eq "$code" "1" "ac-17 a payload manifest without kernel.bin is refused"
assert_contains "$err" "no 'kernel.bin' member" "ac-17 the refusal names the missing member"

# --------------------------------------------------------------------------- #
# ac-17: no bootloader member is a refusal, and it says bootloader
#
# This is the release that must never happen: a payload that updates everything except
# the thing which boots it. 04 carries the member; before it lands the preflight refuses
# every automatic release, which is the intended behaviour and not a defect.
# --------------------------------------------------------------------------- #

cp -a "$tmp/ok" "$tmp/no-bootloader"
json_edit "$tmp/no-bootloader/stage/manifest.json" drop-member boot.tar
run_preflight "$tmp/no-bootloader" --tag "$upstream" --version-file "$tmp/no-bootloader/VERSION"
assert_eq "$code" "1" "ac-17 a payload manifest without boot.tar is refused"
assert_contains "$err" "bootloader" "ac-17 the refusal says the release would carry no bootloader"
assert_contains "$err" "boot.tar" "ac-17 the refusal names the member that is missing"
assert_eq "$(printf '%s' "$err" | grep -c "no 'kernel.bin' member")" "0" \
  "ac-17 the bootloader gate does not report the other members as missing"

# A manifest entry the tar does not back is the same failure from the other side.
cp -a "$tmp/ok" "$tmp/bootloader-not-in-tar"
tar -cf "$tmp/bootloader-not-in-tar/payload.tar" -C "$tmp/bootloader-not-in-tar/stage" \
  manifest.json rootfs.tar.gz kernel.bin initramfs.cpio.gz platform.tar
run_preflight "$tmp/bootloader-not-in-tar" --tag "$upstream" \
  --version-file "$tmp/bootloader-not-in-tar/VERSION"
assert_eq "$code" "1" "ac-17 a manifest entry the payload tar does not carry is refused"
assert_contains "$err" "does not carry it" "ac-17 the refusal says the promised member is absent"

# --------------------------------------------------------------------------- #
# ac-17: the bootloader member has to hold a menu and a GRUB core
# --------------------------------------------------------------------------- #

cp -a "$tmp/ok" "$tmp/no-grub-cfg"
rm -f "$tmp/no-grub-cfg/tree/boot/grub/grub.cfg"
pack_boot_tar "$tmp/no-grub-cfg"
repack "$tmp/no-grub-cfg"
run_preflight "$tmp/no-grub-cfg" --tag "$upstream" --version-file "$tmp/no-grub-cfg/VERSION"
assert_eq "$code" "1" "ac-17 a boot.tar without grub.cfg is refused"
assert_contains "$err" "no grub.cfg" "ac-17 the refusal names the missing menu"

cp -a "$tmp/ok" "$tmp/no-grub-core"
rm -rf "$tmp/no-grub-core/tree/EFI" "$tmp/no-grub-core/tree/boot"
pack_boot_tar "$tmp/no-grub-core"
repack "$tmp/no-grub-core"
run_preflight "$tmp/no-grub-core" --tag "$upstream" --version-file "$tmp/no-grub-core/VERSION"
assert_eq "$code" "1" "ac-17 a boot.tar without the GRUB core is refused"
assert_contains "$err" "no GRUB core" "ac-17 the refusal names the missing loader"

# The loader the ESP really carries is EFI/BOOT/BOOTX64.EFI: the check must not depend on
# the case the member happens to be stored in.
cp -a "$tmp/ok" "$tmp/upper-core"
rm -rf "$tmp/upper-core/tree/boot/grub/x86_64-efi"
pack_boot_tar "$tmp/upper-core"
repack "$tmp/upper-core"
run_preflight "$tmp/upper-core" --tag "$upstream" --version-file "$tmp/upper-core/VERSION"
assert_eq "$code" "0" "ac-17 a boot.tar with an upper-case BOOTX64.EFI and grub.cfg passes"

# --------------------------------------------------------------------------- #
# ac-17: every digest in the manifest is the digest of the bytes in the tar
# --------------------------------------------------------------------------- #

cp -a "$tmp/ok" "$tmp/bad-digest"
zeros=$(printf '%064d' 0)
json_edit "$tmp/bad-digest/stage/manifest.json" member-digest kernel.bin "$zeros"
run_preflight "$tmp/bad-digest" --tag "$upstream" --version-file "$tmp/bad-digest/VERSION"
assert_eq "$code" "1" "ac-17 a manifest digest that does not match the tar is refused"
assert_contains "$err" "kernel.bin" "ac-17 the refusal names the member with the wrong digest"
assert_contains "$err" "$zeros" "ac-17 the refusal names the digest the manifest records"
assert_contains "$err" "$(digest_of "$tmp/bad-digest/stage/kernel.bin")" \
  "ac-17 the refusal names the digest the payload actually carries"

# --------------------------------------------------------------------------- #
# ac-17: the three versions are the same version
# --------------------------------------------------------------------------- #

cp -a "$tmp/ok" "$tmp/image-version"
json_edit "$tmp/image-version/image/ab/image.json" set upstream_version 25.12.2
run_preflight "$tmp/image-version" --tag "$upstream" --version-file "$tmp/image-version/VERSION"
assert_eq "$code" "1" "ac-17 an image upstream_version that differs from the tag is refused"
assert_contains "$err" "differs from the tag" "ac-17 the refusal says the tag and the image disagree"
assert_contains "$err" "25.12.2" "ac-17 the refusal names the version the image records"

cp -a "$tmp/ok" "$tmp/manifest-version"
json_edit "$tmp/manifest-version/stage/manifest.json" set rootfs 25.12.2
run_preflight "$tmp/manifest-version" --tag "$upstream" \
  --version-file "$tmp/manifest-version/VERSION"
assert_eq "$code" "1" "ac-17 a payload rootfs that differs from the tag is refused"
assert_contains "$err" "payload manifest rootfs '25.12.2' differs from the tag" \
  "ac-17 the refusal says the payload and the tag disagree"

cp -a "$tmp/ok" "$tmp/image-platform"
json_edit "$tmp/image-platform/image/ab/image.json" set platform_version 9.9.8
run_preflight "$tmp/image-platform" --tag "$upstream" --version-file "$tmp/image-platform/VERSION"
assert_eq "$code" "1" "ac-17 an image platform_version that differs from VERSION is refused"
assert_contains "$err" "image platform_version '9.9.8'" \
  "ac-17 the refusal names the platform version the image records"

# "The release does not change VERSION" has to be mechanical: the shipped file is compared
# with the version being published.
cp -a "$tmp/ok" "$tmp/version-drift"
printf '9.9.8\n' >"$tmp/version-drift/VERSION"
run_preflight "$tmp/version-drift" --tag "$upstream" --platform-version "$platform" \
  --version-file "$tmp/version-drift/VERSION"
assert_eq "$code" "1" "ac-17 a VERSION file that differs from the published platform version is refused"
assert_contains "$err" "VERSION carries '9.9.8'" "ac-17 the refusal says what the shipped file carries"
assert_contains "$err" "$platform" "ac-17 the refusal says which platform version is being published"

# --------------------------------------------------------------------------- #
# ac-17: the tag policy, both release lines
# --------------------------------------------------------------------------- #

run_preflight "$tmp/ok" --tag "v$upstream" --version-file "$tmp/ok/VERSION"
assert_eq "$code" "1" "ac-17 a v-prefixed tag is refused under the bare policy"
assert_contains "$err" "--tag-policy bare" "ac-17 the refusal names the policy that refused it"

make_release "$tmp/v-line" "$upstream" "$upstream"
run_preflight "$tmp/v-line" --tag "v$upstream" --tag-policy v --version-file "$tmp/v-line/VERSION"
assert_eq "$code" "0" "ac-17 the same tag passes under the v policy"
assert_eq "$(output_of platform_version)" "$upstream" \
  "ac-17 the v policy takes the platform version from the tag"

run_preflight "$tmp/v-line" --tag "v$upstream" --tag-policy v \
  --platform-version "$platform" --version-file "$tmp/v-line/VERSION"
assert_eq "$code" "1" "ac-17 a platform version that differs from the tag version is refused"
assert_contains "$err" "without its 'v' prefix" "ac-17 the refusal explains where the version comes from"

# The image record is checked on both lines: a v* release whose image names another
# platform version is the v0.0.6 mistake one layer deeper, and the tag alone would not
# catch it.
make_release "$tmp/v-line-image-drift" "$upstream" "$upstream"
python3 - "$tmp/v-line-image-drift/image/ab/image.json" <<'INNER'
import json
import sys

path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["platform_version"] = "9.9.8"
open(path, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
INNER
run_preflight "$tmp/v-line-image-drift" --tag "v$upstream" --tag-policy v \
  --version-file "$tmp/v-line-image-drift/VERSION"
assert_eq "$code" "1" "ac-17 the v policy refuses an image that records another platform version"
assert_contains "$err" "image platform_version '9.9.8'" \
  "ac-17 the refusal names the platform version the image records"

# --------------------------------------------------------------------------- #
# ac-17: every problem is reported, and the verdict is repeatable
# --------------------------------------------------------------------------- #

cp -a "$tmp/probe-image" "$tmp/many-problems"
run_preflight "$tmp/many-problems" --tag "v$upstream" --version-file "$tmp/many-problems/VERSION"
assert_eq "$code" "1" "ac-17 an input with several problems is refused"
reasons=$(printf '%s\n' "$err" | grep -c '^release-preflight: ')
if [ "$reasons" -ge 3 ]; then
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-17 every problem is listed in one run ($reasons reasons)"
else
  _assert_fail "ac-17 every problem is listed in one run" \
    "only $reasons reason(s): $(printf '%s' "$err" | tr '\n' '|')"
fi

run_preflight "$tmp/ok" --tag "$upstream" --version-file "$tmp/ok/VERSION"
first_green=$code
first_env=$(cat "$tmp/out.env")
run_preflight "$tmp/ok" --tag "$upstream" --version-file "$tmp/ok/VERSION"
assert_eq "$code" "$first_green" "ac-17 the same input gives the same exit code twice"
assert_eq "$code" "0" "ac-17 a coherent release passes again"
assert_eq "$(cat "$tmp/out.env")" "$first_env" \
  "ac-17 the same input publishes the same outputs twice"

run_preflight "$tmp/probe-image" --tag "$upstream" --version-file "$tmp/probe-image/VERSION"
first_red=$code
run_preflight "$tmp/probe-image" --tag "$upstream" --version-file "$tmp/probe-image/VERSION"
assert_eq "$code" "$first_red" "ac-17 a refused input is refused again with the same exit code"
assert_eq "$code" "1" "ac-17 the repeated refusal is still a refusal"

# --------------------------------------------------------------------------- #
# ac-17: an input that cannot be read is an invocation error, not a verdict
# --------------------------------------------------------------------------- #

run_preflight "$tmp/ok" --tag "$upstream" --version-file "$tmp/ok/VERSION" \
  --payload-tar "$tmp/absent.tar"
assert_eq "$code" "1" "ac-17 a missing payload tar fails the preflight"
assert_contains "$err" "payload tar not found" "ac-17 the failure names the input it could not read"

run_preflight "$tmp/ok" --tag "$upstream" --version-file "$tmp/ok/VERSION" \
  --image-dir "$tmp/absent-image"
assert_eq "$code" "1" "ac-17 a missing image identity fails the preflight"
assert_contains "$err" "image identity not found" "ac-17 the failure names the file it expected"

run_preflight "$tmp/ok" --tag "$upstream" --tag-policy latest
assert_eq "$code" "1" "ac-17 an unknown tag policy is refused"
assert_contains "$err" "--tag-policy must be bare or v" "ac-17 the failure names the accepted values"

finish
