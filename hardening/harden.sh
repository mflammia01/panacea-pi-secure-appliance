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

# ── PRE-FLIGHT: Ensure SSH key is installed ──────────────────────
AUTH_KEYS="/home/${ADMIN_USER}/.ssh/authorized_keys"
if [ ! -s "$AUTH_KEYS" ]; then
  echo
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  ⚠️  NO SSH PUBLIC KEY FOUND                                ║"
  echo "║  Password auth will be DISABLED — you WILL be locked out!  ║"
  echo "║                                                            ║"
  echo "║  From your BUILD COMPUTER, run:                            ║"
  echo "║  ssh-keygen -t ed25519  (if you don't have a key yet)      ║"
  echo "║  ssh-copy-id ${ADMIN_USER}@$(hostname).local               ║"
  echo "║                                                            ║"
  echo "║  Then re-run this script.                                  ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo
  exit 1
fi
echo "✅ SSH public key found for $ADMIN_USER"

echo "Installing security packages..."
sudo apt update
sudo apt install -y ufw fail2ban unattended-upgrades apt-listchanges usbguard ca-certificates curl cryptsetup

# SSH hardening — key-only, no passwords
echo "Hardening SSH..."
sudo install -d /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/panacea-hardening.conf >/dev/null <<CONF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AllowUsers ${ADMIN_USER}
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AuthenticationMethods publickey
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

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ HARDENING COMPLETE                                     ║"
echo "║                                                            ║"
echo "║  SSH is now key-only (password login disabled).            ║"
echo "║  Next: Run device/encrypt.sh for LUKS root encryption.    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
sleep 5
sudo reboot
