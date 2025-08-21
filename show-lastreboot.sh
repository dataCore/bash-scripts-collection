#!/bin/bash
echo "last reboot:"
date "+%d.%m.%Y %H:%M:%S" -d "$(</proc/uptime awk '{print $1}') seconds ago"
