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
# 2026-10-01 Cleanup also deletes *.zst dumps
# 2026-10-08 MongoDB dump authenticates with MONGO_INITDB_ROOT_* when set
# 2026-10-13 PostgreSQL: TimescaleDB version per database as a header in the
#            dump (for restore-docker), expected catalog FK warnings suppressed
# 2026-10-19 DB dump per container (also with bind-mounted data dirs), exact
#            image matching + label datacore.backup.type, missing credentials
#            and failed dumps fail the run, cleanup keeps the newest file of
#            every artefact, exit 75 for "skipped", MariaDB/MySQL password via
#            MYSQL_PWD inside the container, GitLab: newest backup only + config,
#            artefacts written as .part and renamed, tar "file changed" is a
#            warning, label datacore.backup.stop=true
#
# Usage:   backup-docker {DOCKERCOMPOSE-PROJECTNAME} {BACKUPDIR} {BACKUPDURATIONDAYS}
# Example: backup-docker 'datacorecloud' '/mnt/backup' 2 > /var/log/dataCoreBackupScript.log
#
# Exit codes: 0  all artefacts written
#             1  error, or at least one dump/volume failed or was skipped
#             75 project skipped (not found or no running containers)
#
# Container labels:
#   datacore.backup.ignore=true   skip the container with all its volumes
#   datacore.backup.type=<type>   postgres | mariadb | mysql | none – overrides
#                                 the detection by image name (none: no dump,
#                                 tar the volumes like any other container)
#   datacore.backup.stop=true     stop the container while its volumes are tarred
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

# Exit code for "nothing to back up". Not 2: tar, mysqldump and others use 2
# for real errors, backup-docker-all must not mistake those for a skip.
EXIT_SKIPPED=75

# --- FUNCTIONS ---

cleanup() {
    local exit_code=$?
    if [ -n "${CURRENT_PART:-}" ] && [ -f "$CURRENT_PART" ]; then
        echo "🧹 Removing incomplete file: $CURRENT_PART"
        rm -f "$CURRENT_PART"
    fi
    if [ -n "${STOPPED_CONTAINER:-}" ]; then
        echo "▶️  Starting stopped container again: $STOPPED_CONTAINER"
        docker start "$STOPPED_CONTAINER" >/dev/null \
            || echo "❌ Could not start container '$STOPPED_CONTAINER'!"
    fi
    if [ -n "${TEMPDIR:-}" ] && [ -d "$TEMPDIR" ]; then
        rm -rf "$TEMPDIR"
    fi
    if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne "$EXIT_SKIPPED" ]; then
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

# Record a failed or skipped artefact: the run goes on with the next one and
# exits non-zero at the end, so monitoring sees it.
fail_item() {
    echo "❌ $1"
    FAILURES+=("$1")
}

# Print a container label (empty when not set)
container_label() {
    docker inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true
}

# Classify an image by its repository path – registry, tag and digest removed:
# ghcr.io/immich-app/postgres:14-vectorchord -> immich-app/postgres.
# Prints mariadb | mysql | postgres | mongo | gitlab, or nothing.
# Exact names only, so e.g. postgrest/postgrest is not taken for PostgreSQL.
# restore-docker resolves the credentials of these types the same way.
image_db_type() {
    local ref="${1%%@*}" first
    if [[ "$ref" == */* ]]; then
        first="${ref%%/*}"
        if [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]]; then
            ref="${ref#*/}"
        fi
    fi
    if [[ "${ref##*/}" == *:* ]]; then
        ref="${ref%:*}"
    fi
    ref="${ref#library/}"
    ref="${ref,,}"
    case "$ref" in
        mariadb|bitnami/mariadb|linuxserver/mariadb)
            echo mariadb ;;
        mysql|mysql/mysql-server|bitnami/mysql)
            echo mysql ;;
        postgres|timescale/timescaledb|timescale/timescaledb-ha|postgis/postgis|\
        bitnami/postgresql|pgvector/pgvector|immich-app/postgres|tensorchord/pgvecto-rs)
            echo postgres ;;
        gitlab/gitlab-ce|gitlab/gitlab-ee)
            echo gitlab ;;
        *)
            case "${ref##*/}" in
                mongo|mongodb|mongodb-community-server) echo mongo ;;
            esac ;;
    esac
}

