#!/usr/bin/env bash
set -uo pipefail

# ── Panacea Device Health Check ──────────────────────────────
# Run manually or via systemd timer (every 5 min)
# Logs to /secure/logs/healthcheck.log
# Exit: 0=healthy, 1=degraded (recovered), 2=critical

LOGDIR="/secure/logs"
LOGFILE="$LOGDIR/healthcheck.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
STATUS="HEALTHY"
DETAILS=""

log() { DETAILS="$DETAILS | $1"; }

# ── Vault ──
if mountpoint -q /secure 2>/dev/null; then
  log "vault=OK"
else
  log "vault=FAIL"
  STATUS="CRITICAL"
fi

# ── Detect SSH service name (Raspberry Pi OS uses 'ssh', others use 'sshd') ──
SSH_SVC=$(systemctl list-unit-files ssh.service sshd.service 2>/dev/null | awk '/enabled|generated/ {print $1; exit}')
SSH_SVC="${SSH_SVC%.service}"
[ -z "$SSH_SVC" ] && SSH_SVC="ssh"

# ── Critical Services ──
for SVC in twingate-connector "$SSH_SVC" fail2ban; do
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    log "$SVC=OK"
  else
    log "$SVC=DOWN"
    mountpoint -q /secure 2>/dev/null && echo "[$TIMESTAMP] Attempting restart: $SVC" >> "$LOGFILE" 2>/dev/null
    sudo systemctl restart "$SVC" 2>/dev/null
    sleep 3
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
      log "$SVC=RECOVERED"
      [ "$STATUS" = "HEALTHY" ] && STATUS="DEGRADED"
    else
      log "$SVC=RESTART_FAILED"
      STATUS="CRITICAL"
    fi
  fi
done

# ── Twingate Client (optional — Step 7) ──
if systemctl list-unit-files twingate.service 2>/dev/null | grep -q twingate.service; then
  if systemctl is-active --quiet twingate 2>/dev/null; then
    log "twingate-client=OK"
  else
    log "twingate-client=DOWN"
    mountpoint -q /secure 2>/dev/null && echo "[$TIMESTAMP] Attempting restart: twingate" >> "$LOGFILE" 2>/dev/null
    sudo systemctl restart twingate 2>/dev/null
    sleep 3
    if systemctl is-active --quiet twingate 2>/dev/null; then
      log "twingate-client=RECOVERED"
      [ "$STATUS" = "HEALTHY" ] && STATUS="DEGRADED"
    else
      log "twingate-client=RESTART_FAILED"
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
fi

# ── Memory ──
MEM_PCT=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
log "mem=${MEM_PCT}%"

# ── Uptime ──
UPTIME=$(uptime -p)
log "up=$UPTIME"

# ── Write Log ──
if mountpoint -q /secure 2>/dev/null; then
  echo "[$TIMESTAMP] $STATUS $DETAILS" >> "$LOGFILE"
else
  logger -t panacea-healthcheck "$STATUS $DETAILS"
fi

# ── Exit Code ──
case "$STATUS" in
  HEALTHY)  exit 0 ;;
  DEGRADED) exit 1 ;;
  CRITICAL) exit 2 ;;
esac
