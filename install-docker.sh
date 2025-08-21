#!/bin/bash
apt-get update && 	apt-get install ca-certificates curl gnupg lsb-release unattended-upgrades nfs-common -y && 	mkdir -p /etc/apt/keyrings && 	curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && 	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null && 	apt-get update && 	apt-get install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y && 	cat <<'EOF' >/etc/docker/daemon.json
{
  "default-address-pools": [
    {
      "base": "172.17.0.0/16",
      "size": 24
    }
  ]
}
EOF
