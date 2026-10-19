#!/usr/bin/env bash
# =============================================================================
# install-docker.sh — dataCore Docker CE Installation
# =============================================================================
# Usage: install-docker.sh [--subnet <v4-cidr>] [--subnet6 <v6-cidr>]
#   --subnet <cidr>   IPv4 address pool, e.g. 10.42.0.0/16 (prefix /24 or
#                     shorter). Required when the last octet of the primary IP
#                     is outside 16-31 and daemon.json has no pools yet.
#   --subnet6 <cidr>  IPv6 fixed-cidr-v6 for docker0. Default: derived from
#                     the IPv4 pool (a.b.x.x -> fd00:a:b::/64).
#   -h, --help        Show this help
#
# What this script does:
#   1. Detect primary IP → derive Docker subnet (last octet), or keep the
#      address pools already in daemon.json
#   2. Install prerequisites + nfs-common
#   3. Add Docker's official apt repository
#   4. Install Docker CE, CLI, containerd, compose plugin — only what is
#      missing; package updates are left to update-system
#   5. Merge our keys into /etc/docker/daemon.json (subnets, IPv6, logging)
#   6. Enable & start Docker — restart only when daemon.json changed or
#      Docker was just installed (live-restore is off, so a restart stops
#      every container)
#   7. Verify installation
#
# Subnet derivation (last octet of primary IP, only 16-31 is RFC1918):
#   192.168.20.25  →  last octet: 25  →  172.25.0.0/16  +  fd00:172:25::/64
#   10.7.0.30      →  last octet: 30  →  172.30.0.0/16  +  fd00:172:30::/64
#   192.168.20.11  →  last octet: 11  →  172.11.0.0/16 is public address
#                     space → aborts unless --subnet is given
# Address pools that already exist in daemon.json are always kept, so the
# networks of an existing host never change.
#
# daemon.json is merged, never replaced: keys set by others (e.g. the fluentd
# log-driver from install-log.sh --docker) are kept. log-driver/log-opts are
# only set when no log-driver is configured yet.
#
# Repository: https://github.com/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

# --------------- Colors -------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --------------- Config -------------------------------------------------------
DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"   # ASCII-armored, no gpg needed
DOCKER_KEYRING_OLD="/etc/apt/keyrings/docker.gpg" # dearmored key of older installs
DOCKER_SOURCE="/etc/apt/sources.list.d/docker.list"
DAEMON_JSON="/etc/docker/daemon.json"
LOG_FILE="/var/log/datacore-install.log"
DOCKER_POOL_SIZE=24

# --------------- Flags & State ------------------------------------------------
OPT_SUBNET=""
OPT_SUBNET6=""
POOLS_EXISTING=false    # daemon.json already defines default-address-pools
APT_UPDATED=false       # apt-get update ran during this invocation
DOCKER_FRESH=false      # docker-ce was installed by this run
DAEMON_CHANGED=false    # daemon.json was written by this run

# =============================================================================
# Helpers
# =============================================================================

# Tolerate a non-writable log (e.g. an arg error hit as a normal user).
log() {
    [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ) ]] || return 0
    echo "$(date '+%Y-%m-%d %H:%M:%S') [install-docker] $*" >> "$LOG_FILE"
}

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

usage() {
    # Print the header comment block only: start at the first comment line
    # after the shebang, stop at the first non-comment line after that.
    awk 'NR==1 {next} /^#/ {started=1; sub(/^# ?/, ""); print; next} started {exit}' "$0"
    exit "${1:-0}"
}

# Fully installed? `dpkg -l` also succeeds for removed packages whose config
# is still on disk (state "rc"), which would skip a needed install.
pkg_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]
}

# Network helpers in Python (ipaddress module), called as
#   python3 -c "$NET_PY" <command> [args...]
# Commands:
#   pools <daemon.json>         print "base size" per default-address-pool
#   key <daemon.json> <key>     print a top-level string value (or nothing)
#   check4 <cidr> <size>        validate an IPv4 pool, print it normalized
#   check6 <cidr>               validate an IPv6 CIDR, print it normalized
#   derive6 <v4-cidr>           a.b.x.x/n -> fd00:a:b::/64 (dataCore scheme)
#   overlap <cidr> <routes>     print every route (ip -4 route) overlapping
#                               <cidr>, ignoring Docker's own bridges
#   example <v4> <size> <v6>    last /<size> block of the v4 pool and a
#                               sibling of the v6 range, for the Traefik hint
#   merge <daemon.json> <v4> <size> <v6>   print daemon.json with our keys
read -r -d '' NET_PY <<'PYEOF' || true
import ipaddress, json, os, sys

