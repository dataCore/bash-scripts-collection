#!/bin/sh
REPO="/usr/bin/datacore/bash"
BRANCH="main"

if git -C "$REPO" pull; then
    echo "git pull succeeded."
else
    echo "WARNING: git pull failed. Local changes will be discarded."
    if git -C "$REPO" fetch --all && git -C "$REPO" reset --hard "origin/$BRANCH"; then
        echo "Repository has been hard reset to origin/$BRANCH."
    else
        echo "ERROR: fetch/reset failed."
        exit 1
    fi
fi

# Execute link.sh if available
if [ -x "$REPO/link.sh" ]; then
    "$REPO/link.sh"
else
    echo "ERROR: link.sh cannot be executed."
    exit 1
fi
