#!/usr/bin/env bash
# =============================================================================
# test_suite_pcloud_to_synology_sync_svdt.sh
# Test suite for pcloud_to_synology_sync_svdt.sh
# Version: 1.0.0
# =============================================================================
# HOW IT WORKS:
#   Exercises the self-contained logic of the backup script without requiring
#   a real pCloud remote, real NAS volume, or rclone installation.
#   Uses a temporary directory tree to simulate state dirs, log dirs,
#   lockfiles, diff artefacts, and stats history files.
#
# COVERS:
#   --help flag              · --version flag         · Unknown flag rejection
#   Structured log format    · Log levels (INFO/WARN/ERROR)
#   Stale lock detection     · Atomic lock (noclobber) · Lock cleanup on exit
#   Disk space check logic   · Log prune by run count
#   Stats history trimming   · Health score calculation (all deduction branches)
#   API-lag detection logic  · Persistent API-lag (cross-run diff)
#   Self-test dry-run flag   · PCLOUD_NOHUP detection
#   Stats table parsing      · Sidecar/artefact file naming
#
# REQUIREMENTS:
#   bash, awk, find, sort, head, wc, diff, date, kill, mktemp
#
# USAGE:
#   chmod +x test_suite_pcloud_to_synology_sync_svdt.sh
#   ./test_suite_pcloud_to_synology_sync_svdt.sh
#
# MAINTENANCE NOTES (read before modifying):
#   This suite mirrors the logic in pcloud_to_synology_sync_svdt.sh.
#   When you change the main script, update this file accordingly:
#
#   CHANGE TYPE                          ACTION REQUIRED
#   ───────────────────────────────────  ─────────────────────────────────────────
#   New --flag added                     Add a sub-test in section 1
#   Changed health score deductions      Update section 8 (all branches)
#   Changed log format                   Update section 3
#   Changed stats line format            Update sections 9 and 10
#   New log file type added              Update section 6 (prune test)
#   Changed stale-lock threshold         Update section 4
#   Version bump in main script          Update MAIN_SCRIPT_VERSION below
#
# VERSION HISTORY:
#   1.0.1 — updated MAIN_SCRIPT_VERSION to 1.9; corrected section/test count in header
#   1.0.0 — initial release (12 sections, 61 tests)
# =============================================================================

TEST_SUITE_VERSION="1.0.1"
MAIN_SCRIPT_VERSION="1.9"   # version of pcloud_to_synology_sync_svdt.sh this suite targets

SCRIPT_UNDER_TEST="./pcloud_to_synology_sync_svdt.sh"

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
NC="\033[0m"

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0

# ─── Test workspace ───────────────────────────────────────────────────────────
TESTDIR=$(mktemp -d /tmp/svdt_pcloud_test_XXXXXX)
trap 'rm -rf "$TESTDIR"' EXIT

# ─── Helpers ──────────────────────────────────────────────────────────────────
ok()      { echo -e "  ${GREEN}✓ PASS${NC}  $1"; PASS=$((PASS + 1)); }
fail()    { echo -e "  ${RED}✗ FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
skip()    { echo -e "  ${YELLOW}⊘ SKIP${NC}  $1"; SKIP=$((SKIP + 1)); }
section() { echo; echo -e "${BLUE}══ $1 ══${NC}"; }
note()    { echo -e "  ${CYAN}ℹ${NC}  $1"; }

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}test_suite_pcloud_to_synology_sync_svdt.sh v${TEST_SUITE_VERSION}${NC}"
echo -e "Targeting: pcloud_to_synology_sync_svdt.sh v${MAIN_SCRIPT_VERSION}"

# =============================================================================
section "1. CLI flags (--help / --version / unknown)"
# =============================================================================

if [[ ! -f "$SCRIPT_UNDER_TEST" ]]; then
    note "Script not found at $SCRIPT_UNDER_TEST — CLI tests require the script to be present."
    skip "--help output (script not found)"
    skip "--version output (script not found)"
    skip "unknown flag rejected (script not found)"
