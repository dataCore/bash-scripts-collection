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
# 4. Write /etc/fluent-bit/datacore.conf + datacore.env (our own files)
# 5. Deploy relevant conf.d configs based on host type flags
# 6. Point the service at our config via a systemd drop-in
# 7. [--docker] Configure Docker fluentd logging driver
# 8. Enable & start Fluent Bit
#
# The package config /etc/fluent-bit/fluent-bit.conf is NEVER touched. It is a
# dpkg conffile: editing it makes every `apt upgrade` (e.g. via update-system)
# stop on a "modified configuration file" conflict. Instead we keep our config
# beside it and override ExecStart in a systemd drop-in, which no package can
# overwrite. An older install that still owns fluent-bit.conf is migrated back
# to the packaged version automatically.
#
# Files owned by this script:
#   /etc/fluent-bit/datacore.conf                     main config (no secrets)
#   /etc/fluent-bit/datacore.env                      credentials, chmod 600
#   /etc/fluent-bit/datacore-parsers.conf             custom parsers
#   /etc/fluent-bit/conf.d/*.conf                     inputs/outputs per source
#   /etc/systemd/system/fluent-bit.service.d/datacore.conf   ExecStart override
#
# Required:
#   --host <fqdn>     OpenObserve endpoint, e.g. log.geek.ch
#                     Always the Traefik FQDN, for internal hosts too: the
#                     ingest API (/api/) is public, the UI is internal-only.
#                     The container publishes no host port, and Traefik routes
#                     on Host(log.geek.ch) — so the internal name datacorelog
#                     does not work (no route, no matching TLS cert).
#
# Optional source flags:
#   --docker          Include Docker log collection (requires Docker)
#   --proxmox         Include Proxmox task log collection
#   --unifi           Include UniFi syslog receiver (UDP 5140)
#   --bmc             Include BMC/IPMI syslog receiver (UDP 5141)
#   --truenas         Include TrueNAS syslog receiver (UDP 5142)
#
# Optional overrides (otherwise prompted / auto-detected):
#   --user <email>    OpenObserve ingest user
#   --pass <secret>   OpenObserve ingest password (avoid on shared shells)
#   --vlan <id>       Override auto-detected VLAN
#   --org <name>      OpenObserve organization (default: default)
#   -h, --help        Show this help
#
# Re-running is safe and idempotent: datacore.conf is regenerated from scratch,
# so re-running with a different --host switches the target and restarts the
# service.
#
# Examples:
#   install-log.sh --host log.geek.ch --docker
#   install-log.sh --host log.it-processing.ch --docker --proxmox
#   install-log.sh --host log.geek.ch --unifi --user o2-agent@geek.ch
#
# Repository: https://github.com/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

# --------------- Colors -------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --------------- Paths --------------------------------------------------------
PKG_CONF="/etc/fluent-bit/fluent-bit.conf"      # package conffile — never edited
DC_CONF="/etc/fluent-bit/datacore.conf"
DC_ENV="/etc/fluent-bit/datacore.env"
DC_PARSERS="/etc/fluent-bit/datacore-parsers.conf"
CONFD="/etc/fluent-bit/conf.d"
PARSERS_CONF="/etc/fluent-bit/parsers.conf"
DROPIN_DIR="/etc/systemd/system/fluent-bit.service.d"
DROPIN="${DROPIN_DIR}/datacore.conf"
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
OPT_BMC=false
OPT_TRUENAS=false

O2_HOST=""
O2_USER=""
O2_PASSWD=""
O2_ORG="default"
VLAN_OVERRIDE=""

# Filled in by the detection steps
HOST_IP=""
VLAN=""
FB_BIN=""
REPO_ID=""
REPO_CODENAME=""

# =============================================================================
# Helpers
# =============================================================================
# Tolerate a non-writable log (e.g. an arg error hit as a normal user).
# The writability test has to come first: a failing >> redirect reports to the
# terminal before an inline 2>/dev/null would take effect.
log() {
    [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ) ]] || return 0
    echo "$(date '+%Y-%m-%d %H:%M:%S') [install-log] $*" >> "$LOG_FILE"
}
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
cmd()   { echo -e "    ${CYAN}$1${NC}"; }

