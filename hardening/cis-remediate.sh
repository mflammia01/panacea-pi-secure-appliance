#!/usr/bin/env bash
set -euo pipefail

# ── Panacea CIS Stage 1 — Quick Wins ────────────────────────────
# Resolves ~20 CIS Debian/Ubuntu L1 findings flagged by Wazuh SCA.
# Safe to run on a hardened Pi — no service restarts except journald.
# Run as root or with sudo.

echo "=== Panacea CIS Stage 1 Remediation ==="
echo ""

# ── 1. Login Banners (CIS 33048–33053) ──────────────────────────
echo "[1/7] Configuring login banners..."
BANNER="Authorized uses only. All activity may be monitored and reported."

echo "$BANNER" | sudo tee /etc/issue /etc/issue.net /etc/motd > /dev/null
sudo chmod 644 /etc/issue /etc/issue.net /etc/motd
sudo chown root:root /etc/issue /etc/issue.net /etc/motd
echo "  ✓ Banners set on /etc/issue, /etc/issue.net, /etc/motd"

# ── 2. Password Aging Defaults (CIS 33208–33212) ────────────────
echo "[2/7] Setting password aging policies in /etc/login.defs..."
sudo sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   365/' /etc/login.defs
sudo sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'   /etc/login.defs
sudo sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   7/'   /etc/login.defs

# Set inactive lock for new accounts
sudo useradd -D -f 45
echo "  ✓ PASS_MAX_DAYS=365, PASS_MIN_DAYS=1, PASS_WARN_AGE=7, INACTIVE=45"

# ── 3. Restrict su Command (CIS 33182) ──────────────────────────
echo "[3/7] Restricting su to sugroup members..."
sudo groupadd -f sugroup
if ! grep -q "pam_wheel.so.*group=sugroup" /etc/pam.d/su 2>/dev/null; then
  echo "auth required pam_wheel.so use_uid group=sugroup" | sudo tee -a /etc/pam.d/su > /dev/null
fi
echo "  ✓ Only sugroup members can use su"

# ── 4. Sudo Hardening (CIS 33178, 33181) ────────────────────────
echo "[4/7] Hardening sudo configuration..."
sudo mkdir -p /etc/sudoers.d
cat <<'SUDOEOF' | sudo tee /etc/sudoers.d/panacea-cis > /dev/null
Defaults logfile="/var/log/sudo.log"
Defaults timestamp_timeout=15
SUDOEOF
sudo chmod 440 /etc/sudoers.d/panacea-cis
echo "  ✓ Sudo logging to /var/log/sudo.log, timeout 15 min"

# ── 5. Journald Hardening (CIS 33233–33234) ─────────────────────
echo "[5/7] Hardening journald configuration..."
sudo mkdir -p /etc/systemd/journald.conf.d
cat <<'JEOF' | sudo tee /etc/systemd/journald.conf.d/60-cis.conf > /dev/null
[Journal]
Compress=yes
ForwardToSyslog=no
JEOF
sudo systemctl restart systemd-journald
echo "  ✓ journald: Compress=yes, ForwardToSyslog=no"

# ── 6. Mount Hardening — /tmp & /dev/shm (CIS 33010–33017) ─────
echo "[6/7] Hardening /tmp and /dev/shm mount options..."

# /tmp as tmpfs with nosuid,nodev,noexec
if ! grep -q "^tmpfs.*/tmp" /etc/fstab 2>/dev/null; then
  echo "tmpfs /tmp tmpfs defaults,nosuid,nodev,noexec,size=256M 0 0" | sudo tee -a /etc/fstab > /dev/null
  echo "  + Added /tmp tmpfs entry to fstab"
fi
sudo mount -o remount,nosuid,nodev,noexec /tmp 2>/dev/null || sudo mount /tmp 2>/dev/null || true

# /dev/shm with nosuid,nodev,noexec
if ! grep -q "^tmpfs.*/dev/shm" /etc/fstab 2>/dev/null; then
  echo "tmpfs /dev/shm tmpfs defaults,nosuid,nodev,noexec 0 0" | sudo tee -a /etc/fstab > /dev/null
  echo "  + Added /dev/shm entry to fstab"
fi
sudo mount -o remount,nosuid,nodev,noexec /dev/shm 2>/dev/null || true
echo "  ✓ /tmp and /dev/shm hardened with nosuid,nodev,noexec"

# ── 7. Lock Root Account (CIS 33217) ────────────────────────────
echo "[7/7] Locking direct root login..."
sudo usermod -L root
echo "  ✓ Root account locked (sudo still works via your user)"

# ── Verification Summary ────────────────────────────────────────
echo ""
echo "=== Verification ==="
echo "Banners:     $(cat /etc/issue | head -1)"
echo "PASS_MAX:    $(grep ^PASS_MAX_DAYS /etc/login.defs | awk '{print $2}')"
echo "PASS_MIN:    $(grep ^PASS_MIN_DAYS /etc/login.defs | awk '{print $2}')"
echo "su restrict: $(grep pam_wheel /etc/pam.d/su | tail -1)"
echo "journald:    $(cat /etc/systemd/journald.conf.d/60-cis.conf 2>/dev/null | grep Compress)"
echo "/tmp mount:  $(mount | grep '/tmp ' | head -1)"
echo "/dev/shm:    $(mount | grep '/dev/shm' | head -1)"
echo "Root locked: $(passwd -S root 2>/dev/null | awk '{print $2}')"
echo ""
echo "=== CIS Stage 1 Complete — re-run Wazuh SCA scan to verify ==="
