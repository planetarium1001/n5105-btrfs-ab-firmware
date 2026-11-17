#!/bin/sh
# bench-setup.sh - put the bench machine back into a usable state after a flash.
#
#   bench-setup.sh                  # the default set: the theme's settings app + zh-CN
#   bench-setup.sh --list "a b"     # a different package set
#   bench-setup.sh --dry-run        # the plan, nothing sent
#
# Why this is a script: a flash is a full-disk write, so everything installed on top of the
# image is gone. That is correct - the image is the product - but it means every bench run
# starts by reinstalling the same handful of packages, and a person who forgets one of them
# then measures a machine that is "missing something" rather than a machine that is wrong.
# The theme is the case that matters: luci-theme-argon ships inside the image, but the app
# that configures it (luci-app-argon-config) does not, so the web UI looks untouched until
# it is installed - which reads like "the theme did not survive" rather than "it was never
# part of the image".
#
# Not part of the product, and not in the release images: this only ever runs against a
# machine on the bench, over SSH, on top of what the image already provides.
#
# Verdict line: bench-setup=ok base=argon packages=<n> mediaurlbase=/luci-static/argon
#               bench-setup=fail reason=<token>
set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
: "${AB_REPO_ROOT:=$(cd "${DEVICE_DIR}/../.." && pwd)}"
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

# The theme's settings app and its Chinese translation. Both come from the feed the image
# already points at; nothing here installs a theme, because the theme is in the image.
BENCH_PACKAGES=${AB_BENCH_PACKAGES:-luci-app-argon-config luci-i18n-argon-config-zh-cn}
BENCH_THEME=${AB_BENCH_THEME:-/luci-static/argon}
DRY_RUN=${AB_DRY_RUN:-0}

usage() {
    printf 'usage: bench-setup.sh [--list "<packages>"] [--theme <mediaurlbase>] [--dry-run]\n' >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)
            [ $# -ge 2 ] || usage
            BENCH_PACKAGES=$2
            shift 2
            ;;
        --theme)
            [ $# -ge 2 ] || usage
            BENCH_THEME=$2
            shift 2
            ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

_remote() {
    cat <<REMOTE
set -u
theme='${BENCH_THEME}'
packages='${BENCH_PACKAGES}'

# The theme itself must be in the image; a bench that has to install it is a bench that
# would hide a packaging defect.
[ -d "/www\${theme}" ] || { printf 'bench-setup=fail reason=theme-not-in-image theme=%s\n' "\${theme}"; exit 0; }

apk update >/dev/null 2>&1 || :
installed=0
for p in \${packages}; do
    if apk info -e "\${p}" >/dev/null 2>&1; then
        installed=\$((installed + 1))
        continue
    fi
    if apk add "\${p}" >/dev/null 2>&1; then
        installed=\$((installed + 1))
    else
        printf 'bench-setup=fail reason=install-failed package=%s\n' "\${p}"
        exit 0
    fi
done

uci set luci.main.mediaurlbase="\${theme}" && uci commit luci || {
    printf 'bench-setup=fail reason=uci-commit-failed\n'; exit 0
}
/etc/init.d/uhttpd reload >/dev/null 2>&1 || :
now=\$(uci -q get luci.main.mediaurlbase)
[ "\${now}" = "\${theme}" ] || {
    printf 'bench-setup=fail reason=mediaurlbase=%s\n' "\${now}"; exit 0
}
printf 'bench-setup=ok base=%s packages=%s mediaurlbase=%s\n' \
    "\${theme##*/}" "\${installed}" "\${now}"
REMOTE
}

if [ "${DRY_RUN}" = "1" ]; then
    printf 'dry-run: ssh %s\n' "${AB_HOST}"
    printf '%s\n' "$(_remote)"
    exit 0
fi

out=$(dev_ssh "$(_remote)") || {
    printf 'bench-setup=fail reason=unreachable host=%s\n' "${AB_HOST}"
    exit 1
}
printf '%s\n' "${out}"
case "${out}" in
    *"=fail"*) exit 1 ;;
esac
exit 0
