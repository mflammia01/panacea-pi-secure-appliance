#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════
#  Panacea Auto-Provisioner — single-script, reboot-safe build
# ══════════════════════════════════════════════════════════════
#
# Usage:  sudo bash device/auto-provision.sh
#
# On first run it installs itself as a systemd service so the
# build resumes automatically after each reboot.  Progress is
# tracked in /var/lib/panacea/provision.state (one word: the
# current stage name).
#
# Edit the variables below before running.
# ──────────────────────────────────────────────────────────────

# ── REQUIRED ─────────────────────────────────────────────────
ADMIN_USER="${ADMIN_USER:-$(logname 2>/dev/null || whoami)}"
if [ -z "$ADMIN_USER" ] || echo "$ADMIN_USER" | grep -q '[<>]'; then
  echo "❌ ADMIN_USER could not be detected and was not set." >&2
  echo "   Re-run with:  sudo ADMIN_USER=<your_user> bash $0" >&2
  exit 1
fi

# Auto-detect REPO_DIR from script location if not set
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-${SCRIPT_DIR%/device}}"

# ── OPTIONAL STAGES (yes / no) ──────────────────────────────
ENABLE_TWINGATE_CONNECTOR="${ENABLE_TWINGATE_CONNECTOR:-yes}"
ENABLE_TWINGATE_CLIENT="${ENABLE_TWINGATE_CLIENT:-no}"
ENABLE_MONITORING="${ENABLE_MONITORING:-yes}"

ENABLE_CIS_STAGE1="${ENABLE_CIS_STAGE1:-no}"
ENABLE_CIS_STAGE2="${ENABLE_CIS_STAGE2:-no}"
ENABLE_WAZUH="${ENABLE_WAZUH:-no}"
ENABLE_ZABBIX="${ENABLE_ZABBIX:-no}"

# Wazuh / Zabbix connection details (only needed if enabled)
WAZUH_MANAGER="${WAZUH_MANAGER:-}"
WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP:-default}"
ZABBIX_SERVER_ACTIVE="${ZABBIX_SERVER_ACTIVE:-}"

# ── STATE FILE ───────────────────────────────────────────────
STATE_DIR="/var/lib/panacea"
STATE_FILE="${STATE_DIR}/provision.state"

mkdir -p "$STATE_DIR"

get_stage()  { cat "$STATE_FILE" 2>/dev/null || echo "init"; }
set_stage()  { echo "$1" > "$STATE_FILE"; echo "▸ Stage → $1"; }

# ── INSTALL SYSTEMD SERVICE (first run only) ─────────────────
install_service() {
  if [ ! -f /etc/systemd/system/panacea-provision.service ]; then
    echo "Installing systemd service for reboot recovery..."
    cat > /etc/systemd/system/panacea-provision.service <<'UNIT'
[Unit]
Description=Panacea auto-provisioner (reboot-safe)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash REPO_DIR_PLACEHOLDER/device/auto-provision.sh
StandardOutput=journal+console
StandardError=journal+console
Environment=ADMIN_USER=ADMIN_USER_PLACEHOLDER
Environment=REPO_DIR=REPO_DIR_PLACEHOLDER

[Install]
WantedBy=multi-user.target
UNIT
    # Patch placeholders
    sed -i "s|REPO_DIR_PLACEHOLDER|$REPO_DIR|g" /etc/systemd/system/panacea-provision.service
    sed -i "s|ADMIN_USER_PLACEHOLDER|$ADMIN_USER|g" /etc/systemd/system/panacea-provision.service
    systemctl daemon-reload
    systemctl enable panacea-provision.service
    echo "✅ panacea-provision.service installed and enabled"
  fi
}

# ── STAGE RUNNERS ────────────────────────────────────────────

run_harden() {
  echo "══ Stage: harden ══"
  set_stage "encrypt"          # write NEXT stage before reboot
  export ADMIN_USER
  export PANACEA_AUTO_PROVISION=1
  bash "$REPO_DIR/hardening/harden.sh"
  # harden.sh reboots — execution stops here
}

run_encrypt() {
  echo "══ Stage: encrypt ══"
  set_stage "verify_vault"     # write NEXT stage before reboot
  export PANACEA_AUTO_PROVISION=1
  bash "$REPO_DIR/device/encrypt.sh"
  # encrypt.sh reboots — execution stops here
}

