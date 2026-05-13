#!/bin/bash
# =============================================================================
# check-cve – geek.ch Security Check Script
# Repository: https://code.geek.ch/dataCore/bash-scripts-collection
#
# Checks for active exposure to:
#   CVE-2026-31431  "Copy Fail"   – algif_aead kernel module (AF_ALG)
#   CVE-2026-43284  "Dirty Frag"  – esp4 / esp6 (IPsec/xfrm subsystem)
#   CVE-2026-43500  "Dirty Frag"  – rxrpc subsystem
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
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[1/2] CVE-2026-31431 – \"Copy Fail\" (algif_aead / AF_ALG)${RESET}"

COPYFAIL_STATUS="ok"

# 1a. Module loaded right now?
if lsmod 2>/dev/null | grep -q "^algif_aead"; then
    warn "algif_aead ist aktuell GELADEN – Angriffsfläche aktiv"
    COPYFAIL_STATUS="vulnerable"
else
    ok "algif_aead ist nicht geladen"
fi

# 1b. Built-in or module in running kernel config?
KCONF="/boot/config-$(uname -r)"
if [[ -f "$KCONF" ]]; then
    CF_AEAD=$(grep "^CONFIG_CRYPTO_USER_API_AEAD" "$KCONF" 2>/dev/null || echo "not_found")
    case "$CF_AEAD" in
        *"=y")
            warn "algif_aead ist BUILT-IN (=y) – modprobe.d-Blacklist wirkungslos!"
            info "  → Workaround: initcall_blacklist=algif_aead_init via GRUB/grubby"
            COPYFAIL_STATUS="vulnerable_builtin"
            ;;
        *"=m")
            info "algif_aead als Modul (=m) – modprobe.d-Blacklist greift"
            ;;
        *)
            info "CONFIG_CRYPTO_USER_API_AEAD nicht gefunden in $KCONF"
            ;;
    esac
else
    info "Kernel-Config nicht lesbar ($KCONF)"
fi

# 1c. modprobe.d mitigation set?
if grep -rl "algif_aead" /etc/modprobe.d/ 2>/dev/null | grep -q .; then
    ok "modprobe.d-Mitigation für algif_aead ist gesetzt"
    COPYFAIL_STATUS="${COPYFAIL_STATUS}_mitigated"
else
    miss "Keine modprobe.d-Mitigation für algif_aead gefunden"
fi

# 1d. AF_ALG sockets in use?
if command -v lsof &>/dev/null && lsof 2>/dev/null | grep -q "AF_ALG"; then
    warn "AF_ALG Sockets aktiv – prüfe welche Prozesse sie nutzen:"
    info "  → lsof | grep AF_ALG"
else
    ok "Keine aktiven AF_ALG Sockets"
fi

JSON_FIELDS[copyfail]="$COPYFAIL_STATUS"

# ── CVE-2026-43284/43500 – Dirty Frag ────────────────────────────────────────
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[2/2] CVE-2026-43284/43500 – \"Dirty Frag\" (esp4 / esp6 / rxrpc)${RESET}"

DIRTYFRAG_STATUS="ok"
LOADED_MODS=()

for mod in esp4 esp6 rxrpc; do
    if lsmod 2>/dev/null | grep -q "^${mod}[[:space:]]"; then
        warn "${mod} ist geladen – Dirty Frag Angriffsfläche aktiv"
        LOADED_MODS+=("$mod")
        DIRTYFRAG_STATUS="vulnerable"
    else
        ok "${mod} ist nicht geladen"
    fi
done

# Mitigation file present?
if [[ -f /etc/modprobe.d/dirtyfrag.conf ]]; then
    ok "/etc/modprobe.d/dirtyfrag.conf Mitigation vorhanden"
    DIRTYFRAG_STATUS="${DIRTYFRAG_STATUS}_mitigated"
else
    miss "Keine Dirty Frag modprobe.d-Mitigation gefunden (/etc/modprobe.d/dirtyfrag.conf)"
fi

# IPsec / OpenVPN warning
IPSEC_ACTIVE=false
if systemctl is-active --quiet 'openvpn*' 2>/dev/null || \
   systemctl is-active --quiet 'openvpn@*' 2>/dev/null || \
   systemctl is-active --quiet strongswan 2>/dev/null || \
   (command -v ip &>/dev/null && ip xfrm state list 2>/dev/null | grep -q "src"); then
    warn "IPsec oder OpenVPN erkannt – Deaktivierung von esp4/esp6 kann VPN-Funktion beeinträchtigen!"
    info "  OpenVPN (UDP/TLS) benötigt esp4/esp6 i.d.R. NICHT – prüfen und testen"
    IPSEC_ACTIVE=true
