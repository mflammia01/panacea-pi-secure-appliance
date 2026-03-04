#!/usr/bin/env bash
set -euo pipefail

sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on lo
sudo ufw allow out on lo
sudo ufw --force enable

sudo systemctl restart ssh || sudo systemctl restart sshd

echo "Sealed. LAN inbound denied. Only loopback allowed."
