#!/usr/bin/env bash
set -euo pipefail
trap 'echo ""; echo "❌ ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# ════════════════════════════════════════════════════════════════
#   PANACEA DEPLOY-OBSERVABILITY — Combined E1–E6
# ════════════════════════════════════════════════════════════════
#
# Runs all Part E observability stages in sequence:
#   E1: Monitoring (watchdog, timers, persistent logging)
#   E2: Wazuh Agent (SIEM, file-integrity, compliance)
#   E3: Log Forwarding (Wazuh ossec.conf entries)
#   E4: CIS Stage 1 (quick wins — ~20 Wazuh SCA findings)
#   E5: CIS Stage 2 (extended — ~15 additional SCA findings)
#   E6: Zabbix Agent 2 (infrastructure monitoring)
#
# Run from the repo root:
#   cd ~/panacea-pi-secure-appliance
#   sudo bash device/deploy-observability.sh

echo "════════════════════════════════════════════════════════════"
echo "  PANACEA DEPLOY-OBSERVABILITY"
echo "  Combined Part E: Monitoring + SIEM + CIS + Zabbix"
echo "════════════════════════════════════════════════════════════"
echo ""

# ── Validate prerequisites ──────────────────────────────────────
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"
echo "📂 Working from: $REPO_DIR"

ERRORS=0
for f in device/monitoring-setup.sh device/healthcheck.sh ops/network-check.sh hardening/cis-remediate.sh hardening/cis-remediate-2.sh; do
  if [ ! -f "$f" ]; then
    echo "❌ Missing: $f"
    ERRORS=$((ERRORS + 1))
  fi
done
if [ $ERRORS -gt 0 ]; then
  echo ""
  echo "Run 'git pull' to fetch missing scripts, or re-clone the repo."
  exit 1
fi
echo "✅ All required scripts found"
echo ""

# ── Interactive prompts ─────────────────────────────────────────
DEVICE_HOSTNAME=$(hostname)
WAZUH_IP=""
WAZUH_GROUP="default"
ZABBIX_IP=""

echo "── Configuration ──────────────────────────────────────────"
echo ""

read -rp "Device hostname [$DEVICE_HOSTNAME]: " INPUT
DEVICE_HOSTNAME=${INPUT:-$DEVICE_HOSTNAME}

# Validate hostname (no @ allowed — Zabbix rejects it)
if [[ "$DEVICE_HOSTNAME" == *"@"* ]]; then
  echo "❌ Hostname cannot contain '@' — Zabbix will reject it."
  echo "   Use just the machine name, e.g. 'Pi-Twingate-01'"
  exit 1
fi

echo ""
read -rp "Wazuh Manager IP (blank to skip E2/E3): " WAZUH_IP
if [ -n "$WAZUH_IP" ]; then
  read -rp "Wazuh Agent Group [default]: " INPUT
  WAZUH_GROUP=${INPUT:-default}
fi

echo ""
read -rp "Zabbix Server IP (blank to skip E6): " ZABBIX_IP

echo ""
echo "── Summary ────────────────────────────────────────────────"
echo "  Hostname:      $DEVICE_HOSTNAME"
echo "  E1 Monitoring: ✅ (always runs)"
echo "  E2 Wazuh:      $([ -n "$WAZUH_IP" ] && echo "✅ → $WAZUH_IP (group: $WAZUH_GROUP)" || echo "⏭ skip")"
echo "  E3 Log Fwd:    $([ -n "$WAZUH_IP" ] && echo "✅ (auto — depends on E2)" || echo "⏭ skip")"
echo "  E4 CIS Stage1: ✅ (always runs)"
echo "  E5 CIS Stage2: ✅ (always runs)"
echo "  E6 Zabbix:     $([ -n "$ZABBIX_IP" ] && echo "✅ → $ZABBIX_IP" || echo "⏭ skip")"
echo "────────────────────────────────────────────────────────────"
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
  echo "Aborted."
  exit 0
fi

# Track results
declare -A RESULTS

# ════════════════════════════════════════════════════════════════
# E1 — MONITORING SETUP
# ════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  E1 — DEPLOY MONITORING"
echo "═══════════════════════════════════════════════════════════"
chmod +x device/monitoring-setup.sh device/healthcheck.sh ops/network-check.sh
if sudo bash device/monitoring-setup.sh; then
  RESULTS[E1]="✅ PASS"
else
  RESULTS[E1]="❌ FAIL"
fi

