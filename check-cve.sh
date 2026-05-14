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
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[1/3] CVE-2026-31431 – \"Copy Fail\" (algif_aead / AF_ALG)${RESET}"

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
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[2/3] CVE-2026-43284/43500 – \"Dirty Frag\" (esp4 / esp6 / rxrpc)${RESET}"

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
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[3/3] CVE-2026-46300 – \"Fragnesia\" (XFRM ESP-in-TCP / skb_try_coalesce)${RESET}"

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

# ── Kernel / Patch status ─────────────────────────────────────────────────────
# Strategy: check the installed kernel package's changelog for the specific
# upstream commit hashes that fix each CVE. More reliable than version string
# comparison since Debian/Ubuntu backport patches into older version numbers
# with different build suffixes (e.g. 6.8.0-58.60 → fix in 6.8.0-60.62).
#
# Upstream fix commits (also referenced by CVE number in Debian/Ubuntu changelogs):
#   CVE-2026-31431  a664bf3d603d  "crypto: algif_aead - Revert to operating out-of-place"
#   CVE-2026-43284  e91c6cb57978  "esp: fix in-place decryption over paged buffers"
#   CVE-2026-43500  b29d4a88e8ae  "rxrpc: fix in-place decryption over paged buffers"
#   CVE-2026-46300  3f8a2d1c905b  "net: skbuff: preserve shared-frag marker during coalescing"

PATCH_COPYFAIL="unknown"
PATCH_DIRTYFRAG="unknown"
PATCH_FRAGNESIA="unknown"

# Helper: search Debian/Ubuntu kernel package changelog for a pattern.
# Returns "patched", "not_patched", or "unknown" (changelog unreadable/missing).
kernel_changelog_check() {
    local pattern="$1"
    local pkgname changelog=""

    pkgname=$(dpkg --list 2>/dev/null \
        | awk '/^ii[[:space:]]+linux-image-'"$(uname -r | sed 's/[+.]/\\&/g')"'/{print $2}' \
        | head -1)

    if [[ -z "$pkgname" ]]; then
        echo "unknown"
        return
    fi

    # 1st: local compressed changelog – fast, no network required
    local clog_gz="/usr/share/doc/${pkgname}/changelog.Debian.gz"
    if [[ -f "$clog_gz" ]]; then
        changelog=$(zcat "$clog_gz" 2>/dev/null || true)
    fi

    # 2nd: apt-get changelog – fetches from mirrors if local copy is absent/empty
    if [[ -z "$changelog" ]]; then
        changelog=$(apt-get changelog --no-download-limit "$pkgname" 2>/dev/null || true)
    fi

    if [[ -z "$changelog" ]]; then
        echo "unknown"
        return
    fi

    if echo "$changelog" | grep -qiE "$pattern"; then
        echo "patched"
    else
        echo "not_patched"
    fi
}

if [[ "$MODE" != "json" ]]; then
    echo -e "\n${BOLD}[Patch Status] Kernel: $(uname -r)${RESET}"
    if [[ -f "/boot/vmlinuz-$(uname -r)" ]]; then
        info "Build date: $(stat -c '%y' "/boot/vmlinuz-$(uname -r)" | cut -d' ' -f1)"
    fi
    info "Checking kernel changelogs for CVE fixes (may take a moment)..."
fi

# CVE-2026-31431 – Copy Fail
PATCH_COPYFAIL=$(kernel_changelog_check 'a664bf3d603d|CVE-2026-31431|algif_aead.*out-of-place|Revert.*algif_aead')
JSON_FIELDS[patch_copyfail]="$PATCH_COPYFAIL"

# CVE-2026-43284 + CVE-2026-43500 – Dirty Frag (two commits, one check)
PATCH_DIRTYFRAG=$(kernel_changelog_check 'e91c6cb57978|b29d4a88e8ae|CVE-2026-43284|CVE-2026-43500|esp.*in-place.*paged|rxrpc.*in-place.*paged')
JSON_FIELDS[patch_dirtyfrag]="$PATCH_DIRTYFRAG"

# CVE-2026-46300 – Fragnesia
PATCH_FRAGNESIA=$(kernel_changelog_check '3f8a2d1c905b|CVE-2026-46300|shared.frag.*coalescing|skb_try_coalesce.*SKBFL_SHARED_FRAG|preserve.*shared.frag')
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
echo -e "${BOLD}============================================================${RESET}\n"
