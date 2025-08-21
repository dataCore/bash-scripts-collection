#!/bin/bash
# ============================================================================
# RESTORE DOCKER SCRIPT for a single Docker Compose Project
# by dataCore
#
# HISTORY
# 2024-07-22 Initial Version
#
# INFO: You have to be in the docker-compose directory e.g. cd /etc/docker-compose/datacoreipam/
# Usage: restore-docker {BACKUPDIR}
# Example: restore-docker '/mnt/backup'
# =======================================================================

# START script
echo "===============> RESTORE 📦 DOCKER SCRIPT"
HOSTNAME="$(hostname)"
# Set the language
export LANG="en_US.UTF-8"
# Load the Pathes
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Error handling
set -euo pipefail
trap 'echo -e "\n❌ Error on line $LINENO. Restore script aborted."; exit 1' ERR
# SET Variables
PROJECTNAME=$(basename "$PWD")
BACKUPDIR="${1:-"/mnt/backup"}/${HOSTNAME}/${PROJECTNAME}"
DOCKERROOTDIR=$(docker info --format '{{ .DockerRootDir }}')
# Check backup directory
if [ ! -d "$BACKUPDIR" ]; then
   	echo "❌ No backup directory found in: $BACKUPDIR"
  	exit 1
fi
# =======================================================================
echo "===============> Starting restore-docker SCRIPT on Host: '${HOSTNAME}' for Project: '${PROJECTNAME}'"
# Show available backups
echo "📦 Available backups for project '$PROJECTNAME':"
# Define Arrays for the output
declare -a COMPOSES MARIADBS MYSQLS POSTGRES MONGOS GITLABS VOLUMES
declare -A OPTIONS
i=1
# Analyse and Sort different backup types
for file in "$BACKUPDIR"/*"$PROJECTNAME"*; do
	filename=$(basename "$file")
	if [[ "$filename" == *.compose.tar.gz ]]; then
  		COMPOSES+=("$filename")
  	elif [[ "$filename" == *.mariadbdump.sql.gz ]]; then
  		MARIADBS+=("$filename")
  	elif [[ "$filename" == *.mysqldump.sql.gz ]]; then
  		MYSQLS+=("$filename")
  	elif [[ "$filename" == *.postgredump.sql.gz ]]; then
  		POSTGRES+=("$filename")
  	elif [[ "$filename" == *.mongodump.sql.gz ]]; then
  		MONGOS+=("$filename")
  	elif [[ "$filename" == *.gitlabbackup.tar.gz ]]; then
  		GITLABS+=("$filename")
  	elif [[ "$filename" == *.volume.tar.gz ]]; then
  		VOLUMES+=("$filename")
  	fi
done

# Define Function to print the sorted backup types
print_group() {
  	local icon="$1"
  	local label="$2"
  	shift 2
  	local group=("$@")
  	if [ ${#group[@]} -gt 0 ]; then
  		echo "$icon $label:"
  		for item in "${group[@]}"; do
  			printf "  - [%02d] %s\n" "$i" "$item"
  			OPTIONS[$i]="$BACKUPDIR/$item"
  			((i++))
  		done
  	fi
}

# Print each group
print_group "📦" "DockerCompose" "${COMPOSES[@]}"
print_group "🐬" "MariaDB" "${MARIADBS[@]}"
print_group "🐬" "MySQL" "${MYSQLS[@]}"
print_group "🐘" "PostgreSQL" "${POSTGRES[@]}"
print_group "🍃" "MongoDB" "${MONGOS[@]}"
print_group "🦊" "GitLab" "${GITLABS[@]}"
print_group "💾" "LocalStorage" "${VOLUMES[@]}"

# Give the selection
read -r -p "❓ Choose which backup you want to restore: " CHOICE
NORMALIZED_CHOICE=$((10#$CHOICE))
SELECTED="${OPTIONS[$NORMALIZED_CHOICE]}"
if [ -z "$SELECTED" ]; then
   	echo "❌ Wrong selection"
  	exit 1
fi

# =======================================================================
echo "🔄 Restore of: $SELECTED"
# Get ContainerName if available from the given backup name
CONTAINERNAME=$(echo "$SELECTED" | sed -E 's/^[^_]+_[^_]+_[^_]+_([^\.]+)\..*/\1/')
# =======================================================================
# Restore Docker Compose
if [[ "$SELECTED" == *.compose.tar.gz ]]; then
  	echo "📦 Restore Docker Compose..."
  	tar -xzf "$SELECTED" -C "$PWD"
  	echo "✅ Restored in $PWD"
