#!/usr/bin/env bash
set -uo pipefail

# ── Panacea Network Connectivity Check ──────────────────────
# Run manually or via systemd timer (every 15 min)
# Logs to /secure/logs/network-check.log when vault is mounted

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
FAILURES=""

check() {
  local name="$1" result="$2"
  if [ "$result" = "OK" ]; then
    output "✅ $name OK"
  else
    output "❌ $name $result"
    FAILURES="${FAILURES:+$FAILURES,}$name"
  fi
}

# Log to vault if mounted, otherwise stdout only
if mountpoint -q /secure 2>/dev/null; then
  LOGFILE="/secure/logs/network-check.log"
  output() { echo "  $1" >> "$LOGFILE"; echo "$1"; }
  echo "[$TIMESTAMP] ── Network Check ──" >> "$LOGFILE"
else
  output() { echo "$1"; }
fi

echo "══ Panacea Network Connectivity Check ══"

# DNS
if getent hosts github.com >/dev/null 2>&1; then
  check "DNS" "OK"
else
  check "DNS" "FAIL"
fi

# NTP
NTP_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "no")
if [ "$NTP_SYNC" = "yes" ]; then
  check "NTP" "OK"
else
  check "NTP" "NOT_SYNCED"
fi

# Twingate control plane
if curl -sf --max-time 5 https://api.twingate.com >/dev/null; then
  check "Twingate-API" "OK"
else
  check "Twingate-API" "UNREACHABLE"
fi

# Twingate data plane (check connector status)
if systemctl is-active --quiet twingate-connector 2>/dev/null; then
  check "Tunnel" "OK"
else
  check "Tunnel" "DOWN"
fi

# APT repos
if curl -sf --max-time 5 https://deb.debian.org/debian/dists/bookworm/Release >/dev/null; then
  check "APT" "OK"
else
  check "APT" "UNREACHABLE"
fi

# GitHub
if timeout 5 git ls-remote https://github.com/octocat/Hello-World.git >/dev/null 2>&1; then
  check "GitHub" "OK"
else
  check "GitHub" "UNREACHABLE"
fi

# ── Optional Twingate Resource Probe ──
# Set TG_TEST_HOST and TG_TEST_PORT (comma-separated) to probe resources
# through the tunnel. Unset = skipped (backward-compatible).
if [ -n "${TG_TEST_HOST:-}" ] && [ -n "${TG_TEST_PORT:-}" ]; then
  IFS=',' read -ra PORTS <<< "$TG_TEST_PORT"
  for PORT in "${PORTS[@]}"; do
    PORT=$(echo "$PORT" | tr -d ' ')
    if timeout 5 bash -c "</dev/tcp/$TG_TEST_HOST/$PORT" 2>/dev/null; then
      check "Twingate-Resource($TG_TEST_HOST:$PORT)" "OK"
    else
      check "Twingate-Resource($TG_TEST_HOST:$PORT)" "UNREACHABLE"
    fi
  done
fi

# ── Summary ──
if [ -z "$FAILURES" ]; then
  SUMMARY="ALL_OK"
else
  SUMMARY="DEGRADED: $FAILURES"
fi

if mountpoint -q /secure 2>/dev/null; then
  echo "[$TIMESTAMP] $SUMMARY" >> "$LOGFILE"
  echo "" >> "$LOGFILE"
fi
echo "── $SUMMARY ──"
