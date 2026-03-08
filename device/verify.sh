#!/usr/bin/env bash
set -euo pipefail

DEVICE_NAME=$(hostname)

echo "════════════════════════════════════════════"
echo "  PANACEA DEVICE VERIFICATION — $DEVICE_NAME"
echo "════════════════════════════════════════════"
echo

echo "Kernel:"; uname -a
echo

# ── Encrypted Vault ───────────────────────────
echo "── Encrypted Data Vault ──"
if mountpoint -q /secure 2>/dev/null; then
  echo "✅ /secure is mounted"
  sudo cryptsetup status panacea_vault 2>/dev/null && echo "✅ LUKS vault active" || echo "⚠️  Vault mapper not found"
  echo "  Vault contents:"
  ls -la /secure/ 2>/dev/null || true
else
  echo "❌ /secure is NOT mounted — run device/encrypt.sh"
fi
echo

# ── Vault Service ─────────────────────────────
echo "── Vault Service ──"
sudo systemctl is-enabled panacea-vault.service 2>/dev/null && echo "✅ panacea-vault.service enabled" || echo "❌ panacea-vault.service not enabled"
sudo systemctl is-active panacea-vault.service 2>/dev/null && echo "✅ panacea-vault.service running" || echo "⚠️  panacea-vault.service not active"
echo

# ── SSH Host Keys ─────────────────────────────
echo "── SSH Host Keys ──"
if ls /etc/ssh/ssh_host_* 1>/dev/null 2>&1; then
  echo "✅ SSH host keys present in /etc/ssh/"
  if [ -L /etc/ssh/ssh_host_ed25519_key ]; then
    echo "⚠️  Host keys are symlinked (legacy setup) — consider restoring local copies"
  fi
else
  echo "❌ No SSH host keys found in /etc/ssh/"
fi
echo

# ── authorized_keys ───────────────────────────
echo "── authorized_keys ──"
AUTH_KEYS="$HOME/.ssh/authorized_keys"
if [ -f "$AUTH_KEYS" ] && [ ! -L "$AUTH_KEYS" ]; then
  echo "✅ authorized_keys present and local"
elif [ -L "$AUTH_KEYS" ]; then
  echo "❌ authorized_keys is symlinked — should stay local"
else
  echo "❌ authorized_keys missing"
fi
echo

# ── Twingate in Vault ─────────────────────────
echo "── Twingate Config ──"
if mountpoint -q /etc/twingate 2>/dev/null; then
  echo "✅ /etc/twingate is bind-mounted from vault"
  if sudo test -f /secure/twingate/connector.conf; then
    echo "✅ connector.conf present in vault"
  else
    echo "❌ connector.conf MISSING from vault — re-run setup"
  fi
elif [ -L /etc/twingate ]; then
  echo "❌ /etc/twingate is a symlink (breaks Twingate Client) — re-run seal.sh to fix"
elif [ -d /etc/twingate ]; then
  echo "⚠️  /etc/twingate exists but is NOT vault-backed — run seal.sh"
else
  echo "ℹ️  Twingate not installed yet"
fi
if systemctl is-active --quiet twingate-connector 2>/dev/null; then
  echo "✅ twingate-connector service is running"
else
  echo "⚠️  twingate-connector service is NOT running"
fi
echo

# ── Twingate Client (optional — Step 7) ──
echo "── Twingate Client (optional) ──"
if systemctl list-unit-files twingate.service 2>/dev/null | grep -q '^twingate\.service'; then
  if systemctl is-active --quiet twingate 2>/dev/null; then
    echo "✅ twingate client service is running"
  else
    echo "⚠️  twingate client service is NOT running"
  fi
else
  echo "ℹ️  Twingate client not installed (optional — Step 7)"
fi
echo

# ── Standard checks ──────────────────────────
echo "── Disk/crypto state ──"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS
echo
echo "── UFW ──"; sudo ufw status verbose || true
echo
echo "── SSHD ──"; sudo sshd -T 2>/dev/null | egrep 'passwordauthentication|permitrootlogin|pubkeyauthentication|allowusers|authenticationmethods' || true
echo
echo "── fail2ban ──"; sudo systemctl is-enabled fail2ban 2>/dev/null && sudo fail2ban-client status sshd || true
echo
echo "── unattended-upgrades ──"; systemctl is-enabled unattended-upgrades 2>/dev/null || true
echo
echo "── USBGuard ──"
if systemctl is-active --quiet usbguard 2>/dev/null; then
  echo "✅ USBGuard is running"
elif systemctl is-enabled --quiet usbguard 2>/dev/null; then
  echo "⚠️  USBGuard enabled but not active"
else
  echo "ℹ️  USBGuard not installed (optional — see Step 10)"
fi
echo
echo "── Serial Console ──"
if [ -f device/serial-console.sh ] || [ -f /usr/local/bin/serial-console.sh ]; then
  echo "✅ serial-console.sh present"
else
  echo "ℹ️  serial-console.sh not found (optional — see Step 11)"
fi
echo
echo "════════════════════════════════════════════"
echo "  VERIFICATION COMPLETE — $DEVICE_NAME"
echo "════════════════════════════════════════════"