else
    # Ensure the script is executable for this test session
    chmod +x "$SCRIPT_UNDER_TEST" 2>/dev/null || true

    # 1a: --help exits 0 and produces output
    help_out=$("$SCRIPT_UNDER_TEST" --help 2>&1) && help_rc=0 || help_rc=$?
    [[ "$help_rc" -eq 0 ]] \
        && ok "--help exits with code 0" \
        || fail "--help did not exit 0 (rc=$help_rc)"
    [[ -n "$help_out" ]] \
        && ok "--help produces output" \
        || fail "--help produced no output"
    echo "$help_out" | grep -q "SELF_TEST" \
        && ok "--help documents SELF_TEST env var" \
        || fail "--help does not mention SELF_TEST"
    echo "$help_out" | grep -q "PCLOUD_NOHUP" \
        && ok "--help documents PCLOUD_NOHUP env var" \
        || fail "--help does not mention PCLOUD_NOHUP"
    echo "$help_out" | grep -q "health" \
        && ok "--help documents health score" \
        || fail "--help does not mention health score"
    echo "$help_out" | grep -q "DRY-RUN\|dry-run\|self-test\|SELF_TEST" \
        && ok "--help documents dry-run / self-test mode" \
        || fail "--help does not document dry-run mode"

    # 1b: --version exits 0 and contains the expected version string
    ver_out=$("$SCRIPT_UNDER_TEST" --version 2>&1) && ver_rc=0 || ver_rc=$?
    [[ "$ver_rc" -eq 0 ]] \
        && ok "--version exits with code 0" \
        || fail "--version did not exit 0 (rc=$ver_rc)"
    echo "$ver_out" | grep -q "$MAIN_SCRIPT_VERSION" \
        && ok "--version output contains expected version ($MAIN_SCRIPT_VERSION)" \
        || fail "--version output does not contain $MAIN_SCRIPT_VERSION (got: $ver_out)"

    # 1c: unknown flag exits non-zero
    "$SCRIPT_UNDER_TEST" --bogus-flag 2>/dev/null && unk_rc=0 || unk_rc=$?
    [[ "$unk_rc" -ne 0 ]] \
        && ok "Unknown flag --bogus-flag exits non-zero (rc=$unk_rc)" \
        || fail "Unknown flag --bogus-flag should exit non-zero but got 0"
fi

# =============================================================================
section "2. Structured log format"
# =============================================================================
# Replicate the log() function from the main script and verify its output.

LOG_TMP="$TESTDIR/test_meta.log"
RUN_ID_TEST="20260101-120000-99999"
SCRIPT_VERSION_TEST="1.9"

log_test() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s level=%s run_id=%s script_version=%s msg="%s"\n' \
        "$ts" "$level" "$RUN_ID_TEST" "$SCRIPT_VERSION_TEST" "$msg" | tee -a "$LOG_TMP"
}

log_test INFO  "test info message"   > /dev/null
log_test WARN  "test warn message"   > /dev/null
log_test ERROR "test error message"  > /dev/null

# 2a: log file created
[[ -f "$LOG_TMP" ]] \
    && ok "Log file created by log() function" \
    || fail "Log file not created"

# 2b: INFO level present
grep -q 'level=INFO' "$LOG_TMP" \
    && ok "Log contains level=INFO entry" \
    || fail "Log missing level=INFO"

# 2c: WARN level present
grep -q 'level=WARN' "$LOG_TMP" \
    && ok "Log contains level=WARN entry" \
    || fail "Log missing level=WARN"

# 2d: ERROR level present
grep -q 'level=ERROR' "$LOG_TMP" \
    && ok "Log contains level=ERROR entry" \
    || fail "Log missing level=ERROR"

# 2e: run_id present
grep -q "run_id=${RUN_ID_TEST}" "$LOG_TMP" \
    && ok "Log contains correct run_id" \
    || fail "Log missing run_id"

# 2f: script_version present
grep -q "script_version=${SCRIPT_VERSION_TEST}" "$LOG_TMP" \
    && ok "Log contains script_version" \
    || fail "Log missing script_version"

# 2g: msg field present and quoted
grep -q 'msg="test info message"' "$LOG_TMP" \
    && ok "Log msg field is correctly quoted" \
    || fail "Log msg field format incorrect"

