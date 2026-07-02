#!/bin/bash
# =======================================================================
# BACKUP DOCKER SCRIPT for a single Docker Compose on a Server
# by dataCore
# inspired by https://github.com/alaub81/backup_docker_scripts/blob/main/backup-docker-volume.sh
#
# HISTORY
# 2024-04-15 Initial Version
# 2025-07-14 Redesign with generic backup scripts
# 2025-08-21 Optimierungen und >1
# 2026-05-07 Bugfixes & Optimierungen (root-check, TEMPDIR race, DB-done flag,
#            volume dedup, bind-mount skip, trap ERR entfernt)
#
# Usage:   backup-docker {DOCKERCOMPOSE-PROJECTNAME} {BACKUPDIR} {BACKUPDURATIONDAYS}
# Example: backup-docker 'datacorecloud' '/mnt/backup' 2 > /var/log/dataCoreBackupScript.log
# =======================================================================

# --- LOCALE & PATH ---
export LANG="en_US.UTF-8"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- ROOT CHECK (before anything else) ---
if [ "$EUID" -ne 0 ]; then
    echo "❌  Run as root!"
    exit 1
fi

# --- STRICT MODE ---
# Note: no ERR trap here – cleanup is attached to EXIT only, which fires on
# both normal exit and error. Attaching it to ERR as well caused the trap to
# run twice and reported wrong line numbers.
set -euo pipefail

# --- FUNCTIONS ---

cleanup() {
    local exit_code=$?
    if [ -n "${TEMPDIR:-}" ] && [ -d "$TEMPDIR" ]; then
        echo "🧹 Removing temporary folder: $TEMPDIR"
        rm -rf "$TEMPDIR"
    fi
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n❌ Backup script exited with error (code $exit_code)."
    fi
}
trap cleanup EXIT

