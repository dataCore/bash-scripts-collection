#!/bin/bash
# ============================================================================
# RESTORE DOCKER SCRIPT for a single Docker Compose Project
# by dataCore
#
# HISTORY
# 2024-07-22 Initial Version
# 2026-05-07 Bugfixes & Optimierungen (docker inspect fix, healthcheck fallback,
#            ELAPSED reset per DB, MongoDB $CONTAINER typo, GitLab path fix,
#            root check moved up, trap cleanup added)
#
# INFO: Run from the docker-compose project directory, e.g.:
#       cd /etc/docker-compose/datacoreipam/
# Usage:   restore-docker {BACKUPDIR}
# Example: restore-docker '/mnt/backup'
# ============================================================================

# --- ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo or as root."
    exit 1
fi

# --- LOCALE & PATH ---
export LANG="en_US.UTF-8"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- STRICT MODE ---
set -euo pipefail

# --- FUNCTIONS ---

cleanup() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n❌ Error on line $LINENO. Restore script aborted."
    fi
}
trap cleanup EXIT

# Wait until a compose service is ready to accept connections.
# Priority: (1) Docker healthcheck → (2) in-container DB ping → (3) plain running state
# Usage: wait_healthy <service_name> [db_type]
#   db_type: mariadb | mysql | postgres | mongo (optional – enables in-container probe)
wait_healthy() {
    local service="$1"
    local db_type="${2:-}"
    local elapsed=0

    echo "⏳ Waiting for '${service}' to be ready (timeout: ${TIMEOUT}s)..."

    while true; do
        local cid
        cid=$(docker compose ps -q "$service" 2>/dev/null || true)

        if [ -n "$cid" ]; then
            # --- Check 1: Docker healthcheck (if defined) ---
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "$cid" 2>/dev/null || true)
            if [ "$health" == "healthy" ]; then
                echo "✅ '${service}' is healthy."
                return 0
            fi

            # --- Check 2: In-container DB readiness probe (no healthcheck defined) ---
            # Runs inside the container → network-topology independent
            if [ -z "$health" ] || [ "$health" == "<no value>" ]; then
                local ready=false
                case "$db_type" in
                    mariadb|mysql)
                        docker exec "$cid" sh -c \
                            'mariadb-admin ping -u root -p"${MYSQL_ROOT_PASSWORD}" --silent' \
                            2>/dev/null && ready=true || true
                        ;;
                    postgres)
                        docker exec "$cid" sh -c \
                            'pg_isready -U "${POSTGRES_USER}" --quiet' \
                            2>/dev/null && ready=true || true
                        ;;
                    mongo)
                        docker exec "$cid" sh -c \
                            'mongosh --quiet --eval "db.adminCommand(\"ping\")" 2>/dev/null || \
                             mongo --quiet --eval "db.adminCommand(\"ping\")" 2>/dev/null' \
                            2>/dev/null && ready=true || true
                        ;;
                    *)
                        # Non-DB service: just check if container is running
                        local running
                        running=$(docker inspect --format='{{.State.Running}}' "$cid" 2>/dev/null || true)
                        [ "$running" == "true" ] && ready=true
                        ;;
                esac

                if [ "$ready" == "true" ]; then
                    echo "✅ '${service}' is ready."
                    return 0
                fi
            fi
        fi

        if [ "$elapsed" -ge "$TIMEOUT" ]; then
            echo "❌ Timeout after ${TIMEOUT}s: '${service}' is not ready."
            exit 1
        fi

        sleep "$WAIT_INTERVAL"
        elapsed=$(( elapsed + WAIT_INTERVAL ))
    done
}

# --- VARIABLES ---
HOSTNAME="$(hostname)"
PROJECTNAME=$(basename "$PWD")
BACKUPDIR="${1:-"/mnt/backup"}/${HOSTNAME}/${PROJECTNAME}"
DOCKERROOTDIR=$(docker info --format '{{ .DockerRootDir }}')
TIMEOUT=60        # Max wait time in seconds
WAIT_INTERVAL=2   # Poll interval in seconds

# =======================================================================
echo "===============> RESTORE 📦 DOCKER SCRIPT"
echo "===============> Host: '${HOSTNAME}'  Project: '${PROJECTNAME}'"

# --- VALIDATE BACKUP DIR ---
if [ ! -d "$BACKUPDIR" ]; then
    echo "❌ Backup directory not found: $BACKUPDIR"
    exit 1
fi

# =======================================================================
# SHOW AVAILABLE BACKUPS & LET USER CHOOSE
echo ""
echo "📦 Available backups for project '${PROJECTNAME}':"

declare -a COMPOSES MARIADBS MYSQLS POSTGRES MONGOS GITLABS VOLUMES
declare -A OPTIONS
i=1

