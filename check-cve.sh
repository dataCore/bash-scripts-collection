#!/bin/bash
# =============================================================================
# check-cve – geek.ch Security Check Script
# Repository: https://github.com/dataCore/bash-scripts-collection
#
# Checks for active exposure to:
#   CVE-2026-98432  IPv4 TCP ireq_opt use-after-free – remote root via a SYN
#                   with IP options (Record Route / Timestamp), CVSS 9.8
#
# Earlier versions checked Copy Fail, Dirty Frag, Fragnesia, CrackArmor,
# ptrace mm-NULL and CIFSwitch; those are fixed by current kernels and were
# dropped. Mitigation files they left behind are only listed.
#
# Usage:
#   check-cve            # interactive output
#   check-cve --fix      # apply mitigations (MPTCP off, drop IPv4 TCP with IP options)
#   check-cve --json     # machine-readable JSON output
#
# Advisories:
#   https://thehackernews.com/2026/10/linux-kernel-tcp-flaw-with-98-cvss.html
#   https://security-tracker.debian.org/tracker/CVE-2026-98432
#   https://ubuntu.com/security/CVE-2026-98432
#   https://access.redhat.com/security/cve/cve-2026-98432
#   https://forum.proxmox.com/threads/cve-2026-98432-in-proxmox-ve.187339/
#   https://getrff.com/blog/cve-2026-98432-linux-tcp-ip-options-block/
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Argument parsing ──────────────────────────────────────────────────────────
MODE="check"
OPT_FIX=false
OPT_JSON=false
for arg in "$@"; do
    case "$arg" in
        --fix)  OPT_FIX=true;  MODE="fix"  ;;
        --json) OPT_JSON=true; MODE="json" ;;
        -h|--help)
            echo "Usage: $0 [--fix | --json]"
            echo "  (no flag)  Interactive security check"
            echo "  --fix      Apply mitigations (MPTCP off, drop IPv4 TCP with IP options)"
            echo "  --json     Output results as JSON"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done
if [[ "$OPT_FIX" == "true" && "$OPT_JSON" == "true" ]]; then
    echo "Error: --fix and --json cannot be combined" >&2
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
# In JSON mode stdout must carry nothing but the JSON document.
ok()   { [[ "$MODE" == "json" ]] && return 0; echo -e "  ${GREEN}[OK]${RESET}   $*"; }
warn() { [[ "$MODE" == "json" ]] && return 0; echo -e "  ${RED}[WARN]${RESET} $*"; }
info() { [[ "$MODE" == "json" ]] && return 0; echo -e "  ${CYAN}[INFO]${RESET} $*"; }
miss() { [[ "$MODE" == "json" ]] && return 0; echo -e "  ${YELLOW}[MISS]${RESET} $*"; }
section() { [[ "$MODE" == "json" ]] && return 0; echo -e "\n${BOLD}$*${RESET}"; }

# Escape a string for use inside a JSON string literal.
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    # Drop any remaining control characters
    printf '%s' "$s" | tr -d '\000-\037'
}

# Read a sysctl from /proc/sys (sysctl itself is in /sbin, often not in PATH).
# Prints "absent" when the key does not exist on this kernel.
read_sysctl() {
    local f="/proc/sys/${1//.//}"
    if [[ -r "$f" ]]; then cat "$f"; else echo "absent"; fi
}

# True when version $1 >= $2 (sort -V, works without dpkg)
ver_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

IS_ROOT=false
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=true

CONTAINER="none"
if command -v systemd-detect-virt &>/dev/null; then
    CONTAINER=$(systemd-detect-virt -c 2>/dev/null || true)
    [[ -z "$CONTAINER" ]] && CONTAINER="none"
fi

