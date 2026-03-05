cat > device/seal.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ── Migrate Twingate config into vault (if not already done) ──
if [ -d /etc/twingate ] && [ ! -L /etc/twingate ]; then
  echo "Migrating Twingate config into encrypted vault..."
  sudo systemctl stop twingate-connector || true
  mountpoint -q /secure || { echo "❌ /secure not mounted"; exit 1; }
  sudo mkdir -p /secure/twingate
  sudo cp -a /etc/twingate/. /secure/twingate/
  if [ -f /secure/twingate/connector.conf ]; then
    sudo rm -rf /etc/twingate
    sudo ln -s /secure/twingate /etc/twingate
    echo "✅ Twingate config migrated and symlinked"
  else
    echo "⚠️  connector.conf not found in vault — skipping migration"
  fi
  sudo systemctl start twingate-connector || true
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

echo "Sealed. All inbound blocked except SSH (port 22)."
if systemctl is-active --quiet twingate-connector 2>/dev/null; then
  echo "✅ Twingate connector is running"
fi
EOF
