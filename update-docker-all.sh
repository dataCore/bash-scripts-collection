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
for PROJECTNAME in $ALLPROJECTS; do
    update-docker "$PROJECTNAME" --auto=y
done
docker system prune -f
echo "Script to update all Docker Compose Projects completed"
# =======================================================================
echo "===============> End of backup-docker-all SCRIPT for: '${HOSTNAME}' "
