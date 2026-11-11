#!/usr/bin/env bash
# Module: device
# Exercises scripts/device/scenarios.sh against a simulated apk machine: a stub `ssh`
# answers with canned output and keeps state in a directory, so every judgement below is
# about parsing, verdicts and step order rather than about hardware.
#   ac-4 a package that cannot be installed is recorded as unavailable, never as a failure
#   ac-4 a kmod built for a kernel the machine no longer runs is a FINDING, not a FAIL
#   ac-4 a data file whose hash moved is a FAIL that names the file
#   ac-4 ssh lost after the network reload is a FAIL, after the machine reverts itself
#   ac-4 the ESP kernel/initramfs and the platform layer tool are compared with the payload
#        byte for byte, and tools newer than the rootfs are a FINDING, never a FAIL
#   ac-4 --dry-run prints the steps in order and names a missing payload before a run does
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

stub_bin="$tmp/bin"
FAKE_DEV="$tmp/device"
STUB_CALLS="$tmp/calls.log"
mkdir -p "$stub_bin"
: >"$STUB_CALLS"
export FAKE_DEV STUB_CALLS
export PATH="$stub_bin:$PATH"

# --- the stub machine ------------------------------------------------------- #
# The device command is the last argument, which is how ssh itself passes it on. The
# simulator below keeps the state files the driver reads (`committed`, `pending`,
# `generation`, `uci`, ...) so the same code path runs for a passed and a failed case.
cat >"$stub_bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
last=""
for a in "$@"; do last=$a; done
dev=${FAKE_DEV:?stub needs FAKE_DEV}

# A machine whose network change took the session away answers nothing at all, which is
# what "ssh is down" looks like from the driver's side.
if [ -f "$dev/sshdead" ]; then exit 255; fi

uci_set() { # <key> <value>
    if [ -f "$dev/uci" ]; then grep -v "^$1=" "$dev/uci" >"$dev/uci.tmp" 2>/dev/null; else : >"$dev/uci.tmp"; fi
    printf '%s=%s\n' "$1" "$2" >>"$dev/uci.tmp"
    mv "$dev/uci.tmp" "$dev/uci"
}
uci_get() { sed -n "s/^$1=//p" "$dev/uci" 2>/dev/null | head -n 1; }

slot=$(cat "$dev/committed")
if [ "$slot" = "a" ]; then other=b; else other=a; fi
pending=$(cat "$dev/pending")

