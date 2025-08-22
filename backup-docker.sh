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
# START script
# =======================================================================
# Set the language
export LANG="en_US.UTF-8"
# Load the Pathes
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Error handling
set -euo pipefail
trap 'echo -e "\n❌ Error in Line $LINENO. Backup Script canceled."; exit 1' ERR
if [ "$EUID" -ne 0 ]; then
    echo "❌  Run as root!"
    exit 1
fi
# SET Variables
HOSTNAME="$(hostname)"
TIMESTAMP=$(date +"%Y%m%d_%H%M")
BACKUPDIR="${2:-"/mnt/backup"}/${HOSTNAME}"
if [ ! -d "$BACKUPDIR" ]; then
    mkdir -p "$BACKUPDIR"
fi
TEMPDIR="/var/tmp"
BACKUPDURATIONDAYS=${3:-2}
DOCKERROOTDIR=$(docker info --format '{{ .DockerRootDir }}')
# get docker-compose project name from variable or from current directory (lower case)
PROJECTNAME=$(echo "${1:-$(basename "$PWD")}" | tr '[:upper:]' '[:lower:]')
PROJECTBACKUPDIR="${BACKUPDIR}/${PROJECTNAME}"
if [ ! -d "$PROJECTBACKUPDIR" ]; then
    mkdir -p "$PROJECTBACKUPDIR"
fi
ALLCONTAINER=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECTNAME")
if [ -z "$ALLCONTAINER" ]; then
    echo "⚠️ Warning: Docker-Compose Folder: ${PROJECTNAME} was not found or has no running containers. Ignore Backup!"
    exit 2
fi
WORKINGDIR=$(for i in $ALLCONTAINER; do
    docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir"}}' "$i"
done | sort -u | head -n 1)
cd "$WORKINGDIR"
# =======================================================================
# PUT FUNCTIONS HERE
# Print Status
print_status() {
    local message=$1
    local min_width=100
    local width=$((${#message} + 10))
    if [ $width -lt $min_width ]; then
        width=$min_width
    fi
    printf "%-${width}s" "$message"
}
# Print Duration
print_duration() {
    local duration=$1
    printf "✅ (%02d:%02d:%02d)\n" $((duration / 3600)) $(((duration % 3600) / 60)) $((duration % 60))
}
# =======================================================================
# BACKUP DOCKER COMPOSE
START=$(date +%s)
echo "Backup Docker Project: ${PROJECTNAME}"
print_status "  📦 DockerCompose: $WORKINGDIR... "
OUTPUT=${TIMESTAMP}_${PROJECTNAME}.compose.tar.gz
tar -czf "${TEMPDIR}/${OUTPUT}" -C "$WORKINGDIR" .
cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
END=$(date +%s)
DURATION=$((END - START))
print_duration $DURATION
# =======================================================================
# BACKUP DOCKER VOLUMES AND DATABASES
# get all volumes of the given docker compose and ignore databases
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
            CONTAINERENV_DBPW=$(docker exec "${cont}" sh -c 'echo "$MYSQL_ROOT_PASSWORD $DB_ROOT_PASSWORD"')
            docker exec "${cont}" sh -c 'exec mariadb-dump -u root -p"$0" --all-databases' "${CONTAINERENV_DBPW}" | gzip -9 >"${TEMPDIR}/${OUTPUT}"
            cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
        elif echo "$IMAGE" | grep -qi "^mysql"; then
            # =======================================================================
            # BACKUP MySQL
            print_status "  🐬 MySQL: ${PROJECTNAME}.${CONTAINERNAME}.mysqldump.sql.gz... "
            OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mysqldump.sql.gz
            CONTAINERENV_DBPW=$(docker exec "${cont}" sh -c 'echo "$MYSQL_ROOT_PASSWORD $DB_ROOT_PASSWORD"')
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
                cd "$VOLUMEDIR"
                OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${VOLUMENAME}.volume.tar.gz
                tar -czf "${TEMPDIR}/${OUTPUT}" .
                cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
            else
                print_status "  🍃 MongoDB: ${PROJECTNAME}.${CONTAINERNAME}.mongodump.sql.gz... "
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
            DURATION=$((END - START))
            print_duration $DURATION
            break
        else
            # =======================================================================
            # BACKUP as a Volume
            VOLUMEDIR=${DOCKERROOTDIR}/volumes/$vol
            printf "%-100s" "  💾 LocalStorage: ${PROJECTNAME}.${VOLUMENAME}.volume.tar.gz... "
            OUTPUT=${TIMESTAMP}_${PROJECTNAME}.${VOLUMENAME}.volume.tar.gz
            cp -r "${VOLUMEDIR}" "${TEMPDIR}"
            tar -czf "${TEMPDIR}/${OUTPUT}" -C "${TEMPDIR}/${vol}" .
            rm -r "${TEMPDIR:?}/${vol:?}"
            cp "${TEMPDIR}/${OUTPUT}" "${PROJECTBACKUPDIR}" && rm "${TEMPDIR}/${OUTPUT}"
        fi
        END=$(date +%s)
        DURATION=$((END - START))
        print_duration $DURATION
    done
done
# =======================================================================
echo "  🗑️$ Cleanup old backups (older than ${BACKUPDURATIONDAYS} days)..."
find "$PROJECTBACKUPDIR" -name "*_$PROJECTNAME*.gz" -daystart -mtime +"$BACKUPDURATIONDAYS" | while read -r file; do
    echo "    - Delete: $file"
    rm "$file"
done
# =======================================================================
echo "  ✔️ All done."
