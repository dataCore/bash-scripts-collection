#!/bin/bash

# =======================================================================
# FIX APT SOURCES SCRIPT
# by dataCore
#
# Moves the official Debian/Ubuntu repositories into one deb822 file
# (/etc/apt/sources.list.d/debian.sources or ubuntu.sources) with the
# <release>, -updates and -security suites, the way current installers
# write it. Security updates come straight from security.debian.org or
# security.ubuntu.com, not from a mirror.
#
# Third-party repositories (Docker, Zabbix, Proxmox, Fluent Bit, PPAs, ...)
# are never touched: an entry counts as official only when its Release
# file says "Origin: Debian" or "Origin: Ubuntu". Official lines are
# removed from sources.list and *.list files, every other line stays.
#
# Usage: fix-apt-sources            (show what would change)
#        fix-apt-sources --apply    (change it, as root)
#
# HISTORY
# 2026-10-30 Initial Version
#
# =======================================================================
# START script
# =======================================================================

set -euo pipefail

APPLY=false
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
        -h|--help)
            echo "Usage: fix-apt-sources [--apply]"
            echo "  (no flag)  Show the current entries and the planned change"
            echo "  --apply    Write the change, run apt-get update, roll back on errors"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done
if [ "$APPLY" = true ] && [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo or as root."
    exit 1
fi

# openmediavault writes the apt sources itself (omv-salt) and would undo it
if [ -d /etc/openmediavault ]; then
    echo "openmediavault manages the apt sources itself – fix them in the OMV web UI or with omv-salt."
    exit 1
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# shellcheck disable=SC1091
DISTRO_ID=$(. /etc/os-release && echo "${ID:-}")
# shellcheck disable=SC1091
CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
SOURCES_D="/etc/apt/sources.list.d"
SOURCES_LIST="/etc/apt/sources.list"

# Captured first: under pipefail an early grep exit would SIGPIPE apt-cache
has_security() {
    local policy
    policy=$(apt-cache policy 2>/dev/null || true)
    grep -qE "[[:space:]]${CODENAME}-security/" <<< "$policy"
}

# --- distribution (begin) ---
case "$DISTRO_ID" in
    debian)
        if [ -z "$CODENAME" ] || grep -q 'sid' /etc/debian_version 2>/dev/null; then
            echo "Debian testing/sid has no security suite – nothing to do."
            exit 0
        fi
        TARGET="$SOURCES_D/debian.sources"
        DEFAULT_MIRROR="http://deb.debian.org/debian"
        SECURITY_URI="http://security.debian.org/debian-security"
        ORIGIN="Debian"
        COMP_ORDER="main contrib non-free non-free-firmware"
        if [ "$CODENAME" = "bullseye" ]; then DEFAULT_COMPS="main"; else DEFAULT_COMPS="main non-free-firmware"; fi
        KEYRING=""
        for k in /usr/share/keyrings/debian-archive-keyring.pgp /usr/share/keyrings/debian-archive-keyring.gpg; do
            [ -f "$k" ] && { KEYRING="$k"; break; }
        done
        ;;
    ubuntu)
        TARGET="$SOURCES_D/ubuntu.sources"
        case "$(dpkg --print-architecture)" in
            amd64|i386)
                DEFAULT_MIRROR="http://archive.ubuntu.com/ubuntu"
                SECURITY_URI="http://security.ubuntu.com/ubuntu"
                ;;
            *)
                DEFAULT_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
                SECURITY_URI="http://ports.ubuntu.com/ubuntu-ports"
                ;;
        esac
        ORIGIN="Ubuntu"
        COMP_ORDER="main restricted universe multiverse"
        DEFAULT_COMPS="$COMP_ORDER"
        KEYRING=""
        [ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ] && KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
        ;;
    linuxmint)
        # Mint manages its sources with mintsources; only report
        # shellcheck disable=SC1091
        CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${DEBIAN_CODENAME:-$CODENAME}}")
        if has_security; then
            echo "[✓] Linux Mint: ${CODENAME}-security is configured. Mint manages its sources itself – nothing to do."
        else
            echo "[!] Linux Mint: ${CODENAME}-security is missing. Fix it with the Software Sources tool (mintsources)."
            exit 1
        fi
        exit 0
        ;;
    *)
        echo "Unsupported distribution '${DISTRO_ID}' – only Debian, Ubuntu and Linux Mint."
        exit 1
        ;;
