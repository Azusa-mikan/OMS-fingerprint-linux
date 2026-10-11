#!/usr/bin/env bash
#
# Uninstaller for the OMS fingerprint setup. Reverses what install.sh did.
#
#   Copyright (C) 2026 The OMS Linux driver contributors
#   SPDX-License-Identifier: LGPL-2.1-or-later
#
# Usage:
#   sudo ./uninstall.sh              # remove driver + our PAM/udev/tool changes
#   sudo ./uninstall.sh --keep-driver  # only revert our config, keep the package
#   sudo ./uninstall.sh --purge        # also delete enrolled fingerprint records
#
# By default it leaves the distro package state clean: removing
# libfprint-omsmoc lets you reinstall the stock libfprint with:
#   sudo pacman -S libfprint
# and it never touches the templates stored inside the chip.
#
set -euo pipefail

KEEP_DRIVER=0
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --keep-driver) KEEP_DRIVER=1 ;;
        --purge)       PURGE=1 ;;
        -h|--help)     sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 $*" >&2; exit 1; }

# 1. GDM login override
if [ -f /etc/pam.d/gdm-password ] && grep -q "OMS fingerprint" /etc/pam.d/gdm-password; then
    log "Removing GDM login override /etc/pam.d/gdm-password"
    rm -f /etc/pam.d/gdm-password
fi

# 2. sudo rule: restore newest backup if present
bak=$(ls -1t /etc/pam.d/sudo.bak-OMS-* 2>/dev/null | head -n1 || true)
if [ -n "$bak" ]; then
    log "Restoring /etc/pam.d/sudo from $bak"
    cp -a "$bak" /etc/pam.d/sudo
elif grep -q pam_fprintd /etc/pam.d/sudo 2>/dev/null; then
    warn "/etc/pam.d/sudo contains pam_fprintd but no backup was found;"
    warn "remove the 'pam_fprintd' line manually if you want it gone."
fi

# 3. udev rule
rm -f /etc/udev/rules.d/99-oms-fingerprint.rules && log "Removed udev rule"
udevadm control --reload 2>/dev/null || true

# 4. helper tools and recovery script
for t in oms-claim oms-ident oms-smoke oms-pam-restore; do
    [ -e "/usr/local/bin/$t" ] && rm -f "/usr/local/bin/$t" && log "Removed /usr/local/bin/$t"
done

# 5. driver package
if [ "$KEEP_DRIVER" -eq 0 ]; then
    if pacman -Qq libfprint-omsmoc >/dev/null 2>&1; then
        log "Removing package libfprint-omsmoc"
        pacman -R --noconfirm libfprint-omsmoc
        log "You can now reinstall the stock library with:  sudo pacman -S libfprint"
    fi
fi

# 6. optionally drop enrolled fingerprint records (usr-owned, regenerable)
if [ "$PURGE" -eq 1 ]; then
    log "Purging fprintd records under /var/lib/fprint"
    rm -rf /var/lib/fprint
fi

echo
log "Done. The chip's own templates were left untouched."
echo "To reinstall later:  sudo ./install.sh"