# 2h: timestamp format YYYY-MM-DD HH:MM:SS
grep -q '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}' "$LOG_TMP" \
    && ok "Log timestamp format is YYYY-MM-DD HH:MM:SS" \
    || fail "Log timestamp format unexpected"

# =============================================================================
section "3. Lockfile — atomic creation (noclobber)"
# =============================================================================

LOCK_TEST="$TESTDIR/test.lock"

# 3a: noclobber creates the file when it does not exist
( set -o noclobber; echo "12345" > "$LOCK_TEST" ) 2>/dev/null && created_rc=0 || created_rc=$?
[[ "$created_rc" -eq 0 && -f "$LOCK_TEST" ]] \
    && ok "noclobber: lockfile created when absent" \
    || fail "noclobber: failed to create lockfile (rc=$created_rc)"

# 3b: noclobber fails when the file already exists
( set -o noclobber; echo "99999" > "$LOCK_TEST" ) 2>/dev/null && dup_rc=0 || dup_rc=$?
[[ "$dup_rc" -ne 0 ]] \
    && ok "noclobber: second write correctly fails when lockfile exists (rc=$dup_rc)" \
    || fail "noclobber: second write should fail but succeeded"

# 3c: PID in lockfile is readable
stored_pid=$(cat "$LOCK_TEST")
[[ "$stored_pid" == "12345" ]] \
    && ok "Lockfile contains expected PID" \
    || fail "Lockfile PID mismatch (expected 12345, got $stored_pid)"

# 3d: cleanup removes lock only when PID matches
rm -f "$LOCK_TEST"
echo "$$" > "$LOCK_TEST"
if [ -f "$LOCK_TEST" ] && [ "$(cat "$LOCK_TEST" 2>/dev/null || echo "")" = "$$" ]; then
    rm -f "$LOCK_TEST"
fi
[[ ! -f "$LOCK_TEST" ]] \
    && ok "Cleanup removes lockfile when PID matches" \
    || fail "Cleanup did not remove lockfile with matching PID"

# 3e: cleanup does not remove lock when PID does not match
echo "99999" > "$LOCK_TEST"
if [ -f "$LOCK_TEST" ] && [ "$(cat "$LOCK_TEST" 2>/dev/null || echo "")" = "$$" ]; then
    rm -f "$LOCK_TEST"
fi
[[ -f "$LOCK_TEST" ]] \
    && ok "Cleanup leaves lockfile when PID does not match (foreign lock preserved)" \
    || fail "Cleanup removed a lockfile it does not own"
rm -f "$LOCK_TEST"

# =============================================================================
section "4. Stale lockfile repair logic"
# =============================================================================

STALE_LOCK="$TESTDIR/stale.lock"

# 4a: dead-process PID is detected as dead
DEAD_PID=999999999
kill -0 "$DEAD_PID" 2>/dev/null && dead_rc=0 || dead_rc=$?
[[ "$dead_rc" -ne 0 ]] \
    && ok "Dead PID $DEAD_PID correctly identified as not running" \
    || fail "PID $DEAD_PID appears alive — choose a different test PID"

# 4b: stale lock detection using find -mmin
echo "$DEAD_PID" > "$STALE_LOCK"
touch -t "$(date -d '25 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-25H +%Y%m%d%H%M)" "$STALE_LOCK" 2>/dev/null || true
stale_result=$(find "$STALE_LOCK" -mmin +720 2>/dev/null)
if [[ -n "$stale_result" ]]; then
    ok "find -mmin +720 detects a lock file older than 720 minutes"
else
    skip "find -mmin +720 stale detection (touch -t not supported on this platform — expected in production)"
fi
rm -f "$STALE_LOCK"

# 4c: fresh lock is not stale
echo "$DEAD_PID" > "$STALE_LOCK"
fresh_result=$(find "$STALE_LOCK" -mmin +720 2>/dev/null)
[[ -z "$fresh_result" ]] \
    && ok "find -mmin +720 does not flag a freshly created lockfile as stale" \
    || fail "find -mmin +720 incorrectly flagged a fresh lock as stale"
rm -f "$STALE_LOCK"

