#!/usr/bin/env bash

# =============================================================================
# install-log.sh — dataCore Fluent Bit Log Agent Installation
# =============================================================================
# Usage: install-log.sh --host <openobserve-host> [options]
#
# What this script does:
# 1. Detect host IP and VLAN
# 2. Prompt for / accept OpenObserve credentials
# 3. Install Fluent Bit via APT
# 4. Deploy fluent-bit.conf with host-specific variables
# 5. Deploy relevant conf.d configs based on host type flags
# 6. [--docker] Configure Docker fluentd logging driver
# 7. Enable & start Fluent Bit
# 8. Verify logs are reaching OpenObserve
#
# Required:
#   --host <fqdn>     OpenObserve endpoint (e.g. log.geek.ch, log.it-processing.ch)
#
# Optional source flags:
#   --docker          Include Docker log collection (requires Docker)
#   --proxmox         Include Proxmox task log collection
#   --unifi           Include UniFi syslog receiver (UDP 5140)
#
# Optional overrides (otherwise prompted / auto-detected):
#   --user <email>    OpenObserve ingest user
#   --pass <secret>   OpenObserve ingest password (avoid on shared shells)
#   --vlan <id>       Override auto-detected VLAN
#   --org <name>      OpenObserve organization (default: default)
#
# Examples:
#   install-log.sh --host log.geek.ch --docker
#   install-log.sh --host log.it-processing.ch --docker --proxmox
#   install-log.sh --host log.geek.ch --unifi --user o2-agent@geek.ch
#
# Repository: https://code.geek.ch/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

# --------------- Colors -------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --------------- Paths --------------------------------------------------------
FLUENT_BIT_CONF="/etc/fluent-bit/fluent-bit.conf"
FLUENT_BIT_CONFD="/etc/fluent-bit/conf.d"
DAEMON_JSON="/etc/docker/daemon.json"
LOG_FILE="/var/log/datacore-install.log"
# Resolve real script location even when called via symlink (e.g. from link.sh)
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

# --------------- Flags & Defaults ---------------------------------------------
OPT_DOCKER=false
OPT_PROXMOX=false
OPT_UNIFI=false

O2_HOST=""
O2_USER=""
O2_PASSWD=""
O2_ORG="default"
VLAN_OVERRIDE=""

# =============================================================================
# Helpers
# =============================================================================
log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [install-log] $*" >> "$LOG_FILE"; }
print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo " ╔══════════════════════════════════════════════════════════╗"
    echo " ║      dataCore — Fluent Bit Log Agent Installation        ║"
    echo " ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}
print_section() {
    echo ""
    echo -e "${BLUE}${BOLD}▶ $1${NC}"
    echo -e "${BLUE}$(printf '─%.0s' {1..60})${NC}"
}
ok()    { echo -e "  ${GREEN}✓${NC} $1"; log "[OK] $1"; }
info()  { echo -e "  ${CYAN}ℹ${NC} $1"; log "[INFO] $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; log "[WARN] $1"; }
err()   { echo -e "  ${RED}✗${NC} $1"; log "[ERR] $1"; }
die()   { err "$1"; echo ""; exit 1; }

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40
    exit "${1:-0}"
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)      O2_HOST="${2:-}"; shift 2 ;;
            --user)      O2_USER="${2:-}"; shift 2 ;;
            --pass)      O2_PASSWD="${2:-}"; shift 2 ;;
            --org)       O2_ORG="${2:-}"; shift 2 ;;
            --vlan)      VLAN_OVERRIDE="${2:-}"; shift 2 ;;
            --docker)    OPT_DOCKER=true; shift ;;
            --proxmox)   OPT_PROXMOX=true; shift ;;
            --unifi)     OPT_UNIFI=true; shift ;;
            -h|--help)   usage 0 ;;
            *) die "Unknown argument: $1 (use --help)" ;;
        esac
    done

    [[ -n "$O2_HOST" ]] || die "Missing required --host <fqdn>. Use --help for usage."
}

# =============================================================================
# Step 0 — Detect Network
# =============================================================================
step_detect_network() {
    print_section "Network Detection"

    HOST_IP=$(ip -4 addr show scope global up \
        | awk '/inet / {print $2}' \
        | head -1 | cut -d/ -f1)
    [[ -n "$HOST_IP" ]] || die "Could not detect primary IPv4 address."

    if [[ -n "$VLAN_OVERRIDE" ]]; then
        VLAN="$VLAN_OVERRIDE"
        ok "Primary IP:    ${BOLD}${HOST_IP}${NC}"
        ok "VLAN (manual): ${BOLD}${VLAN}${NC}"
    else
        VLAN=$(echo "$HOST_IP" | awk -F. '{print $3}')
        ok "Primary IP:   ${BOLD}${HOST_IP}${NC}"
        ok "VLAN (auto):  ${BOLD}${VLAN}${NC}"
        echo ""
        warn "If the VLAN is wrong, re-run with --vlan <id> or edit the config later."
    fi

    ok "Target:       ${BOLD}https://${O2_HOST}${NC} (org: ${O2_ORG})"
}

