#!/bin/bash
# =============================================================================
# FIX DOCKER NETWORKS
# by dataCore
#
# Moves a Docker host to the standard address pool 172.16.0.0/16 (networks
# of /24), the pool install-docker.sh sets on new hosts. Hosts installed with
# the install-docker.sh of 2026-05 to 2026-10 derived the pool from the last
# octet of the host IP (172.<octet>.0.0/16); outside 16-31 that is public
# address space. Keycloak, ASP.NET forwarded headers, Traefik trustedIPs and
# the like then treat container traffic as external ("HTTPS required").
#
# The containers are kept as they are: no compose down/up, so image tags,
# variables a pipeline exported at deploy time and stopped containers stay
# untouched. Only the networks are recreated:
#   1. daemon.json: new pool (IPv6 pools and all other keys are kept),
#      bip for docker0, then dockerd restart. Existing networks survive the
#      restart on their old subnets.
#   2. Per network: stop the containers on it, disconnect every endpoint
#      (running or not), remove the network, create it again with the same
#      name, driver, options, labels (compose ones included), internal,
#      attachable and IPv6 subnet, reconnect every endpoint with its aliases.
#   3. Start what was running before, network-mode "container:" ones last.
#
# Migrated: bridge networks with a subnet outside RFC 1918 (always) or, with
# --all, every bridge network outside the target pool.
# Reported, never migrated: networks of compose projects whose files pin a
# "subnet:", networks with static endpoint IPv4 addresses, non-bridge drivers.
# Also reported: references to the old range in /etc and in the compose
# directories (e.g. trustedIPs), which have to be changed by hand.
#
# Usage: fix-dockernet [--all] [--pool <v4-cidr>]   (show the plan)
#        fix-dockernet --apply [--all] [--pool <v4-cidr>]
#        fix-dockernet --resume <state-dir>         (finish an aborted run)
#   --all            also move private pools/networks outside the target pool
#   --pool <cidr>    target pool instead of 172.16.0.0/16
#
# State and backup: /var/backups/fix-dockernet-<timestamp>/
# Takes /run/lock/datacore-docker.lock (shared with backup/update runs).
#
# HISTORY
# 2026-11-25 Initial Version
#
# =============================================================================

set -euo pipefail

LOG_TAG="fix-dockernet"
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

DAEMON_JSON="/etc/docker/daemon.json"
LOCKFILE="/run/lock/datacore-docker.lock"
POOL="172.16.0.0/16"
POOL_SIZE=24

APPLY=false
ALL=false
RESUME=""

