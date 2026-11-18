#!/usr/bin/env bash

# =============================================================================
# install-mail.sh — dataCore Outgoing Mail (Postfix Satellite)
# =============================================================================
# Usage: install-mail.sh --relay <host:port> --from <address> (--user <login> | --no-auth) [options]
#
# Sends all mail of the host (cron, smartd, apt, Proxmox notifications, …)
# through an authenticated submission relay instead of delivering it directly
# to port 25 of the recipient's MX.
#
# What this script does:
# 1. Install postfix (as "Satellite system") and libsasl2-modules if missing
# 2. Point postfix at the relay with TLS (certificate checked by default):
#    port 465 = implicit TLS (smtp_tls_wrappermode), any other port = STARTTLS
# 3. Store the SASL login in /etc/postfix/sasl_passwd (600, hashed with
#    postmap) — or, with --no-auth, switch SASL off and remove that file
# 4. Rewrite every sender (root@host.lan …) to --from, so the relay sees a
#    real address it allows the login to send as
# 5. Check the config and reload postfix
# 6. [--test <rcpt>] Send a test mail and wait until it has left the queue
#
# Required:
#   --relay <host:port>    Submission relay, e.g. mail.geek.ch:587
#   --from <address>       Sender address for all mail of this host,
#                          e.g. datacorebackup02@geek.ch
#   --user <login>         Relay login, e.g. serviceaccount@geek.ch
#     or --no-auth         Relay without login (internal smarthost that
#                          allows this host by IP)
#
# Options:
#   --password-file <f>    Read the relay password from file <f> (first line)
#   --tls <level>          verify (default): TLS required, certificate must be
#                          valid for the relay name
#                          encrypt: TLS required, certificate not checked
#                          (relay with a self-signed or internal certificate)
#   --test <rcpt>          Send a test mail to <rcpt> afterwards
#   --dry-run              Show what would happen, change nothing
#   -h, --help             Show this help
#
# Password: --password-file, else $SMTP_PASSWORD, else the password already
# stored for the same login, else an interactive prompt. It is never taken
# as an argument, so it does not end up in the shell history or in ps.
#
# Re-running is safe and idempotent: settings that already have the target
# value are left alone, and postfix is only reloaded when something changed.
# Before the first change of a run, main.cf and sasl_passwd are backed up to
# /etc/postfix/install-mail-backup/<timestamp>/.
#
# Examples (geek.ch):
#   install-mail.sh --relay mail.geek.ch:587 --user serviceaccount@geek.ch \
#       --from datacorebackup02@geek.ch --test datacore@geek.ch
#   install-mail.sh --relay mail.geek.ch:465 --user serviceaccount@geek.ch \
#       --from datacorebackup02@geek.ch            # after the switch to 465
#   SMTP_PASSWORD=… install-mail.sh --relay smtp.example.com:587 \
#       --user alerts@example.com --from pve01@example.com
#   install-mail.sh --relay smarthost.lan:25 --no-auth --tls encrypt \
#       --from pve01@example.com
#
# Repository: https://github.com/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

# Output helpers, log and apt_update (lib/common.sh)
LOG_TAG="install-mail"
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

# --------------- Paths --------------------------------------------------------
POSTFIX_DIR="/etc/postfix"
SASL_FILE="${POSTFIX_DIR}/sasl_passwd"
CANONICAL_FILE="${POSTFIX_DIR}/sender_canonical"
BACKUP_ROOT="${POSTFIX_DIR}/install-mail-backup"
CA_FILE="/etc/ssl/certs/ca-certificates.crt"

# --------------- Flags & Defaults ---------------------------------------------
OPT_FROM=""
OPT_RELAY=""
OPT_USER=""
OPT_NO_AUTH=false
OPT_TLS="verify"
OPT_PASSWORD_FILE=""
OPT_TEST=""
OPT_DRY_RUN=false