def load(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        raise ValueError("top level is not a JSON object")
    return cfg

cmd, args = sys.argv[1], sys.argv[2:]
try:
    if cmd == "pools":
        for p in load(args[0]).get("default-address-pools") or []:
            print(p["base"], p["size"])
    elif cmd == "key":
        v = load(args[0]).get(args[1])
        if isinstance(v, str):
            print(v)
    elif cmd == "check4":
        net = ipaddress.IPv4Network(args[0], strict=True)
        if net.prefixlen > int(args[1]):
            raise ValueError("prefix /%d is longer than the pool size /%s" % (net.prefixlen, args[1]))
        print(net)
        if not net.is_private:
            print("public")
    elif cmd == "check6":
        net = ipaddress.IPv6Network(args[0], strict=True)
        if net.prefixlen > 80:
            raise ValueError("prefix /%d is too long for docker0 (use /80 or shorter)" % net.prefixlen)
        print(net)
    elif cmd == "derive6":
        a, b = str(ipaddress.IPv4Network(args[0]).network_address).split(".")[:2]
        print("fd00:%s:%s::/64" % (a, b))
    elif cmd == "overlap":
        net = ipaddress.IPv4Network(args[0])
        types = {"unicast", "local", "broadcast", "blackhole", "unreachable",
                 "prohibit", "throw", "nat", "anycast", "multicast"}
        for line in args[1].splitlines():
            tok = line.split()
            if tok and tok[0] in types:
                tok = tok[1:]
            if not tok or tok[0] == "default":
                continue
            dev = tok[tok.index("dev") + 1] if "dev" in tok[:-1] else ""
            if dev == "docker0" or dev == "docker_gwbridge" or dev.startswith("br-"):
                continue
            try:
                dst = ipaddress.IPv4Network(tok[0], strict=False)
            except ValueError:
                continue
            if net.overlaps(dst):
                print(line.strip())
    elif cmd == "example":
        v4 = ipaddress.IPv4Network(args[0], strict=False)
        size = int(args[1])
        print(list(v4.subnets(new_prefix=size))[-1] if v4.prefixlen < size else "")
        v6 = ipaddress.IPv6Network(args[2], strict=False) if args[2] else None
        if v6:
            sib = ipaddress.IPv6Network((int(v6.network_address) + 0xff * v6.num_addresses, v6.prefixlen))
            print(sib)
    elif cmd == "merge":
        cfg = load(args[0])
        # Enforced: IPv6 for containers is part of the dataCore baseline
        cfg["ipv6"] = True
        cfg["ip6tables"] = True
        # Only when absent: never move the networks of an existing host and
        # never undo a log-driver set by someone else (install-log.sh --docker)
        # An empty list counts as missing: "pools" saw none and derived one
        if not cfg.get("default-address-pools"):
            cfg["default-address-pools"] = [{"base": args[1], "size": int(args[2])}]
        if not cfg.get("fixed-cidr-v6"):
            cfg["fixed-cidr-v6"] = args[3]
        cfg.setdefault("live-restore", False)
        if "log-driver" not in cfg:
            cfg["log-driver"] = "json-file"
            cfg.setdefault("log-opts", {"max-size": "100m", "max-file": "2"})
        print(json.dumps(cfg, indent=2))
    elif cmd == "norm":
        print(json.dumps(load(args[0]), sort_keys=True))
    else:
        raise ValueError("unknown command " + cmd)
except (ValueError, KeyError, TypeError, IndexError) as e:
    print(e, file=sys.stderr)
    sys.exit(1)
PYEOF

net_py() { python3 -c "$NET_PY" "$@"; }

# Run `apt-get update` but do not abort the whole install if an unrelated
# third-party repository is broken — we verify the packages we actually need
# are available before installing.
apt_update() {
    local errfile="/tmp/datacore-apt-update.$$"
    APT_UPDATED=true
    if apt-get update -qq 2>"$errfile"; then
        rm -f "$errfile"
        return 0
    fi
    warn "apt-get update reported errors — likely a broken third-party repo:"
    grep -E '^(E|W):' "$errfile" | sed 's/^/      /' || sed 's/^/      /' "$errfile"
    rm -f "$errfile"
    return 0
}

# Detect the OS and resolve the upstream Docker repository base.
# Docker only publishes packages for debian and ubuntu, so derivatives such as
# Linux Mint must map to their upstream distro + codename (e.g. Mint 22 -> ubuntu
# noble), NOT the Mint-specific codename like "zena".
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS: /etc/os-release not found"
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    local os_id="${ID:-unknown}"
    local os_codename="${VERSION_CODENAME:-unknown}"
    info "Detected OS: ${os_id} ${VERSION_ID:-?} (${os_codename})"

    case "${os_id}" in
        debian)
            DOCKER_DISTRO="debian"
            DOCKER_CODENAME="${os_codename}"
            ;;
        ubuntu)
            DOCKER_DISTRO="ubuntu"
            DOCKER_CODENAME="${os_codename}"
            ;;
        linuxmint|lmde)
            # Mint ships the upstream codename in os-release:
            #   Ubuntu-based Mint -> UBUNTU_CODENAME=jammy|noble|...
            #   LMDE (Debian)     -> DEBIAN_CODENAME=bookworm|...
            if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
                DOCKER_DISTRO="ubuntu"
                DOCKER_CODENAME="${UBUNTU_CODENAME}"
            elif [[ -n "${DEBIAN_CODENAME:-}" ]]; then
                DOCKER_DISTRO="debian"
                DOCKER_CODENAME="${DEBIAN_CODENAME}"
            elif [[ "${ID_LIKE:-}" == *debian* ]]; then
                DOCKER_DISTRO="debian"
                DOCKER_CODENAME="${os_codename}"
            else
                DOCKER_DISTRO="ubuntu"
                DOCKER_CODENAME="${os_codename}"
            fi
            info "Using ${DOCKER_DISTRO} (${DOCKER_CODENAME}) Docker repository base for ${os_id}"
            ;;
        *)
            die "Unsupported OS '${os_id}' — only Debian, Ubuntu and Linux Mint are supported"
            ;;
    esac
}

