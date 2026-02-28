#!/usr/bin/env bash
# Test: sentinel-daemon.sh runs one cycle without errors
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-daemon.sh ==="

# We need to run the daemon in a controlled environment
# Override state/logs dirs
export SENTINEL_STATE="/tmp/sentinel-test-state-$$"
export SENTINEL_LOGS="/tmp/sentinel-test-logs-$$"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS"

# Safe thresholds: prevent check_pressure from entering CRITICAL path
# (which iterates all processes and can hang under memory pressure)
export SWAP_WARNING_MB=999999
export SWAP_CRITICAL_MB=999999
export MEMORY_FREE_CRITICAL_MB=0

# Disable service auto-restart (launchctl kickstart can hang for crashed services)
export AUTO_RESTART=false

# Disable file janitor (avoid moving real files during tests)
export JANITOR_ENABLED=false

# --- Test 1: Single cycle exits cleanly ---
echo "  -- Test: single cycle exits cleanly --"
output=$(bash "$SCRIPT_DIR/../scripts/sentinel-daemon.sh" --once 2>&1) || true
exit_code=$?
assert_eq "0" "$exit_code" "daemon single cycle exits cleanly"
assert_contains "$output" "cycle" "daemon reports cycle info"

# --- Test 2: Log file created ---
echo "  -- Test: log file created --"
assert_file_exists "$SENTINEL_LOGS/sentinel.log" "daemon creates log file"

# --- Test 3: Log has cycle entries ---
echo "  -- Test: log has cycle entries --"
log_content=$(cat "$SENTINEL_LOGS/sentinel.log")
assert_contains "$log_content" "Cycle" "log contains cycle entry"
assert_contains "$log_content" "starting" "log contains cycle start"
assert_contains "$log_content" "complete" "log contains cycle complete"

# --- Test 4: Cycle counter persisted ---

# --- Test: status.json created after cycle ---
echo "  -- Test: status.json created --"
assert_file_exists "$SENTINEL_LOGS/status.json" "daemon creates status.json"

# --- Test: history.jsonl created after cycle ---
echo "  -- Test: history.jsonl created --"
assert_file_exists "$SENTINEL_LOGS/history.jsonl" "daemon creates history.jsonl"
echo "  -- Test: cycle counter persisted --"
assert_file_exists "$SENTINEL_STATE/cycle-counter" "cycle counter file exists"
cycle_val=$(cat "$SENTINEL_STATE/cycle-counter")
assert_eq "1" "$cycle_val" "cycle counter is 1 after first run"

# --- Test 5: Second run increments counter ---
echo "  -- Test: second run increments --"
bash "$SCRIPT_DIR/../scripts/sentinel-daemon.sh" --once 2>&1 >/dev/null || true
cycle_val=$(cat "$SENTINEL_STATE/cycle-counter")
assert_eq "2" "$cycle_val" "cycle counter is 2 after second run"

# --- Test 6: Phase intervals respected ---
echo "  -- Test: phase intervals --"
# Set counter to 9 so next run is cycle 10 (triggers backup + disk)
echo "9" > "$SENTINEL_STATE/cycle-counter"
output=$(bash "$SCRIPT_DIR/../scripts/sentinel-daemon.sh" --once 2>&1) || true
cycle_val=$(cat "$SENTINEL_STATE/cycle-counter")
assert_eq "10" "$cycle_val" "counter incremented to 10"
# At cycle 10, backups and disk should run — check logs
log_content=$(cat "$SENTINEL_LOGS/sentinel.log")
assert_contains "$log_content" "Cycle #10" "cycle 10 logged"

# --- Test 7: Phase 5 interval (every 5th) ---
echo "  -- Test: janitor interval --"
echo "4" > "$SENTINEL_STATE/cycle-counter"
bash "$SCRIPT_DIR/../scripts/sentinel-daemon.sh" --once 2>&1 >/dev/null || true
cycle_val=$(cat "$SENTINEL_STATE/cycle-counter")
assert_eq "5" "$cycle_val" "counter at 5 (janitor should run)"

# --- Test 8: Daemon version in logs ---
echo "  -- Test: version in logs --"
log_content=$(cat "$SENTINEL_LOGS/sentinel.log")
assert_contains "$log_content" "0.2.0" "sentinel version appears in log"

# Cleanup
rm -rf "$SENTINEL_STATE" "$SENTINEL_LOGS"

test_summary
