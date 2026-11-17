#!/usr/bin/env bash
# Module: ci
# The build-time half of the /dev contract.
#
# The initramfs owns /dev for the window before switch_root and this kernel has no
# devtmpfs, so the nodes have to be inside the archive: init/initramfs.c unpacks a newc
# device entry by calling init_mknod, and that is the only way a device node can exist in
# an initramfs. A boot that only finds out at runtime powers the machine off on somebody's
# desk, so the archive is graded when it is built, against the same list the boot asserts
# (initramfs/lib/wf.sh, WF_DEV_CONTRACT) - read out of that file, never copied here.
#
#   ac-6 the stage grades every archive it packs, reads the list from wf.sh, and generates
#        the entries itself because mknod(1) needs CAP_MKNOD (the runner is unprivileged,
#        and a laptop running this suite is macOS with no newc device nodes at all)
#   ac-6 a complete archive passes; a missing entry, a wrong major:minor, a directory where
#        a node belongs, a missing /dev, a node the kernel owns and an unreadable archive
#        are each named and each fail instead of being skipped
#
# The two programs are lifted out of the shipped script byte for byte and run against real
# archives, because the stage itself cannot run here: it needs the locked apk toolset. A
# copy of the rule in this file would prove nothing about the file that ships, which is the
# same reasoning tests/modules/boot/test_production_init.sh uses for handover_cmd.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ci_script="scripts/ci/initramfs.sh"
wf_sh="initramfs/lib/wf.sh"
script_src="$(cat "${ci_script}")"
real_contract="$(sed -n 's/^WF_DEV_CONTRACT="\([^"]*\)"$/\1/p' "${wf_sh}" | head -n 1)"

assert_command_ok "ac-6 the host can build and list a cpio archive" \
    bash -c 'command -v cpio && command -v gzip && command -v python3'

# extract_program <name>: one of the two programs, from its `name='` line to the
# closing quote, exactly as the script carries it. `quote` keeps the literal single
# quote out of the awk program, which is single-quoted itself.
quote="'"
extract_program() {
    awk -v start="$1=${quote}" -v end="${quote}" \
        '$0 == start { inside = 1 } inside { print } inside && $0 == end { exit }' \
        "${ci_script}"
}
insert_program="$(extract_program dev_contract_insert)"
check_program="$(extract_program dev_contract_check)"
eval "${insert_program}"
eval "${check_program}"

# insert <tree.cpio> <out.cpio> <contract>: the generator, on a tree packed the way the
# stage packs one. Prints the paths it added.
insert() {
    WF_DEV_CONTRACT="$3" python3 -c "${dev_contract_insert}" "$1" "$2"
}

# grade <archive.cpio.gz> <contract>: the grader, on a packed archive. Prints one line per
# deviation and nothing when the archive satisfies the contract.
grade() {
    gzip -dc "$1" 2>/dev/null | cpio -itv 2>/dev/null \
        | awk -v manifest="$2" -v archive="$1" "${dev_contract_check}" || true
}

# make_tree <dir>: the tree scripts/ci/initramfs.sh stages, at its core.
make_tree() {
    local dir="$1"
    mkdir -p "${dir}/bin" "${dir}/lib" "${dir}/proc" "${dir}/sys" "${dir}/dev" "${dir}/mnt"
    printf '#!/bin/sh\nexec /sbin/init\n' >"${dir}/init"
    chmod 0755 "${dir}/init"
    printf 'busybox\n' >"${dir}/bin/busybox"
    printf '# wf\n' >"${dir}/lib/wf.sh"
    (cd "${dir}" && find . -print0 | cpio --null -o -H newc 2>/dev/null) >"${dir}.cpio"
}

# --------------------------------------------------------------------------- #
# ac-6 the stage reads the one list, generates the entries, and fails on a deviation
# --------------------------------------------------------------------------- #

assert_contains "${script_src}" 'ci_require_cmd cpio gzip find sort cmp python3 awk' \
    "ac-6 the stage requires the programs the contract needs"
assert_contains "${script_src}" 'dev_contract_source="${CI_REPO_ROOT}/initramfs/lib/wf.sh"' \
    "ac-6 the contract source is wf.sh, the file the boot reads too"
assert_eq "$(printf '%s\n' "${script_src}" | grep -c 'null:char:ours')" "0" \
    "ac-6 the stage carries no second copy of the list"
assert_eq "$(printf '%s\n' "${script_src}" | grep -c "^dev_contract_insert='")" "1" \
    "ac-6 the generator is written once"
assert_eq "$(printf '%s\n' "${script_src}" | grep -c "^dev_contract_check='")" "1" \
    "ac-6 ... and so is the rule that grades the archive"
assert_contains "${insert_program}" 'TRAILER!!!' \
    "ac-6 the generator is lifted out of the shipped file (it keeps the cpio trailer)"
assert_contains "${check_program}" 'malformed contract entry' \
    "ac-6 the grader is lifted out of the shipped file"
assert_contains "${script_src}" 'python3 -c "${dev_contract_insert}" "${tree_archive}" "${archive_plain}"' \
    "ac-6 the stage inserts the entries with that generator"
assert_contains "${script_src}" 'awk -v manifest="${dev_manifest}" -v archive="${out_file}" "${dev_contract_check}"' \
    "ac-6 ... and grades the packed archive with that rule"
assert_contains "${script_src}" 'ci_die "the initramfs does not satisfy the /dev contract' \
    "ac-6 a deviation fails the stage"
assert_contains "${script_src}" 'the staged /lib/wf.sh carries a different /dev contract' \
    "ac-6 a staged wf.sh with another list is refused, so build and boot cannot disagree"
assert_eq "$(printf '%s\n' "${script_src}" | grep -c 'ci_warn.*dev-contract')" "0" \
    "ac-6 the check is never downgraded to a warning"
assert_eq "${real_contract}" \
    "console:char:kernel:5:1:0600 null:char:ours:1:3:0666 zero:char:ours:1:5:0666 urandom:char:ours:1:9:0666 ttyS0:char:ours:4:64:0660" \
    "ac-6 the list in wf.sh is the one both sides assert"

# --------------------------------------------------------------------------- #
# ac-6 a complete archive passes, and cpio agrees about what is in it
# --------------------------------------------------------------------------- #

make_tree "$tmp/tree"
assert_eq "$(insert "$tmp/tree.cpio" "$tmp/good.cpio" "${real_contract}")" \
    "dev/null dev/zero dev/urandom dev/ttyS0" \
    "ac-6 the generator adds exactly the entries the contract calls ours"
gzip -9 <"$tmp/good.cpio" >"$tmp/good.cpio.gz"
assert_eq "$(grade "$tmp/good.cpio.gz" "${real_contract}")" "" \
    "ac-6 a complete archive satisfies the contract"

listing="$(gzip -dc "$tmp/good.cpio.gz" | cpio -itv 2>/dev/null)"
assert_contains "${listing}" "dev" "ac-6 the /dev directory is in the archive"
null_line="$(printf '%s\n' "${listing}" | awk '$NF == "dev/null"')"
assert_contains "${null_line}" "crw-rw-rw-" "ac-6 /dev/null is a character device with mode 0666"
assert_matches "${null_line}" '1,[[:space:]]*3([[:space:]]|$)' "ac-6 ... char 1:3, as cpio reads it"
tty_line="$(printf '%s\n' "${listing}" | awk '$NF == "dev/ttyS0"')"
assert_contains "${tty_line}" "crw-rw----" "ac-6 /dev/ttyS0 carries the contract's mode"
assert_matches "${tty_line}" '4,[[:space:]]*64([[:space:]]|$)' "ac-6 ... char 4:64"
assert_eq "$(printf '%s\n' "${listing}" | grep -c 'dev/console')" "0" \
    "ac-6 the archive does not carry a second /dev/console"
# bsdcpio lists stored names with their "./" prefix and GNU cpio without it.
assert_eq "$(printf '%s\n' "${listing}" | awk '$NF == "init" || $NF == "./init"' | wc -l | tr -d ' ')" "1" \
    "ac-6 the tree's own members survive the insertion"

assert_eq "$(insert "$tmp/good.cpio" "$tmp/twice.cpio" "${real_contract}")" "" \
    "ac-6 a second pass adds nothing: the generator only fills what is missing"
gzip -9 <"$tmp/twice.cpio" >"$tmp/twice.cpio.gz"
assert_eq "$(grade "$tmp/twice.cpio.gz" "${real_contract}")" "" \
    "ac-6 ... and leaves an archive that still satisfies the contract"

# The archive the stage grades is the gzipped one; a plain one is graded the same way.
assert_eq "$( { cat "$tmp/good.cpio" | cpio -itv 2>/dev/null; } \
    | awk -v manifest="${real_contract}" -v archive="$tmp/good.cpio" "${dev_contract_check}")" "" \
    "ac-6 the rule reads an unpacked archive too"

# --------------------------------------------------------------------------- #
# ac-6 every way of being wrong is named and fails
# --------------------------------------------------------------------------- #

# 1. an entry the contract calls ours is missing from the archive
no_null="console:char:kernel:5:1:0600 zero:char:ours:1:5:0666 urandom:char:ours:1:9:0666 ttyS0:char:ours:4:64:0660"
insert "$tmp/tree.cpio" "$tmp/missing.cpio" "${no_null}" >/dev/null
gzip -9 <"$tmp/missing.cpio" >"$tmp/missing.cpio.gz"
assert_eq "$(grade "$tmp/missing.cpio.gz" "${real_contract}")" \
    "dev/null: missing (expected char 1:3)" \
    "ac-6 an archive without /dev/null is named with what was expected"

# 2. the number is wrong
wrong_ids="console:char:kernel:5:1:0600 null:char:ours:1:4:0666 zero:char:ours:1:5:0666 urandom:char:ours:1:9:0666 ttyS0:char:ours:4:64:0660"
insert "$tmp/tree.cpio" "$tmp/wrong-ids.cpio" "${wrong_ids}" >/dev/null
gzip -9 <"$tmp/wrong-ids.cpio" >"$tmp/wrong-ids.cpio.gz"
assert_eq "$(grade "$tmp/wrong-ids.cpio.gz" "${real_contract}")" \
    "dev/null: expected 1:3, the archive carries 1:4" \
    "ac-6 a wrong major:minor is a failure, not a warning"

# 3. something that is not a character device sits at the path
mkdir -p "$tmp/tree-type/dev/null"
(cd "$tmp/tree-type" && find . -print0 | cpio --null -o -H newc 2>/dev/null) >"$tmp/wrong-type.cpio"
insert "$tmp/wrong-type.cpio" "$tmp/wrong-type-dev.cpio" "${real_contract}" >/dev/null
gzip -9 <"$tmp/wrong-type-dev.cpio" >"$tmp/wrong-type.cpio.gz"
type_out="$(grade "$tmp/wrong-type.cpio.gz" "${real_contract}")"
assert_contains "${type_out}" "dev/null: expected char 1:3, the archive carries d" \
    "ac-6 a directory where a node belongs is named with the type that is there"

# 4. no /dev directory at all
mkdir -p "$tmp/tree-nodev/lib"
(cd "$tmp/tree-nodev" && find . -print0 | cpio --null -o -H newc 2>/dev/null) >"$tmp/no-dev.cpio"
insert "$tmp/no-dev.cpio" "$tmp/no-dev-out.cpio" "${real_contract}" >/dev/null
gzip -9 <"$tmp/no-dev-out.cpio" >"$tmp/no-dev.cpio.gz"
assert_contains "$(grade "$tmp/no-dev.cpio.gz" "${real_contract}")" \
    "dev/: missing (the archive carries no /dev directory)" \
    "ac-6 a missing /dev directory is its own finding"

# 5. a node the kernel's own initramfs provides, shipped again by us
console_ours="console:char:ours:5:1:0600 null:char:ours:1:3:0666 zero:char:ours:1:5:0666 urandom:char:ours:1:9:0666 ttyS0:char:ours:4:64:0660"
insert "$tmp/tree.cpio" "$tmp/console.cpio" "${console_ours}" >/dev/null
gzip -9 <"$tmp/console.cpio" >"$tmp/console.cpio.gz"
assert_contains "$(grade "$tmp/console.cpio.gz" "${real_contract}")" \
    "dev/console: shipped although the kernel provides it" \
    "ac-6 a duplicated console is refused: one path, one owner"

# 6. nothing at all: the archive the stage would produce if the insertion were dropped
gzip -9 <"$tmp/tree.cpio" >"$tmp/plain.cpio.gz"
assert_eq "$(grade "$tmp/plain.cpio.gz" "${real_contract}" | wc -l | tr -d ' ')" "4" \
    "ac-6 without the insertion all four of our entries are reported"

# 7. an archive that does not parse is a finding, never a pass
printf 'not a cpio archive\n' >"$tmp/junk.cpio.gz"
assert_matches "$(grade "$tmp/junk.cpio.gz" "${real_contract}")" \
    '^unreadable: .* does not list as a cpio archive' \
    "ac-6 an unreadable archive fails instead of passing vacuously"

# 8. a malformed list is a finding too
assert_contains "$(grade "$tmp/good.cpio.gz" 'null:char')" \
    "malformed contract entry: null:char" \
    "ac-6 a malformed contract entry is reported"
