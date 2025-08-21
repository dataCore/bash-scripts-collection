#!/bin/bash
# =======================================================================
# update/upgrade docker image
# created by: datacore
#
# Usage: update-docker {DOCKERCOMPOSE-PROJECTNAME} --auto={y,n,b}
# Example: backup-docker 'datacorecloud' --auto=y
# 
# =======================================================================
# START script
# =======================================================================
# Error handling and sudo
set -euo pipefail
trap 'echo -e "\n❌ Error in Line $LINENO. Update Script canceled."; exit 1' ERR
if [ "$EUID" -ne 0 ]; then
  echo "❌  Run as root!"
  exit 1
fi
# get docker-compose project name from variable or from current directory (lower case)
PROJECTNAME=$(echo "${1:-$(basename "$PWD")}" | tr '[:upper:]' '[:lower:]')
AUTO="${2:-}"

ALLCONTAINER=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECTNAME")
if [ -z "$ALLCONTAINER" ]; then
  echo "❌ Error: Docker-Compose Folder: ${PROJECTNAME} was not found or has no running containers."
  exit 1
fi
WORKINGDIR=$(for i in $ALLCONTAINER; do
  docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir"}}' "$i"
done | sort -u | head -n 1)
# =======================================================================
echo -n "🔍 Checking for newer Docker images for '${PROJECTNAME}'..."
# Get all images used in the current docker-compose.yml
cd $WORKINGDIR

CONTAINERS=$(docker compose ps -q 2>/dev/null || true)
for CONTAINER in $CONTAINERS; do 
  IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER")
  # Pull the latest image (but don't run it)
  docker pull "$IMAGE" > /dev/null
  LATEST_IMAGE_ID=$(docker inspect --format='{{.Id}}' "$IMAGE")
  RUNNING_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CONTAINER")
  # Check if we need an update
  if [ "$RUNNING_IMAGE_ID" != "$LATEST_IMAGE_ID" ]; then
    echo -e "\n🔄 Update for '${PROJECTNAME}' available!"
    if [[ -n "$AUTO" ]]; then
      answer="$AUTO"
    else
      read -p "Want to continue with the update? (y/n) with a backup? (b): " answer
    fi
    if [[ $answer == "n" ]]; then
      echo "❌ Update canceled."
      exit
    elif [[ $answer == "b" ]]; then
      echo "📦 Creating backup..."
      backup-docker ${PROJECTNAME}
    fi
    # again pull everything
    docker compose pull
    docker compose down && docker compose up -d
    printf "✅ All up to date\n"
    exit
  fi
done
printf "✅ All up to date!\n"
