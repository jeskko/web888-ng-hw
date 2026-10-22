#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Days until the Vivado licence expires (earliest dated Vivado feature in
# $XILINXD_LICENSE_FILE, or the file given).
#
#   scripts/licence-check.sh [--days N] [licence file]
#
# Prints one line. Exit status: 0 = more than N days left (default 30),
# 2 = N days or fewer, 1 = expired, missing or unreadable.
# In GitHub Actions it also emits a warning/error annotation.
set -eu
export LC_ALL=C
days=30
if [ "${1:-}" = "--days" ]; then days=$2; shift 2; fi
lic=${1:-${XILINXD_LICENSE_FILE:-}}

say() {   # level message
    echo "$2"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        [ "$1" != ok ] && echo "::$1::$2"
        echo "$2" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    fi
    return 0
}

if [ -z "$lic" ] || [ ! -r "$lic" ]; then
    say error "licence: no readable licence file (XILINXD_LICENSE_FILE='$lic')"
    exit 1
fi
# INCREMENT <feature> <vendor> <version> <expiry|permanent> ...
exp=$(awk '$1 == "INCREMENT" && $2 ~ /^Vivado_/ && $5 != "permanent" { print $5 }' "$lic" |
    while read -r d; do date -d "$(echo "$d" | tr '-' ' ')" +%F; done | sort | head -n 1)
if [ -z "$exp" ]; then
    say error "licence: no dated Vivado feature in $lic"
    exit 1
fi
left=$(( ($(date -d "$exp" +%s) - $(date +%s)) / 86400 ))
if [ "$left" -lt 0 ]; then
    say error "licence: Vivado licence EXPIRED on $exp: renew it (AMD Product Licensing) and replace the file on the build host"
    exit 1
elif [ "$left" -le "$days" ]; then
    say warning "licence: Vivado licence expires on $exp, in $left days: renew it (AMD Product Licensing) and replace the file on the build host"
    exit 2
fi
say ok "licence: Vivado licence valid until $exp ($left days)"
