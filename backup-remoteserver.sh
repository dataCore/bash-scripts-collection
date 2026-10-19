#!/bin/bash

# backup-remoteserver Script
# backups a remote location with proxmox-backup-client
#
# 2026-10-19 Calls the wrapper pbs-remote-backup on the target (password via
#            stdin, sudoers rule without wildcards); falls back to the old
#            invocation where it is not installed yet. ExitOnForwardFailure,
#            remote arguments quoted

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
  # Optional: path of the wrapper on the target
  # export REMOTE_WRAPPER="/usr/local/sbin/pbs-remote-backup"

# --- TARGET SETUP (recommended) ---
# Install the wrapper pbs-remote-backup.sh from this collection on the target
# and allow exactly that one command, without wildcards:
#   install -o root -g root -m 0755 pbs-remote-backup.sh /usr/local/sbin/pbs-remote-backup
#   echo 'sa_backup ALL=(root) NOPASSWD: /usr/local/sbin/pbs-remote-backup' > /etc/sudoers.d/pbs-remote-backup
#   chmod 0440 /etc/sudoers.d/pbs-remote-backup && visudo -c
# The wrapper validates archive name, path, repository (localhost only) and
# fingerprint, and reads the password from stdin – it is in no command line.
#
# --- MIGRATION ---
# Old targets have this rule, and the script still uses it (with a warning)
# as long as the wrapper is missing:
#   sa_backup ALL=(ALL) NOPASSWD: /usr/bin/env PBS_PASSWORD=* PBS_FINGERPRINT=* /usr/bin/proxmox-backup-client *
# It is NOT safe: sudoers '*' also matches spaces, so the backup user can run
# any command as root (e.g. 'PBS_FINGERPRINT=x /bin/sh -c ...'), and the
# password is visible in the target's process list. Install the wrapper and
# the new rule as above, then delete the old rule.

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
WRAPPER=${REMOTE_WRAPPER:-"/usr/local/sbin/pbs-remote-backup"}
ARCHIVE="fileserver-backup.pxar"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

echo "-"
echo "Date:   $(date '+%Y-%m-%d %H:%M:%S')"
echo "Target: $REMOTE_IP"
echo "Path:   $REMOTE_PATH"
echo "Store:  $PBS_DATASTORE"
echo "-"

# --- REMOTE COMMAND ---
# Every argument is quoted for the remote shell (printf %q), so a path with
# spaces or shell characters cannot split or inject.
WRAPPER_RC=0
# shellcheck disable=SC2029  # expanded locally on purpose, quoted with %q
ssh -n "${SSH_OPTS[@]}" "$USER@$REMOTE_IP" "test -x $(printf '%q' "$WRAPPER")" || WRAPPER_RC=$?
if [ "$WRAPPER_RC" -eq 255 ]; then
    echo "-"
    echo "ERROR: SSH connection to $USER@$REMOTE_IP failed!"
    echo "-"
    exit 1
elif [ "$WRAPPER_RC" -eq 0 ]; then
    # The password is not part of the command: the wrapper hands stdin (what
    # ssh forwards) to proxmox-backup-client as PBS_PASSWORD_FD=0. sudo -n
    # never prompts, so it does not consume stdin.
    REMOTE_CMD="sudo -n $(printf '%q' "$WRAPPER") $(printf '%q' "$ARCHIVE") $(printf '%q' "$REMOTE_PATH")"
    REMOTE_CMD+=" $(printf '%q' "$PBS_REPOSITORY") $(printf '%q' "$PBS_FINGERPRINT")"
    STDIN_DATA="$PBS_PASSWORD"
else
    echo "WARNING: DEPRECATED – $WRAPPER is not installed on $REMOTE_IP."
    echo "         Using the old invocation: the PBS password is in the remote command"
    echo "         line, and its sudoers rule lets $USER run any command as root."
    echo "         Install the wrapper and its sudoers rule (see the header of this script)."
    REMOTE_CMD="sudo -n /usr/bin/env PBS_PASSWORD=$(printf '%q' "$PBS_PASSWORD") PBS_FINGERPRINT=$(printf '%q' "$PBS_FINGERPRINT")"
    REMOTE_CMD+=" /usr/bin/proxmox-backup-client backup $(printf '%q' "${ARCHIVE}:${REMOTE_PATH}")"
    REMOTE_CMD+=" --repository $(printf '%q' "$PBS_REPOSITORY")"
    STDIN_DATA=""
fi

# --- EXECUTE REMOTE BACKUP ---
# We open a Reverse Tunnel (-R):
# Remote Port 8007 is forwarded to Local Port 8007
# ExitOnForwardFailure: without the tunnel the client would reach whatever
# listens on the remote port 8007 – fail instead.
# --- ERROR HANDLING ---
if printf '%s' "$STDIN_DATA" | ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes \
    -R 8007:127.0.0.1:8007 "$USER@$REMOTE_IP" "$REMOTE_CMD"
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