run_verify_vault() {
  echo "══ Stage: verify_vault ══"

  # ── Self-healing: recreate missing service/helper if vault file exists ──
  if [ -f /opt/vault.luks ] && [ ! -f /etc/systemd/system/panacea-vault.service ]; then
    echo "⚠️  Vault file exists but service is missing — recreating..."
    # Recreate helper script
    cat > /usr/local/sbin/panacea-vault-mount.sh <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
MAPPER="panacea_vault"
MOUNT="/secure"
mkdir -p "$MOUNT"
if [ -e "/dev/mapper/$MAPPER" ]; then
  echo "Vault mapper already open — skipping cryptsetup"
else
  SERIAL=$(grep Serial /proc/cpuinfo | awk '{print $3}')
  HOST=$(hostname)
  KEY=$(echo -n "${SERIAL}:panacea-vault-${HOST}" | sha256sum | awk '{print $1}')
  echo "$KEY" | /sbin/cryptsetup open --type luks2 --key-file=- /opt/vault.luks "$MAPPER"
  echo "Vault mapper opened"
fi
if mountpoint -q "$MOUNT"; then
  echo "$MOUNT already mounted — skipping mount"
else
  /bin/mount "/dev/mapper/$MAPPER" "$MOUNT"
  echo "Mounted $MOUNT"
fi
mountpoint -q "$MOUNT" || { echo "FATAL: $MOUNT failed to mount"; exit 1; }
echo "✅ Vault is ready at $MOUNT"
HELPER
    chmod 755 /usr/local/sbin/panacea-vault-mount.sh

    # Recreate systemd service
    cat > /etc/systemd/system/panacea-vault.service <<'SERVICE'
[Unit]
Description=Panacea Encrypted Data Vault
After=local-fs.target
Wants=local-fs.target
Before=twingate-connector.service twingate.service
ConditionPathExists=/opt/vault.luks

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/panacea-vault-mount.sh
ExecStop=/bin/umount /secure
ExecStopPost=/sbin/cryptsetup close panacea_vault

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    systemctl enable panacea-vault.service
    echo "✅ Vault service recreated"
  fi

  if ! mountpoint -q /secure 2>/dev/null; then
    echo "Vault not mounted — attempting recovery..."
    systemctl start panacea-vault.service 2>&1 || true
    sleep 3
  fi
  if ! mountpoint -q /secure 2>/dev/null; then
    echo "❌ /secure still not mounted after recovery attempt"
    echo ""
    echo "── Vault service status ──"
    systemctl status panacea-vault.service --no-pager 2>&1 || true
    echo ""
    echo "── Vault service logs ──"
    journalctl -u panacea-vault.service --no-pager -n 20 2>&1 || true
    echo ""
    echo "Fix the issue above, then re-run: sudo bash $REPO_DIR/device/auto-provision.sh"
    exit 1
  fi
  echo "✅ /secure is mounted"
  set_stage "install_twingate"
}

