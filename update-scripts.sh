#!/bin/sh
if ! git -C /usr/bin/datacore/bash fetch --all; then
    echo "ERROR: git fetch failed."
    exit 1
fi

if ! git -C /usr/bin/datacore/bash reset --hard origin/main; then
    echo "ERROR: git reset failed."
    exit 1
fi

if [ -x /usr/bin/datacore/bash/link.sh ]; then
    /usr/bin/datacore/bash/link.sh
else
    echo "ERROR: link.sh cannot be executed."
    exit 1
fi