esac
# --- distribution (end) ---

# --- read entries (begin) ---
# One record per entry, tab separated:
#   file  line  type  uri  suite  components
# line is 0 for deb822 entries.
parse_oneline() {
    awk -v f="$1" '
        { line = $0; sub(/#.*/, "", line) }
        line ~ /^[[:space:]]*deb(-src)?[[:space:]]/ {
            gsub(/\[[^]]*\]/, "", line)
            n = split(line, F, " ")
            comps = ""
            for (i = 4; i <= n; i++) comps = comps (comps == "" ? "" : " ") F[i]
            printf "%s\t%d\t%s\t%s\t%s\t%s\n", f, NR, F[1], F[2], F[3], comps
        }' "$1"
}

parse_deb822() {
    awk -v f="$1" '
        function flush(  nt, nu, ns, a, b, c, T, U, S) {
            if (types != "" && enabled != "no") {
                nt = split(types, T, " "); nu = split(uris, U, " "); ns = split(suites, S, " ")
                for (a = 1; a <= nt; a++) for (b = 1; b <= nu; b++) for (c = 1; c <= ns; c++)
                    printf "%s\t0\t%s\t%s\t%s\t%s\n", f, T[a], U[b], S[c], comps
            }
            types = uris = suites = comps = enabled = cur = ""
        }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { flush(); next }
        /^[A-Za-z-]+:/ {
            cur = tolower($1); sub(/:$/, "", cur)
            val = $0; sub(/^[^:]*:[[:space:]]*/, "", val)
            if (cur == "types") types = val
            else if (cur == "uris") uris = val
            else if (cur == "suites") suites = val
            else if (cur == "components") comps = val
            else if (cur == "enabled") enabled = tolower(val)
            next
        }
        /^[[:space:]]/ {
            val = $0; sub(/^[[:space:]]+/, "", val)
            if (cur == "types") types = types " " val
            else if (cur == "uris") uris = uris " " val
            else if (cur == "suites") suites = suites " " val
            else if (cur == "components") comps = comps " " val
        }
        END { flush() }' "$1"
}

# Origin from the Release file apt downloaded for this source, empty if none
release_origin() {
    local base f
    base=$(sed -E 's|^[a-z+]+://||; s|^[^@/]*@||; s|/+$||' <<< "$1")
    base=${base//_/%5f}
    base=${base//\//_}
    for f in "/var/lib/apt/lists/${base}_dists_${2//\//_}_InRelease" \
             "/var/lib/apt/lists/${base}_dists_${2//\//_}_Release"; do
        if [ -f "$f" ]; then
            sed -n 's/^Origin:[[:space:]]*//p' "$f" | head -1
            return 0
        fi
    done
}

# official | cdrom | foreign
classify() {
    local uri="$1" suite="$2" origin host
    case "$uri" in cdrom:*) echo "cdrom"; return 0 ;; esac
    case "$suite" in
        "$CODENAME"|"$CODENAME"-updates|"$CODENAME"-security|"$CODENAME"-backports|\
        "$CODENAME"-proposed-updates|"$CODENAME"-proposed) ;;
        *) echo "foreign"; return 0 ;;
    esac
    origin=$(release_origin "$uri" "$suite")
    if [ -n "$origin" ]; then
        if [ "$origin" = "$ORIGIN" ]; then echo "official"; else echo "foreign"; fi
        return 0
    fi
    # Never fetched: trust only the project's own hosts
    host=$(sed -E 's|^[a-z+]+://||; s|^[^@/]*@||; s|[:/].*||' <<< "$uri")
    case "$host" in
        *debian.org|*ubuntu.com) echo "official" ;;
        *) echo "foreign" ;;
    esac
}

