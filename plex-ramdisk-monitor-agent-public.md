# Plex Ramdisk Monitor — Agent Description

> **Note:** Replace all `<PLACEHOLDER>` values with your site-specific values before use.
> Paths, service names, and script locations are standard to the plex-ramdisk-setup.sh installer
> and should not need changes unless you customised the install.

## Purpose

This agent monitors the complete health of the `<YOUR_HOSTNAME>` server — Ubuntu system resources, Plex Media Server, CIFS share mounts, and the ramdisk database process. It watches log files, service states, disk usage, network connectivity, and backup integrity, proactively alerting on problems before they affect Plex availability or result in data loss.

**Scope:**
- Ubuntu 20.04+ host health (CPU, memory, disk, network, kernel, services)
- Plex Media Server process and database integrity
- CIFS share mounts (media library access)
- Ramdisk DB process (boot restore, shutdown backup, daily snapshots, manifest verification)

---

## System Context

**Host:** `<YOUR_HOSTNAME>` (Ubuntu 20.04+ LTS, x86_64 or aarch64)
**Ramdisk:** `/mnt/ramdisk` — size determined by your setup, Plex databases live at `/mnt/ramdisk/PlexDB/Databases/`
**Plex DB symlink:** `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases → /mnt/ramdisk/PlexDB/Databases`
**Setup script:** `~/plex-ramdisk-setup.sh` (check current version with `grep "^SETUP_VERSION" ~/plex-ramdisk-setup.sh`)
**Backup script:** `/usr/local/bin/plex-ramdisk-backup.sh` (check version with `grep "^# Version:" /usr/local/bin/plex-ramdisk-backup.sh`)
**Restore script:** `/usr/local/bin/plex-ramdisk-restore.sh` (check version with `grep "^# Version:" /usr/local/bin/plex-ramdisk-restore.sh`)

---

## Log Files to Monitor

| Log File | Purpose | Check Frequency |
|---|---|---|
| `/var/log/plex-ramdisk-backup.log` | All backup and restore activity | Continuous |
| `/var/log/plex-ramdisk-error.log` | Errors and warnings from all scripts | Continuous |
| `/var/log/plex-ramdisk-setup.log` | Setup and validation activity | On change |
| `journalctl -u plex-ramdisk-sync` | Systemd service output | Continuous |
| `journalctl -u plexmediaserver` | Plex startup/shutdown events | Continuous |

---

## Services to Monitor

| Service | Expected State | Action on Failure |
|---|---|---|
| `plex-ramdisk-sync.service` | `active (exited)` after boot | Alert immediately — Plex will not start |
| `plexmediaserver.service` | `active (running)` | Alert — check if restore service failed |
| Cron job (default 04:30) | Backup entry in log daily | Alert if no entry within 30 min of scheduled time |

---

## Checks and Alert Conditions

### Critical — Alert Immediately

**Restore service failed on boot**
```
journalctl -u plex-ramdisk-sync | grep "Failed\|FAILURE\|exit-code"
```
Symptom: `plex-ramdisk-sync.service` in failed state. Plex will not start. Most common causes: restore script error, ramdisk not mounted, hash verification failure.

**Plex not running**
```
systemctl is-active plexmediaserver
```
If inactive and `plex-ramdisk-sync` is also failed — restore caused it. If `plex-ramdisk-sync` is healthy — Plex crashed independently.

**Hash verification failure in restore log**
```
grep "failed hash verification\|FAILED\|Missing after restore" /var/log/plex-ramdisk-backup.log
```
Means restore found files missing or corrupted. Check which snapshot was used and whether all snapshots are also failing.

**Ramdisk not mounted**
```
mountpoint -q /mnt/ramdisk || echo "NOT MOUNTED"
```
If the ramdisk is not mounted, restore cannot run and Plex cannot start.

**Script-level `local` error in installed scripts**
```
grep "local: can only be used in a function" /var/log/plex-ramdisk-backup.log
journalctl -u plex-ramdisk-sync | grep "local: can only"
```
This indicates an outdated installed script. Run `sudo bash ~/plex-ramdisk-setup.sh --fix` immediately.

