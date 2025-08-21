#!/bin/sh
if ! git -C /usr/bin/datacore/bash/ pull; then
    echo "ERROR: git pull failed."
    exit 1
fi

if [ -x /usr/bin/datacore/bash/link.sh ]; then
    /usr/bin/datacore/bash/link.sh
else
    echo "ERROR: link.sh cannot be executed."
    exit 1
fi