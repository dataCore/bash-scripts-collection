#!/usr/bin/env bash
# =============================================================================
# komodo-migrate-env.sh — move a Compose project's .env into Komodo
# =============================================================================
# Usage: komodo-migrate-env.sh <project-dir> [<secret-prefix>]
#
#   project-dir     directory holding the project's .env, e.g.
#                   /etc/docker-compose/datacoremcp
#   secret-prefix   prefix for the secret names (default: the directory name,
#                   upper-cased), so stacks on the same host never collide
#
# What this script does:
#   1. Splits the .env into secrets (names ending in TOKEN, SECRET, PASSWORD,
#      PASS or _KEY, and URLs with credentials like scheme://user:pass@host)
#      and plain settings
#   2. Appends the secrets to the [secrets] section of
#      /etc/komodo/periphery.config.toml as <PREFIX>_<NAME> (existing names
#      are left alone). Only when something was added: the config is backed
#      up first (<config>.bak-<timestamp>), Periphery is restarted and must
#      come up active again
#   3. Prints the stack Environment to paste into Komodo: plain settings as
#      they are, secrets as [[<PREFIX>_<NAME>]]
#
# Periphery fills in [[...]] on the host, so secret values never reach
# Komodo Core or its database backups. The .env itself is not changed.
# Values that use ${...} interpolation are kept as they are and reported:
# check them in Komodo, the referenced variables must exist there as well.
#
# Repository: https://github.com/dataCore/bash-scripts-collection
# =============================================================================

set -euo pipefail

CONFIG=/etc/komodo/periphery.config.toml

dir="${1:?usage: $0 <project-dir> [<secret-prefix>]}"
prefix="${2:-$(basename "$(realpath "$dir")")}"

[ "$(id -u)" -eq 0 ] || { echo "error: run as root" >&2; exit 1; }
[ -f "$dir/.env" ] || { echo "error: no .env in $dir" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "error: no $CONFIG; run install-dockeradminagent first" >&2; exit 1; }
grep -q '^\[secrets\]' "$CONFIG" || { echo "error: no [secrets] section in $CONFIG" >&2; exit 1; }
# Appending only lands in [secrets] while it is the last table.
last_table=$(grep -E '^\[\[?[A-Za-z_.]+\]\]?' "$CONFIG" | tail -1)
[ "$last_table" = "[secrets]" ] \
  || { echo "error: [secrets] is not the last table in $CONFIG; add the secrets by hand" >&2; exit 1; }

# Backup before appending; removed again below when nothing was added
backup="${CONFIG}.bak-$(date +%Y%m%d_%H%M%S)"
cp -a "$CONFIG" "$backup"

python3 - "$dir/.env" "$CONFIG" "$prefix" <<'PY'
import json, re, sys

env_path, config_path, prefix = sys.argv[1:]
prefix = re.sub(r"[^A-Z0-9]+", "_", prefix.upper()).strip("_")
secret_name = re.compile(r"(TOKEN|SECRET|PASSWORD|PASS|_KEY)$")
# A URL with user:password (DATABASE_URL, REDIS_URL, ...) is a secret too
secret_value = re.compile(r"://[^/]*:[^@]*@")
interpolation = re.compile(r"\$\{[^}]*\}")
line_re = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")

def value_of(raw):
    # Returns (value, literal): literal is True for single-quoted values,
    # in which compose does not interpolate ${...}.
    raw = raw.strip()
    if raw[:1] == "'":
        end = raw.find("'", 1)
        return (raw[1:end] if end > 0 else raw[1:]), True
    if raw[:1] == '"':
        out, i = [], 1
        while i < len(raw) and raw[i] != '"':
            if raw[i] == "\\" and i + 1 < len(raw):
                i += 1
                out.append({"n": "\n", "t": "\t"}.get(raw[i], raw[i]))
            else:
                out.append(raw[i])
            i += 1
        return "".join(out), False
    # Unquoted: " #" starts a comment, as in docker compose.
    return re.split(r"\s+#", raw, 1)[0].strip(), False

def quoted(key, text, value, literal):
    # Komodo writes the Environment verbatim as .env and compose parses it
    # again: quote whatever compose would cut at a space, '#' or quote.
    if not re.search(r"[\s#'\"\\$]", value):
        return text
    if not literal and interpolation.search(value):
        # Single quotes would turn ${...} into literal text. Keep it
        # interpolating (double quotes only where compose needs quoting).
        print(f"warning: {key} uses ${{...}} interpolation ({value!r}); kept as is, check it in Komodo",
              file=sys.stderr)
        if not re.search(r"[\s#'\"\\]", text):
            return text
        return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if "'" not in value:
        return f"'{text}'"
    print(f"warning: {value!r} holds a single quote; check it in Komodo", file=sys.stderr)
    return text

with open(config_path) as f:
    config = f.read()
known = set(re.findall(r"^([A-Za-z0-9_]+)\s*=", config.split("[secrets]", 1)[1], re.M))

secrets, environment = [], []
with open(env_path) as f:
    for line in f:
        m = line_re.match(line)
        if not m:
            continue
        key = m.group(1)
        value, literal = value_of(m.group(2))
        if value and (secret_name.search(key) or secret_value.search(value)):
            name = f"{prefix}_{key}"
            environment.append(f"{key}=" + quoted(key, f"[[{name}]]", value, literal))
            if name not in known:
                secrets.append(f"{name} = {json.dumps(value)}")
        else:
            environment.append(f"{key}=" + quoted(key, value, value, literal))

if secrets:
    with open(config_path, "a") as f:
        f.write(f"\n# {prefix} (komodo-migrate-env)\n" + "\n".join(secrets) + "\n")
print(f"{len(secrets)} secret(s) added to {config_path}", file=sys.stderr)
print("----- Environment for the Komodo stack -----", file=sys.stderr)
print("\n".join(environment))
PY

if cmp -s "$CONFIG" "$backup"; then
    rm -f "$backup"
    echo "No new secrets, Periphery not restarted" >&2
    exit 0
fi
echo "Backup of the previous config: $backup" >&2
systemctl restart periphery
# Give a broken config the moment it needs to crash the service
sleep 3
if ! systemctl is-active --quiet periphery; then
    echo "error: periphery is not active after the restart; see 'journalctl -u periphery'." >&2
    echo "       Previous config: $backup" >&2
    exit 1
fi
echo "Periphery restarted" >&2
