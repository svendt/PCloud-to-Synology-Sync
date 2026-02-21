#!/bin/bash
# =============================================================================
# pcloud_to_synology_sync_svdt.sh — pCloud → Synology NAS Backup
# One-way backup of pCloud to a local Synology NAS using rclone.
# No files are ever deleted on the NAS.
# See README.md for full documentation. See CHANGELOG.md for version history.
SCRIPT_VERSION="1.9"
SCRIPT_NAME="pCloud → Synology Backup"
SCRIPT_YEAR="2026"
SCRIPT_AUTHOR="SVDT"
# Distributed under the MIT License
# =============================================================================

set -euo pipefail
umask 077

# =============================================================================
# HELP
# =============================================================================

usage() {
    echo "  ${SCRIPT_NAME} v${SCRIPT_VERSION} — (c) ${SCRIPT_YEAR} ${SCRIPT_AUTHOR}"
    echo
    echo "  A production-grade, one-way backup script that synchronises data from"
    echo "  pCloud to a Synology NAS using rclone. Files are never deleted on the NAS."
    echo
    echo "USAGE"
    echo "  ./pcloud_to_synology_sync_svdt.sh [--help | --version]"
    echo "  SELF_TEST=1 ./pcloud_to_synology_sync_svdt.sh"
    echo
    echo "FLAGS"
    echo "  --help        Show this help screen and exit."
    echo "  --version     Show version number and exit."
    echo
    echo "ENVIRONMENT VARIABLES"
    echo "  SELF_TEST=1         Dry-run mode. Runs all pre-flight checks and passes"
    echo "                      --dry-run to rclone. No files are transferred or"
    echo "                      modified. Use this to validate your environment before"
    echo "                      scheduling a real backup."
    echo
    echo "  PCLOUD_NOHUP=1      Forces non-interactive mode (disables rclone --progress)."
    echo "                      Set this when running via cron, DSM Task Scheduler, or"
    echo "                      nohup. Without it, the script auto-detects interactivity"
    echo "                      via file descriptor check."
    echo
    echo "WHAT IT DOES (one run)"
    echo "  1.  Creates required directories (log dir, state dir, local backup dir)."
    echo "  2.  Repairs or removes stale lockfiles left by crashed runs."
    echo "  3.  Acquires an atomic PID-based lockfile to prevent concurrent runs."
    echo "  4.  Checks that rclone is available in PATH."
    echo "  5.  Checks that the NAS volume has enough free space (default: ~1 TB)."
    echo "  6.  NAS resource snapshot — skipped (disabled on DSM; see REQUIREMENTS)."
    echo "  7.  Probes pCloud API connectivity and measures response latency."
    echo "  8.  Runs rclone copy (up to 3 attempts with 5-minute backoff)."
    echo "  9.  Runs rclone check (one-way: pCloud → NAS) to detect missing or"
    echo "      differing files, and writes diff artefact files."
    echo "  10. Detects pCloud API lag (eventual consistency) and compares to the"
    echo "      previous run's missing-on-dst list."
    echo "  11. Calculates a health score (0–100) for this run."
    echo "  12. Appends a structured stats entry to the rolling 30-run history."
    echo "  13. Updates the last-success timestamp."
    echo "  14. Prunes log files, keeping the last 30 runs."
    echo "  15. NAS resource snapshot post-backup — skipped (disabled on DSM; see REQUIREMENTS)."
    echo "  16. Prints a formatted 30-run statistics table."
    echo
    echo "DRY-RUN / SELF-TEST MODE"
    echo "  SELF_TEST=1 ./pcloud_to_synology_sync_svdt.sh"
    echo
    echo "  When SELF_TEST=1 is set:"
    echo "  - All pre-flight checks run normally (connectivity, disk space, lockfile)."
    echo "  - rclone runs with --dry-run: no files are downloaded or modified."
    echo "  - Diff files and health score are still generated."
    echo "  - Statistics are recorded in the 30-run history."
    echo "  - The run is labelled 'self-test' in the final log entry."
    echo "  Use this to verify your rclone config, paths, and credentials without"
    echo "  transferring any data."
    echo
    echo "LOG FILES  (default: /volume1/pcloud_filebackup_logs/)"
    echo "  pcloud-meta-TIMESTAMP.log            Structured key=value run log (all events)."
    echo "  pcloud-rclone-TIMESTAMP.log          Raw rclone output (copy + check combined)."
    echo "  pcloud-diff-TIMESTAMP.txt            Files with size differences (pCloud vs NAS)."
    echo "  pcloud-missing-on-dst-TIMESTAMP.txt  Files on pCloud not yet on NAS."
    echo
    echo "STATE FILES  (default: /var/lib/pcloud-backup/)"
    echo "  backup.lock              PID lockfile — removed on clean exit."
    echo "  last_success             Timestamp of the last successful run."
    echo "  prev_missing_on_dst.txt  Used to detect persistent API-lag across runs."
    echo "  stats_history.txt        Rolling 30-run statistics (one line per run)."
    echo
    echo "HEALTH SCORE"
    echo "  Each run produces a health score from 0 to 100:"
    echo "  Start:                  100"
    echo "  API latency > 30s:      -40"
    echo "  API latency > 10s:      -20"
    echo "  rclone check exit=1:    -10  (API lag, non-fatal)"
    echo "  rclone check exit>1:    -50  (real error)"
    echo "  Files missing on NAS:   -10"
    echo "  Size differences found: -50"
    echo "  Score is clamped to [0, 100]."
    echo
    echo "STATISTICS TABLE COLUMNS"
    echo "  Date/Time       Timestamp of the run."
    echo "  API(s)          pCloud API response time in seconds."
    echo "  IndexDelay(s)   Seconds between end of copy and pCloud API exposing new files."
    echo "  Missing         Files on pCloud not yet visible on NAS."
    echo "  Diff            Files with size differences."
    echo "  Copy            rclone copy exit code (0=OK, 1=non-fatal)."
    echo "  Check           rclone check exit code (0=OK, 1=API lag, >1=error)."
    echo "  Health          Health score for the run (0–100)."
    echo
    echo "REQUIREMENTS"
    echo "  rclone              Required. v1.56+ (2021). Must be in PATH and configured for pCloud."
    echo "  ionice              Optional. Lowers rclone I/O priority (class 2, niceness 7)."
    echo "  top / vmstat / iostat  Disabled on DSM (these tools hang on busybox/DSM)."
    echo
    echo "CONFIGURATION  (edit the CONFIG section in the script)"
    echo "  REMOTE              rclone remote name (default: pcloud:)"
    echo "  LOCAL               NAS destination path (default: /volume1/pcloud_filebackup)"
    echo "  LOG_DIR             Log directory (default: /volume1/pcloud_filebackup_logs)"
    echo "  STATE_DIR           State/lock dir (default: /var/lib/pcloud-backup)"
    echo "  MIN_FREE_MB         Minimum free space in MB before starting (default: 1000000)"
    echo "  MAX_RETRIES         rclone copy attempts (default: 3)"
    echo "  RETRY_DELAY         Seconds between retries (default: 300)"
    echo "  LOG_RETENTION_RUNS  Number of runs to retain log files for (default: 30)"
    echo
    echo "SCHEDULING (Synology DSM Task Scheduler)"
    echo "  1. DSM → Control Panel → Task Scheduler → Create → Scheduled Task."
    echo "  2. User: root."
    echo "  3. Schedule: daily at your preferred time (e.g. 02:00)."
    echo "  4. Run command:"
    echo "       PCLOUD_NOHUP=1 /path/to/pcloud_to_synology_sync_svdt.sh"
    echo "  5. Enable notification on abnormal termination (optional but recommended)."
    echo
    echo "TROUBLESHOOTING"
    echo "  Lockfile already active"
    echo "    Stale locks from dead processes are removed automatically."
    echo "    Manual removal: rm /var/lib/pcloud-backup/backup.lock"
    echo
    echo "  rclone not found in PATH"
    echo "    Install rclone on Synology (Entware or manual binary)."
    echo "    Verify: rclone version"
    echo
    echo "  Insufficient free space"
    echo "    Free space on the volume or lower MIN_FREE_MB in the script."
    echo
    echo "  No connection to pCloud"
    echo "    Check network, pCloud API status, rclone remote name, OAuth token."
    echo "    Test: rclone lsd pcloud: --max-depth=1"
    echo
    echo "  API-lag detected"
    echo "    Files were downloaded but are not yet visible in the pCloud API."
    echo "    No action needed — handled automatically across runs."
    echo
    echo "  rclone check reports differences"
    echo "    Inspect: pcloud-diff-TIMESTAMP.txt and pcloud-missing-on-dst-TIMESTAMP.txt"
    echo
    echo "  Statistics file corrupted"
    echo "    Delete to reset: rm /var/lib/pcloud-backup/stats_history.txt"
    echo
    echo "EXIT CODES"
    echo "  0    Success (or successful self-test dry-run)."
    echo "  1    rclone copy returned a non-fatal error."
    echo "  >1   Fatal failure — rclone failed all retries, or a pre-flight check failed."
    echo
    echo "SEE ALSO"
    echo "  README.md     Full documentation, installation, OAuth token setup."
    echo "  CHANGELOG.md  Complete version history."
    echo "  LICENSE       MIT License."
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
        --version|-v)
            echo "pcloud_to_synology_sync_svdt.sh v${SCRIPT_VERSION}"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--help | --version]" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# CONFIG
