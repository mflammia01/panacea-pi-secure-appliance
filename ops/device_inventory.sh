#!/usr/bin/env bash
set -euo pipefail

INVENTORY="ops/inventory.csv"

if [[ ! -f "$INVENTORY" ]]; then
  echo "hostname,serial,ip,provisioned_date,notes" > "$INVENTORY"
  echo "Created $INVENTORY"
fi

read -rp "Device hostname: " HOSTNAME
read -rp "Serial number (from Pi label): " SERIAL
read -rp "IP address: " IP
read -rp "Notes (optional): " NOTES

echo "$HOSTNAME,$SERIAL,$IP,$(date +%Y-%m-%d),$NOTES" >> "$INVENTORY"
echo "Added to $INVENTORY"