# ════════════════════════════════════════════════════════════════
# E2 — WAZUH AGENT
# ════════════════════════════════════════════════════════════════
if [ -n "$WAZUH_IP" ]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  E2 — WAZUH AGENT"
  echo "═══════════════════════════════════════════════════════════"

  # Skip if already installed
  if systemctl list-unit-files wazuh-agent.service 2>/dev/null | grep -q wazuh-agent; then
    echo "✅ Wazuh agent already installed — skipping"
    RESULTS[E2]="✅ ALREADY INSTALLED"
  else
    # Connectivity test
    if ! timeout 5 bash -c "</dev/tcp/$WAZUH_IP/1514" 2>/dev/null; then
      echo "⚠️  Port 1514 not reachable on $WAZUH_IP"
      echo "   Check Twingate client is running and the manager firewall allows 1514/tcp."
      read -rp "Continue anyway? [y/N]: " CONT
      if [[ ! "$CONT" =~ ^[Yy] ]]; then
        RESULTS[E2]="⏭ SKIPPED (connectivity)"
        RESULTS[E3]="⏭ SKIPPED (no Wazuh)"
      fi
    fi

    if [ -z "${RESULTS[E2]:-}" ]; then
      (
        # Install prerequisites
        sudo apt-get install -y gnupg apt-transport-https

        # Import GPG key
        curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
          sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && \
          sudo chmod 644 /usr/share/keyrings/wazuh.gpg

        # Add repo
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | \
          sudo tee /etc/apt/sources.list.d/wazuh.list
        sudo apt-get update

        # Install agent
        sudo WAZUH_MANAGER="$WAZUH_IP" \
          WAZUH_AGENT_NAME="$DEVICE_HOSTNAME" \
          WAZUH_AGENT_GROUP="$WAZUH_GROUP" \
          apt-get install -y wazuh-agent

        # Lock repo version
        sudo sed -i "s/^deb/#deb/" /etc/apt/sources.list.d/wazuh.list
        sudo apt-get update

        # Register agent
        sudo /var/ossec/bin/agent-auth -m "$WAZUH_IP"
        sudo systemctl daemon-reload
        sudo systemctl enable --now wazuh-agent
      ) && RESULTS[E2]="✅ PASS" || RESULTS[E2]="❌ FAIL"
    fi
  fi
else
  RESULTS[E2]="⏭ SKIPPED"
fi

# ════════════════════════════════════════════════════════════════
# E3 — LOG FORWARDING (Wazuh ossec.conf entries)
# ════════════════════════════════════════════════════════════════
if [ -n "$WAZUH_IP" ] && [ -d /var/ossec ] && [ "${RESULTS[E2]:-}" != "⏭ SKIPPED (connectivity)" ]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  E3 — LOG FORWARDING"
  echo "═══════════════════════════════════════════════════════════"

  if ! sudo grep -q 'network-check.log' /var/ossec/etc/ossec.conf 2>/dev/null; then
    sudo sed -i '/<\/ossec_config>/i \
  <!-- Panacea flat-file logs -->\
  <localfile>\
    <log_format>syslog</log_format>\
    <location>/secure/logs/healthcheck.log</location>\
  </localfile>\
  <localfile>\
    <log_format>syslog</log_format>\
    <location>/secure/logs/boot_report.log</location>\
  </localfile>\
  <localfile>\
    <log_format>syslog</log_format>\
    <location>/secure/logs/network-check.log</location>\
  </localfile>\
  <!-- File integrity monitoring -->\
  <syscheck>\
    <directories realtime="yes">/secure</directories>\
  </syscheck>\
  <!-- Journald: Twingate tunnel and client -->\
  <localfile>\
    <log_format>journald</log_format>\
    <location>journald</location>\
    <filter field="_SYSTEMD_UNIT" type="match">twingate-connector.service</filter>\
  </localfile>\
  <localfile>\
    <log_format>journald</log_format>\
    <location>journald</location>\
    <filter field="_SYSTEMD_UNIT" type="match">twingate.service</filter>\
  </localfile>\
  <!-- Journald: SSH and fail2ban -->\
  <localfile>\
    <log_format>journald</log_format>\
    <location>journald</location>\
    <filter field="_SYSTEMD_UNIT" type="match">ssh.service</filter>\
  </localfile>\
  <localfile>\
    <log_format>journald</log_format>\
    <location>journald</location>\
    <filter field="_SYSTEMD_UNIT" type="match">fail2ban.service</filter>\
  </localfile>\
  <!-- Journald: Panacea services -->\
  <localfile>\
    <log_format>journald</log_format>\
    <location>journald</location>\
    <filter field="_SYSTEMD_UNIT" type="match">panacea-vault.service</filter>\
  </localfile>\
  <localfile>\
    <log_format>journald</log_format>\
    <location>journald</location>\
    <filter field="_SYSTEMD_UNIT" type="match">panacea-healthcheck.service</filter>\
  </localfile>\
  <!-- Journald: Wazuh agent self-monitoring -->\
  <localfile>\
    <log_format>journald</log_format>\
    <location>journald</location>\
    <filter field="_SYSTEMD_UNIT" type="match">wazuh-agent.service</filter>\
  </localfile>' /var/ossec/etc/ossec.conf
    echo "✅ Log forwarding entries added to ossec.conf"
  else
    echo "✅ Log forwarding entries already present — skipping"
  fi

  # Ensure log files exist
  sudo mkdir -p /secure/logs
  sudo touch /secure/logs/healthcheck.log /secure/logs/boot_report.log /secure/logs/network-check.log

  sudo systemctl restart wazuh-agent
  RESULTS[E3]="✅ PASS"