# =============================================================================
# Step 0 — Detect IP & Derive Subnets
# =============================================================================

step_detect_network() {
    print_section "Network Detection"

    ensure_python3

    # Primary non-loopback IPv4 address
    PRIMARY_IP=$(ip -4 addr show scope global up \
        | awk '/inet / {print $2}' \
        | head -1 | cut -d/ -f1)

    [[ -n "$PRIMARY_IP" ]] || die "Could not detect a primary IPv4 address. Is the network up?"
    ok "Primary IP:       ${BOLD}${PRIMARY_IP}${NC}"

    # Existing pools win: changing them would move the networks of a host
    # that already runs containers (and break anything pinned to them).
    local pools=""
    if [[ -f "$DAEMON_JSON" ]]; then
        pools=$(net_py pools "$DAEMON_JSON" 2>/dev/null) \
            || die "${DAEMON_JSON} is not valid JSON — fix or remove it, then re-run"
    fi

    local out
    if [[ -n "$pools" ]]; then
        POOLS_EXISTING=true
        read -r DOCKER_SUBNET_V4 DOCKER_POOL_SIZE <<< "$(head -1 <<< "$pools")"
        DOCKER_POOLS_ALL=$(awk '{printf "%s%s (/%s)", (NR>1 ? ", " : ""), $1, $2}' <<< "$pools")
        ok "Keeping the address pools from ${DAEMON_JSON}"
        [[ -z "$OPT_SUBNET" ]] \
            || warn "--subnet ${OPT_SUBNET} ignored — ${DAEMON_JSON} already defines address pools"
    elif [[ -n "$OPT_SUBNET" ]]; then
        out=$(net_py check4 "$OPT_SUBNET" "$DOCKER_POOL_SIZE" 2>&1) \
            || die "Invalid --subnet '${OPT_SUBNET}': ${out}"
        DOCKER_SUBNET_V4=$(head -1 <<< "$out")
        grep -qx public <<< "$out" \
            && warn "--subnet ${DOCKER_SUBNET_V4} is not a private (RFC1918) range"
        DOCKER_POOLS_ALL="${DOCKER_SUBNET_V4} (/${DOCKER_POOL_SIZE})"
    else
        # Last octet → Docker bridge subnet base. 172.16.0.0/12 is the only
        # private range in 172.x, so the scheme only works for octets 16-31.
        local last_octet
        last_octet=$(awk -F. '{print $NF}' <<< "$PRIMARY_IP")
        if (( last_octet < 16 || last_octet > 31 )); then
            err "Last octet ${last_octet} of ${PRIMARY_IP} gives 172.${last_octet}.0.0/16 — public address space, not RFC1918"
            die "The 172.<octet>.0.0/16 scheme only covers octets 16-31. Pick a free private pool and re-run with --subnet <v4-cidr> (e.g. --subnet 10.42.0.0/16)"
        fi
        DOCKER_SUBNET_V4="172.${last_octet}.0.0/16"
        DOCKER_POOLS_ALL="${DOCKER_SUBNET_V4} (/${DOCKER_POOL_SIZE})"
    fi

    # IPv6: keep an existing fixed-cidr-v6, else --subnet6, else derive
    local existing_v6=""
    [[ -f "$DAEMON_JSON" ]] && existing_v6=$(net_py key "$DAEMON_JSON" fixed-cidr-v6)
    if [[ -n "$existing_v6" ]]; then
        DOCKER_SUBNET_V6="$existing_v6"
        [[ -z "$OPT_SUBNET6" ]] \
            || warn "--subnet6 ${OPT_SUBNET6} ignored — ${DAEMON_JSON} already sets fixed-cidr-v6"
    elif [[ -n "$OPT_SUBNET6" ]]; then
        out=$(net_py check6 "$OPT_SUBNET6" 2>&1) \
            || die "Invalid --subnet6 '${OPT_SUBNET6}': ${out}"
        DOCKER_SUBNET_V6="$out"
    else
        DOCKER_SUBNET_V6=$(net_py derive6 "$DOCKER_SUBNET_V4")
    fi

    # A pool that overlaps a routed network makes those hosts unreachable
    # from the containers. Only checked for new pools: existing ones are in
    # use, and Docker's own bridges carry the routes for them.
    if ! $POOLS_EXISTING; then
        local overlap route
        overlap=$(net_py overlap "$DOCKER_SUBNET_V4" "$(ip -4 route show)")
        if [[ -n "$overlap" ]]; then
            err "Docker pool ${DOCKER_SUBNET_V4} overlaps these routes:"
            while IFS= read -r route; do echo "      ${route}"; done <<< "$overlap"
            die "Pick a non-overlapping pool with --subnet <v4-cidr>"
        fi
        ok "No overlap with the routing table"
    fi

    ok "Docker IPv4 pool: ${BOLD}${DOCKER_POOLS_ALL}${NC}"
    ok "Docker IPv6 pool: ${BOLD}${DOCKER_SUBNET_V6}${NC}"
}

