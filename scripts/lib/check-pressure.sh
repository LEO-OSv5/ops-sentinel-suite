#!/usr/bin/env bash
# ================================================================================
# CHECK-PRESSURE — Memory/Swap pressure detection with tiered auto-kill
# ================================================================================
# Source this file from sentinel-daemon.sh. Do NOT execute directly.
#
# Requires (already sourced by daemon):
#   - sentinel-utils.sh  (logging, cooldowns, notifications)
#   - sentinel.conf      (thresholds: SWAP_WARNING_MB, SWAP_CRITICAL_MB, etc.)
#
# Provides:
#   check_pressure()     — main entry point, returns 0/1/2
#   _get_swap_used_mb()  — current swap used in MB (integer)
#   _get_free_memory_mb()— current free memory in MB (integer)
#   _is_protected()      — check if process is in KILL_NEVER
#   _kill_by_name()      — kill process by name, return freed MB
#   _kill_tier()         — iterate a tier list, kill each, return total freed
#
# Part of: OPS Sentinel Suite
# ================================================================================

# =============================================================================
# GUARD: Prevent direct execution
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: check-pressure.sh should be sourced, not executed directly."
    echo "Usage: source check-pressure.sh"
    exit 1
fi

# =============================================================================
# STATE: Phase 1 critical flag (used by Phase 2 pressure gate)
# =============================================================================
PHASE1_CRITICAL="${PHASE1_CRITICAL:-false}"

# =============================================================================
# _get_swap_used_mb — Parse sysctl vm.swapusage for used MB (integer)
# =============================================================================
# Format: vm.swapusage: total = 6144.00M  used = 5355.12M  free = 788.88M  (encrypted)
# Returns: 5355 (integer part of used)
# =============================================================================
_get_swap_used_mb() {
    local swap_line
    swap_line=$(sysctl vm.swapusage 2>/dev/null) || { echo "0"; return; }

    # Extract the number after "used = " and before "M"
    local used_raw
    used_raw=$(echo "$swap_line" | sed -n 's/.*used = \([0-9]*\).*/\1/p')

    if [[ -z "$used_raw" ]]; then
        echo "0"
    else
        echo "$used_raw"
    fi
}

# =============================================================================
# _get_free_memory_mb — Parse vm_stat for free pages, convert to MB
# =============================================================================
# vm_stat format:  Pages free:                                3640.
# ARM64 page size: 16384 bytes
# Formula: (pages_free * page_size) / 1024 / 1024
# =============================================================================
_get_free_memory_mb() {
    local vmstat_output
    vmstat_output=$(vm_stat 2>/dev/null) || { echo "0"; return; }

    # Extract pages free count (strip trailing period)
    local pages_free
    pages_free=$(echo "$vmstat_output" | sed -n 's/^Pages free:[[:space:]]*\([0-9]*\).*/\1/p')

    if [[ -z "$pages_free" ]]; then
        echo "0"
        return
    fi

    # Detect page size from vm_stat header or default to 16384 (ARM64)
    local page_size
    page_size=$(echo "$vmstat_output" | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p')
    page_size="${page_size:-16384}"

    # Calculate MB: (pages * page_size) / 1048576
    local total_bytes=$(( pages_free * page_size ))
    local mb=$(( total_bytes / 1048576 ))
    echo "$mb"
}

# =============================================================================
# _is_protected — Check if process name is in KILL_NEVER list
# =============================================================================
# Returns 0 if protected, 1 if not protected
# =============================================================================
_is_protected() {
    local name="$1"
    local IFS=','
    local entry
    for entry in $KILL_NEVER; do
        # Trim whitespace (Bash 3.2 compatible)
        entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ "$entry" == "$name" ]]; then
            return 0
        fi
    done
    return 1
}

