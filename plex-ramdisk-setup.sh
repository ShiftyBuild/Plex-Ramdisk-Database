#!/usr/bin/env bash
# =============================================================================
# plex-ramdisk-setup.sh
# Version: 4.5.0
# Description: Moves the entire Plex Databases directory to an existing tmpfs
#              ramdisk via a directory-level symlink. Dated Plex backup files
#              are automatically offloaded from the ramdisk to disk. Manages
#              persistence via a systemd unit (boot restore + shutdown sync)
#              and a cron job that creates timestamped snapshots every 24 hours,
#              retaining the 10 most recent.
#
# Directory structure:
#   /mnt/ramdisk/PlexDB/Databases/       ← entire Databases dir lives here
#   /var/lib/.../Plug-in Support/
#       Databases/                       ← symlink → ramdisk
#       BACKUP_Databases_<timestamp>/    ← original dir (safety copy)
#   /var/lib/plex-ramdisk/db-backups/   ← dated Plex backups offloaded here
#
# Backup structure:
#   /var/backups/plex-ramdisk/
#   ├── current/           ← latest verified backup (active DBs only)
#   │   └── current.sha256
#   └── snapshots/
#       ├── 2026-05-11_03-00-00/
#       │   └── snapshot.sha256
#       └── ...            ← 10 maximum
#
# Logs:
#   /var/log/plex-ramdisk-setup.log     ← setup script activity
#   /var/log/plex-ramdisk-backup.log    ← backup/restore runtime activity
#   /var/log/plex-ramdisk-error.log     ← errors and warnings only
#
# Usage:
#   sudo bash plex-ramdisk-setup.sh [OPTIONS]
#
# Options:
#   --dry-run     Validate and preview all steps without making changes
#   --rollback    Roll back all changes made by the current/last run
#   --reset       Wipe state file and start fresh
#   --status      Show current setup state and exit
#   --summary     Show operational health summary and exit
#   --fix-seed    Reset failed seed state so setup retries it on next run
#   --validate    Deep content check of all installed components
#   --fix         Run --validate then repair any issues found
#   --help        Show this help message
#
# Changelog:
#   4.5.1 - Changed cron schedule from 05:00 to 04:30 to run after
#            Plex's nightly cleanup/maintenance window; WAL warning
#            messages updated to note post-cleanup-window context;
#            backup script bumped to v3.4.0
#   4.5.0 - Fixed post-restore hash verification loop in restore script
#            heredoc: variables (line, rel_path, fpath, expected_hash,
#            actual_hash, RESTORE_MANIFEST) lacked backslash escaping —
#            outer shell expanded them at heredoc-generation time, baking
#            empty strings into the generated script so the verification
#            loop silently passed without checking any file; restore script
#            bumped to v3.3.0; fixed two residual script-scope "local"
#            declarations in restore heredoc (waited, snap_mf) that emitted
#            boot-time warnings; replaced eval-based run() with array-based
#            run_cmd() — eliminates word-splitting/injection risk on paths
#            containing spaces or special characters; fixed unescaped
#            $(echo ...) command substitution in backup script rsync filter
#            (expanded at setup time rather than backup time — happened to
#            produce correct string but was fragile); backup script bumped
#            to v3.3.0; rollback() now removes drop-in and reloads systemd
#            before restarting Plex so Plex has no dangling unit dependency
#            during rollback; fixed header comment version (said 4.0.0);
#            SETUP_VERSION bumped to 4.5.0
#   4.4.2 - Fixed script-level "local" declarations in backup script
#            heredoc; backup rsync excludes sha256/tmp; cleanup updated;
#            backup script bumped to v3.2.0, restore script to v3.2.0
#            heredoc (same bug as restore script — local rel, local hash,
#            local dest_file, local dest_hash at script scope caused hash
#            verification to silently fail); backup rsync now excludes
#            *.sha256 and *.tmp files from current/; belt-and-suspenders
#            cleanup also removes stray sha256/tmp from current/
#   4.4.1 - Increased SHUTDOWN_WAL_TIMEOUT from 15s to 30s;
#            restore and backup scripts remove stray sha256/tmp files
#            from ramdisk before/after operations so manifest stays
#            consistent; summary and validate now warn on empty manifest
#            (0 entries) rather than showing OK
#   4.4.0 - verify_setup() now actively tests installed components:
#            bash -n syntax check on both installed scripts; explicit
#            check for script-level "local" declarations in restore
#            script (the bug that broke boot); unit file directive
#            verification; live plex-ramdisk-sync.service start test;
#            Plex drop-in directive check; manifest hash verification;
#            Plex service start attempt with result logging
#   4.3.6 - Critical fix: restore script post-verify used "local" keyword
#            in while loop at script level (not inside a function) — bash
#            silently ignores local at script scope causing rel_path to be
#            empty, making every file appear missing; Plex blocked from
#            starting; fixed by removing local from script-level while loop
#   4.3.5 - Fixed current.sha256 leaking onto ramdisk: seed and restore
#            rsyncs now exclude *.sha256, *.tmp files; migration step
#            removes stray manifest/tmp files from ramdisk after offload
#   4.3.4 - Replaced symlink ownership check with target directory
#            ownership check — chown -h does not work on tmpfs;
#            Linux ignores symlink ownership for access control;
#            validate now checks plex:plex on RAMDISK_DB_DIR instead
#   4.3.3 - Fixed symlink created as root:root — now set to plex:plex
#            with chown -h; added symlink ownership check to --validate;
#            added fix_symlink_owner repair action to --fix
#   4.3.2 - Fixed write_manifest to exclude .tmp files (false positive
#            current/ hash error); fixed script constants validation to
#            extract values rather than grep literal strings; fix mode
#            now clears state before rewriting scripts/unit so they
#            actually get rewritten instead of skipped
#   4.3.1 - Changed cron backup schedule from 03:00 to 05:00
#   4.3.0 - Added --validate: deep content check (symlink target, DB
#            readability, SQLite integrity if sqlite3 installed, sha256sum
#            on current/ and all snapshots, script versions and constants,
#            systemd unit directives, drop-in directives, cron content,
#            logrotate config, dated files in current/);
#            added --fix: runs validate then repairs identified issues
#            with confirmation prompt before making any changes
#   4.2.8 - migrate_database_dir() now checks seed state independently
#            so a failed seed step can be retried without re-migrating;
#            added --fix-seed flag to reset seed state for retry
#   4.2.7 - Fixed snap_count arithmetic error: wc -l output includes
#            trailing newline even with || echo 0 fallback; now stripped
#            explicitly with tr -d before arithmetic comparison
#   4.2.6 - Fixed --summary: doubled _sum_row function name on scripts
#            rows (from ternary conversion); snap_count and stat -c %%Y
#            arithmetic errors from trailing newlines in command
#            substitutions — stripped with tr -d
#   4.2.5 - Fixed manifest verification: rsync all then strip dated files
#            so manifest and current/ always agree; rewrote verify_setup()
#            with proper if/else blocks — eliminates double OK/WARN output
#   4.2.4 - Fixed stray trailing backslash on OS version audit row
#            causing if/else to misbehave; audit_row trailing backslash
#            scan added to catch similar issues
#   4.2.3 - Fixed remaining audit/sum_row ternary patterns and broken
#            DB backup dir if/else block; zero bare && || audit patterns remain
#   4.2.2 - Replaced all condition && _audit_row || _audit_row ternary
#            patterns with proper if/else blocks — fixes double-printing
#            of both OK and ERROR for every check; trap_rollback now
#            only fires rollback if setup steps actually executed
#   4.2.1 - Fixed silent exit: removed set -e (errexit) which caused
#            false conditions in audit && || chains to trigger immediate
#            exit; added || true guards to arithmetic increments;
#            errors now handled explicitly via return codes
#   4.2.0 - Added --summary flag: concise operational health check with
#            per-component status, backup age, snapshot count, error log
#            presence, and overall health result; added pre-confirmation
#            step plan table showing exactly what will run, skip, or
#            re-run before the user confirms
#   4.1.0 - Added ttylog() to backup and restore scripts: user-facing
#            progress messages written to /dev/console during boot/shutdown
#            so the user can see what is happening on the terminal;
#            systemd unit updated with StandardOutput=journal+console
#   4.0.0 - Switched from per-file symlinks to directory-level symlink;
#            entire Databases dir moved to ramdisk — all files including
#            future ones automatically mapped; dated Plex backup files
#            offloaded from ramdisk to /var/lib/plex-ramdisk/db-backups/
#            on migration, backup, and restore; ACTIVE_FILES array removed;
#            dated backup pruning stubbed as future feature placeholder;
#            rollback updated for directory symlink approach
#   3.3.0 - Hardened logging: dedicated error log; disk state snapshots;
#            file size logging; manifest diff; run summary blocks;
#            logrotate config; configurable log rotation
#   3.2.0 - Added Ubuntu compatibility check to audit
#   3.1.0 - Added watchdog placeholder
#   3.0.0 - Step-state tracking; rollback; hash verification; WAL handling;
#            restore fallback to snapshots; systemd drop-in
#   2.x.x - Per-file symlinks; existing ramdisk; boot/shutdown sync;
#            24-hour snapshots with rotation
#   1.3.0 - Moved backup destination to /var/backups/plex-ramdisk (FHS)
#   1.2.0 - Backup script scoped to Plex subdir; fixed rsync exit code bug
#   1.1.0 - Added comprehensive pre-execution inventory audit
#   1.0.0 - Initial release
# =============================================================================

# Note: -e (errexit) intentionally omitted — this script handles errors
# explicitly via return codes and the trap_rollback mechanism.
set -uo pipefail

# ── Versions ──────────────────────────────────────────────────────────────────
SETUP_VERSION="4.5.1"
BACKUP_SCRIPT_VERSION="3.4.0"
RESTORE_SCRIPT_VERSION="3.3.0"

# ── Constants ─────────────────────────────────────────────────────────────────
RAMDISK_MOUNT="/mnt/ramdisk"
RAMDISK_PLEX_DIR="${RAMDISK_MOUNT}/PlexDB"
RAMDISK_DB_DIR="${RAMDISK_PLEX_DIR}/Databases"

PLEX_BASE="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
PLEX_PLUGIN_SUPPORT="${PLEX_BASE}/Plug-in Support"
PLEX_DB_SYMLINK="${PLEX_PLUGIN_SUPPORT}/Databases"
PLEX_USER="plex"
PLEX_SERVICE="plexmediaserver"

BACKUP_ROOT="/var/backups/plex-ramdisk"
BACKUP_CURRENT="${BACKUP_ROOT}/current"
BACKUP_SNAPSHOTS="${BACKUP_ROOT}/snapshots"
CURRENT_MANIFEST="${BACKUP_CURRENT}/current.sha256"
SNAPSHOT_KEEP=10

STATE_DIR="/var/lib/plex-ramdisk"
STATE_FILE="${STATE_DIR}/setup.state"
DB_BACKUP_DIR="${STATE_DIR}/db-backups"

# Dated backup pattern — files matching this are offloaded from ramdisk to disk
# Matches: *.db-YYYY-MM-DD, *.db-YYYY-MM-DD-tmp, *.db-YYYY-MM-DD-anything
DATED_PATTERN='.*\.db-[0-9]{4}-[0-9]{2}-[0-9]{2}.*'

SYSTEMD_UNIT_FILE="/lib/systemd/system/plex-ramdisk-sync.service"
SYSTEMD_DROPIN_DIR="/etc/systemd/system/plexmediaserver.service.d"
SYSTEMD_DROPIN_FILE="${SYSTEMD_DROPIN_DIR}/ramdisk-wait.conf"
CRON_FILE="/etc/cron.d/plex-ramdisk-backup"
BACKUP_SCRIPT="/usr/local/bin/plex-ramdisk-backup.sh"
RESTORE_SCRIPT="/usr/local/bin/plex-ramdisk-restore.sh"
SETUP_LOG="/var/log/plex-ramdisk-setup.log"
RUNTIME_LOG="/var/log/plex-ramdisk-backup.log"
ERROR_LOG="/var/log/plex-ramdisk-error.log"
SCRIPT_NAME="$(basename "$0")"

# Timeouts (seconds)
SHUTDOWN_GRACEFUL_TIMEOUT=60
SHUTDOWN_WAL_TIMEOUT=30
RESTORE_STOP_TIMEOUT=30
PLEX_BOOT_DELAY=15

MAX_LOG_LINES=5000

DRY_RUN=false
MODE="setup"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
_ts()      { date '+%Y-%m-%d %H:%M:%S'; }
START_TIME=$(date +%s)

_write_log() { local file="$1"; shift; echo "$*" >> "${file}" 2>/dev/null || true; }

_slog() {
    local level="$1"; shift
    local line="$(_ts) [setup v${SETUP_VERSION}] [${level}] $*"
    if $DRY_RUN; then return; fi
    _write_log "${SETUP_LOG}" "${line}"
    [[ "${level}" == "ERROR" || "${level}" == "WARN" ]] && \
        _write_log "${ERROR_LOG}" "${line}"
}

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*";  _slog "INFO"  "$*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*";  _slog "OK"    "$*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; _slog "WARN"  "$*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; _slog "ERROR" "$*"; }
log_step()  { echo -e "\n${BOLD}── $* ${NC}";    _slog "STEP"  "────── $*"; }
log_dry()   { echo -e "${YELLOW}[DRY-RUN]${NC} $*"; }

die() { log_error "$*"; exit 1; }

run_cmd() {
    if $DRY_RUN; then
        log_dry "$(printf '%q ' "$@")"
    else
        local t0; t0=$(date +%s%3N)
        _slog "RUN" "$(printf '%q ' "$@")"
        "$@"
        local rc=$? t1; t1=$(date +%s%3N)
        _slog "RUN" "  exit=${rc}  duration=$(( t1 - t0 ))ms"
        return $rc
    fi
}

log_disk_state() {
    if $DRY_RUN; then return; fi
    local label="${1:-disk state}"
    local rd_used rd_avail rd_pct bk_used bk_avail
    if mountpoint -q "${RAMDISK_MOUNT}" 2>/dev/null; then
        read -r rd_used rd_avail rd_pct <<< \
            "$(df -k "${RAMDISK_MOUNT}" | awk 'NR==2{print $3, $4, $5}')"
        _slog "INFO" "[${label}] ramdisk: used=$(( rd_used/1024 ))MB  avail=$(( rd_avail/1024 ))MB  ${rd_pct} full"
    fi
    if [[ -d "${BACKUP_ROOT}" ]]; then
        read -r bk_used bk_avail <<< \
            "$(df -k "${BACKUP_ROOT}" | awk 'NR==2{print $3, $4}')"
        _slog "INFO" "[${label}] backup disk: used=$(( bk_used/1024 ))MB  avail=$(( bk_avail/1024 ))MB"
    fi
}

log_db_sizes() {
    if $DRY_RUN; then return; fi
    local dir="${1}" label="${2:-db sizes}"
    [[ -d "${dir}" ]] || return
    _slog "INFO" "[${label}] contents of ${dir}:"
    while IFS= read -r -d '' f; do
        local sz; sz=$(du -sh "${f}" 2>/dev/null | awk '{print $1}')
        _slog "INFO" "  ${sz}  $(basename "${f}")"
    done < <(find "${dir}" -maxdepth 1 -type f -print0 | sort -z)
}

_rotate_log() {
    local file="$1"
    [[ -f "${file}" ]] || return
    local lines; lines=$(wc -l < "${file}" | tr -d "[:space:]")
    if (( lines > MAX_LOG_LINES )); then
        local kept=$(( MAX_LOG_LINES - 1 ))
        tail -n "${kept}" "${file}" > "${file}.tmp"
        echo "$(_ts) [setup v${SETUP_VERSION}] [INFO] --- log rotated (${lines} → ${kept} lines) ---" \
            >> "${file}.tmp"
        mv "${file}.tmp" "${file}"
    fi
}

_write_logrotate_config() {
    local lr_file="/etc/logrotate.d/plex-ramdisk"
    cat > "${lr_file}" << LR_EOF
# Plex ramdisk log rotation — generated by plex-ramdisk-setup.sh v${SETUP_VERSION}
${SETUP_LOG}
${RUNTIME_LOG}
${ERROR_LOG} {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
LR_EOF
    chmod 644 "${lr_file}"
    _slog "OK" "logrotate config written: ${lr_file}"
}

init_setup_log() {
    if $DRY_RUN; then return; fi
    mkdir -p "$(dirname "${SETUP_LOG}")"
    touch "${SETUP_LOG}" "${ERROR_LOG}" 2>/dev/null || true
    START_TIME=$(date +%s)
    {
        echo "================================================================"
        echo "$(_ts) plex-ramdisk-setup.sh v${SETUP_VERSION} started"
        echo "$(_ts) Mode: ${MODE}  DryRun: ${DRY_RUN}"
        echo "$(_ts) User: $(whoami)  Host: $(hostname)  PID: $$"
        echo "$(_ts) Setup log:   ${SETUP_LOG}"
        echo "$(_ts) Runtime log: ${RUNTIME_LOG}"
        echo "$(_ts) Error log:   ${ERROR_LOG}"
        echo "$(_ts) OS:   $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
        echo "$(_ts) Arch: $(uname -m)  Kernel: $(uname -r)"
        echo "$(_ts) Bash: ${BASH_VERSION}"
        echo "$(_ts) RAM:  $(free -h | awk '/^Mem/{print $2}') total  $(free -h | awk '/^Mem/{print $7}') available"
        echo "================================================================"
    } >> "${SETUP_LOG}"
    log_disk_state "setup start"
    _rotate_log "${SETUP_LOG}"
    _rotate_log "${ERROR_LOG}"
}

finalize_setup_log() {
    if $DRY_RUN; then return; fi
    local duration=$(( $(date +%s) - START_TIME ))
    {
        echo "================================================================"
        echo "$(_ts) plex-ramdisk-setup.sh v${SETUP_VERSION} finished"
        echo "$(_ts) Total duration: ${duration}s"
        echo "================================================================"
    } >> "${SETUP_LOG}"
    log_disk_state "setup end"
    _rotate_log "${SETUP_LOG}"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true;      shift ;;
        --rollback) MODE="rollback";   shift ;;
        --reset)    MODE="reset";      shift ;;
        --status)   MODE="status";     shift ;;
        --summary)  MODE="summary";    shift ;;
        --fix-seed) MODE="fix-seed";   shift ;;
        --validate) MODE="validate";   shift ;;
        --fix)      MODE="fix";        shift ;;
        --help|-h)  usage ;;
        *) die "Unknown argument: $1. Use --help for usage." ;;
    esac
done

# ── State management ──────────────────────────────────────────────────────────
state_get() {
    local key="$1"
    [[ -f "${STATE_FILE}" ]] || { echo "absent"; return; }
    grep -m1 "^${key}=" "${STATE_FILE}" 2>/dev/null | cut -d= -f2- || echo "absent"
}

state_set() {
    local key="$1" val="$2"
    if $DRY_RUN; then log_dry "state_set ${key}=${val}"; return; fi
    mkdir -p "${STATE_DIR}"
    local tmp="${STATE_FILE}.tmp"
    grep -v "^${key}=" "${STATE_FILE}" 2>/dev/null > "${tmp}" || true
    echo "${key}=${val}" >> "${tmp}"
    mv "${tmp}" "${STATE_FILE}"
    _slog "STATE" "${key}=${val}"
}

state_clear() {
    if $DRY_RUN; then log_dry "state_clear"; return; fi
    rm -f "${STATE_FILE}"
    _slog "STATE" "State file cleared"
}