**Ramdisk critically full**
```
df -k /mnt/ramdisk | awk 'NR==2{print $5}' | tr -d '%'
```
Alert if above 85%. With typical DB sizes well under ramdisk capacity this should not happen unless Plex is writing large amounts of WAL data or unexpected files appeared on the ramdisk.

---

### Warning — Alert Within 1 Hour

**Scheduled backup did not run**
Check for a backup entry dated today after 05:00:
```
grep "$(date +%Y-%m-%d) 04:" /var/log/plex-ramdisk-backup.log | grep "Backup started"
```
If no entry by 05:30, the cron job did not fire. Check `systemctl status cron` and `cat /etc/cron.d/plex-ramdisk-backup`.

**WAL files not empty at backup time**
```
grep "WAL files not empty" /var/log/plex-ramdisk-backup.log | tail -5
```
The `com.plexapp.dlna.db-wal` WAL consistently does not checkpoint — this is a known Plex behavior with the DLNA database and is not immediately harmful. Log it but only escalate if the main library WAL files also fail to checkpoint.

**Backup duration increasing significantly**
```
grep "Duration:" /var/log/plex-ramdisk-backup.log | tail -10
```
Normal backup duration depends on DB size and disk speed — establish a baseline from your first few runs. If duration exceeds 300s, investigate disk write speed on backup destination or unexpected DB size growth.

**Manifest is empty (0 entries)**
```
wc -l < /var/backups/plex-ramdisk/current/current.sha256
```
An empty manifest means hash verification is not running correctly. Run a manual backup: `sudo /usr/local/bin/plex-ramdisk-backup.sh`

**Stray files on ramdisk**
```
find /mnt/ramdisk/PlexDB/Databases -maxdepth 1 -name "*.sha256" -o -name "*.tmp" 2>/dev/null
```
Stray manifest files on the ramdisk indicate a previous backup or restore did not clean up correctly.

**New database files appeared on ramdisk**
```
find /mnt/ramdisk/PlexDB/Databases -maxdepth 1 -name "*.db" | sort
```
Compare against known files. New `.db` files (like `tv.plex.providers.epg.cloud-*.db`) are picked up automatically by the directory symlink and will be included in backups — log them for awareness but no action required unless they are very large.

**Error log has new entries**
```
wc -l < /var/log/plex-ramdisk-error.log
```
Track line count and alert if it increases since last check. All ERRORs and WARNs from all scripts go here.

**Snapshot count at maximum**
```
ls /var/backups/plex-ramdisk/snapshots/ | wc -l
```
Alert if count drops unexpectedly (snapshots being deleted faster than created) or if count stays at 0 for more than 48 hours after setup.

**Backup disk space low**
```
df -h /var/backups/plex-ramdisk
```
Alert if free space on the backup disk falls below a comfortable threshold for your setup (suggested: 3× your total DB size). Snapshots use hard links so incremental storage is small, but large DB changes accumulate over time.

---

### Informational — Daily Digest

Include in a daily summary report:

- Last backup result and duration
- Current ramdisk usage (used / available / %)
- Current backup `current/` size and file count
- Snapshot count and age of newest snapshot
- Plex uptime
- Any WAL checkpoint warnings
- Dated DB backup file count in `/var/lib/plex-ramdisk/db-backups/`
- Error log entry count since last digest
- Script versions: setup, backup, restore

---

## Diagnostic Commands

Run these when investigating an issue:

```bash
# Full health snapshot
sudo bash ~/plex-ramdisk-setup.sh --summary

# Deep component validation
sudo bash ~/plex-ramdisk-setup.sh --validate

# Setup step states
sudo bash ~/plex-ramdisk-setup.sh --status

# Recent backup/restore activity (last 50 lines)
sudo tail -50 /var/log/plex-ramdisk-backup.log

# All errors and warnings
sudo cat /var/log/plex-ramdisk-error.log

# This boot's sync service output
journalctl -u plex-ramdisk-sync -b --no-pager

# This boot's Plex output
journalctl -u plexmediaserver -b --no-pager -n 50

# Ramdisk contents
ls -lh /mnt/ramdisk/PlexDB/Databases/

# Backup current/ contents
ls -lh /var/backups/plex-ramdisk/current/

# Snapshot list
ls -lh /var/backups/plex-ramdisk/snapshots/

# Verify manifest integrity manually
sudo sha256sum -c /var/backups/plex-ramdisk/current/current.sha256

# Manually trigger backup (stops Plex briefly)
sudo /usr/local/bin/plex-ramdisk-backup.sh

# Attempt auto-repair of issues
sudo bash ~/plex-ramdisk-setup.sh --fix
```

