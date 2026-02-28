#!/usr/bin/env bash
# ================================================================================
# WRITE-STATUS — JSON data writer for web dashboard
# ================================================================================
# Source this file from sentinel-daemon.sh. Do NOT execute directly.
#
# Requires (already sourced by daemon):
#   - sentinel-utils.sh  (SENTINEL_LOGS, SENTINEL_MACHINE, log_info, etc.)
#   - sentinel.conf      (MONITORED_SERVICES, WEB_HISTORY_DAYS, etc.)
#   - check-pressure.sh  (PHASE1_CRITICAL, KILL_NEVER)
#
# Provides:
#   write_status()       — writes status.json + appends to history.jsonl
#   record_action()      — appends an action to actions.jsonl
#
# Data collectors (prefixed _ws_ to avoid collisions):
#   _ws_memory()         — JSON: used_mb, total_mb, free_mb, percent
#   _ws_swap()           — JSON: used_mb, total_mb, percent
#   _ws_disk()           — JSON: used_gb, total_gb, free_gb, percent
#   _ws_load()           — JSON: avg_1m, cores, percent
#   _ws_network()        — JSON: bytes_in, bytes_out
#   _ws_services()       — JSON array of service status objects
#   _ws_top_processes()  — JSON array of top 10 processes by RSS
#   _ws_backups()        — JSON: ops_sync, ops_mini, github_stale
#   _ws_predictions()    — JSON: swap/disk forecasts, suggested kills, warnings
#
# Part of: OPS Sentinel Suite
# ================================================================================

# =============================================================================
# GUARD: Prevent direct execution
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: write-status.sh should be sourced, not executed directly."
    echo "Usage: source write-status.sh"
    exit 1
fi

# =============================================================================
# _ws_escape — Escape a string for safe JSON embedding
# =============================================================================
# Handles: backslashes, double quotes, newlines, tabs, carriage returns
# =============================================================================
_ws_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s=$(printf '%s' "$s" | tr '\n' ' ' | tr '\r' ' ' | tr '\t' ' ')
    printf '%s' "$s"
}

# =============================================================================
# _ws_memory — Memory usage as JSON
# =============================================================================
# Uses sysctl hw.memsize for total, vm_stat for free/active/wired pages.
# Note: Uses $NF (last field) since "Pages wired down:" has 3 label words.
# Returns: {"used_mb":N,"total_mb":N,"free_mb":N,"percent":N}
# =============================================================================
_ws_memory() {
    local total_bytes
    total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "8589934592")
    local total_mb=$(( total_bytes / 1024 / 1024 ))

    local page_size
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "16384")

    local vmstat_output
    vmstat_output=$(vm_stat 2>/dev/null || true)

    local pages_free pages_active pages_wired
    pages_free=$(echo "$vmstat_output" | awk '/Pages free/ {gsub(/\./,""); print $NF}')
    pages_active=$(echo "$vmstat_output" | awk '/Pages active/ {gsub(/\./,""); print $NF}')
    pages_wired=$(echo "$vmstat_output" | awk '/Pages wired/ {gsub(/\./,""); print $NF}')

    pages_free="${pages_free:-0}"
    pages_active="${pages_active:-0}"
    pages_wired="${pages_wired:-0}"

    local used_mb=$(( (pages_active + pages_wired) * page_size / 1024 / 1024 ))
    local free_mb=$(( pages_free * page_size / 1024 / 1024 ))
    local percent=0
    if (( total_mb > 0 )); then
        percent=$(( used_mb * 100 / total_mb ))
    fi

    echo "{\"used_mb\":${used_mb},\"total_mb\":${total_mb},\"free_mb\":${free_mb},\"percent\":${percent}}"
}

