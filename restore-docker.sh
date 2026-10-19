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
# 2026-10-02 Postgres: empty check over all databases and fail-closed,
#            restore fails on any error besides 'role/database already exists'.
#            MariaDB/MySQL/MongoDB: no success message on import errors
# 2026-10-13 PostgreSQL: TimescaleDB restore (version check, pre/post restore,
#            catalog schemas ignored in the empty check), wait for the init
#            phase of the image to finish (TCP instead of socket)
# 2026-10-19 Volume: archive tested and extracted next to the target, the old
#            dir is kept as .bak-<ts>. Credentials resolved like backup-docker
#            (MARIADB_ROOT_PASSWORD, *_FILE, MYSQL_PWD, POSTGRES_USER default
#            postgres). Compose files/project from the container labels.
#            GitLab: new .gitlabbackup.tar and .gitlabconfig.tar.gz, wait for
#            healthy, token from the archive. Timeouts configurable.
#
# INFO: Run from the docker-compose project directory, e.g.:
#       cd /etc/docker-compose/datacoreipam/
# Usage:   restore-docker {BACKUPDIR}
# Example: restore-docker '/mnt/backup'
# Env:     RESTORE_TIMEOUT (default 180 s) – wait for a service to be ready
#          RESTORE_GITLAB_TIMEOUT (default 900 s) – the same for GitLab
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

# docker compose for this project. COMPOSE_ARGS holds -p/-f/--project-directory
# from the container labels when the project exists (set below).
dc() {
    docker compose "${COMPOSE_ARGS[@]}" "$@"
}

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

# Judge a dump import by its exit code and stderr: DB clients may keep going
# after errors and still exit 0 (psql) or only log failed documents
# (mongorestore). Aborts with a summary unless the exit code is 0 and no stderr
# line matches error_re (lines matching the optional expected_re are ignored).
# Usage: check_import <label> <exit_code> <stderr> <error_re> [expected_re]
check_import() {
    local label="$1" rc="$2" stderr="$3" error_re="$4" expected_re="${5:-}"
    local errors count
    errors=$(grep -E "$error_re" <<< "$stderr" || true)
    if [ -n "$expected_re" ]; then
        errors=$(grep -vE "$expected_re" <<< "$errors" || true)
    fi
    count=$(grep -c . <<< "$errors" || true)
    if [ "$count" -ne 0 ] || [ "$rc" -ne 0 ]; then
        echo "❌ ${label} restore failed: ${count} error(s), exit code ${rc}."
        if [ "$count" -ne 0 ]; then
            echo "   First errors:"
            head -n 10 <<< "$errors" | sed 's/^/   /'
        else
            tail -n 10 <<< "$stderr" | sed 's/^/   /'
        fi
        exit 1
    fi
}

# Run one SQL statement in a database of the selected PostgreSQL service.
# stdin is /dev/null so callers can loop over a here-string.
# Usage: pg_query <database> <sql>
pg_query() {
    dc exec -T "$SERVICENAME" \
        psql -X -v ON_ERROR_STOP=1 -U "$CONTAINERENV_DBUSER" -d "$1" -tAc "$2" </dev/null | tr -d '\r'
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
        *.gitlabbackup.tar.gz)   echo "gitlab .gitlabbackup.tar.gz" ;;   # before 2026-10-19
        *.gitlabbackup.tar)      echo "gitlab .gitlabbackup.tar" ;;
        *.gitlabconfig.tar.gz)   echo "gitlabconfig .gitlabconfig.tar.gz" ;;
        *.volume.tar.gz)         echo "volume .volume.tar.gz" ;;
    esac
}

