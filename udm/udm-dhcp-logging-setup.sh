#!/bin/bash
# =============================================================================
# UDM Pro SE - persistent dnsmasq DHCP logging + 6-month log rotation
# =============================================================================
# AUTHORITATIVE bootstrap. This single script is the source of truth for all
# on-box (/data) files. Run it on the UDM to install or fully restore:
#
#     ssh root@<UDM_IP> 'bash -s' < udm-dhcp-logging-setup.sh
#
# It writes everything to /data (which survives reboots AND firmware upgrades)
# and installs the systemd units into /etc (which survive reboots but are wiped
# on a firmware upgrade -> re-run /data/scripts/install-dhcp-logging.sh after one).
#
# Idempotent: safe to re-run at any time.
# =============================================================================
set -e
echo "== Installing dnsmasq DHCP logging persistence + rotation =="

mkdir -p /data/scripts/units /data/log/dhcp/archive

# ---- worker: ensures the logging directive exists; restarts dnsmasq if not ----
cat > /data/scripts/dnsmasq-dhcp-logging.sh <<'WORKER'
#!/bin/bash
# Ensure dnsmasq DHCP logging is enabled on the main LAN bridge.
# Idempotent + self-quieting: only writes + restarts dnsmasq when the logging
# directive is missing, so it never loops when re-triggered by its own write.
LOG_DIR=/data/log/dhcp
CONF_DIR=/run/dnsmasq.dhcp.conf.d
CONF_FILE="$CONF_DIR/dhcp-logging.conf"

mkdir -p "$LOG_DIR"
[ -d "$CONF_DIR" ] || exit 0   # dnsmasq main not provisioned yet

if [ -f "$CONF_FILE" ] \
   && grep -q '^log-dhcp$' "$CONF_FILE" \
   && grep -q "^log-facility=$LOG_DIR/dhcp.log$" "$CONF_FILE"; then
    exit 0   # already correct -> do nothing (prevents restart loop)
fi

printf 'log-dhcp\nlog-facility=%s/dhcp.log\n' "$LOG_DIR" > "$CONF_FILE"

# log-facility/log-dhcp are read only at startup; SIGHUP is insufficient.
# Restart dnsmasq-main; ubios-udapi-server respawns it reading the conf-dir.
PID="$(cat /run/dnsmasq-main.pid 2>/dev/null)"
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    logger -t dhcp-logging "re-applying DHCP logging; restarting dnsmasq-main ($PID)"
    kill "$PID"
fi
WORKER
chmod 0755 /data/scripts/dnsmasq-dhcp-logging.sh

# ---- log rotation worker: monthly rotate, keep 6 months, prune older ----
cat > /data/scripts/log-rotate-dhcp.sh <<'ROTATE'
#!/bin/bash
# Rotate /data/log/dhcp/dhcp.log monthly into compressed archives and keep a
# rolling 6-month retention window. Self-contained (no system logrotate needed)
# and persistent on /data. Uses copytruncate so dnsmasq's open fd keeps writing.
set -e
LOG_DIR=/data/log/dhcp
LOG="$LOG_DIR/dhcp.log"
ARCHIVE="$LOG_DIR/archive"
STAMP="$LOG_DIR/.last-rotate-month"
RETENTION_MONTHS=6
SIZE_CAP_BYTES=$((100 * 1024 * 1024))   # safety: also rotate if log exceeds 100 MB

mkdir -p "$ARCHIVE"
[ -f "$LOG" ] || exit 0

NOW_MONTH="$(date +%Y-%m)"
LAST_MONTH="$(cat "$STAMP" 2>/dev/null || echo '')"
SIZE="$(stat -c %s "$LOG" 2>/dev/null || echo 0)"

month_changed=0
[ -n "$LAST_MONTH" ] && [ "$LAST_MONTH" != "$NOW_MONTH" ] && [ "$SIZE" -gt 0 ] && month_changed=1
size_exceeded=0
[ "$SIZE" -ge "$SIZE_CAP_BYTES" ] && size_exceeded=1

if [ "$month_changed" = 1 ] || [ "$size_exceeded" = 1 ]; then
    # Tag the archive with the month being closed out.
    TAG="${LAST_MONTH:-$NOW_MONTH}"
    DEST="$ARCHIVE/dhcp-$TAG.log.gz"
    [ -e "$DEST" ] && DEST="$ARCHIVE/dhcp-$TAG-$(date +%d%H%M%S).log.gz"
    gzip -c "$LOG" > "$DEST"
    : > "$LOG"   # truncate in place (copytruncate); dnsmasq keeps appending
    logger -t dhcp-logrotate "rotated DHCP log -> $DEST (${SIZE} bytes)"
