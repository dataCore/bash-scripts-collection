#!/bin/sh
REPO="/usr/bin/datacore/bash"
BRANCH="main"

# Fetch only; no pull, so a diverged local branch never ends in a merge
if ! timeout 120 git -C "$REPO" fetch origin "$BRANCH"; then
    echo "ERROR: git fetch origin $BRANCH failed or timed out. Repository left unchanged."
    exit 1
fi

# Pin the fetched commit: a concurrent run (cron, check-cve, update-system,
# update-docker-all all call this script) could move origin/$BRANCH between
# the signature check and the reset.
REV=$(git -C "$REPO" rev-parse "origin/$BRANCH") || exit 1

# Opt-in signature check: once gpg.ssh.allowedSignersFile is configured
# (repository or system git config), only a signed commit from a listed key
# is accepted.
if [ -n "$(git -C "$REPO" config --get gpg.ssh.allowedSignersFile)" ]; then
    if git -C "$REPO" verify-commit "$REV"; then
        echo "Signature of origin/$BRANCH verified."
    else
        echo "ERROR: signature of origin/$BRANCH could not be verified. Repository left unchanged."
        exit 1
    fi
fi

# Same semantics as before: local changes are discarded, but say so only
# when there are any (modified tracked files or local commits).
if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] ||
    [ -n "$(git -C "$REPO" rev-list "$REV..HEAD")" ]; then
    echo "WARNING: local changes in $REPO are discarded."
fi

# --quiet: git's own "HEAD is now at ..." line is replaced by the message below
if git -C "$REPO" reset --quiet --hard "$REV"; then
    echo "Repository is at origin/$BRANCH ($(git -C "$REPO" log -1 --format='%h %s'))."
else
    echo "ERROR: git reset --hard origin/$BRANCH failed."
    exit 1
fi

# Execute link.sh if available
if [ -x "$REPO/link.sh" ]; then
    "$REPO/link.sh"
else
    echo "ERROR: link.sh cannot be executed."
    exit 1
fi