# =============================================================================
# Step 1 — Credentials
# =============================================================================
step_get_credentials() {
    print_section "OpenObserve Credentials"

    if [[ -z "$O2_USER" ]]; then
        read -rp "  OpenObserve user (e.g. o2-agent@example.ch): " O2_USER
        [[ -n "$O2_USER" ]] || die "User cannot be empty."
    else
        ok "User: ${O2_USER} (from --user)"
    fi

    if [[ -z "$O2_PASSWD" ]]; then
        read -rsp "  OpenObserve password: " O2_PASSWD
        echo ""
        [[ -n "$O2_PASSWD" ]] || die "Password cannot be empty."
    else
        ok "Password: (from --pass)"
    fi

    if $OPT_NO_VERIFY; then
        warn "Skipping credential verification (--no-verify)"
        return
    fi

    echo ""
    info "Verifying credentials against https://${O2_HOST}..."
    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${O2_USER}:${O2_PASSWD}" \
        "https://${O2_HOST}/api/${O2_ORG}/streams" || echo "000")

    if [[ "$http_status" == "200" ]]; then
        ok "Credentials verified successfully"
    else
        die "Credential check failed (HTTP ${http_status}). Check --host / user / password."
    fi
}

# =============================================================================
# Step 2 — Install Fluent Bit
# =============================================================================
step_install_fluent_bit() {
    print_section "Installing Fluent Bit"

    if command -v fluent-bit &>/dev/null; then
        ok "Fluent Bit already installed: $(fluent-bit --version 2>/dev/null | head -1)"
        info "Checking for updates..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fluent-bit
        ok "Fluent Bit up to date"
        return
    fi

    info "Adding Fluent Bit APT repository..."
    curl -fsSL https://packages.fluentbit.io/fluentbit.key \
        | gpg --dearmor > /usr/share/keyrings/fluentbit-keyring.gpg

    local codename
    codename=$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release)
    [[ -n "$codename" ]] || die "Could not detect OS codename."

    echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] \
https://packages.fluentbit.io/debian/${codename} ${codename} main" \
        | tee /etc/apt/sources.list.d/fluent-bit.list > /dev/null
    ok "Repository added: debian/${codename}"

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fluent-bit
    ok "Fluent Bit installed: $(fluent-bit --version 2>/dev/null | head -1)"
}

# =============================================================================
# Step 3 — Deploy Main Config
# =============================================================================
step_deploy_main_config() {
    print_section "Deploying Main Config"

    mkdir -p "$FLUENT_BIT_CONFD"

    local includes=""
    includes+="@INCLUDE ${FLUENT_BIT_CONFD}/linux.conf\n"
    $OPT_DOCKER  && includes+="@INCLUDE ${FLUENT_BIT_CONFD}/docker.conf\n"
    $OPT_PROXMOX && includes+="@INCLUDE ${FLUENT_BIT_CONFD}/proxmox.conf\n"
    $OPT_UNIFI   && includes+="@INCLUDE ${FLUENT_BIT_CONFD}/unifi.conf\n"

    cat > "$FLUENT_BIT_CONF" <<EOF
# =============================================================================
# Fluent Bit - Main Config
# Generated by install-log.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Host: $(hostname) (${HOST_IP})
# Target: https://${O2_HOST} (org: ${O2_ORG})
# =============================================================================

[SERVICE]
    Flush           5
    Daemon          Off
    Log_Level       info
    HTTP_Server     Off
    Parsers_File    /etc/fluent-bit/parsers.conf

# =============================================================================
# Host-specific settings
# =============================================================================
@SET o2_host=${O2_HOST}
@SET o2_org=${O2_ORG}
@SET host_ip=${HOST_IP}
@SET vlan=${VLAN}
@SET o2_user=${O2_USER}
@SET o2_passwd=${O2_PASSWD}

# =============================================================================
# Load configs
# =============================================================================
$(echo -e "$includes")
EOF

    chmod 600 "$FLUENT_BIT_CONF"
    ok "Main config written to ${FLUENT_BIT_CONF} (chmod 600 — contains password)"
}

# =============================================================================
# Step 4 — Deploy conf.d Configs
# =============================================================================
step_deploy_confd() {
    print_section "Deploying conf.d Configs"

    local confd_source="${SCRIPT_DIR}/logconfs"
    [[ -d "$confd_source" ]] || die "logconfs directory not found at ${confd_source}."

    cp "${confd_source}/linux.conf" "${FLUENT_BIT_CONFD}/linux.conf"
    ok "Deployed: linux.conf"

    if $OPT_DOCKER; then
        cp "${confd_source}/docker.conf" "${FLUENT_BIT_CONFD}/docker.conf"
        ok "Deployed: docker.conf"
    fi
    if $OPT_PROXMOX; then
        cp "${confd_source}/proxmox.conf" "${FLUENT_BIT_CONFD}/proxmox.conf"
        ok "Deployed: proxmox.conf"
    fi
    if $OPT_UNIFI; then
        cp "${confd_source}/unifi.conf" "${FLUENT_BIT_CONFD}/unifi.conf"
        ok "Deployed: unifi.conf"
    fi
}

