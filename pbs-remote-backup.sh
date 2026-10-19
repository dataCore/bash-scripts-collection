#!/bin/bash
# =======================================================================
# PBS REMOTE BACKUP WRAPPER – runs on the TARGET of backup-remoteserver
# by dataCore
#
# backup-remoteserver calls this wrapper through sudo instead of
# proxmox-backup-client itself, so the sudoers rule needs no wildcards
# (sudoers '*' also matches spaces, so 'PBS_FINGERPRINT=* ...client *'
# would let the backup user run any command as root). Every argument is
# validated here; the PBS password arrives on stdin, never in a command line.
#
# HISTORY
# 2026-10-19 Initial Version
#
# Install on the target (as root, from a checkout of this collection):
#   install -o root -g root -m 0755 pbs-remote-backup.sh /usr/local/sbin/pbs-remote-backup
#   echo 'sa_backup ALL=(root) NOPASSWD: /usr/local/sbin/pbs-remote-backup' > /etc/sudoers.d/pbs-remote-backup
#   chmod 0440 /etc/sudoers.d/pbs-remote-backup && visudo -c
# Then remove the old rule (/usr/bin/env PBS_PASSWORD=* PBS_FINGERPRINT=* ...).
#
# Optional /etc/pbs-remote-backup.conf (root-owned), restricting the paths:
#   PBS_REMOTE_ALLOWED_PATHS="/mnt/data /srv/share"
#
# Usage:   echo -n "$PBS_PASSWORD" | sudo -n pbs-remote-backup <archive>.pxar <path> <repository> <fingerprint>
# Example: ... | sudo -n pbs-remote-backup fileserver-backup.pxar /mnt/data/Backups 'root@pam@localhost:Backup-HDD' 'AA:BB:...'
# =======================================================================

set -euo pipefail
export LANG="C.UTF-8"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG_FILE="/etc/pbs-remote-backup.conf"
CLIENT="/usr/bin/proxmox-backup-client"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ "$EUID" -eq 0 ] || die "run as root (through sudo)."
[ "$#" -eq 4 ] || die "usage: pbs-remote-backup <archive>.pxar <path> <repository> <fingerprint>"

ARCHIVE="$1"
SRC_PATH="$2"
REPOSITORY="$3"
FINGERPRINT="$4"

# --- VALIDATION (fixed forms only) ---
# Archive name: letters, digits, '_' and '-', ending in .pxar
[[ "$ARCHIVE" =~ ^[A-Za-z0-9_-]{1,64}\.pxar$ ]] || die "invalid archive name: '$ARCHIVE'"

# Repository: user@realm[!token]@localhost[:port]:datastore – only localhost,
# i.e. the reverse tunnel from backup-remoteserver
[[ "$REPOSITORY" =~ ^[A-Za-z0-9._-]{1,64}@[A-Za-z0-9._-]{1,32}(![A-Za-z0-9._-]{1,64})?@(localhost|127\.0\.0\.1)(:[0-9]{1,5})?:[A-Za-z0-9._-]{1,64}$ ]] \
    || die "invalid repository (must be user@realm@localhost:datastore): '$REPOSITORY'"

# Fingerprint: SHA-256, 32 hex pairs separated by ':'
[[ "$FINGERPRINT" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] || die "invalid fingerprint."

# Path: absolute, no shell or option characters, an existing directory.
# Checked again after resolving symlinks.
[[ "$SRC_PATH" =~ ^/[A-Za-z0-9._/@+\ -]*$ ]] || die "invalid path: '$SRC_PATH'"
case "/$SRC_PATH/" in
    */../*|*/./*) die "path must not contain '.' or '..' components: '$SRC_PATH'" ;;
esac
REAL_PATH=$(realpath -e -- "$SRC_PATH" 2>/dev/null) || die "path not found: '$SRC_PATH'"
[ -d "$REAL_PATH" ] || die "path is not a directory: '$SRC_PATH'"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi
if [ -n "${PBS_REMOTE_ALLOWED_PATHS:-}" ]; then
    allowed=false
    for prefix in $PBS_REMOTE_ALLOWED_PATHS; do
        prefix="${prefix%/}"
        if [ "$REAL_PATH" == "$prefix" ] || [[ "$REAL_PATH" == "$prefix"/* ]]; then
            allowed=true
            break
        fi
    done
    [ "$allowed" == true ] || die "path '$REAL_PATH' is not in PBS_REMOTE_ALLOWED_PATHS ($CONFIG_FILE)."
fi

[ -x "$CLIENT" ] || die "$CLIENT not found."

# --- BACKUP ---
# The client reads the password from file descriptor 0 (stdin from ssh).
PBS_PASSWORD_FD=0 PBS_FINGERPRINT="$FINGERPRINT" \
    exec "$CLIENT" backup "${ARCHIVE}:${REAL_PATH}" --repository "$REPOSITORY"
