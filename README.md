# 📦 dataCore's Bash Scripts Collection

This repository contains a collection of useful Bash scripts for e.g. managing Docker containers and performing system tasks. These scripts simplify backup, restore, installation, and updates for Docker, and linux systems in general. Additionaly there are some usefull utility scripts.

⚠️ Usage at your own risk.
📝 License: Free (give me a beer)


## 🗂️ Contents

| Script Name            | Description |
|------------------------|-------------|
| `install-docker.sh`    | Installs Docker on a Linux system. |
| `backup-docker.sh`     | Creates a backup of a single Docker container. |
| `backup-docker-all.sh` | Creates backups of all running Docker containers. |
| `restore-docker.sh`    | Restores a Docker container from a backup file. |
| `update-docker.sh`     | Updates a single Docker container. |
| `update-docker-all.sh` | Updates all Docker containers. |
| `update-scripts.sh`    | Updates this scripts collection itself. |
| `update-system.sh`     | Performs all linux system updates and also updates the scripts itself and makes a reboot if needed |
| `show-lastreboot.sh`   | Displays the last system reboot time. |
| `link.sh`              | Creates symbolic links for all scripts in this collection. |
| `wol.sh`               | Sends a Wake-on-LAN packet to a device on the network. |

## 🛠️ Installation

- Create Folder: `sudo mkdir -p /usr/bin/datacore/bash` 
- Clone the Project: 'git clone https://github.com/dataCore/bash-scripts-collection.git /usr/bin/datacore/bash/' 
- Execute the Script-Linker: `bash /usr/bin/datacore/bash/link.sh`
- Test it:  `show-lastreboot`

## ⏰ Cronjobs

To automate the scripts, you can use 'crontab -e' to backup e.g. each day at 03:23 and update the system and all docker-compose each wednesday at 05:03

```bash
# m h  dom mon dow   command
23 03 * * * backup-docker-all '/mnt/backup' 0 > /var/log/dataCoreBackupScript.log
23 05 * * 03 update-system -y > /var/log/dataCoreUpdateScript.log
43 05 * * 03 update-docker-all > /var/log/dataCoreUpdateDockerScript.log
```