# ── Status display ────────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Plex Ramdisk — Setup Status  (v${SETUP_VERSION})${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ ! -f "${STATE_FILE}" ]]; then
        echo -e "\n  ${YELLOW}No state file found — setup has not been run.${NC}\n"
        return
    fi

    echo -e "\n  ${BOLD}Step States:${NC}"
    local steps=(
        "STEP_1_RAMDISK_DIR"
        "STEP_2_BACKUP_DIRS"
        "STEP_3_MIGRATE_DIR"
        "STEP_3_OFFLOAD_DATED"
        "STEP_3_SEED_CURRENT"
        "STEP_4_RESTORE_SCRIPT"
        "STEP_5_BACKUP_SCRIPT"
        "STEP_6_SYSTEMD_UNIT"
        "STEP_6_SYSTEMD_DROPIN"
        "STEP_7_CRON"
        "STEP_8_WATCHDOG"
        "STEP_9_DB_BACKUP_PRUNING"
    )
    for step in "${steps[@]}"; do
        local val; val=$(state_get "${step}")
        case "${val}" in
            complete) echo -e "    ${GREEN}[complete]${NC}  ${step}" ;;
            failed)   echo -e "    ${RED}[failed]${NC}    ${step}" ;;
            pending)  echo -e "    ${BLUE}[pending]${NC}   ${step}  ← future feature" ;;
            absent)   echo -e "    ${YELLOW}[not run]${NC}   ${step}" ;;
            *)        echo -e "    ${BLUE}[${val}]${NC}  ${step}" ;;
        esac
    done

    echo -e "\n  ${BOLD}Runtime State:${NC}"
    local snap_count=0
    [[ -d "${BACKUP_SNAPSHOTS}" ]] && \
        snap_count=$(ls -d "${BACKUP_SNAPSHOTS}"/[0-9]* 2>/dev/null | wc -l | tr -d "[:space:]" || echo 0)
    local dated_count=0
    [[ -d "${DB_BACKUP_DIR}" ]] && \
        dated_count=$(find "${DB_BACKUP_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0)

    echo -e "    Ramdisk mounted:    $(mountpoint -q "${RAMDISK_MOUNT}" 2>/dev/null \
        && echo -e "${GREEN}yes${NC}" || echo -e "${RED}no${NC}")"
    echo -e "    Ramdisk DB dir:     $([[ -d "${RAMDISK_DB_DIR}" ]] \
        && echo -e "${GREEN}exists${NC}" || echo -e "${RED}missing${NC}")"
    echo -e "    Databases symlink:  $([[ -L "${PLEX_DB_SYMLINK}" ]] \
        && echo -e "${GREEN}$(readlink "${PLEX_DB_SYMLINK}")${NC}" \
        || echo -e "${YELLOW}not a symlink${NC}")"
    echo -e "    Backup current/:    $([[ -d "${BACKUP_CURRENT}" ]] \
        && echo -e "${GREEN}exists${NC}" || echo -e "${RED}missing${NC}")"
    echo -e "    Hash manifest:      $([[ -f "${CURRENT_MANIFEST}" ]] \
        && echo -e "${GREEN}exists${NC}" || echo -e "${RED}missing${NC}")"
    echo -e "    Snapshots:          ${snap_count}/${SNAPSHOT_KEEP}"
    echo -e "    Dated DB backups:   ${dated_count} file(s) in ${DB_BACKUP_DIR}"
    local _plex_state _restore_state
    _plex_state=$(systemctl is-active "${PLEX_SERVICE}" 2>/dev/null || true)
    [[ -z "${_plex_state}" ]] && _plex_state="inactive"
    _restore_state=$(systemctl is-enabled plex-ramdisk-sync.service 2>/dev/null || true)
    [[ -z "${_restore_state}" ]] && _restore_state="not installed"
    echo -e "    Plex service:       ${_plex_state}"
    echo -e "    Restore service:    ${_restore_state}"
    echo -e "    Plex drop-in:       $([[ -f "${SYSTEMD_DROPIN_FILE}" ]] \
        && echo -e "${GREEN}installed${NC}" || echo -e "${YELLOW}not installed${NC}")"
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}


# ── Summary view ──────────────────────────────────────────────────────────────
# --summary: concise operational health check of all installed components.
# Distinct from --status which shows setup step state.
# Use this day-to-day to confirm everything is in order.
show_summary() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Plex Ramdisk — Operational Summary  (v${SETUP_VERSION})${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local ok=0 warn=0 fail=0

    _sum_row() {
        local label="$1" state="$2" detail="$3"
        case "${state}" in
            OK)   echo -e "  ${GREEN}[  OK  ]${NC}  ${label}  ${detail}"; (( ok++ )) || true ;;
            WARN) echo -e "  ${YELLOW}[ WARN ]${NC}  ${label}  ${detail}"; (( warn++ )) || true ;;
            FAIL) echo -e "  ${RED}[FAILED]${NC}  ${label}  ${detail}"; (( fail++ )) || true ;;
            INFO) echo -e "  ${BLUE}[ INFO ]${NC}  ${label}  ${detail}" ;;
        esac
    }

    # ── Ramdisk ───────────────────────────────────────────────────────────────
    echo -e "
  ${BOLD}Ramdisk${NC}"
    if mountpoint -q "${RAMDISK_MOUNT}" 2>/dev/null; then
        local rd_used rd_avail rd_pct
        read -r rd_used rd_avail rd_pct <<<             "$(df -k "${RAMDISK_MOUNT}" | awk 'NR==2{print $3,$4,$5}')"
        _sum_row "Ramdisk mounted" "OK"             "${RAMDISK_MOUNT}  used=$(( rd_used/1024 ))MB  avail=$(( rd_avail/1024 ))MB  ${rd_pct} full"
    else
        _sum_row "Ramdisk mounted" "FAIL" "${RAMDISK_MOUNT} is NOT mounted"
    fi

    if [[ -d "${RAMDISK_DB_DIR}" ]]; then
        local rd_db_size; rd_db_size=$(du -sh "${RAMDISK_DB_DIR}" 2>/dev/null | awk '{print $1}')
        local rd_db_count; rd_db_count=$(find "${RAMDISK_DB_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l)
        _sum_row "Ramdisk DB dir" "OK"             "${RAMDISK_DB_DIR}  ${rd_db_size}  ${rd_db_count} file(s)"
    else
        _sum_row "Ramdisk DB dir" "FAIL" "Missing: ${RAMDISK_DB_DIR}"
    fi

    if [[ -L "${PLEX_DB_SYMLINK}" ]]; then
        local link_target; link_target=$(readlink -f "${PLEX_DB_SYMLINK}")
        if [[ "${link_target}" == "${RAMDISK_DB_DIR}" ]]; then
            _sum_row "Databases symlink" "OK" "→ ${RAMDISK_DB_DIR}"
        else
            _sum_row "Databases symlink" "WARN" "→ ${link_target}  (expected ${RAMDISK_DB_DIR})"
        fi
    else
        _sum_row "Databases symlink" "FAIL" "Not a symlink: ${PLEX_DB_SYMLINK}"
    fi

    # ── Plex service ──────────────────────────────────────────────────────────
    echo -e "
  ${BOLD}Plex Service${NC}"
    local plex_state
    plex_state=$(systemctl is-active "${PLEX_SERVICE}" 2>/dev/null || true)
    [[ -z "${plex_state}" ]] && plex_state="inactive"
    case "${plex_state}" in
        active)
            local plex_uptime
            plex_uptime=$(systemctl show "${PLEX_SERVICE}"                 --property=ActiveEnterTimestamp 2>/dev/null                 | cut -d= -f2 | xargs -I{} date -d "{}" "+since %Y-%m-%d %H:%M" 2>/dev/null || echo "")
            _sum_row "plexmediaserver" "OK" "${plex_state}  ${plex_uptime}"
            ;;
        activating) _sum_row "plexmediaserver" "WARN" "still starting up" ;;
        *)          _sum_row "plexmediaserver" "WARN" "${plex_state}" ;;
    esac

    # ── Systemd services ──────────────────────────────────────────────────────
    echo -e "
  ${BOLD}Systemd${NC}"
    local sync_enabled sync_active
    sync_enabled=$(systemctl is-enabled plex-ramdisk-sync.service 2>/dev/null || echo "not-found")
    sync_active=$(systemctl is-active plex-ramdisk-sync.service 2>/dev/null || true)
    [[ -z "${sync_active}" ]] && sync_active="inactive"
    if [[ "${sync_enabled}" == "enabled" ]]; then
        _sum_row "plex-ramdisk-sync" "OK" "enabled  active=${sync_active}"
    else
        _sum_row "plex-ramdisk-sync" "FAIL" "NOT enabled (${sync_enabled})"
    fi

    if [[ -f "${SYSTEMD_DROPIN_FILE}" ]]; then
        _sum_row _sum_row "Plex drop-in" "OK" "${SYSTEMD_DROPIN_FILE}"
    else
        _sum_row "Plex drop-in" "FAIL" "Missing: ${SYSTEMD_DROPIN_FILE}"
    fi

    # ── Backup health ─────────────────────────────────────────────────────────
    echo -e "
  ${BOLD}Backup${NC}"
    if [[ -f "${CURRENT_MANIFEST}" ]]; then
        local manifest_lines; manifest_lines=$(wc -l < "${CURRENT_MANIFEST}")
        local manifest_age
        manifest_age=$(( ( $(date +%s) - $(stat -c %Y "${CURRENT_MANIFEST}" | tr -d "[:space:]") ) / 3600 ))
        manifest_lines=$(echo "${manifest_lines}" | tr -d '[:space:]')
        if (( manifest_lines == 0 )); then
            _sum_row "Hash manifest" "WARN" "Empty manifest — run: sudo /usr/local/bin/plex-ramdisk-backup.sh"
        elif (( manifest_age <= 25 )); then
            _sum_row "Hash manifest" "OK"                 "${manifest_lines} entries  last updated ${manifest_age}h ago"
        elif (( manifest_age <= 48 )); then
            _sum_row "Hash manifest" "WARN"                 "${manifest_lines} entries  last updated ${manifest_age}h ago — backup may be overdue"
        else
            _sum_row "Hash manifest" "FAIL"                 "Last updated ${manifest_age}h ago — backup has not run in over 48 hours"
        fi
    else
        _sum_row "Hash manifest" "FAIL" "Missing: ${CURRENT_MANIFEST}"
    fi

    if [[ -d "${BACKUP_CURRENT}" ]]; then
        local cur_size; cur_size=$(du -sh "${BACKUP_CURRENT}" 2>/dev/null | awk '{print $1}')
        local cur_count; cur_count=$(find "${BACKUP_CURRENT}"             -maxdepth 1 -type f ! -name "*.sha256" 2>/dev/null | wc -l)
        _sum_row "Backup current/" "OK" "${BACKUP_CURRENT}  ${cur_size}  ${cur_count} file(s)"
    else
        _sum_row "Backup current/" "FAIL" "Missing: ${BACKUP_CURRENT}"
    fi

    if [[ -d "${BACKUP_SNAPSHOTS}" ]]; then
        local snap_count snap_newest snap_age=""
        snap_count=$(ls -d "${BACKUP_SNAPSHOTS}"/[0-9]* 2>/dev/null | wc -l 2>/dev/null || echo 0)
        snap_count=$(echo "${snap_count}" | tr -d '[:space:]')
        snap_newest=$(ls -d "${BACKUP_SNAPSHOTS}"/[0-9]* 2>/dev/null | sort -r | head -1)
        if [[ -n "${snap_newest}" ]]; then
            local snap_age_h
            snap_age_h=$(( ( $(date +%s) - $(stat -c %Y "${snap_newest}" | tr -d "[:space:]") ) / 3600 ))
            snap_age="  newest: $(basename "${snap_newest}") (${snap_age_h}h ago)"
        fi
        if (( snap_count > 0 )); then
            _sum_row "Snapshots" "OK" "${snap_count}/${SNAPSHOT_KEEP}${snap_age}"
        else
            _sum_row "Snapshots" "WARN" "No snapshots yet"
        fi
    else
        _sum_row "Snapshots" "FAIL" "Missing: ${BACKUP_SNAPSHOTS}"
    fi

    if [[ -d "${DB_BACKUP_DIR}" ]]; then
        local db_bk_count db_bk_size
        db_bk_count=$(find "${DB_BACKUP_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l)
        db_bk_size=$(du -sh "${DB_BACKUP_DIR}" 2>/dev/null | awk '{print $1}')
        _sum_row "Dated DB backups" "INFO"             "${DB_BACKUP_DIR}  ${db_bk_count} file(s)  ${db_bk_size}"
    else
        _sum_row "Dated DB backups" "INFO" "None yet: ${DB_BACKUP_DIR}"
    fi

    # ── Scripts ───────────────────────────────────────────────────────────────
    echo -e "
  ${BOLD}Scripts${NC}"
    if [[ -x "${BACKUP_SCRIPT}" ]]; then
        _sum_row "Backup script"  "OK"   "${BACKUP_SCRIPT}"
    else
        _sum_row "Backup script"  "FAIL" "Missing or not executable"
    fi

    if [[ -x "${RESTORE_SCRIPT}" ]]; then
        _sum_row "Restore script" "OK"   "${RESTORE_SCRIPT}"
    else
        _sum_row "Restore script" "FAIL" "Missing or not executable"
    fi

    if [[ -f "${CRON_FILE}" ]]; then
        _sum_row _sum_row "Cron job"       "OK"   "${CRON_FILE}"
    else
        _sum_row "Cron job"       "FAIL" "Missing: ${CRON_FILE}"
    fi

    # ── Logs ──────────────────────────────────────────────────────────────────
    echo -e "
  ${BOLD}Logs${NC}"
    for lf in "${SETUP_LOG}" "${RUNTIME_LOG}" "${ERROR_LOG}"; do
        if [[ -f "${lf}" ]]; then
            local lf_lines lf_size lf_age_h
            lf_lines=$(wc -l < "${lf}")
            lf_size=$(du -sh "${lf}" | awk '{print $1}')
            lf_age_h=$(( ( $(date +%s) - $(stat -c %Y "${lf}" | tr -d "[:space:]") ) / 3600 ))
            _sum_row "$(basename "${lf}")" "INFO"                 "${lf_lines} lines  ${lf_size}  last write ${lf_age_h}h ago"
        else
            _sum_row "$(basename "${lf}")" "INFO" "Not yet created"
        fi
    done

    # Check error log for recent entries (last 24h)
    if [[ -f "${ERROR_LOG}" ]] && [[ -s "${ERROR_LOG}" ]]; then
        local recent_errors
        recent_errors=$(find "${ERROR_LOG}" -newer "${ERROR_LOG}" -mmin -1440 2>/dev/null             | wc -l || echo 0)
        local error_lines; error_lines=$(wc -l < "${ERROR_LOG}" | tr -d "[:space:]")
        if (( error_lines > 0 )); then
            _sum_row "Error log entries" "WARN"                 "${error_lines} total — review: tail -50 ${ERROR_LOG}"
        fi
    fi

    # ── Overall result ────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  Health:  "
    if (( fail > 0 )); then
        echo -e "${RED}${BOLD}${fail} critical issue(s)${NC}  |  ${YELLOW}${warn} warning(s)${NC}  |  ${GREEN}${ok} OK${NC}"
    elif (( warn > 0 )); then
        echo -e "${GREEN}${BOLD}Healthy${NC}  |  ${YELLOW}${warn} warning(s)${NC}  |  ${GREEN}${ok} OK${NC}"
    else
        echo -e "${GREEN}${BOLD}All systems healthy  (${ok} checks passed)${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}Quick commands:${NC}"
    echo -e "    Full step detail:  sudo bash ${SCRIPT_NAME} --status"
    echo -e "    View error log:    tail -50 ${ERROR_LOG}"
    echo -e "    Runtime log:       tail -f ${RUNTIME_LOG}"
    echo -e "    Manual backup:     sudo ${BACKUP_SCRIPT}"
    echo -e "    Verify manifest:   sha256sum -c ${CURRENT_MANIFEST}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ── Hash verification ─────────────────────────────────────────────────────────
hash_file() {
    local f="$1"
    [[ -f "${f}" ]] || { echo ""; return; }
    sha256sum "${f}" | awk '{print $1}'
}

write_manifest() {
    local dir="$1" manifest="$2"
    local tmp="${manifest}.tmp"
    : > "${tmp}"
    while IFS= read -r -d '' f; do
        local rel="${f#${dir}/}"
        local hash; hash=$(sha256sum "${f}" | awk '{print $1}')
        echo "${hash}  ${rel}" >> "${tmp}"
    done < <(find "${dir}" -maxdepth 1 -type f \
        ! -name "*.sha256" \
        ! -name "*.sha256.tmp" \
        ! -name "*.tmp" \
        ! -regex "${DATED_PATTERN}" \
        -print0 | sort -z)
    mv "${tmp}" "${manifest}"
    _slog "INFO" "Manifest written: ${manifest} ($(wc -l < "${manifest}") entries)"
}

verify_manifest() {
    local dir="$1" manifest="$2"
    if [[ ! -f "${manifest}" ]]; then
        _slog "ERROR" "Manifest not found: ${manifest}"; return 1
    fi
    local errors=0
    while IFS= read -r line; do
        local expected_hash rel_path actual_hash
        expected_hash=$(echo "${line}" | awk '{print $1}')
        rel_path=$(echo "${line}" | awk '{print $2}')
        local full_path="${dir}/${rel_path}"
        if [[ ! -f "${full_path}" ]]; then
            _slog "ERROR" "Hash verify: missing: ${full_path}"; (( errors++ )) || true; continue
        fi
        actual_hash=$(sha256sum "${full_path}" | awk '{print $1}')
        if [[ "${actual_hash}" != "${expected_hash}" ]]; then
            _slog "ERROR" "Hash mismatch: ${rel_path}"
            _slog "ERROR" "  Expected: ${expected_hash}"
            _slog "ERROR" "  Actual:   ${actual_hash}"
            (( errors++ )) || true
        else
            _slog "INFO" "Hash OK: ${rel_path} (${actual_hash:0:12}...)"
        fi
    done < "${manifest}"
    return $(( errors > 0 ? 1 : 0 ))
}

verify_copy() {
    local src="$1" dest="$2"
    local src_hash; src_hash=$(hash_file "${src}")
    local dest_hash; dest_hash=$(hash_file "${dest}")
    if [[ -z "${src_hash}" || -z "${dest_hash}" ]]; then
        _slog "ERROR" "verify_copy: file missing (src=${src} dest=${dest})"; return 1
    fi
    if [[ "${src_hash}" != "${dest_hash}" ]]; then
        _slog "ERROR" "Hash mismatch after copy: $(basename "${dest}")"
        _slog "ERROR" "  src:  ${src_hash}"
        _slog "ERROR" "  dest: ${dest_hash}"
        return 1
    fi
    _slog "INFO" "Hash verified: $(basename "${dest}") (${dest_hash:0:12}...)"
    return 0
}

# ── Dated backup offload ──────────────────────────────────────────────────────
# Moves files matching DATED_PATTERN from a source directory to DB_BACKUP_DIR.
# Called during migration, backup, and restore to keep the ramdisk clear of
# large infrequently-accessed backup files.
#
# FUTURE FEATURE — Step 9: DB_BACKUP_PRUNING
#   Add retention policy here (e.g. keep last 30 days, prune older).
#   State key STEP_9_DB_BACKUP_PRUNING is reserved.
#   When implementing: add --prune-db-backups flag and a cron job.
offload_dated_backups() {
    local src_dir="${1:-${RAMDISK_DB_DIR}}"
    local log_fn="${2:-_slog}"  # _slog for setup, rlog/blog for installed scripts

    mkdir -p "${DB_BACKUP_DIR}"

    local moved=0 skipped=0
    while IFS= read -r -d '' f; do
        local fname; fname=$(basename "${f}")
        local dest="${DB_BACKUP_DIR}/${fname}"

        if [[ -f "${dest}" ]]; then
            # Already exists on disk — remove from ramdisk
            "${log_fn}" "INFO" "  Dated backup already on disk, removing from ramdisk: ${fname}"
            rm -f "${f}"
            (( skipped++ )) || true
        else
            "${log_fn}" "INFO" "  Offloading dated backup: ${fname}"
            mv "${f}" "${dest}"
            (( moved++ ))
        fi
    done < <(find "${src_dir}" -maxdepth 1 -type f \
        -regex "${DATED_PATTERN}" -print0 2>/dev/null | sort -z)

    "${log_fn}" "INFO" "Dated backup offload: ${moved} moved, ${skipped} already on disk"
    "${log_fn}" "INFO" "  DB backup dir: ${DB_BACKUP_DIR} ($(find "${DB_BACKUP_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l) total files)"
}

# ── Rollback ──────────────────────────────────────────────────────────────────
THIS_RUN_CREATED_RAMDISK_DIR=false
THIS_RUN_CREATED_BACKUP_DIRS=false
THIS_RUN_MIGRATED_DIR=false
THIS_RUN_CREATED_RESTORE_SCRIPT=false
THIS_RUN_CREATED_BACKUP_SCRIPT=false
THIS_RUN_CREATED_UNIT=false
THIS_RUN_CREATED_DROPIN=false
THIS_RUN_CREATED_CRON=false
PLEX_WAS_RUNNING=false
ORIGINAL_DB_BACKUP_NAME=""

