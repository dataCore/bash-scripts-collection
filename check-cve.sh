#!/bin/bash
# =============================================================================
# check-cve – geek.ch Security Check Script
# Repository: https://code.geek.ch/dataCore/bash-scripts-collection
#
# Checks for active exposure to:
#   CVE-2026-31431  "Copy Fail"   – algif_aead kernel module (AF_ALG)
#   CVE-2026-43284  "Dirty Frag"  – esp4 / esp6 (IPsec/xfrm subsystem)
#   CVE-2026-43500  "Dirty Frag"  – rxrpc subsystem
#   CVE-2026-46300  "Fragnesia"   – XFRM ESP-in-TCP (skb_try_coalesce / shared-frag marker)
#   CVE-2026-23268..23411 "CrackArmor" – AppArmor confused-deputy LPE (kernel + util-linux)
#
# Usage:
#   check-cve            # interactive output
#   check-cve --fix      # apply mitigations automatically
#   check-cve --json     # machine-readable JSON output
#
# Advisories:
#   https://ubuntu.com/blog/copy-fail-vulnerability-fixes-available
#   https://www.wiz.io/blog/dirty-frag-linux-kernel-local-privilege-escalation-via-esp-and-rxrpc
#   https://cert.europa.eu/publications/security-advisories/2026-005/
#   https://github.com/v12-security/pocs/tree/main/fragnesia
#   https://almalinux.org/blog/2026-05-13-fragnesia-cve-2026-46300/
#   https://blog.cloudlinux.com/fragnesia-mitigation-and-kernel-update
#   https://ubuntu.com/security/vulnerabilities/crackarmor
#   https://blog.qualys.com/vulnerabilities-threat-research/2026/03/12/crackarmor-critical-apparmor-flaws-enable-local-privilege-escalation-to-root
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
for arg in "$@"; do
    case "$arg" in
        --fix)  MODE="fix"  ;;
        --json) MODE="json" ;;
        -h|--help)
            echo "Usage: $0 [--fix | --json]"
            echo "  (no flag)  Interactive security check"
            echo "  --fix      Apply module-blacklist mitigations"
            echo "  --json     Output results as JSON"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}[OK]${RESET}   $*"; }
warn() { echo -e "  ${RED}[WARN]${RESET} $*"; }
info() { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
miss() { echo -e "  ${YELLOW}[MISS]${RESET} $*"; }

# Collect JSON results
declare -A JSON_FIELDS

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

# ── CVE-2026-31431 – Copy Fail ────────────────────────────────────────────────
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[1/4] CVE-2026-31431 – \"Copy Fail\" (algif_aead / AF_ALG)${RESET}"

COPYFAIL_STATUS="ok"

# 1a. Module loaded right now?
if lsmod 2>/dev/null | grep -q "^algif_aead"; then
    warn "algif_aead is currently LOADED – attack surface active"
    COPYFAIL_STATUS="vulnerable"
else
    ok "algif_aead is not loaded"
fi

# 1b. Built-in or module in running kernel config?
KCONF="/boot/config-$(uname -r)"
if [[ -f "$KCONF" ]]; then
    CF_AEAD=$(grep "^CONFIG_CRYPTO_USER_API_AEAD" "$KCONF" 2>/dev/null || echo "not_found")
    case "$CF_AEAD" in
        *"=y")
            warn "algif_aead is BUILT-IN (=y) – modprobe.d blacklist has no effect!"
            info "  → Workaround: add initcall_blacklist=algif_aead_init to GRUB_CMDLINE_LINUX"
            COPYFAIL_STATUS="vulnerable_builtin"
            ;;
        *"=m")
            info "algif_aead is a module (=m) – modprobe.d blacklist is effective"
            ;;
        *)
            info "CONFIG_CRYPTO_USER_API_AEAD not found in $KCONF"
            ;;
    esac
else
    info "Kernel config not readable ($KCONF)"
fi

# 1c. modprobe.d mitigation set?
if grep -rl "algif_aead" /etc/modprobe.d/ 2>/dev/null | grep -q .; then
    ok "modprobe.d mitigation for algif_aead is in place"
    COPYFAIL_STATUS="${COPYFAIL_STATUS}_mitigated"
else
    miss "No modprobe.d mitigation found for algif_aead"
fi

# 1d. AF_ALG sockets in use?
if command -v lsof &>/dev/null && lsof 2>/dev/null | grep -q "AF_ALG"; then
    warn "AF_ALG sockets are active – check which processes are using them:"
    info "  → lsof | grep AF_ALG"