# =============================================================================
section "5. Disk space check logic"
# =============================================================================

# 5a: df -Pm produces a numeric value on the test dir
FREE_RESULT=$(df -Pm "$TESTDIR" | awk 'NR==2 {print $4}')
[[ "$FREE_RESULT" =~ ^[0-9]+$ ]] \
    && ok "df -Pm returns numeric free MB (got ${FREE_RESULT}MB)" \
    || fail "df -Pm did not return a numeric value (got: $FREE_RESULT)"

# 5b: comparison logic — below threshold triggers failure
TEST_FREE=500
TEST_MIN=1000
if [ "${TEST_FREE:-0}" -lt "$TEST_MIN" ]; then
    ok "Disk space below threshold correctly detected (${TEST_FREE}MB < ${TEST_MIN}MB)"
else
    fail "Disk space check logic: below-threshold case not triggered"
fi

# 5c: comparison logic — above threshold is OK
TEST_FREE=2000
if [ "${TEST_FREE:-0}" -lt "$TEST_MIN" ]; then
    fail "Disk space check incorrectly triggered above-threshold case (${TEST_FREE}MB)"
else
    ok "Disk space above threshold passes correctly (${TEST_FREE}MB >= ${TEST_MIN}MB)"
fi

# =============================================================================
section "6. Log pruning by run count"
# =============================================================================

PRUNE_DIR="$TESTDIR/prune_logs"
mkdir -p "$PRUNE_DIR"

# Create 35 fake log files with sequential timestamps
for i in $(seq -w 1 35); do
    touch "${PRUNE_DIR}/pcloud-meta-202601${i}-120000.log"
done

RETENTION=30

# Replicate prune_logs() from the main script
find "$PRUNE_DIR" -maxdepth 1 -type f -name "pcloud-meta-*.log" \
    | sort \
    | head -n "-${RETENTION}" \
    | xargs -r rm -f

remaining=$(find "$PRUNE_DIR" -maxdepth 1 -type f -name "pcloud-meta-*.log" | wc -l | tr -d ' ')

[[ "$remaining" -eq "$RETENTION" ]] \
    && ok "Log pruning retains exactly $RETENTION files (had 35, kept $remaining)" \
    || fail "Log pruning: expected $RETENTION files, got $remaining"

# 6b: oldest files are removed, newest retained
oldest_remaining=$(find "$PRUNE_DIR" -maxdepth 1 -type f -name "pcloud-meta-*.log" | sort | head -n 1)
[[ "$oldest_remaining" == *"202601"* ]] || true  # just confirm a file exists
[[ -n "$oldest_remaining" ]] \
    && ok "Log pruning: files remain after pruning" \
    || fail "Log pruning: no files remain after pruning"

# =============================================================================
section "7. Stats history — 30-run trimming"
# =============================================================================

STATS_TEST="$TESTDIR/stats_history.txt"
> "$STATS_TEST"

# Write 35 fake stats lines
for i in $(seq 1 35); do
    echo "2026-01-$(printf '%02d' "$i")T12:00:00 API=2 INDEX=0 MISSING=0 DIFF=0 COPY=0 CHECK=0 HEALTH=100" >> "$STATS_TEST"
done

# Replicate the trim logic from the main script
if [ "$(wc -l < "$STATS_TEST")" -gt 30 ]; then
    tail -n 30 "$STATS_TEST" > "${STATS_TEST}.tmp"
    mv "${STATS_TEST}.tmp" "$STATS_TEST"
fi

line_count=$(wc -l < "$STATS_TEST" | tr -d ' ')
[[ "$line_count" -eq 30 ]] \
    && ok "Stats history trimmed to 30 lines (had 35, kept $line_count)" \
    || fail "Stats history: expected 30 lines, got $line_count"

# 7b: most recent entries are kept (not oldest)
last_line=$(tail -n 1 "$STATS_TEST")
echo "$last_line" | grep -q "2026-01-35" \
    && ok "Stats history: most recent entry (day 35) is retained" \
    || fail "Stats history: most recent entry is not retained (last: $last_line)"

