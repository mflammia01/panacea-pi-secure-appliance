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

# ── Critical Services ──
for SVC in twingate-connector sshd fail2ban; do
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    log "$SVC=OK"
  else
    log "$SVC=DOWN"
    echo "[$TIMESTAMP] Attempting restart: $SVC" >> "$LOGFILE" 2>/dev/null
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
mkdir -p "$LOGDIR" 2>/dev/null
echo "[$TIMESTAMP] $STATUS $DETAILS" >> "$LOGFILE"

# ── Exit Code ──
case "$STATUS" in
  HEALTHY)  exit 0 ;;
  DEGRADED) exit 1 ;;
  CRITICAL) exit 2 ;;
esac