else
    ok "No active AF_ALG sockets"
fi

JSON_FIELDS[copyfail]="$COPYFAIL_STATUS"

# ── CVE-2026-43284/43500 – Dirty Frag ────────────────────────────────────────
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[2/4] CVE-2026-43284/43500 – \"Dirty Frag\" (esp4 / esp6 / rxrpc)${RESET}"

DIRTYFRAG_STATUS="ok"
LOADED_MODS=()

for mod in esp4 esp6 rxrpc; do
    if lsmod 2>/dev/null | grep -q "^${mod}[[:space:]]"; then
        warn "${mod} is loaded – Dirty Frag attack surface active"
        LOADED_MODS+=("$mod")
        DIRTYFRAG_STATUS="vulnerable"
    else
        ok "${mod} is not loaded"
    fi
done

# Mitigation file present?
if [[ -f /etc/modprobe.d/dirtyfrag.conf ]]; then
    ok "/etc/modprobe.d/dirtyfrag.conf mitigation is in place"
    DIRTYFRAG_STATUS="${DIRTYFRAG_STATUS}_mitigated"
else
    miss "No Dirty Frag modprobe.d mitigation found (/etc/modprobe.d/dirtyfrag.conf)"
fi

# IPsec / OpenVPN warning
IPSEC_ACTIVE=false
if systemctl is-active --quiet 'openvpn*' 2>/dev/null || \
   systemctl is-active --quiet 'openvpn@*' 2>/dev/null || \
   systemctl is-active --quiet strongswan 2>/dev/null || \
   (command -v ip &>/dev/null && ip xfrm state list 2>/dev/null | grep -q "src"); then
    warn "IPsec or OpenVPN detected – disabling esp4/esp6 may break VPN functionality!"
    info "  OpenVPN (UDP/TLS) does NOT require esp4/esp6 – verify and test after mitigation"
    IPSEC_ACTIVE=true
fi

JSON_FIELDS[dirtyfrag]="$DIRTYFRAG_STATUS"
JSON_FIELDS[ipsec_active]="$IPSEC_ACTIVE"

# ── CVE-2026-46300 – Fragnesia ────────────────────────────────────────────────
# Same attack surface as Dirty Frag (esp4/esp6/rxrpc), separate bug.
# Root cause: skb_try_coalesce() loses SKBFL_SHARED_FRAG marker → XFRM
# ESP-in-TCP receive path decrypts AES-GCM in-place over page-cache pages →
# unprivileged write primitive into read-only files (e.g. /usr/bin/su).
# PoC achieves root in a single command; no race condition required.
# Mitigation: identical to Dirty Frag — blacklist esp4/esp6/rxrpc.
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[3/4] CVE-2026-46300 – \"Fragnesia\" (XFRM ESP-in-TCP / skb_try_coalesce)${RESET}"

FRAGNESIA_STATUS="ok"

# 3a. Dirty Frag mitigation file covers Fragnesia too (same modules)
if [[ -f /etc/modprobe.d/fragnesia.conf ]]; then
    ok "/etc/modprobe.d/fragnesia.conf present (dedicated Fragnesia mitigation)"
    FRAGNESIA_STATUS="mitigated_dedicated"
elif [[ -f /etc/modprobe.d/dirtyfrag.conf ]]; then
    ok "/etc/modprobe.d/dirtyfrag.conf covers Fragnesia (same modules: esp4/esp6/rxrpc)"
    FRAGNESIA_STATUS="mitigated_via_dirtyfrag"
else
    miss "No modprobe.d mitigation found for Fragnesia"
    FRAGNESIA_STATUS="not_mitigated"
fi

# 3b. Check if any of the three modules are still loaded despite mitigation
FRAGNESIA_LOADED=()
for mod in esp4 esp6 rxrpc; do
    if lsmod 2>/dev/null | grep -q "^${mod}[[:space:]]"; then
        warn "${mod} is loaded – Fragnesia attack surface active!"
        FRAGNESIA_LOADED+=("$mod")
        FRAGNESIA_STATUS="vulnerable"
    fi
