#!/usr/bin/env bash
set -euo pipefail

# LUKS Root Partition Encryption for Raspberry Pi 5 (SD Card)
# Run AFTER harden.sh, BEFORE seal.sh

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  🔒 LUKS ROOT PARTITION ENCRYPTION                         ║"
echo "║                                                            ║"
echo "║  This will encrypt your root partition with AES-256.       ║"
echo "║  You will need to enter a passphrase on every boot.        ║"
echo "║                                                            ║"
echo "║  ⚠️  BACK UP ANY DATA FIRST — this is destructive.         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

# Detect root device
ROOT_DEV=$(findmnt -no SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV")
echo "Detected root partition: $ROOT_DEV (on /dev/$ROOT_DISK)"
echo

# Safety check
read -rp "Type YES to proceed with LUKS encryption of $ROOT_DEV: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted."
  exit 0
fi

# Install required packages
sudo apt update
sudo apt install -y cryptsetup cryptsetup-initramfs

# Configure cryptsetup-initramfs
echo "CRYPTSETUP=y" | sudo tee /etc/cryptsetup-initramfs/conf-hook >/dev/null

echo
echo "You will now set the LUKS passphrase."
echo "This passphrase is required on EVERY boot."
echo "Save it in your password manager immediately."
echo

# Shrink filesystem to make room for LUKS header
echo "Running filesystem check..."
sudo e2fsck -f "$ROOT_DEV"

PART_SIZE=$(sudo blockdev --getsize64 "$ROOT_DEV")
BLOCK_SIZE=$(sudo dumpe2fs -h "$ROOT_DEV" 2>/dev/null | grep "Block size" | awk '{print $3}')
SHRINK_BLOCKS=$(( (PART_SIZE - 33554432) / BLOCK_SIZE ))

echo "Shrinking filesystem to make room for LUKS header..."
sudo resize2fs "$ROOT_DEV" "$SHRINK_BLOCKS"

# Encrypt in-place
echo "Encrypting partition — this may take several minutes..."
echo "You will be prompted to set your LUKS passphrase."
sudo cryptsetup reencrypt --encrypt --reduce-device-size 32M "$ROOT_DEV" \
  --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha256

# Update crypttab
ROOT_UUID=$(sudo blkid -s UUID -o value "$ROOT_DEV")
echo "crypt_root UUID=$ROOT_UUID none luks,initramfs" | sudo tee /etc/crypttab >/dev/null

# Update fstab to use mapper device
sudo sed -i "s|PARTUUID=[^ ]*|/dev/mapper/crypt_root|" /etc/fstab

# Update initramfs
sudo update-initramfs -u -k all

# Update boot config
sudo sed -i "s|root=[^ ]*|root=/dev/mapper/crypt_root cryptdevice=UUID=$ROOT_UUID:crypt_root|" /boot/firmware/cmdline.txt

# Expand filesystem back to fill LUKS container
sudo cryptsetup open "$ROOT_DEV" crypt_root
sudo resize2fs /dev/mapper/crypt_root

# Back up LUKS header
HEADER_BACKUP="/home/$(logname)/luks-header-backup-$(date +%Y%m%d).img"
sudo cryptsetup luksHeaderBackup "$ROOT_DEV" --header-backup-file "$HEADER_BACKUP"
sudo chown "$(logname):$(logname)" "$HEADER_BACKUP"

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ LUKS ENCRYPTION COMPLETE                               ║"
echo "║                                                            ║"
echo "║  Header backup: $HEADER_BACKUP"
echo "║  Copy this file OFF the device to a secure location.       ║"
echo "║                                                            ║"
echo "║  On next boot, you will be prompted for the passphrase.    ║"
echo "║  Save the passphrase in your password manager NOW.         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
read -rp "Have you saved the passphrase and header backup? (yes/no): " SAVED
if [ "$SAVED" != "yes" ]; then
  echo "❌ Reboot cancelled. Save your passphrase first, then: sudo reboot"
  exit 0
fi
echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
sleep 5
sudo reboot
