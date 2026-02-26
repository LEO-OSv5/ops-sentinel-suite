#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# OPS Sentinel Suite — Live Interactive Dashboard
# ═══════════════════════════════════════════════════════════════
# Usage: sentinel-status
#
# Live-updating TUI. Refreshes every 2 seconds.
# Keys: [q] quit  [r] restart crashed  [t] triage  [k] kill
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sentinel-utils.sh"

if [[ -f "$SENTINEL_CONFIG/sentinel.conf" ]]; then
    source "$SENTINEL_CONFIG/sentinel.conf"
elif [[ -f "$SCRIPT_DIR/../config/sentinel.conf" ]]; then
    source "$SCRIPT_DIR/../config/sentinel.conf"
fi

REFRESH_INTERVAL=2

# ─── Drawing Helpers ───

_bar() {
    local percent=$1 width=${2:-20}
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local color

    if (( percent >= 80 )); then color="$RED"
    elif (( percent >= 60 )); then color="$YELLOW"
    else color="$GREEN"
    fi

    printf "${color}"
    for ((i=0; i<filled; i++)); do printf "▓"; done
    printf "${NC}"
    for ((i=0; i<empty; i++)); do printf "░"; done
}

# ─── Data Collection ───

_get_memory_info() {
    local total_bytes
    total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "8589934592")
    local total_mb=$(( total_bytes / 1024 / 1024 ))
    local page_size
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "16384")

    local pages_free pages_active pages_wired
    pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
    pages_wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {gsub(/\./,"",$3); print $3}')

    local used_mb=$(( (pages_active + pages_wired) * page_size / 1024 / 1024 ))
    local free_mb=$(( pages_free * page_size / 1024 / 1024 ))
    local percent=0
    if (( total_mb > 0 )); then
        percent=$(( used_mb * 100 / total_mb ))
    fi

    echo "$used_mb $total_mb $percent $free_mb"
}

_get_swap_info() {
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
    echo "$used $total $percent"
}

_get_disk_info() {
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
    echo "$used $total $percent $avail"
}

_get_load() {
    local load
    load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
    local cores
    cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "4")
    load="${load:-0}"
    local percent
    percent=$(awk "BEGIN {printf \"%d\", ($load/$cores)*100}")
    echo "$load $cores $percent"
}

_get_service_status_line() {
    local service="$1"
    local short_name="${service##*.}"
    local line
    line=$(launchctl list 2>/dev/null | grep "$service" || true)

    if [[ -z "$line" ]]; then
        printf "  ${RED}✗${NC} %-18s %-8s ${RED}NOT FOUND${NC}\n" "$short_name" "----"
        return
    fi

    local pid exit_code
    pid=$(echo "$line" | awk '{print $1}')
    exit_code=$(echo "$line" | awk '{print $2}')

    if [[ "$pid" == "-" ]] || [[ "$exit_code" != "0" ]]; then
        printf "  ${RED}✗${NC} %-18s %-8s ${RED}CRASHED (exit $exit_code)${NC}\n" "$short_name" "----"
    else
        printf "  ${GREEN}●${NC} %-18s %-8s ${GREEN}running${NC}\n" "$short_name" "$pid"
    fi
}

_get_recent_activity() {
    local logfile="$SENTINEL_LOGS/sentinel.log"
    if [[ -f "$logfile" ]]; then
        tail -30 "$logfile" | grep -E 'WARN|ERROR|Kill|Restart|Sort|freed|CRITICAL|Triage' | tail -5
    fi
}

# ─── Render Frame ───

