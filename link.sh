#!/bin/bash
cd /usr/bin || exit 1
folder="/usr/bin/datacore/bash"

scripts=(
    "backup-docker.sh:backup-docker"
    "backup-docker-all.sh:backup-docker-all"
    "backup-remoteserver.sh:backup-remoteserver"
    "check-cve.sh:check-cve"
    "fix-apt-sources.sh:fix-apt-sources"
    "install-docker.sh:install-docker"
    "install-dockeradminagent.sh:install-dockeradminagent"
    "install-log.sh:install-log"
    "install-mon.sh:install-mon"
    "install-ssh.sh:install-ssh"
    "install-swap.sh:install-swap"
    "komodo-migrate-env.sh:komodo-migrate-env"
    "restore-docker.sh:restore-docker"
    "show-lastreboot.sh:show-lastreboot"
    "update-docker.sh:update-docker"
    "update-docker-all.sh:update-docker-all"
    "update-scripts.sh:update-scripts"
    "update-system.sh:update-system"
)

for entry in "${scripts[@]}"; do
    IFS=":" read -r script linkname <<<"$entry"
    if [ ! -f "$folder/$script" ]; then
        echo "Skipped $linkname: $folder/$script not found."
        continue
    fi
    # Checked out as 100755 by git; only repair a copy that lost the bit
    [ -x "$folder/$script" ] || chmod 755 "$folder/$script"
    ln -sf "$folder/$script" "$linkname"
done

# Remove links into the collection whose script no longer exists
for link in /usr/bin/*; do
    { [ -L "$link" ] && [ ! -e "$link" ]; } || continue
    case "$(readlink "$link")" in
        "$folder"/*)
            rm -f "$link"
            echo "Removed dangling link $link"
            ;;
    esac
done
