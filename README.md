# plex-ramdisk-setup

**Move your Plex Media Server database to a ramdisk for faster library performance — with full persistence, hash-verified backups, automatic recovery, and safe rollback.**

---

## Why

Plex performs constant random read/write operations against its SQLite databases during normal use — browsing, playback, metadata fetching, and background scanning all hit the database. On spinning disks or even busy SSDs this creates measurable latency. Moving the database to a tmpfs ramdisk eliminates that I/O bottleneck entirely.

The catch is that tmpfs is volatile — it disappears on reboot. This script handles everything required to make ramdisk hosting production-safe: it restores the database from disk on every boot, syncs it back to disk on every shutdown, takes verified snapshots daily, and can recover automatically from corruption.

---

## What It Does

- Moves the entire Plex `Databases/` directory to a tmpfs ramdisk via a **directory-level symlink** — Plex sees no difference, and any new database files Plex creates in the future are automatically included
- **Offloads dated Plex backup files** (`.db-YYYY-MM-DD`) from the ramdisk to disk automatically so they don't consume ramdisk space
- **Restores the database on every boot** from a verified on-disk backup before Plex starts
- **Syncs the database on every shutdown** to disk with graceful Plex stop, WAL checkpoint wait, and hash verification
- **Takes timestamped snapshots daily** (default 04:30, after Plex's nightly maintenance window) retaining the 10 most recent
- **Verifies SHA256 hashes** at every stage — copy to ramdisk, sync to backup, restore from backup — so silent corruption is detected immediately
- **Falls back to snapshots automatically** if the current backup fails hash verification on restore
- **Writes to the terminal during boot and shutdown** so you can see what's happening

---

## Requirements

- Ubuntu 20.04 or later (x86_64 or aarch64)
- systemd
- An existing tmpfs ramdisk already mounted (the script does **not** create the ramdisk — it uses one you already have)
- `rsync` (`sudo apt install rsync`)
- Plex Media Server installed via the official Linux package
- Sufficient RAM: your ramdisk must comfortably hold your Plex `Databases/` folder

> **Note on ramdisk size:** Check your current database size with `du -sh "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases/"` before proceeding. Ensure your ramdisk has at least 2× that size free.

---

## Quick Start

### 1. Mount a ramdisk

If you don't already have one, add a tmpfs to `/etc/fstab` and mount it:

```bash
sudo mkdir -p /mnt/ramdisk
# Add to /etc/fstab (adjust size to suit):
echo "tmpfs /mnt/ramdisk tmpfs rw,size=8G 0 0" | sudo tee -a /etc/fstab
sudo mount /mnt/ramdisk
```

### 2. Install rsync

```bash
sudo apt install rsync
```

### 3. Download the script

```bash
wget https://raw.githubusercontent.com/<YOUR_USERNAME>/plex-ramdisk-setup/main/plex-ramdisk-setup.sh
chmod +x plex-ramdisk-setup.sh
```

### 4. Dry run first

Always preview before making changes:

```bash
sudo bash plex-ramdisk-setup.sh --dry-run
```

Review the audit output. All rows should be `[OK]` or `[INFO]`. Resolve any `[ERR]` rows before proceeding.

### 5. Run it

```bash
sudo bash plex-ramdisk-setup.sh
```

Type `yes` at the confirmation prompt. The script will:

1. Create `/mnt/ramdisk/PlexDB/Databases/`
2. Stop Plex
3. Copy your entire `Databases/` directory to the ramdisk
4. Offload any dated Plex backup files to disk
5. Rename the original `Databases/` folder as a timestamped safety copy
6. Create a directory symlink at the original path pointing to the ramdisk
7. Seed `/var/backups/plex-ramdisk/current/` and write a SHA256 manifest
8. Install `plex-ramdisk-sync.service` (boot restore + shutdown sync)
9. Install a Plex systemd drop-in that makes Plex wait for the restore to complete
10. Install a daily cron job for snapshots
11. Start Plex

> The copy step can take a while for large databases — progress is logged to `/var/log/plex-ramdisk-setup.log`.

### 6. Verify

```bash
sudo bash plex-ramdisk-setup.sh --validate
```

All checks should pass. Then confirm Plex is running:

```bash
systemctl status plexmediaserver
sudo bash plex-ramdisk-setup.sh --summary
```

---

## File Structure After Setup

```
/mnt/ramdisk/PlexDB/Databases/              ← live databases (on ramdisk)
    com.plexapp.plugins.library.db
    com.plexapp.plugins.library.blobs.db
    com.plexapp.dlna.db
    ... (any future databases Plex creates)

/var/lib/plexmediaserver/.../Plug-in Support/
    Databases → /mnt/ramdisk/PlexDB/Databases   ← symlink (Plex sees this)
    BACKUP_Databases_<timestamp>/               ← original dir (safety copy)

/var/backups/plex-ramdisk/
    current/                                    ← latest verified backup
        current.sha256                          ← SHA256 manifest
    snapshots/
        2026-05-15_04-30-01/                    ← daily snapshot
            snapshot.sha256
        ... (10 max, oldest pruned)

/var/lib/plex-ramdisk/
    setup.state                                 ← step completion tracking
    db-backups/                                 ← dated Plex backups offloaded here

/usr/local/bin/
    plex-ramdisk-backup.sh                      ← shutdown sync + daily snapshot
    plex-ramdisk-restore.sh                     ← boot restore

/var/log/
    plex-ramdisk-setup.log                      ← installation activity
    plex-ramdisk-backup.log                     ← backup/restore runtime
    plex-ramdisk-error.log                      ← errors and warnings only
```

---

## Boot and Shutdown Sequence

**On boot:**
```
plex-ramdisk-sync.service starts
  → plex-ramdisk-restore.sh runs
      → verifies SHA256 manifest on current/
      → rsyncs current/ → ramdisk (falls back to snapshots if manifest fails)
      → verifies SHA256 hashes on restored files
      → exits 0
  → 15 second delay (Plex drop-in)
  → plexmediaserver.service starts
```

**On shutdown:**
```
systemd stops plexmediaserver.service
systemd stops plex-ramdisk-sync.service
  → plex-ramdisk-backup.sh --shutdown runs
      → stops Plex gracefully (force-kills after 60s timeout if needed)
      → waits for SQLite WAL checkpoint (30s timeout)
      → SHA256 hashes all ramdisk DB files
      → rsyncs ramdisk → current/
      → verifies hashes on destination
      → writes new manifest only on clean verify
```

**Daily at 04:30 (cron):**
```
plex-ramdisk-backup.sh runs
  → same as shutdown sync above
  → additionally: creates hard-linked snapshot with own manifest
  → prunes oldest snapshot if count exceeds 10
  → Plex is restarted after sync completes
```

---

## Command Reference

```bash
# Preview all steps without making changes
sudo bash plex-ramdisk-setup.sh --dry-run

# Show current state of each setup step
sudo bash plex-ramdisk-setup.sh --status

# Operational health summary (fastest day-to-day check)
sudo bash plex-ramdisk-setup.sh --summary

# Deep content validation of all installed components
sudo bash plex-ramdisk-setup.sh --validate

# Validate then auto-repair any issues found
sudo bash plex-ramdisk-setup.sh --fix

# Roll back all changes (removes symlink, restores original dir, uninstalls services)
sudo bash plex-ramdisk-setup.sh --rollback

# Wipe state file and start fresh (leaves installed files in place)
sudo bash plex-ramdisk-setup.sh --reset

# Force retry of the seed step if it previously failed
sudo bash plex-ramdisk-setup.sh --fix-seed

# Manual backup (stops Plex briefly, creates snapshot)
sudo /usr/local/bin/plex-ramdisk-backup.sh

# Manual restore from current/ backup
sudo /usr/local/bin/plex-ramdisk-restore.sh
```

---

## Configuration

Key constants at the top of `plex-ramdisk-setup.sh`:

| Variable | Default | Description |
|---|---|---|
| `RAMDISK_MOUNT` | `/mnt/ramdisk` | Where your tmpfs is mounted |
| `RAMDISK_PLEX_DIR` | `/mnt/ramdisk/PlexDB` | Plex subdirectory on ramdisk |
| `BACKUP_ROOT` | `/var/backups/plex-ramdisk` | Where backups are stored |
| `SNAPSHOT_KEEP` | `10` | Number of daily snapshots to retain |
| `SHUTDOWN_GRACEFUL_TIMEOUT` | `60` | Seconds to wait for Plex to stop before force-kill |
| `SHUTDOWN_WAL_TIMEOUT` | `30` | Seconds to wait for SQLite WAL checkpoint |
| `PLEX_BOOT_DELAY` | `15` | Seconds Plex waits after restore completes |
| `MAX_LOG_LINES` | `5000` | Log rotation threshold |

Edit these at the top of the script before running. Re-run `--fix` after changes to update installed scripts.

---

## How Rollback Works

If the script fails at any point during setup, it automatically rolls back everything it changed in that run:

- Removes any per-file symlinks created
- Renames `BACKUP_Databases_<timestamp>` back to `Databases`
- Removes files copied to the ramdisk
- Removes installed scripts, systemd unit, drop-in, and cron job
- Restarts Plex if it was running before setup started

You can also trigger rollback manually:

```bash
sudo bash plex-ramdisk-setup.sh --rollback
```

---

## Troubleshooting

### Plex won't start after setup

Check the restore service:

```bash
sudo systemctl status plex-ramdisk-sync.service
journalctl -u plex-ramdisk-sync -b --no-pager
```

If the restore service failed, attempt auto-repair:

```bash
sudo bash plex-ramdisk-setup.sh --fix
sudo systemctl restart plex-ramdisk-sync.service
sudo systemctl start plexmediaserver
```

### Validation shows issues

```bash
sudo bash plex-ramdisk-setup.sh --validate
sudo bash plex-ramdisk-setup.sh --fix
```

`--fix` will identify and repair most issues automatically — wrong cron schedule, outdated scripts, missing directives in the systemd unit, stray files in `current/`, incorrect ownership.

### Backup manifest is empty

```bash
# Remove stray files and run a fresh backup
sudo find /mnt/ramdisk/PlexDB/Databases -name "*.sha256" -delete
sudo find /var/backups/plex-ramdisk/current -name "*.sha256" -delete
sudo /usr/local/bin/plex-ramdisk-backup.sh
wc -l < /var/backups/plex-ramdisk/current/current.sha256
```

### Manual restore from a specific snapshot

```bash
# List available snapshots
ls -lht /var/backups/plex-ramdisk/snapshots/

# Restore from a specific snapshot
sudo rsync -av --exclude="*.sha256" --exclude="*.tmp" \
  /var/backups/plex-ramdisk/snapshots/YYYY-MM-DD_HH-MM-SS/ \
  /mnt/ramdisk/PlexDB/Databases/
sudo chown -R plex:plex /mnt/ramdisk/PlexDB/Databases/
sudo systemctl start plexmediaserver
```

### WAL files not empty at backup time

The `com.plexapp.dlna.db-wal` file in particular may not checkpoint cleanly — this is a known Plex behavior with the DLNA database and is not harmful. SQLite recovers the WAL automatically on next open. Only escalate if the main library WAL files (`com.plexapp.plugins.library.db-wal`, `com.plexapp.plugins.library.blobs.db-wal`) are also consistently non-empty.

---

## Log Files

| File | Contents |
|---|---|
| `/var/log/plex-ramdisk-setup.log` | Everything the setup script does — audit results, commands run, timing |
| `/var/log/plex-ramdisk-backup.log` | All backup and restore activity — rsync output, hash results, summaries |
| `/var/log/plex-ramdisk-error.log` | Errors and warnings only — the first place to look when something goes wrong |

Quick check:

```bash
# Operational summary
sudo bash plex-ramdisk-setup.sh --summary

# Recent errors
sudo tail -30 /var/log/plex-ramdisk-error.log

# Last backup result
grep -A 12 "BACKUP SUMMARY" /var/log/plex-ramdisk-backup.log | tail -15

# Last restore result
grep -A 10 "RESTORE SUMMARY" /var/log/plex-ramdisk-backup.log | tail -12
```

---

## Known Benign Conditions

These will appear in logs or `--validate` output and are **not** errors:

- `com.plexapp.dlna.db-wal` not empty at backup — DLNA WAL does not checkpoint cleanly; SQLite recovers on next open
- `libusb_init failed` in Plex journal — Plex Tuner Service looking for USB hardware; unrelated to this setup
- Ramdisk vs manifest hash mismatch during `--validate` when Plex is running — Plex is actively writing; expected
- `plex-ramdisk-sync.service` state `active (exited)` — correct for a oneshot service that succeeded
- Databases symlink owned by `root:root` — Linux does not enforce symlink ownership; the ramdisk target directory is `plex:plex` which is what matters

---

## Planned Features

- **Database crash watchdog** — monitors Plex logs for SQLite error patterns and auto-restores from snapshots on corruption (requires `sqlite3`)
- **Dated backup pruning** — configurable retention policy for files in `/var/lib/plex-ramdisk/db-backups/` (currently kept indefinitely)

---

## Script Versions

The installer generates two standalone scripts. Each has its own version and changelog:

| Script | Current Version | Purpose |
|---|---|---|
| `plex-ramdisk-setup.sh` | 4.5.1 | Installer, validator, repair tool |
| `plex-ramdisk-backup.sh` | 3.4.0 | Shutdown sync + daily snapshot |
| `plex-ramdisk-restore.sh` | 3.3.0 | Boot restore |

Check installed versions:

```bash
grep "^# Version:" /usr/local/bin/plex-ramdisk-backup.sh
grep "^# Version:" /usr/local/bin/plex-ramdisk-restore.sh
```

Update installed scripts after downloading a new version of the setup script:

```bash
sudo bash plex-ramdisk-setup.sh --fix
```

---

## License

MIT — do whatever you want with it. If you improve it, a PR is welcome.