done
if [[ ${#FRAGNESIA_LOADED[@]} -eq 0 ]]; then
    ok "No Fragnesia-relevant modules loaded (esp4, esp6, rxrpc)"
fi

# 3c. ESP-in-TCP ULP activity (Fragnesia-specific trigger path)
if command -v ss &>/dev/null && ss --tcp --no-header 2>/dev/null | grep -qi "espintcp"; then
    warn "espintcp ULP sockets are active – direct Fragnesia trigger path detected!"
    info "  → ss -tnp | grep espintcp"
    FRAGNESIA_STATUS="vulnerable_active"
else
    ok "No active espintcp ULP sockets"
fi

# 3d. Page-cache integrity: check /usr/bin/su against package database
if command -v dpkg &>/dev/null; then
    SU_VERIFY=$(dpkg --verify login 2>/dev/null | grep "usr/bin/su" || true)
    if [[ -n "$SU_VERIFY" ]]; then
        warn "/usr/bin/su checksum mismatch – possible page-cache corruption (PoC exploit)!"
        info "  → dpkg --verify login"
        FRAGNESIA_STATUS="${FRAGNESIA_STATUS}_su_tampered"
    else
        ok "/usr/bin/su checksum matches package (no evidence of PoC exploit)"
    fi
fi

[[ "$MODE" != "json" ]] && info "Advisory: https://almalinux.org/blog/2026-05-13-fragnesia-cve-2026-46300/"

JSON_FIELDS[fragnesia]="$FRAGNESIA_STATUS"

# ── CVE-2026-23268..23411 – CrackArmor ───────────────────────────────────────
# Nine confused-deputy vulnerabilities in the AppArmor Linux Security Module,
# discovered by Qualys TRU. An unprivileged user can open AppArmor policy
# pseudo-files under /sys/kernel/security/apparmor/ and coerce a privileged
# setuid binary (e.g. su, sudo, Postfix) into writing attacker-controlled data
# to them, bypassing all permission checks. Combined with kernel-level parser
# flaws (UAF, OOB reads/writes), this enables:
#   - Full AppArmor policy management (load/replace/remove profiles)
#   - Bypass of unprivileged user-namespace restrictions
#   - Local privilege escalation to root (CVSS 7.8–8.8)
#   - Container isolation bypass
#   - KASLR disclosure via out-of-bounds reads
#
# Affected: all Linux kernels >= 4.11 where AppArmor is enabled (Ubuntu, Debian, SUSE)
# NOT affected: RHEL/CentOS/Rocky/AlmaLinux (use SELinux, not AppArmor)
#
# Fix requires TWO components:
#   1. Patched kernel (AppArmor LSM fixes)
#   2. Patched util-linux / login package (su hardening – closes the deputy path)
#
# No modprobe.d-style mitigation exists. Patch is the only reliable fix.
# Disabling AppArmor entirely would be counterproductive and is NOT recommended.

[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[4/4] CVE-2026-23268..23411 – \"CrackArmor\" (AppArmor / confused-deputy LPE)${RESET}"

CRACKARMOR_STATUS="ok"
CRACKARMOR_APPARMOR="inactive"

# 4a. Is AppArmor active? (Not affected if disabled or SELinux in use)
if command -v aa-status &>/dev/null && aa-status --enabled 2>/dev/null; then
    CRACKARMOR_APPARMOR="active"
    info "AppArmor is enabled – system is in scope for CrackArmor"
elif [[ -d /sys/kernel/security/apparmor ]]; then
    CRACKARMOR_APPARMOR="active"
    info "AppArmor securityfs present – system is in scope for CrackArmor"
else
    ok "AppArmor is not active – system is NOT in scope for CrackArmor"
    CRACKARMOR_STATUS="not_applicable"
fi

# 4b. Only run further checks if AppArmor is active
if [[ "$CRACKARMOR_APPARMOR" == "active" ]]; then

    # 4c. Check if the AppArmor policy interfaces are writable by unprivileged users
    #     On a patched kernel the permissions on .load/.replace/.remove are restricted.
    AA_FS="/sys/kernel/security/apparmor"
    for iface in .load .replace .remove; do
        if [[ -e "${AA_FS}/${iface}" ]]; then
            perms=$(stat -c '%a' "${AA_FS}/${iface}" 2>/dev/null || echo "unknown")
            if [[ "$perms" == "unknown" ]]; then
                miss "  ${AA_FS}/${iface}: cannot read permissions"
            elif [[ "$perms" =~ [2367] ]]; then
                # world-writable or group-writable bit set
                warn "  ${AA_FS}/${iface}: permissions ${perms} – world/group-writable (unpatched kernel)"
                CRACKARMOR_STATUS="vulnerable"
            else
                ok "  ${AA_FS}/${iface}: permissions ${perms} (write-restricted)"
            fi
        fi
    done

    # 4d. Check util-linux / login package version (su hardening)
    #     Patched versions close the deputy path via su by dropping fd inheritance.
    #     Known fixed versions:
    #       Debian 12 bookworm:  util-linux 2.38.1-5+deb12u2 (DSA-XXXX / March 2026)
    #       Debian 13 trixie:    util-linux 2.41-4
    #       Ubuntu 24.04 noble:  util-linux 2.39.3-9ubuntu6.2
    #       Ubuntu 22.04 jammy:  util-linux 2.37.2-4ubuntu3.4
    ULVER=$(dpkg --status util-linux 2>/dev/null | awk '/^Version:/{print $2}')
    if [[ -z "$ULVER" ]]; then
        miss "util-linux package not found – cannot check su hardening"
    else
        info "util-linux installed: ${ULVER}"
        ULFIX=false
        case "${_DISTRO_ID}:${_DISTRO_VER}" in
            debian:bookworm) dpkg --compare-versions "$ULVER" ge "2.38.1-5+deb12u2" 2>/dev/null && ULFIX=true ;;
            debian:trixie|debian:forky) dpkg --compare-versions "$ULVER" ge "2.41-4" 2>/dev/null && ULFIX=true ;;
            debian:sid|debian:unstable) dpkg --compare-versions "$ULVER" ge "2.41-4" 2>/dev/null && ULFIX=true ;;
            ubuntu:noble)  dpkg --compare-versions "$ULVER" ge "2.39.3-9ubuntu6.2" 2>/dev/null && ULFIX=true ;;
            ubuntu:jammy)  dpkg --compare-versions "$ULVER" ge "2.37.2-4ubuntu3.4"  2>/dev/null && ULFIX=true ;;
            ubuntu:focal)  dpkg --compare-versions "$ULVER" ge "2.34-0.1ubuntu9.6"  2>/dev/null && ULFIX=true ;;
            *) miss "  Unknown release – cannot verify util-linux fix version" ;;
        esac
        if [[ "$ULFIX" == "true" ]]; then
            ok "util-linux su hardening patch installed (CrackArmor deputy path blocked)"
        else
            warn "util-linux su hardening NOT installed – CrackArmor deputy path open"
            info "  → apt update && apt install util-linux login"
            [[ "$CRACKARMOR_STATUS" != "vulnerable" ]] && CRACKARMOR_STATUS="partial"
        fi
    fi

    # 4e. Check if sudo is patched (Ubuntu-specific – Debian does not ship sudo fixes)
    if [[ "${_DISTRO_ID}" == "ubuntu" ]] && command -v sudo &>/dev/null; then
        SUDOVER=$(dpkg --status sudo 2>/dev/null | awk '/^Version:/{print $2}')
        if [[ -n "$SUDOVER" ]]; then
            info "sudo installed: ${SUDOVER}"
            SUDOFIX=false
            case "${_DISTRO_VER}" in
                noble)  dpkg --compare-versions "$SUDOVER" ge "1.9.15p5-3ubuntu5.2" 2>/dev/null && SUDOFIX=true ;;
                jammy)  dpkg --compare-versions "$SUDOVER" ge "1.9.9-1ubuntu2.4"    2>/dev/null && SUDOFIX=true ;;
                focal)  dpkg --compare-versions "$SUDOVER" ge "1.8.31-1ubuntu1.5"   2>/dev/null && SUDOFIX=true ;;
            esac
            if [[ "$SUDOFIX" == "true" ]]; then
                ok "sudo CrackArmor patch installed"
            else
                warn "sudo CrackArmor patch NOT installed"
                info "  → apt update && apt install sudo"
                [[ "$CRACKARMOR_STATUS" != "vulnerable" ]] && CRACKARMOR_STATUS="partial"
            fi
        fi
    fi

    [[ "$MODE" != "json" ]] && info "Advisory: https://ubuntu.com/security/vulnerabilities/crackarmor"
