#!/bin/bash
# =======================================================================
# BACKUP DOCKER SCRIPT for a single Docker Compose on a Server
# by dataCore
# inspired by https://github.com/alaub81/backup_docker_scripts/blob/main/backup-docker-volume.sh
#
#
# HISTORY
# 2024-04-15 Initial Version
# 2025-07-14 Redesign with generic backup scripts
# 2025-08-21 Optimierungen und >1
#
# Usage: backup-docker {DOCKERCOMPOSE-PROJECTNAME} {BACKUPDIR} {BACKUPDURATIONDAYS}"
# Example: backup-docker 'datacorecloud' '/mnt/backup' 2 > /var/log/itpbackupscript.log"
#
# =======================================================================

# Set the language
export LANG="en_US.UTF-8"
# Load paths
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Error handling
set -euo pipefail

# --- FUNCTIONS ---
# Cleanup function to remove the entire temp folder
cleanup() {
    local exit_code=$?
    # Only try to remove if TEMPDIR is defined to avoid accidents
    if [ -n "${TEMPDIR:-}" ] && [ -d "$TEMPDIR" ]; then
        echo "🧹 Removing temporary folder: $TEMPDIR"
        rm -rf "$TEMPDIR"
    fi
    
    if [ $exit_code -ne 0 ]; then
        echo -e "\n❌ Error in Line $LINENO. Backup Script canceled."
    fi
}