case "${last}" in
    "true")
        exit 0
        ;;
    "ab-slot status")
        if [ "$pending" = "none" ]; then next=${slot}; else next=${pending}; fi
        printf 'slot=%s upper=%s generation=%s committed=%s pending=%s p4=%s data=%s docker=ok swap=ok next=%s disk=/dev/nvme0n1 method=partname boot=%s esp=%s\n' \
            "${slot}" "$(cat "$dev/upper-${slot}")" "$(cat "$dev/generation")" "${slot}" "${pending}" \
            "$(cat "$dev/p4")" "$(cat "$dev/data")" "${next}" "$(cat "$dev/boot")" "$(cat "$dev/esp")"
        ;;
    "ab-slot rootfs")
        cat "$dev/rootfs-${slot}"
        ;;
    "btrfs subvolume list /mnt/p4")
        printf 'ID 256 gen 10 top level 5 path %s\n' "$(cat "$dev/upper-a")"
        printf 'ID 257 gen 11 top level 5 path %s\n' "$(cat "$dev/upper-b")"
        ;;
    "cat /boot/ab/state.json")
        if [ "$pending" = "none" ]; then pend=null; else pend="\"${pending}\""; fi
        printf '{"generation": %s, "committed": "%s", "pending": %s, "slots": {"a": {"rootfs": "%s", "upper": "%s"}, "b": {"rootfs": "%s", "upper": "%s"}}}\n' \
            "$(cat "$dev/generation")" "${slot}" "${pend}" \
            "$(cat "$dev/rootfs-a")" "$(cat "$dev/upper-a")" \
            "$(cat "$dev/rootfs-b")" "$(cat "$dev/upper-b")"
        ;;
    "for d in /mnt/slots/a"*)
        exit 0
        ;;
    "sync; reboot")
        if [ "$pending" != "none" ]; then
            printf '%s' "$pending" >"$dev/committed"
            printf 'none' >"$dev/pending"
        fi
        printf '%s' "${FAKE_BOOT_AFTER:-ok}" >"$dev/boot"
        ;;
    "ab-upgrade --check "*)
        ver=$(printf '%s' "$last" | sed -e 's|.*/payload-||' -e 's|\.tar$||')
        if [ "$ver" = "$(cat "$dev/rootfs-${slot}")" ]; then
            printf 'ab-upgrade: refused, reason=payload-already-installed\n'
            exit 74
        fi
        printf 'ab-upgrade: %s validated\n' "$ver"
        ;;
    "ab-upgrade "*)
        ver=$(printf '%s' "$last" | sed -e 's|.*/payload-||' -e 's|\.tar$||')
        printf '%s' "$ver" >"$dev/rootfs-${other}"
        printf '@overlay-%s' "$ver" >"$dev/upper-${other}"
        printf '%s' "$other" >"$dev/pending"
        printf '%s' "$(( $(cat "$dev/generation") + 1 ))" >"$dev/generation"
        ;;
    "cat > "*)
        # dev_push: the guest has no sftp-server, the bytes arrive on stdin.
        f=$(printf '%s' "$last" | sed -e 's|^cat > ||')
        cat >"$dev/$(basename "$f")"
        ;;
    "cat "*)
        f=$(printf '%s' "$last" | sed -e 's|^cat ||')
        cat "$dev/$(basename "$f")" 2>/dev/null || exit 1
        ;;
    "sh "*ab-scen-helper.sh*)
        # A reboot on an image whose helper lives on tmpfs leaves nothing to run: the shell
        # exits non-zero with no output, which is the answer this stub reproduces.
        if [ "${FAKE_HELPER_MISSING:-0}" = "1" ]; then exit 127; fi
        # sh <helper> <sub> <args...>: dispatch the same subcommands the real helper has.
        rest=$(printf '%s' "$last" | sed -e 's|^sh [^ ]* ||')
        sub=${rest%% *}
        args=${rest#"$sub"}
        set -f
        set -- $args
        case "$sub" in
            probe)
                # The helper answers mount points, not ab-slot's ok/short fields: a machine
                # whose /data is not a mount point says so here and everywhere else stays ok.
                dm=missing
                [ "$(cat "$dev/data")" = "ok" ] && dm=mounted
                pm=missing
                [ "$(cat "$dev/p4")" = "ok" ] && pm=mounted
                printf 'kver=%s\nkernel_dirs=1\napk=%s\ndata=%s\np4=%s\nhash=sha256sum\nhelper=1\n' \
                    "$(cat "$dev/kver")" "$(cat "$dev/apk")" "$dm" "$pm"
                ;;
            mkdirs)
                for d in "$@"; do printf 'mkdir=%s ok=yes\n' "$d"; done
                ;;
            pkginstall)
                if grep -qx "$1" "$dev/pkgfail" 2>/dev/null; then
                    printf 'pkg=%s state=unavailable rc=1 err=ERROR: unable to select packages:\n' "$1"
                else
                    printf 'pkg=%s state=installed rc=0 version=%s-1.0-r0\n' "$1" "$1"
                fi
                ;;
            pkgsnap)
                printf 'snap=%s count=%s\n' "$1" "${FAKE_SNAP_COUNT:-42}"
                ;;
            pkgcheck)
                printf 'pkg=%s present=%s version=%s-1.0-r0 file=/usr/bin/%s fileok=%s\n' \
                    "$1" "${FAKE_PRESENT:-yes}" "$1" "$1" "${FAKE_FILEOK:-yes}"
                ;;
            kmodcheck)
                printf 'kmod=%s state=%s kver=%s version=%s-1.0-r0 modver=%s depver=%s\n' \
                    "$1" "${FAKE_KMOD_STATE:-match}" "$(cat "$dev/kver")" "$1" \
                    "${FAKE_KMOD_MODVER:-$(cat "$dev/kver")}" "${FAKE_KMOD_DEPVER:-$(cat "$dev/kver")}"
                ;;
            exec)
                printf 'cmd=%s rc=%s out=stub\n' "$*" "${FAKE_EXEC_RC:-0}"
                ;;
            seed)
                printf 'seed=%s rc=%s files=9 dirs=5\n' "$2" "${FAKE_SEED_RC:-0}"
                ;;
            hash)
                cat "$dev/hash-now" 2>/dev/null || { printf 'tool=sha256sum\nfiles=0\ndirs=0\n' ; }
                ;;
            tartest)
                for f in "$@"; do printf 'tar=%s rc=%s members=2\n' "$f" "${FAKE_TAR_RC:-0}"; done
                ;;
            cfg-backup)
                bak=$1
                shift
                n=0
                for f in "$@"; do
                    n=$((n + 1))
                    printf 'backup=%s -> %s ok=yes\n' "$f" "$bak"
                done
                printf 'backups=%s of=%s\n' "${FAKE_BACKUPS:-$n}" "$n"
                ;;
            cfg-write)
                uci_set abscen "$2"
                printf 'cfg=%s commit_rc=0 label=%s\n' "$1" "$2"
                ;;
            cfg-system)
                uci_set hostname "$1"
                uci_set timezone "$2"
                uci_set zonename "$3"
                printf 'system commit_rc=0 hostname=%s timezone=%s zonename=%s running=%s\n' "$1" "$2" "$3" "$1"
                ;;
            cfg-net)
                uci_set netsec "${FAKE_NET_SEC:-yes}"
                printf 'net=%s proto=%s commit_rc=0\n' "$1" "${FAKE_NET_PROTO:-none}"
                ;;
            cfg-fw)
                uci_set fwrule "${FAKE_FW_RULE:-yes}"
                if [ "${FAKE_FW_REUSE:-0}" = "1" ]; then
                    # The second run of S2 finds the rule it added the first time. The
                    # machine answers with the same keys as the fresh path, which is the
                    # property that makes a re-run judgeable at all.
                    printf 'fwrule=%s already=yes reused=yes sec=cfg0 target=%s src=lan proto=tcp dest_port=9\n' \
                        "$1" "${FAKE_FW_TARGET:-DROP}"
                else
                    printf 'fwrule=%s target=%s commit_rc=0\n' "$1" "${FAKE_FW_TARGET:-DROP}"
                fi
                ;;
            net-apply)
                if [ "${FAKE_WATCHDOG:-yes}" = "no" ]; then
                    # No way to schedule the revert: the machine must not reload at all.
                    printf 'watchdog=no grace=%s confirm=/tmp/ab-scen-net.ok\nnet-reload rc=skipped\n' "$2"
                else
                    printf 'watchdog=yes how=%s grace=%s confirm=/tmp/ab-scen-net.ok\nnet-reload rc=0\n' \
                        "${FAKE_WATCHDOG_HOW:-setsid}" "$2"
                    if [ "${FAKE_BREAK_NET:-0}" = "1" ]; then : >"$dev/sshdead"; fi
                fi
                ;;
            net-confirm)
                printf 'confirm=ok\n'
                ;;
            net-rollback)
                rm -f "$dev/sshdead"
                printf 'rollback=done restored=2\n'
                ;;
            cfg-read)
                printf 'abscen=%s\nhostname=%s\ntimezone=%s\nzonename=%s\nnetsec=%s\nfwrule=%s\n' \
                    "$(uci_get abscen)" "$(uci_get hostname)" "$(uci_get timezone)" \
                    "$(uci_get zonename)" "$(uci_get netsec)" "$(uci_get fwrule)"
                ;;
            overlay-probe)
                printf 'target=/overlay write=%s\n' "${FAKE_OVERLAY:-rw}"
                ;;
            svc-cycle)
                printf 'svc=%s state=present stop=%s start=%s\n' "$1" "${FAKE_SVC_STOP:-0}" "${FAKE_SVC_START:-0}"
                ;;
            boottools)
                # The boot chain answer is a fixture: every field is a digest the test
                # computed from a real payload tar, so one field can be moved to watch the
                # judgement follow it.
                cat "$dev/boottools" 2>/dev/null
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod +x "$stub_bin/ssh"

# The driver sleeps between polls; on the test host the only thing that sleep has to do
# is not take five seconds.
printf '#!/bin/sh\nexit 0\n' >"$stub_bin/sleep"
chmod +x "$stub_bin/sleep"

# --- fixtures --------------------------------------------------------------- #

setup_fake_device() { # <version the machine runs>
    rm -rf "$FAKE_DEV"
    mkdir -p "$FAKE_DEV"
    printf 'a' >"$FAKE_DEV/committed"
    printf 'none' >"$FAKE_DEV/pending"
    printf '3' >"$FAKE_DEV/generation"
    printf 'ok' >"$FAKE_DEV/boot"
    printf 'ok' >"$FAKE_DEV/esp"
    printf 'ok' >"$FAKE_DEV/p4"
    printf 'ok' >"$FAKE_DEV/data"
    printf '6.12.103' >"$FAKE_DEV/kver"
    printf 'yes' >"$FAKE_DEV/apk"
    printf '%s' "$1" >"$FAKE_DEV/rootfs-a"
    printf '@overlay-%s' "$1" >"$FAKE_DEV/upper-a"
    printf '%s' "$1" >"$FAKE_DEV/rootfs-b"
    printf '@overlay-%s' "$1" >"$FAKE_DEV/upper-b"
    printf 'hostname=ImmortalWrt\ntimezone=UTC\nzonename=UTC\nabscen=\nnetsec=no\nfwrule=no\n' >"$FAKE_DEV/uci"
    : >"$FAKE_DEV/pkgfail"
    cat >"$FAKE_DEV/hash-now" <<'HASH'
tool=sha256sum
files=4
dirs=5
H aaa1 big-1.bin
H aaa2 中文文件名-测试.txt
H aaa3 tree/a/one.txt
H aaa4 docker-image-alpine.tar
HASH
    cp "$FAKE_DEV/hash-now" "$FAKE_DEV/data.sha256"
    : >"$STUB_CALLS"
}

