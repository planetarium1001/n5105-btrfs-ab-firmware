#!/usr/bin/env bash
# Module: ci
# ac-10 (F10): the published image is compressed reproducibly.
#
# The release stage used `gzip -9 -c`, which writes the build time and the source file name
# into the gzip header (MTIME and FNAME). Two builds of the same image therefore produced
# different bytes, and the published `SHA256SUMS` changed for a reason that has nothing to
# do with the release: "did the image change?" could not be answered from the checksums, and
# a rebuild of a tag did not reproduce it. `gzip -9 -n` drops both fields.
#
# What is asserted, in order:
#   ac-10 the header the stage writes has FNAME off and MTIME zero
#   ac-10 the reverse control: plain `gzip -9 -c` does set both, so the assertion is not
#         passing on a header nothing ever writes
#   ac-10 the whole compressed artefact is byte-identical across two runs with a different
#         wall clock, which is the property the header fix exists for
#
# The stage is run rather than the gzip invocation quoted out of it: a test that only greps
# the script would stay green if the flag were dropped from a different branch (the variant
# image, or the reuse path), and the FNAME the old code wrote came from the source file name,
# which only exists once the stage names the output.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# macOS has shasum only; the target and CI both have sha256sum.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/sha256sum" <<'STUB'
#!/bin/sh
if [ "$#" -eq 0 ]; then
  exec shasum -a 256
fi
for f in "$@"; do shasum -a 256 "$f"; done
STUB
chmod +x "$tmp/bin/sha256sum"

# gzip_header <file>: the fields this test is about, one KEY=VALUE per line.
#
# The gzip member header (RFC 1952) is: 1f 8b 08 FLG MTIME[4] XFL OS. Byte 4 is the flags -
# bit 3 (0x08) is FNAME, which means the original file name follows the 10 byte header as a
# NUL terminated string. Bytes 5-8 are MTIME, little endian, in seconds since the epoch.
gzip_header() {
    python3 - "$1" <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
if len(data) < 10 or data[0:2] != b"\x1f\x8b":
    print("ERROR=not-a-gzip-member")
    raise SystemExit(1)
flags = data[3]
mtime = int.from_bytes(data[4:8], "little")
fname = b""
if flags & 0x08:
    end = data.index(b"\x00", 10)
    fname = data[10:end]
print(f"FLG={flags:#04x}")
print(f"MTIME={mtime}")
print(f"FNAME={fname.decode('latin-1')}")
PY
}

header_field() { # <file> <FIELD>: one value out of gzip_header
    gzip_header "$1" | sed -n "s/^$2=//p" | head -n 1
}

# --- the artefact the release stage produces -------------------------------- #
# The image is random, so a compression that reused a cached stream would not verify; the
# release stage round-trips its output against the input on its own, and the digest check
# below re-proves it.
image="$tmp/build.img"
head -c 131072 /dev/urandom >"$image"
image_sha="$(shasum -a 256 "$image" | cut -d' ' -f1)"
payload="$tmp/payload.tar"
printf 'not really a payload\n' >"$payload"
# A distinct modification time is what a compressor without -n would record, independent of
# the run's own clock.
touch -t 202001020304.05 "$image"

run_release() { # <ci-root> [flags...]
    local ci_root="$1"
    shift
    env PATH="$tmp/bin:$PATH" CI_TMP_ROOT="$ci_root" CI_LOG_DIR="$ci_root/logs" "$@" \
        bash scripts/ci/release.sh 2>&1
}

first_root="$tmp/ci-first"
run_release "$first_root" CI_IMAGE="$image" CI_PAYLOAD="$payload" \
    CI_PLATFORM_VERSION=0.0.11 CI_UPSTREAM_VERSION=25.12.2 CI_RELEASE_TAG=v0.0.11 \
    >"$tmp/release-1.log" 2>&1
assert_eq "$?" "0" "ac-10 the release stage builds from an image"
img_gz="$first_root/release/n5105-ab-25.12.2-install.img.gz"
assert_file_exists "$img_gz" "ac-10 the stage publishes the compressed image"

# The stage must still produce the same image the build made: -n changes the header, not the
# deflate stream, and a test that only reads header bytes would not notice a broken stream.
assert_eq "$(gzip -dc "$img_gz" | shasum -a 256 | cut -d' ' -f1)" "$image_sha" \
    "ac-10 the compressed image still decompresses to the built image"

header="$(gzip_header "$img_gz")"
assert_eq "$(header_field "$img_gz" FLG)" "0x00" \
    "ac-10 the header carries no flags: FNAME (bit 3) is clear"