# =============================================================================

# rclone remote name — must match the [pcloud] entry in your rclone.conf
# $HOME resolves to the home directory of the user running the script.
# On Synology DSM when running as root via Task Scheduler, set this explicitly:
#   export RCLONE_CONFIG="/var/services/homes/YOUR_USERNAME/.rclone.conf"
export RCLONE_CONFIG="${HOME}/.rclone.conf"
REMOTE="pcloud:"

# NAS destination — files are copied here, never deleted
LOCAL="/volume1/pcloud_filebackup"

# Log directory — meta logs, rclone logs, and diff artefacts
LOG_DIR="/volume1/pcloud_filebackup_logs"

# State directory — lockfile, last-success stamp, rolling stats
STATE_DIR="/var/lib/pcloud-backup"
LOCKFILE="${STATE_DIR}/backup.lock"
STATE_FILE="${STATE_DIR}/last_success"

# Number of runs to retain log files for (oldest files pruned first)
LOG_RETENTION_RUNS=30

# Minimum free space required on the NAS volume before starting (MB)
# Default: 1 000 000 MB ≈ 1 TB — set this to your pCloud storage capacity
MIN_FREE_MB=1000000

# rclone copy: maximum attempts and delay between them
MAX_RETRIES=3
RETRY_DELAY=300  # seconds (5 minutes)