# Start a compose service and surface a clear error if it fails.
# docker compose up -d swallows the OCI/runc error text – we capture stderr
# and print it explicitly so the operator knows what to fix.
compose_up() {
    local service="$1"
    local output
    if ! output=$(dc up -d "$service" 2>&1); then
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
        cid=$(dc ps -q "$service" 2>/dev/null || true)

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
                        # shellcheck disable=SC2016  # expanded in the container
                        if docker exec "$cid" sh -c "${MYSQL_PW_SH}"'
                            u="${MARIADB_ROOT_USER:-root}"
                            mariadb-admin ping -u "$u" --silent 2>/dev/null \
                                || mysqladmin ping -u "$u" --silent' \
                            2>/dev/null; then ready=true; fi
                        ;;
                    postgres)
                        # shellcheck disable=SC2016
                        if docker exec "$cid" sh -c \
                            'pg_isready -U "$('"$PG_USER_SH"')" --quiet' \
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

# --- CREDENTIALS (resolved inside the container, as in backup-docker) ---
# The root password of MariaDB/MySQL never becomes an argument on the host
# (visible in ps): the shell in the container looks it up and hands it to the
# client in MYSQL_PWD. Plain variables first, then the *_FILE variants
# (Docker secrets). Keep in sync with backup-docker.
# shellcheck disable=SC2016  # expanded by the shell inside the container
MYSQL_PW_SH='MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-${DB_ROOT_PASSWORD:-}}}"
for f in "${MARIADB_ROOT_PASSWORD_FILE:-}" "${MYSQL_ROOT_PASSWORD_FILE:-}"; do
    if [ -z "$MYSQL_PWD" ] && [ -n "$f" ] && [ -r "$f" ]; then MYSQL_PWD=$(cat "$f"); fi
done
export MYSQL_PWD
'
# Succeeds when a password was found (or the image allows an empty one)
# shellcheck disable=SC2016
MYSQL_PW_CHECK='[ -n "$MYSQL_PWD" ] || [ -n "${MARIADB_ALLOW_EMPTY_ROOT_PASSWORD:-}${MYSQL_ALLOW_EMPTY_PASSWORD:-}" ]'
# PostgreSQL superuser: POSTGRES_USER(_FILE) as the official image, else postgres
# shellcheck disable=SC2016
PG_USER_SH='u="${POSTGRES_USER:-}"
if [ -z "$u" ] && [ -n "${POSTGRES_USER_FILE:-}" ] && [ -r "$POSTGRES_USER_FILE" ]; then u=$(cat "$POSTGRES_USER_FILE"); fi
echo "${u:-postgres}"'

# GitLab's backup_path, bind-mounted at the same path on the host and in the
# container (as in backup-docker)
GITLAB_BACKUP_CACHE="/mnt/backup-cache/gitlab-backup"

# --- VARIABLES ---
HOSTNAME="$(hostname)"
# Lower-cased like backup-docker does, otherwise a project dir such as
# 'godlessDescentWeb' never matches its files '..._godlessdescentweb.*'.
PROJECTNAME=$(basename "$PWD" | tr '[:upper:]' '[:lower:]')
BACKUPDIR="${1:-"/mnt/backup"}/${HOSTNAME}/${PROJECTNAME}"
DOCKERROOTDIR=$(docker info --format '{{ .DockerRootDir }}')
TIMEOUT="${RESTORE_TIMEOUT:-180}"                # Max wait time in seconds
GITLAB_TIMEOUT="${RESTORE_GITLAB_TIMEOUT:-900}"  # GitLab needs minutes to boot
WAIT_INTERVAL=2   # Poll interval in seconds

# Address the project the way it was started: a compose file with another
# name than the default, or several -f files, is otherwise not found. Only
# when containers of this project exist (running or stopped) – without them
# a -p from the directory name could start a second project next to one
# that sets 'name:' in its compose file; plain 'docker compose' is used then.
COMPOSE_ARGS=()
PROJECT_CID=$(docker ps -aq --filter "label=com.docker.compose.project=${PROJECTNAME}" | head -n 1)
if [ -n "$PROJECT_CID" ]; then
    COMPOSE_ARGS=(-p "$PROJECTNAME")
    COMPOSE_WORKDIR=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$PROJECT_CID")
    COMPOSE_FILES=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$PROJECT_CID")
    if [ -n "$COMPOSE_WORKDIR" ] && [ -d "$COMPOSE_WORKDIR" ]; then
        COMPOSE_ARGS+=(--project-directory "$COMPOSE_WORKDIR")
    fi
    FILE_ARGS=()
    IFS=',' read -r -a CONFIG_FILES <<< "$COMPOSE_FILES"
    for f in "${CONFIG_FILES[@]}"; do
        if [ ! -f "$f" ]; then
            FILE_ARGS=()
            break
        fi
        FILE_ARGS+=(-f "$f")
    done
    COMPOSE_ARGS+=("${FILE_ARGS[@]}")