rollback() {
    log_warn "Rolling back changes made this run..."
    _slog "WARN" "Rollback initiated"

    # ── Undo directory migration ──────────────────────────────────────────
    if $THIS_RUN_MIGRATED_DIR; then
        log_warn "Reverting database directory migration..."

        # Remove symlink
        if [[ -L "${PLEX_DB_SYMLINK}" ]]; then
            log_info "  Removing directory symlink"
            rm -f "${PLEX_DB_SYMLINK}"
            _slog "ROLLBACK" "Removed symlink: ${PLEX_DB_SYMLINK}"
        fi

        # Restore original directory from backup
        if [[ -n "${ORIGINAL_DB_BACKUP_NAME}" && \
              -d "${PLEX_PLUGIN_SUPPORT}/${ORIGINAL_DB_BACKUP_NAME}" ]]; then
            log_info "  Restoring original: ${ORIGINAL_DB_BACKUP_NAME} → Databases"
            mv "${PLEX_PLUGIN_SUPPORT}/${ORIGINAL_DB_BACKUP_NAME}" "${PLEX_DB_SYMLINK}"
            _slog "ROLLBACK" "Restored: ${PLEX_DB_SYMLINK}"
        fi

        # Move dated backups back from DB_BACKUP_DIR to Databases
        if [[ -d "${DB_BACKUP_DIR}" && -d "${PLEX_DB_SYMLINK}" ]]; then
            log_info "  Moving dated backups back to Databases dir..."
            local moved_back=0
            while IFS= read -r -d '' f; do
                mv "${f}" "${PLEX_DB_SYMLINK}/"
                (( moved_back++ ))
            done < <(find "${DB_BACKUP_DIR}" -maxdepth 1 -type f -print0 2>/dev/null)
            log_info "  Moved ${moved_back} dated backup file(s) back"
            _slog "ROLLBACK" "Moved ${moved_back} dated backups back to Databases"
        fi

        state_set "STEP_3_MIGRATE_DIR"    "rolled_back"
        state_set "STEP_3_OFFLOAD_DATED"  "rolled_back"
        state_set "STEP_3_SEED_CURRENT"   "rolled_back"
    fi

    # ── Remove cron ───────────────────────────────────────────────────────
    if $THIS_RUN_CREATED_CRON && [[ -f "${CRON_FILE}" ]]; then
        log_info "Removing cron job..."
        rm -f "${CRON_FILE}"
        state_set "STEP_7_CRON" "rolled_back"
        _slog "ROLLBACK" "Removed: ${CRON_FILE}"
    fi

    # ── Remove drop-in ────────────────────────────────────────────────────
    if $THIS_RUN_CREATED_DROPIN && [[ -f "${SYSTEMD_DROPIN_FILE}" ]]; then
        log_info "Removing Plex drop-in..."
        rm -f "${SYSTEMD_DROPIN_FILE}"
        rmdir "${SYSTEMD_DROPIN_DIR}" 2>/dev/null || true
        state_set "STEP_6_SYSTEMD_DROPIN" "rolled_back"
        _slog "ROLLBACK" "Removed: ${SYSTEMD_DROPIN_FILE}"
    fi

    # ── Disable and remove systemd unit ──────────────────────────────────
    if $THIS_RUN_CREATED_UNIT && [[ -f "${SYSTEMD_UNIT_FILE}" ]]; then
        log_info "Disabling and removing systemd unit..."
        systemctl disable plex-ramdisk-sync.service 2>/dev/null || true
        rm -f "${SYSTEMD_UNIT_FILE}"
        state_set "STEP_6_SYSTEMD_UNIT" "rolled_back"
        _slog "ROLLBACK" "Removed: ${SYSTEMD_UNIT_FILE}"
    fi

    if $THIS_RUN_CREATED_UNIT || $THIS_RUN_CREATED_DROPIN; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    # Restart Plex — drop-in already removed above so no dangling dependency
    if $PLEX_WAS_RUNNING && ! systemctl is-active --quiet "${PLEX_SERVICE}" 2>/dev/null; then
        log_info "Restarting Plex..."
        systemctl start "${PLEX_SERVICE}" 2>/dev/null \
            && log_ok "Plex restarted." \
            || log_warn "Could not restart Plex — start manually."
        _slog "ROLLBACK" "Plex restart attempted"
    fi

    # ── Remove scripts ────────────────────────────────────────────────────
    if $THIS_RUN_CREATED_BACKUP_SCRIPT && [[ -f "${BACKUP_SCRIPT}" ]]; then
        rm -f "${BACKUP_SCRIPT}"
        state_set "STEP_5_BACKUP_SCRIPT" "rolled_back"
        _slog "ROLLBACK" "Removed: ${BACKUP_SCRIPT}"
    fi

    if $THIS_RUN_CREATED_RESTORE_SCRIPT && [[ -f "${RESTORE_SCRIPT}" ]]; then
        rm -f "${RESTORE_SCRIPT}"
        state_set "STEP_4_RESTORE_SCRIPT" "rolled_back"
        _slog "ROLLBACK" "Removed: ${RESTORE_SCRIPT}"
    fi

    # ── Remove backup dirs created this run ───────────────────────────────
    if $THIS_RUN_CREATED_BACKUP_DIRS; then
        rm -rf "${BACKUP_CURRENT}" "${BACKUP_SNAPSHOTS}"
        state_set "STEP_2_BACKUP_DIRS" "rolled_back"
        _slog "ROLLBACK" "Removed backup dirs"
    fi

    # ── Remove ramdisk dirs created this run ──────────────────────────────
    if $THIS_RUN_CREATED_RAMDISK_DIR && [[ -d "${RAMDISK_PLEX_DIR}" ]]; then
        rm -rf "${RAMDISK_PLEX_DIR}"
        state_set "STEP_1_RAMDISK_DIR" "rolled_back"
        _slog "ROLLBACK" "Removed: ${RAMDISK_PLEX_DIR}"
    fi

    log_warn "Rollback complete."
    _slog "WARN" "Rollback complete"
}

trap_rollback() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        # Only roll back if setup steps actually ran — not on audit abort
        if $THIS_RUN_MIGRATED_DIR || $THIS_RUN_CREATED_RAMDISK_DIR ||            $THIS_RUN_CREATED_BACKUP_DIRS || $THIS_RUN_CREATED_UNIT ||            $THIS_RUN_CREATED_CRON; then
            echo ""
            log_error "Script exited unexpectedly (code ${exit_code}). Initiating rollback..."
            rollback
        else
            echo ""
            log_error "Script aborted (code ${exit_code}) before any changes were made."
        fi
    fi
}

# ── Inventory audit ───────────────────────────────────────────────────────────
AUDIT_ERRORS=0
AUDIT_WARNINGS=0

_audit_row() {
    local label="$1" status="$2" detail="$3"
    local color="$NC" tag=""
    case "$status" in
        OK)    color="$GREEN";  tag="  OK  " ;;
        WARN)  color="$YELLOW"; tag=" WARN " ; (( AUDIT_WARNINGS++ )) || true ;;
        ERROR) color="$RED";    tag=" ERR  " ; (( AUDIT_ERRORS++ )) || true   ;;
        INFO)  color="$BLUE";   tag=" INFO " ;;
    esac
    printf "  ${color}[%s]${NC}  %-45s %s\n" "$tag" "$label" "$detail"
    _slog "${status}" "AUDIT  ${label}: ${detail}"
}

inventory_audit() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  PRE-EXECUTION INVENTORY AUDIT${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # ── Ubuntu Compatibility ─────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Ubuntu Compatibility${NC}"

    if [[ -f /etc/os-release ]]; then
        local distro_id distro_ver distro_pretty distro_major
        distro_id=$(grep -m1 "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        distro_ver=$(grep -m1 "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        distro_pretty=$(grep -m1 "^PRETTY_NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
        distro_major=$(echo "${distro_ver}" | cut -d. -f1)
        if [[ "${distro_id}" == "ubuntu" ]]; then
            if (( distro_major >= 20 )); then
                _audit_row "OS" "OK"    "${distro_pretty}"
            else
                _audit_row "OS" "ERROR" "${distro_pretty} — Ubuntu 20.04+ required"
            fi
        else
            _audit_row "OS" "WARN" "${distro_pretty} — designed for Ubuntu, untested on this distro"
        fi
    else
        _audit_row "OS" "ERROR" "/etc/os-release not found"
    fi

    local arch; arch=$(uname -m)
    if [[ "${arch}" == "x86_64" || "${arch}" == "aarch64" ]]; then
        _audit_row "Architecture" "OK"    "${arch}"
    else
        _audit_row "Architecture" "ERROR" "${arch} — Plex requires x86_64 or aarch64"
    fi

    local bash_major="${BASH_VERSINFO[0]}"
    if (( bash_major >= 4 )); then
        _audit_row "Bash version" "OK"    "${BASH_VERSION}"
    else
        _audit_row "Bash version" "ERROR" "${BASH_VERSION} — Bash 4.0+ required"
    fi

    if [[ "$(ps -p 1 -o comm=)" == "systemd" ]]; then
        _audit_row "Init system" "OK"    "systemd (PID 1)"
    else
        _audit_row "Init system" "ERROR" "$(ps -p 1 -o comm=) — systemd required"
    fi

    # ── System Requirements ───────────────────────────────────────────────────
    echo -e "\n  ${BOLD}System Requirements${NC}"

    if [[ $EUID -eq 0 ]]; then
        _audit_row "Running as root"     "OK"    "uid=0"
    else
        _audit_row "Running as root"     "ERROR" "Must run with sudo"
    fi

    if command -v rsync &>/dev/null; then
        _audit_row "rsync"               "OK"    "$(command -v rsync)"
    else
        _audit_row "rsync"               "ERROR" "Not found — sudo apt install rsync"
    fi

    if command -v sha256sum &>/dev/null; then
        _audit_row "sha256sum"           "OK"    "$(command -v sha256sum)"
    else
        _audit_row "sha256sum"           "ERROR" "Not found — sudo apt install coreutils"
    fi

    if command -v systemctl &>/dev/null; then
        _audit_row "systemctl"           "OK"    "$(command -v systemctl)"
    else
        _audit_row "systemctl"           "ERROR" "Not found — systemd required"
    fi

    if touch "${SETUP_LOG}" 2>/dev/null; then
        _audit_row "Setup log writable"  "OK"    "${SETUP_LOG}"
    else
        _audit_row "Setup log writable"  "WARN"  "Cannot write ${SETUP_LOG}"
    fi

    if touch "${RUNTIME_LOG}" 2>/dev/null; then
        _audit_row "Runtime log writable" "OK"   "${RUNTIME_LOG}"
    else
        _audit_row "Runtime log writable" "WARN" "Cannot write ${RUNTIME_LOG}"
    fi

    # ── Previous State ────────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Previous Setup State${NC}"

    if [[ -f "${STATE_FILE}" ]]; then
        local failed=0 complete=0
        while IFS='=' read -r key val; do
            [[ "${val}" == "complete" ]] && (( complete++ )) || true
            [[ "${val}" == "failed" || "${val}" == "rolled_back" ]] && (( failed++ )) || true
        done < "${STATE_FILE}"
        if (( failed > 0 )); then
            _audit_row "State file" "WARN" "${STATE_FILE} — ${failed} failed, ${complete} complete — use --status"
        else
            _audit_row "State file" "WARN" "${STATE_FILE} — ${complete} step(s) previously complete"
        fi
    else
        _audit_row "State file" "INFO" "No prior state — fresh install"
    fi

    # ── Ramdisk ───────────────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Ramdisk${NC}"

    if mountpoint -q "${RAMDISK_MOUNT}" 2>/dev/null; then
        local rd_avail; rd_avail=$(df -h "${RAMDISK_MOUNT}" | awk 'NR==2{print $4}')
        _audit_row "Ramdisk mounted"        "OK"    "${RAMDISK_MOUNT} (${rd_avail} available)"
    else
        _audit_row "Ramdisk mounted"        "ERROR" "${RAMDISK_MOUNT} is not mounted"
    fi

    if [[ -d "${RAMDISK_PLEX_DIR}" ]]; then
        _audit_row "Ramdisk Plex dir"    "WARN"  "Already exists: ${RAMDISK_PLEX_DIR}"
    else
        _audit_row "Ramdisk Plex dir"    "INFO"  "Will be created: ${RAMDISK_PLEX_DIR}"
    fi

    if [[ -d "${RAMDISK_DB_DIR}" ]]; then
        _audit_row "Ramdisk DB dir"      "WARN"  "Already exists: ${RAMDISK_DB_DIR}"
    else
        _audit_row "Ramdisk DB dir"      "INFO"  "Will be created: ${RAMDISK_DB_DIR}"
    fi

    # ── Plex Installation ─────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Plex Installation${NC}"

    if id "${PLEX_USER}" &>/dev/null; then
        _audit_row "Plex user"           "OK"    "${PLEX_USER} (uid=$(id -u "${PLEX_USER}"))"
    else
        _audit_row "Plex user"           "ERROR" "User '${PLEX_USER}' not found"
    fi

    if systemctl list-unit-files "${PLEX_SERVICE}.service" 2>/dev/null | grep -q "${PLEX_SERVICE}"; then
        local plex_state
        plex_state=$(systemctl is-active "${PLEX_SERVICE}" 2>/dev/null || true)
        [[ -z "${plex_state}" ]] && plex_state="inactive"
        _audit_row "Plex service"           "OK"    "${PLEX_SERVICE}.service (${plex_state})"
    else
        _audit_row "Plex service"           "ERROR" "${PLEX_SERVICE}.service not found"
    fi

    # ── Databases Directory ───────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Databases Directory${NC}"

    if [[ -L "${PLEX_DB_SYMLINK}" ]]; then
        _audit_row "Databases path" "WARN" "Already a symlink → $(readlink -f "${PLEX_DB_SYMLINK}") (already configured?)"
    elif [[ -d "${PLEX_DB_SYMLINK}" ]]; then
        local db_total_mb; db_total_mb=$(du -sm "${PLEX_DB_SYMLINK}" 2>/dev/null | awk '{print $1}')
        local db_active_mb dated_count active_count total_count
        # Count and size active vs dated files
        dated_count=$(find "${PLEX_DB_SYMLINK}" -maxdepth 1 -type f \
            -regex "${DATED_PATTERN}" 2>/dev/null | wc -l)
        total_count=$(find "${PLEX_DB_SYMLINK}" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d "[:space:]")
        active_count=$(( total_count - dated_count ))
        db_active_mb=$(find "${PLEX_DB_SYMLINK}" -maxdepth 1 -type f \
            ! -regex "${DATED_PATTERN}" 2>/dev/null \
            -exec du -sc {} + 2>/dev/null | tail -1 | awk '{print int($1/1024)}')
        _audit_row "Databases dir"  "OK"   "${PLEX_DB_SYMLINK}"
        _audit_row "  Total size"   "INFO" "${db_total_mb}MB (${total_count} files)"
        _audit_row "  Active files" "INFO" "${active_count} files — ${db_active_mb}MB → will move to ramdisk"
        _audit_row "  Dated files"  "INFO" "${dated_count} files → will offload to ${DB_BACKUP_DIR}"

        # Check active files fit on ramdisk
        if mountpoint -q "${RAMDISK_MOUNT}" 2>/dev/null; then
            local rd_avail_kb; rd_avail_kb=$(df -k "${RAMDISK_MOUNT}" | awk 'NR==2{print $4}')
            local db_active_kb=$(( db_active_mb * 1024 ))
            if (( db_active_kb > rd_avail_kb )); then
                _audit_row "Active files fit on ramdisk" "ERROR" \
                    "${db_active_mb}MB needed, $(( rd_avail_kb/1024 ))MB available"
            else
                _audit_row "Active files fit on ramdisk" "OK" \
                    "${db_active_mb}MB of $(( rd_avail_kb/1024 ))MB available"
            fi
        fi
    else
        _audit_row "Databases dir"  "ERROR" "Not found: ${PLEX_DB_SYMLINK}"
    fi

    # ── Backup Structure ──────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Backup Structure${NC}"

    if [[ -d "${BACKUP_ROOT}" ]]; then
        _audit_row "Backup root"         "WARN"  "Exists: ${BACKUP_ROOT}"
    else
        _audit_row "Backup root"         "INFO"  "Will be created: ${BACKUP_ROOT}"
    fi

    if [[ -d "${BACKUP_CURRENT}" ]]; then
        _audit_row "current/ dir"        "WARN"  "Exists — will be overwritten on first sync"
    else
        _audit_row "current/ dir"        "INFO"  "Will be created: ${BACKUP_CURRENT}"
    fi

    if [[ -f "${CURRENT_MANIFEST}" ]]; then
        _audit_row "Hash manifest"       "WARN"  "Exists: ${CURRENT_MANIFEST}"
    else
        _audit_row "Hash manifest"       "INFO"  "Will be created after first backup"
    fi

    if [[ -d "${DB_BACKUP_DIR}" ]]; then
        local dated_on_disk; dated_on_disk=$(find "${DB_BACKUP_DIR}" -maxdepth 1 \
            -type f 2>/dev/null | wc -l)
        _audit_row "DB backup dir"          "WARN"  "Exists: ${DB_BACKUP_DIR} (${dated_on_disk} files)"
    else
        _audit_row "DB backup dir"         "INFO"  "Will be created: ${DB_BACKUP_DIR}"
    fi

    if [[ -d "${BACKUP_SNAPSHOTS}" ]]; then
        local snap_count; snap_count=$(ls -d "${BACKUP_SNAPSHOTS}"/[0-9]* \
            2>/dev/null | wc -l || echo 0)
        _audit_row "Existing snapshots"     "INFO"  "${snap_count}/${SNAPSHOT_KEEP} slots used"
    else
        _audit_row "snapshots/ dir"         "INFO"  "Will be created: ${BACKUP_SNAPSHOTS}"
    fi

    # ── Systemd ───────────────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Systemd${NC}"

    if [[ -f "${SYSTEMD_UNIT_FILE}" ]]; then
        _audit_row "plex-ramdisk-sync.service"  "WARN" "Exists — will overwrite"
    else
        _audit_row "plex-ramdisk-sync.service"  "INFO" "Will be created"
    fi

    if [[ -f "${SYSTEMD_DROPIN_FILE}" ]]; then
        _audit_row "Plex drop-in"               "WARN" "Exists — will overwrite"
    else
        _audit_row "Plex drop-in"               "INFO" "Will be created: ${SYSTEMD_DROPIN_FILE}"
    fi

    # ── Scripts & Cron ────────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Scripts & Cron${NC}"

    if [[ -f "${BACKUP_SCRIPT}" ]]; then
        _audit_row "Backup script"       "WARN"  "Exists — will overwrite"
    else
        _audit_row "Backup script"       "INFO"  "Will be created: ${BACKUP_SCRIPT}"
    fi

    if [[ -f "${RESTORE_SCRIPT}" ]]; then
        _audit_row "Restore script"      "WARN"  "Exists — will overwrite"
    else
        _audit_row "Restore script"      "INFO"  "Will be created: ${RESTORE_SCRIPT}"
    fi

    if [[ -f "${CRON_FILE}" ]]; then
        _audit_row "Cron job"            "WARN"  "Exists — will overwrite"
    else
        _audit_row "Cron job"            "INFO"  "Will be created (daily 04:30)"
    fi

    # ── Audit Result ──────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  Audit result:  "
    if (( AUDIT_ERRORS > 0 )); then
        echo -e "${RED}${BOLD}${AUDIT_ERRORS} blocking error(s)${NC}  |  ${YELLOW}${AUDIT_WARNINGS} warning(s)${NC}"
        echo -e "\n  ${RED}Resolve errors above before running.${NC}"
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        _slog "ERROR" "Audit failed: ${AUDIT_ERRORS} error(s) — aborting"
        exit 1
    elif (( AUDIT_WARNINGS > 0 )); then
        echo -e "${GREEN}${BOLD}No blocking errors${NC}  |  ${YELLOW}${AUDIT_WARNINGS} warning(s)${NC}"
        _slog "WARN" "Audit passed with ${AUDIT_WARNINGS} warning(s)"
    else
        echo -e "${GREEN}${BOLD}Clean${NC}"
        _slog "OK" "Audit clean"
    fi
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN] Skipping confirmation.${NC}\n"; return
    fi

    # ── Pre-confirmation state table ──────────────────────────────────────────
    # Shows exactly what each step will do before the user confirms.
    echo -e "  ${BOLD}Step plan — what will happen when you confirm:${NC}"
    echo ""

    local _steps=(
        "STEP_1_RAMDISK_DIR:    Create ${RAMDISK_DB_DIR}/"
        "STEP_2_BACKUP_DIRS:    Create backup dirs + DB backup dir"
        "STEP_3_MIGRATE_DIR:    Stop Plex → copy Databases/ → offload dated → symlink → seed"
        "STEP_3_OFFLOAD_DATED:  Move dated Plex backups → ${DB_BACKUP_DIR}"
        "STEP_3_SEED_CURRENT:   Seed + hash-verify ${BACKUP_CURRENT}/"
        "STEP_4_RESTORE_SCRIPT: Write ${RESTORE_SCRIPT}"
        "STEP_5_BACKUP_SCRIPT:  Write ${BACKUP_SCRIPT}"
        "STEP_6_SYSTEMD_UNIT:   Write + enable plex-ramdisk-sync.service"
        "STEP_6_SYSTEMD_DROPIN: Write Plex boot drop-in (${PLEX_BOOT_DELAY}s delay)"
        "STEP_7_CRON:           Write cron job + logrotate config"
        "STEP_8_WATCHDOG:       Future feature — placeholder only"
        "STEP_9_DB_BACKUP_PRUNING: Future feature — placeholder only"
    )

    local _will_run=0 _will_skip=0 _will_resume=0
    for entry in "${_steps[@]}"; do
        local key desc
        key="${entry%%:*}"
        desc="${entry#*: }"
        local val; val=$(state_get "${key}")
        case "${val}" in
            complete)
                # Validate the thing still exists — if not, will re-run
                local _still_ok=true
                case "${key}" in
                    STEP_1_RAMDISK_DIR)    [[ -d "${RAMDISK_DB_DIR}" ]]         || _still_ok=false ;;
                    STEP_2_BACKUP_DIRS)    [[ -d "${BACKUP_CURRENT}" ]]          || _still_ok=false ;;
                    STEP_3_MIGRATE_DIR)    [[ -L "${PLEX_DB_SYMLINK}" ]]         || _still_ok=false ;;
                    STEP_4_RESTORE_SCRIPT) [[ -x "${RESTORE_SCRIPT}" ]]          || _still_ok=false ;;
                    STEP_5_BACKUP_SCRIPT)  [[ -x "${BACKUP_SCRIPT}" ]]           || _still_ok=false ;;
                    STEP_6_SYSTEMD_UNIT)   [[ -f "${SYSTEMD_UNIT_FILE}" ]]       || _still_ok=false ;;
                    STEP_6_SYSTEMD_DROPIN) [[ -f "${SYSTEMD_DROPIN_FILE}" ]]     || _still_ok=false ;;
                    STEP_7_CRON)           [[ -f "${CRON_FILE}" ]]               || _still_ok=false ;;
                esac
                if $_still_ok; then
                    printf "    ${GREEN}[SKIP]${NC}    %-30s already complete and verified\n" "${key}"
                    (( _will_skip++ )) || true
                else
                    printf "    ${YELLOW}[RE-RUN]${NC}  %-30s was complete but target is missing\n" "${key}"
                    (( _will_resume++ )) || true
                fi
                ;;
            failed|rolled_back)
                printf "    ${RED}[RE-RUN]${NC}  %-30s previous run failed — will retry\n" "${key}"
                (( _will_resume++ )) || true
                ;;
            pending)
                printf "    ${BLUE}[SKIP]${NC}    %-30s future feature placeholder\n" "${key}"
                ;;
            *)
                printf "    ${BLUE}[RUN]${NC}     %-30s %s\n" "${key}" "${desc}"
                (( _will_run++ )) || true
                ;;
        esac
    done

    echo ""
    echo -e "  ${BOLD}Summary:${NC}  ${GREEN}${_will_run} step(s) to run${NC}  |"         "${YELLOW}${_will_resume} to re-run${NC}  |  ${GREEN}${_will_skip} to skip${NC}"
    echo ""
    echo -e "  ${YELLOW}Note: rollback will fire automatically on any failure.${NC}"
    echo ""
    read -r -p "  Proceed? [yes/no]: " confirm
    echo ""
    case "${confirm,,}" in
        yes|y) log_ok "Confirmed. Starting setup..."; _slog "INFO" "User confirmed" ;;
        *)     echo "  Aborted."; _slog "INFO" "User aborted"; exit 0 ;;
    esac
}