_DISTRO_ID=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
_DISTRO_VER=$(grep "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
_DISTRO_LIKE=$(grep "^ID_LIKE=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true)

# Mitigation installed by --fix
NFT_TABLE="cve_2026_98432"
NFT_FILE="/etc/datacore/cve-2026-98432.nft"
NFT_UNIT="cve-2026-98432-nft.service"
SYSCTL_FILE="/etc/sysctl.d/99-cve-2026-98432.conf"

# ── Header ────────────────────────────────────────────────────────────────────
if [[ "$MODE" != "json" ]]; then
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${BOLD} geek.ch Linux Security – CVE CHECKER ${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo    "  Host   : $(hostname -f 2>/dev/null || hostname)"
    echo    "  Kernel : $(uname -r)"
    echo    "  OS     : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -s)"
    echo    "  Date   : $(date '+%Y-%m-%d %H:%M %Z')"
    echo    "  User   : $(whoami)"
    echo -e "${BOLD}------------------------------------------------------------${RESET}"
fi

# ── [1/3] Patch status ────────────────────────────────────────────────────────
# The race is in the IPv4 TCP handshake: a SYN with IP options (Record Route
# or Timestamp) stores them in the request; on completion they are handed to
# the new socket without a copy and freed while another CPU still answers a
# retransmitted SYN with them. All kernels since 4.4, IPv6 is not affected.
# Upstream fix e3f33b0a1d89 "ipv4: free inet_opt and ireq_opt after an RCU
# grace period".
#
# Known fixed versions:
#   Upstream stable:     5.10.272, 5.15.223, 6.1.190, 6.6.159, 6.12.113,
#                        6.18.56, 7.2.10, 7.3
#   Debian 12 bookworm:  linux 6.1.190-1 (DLA-4841-1),
#                        linux-6.12 6.12.113-1~deb12u1 (DLA-4850-1)
#   Debian 13 trixie:    linux 6.12.113-1 (DSA-6568-1)
#   Proxmox 7.0 kernel:  7.0.14-25 – built on Ubuntu-7.0.0-43.43i1, which
#                        carries the backport (Ubuntu commit 091732b7). Taken
#                        from the Proxmox forum, not confirmed by Proxmox.
#   Ubuntu, RHEL:        no fixed kernel as of 2026-10-30 – changelog only
section "[1/3] CVE-2026-98432 – patch status (IPv4 TCP ireq_opt use-after-free)"

CHANGELOG_PATTERN='CVE-2026-98432|e3f33b0a1d89|free inet_opt and ireq_opt'

# Running kernel package, resolved via the owner of the kernel image.
KPKG_NAME=""
KPKG_VER=""
KPKG_FLAVOUR="none"   # debian | proxmox | none (image not owned by a package)
if command -v dpkg &>/dev/null && [[ -e "/boot/vmlinuz-$(uname -r)" ]]; then
    KPKG_NAME=$(dpkg -S "/boot/vmlinuz-$(uname -r)" 2>/dev/null \
        | awk -F': ' '!/^diversion / { split($1, a, ", "); print a[1]; exit }' || true)
    KPKG_NAME="${KPKG_NAME%%:*}"   # strip :arch qualifier
fi
if [[ -n "$KPKG_NAME" ]]; then
    KPKG_VER=$(dpkg-query -W -f='${Version}' "$KPKG_NAME" 2>/dev/null || true)
    case "$KPKG_NAME" in
        proxmox-kernel-*|pve-kernel-*) KPKG_FLAVOUR="proxmox" ;;
        *)                             KPKG_FLAVOUR="debian" ;;
    esac
fi

# Kernel changelog, loaded at most once (local copy first, then a single
# 'apt-get changelog' which needs network) into a temp file.
KCHANGELOG=""
KCHANGELOG_STATE="unloaded"   # unloaded | loaded | unavailable
cleanup_tmp() { [[ -n "$KCHANGELOG" ]] && rm -f "$KCHANGELOG"; return 0; }
trap cleanup_tmp EXIT

_kernel_changelog_load() {
    [[ "$KCHANGELOG_STATE" != "unloaded" ]] && return 0
    KCHANGELOG_STATE="unavailable"
    [[ -z "$KPKG_NAME" ]] && return 0
    KCHANGELOG=$(mktemp) || { KCHANGELOG=""; return 0; }
    local doc_dir="/usr/share/doc/${KPKG_NAME}" f
    # Debian kernel: changelog.gz (upstream); Ubuntu kernel: changelog.Debian.gz
    for f in "${doc_dir}/changelog.gz" "${doc_dir}/changelog.Debian.gz"; do
        if [[ -f "$f" ]]; then
            zcat "$f" > "$KCHANGELOG" 2>/dev/null || true
            break
        fi
    done
    if [[ ! -s "$KCHANGELOG" ]]; then
        apt-get changelog --no-download-limit "$KPKG_NAME" > "$KCHANGELOG" 2>/dev/null || true
    fi
    [[ -s "$KCHANGELOG" ]] && KCHANGELOG_STATE="loaded"
    return 0
}

# Fixed version for the running kernel package, empty when unknown
fixed_version() {
    case "$KPKG_FLAVOUR" in
        proxmox)
            case "$KPKG_NAME" in
                proxmox-kernel-7.0.*) echo "7.0.14-25" ;;
            esac
            ;;
        debian)
            case "${_DISTRO_ID}:${_DISTRO_VER}" in
                debian:bookworm)
                    case "$KPKG_VER" in
                        6.12.*) echo "6.12.113-1~deb12u1" ;;
                        6.1.*)  echo "6.1.190-1" ;;
                    esac
                    ;;
                debian:trixie)
                    case "$KPKG_VER" in
                        6.12.*) echo "6.12.113-1" ;;
                    esac
                    ;;
            esac
            ;;
    esac
}

