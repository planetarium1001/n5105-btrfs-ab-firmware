#!/usr/bin/env bash
# Module: boot
# The /dev contract of the initramfs window.
#
# Before switch_root this initramfs owns /dev, and this kernel offers neither of the two
# usual helpers: there is no devtmpfs (`mount -t devtmpfs` fails with ENODEV, the name is
# absent from /proc/filesystems) and the upstream busybox has no mdev applet. The nodes
# therefore have to come from the initramfs itself, and the failure mode when they do not
# is silent rather than loud: a shell output redirect creates its target, so the first
# `2>/dev/null` leaves a *regular file* named /dev/null behind, an `[ -e /dev/null ]` gate
# passes on it, and the output meant for the bit bucket is written into ramfs. Measured on
# the reference device with the same busybox, 2026-11-17.
#
#   ac-5 one contract list in wf.sh; wf_make_dev creates the nodes this side owns and never
#        touches the one the kernel provides; wf_assert_dev checks every entry and prints
#        expected versus found plus the filesystem table when one is missing or wrong
#   ac-5 the boot init runs the contract before its first redirect, still asserts it after
#        the sysfs coldplug, and dumps the directory before failing the boot
#   ac-9 the two dead attempts (devtmpfs) are gone from both inits and the comments no
#        longer claim the kernel unpacks console and null out of our archive
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The three programs the contract shells out to, and the listing it reads, are all faked:
# a test host cannot create a device node (that needs CAP_MKNOD, and macOS has no newc
# device nodes at all), and what has to be proven here is the decision, not mknod(1).
mkdir -p "$tmp/bin" "$tmp/dev"
export WF_STUB_LOG="$tmp/stub.log"
export WF_LS_MAP="$tmp/ls.map"
: >"$WF_STUB_LOG"
: >"$WF_LS_MAP"

cat >"$tmp/bin/ls" <<'STUB'
#!/bin/sh
# Fake `ls -l <path>`: the canned line for that path, or the exit status real ls uses when
# nothing is there. WF_LS_MAP holds one "<path>|<ls -l line>" pair per line.
for last; do :; done
if [ -n "${WF_LS_MAP:-}" ] && [ -f "${WF_LS_MAP}" ]; then
    while IFS='|' read -r map_path map_line; do
        [ "${map_path}" = "${last}" ] || continue
        printf '%s\n' "${map_line}"
        exit 0
    done <"${WF_LS_MAP}"
fi
printf 'ls: cannot access %s\n' "${last}" >&2
exit 1
STUB
for program in mknod rm chmod; do
    cat >"$tmp/bin/${program}" <<STUB
#!/bin/sh
printf '${program} %s\n' "\$*" >>"\${WF_STUB_LOG:?}"
exit 0
STUB
done
chmod 0755 "$tmp/bin/ls" "$tmp/bin/mknod" "$tmp/bin/rm" "$tmp/bin/chmod"

export WF_LS="$tmp/bin/ls" WF_MKNOD="$tmp/bin/mknod" WF_RM="$tmp/bin/rm"
export WF_CHMOD="$tmp/bin/chmod" WF_FILESYSTEMS="$tmp/filesystems"
export WF_SERIAL="$tmp/ttyS0" WF_CONSOLES="$tmp/consoles"
printf 'nodev\ttmpfs\n\text4\n' >"$WF_FILESYSTEMS"
: >"$WF_CONSOLES"

# shellcheck source=initramfs/lib/wf.sh
source "$root/initramfs/lib/wf.sh"

dev="$tmp/dev"
boot_init="$root/initramfs/boot/init"
s1_init="$root/initramfs/init"
wf_source="$(cat "$root/initramfs/lib/wf.sh")"
boot_source="$(cat "${boot_init}")"

# describe <path> <ls -l line>: one entry of the fake listing.
describe() {
    printf '%s|%s\n' "$1" "$2" >>"$WF_LS_MAP"
}

# complete: every entry of the contract, exactly as the kernel and the archive provide it.
complete() {
    : >"$WF_LS_MAP"
    describe "$dev" 'drwxr-xr-x    2 root     root            60 dev'
    describe "${dev}/console" 'crw-------    1 root     root         5,   1 dev/console'
    describe "${dev}/null" 'crw-rw-rw-    1 root     root         1,   3 dev/null'
    describe "${dev}/zero" 'crw-rw-rw-    1 root     root         1,   5 dev/zero'
    describe "${dev}/urandom" 'crw-rw-rw-    1 root     root         1,   9 dev/urandom'
    # The other spelling of a device field (bsd ls prints "4,64"), so both are covered.
    describe "${dev}/ttyS0" 'crw-rw----    1 root     dialout      4,64 dev/ttyS0'
}

# --------------------------------------------------------------------------- #
# ac-5 one list, in one place
# --------------------------------------------------------------------------- #

