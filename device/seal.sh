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

# ── Migrate Twingate config into vault (bind mount) ──────────
# Twingate Client rejects symlinks — use bind mount instead.
# /etc/twingate stays a real directory; data lives in /secure/twingate.

# Fix legacy symlink from older seal.sh versions
if [ -L /etc/twingate ]; then
  echo "⚠️  Found legacy symlink — converting to bind mount..."
  if systemctl list-unit-files twingate-connector.service 2>/dev/null | grep -q twingate-connector; then
    sudo systemctl stop twingate-connector || true
  fi
  if systemctl list-unit-files twingate.service 2>/dev/null | grep -q twingate; then
    sudo systemctl stop twingate || true
  fi
  sudo rm /etc/twingate
  sudo mkdir -p /etc/twingate
fi

if mountpoint -q /etc/twingate 2>/dev/null; then
  echo "ℹ️  /etc/twingate already bind-mounted from vault — skipping"
elif [ -d /etc/twingate ]; then
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
    # Normalize permissions (Twingate expects 755, not 700)
    sudo chmod 755 /secure/twingate
    sudo mount --bind /secure/twingate /etc/twingate
    echo "✅ Twingate config migrated and bind-mounted from vault"
  else
    echo "⚠️  connector.conf not found in vault — skipping migration"
  fi
fi

# ── Install systemd unit for persistent bind mount on boot ────
if [ ! -f /etc/systemd/system/panacea-twingate-vault.service ]; then
  echo "Creating persistent bind mount service..."
  sudo tee /etc/systemd/system/panacea-twingate-vault.service >/dev/null <<'UNIT'
[Unit]
Description=Bind-mount Twingate config from encrypted vault
After=panacea-vault.service
Requires=panacea-vault.service
Before=twingate-connector.service twingate.service
ConditionPathExists=/secure/twingate

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount --bind /secure/twingate /etc/twingate
ExecStop=/bin/umount /etc/twingate

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable panacea-twingate-vault.service
  echo "✅ panacea-twingate-vault.service enabled"
fi

# ── Firewall lockdown ─────────────────────────────────────────
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow in on lo
sudo ufw allow out on lo
sudo ufw --force enable

# ── Dual-role routing: allow forwarding between LAN and Twingate overlay ──
if ip link show sdwan0 &>/dev/null; then
  echo "Detected sdwan0 (Twingate Client) — adding FORWARD rules for dual-role routing..."
  sudo ufw route allow in on eth0 out on sdwan0
  sudo ufw route allow in on sdwan0 out on eth0
  echo "✅ UFW FORWARD rules added (eth0 ↔ sdwan0)"
fi

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
