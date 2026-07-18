#!/usr/bin/env bash

# =============================================================================
# install-swap.sh — dataCore Swap File Configuration
# =============================================================================
# Usage: install-swap.sh [options]
#
# What this script does:
# 1. Refuse to run inside LXC/OpenVZ containers (swap comes from the host there)
# 2. Detect RAM and derive the target swap size (dataCore sizing rule)
# 3. Report existing swap: file, partitions, LVM volumes
# 4. [--remove-old] Deactivate old swap partitions/LVs and clean up /etc/fstab
# 5. Create (or resize) /pagefile.sys and enable it
# 6. Persist the fstab entry
# 7. Persist vm.swappiness via /etc/sysctl.d (survives reboot)
# 8. [--fix-resume] Clear a stale resume device and rebuild initramfs/grub
#
# Sizing rule (applied when --size is not given):
#   RAM  < 2 GB   ->  2 GB swap
#   RAM 2-8 GB    ->  swap = RAM
#   RAM  > 8 GB   ->  8 GB swap
#
# Options:
#   --size <n>        Swap size, e.g. 8G, 4096M or plain GB number (default: auto)
#   --swappiness <n>  vm.swappiness value (default: 10 = server; desktop is 60)
#   --remove-old      Deactivate old swap partitions / LVs and comment out their
#                     /etc/fstab entries. Does NOT touch the partition table —
#                     the exact fdisk/lvremove commands are printed instead.
#   --fix-resume      Fix "Gave up waiting for suspend/resume device" by
#                     clearing /etc/initramfs-tools/conf.d/resume, then
#                     update-initramfs -u -k all && update-grub
#   --dry-run         Show what would happen, change nothing
#   -h, --help        Show this help
#
# Re-running is safe and idempotent: an existing /pagefile.sys of the right
# size is left alone, a differing size is rebuilt (swapoff -> recreate -> swapon).
#
# Examples:
#   install-swap.sh                          # auto size, server swappiness
#   install-swap.sh --size 4G                # explicit size
#   install-swap.sh --swappiness 60          # desktop tuning
#   install-swap.sh --remove-old             # migrate off an old swap partition
#   install-swap.sh --dry-run
#
# Note on Proxmox containers (LXC): a swap *file* cannot be created inside a
# container. Set the swap on the host instead:
#   pct set <ctid> -swap 2048          # MB, 0 disables swap for the CT
#
# Repository: https://github.com/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

# --------------- Colors -------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --------------- Paths --------------------------------------------------------
SWAPFILE="/pagefile.sys"
FSTAB="/etc/fstab"
SYSCTL_CONF="/etc/sysctl.d/99-swappiness.conf"
RESUME_CONF="/etc/initramfs-tools/conf.d/resume"
LOG_FILE="/var/log/datacore-install.log"

# --------------- Flags & Defaults ---------------------------------------------
OPT_SIZE=""
OPT_SWAPPINESS=10
OPT_REMOVE_OLD=false
OPT_FIX_RESUME=false
OPT_DRY_RUN=false

# Filled in by the detection steps
RAM_MB=0
TARGET_MB=0
CURRENT_MB=0
ROOT_FSTYPE=""
OLD_SWAPS=()
REMOVED_BLOCKDEV=false

# =============================================================================
# Helpers
# =============================================================================
# Tolerate a non-writable log (e.g. an arg error hit as a normal user).
# The writability test has to come first: a failing >> redirect reports to the
# terminal before an inline 2>/dev/null would take effect.
log() {
    [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ) ]] || return 0
    echo "$(date '+%Y-%m-%d %H:%M:%S') [install-swap] $*" >> "$LOG_FILE"
}
print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo " ╔══════════════════════════════════════════════════════════╗"
    echo " ║          dataCore — Swap File Configuration              ║"
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

# Run a command, or just announce it in dry-run mode
run() {
    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} $*"
        return 0
    fi
    log "[RUN] $*"
    "$@"
}

usage() {
    # Print the header comment block only: start at the first comment line
    # after the shebang, stop at the first non-comment line after that.
    awk 'NR==1 {next} /^#/ {started=1; sub(/^# ?/, ""); print; next} started {exit}' "$0"
    exit "${1:-0}"
}