ENTRIES=()
[ -f "$SOURCES_LIST" ] && mapfile -t -O "${#ENTRIES[@]}" ENTRIES < <(parse_oneline "$SOURCES_LIST")
for f in "$SOURCES_D"/*.list; do
    [ -f "$f" ] && mapfile -t -O "${#ENTRIES[@]}" ENTRIES < <(parse_oneline "$f")
done
for f in "$SOURCES_D"/*.sources; do
    [ -f "$f" ] && mapfile -t -O "${#ENTRIES[@]}" ENTRIES < <(parse_deb822 "$f")
done
# --- read entries (end) ---

# --- plan (begin) ---
declare -A DROP_LINES   # one-line file -> " n1 n2 " lines to remove
MIRROR=""
COMPS_FOUND=" "
SUITES_FOUND=" "
ONELINE_OFFICIAL=0
SRC_DROPPED=0
SECURITY_IN_TARGET=false
ABORT=""

echo "Current entries (${DISTRO_ID} ${CODENAME}):"
for e in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r file line type uri suite comps <<< "$e"
    class=$(classify "$uri" "$suite")
    case "$class" in
        foreign)
            echo "  keep     $type $uri $suite $comps  ($file)"
            if [ "$file" = "$TARGET" ]; then
                ABORT="$TARGET contains a third-party entry ($uri $suite) – move it to its own file first."
            fi
            continue
            ;;
        cdrom)
            echo "  drop     $type $uri $suite  ($file, installation medium)"
            ;;
        official)
            if [ "$type" = "deb-src" ]; then
                echo "  drop     $type $uri $suite  ($file, source packages are not needed)"
                SRC_DROPPED=$((SRC_DROPPED + 1))
            else
                if [ "$file" = "$TARGET" ]; then label="current"; else label="replace"; fi
                echo "  $label  $type $uri $suite $comps  ($file)"
                for c in $comps; do
                    [[ "$COMPS_FOUND" == *" $c "* ]] || COMPS_FOUND+="$c "
                done
                [[ "$SUITES_FOUND" == *" $suite "* ]] || SUITES_FOUND+="$suite "
                if [ -z "$MIRROR" ] && [ "$suite" = "$CODENAME" ]; then
                    MIRROR="${uri%/}"
                fi
                [ "$file" = "$TARGET" ] && [ "$suite" = "$CODENAME-security" ] && SECURITY_IN_TARGET=true
            fi
            ;;
    esac
    if [ "$line" -gt 0 ]; then
        DROP_LINES[$file]="${DROP_LINES[$file]:- } $line "
        ONELINE_OFFICIAL=$((ONELINE_OFFICIAL + 1))
    elif [ "$file" != "$TARGET" ]; then
        ABORT="$file holds official entries in deb822 format – merge it into $TARGET by hand."
    fi
done
[ ${#ENTRIES[@]} -eq 0 ] && echo "  (none)"

if [ -n "$ABORT" ]; then
    echo "Error: $ABORT"
    exit 1
fi

if [ "$ONELINE_OFFICIAL" -eq 0 ] && [ "$SECURITY_IN_TARGET" = true ]; then
    echo "[✓] $TARGET is in place with ${CODENAME}-security – nothing to do."
    exit 0
fi

[ -z "$MIRROR" ] && MIRROR="$DEFAULT_MIRROR"

# Components in the usual order, unknown ones appended
COMPS=""
for c in $COMP_ORDER; do
    [[ "$COMPS_FOUND" == *" $c "* ]] && COMPS+="${COMPS:+ }$c"
done
for c in $COMPS_FOUND; do
    [[ " $COMP_ORDER " == *" $c "* ]] || COMPS+="${COMPS:+ }$c"
done
[ -z "$COMPS" ] && COMPS="$DEFAULT_COMPS"

SUITES="$CODENAME $CODENAME-updates"
for s in backports proposed-updates proposed; do
    [[ "$SUITES_FOUND" == *" $CODENAME-$s "* ]] && SUITES+=" $CODENAME-$s"
done

stanza() {
    echo "Types: deb"
    echo "URIs: $1"
    echo "Suites: $2"
    echo "Components: $COMPS"
    [ -n "$KEYRING" ] && echo "Signed-By: $KEYRING"
    return 0
}
NEW_SOURCES="# Written by fix-apt-sources on $(date '+%Y-%m-%d')
$(stanza "$MIRROR" "$SUITES")

$(stanza "$SECURITY_URI" "$CODENAME-security")"

echo ""
echo "Planned $TARGET:"
awk '{ print "  | " $0 }' <<< "$NEW_SOURCES"
for file in "${!DROP_LINES[@]}"; do
    rest=$(awk -v drop="${DROP_LINES[$file]}" 'index(drop, " " NR " ") == 0' "$file" \
        | grep -cE '^[[:space:]]*deb(-src)?[[:space:]]' || true)
    if [ "$rest" -gt 0 ]; then
        echo "  $file: official lines removed, $rest third-party line(s) kept"
    elif [ "$file" = "$SOURCES_LIST" ]; then
        echo "  $file: emptied (only a pointer comment stays)"
    else
        echo "  $file: removed (official entries only)"
    fi
done
[ "$SRC_DROPPED" -gt 0 ] && echo "  deb-src entries are dropped; add 'Types: deb deb-src' if you build packages."
# --- plan (end) ---

if [ "$APPLY" != true ]; then
    echo ""
    echo "Nothing changed. Run 'fix-apt-sources --apply' to write it."
    exit 0
fi

# --- apply (begin) ---
# Errors apt already reports with the old sources (a third-party repo with
# a missing key, ...) must not block the fix; only new errors roll back.
apt_errors() {
    apt-get -o DPkg::Lock::Timeout=600 update 2>&1 | grep '^E:' | sort -u || true
}
ERRORS_BEFORE=$(apt_errors)

BACKUP="/var/backups/fix-apt-sources-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$BACKUP"
[ -f "$SOURCES_LIST" ] && cp -a "$SOURCES_LIST" "$BACKUP/"
cp -a "$SOURCES_D" "$BACKUP/"

restore() {
    echo "Restoring the previous sources from $BACKUP ..."
    rm -rf "$SOURCES_D"
    cp -a "$BACKUP/sources.list.d" "$SOURCES_D"
    if [ -f "$BACKUP/sources.list" ]; then
        cp -a "$BACKUP/sources.list" "$SOURCES_LIST"
    fi
    apt-get -o DPkg::Lock::Timeout=600 update >/dev/null 2>&1 || true
}

for file in "${!DROP_LINES[@]}"; do
    kept=$(awk -v drop="${DROP_LINES[$file]}" 'index(drop, " " NR " ") == 0' "$file")
    if grep -qE '^[[:space:]]*deb(-src)?[[:space:]]' <<< "$kept"; then
        printf '%s\n' "$kept" > "$file"
    elif [ "$file" = "$SOURCES_LIST" ]; then
        echo "# Official repositories: $TARGET (written by fix-apt-sources)" > "$file"
    else
        rm -f "$file"
    fi
done
printf '%s\n' "$NEW_SOURCES" > "$TARGET"
chmod 644 "$TARGET"

ERRORS_AFTER=$(apt_errors)
NEW_ERRORS=$(comm -13 <(echo "$ERRORS_BEFORE") <(echo "$ERRORS_AFTER") | grep . || true)
if [ -n "$NEW_ERRORS" ]; then
    echo "$NEW_ERRORS"
    echo "Error: apt-get update fails with the new sources."
    restore
    exit 1
fi
if [ -n "$ERRORS_AFTER" ]; then
    echo "[!] Warning: errors that were there before (not caused by this change):"
    awk '{ print "    " $0 }' <<< "$ERRORS_AFTER"
fi
if ! has_security; then
    echo "Error: ${CODENAME}-security is still not active after apt-get update."
    restore
    exit 1
fi

echo "[✓] Sources fixed: $TARGET with ${CODENAME}-security. Backup: $BACKUP"
echo "    Install the missing security updates now: update-system"
# --- apply (end) ---
