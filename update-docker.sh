#!/bin/bash
# =======================================================================
# update/upgrade docker image
# created by: datacore
#
# Usage: update-docker {DOCKERCOMPOSE-PROJECTNAME} --auto={y,n,b}
# Example: update-docker 'datacorecloud' --auto=y
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

# Get docker-compose project name from variable or from current directory (lower case)
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
# Check for pending git changes in the working directory
# =======================================================================
cd "$WORKINGDIR"

if git -C "$WORKINGDIR" rev-parse --is-inside-work-tree &>/dev/null; then
    GIT_STATUS=$(git -C "$WORKINGDIR" status --porcelain 2>/dev/null)
    GIT_UNPUSHED=$(git -C "$WORKINGDIR" log @{u}.. --oneline 2>/dev/null || true)

    if [ -n "$GIT_STATUS" ] || [ -n "$GIT_UNPUSHED" ]; then
        echo ""
        echo "⚠️  WARNING: Pending Git changes detected in '${WORKINGDIR}'!"
        if [ -n "$GIT_STATUS" ]; then
            echo "   Uncommitted changes:"
            git -C "$WORKINGDIR" status --short | sed 's/^/     /'
        fi
        if [ -n "$GIT_UNPUSHED" ]; then
            echo "   Unpushed commits:"
            echo "$GIT_UNPUSHED" | sed 's/^/     /'
        fi
        echo ""
        echo "   ⚠️  These local changes may be overwritten or conflict with the update."
        echo ""
    fi
fi

# =======================================================================
echo -n "🔍 Checking for newer Docker images for '${PROJECTNAME}'..."

# Get all images used in the current docker-compose.yml
CONTAINERS=$(docker compose ps -q 2>/dev/null || true)
for CONTAINER in $CONTAINERS; do
    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER")
    # Pull the latest image (but don't run it yet)
    docker pull "$IMAGE" >/dev/null
    LATEST_IMAGE_ID=$(docker inspect --format='{{.Id}}' "$IMAGE")
    RUNNING_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CONTAINER")
    # Check if we need an update
    if [ "$RUNNING_IMAGE_ID" != "$LATEST_IMAGE_ID" ]; then
        echo -e "\n🔄 Update for '${PROJECTNAME}' available!"
        if [[ -n $AUTO ]]; then
            answer="$AUTO"
        else
            read -r -p "Want to continue with the update? (y/n) with a backup? (b): " answer
        fi
        if [[ $answer == "n" ]]; then
            echo "❌ Update canceled."
            exit
        elif [[ $answer == "b" ]]; then
            echo "📦 Creating backup..."
            backup-docker "${PROJECTNAME}"
        fi
        # Pull everything and restart
        docker compose pull
        docker compose down && docker compose up -d
        printf "✅ All up to date\n"
        exit
    fi
done
printf "✅ All up to date!\n"