# ── Step 1: Ramdisk directories ───────────────────────────────────────────────
setup_ramdisk_dir() {
    log_step "Step 1: Ramdisk Plex Directory"
    local prev; prev=$(state_get "STEP_1_RAMDISK_DIR")

    if [[ "${prev}" == "complete" && -d "${RAMDISK_DB_DIR}" ]]; then
        log_ok "Already complete — skipping."; return
    fi

    if [[ ! -d "${RAMDISK_PLEX_DIR}" ]]; then
        run_cmd mkdir -p "${RAMDISK_DB_DIR}"
        THIS_RUN_CREATED_RAMDISK_DIR=true
    else
        run_cmd mkdir -p "${RAMDISK_DB_DIR}"
    fi
    run_cmd chown -R "${PLEX_USER}:${PLEX_USER}" "${RAMDISK_PLEX_DIR}"
    state_set "STEP_1_RAMDISK_DIR" "complete"
    log_ok "Ramdisk dirs ready: ${RAMDISK_DB_DIR}"
}

# ── Step 2: Backup directory structure ────────────────────────────────────────
setup_backup_dirs() {
    log_step "Step 2: Backup Directory Structure"
    local prev; prev=$(state_get "STEP_2_BACKUP_DIRS")

    if [[ "${prev}" == "complete" && -d "${BACKUP_CURRENT}" && -d "${BACKUP_SNAPSHOTS}" ]]; then
        log_ok "Already complete — skipping."; return
    fi

    [[ ! -d "${BACKUP_CURRENT}" ]] && THIS_RUN_CREATED_BACKUP_DIRS=true
    run_cmd mkdir -p "${BACKUP_CURRENT}"
    run_cmd mkdir -p "${BACKUP_SNAPSHOTS}"
    run_cmd mkdir -p "${STATE_DIR}"
    run_cmd mkdir -p "${DB_BACKUP_DIR}"
    state_set "STEP_2_BACKUP_DIRS" "complete"
    log_ok "Backup dirs ready: ${BACKUP_ROOT}"
}

# ── Step 3: Migrate entire Databases directory ────────────────────────────────
migrate_database_dir() {
    log_step "Step 3: Migrate Databases Directory to Ramdisk"

    local prev; prev=$(state_get "STEP_3_MIGRATE_DIR")
    local prev_seed; prev_seed=$(state_get "STEP_3_SEED_CURRENT")

    # If migration is complete but seed failed, skip straight to seed retry
    if [[ "${prev}" == "complete" && -L "${PLEX_DB_SYMLINK}" && -d "${RAMDISK_DB_DIR}" ]]; then
        if [[ "${prev_seed}" == "complete" ]]; then
            log_ok "Already complete — skipping."; return
        else
            log_warn "Migration complete but seed step ${prev_seed} — retrying seed only..."
            _slog "WARN" "Retrying failed seed step (migration already complete)"
        fi
    fi

    # If migration already done, skip straight to seed
    local _skip_to_seed=false
    local _prev_migrate; _prev_migrate=$(state_get "STEP_3_MIGRATE_DIR")
    if [[ "${_prev_migrate}" == "complete" && -L "${PLEX_DB_SYMLINK}" ]]; then
        _skip_to_seed=true
        log_info "Skipping file migration (already complete) — proceeding to seed step."
    fi

    # Stop Plex
    if ! $_skip_to_seed && systemctl is-active --quiet "${PLEX_SERVICE}" 2>/dev/null; then
        PLEX_WAS_RUNNING=true
        log_info "Stopping Plex..."
        run_cmd systemctl stop "${PLEX_SERVICE}"
        local waited=0
        while systemctl is-active --quiet "${PLEX_SERVICE}" 2>/dev/null; do
            sleep 2; (( waited += 2 ))
            log_info "  Waiting for Plex to stop... (${waited}s)"
            if (( waited >= 30 )); then
                log_error "Plex did not stop within 30s — aborting"
                state_set "STEP_3_MIGRATE_DIR" "failed"; return 1
            fi
        done
        log_ok "Plex stopped."
    else
        PLEX_WAS_RUNNING=false
        log_info "Plex is not running."
    fi

    if ! $_skip_to_seed; then
    log_disk_state "before migrate"
    log_db_sizes "${PLEX_DB_SYMLINK}" "Databases dir before migrate"

    # Copy entire Databases directory to ramdisk
    log_info "Copying Databases/ → ${RAMDISK_DB_DIR} ..."
    if ! $DRY_RUN; then
        local t0; t0=$(date +%s)
        rsync -av "${PLEX_DB_SYMLINK}/" "${RAMDISK_DB_DIR}/" >> "${SETUP_LOG}" 2>&1
        local rsync_rc=$? t1; t1=$(date +%s)
        _slog "INFO" "Directory copy rsync: exit=${rsync_rc}  duration=$(( t1 - t0 ))s"
        if [[ ${rsync_rc} -ne 0 ]]; then
            log_error "rsync failed (exit ${rsync_rc})"
            state_set "STEP_3_MIGRATE_DIR" "failed"; return 1
        fi
        chown -R "${PLEX_USER}:${PLEX_USER}" "${RAMDISK_DB_DIR}"
        log_ok "Directory copied to ramdisk."
    else
        log_dry "rsync -av '${PLEX_DB_SYMLINK}/' '${RAMDISK_DB_DIR}/'"
    fi

    # Offload dated backups from ramdisk to disk
    log_info "Offloading dated Plex backup files and stray files from ramdisk..."
    if ! $DRY_RUN; then
        # Remove any stray manifest/tmp files that don't belong on ramdisk
        local stray_count
        stray_count=$(find "${RAMDISK_DB_DIR}" -maxdepth 1 -type f             \( -name "*.sha256" -o -name "*.sha256.tmp" -o -name "*.tmp" \)             2>/dev/null | wc -l | tr -d '[:space:]')
        if (( stray_count > 0 )); then
            log_info "  Removing ${stray_count} stray file(s) from ramdisk (sha256/tmp)"
            find "${RAMDISK_DB_DIR}" -maxdepth 1 -type f                 \( -name "*.sha256" -o -name "*.sha256.tmp" -o -name "*.tmp" \)                 -delete 2>/dev/null || true
        fi
        offload_dated_backups "${RAMDISK_DB_DIR}" "_slog"
        state_set "STEP_3_OFFLOAD_DATED" "complete"
        log_ok "Dated backups offloaded to ${DB_BACKUP_DIR}"
    else
        log_dry "offload_dated_backups: move *.db-YYYY-MM-DD* from ramdisk → ${DB_BACKUP_DIR}"
    fi

    log_db_sizes "${RAMDISK_DB_DIR}" "ramdisk DB dir after offload"
    log_disk_state "after offload"

    # Rename original Databases directory as timestamped safety backup
    ORIGINAL_DB_BACKUP_NAME="BACKUP_Databases_$(date +%Y%m%d_%H%M%S)"
    log_info "Renaming original: Databases → ${ORIGINAL_DB_BACKUP_NAME}"
    run_cmd mv "${PLEX_DB_SYMLINK}" "${PLEX_PLUGIN_SUPPORT}/${ORIGINAL_DB_BACKUP_NAME}"
    THIS_RUN_MIGRATED_DIR=true

    # Create directory symlink
    log_info "Creating directory symlink: Databases → ${RAMDISK_DB_DIR}"
    run_cmd ln -s "${RAMDISK_DB_DIR}" "${PLEX_DB_SYMLINK}"
    # Note: chown -h on symlinks may not work on all filesystems (e.g. tmpfs).
    # Linux does not enforce symlink ownership for access control — target
    # directory ownership (plex:plex) is what matters.
    log_ok "Directory symlink created."

    state_set "STEP_3_MIGRATE_DIR" "complete"
    fi # end skip_to_seed guard

    # Seed current/ and write manifest (active files only — no dated backups)
    log_info "Seeding ${BACKUP_CURRENT}/ (active files only)..."
    if ! $DRY_RUN; then
        log_disk_state "before seed"
        local t0; t0=$(date +%s)
        # Copy active DB files to current/ — exclude manifests, tmp files, dated backups
        rsync -av \
            --exclude="*.sha256" \
            --exclude="*.sha256.tmp" \
            --exclude="*.tmp" \
            --filter="- *-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*" \
            "${RAMDISK_DB_DIR}/" "${BACKUP_CURRENT}/" >> "${SETUP_LOG}" 2>&1
        # Belt-and-suspenders: remove anything that slipped through
        find "${BACKUP_CURRENT}" -maxdepth 1 -type f \
            \( -name "*.sha256" -o -name "*.tmp" -o -regex "${DATED_PATTERN}" \) \
            -delete 2>/dev/null || true
        local t1; t1=$(date +%s)
        _slog "INFO" "Seed rsync: duration=$(( t1 - t0 ))s"
        chown -R "${PLEX_USER}:${PLEX_USER}" "${BACKUP_CURRENT}"
        log_info "Seeded $(find "${BACKUP_CURRENT}" -maxdepth 1 -type f | wc -l) files to current/"

        log_info "Writing hash manifest..."
        write_manifest "${BACKUP_CURRENT}" "${CURRENT_MANIFEST}"
        local manifest_entries; manifest_entries=$(wc -l < "${CURRENT_MANIFEST}")
        log_info "Manifest written: ${manifest_entries} entries"

        log_info "Verifying manifest..."
        if ! verify_manifest "${BACKUP_CURRENT}" "${CURRENT_MANIFEST}"; then
            log_error "Manifest verification failed — check ${SETUP_LOG} for details"
            state_set "STEP_3_SEED_CURRENT" "failed"; return 1
        fi
        log_ok "Manifest verified: ${manifest_entries} file(s) OK."
        log_db_sizes "${BACKUP_CURRENT}" "current/ after seed"
        log_disk_state "after seed"
    else
        log_dry "rsync active files → current/ && write_manifest && verify"
    fi

    state_set "STEP_3_SEED_CURRENT" "complete"

    # Restart Plex
    log_info "Starting Plex..."
    run_cmd systemctl start "${PLEX_SERVICE}"
    log_ok "Plex started."
}

# ── Step 4: Restore script ────────────────────────────────────────────────────
write_restore_script() {
    log_step "Step 4: Restore Script"
    local prev; prev=$(state_get "STEP_4_RESTORE_SCRIPT")
    if [[ "${prev}" == "complete" && -x "${RESTORE_SCRIPT}" ]]; then
        log_ok "Already installed — skipping."; return
    fi

    cat > "${RESTORE_SCRIPT}" << RESTORE_EOF
#!/usr/bin/env bash
# =============================================================================
# plex-ramdisk-restore.sh
# Version: ${RESTORE_SCRIPT_VERSION}
# Generated by: plex-ramdisk-setup.sh v${SETUP_VERSION}
# Generated on: $(date '+%Y-%m-%d %H:%M:%S')
# Changelog:
#   3.2.0 - Fixed script-level "local" declarations in post-restore
#            verification loop; stray sha256/tmp files cleaned from
#            ramdisk after offload; rsync excludes sha256/tmp files
#   3.1.0 - Added ttylog() for console output during boot/shutdown
#   3.0.0 - Added boot restore with snapshot fallback; hash verification;
#            Plex stop/start handling; WAL checkpoint wait
# Description:  Restores Plex DB files from backup current/ (or most recent
#               valid snapshot) to ramdisk on boot. Offloads any dated backup
#               files that crept into the ramdisk back to disk. Verifies hashes
#               before and after restore. Ensures Plex is not running.
#               Called by plex-ramdisk-sync.service ExecStart.
# Log:          ${RUNTIME_LOG}
# =============================================================================

SCRIPT_VERSION="${RESTORE_SCRIPT_VERSION}"
RAMDISK_MOUNT="${RAMDISK_MOUNT}"
RAMDISK_DB_DIR="${RAMDISK_DB_DIR}"
BACKUP_CURRENT="${BACKUP_CURRENT}"
BACKUP_SNAPSHOTS="${BACKUP_SNAPSHOTS}"
CURRENT_MANIFEST="${CURRENT_MANIFEST}"
DB_BACKUP_DIR="${DB_BACKUP_DIR}"
DATED_PATTERN="${DATED_PATTERN}"
PLEX_USER="${PLEX_USER}"
PLEX_SERVICE="${PLEX_SERVICE}"
LOG_FILE="${RUNTIME_LOG}"
ERROR_LOG="${ERROR_LOG}"
RESTORE_STOP_TIMEOUT=${RESTORE_STOP_TIMEOUT}

_ts()    { date '+%Y-%m-%d %H:%M:%S'; }
_RESTORE_START=\$(date +%s)

# rlog: detailed entries to log file only (and error log for WARN/ERROR)
rlog() {
    local lvl="\$1"; shift
    local line="\$(_ts) [restore v\${SCRIPT_VERSION}] [\${lvl}] \$*"
    echo "\${line}" >> "\${LOG_FILE}"
    [[ "\${lvl}" == "ERROR" || "\${lvl}" == "WARN" ]] && \
        echo "\${line}" >> "\${ERROR_LOG}" 2>/dev/null || true
}

# ttylog: user-facing progress — writes to console AND log file
# Uses /dev/console for guaranteed terminal output during boot/shutdown
# when a normal TTY may not be available.
ttylog() {
    local lvl="\$1"; shift
    local msg="\$*"
    local prefix
    case "\${lvl}" in
        OK)    prefix="[  OK  ] Plex Ramdisk Restore:" ;;
        WARN)  prefix="[ WARN ] Plex Ramdisk Restore:" ;;
        ERROR) prefix="[FAILED] Plex Ramdisk Restore:" ;;
        *)     prefix="[      ] Plex Ramdisk Restore:" ;;
    esac
    echo "\${prefix} \${msg}" > /dev/console 2>/dev/null || echo "\${prefix} \${msg}" || true
    rlog "\${lvl}" "\${msg}"
}

rlog_disk() {
    local label="\${1:-disk}"
    local rd_used rd_avail bk_used bk_avail
    mountpoint -q "\${RAMDISK_MOUNT}" 2>/dev/null && \
        read -r rd_used rd_avail <<< "\$(df -k "\${RAMDISK_MOUNT}" | awk 'NR==2{print \$3, \$4}')" && \
        rlog "INFO" "[\${label}] ramdisk: used=\$(( rd_used/1024 ))MB  avail=\$(( rd_avail/1024 ))MB"
    [[ -d "${BACKUP_ROOT}" ]] && \
        read -r bk_used bk_avail <<< "\$(df -k "${BACKUP_ROOT}" | awk 'NR==2{print \$3, \$4}')" && \
        rlog "INFO" "[\${label}] backup disk: used=\$(( bk_used/1024 ))MB  avail=\$(( bk_avail/1024 ))MB"
}

# Offload dated backup files from ramdisk to disk
offload_dated() {
    mkdir -p "\${DB_BACKUP_DIR}"
    local moved=0 skipped=0
    while IFS= read -r -d '' f; do
        local fname dest; fname=\$(basename "\${f}"); dest="\${DB_BACKUP_DIR}/\${fname}"
        if [[ -f "\${dest}" ]]; then
            rlog "INFO" "  Dated backup already on disk, removing from ramdisk: \${fname}"
            rm -f "\${f}"; (( skipped++ )) || true
        else
            rlog "INFO" "  Offloading: \${fname}"
            mv "\${f}" "\${dest}"; (( moved++ ))
        fi
    done < <(find "\${RAMDISK_DB_DIR}" -maxdepth 1 -type f \
        -regex "\${DATED_PATTERN}" -print0 2>/dev/null | sort -z)
    rlog "INFO" "Dated backup offload: \${moved} moved, \${skipped} already on disk"
}

rlog "INFO" "========================================================"
ttylog "INFO" "Starting — v\${SCRIPT_VERSION}"
rlog "INFO" "  Host: \$(hostname)  PID: \$$"
rlog "INFO" "  current/:   \${BACKUP_CURRENT}"
rlog "INFO" "  snapshots/: \${BACKUP_SNAPSHOTS}"
rlog_disk "restore start"

# ── Verify ramdisk mounted ────────────────────────────────────────────────────
if ! mountpoint -q "\${RAMDISK_MOUNT}"; then
    ttylog "ERROR" "Ramdisk not mounted at \${RAMDISK_MOUNT} — aborting"
    exit 1
fi

# ── Ensure Plex is not running ────────────────────────────────────────────────
if systemctl is-active --quiet "\${PLEX_SERVICE}" 2>/dev/null; then
    ttylog "WARN" "Plex is running before restore — stopping it first"
    systemctl stop "\${PLEX_SERVICE}" 2>/dev/null || true
    waited=0
    while systemctl is-active --quiet "\${PLEX_SERVICE}" 2>/dev/null; do
        sleep 2; (( waited += 2 ))
        ttylog "INFO" "Waiting for Plex to stop... (\${waited}s)"
        if (( waited >= RESTORE_STOP_TIMEOUT )); then
            ttylog "ERROR" "Plex did not stop within \${RESTORE_STOP_TIMEOUT}s — aborting"
            exit 1
        fi
    done
    ttylog "INFO" "Plex stopped after \${waited}s"
else
    rlog "INFO" "Plex is not running — OK"
fi

# ── Find and verify a valid restore source ────────────────────────────────────
verify_source() {
    local dir="\$1" manifest="\$2"
    [[ -d "\${dir}" ]] || { rlog "WARN" "Source dir missing: \${dir}"; return 1; }
    [[ -f "\${manifest}" ]] || { rlog "WARN" "Manifest missing: \${manifest}"; return 1; }
    rlog "INFO" "Verifying source: \$(basename "\${dir}")"
    local errors=0
    while IFS= read -r line; do
        local expected_hash rel_path actual_hash fpath
        expected_hash=\$(echo "\${line}" | awk '{print \$1}')
        rel_path=\$(echo "\${line}" | awk '{print \$2}')
        fpath="\${dir}/\${rel_path}"
        if [[ ! -f "\${fpath}" ]]; then
            rlog "WARN" "  Missing: \${rel_path}"; (( errors++ )) || true; continue
        fi
        actual_hash=\$(sha256sum "\${fpath}" | awk '{print \$1}')
        if [[ "\${actual_hash}" != "\${expected_hash}" ]]; then
            rlog "WARN" "  Hash mismatch: \${rel_path}"; (( errors++ )) || true
        else
            rlog "INFO" "  Hash OK: \${rel_path} (\${actual_hash:0:12}...)"
        fi
    done < "\${manifest}"
    return \$(( errors > 0 ? 1 : 0 ))
}

RESTORE_SOURCE="" RESTORE_MANIFEST=""

if verify_source "\${BACKUP_CURRENT}" "\${CURRENT_MANIFEST}"; then
    RESTORE_SOURCE="\${BACKUP_CURRENT}"
    RESTORE_MANIFEST="\${CURRENT_MANIFEST}"
    ttylog "INFO" "Source verified: current/"