# =============================================================================
# _ws_swap — Swap usage as JSON
# =============================================================================
# Parses sysctl vm.swapusage.
# Returns: {"used_mb":N,"total_mb":N,"percent":N}
# =============================================================================
_ws_swap() {
    local swap_line
    swap_line=$(sysctl vm.swapusage 2>/dev/null || echo "vm.swapusage: total = 0.00M  used = 0.00M  free = 0.00M")

    local used total
    used=$(echo "$swap_line" | sed -n 's/.*used = \([0-9]*\)\..*/\1/p')
    total=$(echo "$swap_line" | sed -n 's/.*total = \([0-9]*\)\..*/\1/p')
    used="${used:-0}"
    total="${total:-0}"

    local percent=0
    if (( total > 0 )); then
        percent=$(( used * 100 / total ))
    fi

    echo "{\"used_mb\":${used},\"total_mb\":${total},\"percent\":${percent}}"
}

# =============================================================================
# _ws_disk — Disk usage as JSON
# =============================================================================
# Uses df -g / for root volume.
# Returns: {"used_gb":N,"total_gb":N,"free_gb":N,"percent":N}
# =============================================================================
_ws_disk() {
    local line
    line=$(df -g / 2>/dev/null | awk 'NR==2')

    local total used avail
    total=$(echo "$line" | awk '{print $2}')
    used=$(echo "$line" | awk '{print $3}')
    avail=$(echo "$line" | awk '{print $4}')
    total="${total:-0}"
    used="${used:-0}"
    avail="${avail:-0}"

    local percent=0
    if (( total > 0 )); then
        percent=$(( used * 100 / total ))
    fi

    echo "{\"used_gb\":${used},\"total_gb\":${total},\"free_gb\":${avail},\"percent\":${percent}}"
}

# =============================================================================
# _ws_load — Load average as JSON
# =============================================================================
# Uses sysctl vm.loadavg for 1-minute average, hw.ncpu for core count.
# Returns: {"avg_1m":N,"cores":N,"percent":N}
# =============================================================================
_ws_load() {
    local load
    load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
    local cores
    cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "4")
    load="${load:-0}"

    # Convert float load to integer percent relative to core count
    local percent
    percent=$(awk "BEGIN {printf \"%d\", ($load/$cores)*100}" 2>/dev/null || echo "0")

    echo "{\"avg_1m\":${load},\"cores\":${cores},\"percent\":${percent}}"
}

# =============================================================================
# _ws_network — Network I/O as JSON
# =============================================================================
# Parses netstat -ib for en0 interface bytes in/out.
# Returns: {"bytes_in":N,"bytes_out":N}
# =============================================================================
_ws_network() {
    local net_line
    net_line=$(netstat -ib 2>/dev/null | awk '/^en0 / && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print; exit}')

    local bytes_in bytes_out
    if [[ -n "$net_line" ]]; then
        bytes_in=$(echo "$net_line" | awk '{print $7}')
        bytes_out=$(echo "$net_line" | awk '{print $10}')
    fi
    bytes_in="${bytes_in:-0}"
    bytes_out="${bytes_out:-0}"

    echo "{\"bytes_in\":${bytes_in},\"bytes_out\":${bytes_out}}"
}