# First fixed upstream stable release for the branch of version $1
upstream_fixed() {
    case "$(cut -d. -f1,2 <<< "$1")" in
        5.10) echo "5.10.272" ;;
        5.15) echo "5.15.223" ;;
        6.1)  echo "6.1.190" ;;
        6.6)  echo "6.6.159" ;;
        6.12) echo "6.12.113" ;;
        6.18) echo "6.18.56" ;;
        7.2)  echo "7.2.10" ;;
    esac
}

# Result: patched | not_patched | not_tracked | unknown
PATCH_STATUS="unknown"
FIXED_VER=""
if [[ -n "$KPKG_VER" ]]; then
    FIXED_VER=$(fixed_version)
    if [[ -n "$FIXED_VER" ]] && dpkg --compare-versions "$KPKG_VER" ge "$FIXED_VER" 2>/dev/null; then
        PATCH_STATUS="patched"
    else
        # Changelog catches backports with unusual version strings and
        # releases fixed after this script was written (Ubuntu lists CVE ids)
        _kernel_changelog_load
        if [[ "$KCHANGELOG_STATE" == "loaded" ]] && grep -qiE "$CHANGELOG_PATTERN" "$KCHANGELOG"; then
            PATCH_STATUS="patched"
        elif [[ -n "$FIXED_VER" ]]; then
            PATCH_STATUS="not_patched"
        else
            PATCH_STATUS="not_tracked"
        fi
    fi
elif [[ "$CONTAINER" == "none" ]]; then
    # Self-built kernel: compare the upstream version
    KBASE="$(uname -r)"; KBASE="${KBASE%%[-+]*}"
    FIXED_VER=$(upstream_fixed "$KBASE")
    if [[ -n "$FIXED_VER" ]]; then
        if ver_ge "$KBASE" "$FIXED_VER"; then PATCH_STATUS="patched"; else PATCH_STATUS="not_patched"; fi
    elif ver_ge "$KBASE" "7.3"; then
        PATCH_STATUS="patched"
    fi
fi

if [[ "$CONTAINER" != "none" ]]; then
    info "Running in a container (${CONTAINER}) – the kernel is the host's, check the host"
fi
if [[ -n "$KPKG_VER" ]]; then
    info "Package     : ${KPKG_NAME} ${KPKG_VER}"
fi
case "$PATCH_STATUS" in
    patched)
        ok "Kernel fix installed${FIXED_VER:+ (fixed in ${FIXED_VER})}"
        [[ "$KPKG_FLAVOUR" == "proxmox" ]] && \
            info "  Proxmox fix version from the forum, not confirmed by Proxmox"
        ;;
    not_patched)
        warn "Kernel NOT patched – fixed in ${FIXED_VER:-a newer kernel}"
        ;;
    not_tracked)
        miss "No fixed-version data for ${KPKG_NAME} and no fix in its changelog"
        [[ " ${_DISTRO_ID} ${_DISTRO_LIKE} " == *" ubuntu "* ]] && \
            info "  Ubuntu had no fixed kernel as of 2026-10-30 – https://ubuntu.com/security/CVE-2026-98432"
        ;;
    unknown)
        miss "Kernel package not identified – patch status unknown"
        ;;
esac

# Running kernel older than the newest installed one?
AVAIL=$(apt list --upgradable 2>/dev/null \
    | grep -iE "^(linux-image|proxmox-kernel|pve-kernel)" || true)
if [[ -n "$AVAIL" ]]; then
    warn "Newer kernel available via apt – update recommended:"
    while read -r line; do info "    $line"; done <<< "$AVAIL"
fi

# ── [2/3] Exposure ────────────────────────────────────────────────────────────
section "[2/3] Exposure (IPv4 TCP listeners, MPTCP)"