# Filled in by the steps
RELAY_HOST=""
RELAY_PORT=""
RELAY_KEY=""        # [host]:port — the relayhost value and the sasl_passwd key
PASSWORD=""
CHANGED=false
BACKUP_DIR=""

# =============================================================================
# Helpers
# =============================================================================
run() {
    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} $*"
        return 0
    fi
    log "[RUN] $*"
    "$@"
}

usage() {
    awk 'NR==1 {next} /^#/ {started=1; sub(/^# ?/, ""); print; next} started {exit}' "$0"
    exit "${1:-0}"
}

# Once per run, before the first change: copy what this script edits
backup_once() {
    [[ -z "$BACKUP_DIR" && "$OPT_DRY_RUN" == false ]] || return 0
    BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
    install -d -m 700 "$BACKUP_DIR"
    local f
    for f in "${POSTFIX_DIR}/main.cf" "$SASL_FILE" "$CANONICAL_FILE"; do
        if [[ -f "$f" ]]; then cp -a "$f" "$BACKUP_DIR/"; fi
    done
    ok "Backup: ${BACKUP_DIR}"
}

# Set a main.cf parameter only when it differs from the target
set_param() {
    local name="$1" value="$2" current
    current=$(postconf -h "$name" 2>/dev/null || true)
    if [[ "$current" == "$value" ]]; then
        ok "${name} = ${value}"
        return 0
    fi
    backup_once
    run postconf -e "${name} = ${value}"
    ok "${name} = ${value} ${YELLOW}(was: ${current:-empty})${NC}"
    CHANGED=true
}

# Write a file only when its content differs; mode is applied either way
write_file() {
    local path="$1" mode="$2" content="$3"
    if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
        [[ "$OPT_DRY_RUN" == true ]] || chmod "$mode" "$path"
        return 1
    fi
    backup_once
    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} write ${path} (mode ${mode})"
    else
        install -m "$mode" /dev/null "$path"
        printf '%s\n' "$content" > "$path"
    fi
    CHANGED=true
    return 0
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from|--relay|--user|--password-file|--test|--tls)
                [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value (use --help)"
                case "$1" in
                    --from)          OPT_FROM="$2" ;;
                    --relay)         OPT_RELAY="$2" ;;
                    --user)          OPT_USER="$2" ;;
                    --password-file) OPT_PASSWORD_FILE="$2" ;;
                    --test)          OPT_TEST="$2" ;;
                    --tls)           OPT_TLS="$2" ;;
                esac
                shift 2 ;;
            --no-auth) OPT_NO_AUTH=true; shift ;;
            --dry-run) OPT_DRY_RUN=true; shift ;;
            -h|--help) usage 0 ;;
            *) die "Unknown argument: $1 (use --help)" ;;
        esac
    done

    [[ -n "$OPT_RELAY" ]] || die "--relay <host:port> is required, e.g. mail.geek.ch:587 (use --help)"
    [[ -n "$OPT_FROM" ]] || die "--from <address> is required (use --help)"
    if [[ "$OPT_NO_AUTH" == true && -n "$OPT_USER" ]]; then
        die "--user and --no-auth exclude each other"
    fi
    [[ "$OPT_NO_AUTH" == true || -n "$OPT_USER" ]] \
        || die "--user <login> is required (or --no-auth for a relay without login)"
    [[ "$OPT_TLS" == verify || "$OPT_TLS" == encrypt ]] \
        || die "Invalid --tls '${OPT_TLS}' (verify or encrypt)"
    local addr_re='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    [[ "$OPT_FROM" =~ $addr_re ]] || die "Invalid --from '${OPT_FROM}'"
    [[ -z "$OPT_TEST" || "$OPT_TEST" =~ $addr_re ]] || die "Invalid --test '${OPT_TEST}'"
    [[ -z "$OPT_USER" || "$OPT_USER" =~ ^[^[:space:]:]+$ ]] || die "Invalid --user '${OPT_USER}'"

    [[ "$OPT_RELAY" =~ ^([A-Za-z0-9.-]+):([0-9]+)$ ]] \
        || die "Invalid --relay '${OPT_RELAY}' (expected host:port, e.g. mail.geek.ch:587)"
    RELAY_HOST="${BASH_REMATCH[1]}"
    RELAY_PORT="${BASH_REMATCH[2]}"
    # Brackets: use the host as given, no MX lookup — so the TLS check
    # verifies exactly this name against the certificate.
    RELAY_KEY="[${RELAY_HOST}]:${RELAY_PORT}"

    if [[ -n "$OPT_PASSWORD_FILE" && ! -r "$OPT_PASSWORD_FILE" ]]; then
        die "Password file not readable: ${OPT_PASSWORD_FILE}"
    fi
}