# Run a PostgreSQL client in the container with PGUSER/PGPASSWORD from
# PG_ENV_SH (the password stays inside the container).
# Usage: pg_exec <container> <command> [args...]
pg_exec() {
    local cont="$1"
    shift
    # shellcheck disable=SC2016  # expanded in the container
    docker exec "$cont" sh -c "${PG_ENV_SH}"'exec "$@"' pg_exec "$@"
}

# Print "<database> <version>" for every database with the TimescaleDB extension.
# Usage: timescaledb_versions <container> <user>
timescaledb_versions() {
    local cont="$1" user="$2" db ver
    for db in $(pg_exec "$cont" psql -U "$user" -d postgres -tAc \
        "SELECT datname FROM pg_database WHERE datallowconn" | tr -d '\r'); do
        ver=$(pg_exec "$cont" psql -U "$user" -d "$db" -tAc \
            "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'" | tr -d '\r')
        [ -n "$ver" ] && echo "$db $ver"
    done
    return 0
}

# Print pg_dumpall's stderr. With TimescaleDB, pg_dump warns once per database
# about circular foreign keys in the extension catalog (continuous_agg, …) plus
# detail/hint lines. A full dump restores them fine, so with TimescaleDB that
# block is dropped and only counted; everything else is printed as is.
# Usage: print_pgdump_stderr <stderr_file> <timescaledb_info>
print_pgdump_stderr() {
    local errfile="$1" tsdb="$2" count
    [ -s "$errfile" ] || return 0
    if [ -z "$tsdb" ]; then
        cat "$errfile"
        return 0
    fi
    count=$(grep -c 'circular foreign-key constraints' "$errfile" || true)
    awk '/circular foreign-key constraints/ { skip = 1; next }
         skip && /^pg_dump: (detail|hint):/ { next }
         { skip = 0; print }' "$errfile"
    [ "$count" -gt 0 ] && printf '(%s expected TimescaleDB catalog notice(s) hidden) ' "$count"
    return 0
}

# Artefacts are written to a hidden ".<name>.part" next to the final file and
# only renamed once complete: an aborted run never leaves a truncated file that
# looks like a valid backup (and that the cleanup would keep as the newest).
# begin_backup sets PART; commit_backup/discard_backup finish it.
begin_backup() {
    PART="${PROJECTBACKUPDIR}/.${1}.part"
    CURRENT_PART="$PART"
}
commit_backup() {
    mv -f "${PROJECTBACKUPDIR}/.${1}.part" "${PROJECTBACKUPDIR}/${1}"
    CURRENT_PART=""
}
discard_backup() {
    rm -f "${PROJECTBACKUPDIR}/.${1}.part"
    CURRENT_PART=""
}

# Run tar. Exit code 1 means "file changed as we read it" (a live volume) and
# is only a warning; anything above is an error and returned.
run_tar() {
    local rc=0
    tar --warning=no-file-changed "$@" || rc=$?
    if [ "$rc" -eq 1 ]; then
        printf '(⚠️  files changed while reading) '
        return 0
    fi
    return "$rc"
}

# Tar one named volume into OUTPUT. Usage: backup_volume <volume> <label>
backup_volume() {
    local vol="$1" label="$2" volumedir output start
    volumedir="${DOCKERROOTDIR}/volumes/${vol}"
    if [ ! -d "$volumedir" ]; then
        echo "  ⚠️  Volume dir not found, skipping: $volumedir"
        return 0
    fi
    start=$(date +%s)
    output="${TIMESTAMP}_${PROJECTNAME}.${vol##*/}.volume.tar.gz"
    print_status "  💾 ${label}: ${output}... "
    begin_backup "$output"
    # tar directly from the volume dir (no intermediate cp needed); gzip stays,
    # restore-docker reads volume archives as .tar.gz
    if run_tar -cpzf "$PART" --numeric-owner -C "$volumedir" .; then
        commit_backup "$output"
        print_duration $(( $(date +%s) - start ))
    else
        discard_backup "$output"
        fail_item "tar failed for volume '${vol}'."
    fi
}