---

## Recovery Procedures

### Restore service failed — Plex not starting

```bash
# Check what failed
journalctl -u plex-ramdisk-sync -b --no-pager
tail -30 /var/log/plex-ramdisk-backup.log

# Attempt fix
sudo bash ~/plex-ramdisk-setup.sh --fix

# Manually restart restore service
sudo systemctl restart plex-ramdisk-sync.service
sudo systemctl status plex-ramdisk-sync.service

# If successful, start Plex
sudo systemctl start plexmediaserver
```

### Hash verification failed — all sources corrupted

```bash
# List available snapshots
ls -lh /var/backups/plex-ramdisk/snapshots/

# Manually restore from a specific snapshot
sudo rsync -av --exclude="*.sha256" --exclude="*.tmp" \
  /var/backups/plex-ramdisk/snapshots/YYYY-MM-DD_HH-MM-SS/ \
  /mnt/ramdisk/PlexDB/Databases/
sudo chown -R plex:plex /mnt/ramdisk/PlexDB/Databases/
sudo systemctl start plexmediaserver
```

### Manifest empty — backup not hashing correctly

```bash
# Check for stray files
find /mnt/ramdisk/PlexDB/Databases -name "*.sha256" -delete
find /var/backups/plex-ramdisk/current -name "*.sha256" -delete

# Run fresh backup to regenerate manifest
sudo /usr/local/bin/plex-ramdisk-backup.sh

# Verify
wc -l < /var/backups/plex-ramdisk/current/current.sha256
```

### Script version mismatch detected

```bash
# Check installed vs expected versions
grep "^# Version:" /usr/local/bin/plex-ramdisk-backup.sh
grep "^# Version:" /usr/local/bin/plex-ramdisk-restore.sh

# Rewrite with current versions
sudo bash ~/plex-ramdisk-setup.sh --fix
```

---

## Known Benign Conditions (Do Not Alert)

- `com.plexapp.dlna.db-wal` WAL not empty at backup time — DLNA WAL does not checkpoint cleanly; SQLite recovers automatically on next open
- `libusb_init failed` in Plex journal — Plex Tuner Service looking for USB hardware that doesn't exist; pre-existing behavior unrelated to ramdisk
- Ramdisk vs manifest hash mismatch warning during `--validate` when Plex is running — expected, Plex is actively writing to DB files
- Symlink owned by `root:root` — Linux does not enforce symlink ownership; target directory is `plex:plex` which is what matters
- `plex-ramdisk-sync.service` state `active (exited)` — correct for a oneshot service that ran successfully

---

## Future Features (Planned — Not Yet Implemented)

- **Watchdog service** (`STEP_8_WATCHDOG`) — monitors Plex log for SQLite error patterns; auto-restores from snapshot on database corruption; requires `sqlite3` to be installed
- **Dated DB backup pruning** (`STEP_9_DB_BACKUP_PRUNING`) — retention policy for files in `/var/lib/plex-ramdisk/db-backups/`; currently accumulates indefinitely

When these are implemented, extend this agent description to include their log files and alert conditions.

---

# Ubuntu Server Health Monitoring

## Purpose

Monitor the health of the Ubuntu host itself — CPU, memory, disk, network, system services, and kernel — to catch infrastructure problems before they impact Plex or the ramdisk database process.

---

## System Resources

### CPU

