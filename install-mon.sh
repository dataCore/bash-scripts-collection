#!/usr/bin/env bash
# =============================================================================
# install-mon.sh — dataCore Zabbix Agent2 Installation & Configuration
# =============================================================================
# Usage: install-mon.sh <monitoring-server>
#
#   monitoring-server   Hostname/IP of Zabbix Server or Proxy
#                       e.g. dataCoreMonitor, itpmonitor
#
# What this script does:
#   1. Install Zabbix Agent2 from official Zabbix repository
#   2. Generate a random 256-bit PSK key
#   3. Write agent drop-in config
#   4. Add zabbix user to docker group (if Docker is installed)
#   5. Enable & start zabbix-agent2
#   6. Print PSK key + Zabbix host config for copy-paste into monitoring
#
# Hostname and TLSPSKIdentity are derived from: $(hostname -s)
#
# Repository: https://code.geek.ch/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

# --------------- Colors -------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --------------- Config -------------------------------------------------------
ZABBIX_AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"
ZABBIX_DROP_DIR="/etc/zabbix/zabbix_agent2.d"
ZABBIX_PSK_FILE="/etc/zabbix/key.psk"
LOG_FILE="/var/log/datacore-install.log"
# ZABBIX_CONF_FILE is set after MON_SERVER is known (in check_args)

# =============================================================================
# Helpers
# =============================================================================

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [install-mon] $*" >> "$LOG_FILE"; }

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║         dataCore — Zabbix Agent2 Installation            ║"
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
# Pre-flight
# =============================================================================

