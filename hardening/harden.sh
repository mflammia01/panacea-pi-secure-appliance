#!/usr/bin/env bash
set -euo pipefail

# Admin username — pass via env var or enter when prompted
ADMIN_USER="${ADMIN_USER:-}"
if [ -z "$ADMIN_USER" ]; then
  read -rp "Enter admin username (must match Raspberry Pi Imager): " ADMIN_USER
fi
if [ -z "$ADMIN_USER" ]; then
  echo "Error: admin username cannot be empty" >&2
  exit 1
fi
echo "Using admin user: $ADMIN_USER"

echo "Installing security packages..."
sudo apt update
sudo apt install -y ufw fail2ban unattended-upgrades apt-listchanges usbguard ca-certificates curl cryptsetup libpam-google-authenticator

# LUKS full-disk encryption
echo "Setting up LUKS encryption..."
echo "⚠️  LUKS encryption of the root partition on a running system requires"
echo "   an offline migration. For production, encrypt during image preparation."
echo "   For now, this script ensures cryptsetup is installed and ready."
echo "   See: https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system"
echo

# SSH hardening
echo "Hardening SSH..."
sudo install -d /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/panacea-hardening.conf >/dev/null <<CONF
PasswordAuthentication no
KbdInteractiveAuthentication yes
PermitRootLogin no
PubkeyAuthentication yes
AllowUsers ${ADMIN_USER}
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AuthenticationMethods publickey,keyboard-interactive
CONF

# Enable fail2ban ssh jail
echo "Configuring fail2ban..."
sudo install -d /etc/fail2ban/jail.d
sudo tee /etc/fail2ban/jail.d/sshd.local >/dev/null <<JAIL
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
JAIL
sudo systemctl enable fail2ban || true

# Enable unattended upgrades
echo "Enabling unattended upgrades..."
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<AUTO
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
AUTO
sudo systemctl enable unattended-upgrades || true

# Disable USB mass storage
echo "Blocking USB mass storage..."
sudo tee /etc/modprobe.d/panacea-usb-storage-blacklist.conf >/dev/null <<USB
blacklist usb_storage
blacklist uas
USB

# Firewall baseline
echo "Setting up firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow in on lo
sudo ufw allow out on lo
sudo ufw --force enable

# Configure PAM for Google Authenticator
echo "Configuring SSH 2FA (TOTP)..."
sudo sed -i 's/^@include common-auth$/#@include common-auth/' /etc/pam.d/sshd
echo "auth required pam_google_authenticator.so" | sudo tee -a /etc/pam.d/sshd >/dev/null

# Enroll TOTP for the admin user
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  SETTING UP 2FA — A QR CODE WILL APPEAR BELOW              ║"
echo "║  Screenshot it or copy the secret key to share with staff   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
google-authenticator -t -d -f -r 3 -R 30 -w 3

echo
echo "✅ Hardening + 2FA complete. Reboot recommended."
echo "   sudo reboot"
EOF