# =======================================================================
# Restore MariaDB 
elif [[ "$SELECTED" == *mariadbdump* ]]; then
  	echo "🐬 Restore MariaDB..."
  	docker compose up -d "$CONTAINERNAME"
  	CONTAINERENV_ROOTPW=$(docker compose exec "$CONTAINERNAME" sh -c 'echo "$MYSQL_ROOT_PASSWORD"')
  	echo "Restore Databases..."
  	gunzip -c "$SELECTED" | docker compose exec -T "$CONTAINERNAME" sh -c "mariadb -u root -p$CONTAINERENV_ROOTPW"
  	echo "✅ MariaDB restored"
# =======================================================================
# Restore MySQL
elif [[ "$SELECTED" == *mysqldump* ]]; then
  	echo "🐬 Restore MySQL..."
  	docker compose up -d "$CONTAINERNAME"
  	CONTAINERENV_ROOTPW=$(docker compose exec "$CONTAINERNAME" sh -c 'echo "$MYSQL_ROOT_PASSWORD"')
  	echo "Restore Databases..."
  	gunzip -c "$SELECTED" | docker compose exec -T "$CONTAINERNAME" sh -c "mysql -u root -p$CONTAINERENV_ROOTPW"
  	echo "✅ MySQL restored"
# =======================================================================
# Restore PostgreSQL
elif [[ "$SELECTED" == *postgredump* ]]; then
  	echo "🐘 Restore PostgreSQL..."
  	docker compose up -d "$CONTAINERNAME"
  	CONTAINERENV_DBNAME=$(docker compose exec "$CONTAINERNAME" sh -c 'echo "$POSTGRES_DB"')
  	CONTAINERENV_DBUSER=$(docker compose exec "$CONTAINERNAME" sh -c 'echo "$POSTGRES_USER"')
  	echo "Restore Database '$CONTAINERENV_DBNAME'..."
  	gunzip -c "$SELECTED" | docker compose exec -T "$CONTAINERNAME" psql -U "$CONTAINERENV_DBUSER" -d "$CONTAINERENV_DBNAME"
  	echo "✅ PostgreSQL restored"
# =======================================================================
# Restore MongoDB
elif [[ "$SELECTED" == *mongodump* ]]; then
  	echo "🍃 Restore MongoDB..."
  	docker compose up -d "$CONTAINERNAME"
  	gunzip -c "$SELECTED" | docker exec -i "$CONTAINER" sh -c 'mongorestore --archive --gzip'
  	echo "✅ MongoDB restored"
# =======================================================================
# Restore Gitlab
elif [[ "$SELECTED" == *gitlabbackup* ]]; then
    echo "🦊 Restore GitLab..."
    docker compose up -d "$CONTAINERNAME"
    sudo cp "$SELECTED" /mnt/backup-cache/gitlab-backup/
    docker compose exec "$CONTAINERNAME" bash -c "chown git /mnt/backup-cache/gitlab-backup && chmod 700 /mnt/backup-cache/gitlab-backup"
    docker compose exec "$CONTAINERNAME" bash -c "gitlab-ctl stop puma && gitlab-ctl stop sidekiq && gitlab-ctl status"
    docker compose exec "$CONTAINERNAME" bash -c "gitlab-backup restore BACKUP=$SELECTED force=yes"
    docker compose exec "$CONTAINERNAME" bash -c "gitlab-ctl restart && gitlab-rake gitlab:check SANITIZE=true && gitlab-rake gitlab:doctor:secrets"
    docker compose exec "$CONTAINERNAME" bash -c "gitlab-rake gitlab:artifacts:check && gitlab-rake gitlab:lfs:check && gitlab-rake gitlab:uploads:check"
    echo "✅ GitLab restored"
# =======================================================================
# Restore Volume
elif [[ "$SELECTED" == *.volume.tar.gz ]]; then
  	echo "💾 Restore Volume..."
  	TARGETDIR=${DOCKERROOTDIR}/volumes/${CONTAINERNAME}
  	if [ -d "$TARGETDIR" ]; then
  		read -r -p "Folder $TARGETDIR already exists. Do you want to delete it first? (y/n): " CONFIRM
  		if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
  			rm -rf "$TARGETDIR"
  			echo "Folder deleted."
  		else
  			echo "❌ Restore cancelled."
  			exit 1
  		fi
  	fi
  	mkdir -p "$TARGETDIR"
  	sudo tar -xzf "$SELECTED" -C "$TARGETDIR"
  	echo "✅ Volume restored to $TARGETDIR"
fi

# =======================================================================
echo "===============> End of restore-docker- SCRIPT for: '${HOSTNAME}' "

