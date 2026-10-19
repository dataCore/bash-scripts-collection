#!/bin/bash

# backup-remoteserver Script
# backups a remote location with proxmox-backup-client
#
# 2026-10-19 PBS password via stdin (PBS_PASSWORD_FD=0) instead of the remote
#            command line, ExitOnForwardFailure, remote arguments quoted

set -euo pipefail

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

# add visudo entry for the target server user. The password arrives on stdin
# (PBS_PASSWORD_FD=0), so it is in no command line and the rule can be narrow:
#  sa_backup ALL=(root) NOPASSWD: /usr/bin/env PBS_PASSWORD_FD=0 PBS_FINGERPRINT=* /usr/bin/proxmox-backup-client backup fileserver-backup.pxar\:* --repository *
# (check with 'visudo -c'). The old rule allowed any PBS_PASSWORD and any
# proxmox-backup-client subcommand:
#  sa_backup ALL=(ALL) NOPASSWD: /usr/bin/env PBS_PASSWORD=* PBS_FINGERPRINT=* /usr/bin/proxmox-backup-client *

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file $CONFIG_FILE not found!"
    exit 1
fi

# --- ARGUMENT VALIDATION ---
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <REMOTE_IP> <REMOTE_PATH>"
    echo "Example: $0 10.7.0.13 /mnt/data/Backups"
    exit 1
fi

for var in PBS_PASSWORD PBS_FINGERPRINT PBS_DATASTORE PBS_REPOSITORY; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var is not set in $CONFIG_FILE!"
        exit 1
    fi
done

REMOTE_IP=$1
REMOTE_PATH=$2
USER=${REMOTE_USER:-"sa_backup"}

echo "-"
echo "Date:   $(date '+%Y-%m-%d %H:%M:%S')"
echo "Target: $REMOTE_IP"
echo "Path:   $REMOTE_PATH"
echo "Store:  $PBS_DATASTORE"
echo "-"

# --- REMOTE COMMAND ---
# Every argument is quoted for the remote shell (printf %q), so a path with
# spaces or shell characters cannot split or inject. The password is not part
# of it: proxmox-backup-client reads it from file descriptor 0, i.e. the
# stdin that ssh forwards (sudo -n never prompts, so it does not consume it).
REMOTE_CMD="sudo -n /usr/bin/env PBS_PASSWORD_FD=0 PBS_FINGERPRINT=$(printf '%q' "$PBS_FINGERPRINT")"
REMOTE_CMD+=" /usr/bin/proxmox-backup-client backup $(printf '%q' "fileserver-backup.pxar:${REMOTE_PATH}")"
REMOTE_CMD+=" --repository $(printf '%q' "$PBS_REPOSITORY")"

# --- EXECUTE REMOTE BACKUP ---
# We open a Reverse Tunnel (-R):
# Remote Port 8007 is forwarded to Local Port 8007
# ExitOnForwardFailure: without the tunnel the client would reach whatever
# listens on the remote port 8007 – fail instead.
# --- ERROR HANDLING ---
if printf '%s' "$PBS_PASSWORD" | ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -o ExitOnForwardFailure=yes -R 8007:127.0.0.1:8007 "$USER@$REMOTE_IP" "$REMOTE_CMD"
then
    echo "-"
    echo "SUCCESS: Backup of $REMOTE_IP completed."
    echo "-"
else
    echo "-"
    echo "ERROR: Backup failed!"
    echo "-"
    exit 1
fi
