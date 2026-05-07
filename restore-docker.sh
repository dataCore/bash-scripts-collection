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

# Start a compose service and surface a clear error if it fails.
# docker compose up -d swallows the OCI/runc error text – we capture stderr
# and print it explicitly so the operator knows what to fix.
compose_up() {
    local service="$1"
    local output
    if ! output=$(docker compose up -d "$service" 2>&1); then
        echo "❌ Failed to start service '${service}':"
        echo "$output" | sed 's/^/   /'
        # Common hint: missing bind-mount source files on the host
        if echo "$output" | grep -q "not a directory\|No such file or directory"; then
            echo ""
            echo "💡 Hint: A bind-mount source path is missing on this host."
            echo "   Check the volumes: section in docker-compose.yml and ensure"
            echo "   all host paths exist with the correct type (file vs directory)."
            echo "   Example fix:  echo 'Europe/Zurich' > /etc/timezone"
        fi
        exit 1
    fi
    echo "$output"
}

# Wait until a compose service is ready to accept connections.
# Priority: (1a) Docker healthcheck status = healthy
#           (1b) Re-run the healthcheck test cmd directly (catches broken CMD vs CMD-SHELL configs)
#           (2)  In-container DB ping (no healthcheck defined at all)
#           (3)  Plain running state (non-DB services)
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
            # --- Check 1a: Docker healthcheck status ---
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "$cid" 2>/dev/null || true)
            if [ "$health" == "healthy" ]; then
                echo "✅ '${service}' is healthy."
                return 0
            fi

            # --- Check 1b: Re-run the healthcheck test command ourselves ---
            # Handles misconfigured healthchecks (e.g. CMD instead of CMD-SHELL)
            # by running the test string via sh -c directly in the container.
            if [ "$health" == "starting" ] || [ "$health" == "unhealthy" ]; then
                local hc_test
                # Extract the test array: first element is CMD/CMD-SHELL, rest is the command
                hc_test=$(docker inspect \
                    --format='{{range $i,$v := .Config.Healthcheck.Test}}{{if gt $i 1}} {{end}}{{if gt $i 0}}{{$v}}{{end}}{{end}}' \
                    "$cid" 2>/dev/null || true)
                if [ -n "$hc_test" ]; then
                    if docker exec "$cid" sh -c "$hc_test" 2>/dev/null; then
                        echo "✅ '${service}' passed healthcheck test."
                        return 0
                    fi
                fi
            fi

            # --- Check 2: In-container DB readiness probe (no healthcheck defined) ---
            # Runs inside the container → network-topology independent
            if [ -z "$health" ] || [ "$health" == "<no value>" ]; then
                local ready=false
                case "$db_type" in
                    mariadb|mysql)
                        docker exec "$cid" sh -c \
                            'mariadb-admin ping -u root -p"${MYSQL_ROOT_PASSWORD:-$DB_ROOT_PASSWORD}" --silent' \
                            2>/dev/null && ready=true || true
                        ;;
                    postgres)
                        docker exec "$cid" sh -c \
                            'pg_isready -U "$POSTGRES_USER" --quiet' \
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

# Extract the container name from the backup filename:
# Pattern: {date}_{time}_{project}.{containername}.{backuptype}.ext
# compose.tar.gz has no containername segment → CONTAINERNAME will be empty, that is fine.
CONTAINERNAME=$(basename "$SELECTED" | sed -n 's/^[0-9]*_[0-9]*_[^.]*\.\([^.]*\)\..*/\1/p')

