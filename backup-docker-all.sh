#!/bin/bash
# =======================================================================
# BACKUP DOCKER ALL SCRIPT for all Containers on a Server
# by dataCore
# inspired by https://github.com/alaub81/backup_docker_scripts/blob/main/backup-docker-volume.sh
#
# iterates over all docker container and backups each docker container with the corresponding 'docker-backup.sh'
#
# HISTORY
# 2024-04-15 Initial Version
# 2025-07-14 Redesign with generic backup scripts
# 2026-10-19 Refuses an unmounted BACKUPDIR, lock shared with update-docker-all,
#            PBS upload of this host's dir only, skip code 75
#
# Usage: backup-docker-all {BACKUPDIR} {BACKUPDURATIONDAYS} {PROXMOXBACKUP}
# Example: backup-docker-all '/mnt/backup' 2 'root@pam@192.168.1.100:Backup-HDD' > /var/log/itpbackupscript.log
# Env:     ALLOW_UNMOUNTED=1 – back up even when BACKUPDIR is not a mount point
#
# =======================================================================
# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo or as root."
  exit 1
fi
# Backup and update runs must not overlap (an update recreating containers
# while their volumes are tarred): backup-docker-all and update-docker-all
# share this lock and wait up to 1 h for each other.
LOCKFILE=/run/lock/datacore-docker.lock
exec 9>"$LOCKFILE"
if ! flock -w 3600 9; then
    echo "❌ ${LOCKFILE} is still held by another backup/update run after 1 h. Aborting."
    exit 1
fi
# Update scripts
update-scripts
# START script
echo "===============> BACKUP 📦 DOCKER ALL SCRIPT"
HOSTNAME="$(hostname)"
echo "===============> Starting backup-docker-all SCRIPT for: '${HOSTNAME}'"
# Set the language
export LANG="en_US.UTF-8"
# Load the Pathes
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Error handling
set -euo pipefail
trap 'echo -e "\n❌ Error in Line $LINENO. Backup Script canceled."; exit 1' ERR
# SET Variables
TIMESTAMP=$(date +"%Y%m%d_%H%M")
BACKUPDIR="${1:-"/mnt/backup"}"
BACKUPDURATIONDAYS=${2:-2}
# =======================================================================
# Print Variables
echo "HOSTNAME=${HOSTNAME}"
echo "CURRENTDATE=${TIMESTAMP}"
echo "BACKUPDIR=${BACKUPDIR}"
echo "BACKUPDURATIONDAYS=${BACKUPDURATIONDAYS}"
# A missing CIFS/NFS mount would otherwise fill the local disk unnoticed
if ! mountpoint -q "$BACKUPDIR"; then
    if [ "${ALLOW_UNMOUNTED:-0}" == "1" ]; then
        echo "⚠️  '${BACKUPDIR}' is not a mount point – writing to the local disk (ALLOW_UNMOUNTED=1)."
    else
        echo "❌ '${BACKUPDIR}' is not a mount point. Mount it, or set ALLOW_UNMOUNTED=1 to back up to the local disk."
        exit 1
    fi
fi
# =======================================================================
ALLCONTAINER=$(docker ps --format '{{.Names}}')
ALLPROJECTS=$(for i in $ALLCONTAINER; do docker inspect --format '{{ index .Config.Labels "com.docker.compose.project"}}' "$i"; done | sort -u)
### Do the stuff
# A failing project must not abort the remaining backups – collect failures
# and report them at the end with a non-zero exit code for monitoring.
FAILED_PROJECTS=()
for PROJECTNAME in $ALLPROJECTS; do
    RC=0
    backup-docker "$PROJECTNAME" "$BACKUPDIR" "$BACKUPDURATIONDAYS" || RC=$?
    # 75 = skipped (EXIT_SKIPPED in backup-docker); 2 is a real error of tar etc.
    if [ "$RC" -eq 75 ]; then
        echo "⚠️  Project '${PROJECTNAME}' skipped (no running containers)."
    elif [ "$RC" -ne 0 ]; then
        echo "❌ Backup of project '${PROJECTNAME}' failed (exit $RC). Continuing with next project."
        FAILED_PROJECTS+=("$PROJECTNAME")
    fi
done
TIMESTAMP=$(date +"%Y%m%d_%H%M")
echo "$TIMESTAMP Backup for all Docker Compose Projects completed"
# =======================================================================
# OPTIONAL: UPLOAD TO PROXMOX BACKUP SERVER
# Check if PBS_REPOSITORY is provided as 3rd argument
PBS_REPO="${3:-}"

if [ -n "$PBS_REPO" ]; then
    START_PBS=$(date +%s)
    echo "🚀 Uploading to PBS: $HOSTNAME (All Projects)..."

    # nano ~/.bashrc
    # export PBS_PASSWORD="Dein_LXC_Passwort"
    # export PBS_FINGERPRINT="Dein:LXC:Fingerprint:von:vorhin"
    # source ~/.bashrc

    # Archiv: hostname.pxar – only this host's dir: BACKUPDIR may be a share
    # that other hosts back up to as well
    proxmox-backup-client backup \
        "${HOSTNAME}.pxar:${BACKUPDIR}/${HOSTNAME}" \
        --repository "$PBS_REPO" \
        --quiet

    END_PBS=$(date +%s)
    echo "✅ PBS upload completed in $((END_PBS - START_PBS))s"
fi
# =======================================================================
echo "===============> End of backup-docker-all SCRIPT for: '${HOSTNAME}' "
if [ "${#FAILED_PROJECTS[@]}" -gt 0 ]; then
    echo "❌ Failed projects: ${FAILED_PROJECTS[*]}"
    exit 1
fi