# Human-readable MB
fmt_mb() {
    local mb="$1"
    if (( mb >= 1024 )) && (( mb % 1024 == 0 )); then
        echo "$(( mb / 1024 )) GB"
    else
        echo "${mb} MB"
    fi
}

# Accept 8G / 4096M / 8 (=GB) and return MB
parse_size() {
    local raw="${1^^}"
    case "$raw" in
        *G|*GB) echo $(( ${raw%%G*} * 1024 )) ;;
        *M|*MB) echo "${raw%%M*}" ;;
        *[!0-9]*) die "Invalid --size '$1'. Use e.g. 8G, 4096M or 8." ;;
        *) echo $(( raw * 1024 )) ;;
    esac
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --size)        OPT_SIZE="${2:-}"; shift 2 ;;
            --swappiness)  OPT_SWAPPINESS="${2:-}"; shift 2 ;;
            --remove-old)  OPT_REMOVE_OLD=true; shift ;;
            --fix-resume)  OPT_FIX_RESUME=true; shift ;;
            --dry-run)     OPT_DRY_RUN=true; shift ;;
            -h|--help)     usage 0 ;;
            *) die "Unknown argument: $1 (use --help)" ;;
        esac
    done

    if [[ ! "$OPT_SWAPPINESS" =~ ^[0-9]+$ ]] || (( OPT_SWAPPINESS > 200 )); then
        die "Invalid --swappiness '$OPT_SWAPPINESS' (expected 0-200)."
    fi
}

# =============================================================================
# Step 0 — Environment Check
# =============================================================================
# A swap file needs its own block device access, which a container does not
# have. In Proxmox the CT swap is a host-side cgroup setting, so bailing out
# with the pct command is far more useful than a cryptic mkswap failure.
step_check_environment() {
    print_section "Environment Check"

    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt -c 2>/dev/null || true)"
    fi
    [[ -z "$virt" && -f /proc/1/environ ]] && grep -qa 'container=' /proc/1/environ \
        && virt="container"

    if [[ -n "$virt" && "$virt" != "none" ]]; then
        err "Container detected (${BOLD}${virt}${NC}) — a swap file cannot be created here."
        echo ""
        info "Swap for a container is configured on the Proxmox host:"
        cmd "pct set <ctid> -swap 2048      # MB, 0 disables swap"
        cmd "pct config <ctid> | grep swap  # verify"
        echo ""
        info "The value is applied live; no container restart is needed."
        echo ""
        exit 1
    fi
    ok "Running on bare metal / VM — swap file is supported"

    RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    ok "RAM detected: ${BOLD}$(fmt_mb "$RAM_MB")${NC}"

    local rootfs
    rootfs=$(findmnt -no FSTYPE / 2>/dev/null || echo "unknown")
    info "Root filesystem: ${rootfs}"
    if [[ "$rootfs" == "zfs" ]]; then
        err "Swap files on ZFS can deadlock the kernel under memory pressure."
        echo ""
        info "Use a ZFS volume instead:"
        cmd "zfs create -V 8G -b \$(getconf PAGESIZE) -o compression=zle \\"
        cmd "    -o logbias=throughput -o sync=always \\"
        cmd "    -o primarycache=metadata -o secondarycache=none rpool/swap"
        cmd "mkswap -f /dev/zvol/rpool/swap && swapon /dev/zvol/rpool/swap"
        echo ""
        exit 1
    fi
    ROOT_FSTYPE="$rootfs"
}

