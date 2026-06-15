#!/bin/bash
# =============================================================================
# Off-box watchdog: verify UDM DHCP logging is alive, restore it if broken.
# Runs on the Raspberry Pi on a systemd timer. Reuses the UDM's own idempotent
# scripts for repair; only does a deep restore (re-push) if /data is lost.
# =============================================================================
set -u

# --- resolve paths -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# config.env: prefer repo root, fall back to /etc/udm-watchdog/
if [ -f "$REPO_DIR/config.env" ]; then
    # shellcheck disable=SC1091
    . "$REPO_DIR/config.env"
elif [ -f /etc/udm-watchdog/config.env ]; then
    # shellcheck disable=SC1091
    . /etc/udm-watchdog/config.env
fi

# --- defaults (override in config.env) ---------------------------------------
UDM_HOST="${UDM_HOST:-192.168.0.1}"
UDM_USER="${UDM_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/udm_restore_ed25519}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/udm_known_hosts}"
LOG_STALE_HOURS="${LOG_STALE_HOURS:-24}"
GRACE_SECONDS="${GRACE_SECONDS:-90}"   # let the on-box timer (60s) win transient cases
MAX_REPAIRS_PER_HOUR="${MAX_REPAIRS_PER_HOUR:-3}"
NOTIFY="${NOTIFY:-$SCRIPT_DIR/notify-gmail.sh}"
SETUP_PAYLOAD="${SETUP_PAYLOAD:-$REPO_DIR/udm/udm-dhcp-logging-setup.sh}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/udm-watchdog}"
GIT_PULL_MIN_INTERVAL="${GIT_PULL_MIN_INTERVAL:-3600}"   # hourly --ff-only pull

mkdir -p "$STATE_DIR"

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8
          -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS")
udm_ssh() { ssh "${SSH_OPTS[@]}" "$UDM_USER@$UDM_HOST" "$@"; }

log() { logger -t udm-watchdog "$*"; echo "[$(date '+%F %T')] $*"; }

notify() {  # notify <severity> <subject> <body>
    if [ -x "$NOTIFY" ]; then
        "$NOTIFY" "$1" "$2" "$3" || log "notify command failed (check gmail.secret): $2"
    else
        log "notify skipped (not executable: $NOTIFY): $2"
    fi
}

# --- single-instance lock ----------------------------------------------------
exec 9>"$STATE_DIR/lock"
flock -n 9 || { log "another check is running; exiting"; exit 0; }

# --- keep the local restore copy current (hourly, ff-only, never clobbers) ---
pull_stamp="$STATE_DIR/last-pull"
now="$(date +%s)"
last_pull="$(cat "$pull_stamp" 2>/dev/null || echo 0)"
if [ $((now - last_pull)) -ge "$GIT_PULL_MIN_INTERVAL" ] && [ -d "$REPO_DIR/.git" ]; then
    if git -C "$REPO_DIR" pull --ff-only --quiet 2>/dev/null; then
        echo "$now" > "$pull_stamp"
    else
        log "git pull --ff-only failed (diverged/offline); using existing local copy"
    fi
fi

# --- restart budget (flap guard) ---------------------------------------------
repairs_log="$STATE_DIR/repairs.log"
recent_repairs() {  # count repairs in the last hour
    [ -f "$repairs_log" ] || { echo 0; return; }
    local cutoff=$((now - 3600)) c=0 t
    while read -r t _; do [ "${t:-0}" -ge "$cutoff" ] && c=$((c+1)); done < "$repairs_log"
    echo "$c"
}
record_repair() { echo "$now $1" >> "$repairs_log"; tail -n 50 "$repairs_log" > "$repairs_log.tmp" && mv "$repairs_log.tmp" "$repairs_log"; }

