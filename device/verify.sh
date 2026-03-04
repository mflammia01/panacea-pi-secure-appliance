#!/usr/bin/env bash
set -euo pipefail

echo "Kernel:"; uname -a
echo
echo "Disk/crypto state:"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS
echo
echo "UFW:"; sudo ufw status verbose || true
echo
echo "SSHD:"; sudo sshd -T | egrep 'passwordauthentication|permitrootlogin|pubkeyauthentication|allowusers' || true
echo
echo "fail2ban:"; sudo systemctl is-enabled fail2ban && sudo fail2ban-client status sshd || true
echo
echo "unattended-upgrades:"; systemctl is-enabled unattended-upgrades || true
echo
echo "2FA:"; grep -c 'pam_google_authenticator' /etc/pam.d/sshd && echo "enabled" || echo "NOT configured"
