#!/usr/bin/env bash
# =============================================================================
# install-dockeradminagent.sh — Komodo Periphery (Docker admin agent) as a
# systemd service
# =============================================================================
# Usage: install-dockeradminagent.sh --core-ip <ip>[,<ip>...] --core-public-key <key>
#        install-dockeradminagent.sh                     (update the binary)
#
#   --core-ip           Source address(es) of Komodo Core; nobody else may
#                       connect. Required on the first install.
#   --core-public-key   Core's public key (Komodo UI, Settings). Required on
#                       the first install.
#
# What this script does:
#   1. Download the pinned Periphery release and verify its sha256
#   2. Write /etc/komodo/periphery.config.toml on the first run only
#      (inbound only on port 8120, Core's IP and key pinned, no host terminal)
#   3. Install, enable and (re)start the systemd service "periphery"
#
# Run it again to update: only the binary changes, the config stays.
# Replaces the upstream setup-periphery.py (unpinned, unverified download).
#
# Repository: https://github.com/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

# Must match the version of Komodo Core.
KOMODO_VERSION=v2.3.3
# sha256 of the release assets (GitHub release v2.3.3, asset digests).
SHA256_X86_64=40b78f377626799afad8331246a501f077d4ebcfb6d9096894cf55b64f6dcf13
SHA256_AARCH64=60334780d7115ddc7a35fad062f4c606a4c814ae9a7dd8710ca96a0c1a37d85c

ROOT_DIR=/etc/komodo
CONFIG="$ROOT_DIR/periphery.config.toml"
BINARY=/usr/local/bin/periphery
UNIT=/etc/systemd/system/periphery.service

core_public_key=""
core_ips=""

usage() {
  cat <<USAGE
Usage: $0 --core-ip IP[,IP...] --core-public-key KEY    first install
       $0                                               update the binary

An existing $CONFIG is never overwritten.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --core-public-key) core_public_key="${2:?--core-public-key needs a value}"; shift 2 ;;
    --core-ip)         core_ips="${2:?--core-ip needs a value}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "error: run as root" >&2; exit 1; }
[ -d /run/systemd/system ] || { echo "error: systemd is not the init system" >&2; exit 1; }
command -v docker >/dev/null || { echo "error: docker is not installed" >&2; exit 1; }

case "$(uname -m)" in
  x86_64)        asset=periphery-x86_64;  sha256=$SHA256_X86_64 ;;
  aarch64|arm64) asset=periphery-aarch64; sha256=$SHA256_AARCH64 ;;
  *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

if [ ! -f "$CONFIG" ] && { [ -z "$core_public_key" ] || [ -z "$core_ips" ]; }; then
  echo "error: no $CONFIG yet; pass --core-ip and --core-public-key on the first install" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $asset $KOMODO_VERSION"
curl -fsSL -o "$tmp/periphery" \
  "https://github.com/moghtech/komodo/releases/download/$KOMODO_VERSION/$asset"
echo "$sha256  $tmp/periphery" | sha256sum -c --quiet - \
  || { echo "error: checksum mismatch for $asset $KOMODO_VERSION" >&2; exit 1; }

systemctl stop periphery 2>/dev/null || true
install -m 0755 "$tmp/periphery" "$BINARY"

install -d -m 0700 "$ROOT_DIR"
if [ -f "$CONFIG" ]; then
  echo "Keeping existing $CONFIG"
else
  # TOML array from the comma-separated list.
  ips_toml=$(printf '%s' "$core_ips" | sed 's/[[:space:]]//g; s/,/", "/g')
  umask 077
  cat >"$CONFIG" <<CONF
# Komodo Periphery, written by install-dockeradminagent.sh.
# Holds the [secrets] of this host's stacks: root-only, never in git.

root_directory = "$ROOT_DIR"

# Inbound only: Core connects here, this host never calls out.
server_enabled = true
port = 8120
bind_ip = "[::]"
allowed_ips = ["$ips_toml"]
ssl_enabled = true
# Only a Core holding this key passes the handshake.
core_public_keys = "$core_public_key"

# No root shell on the host through the web UI; container exec stays.
disable_terminals = true
disable_container_terminals = false

logging.level = "info"

# Read access to the stack repos, kept on this host only.
# [[git_provider]]
# domain = "git.example.com"
# accounts = [
#   { username = "<deploy token user>", token = "<token with read_repository>" },
# ]

# Referenced from a stack's Environment as [[NAME]].
[secrets]
# NAME = "value"
CONF
  echo "Wrote $CONFIG"
fi

cat >"$UNIT" <<UNITFILE
[Unit]
Description=Komodo Periphery (Docker admin agent)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Environment=HOME=/root
ExecStart=$BINARY --config-path $CONFIG
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITFILE

systemctl daemon-reload
systemctl enable --now periphery
systemctl restart periphery
sleep 2
if ! systemctl is-active --quiet periphery; then
  echo "error: periphery did not start; see journalctl -u periphery" >&2
  exit 1
fi
echo "Periphery $KOMODO_VERSION running on port 8120"