usage() {
    # Print the header comment block only: start at the first comment line
    # after the shebang, stop at the first non-comment line after that.
    awk 'NR==1 {next} /^#/ {started=1; sub(/^# ?/, ""); print; next} started {exit}' "$0"
    exit "${1:-0}"
}

# Run `apt-get update` but do not abort the whole install if an unrelated
# third-party repository is broken — we verify the package we actually need
# is available before installing.
apt_update() {
    local errfile="/tmp/datacore-apt-update.$$"
    if apt-get update -qq 2>"$errfile"; then
        rm -f "$errfile"
        return 0
    fi
    warn "apt-get update reported errors — likely a broken third-party repo:"
    grep -E '^(E|W):' "$errfile" | sed 's/^/      /' || sed 's/^/      /' "$errfile"
    rm -f "$errfile"
    return 0
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
            --bmc)       OPT_BMC=true; shift ;;
            --truenas)   OPT_TRUENAS=true; shift ;;
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

    echo ""
    info "Verifying credentials against https://${O2_HOST}..."
    local http_status
    # Pass credentials via stdin config so they don't show up in the process list
    http_status=$(curl -s -o /dev/null -w "%{http_code}" \
        --config - \
        "https://${O2_HOST}/api/${O2_ORG}/streams" \
        <<< "user = \"${O2_USER}:${O2_PASSWD}\"" || echo "000")

    if [[ "$http_status" == "200" ]]; then
        ok "Credentials verified successfully"
    else
        die "Credential check failed (HTTP ${http_status}). Check --host / user / password."
    fi
}

# =============================================================================
# Step 2 — Install Fluent Bit
# =============================================================================
# Resolve the upstream distro Fluent Bit actually publishes packages for and
# set REPO_ID / REPO_CODENAME. Derivatives such as Linux Mint carry their own
# codename (e.g. "zena"), which has no repo at packages.fluentbit.io — their
# os-release names the upstream base in UBUNTU_CODENAME / DEBIAN_CODENAME.
detect_os() {
    local os_release="${OS_RELEASE:-/etc/os-release}"
    [[ -f "$os_release" ]] || die "Cannot detect OS: ${os_release} not found"
    # shellcheck source=/dev/null
    source "$os_release"

    local os_id="${ID:-unknown}"
    local os_codename="${VERSION_CODENAME:-}"
    info "Detected OS: ${os_id} ${VERSION_ID:-?} (${os_codename:-?})"

    case "$os_id" in
        debian|ubuntu)
            REPO_ID="$os_id"
            REPO_CODENAME="$os_codename"
            ;;
        linuxmint|lmde)
            if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
                REPO_ID="ubuntu"
                REPO_CODENAME="${UBUNTU_CODENAME}"
            elif [[ -n "${DEBIAN_CODENAME:-}" ]]; then
                REPO_ID="debian"
                REPO_CODENAME="${DEBIAN_CODENAME}"
            else
                die "Linux Mint detected but os-release names no upstream codename."
            fi
            ;;
        *)
            if [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
                REPO_ID="ubuntu"
                REPO_CODENAME="${UBUNTU_CODENAME:-$os_codename}"
            elif [[ "${ID_LIKE:-}" == *debian* ]]; then
                REPO_ID="debian"
                REPO_CODENAME="${DEBIAN_CODENAME:-$os_codename}"
            else
                die "Unsupported distribution: ${os_id}"
            fi
            ;;
    esac

    [[ -n "$REPO_CODENAME" ]] || die "Could not detect OS codename."
    [[ "$os_codename" == "$REPO_CODENAME" ]] \
        || info "Derivative ${os_id} (${os_codename}) -> using ${REPO_ID}/${REPO_CODENAME} packages"
}

