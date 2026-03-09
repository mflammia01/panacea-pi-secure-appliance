#!/usr/bin/env bash
set -uo pipefail

# ── Panacea Device Health Check ──────────────────────────────
# Run manually or via systemd timer (every 5 min)
# Logs to /secure/logs/healthcheck.log
# Status to /secure/logs/healthcheck.status (machine-readable)
# Exit: 0=healthy, 1=degraded (recovered), 2=critical

LOGDIR="/secure/logs"
LOGFILE="$LOGDIR/healthcheck.log"
STATUSFILE="$LOGDIR/healthcheck.status"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
STATUS="HEALTHY"
DETAILS=""
KV=""

log() { DETAILS="$DETAILS | $1"; }
kv()  { KV="${KV}$1=$2\n"; }

# ── Vault ──
if mountpoint -q /secure 2>/dev/null; then
  log "vault=OK"
  kv vault OK
else
  log "vault=FAIL"
  kv vault FAIL
  STATUS="CRITICAL"
fi

# ── Detect SSH service name (Raspberry Pi OS uses 'ssh', others use 'sshd') ──
SSH_SVC=$(systemctl list-unit-files ssh.service sshd.service 2>/dev/null | awk '/enabled|generated/ {print $1; exit}')
SSH_SVC="${SSH_SVC%.service}"
[ -z "$SSH_SVC" ] && SSH_SVC="ssh"

# ── Critical Services ──
for SVC in twingate-connector "$SSH_SVC" fail2ban; do
  SVC_KEY=$(echo "$SVC" | tr '-' '_')
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    log "$SVC=OK"
    kv "$SVC_KEY" OK
  else
    log "$SVC=DOWN"
    mountpoint -q /secure 2>/dev/null && echo "[$TIMESTAMP] Attempting restart: $SVC" >> "$LOGFILE" 2>/dev/null
    sudo systemctl restart "$SVC" 2>/dev/null
    sleep 3
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
      log "$SVC=RECOVERED"
      kv "$SVC_KEY" RECOVERED
      [ "$STATUS" = "HEALTHY" ] && STATUS="DEGRADED"
    else
      log "$SVC=RESTART_FAILED"
      kv "$SVC_KEY" RESTART_FAILED
      STATUS="CRITICAL"
    fi
  fi
done

# ── Twingate Client (optional — Step 7) ──
if systemctl list-unit-files twingate.service 2>/dev/null | grep -q twingate.service; then
  if systemctl is-active --quiet twingate 2>/dev/null; then
    log "twingate-client=OK"
    kv twingate_client OK
  else
    log "twingate-client=DOWN"
    mountpoint -q /secure 2>/dev/null && echo "[$TIMESTAMP] Attempting restart: twingate" >> "$LOGFILE" 2>/dev/null
    sudo systemctl restart twingate 2>/dev/null
    sleep 3
    if systemctl is-active --quiet twingate 2>/dev/null; then
      log "twingate-client=RECOVERED"
      kv twingate_client RECOVERED
      [ "$STATUS" = "HEALTHY" ] && STATUS="DEGRADED"
    else
      log "twingate-client=RESTART_FAILED"
      kv twingate_client RESTART_FAILED
      STATUS="CRITICAL"
    fi
  fi
fi

# ── Wazuh Agent (optional — Part E) ──
if systemctl list-unit-files wazuh-agent.service 2>/dev/null | grep -q wazuh-agent.service; then
  if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
    log "wazuh-agent=OK"
    kv wazuh_agent OK
  else
    log "wazuh-agent=DOWN"
    mountpoint -q /secure 2>/dev/null && echo "[$TIMESTAMP] Attempting restart: wazuh-agent" >> "$LOGFILE" 2>/dev/null
    sudo systemctl restart wazuh-agent 2>/dev/null
    sleep 3
    if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
      log "wazuh-agent=RECOVERED"
      kv wazuh_agent RECOVERED
      [ "$STATUS" = "HEALTHY" ] && STATUS="DEGRADED"
    else
      log "wazuh-agent=RESTART_FAILED"
      kv wazuh_agent RESTART_FAILED
      STATUS="CRITICAL"
    fi
  fi
fi

# ── Zabbix Agent 2 (optional — Part E6) ──
if systemctl list-unit-files zabbix-agent2.service 2>/dev/null | grep -q zabbix-agent2.service; then
  if systemctl is-active --quiet zabbix-agent2 2>/dev/null; then
    log "zabbix-agent2=OK"
    kv zabbix_agent2 OK
  else
    log "zabbix-agent2=DOWN"
    mountpoint -q /secure 2>/dev/null && echo "[$TIMESTAMP] Attempting restart: zabbix-agent2" >> "$LOGFILE" 2>/dev/null
    sudo systemctl restart zabbix-agent2 2>/dev/null
    sleep 3
    if systemctl is-active --quiet zabbix-agent2 2>/dev/null; then
      log "zabbix-agent2=RECOVERED"
      kv zabbix_agent2 RECOVERED
      [ "$STATUS" = "HEALTHY" ] && STATUS="DEGRADED"
    else
      log "zabbix-agent2=RESTART_FAILED"
      kv zabbix_agent2 RESTART_FAILED
      STATUS="CRITICAL"
    fi
  fi
fi

# ── Disk Usage ──
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
if [ "$DISK_PCT" -gt 85 ]; then
  log "disk=${DISK_PCT}%_HIGH"
  [ "$STATUS" = "HEALTHY" ] && STATUS="DEGRADED"
else
  log "disk=${DISK_PCT}%"
fi
kv disk_pct "$DISK_PCT"

# ── CPU Temperature ──
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
  TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp)
  TEMP_C=$((TEMP_RAW / 1000))
  if [ "$TEMP_C" -gt 75 ]; then
    log "temp=${TEMP_C}C_HIGH"
    [ "$STATUS" = "HEALTHY" ] && STATUS="DEGRADED"
  else
    log "temp=${TEMP_C}C"
  fi
  kv temp_c "$TEMP_C"
fi

# ── Memory ──
MEM_PCT=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
log "mem=${MEM_PCT}%"
kv mem_pct "$MEM_PCT"

# ── Uptime ──
UPTIME=$(uptime -p)
log "up=$UPTIME"
kv uptime "$UPTIME"

# ── Write Log ──
if mountpoint -q /secure 2>/dev/null; then
  echo "[$TIMESTAMP] $STATUS $DETAILS" >> "$LOGFILE"
else
  logger -t panacea-healthcheck "$STATUS $DETAILS"
fi

# ── Write Machine-Readable Status File (atomic) ──
if mountpoint -q /secure 2>/dev/null; then
  STATUS_CONTENT="state=$STATUS\nlast_check=$TIMESTAMP\n$KV"
  printf "%b" "$STATUS_CONTENT" > "$STATUSFILE.tmp"
  mv "$STATUSFILE.tmp" "$STATUSFILE"
fi

# ── Exit Code ──
case "$STATUS" in
  HEALTHY)  exit 0 ;;
  DEGRADED) exit 1 ;;
  CRITICAL) exit 2 ;;
esac
