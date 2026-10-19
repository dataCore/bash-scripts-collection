#!/bin/bash
# =============================================================================
# check-cve – geek.ch Security Check Script
# Repository: https://github.com/dataCore/bash-scripts-collection
#
# Checks for active exposure to:
#   CVE-2026-31431  "Copy Fail"   – algif_aead kernel module (AF_ALG)
#   CVE-2026-43284  "Dirty Frag"  – esp4 / esp6 (IPsec/xfrm subsystem)
#   CVE-2026-43500  "Dirty Frag"  – rxrpc subsystem
#   CVE-2026-46300  "Fragnesia"   – XFRM ESP-in-TCP (skb_try_coalesce / shared-frag marker)
#   CVE-2026-23268..23411 "CrackArmor" – AppArmor confused-deputy LPE (kernel + util-linux)
#   CVE-2026-46333  "ptrace mm-NULL" – ptrace_may_access bypass → SSH key + shadow theft
#   (pending)       "CIFSwitch"   – CIFS/cifs.spnego key forgery → NSS module injection → root
#
# Usage:
#   check-cve            # interactive output
#   check-cve --fix      # apply mitigations automatically
#   check-cve --fix --force-ipsec  # also blacklist esp4/esp6 on IPsec hosts
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
#   https://security-tracker.debian.org/tracker/CVE-2026-46333
#   https://github.com/0xdeadbeefnetwork/ssh-keysign-pwn
#   https://heyitsas.im/posts/cifswitch/
#   https://github.com/manizada/CIFSwitch
#   https://kb.wisc.edu/tcd/161613
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
FORCE_IPSEC=false
for arg in "$@"; do
    case "$arg" in
        --fix)  MODE="fix"  ;;
        --json) MODE="json" ;;
        --force-ipsec) FORCE_IPSEC=true ;;
        -h|--help)
            echo "Usage: $0 [--fix [--force-ipsec] | --json]"
            echo "  (no flag)      Interactive security check"
            echo "  --fix          Apply module-blacklist mitigations"
            echo "  --force-ipsec  With --fix: blacklist esp4/esp6 even if IPsec is in use"
            echo "  --json         Output results as JSON"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
# In JSON mode stdout must carry nothing but the JSON document.
ok()   { [[ "$MODE" == "json" ]] && return 0; echo -e "  ${GREEN}[OK]${RESET}   $*"; }
warn() { [[ "$MODE" == "json" ]] && return 0; echo -e "  ${RED}[WARN]${RESET} $*"; }
info() { [[ "$MODE" == "json" ]] && return 0; echo -e "  ${CYAN}[INFO]${RESET} $*"; }
miss() { [[ "$MODE" == "json" ]] && return 0; echo -e "  ${YELLOW}[MISS]${RESET} $*"; }

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

# Loaded kernel modules, read once from /proc/modules. Matching against a
# variable avoids `lsmod | grep -q`, which under pipefail reports a match as
# failure when grep exits early and lsmod dies of SIGPIPE.
PROC_MODULES=""
refresh_modules() { PROC_MODULES=$(cat /proc/modules 2>/dev/null || true); }
module_loaded() { grep -q "^$1 " <<< "$PROC_MODULES"; }
refresh_modules

# Collect JSON results
declare -A JSON_FIELDS