# --- CREDENTIALS (resolved inside the container) ---
# The root password of MariaDB/MySQL never becomes an argument on the host
# (visible in ps): the shell in the container looks it up and hands it to the
# client in MYSQL_PWD. Plain variables first, then the *_FILE variants
# (Docker secrets). Keep in sync with restore-docker.
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
# PostgreSQL superuser, resolved in the container and exported as PGUSER (and
# PGPASSWORD when a password is set, for images without local trust auth):
# official image POSTGRES_USER/_PASSWORD(_FILE); bitnami/postgresql
# POSTGRESQL_POSTGRES_PASSWORD (user postgres), else POSTGRESQL_USERNAME/
# POSTGRESQL_PASSWORD; default user postgres.
# shellcheck disable=SC2016
PG_ENV_SH='u="${POSTGRES_USER:-}"
if [ -z "$u" ] && [ -n "${POSTGRES_USER_FILE:-}" ] && [ -r "$POSTGRES_USER_FILE" ]; then u=$(cat "$POSTGRES_USER_FILE"); fi
p="${POSTGRES_PASSWORD:-}"
if [ -z "$p" ] && [ -n "${POSTGRES_PASSWORD_FILE:-}" ] && [ -r "$POSTGRES_PASSWORD_FILE" ]; then p=$(cat "$POSTGRES_PASSWORD_FILE"); fi
if [ -z "$u" ]; then
    if [ -n "${POSTGRESQL_POSTGRES_PASSWORD:-}" ]; then
        u=postgres; p="$POSTGRESQL_POSTGRES_PASSWORD"
    else
        u="${POSTGRESQL_USERNAME:-}"; p="${p:-${POSTGRESQL_PASSWORD:-}}"
    fi
fi
PGUSER="${u:-postgres}"
export PGUSER
if [ -n "$p" ]; then PGPASSWORD="$p"; export PGPASSWORD; fi
'
# Prints the resolved user (no password)
# shellcheck disable=SC2016
PG_USER_SH="${PG_ENV_SH}"'echo "$PGUSER"'

# GitLab writes its backups to backup_path from gitlab.rb. By convention that
# is this directory, bind-mounted at the same path on the host and in the
# container (restore-docker uses the same path).
GITLAB_BACKUP_CACHE="/mnt/backup-cache/gitlab-backup"

# --- VARIABLES ---
HOSTNAME="$(hostname)"
TIMESTAMP=$(date +"%Y%m%d_%H%M")
PROJECTNAME=$(echo "${1:-$(basename "$PWD")}" | tr '[:upper:]' '[:lower:]')
BACKUPDURATIONDAYS=${3:-2}
DOCKERROOTDIR=$(docker info --format '{{ .DockerRootDir }}')
FAILURES=()
CURRENT_PART=""
STOPPED_CONTAINER=""

# --- SANITY CHECK: project running? ---
ALLCONTAINER=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECTNAME")
if [ -z "$ALLCONTAINER" ]; then
    echo "⚠️  Warning: Project '${PROJECTNAME}' not found or no running containers. Skipping."
    exit "$EXIT_SKIPPED"
fi

# --- BACKUP DIRECTORIES ---
BACKUPDIR="${2:-"/mnt/backup"}/${HOSTNAME}"
PROJECTBACKUPDIR="${BACKUPDIR}/${PROJECTNAME}"
mkdir -p "$PROJECTBACKUPDIR"
# Small scratch files only (pg_dumpall stderr); artefacts go to .part files
TEMPDIR=$(mktemp -d "/var/tmp/backup-docker.${PROJECTNAME}.XXXXXX")

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
begin_backup "$OUTPUT"
if run_tar -czf "$PART" -C "$WORKINGDIR" .; then
    commit_backup "$OUTPUT"
    print_duration $(( $(date +%s) - START ))
