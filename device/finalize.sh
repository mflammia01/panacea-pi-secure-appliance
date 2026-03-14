#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════
#  PANACEA POST-BUILD CLEANUP — finalize.sh
#  Run once after confirming the device is fully operational.
#  This script is IRREVERSIBLE — the repo must be re-cloned to undo.
# ══════════════════════════════════════════════════════════════

DEVICE_NAME=$(hostname)
REPO_DIR="${REPO_DIR:-$HOME/panacea-pi-secure-appliance}"
LOG_DIR="/secure/logs"
LOG_FILE="$LOG_DIR/provision-finalize.log"
DEPLOY_KEY_PATH="$HOME/.ssh/panacea_deploy_key"

echo "════════════════════════════════════════════"
echo "  POST-BUILD CLEANUP — $DEVICE_NAME"
echo "════════════════════════════════════════════"
echo

# ── Pre-flight checks ────────────────────────────
echo "── Pre-flight checks ──"

if ! mountpoint -q /secure 2>/dev/null; then
  echo "❌ /secure is not mounted — cannot proceed safely."
  echo "   Run: sudo systemctl start panacea-vault.service"
  exit 1
fi
echo "✅ /secure is mounted"

if [ ! -d "$LOG_DIR" ]; then
  sudo mkdir -p "$LOG_DIR"
fi

# Run verify.sh if available
if [ -f "$REPO_DIR/device/verify.sh" ]; then
  echo "Running verify.sh pre-flight..."
  echo "────────────────────────────────"
  bash "$REPO_DIR/device/verify.sh" 2>&1 | tee /tmp/finalize-verify.log
  echo "────────────────────────────────"
  echo
  read -rp "Does verify.sh output look correct? (y/N): " VERIFY_OK
  if [[ "$VERIFY_OK" != "y" && "$VERIFY_OK" != "Y" ]]; then
    echo "Aborting cleanup — fix issues first."
    exit 1
  fi
else
  echo "⚠️  verify.sh not found — skipping pre-flight verification"
  read -rp "Continue without verification? (y/N): " CONTINUE_OK
  if [[ "$CONTINUE_OK" != "y" && "$CONTINUE_OK" != "Y" ]]; then
    echo "Aborting."
    exit 1
  fi
fi
echo

# Start logging
{
  echo "═══ Finalize started: $(date -u '+%Y-%m-%dT%H:%M:%SZ') ═══"
  echo "Device: $DEVICE_NAME"
  echo "User: $(whoami)"
  echo

  # ── 1. Remove /etc/panacea/ staging files ──────────
  echo "── Step 1: Remove /etc/panacea/ staging files ──"
  if [ -d /etc/panacea ]; then
    echo "  Removing /etc/panacea/ (installer script + service key)..."
    sudo rm -rf /etc/panacea
    echo "  ✅ /etc/panacea/ removed"
  else
    echo "  ℹ️  /etc/panacea/ not found (already removed or never created)"
  fi
  echo

  # ── 2. Copy runtime scripts to /usr/local/sbin/ ────
  echo "── Step 2: Migrate runtime scripts ──"
  RUNTIME_SCRIPTS=(
    "ops/network-check.sh"
  )
  for script in "${RUNTIME_SCRIPTS[@]}"; do
    src="$REPO_DIR/$script"
    dest="/usr/local/sbin/$(basename "$script")"
    if [ -f "$src" ] && [ ! -f "$dest" ]; then
      sudo cp "$src" "$dest"
      sudo chmod 755 "$dest"
      echo "  ✅ Copied $script → $dest"
    elif [ -f "$dest" ]; then
      echo "  ℹ️  $dest already exists — skipping"
    else
      echo "  ⚠️  $src not found — skipping"
    fi
  done
  echo

  # ── 3. Remove the repo clone ───────────────────────
  echo "── Step 3: Remove repo clone ──"
  if [ -d "$REPO_DIR" ]; then
    echo "  Removing $REPO_DIR..."
    rm -rf "$REPO_DIR"
    echo "  ✅ Repo clone removed"
  else
    echo "  ℹ️  $REPO_DIR not found (already removed)"
  fi
  echo

  # ── 4. Remove git deploy key ───────────────────────
  echo "── Step 4: Remove git deploy key ──"
  if [ -f "$DEPLOY_KEY_PATH" ]; then
    rm -f "$DEPLOY_KEY_PATH"
    rm -f "${DEPLOY_KEY_PATH}.pub"
    echo "  ✅ Deploy key removed"
  else
    echo "  ℹ️  No deploy key found at $DEPLOY_KEY_PATH"
  fi

  # Clean SSH config entry for GitHub
  SSH_CONFIG="$HOME/.ssh/config"
  if [ -f "$SSH_CONFIG" ] && grep -q "panacea" "$SSH_CONFIG" 2>/dev/null; then
    sed -i '/# panacea deploy key/,/^$/d' "$SSH_CONFIG"
    echo "  ✅ SSH config entry removed"
  fi

  # Remove git global config pointing to deploy key
  if git config --global --get core.sshCommand 2>/dev/null | grep -q panacea 2>/dev/null; then
    git config --global --unset core.sshCommand
    echo "  ✅ Git SSH command unset"
  fi
  echo

  # ── 5. Remove provisioner service ──────────────────
  echo "── Step 5: Remove provisioner service ──"
  SERVICE_FILE="/etc/systemd/system/panacea-provision.service"
  if [ -f "$SERVICE_FILE" ]; then
    sudo systemctl disable panacea-provision.service 2>/dev/null || true
    sudo systemctl stop panacea-provision.service 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload
    echo "  ✅ panacea-provision.service removed"
  else
    echo "  ℹ️  Provisioner service not found (already removed or manual build)"
  fi
  echo

  # ── 6. Remove provision state file ─────────────────
  echo "── Step 6: Remove provision state ──"
  STATE_FILE="/var/lib/panacea/provision.state"
  if [ -f "$STATE_FILE" ]; then
    sudo rm -f "$STATE_FILE"
    echo "  ✅ State file removed"
  else
    echo "  ℹ️  State file not found"
  fi
  echo

  echo "═══ Finalize completed: $(date -u '+%Y-%m-%dT%H:%M:%SZ') ═══"
} 2>&1 | sudo tee "$LOG_FILE"

echo
echo "════════════════════════════════════════════"
echo "  ✅ POST-BUILD CLEANUP COMPLETE"
echo "  Device: $DEVICE_NAME"
echo "  Log:    $LOG_FILE"
echo "════════════════════════════════════════════"
echo
echo "What was removed:"
echo "  • /etc/panacea/ (staging credentials)"
echo "  • $REPO_DIR (build scripts)"
echo "  • Git deploy key + SSH config"
echo "  • Provisioner systemd service"
echo "  • Provision state file"
echo
echo "What remains:"
echo "  • /secure/ (encrypted vault + Twingate config)"
echo "  • All installed systemd services"
echo "  • Runtime scripts in /usr/local/sbin/"
echo "  • This log at $LOG_FILE"
echo
echo "To re-provision, re-clone the repo and start fresh."