_render() {
    local mem_used mem_total mem_pct mem_free
    read -r mem_used mem_total mem_pct mem_free <<< "$(_get_memory_info)"
    local swap_used swap_total swap_pct
    read -r swap_used swap_total swap_pct <<< "$(_get_swap_info)"
    local disk_used disk_total disk_pct disk_avail
    read -r disk_used disk_total disk_pct disk_avail <<< "$(_get_disk_info)"
    local load_avg load_cores load_pct
    read -r load_avg load_cores load_pct <<< "$(_get_load)"

    local now
    now=$(date '+%H:%M:%S')

    local cycle_num="--"
    if [[ -f "$SENTINEL_STATE/cycle-counter" ]]; then
        cycle_num=$(cat "$SENTINEL_STATE/cycle-counter")
    fi

    # Move cursor to top-left (no clear — prevents flicker)
    tput cup 0 0

    echo -e "┌──────────────────────────────────────────────────────────────────┐"
    echo -e "│  ${BOLD}OPS SENTINEL${NC}         ${CYAN}$SENTINEL_MACHINE${NC}         $now         │"
    echo -e "├──────────────────────────────────────────────────────────────────┤"

    # Memory bar
    printf "│  MEMORY  $(_bar $mem_pct)  %5d / %5d MB  %3d%%  │\n" "$mem_used" "$mem_total" "$mem_pct"

    # Swap bar
    printf "│  SWAP    $(_bar $swap_pct)  %5d / %5d MB  %3d%%  │\n" "$swap_used" "$swap_total" "$swap_pct"

    # CPU/Load bar
    printf "│  LOAD    $(_bar $load_pct)  %5s / %-2d cores   %3d%%  │\n" "$load_avg" "$load_cores" "$load_pct"

    # Disk bar
    printf "│  DISK    $(_bar $disk_pct)  %5d / %5d GB   %3d%%  │\n" "$disk_used" "$disk_total" "$disk_pct"

    echo -e "├──────────────────────────────────────────────────────────────────┤"
    echo -e "│  ${BOLD}SERVICES${NC}                                                        │"

    local IFS=','
    for svc in $MONITORED_SERVICES; do
        svc=$(echo "$svc" | xargs)
        printf "│"
        _get_service_status_line "$svc"
    done

    echo -e "├──────────────────────────────────────────────────────────────────┤"
    echo -e "│  ${BOLD}BACKUPS${NC}                                                         │"

    if mount 2>/dev/null | grep -q "OPS-mini"; then
        echo -e "│  OPS-mini  ${GREEN}✓ mounted${NC}                                             │"
    else
        echo -e "│  OPS-mini  ${RED}✗ disconnected${NC}                                         │"
    fi

    echo -e "├──────────────────────────────────────────────────────────────────┤"
    echo -e "│  ${BOLD}RECENT ACTIVITY${NC}                                                  │"

    local activity_lines=0
    _get_recent_activity | while IFS= read -r line; do
        local trimmed="${line:22}"  # strip timestamp prefix
        printf "│  %.62s\n" "$trimmed"
        activity_lines=$((activity_lines + 1))
    done

    # Pad to consistent height
    echo -e "│                                                                  │"
    echo -e "├──────────────────────────────────────────────────────────────────┤"
    echo -e "│  ${BOLD}[q]${NC} quit  ${BOLD}[r]${NC} restart crashed  ${BOLD}[t]${NC} triage  ${BOLD}[k]${NC} kill process  │"
    printf  "└─────────────────────────────────────── cycle: #%-6s ─────────┘\n" "$cycle_num"
}

# ─── Keyboard Handler ───

_handle_key() {
    local key="$1"
    case "$key" in
        q|Q)
            tput cnorm
            clear
            exit 0
            ;;
        r|R)
            echo -e "\n${YELLOW}Restarting crashed services...${NC}"
            local IFS=','
            local uid
            uid=$(id -u)
            for svc in $MONITORED_SERVICES; do
                svc=$(echo "$svc" | xargs)
                local line
                line=$(launchctl list 2>/dev/null | grep "$svc" || true)
                if [[ -z "$line" ]]; then continue; fi
                local pid exit_code
                pid=$(echo "$line" | awk '{print $1}')
                exit_code=$(echo "$line" | awk '{print $2}')
                if [[ "$pid" == "-" ]] || [[ "${exit_code:-0}" != "0" ]]; then
                    launchctl kickstart -k "gui/${uid}/${svc}" 2>/dev/null || true
                    echo "  Restarted: ${svc##*.}"
                fi
            done
            sleep 1
            ;;
        t|T)
            tput cnorm
            clear
            bash "$SCRIPT_DIR/sentinel-triage.sh"
            tput civis
            clear
            ;;
        k|K)
            echo -e "\n${YELLOW}Kill which process? (enter PID or name):${NC} "
            tput cnorm
            read -r target
            tput civis
            if [[ -z "$target" ]]; then
                echo "  Cancelled."
            elif [[ "$target" =~ ^[0-9]+$ ]]; then
                kill -TERM "$target" 2>/dev/null && echo "  Killed PID $target" || echo "  Failed to kill PID $target"
            else
                pkill -f "$target" 2>/dev/null && echo "  Killed '$target'" || echo "  No process matching '$target'"
            fi
            sleep 1
            ;;
    esac
}

# ─── Main Loop ───

# Hide cursor, clear screen
tput civis
clear

# Restore cursor on exit
trap 'tput cnorm; echo' EXIT

while true; do
    _render

    # Non-blocking key read (2 second timeout = refresh rate)
    if read -rsn1 -t "$REFRESH_INTERVAL" key 2>/dev/null; then
        _handle_key "$key"
    fi
done