# Detect distro early – needed by both CrackArmor and Patch-Status sections
_DISTRO_ID=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
_DISTRO_VER=$(grep "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

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
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[1/6] CVE-2026-31431 – \"Copy Fail\" (algif_aead / AF_ALG)${RESET}"

COPYFAIL_STATUS="ok"

# 1a. Module loaded right now?
if module_loaded algif_aead; then
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
if grep -rqs "algif_aead" /etc/modprobe.d/; then
    ok "modprobe.d mitigation for algif_aead is in place"
    COPYFAIL_STATUS="${COPYFAIL_STATUS}_mitigated"
else
    miss "No modprobe.d mitigation found for algif_aead"
fi

# 1d. AF_ALG sockets in use?
#     Count instead of `grep -q`: an early grep exit would SIGPIPE lsof and
#     turn a match into a pipefail failure. Non-root only sees own processes.
AFALG_COUNT=0
if command -v lsof &>/dev/null; then
    AFALG_COUNT=$(lsof 2>/dev/null | grep -c "AF_ALG" || true)
fi
if [[ "${AFALG_COUNT:-0}" -gt 0 ]]; then
    warn "AF_ALG sockets are active – check which processes are using them:"
    info "  → lsof | grep AF_ALG"
else
    ok "No active AF_ALG sockets"
fi

JSON_FIELDS[copyfail]="$COPYFAIL_STATUS"

# ── CVE-2026-43284/43500 – Dirty Frag ────────────────────────────────────────
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[2/6] CVE-2026-43284/43500 – \"Dirty Frag\" (esp4 / esp6 / rxrpc)${RESET}"

DIRTYFRAG_STATUS="ok"
LOADED_MODS=()

for mod in esp4 esp6 rxrpc; do
    if module_loaded "$mod"; then
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

# IPsec / OpenVPN detection
# IPsec (kernel xfrm states, strongSwan, Libreswan) needs esp4/esp6; OpenVPN
# does not. 'ip xfrm state' requires CAP_NET_ADMIN, so as non-root only the
# service check applies.
IPSEC_ACTIVE=false
XFRM_STATES=""
if command -v ip &>/dev/null; then
    XFRM_STATES=$(ip xfrm state list 2>/dev/null || true)
fi
if [[ -n "$XFRM_STATES" ]] || \
   systemctl is-active --quiet strongswan 2>/dev/null || \
   systemctl is-active --quiet strongswan-starter 2>/dev/null || \
   systemctl is-active --quiet strongswan-swanctl 2>/dev/null || \
   systemctl is-active --quiet ipsec 2>/dev/null; then
    warn "IPsec in use (xfrm states or strongSwan/Libreswan) – disabling esp4/esp6 breaks IPsec tunnels!"
    info "  --fix keeps esp4/esp6 loadable unless --force-ipsec is given"
    IPSEC_ACTIVE=true
fi
if systemctl is-active --quiet 'openvpn*' 2>/dev/null || \
   systemctl is-active --quiet 'openvpn@*' 2>/dev/null; then
    info "OpenVPN detected – OpenVPN (UDP/TLS) does NOT require esp4/esp6"
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
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[3/6] CVE-2026-46300 – \"Fragnesia\" (XFRM ESP-in-TCP / skb_try_coalesce)${RESET}"

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
    if module_loaded "$mod"; then
        warn "${mod} is loaded – Fragnesia attack surface active!"
        FRAGNESIA_LOADED+=("$mod")
        FRAGNESIA_STATUS="vulnerable"
    fi
done
if [[ ${#FRAGNESIA_LOADED[@]} -eq 0 ]]; then
    ok "No Fragnesia-relevant modules loaded (esp4, esp6, rxrpc)"
fi

# 3c. ESP-in-TCP ULP activity (Fragnesia-specific trigger path)
#     Best-effort: the plain socket list never shows the ULP. With -i, ss
#     prints the ULP name as 'tcp-ulp-<name>' (format string present in
#     iproute2 ss), but the kernel only reports ULP info to CAP_NET_ADMIN,
#     so as non-root this check cannot see espintcp sockets at all.
ESPINTCP_COUNT=0
if command -v ss &>/dev/null; then
    ESPINTCP_COUNT=$(ss -tni 2>/dev/null | grep -c "tcp-ulp-espintcp" || true)
fi
if [[ "${ESPINTCP_COUNT:-0}" -gt 0 ]]; then
    warn "espintcp ULP sockets are active (${ESPINTCP_COUNT}) – direct Fragnesia trigger path detected!"
    info "  → ss -tnip | grep -B1 tcp-ulp-espintcp"
    FRAGNESIA_STATUS="vulnerable_active"
elif [[ "$(id -u)" -ne 0 ]]; then
    miss "espintcp ULP sockets not checked – ULP info requires root"
else
    ok "No active espintcp ULP sockets"
fi

# 3d. Page-cache integrity: check /usr/bin/su against package database
#     su moved from 'login' to 'util-linux' (Debian >= 10), so the owning
#     package is resolved via dpkg -S. On usr-merged systems the dpkg database
#     may record either /usr/bin/su or /bin/su – try both, keep the recorded one.
if command -v dpkg &>/dev/null; then
    SU_PATH=""; SU_PKG=""
    for p in /usr/bin/su /bin/su; do
        SU_PKG=$(dpkg -S "$p" 2>/dev/null \
            | awk -F': ' -v p="$p" '!/^diversion / && $2 == p { split($1, a, ", "); print a[1]; exit }' || true)
        if [[ -n "$SU_PKG" ]]; then
            SU_PATH="$p"
            break
        fi
    done
    if [[ -z "$SU_PKG" ]]; then
        miss "su is not registered in the dpkg database – integrity check skipped"
    else
        SU_VERIFY=$(dpkg --verify "$SU_PKG" 2>/dev/null | awk -v p="$SU_PATH" '$NF == p' || true)
        if [[ -n "$SU_VERIFY" ]]; then
            warn "${SU_PATH} checksum mismatch – possible page-cache corruption (PoC exploit)!"
            info "  → dpkg --verify ${SU_PKG}"
            FRAGNESIA_STATUS="${FRAGNESIA_STATUS}_su_tampered"
        else
            ok "${SU_PATH} checksum matches package ${SU_PKG} (no evidence of PoC exploit)"
        fi
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

[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[4/6] CVE-2026-23268..23411 – \"CrackArmor\" (AppArmor / confused-deputy LPE)${RESET}"

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
            elif (( 8#$perms & 8#022 )); then
                # world-writable or group-writable bit set (owner bits ignored)
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

# ── CVE-2026-46333 – ptrace mm-NULL bypass ────────────────────────────────────
# ptrace_may_access() evaluates the 'dumpability' flag even for threads with a
# NULL mm pointer (kernel threads, zombies). A local unprivileged user can use
# this together with pidfd_getfd() to inherit open file descriptors from
# privileged processes (e.g. ssh-keysign, sshd) and exfiltrate:
#   - SSH host private keys (via ssh-keysign file descriptors)
#   - /etc/shadow contents
# Public PoC available: github.com/0xdeadbeefnetwork/ssh-keysign-pwn
# Fix: commit 31e62c2ebbfd – require CAP_SYS_PTRACE for mm-NULL threads.
# No modprobe.d mitigation. Patch (kernel update) is the only fix.
# DSA-6275-1 (bookworm), DSA-6274-1 (trixie), DLA-4587-1 (bullseye).
[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[5/6] CVE-2026-46333 – ptrace mm-NULL bypass (ssh-keysign / shadow theft)${RESET}"

PTRACE_STATUS="ok"

# 5a. Check if ssh-keysign is installed (primary attack vector)
if [[ -f /usr/lib/openssh/ssh-keysign ]] || [[ -f /usr/libexec/openssh/ssh-keysign ]]; then
    info "ssh-keysign is installed – attack vector present"
    PTRACE_STATUS="exposed"
else
    ok "ssh-keysign not found – primary PoC attack vector not present"
fi

# 5b. Check if sshd is running (secondary indicator)
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    info "sshd is running – SSH host keys are in scope"
fi

# 5c. Check /etc/shadow readability as indicator of exploit success
#     (readable by root only; world-readable would indicate compromise)
if [[ -f /etc/shadow ]]; then
    SHADOW_PERMS=$(stat -c '%a' /etc/shadow 2>/dev/null || echo "unknown")
    if [[ "$SHADOW_PERMS" =~ ^[0-9]*[1-7]$ ]]; then
        warn "/etc/shadow has unexpected permissions (${SHADOW_PERMS}) – possible tampering!"
    else
        ok "/etc/shadow permissions look correct (${SHADOW_PERMS})"
    fi
fi

[[ "$MODE" != "json" ]] && info "PoC: https://github.com/0xdeadbeefnetwork/ssh-keysign-pwn"
[[ "$MODE" != "json" ]] && info "DSA: https://security-tracker.debian.org/tracker/CVE-2026-46333"

JSON_FIELDS[ptrace_mmnull]="$PTRACE_STATUS"

# ── CIFSwitch – CIFS/cifs.spnego key forgery ─────────────────────────────────
# Disclosed 2026-05-28 by Asim Manizada (SpaceX). CVE pending.
# A logic flaw between kernel CIFS and the userspace cifs-utils helper:
#   The cifs.spnego key type does not validate that the key description
#   originates from kernel CIFS. An attacker can call request_key() with
#   a forged description, causing the root-privileged cifs.upcall helper
#   to switch into an attacker-controlled mount namespace, trigger an NSS
#   lookup before privilege drop, and load a malicious libnss_*.so.2 →
#   arbitrary code execution as root. No race condition required.
#
# Requirements for exploitation (ALL must be true):
#   1. cifs.ko kernel module loaded
#   2. cifs-utils package installed (provides /usr/sbin/cifs.upcall)
#   3. Unprivileged user namespaces enabled (kernel.unprivileged_userns_clone=1)
#
# Known affected: Ubuntu 20.04/22.04/24.04, Debian 11/12/13, SUSE Leap 15.x
# NOT affected: RHEL/CentOS/Rocky/AlmaLinux (cifs.upcall not present by default)
#
# Mitigations (in order of preference):
#   1. Kernel + cifs-utils package update (upstream patch: commit 3da1fdf4efbc)
#   2. Disable unprivileged user namespaces (sysctl kernel.unprivileged_userns_clone=0)
#   3. Remove cifs-utils if Kerberos CIFS mounts not required
#
# Advisory: https://heyitsas.im/posts/cifswitch/
# PoC:      https://github.com/manizada/CIFSwitch

[[ "$MODE" != "json" ]] && echo -e "\n${BOLD}[6/6] CIFSwitch (pending CVE) – CIFS/cifs.spnego key forgery → root${RESET}"

CIFSWITCH_STATUS="ok"

# 6a. Is cifs.ko loaded?
CIFS_LOADED=false
if module_loaded cifs; then
    warn "cifs module is LOADED – kernel attack surface present"
    CIFS_LOADED=true
    CIFSWITCH_STATUS="cifs_loaded"
else
    ok "cifs module is not loaded"
fi

# 6b. Is cifs.upcall (from cifs-utils) installed?
CIFSUTILS_INSTALLED=false
CIFS_UPCALL=""
for p in /usr/sbin/cifs.upcall /sbin/cifs.upcall; do
    if [[ -f "$p" ]]; then
        CIFS_UPCALL="$p"
        CIFSUTILS_INSTALLED=true
        break
    fi
done

if [[ "$CIFSUTILS_INSTALLED" == "true" ]]; then
    warn "cifs.upcall found at ${CIFS_UPCALL} – root-privileged helper is present"
    CIFSWITCH_STATUS="${CIFSWITCH_STATUS}+upcall"
    # Show installed version for awareness
    CIFSU_VER=$(dpkg --status cifs-utils 2>/dev/null | awk '/^Version:/{print $2}' || true)
    [[ -n "$CIFSU_VER" ]] && info "cifs-utils version: ${CIFSU_VER}"
else
    ok "cifs.upcall not found – root-privileged helper absent (not exploitable)"
fi

# 6c. Unprivileged user namespaces enabled?
#     kernel.unprivileged_userns_clone is a Debian/Ubuntu kernel patch. Other
#     kernels only have user.max_user_namespaces (0 = no new user namespaces).
USERNS_ENABLED=false
USERNS_SYSCTL="kernel.unprivileged_userns_clone"
USERNS_VAL=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || \
             cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo "unknown")
USERNS_SHOWN="$USERNS_VAL"
if [[ "$USERNS_VAL" == "unknown" ]]; then
    MAXNS=$(sysctl -n user.max_user_namespaces 2>/dev/null || \
            cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo "unknown")
    if [[ "$MAXNS" =~ ^[0-9]+$ ]]; then
        USERNS_SYSCTL="user.max_user_namespaces"
        USERNS_SHOWN="$MAXNS"
        if (( MAXNS > 0 )); then USERNS_VAL=1; else USERNS_VAL=0; fi
    fi
fi
if [[ "$USERNS_VAL" == "1" ]]; then
    warn "${USERNS_SYSCTL}=${USERNS_SHOWN} – namespace switch attack path OPEN"
    USERNS_ENABLED=true
    CIFSWITCH_STATUS="${CIFSWITCH_STATUS}+userns"
elif [[ "$USERNS_VAL" == "0" ]]; then
    ok "${USERNS_SYSCTL}=0 – namespace attack path BLOCKED"
    CIFSWITCH_STATUS="${CIFSWITCH_STATUS}_userns_blocked"
else
    miss "Neither kernel.unprivileged_userns_clone nor user.max_user_namespaces readable"
fi

# 6d. Full exploitability summary
if [[ "$CIFS_LOADED" == "true" && "$CIFSUTILS_INSTALLED" == "true" && "$USERNS_ENABLED" == "true" ]]; then
    warn "ALL THREE conditions met – system is FULLY EXPOSED to CIFSwitch!"
    warn "  Apply mitigation immediately: sudo check-cve --fix"
    CIFSWITCH_STATUS="VULNERABLE"
elif [[ "$CIFSUTILS_INSTALLED" == "true" && "$USERNS_ENABLED" == "true" && "$CIFS_LOADED" == "false" ]]; then
    warn "cifs.upcall + userns present – exploitable if cifs module is loaded (e.g. via mount)"
    info "  → cifs module auto-loads on 'mount -t cifs'; mitigation recommended"
    CIFSWITCH_STATUS="at_risk_on_mount"
elif [[ "$CIFSWITCH_STATUS" == "ok" ]]; then
    ok "No exploitable CIFSwitch condition detected"
fi

# 6e. Active CIFS mounts (informational)
ACTIVE_CIFS=$(mount 2>/dev/null | grep -c "type cifs" || true)
if [[ "$ACTIVE_CIFS" -gt 0 ]]; then
    info "Active CIFS mounts: ${ACTIVE_CIFS} – cifs module will remain loaded"
    if [[ "$MODE" != "json" ]]; then
        mount 2>/dev/null | grep "type cifs" | awk '{print "    "$0}' || true
    fi
fi

# 6f. Check if sysctl mitigation is already persisted
if grep -rqsE "^[[:space:]]*${USERNS_SYSCTL//./[./]}[[:space:]]*=[[:space:]]*0[[:space:]]*$" \
        /etc/sysctl.d/ /etc/sysctl.conf; then
    ok "${USERNS_SYSCTL}=0 is persisted in sysctl.d"
else
    if [[ "$USERNS_ENABLED" == "true" ]]; then
        miss "No persistent sysctl mitigation found for ${USERNS_SYSCTL}"
    fi
fi

[[ "$MODE" != "json" ]] && info "Advisory: https://heyitsas.im/posts/cifswitch/"

JSON_FIELDS[cifswitch]="$CIFSWITCH_STATUS"
JSON_FIELDS[cifswitch_userns]="$USERNS_ENABLED"
JSON_FIELDS[cifswitch_upcall]="$CIFSUTILS_INSTALLED"

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
#     permissions and util-linux/sudo package version – see section [4/5].
#
#   CVE-2026-46333 (ptrace mm-NULL):
#     Debian 12 bookworm:  linux 6.1.172-1   (DSA-6275-1)
#     Debian 13 trixie:    linux 6.12.88-1   (DSA-6274-1)
#     Debian 11 bullseye:  linux 5.10.251-5  (DLA-4587-1)
#     Ubuntu 24.04 noble:  linux 6.8.0-63.66 (USN-XXXX)
#     Ubuntu 22.04 jammy:  linux 5.15.0-142.152
#
# Sources: security-tracker.debian.org, ubuntu.com/security, ostechnix.com

PATCH_COPYFAIL="unknown"
PATCH_DIRTYFRAG="unknown"
PATCH_FRAGNESIA="unknown"
PATCH_CIFSWITCH="unknown"

# Running kernel package, resolved once via the owner of the kernel image.
# Matching 'linux-image-$(uname -r)' misses Proxmox (proxmox-kernel-*,
# pve-kernel-*) and any other naming scheme.
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

# Main check: version comparison first, changelog as confirmation.
# Usage: kernel_patch_check <result_var> <fixed_version_or_"none"> <changelog_pattern>
# "none" as fixed_version means: no patch available yet for this distro.
# Result: patched | not_patched | not_tracked | unknown
kernel_patch_check() {
    local -n _result="$1"
    local fixed_ver="$2" pattern="$3"

    if [[ -z "$KPKG_VER" ]]; then
        _result="unknown"; return 0
    fi

    # Debian/Ubuntu fixed versions do not apply to Proxmox kernel packages
    if [[ "$KPKG_FLAVOUR" == "proxmox" ]]; then
        _result="not_tracked"; return 0
    fi

    # "none" = explicitly known to be unpatched in all current stable releases
    if [[ "$fixed_ver" == "none" ]]; then
        _result="not_patched"; return 0
    fi

    # Primary: dpkg version comparison
    if dpkg --compare-versions "$KPKG_VER" ge "$fixed_ver" 2>/dev/null; then
        _result="patched"; return 0
    fi

    # Secondary: changelog grep (catches backports with unusual version strings)
    _kernel_changelog_load
    if [[ "$KCHANGELOG_STATE" == "loaded" ]] && grep -qiE "$pattern" "$KCHANGELOG"; then
        _result="patched"; return 0
    fi

    _result="not_patched"
}

# Select fixed versions based on distro/release
case "${_DISTRO_ID}:${_DISTRO_VER}" in
    debian:bookworm)
        FIXED_COPYFAIL="6.1.170-1"
        FIXED_DIRTYFRAG="none"
        FIXED_FRAGNESIA="none"
        FIXED_PTRACE="6.1.172-1"    # DSA-6275-1
        FIXED_CIFSWITCH="6.1.173-1" # cifs.spnego origin validation; cifs-utils >= 7.0-1+deb12u2
        ;;
    debian:trixie|debian:forky)
        FIXED_COPYFAIL="6.12.85-1"
        FIXED_DIRTYFRAG="none"
        FIXED_FRAGNESIA="none"
        FIXED_PTRACE="6.12.88-1"    # DSA-6274-1
        FIXED_CIFSWITCH="6.12.90-1" # upstream commit 3da1fdf4efbc queued for stable
        ;;
    debian:sid|debian:unstable)
        FIXED_COPYFAIL="7.0.3-1"
        FIXED_DIRTYFRAG="7.0.4-1"
        FIXED_FRAGNESIA="none"
        FIXED_PTRACE="7.0.7-1"
        FIXED_CIFSWITCH="7.0.8-1"
        ;;
    ubuntu:noble)
        FIXED_COPYFAIL="6.8.0-60.62"
        FIXED_DIRTYFRAG="none"
        FIXED_FRAGNESIA="none"
        FIXED_PTRACE="6.8.0-63.66"
        FIXED_CIFSWITCH="6.8.0-64.67"
        ;;
    ubuntu:jammy)
        FIXED_COPYFAIL="5.15.0-140.150"
        FIXED_DIRTYFRAG="none"
        FIXED_FRAGNESIA="none"
        FIXED_PTRACE="5.15.0-142.152"
        FIXED_CIFSWITCH="5.15.0-143.153"
        ;;
    ubuntu:focal)
        FIXED_COPYFAIL="5.4.0-220.240"
        FIXED_DIRTYFRAG="none"
        FIXED_FRAGNESIA="none"
        FIXED_PTRACE="5.4.0-222.242"
        FIXED_CIFSWITCH="5.4.0-223.243"
        ;;
    *)
        FIXED_COPYFAIL=""
        FIXED_DIRTYFRAG=""
        FIXED_FRAGNESIA=""
        FIXED_PTRACE=""
        FIXED_CIFSWITCH=""
        ;;
