# bash-scripts-collection

Bash scripts for provisioning and maintaining Debian-based servers (plus `install-log.ps1` for Windows Server): SSH hardening,
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
| `install-ssh.sh` | `<username> [--bantime <duration>]` | SSH hardening: openssh-server, pre-auth warning banner, figlet hostname + OS/IP as MOTD (`/etc/update-motd.d/20-datacore`), fail2ban, sudo, `ssh-users` group, authorized_keys. Public keys are read from `pubkeys/<username>.pub`. On a Proxmox VE cluster node (`/etc/pve/corosync.conf` present) root keeps key-only SSH from the corosync addresses of the nodes (`99-pve-cluster.conf` with `Match Address`), root joins `ssh-users` and fail2ban ignores the nodes: PVE needs root SSH for migration, replication and `pvesh` on another node. |
| `install-docker.sh` | | Installs Docker CE. Derives the Docker subnet from the last octet of the host IP, configures IPv4/IPv6 address pools, log limits and NFS support. |
| `install-dockeradminagent.sh` | `--core-ip <ip>[,<ip>...] --core-public-key <key>` | Installs [Komodo](https://komo.do) Periphery as the systemd service `periphery`: pinned release, sha256-verified. The first run writes `/etc/komodo/periphery.config.toml` (root-only): inbound only on port 8120, only Komodo Core's address and public key accepted, no host shell through the web UI. Stack secrets go into its `[secrets]` section and never leave the host. Run again without arguments to update the binary; the config is never overwritten. |
| `install-mon.sh` | `<monitoring-server>` | Installs Zabbix Agent2 with PSK encryption, generates the PSK and prints the matching host configuration for the Zabbix frontend. |
| `install-log.sh` | `--host <fqdn> [--docker] [--proxmox] [--unifi] [--bmc] [--user <email>] [--pass <secret>] [--vlan <id>] [--org <name>]` | Installs Fluent Bit and ships logs to OpenObserve. Source configs live in `logconfs/` (`linux` always, the rest on demand). IP and VLAN are auto-detected. Configuration is written to `/etc/fluent-bit/datacore.conf` and `datacore.env` and wired in through a systemd drop-in, so the packaged `fluent-bit.conf` stays untouched and `apt upgrade` never triggers a conffile prompt. |
| `install-log.ps1` | `-O2Host <fqdn> [-Dc] [-Hmail] [-User <email>] [-Pass <secret>] [-Vlan <id>] [-Org <name>]` | Windows counterpart of `install-log.sh` (Windows Server, PowerShell 5.1, run as Administrator). Fluent Bit must already be installed and may be updated freely (installer, winget, UniGetUI). Writes its own config to `C:\ProgramData\fluent-bit\` (`datacore.conf`, credentials in `datacore-secrets.conf` readable by SYSTEM and Administrators only, `conf.d\`, DB, disk buffer, agent log) and points the `fluent-bit` service at it through the Service Control Manager. The installer's `fluent-bit.conf` is never used, because every update overwrites it. Verifies the credentials before the restart and checks the agent log afterwards. A hand-made setup in the install directory is moved to `legacy-<timestamp>\` and its DB files are taken over. Run with `powershell -ExecutionPolicy Bypass -File .\install-log.ps1 -O2Host log.geek.ch -Hmail`. |
| `install-swap.sh` | `[--size <n>] [--swappiness <n>] [--remove-old] [--fix-resume] [--dry-run]` | Sets up `/pagefile.sys` including fstab entry and persistent `vm.swappiness` (default 10). Size defaults to RAM, capped at 8G and floored at 2G. `--remove-old` disables previous swap partitions or files and cleans up fstab. Refuses to run inside LXC containers, where `pct set <ctid> -swap` is the correct tool. |
| `komodo-migrate-env.sh` | `<project-dir> [<secret-prefix>]` | Moves a Compose project's `.env` into a Komodo stack: secrets (names ending in `TOKEN`, `SECRET`, `PASSWORD`, `PASS`, `_KEY`, and URLs with credentials such as `postgres://user:pass@host`) go to the `[secrets]` of the local Periphery as `<PREFIX>_<NAME>`, and the script prints the stack Environment with `[[<PREFIX>_<NAME>]]` placeholders to paste into Komodo. Periphery fills them in on the host, so secret values never reach Komodo Core. Only when secrets were added is the config backed up (`periphery.config.toml.bak-<timestamp>`) and Periphery restarted; the script fails if it is not active afterwards. Values with `${...}` interpolation are kept interpolating and reported. The `.env` is left unchanged; re-running skips secrets already there. |

### Backup and restore

| Script | Parameters | Description |
|---|---|---|
| `backup-docker.sh` | `{PROJECT} {BACKUPDIR:/mnt/backup/} {DAYS:2}` | Backs up one Docker Compose project: compose configuration, volumes and databases (MariaDB, MySQL, PostgreSQL, MongoDB, GitLab). Database containers are recognised by their exact image name (`mariadb`, `mysql`, `postgres`, `timescale/timescaledb(-ha)`, `postgis/postgis`, `pgvector/pgvector`, `ghcr.io/immich-app/postgres`, `tensorchord/pgvecto-rs`, the `bitnami/` and `linuxserver/` variants, …) and dumped whether their data lives in a named volume or a bind mount; the label `datacore.backup.type=postgres\|mariadb\|mysql\|none` overrides the detection. MariaDB/MySQL dumps use `--single-transaction --routines --events --triggers`; the root password comes from `MYSQL_ROOT_PASSWORD`, `MARIADB_ROOT_PASSWORD`, `DB_ROOT_PASSWORD` or the `*_FILE` variants and is resolved inside the container. PostgreSQL uses `POSTGRES_USER`/`POSTGRES_PASSWORD` (or bitnami's `POSTGRESQL_POSTGRES_PASSWORD`, `POSTGRESQL_USERNAME`/`POSTGRESQL_PASSWORD`), default user `postgres`; a password is handed to the clients as `PGPASSWORD` inside the container. When a dump is skipped or fails, the container's named volumes are tarred instead as a fallback. GitLab: the newest `gitlab-backup` archive (then removed from `/mnt/backup-cache/gitlab-backup`) plus `gitlab.rb` and `gitlab-secrets.json` (`.gitlabconfig.tar.gz`). SQL dumps are compressed with `zstd` (all cores, `.sql.zst`) when it is installed, otherwise with `gzip` (`.sql.gz`). A container labelled `datacore.backup.ignore=true` is skipped with all its volumes, one labelled `datacore.backup.stop=true` is stopped while its volumes are tarred. Files are written as `.<name>.part` and renamed when complete. Cleanup deletes files older than `DAYS` but always keeps the newest file of every artefact. A missing password or a failed dump does not stop the other containers, but the run exits with 1; exit 75 means the project has no running containers. For TimescaleDB the dump starts with one comment line per database (`-- backup-docker timescaledb: <db> <version>`), and pg_dump's expected warnings about circular foreign keys in the TimescaleDB catalog are hidden (only counted), so a log monitor does not alert on every run. |
| `backup-docker-all.sh` | `{BACKUPDIR:/mnt/backup/} {DAYS:2} {PBS_REPO}` | Backs up all running Compose projects, optionally uploading `BACKUPDIR/<hostname>` to a Proxmox Backup Server (archive `<hostname>.pxar`; since 2026-10-19 its root is `BACKUPDIR/<hostname>`, one level deeper than in older snapshots, which held the whole `BACKUPDIR`). Refuses to run when `BACKUPDIR` is missing or lies on the root filesystem (a subdirectory of a mount is fine), unless `ALLOW_UNMOUNTED=1` is set. Shares the lock `/run/lock/datacore-docker.lock` with `update-docker-all` and waits up to 1 h for it. |
| `restore-docker.sh` | `{BACKUPDIR:/mnt/backup/}` | Interactive restore of a Compose project. Run from the project directory. Restores every type `backup-docker.sh` writes. A PostgreSQL dump is only restored into an empty database (fresh volume), a volume only while no running container uses it. A volume archive is tested and extracted next to the target first; the current volume dir is kept as `<dir>.bak-<timestamp>`, not deleted. Compose files and project name come from the container labels when the project exists, so non-default compose file names work. GitLab: restore the `.gitlabconfig.tar.gz` (secrets) before the `.gitlabbackup.tar`; the script waits until GitLab is healthy. Wait limits: `RESTORE_TIMEOUT` (default 180 s), `RESTORE_GITLAB_TIMEOUT` (default 900 s). TimescaleDB: the image must have the same extension version as the dump (checked against the header, otherwise the restore stops and says which tag to pin); the restore runs between `timescaledb_pre_restore()` and `timescaledb_post_restore()`. Dumps made before 2026-10-13 have no header, the version is then not checked. |
| `backup-remoteserver.sh` | `<remote-ip> <remote-path>` | Backs up a remote path to a Proxmox Backup Server through an SSH reverse tunnel. Credentials in `/etc/backup-remoteserver.conf`. |

### Updates

| Script | Parameters | Description |
|---|---|---|
| `update-docker.sh` | `{PROJECT} --auto={y,n,b}` | Updates one Compose project. `--auto` controls the restart: yes, no, or backup first; any other value is rejected, and at the prompt only `y` or `b` update (anything else aborts). Compose is called with the project name and the compose files from the container labels, so non-default file names work. Warns when the project directory has uncommitted or unpushed changes, and when it is behind its Git remote and should be pulled before the containers are updated. Git runs as the owner of the project directory (root would hit "dubious ownership"), and Git errors are shown instead of skipping the check silently. Also warns when an env file (`.env`, `.env.*`, `*.env`, templates excluded) is readable by group/others or tracked by Git. Checks for newer images with HEAD requests on the registry manifest, which Docker Hub does not count against its pull rate limit, and pulls only the services whose image changed. Images from private registries that refuse an anonymous token fall back to a `docker pull` with the host's credentials. A project with the label `datacore.update.ignore=true` on any container (e.g. a Komodo stack with Renovate-pinned versions) is skipped. |
| `update-docker-all.sh` | | Updates all running Compose projects with `--auto=y`, then prunes unused images. Waits up to 1 h for a running `backup-docker-all` (shared lock `/run/lock/datacore-docker.lock`). |
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
| `logconfs/` | `install-log.sh`, `install-log.ps1` | Fluent Bit input configs: `linux.conf`, `docker.conf`, `proxmox.conf`, `unifi.conf`, `bmc.conf`, `truenas.conf` (Linux); `windows.conf`, `dc.conf`, `hmail.conf` (Windows). | |
| `pubkeys/` | `install-ssh.sh` | One SSH public key file per user, named `<username>.pub`. |

## Provisioning a new server

Order used for a fresh Debian 13 install:

```bash
install-ssh datacore --bantime 30m     # SSH hardening, sudo, fail2ban, keys
install-docker                          # only where containers run
install-dockeradminagent --core-ip <core-ip> --core-public-key <key>   # Komodo agent, Docker hosts only
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
  03  03   *   *   *    backup-docker-all '/mnt/backup' 0 > /var/log/dataCoreBackupScript.log 2>&1
  03  05   *   *   03   update-system -y > /var/log/dataCoreUpdateScript.log
  43  05   *   *   03   update-docker-all > /var/log/dataCoreUpdateDockerScript.log
```

`backup-docker-all` exits with an error when `/mnt/backup` is not on a mounted
filesystem (it lies on `/`), so a missing CIFS mount no longer fills the local disk
unnoticed (`ALLOW_UNMOUNTED=1` for a local backup dir); `2>&1` sends error messages
to the log as well.