fi

JSON_FIELDS[crackarmor]="$CRACKARMOR_STATUS"
JSON_FIELDS[crackarmor_apparmor]="$CRACKARMOR_APPARMOR"
# Strategy (Debian/Ubuntu):
#
# 1. Version comparison against known-fixed package versions (primary, no network).
#    Debian uses dpkg version strings (e.g. 6.1.170-1), Ubuntu uses ABI strings
#    (e.g. 6.8.0-60.62). dpkg --compare-versions handles both correctly.
#
# 2. zgrep on the local changelog as confirmation/fallback:
#    - Debian kernel packages ship changelog.gz (upstream), NOT changelog.Debian.gz
#    - Ubuntu kernel packages ship changelog.Debian.gz
#    Both are tried.
#
# Known fixed versions (Debian stable / Ubuntu LTS):
#   CVE-2026-31431 (Copy Fail):
#     Debian 12 bookworm:  linux 6.1.170-1   (DSA-XXXX)
#     Debian 13 trixie:    linux 6.12.85-1
#     Ubuntu 24.04 noble:  linux 6.8.0-60.62
#     Ubuntu 22.04 jammy:  linux 5.15.0-140.150
#
#   CVE-2026-43284/43500 (Dirty Frag):
#     Debian bookworm:     NOT YET PATCHED in stable (only sid: 7.0.4-1)
#     Debian trixie:       NOT YET PATCHED in stable
#     Ubuntu 24.04:        NOT YET PATCHED
#
#   CVE-2026-46300 (Fragnesia):
#     Debian bookworm:     NOT YET PATCHED (disclosed today)
#     Ubuntu all releases: NOT YET PATCHED (tracker: "needs evaluation")
#
#   CVE-2026-23268..23411 (CrackArmor):
#     Kernel fix committed upstream (7.0-rc4); check done via apparmor fs
#     permissions and util-linux/sudo package version – see section [4/4].
#
# Sources: security-tracker.debian.org, ubuntu.com/security, ostechnix.com