# The state S1 and S2 leave behind: the package inventory, the configuration record and
# the uci values that go with it, so a jump case can be run without running S1 and S2.
setup_inventories() {
    printf 'stamp\t2026-11-12T00-00-00Z\nkver\t6.12.103\nsrc\ts1\npkg\tcurl\tcurl-8.5.0-r0\npkg\thtop\thtop-3.3.0-r0\nkmod\tkmod-usb-storage\tkmod-usb-storage-1.0-r0\nprobe\tcurl\t0\n' \
        >"$FAKE_DEV/packages.tsv"
    printf 'stamp\t2026-11-12T00-00-00Z\nkver\t6.12.103\nsrc\ts2\ncfg\tabscen\tab-scenarios-2026-11-12T00-00-00Z\ncfg\thostname\tab-scen-host\ncfg\ttimezone\tCST-8\ncfg\tzonename\tAsia/Shanghai\ncfg\tnetsec\tyes\ncfg\tfwrule\tyes\nbackup\t/data/scen/backup/etc-config-x\nsvc\tuhttpd\nseed\t/data/scen/data\n' \
        >"$FAKE_DEV/config.tsv"
    printf 'hostname=ab-scen-host\ntimezone=CST-8\nzonename=Asia/Shanghai\nabscen=ab-scenarios-2026-11-12T00-00-00Z\nnetsec=yes\nfwrule=yes\n' \
        >"$FAKE_DEV/uci"
}

setup_fake_world() { # <version the machine runs>
    setup_fake_device "$1"
    setup_inventories
}

payloads="$tmp/payloads"
mkdir -p "$payloads"
for v in 25.12.0 25.12.1 25.12.2; do
    printf 'payload %s\n' "$v" >"$payloads/payload-${v}.tar"
done

run_scen_payloads() { # <payload dir> <results dir> [scenarios args...]
    local pdir=$1 dir=$2
    shift 2
    AB_WAIT_UP=4 AB_WAIT_UP_FIRST=4 AB_WAIT_UP_HARD=8 AB_POLL_INTERVAL=1 \
        AB_HOST=root@stub AB_KEY="$tmp/abkey" \
        sh "$root/scripts/device/scenarios.sh" \
        --payload-dir "$pdir" --results "$dir/results.tsv" "$@" 2>&1
}

run_scen() { # <results dir> [scenarios args...]
    local dir=$1
    shift
    run_scen_payloads "$payloads" "$dir" "$@"
}

verdict_of() { awk -F'\t' 'NR == 1 {print $2}' "$1/results.tsv"; }
note_of() { awk -F'\t' 'NR == 1 {print $4}' "$1/results.tsv"; }
evidence_of() { printf '%s/evidence/%s-%s.log' "$1" "$(date -u +%Y%m%d)" "$2"; }

# --- ac-4: a package that cannot be installed is not a failure -------------- #
# The user asked for a batch of packages from the store. One of them is not in the
# repositories on this machine; the answer is "recorded, carried on", not "aborted".
setup_fake_device 25.12.2
printf 'luci-app-ttyd\n' >"$FAKE_DEV/pkgfail"
out=$(run_scen "$tmp/r-s1" --case S1)
assert_eq "$?" "0" "S1 exits zero even though one package could not be installed"
assert_eq "$(verdict_of "$tmp/r-s1")" "PASS" "an unavailable package does not turn the case red"
assert_contains "$(note_of "$tmp/r-s1")" "unavailable: luci-app-ttyd(rc=1:" \
    "the note records the package, its exit status and the first error line"
assert_contains "$(note_of "$tmp/r-s1")" "installed 4/5" "all five packages were attempted and four landed"
assert_contains "$(cat "$FAKE_DEV/packages.tsv")" "unavailable	luci-app-ttyd" \
    "the inventory keeps the unavailable package so the jump cases can report it"
assert_contains "$(cat "$FAKE_DEV/packages.tsv")" "kmod	kmod-usb-storage" \
    "the kmod that did install is in the inventory"
assert_contains "$(cat "$(evidence_of "$tmp/r-s1" s1)")" "preinstall luci-app-ttyd: unavailable rc=1" \
    "the failure line is kept in the evidence, not swallowed"
assert_eq "$(grep -c 'pkginstall' "$STUB_CALLS")" "5" "one apk call per package, no batch that a single failure stops"
assert_eq "$(grep -c 'apk-snapshot' "$STUB_CALLS")" "1" "the full installed set is snapshotted to a file"

# Nothing installable at all: that is a gap in the world, not a broken machine.
setup_fake_device 25.12.2
printf 'luci-app-attendedsysupgrade\nluci-app-ttyd\ncurl\nhtop\nkmod-usb-storage\n' >"$FAKE_DEV/pkgfail"
out=$(run_scen "$tmp/r-s1-gap" --case S1)
assert_eq "$?" "4" "S1 with nothing installable exits with the gap status"
assert_eq "$(verdict_of "$tmp/r-s1-gap")" "GAP" "zero packages and zero kmods is a GAP, not a FAIL"
assert_contains "$(note_of "$tmp/r-s1-gap")" "the scenario needs one of each" "the gap says why it could not judge anything"

# No apk at all: the same gap, named.
setup_fake_device 25.12.2
printf 'no' >"$FAKE_DEV/apk"
out=$(run_scen "$tmp/r-s1-noapk" --case S1)
assert_eq "$?" "4" "a machine without apk is a gap for the preinstall case"
assert_contains "$(note_of "$tmp/r-s1-noapk")" "no apk on this image" "the gap names the reason"

# --- S2: the user's files, config and settings ------------------------------ #
setup_fake_device 25.12.2
out=$(run_scen "$tmp/r-s2" --case S2)
assert_eq "$?" "0" "S2 exits zero when the data lands and ssh stays up"
assert_eq "$(verdict_of "$tmp/r-s2")" "PASS" "S2 records PASS"
calls=$(cat "$STUB_CALLS")
assert_contains "$calls" "seed /tmp/ab-scen-seed.tar /data/scen/data" "the seed tree is pushed as one tar and unpacked on the machine"
assert_contains "$calls" "hash /data/scen/data" "the manifest is taken right after the write"
assert_contains "$calls" "cfg-backup /data/scen/backup/etc-config-" "the configuration is backed up before it is touched"
assert_eq "$(printf '%s\n' "$calls" | grep 'cfg-backup' | grep -o '/etc/config/[a-z]*' | wc -l | tr -d ' ')" "3" \
    "network, firewall and system are all in the backup"
assert_contains "$calls" "cfg-net abscen" "a network section of the user's own is added"
assert_contains "$calls" "cfg-fw abscen-discard" "a firewall rule is added"
assert_contains "$calls" "net-confirm" "the scheduled revert is confirmed away once ssh answers again"
assert_contains "$(cat "$FAKE_DEV/config.tsv")" "cfg	hostname	ab-scen-host" \
    "the inventory records the hostname the machine actually took"