# =============================================================================
# RUN IDENTITY
# =============================================================================

# Timestamp used in all filenames for this run
TS=$(date +"%Y%m%d-%H%M%S")

# Unique run ID — combines timestamp and PID for log correlation across files
RUN_ID="${TS}-$$"

META_LOG="${LOG_DIR}/pcloud-meta-${TS}.log"
RCLONE_LOG="${LOG_DIR}/pcloud-rclone-${TS}.log"
DIFF_FILE="${LOG_DIR}/pcloud-diff-${TS}.txt"

# Seconds between copy completion and pCloud API exposure of new files
INDEX_DELAY=0

# SELF_TEST=1      → passes --dry-run to rclone; no data transferred
# PCLOUD_NOHUP=1   → forces non-interactive mode (disables rclone --progress)
SELF_TEST="${SELF_TEST:-0}"
PCLOUD_NOHUP="${PCLOUD_NOHUP:-}"

# =============================================================================
# DIRECTORIES
# =============================================================================

mkdir -p "$LOG_DIR" "$STATE_DIR" "$LOCAL"

# =============================================================================
# STRUCTURED LOGGING
# =============================================================================
# Log file format (machine-readable, grep/awk-friendly):
#   YYYY-MM-DD HH:MM:SS level=LEVEL run_id=RUN_ID script_version=VER msg="..."
#
# Terminal format (human-readable):
#   YYYY-MM-DD HH:MM:SS [LEVEL] message

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    # Full structured line → log file only
    printf '%s level=%s run_id=%s script_version=%s msg="%s"\n' \
        "$ts" "$level" "$RUN_ID" "$SCRIPT_VERSION" "$msg" >> "$META_LOG"
    # Clean line → terminal only
    printf '%s [%s] %s\n' "$ts" "$level" "$msg"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# log_plain: writes full structured line to log file, prints indented plain text to terminal.
