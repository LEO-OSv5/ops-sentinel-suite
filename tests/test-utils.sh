#!/usr/bin/env bash
# Test: sentinel-utils.sh — machine detection, paths, functions, logging, cooldown
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-utils.sh ==="

# Source utils (it must be sourced, not executed)
SENTINEL_UTILS="$SCRIPT_DIR/../scripts/sentinel-utils.sh"
source "$SENTINEL_UTILS"

# ── Machine detection ──
assert_eq "NODE" "$SENTINEL_MACHINE" "Machine detected as NODE"
assert_eq "curl" "$SENTINEL_USER" "User detected as curl"

# ── Path constants ──
assert_eq "$HOME/.local/share/ops-sentinel" "$SENTINEL_HOME" "SENTINEL_HOME default"

# ── Version bump ──
assert_eq "0.2.0" "$SENTINEL_VERSION" "SENTINEL_VERSION is 0.2.0"

# ── Key functions exist ──
REQUIRED_FUNCS="log_info log_warn log_error check_cooldown set_cooldown clear_cooldown sentinel_notify load_config"
for fn in $REQUIRED_FUNCS; do
    fn_exists=0
    type -t "$fn" >/dev/null 2>&1 && fn_exists=1
    assert_eq "1" "$fn_exists" "Function exists: $fn"
done

# ── Logging works ──
TMPLOG=$(mktemp /tmp/sentinel-test-log.XXXXXX)
log_info "test message alpha" "$TMPLOG"
LOG_CONTENT=$(cat "$TMPLOG")
assert_contains "$LOG_CONTENT" "[INFO]" "Log contains [INFO]"
assert_contains "$LOG_CONTENT" "test message alpha" "Log contains the message"
assert_contains "$LOG_CONTENT" "[0.2.0]" "Log contains version"
rm -f "$TMPLOG"

# ── Cooldown works ──
COOLDOWN_NAME="test-cooldown-$$"
clear_cooldown "$COOLDOWN_NAME"

# Before setting: check_cooldown should return 0 (no active cooldown)
check_cooldown "$COOLDOWN_NAME" 30
rc_before=$?
assert_eq "0" "$rc_before" "Cooldown not active before set"

# Set cooldown
set_cooldown "$COOLDOWN_NAME"

# After setting: check_cooldown should return 1 (active)
rc_after=0
check_cooldown "$COOLDOWN_NAME" 30 || rc_after=$?
assert_eq "1" "$rc_after" "Cooldown active after set"

# Clear and re-check: should return 0 (expired/cleared)
clear_cooldown "$COOLDOWN_NAME"
check_cooldown "$COOLDOWN_NAME" 30
rc_cleared=$?
assert_eq "0" "$rc_cleared" "Cooldown cleared"

# ── load_config with explicit file ──
TMPCONF=$(mktemp /tmp/sentinel-test-conf.XXXXXX)
echo 'TEST_LOADED_VAR="sentinel-config-loaded"' > "$TMPCONF"
load_config "$TMPCONF"
assert_eq "sentinel-config-loaded" "$TEST_LOADED_VAR" "load_config sources explicit file"
rm -f "$TMPCONF"

# ── load_config with nonexistent file does not error ──
load_config "/tmp/nonexistent-sentinel-config-$$.conf"
TESTS=$((TESTS + 1))
echo "  PASS: load_config with nonexistent file does not error"

test_summary
