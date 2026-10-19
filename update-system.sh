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
# 2026-08-19 Fix "reboot: command not found" (sbin missing from PATH)
# 2026-10-19 Abort on a failed upgrade, keep local conffiles
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

# Make sure the sbin directories are in PATH. Started from cron, "su" or a
# sudo setup with a sanitized secure_path, /sbin and /usr/sbin can be missing
# and tools like "reboot" are not found.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Reboot the machine, whatever the init system provides.
do_reboot() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot
    elif command -v reboot >/dev/null 2>&1; then
        reboot
    else
        echo "Error: no reboot command found. Please reboot manually."
        exit 1
    fi
}

# Update the script collection
update-scripts
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "[✓] update-scripts finished (exit 0)."
else
    echo "[!] Warning: update-scripts failed (exit $rc), continuing with the current scripts."
fi

# Finish an interrupted dpkg run first, otherwise apt-get refuses to work
if ! dpkg --configure -a; then
    echo "Error: dpkg --configure -a failed."
    exit 1
fi

# Start update
if ! apt-get -o DPkg::Lock::Timeout=600 update; then
    echo "Error: apt-get update failed."
    exit 1
fi

# Install upgrades and kernel updates. Locally modified conffiles are kept
# instead of stopping at the prompt; a running apt (unattended-upgrades) is
# waited for instead of failing on the lock.
apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    -o DPkg::Lock::Timeout=600 dist-upgrade -y
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "Error: apt-get dist-upgrade failed (exit $rc). No cleanup, no reboot."
    exit 1
fi

# Clean up unnecessary packages and cache
echo "Cleaning up..."
apt-get autoremove -y
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
        do_reboot
    else
        read -r -p "Reboot required (running: $(uname -r) → newest: $NEWEST_KERNEL). Reboot now? (y/n): " answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            echo "[✓] Rebooting now..."
            do_reboot
        else
            echo "[i] Reboot skipped. Running: $(uname -r) → Newest: $NEWEST_KERNEL"
        fi
    fi
fi

echo "[✓] All done."