PATCH_COPYFAIL="unknown"
PATCH_DIRTYFRAG="unknown"
PATCH_FRAGNESIA="unknown"

# Get the dpkg version of the running kernel package.
# Returns the version string (e.g. "6.1.170-1") or empty string.
_kernel_pkg_version() {
    local pkgname
    pkgname=$(dpkg --list 2>/dev/null \
        | awk '/^ii[[:space:]]+linux-image-'"$(uname -r | sed 's/[+.]/\\&/g')"'/{print $2}' \
        | head -1)
    [[ -z "$pkgname" ]] && return
    dpkg --status "$pkgname" 2>/dev/null | awk '/^Version:/{print $2}'
}

# Compare installed kernel package version against a known-fixed version.
# Usage: kernel_version_ge <fixed_version>
# Returns 0 (true) if installed >= fixed_version, 1 otherwise, 2 if unknown.
kernel_version_ge() {
    local fixed="$1"
    local installed
    installed=$(_kernel_pkg_version)
    [[ -z "$installed" ]] && return 2
    dpkg --compare-versions "$installed" ge "$fixed" && return 0 || return 1
}

# Search local changelog files (both .gz variants) for a grep pattern.
# Returns "patched", "not_patched", or "" (not found in changelog).
_changelog_grep() {
    local pkgname="$1" pattern="$2"
    local doc_dir="/usr/share/doc/${pkgname}"
    # Debian kernel: changelog.gz (upstream); Ubuntu kernel: changelog.Debian.gz
    for f in "${doc_dir}/changelog.gz" "${doc_dir}/changelog.Debian.gz"; do
        if [[ -f "$f" ]]; then
            if zgrep -qiE "$pattern" "$f" 2>/dev/null; then
                echo "patched"; return
            else
                echo "not_patched"; return
            fi
        fi
    done
    # No local changelog found – try apt-get changelog (requires network)
    local cl
    cl=$(apt-get changelog --no-download-limit "$pkgname" 2>/dev/null || true)
    if [[ -n "$cl" ]]; then
        if echo "$cl" | grep -qiE "$pattern"; then
            echo "patched"
        else
            echo "not_patched"
        fi
    fi
}

# Main check: version comparison first, changelog as confirmation.
# Usage: kernel_patch_check <fixed_version_or_"none"> <changelog_pattern>
# "none" as fixed_version means: no patch available yet for this distro.
kernel_patch_check() {
    local fixed_ver="$1" pattern="$2"
    local installed
    installed=$(_kernel_pkg_version)

    if [[ -z "$installed" ]]; then
        echo "unknown"; return
    fi

    # "none" = explicitly known to be unpatched in all current stable releases
    if [[ "$fixed_ver" == "none" ]]; then
        echo "not_patched"; return
    fi

    # Primary: dpkg version comparison
    if dpkg --compare-versions "$installed" ge "$fixed_ver" 2>/dev/null; then
        echo "patched"; return
    fi

    # Secondary: changelog grep (catches backports with unusual version strings)
    local pkgname
    pkgname=$(dpkg --list 2>/dev/null \
        | awk '/^ii[[:space:]]+linux-image-'"$(uname -r | sed 's/[+.]/\\&/g')"'/{print $2}' \
        | head -1)
    if [[ -n "$pkgname" ]]; then
        local clog_result
        clog_result=$(_changelog_grep "$pkgname" "$pattern")
        if [[ "$clog_result" == "patched" ]]; then
            echo "patched"; return
        elif [[ "$clog_result" == "not_patched" ]]; then
            echo "not_patched"; return
        fi
    fi

    echo "not_patched"
}

