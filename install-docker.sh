#!/usr/bin/env bash
# =============================================================================
# install-docker.sh — dataCore Docker CE Installation
# =============================================================================
# Usage: install-docker.sh
#
# What this script does:
#   1. Detect primary IP → derive Docker subnet (last octet)
#   2. Install prerequisites + nfs-common
#   3. Add Docker's official apt repository
#   4. Install Docker CE, CLI, containerd, compose plugin
#   5. Write /etc/docker/daemon.json (subnets, IPv6, logging)
#   6. Enable & start Docker, verify installation
#
# Subnet derivation (last octet of primary IP):
#   192.168.20.11  →  last octet: 11  →  172.11.0.0/16  +  fd00:172:11::/64
#   10.7.0.30      →  last octet: 30  →  172.30.0.0/16  +  fd00:172:30::/64
#
# Repository: https://code.geek.ch/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

# --------------- Colors -------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --------------- Config -------------------------------------------------------
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_SOURCE="/etc/apt/sources.list.d/docker.list"
DAEMON_JSON="/etc/docker/daemon.json"
LOG_FILE="/var/log/datacore-install.log"

# =============================================================================
# Helpers
# =============================================================================

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [install-docker] $*" >> "$LOG_FILE"; }

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║           dataCore — Docker CE Installation              ║"
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
# Step 0 — Detect IP & Derive Subnets
# =============================================================================

step_detect_network() {
    print_section "Network Detection"

    # Primary non-loopback IPv4 address
    PRIMARY_IP=$(ip -4 addr show scope global up \
        | awk '/inet / {print $2}' \
        | head -1 | cut -d/ -f1)

    [[ -n "$PRIMARY_IP" ]] || die "Could not detect a primary IPv4 address. Is the network up?"

    # Last octet → Docker bridge subnet base
    LAST_OCTET=$(echo "$PRIMARY_IP" | awk -F. '{print $NF}')

    DOCKER_SUBNET_V4="172.${LAST_OCTET}.0.0/16"
    DOCKER_SUBNET_V6="fd00:172:${LAST_OCTET}::/64"
    DOCKER_POOL_SIZE=24

    ok "Primary IP:       ${BOLD}${PRIMARY_IP}${NC}"
    ok "Docker IPv4 pool: ${BOLD}${DOCKER_SUBNET_V4}${NC}  (size /${DOCKER_POOL_SIZE})"
    ok "Docker IPv6 pool: ${BOLD}${DOCKER_SUBNET_V6}${NC}"
}

# =============================================================================
# Step 1 — Prerequisites
# =============================================================================

step_install_prerequisites() {
    print_section "Installing Prerequisites"

    local packages=(
        ca-certificates
        curl
        gnupg
        lsb-release
        nfs-common             # NFS volume support for Docker
    )

    local to_install=()
    for pkg in "${packages[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            ok "${pkg} already installed"
        else
            to_install+=("$pkg")
            info "${pkg} — will install"
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}"
        ok "Installed: ${to_install[*]}"
    fi
}

# =============================================================================
# Step 2 — Docker Repository
# =============================================================================

step_add_docker_repo() {
    print_section "Docker APT Repository"

    if [[ -f "$DOCKER_SOURCE" ]]; then
        ok "Docker repository already configured — skipping"
        return
    fi

    install -m 0755 -d /etc/apt/keyrings

    info "Fetching Docker GPG key..."
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o "$DOCKER_KEYRING"
    chmod a+r "$DOCKER_KEYRING"
    ok "GPG key saved to ${DOCKER_KEYRING}"

    local codename
    codename=$(lsb_release -cs)
    local arch
    arch=$(dpkg --print-architecture)

    echo "deb [arch=${arch} signed-by=${DOCKER_KEYRING}] \
https://download.docker.com/linux/debian ${codename} stable" \
        > "$DOCKER_SOURCE"

    ok "Repository added: debian/${codename} (${arch})"
    apt-get update -qq
}

# =============================================================================
# Step 3 — Install Docker CE
# =============================================================================

