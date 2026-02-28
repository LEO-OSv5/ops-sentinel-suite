#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# check-services.sh — LaunchAgent health + auto-restart
# ═══════════════════════════════════════════════════════════════
# Sourced by sentinel-daemon.sh. Do not execute directly.
#
# Requires: sentinel-utils.sh, sentinel.conf sourced first
# Globals:  PHASE1_CRITICAL (set by check-pressure.sh)
# Returns:  0 = all healthy, 1 = restarts performed, 2 = crash loop
# ═══════════════════════════════════════════════════════════════

# =============================================================================
# GUARD: Prevent direct execution
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: check-services.sh should be sourced, not executed directly."
    echo "Usage: source check-services.sh"
    exit 1
fi

# Get exit status of a LaunchAgent service
_get_service_status() {
    local service="$1"
    local line
    line=$(launchctl list 2>/dev/null | grep "$service" || true)

    if [[ -z "$line" ]]; then
        echo "missing"
        return
    fi

    local pid exit_code
    pid=$(echo "$line" | awk '{print $1}')
    exit_code=$(echo "$line" | awk '{print $2}')

    if [[ "$pid" == "-" ]] || [[ "$exit_code" != "0" ]]; then
        echo "crashed:$exit_code"
    else
        echo "running:$pid"
    fi
}

# Count restarts in the last hour for a service
_restart_count_this_hour() {
    local service="$1"
    local counter_file="$SENTINEL_STATE/restart-${service}"

    if [[ ! -f "$counter_file" ]]; then
        echo "0"
        return
    fi

    local now one_hour_ago count
    now=$(date +%s)
    one_hour_ago=$(( now - 3600 ))
    count=0

    while IFS= read -r ts; do
        [[ -z "$ts" ]] && continue
        if (( ts > one_hour_ago )); then
            count=$(( count + 1 ))
        fi
    done < "$counter_file"

    echo "$count"
}

# Record a restart timestamp
_record_restart() {
    local service="$1"
    local counter_file="$SENTINEL_STATE/restart-${service}"
    date +%s >> "$counter_file"

    # Prune old entries (keep last hour only)
    local now one_hour_ago
    now=$(date +%s)
    one_hour_ago=$(( now - 3600 ))
    if [[ -f "$counter_file" ]]; then
        local tmp="$counter_file.tmp"
        while IFS= read -r ts; do
            [[ -z "$ts" ]] && continue
            if (( ts > one_hour_ago )); then
                echo "$ts"
            fi
        done < "$counter_file" > "$tmp"
        mv "$tmp" "$counter_file"
    fi
}

# Restart a crashed LaunchAgent
_restart_service() {
    local service="$1"
    local uid
    uid=$(id -u)
    launchctl kickstart -k "gui/${uid}/${service}" 2>/dev/null || true
    _record_restart "$service"
    log_info "Restarted $service"
}

# Main service check — called by sentinel-daemon.sh
check_services() {
    local has_restarts=false
    local has_crash_loop=false
    local IFS=','

    for service in $MONITORED_SERVICES; do
        service=$(echo "$service" | xargs)
        [[ -z "$service" ]] && continue

        local status
        status=$(_get_service_status "$service")

        case "$status" in
            running:*)
                # Healthy — nothing to do
                ;;
            crashed:*|missing)
                local exit_code="${status#*:}"

                # Pressure gate: don't restart if Phase 1 was critical
                if [[ "${PHASE1_CRITICAL:-false}" == "true" ]]; then
                    log_info "Skipped restart of $service (pressure gate active)"
                    continue
                fi

                # Check for crash loop
                local restart_count
                restart_count=$(_restart_count_this_hour "$service")

                if (( restart_count >= MAX_RESTARTS_PER_HOUR )); then
                    log_error "CRASH LOOP: $service — $restart_count restarts in 1 hour"
                    sentinel_notify "Sentinel" "$service is crash-looping ($restart_count restarts/hr) — needs manual intervention" "Basso" \
                        "Service: $service
Exit code: $exit_code
Restarts this hour: $restart_count (max: $MAX_RESTARTS_PER_HOUR)

CRASH LOOP DETECTED — auto-restart disabled for this service.
Manual intervention required:
  launchctl kickstart gui/$(id -u)/$service
  Or check: launchctl print gui/$(id -u)/$service"
                    type record_action &>/dev/null && record_action "crash_loop" "$service" "restart_count=$restart_count"
                    has_crash_loop=true
                    continue
                fi

                # Auto-restart if enabled
                if [[ "$AUTO_RESTART" == "true" ]]; then
                    _restart_service "$service"
                    type record_action &>/dev/null && record_action "restart" "$service" "exit_code=$exit_code"
                    sentinel_notify "Sentinel" "Restarted $service (was exit $exit_code)" "Glass" \
                        "Service: $service
Previous exit code: $exit_code

ACTION TAKEN: Auto-restarted via launchctl kickstart.
The daemon will continue monitoring this service."
                    has_restarts=true
                else
                    log_warn "$service crashed (exit $exit_code) — auto-restart disabled"
                    sentinel_notify "Sentinel" "$service crashed (exit $exit_code)" "Submarine" \
                        "Service: $service
Exit code: $exit_code

Auto-restart is DISABLED (AUTO_RESTART=false in config).
To restart manually:
  launchctl kickstart gui/$(id -u)/$service"
                fi
                ;;
        esac
    done

    if [[ "$has_crash_loop" == "true" ]]; then
        return 2
    elif [[ "$has_restarts" == "true" ]]; then
        return 1
    else
        return 0
    fi
}