# Detect distro family to pick the right fixed version
_DISTRO_ID=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
_DISTRO_VER=$(grep "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

# Select fixed versions based on distro/release
case "${_DISTRO_ID}:${_DISTRO_VER}" in
    debian:bookworm)
        FIXED_COPYFAIL="6.1.170-1"
        FIXED_DIRTYFRAG="none"   # not yet patched in bookworm stable
        FIXED_FRAGNESIA="none"   # not yet patched
        ;;
    debian:trixie|debian:forky)
        FIXED_COPYFAIL="6.12.85-1"
        FIXED_DIRTYFRAG="none"
        FIXED_FRAGNESIA="none"
        ;;
    debian:sid|debian:unstable)
        FIXED_COPYFAIL="7.0.3-1"
        FIXED_DIRTYFRAG="7.0.4-1"
        FIXED_FRAGNESIA="none"   # patch pending as of 2026-05-14
        ;;
    ubuntu:noble)             # 24.04 LTS
        FIXED_COPYFAIL="6.8.0-60.62"
        FIXED_DIRTYFRAG="none"
        FIXED_FRAGNESIA="none"
        ;;
    ubuntu:jammy)             # 22.04 LTS
        FIXED_COPYFAIL="5.15.0-140.150"
        FIXED_DIRTYFRAG="none"
        FIXED_FRAGNESIA="none"
        ;;
    ubuntu:focal)             # 20.04 LTS
        FIXED_COPYFAIL="5.4.0-220.240"
        FIXED_DIRTYFRAG="none"
        FIXED_FRAGNESIA="none"
        ;;
    *)
        # Unknown release – fall back to changelog grep only (no version anchor)
        FIXED_COPYFAIL=""
        FIXED_DIRTYFRAG=""
        FIXED_FRAGNESIA=""
        ;;
esac

if [[ "$MODE" != "json" ]]; then
    echo -e "\n${BOLD}[Patch Status] Kernel: $(uname -r) | Distro: ${_DISTRO_ID:-unknown} ${_DISTRO_VER:-}${RESET}"
    if [[ -f "/boot/vmlinuz-$(uname -r)" ]]; then
        info "Build date  : $(stat -c '%y' "/boot/vmlinuz-$(uname -r)" | cut -d' ' -f1)"
    fi
    _kpkgver=$(_kernel_pkg_version)
    [[ -n "$_kpkgver" ]] && info "Pkg version : ${_kpkgver}"
    info "Checking patch status (version compare + changelog)..."
fi

# CVE-2026-31431 – Copy Fail
# Upstream commit: a664bf3d603d
if [[ -n "$FIXED_COPYFAIL" ]]; then
    PATCH_COPYFAIL=$(kernel_patch_check "$FIXED_COPYFAIL" \
        'a664bf3d603d|CVE-2026-31431|algif_aead.*out-of-place|Revert.*algif_aead')
else
    PATCH_COPYFAIL=$(kernel_patch_check "none" \
        'a664bf3d603d|CVE-2026-31431|algif_aead.*out-of-place|Revert.*algif_aead')
fi
JSON_FIELDS[patch_copyfail]="$PATCH_COPYFAIL"

# CVE-2026-43284/43500 – Dirty Frag
# Upstream commits: e91c6cb57978 / b29d4a88e8ae
if [[ -n "$FIXED_DIRTYFRAG" ]]; then
    PATCH_DIRTYFRAG=$(kernel_patch_check "$FIXED_DIRTYFRAG" \
        'e91c6cb57978|b29d4a88e8ae|CVE-2026-43284|CVE-2026-43500|esp.*in-place.*paged|rxrpc.*in-place.*paged')
else
    PATCH_DIRTYFRAG=$(kernel_patch_check "none" \
        'e91c6cb57978|b29d4a88e8ae|CVE-2026-43284|CVE-2026-43500|esp.*in-place.*paged|rxrpc.*in-place.*paged')
fi
JSON_FIELDS[patch_dirtyfrag]="$PATCH_DIRTYFRAG"

# CVE-2026-46300 – Fragnesia
# Upstream commit: 3f8a2d1c905b
if [[ -n "$FIXED_FRAGNESIA" ]]; then
    PATCH_FRAGNESIA=$(kernel_patch_check "$FIXED_FRAGNESIA" \
        '3f8a2d1c905b|CVE-2026-46300|shared.frag.*coalescing|skb_try_coalesce.*SKBFL_SHARED_FRAG|preserve.*shared.frag')