# =============================================================================
# _ws_services — Service status as JSON array
# =============================================================================
# Checks launchctl list for each service in MONITORED_SERVICES.
# Returns: [{"name":"short","label":"full","status":"running","pid":N,"exit_code":N}, ...]
# =============================================================================
_ws_services() {
    local result="["
    local first=true
    local IFS=','

    for service in $MONITORED_SERVICES; do
        # Trim whitespace
        service=$(echo "$service" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$service" ]] && continue

        local short_name="${service##*.}"
        local line
        line=$(launchctl list 2>/dev/null | grep "$service" || true)

        local status="missing"
        local pid="-1"
        local exit_code="-1"

        if [[ -n "$line" ]]; then
            pid=$(echo "$line" | awk '{print $1}')
            exit_code=$(echo "$line" | awk '{print $2}')

            if [[ "$pid" == "-" ]] || [[ "$exit_code" != "0" ]]; then
                status="crashed"
                pid="-1"
            else
                status="running"
            fi
        fi

        if [[ "$first" == "true" ]]; then
            first=false
        else
            result="${result},"
        fi

        local esc_short esc_label
        esc_short=$(_ws_escape "$short_name")
        esc_label=$(_ws_escape "$service")
        result="${result}{\"name\":\"${esc_short}\",\"label\":\"${esc_label}\",\"status\":\"${status}\",\"pid\":${pid},\"exit_code\":${exit_code}}"
    done

    result="${result}]"
    echo "$result"
}

# =============================================================================
# _ws_top_processes — Top 10 processes by RSS as JSON array
# =============================================================================
# Uses ps -eo pid,rss,comm -m (sorted by memory descending).
# Marks each with killable flag based on KILL_NEVER.
# Returns: [{"pid":N,"rss_mb":N,"name":"...","killable":bool}, ...]
# =============================================================================
_ws_top_processes() {
    local result="["
    local count=0
    local first=true

    local ps_output
    ps_output=$(ps -eo pid,rss,comm -m 2>/dev/null || true)

    while IFS= read -r line; do
        # Skip header
        [[ "$line" == *"PID"*"RSS"* ]] && continue
        [[ -z "$line" ]] && continue

        local pid rss comm
        pid=$(echo "$line" | awk '{print $1}')
        rss=$(echo "$line" | awk '{print $2}')
        comm=$(echo "$line" | awk '{$1=""; $2=""; print}' | sed 's/^[[:space:]]*//')

        [[ -z "$pid" ]] && continue
        [[ -z "$rss" ]] && continue

        local rss_mb=$(( rss / 1024 ))
        local short_name
        short_name=$(basename "$comm" 2>/dev/null || echo "$comm")

        # Check killable: not in KILL_NEVER
        local killable="true"
        local IFS_save="$IFS"
        IFS=','
        local entry
        for entry in $KILL_NEVER; do
            entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ "$short_name" == *"$entry"* ]]; then
                killable="false"
                break
            fi
        done
        IFS="$IFS_save"

        if [[ "$first" == "true" ]]; then
            first=false
        else
            result="${result},"
        fi

        local esc_name
        esc_name=$(_ws_escape "$short_name")
        result="${result}{\"pid\":${pid},\"rss_mb\":${rss_mb},\"name\":\"${esc_name}\",\"killable\":${killable}}"

        count=$(( count + 1 ))
        if (( count >= 10 )); then
            break
        fi
    done <<< "$ps_output"

    result="${result}]"
    echo "$result"
}