**Commands:**
```bash
# Current load averages (1m, 5m, 15m)
uptime

# Per-core utilization snapshot
mpstat -P ALL 1 3

# Top CPU consumers
ps aux --sort=-%cpu | head -15

# Sustained high CPU (run for 10 seconds)
sar -u 1 10
```

**Alert conditions:**
- Load average (1m) exceeds number of CPU cores for more than 5 minutes → Warning
- Load average (1m) exceeds 2× number of CPU cores → Critical
- Single process consuming >90% CPU sustained → Warning (identify process)
- `iowait` consistently above 20% → Warning — disk I/O bottleneck, may affect backup performance

**Get CPU core count:**
```bash
nproc
```

---

### Memory

**Commands:**
```bash
# Overall memory summary
free -h

# Detailed memory breakdown
cat /proc/meminfo

# Top memory consumers
ps aux --sort=-%mem | head -15

# Memory pressure over time
vmstat 5 6
```

**Alert conditions:**
- Available memory below 4GB → Warning (ramdisk consumes RAM proportional to its contents — monitor ramdisk usage and available memory together)
- Available memory below 2GB → Critical — system may start swapping, ramdisk performance degrades
- Swap usage above 10% → Warning — system is under memory pressure
- Swap usage above 50% → Critical

**Note on ramdisk and memory:** The ramdisk consumes RAM proportional to its content (DB files plus any WAL files). If the ramdisk fills significantly, available system memory will drop correspondingly. Monitor both ramdisk usage and available memory together.

---

### Disk

**Commands:**
```bash
# All filesystem usage
df -h

# Inode usage (can fill independently of space)
df -i

# Disk I/O stats
iostat -x 1 5

# Largest directories under /var
du -sh /var/* 2>/dev/null | sort -rh | head -10

# Backup disk specifically
df -h /var/backups/plex-ramdisk

# Log directory size
du -sh /var/log/

# Find files larger than 1GB
find / -xdev -size +1G -ls 2>/dev/null
```

**Alert conditions:**
- Any filesystem above 85% full → Warning
- Any filesystem above 95% full → Critical
- `/var/backups/plex-ramdisk` below 50GB free → Warning (snapshots need space)
- `/var/log` above 5GB → Warning — check for runaway log files
- Inode usage above 80% on any filesystem → Warning
- Disk I/O `%util` consistently above 80% → Warning — may affect backup duration

---

### Network

**Commands:**
```bash
# Interface statistics
ip -s link

# Active connections
ss -tuln

# Network throughput
sar -n DEV 1 5

# Check specific interface (replace eth0 with actual interface)
ip addr show

# DNS resolution test
dig +short google.com

# Test connectivity to NAS/CIFS host
ping -c 4 <YOUR_NAS_IP>
```

**Alert conditions:**
- Network interface down → Critical if primary interface
- Packet error rate above 0.1% → Warning
- DNS resolution failing → Warning — affects Plex metadata fetching
- Ping to NAS host failing → Critical if CIFS shares are mounted (see CIFS section)

---

## System Services

**Commands:**
```bash
# All failed units
systemctl --failed

# Units that failed to start
journalctl -p err -b --no-pager | head -30

# Check specific service
systemctl status <service>

# Service uptime
systemctl show <service> --property=ActiveEnterTimestamp
```

**Services to monitor:**

| Service | Expected State | Alert Level |
|---|---|---|
| `ssh.service` | active (running) | Critical if down |
| `cron.service` | active (running) | Critical — backup cron won't fire |
| `systemd-journald.service` | active (running) | Warning |
| `networking.service` or `NetworkManager` | active | Critical |
| `smbd.service` / `nmbd.service` | active if Samba used | Warning |

**Alert conditions:**
- Any service in `failed` state → Warning minimum, Critical for ssh/cron/networking
- `cron.service` not running → Critical — the 05:00 backup will not fire
- More than 3 failed units → Warning — investigate systemctl --failed

---

## Kernel and System Health

