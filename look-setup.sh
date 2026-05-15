#!/bin/bash
# ---------------------------------------------------------
# Looking Glass Auto-Manager (Install / Eject)
# ---------------------------------------------------------

# FAILSAFE 1: Exit immediately if any command fails, a variable is missing, or a pipe breaks.
set -euo pipefail

echo "Starting Looking Glass Manager..."

# FAILSAFE 2: Must be run with root privileges
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root. Please use sudo."
   exit 1
fi

# FAILSAFE 3: VM Detection
# The LG Client belongs on the HOST. If we detect a virtualized environment, abort.
if systemd-detect-virt -q; then
    echo "🚨 FAILSAFE TRIGGERED: Virtual Machine detected! 🚨"
    echo "The Looking Glass Client must be installed on your bare-metal Host, not inside a VM."
    echo "Aborting immediately to prevent system damage."
    exit 1
fi
echo "✅ Bare-metal host verified."

# Figure out the actual user (since running as sudo makes whoami = root)
REAL_USER=${SUDO_USER:-$USER}

# ==========================================
# EJECT MODE (Uninstall and Cleanup)
# ==========================================
if [[ "${1:-}" == "--eject" ]]; then
    echo "Ejecting Looking Glass from the system..."

    # 1. Kill any running instances
    killall looking-glass-client 2>/dev/null || true

    # 2. Wipe the shared memory and configuration
    rm -f /etc/tmpfiles.d/10-looking-glass.conf
    rm -f /dev/shm/looking-glass
    echo "✅ Shared memory wiped."

    # 3. Remove packages based on the OS
    if command -v dnf >/dev/null; then
        dnf remove -y looking-glass-client
        dnf copr disable -y agnelo/looking-glass || true
    elif command -v pacman >/dev/null; then
        pacman -Rns --noconfirm looking-glass-client 2>/dev/null || true
    elif command -v apt >/dev/null; then
        echo "Note: On Ubuntu, LG is usually compiled from source. Dependencies remain installed."
    fi

    echo "🚀 Looking Glass has been successfully ejected."
    exit 0
fi

# ==========================================
# INSTALL MODE
# ==========================================
echo "Detecting package manager for installation..."

if command -v dnf >/dev/null; then
    echo "📦 Detected Fedora/RHEL (dnf)"
    dnf copr enable -y agnelo/looking-glass
    dnf install -y looking-glass-client

elif command -v pacman >/dev/null; then
    echo "📦 Detected Arch Linux (pacman)"
    # Arch installs from the AUR. Makepkg cannot be run as root.
    echo "Installing base-devel and dependencies..."
    pacman -S --noconfirm --needed base-devel
    echo "⚠️ NOTE: Looking Glass is in the AUR. Please run 'yay -S looking-glass' or 'paru -S looking-glass' as your normal user after this script finishes."

elif command -v apt >/dev/null; then
    echo "📦 Detected Ubuntu/Debian (apt)"
    echo "Ubuntu does not have an official LG package. Installing all required build dependencies..."
    apt-get update
    apt-get install -y binutils-dev cmake fonts-freefont-ttf libsdl2-dev libsdl2-ttf-dev \
    libspice-protocol-dev libfontconfig1-dev libgmp-dev libwayland-dev \
    wayland-protocols libx11-dev libxext-dev libxfixes-dev libxi-dev \
    libxinerama-dev libxss-dev libxcursor-dev libxpresent-dev libxkbcommon-dev \
    libglvnd-dev libegl1-mesa-dev
    echo "⚠️ NOTE: Dependencies installed. You will need to compile the client from source (check looking-glass.io)."
else
    echo "❌ Unsupported package manager. Please install manually."
    exit 1
fi

# ==========================================
# CONFIGURE SHARED MEMORY
# ==========================================
echo "Configuring persistent shared memory for user: $REAL_USER"

# Create the config file (assigning permissions to your actual user account and the qemu group)
echo "f /dev/shm/looking-glass 0660 $REAL_USER qemu -" > /etc/tmpfiles.d/10-looking-glass.conf

# Trigger creation instantly so you don't have to reboot
systemd-tmpfiles --create /etc/tmpfiles.d/10-looking-glass.conf

echo "🎉 Installation complete! You can now run 'looking-glass-client' (if using Fedora/Arch)."
