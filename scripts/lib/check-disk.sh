#!/usr/bin/env bash
# ================================================================================
# CHECK-DISK — Disk free space monitoring
# ================================================================================
# Source this file from sentinel-daemon.sh. Do NOT execute directly.
#
# Requires (already sourced by daemon):
#   - sentinel-utils.sh  (logging, cooldowns, notifications)
#   - sentinel.conf      (thresholds: DISK_WARNING_GB, DISK_CRITICAL_GB)
#
# Provides:
#   check_disk()        — main entry point, returns 0/1/2
#   _get_free_gb()      — current free disk space on root volume in GB (integer)
#
# Part of: OPS Sentinel Suite
# ================================================================================

# =============================================================================
# GUARD: Prevent direct execution
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: check-disk.sh should be sourced, not executed directly."
    echo "Usage: source check-disk.sh"
    exit 1
fi

# =============================================================================
# _get_free_gb — Get free disk space in GB for root volume (integer)
# =============================================================================
# Uses `df -g /` which outputs 1G-blocks on macOS.
# Falls back to `df -h /` and strips non-numeric chars if -g fails.
#
# Example df -g output:
#   Filesystem     1G-blocks Used Available Capacity iused     ifree %iused  Mounted on
#   /dev/disk3s1s1       228   15        61    20%  453019 641022240    0%   /
#
# Column 4 (Available) = free GB.
# =============================================================================
_get_free_gb() {
    local free
    free=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')

    # Fallback: parse from human-readable output
    if [[ -z "$free" ]] || ! [[ "$free" =~ ^[0-9]+$ ]]; then
        free=$(df -h / 2>/dev/null | awk 'NR==2 {gsub(/[^0-9]/,"",$4); print $4}')
    fi

    echo "${free:-0}"
}

# =============================================================================
# check_disk — Main entry point (called by daemon each cycle)
# =============================================================================
# Returns:
#   0 = NORMAL    (free >= warning threshold)
#   1 = WARNING   (free < warning threshold but >= critical)
#   2 = CRITICAL  (free < critical threshold)
# =============================================================================
check_disk() {
    local free_gb
    free_gb=$(_get_free_gb)

    # --- CRITICAL ---
    if (( free_gb < DISK_CRITICAL_GB )); then
        log_error "Disk CRITICAL: ${free_gb} GB free (threshold: ${DISK_CRITICAL_GB} GB)"
        if check_cooldown "disk-critical" 1800; then
            sentinel_notify "Sentinel" "NODE SSD critically low: ${free_gb} GB free" "Basso"
            set_cooldown "disk-critical"
        fi
        return 2
    fi

    # --- WARNING ---
    if (( free_gb < DISK_WARNING_GB )); then
        log_warn "Disk warning: ${free_gb} GB free (threshold: ${DISK_WARNING_GB} GB)"
        if check_cooldown "disk-warn" 3600; then
            sentinel_notify "Sentinel" "NODE SSD getting low: ${free_gb} GB free" "Submarine"
            set_cooldown "disk-warn"
        fi
        return 1
    fi

    # --- NORMAL ---
    return 0
}
