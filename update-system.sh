#!/bin/bash
# =======================================================================
# UPDATE SYSTEM SCRIPT to update the Linux System automaticly
# by dataCore
#
# Usage: update-system -y (optional: reboot automaticly)
# Example: update-system -y
#
# HISTORY
# 2024-04-15 Initial Version
#
# =======================================================================
# START script
# =======================================================================

# Check for -y flag to skip confirmation
AUTO_REBOOT=false
for arg in "$@"; do
	if [ "$arg" == "-y" ]; then
		AUTO_REBOOT=true
	fi
done

# Deactivate interactive menues
export DEBIAN_FRONTEND=noninteractive

# Update the script collection
update-scripts	fi

# Start update
apt-get update -y
apt-get upgrade -y

# Clean up unnecessary packages and cache
echo "Cleaning up..."
apt-get -f install
apt-get autoremove -y
apt-get autoclean -y
apt-get clean -y

# Check if a reboot is required
if [ -f /var/run/reboot-required ]; then
  	if [ "$AUTO_REBOOT" = true ]; then
  		echo "[✓] Auto-confirm enabled. Rebooting now..."
  		reboot
  	else
  		read -r -p "System reboot is required. Do you want to reboot now? (y/n): " answer
  		if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
  			echo "[✓] Rebooting now..."
  			reboot
  		else
  			echo "[i] Reboot skipped. Please reboot manually later."
  		fi
  	fi
fi

echo "[✓] All done."
