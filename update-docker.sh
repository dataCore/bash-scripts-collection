#!/bin/bash
# =======================================================================
# update/upgrade docker image
# created by: datacore
#
# Usage: update-docker {DOCKERCOMPOSE-PROJECTNAME} --auto={y,n,b}
# Example: update-docker 'datacorecloud' --auto=y
#
# 2026-10-19 Answer/--auto validated (only y updates, b backs up first),
#            git runs as the owner of the project dir and reports errors,
#            compose -p/-f from the container labels
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
AUTO=""
case "${2:-}" in
    "") ;;
    --auto=[yYnNbB]) AUTO="${2#--auto=}" ;;
    *)
        echo "❌ Invalid option '${2}'. Usage: update-docker {PROJECT} --auto={y,n,b}"
        exit 1 ;;
esac

ALLCONTAINER=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECTNAME")
if [ -z "$ALLCONTAINER" ]; then
    echo "❌ Error: Docker-Compose Folder: ${PROJECTNAME} was not found or has no running containers."
    exit 1
fi

# Projects updated elsewhere (e.g. a Komodo stack with Renovate-pinned
# versions) carry the label datacore.update.ignore=true on a container
if docker ps -q --filter "label=com.docker.compose.project=$PROJECTNAME" \
    --filter "label=datacore.update.ignore=true" | grep -q .; then
    echo "⏭️  Skipping '${PROJECTNAME}': labelled datacore.update.ignore=true."
    exit 0
fi

WORKINGDIR=$(for i in $ALLCONTAINER; do
    docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir"}}' "$i"
done | sort -u | head -n 1)

if [ -z "$WORKINGDIR" ] || [ ! -d "$WORKINGDIR" ]; then
    echo "❌ Could not determine working directory for project '${PROJECTNAME}'."
    exit 1
fi

# docker compose for exactly this project: name from the label filter above,
# compose files as it was started with. Without -f a non-default file name
# (or several -f files) is not found. Falls back to the default lookup in
# WORKINGDIR when a recorded file no longer exists.
FIRST_CONTAINER="${ALLCONTAINER%%$'\n'*}"
COMPOSE=(docker compose -p "$PROJECTNAME" --project-directory "$WORKINGDIR")
IFS=',' read -r -a CONFIG_FILES <<< "$(docker inspect \
    --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$FIRST_CONTAINER")"
FILE_ARGS=()
for f in "${CONFIG_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "⚠️  Compose file '${f}' from the container labels is missing, using the default lookup."
        FILE_ARGS=()
        break
    fi
    FILE_ARGS+=(-f "$f")
done
COMPOSE+=("${FILE_ARGS[@]}")

# =======================================================================
# Check the working directory against its Git remote
# =======================================================================
cd "$WORKINGDIR"

# Run git as the owner of the project dir: as root, git refuses a repository
# owned by someone else ("dubious ownership") and the check silently did
# nothing; the owner's SSH key and config are needed for the fetch as well.
# Prompts are disabled so an unattended run cannot hang.
GIT_OWNER=$(stat -c %U "$WORKINGDIR")
if [ "$GIT_OWNER" == root ] || [ "$GIT_OWNER" == UNKNOWN ] || ! command -v sudo >/dev/null 2>&1; then
    GIT=(env LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -C "$WORKINGDIR")
else
    GIT=(sudo -u "$GIT_OWNER" -H -- env LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -C "$WORKINGDIR")
fi

GIT_REPO=false
if GIT_ERR=$("${GIT[@]}" rev-parse --is-inside-work-tree 2>&1 >/dev/null); then
    GIT_REPO=true
elif ! grep -q "not a git repository" <<< "$GIT_ERR"; then
    echo "⚠️  WARNING: Git check of '${WORKINGDIR}' skipped (as user '${GIT_OWNER}'):"
    echo "     ${GIT_ERR//$'\n'/$'\n'     }"
fi