# Print Status with dynamic width
print_status() {
    local message=$1
    local min_width=100
    local width=$((${#message} + 10))
    if [ $width -lt $min_width ]; then
        width=$min_width
    fi
    printf "%-${width}s" "$message"
}

# Print Duration in HH:MM:SS
print_duration() {
    local duration=$1
    printf "✅ (%02d:%02d:%02d)\n" $((duration / 3600)) $(((duration % 3600) / 60)) $((duration % 60))
}

# Trap ensures cleanup runs on EXIT (success) or ERR (failure)
trap cleanup EXIT ERR

# --- SET Variables ---
HOSTNAME="$(hostname)"
TIMESTAMP=$(date +"%Y%m%d_%H%M")
PROJECTNAME=$(echo "${1:-$(basename "$PWD")}" | tr '[:upper:]' '[:lower:]')
BACKUPDURATIONDAYS=${3:-2}
DOCKERROOTDIR=$(docker info --format '{{ .DockerRootDir }}')
TEMPDIR="/var/tmp/backup-docker"

# Create temp dir immediately
mkdir -p "$TEMPDIR"

if [ "$EUID" -ne 0 ]; then
    echo "❌  Run as root!"
    exit 1
fi

# SET Backup Directory
BACKUPDIR="${2:-"/mnt/backup"}/${HOSTNAME}"
mkdir -p "$BACKUPDIR"

PROJECTBACKUPDIR="${BACKUPDIR}/${PROJECTNAME}"
mkdir -p "$PROJECTBACKUPDIR"

# Check for running containers
ALLCONTAINER=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECTNAME")
if [ -z "$ALLCONTAINER" ]; then
    echo "⚠️ Warning: Project ${PROJECTNAME} not found. Skipping."
    exit 2
fi

# Get compose working directory
WORKINGDIR=$(for i in $ALLCONTAINER; do
    docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir"}}' "$i"
done | sort -u | head -n 1)
cd "$WORKINGDIR"

# BACKUP DOCKER COMPOSE CONFIG
START=$(date +%s)
echo "Backup Docker Project: ${PROJECTNAME}"
print_status "  📦 DockerCompose: $WORKINGDIR... "
OUTPUT=${TIMESTAMP}_${PROJECTNAME}.compose.tar.gz
tar -czf "${TEMPDIR}/${OUTPUT}" -C "$WORKINGDIR" .
cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
END=$(date +%s)
print_duration $((END - START))

# =======================================================================
# BACKUP DOCKER VOLUMES AND DATABASES
CONTAINERS=$(docker compose ps -q 2>/dev/null || true)
for cont in $CONTAINERS; do
    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$cont" 2>/dev/null)
    CONTAINERNAME=$(docker inspect --format '{{.Name}}' "$cont" 2>/dev/null | sed 's/^\/\(.*\)/\1/')
    VOLUMES=$(docker inspect --format '{{ range .Mounts }}{{ .Name }}{{ "\n" }}{{ end }}' "$cont" 2>/dev/null || true | grep -v '^$')
    
    for vol in $VOLUMES; do
        START=$(date +%s)
        VOLUMENAME=${vol##*/}
        
        if echo "$IMAGE" | grep -qi "^mariadb"; then
            # =======================================================================
            # BACKUP MariaDB
            print_status "  🐬 MariaDB: ${PROJECTNAME}.${CONTAINERNAME}.mariadbdump.sql.gz... "
            OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mariadbdump.sql.gz
            CONTAINERENV_DBPW=$(docker exec "${cont}" sh -c 'echo "${MYSQL_ROOT_PASSWORD:-$DB_ROOT_PASSWORD}"')
            docker exec "${cont}" sh -c 'exec mariadb-dump -u root -p"$0" --all-databases' "${CONTAINERENV_DBPW}" | gzip -9 >"${TEMPDIR}/${OUTPUT}"
            cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
        elif echo "$IMAGE" | grep -qi "^mysql"; then
            # =======================================================================
            # BACKUP MySQL
            print_status "  🐬 MySQL: ${PROJECTNAME}.${CONTAINERNAME}.mysqldump.sql.gz... "
            OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mysqldump.sql.gz
            CONTAINERENV_DBPW=$(docker exec "${cont}" sh -c 'echo "${MYSQL_ROOT_PASSWORD:-$DB_ROOT_PASSWORD}"')
            docker exec "${cont}" sh -c 'exec mysqldump -u root -p"$0" --all-databases' "${CONTAINERENV_DBPW}" | gzip -9 >"${TEMPDIR}/${OUTPUT}"
            cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
        elif echo "$IMAGE" | grep -qi "^postgres"; then
            # =======================================================================
            # BACKUP PostgreSQL
            print_status "  🐘️ PostgreSQL: ${PROJECTNAME}.${CONTAINERNAME}.postgredump.sql.gz... "
            OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.postgredump.sql.gz
            CONTAINERENV_DBUSER=$(docker exec "${cont}" sh -c 'echo "$POSTGRES_USER"')
            docker exec "${cont}" sh -c 'exec pg_dumpall -U "$0"' "${CONTAINERENV_DBUSER}" | gzip -9 >"${TEMPDIR}/${OUTPUT}"
            cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
        elif echo "$IMAGE" | grep -qi "^mongo"; then
            # =======================================================================
            # BACKUP MongoDB
            if echo "$vol" | grep -qi "config"; then
                VOLUMEDIR=${DOCKERROOTDIR}/volumes/$vol
                print_status "  💾 LocalStorage: ${PROJECTNAME}.${VOLUMENAME}.volume.tar.gz... "
                OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${VOLUMENAME}.volume.tar.gz
                tar -czf "${TEMPDIR}/${OUTPUT}" -C "$VOLUMEDIR" .
                cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
            else
                print_status "  🍃 MongoDB: ${PROJECTNAME}.${CONTAINERNAME}.mongodump... "
                OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mongodump.sql.gz
                docker exec "${cont}" sh -c 'mongodump --archive --gzip --quiet' >"${TEMPDIR}/${OUTPUT}"
                cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
            fi

        elif echo "$IMAGE" | grep -qiE "^gitlab/gitlab"; then
            # =======================================================================
            # BACKUP Gitlab
            print_status "  🦊 Gitlab: ${PROJECTNAME}.gitlabbackup.tar.gz... "
            OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.gitlabbackup.tar.gz
            docker exec -u root "${cont}" bash -c "mkdir -p /mnt/backup-cache/code && chown git /mnt/backup-cache/code && chmod 700 /mnt/backup-cache/code"
            docker exec -u root "${cont}" bash -c "export COMPRESS_CMD=gzip SKIP=artifacts,registry && gitlab-backup create --quiet"
            tar -czf "${TEMPDIR}/${OUTPUT}" -C /mnt/backup-cache/gitlab-backup .
            # rm -rf /mnt/backup-cache/gitlab-backup/code
            cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
            # Cancel other volume backups for this container
            END=$(date +%s)
            print_duration $((END - START))
            break
        else
            # =======================================================================
            # BACKUP as a Volume
            VOLUMEDIR=${DOCKERROOTDIR}/volumes/$vol
            print_status "  💾 LocalStorage: ${PROJECTNAME}.${VOLUMENAME}.volume.tar.gz... "
            OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${VOLUMENAME}.volume.tar.gz
            # Sub-copy within the temp folder
            cp -a "${VOLUMEDIR}" "${TEMPDIR}/vol_data"
            tar -cpzf "${TEMPDIR}/${OUTPUT}" --numeric-owner -C "${TEMPDIR}/vol_data" .
            rm -rf "${TEMPDIR}/vol_data"
            cp -p "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
        fi
        END=$(date +%s)
        print_duration $((END - START))
    done
done
# =======================================================================
# CLEANUP OLD BACKUPS
echo "  🗑️ Cleanup old backups (older than ${BACKUPDURATIONDAYS} days)..."
find "$PROJECTBACKUPDIR" -name "*_$PROJECTNAME*.gz" -daystart -mtime +"$BACKUPDURATIONDAYS" -exec echo "    - Delete: {}" \; -exec rm {} \;

echo "  ✔️ All done."