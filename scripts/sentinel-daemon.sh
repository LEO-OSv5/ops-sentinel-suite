#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# OPS Sentinel Suite — Daemon
# ═══════════════════════════════════════════════════════════════
# Main daemon process. Runs 5-phase pipeline every cycle.
# Launched via LaunchAgent (com.ops.sentinel.plist).
#
# Usage:
#   sentinel-daemon.sh          # normal daemon loop
#   sentinel-daemon.sh --once   # run one cycle and exit (for testing)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preserve env overrides before sourcing utils (which sets defaults)
_ENV_STATE="${SENTINEL_STATE:-}"
_ENV_LOGS="${SENTINEL_LOGS:-}"
_ENV_CONFIG="${SENTINEL_CONFIG:-}"

# Source foundation
source "$SCRIPT_DIR/sentinel-utils.sh"

# Restore env overrides (tests pass temp dirs via env)
[[ -n "$_ENV_STATE" ]]  && SENTINEL_STATE="$_ENV_STATE"
[[ -n "$_ENV_LOGS" ]]   && SENTINEL_LOGS="$_ENV_LOGS"
[[ -n "$_ENV_CONFIG" ]] && SENTINEL_CONFIG="$_ENV_CONFIG"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS"

# Load config (sentinel.conf overrides utils defaults)
if [[ -f "$SENTINEL_CONFIG/sentinel.conf" ]]; then
    source "$SENTINEL_CONFIG/sentinel.conf"
elif [[ -f "$SCRIPT_DIR/../config/sentinel.conf" ]]; then
    source "$SCRIPT_DIR/../config/sentinel.conf"
fi

# Source lib modules
source "$SCRIPT_DIR/lib/check-pressure.sh"
source "$SCRIPT_DIR/lib/check-services.sh"
source "$SCRIPT_DIR/lib/check-backups.sh"
source "$SCRIPT_DIR/lib/check-disk.sh"
source "$SCRIPT_DIR/lib/check-files.sh"
source "$SCRIPT_DIR/lib/write-status.sh"

# Cycle counter (persisted across daemon restarts)
CYCLE_FILE="$SENTINEL_STATE/cycle-counter"
if [[ -f "$CYCLE_FILE" ]]; then
    CYCLE_COUNT=$(cat "$CYCLE_FILE")
else
    CYCLE_COUNT=0
fi

# Track Phase 1 critical state for Phase 2 pressure gate
PHASE1_CRITICAL=false

# Run one cycle of all checks
run_cycle() {
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    echo "$CYCLE_COUNT" > "$CYCLE_FILE"
    PHASE1_CRITICAL=false

    log_info "Cycle #${CYCLE_COUNT} starting"

    # ─── PHASE 1: PRESSURE (every cycle) ───
    local pressure_result=0
    check_pressure || pressure_result=$?
    if (( pressure_result == 2 )); then
        PHASE1_CRITICAL=true
    fi

    # ─── PHASE 2: SERVICES (every cycle) ───
    check_services || true

    # ─── PHASE 3: BACKUPS (every Nth cycle) ───
    if (( CYCLE_COUNT % BACKUP_CHECK_INTERVAL == 0 )); then
        check_backups || true
    fi

    # ─── PHASE 4: DISK (every Nth cycle) ───
    if (( CYCLE_COUNT % DISK_CHECK_INTERVAL == 0 )); then
        check_disk || true
    fi

    # ─── PHASE 5: FILE JANITOR (every Nth cycle) ───
    if (( CYCLE_COUNT % JANITOR_CHECK_INTERVAL == 0 )); then
        check_files || true
    fi

    # ─── LOG ROTATION ───
    log_rotate "$SENTINEL_LOGS/sentinel.log" "${LOG_MAX_LINES:-5000}"

    # ─── WRITE STATUS JSON (for web dashboard) ───
    write_status || true

    log_info "Cycle #${CYCLE_COUNT} complete"
    echo "cycle #${CYCLE_COUNT} complete"
}

# ─── MAIN ───
if [[ "${1:-}" == "--once" ]]; then
    # Single cycle mode (for testing)
    run_cycle
    exit 0
fi

# Daemon loop
log_info "Sentinel daemon starting (PID $$, cycle interval: ${DAEMON_CYCLE_SECONDS}s)"

while true; do
    run_cycle
    sleep "${DAEMON_CYCLE_SECONDS:-60}"
done