**Commands:**
```bash
# Kernel messages (errors and warnings)
dmesg --level=err,warn --since "1 hour ago"

# OOM killer activity
dmesg | grep -i "oom\|out of memory\|killed process"

# Filesystem errors
dmesg | grep -i "error\|exception\|fault\|corrupt" | grep -iv "usb\|bluetooth"

# System uptime
uptime -s

# Last reboot reason
last reboot | head -5

# Hardware errors (if mcelog installed)
mcelog --client 2>/dev/null || echo "mcelog not installed"

# Check for disk errors in kernel log
dmesg | grep -iE "I/O error|hard reset|exception Emask|Buffer I/O"
```

**Alert conditions:**
- OOM killer fired → Critical — a process was killed for memory; identify which one
- Filesystem errors in dmesg → Critical — potential data corruption risk
- Hardware errors in mcelog → Critical
- Unexpected reboot detected (uptime < expected) → Warning — investigate last reboot cause
- Disk I/O errors in kernel log → Critical — hardware failure possible

---

## Scheduled Tasks Verification

**Commands:**
```bash
# Verify cron daemon is running
systemctl status cron

# List all cron jobs including /etc/cron.d/
cat /etc/cron.d/plex-ramdisk-backup
ls -la /etc/cron.d/

# Check syslog for cron execution
grep CRON /var/log/syslog | grep "$(date +%b\ %d)" | tail -20

# Check if backup ran today
grep "$(date +%Y-%m-%d) 04:" /var/log/plex-ramdisk-backup.log | grep "Backup started"
```

**Alert conditions:**
- `cron.service` not running → Critical
- No backup log entry by 05:00 on any day (scheduled 04:30) → Warning
- Cron file `/etc/cron.d/plex-ramdisk-backup` missing or modified → Warning

---

# Plex Media Server Health Monitoring

## Service State

**Commands:**
```bash
# Service status and uptime
systemctl status plexmediaserver

# Memory and CPU consumption
systemctl show plexmediaserver --property=MemoryCurrent,CPUUsageNSec

# Process list (Plex spawns several children)
ps aux | grep -i plex

# Plex version
/usr/lib/plexmediaserver/Plex\ Media\ Server --version 2>/dev/null || \
  strings /usr/lib/plexmediaserver/Plex\ Media\ Server | grep -m1 "^[0-9]\+\.[0-9]"

# Recent Plex journal entries
journalctl -u plexmediaserver --since "1 hour ago" --no-pager
```

**Alert conditions:**
- Service not `active (running)` → Critical
- Plex consuming >4GB RAM sustained → Warning
- Plex consuming >8GB RAM → Critical — memory leak possible
- Plex main process not present in `ps aux` → Critical
- Unexpected restart (check uptime vs last log entry) → Warning

---

## Plex Log Files

**Location:**
```bash
PLEX_LOGS="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs"
```

**Commands:**
```bash
# Main Plex server log — last 50 lines
sudo tail -50 "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log"

# Check for database errors specifically
sudo grep -i "sqlite\|database\|corrupt\|SQLITE_\|failed to open" \
  "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log" \
  | tail -20

# Check for crash dumps
ls -lh "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/Crash Reports/" 2>/dev/null

# Plex scanner log
sudo tail -20 "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/Plex Media Scanner.log" 2>/dev/null
```

**Alert conditions — Critical (database issues, watchdog territory):**
- Any of the following in Plex log → Critical:
  - `SQLITE_CORRUPT`
  - `SQLITE_IOERR`
  - `database disk image is malformed`
  - `no such table`
  - `unable to open database`
  - `Failed to open database`
  - `SQLite error`
- New crash report files appearing → Warning

**Alert conditions — Warning:**
- `SQLITE_BUSY` or `database is locked` repeated → Warning — Plex having trouble accessing DB
- Scanner errors persisting → Warning — library metadata may be stale
- Log file growing faster than 100MB/day → Warning

---

## Plex Database Files on Ramdisk

**Commands:**
```bash
# Current DB file sizes
ls -lh /mnt/ramdisk/PlexDB/Databases/

# WAL file sizes (should be small between transactions)
ls -lh /mnt/ramdisk/PlexDB/Databases/*.db-wal 2>/dev/null

# Total DB footprint
du -sh /mnt/ramdisk/PlexDB/Databases/

# Check for unexpected files
find /mnt/ramdisk/PlexDB/Databases -maxdepth 1 -type f | sort
```