# Resolve the compose SERVICE name from the container name.
# Not needed for compose.tar.gz restores – skip resolution in that case.
# Strategy 1: container already exists (stopped) → read label directly
# Strategy 2: parse docker compose config → match container_name to service
# Strategy 3: fall back to using container name as-is (simple projects)
SERVICENAME=""
if [[ "$SELECTED" != *.compose.tar.gz ]]; then
    if [ -n "$CONTAINERNAME" ]; then
        SERVICENAME=$(docker ps -a \
            --filter "name=^/${CONTAINERNAME}$" \
            --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null | head -n1 || true)

        if [ -z "$SERVICENAME" ]; then
            SERVICENAME=$(docker compose config 2>/dev/null | awk -v cn="$CONTAINERNAME" '
                /^services:/ { in_svc=1; next }
                in_svc && /^  [a-zA-Z]/ { cur=$1; gsub(/:$/,"",cur) }
                in_svc && /container_name:/ { gsub(/[[:space:]]/,"",$2); if ($2==cn) { print cur; exit } }
            ')
        fi

        if [ -z "$SERVICENAME" ]; then
            SERVICENAME="$CONTAINERNAME"
            echo "⚠️  Could not resolve service name for '${CONTAINERNAME}', using as-is."
        fi
    fi

    if [ -z "$SERVICENAME" ]; then
        echo "❌ Could not determine compose service name from backup filename."
        exit 1
    fi
    [ "$SERVICENAME" != "$CONTAINERNAME" ] && echo "ℹ️  Container '${CONTAINERNAME}' → Service '${SERVICENAME}'"
fi

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
    compose_up "$SERVICENAME"
    wait_healthy "$SERVICENAME" mariadb
    # Verify root password is available inside the container.
    # Supports MYSQL_ROOT_PASSWORD (standard) and DB_ROOT_PASSWORD (some stacks).
    ROOTPW_CHECK=$(docker compose exec "$SERVICENAME" \
        sh -c 'echo "${MYSQL_ROOT_PASSWORD:-${DB_ROOT_PASSWORD:-}}"' 2>/dev/null | tr -d '\r\n')
    if [ -z "$ROOTPW_CHECK" ]; then
        echo "❌ Neither MYSQL_ROOT_PASSWORD nor DB_ROOT_PASSWORD is set in container '${SERVICENAME}'."
        echo "   Check the env_file / environment: section in your docker-compose.yml."
        exit 1
    fi
    gunzip -c "$SELECTED" | docker compose exec -T "$SERVICENAME" \
        sh -c 'mariadb -u root -p"${MYSQL_ROOT_PASSWORD:-$DB_ROOT_PASSWORD}"'
    echo "✅ MariaDB restored"

# =======================================================================
# RESTORE MySQL
elif [[ "$SELECTED" == *.mysqldump.sql.gz ]]; then
    echo "🐬 Restoring MySQL..."
    compose_up "$SERVICENAME"
    wait_healthy "$SERVICENAME" mysql
    ROOTPW_CHECK=$(docker compose exec "$SERVICENAME" \
        sh -c 'echo "${MYSQL_ROOT_PASSWORD:-${DB_ROOT_PASSWORD:-}}"' 2>/dev/null | tr -d '\r\n')
    if [ -z "$ROOTPW_CHECK" ]; then
        echo "❌ Neither MYSQL_ROOT_PASSWORD nor DB_ROOT_PASSWORD is set in container '${SERVICENAME}'."
        echo "   Check the env_file / environment: section in your docker-compose.yml."
        exit 1
    fi
    gunzip -c "$SELECTED" | docker compose exec -T "$SERVICENAME" \
        sh -c 'mysql -u root -p"${MYSQL_ROOT_PASSWORD:-$DB_ROOT_PASSWORD}"'
    echo "✅ MySQL restored"

# =======================================================================
# RESTORE PostgreSQL
elif [[ "$SELECTED" == *.postgredump.sql.gz ]]; then
    echo "🐘 Restoring PostgreSQL..."
    compose_up "$SERVICENAME"
    wait_healthy "$SERVICENAME" postgres
    CONTAINERENV_DBNAME=$(docker compose exec "$SERVICENAME" sh -c 'echo "${POSTGRES_DB:-}"')
    CONTAINERENV_DBUSER=$(docker compose exec "$SERVICENAME" sh -c 'echo "${POSTGRES_USER:-}"')
    if [ -z "$CONTAINERENV_DBUSER" ]; then
        echo "❌ POSTGRES_USER is not set in container '${CONTAINERNAME}'."
        exit 1
    fi
    echo "  Database: '${CONTAINERENV_DBNAME:-postgres}', User: '${CONTAINERENV_DBUSER}'"
    gunzip -c "$SELECTED" | docker compose exec -T "$SERVICENAME" \
        psql -U "$CONTAINERENV_DBUSER" -d "${CONTAINERENV_DBNAME:-postgres}"
    echo "✅ PostgreSQL restored"

# =======================================================================
# RESTORE MongoDB
elif [[ "$SELECTED" == *.mongodump.sql.gz ]]; then
    echo "🍃 Restoring MongoDB..."
    compose_up "$SERVICENAME"
    wait_healthy "$SERVICENAME" mongo
    # Fixed: use $CONTAINERNAME (not the undefined $CONTAINER variable)
    gunzip -c "$SELECTED" | docker compose exec -T "$SERVICENAME" \
        sh -c 'mongorestore --archive --gzip'
    echo "✅ MongoDB restored"

# =======================================================================
# RESTORE GitLab
elif [[ "$SELECTED" == *.gitlabbackup.tar.gz ]]; then
    echo "🦊 Restoring GitLab..."
    compose_up "$SERVICENAME"

    # Unpack backup archive into the GitLab backup mount
    GITLAB_BACKUP_HOST="/mnt/backup-cache/gitlab-backup"
    mkdir -p "$GITLAB_BACKUP_HOST"
    tar -xzf "$SELECTED" -C "$GITLAB_BACKUP_HOST"

    # The extracted file must be owned by 'git' inside the container
    docker compose exec "$SERVICENAME" bash -c \
        "chown git /mnt/backup-cache/gitlab-backup && chmod 700 /mnt/backup-cache/gitlab-backup"

    # Stop application services before restore
    docker compose exec "$SERVICENAME" bash -c \
        "gitlab-ctl stop puma && gitlab-ctl stop sidekiq && gitlab-ctl status"

    # Determine the backup timestamp token from the archive filename
    # GitLab restore expects the token part (everything before _gitlab_backup.tar)
    BACKUP_TOKEN=$(ls "${GITLAB_BACKUP_HOST}"/*_gitlab_backup.tar 2>/dev/null | head -n 1 | xargs basename | sed 's/_gitlab_backup\.tar//')
    if [ -z "$BACKUP_TOKEN" ]; then
        echo "❌ Could not find a gitlab_backup.tar file in ${GITLAB_BACKUP_HOST}"
        exit 1
    fi

    docker compose exec "$SERVICENAME" bash -c \
        "gitlab-backup restore BACKUP=${BACKUP_TOKEN} force=yes"
    docker compose exec "$SERVICENAME" bash -c \
        "gitlab-ctl restart && gitlab-rake gitlab:check SANITIZE=true && gitlab-rake gitlab:doctor:secrets"
    docker compose exec "$SERVICENAME" bash -c \
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
