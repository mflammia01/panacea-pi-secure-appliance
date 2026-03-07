#!/usr/bin/env bash
set -euo pipefail

# Microsoft Teams variant (Workflows incoming webhook)
WEBHOOK_URL="https://your-org.webhook.office.com/webhookb2/..."
DEVICE=$(hostname)
LOGFILE="/secure/logs/healthcheck.log"

# Exit cleanly if log file doesn't exist yet
[ -f "$LOGFILE" ] || exit 0

LAST_LINE=$(tail -1 "$LOGFILE")

if echo "$LAST_LINE" | grep -qv "HEALTHY"; then
  curl -s -H "Content-Type: application/json" \
    -d "{\"text\": \"🚨 $DEVICE: $LAST_LINE\"}" \
    "$WEBHOOK_URL" >/dev/null 2>&1
fi