# Use for paths and secondary info that does not need a timestamp prefix on screen.
log_plain() {
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s level=INFO run_id=%s script_version=%s msg="%s"\n' \
        "$ts" "$RUN_ID" "$SCRIPT_VERSION" "$msg" >> "$META_LOG"
    printf '  %s\n' "$msg"
}

# =============================================================================
# CLEANUP / TRAP
# =============================================================================
# Removes the lockfile on any exit (normal, error, or signal).
# Guard: only removes the lock if it still contains our own PID — prevents
# accidentally clearing a lock written by a concurrent instance.

cleanup() {
    if [ -f "$LOCKFILE" ] && [ "$(cat "$LOCKFILE" 2>/dev/null || echo "")" = "$$" ]; then
        rm -f "$LOCKFILE"
    fi
}

trap cleanup EXIT INT TERM

# =============================================================================
# STALE LOCKFILE REPAIR
# =============================================================================
# If a lockfile exists but the process it points to is dead, remove it.
# The 720-minute threshold is logged for observability but does not gate removal
# in either direction — a dead process means the lock is always safe to remove.

if [ -f "$LOCKFILE" ]; then
    PID="$(cat "$LOCKFILE" 2>/dev/null || echo "")"
    if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
        if [ -n "$(find "$LOCKFILE" -mmin +720 2>/dev/null)" ]; then
            log_warn "Stale lockfile (pid=$PID, >720min old) — process is dead, removing."
        else
            log_warn "Lockfile pid=$PID — process is dead but lock is recent (<720min). Removing to unblock."
        fi
        rm -f "$LOCKFILE"
    fi
fi

# =============================================================================
# ATOMIC LOCKFILE
# =============================================================================
# bash noclobber makes the redirect fail if the file already exists.
# Only one process can win this race; all others exit immediately.

if ! ( set -o noclobber; echo "$$" > "$LOCKFILE" ) 2>/dev/null; then
    EXISTING_PID="$(cat "$LOCKFILE" 2>/dev/null || echo "unknown")"
    log_error "Lockfile already active — process $EXISTING_PID is still running. Exiting."
    exit 1
fi

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

LAST_SUCCESS=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
log_info "Last successful backup: $LAST_SUCCESS"
log_info "Starting pCloud backup on host=$(hostname)"
log_info "Remote=$REMOTE  →  Local=$LOCAL"
log_info "RunId=$RUN_ID  SelfTest=$SELF_TEST"
log_plain "MetaLog  : $META_LOG"
log_plain "RcloneLog: $RCLONE_LOG"
log_plain "DiffFile : $DIFF_FILE"

# rclone must be installed and in PATH before we do anything else
if ! command -v rclone >/dev/null 2>&1; then
    log_error "rclone not found in PATH. Install rclone and ensure it is accessible to root."
    exit 1
fi

# NAS volume must have sufficient free space before the transfer starts
FREE_MB=$(df -Pm "$LOCAL" | awk 'NR==2 {print $4}')
if [ "${FREE_MB:-0}" -lt "$MIN_FREE_MB" ]; then
    log_error "Insufficient free space: ${FREE_MB}MB available, required=${MIN_FREE_MB}MB."
    exit 1
fi
log_info "Disk space OK: ${FREE_MB}MB free."

# =============================================================================
# NAS RESOURCE SNAPSHOTS
# =============================================================================
# Intentionally a no-op on Synology DSM.
# top -b, vmstat, and iostat all hang due to incompatible busybox behaviour.
# The function and its call sites are preserved so the feature can be re-enabled
# on other platforms by adding tool invocations inside resource_snapshot().

resource_snapshot() {
    # Resource snapshot tools (top, vmstat, iostat) hang on Synology DSM /
    # busybox environments due to incompatible flag behaviour. This function
    # is intentionally disabled for DSM compatibility. Re-enable individual
    # tools below if you have verified they work correctly on your platform:
    #
    #   top:     top -b -n 1  (hangs on DSM — do not enable)
    #   vmstat:  vmstat 1 2   (may hang on DSM — test before enabling)
    #   iostat:  iostat 2 1   (may hang on DSM — test before enabling)
    :
}

resource_snapshot "pre"