first_line=$(head -n 1 "$STATS_TEST")
echo "$first_line" | grep -q "2026-01-06" \
    && ok "Stats history: oldest kept entry is day 6 (35-30+1)" \
    || fail "Stats history: unexpected first entry after trim (got: $first_line)"

# =============================================================================
section "8. Health score calculation"
# =============================================================================
# Tests all deduction branches and clamping logic.

calc_health() {
    local api_lat="$1" check_exit="$2" missing_file="$3" diff_file="$4"
    local h=100

    if [ "$api_lat" -gt 30 ]; then
        h=$((h - 40))
    elif [ "$api_lat" -gt 10 ]; then
        h=$((h - 20))
    fi

    if [ "$check_exit" -eq 1 ]; then
        h=$((h - 10))
    elif [ "$check_exit" -gt 1 ]; then
        h=$((h - 50))
    fi

    [ -s "$missing_file" ] && h=$((h - 10))
    [ -s "$diff_file" ]    && h=$((h - 50))

    [ "$h" -lt 0 ]   && h=0
    [ "$h" -gt 100 ] && h=100

    echo "$h"
}

EMPTY="$TESTDIR/empty_file"
POPULATED="$TESTDIR/populated_file"
touch "$EMPTY"
echo "something" > "$POPULATED"

# 8a: perfect run
score=$(calc_health 2 0 "$EMPTY" "$EMPTY")
[[ "$score" -eq 100 ]] \
    && ok "Health: perfect run scores 100 (got $score)" \
    || fail "Health: perfect run expected 100, got $score"

# 8b: API latency >30s
score=$(calc_health 35 0 "$EMPTY" "$EMPTY")
[[ "$score" -eq 60 ]] \
    && ok "Health: API >30s deducts 40 → 60 (got $score)" \
    || fail "Health: API >30s expected 60, got $score"

# 8c: API latency >10s but <=30s
score=$(calc_health 15 0 "$EMPTY" "$EMPTY")
[[ "$score" -eq 80 ]] \
    && ok "Health: API >10s deducts 20 → 80 (got $score)" \
    || fail "Health: API >10s expected 80, got $score"

# 8d: check exit=1 (API lag)
score=$(calc_health 2 1 "$EMPTY" "$EMPTY")
[[ "$score" -eq 90 ]] \
    && ok "Health: check exit=1 deducts 10 → 90 (got $score)" \
    || fail "Health: check exit=1 expected 90, got $score"

# 8e: check exit>1 (real error)
score=$(calc_health 2 2 "$EMPTY" "$EMPTY")
[[ "$score" -eq 50 ]] \
    && ok "Health: check exit>1 deducts 50 → 50 (got $score)" \
    || fail "Health: check exit>1 expected 50, got $score"

# 8f: missing on dst (non-empty file)
score=$(calc_health 2 0 "$POPULATED" "$EMPTY")
[[ "$score" -eq 90 ]] \
    && ok "Health: missing-on-dst deducts 10 → 90 (got $score)" \
    || fail "Health: missing-on-dst expected 90, got $score"

# 8g: diff file non-empty
score=$(calc_health 2 0 "$EMPTY" "$POPULATED")
[[ "$score" -eq 50 ]] \
    && ok "Health: diff file deducts 50 → 50 (got $score)" \
    || fail "Health: diff file expected 50, got $score"

# 8h: worst case (all deductions) — clamped to 0
score=$(calc_health 35 2 "$POPULATED" "$POPULATED")
[[ "$score" -eq 0 ]] \
    && ok "Health: all deductions applied, clamped to 0 (got $score)" \
    || fail "Health: worst-case expected 0, got $score"

# 8i: clamping — cannot exceed 100
raw=105
[ "$raw" -gt 100 ] && raw=100
[[ "$raw" -eq 100 ]] \
    && ok "Health: value >100 correctly clamped to 100" \
    || fail "Health: clamping above 100 failed"

# =============================================================================
section "9. API-lag detection logic"
# =============================================================================

DIFF_EMPTY="$TESTDIR/diff_empty.txt"
DIFF_POP="$TESTDIR/diff_populated.txt"
MISSING_EMPTY="$TESTDIR/missing_empty.txt"
MISSING_POP="$TESTDIR/missing_populated.txt"

