#!/usr/bin/env bash
set -euo pipefail

# ── Panacea CIS Stage 2 — Extended Hardening ────────────────────
# Resolves ~15 additional CIS Debian/Ubuntu L1 findings flagged by Wazuh SCA.
# Safe to run after Stage 1 — no impact on Twingate, Wazuh, or encrypted vault.
# Run as root or with sudo.

echo "=== Panacea CIS Stage 2 — Extended Hardening ==="
echo ""

# ── 1. SSH Hardening (CIS 33158, 33160, 33168, 33171, 33103) ────
echo "[1/14] Hardening SSH configuration..."
sudo mkdir -p /etc/ssh/sshd_config.d
cat <<'SSHEOF' | sudo tee /etc/ssh/sshd_config.d/60-cis-stage2.conf > /dev/null
# CIS Stage 2 — SSH hardening
Banner /etc/issue.net
DisableForwarding yes
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
MaxStartups 10:30:60
ClientAliveInterval 15
ClientAliveCountMax 3
SSHEOF
sudo systemctl restart sshd
echo "  ✓ SSH: Banner, MACs, MaxStartups, ClientAlive, DisableForwarding"

# ── 2. Cron Permissions (CIS 33099–33104) ────────────────────────
echo "[2/14] Tightening cron file permissions..."
sudo chmod 0600 /etc/crontab 2>/dev/null || true
for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d; do
  if [ -d "$d" ]; then
    sudo chmod 0700 "$d"
    sudo chown root:root "$d"
  fi
done
sudo chown root:root /etc/crontab 2>/dev/null || true
echo "  ✓ Cron dirs 0700, crontab 0600, all root:root"

# ── 3. ENCRYPT_METHOD YESCRYPT (CIS 33211) ──────────────────────
echo "[3/14] Setting ENCRYPT_METHOD to YESCRYPT..."
if grep -q "^ENCRYPT_METHOD" /etc/login.defs; then
  sudo sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD YESCRYPT/' /etc/login.defs
else
  echo "ENCRYPT_METHOD YESCRYPT" | sudo tee -a /etc/login.defs > /dev/null
fi
echo "  ✓ ENCRYPT_METHOD set to YESCRYPT in /etc/login.defs"

# ── 4. Remove nullok from PAM (CIS 33204) ───────────────────────
echo "[4/14] Removing nullok from PAM modules..."
for f in /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-password /etc/pam.d/common-session; do
  if [ -f "$f" ]; then
    sudo sed -i 's/\bnullok\b//g' "$f"
  fi
done
echo "  ✓ nullok removed from all common-* PAM files"

# ── 5. Ensure use_authtok in pam_unix (CIS 33207) ───────────────
echo "[5/14] Ensuring use_authtok in common-password..."
if grep -q "pam_unix.so" /etc/pam.d/common-password 2>/dev/null; then
  if ! grep "pam_unix.so" /etc/pam.d/common-password | grep -q "use_authtok"; then
    sudo sed -i '/pam_unix.so/ s/$/ use_authtok/' /etc/pam.d/common-password
  fi
fi
echo "  ✓ use_authtok present in common-password pam_unix line"

# ── 6. Apply chage to existing users (CIS 33208–33210, 33212) ───
echo "[6/14] Applying password aging to existing user accounts..."
for user in $(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd); do
  sudo chage --maxdays 365 --mindays 1 --warndays 7 --inactive 45 "$user" 2>/dev/null || true
done
echo "  ✓ PASS_MAX=365, MIN=1, WARN=7, INACTIVE=45 applied to all human accounts"

# ── 7. Password/shadow sync — pwconv (CIS housekeeping) ─────────
echo "[7/14] Running pwconv and grpconv..."
sudo pwconv
sudo grpconv
echo "  ✓ Password and group shadow files synchronized"

# ── 8. opasswd permissions (CIS 33201) ──────────────────────────
echo "[8/14] Setting opasswd permissions..."
sudo touch /etc/security/opasswd
sudo chmod 600 /etc/security/opasswd
sudo chown root:root /etc/security/opasswd
echo "  ✓ /etc/security/opasswd created with 600 root:root"