esac

if [[ "$MODE" != "json" ]]; then
    echo -e "\n${BOLD}[Patch Status] Kernel: $(uname -r) | Distro: ${_DISTRO_ID:-unknown} ${_DISTRO_VER:-}${RESET}"
    if [[ -f "/boot/vmlinuz-$(uname -r)" ]]; then
        info "Build date  : $(stat -c '%y' "/boot/vmlinuz-$(uname -r)" | cut -d' ' -f1)"
    fi
    if [[ -n "$KPKG_VER" ]]; then
        info "Package     : ${KPKG_NAME} ${KPKG_VER}"
    else
        miss "Running kernel image is not owned by a dpkg package – patch status unknown"
    fi
    if [[ "$KPKG_FLAVOUR" == "proxmox" ]]; then
        info "Proxmox kernel – Debian/Ubuntu fixed versions do not apply; patch status is not tracked"
        info "  → check the Proxmox VE changelog / security advisories for this kernel"
    else
        info "Checking patch status (version compare + changelog)..."
    fi
fi

# CVE-2026-31431 – Copy Fail
# Upstream commit: a664bf3d603d
kernel_patch_check PATCH_COPYFAIL "${FIXED_COPYFAIL:-none}" \
    'a664bf3d603d|CVE-2026-31431|algif_aead.*out-of-place|Revert.*algif_aead'