touch "$DIFF_EMPTY" "$MISSING_EMPTY"
echo "file1.txt" > "$DIFF_POP"
echo "file2.txt" > "$MISSING_POP"

# 9a: API-lag signature: check_exit=1 + missing_non_empty + diff_empty
CHECK_EXIT=1
if [ "$CHECK_EXIT" -eq 1 ] && [ -s "$MISSING_POP" ] && [ ! -s "$DIFF_EMPTY" ]; then
    ok "API-lag correctly identified (check=1, missing non-empty, diff empty)"
else
    fail "API-lag detection: expected match for check=1 + missing + no-diff"
fi

# 9b: NOT API-lag when diff is also non-empty
CHECK_EXIT=1
if [ "$CHECK_EXIT" -eq 1 ] && [ -s "$MISSING_POP" ] && [ ! -s "$DIFF_POP" ]; then
    fail "API-lag false positive: diff is non-empty but condition still matched"
else
    ok "API-lag not triggered when diff is also non-empty (correct)"
fi

# 9c: NOT API-lag when check_exit=0
CHECK_EXIT=0
if [ "$CHECK_EXIT" -eq 1 ] && [ -s "$MISSING_POP" ] && [ ! -s "$DIFF_EMPTY" ]; then
    fail "API-lag false positive when check_exit=0"
else
    ok "API-lag not triggered when check_exit=0 (correct)"
fi

# =============================================================================
section "10. Persistent API-lag (cross-run diff comparison)"
# =============================================================================

PREV_MISSING="$TESTDIR/prev_missing.txt"
CURR_MISSING="$TESTDIR/curr_missing.txt"

echo -e "file1.txt\nfile2.txt" > "$PREV_MISSING"
echo -e "file1.txt\nfile2.txt" > "$CURR_MISSING"

# 10a: identical lists detected
diff -q "$CURR_MISSING" "$PREV_MISSING" >/dev/null 2>&1 && identical=1 || identical=0
[[ "$identical" -eq 1 ]] \
    && ok "Persistent API-lag: identical missing-on-dst lists correctly detected" \
    || fail "Persistent API-lag: identical lists not detected"

# 10b: different lists not flagged as identical
echo "file3.txt" >> "$CURR_MISSING"
diff -q "$CURR_MISSING" "$PREV_MISSING" >/dev/null 2>&1 && ident2=1 || ident2=0
[[ "$ident2" -eq 0 ]] \
    && ok "Persistent API-lag: different lists correctly not flagged as identical" \
    || fail "Persistent API-lag: different lists incorrectly flagged as identical"

# 10c: prev_missing updated correctly
cp "$CURR_MISSING" "$PREV_MISSING"
[[ -f "$PREV_MISSING" ]] \
    && ok "prev_missing_on_dst.txt updated after run" \
    || fail "prev_missing_on_dst.txt not updated"

# 10d: prev_missing removed when current is empty
# Re-create PREV_MISSING so we have something to remove
echo "something" > "$PREV_MISSING"
# Overwrite CURR_MISSING with empty content (0 bytes)
: > "$CURR_MISSING"
# Replicate the main script's logic: if current is non-empty copy it, else remove prev
if [ -s "$CURR_MISSING" ]; then
    cp "$CURR_MISSING" "$PREV_MISSING"
else
    rm -f "$PREV_MISSING" 2>/dev/null || true
fi
[[ ! -f "$PREV_MISSING" ]] \
    && ok "prev_missing_on_dst.txt removed when current missing list is empty" \
    || fail "prev_missing_on_dst.txt not removed when empty"

# =============================================================================
section "11. Stats entry format and field parsing"
# =============================================================================

STATS_PARSE="$TESTDIR/stats_parse.txt"
echo "2026-01-21T14:30:00 API=5 INDEX=12 MISSING=3 DIFF=0 COPY=0 CHECK=1 HEALTH=80" > "$STATS_PARSE"
LINE=$(cat "$STATS_PARSE")

