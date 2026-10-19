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
| `install-log.ps1` | `-O2Host <fqdn> [-Dc] [-Hmail] [-User <email>] [-Pass <secret>] [-Vlan <id>] [-Org <name>]` | Windows counterpart of `install-log.sh` (Windows Server, PowerShell 5.1, run as Administrator). Fluent Bit must already be installed and may be updated freely (installer, winget, UniGetUI). Writes its own config to `C:\ProgramData\fluent-bit\` (`datacore.conf`, credentials in `datacore-secrets.conf`, `conf.d\`, DB, disk buffer, agent log; the whole directory readable by SYSTEM and Administrators only) and points the `fluent-bit` service at it through the Service Control Manager, with restart on failure. The installer's `fluent-bit.conf` is never used, because every update overwrites it. Verifies the credentials and validates the new config (`--dry-run`) before it stops the service: if validation fails, the current config and the running agent stay untouched. Checks the agent log after the start. A hand-made setup in the install directory is moved to `legacy-<timestamp>\` and its DB files are taken over. Event logs are read with the `winevtlog` input (since 2026-10, before `winlog`): its field names differ (`ProviderName`, `Computer`, `EventRecordID`, `TimeCreated`, numeric `Level` instead of `SourceName`, `ComputerName`, `RecordNumber`, `TimeGenerated`, `EventType`), see `logconfs/windows.conf`. Run with `powershell -ExecutionPolicy Bypass -File .\install-log.ps1 -O2Host log.geek.ch -Hmail`. |
| `install-swap.sh` | `[--size <n>] [--swappiness <n>] [--remove-old] [--fix-resume] [--dry-run]` | Sets up `/pagefile.sys` including fstab entry and persistent `vm.swappiness` (default 10). Size defaults to RAM, capped at 8G and floored at 2G. `--remove-old` disables previous swap partitions or files and cleans up fstab. Refuses to run inside LXC containers, where `pct set <ctid> -swap` is the correct tool. |
| `komodo-migrate-env.sh` | `<project-dir> [<secret-prefix>]` | Moves a Compose project's `.env` into a Komodo stack: secrets (names ending in `TOKEN`, `SECRET`, `PASSWORD`, `PASS`, `_KEY`) go to the `[secrets]` of the local Periphery as `<PREFIX>_<NAME>`, and the script prints the stack Environment with `[[<PREFIX>_<NAME>]]` placeholders to paste into Komodo. Periphery fills them in on the host, so secret values never reach Komodo Core. The `.env` is left unchanged; re-running skips secrets already there. |

### Backup and restore

| Script | Parameters | Description |
|---|---|---|
| `backup-docker.sh` | `{PROJECT} {BACKUPDIR:/mnt/backup/} {DAYS:2}` | Backs up one Docker Compose project: compose configuration, volumes and databases (MariaDB, MySQL, PostgreSQL, MongoDB, GitLab). SQL dumps are compressed with `zstd` (all cores, `.sql.zst`) when it is installed, otherwise with `gzip` (`.sql.gz`). A container labelled `datacore.backup.ignore=true` is skipped with all its volumes. For TimescaleDB the dump starts with one comment line per database (`-- backup-docker timescaledb: <db> <version>`), and pg_dump's expected warnings about circular foreign keys in the TimescaleDB catalog are hidden (only counted), so a log monitor does not alert on every run. |
| `backup-docker-all.sh` | `{BACKUPDIR:/mnt/backup/} {DAYS:2} {PBS_REPO}` | Backs up all running Compose projects, optionally uploading to a Proxmox Backup Server. |
| `restore-docker.sh` | `{BACKUPDIR:/mnt/backup/}` | Interactive restore of a Compose project. Run from the project directory. Restores every type `backup-docker.sh` writes. A PostgreSQL dump is only restored into an empty database (fresh volume), a volume only while no running container uses it. TimescaleDB: the image must have the same extension version as the dump (checked against the header, otherwise the restore stops and says which tag to pin); the restore runs between `timescaledb_pre_restore()` and `timescaledb_post_restore()`. Dumps made before 2026-10-13 have no header, the version is then not checked. |
| `backup-remoteserver.sh` | `<remote-ip> <remote-path>` | Backs up a remote path to a Proxmox Backup Server through an SSH reverse tunnel. Credentials in `/etc/backup-remoteserver.conf`. |

### Updates

| Script | Parameters | Description |
|---|---|---|
| `update-docker.sh` | `{PROJECT} --auto={y,n,b}` | Updates one Compose project. `--auto` controls the restart: yes, no, or backup first. Warns when the project directory has uncommitted or unpushed changes, and when it is behind its Git remote and should be pulled before the containers are updated. Also warns when an env file (`.env`, `.env.*`, `*.env`, templates excluded) is readable by group/others or tracked by Git. Checks for newer images with HEAD requests on the registry manifest, which Docker Hub does not count against its pull rate limit, and pulls only the services whose image changed. Images from private registries that refuse an anonymous token fall back to a `docker pull` with the host's credentials. A project with the label `datacore.update.ignore=true` on any container (e.g. a Komodo stack with Renovate-pinned versions) is skipped. |
| `update-docker-all.sh` | | Updates all running Compose projects with `--auto=y`, then prunes unused images. |
| `update-system.sh` | `[-y]` | Full `dist-upgrade` (finishes an interrupted `dpkg` run first, keeps locally modified conffiles, waits up to 10 min for the apt lock). A failed upgrade exits 1 without cleanup or reboot. With `-y` reboots automatically when required; pending kernel updates are detected on Debian and Proxmox, a kernel pinned with `proxmox-boot-tool kernel pin` is respected. It reboots only once per target kernel (remembered in `/var/lib/datacore/update-system.reboot-target`): if the host still runs another kernel afterwards, it warns instead of rebooting every week. Also updates this collection. |
| `update-scripts.sh` | | Updates this collection: `git fetch origin main` (120 s timeout, on failure the repository stays as it is), then `git reset --hard origin/main`, so local changes are always discarded (it says so when there are any), and re-runs `link.sh`. Optionally verifies the commit signature first, see [Signed updates](#signed-updates). |

### Security

| Script | Parameters | Description |
|---|---|---|
| `check-cve.sh` | `[--fix] [--json]` | Checks the host against current kernel and userspace CVEs (Copy Fail, Dirty Frag, Fragnesia, CrackArmor, ptrace mm-NULL, CIFSwitch). `--fix` applies module blacklists and sysctl mitigations, `--json` produces machine-readable output. |

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
# One line per trusted signer: <email> <public key>
echo "you@example.ch $(cat pubkeys/<username>.pub)" | sudo tee /etc/datacore-allowed-signers
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
  03  03   *   *   *    mountpoint -q /mnt/backup && backup-docker-all '/mnt/backup' 0 > /var/log/dataCoreBackupScript.log 2>&1
  03  05   *   *   03   update-system -y > /var/log/dataCoreUpdateScript.log
  43  05   *   *   03   update-docker-all > /var/log/dataCoreUpdateDockerScript.log
```

`backup-docker-all` does not check whether `/mnt/backup` is mounted. Without
`mountpoint -q` a missing CIFS mount makes it write the backup to the local disk
unnoticed; `2>&1` sends error messages to the log as well.