else
  RESULTS[E3]="${RESULTS[E3]:-⏭ SKIPPED}"
fi

# ════════════════════════════════════════════════════════════════
# E4 — CIS STAGE 1
# ════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  E4 — CIS STAGE 1 (Quick Wins) — safe to re-run"
echo "═══════════════════════════════════════════════════════════"
chmod +x hardening/cis-remediate.sh
if sudo bash hardening/cis-remediate.sh; then
  RESULTS[E4]="✅ PASS"
else
  RESULTS[E4]="❌ FAIL"
fi

# ════════════════════════════════════════════════════════════════
# E5 — CIS STAGE 2
# ════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  E5 — CIS STAGE 2 (Extended Hardening) — safe to re-run"
echo "═══════════════════════════════════════════════════════════"
chmod +x hardening/cis-remediate-2.sh
if sudo bash hardening/cis-remediate-2.sh; then
  RESULTS[E5]="✅ PASS"
else
  RESULTS[E5]="❌ FAIL"
fi

# ════════════════════════════════════════════════════════════════
# E6 — ZABBIX AGENT 2
# ════════════════════════════════════════════════════════════════
if [ -n "$ZABBIX_IP" ]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  E6 — ZABBIX AGENT 2"
  echo "═══════════════════════════════════════════════════════════"

  # Skip if already installed
  if command -v zabbix_agent2 &>/dev/null; then
    echo "✅ Zabbix Agent 2 already installed — skipping"
    RESULTS[E6]="✅ ALREADY INSTALLED"
  else
    (
      # Install from official repo
      wget -4 -q https://repo.zabbix.com/zabbix/7.0/raspbian/pool/main/z/zabbix-release/zabbix-release_latest_7.0+debian12_all.deb
      sudo dpkg -i zabbix-release_latest_7.0+debian12_all.deb
      sudo apt update
      apt download zabbix-agent2
      sudo dpkg -i --force-depends zabbix-agent2_*.deb
      rm -f zabbix-release_latest_7.0+debian12_all.deb zabbix-agent2_*.deb

      # Backup and configure
      [ -f /etc/zabbix/zabbix_agent2.conf ] && sudo cp /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf.bak

      sudo tee /etc/zabbix/zabbix_agent2.conf > /dev/null << ZCONF
# Panacea Zabbix Agent 2 Configuration
# Active checks only — no inbound port needed

ServerActive=$ZABBIX_IP
Server=
Hostname=$DEVICE_HOSTNAME

# Security
AllowKey=system.*
AllowKey=vfs.*
AllowKey=net.*
AllowKey=proc.*
AllowKey=panacea.*
DenyKey=system.run[*]

# Logging
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=5
DebugLevel=3

# TLS (optional — configure if your Zabbix server uses PSK/cert)
# TLSConnect=psk
# TLSAccept=psk
# TLSPSKIdentity=panacea-device
# TLSPSKFile=/etc/zabbix/zabbix_agent2.psk

# Include drop-in directory for UserParameters
Include=/etc/zabbix/zabbix_agent2.d/*.conf
ZCONF

      # Deploy UserParameters
      sudo tee /etc/zabbix/zabbix_agent2.d/panacea.conf > /dev/null << 'ZEOF'
# ── Panacea Custom UserParameters ──────────────────────────

# Vault mount status (1=mounted, 0=not mounted)
UserParameter=panacea.vault.mounted,mountpoint -q /secure && echo 1 || echo 0

# LUKS vault active (1=active, 0=inactive)
UserParameter=panacea.luks.active,sudo cryptsetup status panacea_vault >/dev/null 2>&1 && echo 1 || echo 0

# Twingate connector status (1=active, 0=down)
UserParameter=panacea.twingate.connector,systemctl is-active --quiet twingate-connector && echo 1 || echo 0

# Twingate client status (1=active, 0=down, -1=not installed)
UserParameter=panacea.twingate.client,if systemctl list-unit-files twingate.service 2>/dev/null | grep -q twingate.service; then systemctl is-active --quiet twingate && echo 1 || echo 0; else echo -1; fi

# Healthcheck overall state (HEALTHY/DEGRADED/CRITICAL)
UserParameter=panacea.healthcheck.state,grep -oP '(?<=state=)\S+' /secure/logs/healthcheck.status 2>/dev/null || echo UNKNOWN

# Healthcheck last run timestamp
UserParameter=panacea.healthcheck.last_check,grep -oP '(?<=last_check=).*' /secure/logs/healthcheck.status 2>/dev/null || echo never

# CPU temperature (Celsius)
UserParameter=panacea.cpu.temp,cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}' || echo -1

# SD card / root disk usage (percentage, integer)
UserParameter=panacea.disk.root_pct,df / --output=pcent | tail -1 | tr -d ' %'

# Memory usage (percentage, integer)
UserParameter=panacea.mem.pct,free | awk '/Mem:/ {printf "%.0f", $3/$2*100}'

# Wazuh agent status (1=active, 0=down, -1=not installed)
UserParameter=panacea.wazuh.active,if systemctl list-unit-files wazuh-agent.service 2>/dev/null | grep -q wazuh-agent.service; then systemctl is-active --quiet wazuh-agent && echo 1 || echo 0; else echo -1; fi

# Fail2ban status (1=active, 0=down)
UserParameter=panacea.fail2ban.active,systemctl is-active --quiet fail2ban && echo 1 || echo 0

# SSH banned IPs count
UserParameter=panacea.fail2ban.banned,sudo fail2ban-client status sshd 2>/dev/null | grep -oP '(?<=Currently banned:\s)\d+' || echo 0

# System uptime (seconds) — graph to spot unexpected reboots
UserParameter=panacea.uptime.seconds,cat /proc/uptime | awk '{printf "%.0f", $1}'

# SSH service active (1=active, 0=down)
UserParameter=panacea.ssh.active,systemctl is-active --quiet ssh 2>/dev/null && echo 1 || { systemctl is-active --quiet sshd 2>/dev/null && echo 1 || echo 0; }

# Active SSH sessions
UserParameter=panacea.ssh.sessions,who | wc -l

# USB device count (useful alongside USB lockdown)
UserParameter=panacea.usb.device_count,lsusb 2>/dev/null | wc -l

# Encrypted /secure partition usage (percentage)
UserParameter=panacea.disk.secure_pct,df /secure --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo -1

# Pending apt updates (security awareness)
UserParameter=panacea.updates.pending,apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0

# Zabbix agent self-check (1=running)
UserParameter=panacea.zabbix_agent2.active,systemctl is-active --quiet zabbix-agent2 && echo 1 || echo 0
ZEOF

      # Sudoers for LUKS and fail2ban checks
      echo 'zabbix ALL=(root) NOPASSWD: /sbin/cryptsetup status panacea_vault, /usr/bin/fail2ban-client status sshd' | sudo tee /etc/sudoers.d/zabbix-panacea
      sudo chmod 440 /etc/sudoers.d/zabbix-panacea

      # Enable and start
      sudo systemctl enable --now zabbix-agent2
      sudo systemctl restart zabbix-agent2

      echo ""
      echo "Testing UserParameters..."
      for key in panacea.vault.mounted panacea.luks.active panacea.twingate.connector panacea.cpu.temp panacea.disk.root_pct panacea.uptime.seconds; do
        RESULT=$(zabbix_agent2 -t "$key" 2>&1)
        echo "  $RESULT"
      done
    ) && RESULTS[E6]="✅ PASS" || RESULTS[E6]="❌ FAIL"
  fi
else
  RESULTS[E6]="⏭ SKIPPED"
fi

# ════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  DEPLOY-OBSERVABILITY — RESULTS"
echo "════════════════════════════════════════════════════════════"
echo "  E1 Monitoring:   ${RESULTS[E1]}"
echo "  E2 Wazuh Agent:  ${RESULTS[E2]}"
echo "  E3 Log Fwd:      ${RESULTS[E3]}"
echo "  E4 CIS Stage 1:  ${RESULTS[E4]}"
echo "  E5 CIS Stage 2:  ${RESULTS[E5]}"
echo "  E6 Zabbix Agent: ${RESULTS[E6]}"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  • Reboot to activate hardware watchdog: sudo reboot"
[ -n "$WAZUH_IP" ] && echo "  • Check Wazuh dashboard for this agent within 5 minutes"
[ -n "$ZABBIX_IP" ] && echo "  • Create host '$DEVICE_HOSTNAME' in Zabbix UI and link Pi-Twingate template"
echo "  • Re-run Wazuh SCA scan to verify CIS score improvement"
