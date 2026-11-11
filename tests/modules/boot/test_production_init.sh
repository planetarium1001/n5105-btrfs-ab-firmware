#!/usr/bin/env bash
# Module: boot
# Which program becomes PID 1 in the composed root. The CI assertion (initramfs/boot/post.sh)
# enters an initramfs only when the build sets AB_CI_HOOKS=1; the image a machine is flashed
# with carries no hook at all, and until this was conditional the init powered off every
# production boot at `cp /s3-post.sh /newroot/.s3-post || wf_fail`.
#   ac-10 a production /init carries no unconditional copy of /s3-post.sh, the switch_root
#         target without the hook is /sbin/init, and there is no branch anywhere that turns
#         "the hook is absent" into a failure - the absence is the production build
#
# The decision is exercised, not just grepped: handover_cmd is lifted out of the init and run
# against a temporary composed root, so both builds are described by what they hand over.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

boot_init="$root/initramfs/boot/init"
init_src="$(cat "$boot_init")"

# --------------------------------------------------------------------------- #
# ac-10 the source: the copy is conditional, the fallback is the composed root
# --------------------------------------------------------------------------- #

assert_contains "$init_src" 'WF_POST_HOOK="${WF_POST_HOOK:-/s3-post.sh}"' \
  "ac-10 the hook path exists exactly once, in a variable a test can override"
assert_eq "$(printf '%s\n' "$init_src" | grep -c 'cp /s3-post.sh /newroot/.s3-post')" "0" \
  "ac-10 the unconditional copy is gone from the boot path"
assert_eq "$(printf '%s\n' "$init_src" | grep -c 'post-script-stage-failed')" "0" \
  "ac-10 ... and with it the failure branch that powered off a production boot"
assert_contains "$init_src" "[ -f \"\${WF_POST_HOOK}\" ]" \
  "ac-10 the copy is guarded by the hook actually being in the initramfs"
assert_contains "$init_src" '/sbin/init' \
  "ac-10 the composed root's own init is the documented fallback"
assert_contains "$(cat "$root/initramfs/boot/post.sh")" 'not the CI probe entry' \
  "ac-10 the hook itself refuses to act when it is not the probe entry"

# No `wf_fail` may be reachable from the hook at all: the absence of the CI assertion, or a
# staging failure, must not power the machine off. (The other wf_fail calls in the tail of the
# boot - a /proc that cannot be moved, a switch_root that returned - are about something else
# and stay.)
assert_eq "$(printf '%s\n' "$init_src" | grep 'wf_fail' | grep -vE '^[[:space:]]*#' \
  | grep -Ec 'post|hook|s3' || true)" "0" \
  "ac-10 no failure branch is reached by an absent or unstaged hook"
handover_fn="$(printf '%s\n' "$init_src" | awk '/^handover_cmd\(\) \{/,/^\}/')"
assert_eq "$(printf '%s\n' "$handover_fn" | grep -c 'wf_fail' || true)" "0" \
  "ac-10 the handover itself reports a staging failure, it does not fail the boot"

# --------------------------------------------------------------------------- #
# ac-10 the decision, run
# --------------------------------------------------------------------------- #

# handover_cmd is lifted out of the init verbatim: it is the code that decides, so testing a
# copy of the rule would prove nothing about the shipped file.
handover_src="$(printf '%s\n' "$init_src" | awk '/^handover_cmd\(\) \{/,/^\}/')"
assert_contains "$handover_src" 'switch_root %s /sbin/init' \
  "ac-10 the function carries the production target"
eval "$handover_src"

newroot="$tmp/newroot"
mkdir -p "$newroot/sbin" "$newroot/bin" "$newroot/etc"
printf '#!/bin/sh\n' >"$newroot/sbin/init"
chmod 0755 "$newroot/sbin/init"

# Production: no hook in the initramfs.
WF_POST_HOOK="$tmp/no-such-hook"
export WF_POST_HOOK
out="$(handover_cmd "$newroot" a @overlay-25.12.3 1)"
assert_eq "$?" "0" "ac-10 a missing hook is not an error"
assert_eq "$out" "switch_root ${newroot} /sbin/init" \
  "ac-10 without the hook the composed root's /sbin/init is PID 1"
assert_eq "$(find "$newroot" -name '.s3-post' | wc -l | tr -d ' ')" "0" \
  "ac-10 ... and nothing is staged into the composed root"

# CI: the build injected the hook, and it becomes the new /init with the three arguments the
# assertion needs.
hook="$tmp/s3-post.sh"
printf '#!/bin/sh\n# the CI probe\n' >"$hook"
WF_POST_HOOK="$hook"
export WF_POST_HOOK
out="$(handover_cmd "$newroot" a @overlay-25.12.3 1)"
assert_eq "$?" "0" "ac-10 a hook that is there is staged"
assert_eq "$out" "switch_root ${newroot} /bin/sh /.s3-post a @overlay-25.12.3 1" \
  "ac-10 with the hook the assertion runs inside the composed root, with its arguments"
assert_file_exists "$newroot/.s3-post" "ac-10 the hook is copied into the composed root"
assert_eq "$(ls -l "$newroot/.s3-post" | cut -c1-10)" "-rwxr-xr-x" \
  "ac-10 ... and made executable, because switch_root runs it"
assert_eq "$(cat "$newroot/.s3-post")" "$(cat "$hook")" \
  "ac-10 ... byte for byte, so the assertion that runs is the one the build injected"

# A hook that cannot be staged must not decide the boot either: the caller falls back to
# /sbin/init instead of powering off. Asserted on the caller, because that is where the
# fallback lives. A composed root that is not there is the one copy failure that is
# reproducible whatever the test runs as.
rm -rf "$newroot/.s3-post"
out="$(handover_cmd "$tmp/missing/newroot" b @overlay-25.12.2 2)"
rc=$?
assert_eq "$rc" "1" "ac-10 a hook that cannot be copied reports it instead of pretending"
assert_eq "$out" "" "ac-10 ... and prints no switch_root line for the caller to run"
assert_contains "$init_src" 'handover="switch_root' \
  "ac-10 the caller has a fallback command of its own"

# --------------------------------------------------------------------------- #
# ac-10 the decision stays free of the breadcrumbs' bookkeeping
# --------------------------------------------------------------------------- #

assert_eq "$(printf '%s\n' "$handover_src" | grep -c 'wf_mark' || true)" "0" \
  "ac-10 the handover decision does not depend on a breadcrumb write"
assert_contains "$init_src" 'wf_mark switching-root' \
  "ac-10 the last milestone is written before the switch, whatever the target is"

finish
