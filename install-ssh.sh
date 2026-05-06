#!/usr/bin/env bash
# =============================================================================
# install-ssh.sh — dataCore SSH Setup & Hardening
# =============================================================================
# Usage: install-ssh.sh <username> [--bantime <duration>]
#   username         Local user to add to ssh-users group (e.g. datacore, itp)
#   --bantime <val>  fail2ban ban duration, default: 10m (e.g. 30m, 1h, 24h)
#
# Public keys are loaded from:
#   <script-dir>/pubkeys/<username>.pub
#
# What this script does:
#   1. Install openssh-server + figlet (if missing)
#   2. Create group 'ssh-users' and add <username>
#   3. Generate SSH banner via figlet
#   4. Configure fail2ban for SSH (5 attempts → bantime)
#   5. Harden sshd_config (AllowGroups, key-only, no root, etc.)
#   6. Install pubkeys/<username>.pub as authorized_keys for <username>
#
# Repository: https://code.geek.ch/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

# --------------- Colors -------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --------------- Config -------------------------------------------------------
SSH_GROUP="ssh-users"
SSH_PORT=22
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_HARDENED_DROP="/etc/ssh/sshd_config.d/99-datacore-hardened.conf"
SSHD_BANNER_FILE="/etc/ssh/sshd_banner"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/datacore-ssh.conf"
FAIL2BAN_BANTIME="10m"   # overridden by --bantime parameter
LOG_FILE="/var/log/datacore-install.log"

# Directory containing <username>.pub files — same location as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBKEYS_DIR="${SCRIPT_DIR}/pubkeys"

# =============================================================================
# Helpers
# =============================================================================

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [install-ssh] $*" >> "$LOG_FILE"; }

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║           dataCore — SSH Setup & Hardening               ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo ""
    echo -e "${BLUE}${BOLD}▶ $1${NC}"
    echo -e "${BLUE}$(printf '─%.0s' {1..60})${NC}"
}

ok()   { echo -e "  ${GREEN}✓${NC}  $1"; log "[OK]   $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; log "[INFO] $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; log "[WARN] $1"; }
err()  { echo -e "  ${RED}✗${NC}  $1"; log "[ERR]  $1"; }
die()  { err "$1"; echo ""; exit 1; }

# =============================================================================
# Pre-flight Checks
# =============================================================================