# --- remote probe: returns ONE status token ----------------------------------
probe() {
    udm_ssh "bash -s" <<PROBE
set -e
SC=/data/scripts
need="\$SC/dnsmasq-dhcp-logging.sh \$SC/install-dhcp-logging.sh \$SC/log-rotate-dhcp.sh \$SC/units/dnsmasq-dhcp-logging.service \$SC/units/dnsmasq-dhcp-logging.path \$SC/units/dnsmasq-dhcp-logging.timer"
for f in \$need; do [ -f "\$f" ] || { echo NO_DATA_COPIES; exit 0; }; done
for u in dnsmasq-dhcp-logging.service dnsmasq-dhcp-logging.path dnsmasq-dhcp-logging.timer; do
    systemctl is-enabled "\$u" >/dev/null 2>&1 || { echo UNITS_MISSING; exit 0; }
done
CONF=/run/dnsmasq.dhcp.conf.d/dhcp-logging.conf
if [ ! -f "\$CONF" ] || ! grep -q '^log-dhcp\$' "\$CONF" || ! grep -q '^log-facility=/data/log/dhcp/dhcp.log\$' "\$CONF"; then
    echo CONF_MISSING; exit 0
fi
LOG=/data/log/dhcp/dhcp.log
PID="\$(cat /run/dnsmasq-main.pid 2>/dev/null || echo)"
dnsmasq_alive=0; [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null && dnsmasq_alive=1
if [ ! -f "\$LOG" ]; then echo LOG_STALE; exit 0; fi
age_h=\$(( ( \$(date +%s) - \$(stat -c %Y "\$LOG") ) / 3600 ))
if [ "\$age_h" -ge $LOG_STALE_HOURS ] && [ "\$dnsmasq_alive" = 0 ]; then echo LOG_STALE; exit 0; fi
echo OK
PROBE
}

# --- repair actions ----------------------------------------------------------
do_repair() {
    case "$1" in
        CONF_MISSING)   udm_ssh /data/scripts/dnsmasq-dhcp-logging.sh ;;
        UNITS_MISSING)  udm_ssh /data/scripts/install-dhcp-logging.sh ;;
        LOG_STALE)      udm_ssh /data/scripts/install-dhcp-logging.sh && udm_ssh /data/scripts/dnsmasq-dhcp-logging.sh ;;
        NO_DATA_COPIES) udm_ssh 'bash -s' < "$SETUP_PAYLOAD" ;;
    esac
}

# =============================================================================
# main
# =============================================================================
status="$(probe 2>/dev/null || echo UNREACHABLE)"
status="$(echo "$status" | tr -d '\r' | tail -n1)"
log "probe -> $status"

if [ "$status" = OK ]; then
    rm -f "$STATE_DIR/alerted"   # clear any standing alert
    exit 0
fi

if [ "$status" = UNREACHABLE ]; then
    if [ ! -f "$STATE_DIR/alerted" ]; then
        notify ACTION-NEEDED "UDM watchdog: gateway UNREACHABLE" \
               "The Pi watchdog could not SSH to $UDM_USER@$UDM_HOST to verify DHCP logging. Check the UDM and the Pi->UDM key."
        touch "$STATE_DIR/alerted"
    fi
    exit 1
fi

# For the transient case the on-box layer fixes within 60s, defer one grace window.
if [ "$status" = CONF_MISSING ]; then
    log "CONF_MISSING: waiting ${GRACE_SECONDS}s for on-box self-heal before acting"
    sleep "$GRACE_SECONDS"
    status="$(probe 2>/dev/null || echo UNREACHABLE)"; status="$(echo "$status" | tr -d '\r' | tail -n1)"
    log "re-probe -> $status"
    [ "$status" = OK ] && { rm -f "$STATE_DIR/alerted"; exit 0; }
fi

# Flap guard
if [ "$(recent_repairs)" -ge "$MAX_REPAIRS_PER_HOUR" ]; then
    log "repair budget exhausted ($MAX_REPAIRS_PER_HOUR/hr) for status=$status"
    notify ACTION-NEEDED "UDM watchdog: repeated failures (flapping)" \
           "DHCP logging keeps breaking (last status: $status). Auto-restore paused after $MAX_REPAIRS_PER_HOUR repairs in an hour. Manual investigation needed."
    exit 1
fi

log "repairing: $status"
record_repair "$status"
do_repair "$status" || log "repair command for $status returned non-zero"

# Re-verify
final="$(probe 2>/dev/null || echo UNREACHABLE)"; final="$(echo "$final" | tr -d '\r' | tail -n1)"
log "post-repair probe -> $final"

if [ "$final" = OK ]; then
    notify FYI "UDM watchdog: DHCP logging auto-restored" \
           "Detected '$status' and restored DHCP logging on $UDM_HOST. Logging is OK again. (Likely cause for UNITS_MISSING: a firmware upgrade wiped /etc.)"
    rm -f "$STATE_DIR/alerted"
    exit 0
else
    notify ACTION-NEEDED "UDM watchdog: restore FAILED" \
           "Detected '$status' and attempted restore, but logging is still '$final' on $UDM_HOST. Manual action needed."
    touch "$STATE_DIR/alerted"
    exit 1
fi