**Alert conditions:**
- Any `.db-wal` file above 100MB → Warning — large uncommitted transaction
- Any `.db-wal` file above 500MB → Critical — SQLite WAL runaway; Plex may be stuck
- Total DB footprint above 10GB → Warning — approaching capacity concern
- `current.sha256` or `.tmp` files present on ramdisk → Warning — stray files from failed operation
- Unexpected `.db` files → Info — new Plex database created, will be included in next backup

---

## Plex DBRepair.log

**Commands:**
```bash
cat /mnt/ramdisk/PlexDB/Databases/DBRepair.log
```

**Alert conditions:**
- Any content in this file → Warning — Plex repaired a database; review what was fixed
- New entries since last check → Warning — database repair is happening repeatedly

---

# CIFS Share Monitoring

## Mount Status

**Commands:**
```bash
# All currently mounted filesystems
mount | grep -i cifs

# Verify expected mount points are present
findmnt -t cifs

# Check /etc/fstab for expected CIFS mounts
grep cifs /etc/fstab

# Compare fstab entries to active mounts
diff <(grep cifs /etc/fstab | awk '{print $2}' | sort) \
     <(mount | grep cifs | awk '{print $3}' | sort)
```

**Alert conditions:**
- Any CIFS mount in `/etc/fstab` not present in `mount` output → Critical — Plex media library inaccessible
- Mount present but not accessible (see below) → Critical

---

## Mount Accessibility

**Commands:**
```bash
# Test each CIFS mount point is readable (replace paths with actual mount points)
# Run for each expected mount:
# Replace with your actual CIFS mount points:
ls /mnt/<YOUR_SHARE_1>/ > /dev/null 2>&1 && echo "OK" || echo "FAILED"
ls /mnt/<YOUR_SHARE_2>/ > /dev/null 2>&1 && echo "OK" || echo "FAILED"

# Check for stale mount (mount exists but NAS is unreachable)
# Replace /mnt/<YOUR_SHARE> with your actual CIFS mount point:
timeout 5 ls /mnt/<YOUR_SHARE>/ > /dev/null 2>&1
echo "Exit: $?"  # 0=accessible, 1=failed, 124=timeout (stale mount)

# Disk usage on CIFS shares
df -h | grep -i cifs

# Test NAS host reachability
ping -c 3 <YOUR_NAS_IP>
```

**Alert conditions:**
- `ls` on mount point times out (>5s) → Critical — stale mount; NAS unreachable or network issue
- `ls` returns permission denied → Warning — credentials or share permissions changed
- `ls` returns no space left → Warning — NAS storage full
- NAS host not pingable → Critical — network or NAS hardware issue
- CIFS mount present in fstab but unmounted → Critical

---

## CIFS Mount Health Over Time

**Commands:**
```bash
# Check for CIFS errors in kernel log
dmesg | grep -i "cifs\|smb" | tail -20

# Check for mount errors in syslog
grep -i "cifs\|mount\|smb" /var/log/syslog | tail -20

# Check if mount is read-only (unexpected)
mount | grep cifs | grep -v "rw" | grep -v "ro,"   # find unexpected ro mounts
```

**Alert conditions:**
- CIFS errors in dmesg (reconnecting, session expired, etc.) → Warning — connection instability
- `Status code returned 0xc000006d` or similar auth errors in dmesg → Critical — credentials expired
- Mount has become read-only unexpectedly → Critical — filesystem error or NAS forced it

---

## CIFS Auto-Remount Check

If CIFS mounts use `_netdev` or `x-systemd.automount` in fstab, verify the mount units are active:

```bash
# Check systemd automount units
systemctl list-units --type=automount
systemctl list-units --type=mount | grep -i cifs
```

**Alert conditions:**
- Automount unit in failed state → Critical

---

# Ramdisk Database Process — End-to-End Health

## Overview Check

Run the built-in tools first:

```bash
# Operational summary (fastest)
sudo bash ~/plex-ramdisk-setup.sh --summary

# Deep validation (thorough)
sudo bash ~/plex-ramdisk-setup.sh --validate

# Step-by-step state
sudo bash ~/plex-ramdisk-setup.sh --status
```

---

## Boot Restore Verification

After every reboot, confirm the restore ran correctly before checking anything else:

```bash
# Was the restore successful this boot?
journalctl -u plex-ramdisk-sync -b --no-pager

# What did the restore log say?
grep -A 10 "Boot restore started" /var/log/plex-ramdisk-backup.log | tail -15

# How long did restore take?
grep "Duration:" /var/log/plex-ramdisk-backup.log | grep restore | tail -3

# Did Plex start after restore?
systemctl is-active plexmediaserver && echo "Plex running" || echo "Plex NOT running"
```

**Expected restore sequence:**
1. `plex-ramdisk-sync.service` starts → calls `plex-ramdisk-restore.sh`
2. Manifest verified against `current/`
3. Files rsync'd from `current/` → ramdisk (timing depends on DB size and disk speed)
4. Hash verification on ramdisk files
5. Service exits 0 → `active (exited)`
6. 15s delay (drop-in)
7. Plex starts

**Alert conditions:**
- Any step missing from log → Warning
- Restore duration above 120s → Warning — possible slow disk or large DB growth
- Restore fell back to snapshot → Warning — `current/` had hash failures; snapshot was used instead
- All sources failed → Critical — manual intervention required

---

## Backup Cycle Verification

**Commands:**
```bash
# Last backup summary
grep -A 12 "BACKUP SUMMARY" /var/log/plex-ramdisk-backup.log | tail -15

# Backup history — one line per run
grep "Backup started\|Backup complete\|Duration:" /var/log/plex-ramdisk-backup.log | tail -20

# Snapshot inventory
ls -lht /var/backups/plex-ramdisk/snapshots/

# Verify most recent snapshot manifest
LATEST=$(ls -d /var/backups/plex-ramdisk/snapshots/[0-9]* 2>/dev/null | sort -r | head -1)
echo "Latest snapshot: $LATEST"
wc -l < "${LATEST}/snapshot.sha256"
sha256sum -c "${LATEST}/snapshot.sha256" 2>&1 | grep -v ": OK" | head -10
```

**Alert conditions:**
- No backup in last 25 hours → Warning
- No backup in last 48 hours → Critical
- Snapshot count at 0 after 24 hours of operation → Warning
- Any snapshot failing `sha256sum -c` → Warning — that snapshot is unusable for recovery
- Backup `Result` not `SUCCESS` → Critical

---

## Ramdisk Integrity

**Commands:**
```bash
# Ramdisk mount and usage
df -h /mnt/ramdisk

# Confirm ramdisk is tmpfs (not a real disk mount)
findmnt /mnt/ramdisk

# Confirm Plex DB dir exists and is populated
find /mnt/ramdisk/PlexDB/Databases -maxdepth 1 -type f | wc -l

# Confirm symlink points to ramdisk
readlink -f "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases"

# Confirm no stray files
find /mnt/ramdisk/PlexDB/Databases -maxdepth 1 \( -name "*.sha256" -o -name "*.tmp" \) 2>/dev/null

# Confirm DB files are owned by plex
stat -c "%U:%G %n" /mnt/ramdisk/PlexDB/Databases/*.db 2>/dev/null
```

**Alert conditions:**
- Ramdisk not mounted → Critical
- DB dir empty (0 files) → Critical — restore did not run or failed
- Symlink points anywhere other than `/mnt/ramdisk/PlexDB/Databases` → Critical
- Stray `.sha256` or `.tmp` files on ramdisk → Warning
- DB files not owned by `plex:plex` → Warning

---

## Manifest Integrity

**Commands:**
```bash
# Entry count (should be > 0)
wc -l < /var/backups/plex-ramdisk/current/current.sha256

# Full verification
sudo sha256sum -c /var/backups/plex-ramdisk/current/current.sha256 2>&1 | grep -v ": OK"

# Age of manifest
echo "Manifest age: $(( ( $(date +%s) - $(stat -c %Y /var/backups/plex-ramdisk/current/current.sha256) ) / 3600 ))h"

# Stray sha256 files in current/
find /var/backups/plex-ramdisk/current -name "*.sha256" | sort
```