else
    discard_backup "$OUTPUT"
    fail_item "tar failed for the compose directory '${WORKINGDIR}'."
fi

# =======================================================================
# BACKUP DOCKER VOLUMES AND DATABASES
# The containers come from the compose labels, not from 'docker compose ps':
# that only finds the project with the default compose file name.

# Compressor for SQL dumps: zstd uses every core and is far faster than gzip at
# a similar ratio (a 14 GB PostgreSQL took 40+ min with gzip -9). Falls back to
# gzip where zstd is not installed. restore-docker reads both.
if command -v zstd >/dev/null 2>&1; then
    DUMP_COMPRESS=(zstd -T0 -q)
    DUMP_EXT="sql.zst"
else
    DUMP_COMPRESS=(gzip -6)
    DUMP_EXT="sql.gz"
fi

# A volume mounted into several containers is tarred only once
declare -A VOL_DONE=()

for cont in $ALLCONTAINER; do
    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$cont" 2>/dev/null)
    CONTAINERNAME=$(docker inspect --format '{{.Name}}' "$cont" 2>/dev/null | sed 's|^/||')
    # Opt-out per container: label datacore.backup.ignore=true skips all of its
    # volumes (e.g. a search index that can be rebuilt from the primary data).
    BACKUP_IGNORE=$(container_label "$cont" datacore.backup.ignore)
    if [ "${BACKUP_IGNORE,,}" == "true" ]; then
        echo "  ⏭️  ${CONTAINERNAME}: skipped (label datacore.backup.ignore=true)"
        continue
    fi

    # What kind of backup: label datacore.backup.type overrides the image name
    BACKUP_TYPE=$(container_label "$cont" datacore.backup.type)
    case "${BACKUP_TYPE,,}" in
        "")                     DBTYPE=$(image_db_type "$IMAGE") ;;
        postgres|mariadb|mysql) DBTYPE="${BACKUP_TYPE,,}" ;;
        none)                   DBTYPE="" ;;
        *)
            fail_item "${CONTAINERNAME}: unknown label datacore.backup.type='${BACKUP_TYPE}' (postgres|mariadb|mysql|none), detecting by image."
            DBTYPE=$(image_db_type "$IMAGE") ;;
    esac

    # ---------------------------------------------------------------
    # DATABASE DUMP – once per container, before and independent of the
    # volumes: the data dir may just as well be a bind mount.
    START=$(date +%s)
    DUMP_FAILED=false
    case "$DBTYPE" in
    mariadb|mysql)
        if [ "$DBTYPE" == mariadb ]; then
            OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mariadbdump.${DUMP_EXT}"
            DUMPTOOL=mariadb-dump
            print_status "  🐬 MariaDB: ${OUTPUT}... "
        else
            OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mysqldump.${DUMP_EXT}"
            DUMPTOOL=mysqldump
            print_status "  🐬 MySQL: ${OUTPUT}... "
        fi
        if ! docker exec "$cont" sh -c "${MYSQL_PW_SH}${MYSQL_PW_CHECK}"; then
            fail_item "${CONTAINERNAME}: no root password (MYSQL_ROOT_PASSWORD, MARIADB_ROOT_PASSWORD, DB_ROOT_PASSWORD or *_FILE), dump skipped."
            DUMP_FAILED=true
        else
            begin_backup "$OUTPUT"
            # --single-transaction: consistent InnoDB snapshot without locking;
            # routines, events and triggers are not in a default dump
            # shellcheck disable=SC2016
            if docker exec "$cont" sh -c "${MYSQL_PW_SH}"'
                for tool in "$0" mariadb-dump mysqldump; do
                    if command -v "$tool" >/dev/null 2>&1; then
                        exec "$tool" -u "${MARIADB_ROOT_USER:-root}" --all-databases \
                            --single-transaction --routines --events --triggers
                    fi
                done
                echo "no mariadb-dump/mysqldump in the container" >&2
                exit 127' "$DUMPTOOL" | "${DUMP_COMPRESS[@]}" > "$PART"; then
                commit_backup "$OUTPUT"
                print_duration $(( $(date +%s) - START ))
            else
                discard_backup "$OUTPUT"
                fail_item "${DUMPTOOL} failed in container '${CONTAINERNAME}'."
                DUMP_FAILED=true
            fi
        fi
        ;;

    # ---------------------------------------------------------------
    postgres)
        OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.postgredump.${DUMP_EXT}"
        print_status "  🐘 PostgreSQL: ${OUTPUT}... "
        if ! CONTAINERENV_DBUSER=$(docker exec "$cont" sh -c "$PG_USER_SH" | tr -d '\r') \
            || [ -z "$CONTAINERENV_DBUSER" ]; then
            fail_item "${CONTAINERNAME}: could not determine the PostgreSQL user, dump skipped."
            DUMP_FAILED=true
        else
            # TimescaleDB: restore-docker needs the extension version of every
            # database (same version, timescaledb_pre_restore). It goes into the
            # dump as comment lines, which psql ignores.
            TSDB_INFO=$(timescaledb_versions "$cont" "$CONTAINERENV_DBUSER")
            DUMP_ERR="${TEMPDIR}/${CONTAINERNAME}.pg_dumpall.err"
            begin_backup "$OUTPUT"
            # shellcheck disable=SC2016
            if { if [ -n "$TSDB_INFO" ]; then
                     # shellcheck disable=SC2001  # prefix every line
                     sed 's/^/-- backup-docker timescaledb: /' <<< "$TSDB_INFO"
                 fi
                 pg_exec "$cont" pg_dumpall -U "$CONTAINERENV_DBUSER" 2> "$DUMP_ERR"
               } | "${DUMP_COMPRESS[@]}" > "$PART"; then
                print_pgdump_stderr "$DUMP_ERR" "$TSDB_INFO"
                if [ -n "$TSDB_INFO" ]; then
                    printf '(TimescaleDB %s) ' "$(awk '{ print $2 }' <<< "$TSDB_INFO" | sort -u | paste -sd,)"
                fi
                commit_backup "$OUTPUT"
                print_duration $(( $(date +%s) - START ))
            else
                cat "$DUMP_ERR"
                discard_backup "$OUTPUT"
                fail_item "pg_dumpall failed in container '${CONTAINERNAME}'."
                DUMP_FAILED=true
            fi
        fi
        ;;

    # ---------------------------------------------------------------
    mongo)
        OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.mongodump.archive.gz"
        print_status "  🍃 MongoDB: ${OUTPUT}... "
        begin_backup "$OUTPUT"
        # With MONGO_INITDB_ROOT_* set the server enforces auth (e.g. Komodo).
        # shellcheck disable=SC2016
        if docker exec "$cont" sh -c 'set --
                if [ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ]; then
                    set -- --authenticationDatabase admin \
                        -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD"
                fi
                exec mongodump --archive --gzip --quiet "$@"' > "$PART"; then
            commit_backup "$OUTPUT"
            print_duration $(( $(date +%s) - START ))
        else
            discard_backup "$OUTPUT"
            fail_item "mongodump failed in container '${CONTAINERNAME}'."
            DUMP_FAILED=true
        fi
        ;;

    # ---------------------------------------------------------------
    gitlab)
        # Only the backup this run creates: the cache may hold older ones, and
        # the GitLab archive is compressed already – a plain tar around it keeps
        # its file name, which carries the token 'gitlab-backup restore' needs.
        OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.gitlabbackup.tar"
        print_status "  🦊 GitLab: ${OUTPUT}... "
        # Only an archive newer than this marker is from this run; an old one
        # left in the cache must never be stored as today's backup.
        GITLAB_MARKER="${TEMPDIR}/gitlab-${CONTAINERNAME}.marker"
        touch "$GITLAB_MARKER"
        if ! docker exec -u root "$cont" bash -c \
            "mkdir -p '${GITLAB_BACKUP_CACHE}' && chown git '${GITLAB_BACKUP_CACHE}' && chmod 700 '${GITLAB_BACKUP_CACHE}'" \
            || ! docker exec -u root "$cont" bash -c \
            "export COMPRESS_CMD=gzip SKIP=artifacts,registry && gitlab-backup create --quiet"; then
            fail_item "gitlab-backup create failed in container '${CONTAINERNAME}'."
        else
            GITLAB_FILE=""
            if [ -d "$GITLAB_BACKUP_CACHE" ]; then
                GITLAB_FILE=$( { find "$GITLAB_BACKUP_CACHE" -maxdepth 1 -name '*_gitlab_backup.tar' \
                    -newer "$GITLAB_MARKER" -printf '%T@ %f\n' 2>/dev/null || true; } \
                    | sort -n | tail -n 1 | cut -d' ' -f2-)
            fi
            if [ -z "$GITLAB_FILE" ]; then
                fail_item "No new *_gitlab_backup.tar in ${GITLAB_BACKUP_CACHE} on the host (backup_path in gitlab.rb and the bind mount must point there)."
            else
                begin_backup "$OUTPUT"
                if run_tar -cf "$PART" -C "$GITLAB_BACKUP_CACHE" "$GITLAB_FILE"; then
                    commit_backup "$OUTPUT"
                    rm -f "${GITLAB_BACKUP_CACHE:?}/${GITLAB_FILE}"
                    print_duration $(( $(date +%s) - START ))
                else
                    discard_backup "$OUTPUT"
                    fail_item "tar failed for GitLab backup '${GITLAB_FILE}'."
                fi
            fi
        fi
        # gitlab-backup leaves out gitlab.rb and gitlab-secrets.json on purpose,
        # yet without the secrets a restore cannot decrypt 2FA, CI variables and
        # runner tokens.
        START=$(date +%s)
        OUTPUT="${TIMESTAMP}_${PROJECTNAME}.${CONTAINERNAME}.gitlabconfig.tar.gz"
        print_status "  🦊 GitLab config: ${OUTPUT}... "
        begin_backup "$OUTPUT"
        if docker exec -u root "$cont" tar -czf - -C /etc/gitlab gitlab.rb gitlab-secrets.json > "$PART"; then
            commit_backup "$OUTPUT"
            print_duration $(( $(date +%s) - START ))
        else
            discard_backup "$OUTPUT"
            fail_item "Could not archive /etc/gitlab in container '${CONTAINERNAME}'."
        fi
        ;;
    esac

    # ---------------------------------------------------------------
    # NAMED VOLUMES (anonymous and bind mounts are excluded). A container with
    # a database dump or GitLab backup gets no volume tar – the dump is the
    # consistent copy; only MongoDB's config volumes are tarred as well.
    # When the dump was skipped or failed, the raw volumes are tarred instead:
    # not consistent while the DB runs, but better than no new copy at all
    # (the run still exits non-zero).
    if [ "$DUMP_FAILED" == true ]; then
        echo "  ⚠️  ${CONTAINERNAME}: no dump, tarring its volumes as a fallback."
        DBTYPE=""
    fi
    VOLUMES=$(docker inspect \
        --format '{{ range .Mounts }}{{ if eq .Type "volume" }}{{ .Name }}{{ "\n" }}{{ end }}{{ end }}' \
        "$cont" 2>/dev/null | grep -v '^$' || true)
    TAR_VOLUMES=()
    for vol in $VOLUMES; do
        if [ -n "$DBTYPE" ] && ! { [ "$DBTYPE" == mongo ] && grep -qi "config" <<< "$vol"; }; then
            continue
        fi
        [ -n "${VOL_DONE[$vol]+set}" ] && continue
        VOL_DONE[$vol]=1
        TAR_VOLUMES+=("$vol")
    done
    [ "${#TAR_VOLUMES[@]}" -eq 0 ] && continue

    # Label datacore.backup.stop=true: a consistent copy of files that are
    # written all the time (SQLite, caches) needs the container stopped.
    BACKUP_STOP=$(container_label "$cont" datacore.backup.stop)
    if [ "${BACKUP_STOP,,}" == "true" ]; then
        echo "  ⏸️  Stopping ${CONTAINERNAME} (label datacore.backup.stop=true)..."
        if docker stop "$cont" >/dev/null; then
            STOPPED_CONTAINER="$cont"
        else
            fail_item "Could not stop container '${CONTAINERNAME}', tarring its volumes while it runs."
        fi
    fi
    VOLUME_LABEL="LocalStorage"
    [ "$DBTYPE" == mongo ] && VOLUME_LABEL="LocalStorage (mongo-config)"
    for vol in "${TAR_VOLUMES[@]}"; do
        backup_volume "$vol" "$VOLUME_LABEL"
    done
    if [ -n "$STOPPED_CONTAINER" ]; then
        echo "  ▶️  Starting ${CONTAINERNAME}..."
        if ! docker start "$STOPPED_CONTAINER" >/dev/null; then
            fail_item "Could not start container '${CONTAINERNAME}' again!"
        fi
        STOPPED_CONTAINER=""
    fi
