#!/usr/bin/env bash
set -euo pipefail

echo "════════════════════════════════════════════"
echo "  PANACEA DEVICE VERIFICATION"
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

# ── SSH Symlinks ──────────────────────────────
echo "── SSH Host Key Symlinks ──"
for f in /etc/ssh/ssh_host_*; do
  if [ -L "$f" ]; then
    TARGET=$(readlink "$f")
    if [[ "$TARGET" == /secure/* ]]; then
      echo "✅ $f → $TARGET"
    else
      echo "⚠️  $f → $TARGET (not in /secure!)"
    fi
  elif [ -f "$f" ]; then
    echo "❌ $f is a regular file (not symlinked to vault)"
  fi
done
echo

# ── Twingate in Vault ─────────────────────────
echo "── Twingate Config ──"
if [ -L /etc/twingate ]; then
  echo "✅ /etc/twingate → $(readlink /etc/twingate)"
elif [ -d /etc/twingate ]; then
  echo "⚠️  /etc/twingate exists but is NOT symlinked to vault"
else
  echo "ℹ️  Twingate not installed yet"
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
echo "════════════════════════════════════════════"
echo "  VERIFICATION COMPLETE"
echo "════════════════════════════════════════════"
EOF
