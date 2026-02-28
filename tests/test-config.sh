#!/usr/bin/env bash
# Test: sentinel.conf loads and all variables are set
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-config.sh ==="

# Source config
source "$SCRIPT_DIR/../config/sentinel.conf"

# Verify key variables are set
assert_eq "2048" "$SWAP_WARNING_MB" "SWAP_WARNING_MB default"
assert_eq "4096" "$SWAP_CRITICAL_MB" "SWAP_CRITICAL_MB default"
assert_eq "200" "$MEMORY_FREE_CRITICAL_MB" "MEMORY_FREE_CRITICAL_MB default"
assert_eq "300" "$PRESSURE_KILL_COOLDOWN" "PRESSURE_KILL_COOLDOWN default"
assert_eq "true" "$AUTO_RESTART" "AUTO_RESTART default"
assert_eq "3" "$MAX_RESTARTS_PER_HOUR" "MAX_RESTARTS_PER_HOUR default"
assert_eq "true" "$JANITOR_ENABLED" "JANITOR_ENABLED default"
assert_eq "10" "$DISK_WARNING_GB" "DISK_WARNING_GB default"
assert_eq "5" "$DISK_CRITICAL_GB" "DISK_CRITICAL_GB default"
assert_eq "24" "$GITHUB_STALE_HOURS" "GITHUB_STALE_HOURS default"
assert_eq "30" "$OPS_SYNC_STALE_MINUTES" "OPS_SYNC_STALE_MINUTES default"
assert_eq "48" "$OPS_MINI_STALE_HOURS" "OPS_MINI_STALE_HOURS default"
assert_eq "60" "$DAEMON_CYCLE_SECONDS" "DAEMON_CYCLE_SECONDS default"
assert_eq "5000" "$LOG_MAX_LINES" "LOG_MAX_LINES default"
assert_eq "macos" "$NOTIFY_METHOD" "NOTIFY_METHOD default"
assert_contains "$KILL_NEVER" "claude" "claude in KILL_NEVER"
assert_contains "$KILL_NEVER" "Ghostty" "Ghostty in KILL_NEVER"
assert_contains "$MONITORED_SERVICES" "com.aether.periapsis" "periapsis in MONITORED_SERVICES"
assert_not_contains "$KILL_NEVER" "ollama" "ollama NOT in KILL_NEVER"

# Test env-var override
export SWAP_WARNING_MB=1024
source "$SCRIPT_DIR/../config/sentinel.conf"
assert_eq "1024" "$SWAP_WARNING_MB" "SWAP_WARNING_MB env override"
unset SWAP_WARNING_MB


# --- Web Dashboard config ---
assert_eq "8888" "$WEB_PORT" "WEB_PORT default"
assert_eq "$HOME/.sentinel-config/web.token" "$WEB_TOKEN_FILE" "WEB_TOKEN_FILE default"
assert_eq "5" "$WEB_REFRESH_SECONDS" "WEB_REFRESH_SECONDS default"
assert_eq "7" "$WEB_HISTORY_DAYS" "WEB_HISTORY_DAYS default"
assert_eq "30" "$WEB_ACTIONS_DAYS" "WEB_ACTIONS_DAYS default"

test_summary