assert_eq "$(printf '%s\n' "${wf_source}" | grep -c '^WF_DEV_CONTRACT="')" "1" \
    "ac-5 the contract is defined exactly once, as one line"
assert_eq "$(grep -rl '^WF_DEV_CONTRACT="' "$root/initramfs" "$root/scripts/ci/initramfs.sh" | wc -l | tr -d ' ')" "1" \
    "ac-5 ... and nowhere else: the build side reads this one"
assert_contains "${wf_source}" 'console:char:kernel:5:1:0600' \
    "ac-5 /dev/console is in the list with its owner and numbers"
assert_contains "${wf_source}" 'null:char:ours:1:3:0666' \
    "ac-5 /dev/null is in the list as ours, char 1:3"
assert_contains "${wf_source}" "/proc/filesystems" \
    "ac-5 the failure message has the filesystem table next to it"

# --------------------------------------------------------------------------- #
# ac-5 wf_assert_dev: complete passes, one missing fails with the difference
# --------------------------------------------------------------------------- #

complete
assertion_out="$(wf_assert_dev "${dev}")"
assertion_rc=$?
assert_eq "${assertion_rc}" "0" "ac-5 a complete /dev passes the assertion"
assert_eq "${assertion_out}" "" "ac-5 ... silently, because a boot should not log noise"

complete
grep -v "/ttyS0" "$WF_LS_MAP" >"$tmp/ls.map.tmp" && mv "$tmp/ls.map.tmp" "$WF_LS_MAP"
assertion_out="$(wf_assert_dev "${dev}")"
assertion_rc=$?
assert_eq "${assertion_rc}" "1" "ac-5 one missing node fails the assertion"
assert_contains "${assertion_out}" "dev-contract: ${dev}/ttyS0 expected a character device 4:64 (ours), found nothing" \
    "ac-5 ... naming the path, what was expected and what was found"
assert_contains "${assertion_out}" "/proc/filesystems: nodev	tmpfs" \
    "ac-5 ... with the kernel's filesystem table in the same line"
assert_contains "${assertion_out}" "1 entr(y/ies) missing or wrong" \
    "ac-5 ... and a count of the failures"

# The regular file the first `2>/dev/null` leaves behind: the exact shape that made the old
# `[ -e /dev/null ]` gate pass on a /dev that had no device nodes in it.
complete
grep -v "/null" "$WF_LS_MAP" >"$tmp/ls.map.tmp" && mv "$tmp/ls.map.tmp" "$WF_LS_MAP"
describe "${dev}/null" '-rw-r--r--    1 root     root            57 dev/null'
assertion_out="$(wf_assert_dev "${dev}")"
assertion_rc=$?
assert_eq "${assertion_rc}" "1" "ac-5 a regular file at /dev/null fails the assertion"
assert_contains "${assertion_out}" "dev-contract: ${dev}/null expected a character device 1:3 (ours), found a regular file" \
    "ac-5 ... and the log says it is a regular file, not a device"

# A node with the wrong numbers is wrong, even though it is a character device.
complete
grep -v "/null" "$WF_LS_MAP" >"$tmp/ls.map.tmp" && mv "$tmp/ls.map.tmp" "$WF_LS_MAP"
describe "${dev}/null" 'crw-rw-rw-    1 root     root         1,   5 dev/null'
assertion_out="$(wf_assert_dev "${dev}")"
assertion_rc=$?
assert_eq "${assertion_rc}" "1" "ac-5 a node with the wrong major:minor fails the assertion"
assert_contains "${assertion_out}" "expected 1:3 (ours), found 1:5" \
    "ac-5 ... with both numbers in the log"

# --------------------------------------------------------------------------- #
# ac-5 wf_make_dev: creates what is ours, repairs what is in the way, never the kernel's
# --------------------------------------------------------------------------- #

: >"$WF_LS_MAP"
: >"$WF_STUB_LOG"
wf_make_dev "${dev}"
make_log="$(cat "$WF_STUB_LOG")"
assert_contains "${make_log}" "mknod ${dev}/null c 1 3" "ac-5 /dev/null is created as char 1:3"
assert_contains "${make_log}" "mknod ${dev}/zero c 1 5" "ac-5 /dev/zero is created as char 1:5"
assert_contains "${make_log}" "mknod ${dev}/urandom c 1 9" "ac-5 /dev/urandom is created as char 1:9"
assert_contains "${make_log}" "mknod ${dev}/ttyS0 c 4 64" "ac-5 /dev/ttyS0 is created as char 4:64"
assert_contains "${make_log}" "chmod 0666 ${dev}/null" "ac-5 the mode from the contract is applied"
assert_eq "$(printf '%s\n' "${make_log}" | grep -c "${dev}/console")" "0" \
    "ac-5 the kernel's /dev/console is never created or replaced by us"