assert_eq "$(header_field "$img_gz" MTIME)" "0" \
    "ac-10 the header carries no timestamp"
assert_eq "$(header_field "$img_gz" FNAME)" "" \
    "ac-10 and no original file name is embedded"
# The source name must appear nowhere at all, not merely not in the FNAME field: the test
# would pass on a header that names a different path.
assert_eq "$(grep -c 'build.img' <(gzip_header "$img_gz") || true)" "0" \
    "ac-10 the source file name is not anywhere in the header"

# --- the reverse control ---------------------------------------------------- #
# Same input, same flags except -n: this is what the stage used to write. Without this the
# assertion above would also pass for a header that never records anything.
control="$tmp/control.img.gz"
gzip -9 -c "$image" >"$control"
assert_eq "$(header_field "$control" FLG)" "0x08" \
    "ac-10 control: plain gzip -c sets FNAME, so the field can be observed"
assert_eq "$([ "$(header_field "$control" MTIME)" != "0" ] && echo set || echo zero)" "set" \
    "ac-10 control: and it records the modification time"
assert_eq "$(header_field "$control" FNAME)" "build.img" \
    "ac-10 control: the name it records is the source file's"
# The two headers really differ, so the fix is what changed the bytes.
assert_eq "$([ "$(shasum -a 256 "$control" | cut -d' ' -f1)" = \
    "$(shasum -a 256 "$img_gz" | cut -d' ' -f1)" ] && echo same || echo different)" \
    "different" "ac-10 the reproducible stream differs from the one with a header"

# --- reproducibility: two runs, different clocks, identical bytes ----------- #
# This is the property the header fix buys. The builds are separated in time so a header
# timestamp (the old behaviour) would have to differ; the input's mtime is fixed, so the only
# variable left is the run's clock.
second_root="$tmp/ci-second"
sleep 1
run_release "$second_root" CI_IMAGE="$image" CI_PAYLOAD="$payload" \
    CI_PLATFORM_VERSION=0.0.11 CI_UPSTREAM_VERSION=25.12.2 CI_RELEASE_TAG=v0.0.11 \
    >"$tmp/release-2.log" 2>&1
assert_eq "$?" "0" "ac-10 the release stage runs a second time"
second_gz="$second_root/release/n5105-ab-25.12.2-install.img.gz"
assert_file_exists "$second_gz" "ac-10 the second run publishes its image"
assert_eq "$(shasum -a 256 "$second_gz" | cut -d' ' -f1)" \
    "$(shasum -a 256 "$img_gz" | cut -d' ' -f1)" \
    "ac-10 two runs of the same input produce byte-identical compressed images"
assert_eq "$(grep -c "$(basename "$img_gz")" "$first_root/release/SHA256SUMS" || true)" "1" \
    "ac-10 the checksum file covers the image once"

# --- the source really uses -n --------------------------------------------- #
# The end-to-end assertions above prove the shipped bytes are right; this pins the two lines
# themselves so a later edit that removes -n fails here, with the file and the line named,
# rather than only through a digest that someone has to compare by hand.
release_src="$(cat scripts/ci/release.sh)"
assert_contains "$release_src" 'gzip -9 -nc "${image}"' \
    "ac-10 the image is compressed with -n"
assert_contains "$release_src" 'gzip -9 -nc "${variant_in}"' \
    "ac-10 and so is the wan-ssh variant"
assert_eq "$(printf '%s\n' "$release_src" | grep -c 'gzip -9 -c' || true)" "0" \
    "ac-10 no compression site is left without -n"
# -c must stay: without it gzip deletes the input image and writes a side file instead of the
# stream the stage redirects. Every gzip invocation whose result is redirected has to carry
# both flags, in either order.
header_flag_bugs="$(printf '%s\n' "$release_src" | python3 -c '
import re
import sys

bad = 0
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("gzip "):
        continue
    for match in re.finditer(r"gzip ((?:-[A-Za-z0-9]+ ?)+)", line):
        flags = match.group(1).split()
        letters = "".join(flag.lstrip("-") for flag in flags)
        # Only the write-to-stdout invocations matter; -d (decompress) paths are unrelated.
        if "d" in letters:
            continue
        if "n" not in letters or "c" not in letters:
            print(line)
            bad += 1
print(bad)
' | tail -n 1)"
assert_eq "$header_flag_bugs" "0" \
    "ac-10 every compression carries both -n and -c"

finish