# =============================================================================
# _ws_backups — Backup channel status as JSON
# =============================================================================
# Checks: OPS sync agent, OPS-mini mount/age, GitHub repo freshness.
# Returns: {"ops_sync":"running"|"missing","ops_mini":{"mounted":bool,"stale":bool},
#           "github_stale":["repo1","repo2"]}
# =============================================================================
_ws_backups() {
    # OPS sync agent
    local sync_status="missing"
    local sync_line
    sync_line=$(launchctl list 2>/dev/null | grep "com.ops.sync" || true)
    if [[ -n "$sync_line" ]]; then
        sync_status="running"
    fi

    # OPS-mini mount
    local mini_mounted="false"
    local mini_stale="false"
    if mount 2>/dev/null | grep -q "OPS-mini"; then
        mini_mounted="true"
        local ops_mini_path="${OPS_MINI_PATH:-/Volumes/OPS-mini/OPS}"
        if [[ -d "$ops_mini_path" ]]; then
            local stale_seconds=$(( OPS_MINI_STALE_HOURS * 3600 ))
            local now
            now=$(date +%s)
            local last_mod
            last_mod=$(stat -f %m "$ops_mini_path" 2>/dev/null || echo "0")
            local age_seconds=$(( now - last_mod ))
            if (( age_seconds > stale_seconds )); then
                mini_stale="true"
            fi
        fi
    fi

    # GitHub freshness
    local github_stale="["
    local stale_first=true
    local stale_seconds=$(( GITHUB_STALE_HOURS * 3600 ))
    local now
    now=$(date +%s)
    local IFS_save="$IFS"
    IFS=','

    for repo in $GITHUB_REPOS; do
        repo=$(echo "$repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$repo" ]] && continue
        [[ ! -d "$repo/.git" ]] && continue

        local repo_name
        repo_name=$(basename "$repo")
        local last_commit_ts
        last_commit_ts=$(git -C "$repo" log --format=%ct -1 2>/dev/null || echo "0")
        local age_seconds=$(( now - last_commit_ts ))

        if (( age_seconds > stale_seconds )); then
            if [[ "$stale_first" == "true" ]]; then
                stale_first=false
            else
                github_stale="${github_stale},"
            fi
            local esc_repo
            esc_repo=$(_ws_escape "$repo_name")
            github_stale="${github_stale}\"${esc_repo}\""
        fi
    done
    IFS="$IFS_save"
    github_stale="${github_stale}]"

    echo "{\"ops_sync\":\"${sync_status}\",\"ops_mini\":{\"mounted\":${mini_mounted},\"stale\":${mini_stale}},\"github_stale\":${github_stale}}"
}


# =============================================================================
# _ws_predictions — Predictive analytics from history + actions
# =============================================================================
# Analyzes last 30 history.jsonl entries for trends. Checks actions.jsonl
# for repeat kills. Returns forecasts + suggestions.
# Returns: {"swap_full_in_minutes":N|null,"disk_full_in_days":N|null,
#           "suggested_kills":[...],"warnings":[...]}
# =============================================================================
_ws_predictions() {
    local history_file="$SENTINEL_LOGS/history.jsonl"
    local actions_file="$SENTINEL_LOGS/actions.jsonl"

    if ! command -v python3 &>/dev/null || [[ ! -f "$history_file" ]]; then
        echo '{"swap_full_in_minutes":null,"disk_full_in_days":null,"suggested_kills":[],"warnings":[]}'
        return
    fi

    python3 -c "
import json, sys

history_file = '$history_file'
actions_file = '$actions_file'
swap_crit = ${SWAP_CRITICAL_MB:-4096}
disk_crit = ${DISK_CRITICAL_GB:-5}

lines = []
try:
    with open(history_file) as f:
        for line in f:
            line = line.strip()
            if line:
                try: lines.append(json.loads(line))
                except: pass
except: pass

lines = lines[-30:]
pred = {'swap_full_in_minutes': None, 'disk_full_in_days': None, 'suggested_kills': [], 'warnings': []}

if len(lines) >= 5:
    swaps = [l.get('swap', 0) for l in lines]
    n = len(swaps)
    slope = (swaps[-1] - swaps[0]) / max(n, 1)
    if slope > 0 and swaps[-1] < 100:
        mins = int((100 - swaps[-1]) / slope)
        if 0 < mins < 1440:
            pred['swap_full_in_minutes'] = mins
            if mins < 60:
                pred['warnings'].append('Swap trending to full in ~' + str(mins) + ' min')

    frees = [l.get('free_mb', 0) for l in lines]
    if frees and frees[-1] < 100:
        pred['warnings'].append('Free memory critically low: ' + str(frees[-1]) + 'MB')

    disks = [l.get('disk', 0) for l in lines]
    if len(disks) >= 5:
        d_slope = (disks[-1] - disks[0]) / max(n, 1)
        if d_slope > 0 and disks[-1] < 100:
            d_mins = int((100 - disks[-1]) / d_slope)
            d_days = d_mins // 1440
            if 0 < d_days < 365:
                pred['disk_full_in_days'] = d_days

try:
    kills = {}
    with open(actions_file) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                a = json.loads(line)
                if a.get('type') == 'kill':
                    t = a.get('target', '')
                    freed = a.get('freed_mb', 0) or a.get('details', {}).get('freed_mb', 0)
                    if t not in kills: kills[t] = {'count': 0, 'total_freed': 0}
                    kills[t]['count'] += 1
                    kills[t]['total_freed'] += freed
            except: pass
    for t, d in sorted(kills.items(), key=lambda x: x[1]['total_freed'], reverse=True)[:3]:
        avg = d['total_freed'] // max(d['count'], 1)
        pred['suggested_kills'].append({'name': t, 'avg_freed_mb': avg, 'reason': 'Killed ' + str(d['count']) + 'x, avg freed ~' + str(avg) + 'MB'})
except: pass

print(json.dumps(pred))
" 2>/dev/null || echo '{"swap_full_in_minutes":null,"disk_full_in_days":null,"suggested_kills":[],"warnings":[]}'
}

