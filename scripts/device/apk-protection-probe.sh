#!/bin/sh
# Does apk's protected-path list actually keep this project's upgrade adapter out of the
# upper layer?
#
# The prevention is /etc/apk/protected_paths.d/ab-upgrade-adapter.list (the upstream
# sysupgrade paths, hand-written) plus ab-platform-shadow.list (derived at build time from
# the layer's own files that a package owns). Both use `+` rules. `apk-protected_paths(5)`
# defines `+` as "protect matching paths only if the file's checksum does not match the one
# in the apk database", so the rule's premise is a fact that can be asked for:
#
#   apk audit --backup | grep '^U '
#
# A path this layer ships has to appear in that list: if apk sees it as unmodified, the
# `+` rule does not fire and apk will overwrite it, putting an upper copy in front of the
# layer. A path the layer does not ship is *supposed* to be upgraded by apk, so it is
# reported but not required.
#
# The premise is checkable on any boot. The proof - a real transaction writing the package
# copy as `*.apk-new` - needs an upgrade candidate, and a baseline that is already the
# newest release has none. That is why this probe is a command and not a one-off
# measurement: run it before and after the next real `apk upgrade`, and the two outputs
# together are the evidence.
#
# Usage:
#   scripts/device/apk-protection-probe.sh            # report, exit 1 on a broken premise
#   scripts/device/apk-protection-probe.sh --json     # one JSON object per line
#
# Exit codes: 0 premise holds, 1 premise broken, 2 the device could not be read.
#
# Inputs (environment):
#   AB_HOST         device to read (default root@192.168.2.49)
#   AB_KEY          private key, when the device needs one
#   AB_PROBE_INPUT  replay a recorded device report instead of contacting one. The report
#                   is the text this script prints for `--json`, one `kind value state`
#                   line per entry as produced by the remote pass. This is how the
#                   judgement is tested without a device: the parser under test is the
#                   real one, not a copy of it.
#   AB_LAYER_PATHS  space separated paths this platform layer replaces, i.e. the ones apk
#                   must see as modified and must never shadow. The default is the repo
#                   fact: platform/lib/upgrade/ ships platform.sh and packages.sh, and
#                   packages.sh is not owned by any package, so only platform.sh is both.
#
# The device driver scripts in scripts/device are POSIX sh, because scripts/ci/verify.sh
# lints them that way: they run on a workstation but they decide whether the machine on the
# bench keeps a bootable slot, and one dialect everywhere is what keeps that check honest.
set -eu

AB_HOST="${AB_HOST:-root@192.168.2.49}"
AB_LAYER_PATHS="${AB_LAYER_PATHS:-lib/upgrade/platform.sh}"
json="false"
case "${1:-}" in
    --json) json="true" ;;
    -h | --help | help)
        # `$0` is this script, the file `sed` reads, so the help text cannot drift from the
        # code that prints it. One `sed` and not `sed | sed`: the status of a pipeline is
        # its last command's, so an unreadable `$0` would be reported by neither half.
        sed -n -e '2,33{s/^# \{0,1\}//;p;}' "$0"
        exit 0
        ;;
    "") ;;
    *)
        echo "apk-protection-probe: unknown argument: $1" >&2
        exit 2
        ;;
esac

# The device changes its host key when it is reflashed; docs/device-matrix.md records why
# this repository does not pin it.
ssh_cmd() {
    # shellcheck disable=SC2086 # the key is a path, deliberately word-split when set
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10 \
        ${AB_KEY:+-i "${AB_KEY}"} "${AB_HOST}" "$@"
}