**Alert conditions:**
- Manifest has 0 entries → Warning — hash verification not running; run manual backup
- Manifest age above 25h → Warning — backup overdue
- Manifest age above 48h → Critical
- Any file fails `sha256sum -c` → Critical — backup is corrupted

---

## Installed Script Health

**Commands:**
```bash
# Check versions
grep "^# Version:" /usr/local/bin/plex-ramdisk-backup.sh
grep "^# Version:" /usr/local/bin/plex-ramdisk-restore.sh

# Check for known bad pattern (script-level local declarations)
grep -c "^    local expected_hash\|^    local rel_path\|^    local fpath\|^    local hash$" \
  /usr/local/bin/plex-ramdisk-restore.sh /usr/local/bin/plex-ramdisk-backup.sh

# Syntax check both scripts
bash -n /usr/local/bin/plex-ramdisk-backup.sh && echo "backup: OK"
bash -n /usr/local/bin/plex-ramdisk-restore.sh && echo "restore: OK"

# Executable bits
ls -la /usr/local/bin/plex-ramdisk-{backup,restore}.sh
```

**Alert conditions:**
- Either script version does not match what `~/plex-ramdisk-setup.sh` expects → Warning — run `--fix` to rewrite
- `grep -c` above returns any count above 0 → Critical — known bug present; run `--fix` immediately
- Syntax check fails → Critical — script will not run
- Executable bit missing → Critical — systemd cannot execute it

---

# Consolidated Monitoring Schedule

| Frequency | Checks |
|---|---|
| **Every 1 minute** | Ramdisk mounted, Plex service active, sync service state, error log new entries |
| **Every 5 minutes** | CPU load, memory available, CIFS mount accessibility (timeout test), WAL file sizes |
| **Every 15 minutes** | Disk usage all filesystems, network ping to NAS, Plex log for SQLite errors |
| **Every 1 hour** | Full `--summary` output, failed systemd units, kernel error log scan |
| **Daily at 05:00** | Confirm backup ran (scheduled 04:30), snapshot count, manifest age and entry count, `--validate` output |
| **On every reboot** | Full boot restore log review, Plex start confirmation, `--validate` |
| **On any alert** | Run `--validate`, check error log, run `--fix` if appropriate |

---

# Full Diagnostic Runbook

Run this complete block any time an issue is suspected:

```bash
echo "=== SYSTEM ===" && uptime && free -h && df -h
echo "=== FAILED UNITS ===" && systemctl --failed
echo "=== CIFS MOUNTS ===" && mount | grep cifs
echo "=== CIFS ACCESSIBLE ===" && \
  for mnt in $(mount | grep cifs | awk '{print $3}'); do \
    timeout 5 ls "$mnt" > /dev/null 2>&1 \
      && echo "  OK: $mnt" \
      || echo "  FAIL: $mnt"; \
  done
echo "=== RAMDISK ===" && df -h /mnt/ramdisk && ls -lh /mnt/ramdisk/PlexDB/Databases/
echo "=== SERVICES ===" && \
  systemctl is-active plex-ramdisk-sync plexmediaserver cron
echo "=== MANIFEST ===" && \
  wc -l < /var/backups/plex-ramdisk/current/current.sha256
echo "=== SNAPSHOTS ===" && ls /var/backups/plex-ramdisk/snapshots/ | wc -l
echo "=== RECENT ERRORS ===" && sudo tail -20 /var/log/plex-ramdisk-error.log
echo "=== PLEX DB ERRORS ===" && \
  sudo grep -i "SQLITE_CORRUPT\|malformed\|Failed to open database" \
    "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log" \
    2>/dev/null | tail -10
echo "=== KERNEL ERRORS ===" && dmesg --level=err,warn --since "1 hour ago" | tail -20
echo "=== SUMMARY ===" && sudo bash ~/plex-ramdisk-setup.sh --summary
```