# =============================================================================
# Step 1 — Determine Target Size
# =============================================================================
step_determine_size() {
    print_section "Swap Sizing"

    if [[ -n "$OPT_SIZE" ]]; then
        TARGET_MB=$(parse_size "$OPT_SIZE")
        ok "Target size: ${BOLD}$(fmt_mb "$TARGET_MB")${NC} (from --size)"
    else
        # dataCore rule: <2G -> 2G | 2-8G -> RAM | >8G -> 8G
        if   (( RAM_MB < 2048 )); then TARGET_MB=2048
        elif (( RAM_MB <= 8192 )); then TARGET_MB=$RAM_MB
        else TARGET_MB=8192
        fi
        ok "Target size: ${BOLD}$(fmt_mb "$TARGET_MB")${NC} (auto, from $(fmt_mb "$RAM_MB") RAM)"
    fi

    (( TARGET_MB > 0 )) || die "Computed swap size is 0 — check --size."

    # Space check against the filesystem the swap file lives on
    local avail_mb
    avail_mb=$(df -BM --output=avail "$(dirname "$SWAPFILE")" | tail -1 | tr -dc '0-9')
    if [[ -f "$SWAPFILE" ]]; then
        # The existing file's space is reusable
        local existing_mb
        existing_mb=$(( $(stat -c %s "$SWAPFILE") / 1024 / 1024 ))
        avail_mb=$(( avail_mb + existing_mb ))
    fi
    if (( avail_mb < TARGET_MB + 512 )); then
        err "Not enough free space: $(fmt_mb "$avail_mb") available, $(fmt_mb "$TARGET_MB") needed (+512 MB reserve)."
        echo ""
        info "Options: use a smaller --size, or free up an old swap file first"
        info "(this check runs before --remove-old reclaims anything)."
        echo ""
        exit 1
    fi
    ok "Free space OK: $(fmt_mb "$avail_mb") available on $(dirname "$SWAPFILE")"

    local remaining_mb=$(( avail_mb - TARGET_MB ))
    if (( remaining_mb < 2048 )); then
        warn "Only $(fmt_mb "$remaining_mb") left on $(dirname "$SWAPFILE") afterwards — consider a smaller --size."
    fi
}

