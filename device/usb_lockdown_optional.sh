#!/usr/bin/env bash
set -euo pipefail

echo "Unplug any temporary USB devices now."
read -r -p "Type YES to generate allowlist from current devices: " OK
[[ "$OK" == "YES" ]]

sudo tee /etc/modprobe.d/panacea-usb-storage-blacklist.conf >/dev/null <<'BLOCK'
blacklist usb_storage
blacklist uas
BLOCK

sudo install -d -m 0755 /etc/usbguard
sudo usbguard generate-policy --no-hashes | sudo tee /etc/usbguard/rules.conf >/dev/null
sudo systemctl enable --now usbguard

echo "USBGuard enabled. Reboot recommended."