if [ -n "${AB_PROBE_INPUT:-}" ]; then
    # Replay: the caller recorded a device report (a test fixture, or `--json` output saved
    # from a real run). Nothing is contacted and nothing is written.
    [ -f "${AB_PROBE_INPUT}" ] || {
        echo "apk-protection-probe: replay input not found: ${AB_PROBE_INPUT}" >&2
        exit 2
    }
    # Either of this script's own outputs replays. The `--json` form is one object per line,
    # so it is unfolded here into the same `kind value...` lines the remote pass prints; the
    # human report already has that shape and passes through untouched.
    output="$(sed -n 's/^{"kind":"\([^"]*\)","value":"\(.*\)"}$/\1 \2/p' "${AB_PROBE_INPUT}")"
    if [ -z "${output}" ]; then
        output="$(cat "${AB_PROBE_INPUT}")"
    fi
elif ! output="$(ssh_cmd "set -u
    layer_paths='${AB_LAYER_PATHS}'

    echo \"adapter-rules \$(grep -c '^+' /etc/apk/protected_paths.d/ab-upgrade-adapter.list 2>/dev/null || echo 0)\"
    echo \"shadow-rules \$(grep -c '^+' /etc/apk/protected_paths.d/ab-platform-shadow.list 2>/dev/null || echo 0)\"

    # Every rule the device actually carries, so the report covers paths this probe does
    # not know about by name.
    rules=\"\$(cat /etc/apk/protected_paths.d/*.list 2>/dev/null | sed -n 's/^+//p' | sort -u)\"
    modified=\"\$(apk audit --backup 2>/dev/null | sed -n 's/^U //p' | tr '\\n' ' ')\"
    echo \"rules \$(printf '%s' \"\${rules}\" | tr '\n' ' ')\"

    for rel in \${rules}; do
        case \" \${modified} \" in
            *\" \${rel} \"*) state=modified ;;
            *) state=unmodified ;;
        esac
        required=no
        case \" \${layer_paths} \" in
            *\" \${rel} \"*) required=yes ;;
        esac
        echo \"rule \${rel} \${state} required=\${required}\"
    done

    # The booted upper is not the path /proc/mounts names (that one belongs to the
    # initramfs); ab-slot reports the live overlay name, and the candidate is confirmed by
    # holding a copy of a file this boot wrote. busybox has no stat, so ls -i is used.
    want=\"\$(ab-slot status 2>/dev/null | sed -n 's/.*upper=\([^ ]*\).*/\1/p' | head -n 1)\"
    # A file this boot certainly wrote: the boot seed and the feed list both live in the
    # upper layer on a running system, while the layer's own protected-path lists do not.
    probe=/etc/apk/repositories.d/distfeeds.list
    vis_ino=\"\$(ls -i \"\${probe}\" 2>/dev/null | awk '{print \$1}')\"
    upper=''
    for cand in \$(awk '\$2 == \"/\" && \$3 == \"overlay\" { for (i = 1; i <= NF; i++) if (\$i ~ /^upperdir=/) { sub(/^upperdir=/, \"\", \$i); print \$i } }' /proc/mounts) \
                /mnt/*/\"\${want}\"/upper /mnt/*/upper; do
        [ -d \"\${cand}\" ] || continue
        up_ino=\"\$(ls -i \"\${cand}\${probe}\" 2>/dev/null | awk '{print \$1}')\"
        if [ -n \"\${vis_ino}\" ] && [ \"\${vis_ino}\" = \"\${up_ino}\" ]; then upper=\"\${cand}\"; break; fi
    done
    echo \"upper \${upper:-unresolved}\"
    if [ -n \"\${upper}\" ]; then
        for rel in \$(printf '%s' \"\${rules}\"); do
            [ -e \"\${upper}/\${rel}\" ] && echo \"shadow \${rel} present\" || echo \"shadow \${rel} absent\"
        done
    fi
    echo \"apk-new \$(find /lib/upgrade /etc/apk -name '*.apk-new' 2>/dev/null | wc -l | tr -d ' ')\"
    # Counted only where this project's rules and adapter live: /etc/apk also carries
    # unrelated historical leftovers (11 of them on the 0.0.11 device), so a whole-machine
    # count would look like a regression when the next upgrade touched one of those.
    echo \"apk-new-scope /lib/upgrade /etc/apk\"
    echo \"version \$(apk --version 2>/dev/null | head -n 1)\"
" 2>&1)"; then
    echo "apk-protection-probe: could not read ${AB_HOST}" >&2
    printf '%s\n' "${output}" >&2
    exit 2
fi

unprotected=""
shadowed=""
required=0
upper=""
upper_state="missing"
# The report goes through a file, not a here-string: POSIX sh has no `<<<`, and a pipe
# would run the loop in a subshell, where `unprotected`, `shadowed` and `required` would be
# accumulated and then thrown away - the judgement would always answer "premise holds",
# which is the one answer this probe must never invent. `printf '%s\n'` appends exactly the
# newline `<<<` appends, so the sequence of lines `read` sees is unchanged.
probe_tmp="$(mktemp "${TMPDIR:-/tmp}/ab-apk-probe.XXXXXX")" || {
    echo "apk-protection-probe: cannot create a temporary file in ${TMPDIR:-/tmp}" >&2
    exit 2
}
trap 'rm -f "${probe_tmp}"' EXIT
# An interrupted run must not leave the file behind, and it must still exit the way an
# untrapped shell would (128 + the signal), so the EXIT trap above does the removing.
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "${output}" >"${probe_tmp}"
while read -r kind a b c; do
    [ -n "${kind:-}" ] || continue
    case "${kind}" in
        adapter-rules | shadow-rules | rules | upper | apk-new | apk-new-scope | version | rule | shadow) ;;
        *)
            # A summary sentence from a human report is not an entry: it is what the report
            # said about the entries. Echoing it as an object would make a `--json` replay
            # produce a file that cannot be replayed again.
            continue
            ;;
    esac
    case "${kind}" in
        rule)
            case "${b}" in
                modified) ;;
                *)
                    case " ${c:-} " in
                        *" required=yes "*) unprotected="${unprotected} ${a}" ;;
                    esac
                    ;;
            esac
            case " ${c:-} " in *" required=yes "*) required=$((required + 1)) ;; esac
            ;;
        upper)
            upper="${a}"
            case "${a}" in
                "" | unresolved) upper_state="unresolved" ;;
                *) upper_state="resolved" ;;
            esac
            ;;
        shadow)
            [ "${b:-}" = "present" ] && shadowed="${shadowed} ${a}"
            ;;
    esac
    if [ "${json}" = "true" ]; then
        # The whole remainder is the value: a report line's shape is `kind rest...`, and
        # splitting it again here would cut "apk-tools 3.0.5, compiled for x86_64." in half.
        [ -n "${b:-}" ] && a="${a} ${b} ${c:-}"
        printf '{"kind":"%s","value":"%s"}\n' "${kind}" "${a}"
    else
        case "${kind}" in
            rule) printf 'rule     %-28s %-11s %s\n' "${a}" "${b}" "${c:-}" ;;
            shadow) printf 'shadow   %-28s %s\n' "${a}" "${b}" ;;
            *) printf '%-8s %s\n' "${kind}" "${a} ${b:-} ${c:-}" ;;
        esac
    fi
