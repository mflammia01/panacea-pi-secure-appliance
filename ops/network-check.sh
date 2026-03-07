#!/usr/bin/env bash
set -euo pipefail

echo "══ Panacea Network Connectivity Check ══"

# DNS
getent hosts github.com >/dev/null 2>&1 && echo "✅ DNS OK" || echo "❌ DNS blocked"

# NTP
NTP_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "no")
[ "$NTP_SYNC" = "yes" ] && echo "✅ NTP OK" || echo "⚠️  NTP not synced (may need time)"

# Twingate control plane
curl -sf --max-time 5 https://api.twingate.com >/dev/null && echo "✅ Twingate API OK" || echo "❌ Twingate API blocked"

# Twingate data plane (check connector status)
systemctl is-active twingate-connector && echo "✅ Tunnel UP" || echo "❌ Tunnel DOWN"

# APT repos
curl -sf --max-time 5 https://deb.debian.org/debian/dists/bookworm/Release >/dev/null && echo "✅ APT OK" || echo "❌ APT blocked"

# GitHub
timeout 5 git ls-remote https://github.com/octocat/Hello-World.git >/dev/null 2>&1 && echo "✅ GitHub OK" || echo "❌ GitHub blocked"
