#!/bin/bash
folder="/usr/bin/datacore/bash"

scripts=(
    "install-docker.sh:install-docker"
    "restore-docker.sh:restore-docker"
    "update-docker.sh:update-docker"
    "update-system.sh:update-system"
    "update-scripts.sh:update-scripts"
    "backup-docker.sh:backup-docker"
    "backup-docker-all.sh:backup-docker-all"
    "update-docker-all.sh:update-docker-all"
    "show-lastreboot.sh:show-lastreboot"
    "wol.sh:wol"
)

for entry in "${scripts[@]}"; do
    IFS=":" read -r script linkname <<<"$entry"
    chmod 710 "$folder/$script"
    ln -sf "$folder/$script" "$linkname"
done
