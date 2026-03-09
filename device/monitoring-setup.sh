#!/usr/bin/env bash
set -euo pipefail

echo "════════════════════════════════════════════"
echo "  PANACEA MONITORING SETUP"
echo "════════════════════════════════════════════"

# ── 1. Hardware Watchdog ─────────────────────────────────────
echo "Enabling hardware watchdog (15s timeout)..."
sudo sed -i 's/^#\?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=15/' /etc/systemd/system.conf
# If the line doesn't exist, append it
grep -q '^RuntimeWatchdogSec=' /etc/systemd/system.conf || \
  echo 'RuntimeWatchdogSec=15' | sudo tee -a /etc/systemd/system.conf >/dev/null
echo "✅ Watchdog: auto-reboot if kernel hangs >15s"

# ── 2. Persistent Journald Logging ──────────────────────────
echo "Configuring persistent journal logging..."
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/panacea.conf >/dev/null <<JOURNAL
[Journal]
Storage=persistent
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=90day
JOURNAL
sudo systemctl restart systemd-journald
echo "✅ Logs persist across reboots (200MB cap)"

# ── 3. Health Check Timer ────────────────────────────────────
echo "Installing health check timer (every 5 min)..."
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
sudo cp "$SCRIPT_DIR/healthcheck.sh" /usr/local/bin/panacea-healthcheck.sh
sudo chmod +x /usr/local/bin/panacea-healthcheck.sh

sudo tee /etc/systemd/system/panacea-healthcheck.service >/dev/null <<SVC
[Unit]
Description=Panacea Device Health Check
After=panacea-vault.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/panacea-healthcheck.sh
SVC

sudo tee /etc/systemd/system/panacea-healthcheck.timer >/dev/null <<TIMER
[Unit]
Description=Run Panacea health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now panacea-healthcheck.timer
echo "✅ Health checks run every 5 minutes"

# ── 4. Service Auto-Recovery ─────────────────────────────────
echo "Configuring auto-recovery for Twingate connector..."
sudo mkdir -p /etc/systemd/system/twingate-connector.service.d
sudo tee /etc/systemd/system/twingate-connector.service.d/restart.conf >/dev/null <<RESTART
[Service]
Restart=on-failure
RestartSec=10
WatchdogSec=120

[Unit]
StartLimitIntervalSec=600
StartLimitBurst=5
RESTART
sudo systemctl daemon-reload
echo "✅ Twingate connector auto-restarts on failure (max 5× per 10min)"

# If Twingate client is installed (Step 7), add auto-recovery for it too
if systemctl list-unit-files twingate.service 2>/dev/null | grep -q twingate.service; then
  echo "Configuring auto-recovery for Twingate client..."
  sudo mkdir -p /etc/systemd/system/twingate.service.d
  sudo tee /etc/systemd/system/twingate.service.d/restart.conf >/dev/null <<TRESTART
[Service]
Restart=on-failure
RestartSec=10

[Unit]
StartLimitIntervalSec=600
StartLimitBurst=5
TRESTART
  sudo systemctl daemon-reload
  echo "✅ Twingate client auto-restarts on failure"
fi

# If Zabbix Agent 2 is installed (Step E6), add auto-recovery for it too
if systemctl list-unit-files zabbix-agent2.service 2>/dev/null | grep -q zabbix-agent2.service; then
  echo "Configuring auto-recovery for Zabbix Agent 2..."
  sudo mkdir -p /etc/systemd/system/zabbix-agent2.service.d
  sudo tee /etc/systemd/system/zabbix-agent2.service.d/restart.conf >/dev/null <<ZRESTART
[Service]
Restart=on-failure
RestartSec=10

[Unit]
StartLimitIntervalSec=600
StartLimitBurst=5
ZRESTART
  sudo systemctl daemon-reload
  echo "✅ Zabbix Agent 2 auto-restarts on failure"
fi

