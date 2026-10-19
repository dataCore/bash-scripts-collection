#!/bin/bash
echo "last reboot:"
date "+%d.%m.%Y %H:%M:%S" -d "$(uptime -s)"
