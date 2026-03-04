#!/usr/bin/env bash
set -euo pipefail

DB="${1:-/var/lib/rpi-sb-provisioner/manufacturing.db}"

if [[ ! -f "$DB" ]]; then
  echo "DB not found: $DB" 1>&2
  exit 1
fi

sqlite3 "$DB" ".schema" > schema.sql
echo "Wrote schema.sql — inspect it and add a query export for your version."