# Hand /etc/fluent-bit/fluent-bit.conf back to dpkg.
# Installs before mid-2026 generated our config into that path. Since it is a
# conffile, every package upgrade then stopped on a conflict prompt (or left a
# .dpkg-dist behind). Restoring the packaged version ends that for good — our
# config now lives in datacore.conf and the service is pointed there by a
# systemd drop-in.
restore_package_config() {
    [[ -f "$PKG_CONF" ]] || return 0
    grep -q 'Generated by install-log.sh' "$PKG_CONF" 2>/dev/null || return 0

    warn "Legacy install detected: ${PKG_CONF} was generated by this script"
    local backup
    backup="${PKG_CONF}.datacore-legacy.$(date +%Y%m%d%H%M%S)"
    install -m 600 /dev/null "$backup"
    cat "$PKG_CONF" > "$backup"
    info "Backed up to ${backup} (chmod 600 — contains the old password)"

    # A kept-back upgrade leaves the packaged version next to the conffile.
    local candidate
    for candidate in "${PKG_CONF}.dpkg-dist" "${PKG_CONF}.dpkg-new"; do
        if [[ -f "$candidate" ]]; then
            mv "$candidate" "$PKG_CONF"
            ok "Package config restored from $(basename "$candidate")"
            return 0
        fi
    done

    # Otherwise let dpkg put the conffile back: it only restores a *missing*
    # conffile, and only when told to (--force-confmiss).
    rm -f "$PKG_CONF"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --reinstall \
        -o Dpkg::Options::=--force-confmiss fluent-bit &>/dev/null \
        && [[ -f "$PKG_CONF" ]]; then
        ok "Package config restored by reinstalling fluent-bit"
    else
        warn "Could not restore ${PKG_CONF} — the file stays absent."
        warn "That is harmless (nothing reads it), and dpkg will not prompt for it."
    fi
}

# The Debian/Ubuntu package installs into /opt; some builds add a symlink.
detect_fluent_bit_bin() {
    local candidate
    for candidate in /opt/fluent-bit/bin/fluent-bit "$(command -v fluent-bit || true)"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            FB_BIN="$candidate"
            return 0
        fi
    done
    die "Could not locate the fluent-bit binary after installation."
}

step_install_fluent_bit() {
    print_section "Installing Fluent Bit"

    if command -v fluent-bit &>/dev/null || [[ -x /opt/fluent-bit/bin/fluent-bit ]]; then
        ok "Fluent Bit already installed: $(fluent-bit --version 2>/dev/null | head -1)"
        restore_package_config
        info "Checking for updates..."
        apt_update
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fluent-bit
        ok "Fluent Bit up to date"
        detect_fluent_bit_bin
        return
    fi

    info "Adding Fluent Bit APT repository..."
    curl -fsSL https://packages.fluentbit.io/fluentbit.key \
        | gpg --dearmor > /usr/share/keyrings/fluentbit-keyring.gpg

    detect_os

    echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] \
https://packages.fluentbit.io/${REPO_ID}/${REPO_CODENAME} ${REPO_CODENAME} main" \
        | tee /etc/apt/sources.list.d/fluent-bit.list > /dev/null
    ok "Repository added: ${REPO_ID}/${REPO_CODENAME}"

    apt_update
    apt-cache show fluent-bit &>/dev/null \
        || die "fluent-bit is not available — check the Fluent Bit repository above"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fluent-bit
    ok "Fluent Bit installed: $(fluent-bit --version 2>/dev/null | head -1)"
    detect_fluent_bit_bin
}

