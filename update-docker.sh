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
AUTO="${AUTO#--auto=}"

ALLCONTAINER=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECTNAME")
if [ -z "$ALLCONTAINER" ]; then
    echo "❌ Error: Docker-Compose Folder: ${PROJECTNAME} was not found or has no running containers."
    exit 1
fi

WORKINGDIR=$(for i in $ALLCONTAINER; do
    docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir"}}' "$i"
done | sort -u | head -n 1)

if [ -z "$WORKINGDIR" ] || [ ! -d "$WORKINGDIR" ]; then
    echo "❌ Could not determine working directory for project '${PROJECTNAME}'."
    exit 1
fi

# =======================================================================
# Check the working directory against its Git remote
# =======================================================================
cd "$WORKINGDIR"

if git -C "$WORKINGDIR" rev-parse --is-inside-work-tree &>/dev/null; then
    GIT_STATUS=$(git -C "$WORKINGDIR" status --porcelain 2>/dev/null)

    # Refresh the remote-tracking ref so local and remote can be compared.
    # Read-only, never touches the working tree. Prompts are disabled and the
    # whole thing is time-boxed so an unattended run cannot hang on a private
    # repo or an unreachable remote — if the fetch fails, the comparison below
    # simply falls back to the last known state of the remote.
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
        timeout 20 git -C "$WORKINGDIR" fetch --quiet &>/dev/null || true

    GIT_UNPUSHED=$(git -C "$WORKINGDIR" log "@{u}.." --oneline 2>/dev/null || true)
    GIT_BEHIND=$(git -C "$WORKINGDIR" log "..@{u}" --oneline 2>/dev/null || true)

    if [ -n "$GIT_STATUS" ] || [ -n "$GIT_UNPUSHED" ]; then
        echo "⚠️  WARNING: Pending Git changes detected in '${WORKINGDIR}'!"
        if [ -n "$GIT_STATUS" ]; then
            echo "   Uncommitted changes:"
            git -C "$WORKINGDIR" status --short | sed 's/^/     /'
        fi
        if [ -n "$GIT_UNPUSHED" ]; then
            echo "   Unpushed commits:"
            echo "     ${GIT_UNPUSHED//$'\n'/$'\n'     }"
        fi
    fi

    if [ -n "$GIT_BEHIND" ]; then
        echo "⚠️  WARNING: '${WORKINGDIR}' is behind its Git remote!"
        echo "   Missing commits:"
        echo "     ${GIT_BEHIND//$'\n'/$'\n'     }"
        echo "   Run 'git -C ${WORKINGDIR} pull' first — the containers would"
        echo "   otherwise be updated against an outdated compose file."
    fi
fi

# =======================================================================
echo -n "🔍 Checking for newer Docker images for '${PROJECTNAME}'..."

# Get all images used in the current docker-compose.yml
CONTAINERS=$(docker compose ps -q 2>/dev/null || true)
UPDATE_NEEDED=false
for CONTAINER in $CONTAINERS; do
    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER")
    RUNNING_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CONTAINER")

    # Container running an older image than the local tag → recreate needed
    LOCAL_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)
    if [ -n "$LOCAL_IMAGE_ID" ] && [ "$RUNNING_IMAGE_ID" != "$LOCAL_IMAGE_ID" ]; then
        UPDATE_NEEDED=true
        break
    fi

    # Compare local vs. registry digest – no image download needed
    LOCAL_DIGEST=$(docker image inspect \
        --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$IMAGE" 2>/dev/null \
        | awk -F@ '{print $2}' || true)
    REMOTE_DIGEST=$(docker buildx imagetools inspect "$IMAGE" \
        --format '{{.Manifest.Digest}}' 2>/dev/null || true)

    if [ -z "$LOCAL_DIGEST" ] || [ -z "$REMOTE_DIGEST" ]; then
        # Locally built image, buildx missing or registry unreachable –
        # fall back to the old pull-based comparison for this image only.
        if ! docker pull "$IMAGE" >/dev/null 2>&1; then
            continue
        fi
        LATEST_IMAGE_ID=$(docker inspect --format='{{.Id}}' "$IMAGE")
        if [ "$RUNNING_IMAGE_ID" != "$LATEST_IMAGE_ID" ]; then
            UPDATE_NEEDED=true
            break
        fi
    elif [ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ]; then
        UPDATE_NEEDED=true
        break
    fi
done

if [ "$UPDATE_NEEDED" = true ]; then
    echo -e "\n🔄 Update for '${PROJECTNAME}' available!"
    if [[ -n $AUTO ]]; then
        answer="$AUTO"
    else
        read -r -p "Want to continue with the update? (y/n) with a backup? (b): " answer
    fi
    if [[ $answer == "n" ]]; then
        echo "❌ Update canceled."
        exit 0
    elif [[ $answer == "b" ]]; then
        echo "📦 Creating backup..."
        backup-docker "${PROJECTNAME}"
    fi
    # Pull everything, then recreate only changed containers
    # (no 'down' first — avoids leaving the project offline if 'up' fails)
    docker compose pull
    docker compose up -d
fi
printf "✅ All up to date!\n"