# =============================================================================
# _kill_by_name — Kill matching processes, return estimated freed MB
# =============================================================================
# Finds processes via ps, sends SIGTERM, sums RSS to estimate freed memory.
# Skips grep itself. Logs each kill.
# =============================================================================
_kill_by_name() {
    local name="$1"
    local freed_mb=0

    # Get matching processes: pid, rss (KB), command
    local ps_output
    ps_output=$(ps -eo pid,rss,comm 2>/dev/null) || { echo "0"; return; }

    local line pid rss comm
    while IFS= read -r line; do
        # Skip header
        [[ "$line" == *"PID"* ]] && continue

        # Parse fields — pid and rss are numeric, comm is the rest
        pid=$(echo "$line" | awk '{print $1}')
        rss=$(echo "$line" | awk '{print $2}')
        comm=$(echo "$line" | awk '{print $3}')

        # Skip if not matching
        case "$comm" in
            *"$name"*) ;;
            *) continue ;;
        esac

        # Skip grep/awk processes that might match
        case "$comm" in
            *grep*|*awk*) continue ;;
        esac

        # Attempt kill
        if kill -15 "$pid" 2>/dev/null; then
            local this_mb=$(( rss / 1024 ))
            freed_mb=$(( freed_mb + this_mb ))
            log_warn "PRESSURE-KILL: Sent SIGTERM to $name (pid=$pid, ~${this_mb}MB RSS)"
        fi
    done <<< "$ps_output"

    echo "$freed_mb"
}

# =============================================================================
# _kill_tier — Iterate comma-separated tier list, kill each (skip protected)
# =============================================================================
# Returns total freed MB across all processes in the tier.
# =============================================================================
_kill_tier() {
    local tier_list="$1"
    local total_freed=0

    local IFS=','
    local entry
    for entry in $tier_list; do
        # Trim whitespace
        entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$entry" ]] && continue

        # Skip protected processes
        if _is_protected "$entry"; then
            log_info "PRESSURE: Skipping protected process: $entry"
            continue
        fi

        local freed
        freed=$(_kill_by_name "$entry")
        total_freed=$(( total_freed + freed ))
    done

    echo "$total_freed"
}

# =============================================================================
# _check_pressure_resolved — Quick check if pressure is below critical
# =============================================================================
_check_pressure_resolved() {
    local swap_used
    swap_used=$(_get_swap_used_mb)
    local free_mem
    free_mem=$(_get_free_memory_mb)

    if (( swap_used < SWAP_CRITICAL_MB )) && (( free_mem > MEMORY_FREE_CRITICAL_MB )); then
        return 0
    fi
    return 1
}