# =============================================================================
# Step 1 — Packages
# =============================================================================
step_packages() {
    print_section "Packages"

    command -v apt-get >/dev/null 2>&1 || die "apt-get not found — Debian/Ubuntu/Proxmox only."

    local missing=() pkg
    for pkg in postfix libsasl2-modules ca-certificates; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            ok "${pkg} installed"
        else
            missing+=("$pkg")
        fi
    done
    (( ${#missing[@]} > 0 )) || return 0

    # Another MTA (exim, msmtp-mta, …) is replaced by postfix — say so first
    local other
    other=$(dpkg-query -W -f='${Package} ${Status}\n' exim4-base msmtp-mta ssmtp nullmailer dma 2>/dev/null \
        | awk '/install ok installed/ {print $1}' | paste -sd' ' || true)
    [[ -n "$other" ]] && warn "Installing postfix replaces: ${other}"

    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} apt-get install ${missing[*]}"
        return 0
    fi
    # Satellite = send-only via relayhost; the relay itself is set in step 2
    echo "postfix postfix/main_mailer_type select Satellite system" | debconf-set-selections
    echo "postfix postfix/mailname string $(hostname -f 2>/dev/null || hostname)" | debconf-set-selections
    echo "postfix postfix/relayhost string ${RELAY_KEY}" | debconf-set-selections
    apt_update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
    ok "Installed: ${missing[*]}"
    CHANGED=true
}

# =============================================================================
# Step 2 — Relay, TLS, SASL
# =============================================================================
step_relay() {
    print_section "Relay ${RELAY_KEY}"

    [[ -r "$CA_FILE" ]] || die "CA bundle missing: ${CA_FILE} (ca-certificates)"

    set_param relayhost "$RELAY_KEY"
    if [[ "$OPT_NO_AUTH" == true ]]; then
        set_param smtp_sasl_auth_enable no
    else
        set_param smtp_sasl_auth_enable yes
        set_param smtp_sasl_password_maps "hash:${SASL_FILE}"
        set_param smtp_sasl_security_options noanonymous
    fi
    # verify: TLS required and the certificate must match the relay name
    # encrypt: TLS required, certificate not checked
    set_param smtp_tls_security_level "$OPT_TLS"
    set_param smtp_tls_CAfile "$CA_FILE"
    [[ "$OPT_TLS" == verify ]] || warn "Relay certificate is not checked (--tls encrypt)"
    if [[ "$RELAY_PORT" == "465" ]]; then
        set_param smtp_tls_wrappermode yes
    else
        set_param smtp_tls_wrappermode no
    fi
    set_param sender_canonical_maps "regexp:${CANONICAL_FILE}"

    # A send-only host should not accept mail from the network
    local listen
    listen=$(postconf -h inet_interfaces 2>/dev/null || true)
    if [[ "$listen" != "loopback-only" && "$listen" != "localhost" && "$listen" != "127.0.0.1" ]]; then
        warn "postfix listens on '${listen}' — for a send-only host set inet_interfaces = loopback-only"
        cmd "postconf -e 'inet_interfaces = loopback-only' && systemctl restart postfix"
    fi
}

# =============================================================================
# Step 3 — Login
# =============================================================================
# The stored entry is reused when the login is unchanged, so a re-run (or a
# switch from 587 to 465) does not ask for the password again.
step_login() {
    if [[ "$OPT_NO_AUTH" == true ]]; then
        print_section "Login"
        if [[ -f "$SASL_FILE" || -f "${SASL_FILE}.db" ]]; then
            backup_once
            run rm -f "$SASL_FILE" "${SASL_FILE}.db"
            ok "No login (--no-auth) — stored login removed"
            CHANGED=true
        else
            ok "No login (--no-auth)"
        fi
        return 0
    fi

    print_section "Login ${OPT_USER}"

    local stored_user="" stored_pw="" stored_cred=""
    if [[ -f "$SASL_FILE" ]]; then
        # Format: [host]:port user:password — take the first entry
        read -r _ stored_cred < <(grep -vE '^[[:space:]]*(#|$)' "$SASL_FILE" | head -1) || true
        stored_user="${stored_cred%%:*}"
        stored_pw="${stored_cred#*:}"
    fi

    if [[ -n "$OPT_PASSWORD_FILE" ]]; then
        IFS= read -r PASSWORD < "$OPT_PASSWORD_FILE" || true
        info "Password from ${OPT_PASSWORD_FILE}"
    elif [[ -n "${SMTP_PASSWORD:-}" ]]; then
        PASSWORD="$SMTP_PASSWORD"
        info "Password from \$SMTP_PASSWORD"
    elif [[ "$stored_user" == "$OPT_USER" && -n "$stored_pw" ]]; then
        PASSWORD="$stored_pw"
        ok "Stored password for ${OPT_USER} kept"
    elif [[ -t 0 ]]; then
        read -r -s -p "  Password for ${OPT_USER}: " PASSWORD
        echo ""
    else
        die "No password: use --password-file or \$SMTP_PASSWORD (no terminal to ask)."
    fi
    [[ -n "$PASSWORD" ]] || die "Empty password."

    if write_file "$SASL_FILE" 600 "${RELAY_KEY} ${OPT_USER}:${PASSWORD}"; then
        run postmap "hash:${SASL_FILE}"
        ok "Login stored in ${SASL_FILE} (600)"
    else
        # The .db can be missing or stale although the source is unchanged
        if [[ ! -f "${SASL_FILE}.db" || "$SASL_FILE" -nt "${SASL_FILE}.db" ]]; then
            run postmap "hash:${SASL_FILE}"
            CHANGED=true
        fi
        ok "Login unchanged"
    fi
    [[ "$OPT_DRY_RUN" == true || ! -f "${SASL_FILE}.db" ]] || chmod 600 "${SASL_FILE}.db"
}

# =============================================================================
# Step 4 — Sender Rewrite
# =============================================================================
step_sender() {
    print_section "Sender ${OPT_FROM}"

    # Every envelope and header sender becomes --from. Local hostnames such as
    # root@host.lan.example are not routable and a relay that checks sender
    # against login would reject them.
    if write_file "$CANONICAL_FILE" 644 "/.+/ ${OPT_FROM}"; then
        ok "All senders rewritten to ${OPT_FROM} (${CANONICAL_FILE})"
    else
        ok "Sender rewrite unchanged"
    fi
}

# =============================================================================
# Step 5 — Apply
# =============================================================================
step_apply() {
    print_section "Apply"

    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} postfix check && systemctl reload postfix"
        return 0
    fi

    if ! postfix check 2>&1 | sed 's/^/      /'; then
        die "postfix check failed — backup in ${BACKUP_DIR:-<none>}"
    fi
    ok "postfix check passed"

    if ! systemctl is-active --quiet postfix; then
        systemctl enable --now postfix >/dev/null 2>&1 || die "postfix does not start — see journalctl -u postfix"
        ok "postfix started"
    elif [[ "$CHANGED" == true ]]; then
        systemctl reload postfix
        ok "postfix reloaded"
    else
        ok "No change — postfix not reloaded"
    fi
}

# =============================================================================
# Step 6 — Test Mail
# =============================================================================
step_test() {
    [[ -n "$OPT_TEST" ]] || return 0
    print_section "Test Mail to ${OPT_TEST}"

    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} sendmail ${OPT_TEST}"
        return 0
    fi

    local host line
    host=$(hostname -f 2>/dev/null || hostname)
    printf 'To: %s\nSubject: install-mail test from %s\n\nSent by install-mail.sh on %s at %s via %s.\n' \
        "$OPT_TEST" "$host" "$host" "$(date '+%F %T')" "$RELAY_KEY" | sendmail "$OPT_TEST"
    info "Handed to postfix, waiting for delivery to the relay (max 30 s)"

    local i
    for (( i = 0; i < 30; i++ )); do
        sleep 1
        postqueue -j 2>/dev/null | grep -q . || break
    done

    if postqueue -j 2>/dev/null | grep -q .; then
        warn "Still in the queue after 30 s:"
        postqueue -p | sed 's/^/      /'
        info "Reason is in the delay line above; also:"
        cmd "journalctl -t postfix/smtp -n 20 --no-pager"
        return 0
    fi

    # Queue empty: show how the relay answered
    line=$(journalctl -t postfix/smtp --since "-1min" --no-pager -o cat 2>/dev/null \
        | grep -E "to=<${OPT_TEST}>" | tail -1 || true)
    if [[ "$line" == *"status=sent"* ]]; then
        ok "Delivered to the relay: ${line#*relay=}"
    elif [[ -n "$line" ]]; then
        warn "Relay answer: ${line}"
    else
        ok "Queue empty — the mail has left this host"
    fi
}