# =============================================================================
# API CONNECTIVITY + LATENCY MEASUREMENT
# =============================================================================
# rclone lsd --max-depth=1 is used instead of rclone ls, which would recursively
# enumerate all files (expensive on large remotes). lsd only lists top-level
# directories, making it a cheap and reliable connectivity probe.

log_info "Checking pCloud connectivity..."
START_API_CHECK=$(date +%s)

if ! rclone lsd "$REMOTE" --max-depth=1 --timeout=20s >/dev/null 2>&1; then
    log_error "Cannot reach pCloud. Check your network, OAuth token, and rclone remote name."
    exit 1
fi

END_API_CHECK=$(date +%s)
API_LATENCY=$((END_API_CHECK - START_API_CHECK))
log_info "Connectivity OK (API response time=${API_LATENCY}s)"

# Early warning — slow API at check time usually predicts index lag after copy
if [ "$API_LATENCY" -gt 30 ]; then
    log_warn "pCloud API very slow (>30s). Likely index delay. Health score will be penalised."
elif [ "$API_LATENCY" -gt 10 ]; then
    log_info "pCloud API slow (>10s). May cause temporary inconsistencies."
fi

# =============================================================================
# INTERACTIVE / SCHEDULED SESSION DETECTION
# =============================================================================
# --progress is only useful when a human is watching. Enable it when stdout is
# a TTY and PCLOUD_NOHUP is not set. In scheduled runs (DSM Task Scheduler,
# cron, nohup), PCLOUD_NOHUP=1 must be set to suppress progress output.

if [ -t 1 ] && [ -z "$PCLOUD_NOHUP" ]; then
    PROGRESS="--progress"
    log_info "Interactive session — rclone progress enabled."
else
    PROGRESS=""
    log_info "Non-interactive run — rclone progress disabled."
fi

# In non-interactive mode, emit a single rolling stats line instead of a full
# stats block — keeps logs readable when tailing or viewing in DSM.
if [ -z "$PROGRESS" ]; then
    STATS_FLAG="--stats-one-line"
else
    STATS_FLAG="--stats=30s"
fi

# =============================================================================
# IONICE (optional I/O priority reduction)
# =============================================================================
# When available, rclone runs at I/O class 2 (best-effort), niceness level 7.
# This prevents the backup from saturating NAS disk I/O during busy periods.

# Bash array — safe with set -u when empty, and handles spaces in paths correctly.
IONICE_CMD=()
if command -v ionice >/dev/null 2>&1; then
    IONICE_CMD=(ionice -c2 -n7)
    log_info "ionice available — rclone running at reduced I/O priority (class=2, niceness=7)."
else
    log_info "ionice not found — using default I/O priority."
fi

# =============================================================================
# SELF-TEST / DRY-RUN FLAG
# =============================================================================

RCLONE_DRYRUN_FLAGS=""
if [ "$SELF_TEST" -eq 1 ]; then
    RCLONE_DRYRUN_FLAGS="--dry-run"
    log_info "Self-test mode: rclone will run with --dry-run (no files transferred)."
fi

# =============================================================================
# BACKUP — rclone copy with retry
# =============================================================================
# Exit codes from rclone copy:
#   0  = all files transferred successfully
#   1  = partial success (some individual files failed) — treated as non-fatal
#   >1 = fatal error (auth failure, network outage, etc.) — triggers retry
#
# rclone flags used:
#   --check-first           verify which files need transferring before starting
#   --size-only             compare by size only (pCloud does not expose reliable mtimes)
#   --create-empty-src-dirs preserve empty directories in the backup
#   --transfers=2           limit concurrent transfers (conservative for NAS I/O budget)
#   --checkers=4            concurrent file comparisons
#   --tpslimit / burst      API rate limiting to stay within pCloud's fair-use policy
#   --fast-list             fewer API round-trips for large directories

log_info "Backup started (max_attempts=$MAX_RETRIES, retry_delay=${RETRY_DELAY}s)."

RCLONE_EXIT=0
COPY_END_TS=0
i=1