# =============================================================================
# write_status — Main function: write status.json + append history.jsonl
# =============================================================================
# Called by daemon each cycle. Collects all system state and writes:
#   1. $SENTINEL_LOGS/status.json  — full snapshot (atomic write via tmp+mv)
#   2. Appends to $SENTINEL_LOGS/history.jsonl — compact time-series
#   3. Rotates history.jsonl to keep WEB_HISTORY_DAYS days (~1440 lines/day)
# =============================================================================
write_status() {
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local cycle="${CYCLE_COUNT:-0}"
    local machine="${SENTINEL_MACHINE:-UNKNOWN}"

    # Collect all metrics
    local mem swap disk load net services procs backups
    mem=$(_ws_memory)
    swap=$(_ws_swap)
    disk=$(_ws_disk)
    load=$(_ws_load)
    net=$(_ws_network)
    services=$(_ws_services)
    procs=$(_ws_top_processes)
    backups=$(_ws_backups)

    # Predictions engine
    local predictions_json
    predictions_json=$(_ws_predictions)

    # Pressure state
    local pressure_gate="false"
    local phase1_critical="false"
    if [[ "${PHASE1_CRITICAL:-false}" == "true" ]]; then
        pressure_gate="true"
        phase1_critical="true"
    fi

    # Build status.json
    local status_json="{\"timestamp\":\"${timestamp}\",\"cycle\":${cycle},\"machine\":\"${machine}\",\"memory\":${mem},\"swap\":${swap},\"disk\":${disk},\"load\":${load},\"network\":${net},\"services\":${services},\"backups\":${backups},\"top_processes\":${procs},\"pressure_gate\":${pressure_gate},\"phase1_critical\":${phase1_critical},\"predictions\":${predictions_json}}"

    # Atomic write: tmp file + mv
    local tmp_file="${SENTINEL_LOGS}/status.json.tmp.$$"
    printf '%s\n' "$status_json" > "$tmp_file"
    mv -f "$tmp_file" "${SENTINEL_LOGS}/status.json"

    # --- History line (compact) ---
    # Extract numeric values from JSON strings using sed
    local mem_pct swap_pct disk_pct load_pct free_mb
    mem_pct=$(echo "$mem" | sed -n 's/.*"percent":\([0-9]*\).*/\1/p')
    swap_pct=$(echo "$swap" | sed -n 's/.*"percent":\([0-9]*\).*/\1/p')
    disk_pct=$(echo "$disk" | sed -n 's/.*"percent":\([0-9]*\).*/\1/p')
    load_pct=$(echo "$load" | sed -n 's/.*"percent":\([0-9]*\).*/\1/p')
    free_mb=$(echo "$mem" | sed -n 's/.*"free_mb":\([0-9]*\).*/\1/p')

    mem_pct="${mem_pct:-0}"
    swap_pct="${swap_pct:-0}"
    disk_pct="${disk_pct:-0}"
    load_pct="${load_pct:-0}"
    free_mb="${free_mb:-0}"

    local history_line="{\"t\":\"${timestamp}\",\"mem\":${mem_pct},\"swap\":${swap_pct},\"disk\":${disk_pct},\"load\":${load_pct},\"free_mb\":${free_mb}}"
    echo "$history_line" >> "${SENTINEL_LOGS}/history.jsonl"

    # --- History rotation ---
    # Keep WEB_HISTORY_DAYS days worth of data (~1440 lines/day at 1-min intervals)
    local max_lines=$(( ${WEB_HISTORY_DAYS:-7} * 1440 ))
    if [[ -f "${SENTINEL_LOGS}/history.jsonl" ]]; then
        local current_lines
        current_lines=$(wc -l < "${SENTINEL_LOGS}/history.jsonl" | tr -d ' ')
        if (( current_lines > max_lines )); then
            tail -n "$max_lines" "${SENTINEL_LOGS}/history.jsonl" > "${SENTINEL_LOGS}/history.jsonl.tmp"
            mv -f "${SENTINEL_LOGS}/history.jsonl.tmp" "${SENTINEL_LOGS}/history.jsonl"
        fi
    fi

    log_info "write_status: cycle=${cycle}, mem=${mem_pct}%, swap=${swap_pct}%, disk=${disk_pct}%"
}

