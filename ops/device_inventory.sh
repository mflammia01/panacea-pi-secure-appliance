#!/usr/bin/env bash
set -euo pipefail

INVENTORY="ops/inventory.csv"

if [[ ! -f "$INVENTORY" ]]; then
  echo "hostname,cpu_serial,label_serial,ip,provisioned_date,notes" > "$INVENTORY"
  echo "Created $INVENTORY"
fi

read -rp "Device hostname: " HOSTNAME
read -rp "CPU serial (from target: grep Serial /proc/cpuinfo | awk '{print \$3}'): " CPU_SERIAL
read -rp "Label serial / asset tag (optional): " LABEL_SERIAL
read -rp "IP address: " IP
read -rp "Notes (optional): " NOTES

echo "$HOSTNAME,$CPU_SERIAL,$LABEL_SERIAL,$IP,$(date +%Y-%m-%d),$NOTES" >> "$INVENTORY"
echo "Added to $INVENTORY"
