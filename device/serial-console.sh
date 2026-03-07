#!/usr/bin/env bash
set -euo pipefail

echo "🔌 Panacea Serial Console — Firewall CLI Access"
echo "================================================"

# Auto-discover USB serial devices
DEVICES=( $(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true) )

if [ ${#DEVICES[@]} -eq 0 ]; then
  echo "❌ No USB serial devices found."
  echo "   Plug in a USB-to-serial cable and try again."
  echo "   Tip: run 'dmesg | tail -20' after plugging in to check."
  exit 1
fi

if [ ${#DEVICES[@]} -eq 1 ]; then
  DEV="${DEVICES[0]}"
  echo "✅ Found: $DEV"
else
  echo "Found ${#DEVICES[@]} serial devices:"
  for i in "${!DEVICES[@]}"; do
    echo "  [$((i+1))] ${DEVICES[$i]}"
  done
  read -r -p "Select device [1]: " CHOICE
  CHOICE=${CHOICE:-1}
  DEV="${DEVICES[$((CHOICE-1))]}"
fi

echo ""
echo "Common baud rates:"
echo "  [1] 9600   (most common — Cisco, Fortinet, etc.)"
echo "  [2] 19200"
echo "  [3] 38400"
echo "  [4] 115200 (common — Ubiquiti, MikroTik, etc.)"
read -r -p "Select baud rate [1]: " BAUD_CHOICE
case "${BAUD_CHOICE:-1}" in
  1) BAUD=9600 ;;
  2) BAUD=19200 ;;
  3) BAUD=38400 ;;
  4) BAUD=115200 ;;
  *) BAUD=9600 ;;
esac

if ! command -v screen &>/dev/null; then
  echo "Installing screen..."
  sudo apt install -y screen
fi

echo ""
echo "Connecting to $DEV at $BAUD baud..."
echo "To exit: press Ctrl-A then K, then confirm with Y"
echo "================================================"
sleep 1

sudo screen "$DEV" "$BAUD"
