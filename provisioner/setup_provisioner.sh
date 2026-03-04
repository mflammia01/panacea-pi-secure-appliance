#!/usr/bin/env bash
set -euo pipefail

echo "=== Panacea Provisioner Pi Setup ==="
echo

# System update
echo "Updating system packages..."
sudo apt update && sudo apt full-upgrade -y

# Install dependencies
echo "Installing required tools..."
sudo apt install -y git rpiboot curl wget xz-utils

# Download latest Raspberry Pi OS Lite image
echo "Downloading latest Raspberry Pi OS Lite (64-bit)..."
mkdir -p ~/images && cd ~/images
rm -f *.img.xz *.sha1 *.img

LATEST=$(curl -s https://downloads.raspberrypi.com/raspios_lite_arm64/images/ | grep -oP 'raspios_lite_arm64-[\d-]+' | sort | tail -1)
FILE=$(curl -s "https://downloads.raspberrypi.com/raspios_lite_arm64/images/${LATEST}/" | grep -oP '[\w.-]+\.img\.xz(?=")' | head -1)
BASE="https://downloads.raspberrypi.com/raspios_lite_arm64/images/${LATEST}"

echo "Downloading: ${FILE} from ${LATEST}"
wget -4 -O "${FILE}" "${BASE}/${FILE}"
wget -4 -O "${FILE}.sha1" "${BASE}/${FILE}.sha1"

echo "Verifying checksum..."
sha1sum -c *.sha1
echo "Extracting image..."
xz -dk *.img.xz
ls -lh *.img

echo
echo "? Provisioner setup complete."
echo "   OS image ready in ~/images/"
echo "   Reboot recommended: sudo reboot"
