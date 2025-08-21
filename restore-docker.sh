#!/bin/bash
# Remove separators from MAC address input
targetmac=${1//[: -]/}

# Magic packet consists of 12 f followed by 16 repetitions of target's MAC address
magicpacket=$(
	printf "f%.0s" {1..12}
	printf "$targetmac%.0s" {1..16}
)

# Hex-escape
# shellcheck disable=SC2001
magicpacket=$(echo "$magicpacket" | sed -e 's/../\x&/g')

# Apply defaults
if [ $# -ge 3 ]; then
	targetip=$2
	targetport=$3
elif [ $# -eq 2 ]; then
	targetip=$2
	targetport=9
else
	targetip="255.255.255.255"
	targetport=""
fi

# Send magic packet
printf "Sending magic packet..."
echo -e "$magicpacket" | nc -w1 -u "$targetip" "$targetport"
printf " Done!"