# =============================================================================
# record_action — Append an action entry to actions.jsonl
# =============================================================================
# Usage: record_action "kill" "ollama" "tier=2,freed_mb=1200"
# Parses comma-separated key=value pairs into JSON.
# =============================================================================
record_action() {
    local action_type="$1"
    local target="$2"
    local details_str="${3:-}"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local cycle="${CYCLE_COUNT:-0}"

    # Parse comma-separated key=value pairs into JSON object
    local details_json="{"
    local first=true

    if [[ -n "$details_str" ]]; then
        local IFS_save="$IFS"
        IFS=','
        for pair in $details_str; do
            IFS="$IFS_save"
            # Trim whitespace
            pair=$(echo "$pair" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$pair" ]] && continue

            local key val
            key="${pair%%=*}"
            val="${pair#*=}"

            if [[ "$first" == "true" ]]; then
                first=false
            else
                details_json="${details_json},"
            fi

            # If value is numeric, don't quote it
            if [[ "$val" =~ ^[0-9]+$ ]]; then
                details_json="${details_json}\"$(_ws_escape "$key")\":${val}"
            else
                details_json="${details_json}\"$(_ws_escape "$key")\":\"$(_ws_escape "$val")\""
            fi
        done
        IFS="$IFS_save"
    fi
    details_json="${details_json}}"

    local esc_type esc_target
    esc_type=$(_ws_escape "$action_type")
    esc_target=$(_ws_escape "$target")

    local action_line="{\"timestamp\":\"${timestamp}\",\"cycle\":${cycle},\"type\":\"${esc_type}\",\"target\":\"${esc_target}\",\"details\":${details_json}}"
    echo "$action_line" >> "${SENTINEL_LOGS}/actions.jsonl"

    # Rotate actions.jsonl (keep WEB_ACTIONS_DAYS days, ~1 action per 5 min max = 288/day)
    local max_action_lines=$(( ${WEB_ACTIONS_DAYS:-30} * 288 ))
    if [[ -f "${SENTINEL_LOGS}/actions.jsonl" ]]; then
        local current_lines
        current_lines=$(wc -l < "${SENTINEL_LOGS}/actions.jsonl" | tr -d ' ')
        if (( current_lines > max_action_lines )); then
            tail -n "$max_action_lines" "${SENTINEL_LOGS}/actions.jsonl" > "${SENTINEL_LOGS}/actions.jsonl.tmp"
            mv -f "${SENTINEL_LOGS}/actions.jsonl.tmp" "${SENTINEL_LOGS}/actions.jsonl"
        fi
    fi

    log_info "record_action: type=${action_type}, target=${target}"
}
