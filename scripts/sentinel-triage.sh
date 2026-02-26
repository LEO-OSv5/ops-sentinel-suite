#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# OPS Sentinel Suite — Emergency Triage
# ═══════════════════════════════════════════════════════════════
# Kills all non-essential processes and stops expendable bots.
# ALWAYS asks for confirmation. This is the manual nuclear option.
#
# Usage: sentinel-triage
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sentinel-utils.sh"

if [[ -f "$SENTINEL_CONFIG/sentinel.conf" ]]; then
    source "$SENTINEL_CONFIG/sentinel.conf"
elif [[ -f "$SCRIPT_DIR/../config/sentinel.conf" ]]; then
    source "$SCRIPT_DIR/../config/sentinel.conf"
fi

echo -e "${RED}${BOLD}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║         SENTINEL TRIAGE MODE          ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"

# Estimate what we'd free
echo -e "${BOLD}Will kill:${NC}"

estimate_total=0

# Tier 1
IFS=',' read -ra tier1_targets <<< "$KILL_TIER_1"
for target in "${tier1_targets[@]}"; do
    target=$(echo "$target" | xargs)
    [[ -z "$target" ]] && continue
    rss=$(ps -eo rss,comm 2>/dev/null | grep -i "$target" | awk '{sum+=$1} END {print int(sum/1024)}')
    rss="${rss:-0}"
    if (( rss > 0 )); then
        echo -e "  ${RED}✗${NC} $target (~${rss} MB)"
        estimate_total=$((estimate_total + rss))
    else
        echo -e "  ${YELLOW}-${NC} $target (not running)"
    fi
done

# Tier 2
IFS=',' read -ra tier2_targets <<< "$KILL_TIER_2"
for target in "${tier2_targets[@]}"; do
    target=$(echo "$target" | xargs)
    [[ -z "$target" ]] && continue
    rss=$(ps -eo rss,comm 2>/dev/null | grep -i "$target" | awk '{sum+=$1} END {print int(sum/1024)}')
    rss="${rss:-0}"
    if (( rss > 0 )); then
        echo -e "  ${RED}✗${NC} $target (~${rss} MB)"
        estimate_total=$((estimate_total + rss))
    else
        echo -e "  ${YELLOW}-${NC} $target (not running)"
    fi
done

# Expendable bots from Tier 3
IFS=',' read -ra tier3_targets <<< "$KILL_TIER_3"
for target in "${tier3_targets[@]}"; do
    target=$(echo "$target" | xargs)
    [[ -z "$target" ]] && continue
    echo -e "  ${YELLOW}◼${NC} Stop: ${target##*.}"
done

echo ""
echo -e "${BOLD}Will keep:${NC}"
echo -e "  ${GREEN}●${NC} claude, Ghostty, Finder, tmux, PERIAPSIS"
echo ""
echo -e "Estimated RAM freed: ${BOLD}~${estimate_total} MB${NC}"
echo ""

# Confirmation
echo -ne "${YELLOW}Proceed with triage? [y/N]:${NC} "
read -rn1 confirm
echo ""

if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
    echo "Triage cancelled."
    exit 0
fi

echo ""
echo -e "${BOLD}Executing triage...${NC}"

# Kill Tier 1 + 2
freed=0
for target in "${tier1_targets[@]}" "${tier2_targets[@]}"; do
    target=$(echo "$target" | xargs)
    [[ -z "$target" ]] && continue
    rss=$(ps -eo rss,comm 2>/dev/null | grep -i "$target" | awk '{sum+=$1} END {print int(sum/1024)}')
    rss="${rss:-0}"
    pkill -f "$target" 2>/dev/null || true
    freed=$((freed + rss))
    if (( rss > 0 )); then
        echo -e "  ${RED}✗${NC} Killed: $target (~${rss} MB)"
    fi
done

# Stop Tier 3 bots via launchctl
uid=$(id -u)
for svc in "${tier3_targets[@]}"; do
    svc=$(echo "$svc" | xargs)
    [[ -z "$svc" ]] && continue
    launchctl bootout "gui/${uid}/${svc}" 2>/dev/null || true
    echo -e "  ${YELLOW}◼${NC} Stopped: ${svc##*.}"
done

echo ""
echo -e "${GREEN}${BOLD}Triage complete.${NC} Freed ~${freed} MB."
echo "Stopped bots can be restarted with: launchctl kickstart gui/${uid}/SERVICE"

log_info "TRIAGE: freed ~${freed} MB, stopped ${#tier3_targets[@]} bots"
sentinel_notify "Sentinel" "Triage complete — freed ~${freed} MB" "Glass"
