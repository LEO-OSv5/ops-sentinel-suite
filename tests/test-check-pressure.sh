#!/usr/bin/env bash
# ================================================================================
# TEST: check-pressure.sh — Memory/swap pressure detection with tiered auto-kill
# ================================================================================
# Mocks sysctl, vm_stat, ps, kill, pkill, sentinel_notify to test pressure logic
# without touching real system state.
# ================================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-pressure.sh ==="

# =============================================================================
# TEST ISOLATION: temp dirs for state/logs, clean between tests
# =============================================================================
TEST_TMPDIR=$(mktemp -d /tmp/sentinel-pressure-test.XXXXXX)
export SENTINEL_STATE="$TEST_TMPDIR/state"
export SENTINEL_LOGS="$TEST_TMPDIR/logs"
export SENTINEL_CONFIG="$TEST_TMPDIR/config"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS" "$SENTINEL_CONFIG"

# Source utils (sets up logging, cooldowns, etc.)
source "$REPO_DIR/scripts/sentinel-utils.sh"

# Source config (sets thresholds)
source "$REPO_DIR/config/sentinel.conf"

# =============================================================================
# MOCK STATE VARIABLES — control what mocked commands return
# =============================================================================
MOCK_SWAP_USED="500.00"
MOCK_PAGES_FREE="50000"
MOCK_PAGE_SIZE="16384"
MOCK_PS_OUTPUT=""
MOCK_KILL_LOG_FILE="$TEST_TMPDIR/kill.log"
MOCK_NOTIFY_LOG_FILE="$TEST_TMPDIR/notify.log"
: > "$MOCK_KILL_LOG_FILE"
: > "$MOCK_NOTIFY_LOG_FILE"

# =============================================================================
# MOCK FUNCTIONS — override real system commands
# =============================================================================
# NOTE: kill/notify mocks write to FILES instead of variables because
# _kill_by_name and _kill_tier run inside $() subshells, and variable
# changes in subshells don't propagate to the parent shell.
# =============================================================================
sysctl() {
    if [[ "$1" == "vm.swapusage" ]]; then
        echo "vm.swapusage: total = 6144.00M  used = ${MOCK_SWAP_USED}M  free = 5644.00M  (encrypted)"
    fi
}

vm_stat() {
    cat <<VMEOF
Mach Virtual Memory Statistics: (page size of ${MOCK_PAGE_SIZE} bytes)
Pages free:                             ${MOCK_PAGES_FREE}.
Pages active:                           500000.
Pages inactive:                         200000.
Pages speculative:                      10000.
Pages throttled:                        0.
Pages wired down:                       300000.
VMEOF
}

ps() {
    if [[ "$*" == *"-eo"* ]]; then
        echo "  PID   RSS COMM"
        if [[ -n "$MOCK_PS_OUTPUT" ]]; then
            echo "$MOCK_PS_OUTPUT"
        fi
    fi
}

kill() {
    # Log to file (survives subshells)
    echo "kill $*" >> "$MOCK_KILL_LOG_FILE"
    return 0
}

pkill() {
    echo "pkill $*" >> "$MOCK_KILL_LOG_FILE"
    return 0
}

sentinel_notify() {
    echo "notify:$1:$2" >> "$MOCK_NOTIFY_LOG_FILE"
}

# Helpers to read mock logs
get_kill_log() { cat "$MOCK_KILL_LOG_FILE" 2>/dev/null; }
get_notify_log() { cat "$MOCK_NOTIFY_LOG_FILE" 2>/dev/null; }

# Export mocks so they're available in the sourced module
export -f sysctl vm_stat ps kill pkill sentinel_notify 2>/dev/null || true

# =============================================================================
# SOURCE THE MODULE UNDER TEST
# =============================================================================
source "$REPO_DIR/scripts/lib/check-pressure.sh"

