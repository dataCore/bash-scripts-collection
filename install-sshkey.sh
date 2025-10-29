#!/bin/bash
# =======================================================================
# INSTALL SSH KEY (multi-key version)
# by dataCore
#
# HISTORY
# 2025-10-29 Initial Version with multi-key support
# =======================================================================

# --- Variables ---
REPO_URL="https://code.geek.ch/dataCore/ssh-keys.git"
REPO_DIR="$HOME/.ssh-setup-tmp"

# --- Print User Info ---
echo "Running as user: $(whoami)"
echo "Home directory: $HOME"
echo "Do you want to continue? (y/n)"
read -r confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted by user."
    exit 0
fi

# --- Clone SSH Key Repository ---
echo "Cloning SSH key repository..."
git clone "$REPO_URL" "$REPO_DIR" || {
    echo "Failed to clone repository."
    exit 1
}

# --- Prepare SSH Directory ---
mkdir -p "$HOME/.ssh"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"

# --- Loop Through All .pub Files ---
echo "Processing public keys..."
for KEY_PATH in "$REPO_DIR"/*.pub; do
    if [ -f "$KEY_PATH" ]; then
        KEY_CONTENT=$(cat "$KEY_PATH")
        if ! grep -q "$KEY_CONTENT" "$AUTHORIZED_KEYS" 2>/dev/null; then
            echo "$KEY_CONTENT" >> "$AUTHORIZED_KEYS"
            echo "Added key: $(basename "$KEY_PATH")"
        else
            echo "Key already exists: $(basename "$KEY_PATH")"
        fi
    fi
done

# --- Set Permissions ---
chmod 700 "$HOME/.ssh"
chmod 600 "$AUTHORIZED_KEYS"

# --- Cleanup ---
rm -rf "$REPO_DIR"

echo "✅ SSH setup completed successfully."