# ── 5. Boot Diagnostics ─────────────────────────────────────
echo "Installing boot diagnostics service..."
sudo tee /etc/systemd/system/panacea-boot-report.service >/dev/null <<'BOOT'
[Unit]
Description=Panacea Boot Diagnostics Report
After=panacea-vault.service network-online.target
Wants=network-online.target
ConditionPathIsMountPoint=/secure

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  echo "══ BOOT REPORT ══ $(date)" >> /secure/logs/boot_report.log; \
  echo "Uptime: $(uptime -p)" >> /secure/logs/boot_report.log; \
  echo "Last shutdown: $(last -x shutdown | head -1)" >> /secure/logs/boot_report.log; \
  echo "Vault: $(mountpoint -q /secure && echo OK || echo FAIL)" >> /secure/logs/boot_report.log; \
  echo "Twingate: $(systemctl is-active twingate-connector)" >> /secure/logs/boot_report.log; \
  echo "Twingate-Client: $(systemctl is-active twingate 2>/dev/null || echo not-installed)" >> /secure/logs/boot_report.log; \
  SSH_SVC=$(systemctl list-unit-files ssh.service sshd.service 2>/dev/null | awk "/enabled|generated/ {print \$1; exit}"); SSH_SVC="${SSH_SVC%.service}"; [ -z "$SSH_SVC" ] && SSH_SVC="ssh"; echo "SSH: $(systemctl is-active $SSH_SVC)" >> /secure/logs/boot_report.log; \
  echo "Fail2ban: $(systemctl is-active fail2ban)" >> /secure/logs/boot_report.log; \
  echo "Temp: $(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))C" >> /secure/logs/boot_report.log; \
  echo "Disk: $(df / --output=pcent | tail -1)" >> /secure/logs/boot_report.log; \
  echo "" >> /secure/logs/boot_report.log'

[Install]
WantedBy=multi-user.target
BOOT

sudo systemctl daemon-reload
sudo systemctl enable panacea-boot-report.service
echo "✅ Boot report logs to /secure/logs/boot_report.log"

# ── 6. Network Connectivity Timer ───────────────────────────
echo "Installing network connectivity timer (every 15 min)..."
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
sudo cp "$SCRIPT_DIR/../ops/network-check.sh" /usr/local/bin/panacea-network-check.sh 2>/dev/null ||   sudo cp "$SCRIPT_DIR/network-check.sh" /usr/local/bin/panacea-network-check.sh 2>/dev/null ||   { echo "⚠️  network-check.sh not found — copy it manually to /usr/local/bin/panacea-network-check.sh"; }
sudo chmod +x /usr/local/bin/panacea-network-check.sh

sudo tee /etc/systemd/system/panacea-network-check.service >/dev/null <<NETSVC
[Unit]
Description=Panacea Network Connectivity Check
After=panacea-vault.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/panacea-network-check.sh
NETSVC

sudo tee /etc/systemd/system/panacea-network-check.timer >/dev/null <<NETTIMER
[Unit]
Description=Run Panacea network check every 15 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
NETTIMER

sudo systemctl daemon-reload
sudo systemctl enable --now panacea-network-check.timer
echo "✅ Network connectivity checks run every 15 minutes"

echo
echo "════════════════════════════════════════════"
echo "  ✅ MONITORING SETUP COMPLETE"
echo "════════════════════════════════════════════"
echo "  • Hardware watchdog: 15s (reboot on hang)"
echo "  • Persistent logging: 200MB cap, 90-day retention"
echo "  • Health checks: every 5 min → /secure/logs/healthcheck.log"
echo "  • Network checks: every 15 min → /secure/logs/network-check.log"
echo "  • Twingate auto-recovery: restart on failure"
echo "  • Boot diagnostics: /secure/logs/boot_report.log"
echo
echo "Reboot recommended to activate watchdog."
echo "Run: sudo reboot"