fi

echo "$NOW_MONTH" > "$STAMP"

# Retention: drop archives older than ~6 months.
find "$ARCHIVE" -name 'dhcp-*.log.gz' -type f -mtime +$((RETENTION_MONTHS * 31)) -delete 2>/dev/null || true
ROTATE
chmod 0755 /data/scripts/log-rotate-dhcp.sh

# ---- systemd oneshot service (runs the worker) ----
cat > /data/scripts/units/dnsmasq-dhcp-logging.service <<'SVC'
[Unit]
Description=Ensure dnsmasq DHCP logging is enabled
After=network.target

[Service]
Type=oneshot
ExecStart=/data/scripts/dnsmasq-dhcp-logging.sh

[Install]
WantedBy=multi-user.target
SVC

# ---- systemd path watcher (fires on reprovision + at boot) ----
cat > /data/scripts/units/dnsmasq-dhcp-logging.path <<'PTH'
[Unit]
Description=Re-apply dnsmasq DHCP logging when UniFi regenerates the conf dir

[Path]
PathModified=/run/dnsmasq.dhcp.conf.d
Unit=dnsmasq-dhcp-logging.service

[Install]
WantedBy=multi-user.target
PTH

# ---- systemd timer (belt-and-suspenders: catches anything inotify misses) ----
cat > /data/scripts/units/dnsmasq-dhcp-logging.timer <<'TMR'
[Unit]
Description=Periodic re-check that dnsmasq DHCP logging is enabled

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Unit=dnsmasq-dhcp-logging.service

[Install]
WantedBy=timers.target
TMR

# ---- log rotation service + daily timer ----
cat > /data/scripts/units/dnsmasq-dhcp-logrotate.service <<'RSVC'
[Unit]
Description=Rotate dnsmasq DHCP log (monthly, 6-month retention)

[Service]
Type=oneshot
ExecStart=/data/scripts/log-rotate-dhcp.sh
RSVC

cat > /data/scripts/units/dnsmasq-dhcp-logrotate.timer <<'RTMR'
[Unit]
Description=Daily check to rotate the dnsmasq DHCP log

[Timer]
OnCalendar=daily
Persistent=true
Unit=dnsmasq-dhcp-logrotate.service

[Install]
WantedBy=timers.target
RTMR

# ---- installer / self-healer (re-run after firmware upgrade) ----
cat > /data/scripts/install-dhcp-logging.sh <<'INST'
#!/bin/bash
# (Re)install + enable all DHCP-logging + rotation units. Safe to re-run.
set -e
for u in dnsmasq-dhcp-logging.service dnsmasq-dhcp-logging.path dnsmasq-dhcp-logging.timer \
         dnsmasq-dhcp-logrotate.service dnsmasq-dhcp-logrotate.timer; do
    cp "/data/scripts/units/$u" /etc/systemd/system/
done
systemctl daemon-reload
systemctl enable --now dnsmasq-dhcp-logging.service
systemctl enable --now dnsmasq-dhcp-logging.path
systemctl enable --now dnsmasq-dhcp-logging.timer
systemctl enable --now dnsmasq-dhcp-logrotate.timer
echo "Installed + enabled: logging service/path/timer + logrotate timer."
INST
chmod 0755 /data/scripts/install-dhcp-logging.sh

# ---- on-boot hooks (used if an on-boot runner like udm-boot is ever present) ----
mkdir -p /data/on_boot.d
cat > /data/on_boot.d/20-dnsmasq-dhcp-logging.sh <<'BOOT'
#!/bin/bash
# On-boot hook: (re)install DHCP logging persistence.
# NOTE: requires an on-boot runner (e.g. udm-boot) to execute /data/on_boot.d/.
/data/scripts/install-dhcp-logging.sh
BOOT
chmod 0755 /data/on_boot.d/20-dnsmasq-dhcp-logging.sh

# ---- install now ----
/data/scripts/install-dhcp-logging.sh

echo "== Status =="
systemctl is-enabled dnsmasq-dhcp-logging.service dnsmasq-dhcp-logging.path \
                     dnsmasq-dhcp-logging.timer dnsmasq-dhcp-logrotate.timer || true
echo "-- active conf --"
cat /run/dnsmasq.dhcp.conf.d/dhcp-logging.conf 2>/dev/null || echo "(conf not present yet)"