assert_contains "$(cat "$FAKE_DEV/config.tsv")" "cfg	timezone	CST-8" "the inventory records the timezone"
assert_contains "$(cat "$FAKE_DEV/data.sha256")" "H aaa1 big-1.bin" "the manifest is written to /data for a later run"
assert_file_exists "$tmp/r-s2/evidence/scen-data.sha256" "the manifest is also kept host-side, where a jump cannot touch it"
assert_contains "$(cat "$(evidence_of "$tmp/r-s2" s2)")" "ssh alive after the network reload" \
    "the evidence records that ssh was checked right after the reload"

# A backup that did not cover everything is a reason to change nothing at all.
setup_fake_device 25.12.2
export FAKE_BACKUPS=2
out=$(run_scen "$tmp/r-s2-bak" --case S2)
rc=$?
unset FAKE_BACKUPS
assert_eq "$rc" "1" "a partial backup stops the case"
assert_eq "$(verdict_of "$tmp/r-s2-bak")" "FAIL" "a partial backup is a FAIL"
assert_contains "$(note_of "$tmp/r-s2-bak")" "only 2/3" "the note says how much of the backup landed"
assert_eq "$(grep -c 'cfg-write' "$STUB_CALLS" || true)" "0" \
    "no configuration was written when the rollback path was incomplete"

# --- ac-4: ssh lost after the network reload -------------------------------- #
# The machine schedules its own revert before it reloads, because the host cannot send a
# rollback over the connection the reload just broke. Losing ssh is a FAIL and the backup
# is the path back -- both facts have to be in the row and in the evidence.
setup_fake_device 25.12.2
export FAKE_BREAK_NET=1
out=$(run_scen "$tmp/r-s2-net" --case S2)
rc=$?
unset FAKE_BREAK_NET
assert_eq "$rc" "1" "losing ssh after the network reload makes the run non-zero"
assert_eq "$(verdict_of "$tmp/r-s2-net")" "FAIL" "S2 records FAIL when ssh does not come back"
assert_contains "$(note_of "$tmp/r-s2-net")" "ssh lost after applying /etc/config/network" \
    "the note names the change that did it"
assert_contains "$(note_of "$tmp/r-s2-net")" "/data/scen/backup/etc-config-" "the note names the backup to roll back from"
netlog=$(cat "$(evidence_of "$tmp/r-s2-net" s2)")
assert_contains "$netlog" "watchdog=yes" "a revert was scheduled on the machine before the reload"
assert_contains "$netlog" "how=setsid" "the revert is scheduled with a tool this image actually has"
assert_contains "$netlog" "the watchdog restores" "when the host cannot reach the machine, the machine is what restores it"
assert_eq "$(test -f "$FAKE_DEV/config.tsv" && echo yes || echo no)" "no" \
    "no inventory was written after the failed change, so a jump case cannot judge a state the machine does not have"

# The probe table is `name:args` and split on whitespace: a table entry that carries a
# space used to split into two entries, and the case recorded a bare-program usage error
# as the baseline it then compared against.
setup_fake_world 25.12.2
plan=$(sh "$root/scripts/device/scenarios.sh" --dry-run --case S1 --payload-dir "$tmp/payloads" 2>&1)
assert_contains "$plan" "curl --version" "the probe table keeps the argument with its program"
assert_contains "$plan" "htop --version" "the second probe keeps its argument too"

# The helper is a driver artifact, not a fact about the machine. When it does not come
# back after a reboot, the case must say so instead of reporting that the user's data,
# packages and services are gone.
setup_fake_world 25.12.2
setup_inventories
export FAKE_HELPER_MISSING=1
out=$(run_scen "$tmp/r-s3-nh" --case S3)
rc=$?
unset FAKE_HELPER_MISSING
assert_eq "$rc" "1" "a helper that did not survive the reboot stops the case"
assert_eq "$(verdict_of "$tmp/r-s3-nh")" "FAIL" "the case is not recorded as a pass"
assert_contains "$(note_of "$tmp/r-s3-nh")" "driver error" "the note blames the driver, not the machine"
assert_contains "$(cat "$(evidence_of "$tmp/r-s3-nh" s3)")" "helper-unavailable" \
    "the evidence records the helper path that did not answer"

# A scenario has to survive being run twice: the second run finds the section and the rule
# it created the first time, and the reuse path has to answer with the same keys.
setup_fake_device 25.12.2
export FAKE_FW_REUSE=1
out=$(run_scen "$tmp/r-s2-again" --case S2)
rc=$?
unset FAKE_FW_REUSE
assert_eq "$rc" "0" "a second run of S2 passes on the state the first run left"
assert_eq "$(verdict_of "$tmp/r-s2-again")" "PASS" "the reuse path is judged like the fresh one"

# No scheduled revert means no reload: the change is written and not applied, and the
# skipped half of the case is a FINDING rather than a PASS that did not look.
setup_fake_device 25.12.2
export FAKE_WATCHDOG=no
out=$(run_scen "$tmp/r-s2-nowd" --case S2)
rc=$?
unset FAKE_WATCHDOG
assert_eq "$rc" "0" "S2 still passes when the network half had to be skipped"
case "$(note_of "$tmp/r-s2-nowd")" in
    FINDING:*) assert_eq "prefixed" "prefixed" "the skipped half is reported as a FINDING" ;;
    *) assert_eq "prefixed" "not-prefixed" "the skipped half is reported as a FINDING" ;;
esac
assert_contains "$(note_of "$tmp/r-s2-nowd")" "neither setsid nor start-stop-daemon" "the finding says why the reload was skipped"
assert_eq "$(grep -c 'net-confirm' "$STUB_CALLS" || true)" "0" \
    "no confirmation is sent for a reload that never happened"

# --- the jump cases need the state S1 and S2 left -------------------------- #
setup_fake_device 25.12.0
out=$(run_scen "$tmp/r-s3-gap" --case S3)
assert_eq "$?" "4" "a jump with no preinstall snapshot is a GAP"
assert_eq "$(verdict_of "$tmp/r-s3-gap")" "GAP" "missing prerequisite state records GAP"
assert_contains "$(note_of "$tmp/r-s3-gap")" "run --case S1 and --case S2 first" "the gap says what to run"
assert_eq "$(grep -c 'ab-upgrade' "$STUB_CALLS" || true)" "0" "nothing was installed without the state to judge"

mkdir -p "$tmp/payloads-partial"
cp "$payloads/payload-25.12.0.tar" "$tmp/payloads-partial/"
setup_fake_world 25.12.0
out=$(AB_WAIT_UP=4 AB_WAIT_UP_FIRST=4 AB_WAIT_UP_HARD=8 AB_POLL_INTERVAL=1 AB_HOST=root@stub AB_KEY="$tmp/abkey" \
    sh "$root/scripts/device/scenarios.sh" --payload-dir "$tmp/payloads-partial" \
    --results "$tmp/r-s3-nopayload/results.tsv" --case S3 2>&1)
assert_eq "$?" "4" "a missing payload is a gap, not a failure"
assert_contains "$(note_of "$tmp/r-s3-nopayload")" "no payload for 25.12.2" "the gap names the missing artifact"