for file in "$BACKUPDIR"/*"$PROJECTNAME"*; do
    [ -f "$file" ] || continue   # skip if glob matched nothing
    filename=$(basename "$file")
    case "$filename" in
        *.compose.tar.gz)       COMPOSES+=("$filename") ;;
        *.mariadbdump.sql.gz)   MARIADBS+=("$filename") ;;
        *.mysqldump.sql.gz)     MYSQLS+=("$filename") ;;
        *.postgredump.sql.gz)   POSTGRES+=("$filename") ;;
        *.mongodump.sql.gz)     MONGOS+=("$filename") ;;
        *.gitlabbackup.tar.gz)  GITLABS+=("$filename") ;;
        *.volume.tar.gz)        VOLUMES+=("$filename") ;;
    esac
done

# Print a group of backup files with a sequential index
print_group() {
    local icon="$1"
    local label="$2"
    shift 2
    local group=("$@")
    if [ "${#group[@]}" -gt 0 ]; then
        echo "$icon $label:"
        for item in "${group[@]}"; do
            printf "  - [%02d] %s\n" "$i" "$item"
            OPTIONS[$i]="${BACKUPDIR}/${item}"
            (( i++ ))
        done
    fi
}

print_group "📦" "DockerCompose"  "${COMPOSES[@]+"${COMPOSES[@]}"}"
print_group "🐬" "MariaDB"        "${MARIADBS[@]+"${MARIADBS[@]}"}"
print_group "🐬" "MySQL"          "${MYSQLS[@]+"${MYSQLS[@]}"}"
print_group "🐘" "PostgreSQL"     "${POSTGRES[@]+"${POSTGRES[@]}"}"
print_group "🍃" "MongoDB"        "${MONGOS[@]+"${MONGOS[@]}"}"
print_group "🦊" "GitLab"         "${GITLABS[@]+"${GITLABS[@]}"}"
print_group "💾" "LocalStorage"   "${VOLUMES[@]+"${VOLUMES[@]}"}"

if [ "${#OPTIONS[@]}" -eq 0 ]; then
    echo "❌ No backup files found in: $BACKUPDIR"
    exit 1
fi

echo ""
read -r -p "❓ Choose which backup to restore [1-$(( i - 1 ))]: " CHOICE
NORMALIZED_CHOICE=$(( 10#$CHOICE ))
SELECTED="${OPTIONS[$NORMALIZED_CHOICE]:-}"

if [ -z "$SELECTED" ]; then
    echo "❌ Invalid selection: $CHOICE"
    exit 1
fi

# =======================================================================
echo ""
echo "🔄 Restoring: $(basename "$SELECTED")"

# Extract the compose service name from the backup filename:
# Pattern: {date}_{time}_{project}.{servicename}.{backuptype}.ext
CONTAINERNAME=$(basename "$SELECTED" | sed -n 's/^[0-9]*_[0-9]*_[^.]*\.\([^.]*\)\..*/\1/p')

# =======================================================================
# RESTORE DOCKER COMPOSE CONFIG
if [[ "$SELECTED" == *.compose.tar.gz ]]; then
    echo "📦 Restoring Docker Compose config..."
    tar -xzf "$SELECTED" -C "$PWD"
    echo "✅ Compose config restored to $PWD"

# =======================================================================
# RESTORE MariaDB
elif [[ "$SELECTED" == *.mariadbdump.sql.gz ]]; then
    echo "🐬 Restoring MariaDB..."
    docker compose up -d "$CONTAINERNAME"
    wait_healthy "$CONTAINERNAME" mariadb
    CONTAINERENV_ROOTPW=$(docker compose exec "$CONTAINERNAME" sh -c 'echo "${MYSQL_ROOT_PASSWORD:-}"')
    if [ -z "$CONTAINERENV_ROOTPW" ]; then
        echo "❌ MYSQL_ROOT_PASSWORD is not set in container '${CONTAINERNAME}'."
        exit 1
    fi
    gunzip -c "$SELECTED" | docker compose exec -T "$CONTAINERNAME" \
        sh -c "mariadb -u root -p${CONTAINERENV_ROOTPW}"
    echo "✅ MariaDB restored"

# =======================================================================
# RESTORE MySQL
elif [[ "$SELECTED" == *.mysqldump.sql.gz ]]; then
    echo "🐬 Restoring MySQL..."
    docker compose up -d "$CONTAINERNAME"
    wait_healthy "$CONTAINERNAME" mysql
    CONTAINERENV_ROOTPW=$(docker compose exec "$CONTAINERNAME" sh -c 'echo "${MYSQL_ROOT_PASSWORD:-}"')
    if [ -z "$CONTAINERENV_ROOTPW" ]; then
        echo "❌ MYSQL_ROOT_PASSWORD is not set in container '${CONTAINERNAME}'."
        exit 1
    fi
    gunzip -c "$SELECTED" | docker compose exec -T "$CONTAINERNAME" \
        sh -c "mysql -u root -p${CONTAINERENV_ROOTPW}"
    echo "✅ MySQL restored"

