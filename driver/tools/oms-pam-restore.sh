#!/bin/bash
#
# Copyright (C) 2026 The OMS Linux driver contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# oms-pam-restore — undo the OMS fingerprint PAM changes so that graphical
# login (GDM) always works with a password again.
#
# Use this if a fingerprint login attempt leaves you unable to log in.
# From a text console:  Ctrl+Alt+F3  ->  log in with your password  ->
#     sudo oms-pam-restore
#
# Safety:
#   * It only removes files this project created (identified by a marker
#     comment); it never touches distribution files under /usr/lib/pam.d.
#   * Changes take effect on the next authentication; no reboot is needed.
#   * It prints what it did and never fails hard.

set -u

MARKER="OMS fingerprint"
restore_sudo=0
[ "${1:-}" = "--all" ] && restore_sudo=1

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (use: sudo oms-pam-restore)" >&2
    exit 1
fi

changed=0

# 1) GDM login override (the risky change): /etc/pam.d/gdm-password
if [ -f /etc/pam.d/gdm-password ]; then
    if grep -q "$MARKER" /etc/pam.d/gdm-password 2>/dev/null; then
        rm -f /etc/pam.d/gdm-password
        echo "[ok] removed /etc/pam.d/gdm-password  -> GDM default restored"
        changed=1
    else
        echo "[skip] /etc/pam.d/gdm-password exists but is not ours; leaving it"
    fi
else
    echo "[ok] no /etc/pam.d/gdm-password override present"
fi

# 2) Optional: restore /etc/pam.d/sudo from our newest backup (--all)
if [ "$restore_sudo" -eq 1 ]; then
    bak=$(ls -1t /etc/pam.d/sudo.bak-OMS-* 2>/dev/null | head -n1)
    if [ -n "${bak:-}" ]; then
        cp -a "$bak" /etc/pam.d/sudo
        echo "[ok] restored /etc/pam.d/sudo from $bak"
        changed=1
    else
        echo "[skip] no /etc/pam.d/sudo.bak-OMS-* backup found"
    fi
fi

echo
if [ "$changed" -eq 1 ]; then
    echo "Done. Password login works again on the next attempt (no reboot needed)."
    echo "If the GUI is stuck on fingerprint, switch back with Ctrl+Alt+F2."
else
    echo "Nothing to restore — the system already has the stock PAM setup."
fi
echo "(tip: 'sudo oms-pam-restore --all' also restores the sudo fingerprint change)"