# --- S3: the upgrade, and everything the user had -------------------------- #
setup_fake_world 25.12.0
out=$(run_scen "$tmp/r-s3" --case S3)
assert_eq "$?" "0" "S3 exits zero when the user's state survives the upgrade"
assert_eq "$(verdict_of "$tmp/r-s3")" "PASS" "S3 records PASS"
assert_eq "$(cat "$FAKE_DEV/committed")" "b" "the upgrade committed the other slot"
assert_eq "$(cat "$FAKE_DEV/rootfs-b")" "25.12.2" "the committed slot carries the high version"
s3log=$(cat "$(evidence_of "$tmp/r-s3" s3)")
assert_contains "$s3log" "data: 4 file(s), 5 dir(s), every hash matches" "the data judgement counts what it compared"
assert_contains "$s3log" "tar ok: docker-image-alpine.tar 2 member(s)" "the fake docker tar still reads as a tar"
assert_contains "$s3log" "config abscen: ab-scenarios-2026-11-12T00-00-00Z" "the custom uci value survived"
assert_contains "$s3log" "software curl: present, /usr/bin/curl exists" "the package is present and so is its file"
assert_contains "$s3log" "abi kmod-usb-storage: matches 6.12.103" "a kmod on its own kernel is recorded as a match"
assert_contains "$s3log" "service uhttpd: stop/start ok" "a service still stops and starts"
case "$(note_of "$tmp/r-s3")" in
    FINDING:*) assert_eq "finding" "none" "a clean jump carries no FINDING" ;;
    *) assert_eq "clean" "clean" "a clean jump carries no FINDING" ;;
esac

# --- ac-4: the kmod ledger ------------------------------------------------ #
# A kmod is built for one kernel. After a jump that changes the kernel the package is
# still installed and no longer loadable: that is a FINDING with a to-do list, and the
# jump itself still passes.
setup_fake_world 25.12.0
export FAKE_KMOD_STATE=stale FAKE_KMOD_MODVER=6.12.103 FAKE_KMOD_DEPVER=6.12.103
out=$(run_scen "$tmp/r-s3-abi" --case S3)
rc=$?
unset FAKE_KMOD_STATE FAKE_KMOD_MODVER FAKE_KMOD_DEPVER
assert_eq "$rc" "0" "a kmod built for the previous kernel does not fail the jump"
assert_eq "$(verdict_of "$tmp/r-s3-abi")" "PASS" "the verdict stays PASS: an ABI change is normal apk behaviour"
note=$(note_of "$tmp/r-s3-abi")
case "$note" in
    FINDING:*) assert_eq "prefixed" "prefixed" "the finding is prefixed FINDING: in the note column" ;;
    *) assert_eq "prefixed" "not-prefixed [$note]" "the finding is prefixed FINDING: in the note column" ;;
esac
assert_contains "$note" "kmod-usb-storage" "the finding names the package to reinstall"
assert_contains "$note" "reinstall" "the finding says what to do"
assert_contains "$note" "6.12.103" "the finding names the kernel it was built for"
abilog=$(cat "$(evidence_of "$tmp/r-s3-abi" s3)")
assert_contains "$abilog" "abi: reinstall after this jump: kmod-usb-storage" \
    "the evidence carries the reinstall list as a line of its own"

# The kmod that matches stays silent: a ledger that cries wolf is not a ledger.
setup_fake_world 25.12.0
printf '6.12.104' >"$FAKE_DEV/kver"
out=$(run_scen "$tmp/r-s3-knew" --case S3)
assert_eq "$?" "0" "a jump onto a new kernel with matching kmods passes"
assert_contains "$(cat "$(evidence_of "$tmp/r-s3-knew" s3)")" \
    "abi: the kernel changed but every installed kmod still matches it" \
    "a kernel change alone is recorded without a FINDING"

# --- ac-4: a data file whose hash moved ------------------------------------ #
setup_fake_world 25.12.0
cat >"$FAKE_DEV/hash-now" <<'HASH'
tool=sha256sum
files=3
dirs=5
H aaa1 big-1.bin
H zzz9 tree/a/one.txt
H aaa4 docker-image-alpine.tar
HASH
out=$(run_scen "$tmp/r-s3-bad" --case S3)
assert_eq "$?" "1" "a changed file makes the run non-zero"
assert_eq "$(verdict_of "$tmp/r-s3-bad")" "FAIL" "a changed hash records FAIL"
assert_contains "$(note_of "$tmp/r-s3-bad")" "did not survive" "the note says the state did not survive"
assert_contains "$out" "tree/a/one.txt" "the changed file is named"
assert_contains "$out" "中文文件名-测试.txt" "the file that disappeared is named, Chinese name and all"
assert_contains "$out" "difference(s) from the pre-jump manifest" "the failure says what it compared"

# --- the rest of the judgement can fail on its own ------------------------- #
setup_fake_world 25.12.0
export FAKE_TAR_RC=1
out=$(run_scen "$tmp/r-s3-tar" --case S3)
rc=$?
unset FAKE_TAR_RC
assert_eq "$rc" "1" "a tar that no longer opens is a failed jump"
assert_contains "$out" "docker-image-alpine.tar no longer reads as a tar" "the broken archive is named"

setup_fake_world 25.12.0
export FAKE_PRESENT=no
out=$(run_scen "$tmp/r-s3-pkg" --case S3)
rc=$?
unset FAKE_PRESENT
assert_eq "$rc" "1" "a package that apk no longer knows is a failed jump"
assert_contains "$out" "software curl: apk info -e says it is gone" "the missing package is named"

setup_fake_world 25.12.0
export FAKE_EXEC_RC=127
out=$(run_scen "$tmp/r-s3-exec" --case S3)
rc=$?
unset FAKE_EXEC_RC
assert_eq "$rc" "1" "a binary that stopped running is a failed jump"
assert_contains "$out" "exited 127 where it exited 0 before the jump" "the failure compares against the S1 baseline"

setup_fake_world 25.12.0
export FAKE_BOOT_AFTER=degraded
out=$(run_scen "$tmp/r-s3-boot" --case S3)
rc=$?
unset FAKE_BOOT_AFTER
assert_eq "$rc" "1" "a slot that did not come up healthy fails the jump"
assert_contains "$out" "expected=ok got=degraded" "the field that disagreed is named"

# --- S4: the downgrade ----------------------------------------------------- #
setup_fake_world 25.12.2
out=$(run_scen "$tmp/r-s4" --case S4)
assert_eq "$?" "0" "S4 exits zero when the downgrade keeps the user's state"
assert_eq "$(verdict_of "$tmp/r-s4")" "PASS" "S4 records PASS"
assert_eq "$(cat "$FAKE_DEV/rootfs-b")" "25.12.0" "the downgrade landed on the low version"
assert_eq "$(cat "$FAKE_DEV/committed")" "b" "the downgrade committed the other slot"
assert_contains "$(cat "$(evidence_of "$tmp/r-s4" s4)")" "hop: 25.12.2 -> 25.12.0" \
    "the evidence records the direction of the jump"