done <"${probe_tmp}"

if [ "${json}" != "true" ]; then
    echo
    if [ "${upper_state}" != "resolved" ]; then
        # Fail closed. Without the writable layer there is no way to say "no shadow", and a
        # probe that answers "premise holds" because it could not look is the one failure
        # mode this task exists to remove.
        echo "premise unknown: the writable layer could not be resolved (upper='${upper:-}')" >&2
        echo "  looked in: the /proc/mounts upperdir, and /mnt/*/<upper>/upper for the name" >&2
        echo "  ab-slot reports. The live upper is confirmed by inode; if the file that check" >&2
        echo "  compares moved, there is nothing to confirm it with." >&2
    elif [ "${required}" -eq 0 ]; then
        echo "premise unknown: no rule names a path this layer replaces" >&2
    elif [ -z "${unprotected}" ] && [ -z "${shadowed}" ]; then
        echo "premise holds: apk sees all ${required} layer-owned path(s) as modified, so the"
        echo "'+ rules protect them, and the writable layer (${upper}) carries none of them"
        echo "next: re-run this after the next real 'apk upgrade'; the proof is that apk-new"
        echo "      goes up while 'shadow' stays absent"
    else
        [ -z "${unprotected}" ] || echo "premise broken:${unprotected} (apk sees these as unmodified, so nothing protects them)" >&2
        [ -z "${shadowed}" ] || echo "shadow present:${shadowed} (already an upper copy in front of the layer)" >&2
    fi
fi

[ "${upper_state}" = "resolved" ] && [ "${required}" -gt 0 ] \
    && [ -z "${unprotected}" ] && [ -z "${shadowed}" ]
