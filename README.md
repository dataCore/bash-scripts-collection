# 📦 dataCore's Bash Scripts Collection

This repository contains a collection of useful Bash scripts for managing Docker containers, SSH hardening, monitoring, and general system tasks. These scripts simplify backup, restore, installation, and updates for Docker and Linux systems in general. Additionally there are some useful utility scripts.

⚠️ Usage at your own risk.
📝 License: Free (give me a beer)


## 🗂️ Contents

### 🔧 Installation & Setup

| Script | Parameters | Description |
|---|---|---|
| `install-ssh.sh` | `<username> [--bantime <duration>]` | Full SSH hardening: installs openssh-server, figlet banner, fail2ban, sudo, ssh-users group, authorized_keys. Public keys loaded from `pubkeys/<username>.pub`. |
| `install-docker.sh` | | Installs Docker CE. Auto-derives Docker subnet from host IP (last octet). Configures IPv4/IPv6 pools, log limits, and NFS support. |
| `install-mon.sh` | `<monitoring-server>` | Installs and configures Zabbix Agent2 with PSK encryption. Generates PSK key and prints copy-paste config for Zabbix frontend. |
| `install-sshkey.sh` | | Installs public SSH key for the current user from the dataCore key repository. |

### 💾 Backup & Restore

| Script | Parameters | Description |
|---|---|---|
| `backup-docker.sh` | `{PROJECT} {BACKUPDIR:/mnt/backup/} {DAYS:2}` | Creates a backup of a single Docker Compose project. |
| `backup-docker-all.sh` | `{BACKUPDIR:/mnt/backup/} {DAYS:2} {PBS_REPO}` | Creates backups of all running Docker Compose projects, optionally uploads to Proxmox Backup Server. |
| `restore-docker.sh` | `{BACKUPDIR:/mnt/backup/}` | Interactively restores a Docker Compose project from a backup. |

### 🔄 Updates

| Script | Parameters | Description |
|---|---|---|
| `update-docker.sh` | `{PROJECT} --auto={y,n,b}` | Updates a single Docker Compose project. Auto-restart: yes, no, or with backup first. |
| `update-docker-all.sh` | | Updates all running Docker Compose projects with `--auto=y`. |
| `update-system.sh` | `[-y]` | Full Linux system update (dist-upgrade). `-y` triggers automatic reboot if required. Also updates the scripts collection itself. |
| `update-scripts.sh` | | Updates this scripts collection via git pull. |

### 🛠️ Utilities

| Script | Parameters | Description |
|---|---|---|
| `show-lastreboot.sh` | | Displays the last system reboot time. |
| `wol.sh` | `{MAC} {IP} {Port}` | Sends a Wake-on-LAN magic packet to a device on the network. |
| `link.sh` | | Creates symbolic links for all scripts into `/usr/bin/` (run once after install). |


## 📁 Repository Structure

```
bash-scripts-collection/
├── install-ssh.sh
├── install-docker.sh
├── install-mon.sh
├── install-sshkey.sh
├── backup-docker.sh
├── backup-docker-all.sh
├── restore-docker.sh
├── update-docker.sh
├── update-docker-all.sh
├── update-system.sh
├── update-scripts.sh
├── show-lastreboot.sh
├── wol.sh
├── link.sh
├── pubkeys/
│   ├── datacore.pub      ← SSH public keys per user
│   └── itp.pub
└── README.md
```


## 🛠️ Installation

```bash
# Create folder and clone
sudo mkdir -p /usr/bin/datacore/bash
git clone https://github.com/dataCore/bash-scripts-collection.git /usr/bin/datacore/bash/

# Link all scripts to /usr/bin/
bash /usr/bin/datacore/bash/link.sh

# Test
show-lastreboot
```


## 🚀 Fresh Debian Server Setup

Recommended order for setting up a new Debian 13 system:

```bash
# 1. SSH hardening, sudo, fail2ban, authorized_keys
install-ssh datacore [--bantime 30m]

# 2. Docker CE (if needed)
install-docker

# 3. Monitoring agent
install-mon dataCoreMonitor
# or for ITP:
install-mon itpmonitor
```


## ⏰ Cronjobs

Standard cron setup for automated backups and updates:

```bash
# Edit with: crontab -e

PBS_PASSWORD="YourPBSPassword"
PBS_FINGERPRINT="Your:PBS:Fingerprint"

# m  h    dom mon dow   command
03  03  *  *  *    backup-docker-all '/mnt/backup' 0 > /var/log/dataCoreBackupScript.log
03  05  *  *  03   update-system -y > /var/log/dataCoreUpdateScript.log
43  05  *  *  03   update-docker-all > /var/log/dataCoreUpdateDockerScript.log
```