# A downgrade that loses the custom uci config is exactly what S4 exists to catch.
setup_fake_world 25.12.2
printf 'hostname=ab-scen-host\ntimezone=CST-8\nzonename=Asia/Shanghai\nabscen=\nnetsec=yes\nfwrule=yes\n' >"$FAKE_DEV/uci"
out=$(run_scen "$tmp/r-s4-cfg" --case S4)
assert_eq "$?" "1" "a lost uci value fails the downgrade"
assert_contains "$out" "config abscen: expected=ab-scenarios-2026-11-12T00-00-00Z got=empty" \
    "the lost configuration value is named"

# --- S5: the ABI ledger on its own ---------------------------------------- #
setup_fake_world 25.12.2
printf '6.13.0' >"$FAKE_DEV/kver"
export FAKE_KMOD_STATE=stale FAKE_KMOD_MODVER=6.12.103 FAKE_KMOD_DEPVER=6.12.103
out=$(run_scen "$tmp/r-s5" --case S5)
rc=$?
unset FAKE_KMOD_STATE FAKE_KMOD_MODVER FAKE_KMOD_DEPVER
assert_eq "$rc" "0" "S5 passes on a machine whose only problem is an ABI mismatch"
assert_eq "$(verdict_of "$tmp/r-s5")" "PASS" "an ABI mismatch is never a FAIL"
assert_contains "$(note_of "$tmp/r-s5")" "FINDING: kmod-usb-storage" "S5 leads with the finding"
s5log=$(cat "$(evidence_of "$tmp/r-s5" s5)")
assert_contains "$s5log" "abi: kernel 6.12.103 -> 6.13.0" "S5 records which kernel changed"
assert_contains "$s5log" "reinstall after this jump: kmod-usb-storage" "S5 answers what to reinstall"

# A broken mount still fails S5: the ledger is not a licence to ignore the machine.
setup_fake_world 25.12.2
printf 'degraded' >"$FAKE_DEV/data"
out=$(run_scen "$tmp/r-s5-mount" --case S5)
assert_eq "$?" "1" "S5 fails when /data is not mounted any more"
assert_contains "$out" "assert_field data" "the failed field is named"

# --- ac-4: the boot toolchain travels with the payload --------------------- #
# S6 answers "do the busybox, the partition tools and btrfs/ab-slot/ab-upgrade move with
# the update, or do I end up with a new system and old boot tools". The payload here is a
# real tar with a real manifest, so the driver's digest comparison runs for real: the stub
# answers with the digests of those members, and one field moves per test.
host_sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

payloads_s6="$tmp/payloads-s6"
mkdir -p "$payloads_s6"

build_s6_payload() { # <version>; sets S6_KERNEL_SHA, S6_INITRD_SHA, S6_TOOL_SHA
    local v=$1 dir="$tmp/s6-build-$1"
    rm -rf "$dir"
    mkdir -p "$dir/stage" "$dir/platform/usr/sbin" "$dir/initrd/bin"
    printf 'kernel of %s\n' "$v" >"$dir/stage/kernel.bin"
    printf 'rootfs of %s\n' "$v" >"$dir/stage/rootfs.tar.gz"
    printf '#!/bin/sh\necho btrfs-progs v6.12\n' >"$dir/platform/usr/sbin/btrfs"
    chmod +x "$dir/platform/usr/sbin/btrfs"
    ( cd "$dir/platform" && tar -cf "$dir/stage/platform.tar" . )
    # A real newc initramfs when this host can build one: the ledger half of S6 lists its
    # members, and a text file would only ever exercise the "could not list" branch.
    printf 'BusyBox v1.36.1 (2026-01-01 00:00:00 UTC) multi-call binary.\n' >"$dir/initrd/bin/busybox"
    printf 'sfdisk from util-linux 2.39\n' >"$dir/initrd/bin/sfdisk"
    if command -v cpio >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
        ( cd "$dir/initrd" && find . -type f | cpio -o -H newc 2>/dev/null | gzip -9 ) \
            >"$dir/stage/initramfs.cpio.gz"
    else
        printf 'initramfs of %s\n' "$v" >"$dir/stage/initramfs.cpio.gz"
    fi
    S6_KERNEL_SHA=$(host_sha "$dir/stage/kernel.bin")
    S6_INITRD_SHA=$(host_sha "$dir/stage/initramfs.cpio.gz")
    S6_TOOL_SHA=$(host_sha "$dir/platform/usr/sbin/btrfs")
    {
        printf '{\n  "format": "ab-payload/1",\n  "rootfs": "%s",\n  "members": {\n' "$v"
        printf '    "initramfs.cpio.gz": {"sha256": "%s", "size": 1},\n' "$S6_INITRD_SHA"
        printf '    "kernel.bin": {"sha256": "%s", "size": 1},\n' "$S6_KERNEL_SHA"
        printf '    "platform.tar": {"sha256": "%s", "size": 1},\n' "$(host_sha "$dir/stage/platform.tar")"
        printf '    "rootfs.tar.gz": {"sha256": "%s", "size": 1}\n' "$(host_sha "$dir/stage/rootfs.tar.gz")"
        printf '  }\n}\n'
    } >"$dir/stage/manifest.json"
    ( cd "$dir/stage" && tar -cf "$payloads_s6/payload-$v.tar" \
        manifest.json rootfs.tar.gz kernel.bin initramfs.cpio.gz platform.tar )
}

# write_boottools <slot> <kernel sha> <initrd sha> <tool sha> <tool rc> <release version>
# The machine's answer to `boottools`, one field at a time: the digests are the payload's
# members, so "the ESP is that payload" is a fact the test builds and then breaks.
write_boottools() {
    local err=""
    [ "$5" = 0 ] || err="btrfs: symbol lookup error: /usr/sbin/btrfs: undefined symbol"
    cat >"$FAKE_DEV/boottools" <<BOOT
esp=/boot
esp_list=ab,boot,efi,initrd-a,initrd-b,vmlinuz-a,vmlinuz-b
kernel_path=/boot/vmlinuz-$1
kernel_sha=$2
initrd_path=/boot/initrd-$1
initrd_sha=$3
tool=btrfs
tool_source=merged
tool_path=/usr/sbin/btrfs
tool_sha=$4
tool_rc=$5
tool_version=btrfs-progs v6.12
tool_err=${err}
release_path=/etc/platform-release
release=PLATFORM_VERSION=0.0.1 UPSTREAM_VERSION=$6 PLATFORM_STAGE=upgrade
ledger: busybox BusyBox v1.36.1 (2026-01-01 00:00:00 UTC) multi-call binary.
ledger: sfdisk absent
ledger: partx absent
ledger: btrfs btrfs-progs v6.12
BOOT
}

build_s6_payload 25.12.2
S6_K22=$S6_KERNEL_SHA
S6_I22=$S6_INITRD_SHA
S6_T22=$S6_TOOL_SHA
build_s6_payload 25.12.0
S6_K20=$S6_KERNEL_SHA
S6_I20=$S6_INITRD_SHA
S6_T20=$S6_TOOL_SHA