else
    PATCH_FRAGNESIA=$(kernel_patch_check "none" \
        '3f8a2d1c905b|CVE-2026-46300|shared.frag.*coalescing|skb_try_coalesce.*SKBFL_SHARED_FRAG|preserve.*shared.frag')
fi
JSON_FIELDS[patch_fragnesia]="$PATCH_FRAGNESIA"

# Print patch status with mitigation-removal advice
if [[ "$MODE" != "json" ]]; then
    _patch_line() {
        local cve="$1" status="$2" mitfile="$3"
        case "$status" in
            patched)
                ok "${cve}: kernel fix installed"
                if [[ -n "$mitfile" && -f "$mitfile" ]]; then
                    info "  → Mitigation can be removed:"
                    info "    sudo rm ${mitfile} && sudo update-initramfs -u && sudo reboot"
                fi
                ;;
            not_patched)
                warn "${cve}: no kernel fix found in changelog – keep mitigation in place"
                ;;
            unknown)
                miss "${cve}: changelog not readable – patch status unknown (keep mitigation)"
                ;;
        esac
    }

    _patch_line "CVE-2026-31431 (Copy Fail) " "$PATCH_COPYFAIL" "/etc/modprobe.d/disable-algif.conf"
    _patch_line "CVE-2026-43284/43500 (Dirty Frag)" "$PATCH_DIRTYFRAG" "/etc/modprobe.d/dirtyfrag.conf"
    _patch_line "CVE-2026-46300 (Fragnesia)  " "$PATCH_FRAGNESIA" "/etc/modprobe.d/fragnesia.conf"
    # CrackArmor patch status is shown inline in section [4/4] via apparmor fs + pkg versions
    info "CVE-2026-23268..411 (CrackArmor): see [4/4] section above for per-component status"

    # Fragnesia & Dirty Frag share modules – warn if only one is patched
    if [[ "$PATCH_DIRTYFRAG" == "patched" && "$PATCH_FRAGNESIA" != "patched" ]]; then
        warn "Dirty Frag patched but Fragnesia is not yet – keep esp4/esp6/rxrpc blacklist"
    fi

    # Show available kernel updates
    AVAIL=$(apt list --upgradable 2>/dev/null | grep -i "linux-image" || true)
    if [[ -n "$AVAIL" ]]; then
        warn "Newer kernel available via apt – update recommended:"
        echo "$AVAIL" | while read -r line; do info "    $line"; done
    else
        ok "No newer kernel available via apt (already up to date)"
    fi

    # Ubuntu Pro hint
    if command -v pro &>/dev/null; then
        info "Ubuntu Pro: sudo pro fix CVE-2026-31431  (check livepatch status)"
    fi
fi

# ── Apply mitigations (--fix mode) ───────────────────────────────────────────
if [[ "$MODE" == "fix" ]]; then
    echo -e "\n${BOLD}[--fix] Applying mitigations...${RESET}"

    if [[ "$(id -u)" -ne 0 ]]; then
        echo -e "${RED}Error: --fix requires root privileges (sudo check-cve --fix)${RESET}"
        exit 1
    fi

    # Copy Fail mitigation (only effective if module-based, not built-in)
    if [[ "${CF_AEAD:-}" != *"=y"* ]]; then
        echo "install algif_aead /bin/false" > /etc/modprobe.d/disable-algif.conf
        rmmod algif_aead 2>/dev/null || true
        ok "algif_aead blacklist set (/etc/modprobe.d/disable-algif.conf)"
    else
        warn "algif_aead is built-in – modprobe.d fix skipped (manual GRUB config required)"
        info "  Add 'initcall_blacklist=algif_aead_init' to GRUB_CMDLINE_LINUX"
        info "  Then run: sudo update-grub && sudo reboot"
    fi

    # Dirty Frag mitigation
    printf 'install esp4 /bin/false\ninstall esp6 /bin/false\ninstall rxrpc /bin/false\n' \
        > /etc/modprobe.d/dirtyfrag.conf
    rmmod esp4 esp6 rxrpc 2>/dev/null || true
    ok "Dirty Frag modprobe.d blacklist set (/etc/modprobe.d/dirtyfrag.conf)"

    # Fragnesia mitigation (same modules – create dedicated file for auditability)
    if [[ ! -f /etc/modprobe.d/fragnesia.conf ]]; then
        printf '# CVE-2026-46300 Fragnesia – same surface as Dirty Frag\n' \
            > /etc/modprobe.d/fragnesia.conf
        printf '# Covered by dirtyfrag.conf; this file documents the intent explicitly.\n' \
            >> /etc/modprobe.d/fragnesia.conf
        printf 'install esp4 /bin/false\ninstall esp6 /bin/false\ninstall rxrpc /bin/false\n' \
            >> /etc/modprobe.d/fragnesia.conf
        ok "Fragnesia dedicated mitigation set (/etc/modprobe.d/fragnesia.conf)"
    else
        ok "Fragnesia mitigation already present (/etc/modprobe.d/fragnesia.conf)"
    fi

    if [[ "$IPSEC_ACTIVE" == "true" ]]; then
        warn "IPsec/VPN detected – esp4/esp6 are now disabled. Verify VPN functionality!"
    fi

    echo -e "\n${YELLOW}Note: mitigations are active but not a substitute for kernel updates.${RESET}"
    echo    "  Update system: apt update && apt full-upgrade && reboot"
    echo    "  After reboot: re-run check-cve – if 'patched', mitigations can be removed."
