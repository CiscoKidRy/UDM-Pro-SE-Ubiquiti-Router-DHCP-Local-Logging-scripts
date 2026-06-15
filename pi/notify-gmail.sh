#!/bin/bash
# Send an alert email via Gmail SMTP (app password). Self-contained on the Pi.
# Usage: notify-gmail.sh <severity> <subject> <body>
#
# Reads credentials from a root/user-only secret file (NEVER committed):
#   ~/.config/udm-watchdog/gmail.secret   with lines:
#       GMAIL_USER=youraddress@gmail.com
#       GMAIL_APP_PASSWORD=xxxxxxxxxxxxxxxx   # 16-char Google app password
#       ALERT_TO=where-to-send@example.com    # optional; defaults to GMAIL_USER
set -u
SEVERITY="${1:-FYI}"; SUBJECT="${2:-UDM watchdog}"; BODY="${3:-}"
SECRET="${GMAIL_SECRET:-$HOME/.config/udm-watchdog/gmail.secret}"

[ -f "$SECRET" ] || { logger -t udm-watchdog "notify: missing $SECRET"; exit 1; }
# shellcheck disable=SC1090
. "$SECRET"
: "${GMAIL_USER:?}" "${GMAIL_APP_PASSWORD:?}"
ALERT_TO="${ALERT_TO:-$GMAIL_USER}"

GMAIL_USER="$GMAIL_USER" GMAIL_APP_PASSWORD="$GMAIL_APP_PASSWORD" ALERT_TO="$ALERT_TO" \
SEVERITY="$SEVERITY" SUBJECT="$SUBJECT" BODY="$BODY" \
python3 - <<'PY'
import os, smtplib, ssl, socket
from email.message import EmailMessage

user = os.environ["GMAIL_USER"]
pw   = os.environ["GMAIL_APP_PASSWORD"]
to   = os.environ["ALERT_TO"]
sev  = os.environ["SEVERITY"]
host = socket.gethostname()

msg = EmailMessage()
msg["From"] = user
msg["To"] = to
msg["Subject"] = f"[{sev}] {os.environ['SUBJECT']}"
msg.set_content(f"{os.environ['BODY']}\n\n-- sent by udm-dhcp-logging watchdog on {host}")

ctx = ssl.create_default_context()
with smtplib.SMTP("smtp.gmail.com", 587, timeout=20) as s:
    s.starttls(context=ctx)
    s.login(user, pw)
    s.send_message(msg)
print("sent")
PY
rc=$?
[ "$rc" = 0 ] && logger -t udm-watchdog "notify sent: [$SEVERITY] $SUBJECT" \
              || logger -t udm-watchdog "notify FAILED (rc=$rc): [$SEVERITY] $SUBJECT"
exit $rc
