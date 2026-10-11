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
#   4. helper tools (oms-smoke / oms-claim / oms-ident)
#   5. a udev rule (access + keep-powered; the sensor dislikes autosuspend)
#   6. PAM rules so a fingerprint works for login / unlock / sudo
#   7. the recovery script oms-pam-restore
#
# The display manager is auto-detected (GDM / SDDM / LightDM) and the login
# PAM service is configured accordingly. On GDM <= 50 fingerprint login is
# native, so no override is applied there.
#
# Usage:
#   sudo ./install.sh                  # full install (auto-detect the DM)
#   sudo ./install.sh --no-pam         # driver + fprintd only, do not touch PAM
#   sudo ./install.sh --no-login       # skip the display-manager login rule
#   sudo ./install.sh --no-sudo        # skip the sudo rule
#   sudo ./install.sh --dm=sddm        # force a display manager (gdm|sddm|lightdm|none)
#   sudo ./install.sh --force-gdm      # apply the GDM override even on GDM <= 50
#   sudo ./install.sh --build-only     # build the package, do not install it
#   sudo ./install.sh --no-deps        # assume build deps are already present
#
# Safe to re-run. Uninstall with ./uninstall.sh
#
set -euo pipefail

# ----------------------------------------------------------------------
# arguments
# ----------------------------------------------------------------------
DO_PAM=1
DO_LOGIN=1
DO_SUDO=1
DO_DEPS=1
BUILD_ONLY=0
FORCE_GDM=0
DM_OVERRIDE="auto"

for arg in "$@"; do
    case "$arg" in
        --no-pam)     DO_PAM=0 ;;
        --no-login)   DO_LOGIN=0 ;;
        --no-sudo)    DO_SUDO=0 ;;
        --no-deps)    DO_DEPS=0 ;;
        --build-only) BUILD_ONLY=1 ;;
        --force-gdm)  FORCE_GDM=1 ;;
        --dm=*)       DM_OVERRIDE="${arg#--dm=}" ;;
        -h|--help)    sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
FPRINTD_LINE='auth		sufficient	pam_fprintd.so	max-tries=1	timeout=10'
PAM_MARKER='# OMS fingerprint (managed by install.sh)'
stamp=$(date +%Y%m%d-%H%M%S)

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo $0 $*"
command -v pacman >/dev/null 2>&1 || die "this installer targets Arch Linux (pacman not found)"

BUILD_USER="${SUDO_USER:-}"
if [ -z "$BUILD_USER" ] || [ "$BUILD_USER" = "root" ]; then
    die "run with sudo from a normal user account (makepkg refuses to run as root)"
fi
id "$BUILD_USER" >/dev/null 2>&1 || die "build user '$BUILD_USER' not found"
run_as_build_user() { sudo -u "$BUILD_USER" --preserve-env=PATH "$@"; }