# python3 drives the subnet logic and the daemon.json merge
ensure_python3() {
    command -v python3 &>/dev/null && return 0
    info "python3 — will install"
    apt_update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3
    ok "Installed: python3"
}

# =============================================================================
# Step 1 — Prerequisites
# =============================================================================

step_install_prerequisites() {
    print_section "Installing Prerequisites"

    local packages=(
        ca-certificates
        curl
        nfs-common             # NFS volume support for Docker
    )

    local to_install=()
    for pkg in "${packages[@]}"; do
        if pkg_installed "$pkg"; then
            ok "${pkg} already installed"
        else
            to_install+=("$pkg")
            info "${pkg} — will install"
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        apt_update
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}"
        ok "Installed: ${to_install[*]}"
    fi
}

# =============================================================================
# Step 2 — Docker Repository
# =============================================================================

step_add_docker_repo() {
    print_section "Docker APT Repository"

    local arch
    arch=$(dpkg --print-architecture)

    # Desired repository line — derived from the upstream distro/codename so
    # that derivatives like Linux Mint point at the correct Docker repo
    # (e.g. linux/ubuntu noble) instead of a non-existent one (linux/debian zena).
    local desired_line="deb [arch=${arch} signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/${DOCKER_DISTRO} ${DOCKER_CODENAME} stable"

    # Idempotent: if the existing source already matches, keep it.
    if [[ -f "$DOCKER_SOURCE" ]] && grep -qxF "$desired_line" "$DOCKER_SOURCE" \
        && [[ -s "$DOCKER_KEYRING" ]]; then
        ok "Docker repository already configured: ${DOCKER_DISTRO}/${DOCKER_CODENAME} (${arch})"
        return
    fi
    if [[ -f "$DOCKER_SOURCE" ]] && grep -qF "signed-by=${DOCKER_KEYRING_OLD}" "$DOCKER_SOURCE"; then
        info "Migrating the Docker key from ${DOCKER_KEYRING_OLD} to ${DOCKER_KEYRING}"
    elif [[ -f "$DOCKER_SOURCE" ]]; then
        warn "Existing ${DOCKER_SOURCE} differs (wrong distro/codename?) — rewriting"
    fi

    install -m 0755 -d /etc/apt/keyrings

    # Docker's key is ASCII-armored; apt reads it directly from a .asc file,
    # so no gpg --dearmor (and no gnupg package) is needed.
    if [[ ! -s "$DOCKER_KEYRING" ]]; then
        info "Fetching Docker GPG key..."
        curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o "$DOCKER_KEYRING"
        chmod a+r "$DOCKER_KEYRING"
        ok "GPG key saved to ${DOCKER_KEYRING}"
    fi

    echo "$desired_line" > "$DOCKER_SOURCE"
    ok "Repository added: ${DOCKER_DISTRO}/${DOCKER_CODENAME} (${arch})"

    # The old dearmored key is unused once our source points at the .asc —
    # unless another source (e.g. a hand-made docker.sources) still uses it.
    if [[ -f "$DOCKER_KEYRING_OLD" ]]; then
        if grep -rqsF "$DOCKER_KEYRING_OLD" /etc/apt/sources.list /etc/apt/sources.list.d/; then
            info "Keeping ${DOCKER_KEYRING_OLD} — still referenced by another apt source"
        else
            rm -f "$DOCKER_KEYRING_OLD"
            ok "Removed old key ${DOCKER_KEYRING_OLD}"
        fi
    fi

    apt_update
    if ! apt-cache show docker-ce &>/dev/null; then
        die "docker-ce is not available — check the Docker repository for ${DOCKER_DISTRO}/${DOCKER_CODENAME}"
    fi
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

    # Install only what is missing. Upgrading here would restart dockerd (and
    # with it every container) on each re-run; package updates are the job
    # of update-system.
    local missing=()
    for pkg in "${packages[@]}"; do
        pkg_installed "$pkg" || missing+=("$pkg")
    done
    pkg_installed docker-ce || DOCKER_FRESH=true

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "Docker already installed: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',') — updates are left to update-system"
    else
        info "Installing: ${missing[*]}"
        # The repository step skips apt-get update when the source was already
        # in place — the lists may then be stale or missing.
        $APT_UPDATED || apt_update
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
        ok "Docker CE installed: $(docker --version)"
    fi

    # Standalone docker-compose symlink (backwards compat). -L catches a
    # dangling link too, which -e alone reports as missing.
    local compose_link=/usr/local/bin/docker-compose
    if [[ -e "$compose_link" || -L "$compose_link" ]]; then
        ok "docker-compose symlink already exists"
    elif ln -s /usr/libexec/docker/cli-plugins/docker-compose "$compose_link" 2>/dev/null; then
        ok "Symlink created: docker-compose → docker compose plugin"
    else
        warn "Could not create ${compose_link} — use 'docker compose' instead"
    fi
}