step_install_docker() {
    print_section "Installing Docker CE"

    local packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )

    # Check if already installed
    if command -v docker &>/dev/null; then
        local current_version
        current_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
        ok "Docker already installed: ${current_version} — checking for updates"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
        ok "Docker packages up to date"
    else
        info "Installing Docker CE packages..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
        ok "Docker CE installed: $(docker --version)"
    fi

    # Standalone docker-compose symlink (backwards compat)
    if [[ ! -f /usr/local/bin/docker-compose ]]; then
        ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose \
            2>/dev/null || true
        ok "Symlink created: docker-compose → docker compose plugin"
    else
        ok "docker-compose symlink already exists"
    fi
}

# =============================================================================
# Step 4 — daemon.json
# =============================================================================

step_configure_daemon() {
    print_section "Docker Daemon Configuration"

    mkdir -p /etc/docker

    # Build the desired config
    local desired
    desired=$(cat <<EOF
{
  "default-address-pools": [
    {
      "base": "${DOCKER_SUBNET_V4}",
      "size": ${DOCKER_POOL_SIZE}
    }
  ],
  "ipv6": true,
  "fixed-cidr-v6": "${DOCKER_SUBNET_V6}",
  "ip6tables": true,
  "live-restore": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "2"
  }
}
EOF
)

    # Idempotent: only write if content differs
    if [[ -f "$DAEMON_JSON" ]]; then
        local current
        current=$(cat "$DAEMON_JSON")
        if [[ "$current" == "$desired" ]]; then
            ok "daemon.json already up to date — no changes"
            return
        fi
        # Backup existing before overwriting
        cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
        warn "Existing daemon.json differs — backed up and updating"
    fi

    echo "$desired" > "$DAEMON_JSON"
    ok "daemon.json written to ${DAEMON_JSON}"

    echo ""
    echo -e "${BLUE}  Content:${NC}"
    sed 's/^/    /' "$DAEMON_JSON"
    echo ""
}

# =============================================================================
# Step 5 — Enable & Start Docker
# =============================================================================

step_enable_docker() {
    print_section "Enabling Docker Service"

    systemctl enable --quiet docker
    systemctl restart docker

    if systemctl is-active --quiet docker; then
        ok "Docker service is running"
    else
        die "Docker failed to start — check: journalctl -u docker"
    fi
}

# =============================================================================
# Step 6 — Verify
# =============================================================================

step_verify() {
    print_section "Verification"

    ok "Docker:         $(docker --version)"
    ok "Docker Compose: $(docker compose version)"
    ok "containerd:     $(containerd --version 2>/dev/null | head -1)"

    echo ""
    info "Docker info summary:"
    docker info 2>/dev/null | grep -E \
        'Server Version|Storage Driver|Logging Driver|Cgroup|IPv6|Default Address' \
        | sed 's/^/    /'
}

# =============================================================================
# Summary
# =============================================================================

step_summary() {
    print_section "Summary"
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Docker CE installation complete!${NC}"
    echo ""

    printf "  ${BOLD}%-28s${NC} %s\n" "Primary IP:"       "${PRIMARY_IP}"
    printf "  ${BOLD}%-28s${NC} %s\n" "IPv4 pool:"        "${DOCKER_SUBNET_V4}  (/${DOCKER_POOL_SIZE} per network)"
    printf "  ${BOLD}%-28s${NC} %s\n" "IPv6 pool:"        "${DOCKER_SUBNET_V6}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Log driver:"       "json-file  (max 100m × 2 files)"
    printf "  ${BOLD}%-28s${NC} %s\n" "daemon.json:"      "${DAEMON_JSON}"
    printf "  ${BOLD}%-28s${NC} %s\n" "nfs-common:"       "installed (NFS volume support)"
    printf "  ${BOLD}%-28s${NC} %s\n" "docker-compose:"   "/usr/local/bin/docker-compose → plugin"
    printf "  ${BOLD}%-28s${NC} %s\n" "Log:"              "${LOG_FILE}"
    echo ""
    info "Create the traefik_proxy network when setting up Traefik:"
    echo -e "     ${CYAN}docker network create --driver=bridge --ipv6 \\"
    echo -e "       --subnet=172.20.0.0/16 \\"
    echo -e "       --subnet=fd00:192:168:10:25::/80 \\"
    echo -e "       traefik_proxy${NC}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== install-docker.sh === $(date)" >> "$LOG_FILE"

    print_header
    step_detect_network
    step_install_prerequisites
    step_add_docker_repo
    step_install_docker
    step_configure_daemon
    step_enable_docker
    step_verify
    step_summary
}

main "$@"
