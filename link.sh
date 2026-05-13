#!/bin/bash
cd /usr/bin
folder="/usr/bin/datacore/bash"

scripts=(
    "backup-docker.sh:backup-docker"
    "backup-docker-all.sh:backup-docker-all"
    "backup-remoteserver.sh:backup-remoteserver"
    "check-cve.sh:check-cve"
    "install-docker.sh:install-docker"
	"install-mon.sh:install-mon"
    "install-ssh.sh:install-ssh"
    "restore-docker.sh:restore-docker"
    "show-lastreboot.sh:show-lastreboot"
    "update-docker.sh:update-docker"
    "update-docker-all.sh:update-docker-all"
    "update-scripts.sh:update-scripts"
    "update-system.sh:update-system"
    "wol.sh:wol"
)

for entry in "${scripts[@]}"; do
    IFS=":" read -r script linkname <<<"$entry"
    chmod 755 "$folder/$script"
    ln -sf "$folder/$script" "$linkname"
done