# 2a. TCP listeners reachable over IPv4: everything except loopback and
#     addresses bound to one IPv6 address. [::] and * accept IPv4 too.
IPV4_LISTENERS=0
if command -v ss &>/dev/null; then
    IPV4_LISTENERS=$(ss -Hltn 2>/dev/null | awk '
        { addr = $4; sub(/:[0-9]+$/, "", addr); sub(/%.*/, "", addr) }
        addr ~ /^127\./ || addr == "[::1]"                         { next }
        addr ~ /^\[/ && addr != "[::]" && addr !~ /^\[::ffff:/     { next }
        { n++ }
        END { print n + 0 }')
fi
if [[ "$IPV4_LISTENERS" -gt 0 ]]; then
    info "${IPV4_LISTENERS} TCP listener(s) reachable over IPv4 – attack surface present"
else
    ok "No TCP listener reachable over IPv4"
fi

# 2b. MPTCP listeners. The published root exploit needs one; the bug itself
#     does not. Go >= 1.24 opens MPTCP listeners by default (Zabbix Agent 2,
#     Traefik, docker-proxy, ...). Processes are only visible to root.
MPTCP_SYSCTL=$(read_sysctl net.mptcp.enabled)
MPTCP_LISTENERS="unknown"
if command -v ss &>/dev/null && ss -HlnM &>/dev/null; then
    MPTCP_LIST=$(ss -HlnMp 2>/dev/null || true)
    MPTCP_LISTENERS=$(grep -c . <<< "$MPTCP_LIST" || true)
    if [[ "$MPTCP_LISTENERS" -gt 0 ]]; then
        warn "${MPTCP_LISTENERS} MPTCP listener(s) – matches the published exploit:"
        while read -r line; do
            info "    $(awk '{ $2 = $3 = ""; print }' <<< "$line" | tr -s ' ')"
        done <<< "$MPTCP_LIST"
        [[ "$IS_ROOT" != "true" ]] && info "  (run as root to see the processes)"
    else
        ok "No MPTCP listeners"
    fi
else
    miss "ss cannot list MPTCP sockets (iproute2 too old?)"
fi

if [[ "$MPTCP_SYSCTL" == "absent" ]]; then
    ok "Kernel without MPTCP (net.mptcp.enabled absent)"
elif [[ "$MPTCP_SYSCTL" == "0" ]]; then
    ok "net.mptcp.enabled=0 – no new MPTCP sockets in this network namespace"
else
    info "net.mptcp.enabled=${MPTCP_SYSCTL}"
fi

# 2c. Docker containers have their own network namespace with its own
#     net.mptcp.enabled (default 1) – the host sysctl does not cover them.
DOCKER_MPTCP=0
if [[ "$IS_ROOT" == "true" ]] && command -v docker &>/dev/null && command -v nsenter &>/dev/null; then
    while read -r cid; do
        [[ -z "$cid" ]] && continue
        pid=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null || echo 0)
        [[ "$pid" -gt 0 ]] || continue
        n=$(nsenter -t "$pid" -n ss -HlnM 2>/dev/null | grep -c . || true)
        if [[ "$n" -gt 0 ]]; then
            name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || echo "$cid")
            warn "Container ${name#/}: ${n} MPTCP listener(s)"
            DOCKER_MPTCP=$((DOCKER_MPTCP + n))
        fi
    done < <(docker ps -q 2>/dev/null || true)
    if [[ "$DOCKER_MPTCP" -gt 0 ]]; then
        info "  → set GODEBUG=multipathtcp=0 in these services or patch the kernel"
    else
        ok "No MPTCP listeners in Docker containers"
    fi
fi

# 2d. Request socket migration opens a second, narrower path
MIGRATE_REQ=$(read_sysctl net.ipv4.tcp_migrate_req)
if [[ "$MIGRATE_REQ" == "1" ]]; then
    warn "net.ipv4.tcp_migrate_req=1 – second trigger path open"
else
    ok "net.ipv4.tcp_migrate_req=${MIGRATE_REQ}"
fi

# 2e. nftables rule from --fix (listing needs root)
NFT_MITIGATION="unknown"
if [[ "$IS_ROOT" == "true" ]] && command -v nft &>/dev/null; then
    if nft list table ip "$NFT_TABLE" &>/dev/null; then
        NFT_MITIGATION="true"
        ok "nftables drops IPv4 TCP with IP options (table ip ${NFT_TABLE})"
    else
        NFT_MITIGATION="false"
        miss "No nftables rule against IP options (table ip ${NFT_TABLE})"
    fi
elif [[ "$IS_ROOT" != "true" ]]; then
    miss "nftables rule not checked – requires root"
fi

# 2f. Crash traces of failed races in this boot's kernel log
CRASH_TRACES=0
if command -v journalctl &>/dev/null; then
    CRASH_TRACES=$(journalctl -k -b --no-pager 2>/dev/null \
        | grep -cE 'ip_options_build|ip_build_and_send_pkt|skb_under_panic' || true)
fi
if [[ "$CRASH_TRACES" -gt 0 ]]; then
    warn "${CRASH_TRACES} kernel log line(s) matching the crash signature – possible exploit attempts:"
    info "  → journalctl -k -b | grep -E 'ip_options_build|ip_build_and_send_pkt|skb_under_panic'"
fi

# Overall status
if [[ "$PATCH_STATUS" == "patched" ]]; then
    STATUS="patched"
elif [[ "$NFT_MITIGATION" == "true" ]]; then
    STATUS="mitigated"
elif [[ "$IPV4_LISTENERS" -eq 0 ]]; then
    STATUS="not_exposed"
else
    STATUS="vulnerable"
fi

# ── [3/3] Leftovers from earlier check-cve versions ──────────────────────────
section "[3/3] Mitigations left by earlier check-cve versions"
LEFTOVERS=()
for f in /etc/modprobe.d/disable-algif.conf /etc/modprobe.d/dirtyfrag.conf \
         /etc/modprobe.d/fragnesia.conf /etc/sysctl.d/99-cifswitch.conf; do
    [[ -f "$f" ]] && LEFTOVERS+=("$f")
done
if [[ ${#LEFTOVERS[@]} -gt 0 ]]; then
    info "Still in place (Copy Fail, Dirty Frag, Fragnesia, CIFSwitch – no longer checked):"
    for f in "${LEFTOVERS[@]}"; do info "    $f"; done
    info "  Harmless while the features are unused (esp4/esp6 block IPsec)."
    info "  On a current kernel they can go: rm <file> && update-initramfs -u, then reboot"
else
    ok "None"
fi

# ── Apply mitigations (--fix mode) ───────────────────────────────────────────
if [[ "$MODE" == "fix" ]]; then
    echo -e "\n${BOLD}[--fix] Applying mitigations...${RESET}"

    if [[ "$IS_ROOT" != "true" ]]; then
        echo -e "${RED}Error: --fix requires root privileges (sudo check-cve --fix)${RESET}"
        exit 1
    fi

    if [[ "$PATCH_STATUS" == "patched" ]]; then
        ok "Kernel is patched – no mitigation needed"
        if [[ -f "$NFT_FILE" || -f "$SYSCTL_FILE" ]]; then
            info "  Mitigation from an earlier --fix can be removed:"
            info "    systemctl disable --now ${NFT_UNIT}; nft delete table ip ${NFT_TABLE}"
            info "    rm -f /etc/systemd/system/${NFT_UNIT} ${NFT_FILE} ${SYSCTL_FILE}"
        fi
        exit 0
    fi

    # Sysctls: MPTCP off for new sockets, request migration off. Both only
    # apply to this network namespace.
    {
        echo "# CVE-2026-98432 – set by check-cve --fix, remove once the kernel is patched"
        [[ "$MPTCP_SYSCTL" != "absent" ]] && echo "net.mptcp.enabled = 0"
        [[ "$MIGRATE_REQ" != "absent" ]] && echo "net.ipv4.tcp_migrate_req = 0"
    } > "$SYSCTL_FILE"
    [[ "$MPTCP_SYSCTL" != "absent" ]] && { echo 0 > /proc/sys/net/mptcp/enabled 2>/dev/null || true; }
    [[ "$MIGRATE_REQ" != "absent" ]] && { echo 0 > /proc/sys/net/ipv4/tcp_migrate_req 2>/dev/null || true; }
    if [[ "$(read_sysctl net.mptcp.enabled)" =~ ^(0|absent)$ ]]; then
        ok "net.mptcp.enabled=0 (persisted to ${SYSCTL_FILE})"
    else
        warn "net.mptcp.enabled could not be set at runtime (persisted for next boot)"
    fi
    if [[ "${MPTCP_LISTENERS}" =~ ^[0-9]+$ && "$MPTCP_LISTENERS" -gt 0 ]]; then
        warn "Existing MPTCP listeners stay open – restart these services (ss -lnMp)"
    fi
    if [[ "$DOCKER_MPTCP" -gt 0 ]]; then
        warn "Docker containers are not covered – set GODEBUG=multipathtcp=0 there"
    fi

    # Drop IPv4 TCP packets carrying IP options (header longer than 20 bytes)
    # before anything else sees them. Not vendor-confirmed, but it removes
    # the trigger. Breaks CIPSO labelling (SELinux/Smack NetLabel). Also hits
    # traffic routed through this host, and bridged traffic when
    # br_netfilter is active (Proxmox firewall).
    if command -v nft &>/dev/null; then
        mkdir -p "$(dirname "$NFT_FILE")"
        cat > "$NFT_FILE" <<EOF
# CVE-2026-98432 – set by check-cve --fix, remove once the kernel is patched
# Drops IPv4 TCP packets with IP options (Record Route, Timestamp, ...).
add table ip ${NFT_TABLE}
delete table ip ${NFT_TABLE}
table ip ${NFT_TABLE} {
    chain pre {
        type filter hook prerouting priority -300; policy accept;
        meta l4proto tcp ip hdrlength gt 5 counter drop
    }
}
EOF
        cat > "/etc/systemd/system/${NFT_UNIT}" <<EOF
[Unit]
Description=CVE-2026-98432 mitigation: drop IPv4 TCP with IP options
After=nftables.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${NFT_FILE}
ExecStop=/usr/sbin/nft delete table ip ${NFT_TABLE}

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        if systemctl enable --now "$NFT_UNIT" &>/dev/null && nft list table ip "$NFT_TABLE" &>/dev/null; then
            ok "nftables rule active and persisted (${NFT_UNIT})"
        else
            warn "nftables rule could not be loaded – systemctl status ${NFT_UNIT}"
        fi
    else
        warn "nft not installed – IP options cannot be filtered (apt install nftables)"
    fi

    echo -e "\n${YELLOW}Note: mitigations are not a substitute for a kernel update.${RESET}"
    echo    "  Update system: apt update && apt full-upgrade && reboot"
    echo    "  After the reboot run check-cve --fix again: on a patched kernel it"
    echo    "  prints the commands to remove the mitigation."
fi

# ── JSON output (--json mode) ─────────────────────────────────────────────────
if [[ "$MODE" == "json" ]]; then
    _jstr() { printf '  "%s": "%s"%s\n' "$1" "$(json_escape "$2")" "${3-,}"; }
    _jnum() { printf '  "%s": %s%s\n' "$1" "$2" "${3-,}"; }
    [[ "$MPTCP_LISTENERS" =~ ^[0-9]+$ ]] || MPTCP_LISTENERS=null
    printf '{\n'
    _jstr hostname         "$(hostname -f 2>/dev/null || hostname)"
    _jstr kernel           "$(uname -r)"
    _jstr os               "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo unknown)"
    _jstr checked_at       "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    _jstr container        "$CONTAINER"
    _jstr kernel_package   "${KPKG_NAME:+$KPKG_NAME $KPKG_VER}"
    _jstr CVE_2026_98432   "$STATUS"
    _jstr patch            "$PATCH_STATUS"
    _jnum ipv4_listeners   "$IPV4_LISTENERS"
    _jnum mptcp_listeners  "$MPTCP_LISTENERS"
    _jnum mptcp_listeners_docker "$DOCKER_MPTCP"
    _jstr mptcp_enabled    "$MPTCP_SYSCTL"
    _jstr tcp_migrate_req  "$MIGRATE_REQ"
    _jstr nft_mitigation   "$NFT_MITIGATION"
    _jnum crash_traces     "$CRASH_TRACES"
    _jnum legacy_mitigations "${#LEFTOVERS[@]}" ""
    printf '}\n'
    exit 0
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}============================================================${RESET}"
echo -e "${BOLD} Result: CVE-2026-98432 ${STATUS}${RESET}"
echo -e "${BOLD}------------------------------------------------------------${RESET}"
echo    "  1. Patch the system (the only real fix):"
echo    "       apt update && apt full-upgrade && reboot"
echo    ""
echo    "  2. Until then, mitigate (not vendor-confirmed):"
echo    "       sudo check-cve --fix"
echo    "       Go services: GODEBUG=multipathtcp=0"
echo    ""
echo    "  3. Advisories:"
echo    "       https://security-tracker.debian.org/tracker/CVE-2026-98432"
echo    "       https://ubuntu.com/security/CVE-2026-98432"
echo -e "${BOLD}============================================================${RESET}\n"