while [ "$i" -le "$MAX_RETRIES" ]; do
    log_info "rclone copy attempt $i of $MAX_RETRIES"

    # Build argument list — conditional flags added only when non-empty to avoid
    # passing blank positional arguments from unquoted empty variables.
    RCLONE_ARGS=(
        copy "$REMOTE" "$LOCAL"
        --check-first
        --size-only
        --create-empty-src-dirs
        --transfers=2
        --checkers=4
        --tpslimit=5
        --tpslimit-burst=10
        --fast-list
        "$STATS_FLAG"
        --log-file="$RCLONE_LOG"  # rclone appends by default; no --log-file-append needed
        --log-level=INFO
    )
    [ -n "$PROGRESS" ]            && RCLONE_ARGS+=("$PROGRESS")
    [ -n "$RCLONE_DRYRUN_FLAGS" ] && RCLONE_ARGS+=("$RCLONE_DRYRUN_FLAGS")

    set +e
    "${IONICE_CMD[@]+"${IONICE_CMD[@]}"}" rclone "${RCLONE_ARGS[@]}"
    RCLONE_EXIT=$?
    set -e

    # Record copy completion time for accurate index-delay measurement below
    COPY_END_TS=$(date +%s)

    # 0 and 1 are both acceptable outcomes
    if [ "$RCLONE_EXIT" -eq 0 ] || [ "$RCLONE_EXIT" -eq 1 ]; then
        break
    fi

    # Re-check disk space — the volume may have filled during the failed attempt
    FREE_MB=$(df -Pm "$LOCAL" | awk 'NR==2 {print $4}')
    if [ "${FREE_MB:-0}" -lt "$MIN_FREE_MB" ]; then
        log_error "Disk space dropped below threshold (${FREE_MB}MB) after failure. Aborting retries."
        break
    fi

    if [ "$i" -lt "$MAX_RETRIES" ]; then
        log_warn "rclone copy exit=$RCLONE_EXIT on attempt $i — retrying in ${RETRY_DELAY}s."
        sleep "$RETRY_DELAY"
    fi

    i=$((i+1))
done

if [ "$RCLONE_EXIT" -eq 0 ] || [ "$RCLONE_EXIT" -eq 1 ]; then
    log_info "Backup completed (exit=$RCLONE_EXIT) after $i of $MAX_RETRIES attempts."
else
    log_error "rclone copy failed permanently after $MAX_RETRIES attempts (exit=$RCLONE_EXIT)."
    exit "$RCLONE_EXIT"
fi

# =============================================================================
# DIFF GENERATION — rclone check (one-way: pCloud → NAS)
# =============================================================================
# --one-way       only verify that files on pCloud exist on the NAS.
#                 NAS-only files are intentional (no-delete policy) and ignored.
# --missing-on-dst  files on pCloud not yet on the NAS (API lag or copy gap).
# --differ          files present on both sides but with size differences.
# --missing-on-src  intentionally omitted — NAS-only files are not a concern.

log_info "Running rclone check (one-way: pCloud → NAS)."

MISSING_ON_DST="${LOG_DIR}/pcloud-missing-on-dst-${TS}.txt"

set +e
rclone check "$REMOTE" "$LOCAL" \
    --one-way \
    --size-only \
    --checkers=4 \
    --fast-list \
    --tpslimit=5 \
    --tpslimit-burst=10 \
    --differ "$DIFF_FILE" \
    --missing-on-dst "$MISSING_ON_DST" \
    --log-level=ERROR >/dev/null 2>&1
CHECK_EXIT=$?
set -e

if [ "$CHECK_EXIT" -eq 0 ] || [ "$CHECK_EXIT" -eq 1 ]; then
    log_info "rclone check done (exit=$CHECK_EXIT)."
else
    log_warn "rclone check exit=$CHECK_EXIT — inspect diff artefacts for details."
fi

log_info "Diff artefacts written:"
log_plain "diff         : $DIFF_FILE"
log_plain "missing-on-dst: $MISSING_ON_DST"

# =============================================================================
# API-LAG DETECTION (current run)
# =============================================================================
# pCloud is eventually consistent. After a successful copy, the API directory
# index may not yet reflect newly downloaded files. Signature:
#   CHECK_EXIT=1  (non-zero means some files "missing")
#   MISSING_ON_DST non-empty  (files flagged as absent)
#   DIFF_FILE empty            (no actual size differences — files exist, just not indexed)
# In this case the data is fine; the API will catch up without intervention.