run_install_twingate() {
  if [ "$ENABLE_TWINGATE_CONNECTOR" != "yes" ]; then
    echo "ℹ️  Twingate connector disabled — skipping"
    set_stage "seal"
    return
  fi
  echo "══ Stage: install_twingate ══"

  # Skip if connector is already installed and running
  if systemctl is-active --quiet twingate-connector 2>/dev/null; then
    echo "✅ Twingate connector is already running — skipping install"
    set_stage "seal"
    return
  fi

  SCRIPT="/etc/panacea/twingate-connector-install.sh"

  if [ ! -f "$SCRIPT" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ⏸  PAUSED — Twingate connector credentials needed         ║"
    echo "║                                                            ║"
    echo "║  1. Go to Twingate Admin → deploy a new connector         ║"
    echo "║  2. Copy the generated install command                     ║"
    echo "║  3. Create the install script on this device:              ║"
    echo "║                                                            ║"
    echo "║  sudo install -d -m 0755 /etc/panacea                     ║"
    echo "║  sudo tee /etc/panacea/twingate-connector-install.sh      ║"
    echo "║  Paste the curl command, then Ctrl-D                      ║"
    echo "║  sudo chmod 700 /etc/panacea/twingate-connector-install.sh║"
    echo "║                                                            ║"
    echo "║  4. Re-run:                                                ║"
    echo "║  sudo bash $REPO_DIR/device/auto-provision.sh             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    exit 0
  fi

  echo "Running Twingate connector install script..."
  bash "$SCRIPT"
  sleep 5

  if systemctl is-active --quiet twingate-connector 2>/dev/null; then
    echo "✅ Twingate connector is running"
  else
    echo "⚠️  Twingate connector may not be running yet — check manually"
  fi
  set_stage "seal"
}

run_seal() {
  echo "══ Stage: seal ══"
  bash "$REPO_DIR/device/seal.sh"
  set_stage "verify"
}

run_verify() {
  echo "══ Stage: verify ══"
  bash "$REPO_DIR/device/verify.sh"
  set_stage "monitoring"
}

run_monitoring() {
  if [ "$ENABLE_MONITORING" = "yes" ]; then
    echo "══ Stage: monitoring ══"
    bash "$REPO_DIR/device/monitoring-setup.sh"
  fi
  set_stage "network_check"
}

run_network_check() {
  # Network check timer is already installed by monitoring-setup.sh
  set_stage "install_twingate_client"
}

run_install_twingate_client() {
  if [ "$ENABLE_TWINGATE_CLIENT" = "yes" ]; then
    echo "══ Stage: install_twingate_client ══"
    KEY_FILE="/etc/panacea/twingate-service-key.json"
    if [ ! -f "$KEY_FILE" ]; then
      echo ""
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║  ⏸  PAUSED — Twingate Service Key needed                   ║"
      echo "║                                                            ║"
      echo "║  1. Get a Service Key JSON from Twingate Admin             ║"
      echo "║  2. Place it on this device:                               ║"
      echo "║                                                            ║"
      echo "║  sudo install -m 0600 /dev/stdin \\                        ║"
      echo "║    /etc/panacea/twingate-service-key.json                  ║"
      echo "║  (paste JSON, then Ctrl-D)                                 ║"
      echo "║                                                            ║"
      echo "║  3. Re-run:                                                ║"
      echo "║  sudo bash $REPO_DIR/device/auto-provision.sh             ║"
      echo "╚══════════════════════════════════════════════════════════════╝"
      echo ""
      exit 0
    fi
    # Install Twingate client in headless mode
    curl "https://binaries.twingate.com/client/linux/install.sh" | bash
    twingate setup --headless "$KEY_FILE"
    systemctl enable --now twingate
    echo "✅ Twingate client installed in headless mode"
  fi
  set_stage "cis_stage1"
}

run_cis_stage1() {
  if [ "$ENABLE_CIS_STAGE1" = "yes" ]; then
    echo "══ Stage: cis_stage1 ══"
    bash "$REPO_DIR/hardening/cis-remediate.sh"
  fi
  set_stage "cis_stage2"
}

run_cis_stage2() {
  if [ "$ENABLE_CIS_STAGE2" = "yes" ]; then
    echo "══ Stage: cis_stage2 ══"
    bash "$REPO_DIR/hardening/cis-remediate-2.sh"
  fi
  set_stage "install_wazuh"
}

run_install_wazuh() {
  if [ "$ENABLE_WAZUH" = "yes" ]; then
    echo "══ Stage: install_wazuh ══"
    if [ -z "$WAZUH_MANAGER" ]; then
      echo "❌ WAZUH_MANAGER not set — skipping"
    else
      curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh-archive-keyring.gpg 2>/dev/null || true
      echo "deb [signed-by=/usr/share/keyrings/wazuh-archive-keyring.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee /etc/apt/sources.list.d/wazuh.list
      apt update
      WAZUH_MANAGER="$WAZUH_MANAGER" WAZUH_AGENT_NAME="$(hostname)" WAZUH_AGENT_GROUP="$WAZUH_AGENT_GROUP" apt install -y wazuh-agent
      systemctl daemon-reload
      systemctl enable --now wazuh-agent
      echo "✅ Wazuh agent installed"
    fi
  fi
  set_stage "install_zabbix"
}

run_install_zabbix() {
  if [ "$ENABLE_ZABBIX" = "yes" ]; then
    echo "══ Stage: install_zabbix ══"
    if [ -z "$ZABBIX_SERVER_ACTIVE" ]; then
      echo "❌ ZABBIX_SERVER_ACTIVE not set — skipping"
    else
      apt install -y zabbix-agent2
      sed -i "s/^ServerActive=.*/ServerActive=$ZABBIX_SERVER_ACTIVE/" /etc/zabbix/zabbix_agent2.conf
      sed -i "s/^Hostname=.*/Hostname=$(hostname)/" /etc/zabbix/zabbix_agent2.conf
      systemctl enable --now zabbix-agent2
      echo "✅ Zabbix Agent 2 installed"
    fi
  fi
  set_stage "done"
}

# ── MAIN DISPATCH ────────────────────────────────────────────

install_service

STAGE=$(get_stage)
echo ""
echo "════════════════════════════════════════════"
echo "  Panacea Auto-Provisioner"
echo "  Device:  $(hostname)"
echo "  Stage:   $STAGE"
echo "════════════════════════════════════════════"
echo ""

if [ "$STAGE" = "done" ]; then
  echo "✅ Provisioning already complete."
  echo "   To re-run from scratch: sudo rm $STATE_FILE && sudo bash $0"
  exit 0
fi

# Walk through stages — each function either advances or exits (reboot/pause)
case "$STAGE" in
  init)               set_stage "harden" ;&
  harden)             run_harden ;;
  encrypt)            run_encrypt ;;
  verify_vault)       run_verify_vault ;&
  install_twingate)   run_install_twingate ;&
  seal)               run_seal ;&
  verify)             run_verify ;&
  monitoring)         run_monitoring ;&
  network_check)      run_network_check ;&
  install_twingate_client) run_install_twingate_client ;&
  cis_stage1)         run_cis_stage1 ;&
  cis_stage2)         run_cis_stage2 ;&
  install_wazuh)      run_install_wazuh ;&
  install_zabbix)     run_install_zabbix ;;
  *)
    echo "❌ Unknown stage: $STAGE"
    echo "   Valid stages: init harden encrypt verify_vault install_twingate seal verify monitoring done"
    exit 1
    ;;
esac

FINAL=$(get_stage)
if [ "$FINAL" = "done" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  ✅ PROVISIONING COMPLETE                                   ║"
  echo "║                                                            ║"
  echo "║  All stages finished successfully.                         ║"
  echo "║  Run device/verify.sh for a full status check.             ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  # Disable the service — no longer needed
  systemctl disable panacea-provision.service 2>/dev/null || true
fi
