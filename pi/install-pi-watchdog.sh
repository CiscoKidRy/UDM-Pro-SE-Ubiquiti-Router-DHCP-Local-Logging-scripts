#!/bin/bash
# =============================================================================
# Install the off-box watchdog on the Raspberry Pi (run as the service user).
# Idempotent. Assumes this repo is cloned at ~/udm-dhcp-logging.
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UDM_HOST="${1:-192.168.0.1}"

echo "== Installing UDM DHCP-logging watchdog on $(hostname) =="

# 1. Generate the dedicated Pi->UDM key if absent (private key stays on the Pi).
KEY="$HOME/.ssh/udm_restore_ed25519"
if [ ! -f "$KEY" ]; then
    ssh-keygen -t ed25519 -a 100 -f "$KEY" -N "" -C "pi-udm-restore@$(hostname)"
    echo ">> Generated $KEY"
    echo ">> Add this PUBLIC key to the UDM (hardened), see udm/authorized_keys.template:"
    echo "   from=\"$(hostname -I | awk '{print $1}')\",restrict,pty $(cat "$KEY.pub")"
else
    echo ">> Key already present: $KEY"
fi

# 2. Pin the UDM host key (verify the fingerprint against your records!).
KNOWN="$HOME/.ssh/udm_known_hosts"
if ! grep -q "$UDM_HOST" "$KNOWN" 2>/dev/null; then
    ssh-keyscan -t ed25519 "$UDM_HOST" > "$KNOWN" 2>/dev/null || true
    echo ">> Pinned UDM host key. VERIFY this fingerprint matches your UDM:"
    ssh-keygen -lf "$KNOWN" || true
fi
chmod 600 "$KNOWN" 2>/dev/null || true

# 3. Make scripts executable.
chmod 0755 "$SCRIPT_DIR"/*.sh

# 4. Install + enable the systemd timer. Substitute absolute path + user into
#    the service (systemd %h is unreliable in a system unit).
CHECK="$SCRIPT_DIR/udm-dhcp-logging-check.sh"
sudo cp "$SCRIPT_DIR/udm-dhcp-logging-check.timer" /etc/systemd/system/
sed -e "s|__RUN_USER__|$USER|" -e "s|__CHECK_SCRIPT__|$CHECK|" \
    "$SCRIPT_DIR/udm-dhcp-logging-check.service" | sudo tee /etc/systemd/system/udm-dhcp-logging-check.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now udm-dhcp-logging-check.timer

echo "== Done. Next steps =="
echo " - Authorize the Pi public key on the UDM (step 1 output) in BOTH:"
echo "     /data/on_boot.d/settings/ssh/authorized_keys  and  /root/.ssh/authorized_keys"
echo " - Create ~/.config/udm-watchdog/gmail.secret (mode 600) from the README."
echo " - Copy config.env.example -> $REPO_DIR/config.env and edit if needed."
echo " - Test:  $SCRIPT_DIR/udm-dhcp-logging-check.sh"
echo " - Watch: journalctl -u udm-dhcp-logging-check -f"
