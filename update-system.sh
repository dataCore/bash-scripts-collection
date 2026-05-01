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
# 2026-05-01 Fix reboot detection for Proxmox (proxmox-kernel-* package names)
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
# Supports Debian (linux-image-*) and Proxmox (proxmox-kernel-*-pve-signed)
NEWEST_KERNEL="$(dpkg -l | grep '^ii' | awk '{print $2}' \
    | grep -E '^(linux-image|proxmox-kernel)-[0-9]' \
    | grep -v 'proxmox-kernel-helper' \
    | sed -E 's/^(linux-image|proxmox-kernel)-//' \
    | sed -E 's/(-pve-signed|-pve)$//' \
    | sort -V | tail -1)"

if [ -f /var/run/reboot-required ] || \
   { [ -n "$NEWEST_KERNEL" ] && [ "$(uname -r | sed -E 's/-pve$//')" != "$NEWEST_KERNEL" ]; }; then
    if [ "$AUTO_REBOOT" = true ]; then
        echo "[✓] Auto-confirm enabled. Rebooting now..."
        reboot
    else
        read -r -p "Reboot required (running: $(uname -r) → newest: $NEWEST_KERNEL). Reboot now? (y/n): " answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            echo "[✓] Rebooting now..."
            reboot
        else
            echo "[i] Reboot skipped. Running: $(uname -r) → Newest: $NEWEST_KERNEL"
        fi
    fi
fi

echo "[✓] All done."