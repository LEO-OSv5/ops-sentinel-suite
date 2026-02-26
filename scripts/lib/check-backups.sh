#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# check-backups.sh — Backup channel verification
# ═══════════════════════════════════════════════════════════════
# Sourced by sentinel-daemon.sh. Do not execute directly.
#
# Checks: OPS sync agent, GitHub push freshness, OPS-mini mount
# Returns: 0 = all fresh, 1 = warnings issued
# ═══════════════════════════════════════════════════════════════

# =============================================================================
# GUARD: Prevent direct execution
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: check-backups.sh should be sourced, not executed directly."
    echo "Usage: source check-backups.sh"
    exit 1
fi

# Configurable path for OPS-mini backup directory (override in tests)
OPS_MINI_PATH="${OPS_MINI_PATH:-/Volumes/OPS-mini/OPS}"

# Check if OPS sync LaunchAgent has run recently
_check_ops_sync() {
    # Check LaunchAgent status
    local sync_status
    sync_status=$(launchctl list 2>/dev/null | grep "com.ops.sync" || true)

    if [[ -z "$sync_status" ]]; then
        log_warn "OPS sync agent not registered"
        if check_cooldown "backup-sync" 1800; then
            sentinel_notify "Sentinel" "OPS sync agent is not registered — backups may not be running" "Submarine"
            set_cooldown "backup-sync"
        fi
        return 1
    fi

    return 0
}

# Check GitHub push freshness for monitored repos
_check_github_freshness() {
    local stale_seconds=$(( GITHUB_STALE_HOURS * 3600 ))
    local now
    now=$(date +%s)
    local has_stale=false
    local IFS=','

    for repo in $GITHUB_REPOS; do
        repo=$(echo "$repo" | xargs)
        [[ -z "$repo" ]] && continue
        [[ ! -d "$repo/.git" ]] && continue

        local repo_name
        repo_name=$(basename "$repo")

        # Get last commit timestamp
        local last_commit_ts
        last_commit_ts=$(git -C "$repo" log --format=%ct -1 2>/dev/null || echo "0")
        local age_seconds=$(( now - last_commit_ts ))

        if (( age_seconds > stale_seconds )); then
            local age_hours=$(( age_seconds / 3600 ))
            log_warn "GitHub stale: $repo_name — last commit ${age_hours}h ago"
            has_stale=true
        fi
    done

    if [[ "$has_stale" == "true" ]]; then
        if check_cooldown "backup-github" 3600; then
            sentinel_notify "Sentinel" "Some repos haven't been pushed in ${GITHUB_STALE_HOURS}+ hours" "Submarine"
            set_cooldown "backup-github"
        fi
        return 1
    fi

    return 0
}

# Check OPS-mini mount and freshness
_check_ops_mini() {
    if ! mount 2>/dev/null | grep -q "OPS-mini"; then
        log_warn "OPS-mini not mounted"
        if check_cooldown "backup-opsmini" 3600; then
            sentinel_notify "Sentinel" "OPS-mini disconnected — backups paused" "Submarine"
            set_cooldown "backup-opsmini"
        fi
        return 1
    fi

    # Check freshness: stat a known directory
    if [[ -d "$OPS_MINI_PATH" ]]; then
        local stale_seconds=$(( OPS_MINI_STALE_HOURS * 3600 ))
        local now
        now=$(date +%s)
        local last_mod
        last_mod=$(stat -f %m "$OPS_MINI_PATH" 2>/dev/null || echo "0")
        local age_seconds=$(( now - last_mod ))

        if (( age_seconds > stale_seconds )); then
            local age_hours=$(( age_seconds / 3600 ))
            log_warn "OPS-mini backup stale: last write ${age_hours}h ago"
            if check_cooldown "backup-opsmini-stale" 3600; then
                sentinel_notify "Sentinel" "OPS-mini backup is ${age_hours} hours old" "Submarine"
                set_cooldown "backup-opsmini-stale"
            fi
            return 1
        fi
    fi

    return 0
}

# Main backup check — called by sentinel-daemon.sh
check_backups() {
    local warnings=0

    _check_ops_sync || warnings=$((warnings + 1))
    _check_github_freshness || warnings=$((warnings + 1))
    _check_ops_mini || warnings=$((warnings + 1))

    if (( warnings > 0 )); then
        log_warn "Backup check: $warnings channel(s) stale"
        return 1
    fi

    log_info "Backup check: all channels fresh"
    return 0
}