check_args() {
    print_section "Pre-flight Checks"

    if [[ $# -lt 1 ]]; then
        echo -e "${RED}${BOLD}Error:${NC} Missing argument."
        echo ""
        echo -e "  Usage:   ${BOLD}$0 <monitoring-server>${NC}"
        echo -e "  Example: ${BOLD}$0 dataCoreMonitor${NC}"
        echo -e "  Example: ${BOLD}$0 itpmonitor${NC}"
        echo ""
        exit 1
    fi

    MON_SERVER="$1"
    AGENT_HOSTNAME=$(hostname -s)
    AGENT_FQDN=$(hostname -f 2>/dev/null || hostname)
    ZABBIX_CONF_FILE="${ZABBIX_DROP_DIR}/${MON_SERVER,,}.conf"

    ok "Monitoring server: ${BOLD}${MON_SERVER}${NC}"
    ok "Agent hostname:    ${BOLD}${AGENT_HOSTNAME}${NC}"
}

# =============================================================================
# Step 1 — Install Zabbix Repository & Agent2
# =============================================================================

step_install_zabbix() {
    print_section "Installing Zabbix Agent2"

    if command -v zabbix_agent2 &>/dev/null; then
        ok "zabbix-agent2 already installed: $(zabbix_agent2 --version 2>/dev/null | head -1)"
        info "Ensuring package is up to date..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zabbix-agent2
        return
    fi

    # Detect Debian version
    local debian_version
    debian_version=$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"')

    info "Detected Debian ${debian_version}"
    info "Adding Zabbix ${ZABBIX_VERSION} repository..."

    # Download and install Zabbix repo package
    local zabbix_pkg="zabbix-release_7.2-1+debian${debian_version}_all.deb"
    local zabbix_url="https://repo.zabbix.com/zabbix/7.2/release/debian/pool/main/z/zabbix-release/${zabbix_pkg}"

    curl -fsSL "$zabbix_url" -o "/tmp/${zabbix_pkg}"
    dpkg -i "/tmp/${zabbix_pkg}" &>/dev/null
    rm -f "/tmp/${zabbix_pkg}"
    ok "Zabbix repository added"

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zabbix-agent2
    ok "Installed: $(zabbix_agent2 --version 2>/dev/null | head -1)"
}

# =============================================================================
# Step 2 — Generate PSK Key
# =============================================================================

step_generate_psk() {
    print_section "PSK Key"

    if [[ -f "$ZABBIX_PSK_FILE" ]]; then
        PSK_KEY=$(cat "$ZABBIX_PSK_FILE")
        ok "Existing PSK key found — reusing"
        info "Key: ${BOLD}${PSK_KEY}${NC}"
        return
    fi

    # Generate 256-bit (32 byte) random PSK
    PSK_KEY=$(openssl rand -hex 32)

    install -m 640 -o zabbix -g zabbix /dev/null "$ZABBIX_PSK_FILE"
    echo "$PSK_KEY" > "$ZABBIX_PSK_FILE"
    ok "PSK key generated and saved to ${ZABBIX_PSK_FILE}"
    info "Key: ${BOLD}${PSK_KEY}${NC}"
}

# =============================================================================
# Step 3 — Write Agent Config
# =============================================================================

step_write_config() {
    print_section "Agent Configuration"

    mkdir -p "$ZABBIX_DROP_DIR"

    # Ensure the main config includes the drop-in directory
    if ! grep -q "^Include=${ZABBIX_DROP_DIR}" "$ZABBIX_AGENT_CONF" 2>/dev/null; then
        echo "" >> "$ZABBIX_AGENT_CONF"
        echo "Include=${ZABBIX_DROP_DIR}/*.conf" >> "$ZABBIX_AGENT_CONF"
        ok "Include directive added to ${ZABBIX_AGENT_CONF}"
    fi

    # Comment out conflicting directives in main config
    local main_conf_changed=false
    for directive in Server= ServerActive= Hostname= TLSConnect= TLSAccept= TLSPSKFile= TLSPSKIdentity=; do
        if grep -qE "^${directive}" "$ZABBIX_AGENT_CONF" 2>/dev/null; then
            sed -i "s|^${directive}|# ${directive}|g" "$ZABBIX_AGENT_CONF"
            main_conf_changed=true
        fi
    done
    $main_conf_changed && warn "Commented out duplicate directives in ${ZABBIX_AGENT_CONF}"

    # Write drop-in config
    cat > "$ZABBIX_CONF_FILE" <<EOF
##### dataCore Agent Settings
# Generated by install-mon.sh on $(date '+%Y-%m-%d %H:%M:%S')

Server=${MON_SERVER}
ServerActive=${MON_SERVER}
Hostname=${AGENT_HOSTNAME}
TLSPSKIdentity=${AGENT_HOSTNAME}
TLSConnect=psk
TLSAccept=psk
TLSPSKFile=${ZABBIX_PSK_FILE}
EOF

    chown zabbix:zabbix "$ZABBIX_CONF_FILE"
    chmod 640 "$ZABBIX_CONF_FILE"

    ok "Config written to ${ZABBIX_CONF_FILE}"
    echo ""
    echo -e "${BLUE}  Content:${NC}"
    sed 's/^/    /' "$ZABBIX_CONF_FILE"
}

# =============================================================================
# Step 4 — Docker Group (if Docker is installed)
# =============================================================================

step_docker_group() {
    print_section "Docker Integration"

    if ! command -v docker &>/dev/null; then
        info "Docker not installed — skipping docker group setup"
        return
    fi

    if id -nG zabbix | grep -qw docker; then
        ok "zabbix user is already in the docker group"
    else
        usermod -aG docker zabbix
        ok "zabbix user added to docker group"
        info "Docker monitoring enabled (container discovery, stats)"
    fi
}

# =============================================================================
# Step 5 — Enable & Start
# =============================================================================

step_enable_agent() {
    print_section "Enabling Zabbix Agent2"

    systemctl enable --quiet zabbix-agent2
    systemctl restart zabbix-agent2

    sleep 1
    if systemctl is-active --quiet zabbix-agent2; then
        ok "zabbix-agent2 is running"
    else
        err "zabbix-agent2 failed to start"
        warn "Check logs: journalctl -u zabbix-agent2 -n 30"
        die "Agent startup failed"
    fi
}

# =============================================================================
# Summary & PSK Print
# =============================================================================

step_summary() {
    print_section "Summary"
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Zabbix Agent2 setup complete!${NC}"
    echo ""

    printf "  ${BOLD}%-28s${NC} %s\n" "Monitoring server:" "${MON_SERVER}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Agent hostname:"    "${AGENT_HOSTNAME}"
    printf "  ${BOLD}%-28s${NC} %s\n" "PSK identity:"      "${AGENT_HOSTNAME}"
    printf "  ${BOLD}%-28s${NC} %s\n" "PSK file:"          "${ZABBIX_PSK_FILE}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Config drop-in:"    "${ZABBIX_CONF_FILE}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Log:"               "${LOG_FILE}"

    # PSK copy-paste block
    echo ""
    echo -e "  ${YELLOW}$(printf '═%.0s' {1..56})${NC}"
    echo -e "  ${YELLOW}${BOLD}  Add this host in Zabbix (${MON_SERVER}):${NC}"
    echo -e "  ${YELLOW}$(printf '═%.0s' {1..56})${NC}"
    echo ""
    printf "  ${BOLD}%-20s${NC} %s\n" "Host name:"         "${AGENT_HOSTNAME}"
    printf "  ${BOLD}%-20s${NC} %s\n" "Visible name:"      "${AGENT_FQDN}"
    printf "  ${BOLD}%-20s${NC} %s\n" "Agent interface:"   "$(ip -4 addr show scope global up | awk '/inet / {print $2}' | head -1 | cut -d/ -f1)  port 10050"
    printf "  ${BOLD}%-20s${NC} %s\n" "Encryption:"        "PSK"
    printf "  ${BOLD}%-20s${NC} %s\n" "PSK identity:"      "${AGENT_HOSTNAME}"
    echo ""
    echo -e "  ${BOLD}PSK key (copy into Zabbix → Encryption tab):${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}  ${PSK_KEY}${NC}"
    echo ""
    echo -e "  ${YELLOW}$(printf '═%.0s' {1..56})${NC}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== install-mon.sh === $(date)" >> "$LOG_FILE"

    print_header
    check_args "$@"
    step_install_zabbix
    step_generate_psk
    step_write_config
    step_docker_group
    step_enable_agent
    step_summary
}

main "$@"
