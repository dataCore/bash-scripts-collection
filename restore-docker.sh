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
# 2026-10-01 Names from the filename (volumes with dots), lower-cased project,
#            refuse Postgres restore into non-empty DB, newest GitLab backup,
#            refuse volume restore while in use, ERR trap with real line
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
# -E lets the ERR trap fire inside functions too. ERR (not EXIT) is used so
# $LINENO is the failing line; explicit `exit 1` after an own message stays quiet.
set -Eeuo pipefail
trap 'echo -e "\n❌ Error on line $LINENO. Restore script aborted."' ERR

# --- FUNCTIONS ---

# Write a SQL dump to stdout, decompressed by its extension (.sql.zst or .sql.gz).
decompress() {
    case "$1" in
        *.zst)
            if ! command -v zstd >/dev/null 2>&1; then
                echo "❌ '$1' is zstd-compressed, but zstd is not installed (apt install zstd)." >&2
                exit 1
            fi
            zstd -dcq "$1" ;;
        *)  gunzip -c "$1" ;;
    esac
}

# Map a backup filename to "<type> <suffix>"; prints nothing for unknown files.
# Must cover every OUTPUT name that backup-docker writes.
backup_type() {
    case "$1" in
        *.compose.tar.gz)        echo "compose .compose.tar.gz" ;;
        *.mariadbdump.sql.zst)   echo "mariadb .mariadbdump.sql.zst" ;;
        *.mariadbdump.sql.gz)    echo "mariadb .mariadbdump.sql.gz" ;;
        *.mysqldump.sql.zst)     echo "mysql .mysqldump.sql.zst" ;;
        *.mysqldump.sql.gz)      echo "mysql .mysqldump.sql.gz" ;;
        *.postgredump.sql.zst)   echo "postgres .postgredump.sql.zst" ;;
        *.postgredump.sql.gz)    echo "postgres .postgredump.sql.gz" ;;
        *.mongodump.archive.gz)  echo "mongo .mongodump.archive.gz" ;;
        *.mongodump.sql.gz)      echo "mongo .mongodump.sql.gz" ;;   # pre-2026-09 name
        *.gitlabbackup.tar.gz)   echo "gitlab .gitlabbackup.tar.gz" ;;
        *.volume.tar.gz)         echo "volume .volume.tar.gz" ;;
    esac
}

# Start a compose service and surface a clear error if it fails.
# docker compose up -d swallows the OCI/runc error text – we capture stderr
# and print it explicitly so the operator knows what to fix.
compose_up() {
    local service="$1"
    local output
    if ! output=$(docker compose up -d "$service" 2>&1); then
        echo "❌ Failed to start service '${service}':"
        echo "   ${output//$'\n'/$'\n'   }"
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
                        if docker exec "$cid" sh -c \
                            'mariadb-admin ping -u root -p"${MYSQL_ROOT_PASSWORD:-$DB_ROOT_PASSWORD}" --silent' \
                            2>/dev/null; then ready=true; fi
                        ;;
                    postgres)
                        if docker exec "$cid" sh -c \
                            'pg_isready -U "$POSTGRES_USER" --quiet' \
                            2>/dev/null; then ready=true; fi
                        ;;
                    mongo)
                        if docker exec "$cid" sh -c \
                            'mongosh --quiet --eval "db.adminCommand(\"ping\")" 2>/dev/null || \
                             mongo --quiet --eval "db.adminCommand(\"ping\")" 2>/dev/null' \
                            2>/dev/null; then ready=true; fi
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
# Lower-cased like backup-docker does, otherwise a project dir such as
# 'godlessDescentWeb' never matches its files '..._godlessdescentweb.*'.
PROJECTNAME=$(basename "$PWD" | tr '[:upper:]' '[:lower:]')
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

