# bash-scripts-collection

Bash scripts for provisioning and maintaining Debian-based servers: SSH hardening,
Docker installation, monitoring and log agents, swap setup, Docker Compose backup and
restore, and unattended system updates.

Written for Debian 12/13 and Proxmox hosts. Use at your own risk.
License: MIT.

## Installation

```bash
sudo mkdir -p /usr/bin/datacore/bash
git clone https://github.com/dataCore/bash-scripts-collection.git /usr/bin/datacore/bash/
bash /usr/bin/datacore/bash/link.sh
```

`link.sh` symlinks every script into `/usr/bin/` without the `.sh` suffix, so
`install-ssh.sh` is called as `install-ssh`. Verify with `show-lastreboot`.

## Scripts

### Installation and setup

| Script | Parameters | Description |
|---|---|---|
| `install-ssh.sh` | `<username> [--bantime <duration>]` | SSH hardening: openssh-server, figlet banner, fail2ban, sudo, `ssh-users` group, authorized_keys. Public keys are read from `pubkeys/<username>.pub`. |
| `install-docker.sh` | | Installs Docker CE. Derives the Docker subnet from the last octet of the host IP, configures IPv4/IPv6 address pools, log limits and NFS support. |
| `install-mon.sh` | `<monitoring-server>` | Installs Zabbix Agent2 with PSK encryption, generates the PSK and prints the matching host configuration for the Zabbix frontend. |
| `install-log.sh` | `--host <fqdn> [--docker] [--proxmox] [--unifi] [--user <email>] [--pass <secret>] [--vlan <id>] [--org <name>]` | Installs Fluent Bit and ships logs to OpenObserve. Source configs live in `logconfs/` (`linux` always, the rest on demand). IP and VLAN are auto-detected. Configuration is written to `/etc/fluent-bit/datacore.conf` and `datacore.env` and wired in through a systemd drop-in, so the packaged `fluent-bit.conf` stays untouched and `apt upgrade` never triggers a conffile prompt. |
| `install-swap.sh` | `[--size <n>] [--swappiness <n>] [--remove-old] [--fix-resume] [--dry-run]` | Sets up `/pagefile.sys` including fstab entry and persistent `vm.swappiness` (default 10). Size defaults to RAM, capped at 8G and floored at 2G. `--remove-old` disables previous swap partitions or files and cleans up fstab. Refuses to run inside LXC containers, where `pct set <ctid> -swap` is the correct tool. |

### Backup and restore

| Script | Parameters | Description |
|---|---|---|
| `backup-docker.sh` | `{PROJECT} {BACKUPDIR:/mnt/backup/} {DAYS:2}` | Backs up one Docker Compose project: compose configuration, volumes and databases (MariaDB, MySQL, PostgreSQL, MongoDB, GitLab). |
| `backup-docker-all.sh` | `{BACKUPDIR:/mnt/backup/} {DAYS:2} {PBS_REPO}` | Backs up all running Compose projects, optionally uploading to a Proxmox Backup Server. |
| `restore-docker.sh` | `{BACKUPDIR:/mnt/backup/}` | Interactive restore of a Compose project. Run from the project directory. |
| `backup-remoteserver.sh` | `<remote-ip> <remote-path>` | Backs up a remote path to a Proxmox Backup Server through an SSH reverse tunnel. Credentials in `/etc/backup-remoteserver.conf`. |

### Updates

| Script | Parameters | Description |
|---|---|---|
| `update-docker.sh` | `{PROJECT} --auto={y,n,b}` | Updates one Compose project. `--auto` controls the restart: yes, no, or backup first. Warns about uncommitted changes in the project directory. |
| `update-docker-all.sh` | | Updates all running Compose projects with `--auto=y`, then prunes unused images. |
| `update-system.sh` | `[-y]` | Full `dist-upgrade`. With `-y` reboots automatically when required; pending kernel updates are detected on Debian and Proxmox. Also updates this collection. |
| `update-scripts.sh` | | Updates this collection via `git pull`, hard-resetting to `origin/main` on conflict, and re-runs `link.sh`. |

### Security

| Script | Parameters | Description |
|---|---|---|
| `check-cve.sh` | `[--fix] [--json]` | Checks the host against current kernel and userspace CVEs (Copy Fail, Dirty Frag, Fragnesia, CrackArmor, ptrace mm-NULL, CIFSwitch). `--fix` applies module blacklists and sysctl mitigations, `--json` produces machine-readable output. |

### Utilities

| Script | Parameters | Description |
|---|---|---|
| `show-lastreboot.sh` | | Prints the time of the last reboot. |
| `link.sh` | | Symlinks all scripts into `/usr/bin/`. Run once after cloning. |

## Data directories

| Directory | Used by | Contents |
|---|---|---|
| `logconfs/` | `install-log.sh` | Fluent Bit input configs: `linux.conf`, `docker.conf`, `proxmox.conf`, `unifi.conf`, `windows.conf`. |
| `pubkeys/` | `install-ssh.sh` | One SSH public key file per user, named `<username>.pub`. |

## Provisioning a new server

Order used for a fresh Debian 13 install:

```bash
install-ssh datacore --bantime 30m     # SSH hardening, sudo, fail2ban, keys
install-docker                          # only where containers run
install-mon dataCoreMonitor             # Zabbix agent; itpmonitor for ITP hosts
install-swap                            # swap file, size derived from RAM
install-log --host log.example.ch --docker
check-cve
```

## Cron

```bash
# Only required when uploading to a Proxmox Backup Server:
PBS_PASSWORD="..."
PBS_FINGERPRINT="..."

# m   h   dom mon dow   command
  03  03   *   *   *    backup-docker-all '/mnt/backup' 0 > /var/log/dataCoreBackupScript.log
  03  05   *   *   03   update-system -y > /var/log/dataCoreUpdateScript.log
  43  05   *   *   03   update-docker-all > /var/log/dataCoreUpdateDockerScript.log
```