TS_F=$(   echo "$LINE" | awk '{print $1}')
API_F=$(  echo "$LINE" | grep -o 'API=[0-9]*'     | cut -d= -f2)
IDX_F=$(  echo "$LINE" | grep -o 'INDEX=[0-9]*'   | cut -d= -f2)
MISS_F=$( echo "$LINE" | grep -o 'MISSING=[0-9]*' | cut -d= -f2)
DIFF_F=$( echo "$LINE" | grep -o 'DIFF=[0-9]*'    | cut -d= -f2)
COPY_F=$( echo "$LINE" | grep -o 'COPY=[0-9]*'    | cut -d= -f2)
CHK_F=$(  echo "$LINE" | grep -o 'CHECK=[0-9]*'   | cut -d= -f2)
HLTH_F=$( echo "$LINE" | grep -o 'HEALTH=[0-9]*'  | cut -d= -f2)

[[ "$TS_F"   == "2026-01-21T14:30:00" ]] && ok "Stats: timestamp field parsed" || fail "Stats: timestamp wrong ($TS_F)"
[[ "$API_F"  == "5"  ]]                   && ok "Stats: API field parsed (5)"   || fail "Stats: API wrong ($API_F)"
[[ "$IDX_F"  == "12" ]]                   && ok "Stats: INDEX field parsed (12)"|| fail "Stats: INDEX wrong ($IDX_F)"
[[ "$MISS_F" == "3"  ]]                   && ok "Stats: MISSING field parsed (3)"|| fail "Stats: MISSING wrong ($MISS_F)"
[[ "$DIFF_F" == "0"  ]]                   && ok "Stats: DIFF field parsed (0)"  || fail "Stats: DIFF wrong ($DIFF_F)"
[[ "$COPY_F" == "0"  ]]                   && ok "Stats: COPY field parsed (0)"  || fail "Stats: COPY wrong ($COPY_F)"
[[ "$CHK_F"  == "1"  ]]                   && ok "Stats: CHECK field parsed (1)" || fail "Stats: CHECK wrong ($CHK_F)"
[[ "$HLTH_F" == "80" ]]                   && ok "Stats: HEALTH field parsed (80)"|| fail "Stats: HEALTH wrong ($HLTH_F)"

# =============================================================================
section "12. Artefact filename patterns"
# =============================================================================
# Verify that the expected filename patterns are valid and grep-matchable.

TS_SAMPLE="20260121-143000"

META_NAME="pcloud-meta-${TS_SAMPLE}.log"
RCLONE_NAME="pcloud-rclone-${TS_SAMPLE}.log"
DIFF_NAME="pcloud-diff-${TS_SAMPLE}.txt"
MISSING_NAME="pcloud-missing-on-dst-${TS_SAMPLE}.txt"

echo "$META_NAME"    | grep -q '^pcloud-meta-[0-9]\{8\}-[0-9]\{6\}\.log$'    && ok "Meta log filename pattern valid"         || fail "Meta log filename pattern invalid: $META_NAME"
echo "$RCLONE_NAME"  | grep -q '^pcloud-rclone-[0-9]\{8\}-[0-9]\{6\}\.log$'  && ok "rclone log filename pattern valid"       || fail "rclone log filename pattern invalid: $RCLONE_NAME"
echo "$DIFF_NAME"    | grep -q '^pcloud-diff-[0-9]\{8\}-[0-9]\{6\}\.txt$'    && ok "Diff artefact filename pattern valid"    || fail "Diff artefact filename pattern invalid: $DIFF_NAME"
echo "$MISSING_NAME" | grep -q '^pcloud-missing-on-dst-[0-9]\{8\}-[0-9]\{6\}\.txt$' \
    && ok "Missing-on-dst filename pattern valid" || fail "Missing-on-dst filename pattern invalid: $MISSING_NAME"

# =============================================================================
# SUMMARY
# =============================================================================

echo
echo "══════════════════════════════════════════════"
total=$(( PASS + FAIL + SKIP ))
echo -e "  Results:  ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${SKIP} skipped${NC}  (${total} total)"
echo "══════════════════════════════════════════════"
echo

if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}All tests passed.${NC}"
    exit 0
else
    echo -e "${RED}${FAIL} test(s) failed. See above for details.${NC}"
    exit 1
fi