# The ESP and the platform layer are the payload's: PASS, with the digests named on both
# sides so a reader can redo the comparison by hand.
setup_fake_device 25.12.2
write_boottools a "$S6_K22" "$S6_I22" "$S6_T22" 0 25.12.2
out=$(run_scen_payloads "$payloads_s6" "$tmp/r-s6" --case S6)
assert_eq "$?" "0" "S6 exits zero when the boot chain is byte-identical to the payload"
assert_eq "$(verdict_of "$tmp/r-s6")" "PASS" "S6 records PASS"
assert_contains "$(note_of "$tmp/r-s6")" "identical to payload-25.12.2.tar" \
    "the note says what was compared against what"
s6log=$(cat "$(evidence_of "$tmp/r-s6" s6)")
assert_contains "$s6log" "kernel kernel.bin: /boot/vmlinuz-a sha256=$S6_K22 is the payload's" \
    "the kernel digest is recorded with the path it was read from"
assert_contains "$s6log" "initramfs initramfs.cpio.gz: /boot/initrd-a sha256=$S6_I22 is the payload's" \
    "the initramfs digest is recorded the same way"
assert_contains "$s6log" "platform usr/sbin/btrfs: /usr/sbin/btrfs sha256=$S6_T22 is the payload's" \
    "the platform layer's btrfs is compared with the payload's copy"
assert_contains "$s6log" "boot tools and rootfs both record 25.12.2" \
    "a machine whose tools and rootfs agree says so"
assert_contains "$s6log" "esp_list=ab,boot,efi,initrd-a,initrd-b,vmlinuz-a,vmlinuz-b" \
    "the ESP listing is in the evidence, so a renamed layout is visible rather than silent"
assert_contains "$s6log" "ledger: busybox BusyBox v1.36.1" "the runtime ledger is kept as a human account"
case "$(note_of "$tmp/r-s6")" in
    FINDING:*) assert_eq "finding" "none" "a machine whose tools and rootfs agree carries no FINDING" ;;
    *) assert_eq "clean" "clean" "a machine whose tools and rootfs agree carries no FINDING" ;;
esac
if command -v cpio >/dev/null 2>&1; then
    assert_contains "$s6log" "initramfs of payload-25.12.2.tar: " \
        "the initramfs member list is recorded when this host can read it"
    assert_contains "$s6log" "bin/busybox" "the tools inside the initramfs are named"
fi

# An initramfs that is not the payload's is the ABI mismatch the user asked about: FAIL,
# and the file plus both digests are named.
setup_fake_device 25.12.2
write_boottools a "$S6_K22" "0000deadbeef0000deadbeef0000deadbeef0000deadbeef0000deadbeef000" "$S6_T22" 0 25.12.2
out=$(run_scen_payloads "$payloads_s6" "$tmp/r-s6-initrd" --case S6)
assert_eq "$?" "1" "an initramfs that is not the payload's makes the run non-zero"
assert_eq "$(verdict_of "$tmp/r-s6-initrd")" "FAIL" "a mismatched initramfs records FAIL"
assert_contains "$out" "initramfs initramfs.cpio.gz: /boot/initrd-a sha256=0000deadbeef" \
    "the failure names the file the machine carries"
assert_contains "$out" "but the payload says $S6_I22" "the failure names the digest the payload records"
assert_eq "$(printf '%s\n' "$out" | grep -c 'kernel kernel.bin: .* but the payload says' || true)" "0" \
    "the kernel that did match is not blamed for the initramfs"

# The same in the other direction, so neither member can hide behind the other.
setup_fake_device 25.12.2
write_boottools a "1111beef1111beef1111beef1111beef1111beef1111beef1111beef1111bef" "$S6_I22" "$S6_T22" 0 25.12.2
out=$(run_scen_payloads "$payloads_s6" "$tmp/r-s6-kernel" --case S6)
assert_eq "$?" "1" "a kernel that is not the payload's makes the run non-zero"
assert_contains "$out" "kernel kernel.bin: /boot/vmlinuz-a sha256=1111beef" "the kernel is named"

# A boot file the ESP does not have at all: the ESP listing is what the reader needs,
# because "the file is named differently here" is not a digest mismatch.
setup_fake_device 25.12.2
write_boottools a "$S6_K22" "$S6_I22" "$S6_T22" 0 25.12.2
sed -e 's|^kernel_path=/boot/vmlinuz-a$|kernel_path=none|' -e 's|^kernel_sha=.*$|kernel_sha=none|' \
    "$FAKE_DEV/boottools" >"$FAKE_DEV/boottools.tmp"
mv "$FAKE_DEV/boottools.tmp" "$FAKE_DEV/boottools"
out=$(run_scen_payloads "$payloads_s6" "$tmp/r-s6-nokernel" --case S6)
assert_eq "$?" "1" "a boot file that is not on the ESP fails the case"
assert_contains "$out" "nothing on the ESP answers to it (the probe listed ab,boot,efi" \
    "the failure shows the listing, so a renamed layout is not mistaken for a bad digest"

# A tool that exists and does not run: present but broken is worse than missing, because
# the boot hook and the health check are what call it.
setup_fake_device 25.12.2
write_boottools a "$S6_K22" "$S6_I22" "$S6_T22" 127 25.12.2
out=$(run_scen_payloads "$payloads_s6" "$tmp/r-s6-texec" --case S6)
assert_eq "$?" "1" "a platform tool that cannot be executed fails the case"
assert_contains "$out" "platform tool /usr/sbin/btrfs (merged): '--version' exited 127" \
    "the failure says which tool and which exit status"
assert_contains "$out" "symbol lookup error" "the stderr line is recorded, not swallowed"

# The downgrade direction: the tools are the payload's (bytes prove it) and the rootfs is a
# slot's, so the tools may be the newer ones. A FINDING, and the verdict is untouched.
setup_fake_device 25.12.0
write_boottools a "$S6_K20" "$S6_I20" "$S6_T20" 0 25.12.2
out=$(run_scen_payloads "$payloads_s6" "$tmp/r-s6-down" --case S6)
assert_eq "$?" "0" "tools newer than the running rootfs do not fail the case"
assert_eq "$(verdict_of "$tmp/r-s6-down")" "PASS" "the verdict stays PASS in the downgrade direction"
note=$(note_of "$tmp/r-s6-down")
case "$note" in
    FINDING:*) assert_eq "prefixed" "prefixed" "the downgrade line is prefixed FINDING:" ;;
    *) assert_eq "prefixed" "not-prefixed [$note]" "the downgrade line is prefixed FINDING:" ;;
esac
assert_contains "$note" "boot tools come from 25.12.2 while the running rootfs is 25.12.0" \
    "the downgrade line says exactly which version the tools come from"
assert_contains "$(cat "$(evidence_of "$tmp/r-s6-down" s6)")" "boot tools come from 25.12.2" \
    "the same fact is in the evidence, where the note column cannot lose it"
assert_contains "$(cat "$(evidence_of "$tmp/r-s6-down" s6)")" "initramfs initramfs.cpio.gz: /boot/initrd-a sha256=$S6_I20" \
    "the downgraded machine was compared against its own payload, not the newer one"

