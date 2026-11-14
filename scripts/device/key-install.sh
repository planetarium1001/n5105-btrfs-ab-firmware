#!/bin/sh
# key-install.sh - put the project's public key into a fresh machine's dropbear, using
# the one credential a just-flashed system still has: an empty root password.
#
# Why this is its own step: a whole-disk rewrite replaces /etc/dropbear/authorized_keys
# along with everything else, and the WAN-side ssh port is the only way in (docs/install.md).
# So the order is fixed - flash proves the machine booted, this installs the key over the
# password that the image ships with, and every later script (matrix.sh, scenarios.sh,
# probes.sh, feed-probe.sh, power-cut.sh) assumes key auth from then on.
#
#   key-install.sh                 # default host, key from .workflow/secrets
#   key-install.sh --key <file>    # a key that is not the project secret
#   key-install.sh --check         # only report, change nothing
#   key-install.sh --prove         # also prove the key is accepted (see below)
#
# Verdict line: key-install=<ok|present|fail> reason=<token>
#   reason=key-missing | key-unreadable | pub-unreadable | password-rejected
#          | locked-out | write-failed | verify-failed
#
# The password route is deliberately narrow: PubkeyAuthentication=no and
# PreferredAuthentications=password, so a key that is silently missing cannot make this
# look like a password success. `printf '\n'` answers dropbear's empty-password prompt;
# a machine whose root password is set (no empty login) fails here and says so instead of
# retrying forever - that is the one state that needs a monitor and a keyboard.
#
# The public key is derived from the private key when <key>.pub is absent, so there is one
# source of truth and no second copy to keep in step.

set -u

AB_REPO_ROOT=${AB_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
AB_HOST=${AB_HOST:-root@192.168.2.49}
AB_KEY=${AB_KEY:-${AB_REPO_ROOT}/.workflow/secrets/n5105-device-ssh-key}
AB_AUTHORIZED_KEYS=${AB_AUTHORIZED_KEYS:-/etc/dropbear/authorized_keys}
AB_SSH_CONNECT_TIMEOUT=${AB_SSH_CONNECT_TIMEOUT:-8}

key=$AB_KEY
pub=""
check=0
dry=0
prove=0
PROVE_PORT=${AB_PROVE_PORT:-2222}

say() { printf '%s\n' "$*"; }
fail() { say "key-install=fail reason=$1"; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --key) key=${2:-}; shift 2 ;;
        --pub) pub=${2:-}; shift 2 ;;
        --check) check=1; shift ;;
        --prove) prove=1; shift ;;
        --dry-run) dry=1; shift ;;
        -h | --help) sed -n '2,32p' "$0"; exit 0 ;;
        *) say "key-install.sh: unknown argument: $1"; exit 2 ;;
    esac
done

[ -f "$key" ] || fail key-missing
[ -r "$key" ] || fail key-unreadable

if [ -z "$pub" ]; then
    if [ -f "${key}.pub" ]; then
        pub="${key}.pub"
    else
        # Derive rather than demand a second file: ssh-keygen -y reads the private key
        # and prints exactly the line that has to land in authorized_keys.
        pub_line=$(ssh-keygen -y -f "$key" 2>/dev/null) || fail pub-unreadable
    fi
fi
if [ -z "${pub_line:-}" ]; then
    [ -f "$pub" ] || fail pub-unreadable
    [ -r "$pub" ] || fail pub-unreadable
    pub_line=$(tr -d '\r' < "$pub" | sed -e '/^$/d' -e '/^#/d' | head -n 1)
    [ -n "$pub_line" ] || fail pub-unreadable
fi

ssh_key() {
    ssh -i "$key" \
        -o IdentitiesOnly=yes \
        -o PreferredAuthentications=publickey \
        -o PubkeyAuthentication=yes \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o "ConnectTimeout=${AB_SSH_CONNECT_TIMEOUT}" \
        "$AB_HOST" "$@"
}

# The password route: no key is offered, so a success cannot be a key success in disguise.
ssh_password() {
    printf '\n' | ssh \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password \
        -o NumberOfPasswordPrompts=1 \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o "ConnectTimeout=${AB_SSH_CONNECT_TIMEOUT}" \
        "$AB_HOST" "$@"
}

if [ "$dry" -eq 1 ]; then
    say "dry-run: check key auth to $AB_HOST, else install ${pub:-${key}.pub} into $AB_AUTHORIZED_KEYS via the empty-password route"
    say "key-install=ok dry-run=1"
    exit 0
fi

# The install command travels as one argument: ssh consumes the empty password line from
# stdin before the remote command runs, so the key cannot ride on stdin as a second line.
# The key line carries no single quote (base64 plus an optional comment), which is what
# makes the quoting safe; grep -qxF keeps the write idempotent.
case "$pub_line" in
    *"'"*) fail pub-unquotable ;;