# =============================================================================
# check_pressure — Main entry point (called by daemon each cycle)
# =============================================================================
# Returns:
#   0 = NORMAL  (swap < warning AND free > critical)
#   1 = WARNING (swap between warning and critical)
#   2 = CRITICAL (swap > critical OR free < critical) — tiered kill
# =============================================================================
check_pressure() {
    local swap_used
    swap_used=$(_get_swap_used_mb)
    local free_mem
    free_mem=$(_get_free_memory_mb)

    log_info "PRESSURE: swap_used=${swap_used}MB, free_mem=${free_mem}MB"

    # --- NORMAL ---
    if (( swap_used < SWAP_WARNING_MB )) && (( free_mem > MEMORY_FREE_CRITICAL_MB )); then
        PHASE1_CRITICAL="false"
        return 0
    fi

    # --- CRITICAL ---
    if (( swap_used >= SWAP_CRITICAL_MB )) || (( free_mem <= MEMORY_FREE_CRITICAL_MB )); then
        log_error "PRESSURE: CRITICAL — swap=${swap_used}MB (threshold=${SWAP_CRITICAL_MB}MB), free=${free_mem}MB (threshold=${MEMORY_FREE_CRITICAL_MB}MB)"

        # Check kill cooldown — if on cooldown, just report
        if ! check_cooldown "pressure-kill" "$PRESSURE_KILL_COOLDOWN"; then
            log_warn "PRESSURE: Kill on cooldown, skipping tiered kill"
            PHASE1_CRITICAL="true"
            return 2
        fi

        # Tier 1 kill
        local freed_t1
        freed_t1=$(_kill_tier "$KILL_TIER_1")
        log_warn "PRESSURE: Tier 1 kill freed ~${freed_t1}MB"

        if _check_pressure_resolved; then
            log_info "PRESSURE: Resolved after Tier 1 kill"
            set_cooldown "pressure-kill"
            sentinel_notify "Sentinel: Pressure" "Tier 1 kill freed ~${freed_t1}MB — resolved" "Glass" \
                "Swap: ${swap_used}MB (threshold: ${SWAP_CRITICAL_MB}MB)
Free: ${free_mem}MB (threshold: ${MEMORY_FREE_CRITICAL_MB}MB)

ACTION TAKEN:
  Tier 1 kill (expendable apps) freed ~${freed_t1}MB
  Pressure resolved — no further action needed"
            PHASE1_CRITICAL="true"
            return 2
        fi

        # Tier 2 kill
        local freed_t2
        freed_t2=$(_kill_tier "$KILL_TIER_2")
        log_warn "PRESSURE: Tier 2 kill freed ~${freed_t2}MB"

        if _check_pressure_resolved; then
            log_info "PRESSURE: Resolved after Tier 2 kill"
            set_cooldown "pressure-kill"
            sentinel_notify "Sentinel: Pressure" "Tier 1+2 kill freed ~$(( freed_t1 + freed_t2 ))MB — resolved" "Glass" \
                "Swap: ${swap_used}MB (threshold: ${SWAP_CRITICAL_MB}MB)
Free: ${free_mem}MB (threshold: ${MEMORY_FREE_CRITICAL_MB}MB)

ACTIONS TAKEN:
  Tier 1 (expendable apps) freed ~${freed_t1}MB
  Tier 2 (heavy optional)  freed ~${freed_t2}MB
  Total freed: ~$(( freed_t1 + freed_t2 ))MB
  Pressure resolved — no further action needed"
            PHASE1_CRITICAL="true"
            return 2
        fi

        # Tier 3 kill (last resort)
        local freed_t3
        freed_t3=$(_kill_tier "$KILL_TIER_3")
        log_warn "PRESSURE: Tier 3 kill freed ~${freed_t3}MB"

        local total_freed=$(( freed_t1 + freed_t2 + freed_t3 ))
        set_cooldown "pressure-kill"
        sentinel_notify "Sentinel: CRITICAL" "All tiers exhausted — freed ~${total_freed}MB total" "Basso" \
            "Swap: ${swap_used}MB (threshold: ${SWAP_CRITICAL_MB}MB)
Free: ${free_mem}MB (threshold: ${MEMORY_FREE_CRITICAL_MB}MB)

ALL KILL TIERS EXHAUSTED:
  Tier 1 (expendable apps) freed ~${freed_t1}MB
  Tier 2 (heavy optional)  freed ~${freed_t2}MB
  Tier 3 (expendable bots) freed ~${freed_t3}MB
  Total freed: ~${total_freed}MB

MACHINE MAY STILL BE UNDER PRESSURE.
Consider running: sentinel-triage"

        PHASE1_CRITICAL="true"
        return 2
    fi

    # --- WARNING ---
    log_warn "PRESSURE: WARNING — swap=${swap_used}MB (threshold=${SWAP_WARNING_MB}MB)"

    if check_cooldown "pressure-warn" "${PRESSURE_KILL_COOLDOWN:-300}"; then
        sentinel_notify "Sentinel: Pressure Warning" "Swap at ${swap_used}MB (warn=${SWAP_WARNING_MB}MB)" "Submarine" \
            "Swap: ${swap_used}MB (warning threshold: ${SWAP_WARNING_MB}MB)
Free: ${free_mem}MB

Not critical yet — monitoring. No kills triggered.
The daemon will escalate if pressure worsens."
        set_cooldown "pressure-warn"
    fi

    return 1
}