if [ "$GIT_REPO" == true ]; then
    GIT_STATUS=$("${GIT[@]}" status --porcelain)

    # Refresh the remote-tracking ref so local and remote can be compared.
    # Read-only, never touches the working tree. Time-boxed so a private
    # repo or an unreachable remote cannot hang the run — if the fetch
    # fails, the comparison below uses the last known state of the remote.
    if ! GIT_ERR=$(timeout 20 "${GIT[@]}" fetch --quiet 2>&1); then
        echo "⚠️  WARNING: 'git fetch' failed in '${WORKINGDIR}', comparing with the last known remote state:"
        echo "     ${GIT_ERR//$'\n'/$'\n'     }"
    fi

    GIT_UNPUSHED=""
    GIT_BEHIND=""
    if "${GIT[@]}" rev-parse --abbrev-ref --symbolic-full-name "@{u}" &>/dev/null; then
        GIT_UNPUSHED=$("${GIT[@]}" log "@{u}.." --oneline)
        GIT_BEHIND=$("${GIT[@]}" log "..@{u}" --oneline)
    else
        echo "ℹ️  '${WORKINGDIR}': the current branch has no upstream, remote not compared."
    fi

    if [ -n "$GIT_STATUS" ] || [ -n "$GIT_UNPUSHED" ]; then
        echo "⚠️  WARNING: Pending Git changes detected in '${WORKINGDIR}'!"
        if [ -n "$GIT_STATUS" ]; then
            echo "   Uncommitted changes:"
            "${GIT[@]}" status --short | sed 's/^/     /'
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
# Check env files for exposed secrets
# =======================================================================
# Git only tracks the executable bit: a tracked env file is rewritten with
# umask permissions on every pull that changes it, so 'tracked' is reported
# as well. Templates (.env.example etc.) hold no secrets and are skipped.
shopt -s nullglob
for ENVFILE in "$WORKINGDIR"/.env "$WORKINGDIR"/.env.* "$WORKINGDIR"/*.env; do
    [ -f "$ENVFILE" ] || continue
    case "$ENVFILE" in
        *.example|*.sample|*.template|*.dist) continue ;;
    esac
    ENVNAME="${ENVFILE##*/}"

    if [ "$GIT_REPO" == true ] && "${GIT[@]}" ls-files --error-unmatch -- "$ENVNAME" &>/dev/null; then
        echo "⚠️  WARNING: '${ENVFILE}' is tracked by Git — its secrets are in the repository!"
        echo "   Untrack it and ignore it from now on:"
        echo "     git -C $(printf '%q' "$WORKINGDIR") rm --cached -- $(printf '%q' "$ENVNAME") && echo $(printf '%q' "/$ENVNAME") >> $(printf '%q' "$WORKINGDIR/.gitignore")"
    fi

    ENVMODE=$(stat -L -c '%a' "$ENVFILE")
    if (( 8#$ENVMODE & 8#077 )); then
        echo "⚠️  WARNING: '${ENVFILE}' is readable by group/others (mode ${ENVMODE})!"
        echo "   Restrict it to the owner:"
        echo "     chmod go-rwx $(printf '%q' "$ENVFILE")"
    fi
done
shopt -u nullglob

# =======================================================================
# Registry lookups
# =======================================================================
# Docker Hub counts every manifest GET ('docker pull', 'docker compose pull',
# 'buildx imagetools inspect') against the pull rate limit, a HEAD request
# it does not. The check below asks the registry with HEAD only and pulls
# nothing but the images that actually changed.
MANIFEST_ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

# Split an image reference into REF_REGISTRY, REF_PATH and REF_TAG.
# The first segment is a registry when it looks like a host name.
parse_image_ref() {
    local ref="$1" first
    REF_REGISTRY="registry-1.docker.io"
    REF_PATH="$ref"
    if [[ "$ref" == */* ]]; then
        first="${ref%%/*}"
        if [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]]; then
            REF_REGISTRY="$first"
            REF_PATH="${ref#*/}"
        fi
    fi
    case "$REF_REGISTRY" in
        docker.io | index.docker.io) REF_REGISTRY="registry-1.docker.io" ;;
    esac
    REF_TAG="latest"
    if [[ "${REF_PATH##*/}" == *:* ]]; then
        REF_TAG="${REF_PATH##*:}"
        REF_PATH="${REF_PATH%:*}"
    fi
    if [ "$REF_REGISTRY" = "registry-1.docker.io" ] && [[ "$REF_PATH" != */* ]]; then
        REF_PATH="library/${REF_PATH}"
    fi
}

# HEAD on the manifest; prints the response headers. $1 = bearer token or empty
manifest_head() {
    local auth=()
    [ -n "$1" ] && auth=(-H "Authorization: Bearer $1")
    curl -sS -I --max-time 15 -H "Accept: ${MANIFEST_ACCEPT}" "${auth[@]}" \
        "https://${REF_REGISTRY}/v2/${REF_PATH}/manifests/${REF_TAG}" | tr -d '\r'
}

# Print the digest the registry serves for an image reference. Fails when
# the registry cannot be asked anonymously (private, basic auth only,
# unreachable) — the caller decides on a fallback.
registry_digest() {
    local headers status challenge realm service scope token=""
    parse_image_ref "$1"

    headers=$(manifest_head "") || return 1
    status=$(awk 'NR==1 {print $2}' <<<"$headers")

    # Anonymous bearer token, as 'docker pull' fetches it for public images
    if [ "$status" = "401" ]; then
        challenge=$(awk 'tolower($1) == "www-authenticate:" {sub(/^[^:]*: */, ""); print}' <<<"$headers")
        [[ "$challenge" == Bearer* ]] || return 1
        realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")
        service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")
        scope=$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"$challenge")
        [ -n "$realm" ] || return 1
        token=$(curl -sS --max-time 15 -G \
            --data-urlencode "service=${service}" \
            --data-urlencode "scope=${scope:-repository:${REF_PATH}:pull}" \
            "$realm" | grep -o '"token" *: *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/') || return 1
        [ -n "$token" ] || return 1
        headers=$(manifest_head "$token") || return 1
        status=$(awk 'NR==1 {print $2}' <<<"$headers")
    fi

    [ "$status" = "200" ] || return 1
    awk 'tolower($1) == "docker-content-digest:" {print $2}' <<<"$headers" | grep . || return 1
}

# =======================================================================
echo -n "🔍 Checking for newer Docker images for '${PROJECTNAME}'..."

# Services whose image has a newer version in the registry. Only these are
# pulled; 'up' then recreates exactly the containers whose image changed.
declare -A REMOTE_DIGESTS=()
declare -A PULLED_IMAGES=()
PULL_SERVICES=()
UPDATE_NEEDED=false
for CONTAINER in $ALLCONTAINER; do
    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER")
    SERVICE=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service"}}' "$CONTAINER")
    RUNNING_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CONTAINER")

    # Container running an older image than the local tag → recreate needed
    LOCAL_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)
    if [ -n "$LOCAL_IMAGE_ID" ] && [ "$RUNNING_IMAGE_ID" != "$LOCAL_IMAGE_ID" ]; then
        UPDATE_NEEDED=true
    fi

    # Pinned by digest: there is nothing newer behind it
    [[ "$IMAGE" == *@* ]] && continue

    # Every digest the local image is known under. An image keeps the old
    # digests when the registry re-publishes the same content under a new
    # index digest, so only the first entry is not enough.
    LOCAL_DIGESTS=$(docker image inspect \
        --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" 2>/dev/null || true)
    # Locally built image: no registry to compare against
    [ -z "$LOCAL_DIGESTS" ] && continue

    if [ -z "${REMOTE_DIGESTS[$IMAGE]+set}" ]; then
        REMOTE_DIGESTS[$IMAGE]=$(registry_digest "$IMAGE" || true)
    fi
    REMOTE_DIGEST="${REMOTE_DIGESTS[$IMAGE]}"

    if [ -z "$REMOTE_DIGEST" ]; then
        parse_image_ref "$IMAGE"
        if [ "$REF_REGISTRY" = "registry-1.docker.io" ]; then
            # A pull would only burn the rate limit the HEAD check avoids
            echo -en "\n⚠️  Could not query Docker Hub for '${IMAGE}', skipped."
            continue
        fi
        # Private or basic-auth registry: fall back to a pull with the
        # host's credentials, once per image
        if [ -z "${PULLED_IMAGES[$IMAGE]+set}" ]; then
            PULLED_IMAGES[$IMAGE]=1
            docker pull "$IMAGE" >/dev/null 2>&1 || continue
        fi
        LATEST_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE")
        if [ "$RUNNING_IMAGE_ID" != "$LATEST_IMAGE_ID" ]; then
            UPDATE_NEEDED=true
        fi
        continue
    fi

    # containerd image store: the image ID is the index digest itself
    if [ "$REMOTE_DIGEST" != "$LOCAL_IMAGE_ID" ] && ! grep -qF "@${REMOTE_DIGEST}" <<<"$LOCAL_DIGESTS"; then
        PULL_SERVICES+=("$SERVICE")
        UPDATE_NEEDED=true
    fi
done

if [ "$UPDATE_NEEDED" = true ]; then
    echo -e "\n🔄 Update for '${PROJECTNAME}' available!"
    if [[ -n $AUTO ]]; then
        answer="$AUTO"
    else
        read -r -p "Want to continue with the update? (y/n) with a backup? (b): " answer
    fi
    # Only an explicit y or b updates; anything else (n, empty, a typo) aborts
    case "$answer" in
        y|Y) ;;
        b|B)
            echo "📦 Creating backup..."
            backup-docker "${PROJECTNAME}"
            ;;
        *)
            echo "❌ Update canceled."
            exit 0
            ;;
    esac
    # Pull the changed services only, then recreate the changed containers
    # (no 'down' first — avoids leaving the project offline if 'up' fails)
    if [ "${#PULL_SERVICES[@]}" -gt 0 ]; then
        mapfile -t PULL_SERVICES < <(printf '%s\n' "${PULL_SERVICES[@]}" | sort -u)
        "${COMPOSE[@]}" pull "${PULL_SERVICES[@]}"
    fi
    "${COMPOSE[@]}" up -d
    printf "✅ '%s' updated.\n" "$PROJECTNAME"
else
    printf " ✅ All up to date!\n"
fi