JSON_FIELDS[patch_copyfail]="$PATCH_COPYFAIL"

# CVE-2026-43284/43500 – Dirty Frag
# Upstream commits: e91c6cb57978 / b29d4a88e8ae
kernel_patch_check PATCH_DIRTYFRAG "${FIXED_DIRTYFRAG:-none}" \
    'e91c6cb57978|b29d4a88e8ae|CVE-2026-43284|CVE-2026-43500|esp.*in-place.*paged|rxrpc.*in-place.*paged'
JSON_FIELDS[patch_dirtyfrag]="$PATCH_DIRTYFRAG"

# CVE-2026-46300 – Fragnesia
# Upstream commit: 3f8a2d1c905b
kernel_patch_check PATCH_FRAGNESIA "${FIXED_FRAGNESIA:-none}" \
    '3f8a2d1c905b|CVE-2026-46300|shared.frag.*coalescing|skb_try_coalesce.*SKBFL_SHARED_FRAG|preserve.*shared.frag'
JSON_FIELDS[patch_fragnesia]="$PATCH_FRAGNESIA"

# CVE-2026-46333 – ptrace mm-NULL bypass
# Upstream commit: 31e62c2ebbfd
kernel_patch_check PATCH_PTRACE "${FIXED_PTRACE:-none}" \
    '31e62c2ebbfd|CVE-2026-46333|ptrace.*mm.*NULL|get_dumpable.*CAP_SYS_PTRACE|saner.*dumpable'
