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
#
# Usage: backup-docker-all {BACKUPDIR} {BACKUPDURATIONDAYS}
# Example: backup-docker-all '/mnt/backup' 2 > /var/log/itpbackupscript.log
#
# =======================================================================

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
# =======================================================================
ALLCONTAINER=$(docker ps --format '{{.Names}}')
ALLPROJECTS=$(for i in $ALLCONTAINER; do docker inspect --format '{{ index .Config.Labels "com.docker.compose.project"}}' "$i"; done | sort -u)
### Do the stuff
for PROJECTNAME in $ALLPROJECTS; do
	backup-docker "$PROJECTNAME" "$BACKUPDIR" "$BACKUPDURATIONDAYS"
done
TIMESTAMP=$(date +"%Y%m%d_%H%M")
echo "$TIMESTAMP Backup for all Docker Compose Projects completed"
# =======================================================================
echo "===============> End of backup-docker-all SCRIPT for: '${HOSTNAME}' "