fi

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
        gitlab|gitlabconfig) GITLABS+=("$filename") ;;
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
            SERVICENAME=$(dc config 2>/dev/null | awk -v cn="$CONTAINERNAME" '
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
# RESTORE MariaDB / MySQL
elif [ "$TYPE" == mariadb ] || [ "$TYPE" == mysql ]; then
    if [ "$TYPE" == mariadb ]; then DBLABEL="MariaDB"; DBCLIENT=mariadb; else DBLABEL="MySQL"; DBCLIENT=mysql; fi
    echo "🐬 Restoring ${DBLABEL}..."
    compose_up "$SERVICENAME"
    wait_healthy "$SERVICENAME" "$TYPE"
    # Verify the root password is available inside the container: MYSQL_ROOT_PASSWORD,
    # MARIADB_ROOT_PASSWORD, DB_ROOT_PASSWORD (some stacks) or a *_FILE variant.
    if ! dc exec -T "$SERVICENAME" sh -c "${MYSQL_PW_SH}${MYSQL_PW_CHECK}" </dev/null; then
        echo "❌ No root password in container '${SERVICENAME}' (MYSQL_ROOT_PASSWORD, MARIADB_ROOT_PASSWORD,"
        echo "   DB_ROOT_PASSWORD or *_FILE). Check the env_file / environment: section in your docker-compose.yml."
        exit 1
    fi
    IMPORT_RC=0
    # shellcheck disable=SC2016  # expanded in the container
    IMPORT_STDERR=$( { decompress "$SELECTED" | dc exec -T "$SERVICENAME" \
        sh -c "${MYSQL_PW_SH}"'
            for tool in "$0" mariadb mysql; do
                if command -v "$tool" >/dev/null 2>&1; then
                    exec "$tool" -u "${MARIADB_ROOT_USER:-root}"
                fi
            done
            echo "ERROR: no mariadb/mysql client in the container" >&2
            exit 127' "$DBCLIENT"; } 2>&1 ) || IMPORT_RC=$?
    check_import "$DBLABEL" "$IMPORT_RC" "$IMPORT_STDERR" '^ERROR'
    echo "✅ ${DBLABEL} restored"

# =======================================================================
# RESTORE PostgreSQL
elif [ "$TYPE" == postgres ]; then
    echo "🐘 Restoring PostgreSQL..."
    compose_up "$SERVICENAME"
    wait_healthy "$SERVICENAME" postgres
    # shellcheck disable=SC2016
    CONTAINERENV_DBNAME=$(dc exec -T "$SERVICENAME" sh -c 'echo "${POSTGRES_DB:-}"' | tr -d '\r\n')
    CONTAINERENV_DBUSER=$(dc exec -T "$SERVICENAME" sh -c "$PG_USER_SH" </dev/null | tr -d '\r\n')
    if [ -z "$CONTAINERENV_DBUSER" ]; then
        echo "❌ Could not determine the PostgreSQL user in container '${CONTAINERNAME}'."
        exit 1
    fi
    DBNAME="${CONTAINERENV_DBNAME:-postgres}"
    echo "  Database: '${DBNAME}', User: '${CONTAINERENV_DBUSER}'"
    # During its init the image runs a temporary server on the socket only
    # (listen_addresses=''), and a socket healthcheck already passes then. The
    # init scripts (TimescaleDB: CREATE EXTENSION) must be done, so wait for TCP.
    elapsed=0
    until dc exec -T "$SERVICENAME" \
        pg_isready -q -h 127.0.0.1 -U "$CONTAINERENV_DBUSER" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$TIMEOUT" ]; then
            echo "❌ Timeout after ${TIMEOUT}s: PostgreSQL in '${SERVICENAME}' does not answer on TCP."
            exit 1
        fi
        sleep "$WAIT_INTERVAL"
        elapsed=$(( elapsed + WAIT_INTERVAL ))
    done

    # TimescaleDB: backup-docker writes "-- backup-docker timescaledb: <db> <version>"
    # at the top of the dump. Without that header (dumps before 2026-10-13) the
    # databases that already have the extension in the target are used and the
    # version cannot be checked.
    TSDB_INFO=$( (decompress "$SELECTED" | head -n 50 \
        | sed -n 's/^-- backup-docker timescaledb: //p') 2>/dev/null || true)
    TSDB_UNCHECKED=false
    if [ -z "$TSDB_INFO" ] \
        && [ -n "$(pg_query "$DBNAME" "SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb'")" ]; then
        for db in $(pg_query "$DBNAME" "SELECT datname FROM pg_database WHERE datallowconn"); do
            if [ -n "$(pg_query "$db" "SELECT 1 FROM pg_extension WHERE extname = 'timescaledb'")" ]; then
                TSDB_INFO+="${db} ?"$'\n'
            fi
        done
        TSDB_INFO=$(sed '/^$/d' <<< "$TSDB_INFO")
        [ -n "$TSDB_INFO" ] && TSDB_UNCHECKED=true
    fi
    [ -n "$TSDB_INFO" ] && echo "  TimescaleDB: $(paste -sd, <<< "$TSDB_INFO")"
    # A pg_dumpall dump only restores cleanly into a freshly initialised
    # instance. Into existing tables psql reports errors, keeps going and leaves
    # old rows in place (or duplicates them) – so refuse instead of mixing data.
    # The dump switches databases itself (\connect), and apps often use a DB
    # other than POSTGRES_DB, so every database is checked. Fail closed: if a
    # check does not return a number, the instance is treated as not empty.
    if ! PG_DATABASES=$(dc exec -T "$SERVICENAME" \
        psql -U "$CONTAINERENV_DBUSER" -d "$DBNAME" -tAc \
        "SELECT datname FROM pg_database WHERE NOT datistemplate" \
        | tr -d '\r'); then
        echo "❌ Could not list the databases in container '${SERVICENAME}'. Restore aborted."
        exit 1
    fi
    mapfile -t PG_DBLIST < <(printf '%s\n' "$PG_DATABASES" | sed '/^$/d')
    if [ "${#PG_DBLIST[@]}" -eq 0 ]; then
        echo "❌ The database list in container '${SERVICENAME}' came back empty. Restore aborted."
        exit 1
    fi
    USERTABLES=0
    PG_TABLECOUNTS=()
    for db in "${PG_DBLIST[@]}"; do
        if ! COUNT=$(dc exec -T "$SERVICENAME" \
            psql -U "$CONTAINERENV_DBUSER" -d "$db" -tAc \
            "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') AND schemaname !~ '^_?timescaledb'" \
            | tr -d '\r\n'); then
            COUNT=""
        fi
        if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
            echo "❌ Could not count the tables in database '${db}' (got: '${COUNT}'). Restore aborted."
            exit 1
        fi
        PG_TABLECOUNTS+=("${db}: ${COUNT} table(s)")
        USERTABLES=$(( USERTABLES + COUNT ))
    done
    if [ "$USERTABLES" -ne 0 ]; then
        echo "❌ The instance already contains ${USERTABLES} table(s):"
        printf '   - %s\n' "${PG_TABLECOUNTS[@]}"
        echo "   Restore into an empty instance: stop the stack, remove the database"
        echo "   volume (docker compose down; docker volume rm <volume>) and run again."
        exit 1
    fi
    # TimescaleDB: the catalog must be restored into the same extension version,
    # with timescaledb_pre_restore() before and timescaledb_post_restore() after.
    # A database the dump would create itself is created here first, so the
    # extension can be set up in it before the data arrives.
    while read -r db ver; do
        [ -n "$db" ] || continue
        if [ -z "$(pg_query "$DBNAME" "SELECT 1 FROM pg_database WHERE datname = '${db}'")" ]; then
            pg_query "$DBNAME" "CREATE DATABASE \"${db}\"" >/dev/null
        fi
        INSTALLED=$(pg_query "$db" "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")
        if [ "$ver" == "?" ]; then
            :
        elif [ -z "$INSTALLED" ]; then
            if ! pg_query "$db" "CREATE EXTENSION timescaledb VERSION '${ver}'" >/dev/null; then
                echo "❌ TimescaleDB ${ver} (from the dump) is not available in the image of '${SERVICENAME}'."
                echo "   Available: $(pg_query "$DBNAME" "SELECT string_agg(version, ', ') FROM pg_available_extension_versions WHERE name = 'timescaledb'")"
                exit 1
            fi
        elif [ "$INSTALLED" != "$ver" ]; then
            # The image's init created the extension in its own (newer) version.
            # The images ship older versions too, and the database was checked to
            # be empty, so set it up again in the dump's version (separate
            # sessions: a backend cannot load two versions).
            if [ -z "$(pg_query "$db" "SELECT 1 FROM pg_available_extension_versions WHERE name = 'timescaledb' AND version = '${ver}'")" ]; then
                echo "❌ Database '${db}': the image has TimescaleDB ${INSTALLED}, the dump was made with ${ver},"
                echo "   and the image does not ship ${ver}. Pin the image to ${ver}"
                echo "   (e.g. timescale/timescaledb:${ver}-pg<major>), remove the database volume and run again."
                exit 1
            fi
            echo "  TimescaleDB in '${db}': ${INSTALLED} → ${ver} (version of the dump)"
            pg_query "$db" "DROP EXTENSION timescaledb" >/dev/null
            pg_query "$db" "CREATE EXTENSION timescaledb VERSION '${ver}'" >/dev/null
        fi
    done <<< "$TSDB_INFO"
    # Only after every version matched, so an abort leaves no database in restoring mode.
    while read -r db _; do
        [ -n "$db" ] || continue
        pg_query "$db" "SELECT timescaledb_pre_restore()" >/dev/null
    done <<< "$TSDB_INFO"
    if [ "$TSDB_UNCHECKED" == true ]; then
        echo "⚠️  The dump has no TimescaleDB header (made before 2026-10-13): the version"
        echo "   cannot be checked. The image must have the same TimescaleDB version as"
        echo "   the server that made the dump."
    fi

    # psql keeps going after SQL errors and still exits 0, so its stderr decides.
    # Expected on a fresh instance: 'role ... already exists' and
    # 'database ... already exists' for the user/DB the image created at init.
    IMPORT_RC=0
    IMPORT_STDERR=$( { decompress "$SELECTED" | dc exec -T "$SERVICENAME" \
        psql -q -U "$CONTAINERENV_DBUSER" -d "$DBNAME" >/dev/null; } 2>&1 ) || IMPORT_RC=$?
    # Leave restoring mode even if the import failed, then judge the import.
    while read -r db _; do
        [ -n "$db" ] || continue
        pg_query "$db" "SELECT timescaledb_post_restore()" >/dev/null
    done <<< "$TSDB_INFO"
    PG_EXPECTED_RE='ERROR:  (role|database) ".*" already exists$'
    check_import "PostgreSQL" "$IMPORT_RC" "$IMPORT_STDERR" 'ERROR:|FATAL:' "$PG_EXPECTED_RE"
    PG_EXPECTED=$(grep -cE "$PG_EXPECTED_RE" <<< "$IMPORT_STDERR" || true)
    echo "ℹ️  ${PG_EXPECTED} expected error(s) ignored ('role/database ... already exists')."
    echo "✅ PostgreSQL restored"

# =======================================================================
# RESTORE MongoDB
elif [ "$TYPE" == mongo ]; then
    echo "🍃 Restoring MongoDB..."
    compose_up "$SERVICENAME"
    wait_healthy "$SERVICENAME" mongo
    # `mongodump --archive --gzip` gzips the whole archive stream: unpack it here
    # and hand mongorestore a plain archive (--gzip on top fails: invalid header).
    # mongorestore exits 0 even when single documents fail (e.g. duplicate key);
    # it only logs them, so its log decides.
    IMPORT_RC=0
    # shellcheck disable=SC2016  # expanded in the container
    IMPORT_STDERR=$( { gunzip -c "$SELECTED" | dc exec -T "$SERVICENAME" \
        sh -c 'set --
            if [ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ]; then
                set -- --authenticationDatabase admin \
                    -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD"
            fi
            exec mongorestore --archive --drop "$@"'; } 2>&1 ) || IMPORT_RC=$?
    check_import "MongoDB" "$IMPORT_RC" "$IMPORT_STDERR" \
        'Failed:|continuing through error|[1-9][0-9]* document\(s\) failed to restore'
    grep -E 'document\(s\) restored successfully' <<< "$IMPORT_STDERR" | sed 's/^.*\t//; s/^/  /' || true
    echo "✅ MongoDB restored"

# =======================================================================
# RESTORE GitLab
elif [ "$TYPE" == gitlab ]; then
    echo "🦊 Restoring GitLab..."
    # Test the archive and take the backup token from it (everything before
    # _gitlab_backup.tar): old .tar.gz files hold the whole cache dir and may
    # carry several backups – tokens start with the epoch, the last one is the
    # newest. Reading it from the archive, not the cache dir, ignores leftovers.
    if ! GITLAB_MEMBERS=$(tar -tf "$SELECTED"); then
        echo "❌ Archive is damaged or unreadable: $SELECTED"
        exit 1
    fi
    GITLAB_MEMBER=$(grep '_gitlab_backup\.tar$' <<< "$GITLAB_MEMBERS" | sort | tail -n 1 || true)
    BACKUP_TOKEN=$(basename "$GITLAB_MEMBER" _gitlab_backup.tar)
    if [ -z "$GITLAB_MEMBER" ] || [ -z "$BACKUP_TOKEN" ]; then
        echo "❌ No *_gitlab_backup.tar in $(basename "$SELECTED")."
        exit 1
    fi
    echo "  Backup token: ${BACKUP_TOKEN}"
    echo "ℹ️  The restore needs the gitlab-secrets.json of the backed-up instance:"
    echo "   restore the matching .gitlabconfig.tar.gz first (then gitlab-ctl reconfigure)."

    compose_up "$SERVICENAME"
    # GitLab takes minutes until its services are up; chown and gitlab-ctl
    # fail or hang before that.
    TIMEOUT="$GITLAB_TIMEOUT" wait_healthy "$SERVICENAME"

    # Unpack the backup into the GitLab backup mount
    mkdir -p "$GITLAB_BACKUP_CACHE"
    tar -xf "$SELECTED" -C "$GITLAB_BACKUP_CACHE" "$GITLAB_MEMBER"
    GITLAB_FILE="${BACKUP_TOKEN}_gitlab_backup.tar"

    # The extracted file must be owned by 'git' inside the container
    dc exec -T "$SERVICENAME" bash -c \
        "chown git '${GITLAB_BACKUP_CACHE}' '${GITLAB_BACKUP_CACHE}/${GITLAB_FILE}' && chmod 700 '${GITLAB_BACKUP_CACHE}'"

    # Stop application services before restore
    dc exec -T "$SERVICENAME" bash -c \
        "gitlab-ctl stop puma && gitlab-ctl stop sidekiq && gitlab-ctl status"

    dc exec -T "$SERVICENAME" bash -c \
        "gitlab-backup restore BACKUP=${BACKUP_TOKEN} force=yes"
    rm -f "${GITLAB_BACKUP_CACHE:?}/${GITLAB_FILE}"
    dc exec -T "$SERVICENAME" bash -c \
        "gitlab-ctl restart && gitlab-rake gitlab:check SANITIZE=true && gitlab-rake gitlab:doctor:secrets"
    dc exec -T "$SERVICENAME" bash -c \
        "gitlab-rake gitlab:artifacts:check && gitlab-rake gitlab:lfs:check && gitlab-rake gitlab:uploads:check"
    echo "✅ GitLab restored"

# =======================================================================
# RESTORE GitLab config (gitlab.rb, gitlab-secrets.json)
elif [ "$TYPE" == gitlabconfig ]; then
    echo "🦊 Restoring GitLab config (gitlab.rb, gitlab-secrets.json)..."
    if ! tar -tzf "$SELECTED" >/dev/null; then
        echo "❌ Archive is damaged or unreadable: $SELECTED"
        exit 1
    fi
    compose_up "$SERVICENAME"
    RESTORE_TS=$(date +%Y%m%d_%H%M%S)
    # The current files are kept as <file>.bak-<ts> in /etc/gitlab
    # shellcheck disable=SC2016  # expanded in the container
    dc exec -T "$SERVICENAME" sh -c '
        cd /etc/gitlab || exit 1
        for f in gitlab.rb gitlab-secrets.json; do
            if [ -f "$f" ]; then cp -a "$f" "$f.bak-$0" || exit 1; fi
        done
        exec tar -xzf - -C /etc/gitlab' "$RESTORE_TS" < "$SELECTED"
    echo "✅ GitLab config restored to /etc/gitlab (previous files: *.bak-${RESTORE_TS})"
    echo "   Apply it: docker compose exec ${SERVICENAME} gitlab-ctl reconfigure"

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
    # Nothing is touched before the archive has been read completely: test it,
    # extract it next to the target, and only then swap the directories. The
    # current content is kept, not deleted.
    echo "  Testing archive..."
    if ! tar -tzf "$SELECTED" >/dev/null; then
        echo "❌ Archive is damaged or unreadable: $SELECTED"
        exit 1
    fi
    TARGETDIR="${DOCKERROOTDIR}/volumes/${OBJNAME}"
    RESTORE_TS=$(date +%Y%m%d_%H%M%S)
    STAGINGDIR="${TARGETDIR}.restore-${RESTORE_TS}"
    OLDDIR=""
    if [ -d "$TARGETDIR" ]; then
        OLDDIR="${TARGETDIR}.bak-${RESTORE_TS}"
        read -r -p "⚠️  Folder '$TARGETDIR' already exists. Replace it (the current one is kept as '${OLDDIR}')? (y/n): " CONFIRM
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo "❌ Restore cancelled."
            exit 1
        fi
    fi
    mkdir -p "$STAGINGDIR"
    if ! tar -xzf "$SELECTED" -C "$STAGINGDIR"; then
        rm -rf "$STAGINGDIR"
        echo "❌ Extracting failed, '${TARGETDIR}' is unchanged."
        exit 1
    fi
    if [ -n "$OLDDIR" ]; then
        mv "$TARGETDIR" "$OLDDIR"
    fi
    mv "$STAGINGDIR" "$TARGETDIR"
    echo "✅ Volume restored to $TARGETDIR"
    if [ -n "$OLDDIR" ]; then
        echo "ℹ️  The previous content is in '${OLDDIR}'. Docker may list it as a volume"
        echo "   after a daemon restart. Remove it once the restore is verified:"
        echo "     rm -rf $(printf '%q' "$OLDDIR")"
    fi

else
    echo "❌ Unknown backup type: $(basename "$SELECTED")"
    exit 1
fi

# =======================================================================
echo ""
echo "===============> Restore complete on Host: '${HOSTNAME}'"