else
    rlog "WARN" "current/ failed — trying snapshots newest-first"
    mapfile -t SNAPS < <(ls -d "\${BACKUP_SNAPSHOTS}"/[0-9]* 2>/dev/null | sort -r)
    for snap in "\${SNAPS[@]}"; do
        snap_mf="\${snap}/snapshot.sha256"
        rlog "INFO" "Trying: \$(basename "\${snap}")"
        if verify_source "\${snap}" "\${snap_mf}"; then
            RESTORE_SOURCE="\${snap}"
            RESTORE_MANIFEST="\${snap_mf}"
            ttylog "INFO" "Source verified: snapshot \$(basename "\${snap}")"
            break
        else
            rlog "WARN" "Failed: \$(basename "\${snap}")"
        fi
    done
fi

if [[ -z "\${RESTORE_SOURCE}" ]]; then
    ttylog "ERROR" "No valid restore source found — all sources failed hash verification"
    ttylog "ERROR" "Manual intervention required — Plex will NOT start"
    exit 1
fi

# ── Restore files to ramdisk ──────────────────────────────────────────────────
ttylog "INFO" "Restoring DB files from \$(basename "\${RESTORE_SOURCE}") → ramdisk..."
mkdir -p "\${RAMDISK_DB_DIR}"
RSYNC_START=\$(date +%s)
rsync -av \
    --exclude="*.sha256" \
    --exclude="*.sha256.tmp" \
    --exclude="*.tmp" \
    "\${RESTORE_SOURCE}/" "\${RAMDISK_DB_DIR}/" >> "\${LOG_FILE}" 2>&1
RSYNC_EXIT=\$?
RSYNC_END=\$(date +%s)
ttylog "INFO" "DB files copied — \$(( RSYNC_END - RSYNC_START ))s"
rlog "INFO" "rsync: exit=\${RSYNC_EXIT}  duration=\$(( RSYNC_END - RSYNC_START ))s"

if [[ \${RSYNC_EXIT} -ne 0 ]]; then
    rlog "ERROR" "rsync failed (exit \${RSYNC_EXIT}) — aborting"
    exit "\${RSYNC_EXIT}"
fi

# ── Offload any dated backups that came from the snapshot ─────────────────────
ttylog "INFO" "Offloading dated backup files from ramdisk..."
offload_dated

# Remove stray sha256/tmp files that may have been rsync'd from current/
find "${RAMDISK_DB_DIR}" -maxdepth 1 -type f \
    \( -name "*.sha256" -o -name "*.sha256.tmp" -o -name "*.tmp" \) \
    -delete 2>/dev/null || true

# ── Hash verify destination ───────────────────────────────────────────────────
ttylog "INFO" "Verifying restored files (hash check)..."
VERIFY_ERRORS=0
while IFS= read -r line; do
    expected_hash=\$(echo "\${line}" | awk '{print \$1}')
    rel_path=\$(echo "\${line}" | awk '{print \$2}')
    fpath="${RAMDISK_DB_DIR}/\${rel_path}"
    if [[ ! -f "\${fpath}" ]]; then
        rlog "ERROR" "  Missing after restore: \${rel_path}"; (( VERIFY_ERRORS++ )) || true; continue
    fi
    actual_hash=\$(sha256sum "\${fpath}" | awk '{print \$1}')
    if [[ "\${actual_hash}" != "\${expected_hash}" ]]; then
        rlog "ERROR" "  Hash mismatch: \${rel_path}"; (( VERIFY_ERRORS++ )) || true
    else
        rlog "INFO" "  Verified: \${rel_path} (\${actual_hash:0:12}...)"
    fi
done < "\${RESTORE_MANIFEST}"

if (( VERIFY_ERRORS > 0 )); then
    ttylog "ERROR" "\${VERIFY_ERRORS} file(s) failed hash verification — aborting"
    exit 1
fi

chown -R "\${PLEX_USER}":"\${PLEX_USER}" "\${RAMDISK_DB_DIR}"
rlog_disk "restore end"

DURATION=\$(( \$(date +%s) - _RESTORE_START ))
rlog "INFO" "========================================================"
rlog "INFO" "RESTORE SUMMARY"
rlog "INFO" "  Result:      SUCCESS"
rlog "INFO" "  Source:      \$(basename "\${RESTORE_SOURCE}")"
rlog "INFO" "  Files:       \$(find "\${RAMDISK_DB_DIR}" -maxdepth 1 -type f | wc -l) on ramdisk"
rlog "INFO" "  DB backups:  \$(find "\${DB_BACKUP_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l) on disk"
rlog "INFO" "  Size:        \$(du -sh "\${RAMDISK_DB_DIR}" 2>/dev/null | awk '{print \$1}')"
rlog "INFO" "  Duration:    \${DURATION}s"
rlog "INFO" "  Journalctl:  journalctl -u plex-ramdisk-sync --since=\"\$(date -d "-\${DURATION} seconds" '+%Y-%m-%d %H:%M:%S')\""
ttylog "OK" "Restore complete — \${DURATION}s  source: \$(basename "\${RESTORE_SOURCE}")"
rlog "INFO" "========================================================"
RESTORE_EOF

    chmod +x "${RESTORE_SCRIPT}"
    THIS_RUN_CREATED_RESTORE_SCRIPT=true
    state_set "STEP_4_RESTORE_SCRIPT" "complete"
    log_ok "Restore script written: ${RESTORE_SCRIPT} (v${RESTORE_SCRIPT_VERSION})"
}

# ── Step 5: Backup script ─────────────────────────────────────────────────────
write_backup_script() {
    log_step "Step 5: Backup Script"
    local prev; prev=$(state_get "STEP_5_BACKUP_SCRIPT")
    if [[ "${prev}" == "complete" && -x "${BACKUP_SCRIPT}" ]]; then
        log_ok "Already installed — skipping."; return
    fi

    cat > "${BACKUP_SCRIPT}" << BACKUP_EOF
#!/usr/bin/env bash
# =============================================================================
# plex-ramdisk-backup.sh
# Version: ${BACKUP_SCRIPT_VERSION}
# Generated by: plex-ramdisk-setup.sh v${SETUP_VERSION}
# Generated on: $(date '+%Y-%m-%d %H:%M:%S')
# Changelog:
#   3.4.0 - Cron schedule changed to 04:30 (after Plex nightly
#            cleanup window); WAL warning messages updated to note
#            post-cleanup-window context
#   3.2.0 - Fixed script-level "local" declarations in source hashing and
#            destination verification loops; rsync excludes sha256/tmp;
#            belt-and-suspenders cleanup removes sha256/tmp from current/;
#            stray sha256/tmp removed from ramdisk before hashing
#   3.1.0 - Added ttylog() for console output during boot/shutdown
#   3.0.0 - Added WAL checkpoint wait; force-kill on timeout; manifest diff;
#            per-file hash verification; snapshot rotation
# Description:  Offloads dated Plex backup files from ramdisk, then syncs
#               active DB files to backup current/ with hash verification.
#               On scheduled runs creates a timestamped snapshot. Retains
#               ${SNAPSHOT_KEEP} snapshots. On shutdown: graceful stop → force kill
#               if needed → WAL checkpoint wait → sync.
# Log:          ${RUNTIME_LOG}
#
# Usage:
#   plex-ramdisk-backup.sh             # scheduled: offload + backup + snapshot
#   plex-ramdisk-backup.sh --shutdown  # shutdown: offload + sync only
# =============================================================================

SCRIPT_VERSION="${BACKUP_SCRIPT_VERSION}"
RAMDISK_MOUNT="${RAMDISK_MOUNT}"
RAMDISK_DB_DIR="${RAMDISK_DB_DIR}"
BACKUP_CURRENT="${BACKUP_CURRENT}"
BACKUP_SNAPSHOTS="${BACKUP_SNAPSHOTS}"
CURRENT_MANIFEST="${CURRENT_MANIFEST}"
DB_BACKUP_DIR="${DB_BACKUP_DIR}"
DATED_PATTERN="${DATED_PATTERN}"
SNAPSHOT_KEEP=${SNAPSHOT_KEEP}
PLEX_USER="${PLEX_USER}"
PLEX_SERVICE="${PLEX_SERVICE}"
LOG_FILE="${RUNTIME_LOG}"
ERROR_LOG="${ERROR_LOG}"
SHUTDOWN_GRACEFUL_TIMEOUT=${SHUTDOWN_GRACEFUL_TIMEOUT}
SHUTDOWN_WAL_TIMEOUT=${SHUTDOWN_WAL_TIMEOUT}

_ts()    { date '+%Y-%m-%d %H:%M:%S'; }
_BACKUP_START=\$(date +%s)
PREV_MANIFEST="\${CURRENT_MANIFEST}.prev"

# blog: detailed entries to log file only (and error log for WARN/ERROR)
blog() {
    local lvl="\$1"; shift
    local line="\$(_ts) [backup v\${SCRIPT_VERSION}] [\${lvl}] \$*"
    echo "\${line}" >> "\${LOG_FILE}"
    [[ "\${lvl}" == "ERROR" || "\${lvl}" == "WARN" ]] && \
        echo "\${line}" >> "\${ERROR_LOG}" 2>/dev/null || true
}

# ttylog: user-facing progress — writes to console AND log file
# Uses /dev/console for guaranteed terminal output during boot/shutdown
# when a normal TTY may not be available.
ttylog() {
    local lvl="\$1"; shift
    local msg="\$*"
    local prefix
    case "\${lvl}" in
        OK)    prefix="[  OK  ] Plex Ramdisk Backup:" ;;
        WARN)  prefix="[ WARN ] Plex Ramdisk Backup:" ;;
        ERROR) prefix="[FAILED] Plex Ramdisk Backup:" ;;
        *)     prefix="[      ] Plex Ramdisk Backup:" ;;
    esac
    echo "\${prefix} \${msg}" > /dev/console 2>/dev/null || echo "\${prefix} \${msg}" || true
    blog "\${lvl}" "\${msg}"
}

blog_disk() {
    local label="\${1:-disk}"
    local rd_used rd_avail bk_used bk_avail
    mountpoint -q "\${RAMDISK_MOUNT}" 2>/dev/null && \
        read -r rd_used rd_avail <<< "\$(df -k "\${RAMDISK_MOUNT}" | awk 'NR==2{print \$3, \$4}')" && \
        blog "INFO" "[\${label}] ramdisk: used=\$(( rd_used/1024 ))MB  avail=\$(( rd_avail/1024 ))MB"
    [[ -d "${BACKUP_ROOT}" ]] && \
        read -r bk_used bk_avail <<< "\$(df -k "${BACKUP_ROOT}" | awk 'NR==2{print \$3, \$4}')" && \
        blog "INFO" "[\${label}] backup disk: used=\$(( bk_used/1024 ))MB  avail=\$(( bk_avail/1024 ))MB"
}

blog_sizes() {
    local dir="\$1" label="\${2:-sizes}"
    [[ -d "\${dir}" ]] || return
    blog "INFO" "[\${label}] contents of \${dir}:"
    while IFS= read -r -d '' f; do
        local sz; sz=\$(du -sh "\${f}" 2>/dev/null | awk '{print \$1}')
        blog "INFO" "  \${sz}  \$(basename "\${f}")"
    done < <(find "\${dir}" -maxdepth 1 -type f -print0 | sort -z)
}

blog_manifest_diff() {
    local old_mf="\$1" new_mf="\$2"
    [[ -f "\${old_mf}" && -f "\${new_mf}" ]] || return
    blog "INFO" "Manifest diff (changed files since last backup):"
    local changed=0
    while IFS= read -r line; do
        local hash rel old_hash
        hash=\$(echo "\${line}" | awk '{print \$1}')
        rel=\$(echo "\${line}" | awk '{print \$2}')
        old_hash=\$(grep "  \${rel}\$" "\${old_mf}" 2>/dev/null | awk '{print \$1}' || echo "new")
        if [[ "\${hash}" != "\${old_hash}" ]]; then
            blog "INFO" "  CHANGED: \${rel}  (\${old_hash:0:12}... → \${hash:0:12}...)"
            (( changed++ ))
        fi
    done < "\${new_mf}"
    (( changed == 0 )) \
        && blog "INFO" "  No changes since last backup" \
        || blog "INFO" "  \${changed} file(s) changed"
}

# Offload dated backup files from ramdisk to disk
offload_dated() {
    mkdir -p "\${DB_BACKUP_DIR}"
    local moved=0 skipped=0
    while IFS= read -r -d '' f; do
        local fname dest; fname=\$(basename "\${f}"); dest="\${DB_BACKUP_DIR}/\${fname}"
        if [[ -f "\${dest}" ]]; then
            blog "INFO" "  Dated backup already on disk, removing: \${fname}"
            rm -f "\${f}"; (( skipped++ )) || true
        else
            blog "INFO" "  Offloading: \${fname}"
            mv "\${f}" "\${dest}"; (( moved++ ))
        fi
    done < <(find "\${RAMDISK_DB_DIR}" -maxdepth 1 -type f \
        -regex "\${DATED_PATTERN}" -print0 2>/dev/null | sort -z)
    blog "INFO" "Dated backup offload: \${moved} moved, \${skipped} already on disk"
    blog "INFO" "  DB backups on disk: \$(find "\${DB_BACKUP_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l) files"
}

SHUTDOWN_MODE=false
[[ "\${1:-}" == "--shutdown" ]] && SHUTDOWN_MODE=true
SNAPSHOT_NAME="\$(date '+%Y-%m-%d_%H-%M-%S')"
FORCE_KILLED=false

blog "INFO" "========================================================"
ttylog "INFO" "Starting — v\${SCRIPT_VERSION}  mode=\$(\$SHUTDOWN_MODE && echo shutdown || echo scheduled)"
blog "INFO" "  Host: \$(hostname)  PID: \$$"
blog_disk "backup start"

# ── Verify ramdisk ────────────────────────────────────────────────────────────
if ! mountpoint -q "\${RAMDISK_MOUNT}"; then
    ttylog "ERROR" "Ramdisk not mounted — aborting"; exit 1
fi
if [[ ! -d "\${RAMDISK_DB_DIR}" ]]; then
    ttylog "ERROR" "Ramdisk DB dir missing: \${RAMDISK_DB_DIR} — aborting"; exit 1
fi

# ── Offload dated backups first ───────────────────────────────────────────────
ttylog "INFO" "Offloading dated Plex backup files from ramdisk..."
offload_dated
blog_sizes "\${RAMDISK_DB_DIR}" "ramdisk after offload"

# ── Stop Plex ─────────────────────────────────────────────────────────────────
PLEX_WAS_ACTIVE=false
if systemctl is-active --quiet "\${PLEX_SERVICE}" 2>/dev/null; then
    PLEX_WAS_ACTIVE=true
    ttylog "INFO" "Stopping Plex for clean backup..."
    systemctl stop "\${PLEX_SERVICE}" 2>/dev/null || true
    WAITED=0
    while systemctl is-active --quiet "\${PLEX_SERVICE}" 2>/dev/null; do
        sleep 5; (( WAITED += 5 ))
        ttylog "INFO" "Waiting for Plex to stop... (\${WAITED}s / \${SHUTDOWN_GRACEFUL_TIMEOUT}s)"
        if (( WAITED >= SHUTDOWN_GRACEFUL_TIMEOUT )); then
            ttylog "WARN" "Graceful stop timed out — force killing Plex"
            systemctl kill --signal=SIGKILL "\${PLEX_SERVICE}" 2>/dev/null || true
            sleep 5; FORCE_KILLED=true; break
        fi
    done
    \$FORCE_KILLED \
        && ttylog "WARN" "Plex force-killed after \${WAITED}s" \
        || ttylog "INFO" "Plex stopped gracefully after \${WAITED}s"
else
    blog "INFO" "Plex is not running"
fi

# ── Wait for WAL checkpoint ───────────────────────────────────────────────────
ttylog "INFO" "Waiting for SQLite WAL checkpoint..."
WAL_WAITED=0 ALL_EMPTY=true
WAL_FILES=(
    "\${RAMDISK_DB_DIR}/com.plexapp.plugins.library.db-wal"
    "\${RAMDISK_DB_DIR}/com.plexapp.plugins.library.blobs.db-wal"
    "\${RAMDISK_DB_DIR}/com.plexapp.dlna.db-wal"
)
while true; do
    ALL_EMPTY=true
    for wal in "\${WAL_FILES[@]}"; do
        [[ -f "\${wal}" && -s "\${wal}" ]] && {
            ALL_EMPTY=false
            blog "INFO" "  WAL not empty: \$(basename "\${wal}") (\$(stat -c%s "\${wal}") bytes)"
        }
    done
    \$ALL_EMPTY && break
    sleep 2; (( WAL_WAITED += 2 ))
    if (( WAL_WAITED >= SHUTDOWN_WAL_TIMEOUT )); then
        ttylog "WARN" "WAL files not empty after \${WAL_WAITED}s — running after Plex cleanup window; may be genuinely stuck (SQLite will recover)"
        break
    fi
done
\$ALL_EMPTY && ttylog "INFO" "WAL checkpoint complete" \
           || blog "WARN" "Proceeding with non-empty WAL — running after Plex cleanup window; may be genuinely stuck"

# ── Remove stray sha256/tmp files from ramdisk before hashing ────────────────
find "${RAMDISK_DB_DIR}" -maxdepth 1 -type f \
    \( -name "*.sha256" -o -name "*.sha256.tmp" -o -name "*.tmp" \) \
    -delete 2>/dev/null || true

# ── Hash source files ─────────────────────────────────────────────────────────
blog "INFO" "Hashing ramdisk files..."
rel=""
hash=""
declare -A SRC_HASHES
while IFS= read -r -d '' f; do
    rel="\${f#\${RAMDISK_DB_DIR}/}"
    # Skip dated backup files
    [[ "\${f}" =~ \${DATED_PATTERN} ]] && continue
    hash=\$(sha256sum "\${f}" | awk '{print \$1}')
    SRC_HASHES["\${rel}"]="\${hash}"
    blog "INFO" "  \${rel} (\${hash:0:12}...)"
done < <(find "\${RAMDISK_DB_DIR}" -maxdepth 1 -type f -print0 | sort -z)

# ── Sync ramdisk → current/ ───────────────────────────────────────────────────
ttylog "INFO" "Syncing DB files ramdisk → backup..."
[[ -f "\${CURRENT_MANIFEST}" ]] && cp "\${CURRENT_MANIFEST}" "\${PREV_MANIFEST}"

RSYNC_START=\$(date +%s)
rsync -av --delete \
    --exclude="*.sha256" \
    --exclude="*.sha256.tmp" \
    --exclude="*.tmp" \
    --filter="- *-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*" \
    "\${RAMDISK_DB_DIR}/" "\${BACKUP_CURRENT}/" >> "\${LOG_FILE}" 2>&1
RSYNC_EXIT=\$?
RSYNC_END=\$(date +%s)
ttylog "INFO" "Sync complete — \$(( RSYNC_END - RSYNC_START ))s"
blog "INFO" "rsync: exit=\${RSYNC_EXIT}  duration=\$(( RSYNC_END - RSYNC_START ))s"

if [[ \${RSYNC_EXIT} -ne 0 ]]; then
    blog "ERROR" "rsync failed (exit \${RSYNC_EXIT})"
    \$PLEX_WAS_ACTIVE && systemctl start "\${PLEX_SERVICE}" 2>/dev/null || true
    exit "\${RSYNC_EXIT}"
fi

# Belt-and-suspenders: remove dated and stray sha256/tmp files from current/
find "\${BACKUP_CURRENT}" -maxdepth 1 -type f \
    \( -name "*.sha256" -o -name "*.sha256.tmp" -o -name "*.tmp" \
       -o -regex "\${DATED_PATTERN}" \) \
    -delete 2>/dev/null || true

# ── Verify destination ────────────────────────────────────────────────────────
blog "INFO" "Verifying destination hashes..."
dest_file=""
dest_hash=""
DEST_ERRORS=0
for rel in "\${!SRC_HASHES[@]}"; do
    dest_file="\${BACKUP_CURRENT}/\${rel}"
    if [[ ! -f "\${dest_file}" ]]; then
        blog "ERROR" "  Missing in current/: \${rel}"; (( DEST_ERRORS++ )); continue
    fi
    dest_hash=\$(sha256sum "\${dest_file}" | awk '{print \$1}')
    if [[ "\${dest_hash}" != "\${SRC_HASHES[\${rel}]}" ]]; then
        blog "ERROR" "  Hash mismatch: \${rel}"; (( DEST_ERRORS++ ))
    else
        blog "INFO" "  Verified: \${rel} (\${dest_hash:0:12}...)"
    fi
done

if (( DEST_ERRORS > 0 )); then
    ttylog "ERROR" "\${DEST_ERRORS} file(s) failed hash verification — backup NOT saved"
    \$PLEX_WAS_ACTIVE && systemctl start "\${PLEX_SERVICE}" 2>/dev/null || true
    exit 1
fi

# ── Write manifest ────────────────────────────────────────────────────────────
blog "INFO" "Writing manifest..."
: > "\${CURRENT_MANIFEST}.tmp"
for rel in "\${!SRC_HASHES[@]}"; do
    echo "\${SRC_HASHES[\${rel}]}  \${rel}" >> "\${CURRENT_MANIFEST}.tmp"