# No payload for the version the machine runs: nothing to compare against, so a GAP.
setup_fake_device 25.12.1
write_boottools a "$S6_K20" "$S6_I20" "$S6_T20" 0 25.12.1
out=$(run_scen_payloads "$payloads_s6" "$tmp/r-s6-nopay" --case S6)
assert_eq "$?" "4" "a missing payload is a gap for S6"
assert_eq "$(verdict_of "$tmp/r-s6-nopay")" "GAP" "no payload records GAP, not FAIL"
assert_contains "$(note_of "$tmp/r-s6-nopay")" "no payload for 25.12.1" "the gap names the artifact"

# S6 is read-only: the red line still comes first, and nothing is installed or rebooted.
setup_fake_device 25.12.2
write_boottools a "$S6_K22" "$S6_I22" "$S6_T22" 0 25.12.2
out=$(run_scen_payloads "$payloads_s6" "$tmp/r-s6-fold" --case S6)
assert_eq "$(grep -c 'ab-upgrade' "$STUB_CALLS" || true)" "0" "S6 installs nothing"
assert_eq "$(grep -c 'reboot' "$STUB_CALLS" || true)" "0" "S6 reboots nothing"

# --- the red line ---------------------------------------------------------- #
setup_fake_world 25.12.2
printf 'none' >"$FAKE_DEV/committed"
out=$(run_scen "$tmp/r-red" --case S3)
assert_eq "$?" "3" "no committed slot stops the run with the red-line status"
assert_contains "$out" "ABORT red-line [S3]" "the abort names the case that stopped it"
assert_eq "$(grep -c 'ab-upgrade' "$STUB_CALLS" || true)" "0" "nothing was installed after the red line"
assert_eq "$(test -e "$tmp/r-red/results.tsv" && echo yes || echo no)" "no" "an aborted run writes no row at all"

# --- --dry-run ------------------------------------------------------------- #
setup_fake_world 25.12.2
calls_before=$(wc -l <"$STUB_CALLS" | tr -d ' ')
out=$(run_scen "$tmp/dry" --dry-run)
assert_eq "$?" "0" "scenarios.sh --dry-run exits zero"
assert_eq "$(printf '%s\n' "$out" | grep '^# case ' | awk '{print $3}' | tr '\n' ' ')" \
    "S1 S2 S3 S4 S5 S6 " "the six cases are planned in order"
assert_eq "$(printf '%s\n' "$out" | awk '$1 == "S3" && $2 == "1/1" {print $3}' | tr '\n' ',')" \
    "unmount,push,check,install,reboot,wait_up,settle,status,assert," \
    "one hop runs the fixed skeleton in order"
assert_eq "$(printf '%s\n' "$out" | awk '$1 == "S3" && ($2 == "data" || $2 == "config" || $2 == "software" || $2 == "abi" || $2 == "platform") {print $2}' | tr '\n' ' ')" \
    "data data config software software abi platform platform " \
    "the judgement runs data -> config -> software -> abi -> platform"
assert_contains "$out" "S3 abi kmod vs uname -r expect=match is silent, stale/missing/unknown is a FINDING" \
    "the plan states the ABI rule before a machine is touched"
assert_contains "$out" "S2 ssh-liveness after the reload expect=ssh answers" \
    "the plan says the destructive step is followed by a liveness check"
assert_contains "$out" "S2 cfg-backup /etc/config/{network,firewall,system}" \
    "the plan says the backup comes before the change"
assert_contains "$out" "S1 pkg-install luci-app-ttyd expect=installed|unavailable" \
    "the plan says an unavailable package is not a failure"
assert_contains "$out" "S6 assert sha256(<esp>/initrd-<slot>) == manifest initramfs.cpio.gz" \
    "the plan states the byte-for-byte rule S6 judges on"
assert_contains "$out" "S6 version relation expect=same version is silent" \
    "the plan says the downgrade direction is a FINDING and never a FAIL"
rc=0
printf '%s\n' "$out" | grep -q '^# warning: missing' || rc=1
assert_eq "$rc" "1" "a dry run with every payload built has nothing to warn about"
assert_eq "$(wc -l <"$STUB_CALLS" | tr -d ' ')" "$calls_before" \
    "a dry run leaves the stub untouched, so nothing reached a machine"
assert_eq "$(test -e "$tmp/dry/results.tsv" && echo yes || echo no)" "no" "a dry run writes no results file"

# A missing payload is announced per case, with the path a reader can check.
out=$(AB_WAIT_UP=4 AB_WAIT_UP_FIRST=4 AB_WAIT_UP_HARD=8 AB_POLL_INTERVAL=1 sh "$root/scripts/device/scenarios.sh" \
    --dry-run --payload-dir "$tmp/payloads-partial" --results "$tmp/dry2/results.tsv" --case S3 2>&1)
assert_contains "$out" "# warning: missing $tmp/payloads-partial/payload-25.12.2.tar" \
    "the warning carries the path, not just the name"
assert_contains "$out" "S3 1/1 push $tmp/payloads-partial/payload-25.12.2.tar" \
    "the plan still shows the step it would run"

# --- results.tsv shape ----------------------------------------------------- #
assert_eq "$(awk -F'\t' 'NF != 4' "$tmp/r-s3/results.tsv" | wc -l | tr -d ' ')" "0" \
    "every row has four TAB separated columns"
assert_eq "$(awk -F'\t' '{print $2}' "$tmp/r-s3/results.tsv" | tr '\n' ' ')" "PASS " "the verdict is one of the three"

out=$(run_scen "$tmp/r-s3" --case S3 --resume)
assert_eq "$?" "0" "--resume on a finished case exits zero"
assert_contains "$out" "S3: already PASS" "--resume skips a case with a PASS row"
assert_eq "$(wc -l <"$tmp/r-s3/results.tsv" | tr -d ' ')" "1" "--resume appends no second row"

out=$(run_scen "$tmp/r-s3" --case S9)
assert_eq "$?" "2" "an unknown case is a usage error"
assert_contains "$out" "unknown case: S9" "the usage error names the case"

# --- the pushed helper ----------------------------------------------------- #
# The helper is the one piece a stub ssh cannot execute, so it is rendered and checked as
# a script: a driver that pushes a broken helper fails on the machine, not in the suite.
assert_command_ok "the helper renders" sh "$root/scripts/device/scenarios.sh" --render-helper "$tmp/helper.sh"
assert_eq "$(sh -n "$tmp/helper.sh" >/dev/null 2>&1; echo $?)" "0" \
    "the pushed helper is a valid POSIX shell script"
helper=$(cat "$tmp/helper.sh")
assert_contains "$helper" "cmd_kmodcheck" "the helper carries the ABI check"
assert_contains "$helper" "nohup" "the helper schedules the network revert itself"
rc=0
printf '%s' "$helper" | grep -qE '\b(PASS|FAIL|GAP)\b' || rc=1
assert_eq "$rc" "1" "the helper prints facts, never a verdict"

finish
