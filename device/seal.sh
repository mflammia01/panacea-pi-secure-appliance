#!/usr/bin/env bash
set -euo pipefail

DEVICE_NAME=$(hostname)

# ── Check vault is mounted ─────────────────────────────────────
if ! mountpoint -q /secure; then
  echo "❌ /secure not mounted — attempting to start vault service..."
  sudo systemctl start panacea-vault.service
  sleep 2
  if ! mountpoint -q /secure; then
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "  FATAL: /secure still not mounted after service start"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo "── Service status ──"
    sudo systemctl status panacea-vault.service --no-pager 2>&1 || true
    echo ""
    echo "── Recent journal logs ──"
    sudo journalctl -u panacea-vault.service -b --no-pager 2>&1 | tail -n 30
    echo ""
    echo ""
    echo "── Service unit file ──"
    sudo systemctl cat panacea-vault.service 2>&1 || true
    echo ""
    echo "Troubleshooting:"
    echo "  1. If logs show 'unset environment variable H, S' → pull latest encrypt.sh and re-run it"
    echo "  2. Check hostname hasn't changed: hostname"
    echo "  3. Check CPU serial: grep Serial /proc/cpuinfo"
    echo "  4. Check vault file exists: ls -la /opt/vault.luks"
    echo "  5. Check helper script exists: ls -la /usr/local/sbin/panacea-vault-mount.sh"
    exit 1
  fi
  echo "✅ Vault service started — /secure is now mounted"
fi

# ── Migrate Twingate config into vault (if not already done) ──
if [ -d /etc/twingate ] && [ ! -L /etc/twingate ]; then
  echo "Migrating Twingate config into encrypted vault..."
  if systemctl list-unit-files twingate-connector.service 2>/dev/null | grep -q twingate-connector; then
    sudo systemctl stop twingate-connector || true
  fi
  if systemctl list-unit-files twingate.service 2>/dev/null | grep -q twingate; then
    sudo systemctl stop twingate || true
  fi
  sudo mkdir -p /secure/twingate
  sudo cp -a /etc/twingate/. /secure/twingate/
  if [ -f /secure/twingate/connector.conf ]; then
    sudo rm -rf /etc/twingate
    sudo ln -s /secure/twingate /etc/twingate
    echo "✅ Twingate config migrated and symlinked"
  else
    echo "⚠️  connector.conf not found in vault — skipping migration"
  fi
elif [ -L /etc/twingate ]; then
  echo "ℹ️  Twingate already symlinked to vault — skipping"
fi

# ── Firewall lockdown ─────────────────────────────────────────
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow in on lo
sudo ufw allow out on lo
sudo ufw --force enable

sudo systemctl restart ssh || sudo systemctl restart sshd

# ── Restart Twingate AFTER firewall is fully configured ───────
echo "Restarting Twingate connector against final firewall state..."
sudo systemctl restart twingate-connector || true
if systemctl list-unit-files twingate.service 2>/dev/null | grep -q twingate; then
  sudo systemctl restart twingate || true
fi
sleep 5

echo "════════════════════════════════════════════"
echo "  DEVICE SEALED — $DEVICE_NAME"
echo "════════════════════════════════════════════"
echo "All inbound blocked except SSH (port 22)."
if systemctl is-active --quiet twingate-connector 2>/dev/null; then
  echo "✅ Twingate connector is running"
else
  echo "⚠️  Twingate connector not running — check: sudo journalctl -u twingate-connector"
fi
if systemctl list-unit-files twingate.service 2>/dev/null | grep -q '^twingate\.service'; then
  if systemctl is-active --quiet twingate 2>/dev/null; then
    echo "✅ Twingate client is running"
  else
    echo "⚠️  Twingate client is installed but not running"
  fi
else
  echo "ℹ️  Twingate client not installed (optional — Step 7)"
fi
