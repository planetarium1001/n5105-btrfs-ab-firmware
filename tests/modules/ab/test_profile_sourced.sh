#!/usr/bin/env bash
# Module: ab
# Verifies the rule that keeps a `/etc/profile.d` snippet from ending a login session.
#
# `/etc/profile` *sources* every `/etc/profile.d/*.sh`, so a snippet is not a process of
# its own: it runs inside the shell the user is about to type into, and an `exit` in it
# ends that shell. Measured on the n5105 on 2026-11-17 (task 20261117-02): `sh -l -c
# 'echo AFTER'` printed nothing, SSH printed the banner and then closed the connection,
# and the console would not give out a shell on the first Enter - because
# `ab-degraded.sh` ended a healthy boot with `... || exit 0`, and the caller was the login
# shell itself.
#
# The guard covers the whole directory and not just that one file: the next snippet with an
# `exit` breaks logins the same way, and it does not look like a bug in profile.d - it
# looks like a login that dies.
#
#   guard-1 no snippet reaches an `exit` on the sourced path. The one exit that must
#           remain is the one inside the branch that asks whether the file is being
#           sourced: `sh <file>` still has to report status 0 as a program, so that branch
#           is where an `exit` is allowed to live.
#   guard-2 every snippet is sourceable at all: `sh -c '. <file>; echo ALIVE'` prints
#           ALIVE and returns 0, both when the snippet cannot judge the boot and on a
#           degraded one.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

snippets_dir="$root/platform/etc/profile.d"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

shopt -s nullglob
snippets=("$snippets_dir"/*.sh)
shopt -u nullglob

if [[ ${#snippets[@]} -eq 0 ]]; then
  echo "guard-0 no *.sh in $snippets_dir - the guard would pass vacuously" >&2
  exit 1
fi

# bare_exits <file>: every `exit` the file can reach, as `line: text`, empty when there is
# none on a path the sourcing shell could take. A comment is not a command, and only the
# command word of each `;`- / `&&`- / `||`- / `|`-separated command is looked at, so
# `... || exit 0` is caught while a string that merely says `exit` is not. An `exit`
# inside a block opened by a sourcedness test (`${0##*/}`, `BASH_SOURCE`, a `return 0`
# probe) is the one allowed shape, because that block is exactly what a sourced snippet
# skips.
bare_exits() {
  awk '
    {
      line = $0
      if (line ~ /^[[:space:]]*#/) next

      gsub(/;/, "\n", line)
      gsub(/&&/, "\n", line)
      gsub(/\|\|/, "\n", line)
      gsub(/\|/, "\n", line)

      n = split(line, piece, "\n")
      for (i = 1; i <= n; i++) {
        p = piece[i]
        sub(/^[[:space:]]+/, "", p)
        sub(/[[:space:]]+$/, "", p)
        if (p == "") continue
        word = p
        sub(/[[:space:]].*$/, "", word)

        if (word == "if" || word == "case" || word == "for" || word == "while" || word == "until") {
          open++
          if (p ~ /0##\*|_ab_sourced|BASH_SOURCE|return 0 2>/) guarded[open] = 1
          else guarded[open] = 0
          continue
        }
        if (word == "fi" || word == "esac" || word == "done") {
          if (open > 0) open--
          continue
        }
        if (word == "exit") {
          g = 0
          for (d = 1; d <= open; d++) if (guarded[d]) g = 1
          if (!g) printf "%d: %s\n", FNR, p
        }
      }
    }
  ' "$1"
}

# --------------------------------------------------------------------------- #
# guard-1: no exit on the sourced path
# --------------------------------------------------------------------------- #

# The detector itself has to be able to fail: a guard that cannot see the shape that broke
# the device would keep passing while the next snippet reintroduces it.
sample="$tmp/healthy-boot.sh"
printf '#!/bin/sh\n[ "${boot}" = degraded ] || exit 0\n' >"$sample"
assert_contains "$(bare_exits "$sample")" "exit 0" \
  "guard-1 the detector still sees the \`... || exit 0\` that ended every login"

for snippet in "${snippets[@]}"; do
  name=${snippet##*/}
  assert_eq "$(bare_exits "$snippet")" "" \
    "guard-1 ${name} has no exit on the sourced path: /etc/profile dots this file, so an exit in it ends the login shell, not the file (2026-11-17: ssh printed the banner and hung up)"
done

# --------------------------------------------------------------------------- #
# guard-2: the snippets can be sourced, in the states they have to survive
# --------------------------------------------------------------------------- #

esp="$tmp/esp"
mkdir -p "$esp"
cmdline="$tmp/cmdline"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

# A stand-in for `ab-slot`: the answers a snippet can be handed, without a device.
fake_slot="$tmp/ab-slot"
cat >"$fake_slot" <<'SLOT'
#!/bin/sh
printf 'slot=a upper=@overlay-25.12.3 generation=1 committed=a pending=- boot=%s\n' "${AB_FAKE_BOOT}"
SLOT
chmod +x "$fake_slot"

sourced_run() { # <snippet> <slot-bin> <fake-boot>; sets: out, rc
  out=$(AB_ESP="$esp" AB_CMD="$cmdline" AB_SLOT_BIN="$2" AB_FAKE_BOOT="$3" \
    sh -c '. "$1"; echo ALIVE' sh "$1" 2>"$tmp/err-sourced")
  rc=$?
}

for snippet in "${snippets[@]}"; do
  name=${snippet##*/}
  for boot in absent degraded; do
    if [[ "$boot" == absent ]]; then
      sourced_run "$snippet" "$tmp/no-such-ab-slot" ""
      label="a boot it cannot judge"
    else
      sourced_run "$snippet" "$fake_slot" "degraded"
      label="a degraded boot"
    fi
    assert_eq "$rc" "0" "guard-2 ${name} leaves the caller with status 0 on ${label}"
    assert_eq "$out" "ALIVE" \
      "guard-2 ${name} does not end the shell that sourced it on ${label}"
  done
done

finish
