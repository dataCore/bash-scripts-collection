#!/bin/bash
cd /usr/bin || exit 1
folder="/usr/bin/datacore/bash"

scripts=(
    "backup-docker.sh:backup-docker"
    "backup-docker-all.sh:backup-docker-all"
    "backup-remoteserver.sh:backup-remoteserver"
    "check-cve.sh:check-cve"
    "install-docker.sh:install-docker"
    "install-log.sh:install-log"
    "install-mon.sh:install-mon"
    "install-ssh.sh:install-ssh"
    "install-swap.sh:install-swap"
    "restore-docker.sh:restore-docker"
    "show-lastreboot.sh:show-lastreboot"
    "update-docker.sh:update-docker"
    "update-docker-all.sh:update-docker-all"
    "update-scripts.sh:update-scripts"
    "update-system.sh:update-system"
)

for entry in "${scripts[@]}"; do
    IFS=":" read -r script linkname <<<"$entry"
    chmod 755 "$folder/$script"
    ln -sf "$folder/$script" "$linkname"
done
