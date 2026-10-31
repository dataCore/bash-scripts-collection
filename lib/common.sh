# shellcheck shell=bash
# =============================================================================
# Shared helpers of the install-* scripts — sourced, not executed.
#
# The caller sets LOG_TAG (and LOG_FILE, if not the default) before sourcing,
# and calls log_init once it runs as root. The scripts are called through
# symlinks in /usr/bin, so they source this file by their resolved path:
#   source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
# =============================================================================

# shellcheck disable=SC2034  # colors are used by the sourcing scripts
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
# shellcheck disable=SC2034
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="${LOG_FILE:-/var/log/datacore-install.log}"
LOG_TAG="${LOG_TAG:-$(basename "$0" .sh)}"

# Root-only: the log holds what the scripts report, which can be sensitive.
# Also tightens a log that earlier versions created world-readable.
log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    [[ -e "$LOG_FILE" ]] || install -m 600 /dev/null "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    echo "=== ${LOG_TAG}.sh === $(date)" >>"$LOG_FILE"
}

# Silently skipped where the log cannot be written (no root yet, --help)
log() {
    [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ) ]] || return 0
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${LOG_TAG}] $*" >>"$LOG_FILE"
}

ok()   { echo -e "  ${GREEN}✓${NC}  $1"; log "[OK]   $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; log "[INFO] $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; log "[WARN] $1"; }
err()  { echo -e "  ${RED}✗${NC}  $1"; log "[ERR]  $1"; }
die()  { err "$1"; echo ""; exit 1; }
cmd()  { echo -e "    ${CYAN}$1${NC}"; }

# Boxed title, e.g. print_header "dataCore — SSH Setup & Hardening"
print_header() {
    local width=58 title="$1" pad left
    pad=$(( width - ${#title} ))
    (( pad < 0 )) && pad=0
    left=$(( pad / 2 ))
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔$(printf '═%.0s' $(seq 1 "$width"))╗"
    printf '  ║%*s%s%*s║\n' "$left" "" "$title" "$(( pad - left ))" ""
    echo "  ╚$(printf '═%.0s' $(seq 1 "$width"))╝"
    echo -e "${NC}"
}

print_section() {
    echo ""
    echo -e "${BLUE}${BOLD}▶ $1${NC}"
    echo -e "${BLUE}$(printf '─%.0s' {1..60})${NC}"
}

# apt-get update that only warns: a broken third-party repository must not
# stop an installation that does not need it.
apt_update() {
    local errfile
    errfile=$(mktemp)
    # shellcheck disable=SC2034  # read by install-docker
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