# =============================================================================
# Step 4 — daemon.json
# =============================================================================

step_configure_daemon() {
    print_section "Docker Daemon Configuration"

    mkdir -p /etc/docker

    # Merge our keys into the existing file instead of replacing it: other
    # scripts own keys too (install-log.sh --docker sets the fluentd
    # log-driver), and existing address pools must not move.
    local merged
    merged=$(net_py merge "$DAEMON_JSON" "$DOCKER_SUBNET_V4" "$DOCKER_POOL_SIZE" "$DOCKER_SUBNET_V6") \
        || die "Could not merge ${DAEMON_JSON} — is it valid JSON?"

    # Idempotent: only write if content differs (compare JSON semantically,
    # so formatting/whitespace differences don't trigger a rewrite)
    if [[ -f "$DAEMON_JSON" ]]; then
        local merged_norm current_norm
        merged_norm=$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))' <<< "$merged")
        current_norm=$(net_py norm "$DAEMON_JSON")
        if [[ "$current_norm" == "$merged_norm" ]]; then
            ok "daemon.json already up to date — no changes"
            return
        fi
        # Backup existing before overwriting
        cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
        warn "Existing daemon.json differs — backed up and updating"
    fi

    echo "$merged" > "$DAEMON_JSON"
    DAEMON_CHANGED=true
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

    # live-restore is off: a restart stops and restarts every container, so
    # only restart when there is something new to load.
    if $DAEMON_CHANGED || $DOCKER_FRESH; then
        info "Restarting Docker to load ${DAEMON_JSON}..."
        systemctl restart docker
    elif ! systemctl is-active --quiet docker; then
        systemctl start docker
    else
        ok "No changes — Docker not restarted"
    fi

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

    local log_driver
    log_driver=$(net_py key "$DAEMON_JSON" log-driver)
    [[ "$log_driver" == "fluentd" ]] && log_driver+="  (Fluent Bit, install-log.sh --docker)"

    printf "  ${BOLD}%-28s${NC} %s\n" "Primary IP:"       "${PRIMARY_IP}"
    printf "  ${BOLD}%-28s${NC} %s\n" "IPv4 pool:"        "${DOCKER_POOLS_ALL}"
    printf "  ${BOLD}%-28s${NC} %s\n" "IPv6 pool:"        "${DOCKER_SUBNET_V6}"
    printf "  ${BOLD}%-28s${NC} %s\n" "Log driver:"       "${log_driver:-json-file}"
    printf "  ${BOLD}%-28s${NC} %s\n" "daemon.json:"      "${DAEMON_JSON}"
    printf "  ${BOLD}%-28s${NC} %s\n" "nfs-common:"       "installed (NFS volume support)"
    printf "  ${BOLD}%-28s${NC} %s\n" "docker-compose:"   "/usr/local/bin/docker-compose → plugin"
    printf "  ${BOLD}%-28s${NC} %s\n" "Log:"              "${LOG_FILE}"
    echo ""

    # Example subnets from this host's own ranges: the last network of the
    # IPv4 pool (Docker skips subnets already in use when it allocates) and
    # a sibling of fixed-cidr-v6, so neither collides with docker0.
    local example ex_v4 ex_v6
    example=$(net_py example "$DOCKER_SUBNET_V4" "$DOCKER_POOL_SIZE" "$DOCKER_SUBNET_V6" 2>/dev/null) || example=""
    ex_v4=$(sed -n 1p <<< "$example")
    ex_v6=$(sed -n 2p <<< "$example")
    info "Create the traefik_proxy network when setting up Traefik:"
    echo -e "     ${CYAN}docker network create --driver=bridge --ipv6 \\"
    [[ -n "$ex_v4" ]] && echo -e "       --subnet=${ex_v4} \\"
    [[ -n "$ex_v6" ]] && echo -e "       --subnet=${ex_v6} \\"
    echo -e "       traefik_proxy${NC}"
    echo ""
}

# =============================================================================
# Parse Arguments
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subnet|--subnet6)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 needs a value (use --help)"
                if [[ "$1" == "--subnet" ]]; then OPT_SUBNET="$2"; else OPT_SUBNET6="$2"; fi
                shift 2 ;;
            -h|--help)  usage 0 ;;
            *) die "Unknown argument: $1 (use --help)" ;;
        esac
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Parsed before the root check so --help works as a normal user
    parse_args "$@"

    [[ "$EUID" -eq 0 ]] || die "This script must be run as root."

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== install-docker.sh === $(date)" >> "$LOG_FILE"

    print_header
    detect_os
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