# A node that is already right is left alone: no mknod, no rm.
complete
: >"$WF_STUB_LOG"
wf_make_dev "${dev}"
assert_eq "$(cat "$WF_STUB_LOG")" "" "ac-5 an intact /dev is not touched at all"

# The repair path: the regular file a redirect left behind has to go before mknod can take
# the name. Removal first, creation second - the order is the fix.
: >"$WF_LS_MAP"
describe "${dev}/null" '-rw-r--r--    1 root     root            57 dev/null'
: >"$WF_STUB_LOG"
wf_make_dev "${dev}"
make_log="$(cat "$WF_STUB_LOG")"
assert_contains "${make_log}" "rm -f ${dev}/null" "ac-5 a regular file in the way is removed"
assert_contains "${make_log}" "mknod ${dev}/null c 1 3" "ac-5 ... and the node is created after it"
rm_line="$(printf '%s\n' "${make_log}" | grep -n "rm -f ${dev}/null" | cut -d: -f1)"
mk_line="$(printf '%s\n' "${make_log}" | grep -n "mknod ${dev}/null" | cut -d: -f1)"
assert_eq "$([ "${rm_line}" -lt "${mk_line}" ] && echo ordered)" "ordered" \
    "ac-5 the removal happens before the creation"

# --------------------------------------------------------------------------- #
# ac-5 the boot init: contract first, assertion after the coldplug, listing on failure
# --------------------------------------------------------------------------- #

# Comments are excluded: both files name the dead attempt in prose, which is the point of
# ac-9. What must not come back is a line that runs it.
no_dead_mount() {
    printf '%s\n' "$1" | grep -v '^[[:space:]]*#' | grep -c 'mount -t devtmpfs'
}
assert_eq "$(no_dead_mount "${boot_source}")" "0" \
    "ac-5 the devtmpfs attempt is gone from the boot init"
assert_eq "$(no_dead_mount "$(cat "${s1_init}")")" "0" \
    "ac-5 ... and from the S1 probe init"
assert_eq "$(no_dead_mount "${wf_source}")" "0" \
    "ac-5 ... and out of the library the two share"
assert_eq "$(printf '%s\n' "${boot_source}" | grep -c '\[ ! -e /dev/null \]')" "0" \
    "ac-5 the existence-only gate is gone"
assert_contains "${boot_source}" 'wf_make_dev /dev' \
    "ac-5 the boot init creates the contract's nodes"

first_redirect="$(printf '%s\n' "${boot_source}" \
    | awk '!/^[[:space:]]*#/ && /2>\/dev\/null/ { print NR; exit }')"
make_line="$(printf '%s\n' "${boot_source}" | awk '/^wf_make_dev \/dev/ { print NR; exit }')"
assert_eq "$([ "${make_line}" -lt "${first_redirect}" ] && echo first)" "first" \
    "ac-5 the nodes are created before the first output redirect can leave a regular file"

assert_contains "${boot_source}" 'if ! wf_assert_dev /dev; then' \
    "ac-5 the boot init asserts the whole contract"
assert_contains "${boot_source}" 'wf_dev_dump /dev' \
    "ac-5 ... and dumps the directory before failing"
dump_line="$(printf '%s\n' "${boot_source}" | grep -n 'wf_dev_dump /dev' | head -n 1 | cut -d: -f1)"
fail_line="$(printf '%s\n' "${boot_source}" | grep -n 'wf_fail dev-contract' | head -n 1 | cut -d: -f1)"
assert_eq "$([ "${dump_line}" -lt "${fail_line}" ] && echo before)" "before" \
    "ac-5 the listing is in the log before the poweroff"

# --------------------------------------------------------------------------- #
# ac-9 the comments say what is true
# --------------------------------------------------------------------------- #

assert_eq "$(printf '%s\n' "${wf_source}" | grep -c 'only the two nodes the kernel unpacks')" "0" \
    "ac-9 the claim that the kernel unpacks console and null out of our archive is gone"
assert_eq "$(printf '%s\n' "${wf_source}" | grep -c 'devtmpfs when the kernel has it')" "0" \
    "ac-9 ... and so is 'devtmpfs when the kernel has it'"
assert_eq "$(printf '%s\n' "${boot_source}" | grep -c 'devtmpfs when the kernel has it')" "0" \
    "ac-9 ... in the boot init too"
assert_contains "${wf_source}" "mount -t devtmpfs fails with ENODEV" \
    "ac-9 the comment states the measured reason instead"
assert_contains "${wf_source}" "dups PID1's stdin/stdout/stderr from that inode" \
    "ac-9 ... and names the kernel's initramfs as the owner of /dev/console"
assert_contains "$(cat "${s1_init}")" "this kernel has no devtmpfs" \
    "ac-9 the S1 probe says the same thing in its own words"