done
sort "\${CURRENT_MANIFEST}.tmp" > "\${CURRENT_MANIFEST}"
rm -f "\${CURRENT_MANIFEST}.tmp"
chown -R "\${PLEX_USER}":"\${PLEX_USER}" "\${BACKUP_CURRENT}"
ttylog "OK" "Backup verified and saved"

[[ -f "\${PREV_MANIFEST}" ]] && blog_manifest_diff "\${PREV_MANIFEST}" "\${CURRENT_MANIFEST}"
blog_sizes "\${BACKUP_CURRENT}" "current/ after sync"
blog_disk "after sync"

# ── Restart Plex ──────────────────────────────────────────────────────────────
if \$PLEX_WAS_ACTIVE; then
    ttylog "INFO" "Restarting Plex..."
    systemctl start "\${PLEX_SERVICE}" 2>/dev/null \
        && ttylog "OK" "Plex restarted" \
        || ttylog "WARN" "Plex restart failed — run: systemctl start plexmediaserver"
fi

# ── Shutdown mode summary and exit ────────────────────────────────────────────
if \$SHUTDOWN_MODE; then
    DURATION=\$(( \$(date +%s) - _BACKUP_START ))
    blog_disk "shutdown end"
    blog "INFO" "========================================================"
    blog "INFO" "BACKUP SUMMARY (shutdown)"
    blog "INFO" "  Result:        SUCCESS"
    blog "INFO" "  Plex stopped:  \${PLEX_WAS_ACTIVE}  force_killed=\${FORCE_KILLED}"
    blog "INFO" "  WAL cleared:   \${ALL_EMPTY}"
    blog "INFO" "  DB backups:    \$(find "\${DB_BACKUP_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l) files on disk"
    blog "INFO" "  Duration:      \${DURATION}s"
    blog "INFO" "  Snapshot:      skipped (shutdown mode)"
    ttylog "OK" "Shutdown backup complete — \${DURATION}s"
    blog "INFO" "Backup complete"
    blog "INFO" "========================================================"
    LOG_LINES=\$(wc -l < "\${LOG_FILE}" 2>/dev/null || echo 0)
    if (( LOG_LINES > 5000 )); then
        tail -n 4999 "\${LOG_FILE}" > "\${LOG_FILE}.tmp"
        echo "\$(_ts) [backup v\${SCRIPT_VERSION}] [INFO] --- log rotated ---" >> "\${LOG_FILE}.tmp"
        mv "\${LOG_FILE}.tmp" "\${LOG_FILE}"
    fi
    exit 0
fi

# ── Create timestamped snapshot ───────────────────────────────────────────────
SNAPSHOT_DIR="\${BACKUP_SNAPSHOTS}/\${SNAPSHOT_NAME}"
SNAPSHOT_MANIFEST="\${SNAPSHOT_DIR}/snapshot.sha256"
ttylog "INFO" "Creating snapshot: \${SNAPSHOT_NAME}"
mkdir -p "\${SNAPSHOT_DIR}"
cp -al "\${BACKUP_CURRENT}/." "\${SNAPSHOT_DIR}/"
cp "\${CURRENT_MANIFEST}" "\${SNAPSHOT_MANIFEST}"
chown -R "\${PLEX_USER}":"\${PLEX_USER}" "\${SNAPSHOT_DIR}"
ttylog "OK" "Snapshot saved: \${SNAPSHOT_NAME}"

# ── Prune old snapshots ───────────────────────────────────────────────────────
mapfile -t SNAPS < <(ls -d "\${BACKUP_SNAPSHOTS}"/[0-9]* 2>/dev/null | sort)
SNAP_COUNT=\${#SNAPS[@]}
blog "INFO" "Snapshot count: \${SNAP_COUNT}/\${SNAPSHOT_KEEP}"
if (( SNAP_COUNT > SNAPSHOT_KEEP )); then
    PRUNE_COUNT=\$(( SNAP_COUNT - SNAPSHOT_KEEP ))
    blog "INFO" "Pruning \${PRUNE_COUNT} old snapshot(s)"
    for (( i=0; i<PRUNE_COUNT; i++ )); do
        blog "INFO" "  Removing: \$(basename "\${SNAPS[\$i]}")"
        rm -rf "\${SNAPS[\$i]}"
    done
fi
REMAINING=\$(ls -d "\${BACKUP_SNAPSHOTS}"/[0-9]* 2>/dev/null | wc -l)
blog "OK" "Snapshots retained: \${REMAINING}/\${SNAPSHOT_KEEP}"

# ── Run summary ───────────────────────────────────────────────────────────────
DURATION=\$(( \$(date +%s) - _BACKUP_START ))
blog_disk "backup end"
blog "INFO" "========================================================"
blog "INFO" "BACKUP SUMMARY"
blog "INFO" "  Result:        SUCCESS"
blog "INFO" "  Plex stopped:  \${PLEX_WAS_ACTIVE}  force_killed=\${FORCE_KILLED}"
blog "INFO" "  WAL cleared:   \${ALL_EMPTY}"
blog "INFO" "  Files synced:  \$(find "\${BACKUP_CURRENT}" -maxdepth 1 -type f ! -name "*.sha256" | wc -l)"
blog "INFO" "  Backup size:   \$(du -sh "\${BACKUP_CURRENT}" 2>/dev/null | awk '{print \$1}')"
blog "INFO" "  Snapshots:     \${REMAINING}/\${SNAPSHOT_KEEP}"
blog "INFO" "  DB backups:    \$(find "\${DB_BACKUP_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l) files on disk"
blog "INFO" "  Duration:      \${DURATION}s"
blog "INFO" "  Journalctl:    journalctl -u plex-ramdisk-sync --since=\"\$(date -d "-\${DURATION} seconds" '+%Y-%m-%d %H:%M:%S')\""
ttylog "OK" "Scheduled backup complete — \${DURATION}s  snapshot: \${SNAPSHOT_NAME}"
blog "INFO" "Backup complete"
blog "INFO" "========================================================"

LOG_LINES=\$(wc -l < "\${LOG_FILE}" 2>/dev/null || echo 0)
if (( LOG_LINES > 5000 )); then
    tail -n 4999 "\${LOG_FILE}" > "\${LOG_FILE}.tmp"
    echo "\$(_ts) [backup v\${SCRIPT_VERSION}] [INFO] --- log rotated ---" >> "\${LOG_FILE}.tmp"
    mv "\${LOG_FILE}.tmp" "\${LOG_FILE}"
fi
BACKUP_EOF

    chmod +x "${BACKUP_SCRIPT}"
    THIS_RUN_CREATED_BACKUP_SCRIPT=true
    state_set "STEP_5_BACKUP_SCRIPT" "complete"
    log_ok "Backup script written: ${BACKUP_SCRIPT} (v${BACKUP_SCRIPT_VERSION})"
}

# ── Step 6: Systemd unit + Plex drop-in ──────────────────────────────────────
write_systemd_unit() {
    log_step "Step 6: Systemd Unit + Plex Drop-in"
    local prev_unit; prev_unit=$(state_get "STEP_6_SYSTEMD_UNIT")
    local prev_dropin; prev_dropin=$(state_get "STEP_6_SYSTEMD_DROPIN")

    if [[ "${prev_unit}" != "complete" || ! -f "${SYSTEMD_UNIT_FILE}" ]]; then
        cat > "${SYSTEMD_UNIT_FILE}" << UNIT_EOF
[Unit]
Description=Plex Ramdisk Sync (restore on boot, backup on shutdown)
After=local-fs.target
Before=umount.target ${PLEX_SERVICE}.service
Wants=${PLEX_SERVICE}.service

[Service]
Type=oneshot
User=root
StandardOutput=journal+console
StandardError=journal+console
ExecStart=${RESTORE_SCRIPT}
ExecStop=${BACKUP_SCRIPT} --shutdown
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
        THIS_RUN_CREATED_UNIT=true
        state_set "STEP_6_SYSTEMD_UNIT" "complete"
        log_ok "plex-ramdisk-sync.service written."
    else
        log_ok "plex-ramdisk-sync.service already installed — skipping."
    fi

    if [[ "${prev_dropin}" != "complete" || ! -f "${SYSTEMD_DROPIN_FILE}" ]]; then
        mkdir -p "${SYSTEMD_DROPIN_DIR}"
        cat > "${SYSTEMD_DROPIN_FILE}" << DROPIN_EOF
# Generated by plex-ramdisk-setup.sh v${SETUP_VERSION}
# Ensures Plex waits for ramdisk restore before starting,
# with a ${PLEX_BOOT_DELAY}s buffer for timing safety.
[Unit]
After=plex-ramdisk-sync.service
Requires=plex-ramdisk-sync.service

[Service]
ExecStartPre=/bin/sleep ${PLEX_BOOT_DELAY}
DROPIN_EOF
        THIS_RUN_CREATED_DROPIN=true
        state_set "STEP_6_SYSTEMD_DROPIN" "complete"
        log_ok "Plex drop-in written: ${SYSTEMD_DROPIN_FILE}"
    else
        log_ok "Plex drop-in already installed — skipping."
    fi

    systemctl daemon-reload
    systemctl enable plex-ramdisk-sync.service
    log_ok "Services reloaded and plex-ramdisk-sync.service enabled."
}

# ── Step 7: Cron job ──────────────────────────────────────────────────────────
write_cron_job() {
    log_step "Step 7: Cron Job (daily 04:30)"
    local prev; prev=$(state_get "STEP_7_CRON")
    if [[ "${prev}" == "complete" && -f "${CRON_FILE}" ]]; then
        log_ok "Already installed — skipping."; return
    fi

    cat > "${CRON_FILE}" << CRON_EOF
# Plex ramdisk snapshot — generated by plex-ramdisk-setup.sh v${SETUP_VERSION}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Offloads dated DB backups, syncs active files, creates timestamped snapshot
# Retains ${SNAPSHOT_KEEP} snapshots maximum
30 4 * * * root ${BACKUP_SCRIPT} >> "${RUNTIME_LOG}" 2>&1
CRON_EOF

    chmod 644 "${CRON_FILE}"
    THIS_RUN_CREATED_CRON=true
    state_set "STEP_7_CRON" "complete"
    log_ok "Cron job installed: ${CRON_FILE}"

    if ! $DRY_RUN; then
        _write_logrotate_config
        log_ok "Logrotate config installed: /etc/logrotate.d/plex-ramdisk"
    else
        log_dry "write /etc/logrotate.d/plex-ramdisk"
    fi
}

# ── Step 8: Watchdog (future feature) ────────────────────────────────────────
# TODO: Implement database crash watchdog service
#
# The watchdog will monitor the Plex log after startup for SQLite error
# patterns and automatically attempt recovery from snapshots.
#
# Planned behavior:
#   - Starts as a separate systemd service after plexmediaserver.service
#   - Tails: ${PLEX_BASE}/Logs/Plex Media Server.log
#   - Watches for: SQLITE_CORRUPT, SQLITE_IOERR, "database disk image is
#     malformed", "no such table", "database is locked", "unable to open
#     database", "SQLite error", "Failed to open database"
#   - On match:
#       1. Stop Plex
#       2. Run sqlite3 integrity check on ramdisk DB files
#       3. If integrity OK: restart Plex (may be transient)
#       4. If integrity fails: restore from most recent valid snapshot
#       5. If crash repeats within cooldown: try next snapshot
#       6. After max attempts: log critical, write flag file, halt restarts
#   - Cooldown: 10 minutes  Max attempts: 3
#
# New files when implemented:
#   /usr/local/bin/plex-ramdisk-watchdog.sh
#   /lib/systemd/system/plex-ramdisk-watchdog.service
#   /var/lib/plex-ramdisk/watchdog.state
#
# Prerequisites: sqlite3 (apt install sqlite3), notification method chosen
# State key reserved: STEP_8_WATCHDOG
# =============================================================================
setup_watchdog() {
    log_step "Step 8: Database Crash Watchdog (Future Feature)"
    log_warn "Watchdog is a planned future feature — skipping."
    log_info "See setup_watchdog() in this script for implementation plan."
    state_set "STEP_8_WATCHDOG" "pending"
}

# ── Step 9: DB backup pruning (future feature) ────────────────────────────────
# TODO: Implement retention policy for dated DB backups in DB_BACKUP_DIR
#
# Planned behavior:
#   - Configurable retention period (e.g. keep last 30 days)
#   - Run as part of the daily cron job after offload_dated()
#   - Log each file pruned with its age
#   - Separate --prune-db-backups flag for manual invocation
#
# State key reserved: STEP_9_DB_BACKUP_PRUNING
# DB_BACKUP_DIR: ${DB_BACKUP_DIR}
# =============================================================================
setup_db_backup_pruning() {
    log_step "Step 9: Dated DB Backup Pruning (Future Feature)"
    log_warn "DB backup pruning is a planned future feature — skipping."
    log_info "Dated backups accumulate in: ${DB_BACKUP_DIR}"
    log_info "See setup_db_backup_pruning() in this script for implementation plan."
    state_set "STEP_9_DB_BACKUP_PRUNING" "pending"
}

# ── Step 10: Verification ─────────────────────────────────────────────────────
verify_setup() {
    log_step "Step 10: Verification"
    local errors=0

    # ── File & Directory Checks ───────────────────────────────────────────────
    log_info "Checking installed files and directories..."

    if [[ -d "${RAMDISK_DB_DIR}" ]]; then
        local rd_count rd_size
        rd_count=$(find "${RAMDISK_DB_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]')
        rd_size=$(du -sh "${RAMDISK_DB_DIR}" 2>/dev/null | awk '{print $1}')
        log_ok "Ramdisk DB dir: ${rd_count} file(s)  ${rd_size}"
    else
        log_error "Ramdisk DB dir missing: ${RAMDISK_DB_DIR}"; (( errors++ )) || true
    fi

    if [[ -L "${PLEX_DB_SYMLINK}" ]]; then
        local link_target; link_target=$(readlink -f "${PLEX_DB_SYMLINK}")
        if [[ "${link_target}" == "${RAMDISK_DB_DIR}" ]]; then
            log_ok "Databases symlink → ${RAMDISK_DB_DIR}"
        else
            log_warn "Databases symlink points to wrong target: ${link_target}"
            (( errors++ )) || true
        fi
    else
        log_error "Databases symlink missing: ${PLEX_DB_SYMLINK}"; (( errors++ )) || true
    fi

    if [[ -f "${CURRENT_MANIFEST}" ]]; then
        local entries; entries=$(wc -l < "${CURRENT_MANIFEST}" | tr -d '[:space:]')
        log_ok "Hash manifest: ${entries} entries"
    else
        log_warn "Hash manifest missing."; (( errors++ )) || true
    fi

    if [[ -d "${DB_BACKUP_DIR}" ]]; then
        local dated_count; dated_count=$(find "${DB_BACKUP_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]')
        log_ok "DB backup dir: ${dated_count} dated file(s) on disk"
    else
        log_warn "DB backup dir missing."; (( errors++ )) || true
    fi

    if [[ -x "${BACKUP_SCRIPT}" ]]; then
        local bak_ver; bak_ver=$(grep -m1 "^# Version:" "${BACKUP_SCRIPT}" | awk '{print $3}')
        log_ok "Backup script: v${bak_ver}  ${BACKUP_SCRIPT}"
    else
        log_warn "Backup script missing or not executable."; (( errors++ )) || true
    fi

    if [[ -x "${RESTORE_SCRIPT}" ]]; then
        local rst_ver; rst_ver=$(grep -m1 "^# Version:" "${RESTORE_SCRIPT}" | awk '{print $3}')
        log_ok "Restore script: v${rst_ver}  ${RESTORE_SCRIPT}"
    else
        log_warn "Restore script missing or not executable."; (( errors++ )) || true
    fi

    if [[ -f "${CRON_FILE}" ]]; then
        log_ok "Cron job: ${CRON_FILE}"
    else
        log_warn "Cron job missing."; (( errors++ )) || true
    fi

    if [[ -f "${STATE_FILE}" ]]; then
        log_ok "State file: ${STATE_FILE}"
    else
        log_warn "State file missing."; (( errors++ )) || true
    fi

    # ── Script Syntax Validation ──────────────────────────────────────────────
    log_info "Validating installed script syntax..."

    if [[ -f "${BACKUP_SCRIPT}" ]]; then
        if bash -n "${BACKUP_SCRIPT}" 2>/dev/null; then
            log_ok "Backup script syntax: OK"
        else
            log_error "Backup script has syntax errors — run: bash -n ${BACKUP_SCRIPT}"
            (( errors++ )) || true
        fi
    fi

    if [[ -f "${RESTORE_SCRIPT}" ]]; then
        if bash -n "${RESTORE_SCRIPT}" 2>/dev/null; then
            log_ok "Restore script syntax: OK"
        else
            log_error "Restore script has syntax errors — run: bash -n ${RESTORE_SCRIPT}"
            (( errors++ )) || true
        fi
    fi

    # Check for known bad pattern: local used at script level in restore script
    if [[ -f "${RESTORE_SCRIPT}" ]]; then
        local bad_local_count
        bad_local_count=$(grep -c "^    local expected_hash\|^    local rel_path\|^    local fpath"             "${RESTORE_SCRIPT}" 2>/dev/null || echo 0)
        if (( bad_local_count == 0 )); then
            log_ok "Restore script: no script-level 'local' declarations found"
        else
            log_error "Restore script: ${bad_local_count} script-level 'local' declaration(s) — will cause failure"
            log_error "  Fix: sudo bash ${SCRIPT_NAME} --fix"
            (( errors++ )) || true
        fi
    fi

    # ── Systemd Service Validation ────────────────────────────────────────────
    log_info "Validating systemd services..."

    # plex-ramdisk-sync.service — enabled and unit file content
    if systemctl is-enabled --quiet plex-ramdisk-sync.service 2>/dev/null; then
        log_ok "plex-ramdisk-sync.service: enabled"
    else
        log_warn "plex-ramdisk-sync.service: NOT enabled"; (( errors++ )) || true
    fi

    if [[ -f "${SYSTEMD_UNIT_FILE}" ]]; then
        local unit_ok=true
        grep -q "ExecStart=${RESTORE_SCRIPT}"          "${SYSTEMD_UNIT_FILE}" || unit_ok=false
        grep -q "ExecStop=${BACKUP_SCRIPT} --shutdown" "${SYSTEMD_UNIT_FILE}" || unit_ok=false
        grep -q "StandardOutput=journal+console"       "${SYSTEMD_UNIT_FILE}" || unit_ok=false
        grep -q "RemainAfterExit=yes"                  "${SYSTEMD_UNIT_FILE}" || unit_ok=false
        if $unit_ok; then
            log_ok "plex-ramdisk-sync.service: unit file directives verified"
        else
            log_warn "plex-ramdisk-sync.service: unit file missing expected directives"
            (( errors++ )) || true
        fi
    else
        log_error "plex-ramdisk-sync.service: unit file missing: ${SYSTEMD_UNIT_FILE}"
        (( errors++ )) || true
    fi

    # Test the sync service can actually be started
    # (it will run restore — safe since files are already on ramdisk)
    log_info "Testing plex-ramdisk-sync.service start..."
    if systemctl is-active --quiet plex-ramdisk-sync.service 2>/dev/null; then
        log_ok "plex-ramdisk-sync.service: already active"
    else
        # Attempt to start it and wait up to 120s for it to complete
        systemctl start plex-ramdisk-sync.service 2>/dev/null &
        local svc_pid=$!
        local svc_waited=0
        while ! systemctl is-active --quiet plex-ramdisk-sync.service 2>/dev/null               && ! systemctl is-failed --quiet plex-ramdisk-sync.service 2>/dev/null; do
            sleep 2
            (( svc_waited += 2 )) || true
            if (( svc_waited >= 120 )); then break; fi
        done
        wait "${svc_pid}" 2>/dev/null || true

        if systemctl is-active --quiet plex-ramdisk-sync.service 2>/dev/null; then
            log_ok "plex-ramdisk-sync.service: started successfully (${svc_waited}s)"
        elif systemctl is-failed --quiet plex-ramdisk-sync.service 2>/dev/null; then
            log_error "plex-ramdisk-sync.service: FAILED to start"
            log_error "  Check: journalctl -u plex-ramdisk-sync -n 20"
            (( errors++ )) || true
        else
            log_warn "plex-ramdisk-sync.service: status unclear after ${svc_waited}s"
            (( errors++ )) || true
        fi
    fi

    # Plex drop-in — file and directive check
    if [[ -f "${SYSTEMD_DROPIN_FILE}" ]]; then
        local dropin_ok=true
        grep -q "Requires=plex-ramdisk-sync.service" "${SYSTEMD_DROPIN_FILE}" || dropin_ok=false
        grep -q "After=plex-ramdisk-sync.service"    "${SYSTEMD_DROPIN_FILE}" || dropin_ok=false
        grep -q "ExecStartPre=/bin/sleep"             "${SYSTEMD_DROPIN_FILE}" || dropin_ok=false
        if $dropin_ok; then
            log_ok "Plex drop-in: directives verified"
        else
            log_warn "Plex drop-in: missing expected directives"
            (( errors++ )) || true
        fi
    else
        log_warn "Plex drop-in missing: ${SYSTEMD_DROPIN_FILE}"; (( errors++ )) || true
    fi

    # ── Plex Service ──────────────────────────────────────────────────────────
    log_info "Starting Plex Media Server..."
    if systemctl is-active --quiet "${PLEX_SERVICE}" 2>/dev/null; then
        log_ok "Plex service: already running"
    else
        systemctl start "${PLEX_SERVICE}" 2>/dev/null
        local plex_waited=0
        while ! systemctl is-active --quiet "${PLEX_SERVICE}" 2>/dev/null; do
            sleep 2
            (( plex_waited += 2 )) || true
            if (( plex_waited >= 30 )); then break; fi
        done
        if systemctl is-active --quiet "${PLEX_SERVICE}" 2>/dev/null; then
            log_ok "Plex service: started successfully (${plex_waited}s)"
        else
            log_warn "Plex service did not start within 30s"
            log_warn "  Check: journalctl -u ${PLEX_SERVICE} -n 20"
            (( errors++ )) || true
        fi
    fi

    # ── Hash Verification ─────────────────────────────────────────────────────
    log_info "Verifying backup manifest..."
    if [[ -f "${CURRENT_MANIFEST}" ]]; then
        local hash_errors=0 hash_ok=0
        local vh_expected vh_rel vh_actual vh_path
        while IFS= read -r vline; do
            vh_expected=$(echo "${vline}" | awk '{print $1}')
            vh_rel=$(echo "${vline}" | awk '{print $2}')
            vh_path="${BACKUP_CURRENT}/${vh_rel}"
            if [[ ! -f "${vh_path}" ]]; then
                log_warn "  Manifest: missing from current/: ${vh_rel}"
                (( hash_errors++ )) || true
                continue
            fi
            vh_actual=$(sha256sum "${vh_path}" | awk '{print $1}')
            if [[ "${vh_actual}" == "${vh_expected}" ]]; then
                (( hash_ok++ )) || true
            else
                log_warn "  Manifest: hash mismatch: ${vh_rel}"
                (( hash_errors++ )) || true
            fi
        done < "${CURRENT_MANIFEST}"
        if (( hash_errors == 0 )); then
            log_ok "Backup manifest: ${hash_ok} file(s) verified"
        else
            log_warn "Backup manifest: ${hash_errors} file(s) failed verification"
            (( errors++ )) || true
        fi
    fi

    echo ""
    if (( errors == 0 )); then
        echo -e "${GREEN}${BOLD}✔ All checks passed.${NC}"
        _slog "OK" "Verification passed"
    elif (( errors == 1 )); then
        # Plex not running is expected — it was inactive before setup
        log_warn "${errors} check needs attention (Plex not running is expected if it was inactive before setup)."
        _slog "WARN" "Verification: ${errors} issue(s)"
    else
        log_warn "${errors} check(s) need attention."
        _slog "WARN" "Verification: ${errors} issue(s)"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Plex Ramdisk Setup — Complete  (v${SETUP_VERSION})${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Ramdisk DB dir:      ${RAMDISK_DB_DIR}"
    echo -e "  Databases symlink:   ${PLEX_DB_SYMLINK} → ${RAMDISK_DB_DIR}"
    echo -e "  Dated DB backups:    ${DB_BACKUP_DIR}"
    echo -e "  Backup current/:     ${BACKUP_CURRENT}"
    echo -e "  Hash manifest:       ${CURRENT_MANIFEST}"
    echo -e "  Snapshots/:          ${BACKUP_SNAPSHOTS}  (max ${SNAPSHOT_KEEP})"
    echo -e "  State file:          ${STATE_FILE}"
    echo -e "  Setup log:           ${SETUP_LOG}"
    echo -e "  Runtime log:         ${RUNTIME_LOG}"
    echo -e "  Error log:           ${ERROR_LOG}"
    echo -e "  Systemd unit:        plex-ramdisk-sync.service"
    echo -e "  Plex drop-in:        ${SYSTEMD_DROPIN_FILE}"
    echo -e "    Boot delay:        ${PLEX_BOOT_DELAY}s after restore completes"
    echo -e "  Cron schedule:       Daily 04:30"
    echo ""
    echo -e "  ${BOLD}Installed scripts:${NC}"
    echo -e "    ${BACKUP_SCRIPT}  (v${BACKUP_SCRIPT_VERSION})"
    echo -e "    ${RESTORE_SCRIPT} (v${RESTORE_SCRIPT_VERSION})"
    echo ""
    echo -e "  ${BOLD}Useful commands:${NC}"
    echo -e "    Setup status:      sudo bash ${SCRIPT_NAME} --status"
    echo -e "    Health summary:    sudo bash ${SCRIPT_NAME} --summary"
    echo -e "    Deep validation:   sudo bash ${SCRIPT_NAME} --validate"
    echo -e "    Auto repair:       sudo bash ${SCRIPT_NAME} --fix"
    echo -e "    Manual backup:     sudo ${BACKUP_SCRIPT}"
    echo -e "    Manual restore:    sudo ${RESTORE_SCRIPT}"
    echo -e "    Verify manifest:   sha256sum -c ${CURRENT_MANIFEST}"
    echo -e "    View runtime log:  tail -f ${RUNTIME_LOG}"
    echo -e "    View error log:    tail -f ${ERROR_LOG}"
    echo -e "    View setup log:    tail -f ${SETUP_LOG}"
    echo -e "    List snapshots:    ls -lh ${BACKUP_SNAPSHOTS}"
    echo -e "    List DB backups:   ls -lh ${DB_BACKUP_DIR}"
    echo -e "    Service status:    systemctl status plex-ramdisk-sync"
    echo -e "    Plex logs:         journalctl -u ${PLEX_SERVICE} -f"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

# ── Validate & Fix ────────────────────────────────────────────────────────────
# --validate: deep content check of all installed components
# --fix:      runs validate first, then repairs anything broken
#
# VALIDATE_ISSUES array accumulates issues found during validation.
# Each entry format: "SEVERITY|COMPONENT|DESCRIPTION|FIX_KEY"
#   SEVERITY: ERROR | WARN | INFO
#   FIX_KEY:  key used by fix_setup() to identify the repair action

VALIDATE_ISSUES=()
VALIDATE_ERRORS=0
VALIDATE_WARNS=0

_vlog() {
    local sev="$1" comp="$2" msg="$3" fix_key="${4:-none}"
    case "${sev}" in
        ERROR) (( VALIDATE_ERRORS++ )) || true ;;
        WARN)  (( VALIDATE_WARNS++  )) || true ;;
    esac
    VALIDATE_ISSUES+=("${sev}|${comp}|${msg}|${fix_key}")
    _slog "${sev}" "VALIDATE [${comp}] ${msg}"
}

_vok() {
    local comp="$1" msg="$2"
    printf "  ${GREEN}[  OK  ]${NC}  %-30s %s\n" "${comp}" "${msg}"
    _slog "OK" "VALIDATE [${comp}] ${msg}"
}

_vprint_issue() {
    local sev="$1" comp="$2" msg="$3"
    case "${sev}" in
        ERROR) printf "  ${RED}[FAILED]${NC}  %-30s %s\n" "${comp}" "${msg}" ;;
        WARN)  printf "  ${YELLOW}[ WARN ]${NC}  %-30s %s\n" "${comp}" "${msg}" ;;
        INFO)  printf "  ${BLUE}[ INFO ]${NC}  %-30s %s\n" "${comp}" "${msg}" ;;
    esac
}

