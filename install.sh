#!/usr/bin/env bash
#
# One-click installer for the OMS match-on-chip fingerprint sensor
# (USB 33a7:2388, Jiangxi OMS Microelectronics / OFilm).
#
#   Copyright (C) 2026 The OMS Linux driver contributors
#   SPDX-License-Identifier: LGPL-2.1-or-later
#
# Arch Linux (and derivatives using pacman). It installs, in order:
#   1. build dependencies
#   2. the libfprint-omsmoc package (libfprint + the omsmoc driver)
#   3. fprintd
#   4. a udev rule (device access + keep-powered, the sensor dislikes autosuspend)
#   5. PAM rules so a fingerprint works for login / unlock / sudo
#   6. the recovery script oms-pam-restore
#
# Usage:
#   sudo ./install.sh                 # full install (driver + fprintd + PAM)
#   sudo ./install.sh --no-pam        # driver + fprintd only, do not touch PAM
#   sudo ./install.sh --no-gdm        # skip the GDM/login PAM override
#   sudo ./install.sh --no-sudo       # skip the sudo PAM rule
#   sudo ./install.sh --build-only    # build the package, do not install it
#   sudo ./install.sh --no-deps       # assume build deps are already present
#
# It is safe to re-run. Uninstall with ./uninstall.sh
#
set -euo pipefail

# ----------------------------------------------------------------------
# arguments
# ----------------------------------------------------------------------
DO_PAM=1
DO_GDM=1
DO_SUDO=1
DO_DEPS=1
BUILD_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --no-pam)     DO_PAM=0 ;;
        --no-gdm)     DO_GDM=0 ;;
        --no-sudo)    DO_SUDO=0 ;;
        --no-deps)    DO_DEPS=0 ;;
        --build-only) BUILD_ONLY=1 ;;
        -h|--help)
            sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# ----------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
AUR_DIR="$REPO_ROOT/aur/libfprint-omsmoc"
TOOLS_DIR="$REPO_ROOT/driver/tools"
PAM_RESTORE=/usr/local/bin/oms-pam-restore
UDEV_RULE=/etc/udev/rules.d/99-oms-fingerprint.rules
PKGNAME=libfprint-omsmoc

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo $0 $*"
command -v pacman >/dev/null 2>&1 || die "this installer targets Arch Linux (pacman not found)"

# The real (non-root) user, needed because makepkg must not run as root.
BUILD_USER="${SUDO_USER:-}"
if [ -z "$BUILD_USER" ] || [ "$BUILD_USER" = "root" ]; then
    die "run with sudo from a normal user account (makepkg refuses to run as root)"
fi
id "$BUILD_USER" >/dev/null 2>&1 || die "build user '$BUILD_USER' not found"

run_as_build_user() { sudo -u "$BUILD_USER" --preserve-env=PATH "$@"; }

# ----------------------------------------------------------------------
# 1. dependencies
# ----------------------------------------------------------------------
if [ "$DO_DEPS" -eq 1 ]; then
    log "Installing build dependencies and fprintd"
    pacman -S --needed --noconfirm --quiet \
        base-devel meson ninja gobject-introspection glib2-devel
fi

log "Installing fprintd (pulls the driver package's runtime deps)"
pacman -S --needed --noconfirm --quiet fprintd

# ----------------------------------------------------------------------
# 2. build + install the driver package
# ----------------------------------------------------------------------
[ -f "$AUR_DIR/PKGBUILD" ] || die "missing $AUR_DIR/PKGBUILD"

log "Building $PKGNAME (this downloads the libfprint source and compiles it)"
# -f forces a rebuild, -C cleans stale src/pkg so patching is repeatable.
( cd "$AUR_DIR" && run_as_build_user makepkg -fC --noconfirm )

PKGFILE=$(ls -1t "$AUR_DIR"/${PKGNAME}-[0-9]*.pkg.tar.zst 2>/dev/null | head -n1 || true)
[ -n "$PKGFILE" ] || die "package build produced no .pkg.tar.zst"

if [ "$BUILD_ONLY" -eq 1 ]; then
    log "Build only: $PKGFILE"
    exit 0
fi

log "Installing $PKGFILE"
# --ask=4 answers the "replace libfprint?" prompt with yes.
yes | pacman -U --noconfirm "$PKGFILE"