pkg_version() { pacman -Q "$1" 2>/dev/null | awk '{print $2}' | cut -d- -f1; }
ver_ge() {  # ver_ge <have> <want>
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# Insert the fingerprint rule after the PAM header, with a marker comment.
pam_insert() {
    local f=$1
    python3 - "$f" "$FPRINTD_LINE" "$PAM_MARKER" <<'PY'
import sys
f, line, marker = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(f).read().splitlines()
out, done = [], False
for ln in lines:
    out.append(ln)
    if not done and ln.startswith('#%PAM'):
        out.append(marker)
        out.append(line)
        done = True
if not done:
    out.insert(0, marker)
    out.insert(1, line)
open(f, 'w').write('\n'.join(out) + '\n')
PY
}

# Configure one PAM service (name without path): edit /etc/pam.d/<name> in
# place, or materialise an /etc override from /usr/lib/pam.d when the file
# lives in the vendor directory.
configure_service() {
    local name=$1
    local etc="/etc/pam.d/$name" usr="/usr/lib/pam.d/$name"

    if grep -qs pam_fprintd "$etc" 2>/dev/null; then
        log "$name: fingerprint already configured"; return 0
    fi
    if [ -f "$etc" ]; then
        cp -a "$etc" "$etc.bak-OMS-$stamp"
        pam_insert "$etc"
        log "Added fingerprint to $etc (backup: $(basename "$etc").bak-OMS-$stamp)"
    elif [ -f "$usr" ]; then
        install -m 0644 "$usr" "$etc"
        pam_insert "$etc"
        log "Created $etc (from vendor $usr) with fingerprint"
    else
        warn "PAM service '$name' not found; skipping"; return 1
    fi
}

# ----------------------------------------------------------------------
# 1. dependencies + fprintd
# ----------------------------------------------------------------------
if [ "$DO_DEPS" -eq 1 ]; then
    log "Installing build dependencies"
    pacman -S --needed --noconfirm --quiet \
        base-devel meson ninja gobject-introspection glib2-devel
fi
log "Installing fprintd"
pacman -S --needed --noconfirm --quiet fprintd

# ----------------------------------------------------------------------
# 2. build + install the driver package
# ----------------------------------------------------------------------
[ -f "$AUR_DIR/PKGBUILD" ] || die "missing $AUR_DIR/PKGBUILD"
log "Building $PKGNAME (downloads + compiles libfprint)"
( cd "$AUR_DIR" && run_as_build_user makepkg -fC --noconfirm )

PKGFILE=$(ls -1t "$AUR_DIR"/${PKGNAME}-[0-9]*.pkg.tar.zst 2>/dev/null | head -n1 || true)
[ -n "$PKGFILE" ] || die "package build produced no .pkg.tar.zst"
if [ "$BUILD_ONLY" -eq 1 ]; then log "Build only: $PKGFILE"; exit 0; fi

log "Installing $PKGFILE"
yes | pacman -U --noconfirm "$PKGFILE"

# ----------------------------------------------------------------------
# 3. helper tools (built against the freshly installed libfprint)
# ----------------------------------------------------------------------
build_tool() {
    local src="$1" out="$2" shim
    shim=$(mktemp -d)
    # oms-smoke.c includes <libfprint/fprint.h>; the package installs a flat
    # /usr/include/libfprint-2/, so provide a libfprint/ -> libfprint-2 shim.
    ln -sfn /usr/include/libfprint-2 "$shim/libfprint"
    log "Building $out"
    if gcc -O2 -o "$out" "$src" -I"$shim" \
         $(pkg-config --cflags --libs libfprint-2 glib-2.0 gio-2.0 gobject-2.0); then
        install -m 0755 "$out" "/usr/local/bin/$out"
    else
        warn "failed to build $(basename "$src"); skipping"
    fi
    rm -rf "$shim"
}
if pkg-config --exists libfprint-2; then
    build_tool "$TOOLS_DIR/oms-smoke.c" oms-smoke || true
    build_tool "$TOOLS_DIR/oms-claim.c" oms-claim || true
    build_tool "$TOOLS_DIR/oms-ident.c" oms-ident || true
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
# 5. PAM
# ----------------------------------------------------------------------
install -m 0755 "$TOOLS_DIR/oms-pam-restore.sh" "$PAM_RESTORE"

if [ "$DO_PAM" -eq 1 ]; then
    # --- sudo ---
    if [ "$DO_SUDO" -eq 1 ] && ! grep -qs pam_fprintd /etc/pam.d/sudo; then
        log "Adding fingerprint to /etc/pam.d/sudo"
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

    # --- display-manager login ---
    if [ "$DO_LOGIN" -eq 1 ]; then
        if [ "$DM_OVERRIDE" = "auto" ]; then
            unit=$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)
            case "${unit%.service}" in
                gdm|gdm3) DM=gdm ;;
                sddm)     DM=sddm ;;
                lightdm)  DM=lightdm ;;
                *)
                    DM=unknown
                    for p in gdm sddm lightdm; do
                        if pacman -Qq "$p" >/dev/null 2>&1; then DM=$p; break; fi
                    done ;;
            esac
        else
            DM="$DM_OVERRIDE"
        fi

        case "$DM" in
            gdm)
                ver=$(pkg_version gdm)
                if [ -n "$ver" ] && ver_ge "$ver" 51; then
                    log "GDM $ver: applying login override (fingerprint login was removed in 51)"
                    configure_service gdm-password || true
                elif [ "$FORCE_GDM" -eq 1 ]; then
                    log "GDM ${ver:-?}: forcing override (--force-gdm)"
                    configure_service gdm-password || true
                else
                    log "GDM ${ver:-?} (<= 50): fingerprint login is native; no override needed"
                fi ;;
            sddm)
                log "SDDM: adding fingerprint to the login PAM service"
                configure_service sddm || true ;;
            lightdm)
                log "LightDM: adding fingerprint to the login PAM service"
                configure_service lightdm || true ;;
            none)
                log "Display-manager login: skipped (--dm=none)" ;;
            *)
                warn "unknown display manager; configure login PAM manually (see README.zh-CN.md)" ;;
        esac
    fi

    echo
    log "Unlock/keyring notes:"
    echo "   * GNOME: the screen lock re-authenticates through the same service — covered."
    echo "   * KDE Plasma 6: kscreenlocker ships /etc/pam.d/kde-fingerprint — works already."
    echo "   * Login with a fingerprint leaves the keyring locked on some setups;"
    echo "     a password prompt for the keyring may appear once."
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

  3. Reuse templates already stored in the chip (Windows-enrolled) instead of
     re-enrolling — the chip rejects duplicates:
         oms-smoke list
         sudo oms-claim <user> <slot>:<finger>

  4. Re-login to test. A finger now works for: login, screen unlock and sudo
     (press when prompted; the password still works as a fallback).

If a login screen ever stops accepting your password:
    * press Ctrl+Alt+F3, log in with your password, then:
         sudo oms-pam-restore
    * sudo oms-pam-restore --all  also reverts the sudo change.

Remove everything later with:  sudo ./uninstall.sh
EOF