check_username() {
    print_section "Pre-flight Checks"

    # Parse arguments
    if [[ $# -lt 1 ]]; then
        echo -e "${RED}${BOLD}Error:${NC} No username provided."
        echo ""
        echo -e "  Usage: ${BOLD}$0 <username> [--bantime <duration>]${NC}"
        echo -e "  Example: ${BOLD}$0 datacore${NC}"
        echo -e "  Example: ${BOLD}$0 itp --bantime 30m${NC}"
        echo ""
        exit 1
    fi

    TARGET_USER="$1"
    shift

    # Parse optional flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bantime) FAIL2BAN_BANTIME="$2"; shift 2 ;;
            *) warn "Unknown argument: $1"; shift ;;
        esac
    done

    # Reject root as target user
    if [[ "$TARGET_USER" == "root" ]]; then
        die "Do not pass 'root' as username. Root is handled separately (key-only, no group needed)."
    fi

    # Check user exists
    if ! id "$TARGET_USER" &>/dev/null; then
        die "User '${TARGET_USER}' does not exist. Create the user first: adduser ${TARGET_USER}"
    fi

    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    PUBKEY_FILE="${PUBKEYS_DIR}/${TARGET_USER}.pub"

    # Check pubkey file exists
    if [[ ! -f "$PUBKEY_FILE" ]]; then
        die "No public key file found for '${TARGET_USER}'.\n  Expected: ${PUBKEY_FILE}\n  Add the key and re-run."
    fi

    local key_count
    key_count=$(grep -c '^ssh-' "$PUBKEY_FILE" 2>/dev/null || echo 0)

    ok "Target user:   ${BOLD}${TARGET_USER}${NC}  (home: ${TARGET_HOME})"
    ok "Public key:    ${BOLD}${PUBKEY_FILE}${NC}  (${key_count} key(s))"
    ok "Fail2ban ban:  ${BOLD}${FAIL2BAN_BANTIME}${NC}"
}

# =============================================================================
# Step 1 — Install Packages
# =============================================================================

step_install_packages() {
    print_section "Installing Packages"

    local packages=()

    if ! dpkg -l openssh-server &>/dev/null 2>&1; then
        packages+=(openssh-server)
        info "openssh-server not found — will install"
    else
        ok "openssh-server already installed"
    fi

    if ! command -v figlet &>/dev/null; then
        packages+=(figlet)
        info "figlet not found — will install"
    else
        ok "figlet already installed"
    fi

    if ! dpkg -l fail2ban &>/dev/null 2>&1; then
        packages+=(fail2ban)
        info "fail2ban not found — will install"
    else
        ok "fail2ban already installed"
    fi

    if [[ ${#packages[@]} -gt 0 ]]; then
        info "Running apt-get install: ${packages[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
        ok "Packages installed: ${packages[*]}"
    fi

    # Enable & start sshd
    systemctl enable --quiet ssh 2>/dev/null || systemctl enable --quiet sshd 2>/dev/null || true
    systemctl start  ssh 2>/dev/null || systemctl start  sshd 2>/dev/null || true
    ok "SSH service enabled and running"
}

# =============================================================================
# Step 2 — Create Group & Add User
# =============================================================================

step_setup_group() {
    print_section "SSH User Group"

    if getent group "$SSH_GROUP" &>/dev/null; then
        ok "Group '${SSH_GROUP}' already exists"
    else
        groupadd "$SSH_GROUP"
        ok "Group '${SSH_GROUP}' created"
    fi

    if id -nG "$TARGET_USER" | grep -qw "$SSH_GROUP"; then
        ok "User '${TARGET_USER}' is already in group '${SSH_GROUP}'"
    else
        usermod -aG "$SSH_GROUP" "$TARGET_USER"
        ok "User '${TARGET_USER}' added to group '${SSH_GROUP}'"
    fi

    info "Current members of '${SSH_GROUP}':"
    echo -e "     ${CYAN}$(getent group "$SSH_GROUP" | cut -d: -f4)${NC}"
}

# =============================================================================
# Step 3 — SSH Banner via figlet
# =============================================================================

step_create_banner() {
    print_section "SSH Login Banner"

    local hostname
    hostname=$(hostname -s)

    info "Generating banner for: ${BOLD}${hostname}${NC}"

    {
        echo ""
        figlet -w 500 -t "$hostname" 2>/dev/null || echo "  $hostname"
        echo ""
        echo "  ${TARGET_USER} Infrastructure — Authorized Access Only"
        echo "  All connections are logged and monitored."
        echo "  Unauthorized access is strictly prohibited."
        echo ""
        printf "  OS: "; cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "Debian"
        printf "  Host: %s\n" "$(hostname -f 2>/dev/null || hostname)"
        echo ""
    } > "$SSHD_BANNER_FILE"

    ok "Banner written to ${SSHD_BANNER_FILE}"
    echo ""
    echo -e "${BLUE}  Preview:${NC}"
    sed 's/^/  /' "$SSHD_BANNER_FILE" | head -20
}

# =============================================================================
# Step 4 — Fail2ban
# =============================================================================

step_configure_fail2ban() {
    print_section "Fail2ban — SSH Protection"

    mkdir -p "$(dirname "$FAIL2BAN_JAIL")"

    cat > "$FAIL2BAN_JAIL" <<EOF
# dataCore — fail2ban SSH jail
# Generated by install-ssh.sh on $(date '+%Y-%m-%d %H:%M:%S')

[DEFAULT]
bantime  = ${FAIL2BAN_BANTIME}
findtime = 5m
maxretry = 5

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 5
bantime  = ${FAIL2BAN_BANTIME}
EOF

    systemctl enable --quiet fail2ban
    systemctl restart fail2ban

    ok "Fail2ban jail configured: 5 attempts → ${FAIL2BAN_BANTIME} ban"
    info "Jail file: ${FAIL2BAN_JAIL}"

    # Show status
    sleep 1
    if systemctl is-active --quiet fail2ban; then
        ok "Fail2ban is running"
    else
        warn "Fail2ban failed to start — check: journalctl -u fail2ban"
    fi
}

# =============================================================================
# Step 5 — Harden sshd_config
# =============================================================================

step_harden_sshd() {
    print_section "SSH Hardening (sshd_config.d)"

    # Backup main config
    if [[ ! -f "${SSHD_CONFIG}.bak" ]]; then
        cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
        ok "Backup created: ${SSHD_CONFIG}.bak"
    fi

    # Ensure include directive is present in main sshd_config
    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" "$SSHD_CONFIG"; then
        echo "" >> "$SSHD_CONFIG"
        echo "Include /etc/ssh/sshd_config.d/*.conf" >> "$SSHD_CONFIG"
        ok "Added Include directive to ${SSHD_CONFIG}"
    fi

    mkdir -p /etc/ssh/sshd_config.d

    cat > "$SSHD_HARDENED_DROP" <<EOF
# =============================================================================
# dataCore Hardened SSH Configuration
# Generated by install-ssh.sh on $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# --- Access Control ----------------------------------------------------------
# Only users in 'ssh-users' group may log in. Root SSH is disabled entirely.
AllowGroups ${SSH_GROUP}

# Root SSH login disabled — use sudo from a group member
PermitRootLogin no

# --- Authentication ----------------------------------------------------------
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Disable all password-based auth methods
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

# --- Banner ------------------------------------------------------------------
Banner ${SSHD_BANNER_FILE}

# --- Hardening ---------------------------------------------------------------
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PermitEmptyPasswords no
MaxAuthTries 4
MaxSessions 5
LoginGraceTime 30

# Disconnect idle sessions after 30 min (2 × 900s)
ClientAliveInterval 900
ClientAliveCountMax 2

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Only allow strong algorithms
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF

    ok "Hardened config written to ${SSHD_HARDENED_DROP}"

    # Validate config before reloading
    if sshd -t 2>/dev/null; then
        ok "sshd config validation passed"
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
        ok "SSH service reloaded"
    else
        err "sshd config validation FAILED — restoring backup"
        cp "${SSHD_CONFIG}.bak" "$SSHD_CONFIG"
        rm -f "$SSHD_HARDENED_DROP"
        die "Rolled back. Check sshd config manually: sshd -T"
    fi
}

# =============================================================================
# Step 6 — Install authorized_keys
# =============================================================================

step_install_authorized_keys() {
    print_section "SSH Authorized Keys"

    local ssh_dir="${TARGET_HOME}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "${TARGET_USER}:${TARGET_USER}" "$ssh_dir"

    # Append keys from pubkeys/<username>.pub, deduplicate
    cat "$PUBKEY_FILE" >> "$auth_keys"
    sort -u "$auth_keys" -o "$auth_keys"
    chmod 600 "$auth_keys"
    chown "${TARGET_USER}:${TARGET_USER}" "$auth_keys"

    local key_count
    key_count=$(grep -c '^ssh-' "$auth_keys" 2>/dev/null || echo 0)
    ok "Keys installed for '${TARGET_USER}': ${key_count} key(s) → ${auth_keys}"
    info "Source: ${PUBKEY_FILE}"

    # Note: no authorized_keys for root.
    # Root SSH login is disabled via PermitRootLogin no — keys would serve no purpose.
    # To get root access: ssh <username>@<host> → sudo -i
}

# =============================================================================
# Summary
# =============================================================================

step_summary() {
    print_section "Summary"
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ SSH setup complete!${NC}"
    echo ""

    printf "  ${BOLD}%-28s${NC} %s\n" "Target user:"         "${TARGET_USER}"
    printf "  ${BOLD}%-28s${NC} %s\n" "SSH group:"           "${SSH_GROUP}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Fail2ban ban:"        "5 attempts → ${FAIL2BAN_BANTIME}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Banner:"              "${SSHD_BANNER_FILE}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Hardened config:"     "${SSHD_HARDENED_DROP}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Fail2ban jail:"       "${FAIL2BAN_JAIL}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Pubkey source:"       "${PUBKEY_FILE}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Auth keys:"           "${TARGET_HOME}/.ssh/authorized_keys"
    printf "  ${BOLD}%-28s${NC} %s\n" "Log:"                 "${LOG_FILE}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}Important:${NC}"
    echo -e "  ${YELLOW}•${NC} Password auth is now ${RED}disabled${NC} — ensure your key works before closing this session!"
    echo -e "  ${YELLOW}•${NC} Root SSH login is ${RED}disabled${NC} — use: ssh ${TARGET_USER}@<host> then sudo -i"
    echo -e "  ${YELLOW}•${NC} Only members of '${SSH_GROUP}' can log in via SSH."
    echo -e "  ${YELLOW}•${NC} Test in a ${BOLD}second terminal${NC} before closing this one."
    echo ""
    info "Verify SSH config: sshd -T | grep -E 'allowgroups|passwordauth|permitrootlogin'"
    info "Check fail2ban:    fail2ban-client status sshd"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Initialise log
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== install-ssh.sh === $(date)" >> "$LOG_FILE"

    print_header
    check_username "$@"

    step_install_packages
    step_setup_group
    step_create_banner
    step_configure_fail2ban
    step_harden_sshd
    step_install_authorized_keys
    step_summary
}

main "$@"