# =============================================================================
# Step 5 — Configure Docker Logging Driver (optional)
# =============================================================================
step_configure_docker() {
    $OPT_DOCKER || return 0
    print_section "Configuring Docker Logging Driver"

    command -v docker &>/dev/null || die "Docker is not installed. Run install-docker.sh first."

    if [[ -f "$DAEMON_JSON" ]] && grep -q '"log-driver": "fluentd"' "$DAEMON_JSON" 2>/dev/null; then
        ok "Docker already configured with fluentd logging driver"
        return
    fi

    if [[ -f "$DAEMON_JSON" ]]; then
        cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
        warn "Existing daemon.json backed up"
        python3 - <<PYEOF
import json
with open('${DAEMON_JSON}') as f:
    cfg = json.load(f)
cfg['log-driver'] = 'fluentd'
cfg['log-opts'] = {
    'fluentd-address': 'localhost:24224',
    'tag': 'docker.{{.Name}}',
    'fluentd-async': 'true'
}
with open('${DAEMON_JSON}', 'w') as f:
    json.dump(cfg, f, indent=2)
PYEOF
    else
        cat > "$DAEMON_JSON" <<EOF
{
  "log-driver": "fluentd",
  "log-opts": {
    "fluentd-address": "localhost:24224",
    "tag": "docker.{{.Name}}",
    "fluentd-async": "true"
  }
}
EOF
    fi
    ok "Docker daemon.json configured with fluentd logging driver"
}

# =============================================================================
# Step 6 — Enable & Start Fluent Bit
# =============================================================================
step_enable_fluent_bit() {
    print_section "Enabling Fluent Bit Service"

    if /opt/fluent-bit/bin/fluent-bit -c "$FLUENT_BIT_CONF" --dry-run &>/dev/null; then
        ok "Configuration validated successfully"
    else
        die "Configuration validation failed. Check ${FLUENT_BIT_CONF}"
    fi

    systemctl enable --quiet fluent-bit
    systemctl restart fluent-bit
    sleep 2

    if systemctl is-active --quiet fluent-bit; then
        ok "Fluent Bit service is running"
    else
        die "Fluent Bit failed to start — check: journalctl -u fluent-bit"
    fi

    if $OPT_DOCKER; then
        info "Restarting Docker to activate fluentd logging driver..."
        systemctl restart docker
        ok "Docker restarted"
        warn "Restart your containers to activate the new logging driver:"
        echo -e "    ${CYAN}cd /etc/docker-compose/<stack> && docker compose up -d${NC}"
    fi
}



# =============================================================================
# Summary
# =============================================================================
step_summary() {
    print_section "Summary"

    local active_configs="linux"
    $OPT_DOCKER  && active_configs+=", docker"
    $OPT_PROXMOX && active_configs+=", proxmox"
    $OPT_UNIFI   && active_configs+=", unifi"

    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Fluent Bit installation complete!${NC}"
    echo ""
    printf "  ${BOLD}%-28s${NC} %s\n" "Host IP:"        "${HOST_IP}"
    printf "  ${BOLD}%-28s${NC} %s\n" "VLAN:"           "${VLAN}"
    printf "  ${BOLD}%-28s${NC} %s\n" "OpenObserve:"    "https://${O2_HOST} (org: ${O2_ORG})"
    printf "  ${BOLD}%-28s${NC} %s\n" "Active configs:" "${active_configs}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Main config:"    "${FLUENT_BIT_CONF}"
    printf "  ${BOLD}%-28s${NC} %s\n" "conf.d:"         "${FLUENT_BIT_CONFD}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Log:"            "${LOG_FILE}"
    echo ""
    info "Verify locally (journalctl -u fluent-bit -f → look for HTTP status=200):"
    echo -e "    ${CYAN}logger 'test message'${NC}"
    echo ""
    info "Verify in OpenObserve (from admin host):"
    echo -e "    ${CYAN}https://${O2_HOST}${NC} → Logs → syslog → host = '$(hostname)'"
    echo ""
    info "Other useful commands:"
    echo -e "    ${CYAN}systemctl status fluent-bit${NC}"
    echo -e "    ${CYAN}journalctl -u fluent-bit -f${NC}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    [[ "$EUID" -eq 0 ]] || die "This script must be run as root."

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== install-log.sh === $(date)" >> "$LOG_FILE"

    parse_args "$@"
    print_header

    step_detect_network
    step_get_credentials
    step_install_fluent_bit
    step_deploy_main_config
    step_deploy_confd
    step_configure_docker
    step_enable_fluent_bit
    step_summary
}

main "$@"