# =============================================================================
# Step 7 — Summary
# =============================================================================
step_summary() {
    print_section "Summary"

    if [[ "$OPT_DRY_RUN" == true ]]; then
        warn "Dry run — nothing was changed."
        echo ""
        return 0
    fi

    local mode cert
    mode=$( [[ "$RELAY_PORT" == "465" ]] && echo "implicit TLS" || echo "STARTTLS" )
    cert=$( [[ "$OPT_TLS" == verify ]] && echo "certificate verified" || echo "certificate NOT verified" )
    ok "Relay:   ${BOLD}${RELAY_KEY}${NC} (${mode}, ${cert})"
    ok "Login:   ${BOLD}${OPT_USER:-none (--no-auth)}${NC}"
    ok "Sender:  ${BOLD}${OPT_FROM}${NC}"
    [[ -n "$BACKUP_DIR" ]] && info "Rollback: cp -a ${BACKUP_DIR}/* ${POSTFIX_DIR}/ && postmap ${SASL_FILE} && systemctl reload postfix"
    echo ""
    info "Test and check:"
    cmd "printf 'Subject: test\\n\\nok\\n' | sendmail you@example.com"
    cmd "postqueue -p"
    cmd "journalctl -t postfix/smtp -n 20 --no-pager"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"

    [[ "$EUID" -eq 0 ]] || die "This script must be run as root."

    log_init
    log "from=${OPT_FROM} relay=${RELAY_KEY} user=${OPT_USER:-none} tls=${OPT_TLS} test=${OPT_TEST:-none} dry-run=${OPT_DRY_RUN}"

    print_header "dataCore — Outgoing Mail (Postfix)"
    step_packages
    if ! command -v postconf >/dev/null 2>&1; then
        # Only possible in dry-run before the install
        warn "postfix not installed yet — the remaining steps run after the install."
        step_summary
        return 0
    fi
    step_relay
    step_login
    step_sender
    step_apply
    step_test
    step_summary
}

main "$@"