fi

# ── JSON output (--json mode) ─────────────────────────────────────────────────
if [[ "$MODE" == "json" ]]; then
    HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    KERNEL=$(uname -r)
    OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "unknown")
    DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{\n'
    printf '  "hostname": "%s",\n'      "$HOSTNAME"
    printf '  "kernel": "%s",\n'        "$KERNEL"
    printf '  "os": "%s",\n'            "$OS"
    printf '  "checked_at": "%s",\n'    "$DATE"
    printf '  "CVE_2026_31431_copyfail": "%s",\n'  "${JSON_FIELDS[copyfail]}"
    printf '  "CVE_2026_43284_dirtyfrag": "%s",\n' "${JSON_FIELDS[dirtyfrag]}"
    printf '  "CVE_2026_46300_fragnesia": "%s",\n' "${JSON_FIELDS[fragnesia]}"
    printf '  "CVE_2026_23268_crackarmor": "%s",\n' "${JSON_FIELDS[crackarmor]:-unknown}"
    printf '  "crackarmor_apparmor": "%s",\n'       "${JSON_FIELDS[crackarmor_apparmor]:-unknown}"
    printf '  "patch_copyfail": "%s",\n'            "${JSON_FIELDS[patch_copyfail]:-unknown}"
    printf '  "patch_dirtyfrag": "%s",\n'           "${JSON_FIELDS[patch_dirtyfrag]:-unknown}"
    printf '  "patch_fragnesia": "%s",\n'           "${JSON_FIELDS[patch_fragnesia]:-unknown}"
    printf '  "ipsec_active": %s\n'     "${JSON_FIELDS[ipsec_active]}"
    printf '}\n'
    exit 0
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}============================================================${RESET}"
echo -e "${BOLD} Recommendations${RESET}"
echo -e "${BOLD}------------------------------------------------------------${RESET}"
echo    "  1. Patch the system (highest priority):"
echo    "       apt update && apt full-upgrade && reboot"
echo    ""
echo    "  2. Apply immediate mitigations (if not yet patched):"
echo    "       sudo check-cve --fix"
echo    ""
echo    "  3. Copy Fail – PoC / advisory:"
echo    "       https://ubuntu.com/blog/copy-fail-vulnerability-fixes-available"
echo    ""
echo    "  4. Dirty Frag – PoC / advisory:"
echo    "       https://github.com/V4bel/dirtyfrag"
echo    "       https://www.wiz.io/blog/dirty-frag-linux-kernel-local-privilege-escalation-via-esp-and-rxrpc"
echo    ""
echo    "  5. Fragnesia – PoC / advisory:"
echo    "       https://github.com/v12-security/pocs/tree/main/fragnesia"
echo    "       https://almalinux.org/blog/2026-05-13-fragnesia-cve-2026-46300/"
echo    "       https://blog.cloudlinux.com/fragnesia-mitigation-and-kernel-update"
echo    ""
echo    "  6. CrackArmor – advisory (no modprobe mitigation – patch only):"
echo    "       https://ubuntu.com/security/vulnerabilities/crackarmor"
echo    "       https://blog.qualys.com/vulnerabilities-threat-research/2026/03/12/crackarmor-critical-apparmor-flaws-enable-local-privilege-escalation-to-root"
echo    "       apt update && apt install util-linux login sudo"
echo -e "${BOLD}============================================================${RESET}\n"