done

# =======================================================================
# CLEANUP OLD BACKUPS
# The newest file of every artefact (per container/volume and type) is kept
# regardless of its age: when a dump fails for a few nights, the age alone
# would otherwise delete the last good one.

# "<date>_<time>_<project>.<name><suffix>" -> "<project>.<name><suffix>" without
# the compression extension, so .sql.gz/.sql.zst (or the old .gitlabbackup.tar.gz
# and the new .gitlabbackup.tar) count as one kind of artefact.
artefact_key() {
    local key="${1#*_*_}"
    key="${key%.gz}"
    key="${key%.zst}"
    printf '%s' "$key"
}

echo "  🗑️  Cleanup old backups (older than ${BACKUPDURATIONDAYS} days, newest of each kept)..."
declare -A NEWEST=()
# *.zst: SQL dumps since 2026-09-29 – before this was added they were never deleted
while IFS= read -r -d '' file; do
    name="${file##*/}"
    key=$(artefact_key "$name")
    if [ -z "${NEWEST[$key]:-}" ] || [[ "$name" > "${NEWEST[$key]}" ]]; then
        NEWEST[$key]="$name"
    fi
done < <(find "$PROJECTBACKUPDIR" -maxdepth 1 -type f -name "*_${PROJECTNAME}*" \
    \( -name "*.gz" -o -name "*.zst" -o -name "*.tar" \) -print0)

while IFS= read -r -d '' file; do
    name="${file##*/}"
    if [ "${NEWEST[$(artefact_key "$name")]:-}" == "$name" ]; then
        echo "    - Keep (newest of its kind): $file"
        continue
    fi
    echo "    - Delete: $file"
    rm -f "$file"
done < <(find "$PROJECTBACKUPDIR" -maxdepth 1 -type f -name "*_${PROJECTNAME}*" \
    \( -name "*.gz" -o -name "*.zst" -o -name "*.tar" \) \
    -daystart -mtime +"$BACKUPDURATIONDAYS" -print0)

# Leftovers of runs that were killed before their EXIT trap could run
find "$PROJECTBACKUPDIR" -maxdepth 1 -type f -name '.*.part' -mmin +1440 \
    -exec echo "    - Delete stale: {}" \; -exec rm -f {} \;

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "  ❌ ${#FAILURES[@]} problem(s) in project '${PROJECTNAME}':"
    printf '     - %s\n' "${FAILURES[@]}"
    exit 1
fi
echo "  ✔️  All done."