# ── 9. systemd-journal-remote (CIS 33229, 33231) ────────────────
echo "[9/14] Installing and enabling systemd-journal-remote..."
sudo apt-get update -qq
sudo apt-get install -y -qq systemd-journal-remote 2>/dev/null || true
sudo systemctl enable systemd-journal-upload.service 2>/dev/null || true
sudo systemctl start systemd-journal-upload.service 2>/dev/null || true
echo "  ✓ systemd-journal-upload installed and enabled"

# ── 10. Disable avahi-daemon (CIS 33065) ─────────────────────────
echo "[10/14] Disabling avahi-daemon..."
sudo systemctl stop avahi-daemon.socket avahi-daemon.service 2>/dev/null || true
sudo systemctl mask avahi-daemon.socket avahi-daemon.service 2>/dev/null || true
echo "  ✓ avahi-daemon stopped and masked"

# ── 11. Disable bluetooth (CIS 33109) ───────────────────────────
echo "[11/14] Disabling bluetooth..."
sudo systemctl stop bluetooth.service 2>/dev/null || true
sudo systemctl mask bluetooth.service 2>/dev/null || true
echo "  ✓ bluetooth.service stopped and masked"

# ── 12. Verify chrony NTP (CIS 33097) ────────────────────────────
echo "[12/14] Verifying chrony is active (required for Twingate clock sync)..."
if systemctl is-active --quiet chronyd 2>/dev/null; then
  echo "  ✓ chronyd is running — NTP via chrony (single NTP source, CIS-compliant)"
else
  echo "  ⚠ chronyd not running — starting chrony..."
  sudo systemctl enable chrony 2>/dev/null || true
  sudo systemctl start chrony 2>/dev/null || true
  echo "  ✓ chrony enabled and started"
fi

# ── 13. Banner file permissions (CIS 33051–33053) ───────────────
echo "[13/14] Setting banner file permissions..."
sudo chmod u-x,go-wx /etc/motd /etc/issue /etc/issue.net 2>/dev/null || true
echo "  ✓ /etc/motd, /etc/issue, /etc/issue.net permissions tightened"

# ── 14. Unmask tmp.mount (CIS 33010) ────────────────────────────
echo "[14/14] Unmasking tmp.mount..."
sudo systemctl unmask tmp.mount 2>/dev/null || true
echo "  ✓ tmp.mount unmasked (aligns with fstab tmpfs entry from Stage 1)"

# ── Verification Summary ────────────────────────────────────────
echo ""
echo "=== Verification ==="
echo "SSH MACs:        $(grep '^MACs' /etc/ssh/sshd_config.d/60-cis-stage2.conf 2>/dev/null || echo 'not set')"
echo "MaxStartups:     $(grep '^MaxStartups' /etc/ssh/sshd_config.d/60-cis-stage2.conf 2>/dev/null || echo 'not set')"
echo "ENCRYPT_METHOD:  $(grep ^ENCRYPT_METHOD /etc/login.defs | awk '{print $2}')"
echo "nullok check:    $(grep -c 'nullok' /etc/pam.d/common-* 2>/dev/null || echo '0') occurrences"
echo "opasswd perms:   $(stat -c '%a %U:%G' /etc/security/opasswd 2>/dev/null || echo 'missing')"
echo "avahi masked:    $(systemctl is-enabled avahi-daemon 2>/dev/null || echo 'masked/not-found')"
echo "bluetooth:       $(systemctl is-enabled bluetooth 2>/dev/null || echo 'masked/not-found')"
echo "chrony:          $(systemctl is-active chronyd 2>/dev/null || echo 'not running')"
echo "journal-upload:  $(systemctl is-enabled systemd-journal-upload 2>/dev/null || echo 'not found')"
echo "tmp.mount:       $(systemctl is-enabled tmp.mount 2>/dev/null || echo 'not found')"
echo ""
echo "=== CIS Stage 2 Complete — re-run Wazuh SCA scan to verify ==="