# =============================================================================
# Step 3 — Deploy dataCore Config
# =============================================================================
step_deploy_config() {
    print_section "Deploying dataCore Config"

    mkdir -p "$CONFD"

    # Credentials live in an env file read by systemd, not in the config:
    # that keeps datacore.conf readable for debugging and the secret in one
    # place. Fluent Bit resolves ${o2_user} / ${o2_passwd} from its environment
    # exactly like the @SET variables below.
    # systemd strips the quotes and processes \" and \\ inside them — it does
    # not expand $, backticks or anything else, so escaping those two is enough.
    local esc_user esc_passwd
    esc_user=$(printf '%s' "$O2_USER"   | sed 's/[\\"]/\\&/g')
    esc_passwd=$(printf '%s' "$O2_PASSWD" | sed 's/[\\"]/\\&/g')

    install -m 600 /dev/null "$DC_ENV"
    cat > "$DC_ENV" <<EOF
# OpenObserve ingest credentials for Fluent Bit
# Generated by install-log.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Read by systemd (EnvironmentFile=) — see ${DROPIN}
o2_user="${esc_user}"
o2_passwd="${esc_passwd}"
EOF
    ok "Credentials written to ${DC_ENV} (chmod 600)"

    local includes=""
    includes+="@INCLUDE ${CONFD}/linux.conf\n"
    $OPT_DOCKER  && includes+="@INCLUDE ${CONFD}/docker.conf\n"
    $OPT_PROXMOX && includes+="@INCLUDE ${CONFD}/proxmox.conf\n"
    $OPT_UNIFI   && includes+="@INCLUDE ${CONFD}/unifi.conf\n"
    $OPT_BMC     && includes+="@INCLUDE ${CONFD}/bmc.conf\n"
    $OPT_TRUENAS && includes+="@INCLUDE ${CONFD}/truenas.conf\n"

    cat > "$DC_CONF" <<EOF
# =============================================================================
# Fluent Bit - dataCore Main Config
# Generated by install-log.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Host: $(hostname) (${HOST_IP})
# Target: https://${O2_HOST} (org: ${O2_ORG})
#
# Do not edit — re-run install-log.sh instead. The packaged config
# ${PKG_CONF} is deliberately left untouched so package
# upgrades never conflict; the service is pointed here by ${DROPIN}.
# Credentials come from ${DC_ENV}.
# =============================================================================

[SERVICE]
    Flush           5
    Daemon          Off
    Log_Level       warn
    HTTP_Server     Off
    Parsers_File    ${PARSERS_CONF}
    Parsers_File    ${DC_PARSERS}

# =============================================================================
# Host-specific settings
# =============================================================================
@SET o2_host=${O2_HOST}
@SET o2_org=${O2_ORG}
@SET host_ip=${HOST_IP}
@SET vlan=${VLAN}

# =============================================================================
# Load configs
# =============================================================================
$(echo -e "$includes")
EOF

    chmod 644 "$DC_CONF"
    ok "Main config written to ${DC_CONF}"
    ok "Package config ${PKG_CONF} left untouched"
}

# =============================================================================
# Step 4 — Deploy conf.d Configs
# =============================================================================
step_deploy_confd() {
    print_section "Deploying conf.d Configs"

    local confd_source="${SCRIPT_DIR}/logconfs"
    [[ -d "$confd_source" ]] || die "logconfs directory not found at ${confd_source}."

    cp "${confd_source}/datacore-parsers.conf" "$DC_PARSERS"
    ok "Deployed: datacore-parsers.conf"

    cp "${confd_source}/linux.conf" "${CONFD}/linux.conf"
    ok "Deployed: linux.conf"

    if $OPT_DOCKER; then
        cp "${confd_source}/docker.conf" "${CONFD}/docker.conf"
        ok "Deployed: docker.conf"
    fi
    if $OPT_PROXMOX; then
        cp "${confd_source}/proxmox.conf" "${CONFD}/proxmox.conf"
        ok "Deployed: proxmox.conf"
    fi
    if $OPT_UNIFI; then
        cp "${confd_source}/unifi.conf" "${CONFD}/unifi.conf"
        ok "Deployed: unifi.conf"
    fi
    if $OPT_BMC; then
        cp "${confd_source}/bmc.conf" "${CONFD}/bmc.conf"
        ok "Deployed: bmc.conf"
    fi
    if $OPT_TRUENAS; then
        cp "${confd_source}/truenas.conf" "${CONFD}/truenas.conf"
        ok "Deployed: truenas.conf"
    fi
}

# =============================================================================
# Step 5 — Systemd Drop-in
# =============================================================================
# The drop-in lives in /etc/systemd/system and survives every package upgrade,
# so the service keeps reading our config instead of the packaged one.
step_service_override() {
    print_section "Pointing the Service at Our Config"

    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN" <<EOF
# Fluent Bit — dataCore service override
# Generated by install-log.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Runs Fluent Bit with our config instead of the packaged ${PKG_CONF}.
# The empty ExecStart= clears the unit's own command before setting ours.
[Service]
EnvironmentFile=${DC_ENV}
ExecStart=
ExecStart=${FB_BIN} -c ${DC_CONF}
EOF
    chmod 644 "$DROPIN"
    ok "Drop-in written to ${DROPIN}"

    systemctl daemon-reload
    ok "systemd configuration reloaded"
}

