#!/usr/bin/env bash
# ================================================================================
# SENTINEL UTILS
# ================================================================================
# Source this file from all sentinel scripts.
#   source "${SENTINEL_HOME:-$HOME/.local/share/ops-sentinel}/sentinel-utils.sh"
#
# Provides: logging, cooldown management, UI wrappers, path constants,
#           machine detection, color codes, threshold defaults
#
# Part of: OPS Sentinel Suite (https://github.com/LEO-OSv5/ops-sentinel-suite)
# Version: 0.1.0
# ================================================================================

SENTINEL_VERSION="0.1.0"

# =============================================================================
  # GUARD: Prevent direct execution — this file is meant to be sourced
  # =============================================================================
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
      echo "ERROR: sentinel-utils.sh should be sourced, not executed directly."
      echo "Usage: source sentinel-utils.sh"
      exit 1
  fi

 # =============================================================================
  # MACHINE DETECTION
  # =============================================================================
  SENTINEL_HOSTNAME=$(hostname -s | sed 's/[^a-zA-Z0-9-]//g' | tr '[:upper:]' '[:lower:]')
  SENTINEL_USER=$(whoami)

  if [[ "$SENTINEL_HOSTNAME" == "node" ]]; then
      SENTINEL_MACHINE="NODE"
      HOMEBREW_PREFIX="/opt/homebrew"
  elif [[ "$SENTINEL_HOSTNAME" == "mainframe" ]]; then
      SENTINEL_MACHINE="MAINFRAME"
      HOMEBREW_PREFIX="/usr/local"
  else
      SENTINEL_MACHINE="UNKNOWN"
      HOMEBREW_PREFIX="/usr/local"
  fi

  # =============================================================================                                                                                                                                                                                                    
  # PATH CONSTANTS                                                                                                                                                                                                                                                                 
  # =============================================================================
  SENTINEL_HOME="${SENTINEL_HOME:-$HOME/.local/share/ops-sentinel}"
  SENTINEL_STATE="$HOME/.sentinel-state"
  SENTINEL_LOGS="$HOME/.sentinel-logs"
  SENTINEL_CONFIG="$HOME/.sentinel-config"

  # =============================================================================
  # DIRECTORY BOOTSTRAP — create dirs if they don't exist
  # =============================================================================
  mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS" "$SENTINEL_CONFIG"

 # =============================================================================                                                                                                                                                                                                    
  # COLOR CONSTANTS                                                                                                                                                                                                                                                                
  # =============================================================================
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'

 # =============================================================================                                                                                                                                                                                                  
  # LOGGING
  # =============================================================================
  log_msg() {
      local level="$1"
      local message="$2"
      local logfile="${3:-$SENTINEL_LOGS/sentinel.log}"
      local timestamp
      timestamp=$(date '+%Y-%m-%d %H:%M:%S')
      echo "[$timestamp] [$SENTINEL_VERSION] [$level] $message" >> "$logfile"
  }

  log_info()  { log_msg "INFO"  "$1" "${2:-}"; }
  log_warn()  { log_msg "WARN"  "$1" "${2:-}"; }
  log_error() { log_msg "ERROR" "$1" "${2:-}"; }

  log_rotate() {
      local logfile="${1:-$SENTINEL_LOGS/sentinel.log}"
      local max_lines="${2:-500}"
      if [[ -f "$logfile" ]] && [[ $(wc -l < "$logfile") -gt $max_lines ]]; then
          tail -n "$max_lines" "$logfile" > "$logfile.tmp" && mv "$logfile.tmp" "$logfile"
      fi
  }

 # =============================================================================
  # COOLDOWN MANAGEMENT
  # =============================================================================
  check_cooldown() {
      local name="$1"
      local seconds="${2:-1800}"
      local cooldown_file="$SENTINEL_STATE/${name}.cooldown"

      if [[ -f "$cooldown_file" ]]; then
          local last_run
          last_run=$(cat "$cooldown_file")
          local now
          now=$(date +%s)
          local diff=$(( now - last_run ))
          if (( diff < seconds )); then
              return 1
          fi
      fi
      return 0
  }

  set_cooldown() {
      local name="$1"
      date +%s > "$SENTINEL_STATE/${name}.cooldown"
  }

  clear_cooldown() {
      local name="$1"
      rm -f "$SENTINEL_STATE/${name}.cooldown"
  }

  # =============================================================================
  # UI WRAPPERS — argv-safe AppleScript dialogs
  # =============================================================================
  sentinel_notify() {
      local title="$1"
      local message="$2"
      local sound="${3:-Glass}"
      osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\"" 2>/dev/null
  }

  sentinel_dialog() {
      local title="$1"
      local message="$2"
      local buttons="${3:-OK}"
      local result
      result=$(osascript -e "display dialog \"$message\" with title \"$title\" buttons {$buttons} default button 1" 2>/dev/null)
      echo "$result"
  }

  sentinel_modal() {
      local title="$1"
      local message="$2"
      osascript -e "display alert \"$title\" message \"$message\" as critical" 2>/dev/null
  }

  # =============================================================================                                                                                                                                                                                                    
  # THRESHOLD DEFAULTS                                                                                                                                                                                                                                                             
  # =============================================================================
  MEMORY_WARNING_PERCENT="${MEMORY_WARNING_PERCENT:-70}"
  MEMORY_CRITICAL_PERCENT="${MEMORY_CRITICAL_PERCENT:-85}"
  SWAP_WARNING_GB="${SWAP_WARNING_GB:-2}"
  SWAP_CRITICAL_GB="${SWAP_CRITICAL_GB:-4}"
  DISK_WARNING_GB="${DISK_WARNING_GB:-20}"
  DISK_CRITICAL_GB="${DISK_CRITICAL_GB:-10}"
  MONITOR_INTERVAL="${MONITOR_INTERVAL:-300}"
  ENFORCER_INTERVAL="${ENFORCER_INTERVAL:-600}"
  ALERT_COOLDOWN="${ALERT_COOLDOWN:-1800}"