# ----------------------------------------------------------------------
# 3. helper tools (built against the freshly installed libfprint)
# ----------------------------------------------------------------------
build_tool() {
    local src="$1" out="$2"
    local shim
    shim=$(mktemp -d)
    # oms-smoke.c includes <libfprint/fprint.h>; the package installs a flat
    # /usr/include/libfprint-2/, so provide a libfprint/ -> libfprint-2 shim.
    ln -sfn /usr/include/libfprint-2 "$shim/libfprint"
    log "Building $out"
    gcc -O2 -o "$out" "$src" -I"$shim" \
        $(pkg-config --cflags --libs libfprint-2 glib-2.0 gio-2.0 gobject-2.0) \
        || { warn "failed to build $(basename "$src"); rm -rf "$shim"; return 1; }
    rm -rf "$shim"
    install -m 0755 "$out" "/usr/local/bin/$out"
}
if pkg-config --exists libfprint-2; then
    build_tool "$TOOLS_DIR/oms-smoke.c"  oms-smoke  || true
    build_tool "$TOOLS_DIR/oms-claim.c"  oms-claim  || true
    build_tool "$TOOLS_DIR/oms-ident.c"  oms-ident  || true
else
    warn "libfprint-2.pc not found; skipping helper tools"
fi

# ----------------------------------------------------------------------
# 4. udev rule: access + keep powered
# ----------------------------------------------------------------------
log "Installing udev rule $UDEV_RULE"
cat > "$UDEV_RULE" <<'EOF'
# OMS / Jiangxi OMS Microelectronics fingerprint module 33a7:2388
# - grant the console user access (uaccess) with a 0666 fallback
# - keep the device powered: it does not survive kernel autosuspend
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="33a7", ATTR{idProduct}=="2388", MODE="0666", TAG+="uaccess", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=usb || true

# ----------------------------------------------------------------------
# 5. PAM: fingerprint for login / unlock / sudo
# ----------------------------------------------------------------------
install -m 0755 "$TOOLS_DIR/oms-pam-restore.sh" "$PAM_RESTORE"

if [ "$DO_PAM" -eq 1 ]; then
    stamp=$(date +%Y%m%d-%H%M%S)

    if [ "$DO_SUDO" -eq 1 ] && ! grep -q pam_fprintd /etc/pam.d/sudo 2>/dev/null; then
        log "Adding fingerprint to /etc/pam.d/sudo (backup: sudo.bak-OMS-$stamp)"
        cp -a /etc/pam.d/sudo "/etc/pam.d/sudo.bak-OMS-$stamp"
        python3 - <<'PY'
p = "/etc/pam.d/sudo"
lines = open(p).read().splitlines()
out, inserted = [], False
for ln in lines:
    out.append(ln)
    if not inserted and ln.split()[:2] == ["auth", "sufficient"] and "pam_rootok" in ln:
        out.append("auth\t\tsufficient\tpam_fprintd.so\tmax-tries=1\ttimeout=10")
        inserted = True
if not inserted:
    out.insert(0, "auth\t\tsufficient\tpam_fprintd.so\tmax-tries=1\ttimeout=10")
open(p, "w").write("\n".join(out) + "\n")
PY
    fi

    if [ "$DO_GDM" -eq 1 ]; then
        log "Installing GDM login override /etc/pam.d/gdm-password"
        install -m 0644 "$TOOLS_DIR/gdm-password.pam" /etc/pam.d/gdm-password
    fi
else
    log "Skipping PAM configuration (--no-pam)"
fi

# ----------------------------------------------------------------------
# done
# ----------------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32m✓ installation complete\033[0m')

Next steps:
  1. Enroll a finger (press/lift 6 times when prompted):
         fprintd-enroll
     (or a specific finger:  fprintd-enroll -f right-index-finger)

  2. Verify:
         fprintd-verify

  3. Replace existing Windows-enrolled templates instead of re-enrolling:
         sudo oms-claim <user> <slot>:<finger>
     (list the chip slots first:  oms-smoke list)

  4. Re-login to test. Fingerprint now works for: GDM login, screen unlock
     and sudo (press the finger when prompted; password still works).

If the login screen ever stops accepting your password:
    * press Ctrl+Alt+F3, log in with your password, then run:
         sudo oms-pam-restore
    * this removes the GDM fingerprint override (no reboot needed).
    * sudo oms-pam-restore --all  also reverts the sudo change.

Remove everything later with:  sudo ./uninstall.sh
EOF
