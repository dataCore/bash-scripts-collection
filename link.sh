#!/bin/bash
folder="datacore/bash"
cd /usr/bin || exit 1

scripts=(
	"backup-docker.sh:backup-docker"
	"backup-docker-all.sh:backup-docker-all"
	"install-docker.sh:install-docker"
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
  	chmod 710 "$folder/$script"
  	ln -sf "$folder/$script" "$linkname"
done
