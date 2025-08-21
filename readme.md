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
| `update-system.sh`     | Performs all linux system updates and makes a reboot if needed |
| `show-lastreboot.sh`   | Displays the last system reboot time. |
| `link.sh`              | Creates symbolic links for all scripts in this collection. |
| `wol.sh`               | Sends a Wake-on-LAN packet to a device on the network. |

## 🛠️ Installation

- Create Folder: `sudo mkdir -p /usr/bin/datacore/bash` 
- Clone the Project: 'git clone https://github.com/dataCore/bash-scripts-collection.git /usr/bin/datacore/bash/' 
- Execute the Script-Linker: `bash /usr/bin/datacore/bash/link.sh`
- Test it:  `show-lastreboot`