usage() {
    awk 'NR==1 {next} /^#/ {started=1; sub(/^# ?/, ""); print; next} started {exit}' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)  APPLY=true ;;
        --all)    ALL=true ;;
        --pool)   [[ $# -ge 2 ]] || die "--pool needs a CIDR"; POOL="$2"; shift ;;
        --resume) [[ $# -ge 2 ]] || die "--resume needs a state directory"; RESUME="$2"; APPLY=true; shift ;;
        -h|--help) usage 0 ;;
        *) err "Unknown option: $1"; usage 1 ;;
    esac
    shift
done

# =============================================================================
# Planning logic in Python (ipaddress, json), called as
#   python3 -c "$NET_PY" <command> [args...]
# Commands:
#   plan <daemon.json> <networks.json> <containers.json> <pool> <size> <all> <routes>
#        print the plan as JSON
#   report <plan.json>              human-readable plan
#   daemon <daemon.json> <plan.json>  print the new daemon.json
#   nets <plan.json>                networks to migrate, one per line
#   create <plan.json> <net>        NUL-separated `docker network create` args
#   endpoints <plan.json> <net>     container ids on <net>, one per line
#   connect <plan.json> <net> <id>  NUL-separated `docker network connect` args
#   stop <plan.json>                containers to stop (running before)
#   start <plan.json>               the same as "<order> <id>": 0 no dependencies,
#                                   1 compose depends_on, 2 network_mode container:
#   refs <plan.json>                grep patterns of the old public ranges
# =============================================================================
read -r -d '' NET_PY <<'PYEOF' || true
import ipaddress, json, os, re, sys

def load(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)

def v4(net):
    for c in net.get("IPAM", {}).get("Config") or []:
        s = c.get("Subnet", "")
        if s and ":" not in s:
            return ipaddress.IPv4Network(s, strict=False)
    return None

def v6(net):
    for c in net.get("IPAM", {}).get("Config") or []:
        s = c.get("Subnet", "")
        if ":" in s:
            return s
    return ""

def plan(daemon_path, nets_path, ctrs_path, pool, size, all_, routes):
    cfg = load(daemon_path, {}) or {}
    nets = load(nets_path, [])
    ctrs = load(ctrs_path, [])
    target = ipaddress.IPv4Network(pool, strict=True)
    p = {"pool": str(target), "size": size, "warnings": [], "skipped": [],
         "migrate": [], "containers": {}, "daemon_change": False, "old_public": []}

    pools = cfg.get("default-address-pools") or []
    v4pools = [x for x in pools if ":" not in x.get("base", "")]
    for x in v4pools:
        n = ipaddress.IPv4Network(x["base"], strict=False)
        if not n.is_private:
            p["old_public"].append(str(n))
    p["pools_before"] = ["%s (/%s)" % (x["base"], x["size"]) for x in v4pools] or ["(Docker default)"]
    pool_ok = len(v4pools) == 1 and ipaddress.IPv4Network(v4pools[0]["base"], strict=False) == target \
        and int(v4pools[0]["size"]) == size
    bridge = next((n for n in nets if n.get("Name") == "bridge"), None)
    docker0 = v4(bridge) if bridge else None
    p["docker0_before"] = str(docker0) if docker0 else ""
    if not pool_ok and (p["old_public"] or all_):
        p["daemon_change"] = True
    if docker0 and not docker0.subnet_of(target) and (not docker0.is_private or all_):
        p["daemon_change"] = True
    if p["daemon_change"]:
        p["bip"] = "%s/%d" % (next(target.hosts()), size)
        # The target pool must not hide a routed network
        types = {"unicast", "local", "broadcast", "blackhole", "unreachable",
                 "prohibit", "throw", "nat", "anycast", "multicast"}
        for line in routes.splitlines():
            tok = line.split()
            if tok and tok[0] in types:
                tok = tok[1:]
            if not tok or tok[0] == "default":
                continue
            dev = tok[tok.index("dev") + 1] if "dev" in tok[:-1] else ""
            if dev in ("docker0", "docker_gwbridge") or dev.startswith("br-"):
                continue
            try:
                dst = ipaddress.IPv4Network(tok[0], strict=False)
            except ValueError:
                continue
            if target.overlaps(dst):
                p.setdefault("overlap", []).append(line.strip())

    # Compose projects whose files pin a subnet
    pinned = set()
    for c in ctrs:
        lab = c.get("Config", {}).get("Labels") or {}
        proj = lab.get("com.docker.compose.project")
        for f in (lab.get("com.docker.compose.project.config_files") or "").split(","):
            try:
                with open(f) as fh:
                    if re.search(r"^\s*(-\s*)?subnet\s*:", fh.read(), re.M):
                        pinned.add(proj)
            except OSError:
                pass

    # Endpoints from the container side: network inspect omits stopped ones
    eps = {}
    for c in ctrs:
        for name, ep in (c.get("NetworkSettings", {}).get("Networks") or {}).items():
            eps.setdefault(name, []).append((c, ep))

    stopset = set()
    for n in nets:
        name = n["Name"]
        if name in ("bridge", "host", "none"):
            continue
        sub = v4(n)
        if sub is None or sub.subnet_of(target):
            continue
        if sub.is_private and not all_:
            continue
        if not sub.is_private and not any(
                sub.subnet_of(ipaddress.IPv4Network(o)) for o in p["old_public"]):
            p["old_public"].append(str(sub))
        reason = ""
        lab = n.get("Labels") or {}
        if n.get("Driver") != "bridge":
            reason = "driver %s" % n.get("Driver")
        elif lab.get("com.docker.compose.project") in pinned:
            reason = "compose project %s pins a subnet" % lab.get("com.docker.compose.project")
        else:
            static = [c["Name"].lstrip("/") for c, ep in eps.get(name, [])
                      if (ep.get("IPAMConfig") or {}).get("IPv4Address")]
            if static:
                reason = "static IPv4 on " + ", ".join(static)
        if reason:
            p["skipped"].append({"name": name, "subnet": str(sub), "reason": reason})
            continue
        m = {"name": name, "subnet": str(sub), "driver": n["Driver"],
             "options": n.get("Options") or {}, "labels": lab,
             "internal": bool(n.get("Internal")), "attachable": bool(n.get("Attachable")),
             "ipv6": bool(n.get("EnableIPv6")), "subnet6": v6(n),
             "ipam_driver": (n.get("IPAM") or {}).get("Driver") or "default",
             "endpoints": []}
        for c, ep in eps.get(name, []):
            cid = c["Id"][:12]
            # Docker adds the container name and short id by itself
            aliases = [a for a in (ep.get("Aliases") or []) if a != cid and a != c["Name"].lstrip("/")]
            m["endpoints"].append({"id": cid, "aliases": aliases,
                                   "ip6": (ep.get("IPAMConfig") or {}).get("IPv6Address") or ""})
            stopset.add(cid)
        p["migrate"].append(m)

    # Containers sharing the network namespace of a stopped one must follow it
    changed = True
    while changed:
        changed = False
        for c in ctrs:
            mode = (c.get("HostConfig") or {}).get("NetworkMode") or ""
            if mode.startswith("container:"):
                parent = mode.split(":", 1)[1]
                if any(c2["Id"].startswith(parent) or c2["Name"].lstrip("/") == parent
                       for c2 in ctrs if c2["Id"][:12] in stopset) and c["Id"][:12] not in stopset:
                    stopset.add(c["Id"][:12])
                    changed = True

    for c in ctrs:
        cid = c["Id"][:12]
        if cid not in stopset:
            continue
        lab = c.get("Config", {}).get("Labels") or {}
        mode = (c.get("HostConfig") or {}).get("NetworkMode") or ""
        order = 2 if mode.startswith("container:") else (1 if lab.get("com.docker.compose.depends_on") else 0)
        p["containers"][cid] = {"name": c["Name"].lstrip("/"), "running": bool(c["State"].get("Running")),
                                "order": order}
    return p

def report(p):
    out = []
    out.append("Pool now:     %s" % ", ".join(p["pools_before"]))
    out.append("docker0 now:  %s" % (p["docker0_before"] or "-"))
    out.append("Target pool:  %s (/%s)" % (p["pool"], p["size"]))
    if p["daemon_change"]:
        out.append("daemon.json:  pool -> %s, bip %s, dockerd restart" % (p["pool"], p["bip"]))
    for o in p.get("overlap", []):
        out.append("OVERLAP:      %s" % o)
    for m in p["migrate"]:
        names = [p["containers"][e["id"]]["name"] for e in m["endpoints"]]
        out.append("MIGRATE:      %-40s %-18s %d endpoint(s): %s" % (m["name"], m["subnet"], len(names), ", ".join(names) or "-"))
    for s in p["skipped"]:
        out.append("SKIP:         %-40s %-18s %s" % (s["name"], s["subnet"], s["reason"]))
    run = [c["name"] for c in p["containers"].values() if c["running"]]
    out.append("Restart:      %d running container(s)" % len(run))
    print("\n".join(out))

def daemon(path, p):
    cfg = load(path, {}) or {}
    v6pools = [x for x in cfg.get("default-address-pools") or [] if ":" in x.get("base", "")]
    cfg["default-address-pools"] = [{"base": p["pool"], "size": p["size"]}] + v6pools
    cfg["bip"] = p["bip"]
    print(json.dumps(cfg, indent=2))

def find(p, name):
    return next(m for m in p["migrate"] if m["name"] == name)

def nul(args):
    sys.stdout.write("\0".join(args) + "\0")

cmd, a = sys.argv[1], sys.argv[2:]
try:
    if cmd == "plan":
        print(json.dumps(plan(a[0], a[1], a[2], a[3], int(a[4]), a[5] == "1", a[6]), indent=1))
    elif cmd == "report":
        report(load(a[0]))
    elif cmd == "daemon":
        daemon(a[0], load(a[1]))
    elif cmd == "nets":
        for m in load(a[0])["migrate"]:
            print(m["name"])
    elif cmd == "create":
        m = find(load(a[0]), a[1])
        args = ["--driver", m["driver"]]
        if m["ipam_driver"] != "default":
            args += ["--ipam-driver", m["ipam_driver"]]
        for k, v in m["options"].items():
            args += ["--opt", "%s=%s" % (k, v)]
        for k, v in m["labels"].items():
            args += ["--label", "%s=%s" % (k, v)]
        if m["internal"]:
            args.append("--internal")
        if m["attachable"]:
            args.append("--attachable")
        if m["ipv6"]:
            args.append("--ipv6")
            if m["subnet6"]:
                args += ["--subnet", m["subnet6"]]
        nul(args + [m["name"]])
    elif cmd == "endpoints":
        for e in find(load(a[0]), a[1])["endpoints"]:
            print(e["id"])
    elif cmd == "connect":
        e = next(e for e in find(load(a[0]), a[1])["endpoints"] if e["id"] == a[2])
        args = []
        for al in e["aliases"]:
            args += ["--alias", al]
        if e["ip6"]:
            args += ["--ip6", e["ip6"]]
        nul(args + [a[1], e["id"]])
    elif cmd == "stop":
        for cid, c in load(a[0])["containers"].items():
            if c["running"]:
                print(cid)
    elif cmd == "start":
        cs = load(a[0])["containers"]
        for cid, c in sorted(cs.items(), key=lambda kv: kv[1]["order"]):
            if c["running"]:
                print(c["order"], cid)
    elif cmd == "refs":
        for o in load(a[0])["old_public"]:
            n = ipaddress.IPv4Network(o)
            octs = str(n.network_address).split(".")
            keep = 2 if n.prefixlen <= 16 else 3
            print(r"\b" + r"\.".join(octs[:keep]) + r"\.")
    else:
        raise ValueError("unknown command " + cmd)
except (ValueError, KeyError, TypeError, IndexError, StopIteration) as e:
    print("%s: %s" % (type(e).__name__, e), file=sys.stderr)
    sys.exit(1)
PYEOF

net_py() { python3 -c "$NET_PY" "$@"; }

# =============================================================================
# Steps
# =============================================================================

snapshot() {  # snapshot <dir>: daemon.json, networks and containers as JSON
    local dir="$1"
    [[ -f "$DAEMON_JSON" ]] && cp -p "$DAEMON_JSON" "${dir}/daemon.json"
    [[ -f "${dir}/daemon.json" ]] || echo '{}' >"${dir}/daemon.json"
    # shellcheck disable=SC2046  # one id per word
    docker network inspect $(docker network ls -q) >"${dir}/networks.json"
    local ids
    ids=$(docker ps -aq)
    if [[ -n "$ids" ]]; then
        # shellcheck disable=SC2086  # one id per word
        docker inspect $ids >"${dir}/containers.json"
    else
        echo '[]' >"${dir}/containers.json"
    fi
}

make_plan() {  # make_plan <dir>
    local dir="$1"
    net_py plan "${dir}/daemon.json" "${dir}/networks.json" "${dir}/containers.json" \
        "$POOL" "$POOL_SIZE" "$($ALL && echo 1 || echo 0)" "$(ip -4 route show)" >"${dir}/plan.json"
}

show_refs() {  # show_refs <dir>: references to the old public ranges
    local dir="$1" pattern dirs
    mapfile -t pattern < <(net_py refs "${dir}/plan.json")
    [[ ${#pattern[@]} -gt 0 ]] || return 0
    local re
    re=$(IFS='|'; echo "${pattern[*]}")
    mapfile -t dirs < <(docker ps -a --format '{{.Label "com.docker.compose.project.working_dir"}}' | sort -u | grep -v '^$' || true)
    local hits
    hits=$(grep -rIlE "$re" /etc "${dirs[@]}" \
        --include='*.yml' --include='*.yaml' --include='*.toml' --include='*.conf' \
        --include='*.json' --include='.env' --include='*.env' --include='*.cfg' 2>/dev/null \
        | grep -vE '^/etc/docker/daemon\.json' | sort -u || true)
    if [[ -n "$hits" ]]; then
        warn "Files that still name the old range (change by hand, e.g. trustedIPs):"
        while IFS= read -r f; do echo "      ${f}"; done <<<"$hits"
    else
        ok "No file in /etc or the compose directories names the old range"
    fi
}

wait_healthy() {  # wait_healthy <id>...: until no healthcheck reports "starting", max 3 min
    local _ id waiting
    for _ in $(seq 1 90); do
        waiting=0
        for id in "$@"; do
            [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null)" == "starting" ]] \
                && waiting=$((waiting + 1))
        done
        (( waiting == 0 )) && return 0
        sleep 2
    done
    warn "${waiting} container(s) still starting after 3 min, going on"
}

restart_docker() {
    systemctl restart docker
    local _
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && return 0
        sleep 2
    done
    die "dockerd did not come back after the restart"
}

migrate_net() {  # migrate_net <dir> <network>
    local dir="$1" net="$2" id
    local -a args
    if [[ -f "${dir}/done.${net}" ]]; then
        ok "${net}: already migrated"
        return 0
    fi
    # Disconnect every endpoint, also of stopped containers
    while IFS= read -r id; do
        docker network disconnect -f "$net" "$id" 2>/dev/null || true
    done < <(net_py endpoints "${dir}/plan.json" "$net")
    if docker network inspect "$net" >/dev/null 2>&1; then
        docker network rm "$net" >/dev/null || die "${net}: cannot remove (still in use?) — fix, then: fix-dockernet --resume ${dir}"
    fi
    mapfile -d '' -t args < <(net_py create "${dir}/plan.json" "$net")
    docker network create "${args[@]}" >/dev/null || die "${net}: create failed — fix, then: fix-dockernet --resume ${dir}"
    while IFS= read -r id; do
        mapfile -d '' -t args < <(net_py connect "${dir}/plan.json" "$net" "$id")
        docker network connect "${args[@]}" || die "${net}: connect ${id} failed — fix, then: fix-dockernet --resume ${dir}"
    done < <(net_py endpoints "${dir}/plan.json" "$net")
    touch "${dir}/done.${net}"
    ok "${net}: $(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$net")"
}

apply_plan() {  # apply_plan <dir>
    local dir="$1" net id
    local -a ids

    if net_py report "${dir}/plan.json" | grep -q '^daemon.json:' && [[ ! -f "${dir}/done.daemon" ]]; then
        print_section "daemon.json and dockerd restart"
        local tmp
        tmp=$(mktemp "${DAEMON_JSON}.XXXXXX")
        net_py daemon "${dir}/daemon.json" "${dir}/plan.json" >"$tmp"
        chmod 644 "$tmp"
        mv "$tmp" "$DAEMON_JSON"
        restart_docker
        touch "${dir}/done.daemon"
        ok "docker0: $(ip -4 -o addr show docker0 | awk '{print $4}')"
    fi

    print_section "Stopping affected containers"
    mapfile -t ids < <(net_py stop "${dir}/plan.json")
    if [[ ${#ids[@]} -gt 0 ]]; then
        docker stop "${ids[@]}" >/dev/null
        ok "Stopped ${#ids[@]} container(s)"
    fi

    print_section "Recreating networks"
    while IFS= read -r net; do
        migrate_net "$dir" "$net"
    done < <(net_py nets "${dir}/plan.json")

    # Compose waits for depends_on: service_healthy, a plain docker start does
    # not. So each level is started, then its containers with a healthcheck
    # get up to 3 min to turn healthy before the next level starts.
    print_section "Starting what was running before"
    local order level started
    for level in 0 1 2; do
        started=()
        while read -r order id; do
            [[ "$order" == "$level" ]] || continue
            if docker start "$id" >/dev/null; then
                started+=("$id")
            else
                err "start failed: $(docker inspect -f '{{.Name}}' "$id" 2>/dev/null || echo "$id")"
            fi
        done < <(net_py start "${dir}/plan.json")
        [[ ${#started[@]} -gt 0 ]] || continue
        wait_healthy "${started[@]}"
        ok "Level ${level}: started ${#started[@]} container(s)"
    done
    touch "${dir}/done.all"
}

verify() {  # verify <dir>
    local dir="$1" id name
    print_section "Check"
    docker network ls -q | xargs docker network inspect \
        --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' | sort -k2 | sed 's/^/      /'
    sleep 20
    while IFS= read -r id; do
        name=$(docker inspect -f '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null || echo "$id missing")
        case "$name" in
            *" running healthy"|*" running starting"|*" running ") ;;
            *) warn "Not running as before: ${name#/}" ;;
        esac
    done < <(net_py stop "${dir}/plan.json")
    show_refs "$dir"
}

# =============================================================================
# Main
# =============================================================================

[[ $EUID -eq 0 ]] || die "Run as root"
command -v docker >/dev/null || die "docker not found"
command -v python3 >/dev/null || die "python3 not found"
docker info >/dev/null 2>&1 || die "dockerd is not running"

print_header "dataCore — Fix Docker Networks"

if [[ -n "$RESUME" ]]; then
    [[ -f "${RESUME}/plan.json" ]] || die "No plan.json in ${RESUME}"
    log_init
    exec 9>"$LOCKFILE"
    flock -w 3600 9 || die "${LOCKFILE} still held by a backup/update run after 1 h"
    info "Resuming ${RESUME}"
    apply_plan "$RESUME"
    verify "$RESUME"
    exit 0
fi

STATE=$(mktemp -d /tmp/fix-dockernet.XXXXXX)
trap 'rm -rf "$STATE"' EXIT
snapshot "$STATE"
make_plan "$STATE"

print_section "Plan"
net_py report "${STATE}/plan.json" | sed 's/^/  /'

if net_py report "${STATE}/plan.json" | grep -q '^OVERLAP:'; then
    die "Target pool ${POOL} overlaps a routed network — pick another with --pool"
fi
if ! net_py report "${STATE}/plan.json" | grep -qE '^(daemon.json|MIGRATE):'; then
    show_refs "$STATE"
    ok "No change"
    exit 0
fi
show_refs "$STATE"

if ! $APPLY; then
    echo ""
    info "Nothing changed. Apply with: fix-dockernet --apply$($ALL && echo ' --all')"
    exit 0
fi

log_init
exec 9>"$LOCKFILE"
flock -w 3600 9 || die "${LOCKFILE} still held by a backup/update run after 1 h"

DIR="/var/backups/fix-dockernet-$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$DIR"
# containers.json holds every container's environment (secrets): not kept
cp -p "${STATE}/daemon.json" "${STATE}/networks.json" "${STATE}/plan.json" "$DIR"/
ok "State and backup: ${DIR}"

if [[ -t 0 ]]; then
    read -r -p "  Restart dockerd and the containers listed above? [yes/NO] " answer
    [[ "$answer" == "yes" ]] || die "Aborted, nothing changed"
fi

apply_plan "$DIR"
verify "$DIR"
ok "Done. Restore of daemon.json if needed: cp ${DIR}/daemon.json ${DAEMON_JSON} && systemctl restart docker"