validate_setup() {
    local FIX_MODE="${1:-false}"  # true when called from fix_setup
    VALIDATE_ISSUES=()
    VALIDATE_ERRORS=0
    VALIDATE_WARNS=0

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Plex Ramdisk — Deep Validation  (v${SETUP_VERSION})${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # ── Ramdisk & Symlink ─────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Ramdisk & Symlink${NC}"

    if mountpoint -q "${RAMDISK_MOUNT}" 2>/dev/null; then
        _vok "Ramdisk mount" "${RAMDISK_MOUNT} is mounted"
    else
        _vlog "ERROR" "Ramdisk mount" "${RAMDISK_MOUNT} is NOT mounted" "remount_ramdisk"
        _vprint_issue "ERROR" "Ramdisk mount" "${RAMDISK_MOUNT} is NOT mounted"
    fi

    if [[ -d "${RAMDISK_DB_DIR}" ]]; then
        local rd_count; rd_count=$(find "${RAMDISK_DB_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]')
        local rd_size; rd_size=$(du -sh "${RAMDISK_DB_DIR}" 2>/dev/null | awk '{print $1}')
        _vok "Ramdisk DB dir" "${rd_count} file(s)  ${rd_size}"
    else
        _vlog "ERROR" "Ramdisk DB dir" "Missing: ${RAMDISK_DB_DIR}" "restore_ramdisk"
        _vprint_issue "ERROR" "Ramdisk DB dir" "Missing: ${RAMDISK_DB_DIR}"
    fi

    if [[ -L "${PLEX_DB_SYMLINK}" ]]; then
        local link_target; link_target=$(readlink -f "${PLEX_DB_SYMLINK}" 2>/dev/null)
        if [[ "${link_target}" == "${RAMDISK_DB_DIR}" ]]; then
            _vok "Databases symlink" "→ ${RAMDISK_DB_DIR}"
        else
            _vlog "ERROR" "Databases symlink" "Points to ${link_target} (expected ${RAMDISK_DB_DIR})" "fix_symlink"
            _vprint_issue "ERROR" "Databases symlink" "Wrong target: ${link_target}"
        fi
        # Symlink ownership note: on Linux, symlink ownership is not enforced
        # by the kernel for access control — only the target directory matters.
        # chown -h may not work if the symlink is on a tmpfs filesystem.
        # We verify the target directory ownership instead.
        local target_owner; target_owner=$(stat -c "%U:%G" "${RAMDISK_DB_DIR}" 2>/dev/null)
        if [[ "${target_owner}" == "${PLEX_USER}:${PLEX_USER}" ]]; then
            _vok "DB dir ownership" "Target ${RAMDISK_DB_DIR} owned by ${target_owner}"
        else
            _vlog "WARN" "DB dir ownership" "Target owned by ${target_owner} (expected ${PLEX_USER}:${PLEX_USER})" "fix_db_ownership"
            _vprint_issue "WARN" "DB dir ownership" "Target owned by ${target_owner} — should be ${PLEX_USER}:${PLEX_USER}"
        fi
        # Verify the symlink target is actually on the ramdisk
        if mountpoint -q "${RAMDISK_MOUNT}" 2>/dev/null; then
            local real_path; real_path=$(readlink -f "${PLEX_DB_SYMLINK}" 2>/dev/null)
            if [[ "${real_path}" == "${RAMDISK_MOUNT}"* ]]; then
                _vok "Symlink on ramdisk" "Target confirmed on ${RAMDISK_MOUNT}"
            else
                _vlog "ERROR" "Symlink on ramdisk" "Target ${real_path} is not on ramdisk" "fix_symlink"
                _vprint_issue "ERROR" "Symlink on ramdisk" "Target not on ramdisk"
            fi
        fi
    else
        _vlog "ERROR" "Databases symlink" "Not a symlink: ${PLEX_DB_SYMLINK}" "fix_symlink"
        _vprint_issue "ERROR" "Databases symlink" "Not a symlink: ${PLEX_DB_SYMLINK}"
    fi

    # ── DB File Readability ───────────────────────────────────────────────────
    echo -e "\n  ${BOLD}DB File Readability${NC}"

    local db_ok=0 db_missing=0 db_unreadable=0
    if [[ -d "${RAMDISK_DB_DIR}" ]]; then
        while IFS= read -r -d '' f; do
            local fname; fname=$(basename "${f}")
            if [[ ! -r "${f}" ]]; then
                _vlog "ERROR" "DB readable" "${fname} is not readable" "restore_ramdisk"
                _vprint_issue "ERROR" "DB readable" "${fname} not readable"
                (( db_unreadable++ )) || true
            else
                (( db_ok++ )) || true
            fi
        done < <(find "${RAMDISK_DB_DIR}" -maxdepth 1 -name "*.db" -type f -print0 2>/dev/null)

        if (( db_ok > 0 )); then
            _vok "DB files readable" "${db_ok} .db file(s) readable"
        fi
        if (( db_missing > 0 || db_unreadable > 0 )); then
            _vprint_issue "ERROR" "DB files" "${db_unreadable} unreadable"
        fi

        # sqlite3 integrity check if available
        if command -v sqlite3 &>/dev/null; then
            local db_errors=0
            while IFS= read -r -d '' f; do
                local fname; fname=$(basename "${f}")
                local result; result=$(sqlite3 "${f}" "PRAGMA integrity_check;" 2>&1 | head -1)
                if [[ "${result}" == "ok" ]]; then
                    _vok "SQLite integrity" "${fname}: ok"
                else
                    _vlog "ERROR" "SQLite integrity" "${fname}: ${result}" "restore_ramdisk"
                    _vprint_issue "ERROR" "SQLite integrity" "${fname}: ${result}"
                    (( db_errors++ )) || true
                fi
            done < <(find "${RAMDISK_DB_DIR}" -maxdepth 1 -name "*.db" -type f -print0 2>/dev/null)
        else
            _vlog "INFO" "SQLite integrity" "sqlite3 not installed — skipping (apt install sqlite3)" "none"
            _vprint_issue "INFO" "SQLite integrity" "Skipped — sqlite3 not installed"
        fi
    fi

    # ── Hash Verification ─────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Hash Verification${NC}"

    # Verify current/ against manifest
    if [[ -f "${CURRENT_MANIFEST}" ]]; then
        local manifest_count; manifest_count=$(wc -l < "${CURRENT_MANIFEST}" | tr -d '[:space:]')
        local hash_errors=0 hash_ok=0
        while IFS= read -r line; do
            local expected_hash rel_path
            expected_hash=$(echo "${line}" | awk '{print $1}')
            rel_path=$(echo "${line}" | awk '{print $2}')
            local fpath="${BACKUP_CURRENT}/${rel_path}"
            if [[ ! -f "${fpath}" ]]; then
                _vlog "ERROR" "current/ hash" "Missing: ${rel_path}" "reseed_current"
                _vprint_issue "ERROR" "current/ hash" "Missing: ${rel_path}"
                (( hash_errors++ )) || true
            else
                local actual_hash; actual_hash=$(sha256sum "${fpath}" | awk '{print $1}')
                if [[ "${actual_hash}" != "${expected_hash}" ]]; then
                    _vlog "ERROR" "current/ hash" "Mismatch: ${rel_path}" "reseed_current"
                    _vprint_issue "ERROR" "current/ hash" "Mismatch: ${rel_path}"
                    (( hash_errors++ )) || true
                else
                    (( hash_ok++ )) || true
                fi
            fi
        done < "${CURRENT_MANIFEST}"
        if (( manifest_count == 0 )); then
            _vlog "WARN" "current/ manifest" "Manifest is empty — run manual backup" "reseed_current"
            _vprint_issue "WARN" "current/ manifest" "Empty — run: sudo /usr/local/bin/plex-ramdisk-backup.sh"
        elif (( hash_errors == 0 )); then
            _vok "current/ manifest" "${hash_ok}/${manifest_count} file(s) verified"
        fi
    else
        _vlog "ERROR" "current/ manifest" "Manifest missing: ${CURRENT_MANIFEST}" "reseed_current"
        _vprint_issue "ERROR" "current/ manifest" "Manifest missing"
    fi

    # Verify ramdisk files match current/ manifest (live check)
    if [[ -f "${CURRENT_MANIFEST}" && -d "${RAMDISK_DB_DIR}" ]]; then
        local rd_hash_errors=0 rd_hash_ok=0
        while IFS= read -r line; do
            local expected_hash rel_path
            expected_hash=$(echo "${line}" | awk '{print $1}')
            rel_path=$(echo "${line}" | awk '{print $2}')
            local fpath="${RAMDISK_DB_DIR}/${rel_path}"
            if [[ -f "${fpath}" ]]; then
                local actual_hash; actual_hash=$(sha256sum "${fpath}" | awk '{print $1}')
                if [[ "${actual_hash}" == "${expected_hash}" ]]; then
                    (( rd_hash_ok++ )) || true
                else
                    _vlog "WARN" "Ramdisk vs manifest" "${rel_path} differs from last backup (expected if Plex is running)" "none"
                    _vprint_issue "WARN" "Ramdisk vs manifest" "${rel_path} differs (normal if Plex is running)"
                    (( rd_hash_errors++ )) || true
                fi
            fi
        done < "${CURRENT_MANIFEST}"
        if (( rd_hash_errors == 0 )); then
            _vok "Ramdisk vs manifest" "${rd_hash_ok} file(s) match last backup"
        fi
    fi

    # Verify snapshots
    if [[ -d "${BACKUP_SNAPSHOTS}" ]]; then
        local snap_dirs=()
        mapfile -t snap_dirs < <(ls -d "${BACKUP_SNAPSHOTS}"/[0-9]* 2>/dev/null | sort -r)
        if (( ${#snap_dirs[@]} == 0 )); then
            _vlog "INFO" "Snapshots" "No snapshots yet" "none"
            _vprint_issue "INFO" "Snapshots" "No snapshots yet — first runs at 04:30"
        else
            local snap_ok=0 snap_bad=0
            for snap in "${snap_dirs[@]}"; do
                local snap_mf="${snap}/snapshot.sha256"
                if [[ ! -f "${snap_mf}" ]]; then
                    _vlog "WARN" "Snapshot manifest" "Missing manifest in $(basename "${snap}")" "none"
                    _vprint_issue "WARN" "Snapshot" "Missing manifest: $(basename "${snap}")"
                    (( snap_bad++ )) || true
                    continue
                fi
                local snap_errors=0
                while IFS= read -r line; do
                    local expected_hash rel_path
                    expected_hash=$(echo "${line}" | awk '{print $1}')
                    rel_path=$(echo "${line}" | awk '{print $2}')
                    local fpath="${snap}/${rel_path}"
                    if [[ ! -f "${fpath}" ]]; then
                        (( snap_errors++ )) || true
                    else
                        local actual_hash; actual_hash=$(sha256sum "${fpath}" | awk '{print $1}')
                        [[ "${actual_hash}" != "${expected_hash}" ]] && (( snap_errors++ )) || true
                    fi
                done < "${snap_mf}"
                if (( snap_errors == 0 )); then
                    (( snap_ok++ )) || true
                else
                    _vlog "WARN" "Snapshot integrity" "$(basename "${snap}"): ${snap_errors} error(s)" "none"
                    _vprint_issue "WARN" "Snapshot" "$(basename "${snap}"): ${snap_errors} hash error(s)"
                    (( snap_bad++ )) || true
                fi
            done
            if (( snap_ok > 0 )); then
                _vok "Snapshot integrity" "${snap_ok}/${#snap_dirs[@]} snapshot(s) valid"
            fi
            if (( snap_bad > 0 )); then
                _vprint_issue "WARN" "Snapshot integrity" "${snap_bad} snapshot(s) have issues — manual review needed"
            fi
        fi
    fi

    # ── Installed Scripts ─────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Installed Scripts${NC}"

    _validate_script() {
        local path="$1" label="$2" expected_ver="$3" fix_key="$4"
        if [[ ! -f "${path}" ]]; then
            _vlog "ERROR" "${label}" "Missing: ${path}" "${fix_key}"
            _vprint_issue "ERROR" "${label}" "Missing"
            return
        fi
        if [[ ! -x "${path}" ]]; then
            _vlog "ERROR" "${label}" "Not executable: ${path}" "fix_script_perms"
            _vprint_issue "ERROR" "${label}" "Not executable"
        fi
        local found_ver; found_ver=$(grep -m1 "^# Version:" "${path}" 2>/dev/null | awk '{print $3}')
        if [[ "${found_ver}" == "${expected_ver}" ]]; then
            _vok "${label}" "v${found_ver}  ${path}"
        else
            _vlog "WARN" "${label}" "Version mismatch: found v${found_ver}, expected v${expected_ver}" "${fix_key}"
            _vprint_issue "WARN" "${label}" "Version mismatch: v${found_ver} (expected v${expected_ver})"
        fi
        # Verify key constants match current setup
        # Verify key constants by extracting values from installed script
        local rd_ok=true
        local found_rd found_bc found_ps
        found_rd=$(grep -m1 "^RAMDISK_DB_DIR=" "${path}" 2>/dev/null | cut -d= -f2 | tr -d '"')
        found_bc=$(grep -m1 "^BACKUP_CURRENT=" "${path}" 2>/dev/null | cut -d= -f2 | tr -d '"')
        found_ps=$(grep -m1 "^PLEX_SERVICE=" "${path}" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [[ "${found_rd}" != "${RAMDISK_DB_DIR}" ]] && rd_ok=false
        [[ "${found_bc}" != "${BACKUP_CURRENT}" ]] && rd_ok=false
        [[ "${found_ps}" != "${PLEX_SERVICE}" ]]   && rd_ok=false
        if $rd_ok; then
            _vok "${label} constants" "RAMDISK_DB_DIR, BACKUP_CURRENT, PLEX_SERVICE match"
        else
            _vlog "WARN" "${label} constants" "Key constants may not match current setup" "${fix_key}"
            _vprint_issue "WARN" "${label} constants" "Key constants differ from current setup"
            [[ "${found_rd}" != "${RAMDISK_DB_DIR}" ]] && \
                _vprint_issue "WARN" "${label}" "  RAMDISK_DB_DIR: ${found_rd} (expected ${RAMDISK_DB_DIR})"
            [[ "${found_bc}" != "${BACKUP_CURRENT}" ]] && \
                _vprint_issue "WARN" "${label}" "  BACKUP_CURRENT: ${found_bc} (expected ${BACKUP_CURRENT})"
            [[ "${found_ps}" != "${PLEX_SERVICE}" ]] && \
                _vprint_issue "WARN" "${label}" "  PLEX_SERVICE: ${found_ps} (expected ${PLEX_SERVICE})"
        fi
    }

    _validate_script "${BACKUP_SCRIPT}"  "Backup script"  "${BACKUP_SCRIPT_VERSION}"  "rewrite_backup_script"
    _validate_script "${RESTORE_SCRIPT}" "Restore script" "${RESTORE_SCRIPT_VERSION}" "rewrite_restore_script"

    # ── Systemd Unit ──────────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Systemd Unit${NC}"

    if [[ -f "${SYSTEMD_UNIT_FILE}" ]]; then
        local unit_errors=0
        _check_unit() {
            local pattern="$1" label="$2"
            if grep -q "${pattern}" "${SYSTEMD_UNIT_FILE}" 2>/dev/null; then
                _vok "Unit: ${label}" "present"
            else
                _vlog "ERROR" "Unit: ${label}" "Missing in ${SYSTEMD_UNIT_FILE}" "rewrite_unit"
                _vprint_issue "ERROR" "Unit: ${label}" "Missing from unit file"
                (( unit_errors++ )) || true
            fi
        }
        _check_unit "StandardOutput=journal+console"        "StandardOutput"
        _check_unit "ExecStart=${RESTORE_SCRIPT}"           "ExecStart"
        _check_unit "ExecStop=${BACKUP_SCRIPT} --shutdown"  "ExecStop"
        _check_unit "RemainAfterExit=yes"                   "RemainAfterExit"
        _check_unit "After=local-fs.target"                 "After=local-fs"
        _check_unit "Before=umount.target"                  "Before=umount"

        if systemctl is-enabled --quiet plex-ramdisk-sync.service 2>/dev/null; then
            _vok "Unit enabled" "plex-ramdisk-sync.service is enabled"
        else
            _vlog "ERROR" "Unit enabled" "plex-ramdisk-sync.service is NOT enabled" "enable_unit"
            _vprint_issue "ERROR" "Unit enabled" "Service is not enabled"
        fi
        if (( unit_errors == 0 )); then
            _vok "Systemd unit" "All directives present"
        fi
    else
        _vlog "ERROR" "Systemd unit" "Missing: ${SYSTEMD_UNIT_FILE}" "rewrite_unit"
        _vprint_issue "ERROR" "Systemd unit" "Missing: ${SYSTEMD_UNIT_FILE}"
    fi

    # ── Plex Drop-in ──────────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Plex Drop-in${NC}"

    if [[ -f "${SYSTEMD_DROPIN_FILE}" ]]; then
        local dropin_errors=0
        _check_dropin() {
            local pattern="$1" label="$2"
            if grep -q "${pattern}" "${SYSTEMD_DROPIN_FILE}" 2>/dev/null; then
                _vok "Drop-in: ${label}" "present"
            else
                _vlog "ERROR" "Drop-in: ${label}" "Missing in ${SYSTEMD_DROPIN_FILE}" "rewrite_dropin"
                _vprint_issue "ERROR" "Drop-in: ${label}" "Missing from drop-in"
                (( dropin_errors++ )) || true
            fi
        }
        _check_dropin "Requires=plex-ramdisk-sync.service" "Requires"
        _check_dropin "After=plex-ramdisk-sync.service"    "After"
        _check_dropin "ExecStartPre=/bin/sleep"            "Boot delay"
        if (( dropin_errors == 0 )); then
            _vok "Plex drop-in" "All directives present"
        fi
    else
        _vlog "ERROR" "Plex drop-in" "Missing: ${SYSTEMD_DROPIN_FILE}" "rewrite_dropin"
        _vprint_issue "ERROR" "Plex drop-in" "Missing: ${SYSTEMD_DROPIN_FILE}"
    fi

    # ── Cron Job ──────────────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Cron Job${NC}"

    if [[ -f "${CRON_FILE}" ]]; then
        local cron_errors=0
        if grep -q "30 4 \* \* \*" "${CRON_FILE}" 2>/dev/null; then
            _vok "Cron schedule" "Daily at 04:30"
        else
            _vlog "ERROR" "Cron schedule" "Expected '30 4 * * *' not found in ${CRON_FILE}" "rewrite_cron"
            _vprint_issue "ERROR" "Cron schedule" "Schedule missing or wrong"
            (( cron_errors++ )) || true
        fi
        if grep -q "root ${BACKUP_SCRIPT}" "${CRON_FILE}" 2>/dev/null; then
            _vok "Cron command" "Runs as root → ${BACKUP_SCRIPT}"
        else
            _vlog "ERROR" "Cron command" "Expected 'root ${BACKUP_SCRIPT}' not found" "rewrite_cron"
            _vprint_issue "ERROR" "Cron command" "Script path wrong or not running as root"
            (( cron_errors++ )) || true
        fi
        if (( cron_errors == 0 )); then
            _vok "Cron job" "${CRON_FILE} content valid"
        fi
    else
        _vlog "ERROR" "Cron job" "Missing: ${CRON_FILE}" "rewrite_cron"
        _vprint_issue "ERROR" "Cron job" "Missing: ${CRON_FILE}"
    fi

    # ── Logrotate ─────────────────────────────────────────────────────────────
    echo -e "\n  ${BOLD}Logrotate${NC}"

    local lr_file="/etc/logrotate.d/plex-ramdisk"
    if [[ -f "${lr_file}" ]]; then
        local lr_errors=0
        for lf in "${SETUP_LOG}" "${RUNTIME_LOG}" "${ERROR_LOG}"; do
            if grep -q "${lf}" "${lr_file}" 2>/dev/null; then
                _vok "Logrotate: $(basename "${lf}")" "present in config"
            else
                _vlog "WARN" "Logrotate" "$(basename "${lf}") missing from ${lr_file}" "rewrite_logrotate"
                _vprint_issue "WARN" "Logrotate" "$(basename "${lf}") missing"
                (( lr_errors++ )) || true
            fi
        done
        if (( lr_errors == 0 )); then
            _vok "Logrotate config" "${lr_file} — all 3 logs covered"
        fi
    else
        _vlog "WARN" "Logrotate" "Missing: ${lr_file}" "rewrite_logrotate"
        _vprint_issue "WARN" "Logrotate" "Missing: ${lr_file}"
    fi

    # ── no-dated files in current/ ────────────────────────────────────────────
    echo -e "\n  ${BOLD}Backup Integrity${NC}"

    if [[ -d "${BACKUP_CURRENT}" ]]; then
        local dated_in_current
        dated_in_current=$(find "${BACKUP_CURRENT}" -maxdepth 1 -type f             -regex "${DATED_PATTERN}" 2>/dev/null | wc -l | tr -d '[:space:]')
        if (( dated_in_current == 0 )); then
            _vok "current/ clean" "No dated backup files in current/"
        else
            _vlog "WARN" "current/ dated files" "${dated_in_current} dated file(s) found in current/" "clean_current"
            _vprint_issue "WARN" "current/ dated" "${dated_in_current} dated file(s) should not be in current/"
        fi
    fi

    # ── Validation Result ─────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if (( VALIDATE_ERRORS == 0 && VALIDATE_WARNS == 0 )); then
        echo -e "  ${GREEN}${BOLD}✔ Validation passed — all checks clean${NC}"
    elif (( VALIDATE_ERRORS == 0 )); then
        echo -e "  ${YELLOW}${BOLD}Validation passed with ${VALIDATE_WARNS} warning(s)${NC}"
    else
        echo -e "  ${RED}${BOLD}Validation failed — ${VALIDATE_ERRORS} error(s)  ${VALIDATE_WARNS} warning(s)${NC}"
    fi

    if (( VALIDATE_ERRORS > 0 || VALIDATE_WARNS > 0 )) && ! $FIX_MODE; then
        echo ""
        echo -e "  Run ${BOLD}--fix${NC} to attempt automatic repair of the issues above."
    fi
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ── Fix ───────────────────────────────────────────────────────────────────────
fix_setup() {
    # Run validation first to collect issues
    validate_setup true
    _slog "INFO" "Fix mode: ${VALIDATE_ERRORS} error(s), ${VALIDATE_WARNS} warning(s) found"

    if (( VALIDATE_ERRORS == 0 && VALIDATE_WARNS == 0 )); then
        echo -e "  ${GREEN}Nothing to fix — all checks passed.${NC}\n"
        return
    fi

    # Collect unique fix keys from issues
    local fix_keys=()
    for issue in "${VALIDATE_ISSUES[@]}"; do
        local fix_key; fix_key=$(echo "${issue}" | cut -d'|' -f4)
        if [[ "${fix_key}" != "none" ]]; then
            local already=false
            for k in "${fix_keys[@]}"; do [[ "$k" == "${fix_key}" ]] && already=true; done
            if ! $already; then fix_keys+=("${fix_key}"); fi
        fi
    done

    if (( ${#fix_keys[@]} == 0 )); then
        echo -e "  ${YELLOW}Issues found are informational only — no automatic fixes available.${NC}\n"
        return
    fi

    echo -e "  ${BOLD}Repairs that will be attempted:${NC}\n"
    for key in "${fix_keys[@]}"; do
        case "${key}" in
            fix_db_ownership)      echo -e "    • Fix DB directory ownership to ${PLEX_USER}:${PLEX_USER}" ;;
            fix_symlink)           echo -e "    • Recreate Databases directory symlink" ;;
            restore_ramdisk)       echo -e "    • Restore DB files from current/ to ramdisk" ;;
            reseed_current)        echo -e "    • Re-seed current/ from ramdisk and rewrite manifest" ;;
            rewrite_backup_script) echo -e "    • Rewrite backup script (v${BACKUP_SCRIPT_VERSION})" ;;
            rewrite_restore_script)echo -e "    • Rewrite restore script (v${RESTORE_SCRIPT_VERSION})" ;;
            fix_script_perms)      echo -e "    • Fix executable permissions on scripts" ;;
            rewrite_unit)          echo -e "    • Rewrite and reload systemd unit" ;;
            enable_unit)           echo -e "    • Enable plex-ramdisk-sync.service" ;;
            rewrite_dropin)        echo -e "    • Rewrite Plex systemd drop-in" ;;
            rewrite_cron)          echo -e "    • Rewrite cron job" ;;
            rewrite_logrotate)     echo -e "    • Rewrite logrotate config" ;;
            clean_current)         echo -e "    • Remove dated backup files from current/" ;;
        esac
    done

    echo ""
    read -r -p "  Proceed with repairs? [yes/no]: " confirm
    echo ""
    case "${confirm,,}" in
        yes|y) log_ok "Confirmed. Applying fixes..."; _slog "INFO" "Fix confirmed" ;;
        *)     echo "  Aborted."; _slog "INFO" "Fix aborted by user"; return ;;
    esac

    local fixed=0 fix_failed=0

    for key in "${fix_keys[@]}"; do
        _slog "INFO" "Applying fix: ${key}"
        case "${key}" in
            fix_db_ownership)
                log_step "Fix: DB directory ownership"
                chown -R "${PLEX_USER}:${PLEX_USER}" "${RAMDISK_DB_DIR}"
                log_ok "DB dir ownership set to ${PLEX_USER}:${PLEX_USER}: ${RAMDISK_DB_DIR}"
                (( fixed++ )) || true
                ;;
            fix_symlink)
                log_step "Fix: Databases symlink"
                if [[ -L "${PLEX_DB_SYMLINK}" ]]; then
                    rm -f "${PLEX_DB_SYMLINK}"
                    log_info "Removed old symlink."
                fi
                if [[ -d "${RAMDISK_DB_DIR}" ]]; then
                    ln -s "${RAMDISK_DB_DIR}" "${PLEX_DB_SYMLINK}"
                    log_ok "Symlink recreated: ${PLEX_DB_SYMLINK} → ${RAMDISK_DB_DIR}"
                    (( fixed++ )) || true
                else
                    log_error "Cannot fix symlink — ramdisk DB dir missing: ${RAMDISK_DB_DIR}"
                    (( fix_failed++ )) || true
                fi
                ;;
            restore_ramdisk)
                log_step "Fix: Restore DB files to ramdisk from current/"
                if [[ ! -d "${BACKUP_CURRENT}" ]]; then
                    log_error "Cannot restore — backup current/ missing"
                    (( fix_failed++ )) || true
                else
                    mkdir -p "${RAMDISK_DB_DIR}"
                    rsync -av \
                        --exclude="*.sha256" \
                        --exclude="*.sha256.tmp" \
                        --exclude="*.tmp" \
                        "${BACKUP_CURRENT}/" "${RAMDISK_DB_DIR}/" >> "${SETUP_LOG}" 2>&1
                    chown -R "${PLEX_USER}:${PLEX_USER}" "${RAMDISK_DB_DIR}"
                    log_ok "DB files restored to ramdisk from current/"
                    (( fixed++ )) || true
                fi
                ;;
            reseed_current)
                log_step "Fix: Re-seed current/ from ramdisk"
                if [[ ! -d "${RAMDISK_DB_DIR}" ]]; then
                    log_error "Cannot re-seed — ramdisk DB dir missing"
                    (( fix_failed++ )) || true
                else
                    rsync -av "${RAMDISK_DB_DIR}/" "${BACKUP_CURRENT}/" >> "${SETUP_LOG}" 2>&1
                    find "${BACKUP_CURRENT}" -maxdepth 1 -type f                         -regex "${DATED_PATTERN}" -delete 2>/dev/null || true
                    rm -f "${BACKUP_CURRENT}/current.sha256" 2>/dev/null || true
                    write_manifest "${BACKUP_CURRENT}" "${CURRENT_MANIFEST}"
                    chown -R "${PLEX_USER}:${PLEX_USER}" "${BACKUP_CURRENT}"
                    state_set "STEP_3_SEED_CURRENT" "complete"
                    log_ok "current/ re-seeded and manifest rewritten"
                    (( fixed++ )) || true
                fi
                ;;
            rewrite_backup_script)
                log_step "Fix: Rewrite backup script"
                state_set "STEP_5_BACKUP_SCRIPT" "absent"
                write_backup_script
                (( fixed++ )) || true
                ;;
            rewrite_restore_script)
                log_step "Fix: Rewrite restore script"
                state_set "STEP_4_RESTORE_SCRIPT" "absent"
                write_restore_script
                (( fixed++ )) || true
                ;;
            fix_script_perms)
                log_step "Fix: Script permissions"
                [[ -f "${BACKUP_SCRIPT}" ]]  && chmod +x "${BACKUP_SCRIPT}"
                [[ -f "${RESTORE_SCRIPT}" ]] && chmod +x "${RESTORE_SCRIPT}"
                log_ok "Executable permissions set on scripts"
                (( fixed++ )) || true
                ;;
            rewrite_unit)
                log_step "Fix: Rewrite systemd unit"
                state_set "STEP_6_SYSTEMD_UNIT" "absent"
                write_systemd_unit
                (( fixed++ )) || true
                ;;
            enable_unit)
                log_step "Fix: Enable systemd unit"
                systemctl enable plex-ramdisk-sync.service 2>/dev/null
                log_ok "plex-ramdisk-sync.service enabled"
                (( fixed++ )) || true
                ;;
            rewrite_dropin)
                log_step "Fix: Rewrite Plex drop-in"
                # Force rewrite by clearing state
                state_set "STEP_6_SYSTEMD_DROPIN" "absent"
                write_systemd_unit
                (( fixed++ )) || true
                ;;
            rewrite_cron)
                log_step "Fix: Rewrite cron job"
                state_set "STEP_7_CRON" "absent"
                write_cron_job
                (( fixed++ )) || true
                ;;
            rewrite_logrotate)
                log_step "Fix: Rewrite logrotate config"
                _write_logrotate_config
                log_ok "Logrotate config rewritten"
                (( fixed++ )) || true
                ;;
            clean_current)
                log_step "Fix: Remove dated files from current/"
                find "${BACKUP_CURRENT}" -maxdepth 1 -type f                     -regex "${DATED_PATTERN}" -delete 2>/dev/null || true
                log_ok "Dated backup files removed from current/"
                (( fixed++ )) || true
                ;;
        esac
    done

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if (( fix_failed == 0 )); then
        echo -e "  ${GREEN}${BOLD}✔ ${fixed} fix(es) applied successfully.${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}${fixed} fix(es) applied, ${fix_failed} could not be completed.${NC}"
    fi
    echo -e "  Run ${BOLD}--validate${NC} to confirm all issues are resolved."
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _slog "INFO" "Fix complete: ${fixed} applied, ${fix_failed} failed"
}

