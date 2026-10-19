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
# 2026-10-19 Respect a pinned kernel, reboot only once per target kernel
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

# --- reboot detection (begin) ---
# Kernel the last automatic reboot was meant to boot into
STATE_DIR="/var/lib/datacore"
REBOOT_STATE="$STATE_DIR/update-system.reboot-target"

# Kernel version as dpkg and uname name it, without the Proxmox suffix
normalize_kernel() {
    sed -E 's/(-pve-signed|-pve)$//'
}

# Newest installed kernel package
# Supports Debian (linux-image-*) and Proxmox (proxmox-kernel-*-pve-signed)
newest_kernel() {
    dpkg -l | grep '^ii' | awk '{print $2}' |
        grep -E '^(linux-image|proxmox-kernel)-[0-9]' |
        grep -v 'proxmox-kernel-helper' |
        sed -E 's/^(linux-image|proxmox-kernel)-//' |
        normalize_kernel |
        sort -V | tail -1
}

# Kernel pinned with "proxmox-boot-tool kernel pin"; a next-boot pin wins
pinned_kernel() {
    command -v proxmox-boot-tool >/dev/null 2>&1 || return 0
    proxmox-boot-tool kernel list 2>/dev/null | awk '
        /^Pinned kernel:/                   { section = "pin";  next }
        /[Pp]inned on next-boot:?[[:space:]]*$/ { section = "next"; next }
        /^[[:space:]]*$/                    { section = "";     next }
        section == "pin"  && pin == ""      { pin = $1 }
        section == "next" && nextboot == "" { nextboot = $1 }
        END { if (nextboot != "") print nextboot; else if (pin != "") print pin }
    ' | normalize_kernel
}

# Kernel the next boot is expected to run
target_kernel() {
    local pinned
    pinned="$(pinned_kernel)"
    if [ -n "$pinned" ]; then
        echo "$pinned"
    else
        newest_kernel
    fi
}

# Decide whether a reboot is due: sets REBOOT_REASON and KERNEL_TARGET,
# returns 0 when due. A kernel mismatch triggers one reboot per target
# kernel. If the host still runs another kernel after that reboot (boot
# default is not the newest kernel, GRUB_DEFAULT set by hand, ...), it
# warns instead of rebooting again every week.
reboot_due() {
    local running attempted=""
    running="$(uname -r | normalize_kernel)"
    KERNEL_TARGET="$(target_kernel)"
    REBOOT_REASON=""
    [ -f "$REBOOT_STATE" ] && attempted="$(cat "$REBOOT_STATE")"

    if [ -n "$KERNEL_TARGET" ] && [ "$running" != "$KERNEL_TARGET" ]; then
        if [ "$attempted" = "$KERNEL_TARGET" ]; then
            echo "[!] Warning: still running $(uname -r) after a reboot for $KERNEL_TARGET."
            echo "    Check the boot default (proxmox-boot-tool kernel list, GRUB_DEFAULT)."
            echo "    No further automatic reboot for this kernel (state: $REBOOT_STATE)."
        else
            REBOOT_REASON="running: $(uname -r) → target: $KERNEL_TARGET"
        fi
    elif [ -n "$attempted" ]; then
        # Target kernel is running: forget the attempt
        rm -f "$REBOOT_STATE"
    fi

    if [ -z "$REBOOT_REASON" ] && [ -f /var/run/reboot-required ]; then
        REBOOT_REASON="/var/run/reboot-required is present"
    fi
    [ -n "$REBOOT_REASON" ]
}

# Remember the target kernel if it is not running yet, then reboot
reboot_for_target() {
    if [ -n "$KERNEL_TARGET" ] && [ "$(uname -r | normalize_kernel)" != "$KERNEL_TARGET" ]; then
        mkdir -p "$STATE_DIR"
        echo "$KERNEL_TARGET" >"$REBOOT_STATE"
    fi
    do_reboot
}
# --- reboot detection (end) ---

# Update the script collection
update-scripts
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "[✓] update-scripts finished (exit 0)."
else
    echo "[!] Warning: update-scripts failed (exit $rc), continuing with the current scripts."
fi

# Finish an interrupted dpkg run first, otherwise apt-get refuses to work
# ("dpkg was interrupted"). Only when dpkg --audit reports something; keep
# local conffiles instead of prompting. dpkg has no lock timeout of its own
# and apt-get cannot do this step, so retry for up to 10 minutes while
# unattended-upgrades or another apt run holds the lock.
if [ -n "$(dpkg --audit)" ]; then
    echo "Finishing an interrupted dpkg run..."
    for attempt in $(seq 1 60); do
        if dpkg --force-confdef --force-confold --configure -a </dev/null; then
            break
        fi
        if [ "$attempt" -eq 60 ]; then
            echo "Error: dpkg --configure -a failed for 10 minutes."
            exit 1
        fi
        sleep 10
    done
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
if reboot_due; then
    if [ "$AUTO_REBOOT" = true ]; then
        echo "[✓] Reboot required: $REBOOT_REASON. Auto-confirm enabled. Rebooting now..."
        reboot_for_target
    else
        read -r -p "Reboot required: $REBOOT_REASON. Reboot now? (y/n): " answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            echo "[✓] Rebooting now..."
            reboot_for_target
        else
            echo "[i] Reboot skipped: $REBOOT_REASON"
        fi
    fi
fi

echo "[✓] All done."