# =============================================================================
# HELPER: Reset test state between test cases
# =============================================================================
reset_test_state() {
    MOCK_SWAP_USED="500.00"
    MOCK_PAGES_FREE="50000"
    MOCK_PS_OUTPUT=""
    : > "$MOCK_KILL_LOG_FILE"
    : > "$MOCK_NOTIFY_LOG_FILE"
    PHASE1_CRITICAL="false"
    # Clear all cooldowns
    rm -f "$SENTINEL_STATE"/*.cooldown
    # Clear logs
    : > "$SENTINEL_LOGS/sentinel.log"
}

# =============================================================================
# TEST 1: _get_swap_used_mb parses correctly
# =============================================================================
echo ""
echo "  --- _get_swap_used_mb ---"
reset_test_state

MOCK_SWAP_USED="5355.12"
result=$(_get_swap_used_mb)
assert_eq "5355" "$result" "_get_swap_used_mb extracts 5355 from 5355.12M"

MOCK_SWAP_USED="0.00"
result=$(_get_swap_used_mb)
assert_eq "0" "$result" "_get_swap_used_mb returns 0 for 0.00M"

MOCK_SWAP_USED="1024.50"
result=$(_get_swap_used_mb)
assert_eq "1024" "$result" "_get_swap_used_mb extracts 1024 from 1024.50M"

# =============================================================================
# TEST 2: _get_free_memory_mb calculates correctly
# =============================================================================
echo ""
echo "  --- _get_free_memory_mb ---"
reset_test_state

# 3640 pages * 16384 bytes = 59,637,760 bytes = 56 MB
MOCK_PAGES_FREE="3640"
MOCK_PAGE_SIZE="16384"
result=$(_get_free_memory_mb)
assert_eq "56" "$result" "_get_free_memory_mb: 3640 pages * 16384 = 56MB"

# 50000 pages * 16384 = 819,200,000 bytes = 781 MB
MOCK_PAGES_FREE="50000"
result=$(_get_free_memory_mb)
assert_eq "781" "$result" "_get_free_memory_mb: 50000 pages * 16384 = 781MB"

# =============================================================================
# TEST 3: _is_protected checks KILL_NEVER
# =============================================================================
echo ""
echo "  --- _is_protected ---"
reset_test_state

# claude is in KILL_NEVER
_is_protected "claude"
rc=$?
assert_eq "0" "$rc" "_is_protected: claude is protected (in KILL_NEVER)"

# Ghostty is in KILL_NEVER
_is_protected "Ghostty"
rc=$?
assert_eq "0" "$rc" "_is_protected: Ghostty is protected"

# ollama is NOT in KILL_NEVER
rc=0
_is_protected "ollama" || rc=$?
assert_eq "1" "$rc" "_is_protected: ollama is NOT protected"

# ChatGPT Atlas is NOT in KILL_NEVER
rc=0
_is_protected "ChatGPT Atlas" || rc=$?
assert_eq "1" "$rc" "_is_protected: ChatGPT Atlas is NOT protected"

# =============================================================================
# TEST 4: _kill_by_name finds and kills matching processes
# =============================================================================
echo ""
echo "  --- _kill_by_name ---"
reset_test_state

MOCK_PS_OUTPUT="12345 524288 /Applications/ollama
12346 262144 /Applications/Ghostty"

: > "$MOCK_KILL_LOG_FILE"
freed=$(_kill_by_name "ollama")
# 524288 KB = 512 MB
assert_eq "512" "$freed" "_kill_by_name: ollama freed 512MB"
assert_contains "$(get_kill_log)" "12345" "_kill_by_name: kill called with pid 12345"

# =============================================================================
# TEST 5: _kill_tier iterates list and skips protected
# =============================================================================
echo ""
echo "  --- _kill_tier ---"
reset_test_state

# Set up processes — claude should be skipped (protected), ollama should be killed
MOCK_PS_OUTPUT="12345 524288 /Applications/ollama
12346 262144 /Applications/claude"

: > "$MOCK_KILL_LOG_FILE"
freed=$(_kill_tier "ollama,claude")
assert_eq "512" "$freed" "_kill_tier: only ollama killed (claude protected), freed 512MB"
assert_contains "$(get_kill_log)" "12345" "_kill_tier: ollama pid 12345 was killed"
assert_not_contains "$(get_kill_log)" "12346" "_kill_tier: claude pid 12346 was NOT killed"

# =============================================================================
# TEST 6: check_pressure — NORMAL state
# =============================================================================
echo ""
echo "  --- check_pressure: NORMAL ---"
reset_test_state

# Low swap, plenty of free memory
MOCK_SWAP_USED="500.00"
MOCK_PAGES_FREE="50000"  # ~781MB free

check_pressure
rc=$?
assert_eq "0" "$rc" "check_pressure: NORMAL returns 0 (swap=500, free=781)"
assert_eq "false" "$PHASE1_CRITICAL" "check_pressure: NORMAL sets PHASE1_CRITICAL=false"
assert_not_contains "$(get_kill_log)" "kill" "check_pressure: NORMAL — no kills"
assert_not_contains "$(get_notify_log)" "notify" "check_pressure: NORMAL — no notifications"

# =============================================================================
# TEST 7: check_pressure — WARNING state
# =============================================================================
echo ""
echo "  --- check_pressure: WARNING ---"
reset_test_state

# Swap above warning (2048) but below critical (4096), free mem is fine
MOCK_SWAP_USED="3000.00"
MOCK_PAGES_FREE="50000"  # ~781MB free

rc=0
check_pressure || rc=$?
assert_eq "1" "$rc" "check_pressure: WARNING returns 1 (swap=3000)"
assert_not_contains "$(get_kill_log)" "kill" "check_pressure: WARNING — no kills"
assert_contains "$(get_notify_log)" "Warning" "check_pressure: WARNING — notification sent"

# =============================================================================
# TEST 8: check_pressure — CRITICAL state (swap above critical)
# =============================================================================
echo ""
echo "  --- check_pressure: CRITICAL (high swap) ---"
reset_test_state

# Swap above critical threshold
MOCK_SWAP_USED="5000.00"
MOCK_PAGES_FREE="50000"  # ~781MB free (above critical)

# Provide killable processes in Tier 1
MOCK_PS_OUTPUT="99901 204800 /Applications/ChatGPT Atlas
99902 102400 /Applications/Typeless"

rc=0
check_pressure || rc=$?
assert_eq "2" "$rc" "check_pressure: CRITICAL returns 2 (swap=5000)"
assert_eq "true" "$PHASE1_CRITICAL" "check_pressure: CRITICAL sets PHASE1_CRITICAL=true"
assert_contains "$(get_kill_log)" "kill" "check_pressure: CRITICAL — kills attempted"

# =============================================================================
# TEST 9: check_pressure — CRITICAL state (low free memory)
# =============================================================================
echo ""
echo "  --- check_pressure: CRITICAL (low free mem) ---"
reset_test_state

# Swap is fine, but free memory is critically low
MOCK_SWAP_USED="500.00"
MOCK_PAGES_FREE="800"  # ~12MB free — well below 200MB threshold

MOCK_PS_OUTPUT="99901 204800 /Applications/ChatGPT Atlas"

rc=0
check_pressure || rc=$?
assert_eq "2" "$rc" "check_pressure: CRITICAL returns 2 (free_mem=12)"
assert_eq "true" "$PHASE1_CRITICAL" "check_pressure: CRITICAL (low mem) sets PHASE1_CRITICAL=true"

# =============================================================================
# TEST 10: Cooldown prevents re-kill
# =============================================================================
echo ""
echo "  --- check_pressure: Cooldown prevents re-kill ---"
reset_test_state

# Set the kill cooldown BEFORE the critical check
set_cooldown "pressure-kill"

# CRITICAL conditions
MOCK_SWAP_USED="5000.00"
MOCK_PAGES_FREE="50000"

# Processes available but should NOT be killed due to cooldown
MOCK_PS_OUTPUT="99901 204800 /Applications/ChatGPT Atlas"
: > "$MOCK_KILL_LOG_FILE"

rc=0
check_pressure || rc=$?
assert_eq "2" "$rc" "check_pressure: CRITICAL on cooldown still returns 2"
assert_eq "" "$(get_kill_log)" "check_pressure: No kills when on cooldown"

# =============================================================================
# TEST 11: Warning cooldown prevents spam notifications
# =============================================================================
echo ""
echo "  --- check_pressure: Warning cooldown prevents notification spam ---"
reset_test_state

# WARNING conditions
MOCK_SWAP_USED="3000.00"
MOCK_PAGES_FREE="50000"

# First call — should notify
rc=0
check_pressure || rc=$?
assert_eq "1" "$rc" "check_pressure: first WARNING returns 1"
assert_contains "$(get_notify_log)" "Warning" "check_pressure: first WARNING sends notification"

# Second call — on cooldown, should NOT notify again
: > "$MOCK_NOTIFY_LOG_FILE"
rc=0
check_pressure || rc=$?
assert_eq "1" "$rc" "check_pressure: second WARNING returns 1"
assert_not_contains "$(get_notify_log)" "Warning" "check_pressure: second WARNING skips notification (cooldown)"

# =============================================================================
# CLEANUP
# =============================================================================
rm -rf "$TEST_TMPDIR"

echo ""
test_summary