fi

JSON_FIELDS[dirtyfrag]="$DIRTYFRAG_STATUS"
JSON_FIELDS[ipsec_active]="$IPSEC_ACTIVE"

# ── Kernel / Patch status ─────────────────────────────────────────────────────
if [[ "$MODE" != "json" ]]; then
    echo -e "\n${BOLD}[Patch-Status]${RESET}"

    # Build date of running kernel
    if [[ -f "/boot/vmlinuz-$(uname -r)" ]]; then
        info "Kernel-Build-Datum: $(stat -c '%y' "/boot/vmlinuz-$(uname -r)" | cut -d' ' -f1)"
    fi

    # Debian/Ubuntu: available kernel updates
    if command -v apt-get &>/dev/null; then
        AVAIL=$(apt list --upgradable 2>/dev/null | grep -i "linux-image" || true)
        if [[ -n "$AVAIL" ]]; then
            warn "Kernel-Update verfügbar via apt:"
            echo "$AVAIL" | while read -r line; do info "  $line"; done
        else
            ok "Kein neuerer Kernel via apt verfügbar (bereits aktuell oder noch nicht veröffentlicht)"
        fi
        # Ubuntu pro fix check (if available)
        if command -v pro &>/dev/null; then
            info "Ubuntu Pro – CVE-Status prüfen: sudo pro fix CVE-2026-31431"
        fi
    fi
fi

# ── Apply mitigations (--fix mode) ───────────────────────────────────────────
if [[ "$MODE" == "fix" ]]; then
    echo -e "\n${BOLD}[--fix] Wende Mitigationen an...${RESET}"

    if [[ "$(id -u)" -ne 0 ]]; then
        echo -e "${RED}Fehler: --fix benötigt root-Rechte (sudo check-cve-2026 --fix)${RESET}"
        exit 1
    fi

    # Copy Fail mitigation (only useful if module-based)
    if [[ "${CF_AEAD:-}" != *"=y"* ]]; then
        echo "install algif_aead /bin/false" > /etc/modprobe.d/disable-algif.conf
        rmmod algif_aead 2>/dev/null || true
        ok "algif_aead blacklist gesetzt (/etc/modprobe.d/disable-algif.conf)"
    else
        warn "algif_aead ist built-in – modprobe.d-Fix übersprungen (manuell via GRUB nötig)"
        info "  Füge 'initcall_blacklist=algif_aead_init' in GRUB_CMDLINE_LINUX ein"
        info "  Danach: sudo update-grub && sudo reboot"
    fi

    # Dirty Frag mitigation
    printf 'install esp4 /bin/false\ninstall esp6 /bin/false\ninstall rxrpc /bin/false\n' \
        > /etc/modprobe.d/dirtyfrag.conf
    rmmod esp4 esp6 rxrpc 2>/dev/null || true
    ok "Dirty Frag modprobe.d-Blacklist gesetzt (/etc/modprobe.d/dirtyfrag.conf)"

    if [[ "$IPSEC_ACTIVE" == "true" ]]; then
        warn "IPsec/VPN erkannt – esp4/esp6 sind jetzt deaktiviert. VPN-Funktion testen!"
    fi

    echo -e "\n${YELLOW}Hinweis: Mitigationen sind aktiv, aber kein Ersatz für Kernel-Updates.${RESET}"
    echo    "  System updaten: apt update && apt full-upgrade && reboot"
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
    printf '  "ipsec_active": %s\n'     "${JSON_FIELDS[ipsec_active]}"
    printf '}\n'
    exit 0
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}============================================================${RESET}"
echo -e "${BOLD} Empfehlungen${RESET}"
echo -e "${BOLD}------------------------------------------------------------${RESET}"
echo    "  1. System patchen (höchste Priorität):"
echo    "       apt update && apt full-upgrade && reboot"
echo    ""
echo    "  2. Sofort-Mitigation anwenden (falls noch ungepatcht):"
echo    "       sudo check-cve --fix"
echo    ""
echo    "  3. Copy Fail PoC / Info:"
echo    "       https://ubuntu.com/blog/copy-fail-vulnerability-fixes-available"
echo    ""
echo    "  4. Dirty Frag PoC / Info:"
echo    "       https://github.com/V4bel/dirtyfrag"
echo    "       https://www.wiz.io/blog/dirty-frag-linux-kernel-local-privilege-escalation-via-esp-and-rxrpc"
echo -e "${BOLD}============================================================${RESET}\n"
