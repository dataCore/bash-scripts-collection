# bash-scripts-collection

Bash scripts for provisioning and maintaining Debian-based servers (plus `install-log.ps1` and `update-scripts.ps1` for Windows Server): SSH hardening,
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

### Windows Server

Windows has no git, so `update-scripts.ps1` keeps a copy of `main` up to date
instead. Fetch it alone into an empty directory; its first run fetches the
rest:

```powershell
New-Item -ItemType Directory -Force C:\Scripts\bash-scripts-collection | Out-Null
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/dataCore/bash-scripts-collection/main/update-scripts.ps1 -OutFile C:\Scripts\bash-scripts-collection\update-scripts.ps1
powershell -ExecutionPolicy Bypass -File C:\Scripts\bash-scripts-collection\update-scripts.ps1
```

Run the same last line before using a script to update the copy. The Bash
scripts come along but are not used on Windows, and the Linux hosts ignore
the `.ps1` files (`link.sh` only links what it lists).

## Scripts

### Installation and setup

| Script | Parameters | Description |
|---|---|---|
| `install-ssh.sh` | `<username> [--bantime <duration>]` | SSH hardening: openssh-server, pre-auth warning banner, figlet hostname + OS/IP as MOTD (`/etc/update-motd.d/20-datacore`), fail2ban, sudo, `ssh-users` group, authorized_keys. Public keys are read from `pubkeys/<username>.pub`; the keys are installed first, and sshd is only hardened once `authorized_keys` holds at least one valid key. The hardening lives in `/etc/ssh/sshd_config.d/00-datacore-hardened.conf` (sshd keeps the first value it reads, so it sorts before other drop-ins; the older `99-datacore-hardened.conf` is removed) and is checked with `sshd -T` after the reload. Because the hardening now wins over `sshd_config` and drop-ins such as `50-cloud-init.conf`, a re-run on a host where password or root login was effective until now cuts off accounts that relied on it: before changing anything the script lists what changes and which accounts would lose SSH access (not in `ssh-users`, or a password but no `authorized_keys`, root), asks for confirmation on a terminal and only warns when run non-interactively. Idempotent: a file is only written when its content differs (the generated files carry no timestamp), sshd is only reloaded and fail2ban only restarted when their config changed, and a re-run on a configured host ends with "No change". Each run backs up `sshd_config` and its drop-ins to `/etc/ssh/install-ssh-backup/<timestamp>/` and keeps that backup only when it changed something under `/etc/ssh` (the newest 10 are kept); a failed `sshd -t` restores that state. On a Proxmox VE cluster node (`/etc/pve/corosync.conf` present) root keeps key-only SSH from the corosync addresses of the nodes (`99-pve-cluster.conf` with `Match Address`), root joins `ssh-users` and fail2ban ignores the nodes: PVE needs root SSH for migration, replication and `pvesh` on another node. |
| `install-docker.sh` | `[--subnet <v4-cidr>] [--subnet6 <v6-cidr>]` | Installs Docker CE with NFS support. Derives the address pool from the last octet of the host IP (`172.<octet>.0.0/16` + `fd00:172:<octet>::/64`); that is only private address space for octets 16–31, otherwise the script stops and asks for `--subnet` (IPv6 derived as `fd00:<a>:<b>::/64` unless `--subnet6` is given). A new pool that overlaps the routing table is refused. Address pools already in `daemon.json` are always kept, so an existing host's networks never move. `daemon.json` is merged, not replaced: a log-driver set by `install-log.sh --docker` stays, `json-file` with log limits is only set when no driver is configured. Re-runs install only missing packages (updates are left to `update-system`) and restart Docker only when `daemon.json` changed, since every restart stops all containers. |
| `install-dockeradminagent.sh` | `--core-ip <ip>[,<ip>...] --core-public-key <key>` | Installs [Komodo](https://komo.do) Periphery as the systemd service `periphery`: pinned release, sha256-verified. The first run writes `/etc/komodo/periphery.config.toml` (root-only): inbound only on port 8120, only Komodo Core's address and public key accepted, no host shell through the web UI. Stack secrets go into its `[secrets]` section and never leave the host. Run again without arguments to update the binary; the config is never overwritten. If the installed binary already matches the pinned sha256, nothing is downloaded and the running service is left alone. |
| `install-mon.sh` | `<monitoring-server> [--zabbix-version <X.Y>]` | Installs Zabbix Agent2 with PSK encryption, generates the PSK and prints the matching host configuration for the Zabbix frontend. The official Zabbix repository is pinned to 7.0 (LTS, like our server); `--zabbix-version` picks another release when the repository is added. |
| `install-log.sh` | `--host <fqdn> [--docker] [--proxmox] [--unifi] [--bmc] [--user <email>] [--pass <secret>] [--vlan <id>] [--org <name>]` | Installs Fluent Bit and ships logs to OpenObserve. Source configs live in `logconfs/` (`linux` always, the rest on demand). IP and VLAN are auto-detected. Configuration is written to `/etc/fluent-bit/datacore.conf` and `datacore.env` and wired in through a systemd drop-in, so the packaged `fluent-bit.conf` stays untouched and `apt upgrade` never triggers a conffile prompt. An installed Fluent Bit is not upgraded; updates are left to `update-system`. |
| `install-log.ps1` | `-O2Host <fqdn> [-Dc] [-Hmail] [-User <email>] [-Pass <secret>] [-Vlan <id>] [-Org <name>]` | Windows counterpart of `install-log.sh` (Windows Server, PowerShell 5.1, run as Administrator). Fluent Bit must already be installed and may be updated freely (installer, winget, UniGetUI). Writes its own config to `C:\ProgramData\fluent-bit\` (`datacore.conf`, credentials in `datacore-secrets.conf`, `conf.d\`, DB, disk buffer, agent log; the whole directory readable by SYSTEM and Administrators only) and points the `fluent-bit` service at it through the Service Control Manager, with restart on failure. The installer's `fluent-bit.conf` is never used, because every update overwrites it. Verifies the credentials and validates the new config (`--dry-run`) before it stops the service: if validation fails, the current config and the running agent stay untouched. Checks the agent log after the start. A re-run offers the credentials from `datacore-secrets.conf` when neither `-User` nor `-Pass` is given. Event log channels a host does not have are left out with a warning: `winevtlog` refuses to start on a missing channel, and `--dry-run` does not notice. A hand-made setup in the install directory is moved to `legacy-<timestamp>\` and its DB files are taken over. Event logs are read with the `winevtlog` input (since 2026-10, before `winlog`): its field names differ (`ProviderName`, `Computer`, `EventRecordID`, `TimeCreated`, numeric `Level` instead of `SourceName`, `ComputerName`, `RecordNumber`, `TimeGenerated`, `EventType`), see `logconfs/windows.conf`. Run with `powershell -ExecutionPolicy Bypass -File .\install-log.ps1 -O2Host log.geek.ch -Hmail`. |
| `install-swap.sh` | `[--size <n>] [--swappiness <n>] [--remove-old] [--fix-resume] [--dry-run]` | Sets up `/pagefile.sys` including fstab entry and persistent `vm.swappiness` (default 10). Size defaults to RAM, capped at 8G and floored at 2G. `--remove-old` disables previous swap partitions or files and cleans up fstab, and points to `--fix-resume` if the resume config still names a removed partition. Refuses to run inside LXC containers, where `pct set <ctid> -swap` is the correct tool. |
| `komodo-migrate-env.sh` | `<project-dir> [<secret-prefix>]` | Moves a Compose project's `.env` into a Komodo stack: secrets (names ending in `TOKEN`, `SECRET`, `PASSWORD`, `PASS`, `_KEY`, and URLs with credentials such as `postgres://user:pass@host`) go to the `[secrets]` of the local Periphery as `<PREFIX>_<NAME>`, and the script prints the stack Environment with `[[<PREFIX>_<NAME>]]` placeholders to paste into Komodo. Periphery fills them in on the host, so secret values never reach Komodo Core. Only when secrets were added is the config backed up (`periphery.config.toml.bak-<timestamp>`) and Periphery restarted; the script fails if it is not active afterwards. Values with `${...}` interpolation are kept interpolating and reported. The `.env` is left unchanged; re-running skips secrets already there. |

### Backup and restore

| Script | Parameters | Description |
|---|---|---|
| `backup-docker.sh` | `{PROJECT} {BACKUPDIR:/mnt/backup/} {DAYS:2}` | Backs up one Docker Compose project: compose configuration, volumes and databases (MariaDB, MySQL, PostgreSQL, MongoDB, GitLab). Database containers are recognised by their exact image name (`mariadb`, `mysql`, `postgres`, `timescale/timescaledb(-ha)`, `postgis/postgis`, `pgvector/pgvector`, `ghcr.io/immich-app/postgres`, `tensorchord/pgvecto-rs`, the `bitnami/` and `linuxserver/` variants, …) and dumped whether their data lives in a named volume or a bind mount; the label `datacore.backup.type=postgres\|mariadb\|mysql\|none` overrides the detection. MariaDB/MySQL dumps use `--single-transaction --routines --events --triggers`; the root password comes from `MYSQL_ROOT_PASSWORD`, `MARIADB_ROOT_PASSWORD`, `DB_ROOT_PASSWORD` or the `*_FILE` variants and is resolved inside the container. PostgreSQL uses `POSTGRES_USER`/`POSTGRES_PASSWORD` (or bitnami's `POSTGRESQL_POSTGRES_PASSWORD`, `POSTGRESQL_USERNAME`/`POSTGRESQL_PASSWORD`), default user `postgres`; a password is handed to the clients as `PGPASSWORD` inside the container. When a dump is skipped or fails, the container's named volumes are tarred instead as a fallback. GitLab: the newest `gitlab-backup` archive (then removed from `/mnt/backup-cache/gitlab-backup`) plus `gitlab.rb` and `gitlab-secrets.json` (`.gitlabconfig.tar.gz`). SQL dumps are compressed with `zstd` (all cores, `.sql.zst`) when it is installed, otherwise with `gzip` (`.sql.gz`). A container labelled `datacore.backup.ignore=true` is skipped with all its volumes, one labelled `datacore.backup.stop=true` is stopped while its volumes are tarred. Refuses to run when `BACKUPDIR` is missing or lies on the root filesystem, like `backup-docker-all` (`ALLOW_UNMOUNTED=1` to override). Files are written with `umask 077` (600, new directories 700) as `.<name>.part` and renamed when complete. Cleanup deletes files older than `DAYS` but always keeps the newest file of every artefact. A missing password or a failed dump does not stop the other containers, but the run exits with 1; exit 75 means the project has no running containers. For TimescaleDB the dump starts with one comment line per database (`-- backup-docker timescaledb: <db> <version>`), and pg_dump's expected warnings about circular foreign keys in the TimescaleDB catalog are hidden (only counted), so a log monitor does not alert on every run. |
| `backup-docker-all.sh` | `{BACKUPDIR:/mnt/backup/} {DAYS:2} {PBS_REPO}` | Backs up all running Compose projects, optionally uploading `BACKUPDIR/<hostname>` to a Proxmox Backup Server (archive `<hostname>.pxar`; since 2026-10-19 its root is `BACKUPDIR/<hostname>`, one level deeper than in older snapshots, which held the whole `BACKUPDIR`). Refuses to run when `BACKUPDIR` is missing or lies on the root filesystem (a subdirectory of a mount is fine), unless `ALLOW_UNMOUNTED=1` is set. Shares the lock `/run/lock/datacore-docker.lock` with `update-docker-all` and waits up to 1 h for it. |
| `restore-docker.sh` | `{BACKUPDIR:/mnt/backup/}` | Interactive restore of a Compose project. Run from the project directory. Restores every type `backup-docker.sh` writes. A PostgreSQL dump is only restored into an empty database (fresh volume), a volume only while no running container uses it. A volume archive is tested and extracted next to the target first; the current volume dir is kept as `<dir>.bak-<timestamp>`, not deleted. Compose files and project name come from the container labels when the project exists, so non-default compose file names work. GitLab: restore the `.gitlabconfig.tar.gz` (secrets) before the `.gitlabbackup.tar`; the script waits until GitLab is healthy. Wait limits: `RESTORE_TIMEOUT` (default 180 s), `RESTORE_GITLAB_TIMEOUT` (default 900 s). TimescaleDB: the image must have the same extension version as the dump (checked against the header, otherwise the restore stops and says which tag to pin); the restore runs between `timescaledb_pre_restore()` and `timescaledb_post_restore()`. Dumps made before 2026-10-13 have no header, the version is then not checked. |
| `backup-remoteserver.sh` | `<remote-ip> <remote-path>` | Backs up a remote path to a Proxmox Backup Server through an SSH reverse tunnel. Credentials in `/etc/backup-remoteserver.conf`. On the target it calls `pbs-remote-backup` through `sudo`, with the password on stdin. Where the wrapper is not installed yet, it falls back to the old `sudo env PBS_PASSWORD=… proxmox-backup-client` call and prints a deprecation warning. Setup and migration are described in the script header. |
| `pbs-remote-backup.sh` | `<archive>.pxar <path> <repository> <fingerprint>` | Wrapper for the **target** of `backup-remoteserver`, not linked by `link.sh`. Install it as `/usr/local/sbin/pbs-remote-backup` (`install -o root -g root -m 0755`) and allow only this one command: `sa_backup ALL=(root) NOPASSWD: /usr/local/sbin/pbs-remote-backup` in `/etc/sudoers.d/`. Validates every argument (archive name, existing absolute path, repository on `localhost` only, SHA-256 fingerprint); `PBS_REMOTE_ALLOWED_PATHS` in `/etc/pbs-remote-backup.conf` can restrict the paths. Reads the password from stdin (`PBS_PASSWORD_FD=0`). **Migration:** the old rule `/usr/bin/env PBS_PASSWORD=* PBS_FINGERPRINT=* /usr/bin/proxmox-backup-client *` lets the backup user run any command as root (sudoers `*` also matches spaces). Install the wrapper and the new rule, then delete the old rule. |

### Updates

| Script | Parameters | Description |
|---|---|---|
| `update-docker.sh` | `{PROJECT} --auto={y,n,b}` | Updates one Compose project. `--auto` controls the restart: yes, no, or backup first; any other value is rejected, and at the prompt only `y` or `b` update (anything else aborts). Compose is called with the project name and the compose files from the container labels, so non-default file names work. Warns when the project directory has uncommitted or unpushed changes, and when it is behind its Git remote and should be pulled before the containers are updated. Git runs as the owner of the project directory (root would hit "dubious ownership"), and Git errors are shown instead of skipping the check silently. Also warns when an env file (`.env`, `.env.*`, `*.env`, templates excluded) is readable by group/others or tracked by Git. Checks for newer images with HEAD requests on the registry manifest, which Docker Hub does not count against its pull rate limit, and pulls only the services whose image changed. Images from private registries that refuse an anonymous token fall back to a `docker pull` with the host's credentials. A project with the label `datacore.update.ignore=true` on any container (e.g. a Komodo stack with Renovate-pinned versions) is skipped. |
| `update-docker-all.sh` | | Updates all running Compose projects with `--auto=y`, then prunes unused images. Waits up to 1 h for a running `backup-docker-all` (shared lock `/run/lock/datacore-docker.lock`). |
| `update-system.sh` | `[-y]` | Full `dist-upgrade` (runs `autoremove` first when `/boot` has less than 300 MB free and stops if that is still not enough, finishes an interrupted `dpkg` run first, keeps locally modified conffiles, waits up to 10 min for the apt lock). A failed upgrade exits 1 without cleanup or reboot. With `-y` reboots automatically when required; pending kernel updates are detected on Debian and Proxmox, a kernel pinned with `proxmox-boot-tool kernel pin` is respected. It reboots only once per target kernel (remembered in `/var/lib/datacore/update-system.reboot-target`): if the host still runs another kernel afterwards, it warns instead of rebooting every week. Also updates this collection. |
| `update-scripts.ps1` | `[-Force]` | Windows counterpart of `update-scripts.sh`, without git: asks GitHub for the commit at the tip of `main`, stops when the copy is already there (`-Force` mirrors anyway), downloads the ZIP of exactly that commit, removes the internet mark (`Unblock-File`, so `RemoteSigned` does not block the scripts) and mirrors it into its own directory with `robocopy /MIR`. Local changes and files no longer in the repository are removed; the commit is kept in `.commit`. A directory with other files and no `.commit` is refused, so a wrong location is never wiped. No signature check (no git for `verify-commit`). See [Windows Server](#windows-server). |
| `update-scripts.sh` | | Updates this collection: `git fetch origin main` (120 s timeout, on failure the repository stays as it is), then `git reset --hard origin/main`, so local changes are always discarded (it says so when there are any), and re-runs `link.sh`. Optionally verifies the commit signature first, see [Signed updates](#signed-updates). |

### Security

| Script | Parameters | Description |
|---|---|---|
| `check-cve.sh` | `[--fix] [--json]` | Checks the host against CVE-2026-98432 (IPv4 TCP use-after-free, remote root via a SYN with IP options): kernel patch status (fixed versions for Debian 12/13, the Proxmox 7.0 kernel and upstream stable; otherwise the CVE in the kernel changelog), IPv4-reachable TCP listeners, MPTCP listeners on the host and, as root, in Docker containers (Go >= 1.24 opens them by default), `net.mptcp.enabled`, `net.ipv4.tcp_migrate_req` and crash traces in the kernel log. `--fix` (not on a patched kernel) sets both sysctls to 0 in `/etc/sysctl.d/99-cve-2026-98432.conf` and loads an nftables table that drops IPv4 TCP with IP options, persisted by `cve-2026-98432-nft.service`; neither is vendor-confirmed, and the sysctl does not reach container network namespaces. On a patched kernel `--fix` prints the commands to remove the mitigation. Mitigation files from earlier versions (Copy Fail, Dirty Frag, Fragnesia, CIFSwitch) are only listed. `--json` produces machine-readable output. |

### Utilities

| Script | Parameters | Description |
|---|---|---|
| `show-lastreboot.sh` | | Prints the time of the last reboot. |
| `link.sh` | | Symlinks all scripts into `/usr/bin/`, skips missing ones and removes links into the collection whose script is gone. Run once after cloning; `update-scripts` re-runs it. |

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

## Signed updates

`update-scripts` (and with it the weekly `update-system -y`) runs whatever is
on `origin/main` as root. Signature verification is opt-in per host: as soon
as `gpg.ssh.allowedSignersFile` is set in the git config of the repository
(or the system/root git config), `update-scripts` runs
`git verify-commit origin/main` and leaves the repository unchanged when the
newest commit is not signed by a listed key. Without the setting it updates
unverified, as before.

Enable on a host:

```bash
# One line per trusted key: <email> <public key> (works for multi-key files)
sed 's/^/you@example.ch /' pubkeys/<username>.pub | sudo tee /etc/datacore-allowed-signers
sudo git -C /usr/bin/datacore/bash config gpg.ssh.allowedSignersFile /etc/datacore-allowed-signers
```

Sign commits with an SSH key (on the machine you commit from):

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
```

Only the commit at the tip of `main` is checked; it covers the history
before it through the commit hashes. Merge on your own machine (signed), not
with the GitHub web UI: a web merge is signed with GitHub's key, which is not
in the allowed signers file, and the hosts stop updating until the next
signed commit. Enable the check on a host only after the tip of `main` is
signed.

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

`backup-docker-all` (and `backup-docker` alone) exits with an error when `/mnt/backup` is not on a mounted
filesystem (it lies on `/`), so a missing CIFS mount no longer fills the local disk
unnoticed (`ALLOW_UNMOUNTED=1` for a local backup dir); `2>&1` sends error messages
to the log as well.