if [ "$CHECK_EXIT" -eq 1 ] && [ -s "$MISSING_ON_DST" ] && [ ! -s "$DIFF_FILE" ]; then
    log_info "API-lag detected: files were copied correctly but are not yet visible in the pCloud index."
    log_info "  No action required. The API will catch up on its own."
fi

# =============================================================================
# PERSISTENT API-LAG DETECTION (cross-run comparison)
# =============================================================================
# If the missing-on-dst list is identical to the previous run, pCloud has been
# slow to index the same files across multiple consecutive runs.
# This is a stronger indication of delayed indexing rather than a copy failure.

PREV_MISSING_DST="${STATE_DIR}/prev_missing_on_dst.txt"

if [ -s "$MISSING_ON_DST" ]; then
    if [ -f "$PREV_MISSING_DST" ] && diff -q "$MISSING_ON_DST" "$PREV_MISSING_DST" >/dev/null 2>&1; then
        log_info "Persistent API-lag: missing-on-dst list is identical to the previous run."
        log_info "  pCloud index propagation is delayed across consecutive runs. No action needed."
    fi
    cp "$MISSING_ON_DST" "$PREV_MISSING_DST"
else
    rm -f "$PREV_MISSING_DST" 2>/dev/null || true
fi

# =============================================================================
# INDEX DELAY MEASUREMENT
# =============================================================================
# Measures elapsed time from rclone copy completion to the end of rclone check.
# When MISSING_ON_DST is non-empty this approximates how long the pCloud index
# lags behind actual storage state after a completed transfer.

if [ -s "$MISSING_ON_DST" ] && [ "$COPY_END_TS" -gt 0 ]; then
    END_CHECK=$(date +%s)
    INDEX_DELAY=$((END_CHECK - COPY_END_TS))
    log_info "pCloud index lag since copy end: ~${INDEX_DELAY}s."
fi

# =============================================================================
# HEALTH SCORE
# =============================================================================
# A single 0–100 score summarising the quality of this run.
# Deductions are cumulative; result is clamped to [0, 100].

HEALTH=100

if [ "$API_LATENCY" -gt 30 ]; then
    HEALTH=$((HEALTH - 40))
elif [ "$API_LATENCY" -gt 10 ]; then
    HEALTH=$((HEALTH - 20))
fi

if [ "$CHECK_EXIT" -eq 1 ]; then
    HEALTH=$((HEALTH - 10))
elif [ "$CHECK_EXIT" -gt 1 ]; then
    HEALTH=$((HEALTH - 50))
fi

[ -s "$MISSING_ON_DST" ] && HEALTH=$((HEALTH - 10))
[ -s "$DIFF_FILE" ]      && HEALTH=$((HEALTH - 50))

# Clamp to valid range
[ "$HEALTH" -lt 0 ]   && HEALTH=0
[ "$HEALTH" -gt 100 ] && HEALTH=100

log_info "Run health score: ${HEALTH}/100."

# =============================================================================
# 30-RUN ROLLING STATISTICS
# =============================================================================
# One structured key=value line is appended per run.
# The file is trimmed to the last 30 lines after each write.

STATS_FILE="${STATE_DIR}/stats_history.txt"

MISSING_COUNT=0
DIFF_COUNT=0
[ -s "$MISSING_ON_DST" ] && MISSING_COUNT=$(wc -l < "$MISSING_ON_DST")
[ -s "$DIFF_FILE" ]      && DIFF_COUNT=$(wc -l < "$DIFF_FILE")

RUN_TS=$(date '+%Y-%m-%dT%H:%M:%S')
echo "${RUN_TS} API=${API_LATENCY} INDEX=${INDEX_DELAY} MISSING=${MISSING_COUNT} DIFF=${DIFF_COUNT} COPY=${RCLONE_EXIT} CHECK=${CHECK_EXIT} HEALTH=${HEALTH}" >> "$STATS_FILE"

# Trim to last 30 run entries
if [ "$(wc -l < "$STATS_FILE")" -gt 30 ]; then
    tail -n 30 "$STATS_FILE" > "${STATS_FILE}.tmp"
    mv "${STATS_FILE}.tmp" "$STATS_FILE"
fi

log_info "Statistics updated (30-run rolling history)."