main() {
    echo ""
    echo -e "${BOLD}Plex Ramdisk Setup — v${SETUP_VERSION}${NC}"
    if $DRY_RUN; then echo -e "${YELLOW}[DRY-RUN MODE — no changes will be made]${NC}"; fi
    echo -e "Mode: ${MODE}"

    init_setup_log

    case "${MODE}" in
        status)
            show_status; exit 0 ;;
        summary)
            show_summary; exit 0 ;;
        validate)
            validate_setup false; exit 0 ;;
        fix)
            fix_setup; exit 0 ;;
        fix-seed)
            log_warn "Fix-seed mode: forcing STEP_3_SEED_CURRENT to retry."
            # Remove failed seed state so migrate_database_dir retries it
            local tmp="${STATE_FILE}.tmp"
            grep -v "^STEP_3_SEED_CURRENT=" "${STATE_FILE}" 2>/dev/null > "${tmp}" || true
            echo "STEP_3_SEED_CURRENT=failed" >> "${tmp}"
            mv "${tmp}" "${STATE_FILE}"
            _slog "INFO" "Seed state reset to failed — will retry on next setup run"
            log_ok "Seed state reset. Run without flags to retry the seed step."
            log_info "Or run: sudo bash ${SCRIPT_NAME} to proceed."
            exit 0 ;;
        reset)
            log_warn "Resetting state file: ${STATE_FILE}"
            state_clear
            log_ok "State cleared. Run without --reset for fresh setup."
            exit 0 ;;
        rollback)
            log_warn "Manual rollback requested."
            THIS_RUN_CREATED_RAMDISK_DIR=true
            THIS_RUN_CREATED_BACKUP_DIRS=true
            THIS_RUN_MIGRATED_DIR=true
            THIS_RUN_CREATED_RESTORE_SCRIPT=true
            THIS_RUN_CREATED_BACKUP_SCRIPT=true
            THIS_RUN_CREATED_UNIT=true
            THIS_RUN_CREATED_DROPIN=true
            THIS_RUN_CREATED_CRON=true
            PLEX_WAS_RUNNING=$(systemctl is-active --quiet "${PLEX_SERVICE}" \
                2>/dev/null && echo true || echo false)
            # Find the original backup dir name from state or disk
            ORIGINAL_DB_BACKUP_NAME=$(ls -d \
                "${PLEX_PLUGIN_SUPPORT}"/BACKUP_Databases_* 2>/dev/null \
                | sort -r | head -1 | xargs basename 2>/dev/null || echo "")
            rollback
            state_clear
            finalize_setup_log
            exit 0 ;;
        setup)
            trap trap_rollback EXIT
            inventory_audit

            if $DRY_RUN; then
                log_step "Step 1: Ramdisk Plex Directory";       log_dry "mkdir -p ${RAMDISK_DB_DIR}"
                log_step "Step 2: Backup Directory Structure";    log_dry "mkdir -p ${BACKUP_CURRENT} ${BACKUP_SNAPSHOTS} ${DB_BACKUP_DIR}"
                log_step "Step 3: Migrate Databases Directory";   log_dry "stop plex → rsync dir → offload dated → rename original → symlink → seed current/"
                log_step "Step 4: Restore Script";                log_dry "write ${RESTORE_SCRIPT} (v${RESTORE_SCRIPT_VERSION})"
                log_step "Step 5: Backup Script";                 log_dry "write ${BACKUP_SCRIPT} (v${BACKUP_SCRIPT_VERSION})"
                log_step "Step 6: Systemd Unit + Drop-in";        log_dry "write unit + ${SYSTEMD_DROPIN_FILE}"
                log_step "Step 7: Cron Job";                      log_dry "write ${CRON_FILE} + logrotate config"
                log_step "Step 8: Watchdog";                      log_dry "FUTURE FEATURE — skipped"
                log_step "Step 9: DB Backup Pruning";             log_dry "FUTURE FEATURE — skipped"
            else
                setup_ramdisk_dir
                setup_backup_dirs
                migrate_database_dir
                write_restore_script
                write_backup_script
                write_systemd_unit
                write_cron_job
                setup_watchdog
                setup_db_backup_pruning
                verify_setup
                trap - EXIT
                finalize_setup_log
            fi ;;
    esac

    print_summary
}

main "$@"
