#!/bin/bash
# =======================================================================
# UPDATE DOCKER ALL SCRIPT for all Containers on a Server
# by dataCore
#
# iterates over all docker container and check if there is an update
#
#
# Usage: update-docker-all
#
# =======================================================================
# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo or as root."
  exit 1
fi
# START scripts
update-scripts
# START script
echo "===============> UPDATE 🔄 DOCKER ALL SCRIPT"
HOSTNAME="$(hostname)"
echo "===============> Starting update-docker-all SCRIPT for: '${HOSTNAME}'"
# Set the language
export LANG="en_US.UTF-8"
# Load the Pathes
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Fehlerbehandlung aktivieren
set -euo pipefail
trap 'echo -e "\n❌ Error in Line $LINENO. Update Script canceled."; exit 1' ERR
# =======================================================================
ALLCONTAINER=$(docker ps --format '{{.Names}}')
ALLPROJECTS=$(for i in $ALLCONTAINER; do docker inspect --format '{{ index .Config.Labels "com.docker.compose.project"}}' "$i"; done | sort -u)
### Do the stuff
# A failing project must not abort the remaining updates – collect failures
# and report them at the end with a non-zero exit code for monitoring.
FAILED_PROJECTS=()
for PROJECTNAME in $ALLPROJECTS; do
    if ! update-docker "$PROJECTNAME" --auto=y; then
        echo "❌ Update of project '${PROJECTNAME}' failed. Continuing with next project."
        FAILED_PROJECTS+=("$PROJECTNAME")
    fi
done
docker image prune -f
echo "Script to update all Docker Compose Projects completed"
# =======================================================================
echo "===============> End of update-docker-all SCRIPT for: '${HOSTNAME}' "
if [ "${#FAILED_PROJECTS[@]}" -gt 0 ]; then
    echo "❌ Failed projects: ${FAILED_PROJECTS[*]}"
    exit 1
fi
