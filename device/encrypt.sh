#!/usr/bin/env bash
set -euo pipefail

# Encrypted Data Vault for Raspberry Pi 5
# Creates a LUKS-encrypted container at /opt/vault.luks, mounted at /secure
# Auto-unlocks on boot using a hardware-derived key (CPU serial + salt)
# The key is NEVER stored on disk — it is derived at every boot
# Run AFTER harden.sh, BEFORE Twingate install

VAULT_FILE="/opt/vault.luks"
VAULT_MAPPER="panacea_vault"
MOUNT_POINT="/secure"
VAULT_SIZE_MB=5120

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  🔒 ENCRYPTED DATA VAULT SETUP                             ║"
echo "║                                                            ║"
echo "║  This creates a $VAULT_SIZE_MB MB LUKS-encrypted container          ║"
echo "║  at $VAULT_FILE, mounted at $MOUNT_POINT.                 ║"
echo "║                                                            ║"
echo "║  The vault auto-unlocks on boot using the Pi's CPU serial. ║"
echo "║  No passphrase needed — headless reboot is fully supported. ║"
echo "║  The key is derived at boot and NEVER stored on disk.      ║"
echo "║                                                            ║"
echo "║  SSH host keys, authorized_keys, and logs will be moved    ║"
echo "║  into the vault and symlinked back.                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

# Safety check
read -rp "Type YES to create the encrypted vault: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted."
  exit 0
fi

# Install cryptsetup
sudo apt update
sudo apt install -y cryptsetup

# ── Derive hardware-bound key (used only during this script, never stored) ──
CPU_SERIAL=$(grep Serial /proc/cpuinfo | awk '{print $3}')
if [ -z "$CPU_SERIAL" ] || [ "$CPU_SERIAL" = "0000000000000000" ]; then
  echo "❌ Could not read CPU serial. Is this a Raspberry Pi?"
  exit 1
fi
SALT="panacea-vault-$(hostname)"
echo "✅ CPU serial read successfully"

# ── Create LUKS container ─────────────────────────────────────
echo "Creating ${VAULT_SIZE_MB}MB container file..."
sudo dd if=/dev/zero of="$VAULT_FILE" bs=1M count=$VAULT_SIZE_MB status=progress
sudo chmod 600 "$VAULT_FILE"

echo "Formatting with LUKS2 AES-256 (key derived from CPU serial, not stored)..."
echo -n "${CPU_SERIAL}:${SALT}" | sha256sum | awk '{print $1}' | \
  sudo cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 \
  --key-size 512 --hash sha256 --batch-mode \
  "$VAULT_FILE" /dev/stdin

echo "Opening vault..."
echo -n "${CPU_SERIAL}:${SALT}" | sha256sum | awk '{print $1}' | \
  sudo cryptsetup open --type luks2 --key-file=- \
  "$VAULT_FILE" "$VAULT_MAPPER"

echo "Creating ext4 filesystem..."
sudo mkfs.ext4 -L panacea-vault "/dev/mapper/$VAULT_MAPPER"

# ── Mount ──────────────────────────────────────────────────────
sudo mkdir -p "$MOUNT_POINT"
sudo mount "/dev/mapper/$VAULT_MAPPER" "$MOUNT_POINT"

# Create vault directory structure
sudo mkdir -p "$MOUNT_POINT"/{ssh,twingate,auth_keys,logs,secrets}
sudo chmod 700 "$MOUNT_POINT"/secrets
echo "✅ Vault mounted at $MOUNT_POINT"

# ── Move SSH host keys into vault ─────────────────────────────
echo "Moving SSH host keys into vault..."
if ls /etc/ssh/ssh_host_* 1>/dev/null 2>&1; then
  sudo cp -a /etc/ssh/ssh_host_* "$MOUNT_POINT/ssh/"
  for f in /etc/ssh/ssh_host_*; do
    sudo rm "$f"
    sudo ln -s "$MOUNT_POINT/ssh/$(basename $f)" "$f"
  done
  echo "✅ SSH host keys moved and symlinked"
fi

# ── Move authorized_keys into vault ───────────────────────────
ADMIN_USER=$(logname 2>/dev/null || echo "$SUDO_USER")
AUTH_KEYS="/home/$ADMIN_USER/.ssh/authorized_keys"
if [ -f "$AUTH_KEYS" ] && [ ! -L "$AUTH_KEYS" ]; then
  sudo cp -a "$AUTH_KEYS" "$MOUNT_POINT/auth_keys/authorized_keys"
  sudo rm "$AUTH_KEYS"
  sudo ln -s "$MOUNT_POINT/auth_keys/authorized_keys" "$AUTH_KEYS"
  echo "✅ authorized_keys moved and symlinked"
fi

# ── Create log directory ──────────────────────────────────────
sudo mkdir -p /var/log/panacea
if [ ! -L /var/log/panacea ]; then
  sudo rm -rf /var/log/panacea
  sudo ln -s "$MOUNT_POINT/logs" /var/log/panacea
  echo "✅ /var/log/panacea → vault"
fi

# ── Create systemd service for auto-mount ─────────────────────
# Key is derived at boot from CPU serial — never touches disk
echo "Creating systemd auto-mount service..."
sudo tee /etc/systemd/system/panacea-vault.service >/dev/null <<'SERVICE'
[Unit]
Description=Panacea Encrypted Data Vault
DefaultDependencies=no
After=local-fs.target
Before=ssh.service sshd.service twingate-connector.service twingate.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'S=$(grep Serial /proc/cpuinfo | awk "{print \$3}"); H=$(hostname); echo -n "${S}:panacea-vault-${H}" | sha256sum | awk "{print \$1}" | /sbin/cryptsetup open --type luks2 --key-file=- /opt/vault.luks panacea_vault'
ExecStartPost=/bin/mount /dev/mapper/panacea_vault /secure
ExecStop=/bin/umount /secure
ExecStopPost=/sbin/cryptsetup close panacea_vault

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable panacea-vault.service
echo "✅ Vault auto-mount service enabled"

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ ENCRYPTED DATA VAULT CREATED                           ║"
echo "║                                                            ║"
echo "║  Vault:    $VAULT_FILE ($VAULT_SIZE_MB MB, LUKS2 AES-256)  ║"
echo "║  Mounted:  $MOUNT_POINT                                    ║"
echo "║  Key:      Derived at boot (CPU serial + hostname salt)    ║"
echo "║            ⚠️  Key is NEVER stored on disk                  ║"
echo "║  Service:  panacea-vault.service (auto-starts on boot)     ║"
echo "║                                                            ║"
echo "║  ✅ SSH host keys → /secure/ssh/                           ║"
echo "║  ✅ authorized_keys → /secure/auth_keys/                   ║"
echo "║  ✅ Logs → /secure/logs/                                   ║"
echo "║  ⏳ Twingate config → will be moved after install          ║"
echo "║                                                            ║"
echo "║  🔑 IMPORTANT: Record this Pi's CPU serial in your         ║"
echo "║     inventory (ops/inventory.csv) for disaster recovery.   ║"
echo "║                                                            ║"
echo "║  The device will reboot unattended — no passphrase needed. ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
echo "Rebooting in 5 seconds to test vault auto-mount... (Ctrl+C to cancel)"
sleep 5
sudo reboot
