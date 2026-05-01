#!/bin/bash

# =======================================================================
# UPDATE SYSTEM SCRIPT to update the Linux System automaticly
# by dataCore
#
# Usage: update-system -y (optional: reboot automaticly)
# Example: update-system -y
#
# HISTORY
# 2024-04-15 Initial Version
# 2026-05-01 Fix reboot detection (kernel version check via dpkg)
#
# =======================================================================
# START script
# =======================================================================

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo or as root."
    exit 1
fi

# Check for -y flag to skip confirmation
AUTO_REBOOT=false
for arg in "$@"; do
    if [[ "$arg" == "-y" ]]; then
        AUTO_REBOOT=true
    fi
done

# Deactivate interactive menues
export DEBIAN_FRONTEND=noninteractive

# Update the script collection
update-scripts

# Start update
if ! apt-get update; then
    echo "Error: apt-get update failed."
    exit 1
fi

# Install upgrades and kernel updates
apt-get dist-upgrade -y

# Clean up unnecessary packages and cache
echo "Cleaning up..."
apt-get autoremove -y
apt-get autoclean -y
apt-get clean -y

# Check if a reboot is required
REBOOT_NEEDED=false

# Standard Debian check
if [ -f /var/run/reboot-required ]; then
    REBOOT_NEEDED=true
fi

# Kernel version check (works on Debian and Proxmox)
RUNNING_KERNEL="$(uname -r)"
NEWEST_KERNEL="$(dpkg -l 'linux-image-*' | grep '^ii' | awk '{print $2}' \
    | sed 's/linux-image-//' | sort -V | tail -1)"
if [ -n "$NEWEST_KERNEL" ] && [ "$RUNNING_KERNEL" != "$NEWEST_KERNEL" ]; then
    REBOOT_NEEDED=true
fi

if [ "$REBOOT_NEEDED" = true ]; then
    if [ "$AUTO_REBOOT" = true ]; then
        echo "[✓] Auto-confirm enabled. Rebooting now..."
        reboot
    else
        read -r -p "Reboot required (new kernel: $NEWEST_KERNEL). Reboot now? (y/n): " answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            echo "[✓] Rebooting now..."
            reboot
        else
            echo "[i] Reboot skipped. Running: $RUNNING_KERNEL → Newest: $NEWEST_KERNEL"
        fi
    fi
fi

echo "[✓] All done."