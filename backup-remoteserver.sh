#!/bin/bash

# backup-remoteserver Script
# backups a remote location with proxmox-backup-client

# --- CONFIGURATION LOADING ---
CONFIG_FILE="/etc/backup-remoteserver.conf"

# Example config in the backup-remoteserver.conf
# PBS Server Secrets:
  # export PBS_PASSWORD="your-super-secret-password"
  # export PBS_FINGERPRINT="AA:BB:CC:DD:..."
  # PBS Storage Configuration
  # export PBS_DATASTORE="Backup-HDD"
  # export PBS_REPOSITORY="root@pam@localhost:$PBS_DATASTORE"
  # Optional: Remote User
  # export REMOTE_USER="sa_backup"

# add visudo entry for the target server user: e.g.
#  sa_backup ALL=(ALL) NOPASSWD: /usr/bin/env PBS_PASSWORD=* PBS_FINGERPRINT=* /usr/bin/proxmox-backup-client *

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo " ^}^l ERROR: Configuration file $CONFIG_FILE not found!"
    exit 1
fi

# --- ARGUMENT VALIDATION ---
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <REMOTE_IP> <REMOTE_PATH>"
    echo "Example: $0 10.7.0.13 /mnt/data/Backups"
    exit 1
fi

REMOTE_IP=$1
REMOTE_PATH=$2
USER=${REMOTE_USER:-"sa_backup"}

echo "-"
echo " ^=^s^e Date:   $(date '+%Y-%m-%d %H:%M:%S')"
echo " ^=^z^` Target: $REMOTE_IP"
echo " ^=^s^b Path:   $REMOTE_PATH"
echo " ^=^w^d  ^o Store:  $PBS_DATASTORE"
echo "-"

# --- EXECUTE REMOTE BACKUP ---
# We open a Reverse Tunnel (-R):
# Remote Port 8007 is forwarded to Local Port 8007
ssh -o BatchMode=yes -o ConnectTimeout=10 -R 8007:127.0.0.1:8007 $USER@$REMOTE_IP \
    "sudo /usr/bin/env PBS_PASSWORD='$PBS_PASSWORD' PBS_FINGERPRINT='$PBS_FINGERPRINT' \
    /usr/bin/proxmox-backup-client backup fileserver-backup.pxar:$REMOTE_PATH --repository '$PBS_REPOSITORY'"

# --- ERROR HANDLING ---
if [ $? -eq 0 ]; then
    echo "-"
    echo " ^|^e SUCCESS: Backup of $REMOTE_IP completed."
    echo "-"
else
    echo "-"
    echo " ^}^l ERROR: Backup failed!"
    echo "-"
    exit 1
fi