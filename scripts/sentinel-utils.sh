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
# Version: 0.2.0
# ================================================================================

SENTINEL_VERSION="0.2.0"

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

  # sentinel_notify — Send a macOS notification with an optional click action
  # Usage: sentinel_notify "Title" "Message" ["Sound"] ["Detail text"]
  #
  # When terminal-notifier is installed:
  #   - Creates a rich alert file with detail + recent log context
  #   - Clicking the notification opens the alert file
  # When not installed:
  #   - Falls back to osascript (no click action)
  sentinel_notify() {
      local title="$1"
      local message="$2"
      local sound="${3:-Glass}"
      local detail="${4:-}"

      if command -v terminal-notifier &>/dev/null; then
          local alert_file=""

          # Generate rich alert file with context
          local alert_dir="$SENTINEL_LOGS/alerts"
          mkdir -p "$alert_dir"
          local ts
          ts=$(date '+%Y-%m-%d_%H-%M-%S')
          alert_file="$alert_dir/alert-${ts}.txt"

          {
              echo "═══════════════════════════════════════════════"
              echo "  OPS SENTINEL ALERT"
              echo "═══════════════════════════════════════════════"
              echo ""
              echo "  TYPE:    $title"
              echo "  TIME:    $(date '+%Y-%m-%d %H:%M:%S')"
              echo "  MACHINE: ${SENTINEL_MACHINE:-UNKNOWN}"
              echo ""
              echo "═══════════════════════════════════════════════"
              echo ""
              echo "$message"
              echo ""
              if [[ -n "$detail" ]]; then
                  echo "─── Detail ────────────────────────────────────"
                  echo "$detail"
                  echo ""
              fi
              echo "─── What To Do ────────────────────────────────"
              echo "  sentinel-status    — Live dashboard"
              echo "  sentinel-triage    — Emergency intervention"
              echo "  Log: $SENTINEL_LOGS/sentinel.log"
              echo ""
              echo "─── Recent Log ────────────────────────────────"
              tail -15 "$SENTINEL_LOGS/sentinel.log" 2>/dev/null || echo "  (no log yet)"
          } > "$alert_file"
          # Write JSON alert for dashboard API
          local json_alert="$alert_dir/alert-${ts}.json"
          local severity="info"
          if [[ "$title" == *"CRITICAL"* || "$title" == *"critical"* ]]; then severity="critical"
          elif [[ "$title" == *"Warning"* || "$title" == *"warning"* || "$title" == *"WARNING"* ]]; then severity="warning"
          fi
          # JSON escape helper (local, no dependency on write-status.sh)
          local esc_title="${title//\\/\\\\}"; esc_title="${esc_title//\"/\\\"}"
          local esc_msg="${message//\\/\\\\}"; esc_msg="${esc_msg//\"/\\\"}"
          local esc_detail="${detail//\\/\\\\}"; esc_detail="${esc_detail//\"/\\\"}"
          esc_detail="${esc_detail//$'\n'/\\n}"
          printf '{"timestamp":"%s","type":"%s","severity":"%s","message":"%s","detail":"%s"}\n' \
              "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
              "$esc_title" "$severity" "$esc_msg" "$esc_detail" > "$json_alert"

          # Clean up alerts older than 24 hours
          find "$alert_dir" -name "alert-*.txt" -mmin +1440 -delete 2>/dev/null || true
          find "$alert_dir" -name "alert-*.json" -mmin +1440 -delete 2>/dev/null || true

          # Click action: dashboard URL if server running, else open .txt file
          if curl -s -o /dev/null --connect-timeout 1 "http://localhost:${WEB_PORT:-8888}/api/status" 2>/dev/null; then
              terminal-notifier \
                  -title "$title" \
                  -message "$message" \
                  -sound "$sound" \
                  -group "sentinel" \
                  -open "http://localhost:${WEB_PORT:-8888}/#alert-${ts}" \
                  2>/dev/null &
          else
              terminal-notifier \
                  -title "$title" \
                  -message "$message" \
                  -sound "$sound" \
                  -group "sentinel" \
                  -execute "open '$alert_file'" \
                  2>/dev/null &
          fi
      else
          osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\"" 2>/dev/null
      fi
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

  # =============================================================================
  # CONFIG LOADER
  # =============================================================================
  # Priority: explicit arg > user config > repo default
  # Sourcing a config file overrides the threshold defaults above.
  load_config() {
      local config_file="${1:-}"
      if [[ -n "$config_file" ]] && [[ -f "$config_file" ]]; then
          source "$config_file"
      elif [[ -f "$SENTINEL_CONFIG/sentinel.conf" ]]; then
          source "$SENTINEL_CONFIG/sentinel.conf"
      elif [[ -f "$SENTINEL_HOME/sentinel.conf" ]]; then
          source "$SENTINEL_HOME/sentinel.conf"
      fi
  }