JSON_FIELDS[patch_ptrace]="$PATCH_PTRACE"

# CIFSwitch – kernel fix (cifs.spnego origin validation)
# Upstream commit: 3da1fdf4efbc
# Also requires: cifs-utils >= version with safe cifs.upcall (check separately below)
kernel_patch_check PATCH_CIFSWITCH "${FIXED_CIFSWITCH:-none}" \
    '3da1fdf4efbc|CIFSwitch|cifs.*spnego.*origin|cifs_spnego_key_type.*CAP_NET_ADMIN|validate.*spnego.*description'
JSON_FIELDS[patch_cifswitch]="$PATCH_CIFSWITCH"

# CIFSwitch also requires a patched cifs-utils (cifs.upcall) package.
# Known fixed: cifs-utils >= 7.0-1+deb12u2 (Debian bookworm), >= 7.1-1 (trixie/sid)
#              cifs-utils >= 2:7.0-1ubuntu1.2 (Ubuntu noble), >= 2:6.15-1ubuntu2.2 (jammy)
PATCH_CIFSWITCH_UTILS="not_applicable"
if [[ "$CIFSUTILS_INSTALLED" == "true" ]]; then
    UTILS_VER=$(dpkg --status cifs-utils 2>/dev/null | awk '/^Version:/{print $2}' || true)
    if [[ -n "$UTILS_VER" ]]; then
        UTILS_FIXED=false
        case "${_DISTRO_ID}:${_DISTRO_VER}" in
            debian:bookworm)
                dpkg --compare-versions "$UTILS_VER" ge "7.0-1+deb12u2" 2>/dev/null && UTILS_FIXED=true ;;
            debian:trixie|debian:forky|debian:sid|debian:unstable)
                dpkg --compare-versions "$UTILS_VER" ge "7.1-1" 2>/dev/null && UTILS_FIXED=true ;;
            ubuntu:noble)
                dpkg --compare-versions "$UTILS_VER" ge "2:7.0-1ubuntu1.2" 2>/dev/null && UTILS_FIXED=true ;;
            ubuntu:jammy)
                dpkg --compare-versions "$UTILS_VER" ge "2:6.15-1ubuntu2.2" 2>/dev/null && UTILS_FIXED=true ;;
            ubuntu:focal)
                dpkg --compare-versions "$UTILS_VER" ge "2:6.9-1ubuntu0.3" 2>/dev/null && UTILS_FIXED=true ;;
        esac
        [[ "$UTILS_FIXED" == "true" ]] && PATCH_CIFSWITCH_UTILS="patched" || PATCH_CIFSWITCH_UTILS="not_patched"
    fi