# Print a fixed-width status line (no newline) so the duration aligns neatly
print_status() {
    local message="$1"
    local min_width=100
    local width=$(( ${#message} + 10 ))
    [ "$width" -lt "$min_width" ] && width=$min_width
    printf "%-${width}s" "$message"
}

# Print elapsed time in HH:MM:SS and add a newline
print_duration() {
    local duration=$1
    printf "✅ (%02d:%02d:%02d)\n" \
        $((duration / 3600)) $(( (duration % 3600) / 60 )) $((duration % 60))
}

# Move a file from TEMPDIR to the project backup dir, then remove the temp copy
commit_backup() {
    local output="$1"
    mv -f "${TEMPDIR}/${output}" "${PROJECTBACKUPDIR}/${output}"
}

# --- VARIABLES ---
HOSTNAME="$(hostname)"
TIMESTAMP=$(date +"%Y%m%d_%H%M")
PROJECTNAME=$(echo "${1:-$(basename "$PWD")}" | tr '[:upper:]' '[:lower:]')
BACKUPDURATIONDAYS=${3:-2}
DOCKERROOTDIR=$(docker info --format '{{ .DockerRootDir }}')
# Use a project-specific subfolder so parallel runs don't collide
TEMPDIR="/var/tmp/backup-docker/${PROJECTNAME}_$$"
mkdir -p "$TEMPDIR"

# --- BACKUP DIRECTORIES ---
BACKUPDIR="${2:-"/mnt/backup"}/${HOSTNAME}"
mkdir -p "$BACKUPDIR"
PROJECTBACKUPDIR="${BACKUPDIR}/${PROJECTNAME}"
mkdir -p "$PROJECTBACKUPDIR"

# --- SANITY CHECK: project running? ---
ALLCONTAINER=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECTNAME")
if [ -z "$ALLCONTAINER" ]; then
    echo "⚠️  Warning: Project '${PROJECTNAME}' not found or no running containers. Skipping."
    exit 2
fi

# --- RESOLVE COMPOSE WORKING DIR ---
WORKINGDIR=$(for i in $ALLCONTAINER; do
    docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir"}}' "$i"
done | sort -u | head -n 1)

if [ -z "$WORKINGDIR" ] || [ ! -d "$WORKINGDIR" ]; then
    echo "❌ Could not determine working directory for project '${PROJECTNAME}'."
    exit 1
fi
cd "$WORKINGDIR"

# =======================================================================
# BACKUP DOCKER COMPOSE CONFIG
START=$(date +%s)
echo "Backup Docker Project: ${PROJECTNAME}"
print_status "  📦 DockerCompose: $WORKINGDIR... "
OUTPUT="${TIMESTAMP}_${PROJECTNAME}.compose.tar.gz"
tar -czf "${TEMPDIR}/${OUTPUT}" -C "$WORKINGDIR" .
commit_backup "$OUTPUT"
print_duration $(( $(date +%s) - START ))

# =======================================================================
# BACKUP DOCKER VOLUMES AND DATABASES
CONTAINERS=$(docker compose ps -q 2>/dev/null || true)

# Track which DB containers we already dumped (avoid duplicate dumps per volume)
declare -A DB_DONE

for cont in $CONTAINERS; do
    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$cont" 2>/dev/null)
    CONTAINERNAME=$(docker inspect --format '{{.Name}}' "$cont" 2>/dev/null | sed 's|^/||')
    # Only named Docker volumes (anonymous and bind mounts are excluded)
    VOLUMES=$(docker inspect \
        --format '{{ range .Mounts }}{{ if eq .Type "volume" }}{{ .Name }}{{ "\n" }}{{ end }}{{ end }}' \
        "$cont" 2>/dev/null | grep -v '^$' || true)

    for vol in $VOLUMES; do
        START=$(date +%s)
        VOLUMENAME="${vol##*/}"

        # ---------------------------------------------------------------
        if echo "$IMAGE" | grep -qi "^mariadb"; then
            # BACKUP MariaDB – dump once per container, skip extra volumes
            if [ "${DB_DONE[$cont]+set}" ]; then continue; fi
            DB_DONE[$cont]=1
            OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mariadbdump.sql.gz"
            print_status "  🐬 MariaDB: ${OUTPUT}... "
            CONTAINERENV_DBPW=$(docker exec "${cont}" sh -c 'echo "${MYSQL_ROOT_PASSWORD:-${DB_ROOT_PASSWORD:-}}"')
            if [ -z "$CONTAINERENV_DBPW" ]; then
                echo "⚠️  MYSQL_ROOT_PASSWORD not set in container '${CONTAINERNAME}', skipping dump."
                continue
            fi
            docker exec "${cont}" sh -c 'exec mariadb-dump -u root -p"$0" --all-databases' \
                "${CONTAINERENV_DBPW}" | gzip -9 > "${TEMPDIR}/${OUTPUT}"
            commit_backup "$OUTPUT"

        # ---------------------------------------------------------------
        elif echo "$IMAGE" | grep -qi "^mysql"; then
            # BACKUP MySQL – dump once per container
            if [ "${DB_DONE[$cont]+set}" ]; then continue; fi
            DB_DONE[$cont]=1
            OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mysqldump.sql.gz"
            print_status "  🐬 MySQL: ${OUTPUT}... "
            CONTAINERENV_DBPW=$(docker exec "${cont}" sh -c 'echo "${MYSQL_ROOT_PASSWORD:-${DB_ROOT_PASSWORD:-}}"')
            if [ -z "$CONTAINERENV_DBPW" ]; then
                echo "⚠️  MYSQL_ROOT_PASSWORD not set in container '${CONTAINERNAME}', skipping dump."
                continue
            fi
            docker exec "${cont}" sh -c 'exec mysqldump -u root -p"$0" --all-databases' \
                "${CONTAINERENV_DBPW}" | gzip -9 > "${TEMPDIR}/${OUTPUT}"
            commit_backup "$OUTPUT"

        # ---------------------------------------------------------------
        elif echo "$IMAGE" | grep -qiE "^postgres|timescale/timescaledb|postgis/postgis|bitnami/postgresql"; then
            # BACKUP PostgreSQL – dump once per container
            if [ "${DB_DONE[$cont]+set}" ]; then continue; fi
            DB_DONE[$cont]=1
            OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.postgredump.sql.gz"
            print_status "  🐘 PostgreSQL: ${OUTPUT}... "
            CONTAINERENV_DBUSER=$(docker exec "${cont}" sh -c 'echo "$POSTGRES_USER"')
            if [ -z "$CONTAINERENV_DBUSER" ]; then
                echo "⚠️  POSTGRES_USER not set in container '${CONTAINERNAME}', skipping dump."
                continue
            fi
            docker exec "${cont}" sh -c 'exec pg_dumpall -U "$0"' \
                "${CONTAINERENV_DBUSER}" | gzip -9 > "${TEMPDIR}/${OUTPUT}"
            commit_backup "$OUTPUT"

        # ---------------------------------------------------------------
        elif echo "$IMAGE" | grep -qi "^mongo"; then
            # BACKUP MongoDB: dump data volume, tar config volume
            if echo "$vol" | grep -qi "config"; then
                OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${VOLUMENAME}.volume.tar.gz"
                print_status "  💾 LocalStorage (mongo-config): ${OUTPUT}... "
                VOLUMEDIR="${DOCKERROOTDIR}/volumes/${vol}"
                tar -czf "${TEMPDIR}/${OUTPUT}" -C "$VOLUMEDIR" .
                commit_backup "$OUTPUT"
            else
                if [ "${DB_DONE[$cont]+set}" ]; then continue; fi
                DB_DONE[$cont]=1
                OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mongodump.archive.gz"
                print_status "  🍃 MongoDB: ${OUTPUT}... "
                docker exec "${cont}" sh -c 'mongodump --archive --gzip --quiet' \
                    > "${TEMPDIR}/${OUTPUT}"
                commit_backup "$OUTPUT"
            fi

        # ---------------------------------------------------------------
        elif echo "$IMAGE" | grep -qiE "^gitlab/gitlab"; then
            # BACKUP GitLab – single tar per container, then skip remaining volumes
            if [ "${DB_DONE[$cont]+set}" ]; then continue; fi
            DB_DONE[$cont]=1
            OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.gitlabbackup.tar.gz"
            print_status "  🦊 GitLab: ${OUTPUT}... "
            docker exec -u root "${cont}" bash -c \
                "mkdir -p /mnt/backup-cache/code && chown git /mnt/backup-cache/code && chmod 700 /mnt/backup-cache/code"
            docker exec -u root "${cont}" bash -c \
                "export COMPRESS_CMD=gzip SKIP=artifacts,registry && gitlab-backup create --quiet"
            tar -czf "${TEMPDIR}/${OUTPUT}" -C /mnt/backup-cache/gitlab-backup .
            commit_backup "$OUTPUT"

        # ---------------------------------------------------------------
        else
            # BACKUP generic Docker Volume
            VOLUMEDIR="${DOCKERROOTDIR}/volumes/${vol}"
            if [ ! -d "$VOLUMEDIR" ]; then
                echo "  ⚠️  Volume dir not found, skipping: $VOLUMEDIR"
                continue
            fi
            OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${VOLUMENAME}.volume.tar.gz"
            print_status "  💾 LocalStorage: ${OUTPUT}... "
            # tar directly from the volume dir (no intermediate cp needed)
            tar -cpzf "${TEMPDIR}/${OUTPUT}" --numeric-owner -C "$VOLUMEDIR" .
            commit_backup "$OUTPUT"
        fi

        print_duration $(( $(date +%s) - START ))
    done
done

# =======================================================================
# CLEANUP OLD BACKUPS
echo "  🗑️  Cleanup old backups (older than ${BACKUPDURATIONDAYS} days)..."
find "$PROJECTBACKUPDIR" -name "*_${PROJECTNAME}*" \( -name "*.gz" -o -name "*.tar" \) \
    -daystart -mtime +"$BACKUPDURATIONDAYS" \
    -exec echo "    - Delete: {}" \; -exec rm -f {} \;

echo "  ✔️  All done."