# =============================================================================
# Step 6 — Configure Docker Logging Driver (optional)
# =============================================================================
step_configure_docker() {
    $OPT_DOCKER || return 0
    print_section "Configuring Docker Logging Driver"

    command -v docker &>/dev/null || die "Docker is not installed. Run install-docker.sh first."

    if [[ -f "$DAEMON_JSON" ]] && python3 -c "import json,sys; sys.exit(0 if json.load(open('$DAEMON_JSON')).get('log-driver')=='fluentd' else 1)" 2>/dev/null; then
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
# Step 7 — Enable & Start Fluent Bit
# =============================================================================
step_enable_fluent_bit() {
    print_section "Enabling Fluent Bit Service"

    # Same environment systemd will provide, so the dry-run sees real values
    if o2_user="$O2_USER" o2_passwd="$O2_PASSWD" \
        "$FB_BIN" -c "$DC_CONF" --dry-run &>/dev/null; then
        ok "Configuration validated successfully"
    else
        die "Configuration validation failed. Check ${DC_CONF}"
    fi

    systemctl enable --quiet fluent-bit
    systemctl restart fluent-bit
    sleep 2

    if systemctl is-active --quiet fluent-bit; then
        ok "Fluent Bit service is running"
    else
        die "Fluent Bit failed to start — check: journalctl -u fluent-bit"
    fi

    # Confirm the running process actually uses our config, not the packaged one
    if systemctl show -p ExecStart --value fluent-bit | grep -q -- "$DC_CONF"; then
        ok "Service is running with ${DC_CONF}"
    else
        warn "Service does not seem to use ${DC_CONF} — check ${DROPIN}"
    fi

    if $OPT_DOCKER; then
        info "Restarting Docker to activate fluentd logging driver..."
        systemctl restart docker
        ok "Docker restarted"
        warn "Restart your containers to activate the new logging driver:"
        cmd "cd /etc/docker-compose/<stack> && docker compose up -d"
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
    $OPT_BMC     && active_configs+=", bmc"
    $OPT_TRUENAS && active_configs+=", truenas"

    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Fluent Bit installation complete!${NC}"
    echo ""
    printf "  ${BOLD}%-28s${NC} %s\n" "Host IP:"        "${HOST_IP}"
    printf "  ${BOLD}%-28s${NC} %s\n" "VLAN:"           "${VLAN}"
    printf "  ${BOLD}%-28s${NC} %s\n" "OpenObserve:"    "https://${O2_HOST} (org: ${O2_ORG})"
    printf "  ${BOLD}%-28s${NC} %s\n" "Active configs:" "${active_configs}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Main config:"    "${DC_CONF}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Credentials:"    "${DC_ENV}"
    printf "  ${BOLD}%-28s${NC} %s\n" "conf.d:"         "${CONFD}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Service drop-in:" "${DROPIN}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Log:"            "${LOG_FILE}"
    echo ""
    info "The packaged ${PKG_CONF} is untouched, so"
    info "update-system / apt upgrade will not stop on a config conflict."
    echo ""
    info "Verify locally — at Log_Level warn the journal stays quiet unless"
    info "something is wrong, so no output means the agent is healthy:"
    cmd "journalctl -u fluent-bit -f"
    cmd "logger 'install-log test'   # then confirm it in OpenObserve below"
    echo ""
    info "Verify in OpenObserve (from an admin host with UI access):"
    cmd "https://${O2_HOST} -> Logs -> syslog -> host = '$(hostname)'"
    echo ""
    info "Service commands:"
    cmd "systemctl status fluent-bit"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    # Parsed before the root check so --help works as a normal user
    parse_args "$@"

    [[ "$EUID" -eq 0 ]] || die "This script must be run as root."

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== install-log.sh === $(date)" >> "$LOG_FILE"

    print_header

    step_detect_network
    step_get_credentials
    step_install_fluent_bit
    step_deploy_config
    step_deploy_confd
    step_service_override
    step_configure_docker
    step_enable_fluent_bit
    step_summary
}

main "$@"