fi
JSON_FIELDS[patch_cifswitch_utils]="$PATCH_CIFSWITCH_UTILS"

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
            not_tracked)
                miss "${cve}: no fixed-version data for ${KPKG_NAME} – patch status not tracked (keep mitigation)"
                ;;
            unknown)
                miss "${cve}: kernel package not identified – patch status unknown (keep mitigation)"
                ;;
        esac
    }

    _patch_line "CVE-2026-31431 (Copy Fail) " "$PATCH_COPYFAIL" "/etc/modprobe.d/disable-algif.conf"
    _patch_line "CVE-2026-43284/43500 (Dirty Frag)" "$PATCH_DIRTYFRAG" "/etc/modprobe.d/dirtyfrag.conf"
    _patch_line "CVE-2026-46300 (Fragnesia)  " "$PATCH_FRAGNESIA" "/etc/modprobe.d/fragnesia.conf"
    _patch_line "CVE-2026-46333 (ptrace mm-NULL)" "$PATCH_PTRACE" ""
    _patch_line "CIFSwitch (kernel fix)     " "$PATCH_CIFSWITCH" ""
    info "CVE-2026-23268..411 (CrackArmor): see [4/6] section above for per-component status"
    # CIFSwitch cifs-utils package status
    case "$PATCH_CIFSWITCH_UTILS" in
        patched)       ok   "CIFSwitch (cifs-utils pkg)  : patched" ;;
        not_patched)   warn "CIFSwitch (cifs-utils pkg)  : NOT patched – apt install cifs-utils" ;;
        not_applicable) ok  "CIFSwitch (cifs-utils pkg)  : not applicable (cifs.upcall not installed)" ;;
    esac

    # Fragnesia & Dirty Frag share modules – warn if only one is patched
    if [[ "$PATCH_DIRTYFRAG" == "patched" && "$PATCH_FRAGNESIA" != "patched" ]]; then
        warn "Dirty Frag patched but Fragnesia is not yet – keep esp4/esp6/rxrpc blacklist"
    fi

    # Show available kernel updates
    AVAIL=$(apt list --upgradable 2>/dev/null \
        | grep -iE "^(linux-image|proxmox-kernel|pve-kernel)" || true)
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

    # Unload modules, then re-read /proc/modules: rmmod fails silently for
    # modules in use, so success must not be assumed.
    # Usage: unload_modules <mod>...   – prints a reboot hint per survivor
    unload_modules() {
        local mod
        for mod in "$@"; do
            module_loaded "$mod" && { rmmod "$mod" 2>/dev/null || true; }
        done
        refresh_modules
        for mod in "$@"; do
            if module_loaded "$mod"; then
                warn "${mod} is still loaded (in use) – reboot required to unload it"
            fi
        done
    }

    # Copy Fail mitigation (only effective if module-based, not built-in)
    if [[ "${CF_AEAD:-}" != *"=y"* ]]; then
        echo "install algif_aead /bin/false" > /etc/modprobe.d/disable-algif.conf
        ok "algif_aead blacklist set (/etc/modprobe.d/disable-algif.conf)"
        unload_modules algif_aead
    else
        warn "algif_aead is built-in – modprobe.d fix skipped (manual GRUB config required)"
        info "  Add 'initcall_blacklist=algif_aead_init' to GRUB_CMDLINE_LINUX"
        info "  Then run: sudo update-grub && sudo reboot"
    fi

    # Dirty Frag mitigation – esp4/esp6 are needed by IPsec, so they are only
    # blacklisted on IPsec hosts when explicitly forced; rxrpc always.
    DF_MODS=(esp4 esp6 rxrpc)
    if [[ "$IPSEC_ACTIVE" == "true" && "$FORCE_IPSEC" != "true" ]]; then
        DF_MODS=(rxrpc)
        warn "IPsec in use – esp4/esp6 NOT blacklisted (would break IPsec tunnels)"
        info "  Only rxrpc is blacklisted; Dirty Frag/Fragnesia via esp4/esp6 remain open until patched"
        info "  To blacklist esp4/esp6 anyway: sudo check-cve --fix --force-ipsec"
    fi
    DF_CONF=""
    for mod in "${DF_MODS[@]}"; do
        DF_CONF+="install ${mod} /bin/false"$'\n'
    done
    printf '%s' "$DF_CONF" > /etc/modprobe.d/dirtyfrag.conf
    ok "Dirty Frag modprobe.d blacklist set for ${DF_MODS[*]} (/etc/modprobe.d/dirtyfrag.conf)"
    unload_modules "${DF_MODS[@]}"

    # Fragnesia mitigation (same modules – create dedicated file for auditability)
    if [[ ! -f /etc/modprobe.d/fragnesia.conf ]]; then
        {
            printf '# CVE-2026-46300 Fragnesia – same surface as Dirty Frag\n'
            printf '# Covered by dirtyfrag.conf; this file documents the intent explicitly.\n'
            printf '%s' "$DF_CONF"
        } > /etc/modprobe.d/fragnesia.conf
        ok "Fragnesia dedicated mitigation set for ${DF_MODS[*]} (/etc/modprobe.d/fragnesia.conf)"
    else
        ok "Fragnesia mitigation already present (/etc/modprobe.d/fragnesia.conf)"
        if [[ "$IPSEC_ACTIVE" == "true" && "$FORCE_IPSEC" != "true" ]] && \
           grep -qsE '^[[:space:]]*install[[:space:]]+esp[46][[:space:]]' /etc/modprobe.d/fragnesia.conf; then
            warn "/etc/modprobe.d/fragnesia.conf blacklists esp4/esp6 – IPsec will break after reboot"
        fi
    fi

    if [[ "$IPSEC_ACTIVE" == "true" && "$FORCE_IPSEC" == "true" ]]; then
        warn "IPsec in use – esp4/esp6 are now disabled (--force-ipsec). Verify VPN functionality!"
    fi

    echo -e "\n${YELLOW}Note: mitigations are active but not a substitute for kernel updates.${RESET}"
    echo    "  Update system: apt update && apt full-upgrade && reboot"
    echo    "  After reboot: re-run check-cve – if 'patched', mitigations can be removed."

    # CIFSwitch mitigation
    echo -e "\n${BOLD}  [CIFSwitch]${RESET}"
    # Without cifs.upcall the exploit chain is broken – leave userns alone,
    # disabling it would only cost container/sandbox functionality.
    if [[ "$CIFSUTILS_INSTALLED" != "true" ]]; then
        ok "cifs.upcall not installed – CIFSwitch not exploitable, user namespaces left unchanged"
    elif [[ "$USERNS_ENABLED" != "true" ]]; then
        if [[ "$USERNS_VAL" == "0" ]]; then
            ok "${USERNS_SYSCTL} already 0 – CIFSwitch blocked"
        else
            miss "User namespace state unknown – sysctl mitigation not applied"
        fi
        info "  Preferred if Kerberos CIFS mounts are not used:"
        info "    apt remove cifs-utils   (removes cifs.upcall, fully eliminates exploit path)"
    else
        info "  Preferred if Kerberos CIFS mounts are not used:"
        info "    apt remove cifs-utils   (removes cifs.upcall, fully eliminates exploit path)"
        if [[ "$USERNS_SYSCTL" == "kernel.unprivileged_userns_clone" ]]; then
            echo "kernel.unprivileged_userns_clone=0" > /etc/sysctl.d/99-cifswitch.conf
            sysctl -w kernel.unprivileged_userns_clone=0 >/dev/null 2>&1 || true
            if [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" == "0" ]]; then
                ok "kernel.unprivileged_userns_clone=0 set (persisted to /etc/sysctl.d/99-cifswitch.conf)"
            else
                warn "kernel.unprivileged_userns_clone could not be set at runtime (persisted for next boot)"
            fi
            info "  Note: some desktop features (browsers, containers) may require userns."
            info "  If needed, re-enable with: sudo sysctl -w kernel.unprivileged_userns_clone=1"
        else
            # user.max_user_namespaces=0 also blocks root (LXC, Docker userns, sandboxes)
            warn "kernel.unprivileged_userns_clone not available on this kernel"
            info "  user.max_user_namespaces=0 would block ALL new user namespaces, including root"
            info "  (containers, sandboxes) – not applied automatically. If acceptable:"
            info "    sudo sysctl -w user.max_user_namespaces=0"
        fi
    fi
fi

# ── JSON output (--json mode) ─────────────────────────────────────────────────
if [[ "$MODE" == "json" ]]; then
    HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    KERNEL=$(uname -r)
    OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "unknown")
    DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    # String member: "key": "escaped value",
    _jstr() { printf '  "%s": "%s",\n' "$1" "$(json_escape "$2")"; }
    # Boolean member: anything but "true" is emitted as false
    _jbool() {
        local v=false sep="${3-,}"
        [[ "$2" == "true" ]] && v=true
        printf '  "%s": %s%s\n' "$1" "$v" "$sep"
    }
    printf '{\n'
    _jstr hostname   "$HOSTNAME"
    _jstr kernel     "$KERNEL"
    _jstr os         "$OS"
    _jstr checked_at "$DATE"
    _jstr CVE_2026_31431_copyfail   "${JSON_FIELDS[copyfail]}"
    _jstr CVE_2026_43284_dirtyfrag  "${JSON_FIELDS[dirtyfrag]}"
    _jstr CVE_2026_46300_fragnesia  "${JSON_FIELDS[fragnesia]}"
    _jstr CVE_2026_23268_crackarmor "${JSON_FIELDS[crackarmor]:-unknown}"
    _jstr crackarmor_apparmor       "${JSON_FIELDS[crackarmor_apparmor]:-unknown}"
    _jstr CVE_2026_46333_ptrace     "${JSON_FIELDS[ptrace_mmnull]:-unknown}"
    _jstr patch_copyfail            "${JSON_FIELDS[patch_copyfail]:-unknown}"
    _jstr patch_dirtyfrag           "${JSON_FIELDS[patch_dirtyfrag]:-unknown}"
    _jstr patch_fragnesia           "${JSON_FIELDS[patch_fragnesia]:-unknown}"
    _jstr patch_ptrace              "${JSON_FIELDS[patch_ptrace]:-unknown}"
    _jstr cifswitch                 "${JSON_FIELDS[cifswitch]:-unknown}"
    _jbool cifswitch_userns         "${JSON_FIELDS[cifswitch_userns]:-false}"
    _jbool cifswitch_upcall         "${JSON_FIELDS[cifswitch_upcall]:-false}"
    _jstr patch_cifswitch           "${JSON_FIELDS[patch_cifswitch]:-unknown}"
    _jstr patch_cifswitch_utils     "${JSON_FIELDS[patch_cifswitch_utils]:-unknown}"
    _jbool ipsec_active             "${JSON_FIELDS[ipsec_active]:-false}" ""
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
echo    ""
echo    "  7. ptrace mm-NULL bypass – PoC / advisory (patch only):"
echo    "       https://security-tracker.debian.org/tracker/CVE-2026-46333"
echo    "       https://github.com/0xdeadbeefnetwork/ssh-keysign-pwn"
echo    "       DSA-6275-1 (bookworm) / DSA-6274-1 (trixie) / DLA-4587-1 (bullseye)"
echo    ""
echo    "  8. CIFSwitch – CIFS/cifs.spnego key forgery (patch + cifs-utils update):"
echo    "       https://heyitsas.im/posts/cifswitch/"
echo    "       https://github.com/manizada/CIFSwitch"
echo    "       apt update && apt full-upgrade   (kernel + cifs-utils)"
echo    "       Preferred: apt remove cifs-utils  (if Kerberos CIFS mounts unused)"
echo    "       Mitigation: sudo check-cve --fix  (sets unprivileged_userns_clone=0 if cifs-utils is installed)"
echo -e "${BOLD}============================================================${RESET}\n"