shopt -s nocaseglob
for file in "$BACKUPDIR"/*"$PROJECTNAME"*; do
    [ -f "$file" ] || continue   # skip if glob matched nothing
    filename=$(basename "$file")
    read -r type _ <<< "$(backup_type "$filename")"
    case "${type:-}" in
        compose)  COMPOSES+=("$filename") ;;
        mariadb)  MARIADBS+=("$filename") ;;
        mysql)    MYSQLS+=("$filename") ;;
        postgres) POSTGRES+=("$filename") ;;
        mongo)    MONGOS+=("$filename") ;;
        gitlab)   GITLABS+=("$filename") ;;
        volume)   VOLUMES+=("$filename") ;;
    esac
done
shopt -u nocaseglob

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

# Split the backup filename: {date}_{time}_{project}.{name}{suffix}
# {name} is the container (dumps, GitLab) or the volume (volume.tar.gz) and may
# itself contain dots (volume 'web.cache'), so cut the known prefix and suffix
# instead of splitting on dots. compose.tar.gz has no {name}, that is fine.
read -r TYPE SUFFIX <<< "$(backup_type "$(basename "$SELECTED")")"
OBJNAME=$(basename "$SELECTED" "$SUFFIX")
OBJNAME="${OBJNAME#*_*_}"     # drop {date}_{time}_
if [[ "$OBJNAME" == *.* ]]; then
    OBJNAME="${OBJNAME#*.}"   # drop {project}. (compose project names have no dots)
else
    OBJNAME=""
fi
CONTAINERNAME="$OBJNAME"

# Resolve the compose SERVICE name from the container name.
# Not needed for compose and volume restores – skip resolution in those cases.
# Strategy 1: container already exists (stopped) → read label directly
# Strategy 2: parse docker compose config → match container_name to service
# Strategy 3: fall back to using container name as-is (simple projects)
SERVICENAME=""
if [[ "$TYPE" != compose && "$TYPE" != volume ]]; then
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
if [ "$TYPE" == compose ]; then
    echo "📦 Restoring Docker Compose config..."
    tar -xzf "$SELECTED" -C "$PWD"
    echo "✅ Compose config restored to $PWD"

# =======================================================================
# RESTORE MariaDB
elif [ "$TYPE" == mariadb ]; then
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
    decompress "$SELECTED" | docker compose exec -T "$SERVICENAME" \
        sh -c 'mariadb -u root -p"${MYSQL_ROOT_PASSWORD:-$DB_ROOT_PASSWORD}"'
    echo "✅ MariaDB restored"

# =======================================================================
# RESTORE MySQL
elif [ "$TYPE" == mysql ]; then
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
    decompress "$SELECTED" | docker compose exec -T "$SERVICENAME" \
        sh -c 'mysql -u root -p"${MYSQL_ROOT_PASSWORD:-$DB_ROOT_PASSWORD}"'
    echo "✅ MySQL restored"

# =======================================================================
# RESTORE PostgreSQL
elif [ "$TYPE" == postgres ]; then
    echo "🐘 Restoring PostgreSQL..."
    compose_up "$SERVICENAME"
    wait_healthy "$SERVICENAME" postgres
    CONTAINERENV_DBNAME=$(docker compose exec -T "$SERVICENAME" sh -c 'echo "${POSTGRES_DB:-}"' | tr -d '\r\n')
    CONTAINERENV_DBUSER=$(docker compose exec -T "$SERVICENAME" sh -c 'echo "${POSTGRES_USER:-}"' | tr -d '\r\n')
    if [ -z "$CONTAINERENV_DBUSER" ]; then
        echo "❌ POSTGRES_USER is not set in container '${CONTAINERNAME}'."
        exit 1
    fi
    DBNAME="${CONTAINERENV_DBNAME:-postgres}"
    echo "  Database: '${DBNAME}', User: '${CONTAINERENV_DBUSER}'"
    # A pg_dumpall dump only restores cleanly into a freshly initialised
    # instance. Into existing tables psql reports errors, keeps going and leaves
    # old rows in place (or duplicates them) – so refuse instead of mixing data.
    USERTABLES=$(docker compose exec -T "$SERVICENAME" \
        psql -U "$CONTAINERENV_DBUSER" -d "$DBNAME" -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')" \
        | tr -d '\r\n')
    if [ "${USERTABLES:-0}" != "0" ]; then
        echo "❌ Database '${DBNAME}' already contains ${USERTABLES} table(s)."
        echo "   Restore into an empty instance: stop the stack, remove the database"
        echo "   volume (docker compose down; docker volume rm <volume>) and run again."
        exit 1
    fi
    # Expected on a fresh instance: 'role ... already exists' and
    # 'database ... already exists' for the user/DB the image created at init.
    decompress "$SELECTED" | docker compose exec -T "$SERVICENAME" \
        psql -q -U "$CONTAINERENV_DBUSER" -d "$DBNAME" >/dev/null
    echo "✅ PostgreSQL restored (errors 'role/database ... already exists' above are expected)"

# =======================================================================
# RESTORE MongoDB
elif [ "$TYPE" == mongo ]; then
    echo "🍃 Restoring MongoDB..."
    compose_up "$SERVICENAME"
    wait_healthy "$SERVICENAME" mongo
    # `mongodump --archive --gzip` gzips the whole archive stream: unpack it here
    # and hand mongorestore a plain archive (--gzip on top fails: invalid header).
    gunzip -c "$SELECTED" | docker compose exec -T "$SERVICENAME" \
        sh -c 'mongorestore --archive --drop'
    echo "✅ MongoDB restored"

# =======================================================================
# RESTORE GitLab
elif [ "$TYPE" == gitlab ]; then
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
    # backup-docker tars the whole backup dir, so it can hold several backups.
    # Tokens start with the epoch: the last one in sort order is the newest.
    BACKUP_TOKEN=$(find "${GITLAB_BACKUP_HOST}" -maxdepth 1 -name '*_gitlab_backup.tar' -printf '%f\n' 2>/dev/null | sort | tail -n 1)
    BACKUP_TOKEN=${BACKUP_TOKEN%_gitlab_backup.tar}
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
elif [ "$TYPE" == volume ]; then
    echo "💾 Restoring Volume '${OBJNAME}'..."
    if [[ "$OBJNAME" =~ ^[0-9a-f]{64}$ ]]; then
        echo "⚠️  '${OBJNAME}' is an anonymous volume: a recreated container gets a new"
        echo "   one and will not see this data. Copy it over by hand if it is needed."
    fi
    # The archive holds the volume dir incl. _data/; extracting while a container
    # writes to it would mix old and new files.
    INUSE=$(docker ps -q --filter "volume=${OBJNAME}")
    if [ -n "$INUSE" ]; then
        echo "❌ Volume '${OBJNAME}' is used by running container(s): $(docker ps --filter "volume=${OBJNAME}" --format '{{.Names}}' | paste -sd ' ')"
        echo "   Stop them first (docker compose stop <service>)."
        exit 1
    fi
    TARGETDIR="${DOCKERROOTDIR}/volumes/${OBJNAME}"
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