# =============================================================================
# Step 2 — Inspect Existing Swap
# =============================================================================
step_inspect_existing() {
    print_section "Existing Swap"

    CURRENT_MB=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
    if (( CURRENT_MB == 0 )); then
        info "No swap currently active"
    else
        ok "Active swap total: ${BOLD}$(fmt_mb "$CURRENT_MB")${NC}"
    fi

    # /proc/swaps columns: Filename Type Size Used Priority
    while read -r name type _; do
        [[ "$name" == "Filename" ]] && continue
        if [[ "$name" == "$SWAPFILE" ]]; then
            ok "Managed swap file in use: ${name}"
        elif [[ "$type" == "partition" ]]; then
            warn "Old swap partition active: ${BOLD}${name}${NC}"
            OLD_SWAPS+=("$name")
        else
            warn "Other swap in use: ${name} (${type})"
            OLD_SWAPS+=("$name")
        fi
    done < /proc/swaps

    # fstab entries that are swap but not our file (may be inactive already)
    local dev
    while read -r dev _; do
        [[ "$dev" == "$SWAPFILE" ]] && continue
        # shellcheck disable=SC2076  # literal match is intended here
        if [[ ! " ${OLD_SWAPS[*]:-} " =~ " ${dev} " ]]; then
            warn "Old swap entry in fstab (inactive): ${BOLD}${dev}${NC}"
            OLD_SWAPS+=("$dev")
        fi
    done < <(awk '$3=="swap" && $1 !~ /^#/ {print $1, $2}' "$FSTAB")

    if (( ${#OLD_SWAPS[@]} > 0 )) && [[ "$OPT_REMOVE_OLD" == false ]]; then
        echo ""
        info "Re-run with ${BOLD}--remove-old${NC} to deactivate these and clean up fstab."
    fi
}

# =============================================================================
# Step 3 — Remove Old Swap Devices
# =============================================================================
# Deactivating swap and editing fstab is reversible, so the script does that.
# Writing the partition table is not, so the fdisk/lvremove commands are only
# printed — that stays a deliberate manual step.
step_remove_old() {
    [[ "$OPT_REMOVE_OLD" == true ]] || return 0
    (( ${#OLD_SWAPS[@]} > 0 )) || return 0

    print_section "Removing Old Swap Devices"

    if [[ "$OPT_DRY_RUN" == false ]]; then
        local backup
        backup="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
        cp -a "$FSTAB" "$backup"
        ok "fstab backed up to ${backup}"
    fi

    local dev uuid
    for dev in "${OLD_SWAPS[@]}"; do
        # Deactivate first — an fstab entry alone does not free the device
        if grep -q "^${dev} " /proc/swaps 2>/dev/null; then
            if run swapoff "$dev"; then
                ok "swapoff ${dev}"
            else
                warn "swapoff ${dev} failed — not enough free RAM to absorb it?"
                continue
            fi
        fi

        # An fstab line may reference the device by path or by UUID
        uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
        if [[ "$OPT_DRY_RUN" == true ]]; then
            echo -e "  ${YELLOW}[dry-run]${NC} comment out fstab entry for ${dev}"
        else
            awk -v dev="$dev" -v uuid="${uuid:-__none__}" -v stamp="$(date +%F)" '
                $1 !~ /^#/ && $3 == "swap" && ($1 == dev || $1 == "UUID=" uuid) {
                    print "# [install-swap " stamp "] " $0; next
                }
                { print }
            ' "$FSTAB" > "${FSTAB}.new" && mv "${FSTAB}.new" "$FSTAB"
            ok "fstab entry for ${dev} commented out"
        fi

        # A stray swap *file* (e.g. a distro-installed /swapfile) is just a
        # file — deleting it is safe and reclaims the space immediately.
        if [[ -f "$dev" ]]; then
            run rm -f "$dev"
            ok "Deleted old swap file ${dev}"
            continue
        fi

        # Print — never run — the destructive reclaim step
        REMOVED_BLOCKDEV=true
        echo ""
        if [[ "$(lsblk -no TYPE "$dev" 2>/dev/null | head -1)" == "lvm" ]]; then
            info "To reclaim the LVM volume ${BOLD}${dev}${NC} (destructive, do this manually):"
            cmd "lvremove ${dev}"
            cmd "lvextend -l +100%FREE /dev/mapper/<vg>-root && resize2fs /dev/mapper/<vg>-root"
        else
            info "To reclaim the partition ${BOLD}${dev}${NC} (destructive, do this manually):"
            cmd "fdisk /dev/$(lsblk -no pkname "$dev" 2>/dev/null | head -1)"
            cmd "  p    # print, identify $(basename "$dev")"
            cmd "  d    # delete that partition"
            cmd "  w    # write changes"
            cmd "partprobe   # or reboot"
        fi
    done

    echo ""
    if [[ "$REMOVED_BLOCKDEV" == true ]]; then
        warn "Old swap is deactivated and out of fstab — the partition/LV itself still exists."
    else
        ok "Old swap removed completely"
    fi
}

# =============================================================================
# Step 4 — Create / Resize Swap File
# =============================================================================
step_create_swapfile() {
    print_section "Swap File"

    local target_bytes=$(( TARGET_MB * 1024 * 1024 ))

    if [[ -f "$SWAPFILE" ]]; then
        local current_bytes
        current_bytes=$(stat -c %s "$SWAPFILE")
        if (( current_bytes == target_bytes )) && grep -q "^${SWAPFILE} " /proc/swaps; then
            ok "${SWAPFILE} already exists at $(fmt_mb "$TARGET_MB") and is active — nothing to do"
            return 0
        fi
        info "${SWAPFILE} exists at $(fmt_mb $(( current_bytes / 1024 / 1024 )))— rebuilding to $(fmt_mb "$TARGET_MB")"
        if grep -q "^${SWAPFILE} " /proc/swaps; then
            run swapoff "$SWAPFILE" || die "Could not swapoff ${SWAPFILE} (not enough free RAM?)."
            ok "Deactivated existing swap file"
        fi
        run rm -f "$SWAPFILE"
    fi

    if [[ "$ROOT_FSTYPE" == "btrfs" ]]; then
        # btrfs swap files must be nocow and unallocated-extent-free, so the
        # file has to be created empty, flagged, then written with dd.
        info "btrfs detected — creating swap file nocow (chattr +C)"
        run truncate -s 0 "$SWAPFILE"
        run chattr +C "$SWAPFILE"
        run dd if=/dev/zero of="$SWAPFILE" bs=1M count="$TARGET_MB" status=progress
    elif ! run fallocate -l "${TARGET_MB}M" "$SWAPFILE" 2>/dev/null; then
        warn "fallocate not supported here — falling back to dd (slower)"
        run dd if=/dev/zero of="$SWAPFILE" bs=1M count="$TARGET_MB" status=progress
    fi
    ok "Allocated ${SWAPFILE} ($(fmt_mb "$TARGET_MB"))"

    run chmod 600 "$SWAPFILE"
    run chown root:root "$SWAPFILE"
    ok "Permissions set to 600 root:root"

    run mkswap "$SWAPFILE"
    ok "Swap signature written"

    run swapon "$SWAPFILE"
    ok "Swap file activated"
}

# =============================================================================
# Step 5 — Persist in fstab
# =============================================================================
step_fstab() {
    print_section "Persistence (fstab)"

    if grep -qE "^${SWAPFILE}[[:space:]]" "$FSTAB"; then
        ok "fstab entry already present"
        return 0
    fi

    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} append to ${FSTAB}: ${SWAPFILE} none swap sw 0 0"
        return 0
    fi

    printf '%s\tnone\tswap\tsw\t0\t0\n' "$SWAPFILE" >> "$FSTAB"
    ok "Added to ${FSTAB}: ${SWAPFILE} none swap sw 0 0"

    # A broken fstab makes the next boot drop to an emergency shell — verify now
    if findmnt --verify --verbose >/dev/null 2>&1; then
        ok "fstab verified"
    else
        warn "findmnt --verify reported issues — check ${FSTAB} before rebooting"
    fi
}

# =============================================================================
# Step 6 — Swappiness
# =============================================================================
# The wiki only shows the runtime sysctl, which is lost on reboot. Writing to
# /etc/sysctl.d makes it stick.
step_swappiness() {
    print_section "Swappiness"

    local current
    current=$(cat /proc/sys/vm/swappiness)
    info "Current value: ${current} (target: ${OPT_SWAPPINESS})"

    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} write vm.swappiness=${OPT_SWAPPINESS} to ${SYSCTL_CONF}"
        return 0
    fi

    cat > "$SYSCTL_CONF" <<EOF
# Managed by install-swap.sh — dataCore
# Desktop: 60 (default) | Server: 10
vm.swappiness = ${OPT_SWAPPINESS}
EOF
    ok "Written to ${SYSCTL_CONF} (persists across reboots)"

    sysctl -q -w "vm.swappiness=${OPT_SWAPPINESS}"
    ok "Applied live: vm.swappiness = ${OPT_SWAPPINESS}"
}

# =============================================================================
# Step 7 — Resume Device Fix
# =============================================================================
step_fix_resume() {
    [[ "$OPT_FIX_RESUME" == true ]] || return 0

    print_section "Resume Device Fix"

    info "Fixes: 'Gave up waiting for suspend/resume device' at boot"

    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} clear ${RESUME_CONF}, update-initramfs -u -k all, update-grub"
        return 0
    fi

    mkdir -p "$(dirname "$RESUME_CONF")"
    : > "$RESUME_CONF"
    ok "Cleared ${RESUME_CONF}"

    update-initramfs -u -k all
    ok "initramfs rebuilt"

    if command -v update-grub >/dev/null 2>&1; then
        update-grub
        ok "GRUB config updated"
    else
        info "update-grub not present — skipped (non-GRUB boot?)"
    fi
}

# =============================================================================
# Step 8 — Summary
# =============================================================================
step_summary() {
    print_section "Summary"

    if [[ "$OPT_DRY_RUN" == true ]]; then
        warn "Dry run — nothing was changed."
        echo ""
        return 0
    fi

    echo ""
    swapon --show || true
    echo ""
    free -h
    echo ""

    ok "Swap file:   ${BOLD}${SWAPFILE}${NC} ($(fmt_mb "$TARGET_MB"))"
    ok "Swappiness:  ${BOLD}${OPT_SWAPPINESS}${NC} (persistent via ${SYSCTL_CONF})"
    ok "Persistent:  ${BOLD}${FSTAB}${NC}"
    echo ""
    info "Verify commands:"
    cmd "swapon --show"
    cmd "free -h"
    cmd "cat /proc/sys/vm/swappiness"
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
    echo "=== install-swap.sh === $(date)" >> "$LOG_FILE"

    print_header

    step_check_environment
    step_determine_size
    step_inspect_existing
    step_remove_old
    step_create_swapfile
    step_fstab
    step_swappiness
    step_fix_resume
    step_summary
}

main "$@"