esac
install_cmd="umask 077; mkdir -p $(dirname "$AB_AUTHORIZED_KEYS"); \
    touch $AB_AUTHORIZED_KEYS; chmod 600 $AB_AUTHORIZED_KEYS; \
    line='${pub_line}'; grep -qxF \"\$line\" $AB_AUTHORIZED_KEYS || printf '%s\n' \"\$line\" >> $AB_AUTHORIZED_KEYS; \
    sed -i '/^[$]/d' $AB_AUTHORIZED_KEYS 2>/dev/null || true"

# Presence is a property of the file, not of a successful login. This image answers
# SSH_MSG_USERAUTH "none" for an empty root password, so `ssh <host> true` succeeds even
# when no key is installed (measured 2026-11-15: authorized_keys empty, login still ok).
# A login therefore proves reachability and nothing about the key; only the file does.
keys_have_line() {
    ssh_key "grep -qxF '$pub_line' $AB_AUTHORIZED_KEYS" 2>/dev/null
}

if keys_have_line; then
    present=1
    say "key-install=present reason=authorized-keys-contains-key host=$AB_HOST file=$AB_AUTHORIZED_KEYS key=${pub_line##* }"
else
    present=0
    if [ "$check" -eq 1 ]; then
        fail key-not-installed
    fi
    if ! printf '\n' | ssh \
            -o PubkeyAuthentication=no \
            -o PreferredAuthentications=password \
            -o NumberOfPasswordPrompts=1 \
            -o ControlMaster=no \
            -o ControlPath=none \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o "ConnectTimeout=${AB_SSH_CONNECT_TIMEOUT}" \
            "$AB_HOST" "$install_cmd" 2>/dev/null
    then
        # Tell the two failures apart: if the password route cannot even say 'true', the
        # machine has no empty root login and needs a keyboard, not a retry.
        if ssh_password true 2>/dev/null; then
            fail write-failed
        fi
        fail password-rejected
    fi
    keys_have_line || fail verify-failed
fi

# --prove: a second dropbear, on a spare port, with password auth switched off (-s -g),
# so the only way in is the key in authorized_keys. The firewall accepts one new port for
# the duration of the test and the rule is removed again; the main dropbear on 22 is never
# touched, so a failed proof cannot lock the machine out.
prove_key() {
    _p=$PROVE_PORT
    ssh_key "nft insert rule inet fw4 input_wan tcp dport $_p accept 2>/dev/null || \
             nft insert rule inet fw4 input tcp dport $_p accept 2>/dev/null" >/dev/null 2>&1 || true
    ssh_key "setsid dropbear -p $_p -s -g -F -E -P /tmp/ab-keyprove.pid \
             </dev/null >/tmp/ab-keyprove.log 2>&1 & sleep 1" >/dev/null 2>&1 || true
    # The spare dropbear answers a second or two after a fresh boot; three short attempts
    # cost less than a misread "inconclusive" on a machine that only got that far once.
    _auth=""
    _try=0
    while [ "$_try" -lt 3 ]; do
    _try=$((_try + 1))
    _auth=$(ssh -i "$key" -p "$_p" \
        -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes \
        -o BatchMode=yes -o ControlMaster=no -o ControlPath=none \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o "ConnectTimeout=${AB_SSH_CONNECT_TIMEOUT}" -v \
        "$AB_HOST" true 2>&1 | sed -n 's/.*Authenticated to .* using "\([a-z]*\)".*/\1/p' | tail -n 1)
    [ "$_auth" = "publickey" ] && break
    sleep 2
    done
    # Cleanup deletes by handle, not by spec: `nft delete rule <chain> tcp dport N accept`
    # only matches when the rule text is identical, and the insert above adds to whichever
    # of the two chains exists. One pass over the ruleset removes what this run added.
    ssh_key "kill \$(cat /tmp/ab-keyprove.pid 2>/dev/null) 2>/dev/null; \
             for h in \$(nft -a list ruleset 2>/dev/null | grep \"dport $_p accept\" | sed -n 's/.*# handle \\([0-9]*\\)/\\1/p'); do \
                 nft delete rule inet fw4 input_wan handle \$h 2>/dev/null; \
                 nft delete rule inet fw4 input handle \$h 2>/dev/null; \
             done" >/dev/null 2>&1 || true
    [ "$_auth" = "publickey" ]
}

if [ "$prove" -eq 1 ]; then
    if prove_key; then
        say "key-install=ok reason=key-auth-proven host=$AB_HOST port=$PROVE_PORT method=publickey key=${pub_line##* }"
        exit 0
    fi
    say "key-install=inconclusive reason=key-auth-not-proven host=$AB_HOST port=$PROVE_PORT (the key is in $AB_AUTHORIZED_KEYS; the spare-port proof did not come back as publickey)"
    exit 1
fi

say "key-install=ok reason=authorized-keys-contains-key host=$AB_HOST key=${pub_line##* } present=$present"
