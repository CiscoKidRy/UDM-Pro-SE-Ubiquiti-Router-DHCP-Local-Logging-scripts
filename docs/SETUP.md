# UDM Pro SE DHCP Local Logging — Comprehensive Reference

Everything needed to understand, operate, rebuild, and recover this system.
If you read only one file, read this one.

- [1. Problem & background](#1-problem--background)
- [2. Architecture](#2-architecture)
- [3. Every file explained](#3-every-file-explained)
- [4. Persistence matrix](#4-persistence-matrix)
- [5. Where every copy lives](#5-where-every-copy-lives)
- [6. Setup from scratch (runbook)](#6-setup-from-scratch-runbook)
- [7. Operations & troubleshooting](#7-operations--troubleshooting)
- [8. Disaster-recovery playbook](#8-disaster-recovery-playbook)
- [9. Security model](#9-security-model)
- [10. Known limitations & maintenance](#10-known-limitations--maintenance)

---

## 1. Problem & background

The UDM Pro SE runs dnsmasq for DHCP/DNS on the main LAN. We want DHCP transactions
(DISCOVER/OFFER/REQUEST/ACK) written to a persistent log. Four facts about UniFi OS
make this surprisingly hard:

1. **Runtime config lives in tmpfs.** dnsmasq for the main bridge runs with
   `--conf-dir=/run/dnsmasq.dhcp.conf.d/`. `/run` is tmpfs — **wiped on every reboot**.
2. **UniFi regenerates that directory on every reprovision.** The process
   `ubios-udapi-server` rewrites the conf-dir whenever any network/client setting
   changes. Any custom file we drop in there (our `dhcp-logging.conf`) gets **deleted**.
3. **`log-facility` is read only at startup.** Sending dnsmasq `SIGHUP` does **not**
   pick up a new `log-facility`/`log-dhcp`. dnsmasq must be **restarted**. We restart it
   by killing the main pid; `ubios-udapi-server` immediately respawns it, and the respawn
   re-reads the conf-dir (including our logging directive).
4. **Firmware upgrades wipe `/etc`.** The root filesystem is rebuilt on a UniFi OS
   upgrade. `/data` survives; `/etc` does not — so any systemd units we install there
   disappear after an upgrade.

This project addresses all four with layered self-healing plus an off-box safety net.

---

## 2. Architecture

```
/run/dnsmasq.dhcp.conf.d/dhcp-logging.conf      (log-dhcp + log-facility=/data/log/dhcp/dhcp.log)
        ▲  written by the worker, read by dnsmasq
        │
LAYER 1 — ON-BOX self-heal (lives in /data, units in /etc)
   • dnsmasq-dhcp-logging.service  (oneshot worker)
   • dnsmasq-dhcp-logging.path     (inotify watcher, re-applies in ~1s when UniFi wipes the dir)
   • dnsmasq-dhcp-logging.timer    (every 60s; catches anything inotify misses)
   Covers: reboots, UniFi reprovisions.
        ▲  re-installed by /data/scripts/install-dhcp-logging.sh
        │
LAYER 2 — OFF-BOX Pi watchdog (RaspPiServer, every 15 min)
   • SSH to the UDM, run a single probe -> status code
   • repair using the UDM's OWN idempotent scripts; deep-restore from repo if /data is gone
   • email via Gmail on action (FYI) or failure (ACTION-NEEDED)
   Covers: firmware upgrade (/etc wipe), /data loss, total Layer-1 failure, UDM unreachable.
        ▲  restore payload + config pulled from
        │
SOURCE OF TRUTH — this private Git repo (cloned on the Pi, `git pull --ff-only` hourly)
```

Recovery times: Layer 1 ≈ 1–60 s. Layer 2 ≈ up to 15 min (the rare cases Layer 1 can't cover).

---

## 3. Every file explained

### On the UDM (created by `udm/udm-dhcp-logging-setup.sh`)

| Path | Purpose |
|------|---------|
| `/data/scripts/dnsmasq-dhcp-logging.sh` | **Worker.** If `/run/.../dhcp-logging.conf` is missing/incorrect, writes it (`log-dhcp` + `log-facility=...`) and restarts dnsmasq by killing the main pid. Idempotent + self-quieting (exits if already correct, so it never loops when its own write re-triggers the path watcher). |
| `/data/scripts/log-rotate-dhcp.sh` | **Rotation.** Monthly (or at a 100 MB cap), gzip `dhcp.log` into `archive/dhcp-YYYY-MM.log.gz` via copytruncate, then prune archives older than ~6 months. |
| `/data/scripts/install-dhcp-logging.sh` | **Installer/self-healer.** Copies the 5 unit files from `/data/scripts/units/` into `/etc/systemd/system/`, `daemon-reload`, and enables them. Re-run this after a firmware upgrade. |
| `/data/scripts/units/dnsmasq-dhcp-logging.service` | Oneshot that runs the worker. |
| `/data/scripts/units/dnsmasq-dhcp-logging.path` | inotify watcher on `/run/dnsmasq.dhcp.conf.d` → triggers the service (~1s). |
| `/data/scripts/units/dnsmasq-dhcp-logging.timer` | Every 60s → triggers the service (belt-and-suspenders). |
| `/data/scripts/units/dnsmasq-dhcp-logrotate.service` | Oneshot that runs the rotation script. |
| `/data/scripts/units/dnsmasq-dhcp-logrotate.timer` | Daily → triggers rotation. |
| `/data/on_boot.d/20-dnsmasq-dhcp-logging.sh` | On-boot hook that runs the installer. **Dormant** unless an on-boot runner (e.g. udm-boot) is installed — included for completeness/future use. |
| `/data/on_boot.d/15-add-root-ssh-keys.sh` | Pre-existing hook that restores `/root/.ssh/authorized_keys` from the persistent copy. Also dormant without a runner. |
| `/data/on_boot.d/settings/ssh/authorized_keys` | Persistent root authorized keys (Windows admin key + the Pi watchdog key). |
| `/data/log/dhcp/dhcp.log` | The live DHCP log. |
| `/data/log/dhcp/archive/` | Rotated, compressed monthly archives (≤6 months). |
| `/run/dnsmasq.dhcp.conf.d/dhcp-logging.conf` | The active directive dnsmasq reads. **Ephemeral** — regenerated by the worker. |
| `/etc/systemd/system/dnsmasq-dhcp-logging.*`, `…-logrotate.*` | The live units. **Wiped on firmware upgrade.** |

### On the Raspberry Pi (this repo, cloned to `~/udm-dhcp-logging`)

| Path | Purpose |
|------|---------|
| `pi/udm-dhcp-logging-check.sh` | The watchdog. Pulls the repo (hourly, ff-only), probes the UDM over SSH, repairs per status code, re-verifies, emails. Has a flap guard and a grace window so it defers to Layer 1 for transient cases. |
| `pi/notify-gmail.sh` | Sends Gmail via SMTP using an app password from `~/.config/udm-watchdog/gmail.secret`. |
| `pi/install-pi-watchdog.sh` | Generates the Pi→UDM key, pins the UDM host key, installs+enables the systemd timer. |
| `pi/udm-dhcp-logging-check.{service,timer}` | systemd oneshot + 15-min timer. |
| `~/.ssh/udm_restore_ed25519` (+`.pub`) | The Pi's dedicated key. **Private key never leaves the Pi, never committed.** |
| `~/.ssh/udm_known_hosts` | Pinned UDM host key. |
| `~/.config/udm-watchdog/gmail.secret` | Gmail user + app password. **Never committed.** |
| `config.env` (optional) | Local overrides; gitignored. |

### Watchdog status codes

| Code | Meaning | Repair action |
|------|---------|---------------|
| `OK` | conf present, units enabled, log fresh (or quiet network) | none |
| `CONF_MISSING` | `/run` directive gone | wait one grace window (Layer 1 usually fixes), then run the worker |
| `UNITS_MISSING` | `/etc` units gone — **firmware upgrade signature** | run the installer |
| `LOG_STALE` | log not advancing **and** dnsmasq dead | run installer + worker |
| `NO_DATA_COPIES` | `/data/scripts` lost | re-push `udm/udm-dhcp-logging-setup.sh` and run it (deep restore) |
| `UNREACHABLE` | UDM down / SSH fails | email ACTION-NEEDED only |

---

## 4. Persistence matrix

| Component | Reboot | UniFi reprovision | Firmware upgrade | `/data` loss |
|-----------|:------:|:-----------------:|:----------------:|:------------:|
| `/run` conf | recreated (worker at boot) | recreated (path ~1s) | recreated | recreated after deep restore |
| `/data/scripts/*` | survives | survives | **survives** | **lost → Pi deep-restore** |
| `/etc` units | survive | survive | **wiped → installer re-run** | re-created by deep restore |
| dhcp.log + archives | survive | survive | survive | lost (logs are not backed up off-box) |
| Pi watchdog | independent of UDM events; recovers all of the above within ≤15 min |

---

## 5. Where every copy lives

| Location | Holds | Authoritative? |
|----------|-------|----------------|
| **GitHub repo (private)** | all code + docs | **Authoritative for code/docs going forward** |
| Pi `~/udm-dhcp-logging/` | git clone = restore payload | Derived from GitHub |
| Pi `~/.ssh/udm_restore_ed25519` | **private key (root-on-UDM)** | **Unique — exists nowhere else** |
| Pi `~/.config/udm-watchdog/gmail.secret` | Gmail app password | **Unique — exists nowhere else** |
| UDM `/data/scripts/**`, `/data/on_boot.d/**` | worker, installer, units, rotation, hooks | Authoritative on-device (survives FW upgrade) |
| UDM `/etc/systemd/system/**` | live units | Derived (re-created by the installer) |
| UDM `/run/dnsmasq.dhcp.conf.d/` | active conf | Volatile (regenerated) |
| UDM `/data/.../authorized_keys` + `/root/.ssh/authorized_keys` | Pi + admin public keys | `/data` authoritative; `/root` derived |
| Windows `C:\Tools\udm-pro-se-local-logging\` | local working copy / pre-push staging | Derived (pushed to GitHub) |

**Rule:** code is authoritative in GitHub; **secrets are authoritative only at their single
on-device location and are never centralized or committed.**

---

## 6. Setup from scratch (runbook)

Placeholders: `<UDM_IP>` (e.g. 192.168.0.1), `<PI_IP>` (e.g. 192.168.0.108),
`<PI_USER>` (e.g. ryanhocking).

### 6.1 UDM — install logging + rotation
```bash
ssh root@<UDM_IP> 'bash -s' < udm/udm-dhcp-logging-setup.sh
# Verify:
ssh root@<UDM_IP> "systemctl is-enabled dnsmasq-dhcp-logging.{service,path,timer} dnsmasq-dhcp-logrotate.timer; \
                   cat /run/dnsmasq.dhcp.conf.d/dhcp-logging.conf"
```

### 6.2 Pi — clone + install the watchdog
```bash
ssh <PI_USER>@<PI_IP>
git clone <repo-url> ~/udm-dhcp-logging
~/udm-dhcp-logging/pi/install-pi-watchdog.sh <UDM_IP>
# This generates ~/.ssh/udm_restore_ed25519, pins the UDM host key (VERIFY the
# printed fingerprint), and enables the 15-min timer. Note the printed PUBLIC key.
```

### 6.3 UDM — authorize the Pi's public key (hardened)
Append to **both** files on the UDM (see `udm/authorized_keys.template`):
```
from="<PI_IP>",restrict,pty ssh-ed25519 <PI_PUBLIC_KEY> pi-udm-restore@<PI_HOSTNAME>
```
- `/data/on_boot.d/settings/ssh/authorized_keys`  (persistent)
- `/root/.ssh/authorized_keys`  (live)

### 6.4 UDM — DHCP reservation for the Pi
In UniFi, reserve `<PI_IP>` for the Pi's MAC so the `from=` restriction stays valid.

### 6.5 Pi — Gmail alerting secret
Create a Google **app password** (Google Account → Security → App passwords), then:
```bash
mkdir -p ~/.config/udm-watchdog && chmod 700 ~/.config/udm-watchdog
cat > ~/.config/udm-watchdog/gmail.secret <<'EOF'
GMAIL_USER=youraddress@gmail.com
GMAIL_APP_PASSWORD=xxxxxxxxxxxxxxxx
ALERT_TO=youraddress@gmail.com
EOF
chmod 600 ~/.config/udm-watchdog/gmail.secret
```

### 6.6 Verify end-to-end
```bash
~/udm-dhcp-logging/pi/udm-dhcp-logging-check.sh    # expect: probe -> OK
journalctl -u udm-dhcp-logging-check -f
```

---

## 7. Operations & troubleshooting

**Read the DHCP log (UDM):**
```bash
ssh root@<UDM_IP> "grep DHCPACK /data/log/dhcp/dhcp.log | tail -20"
ssh root@<UDM_IP> "ls -lh /data/log/dhcp /data/log/dhcp/archive"
```

**Watchdog history (Pi):**
```bash
journalctl -u udm-dhcp-logging-check --since today
systemctl list-timers udm-dhcp-logging-check.timer
```

**Force a check now (Pi):** `~/udm-dhcp-logging/pi/udm-dhcp-logging-check.sh`

**Manual restore at each layer (UDM):**
```bash
ssh root@<UDM_IP> /data/scripts/dnsmasq-dhcp-logging.sh     # re-apply conf (Layer-1 worker)
ssh root@<UDM_IP> /data/scripts/install-dhcp-logging.sh     # re-install units (after FW upgrade)
ssh root@<UDM_IP> 'bash -s' < udm/udm-dhcp-logging-setup.sh # full rebuild (deep restore)
```

**Force a log rotation (UDM):** `ssh root@<UDM_IP> /data/scripts/log-rotate-dhcp.sh`

**Common issues**

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Log mtime stale, no new entries | reprovision wiped conf and Layer 1 failed | run the worker; check `.path`/`.timer` enabled |
| Logging gone after a UniFi update | firmware wiped `/etc` units | run the installer (Pi does this automatically within 15 min) |
| Pi can't SSH to UDM | key not authorized / IP changed / host key changed | re-authorize key, confirm DHCP reservation, re-pin host key |
| No alert emails | bad app password / no `gmail.secret` | re-create the secret; test `pi/notify-gmail.sh FYI test test` |

---

## 8. Disaster-recovery playbook

| Scenario | Recovery |
|----------|----------|
| **Firmware upgrade** wiped `/etc` | Automatic: Pi detects `UNITS_MISSING` within 15 min and runs the installer. Manual: `ssh root@<UDM_IP> /data/scripts/install-dhcp-logging.sh`. |
| **`/data` lost** (disk/factory reset) | Pi detects `NO_DATA_COPIES`, re-pushes `udm/udm-dhcp-logging-setup.sh`, rebuilds everything. Then re-authorize keys (6.3). |
| **Pi lost / rebuilt** | Re-clone repo, run `install-pi-watchdog.sh`, re-authorize the new public key on the UDM, re-create `gmail.secret`. |
| **Key compromised / rotate** | Generate a new key on the Pi, add the new public key to the UDM authorized_keys (both files), remove the old entry. |
| **Repo lost** | Clone exists on the Pi; Windows staging copy at `C:\Tools\udm-pro-se-local-logging\`. Re-create the GitHub repo and push. |

---

## 9. Security model

- **Blast radius:** the Pi's key is **root on the gateway**. Anyone with the Pi's private
  key (or root on the Pi) controls routing/DNS/DHCP/firewall. The Pi is comparatively
  soft (cloudflared tunnel, Wi-Fi, NOPASSWD sudo), so treat the Pi as gateway-equivalent.
- **Hardening applied:** dedicated key (independent revocation), `from="<PI_IP>"` source
  restriction (paired with a DHCP reservation), `restrict,pty`, and host-key pinning on the
  Pi (`StrictHostKeyChecking=yes`).
- **No secrets in the repo:** enforced by `.gitignore` and a pre-commit secret scan. Private
  keys and the Gmail app password exist only on the Pi.
- **Repo is private:** it documents internal IPs and root-persistence techniques.
- **Caveat:** `from=` is IP-pinned, not host-pinned — an on-LAN spoofer on a flat network
  could defeat it. Its value is limiting accidental/remote reuse.

---

## 10. Known limitations & maintenance

- **Log-freshness heuristic:** `LOG_STALE` only fires when dnsmasq is also dead, to avoid
  false positives on a genuinely quiet network. A long-idle LAN won't be misread as broken.
- **15-minute window:** after a firmware upgrade, logging may be down for up to 15 min
  before the Pi repairs it. Acceptable for a home LAN; not real-time.
- **Dormant on-boot runner:** `/data/on_boot.d/*` only auto-runs if an on-boot runner
  (e.g. udm-boot) is installed — intentionally not added (see the project decision log).
  After a major firmware upgrade, `/root/.ssh/authorized_keys` may need the admin key
  re-pushed from Windows once if the runtime copy is lost; the Pi handles the logging units.
- **Soft dependency:** deep restore (`/data` loss) needs the Pi up. If both fail at once,
  rebuild from the Windows staging copy.
- **Scope:** this verifies the dnsmasq *logging plumbing*, not UniFi application-level DHCP
  behavior, and does not back up historical log *contents* off-box.
- **Maintenance:** none routine. Review after major UniFi OS releases; confirm the Pi's
  DHCP reservation persists; rotate the key if the Pi changes hands.