# =======================================================================
# RESTORE PostgreSQL
elif [[ "$SELECTED" == *.postgredump.sql.gz ]]; then
    echo "🐘 Restoring PostgreSQL..."
    docker compose up -d "$CONTAINERNAME"
    wait_healthy "$CONTAINERNAME" postgres
    CONTAINERENV_DBNAME=$(docker compose exec "$CONTAINERNAME" sh -c 'echo "${POSTGRES_DB:-}"')
    CONTAINERENV_DBUSER=$(docker compose exec "$CONTAINERNAME" sh -c 'echo "${POSTGRES_USER:-}"')
    if [ -z "$CONTAINERENV_DBUSER" ]; then
        echo "❌ POSTGRES_USER is not set in container '${CONTAINERNAME}'."
        exit 1
    fi
    echo "  Database: '${CONTAINERENV_DBNAME:-postgres}', User: '${CONTAINERENV_DBUSER}'"
    gunzip -c "$SELECTED" | docker compose exec -T "$CONTAINERNAME" \
        psql -U "$CONTAINERENV_DBUSER" -d "${CONTAINERENV_DBNAME:-postgres}"
    echo "✅ PostgreSQL restored"

# =======================================================================
# RESTORE MongoDB
elif [[ "$SELECTED" == *.mongodump.sql.gz ]]; then
    echo "🍃 Restoring MongoDB..."
    docker compose up -d "$CONTAINERNAME"
    wait_healthy "$CONTAINERNAME" mongo
    # Fixed: use $CONTAINERNAME (not the undefined $CONTAINER variable)
    gunzip -c "$SELECTED" | docker compose exec -T "$CONTAINERNAME" \
        sh -c 'mongorestore --archive --gzip'
    echo "✅ MongoDB restored"

# =======================================================================
# RESTORE GitLab
elif [[ "$SELECTED" == *.gitlabbackup.tar.gz ]]; then
    echo "🦊 Restoring GitLab..."
    docker compose up -d "$CONTAINERNAME"

    # Unpack backup archive into the GitLab backup mount
    GITLAB_BACKUP_HOST="/mnt/backup-cache/gitlab-backup"
    mkdir -p "$GITLAB_BACKUP_HOST"
    tar -xzf "$SELECTED" -C "$GITLAB_BACKUP_HOST"

    # The extracted file must be owned by 'git' inside the container
    docker compose exec "$CONTAINERNAME" bash -c \
        "chown git /mnt/backup-cache/gitlab-backup && chmod 700 /mnt/backup-cache/gitlab-backup"

    # Stop application services before restore
    docker compose exec "$CONTAINERNAME" bash -c \
        "gitlab-ctl stop puma && gitlab-ctl stop sidekiq && gitlab-ctl status"

    # Determine the backup timestamp token from the archive filename
    # GitLab restore expects the token part (everything before _gitlab_backup.tar)
    BACKUP_TOKEN=$(ls "${GITLAB_BACKUP_HOST}"/*_gitlab_backup.tar 2>/dev/null | head -n 1 | xargs basename | sed 's/_gitlab_backup\.tar//')
    if [ -z "$BACKUP_TOKEN" ]; then
        echo "❌ Could not find a gitlab_backup.tar file in ${GITLAB_BACKUP_HOST}"
        exit 1
    fi

    docker compose exec "$CONTAINERNAME" bash -c \
        "gitlab-backup restore BACKUP=${BACKUP_TOKEN} force=yes"
    docker compose exec "$CONTAINERNAME" bash -c \
        "gitlab-ctl restart && gitlab-rake gitlab:check SANITIZE=true && gitlab-rake gitlab:doctor:secrets"
    docker compose exec "$CONTAINERNAME" bash -c \
        "gitlab-rake gitlab:artifacts:check && gitlab-rake gitlab:lfs:check && gitlab-rake gitlab:uploads:check"
    echo "✅ GitLab restored"

# =======================================================================
# RESTORE Volume
elif [[ "$SELECTED" == *.volume.tar.gz ]]; then
    echo "💾 Restoring Volume..."
    TARGETDIR="${DOCKERROOTDIR}/volumes/${CONTAINERNAME}"
    if [ -d "$TARGETDIR" ]; then
        read -r -p "⚠️  Folder '$TARGETDIR' already exists. Delete it first? (y/n): " CONFIRM
        if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
            rm -rf "$TARGETDIR"
            echo "  Folder deleted."
        else
            echo "❌ Restore cancelled."
            exit 1
        fi
    fi
    mkdir -p "$TARGETDIR"
    tar -xzf "$SELECTED" -C "$TARGETDIR"
    echo "✅ Volume restored to $TARGETDIR"

else
    echo "❌ Unknown backup type: $(basename "$SELECTED")"
    exit 1
fi

# =======================================================================
echo ""
echo "===============> Restore complete on Host: '${HOSTNAME}'"