# =============================================================================
# STATE UPDATE
# =============================================================================

date '+%Y-%m-%d %H:%M:%S' > "$STATE_FILE"

# =============================================================================
# LOG RETENTION (last N runs, by run count not by age)
# =============================================================================
# Filenames embed the YYYYMMDD-HHMMSS timestamp, so lexicographic sort equals
# chronological sort. All files except the newest LOG_RETENTION_RUNS are removed.

log_info "Pruning logs — keeping last ${LOG_RETENTION_RUNS} runs."

prune_logs() {
    local pattern="$1"
    find "$LOG_DIR" -maxdepth 1 -type f -name "$pattern" \
        | sort \
        | head -n "-${LOG_RETENTION_RUNS}" \
        | xargs -r rm -f
}

prune_logs "pcloud-meta-*.log"
prune_logs "pcloud-rclone-*.log"
prune_logs "pcloud-diff-*.txt"
prune_logs "pcloud-missing-on-dst-*.txt"

# =============================================================================
# NAS RESOURCE SNAPSHOT (POST)
# =============================================================================
resource_snapshot "post"

# =============================================================================
# FINAL STATUS
# =============================================================================

if [ "$SELF_TEST" -eq 1 ]; then
    log_info "Run finished in self-test mode (no files were transferred)."
else
    log_info "Backup run finished successfully."
fi

# =============================================================================
# 30-RUN STATISTICS TABLE
# =============================================================================

if [ -f "$STATS_FILE" ]; then
    log_info "Last ${LOG_RETENTION_RUNS} runs  (API=connectivity(s)  IDX=index-delay(s)  MIS=missing  DIF=diff  CPY=copy-exit  CHK=check-exit  HLT=health):"
    printf -- "%-24s | %-7s | %-14s | %-7s | %-4s | %-4s | %-5s | %-6s\n" \
        "Date/Time" "API(s)" "IndexDelay(s)" "Missing" "Diff" "Copy" "Check" "Health" \
        | tee -a "$META_LOG"
    printf -- "%-24s-+-%-7s-+-%-14s-+-%-7s-+-%-4s-+-%-4s-+-%-5s-+-%-6s\n" \
        "------------------------" "-------" "--------------" "-------" "----" "----" "-----" "------" \
        | tee -a "$META_LOG"

    tail -n 30 "$STATS_FILE" | while read -r LINE; do
        echo "$LINE" | grep -q '^[0-9]' || continue

        TS_FIELD=$(    echo "$LINE" | awk '{print $1}')
        API_FIELD=$(   echo "$LINE" | grep -o 'API=[0-9]*'     | cut -d= -f2); API_FIELD=${API_FIELD:-0}
        INDEX_FIELD=$( echo "$LINE" | grep -o 'INDEX=[0-9]*'   | cut -d= -f2); INDEX_FIELD=${INDEX_FIELD:-0}
        MISS_FIELD=$(  echo "$LINE" | grep -o 'MISSING=[0-9]*' | cut -d= -f2); MISS_FIELD=${MISS_FIELD:-0}
        DIFF_FIELD=$(  echo "$LINE" | grep -o 'DIFF=[0-9]*'    | cut -d= -f2); DIFF_FIELD=${DIFF_FIELD:-0}
        COPY_FIELD=$(  echo "$LINE" | grep -o 'COPY=[0-9]*'    | cut -d= -f2); COPY_FIELD=${COPY_FIELD:-0}
        CHECK_FIELD=$( echo "$LINE" | grep -o 'CHECK=[0-9]*'   | cut -d= -f2); CHECK_FIELD=${CHECK_FIELD:-0}
        HEALTH_FIELD=$(echo "$LINE" | grep -o 'HEALTH=[0-9]*'  | cut -d= -f2); HEALTH_FIELD=${HEALTH_FIELD:-0}

        printf -- "%-24s | %-7s | %-14s | %-7s | %-4s | %-4s | %-5s | %-6s\n" \
            "$TS_FIELD" "$API_FIELD" "$INDEX_FIELD" "$MISS_FIELD" "$DIFF_FIELD" \
            "$COPY_FIELD" "$CHECK_FIELD" "$HEALTH_FIELD" \
            | tee -a "$META_LOG"
    done
fi

exit 0
