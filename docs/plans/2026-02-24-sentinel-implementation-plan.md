# OPS Sentinel Suite — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a self-correcting automation daemon for NODE that monitors system health, manages services, verifies backups, enforces disk hygiene, and auto-organizes files — all from a single lightweight process.

**Architecture:** Single layered daemon (`sentinel-daemon.sh`) runs every 60s via one LaunchAgent. Five-phase pipeline: pressure → services → backups → disk → file janitor. Each phase is a separate `lib/check-*.sh` module sourced by the daemon. Config-driven thresholds in `sentinel.conf`. Two manual tools: live dashboard (`sentinel-status.sh`) and emergency triage (`sentinel-triage.sh`).

**Tech Stack:** Bash 3.2 (macOS built-in), LaunchAgent (launchd), osascript (notifications), tput/ANSI (dashboard TUI). No external dependencies.

**Repo:** `/Users/curl/repos/ops-sentinel-suite` on branch `docs/sentinel-suite-redesign`
**Design doc:** `docs/plans/2026-02-24-ops-sentinel-suite-redesign.md`
**Existing code:** `scripts/sentinel-utils.sh` (shared foundation — 159 lines, machine detection, logging, cooldowns, UI wrappers)

---

## Testing Strategy

Each `lib/check-*.sh` module is testable by mocking system commands as bash functions. Tests live in `tests/` and use a lightweight assert pattern (no external framework):

```bash
# tests/test-helpers.sh — shared test utilities
assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label (expected '$expected', got '$actual')"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label (expected to contain '$needle')"
        FAILURES=$((FAILURES + 1))
    fi
}
```

Mock system commands by defining functions with the same name (functions take priority over binaries in bash):

```bash
# Override vm_stat for testing
vm_stat() {
    cat <<'MOCK'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                3000.
Pages active:                             60000.
Pages inactive:                           50000.
MOCK
}
```

Run all tests: `bash tests/run-all.sh`

---

## Task 1: Test Helpers + Config File

**Files:**
- Create: `tests/test-helpers.sh`
- Create: `config/sentinel.conf`
- Create: `tests/test-config.sh`

**Step 1: Create test helpers**

Create `tests/test-helpers.sh`:

```bash
#!/usr/bin/env bash
# Test utilities for OPS Sentinel Suite
# Source this in every test file.

FAILURES=0
TESTS=0

assert_eq() {
    TESTS=$((TESTS + 1))
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_contains() {
    TESTS=$((TESTS + 1))
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label (expected to contain '$needle' in '$haystack')"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_not_contains() {
    TESTS=$((TESTS + 1))
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label (did NOT expect '$needle' in '$haystack')"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_file_exists() {
    TESTS=$((TESTS + 1))
    local path="$1" label="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label (file not found: $path)"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_exit_code() {
    TESTS=$((TESTS + 1))
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label (expected exit $expected, got $actual)"
        FAILURES=$((FAILURES + 1))
    fi
}

test_summary() {
    echo ""
    echo "  Results: $TESTS tests, $FAILURES failures"
    if (( FAILURES > 0 )); then
        echo "  STATUS: FAIL"
        return 1
    else
        echo "  STATUS: PASS"
        return 0
    fi
}
```

**Step 2: Create config file**

Create `config/sentinel.conf`:

```bash
# ═══════════════════════════════════════════════════════════════
# OPS Sentinel Suite — Configuration
# ═══════════════════════════════════════════════════════════════
# All values can be overridden by environment variables.
# Edit this file to tune thresholds for your machine.
# ═══════════════════════════════════════════════════════════════

# --- Pressure Thresholds ---
SWAP_WARNING_MB="${SWAP_WARNING_MB:-2048}"
SWAP_CRITICAL_MB="${SWAP_CRITICAL_MB:-4096}"
MEMORY_FREE_CRITICAL_MB="${MEMORY_FREE_CRITICAL_MB:-200}"
PRESSURE_KILL_COOLDOWN="${PRESSURE_KILL_COOLDOWN:-300}"

# --- Kill Tiers (comma-separated process names or bundle IDs) ---
# Tier 1 = expendable, killed first. Tier 3 = last resort.
KILL_TIER_1="${KILL_TIER_1:-ChatGPT Atlas,Typeless}"
KILL_TIER_2="${KILL_TIER_2:-ollama}"
KILL_TIER_3="${KILL_TIER_3:-com.aether.occult,com.aether.adxstoch,com.aether.syzygy}"
KILL_NEVER="${KILL_NEVER:-claude,Ghostty,Finder,WindowServer,tmux,launchd,sshd}"

# --- Service Monitoring ---
MONITORED_SERVICES="${MONITORED_SERVICES:-com.aether.periapsis,com.aether.occult,com.aether.syzygy,com.aether.adxstoch,com.aether.aether-strategy,com.ops.sync}"
AUTO_RESTART="${AUTO_RESTART:-true}"
MAX_RESTARTS_PER_HOUR="${MAX_RESTARTS_PER_HOUR:-3}"

# --- Backup Freshness ---
GITHUB_STALE_HOURS="${GITHUB_STALE_HOURS:-24}"
OPS_SYNC_STALE_MINUTES="${OPS_SYNC_STALE_MINUTES:-30}"
OPS_MINI_STALE_HOURS="${OPS_MINI_STALE_HOURS:-48}"
GITHUB_REPOS="${GITHUB_REPOS:-/Users/curl/OPS,/Users/curl/repos/aether-periapsis,/Users/curl/repos/aethernote,/Users/curl/repos/strategist,/Users/curl/repos/ops-sentinel-suite}"

# --- Disk ---
DISK_WARNING_GB="${DISK_WARNING_GB:-10}"
DISK_CRITICAL_GB="${DISK_CRITICAL_GB:-5}"

# --- File Janitor ---
JANITOR_ENABLED="${JANITOR_ENABLED:-true}"
JANITOR_WATCH_DIRS="${JANITOR_WATCH_DIRS:-$HOME/Downloads,$HOME/Desktop}"
JANITOR_DESTINATION="${JANITOR_DESTINATION:-/Volumes/OPS-mini/INTAKE}"
JANITOR_FALLBACK_QUEUE="${JANITOR_FALLBACK_QUEUE:-$HOME/Documents/_intake-queue}"
JANITOR_DESKTOP_MAX_AGE_DAYS="${JANITOR_DESKTOP_MAX_AGE_DAYS:-7}"
JANITOR_DOWNLOADS_MAX_AGE_DAYS="${JANITOR_DOWNLOADS_MAX_AGE_DAYS:-3}"
JANITOR_DATE_PREFIX="${JANITOR_DATE_PREFIX:-true}"
JANITOR_IGNORE="${JANITOR_IGNORE:-*.crdownload,*.part,*.tmp}"

# --- Daemon ---
DAEMON_CYCLE_SECONDS="${DAEMON_CYCLE_SECONDS:-60}"
BACKUP_CHECK_INTERVAL="${BACKUP_CHECK_INTERVAL:-10}"
DISK_CHECK_INTERVAL="${DISK_CHECK_INTERVAL:-10}"
JANITOR_CHECK_INTERVAL="${JANITOR_CHECK_INTERVAL:-5}"
LOG_MAX_LINES="${LOG_MAX_LINES:-5000}"

# --- Notifications ---
NOTIFY_METHOD="${NOTIFY_METHOD:-macos}"
```

**Step 3: Write test for config loading**

Create `tests/test-config.sh`:

```bash
#!/usr/bin/env bash
# Test: sentinel.conf loads and all variables are set
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-config.sh ==="

# Source config
source "$SCRIPT_DIR/../config/sentinel.conf"

# Verify key variables are set
assert_eq "2048" "$SWAP_WARNING_MB" "SWAP_WARNING_MB default"
assert_eq "4096" "$SWAP_CRITICAL_MB" "SWAP_CRITICAL_MB default"
assert_eq "200" "$MEMORY_FREE_CRITICAL_MB" "MEMORY_FREE_CRITICAL_MB default"
assert_eq "true" "$AUTO_RESTART" "AUTO_RESTART default"
assert_eq "3" "$MAX_RESTARTS_PER_HOUR" "MAX_RESTARTS_PER_HOUR default"
assert_eq "true" "$JANITOR_ENABLED" "JANITOR_ENABLED default"
assert_eq "10" "$DISK_WARNING_GB" "DISK_WARNING_GB default"
assert_eq "5" "$DISK_CRITICAL_GB" "DISK_CRITICAL_GB default"
assert_contains "$KILL_NEVER" "claude" "claude in KILL_NEVER"
assert_contains "$KILL_NEVER" "Ghostty" "Ghostty in KILL_NEVER"

# Test env-var override
export SWAP_WARNING_MB=1024
source "$SCRIPT_DIR/../config/sentinel.conf"
assert_eq "1024" "$SWAP_WARNING_MB" "SWAP_WARNING_MB env override"
unset SWAP_WARNING_MB

test_summary
```

**Step 4: Run test to verify it passes**

Run: `bash tests/test-config.sh`
Expected: All PASS

**Step 5: Create test runner**

Create `tests/run-all.sh`:

```bash
#!/usr/bin/env bash
# Run all OPS Sentinel Suite tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_FAILURES=0

echo "╔══════════════════════════════════════════╗"
echo "║   OPS Sentinel Suite — Test Runner       ║"
echo "╚══════════════════════════════════════════╝"
echo ""

for test_file in "$SCRIPT_DIR"/test-*.sh; do
    [[ "$(basename "$test_file")" == "test-helpers.sh" ]] && continue
    echo "Running $(basename "$test_file")..."
    if ! bash "$test_file"; then
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    fi
    echo ""
done

echo "════════════════════════════════════════════"
if (( TOTAL_FAILURES > 0 )); then
    echo "TOTAL: $TOTAL_FAILURES test file(s) with failures"
    exit 1
else
    echo "TOTAL: All test files passed"
    exit 0
fi
```

**Step 6: Run full test suite**

Run: `bash tests/run-all.sh`
Expected: All PASS

**Step 7: Commit**

```bash
git add tests/ config/
git commit -m "feat: add test framework and sentinel.conf configuration"
```

---

## Task 2: Update sentinel-utils.sh for Config Loading

**Files:**
- Modify: `scripts/sentinel-utils.sh`
- Create: `tests/test-utils.sh`

**Step 1: Write tests for utils**

Create `tests/test-utils.sh`:

```bash
#!/usr/bin/env bash
# Test: sentinel-utils.sh loads correctly and provides expected functions
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-utils.sh ==="

# Source utils
source "$SCRIPT_DIR/../scripts/sentinel-utils.sh"

# Machine detection
assert_eq "NODE" "$SENTINEL_MACHINE" "machine detected as NODE"
assert_eq "curl" "$SENTINEL_USER" "user detected as curl"

# Path constants exist
assert_eq "$HOME/.local/share/ops-sentinel" "$SENTINEL_HOME" "SENTINEL_HOME default"

# Functions exist
assert_eq "0" "$(type -t log_info >/dev/null 2>&1; echo $?)" "log_info function exists"
assert_eq "0" "$(type -t log_warn >/dev/null 2>&1; echo $?)" "log_warn function exists"
assert_eq "0" "$(type -t log_error >/dev/null 2>&1; echo $?)" "log_error function exists"
assert_eq "0" "$(type -t check_cooldown >/dev/null 2>&1; echo $?)" "check_cooldown function exists"
assert_eq "0" "$(type -t set_cooldown >/dev/null 2>&1; echo $?)" "set_cooldown function exists"
assert_eq "0" "$(type -t sentinel_notify >/dev/null 2>&1; echo $?)" "sentinel_notify function exists"

# Logging works
local test_log="/tmp/sentinel-test-$$.log"
log_info "test message" "$test_log"
assert_file_exists "$test_log" "log file created"
local log_content
log_content=$(cat "$test_log")
assert_contains "$log_content" "[INFO]" "log contains INFO level"
assert_contains "$log_content" "test message" "log contains message"
rm -f "$test_log"

# Cooldown works
set_cooldown "test-cooldown-$$"
check_cooldown "test-cooldown-$$" 5
assert_exit_code "1" "$?" "cooldown is active (returns 1)"
clear_cooldown "test-cooldown-$$"
check_cooldown "test-cooldown-$$" 5
assert_exit_code "0" "$?" "cooldown cleared (returns 0)"

# Config loader function exists (after we add it)
assert_eq "0" "$(type -t load_config >/dev/null 2>&1; echo $?)" "load_config function exists"

test_summary
```

**Step 2: Run test — expect failure on `load_config`**

Run: `bash tests/test-utils.sh`
Expected: FAIL on "load_config function exists"

**Step 3: Add config loader and version bump to sentinel-utils.sh**

Add after the THRESHOLD DEFAULTS section (line 159) in `scripts/sentinel-utils.sh`:

```bash
# =============================================================================
# CONFIG LOADER
# =============================================================================
load_config() {
    local config_file="${1:-}"

    # Priority: explicit arg > user config > repo default
    if [[ -n "$config_file" ]] && [[ -f "$config_file" ]]; then
        source "$config_file"
    elif [[ -f "$SENTINEL_CONFIG/sentinel.conf" ]]; then
        source "$SENTINEL_CONFIG/sentinel.conf"
    elif [[ -f "$SENTINEL_HOME/sentinel.conf" ]]; then
        source "$SENTINEL_HOME/sentinel.conf"
    fi
}
```

Also update `SENTINEL_VERSION` on line 15 from `"0.1.0"` to `"0.2.0"`.

**Step 4: Run test — expect pass**

Run: `bash tests/test-utils.sh`
Expected: All PASS

**Step 5: Commit**

```bash
git add scripts/sentinel-utils.sh tests/test-utils.sh
git commit -m "feat: add config loader to sentinel-utils, add utils tests"
```

---

## Task 3: Pressure Check Module (lib/check-pressure.sh)

This is the most critical module — the self-correcting heart of the suite.

**Files:**
- Create: `scripts/lib/check-pressure.sh`
- Create: `tests/test-check-pressure.sh`

**Step 1: Write failing tests**

Create `tests/test-check-pressure.sh`:

```bash
#!/usr/bin/env bash
# Test: check-pressure.sh detects memory states and takes correct action
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-pressure.sh ==="

# Setup: source utils (need logging, cooldowns)
source "$SCRIPT_DIR/../scripts/sentinel-utils.sh"
source "$SCRIPT_DIR/../config/sentinel.conf"

# Use temp dir for state/logs during tests
export SENTINEL_STATE="/tmp/sentinel-test-state-$$"
export SENTINEL_LOGS="/tmp/sentinel-test-logs-$$"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS"

# Track kills for assertions
KILLED_PIDS=()
NOTIFICATIONS=()

# --- Mock system commands ---
# Mock sysctl to return 8 GB total RAM
sysctl() {
    case "$1" in
        vm.swapusage)
            echo "vm.swapusage: total = 6144.00M  used = ${MOCK_SWAP_USED_MB}.00M  free = 788.88M  (encrypted)"
            ;;
        -n)
            case "$2" in
                hw.memsize) echo "8589934592" ;;  # 8 GB
                hw.ncpu) echo "4" ;;
            esac
            ;;
    esac
}

# Mock vm_stat — pages are 16384 bytes on ARM
vm_stat() {
    cat <<MOCK
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                             ${MOCK_PAGES_FREE}.
Pages active:                             60000.
Pages inactive:                           50000.
Pages speculative:                         2000.
Pages throttled:                              0.
Pages wired down:                        190000.
MOCK
}

# Mock kill — record what would be killed
kill() {
    KILLED_PIDS+=("$2")
}

# Mock sentinel_notify — record notifications
sentinel_notify() {
    NOTIFICATIONS+=("$1: $2")
}

# Mock ps for process lookup
ps() {
    if [[ "$*" == *"ChatGPT Atlas"* ]] || [[ "$*" == *"-eo"* ]]; then
        echo "  PID    RSS COMM"
        echo "20499 395616 ChatGPT Atlas (Renderer)"
        echo "20483 105184 ChatGPT Atlas"
        echo "78289  54176 Typeless Helper (Renderer)"
    fi
}

# Mock pkill
pkill() {
    KILLED_PIDS+=("pkill:$2")
    return 0
}

# Source the module under test
source "$SCRIPT_DIR/../scripts/lib/check-pressure.sh"

# --- Test 1: Normal state (low swap, plenty free) ---
echo "  -- Test: normal state --"
MOCK_SWAP_USED_MB=1000
MOCK_PAGES_FREE=20000   # 20000 * 16384 = ~312 MB free
KILLED_PIDS=()
NOTIFICATIONS=()
clear_cooldown "pressure-kill"

check_pressure
PRESSURE_RESULT=$?

assert_eq "0" "$PRESSURE_RESULT" "normal state returns 0"
assert_eq "0" "${#KILLED_PIDS[@]}" "no kills in normal state"
assert_eq "0" "${#NOTIFICATIONS[@]}" "no notifications in normal state"

# --- Test 2: Warning state (swap above warning threshold) ---
echo "  -- Test: warning state --"
MOCK_SWAP_USED_MB=3000
MOCK_PAGES_FREE=10000
KILLED_PIDS=()
NOTIFICATIONS=()
clear_cooldown "pressure-warn"

check_pressure
PRESSURE_RESULT=$?

assert_eq "1" "$PRESSURE_RESULT" "warning state returns 1"
assert_eq "0" "${#KILLED_PIDS[@]}" "no kills in warning state"

# --- Test 3: Critical state (swap above critical) ---
echo "  -- Test: critical state --"
MOCK_SWAP_USED_MB=5000
MOCK_PAGES_FREE=500    # ~8 MB free — critical
KILLED_PIDS=()
NOTIFICATIONS=()
clear_cooldown "pressure-kill"

check_pressure
PRESSURE_RESULT=$?

assert_eq "2" "$PRESSURE_RESULT" "critical state returns 2"
# Should have attempted kills
if (( ${#KILLED_PIDS[@]} > 0 )); then
    echo "  PASS: kills attempted in critical state (${#KILLED_PIDS[@]} targets)"
    TESTS=$((TESTS + 1))
else
    echo "  FAIL: no kills in critical state"
    TESTS=$((TESTS + 1))
    FAILURES=$((FAILURES + 1))
fi

# --- Test 4: Cooldown prevents re-kill ---
echo "  -- Test: cooldown prevents re-kill --"
set_cooldown "pressure-kill"
KILLED_PIDS=()

check_pressure

assert_eq "0" "${#KILLED_PIDS[@]}" "no kills when cooldown active"

# Cleanup
rm -rf "$SENTINEL_STATE" "$SENTINEL_LOGS"

test_summary
```

**Step 2: Run test — expect failure (module doesn't exist)**

Run: `bash tests/test-check-pressure.sh`
Expected: FAIL — `scripts/lib/check-pressure.sh: No such file or directory`

**Step 3: Implement check-pressure.sh**

Create `scripts/lib/check-pressure.sh`:

```bash
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# check-pressure.sh — Memory/swap pressure detection + auto-kill
# ═══════════════════════════════════════════════════════════════
# Sourced by sentinel-daemon.sh. Do not execute directly.
#
# Returns: 0 = normal, 1 = warning, 2 = critical
# Side effects: kills processes when critical (respects cooldown)
# ═══════════════════════════════════════════════════════════════

# Get current swap usage in MB
_get_swap_used_mb() {
    local swap_line
    swap_line=$(sysctl vm.swapusage 2>/dev/null)
    # Parse: "vm.swapusage: total = 6144.00M  used = 5355.12M  free = 788.88M"
    echo "$swap_line" | sed -n 's/.*used = \([0-9]*\).*/\1/p'
}

# Get free memory in MB (pages_free * page_size / 1024 / 1024)
_get_free_memory_mb() {
    local page_size=16384  # ARM64 macOS
    local pages_free
    pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    echo $(( (pages_free * page_size) / 1024 / 1024 ))
}

# Kill processes matching a name pattern. Returns freed MB estimate.
_kill_by_name() {
    local name="$1"
    local freed=0

    # Find matching PIDs and their RSS (in KB)
    local pids_rss
    pids_rss=$(ps -eo pid,rss,comm 2>/dev/null | grep -i "$name" | grep -v grep || true)

    if [[ -z "$pids_rss" ]]; then
        return 0
    fi

    while IFS= read -r line; do
        local pid rss
        pid=$(echo "$line" | awk '{print $1}')
        rss=$(echo "$line" | awk '{print $2}')
        freed=$(( freed + (rss / 1024) ))
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$pids_rss"

    log_info "Killed '$name' — freed ~${freed} MB"
    echo "$freed"
}

# Check if a process name is in the KILL_NEVER list
_is_protected() {
    local name="$1"
    local IFS=','
    for protected in $KILL_NEVER; do
        protected=$(echo "$protected" | xargs)  # trim whitespace
        if [[ "$name" == *"$protected"* ]]; then
            return 0  # protected
        fi
    done
    return 1  # not protected
}

# Kill a tier of processes. Returns total freed MB.
_kill_tier() {
    local tier_list="$1"
    local total_freed=0
    local IFS=','

    for target in $tier_list; do
        target=$(echo "$target" | xargs)  # trim whitespace
        [[ -z "$target" ]] && continue

        # Safety: never kill protected processes
        if _is_protected "$target"; then
            log_warn "Skipped protected process: $target"
            continue
        fi

        local freed
        freed=$(_kill_by_name "$target")
        total_freed=$(( total_freed + freed ))
    done

    echo "$total_freed"
}

# Main pressure check — called by sentinel-daemon.sh
check_pressure() {
    local swap_used_mb free_mb
    swap_used_mb=$(_get_swap_used_mb)
    free_mb=$(_get_free_memory_mb)

    # --- NORMAL ---
    if (( swap_used_mb < SWAP_WARNING_MB )) && (( free_mb > MEMORY_FREE_CRITICAL_MB )); then
        return 0
    fi

    # --- WARNING ---
    if (( swap_used_mb >= SWAP_WARNING_MB )) && (( swap_used_mb < SWAP_CRITICAL_MB )) && (( free_mb > MEMORY_FREE_CRITICAL_MB )); then
        if check_cooldown "pressure-warn" 600; then
            sentinel_notify "Sentinel" "Memory pressure elevated — swap at ${swap_used_mb} MB" "Submarine"
            set_cooldown "pressure-warn"
        fi
        log_warn "Memory warning: swap=${swap_used_mb}MB free=${free_mb}MB"
        return 1
    fi

    # --- CRITICAL ---
    log_error "Memory CRITICAL: swap=${swap_used_mb}MB free=${free_mb}MB"

    # Respect kill cooldown
    if ! check_cooldown "pressure-kill" "${PRESSURE_KILL_COOLDOWN:-300}"; then
        log_info "Pressure kill on cooldown — skipping"
        return 2
    fi

    local total_freed=0
    local tier_freed

    # Tier 1: expendable apps
    tier_freed=$(_kill_tier "$KILL_TIER_1")
    total_freed=$(( total_freed + tier_freed ))

    # Re-check: did Tier 1 fix it?
    free_mb=$(_get_free_memory_mb)
    swap_used_mb=$(_get_swap_used_mb)
    if (( swap_used_mb < SWAP_CRITICAL_MB )) && (( free_mb > MEMORY_FREE_CRITICAL_MB )); then
        sentinel_notify "Sentinel" "Freed ${total_freed} MB (Tier 1) — pressure resolved" "Glass"
        set_cooldown "pressure-kill"
        # Store result for Phase 2 pressure gate
        PHASE1_CRITICAL=true
        return 2
    fi

    # Tier 2: heavy optional
    tier_freed=$(_kill_tier "$KILL_TIER_2")
    total_freed=$(( total_freed + tier_freed ))

    free_mb=$(_get_free_memory_mb)
    swap_used_mb=$(_get_swap_used_mb)
    if (( swap_used_mb < SWAP_CRITICAL_MB )) && (( free_mb > MEMORY_FREE_CRITICAL_MB )); then
        sentinel_notify "Sentinel" "Freed ${total_freed} MB (Tier 1+2) — pressure resolved" "Glass"
        set_cooldown "pressure-kill"
        PHASE1_CRITICAL=true
        return 2
    fi

    # Tier 3: expendable trading bots (last resort)
    tier_freed=$(_kill_tier "$KILL_TIER_3")
    total_freed=$(( total_freed + tier_freed ))

    sentinel_notify "Sentinel" "CRITICAL: Freed ${total_freed} MB (all tiers) — system under heavy load" "Basso"
    set_cooldown "pressure-kill"
    PHASE1_CRITICAL=true
    return 2
}
```

**Step 4: Run test — expect pass**

Run: `bash tests/test-check-pressure.sh`
Expected: All PASS

**Step 5: Commit**

```bash
git add scripts/lib/check-pressure.sh tests/test-check-pressure.sh
git commit -m "feat: add pressure check module with tiered auto-kill"
```

---

## Task 4: Service Check Module (lib/check-services.sh)

**Files:**
- Create: `scripts/lib/check-services.sh`
- Create: `tests/test-check-services.sh`

**Step 1: Write failing tests**

Create `tests/test-check-services.sh`:

```bash
#!/usr/bin/env bash
# Test: check-services.sh detects crashed services and restarts them
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-services.sh ==="

source "$SCRIPT_DIR/../scripts/sentinel-utils.sh"
source "$SCRIPT_DIR/../config/sentinel.conf"

export SENTINEL_STATE="/tmp/sentinel-test-state-$$"
export SENTINEL_LOGS="/tmp/sentinel-test-logs-$$"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS"

RESTARTED_SERVICES=()
NOTIFICATIONS=()

# Mock launchctl
MOCK_LAUNCHCTL_OUTPUT=""
launchctl() {
    if [[ "$1" == "list" ]]; then
        echo "$MOCK_LAUNCHCTL_OUTPUT"
    elif [[ "$1" == "kickstart" ]]; then
        RESTARTED_SERVICES+=("$3")
    fi
}

sentinel_notify() {
    NOTIFICATIONS+=("$1: $2")
}

# Override MONITORED_SERVICES for testing
MONITORED_SERVICES="com.test.service1,com.test.service2"
AUTO_RESTART=true
MAX_RESTARTS_PER_HOUR=3
PHASE1_CRITICAL=false

source "$SCRIPT_DIR/../scripts/lib/check-services.sh"

# --- Test 1: All services running ---
echo "  -- Test: all services running --"
MOCK_LAUNCHCTL_OUTPUT="1234	0	com.test.service1
5678	0	com.test.service2"
RESTARTED_SERVICES=()
NOTIFICATIONS=()

check_services

assert_eq "0" "${#RESTARTED_SERVICES[@]}" "no restarts when all running"

# --- Test 2: One service crashed ---
echo "  -- Test: one service crashed --"
MOCK_LAUNCHCTL_OUTPUT="1234	0	com.test.service1
-	1	com.test.service2"
RESTARTED_SERVICES=()
NOTIFICATIONS=()

# Clear restart counter
rm -f "$SENTINEL_STATE/restart-com.test.service2"

check_services

assert_eq "1" "${#RESTARTED_SERVICES[@]}" "one service restarted"

# --- Test 3: Pressure gate blocks restarts ---
echo "  -- Test: pressure gate blocks restarts --"
PHASE1_CRITICAL=true
RESTARTED_SERVICES=()

check_services

assert_eq "0" "${#RESTARTED_SERVICES[@]}" "no restarts during pressure gate"
PHASE1_CRITICAL=false

# Cleanup
rm -rf "$SENTINEL_STATE" "$SENTINEL_LOGS"

test_summary
```

**Step 2: Run test — expect failure**

Run: `bash tests/test-check-services.sh`
Expected: FAIL — module doesn't exist

**Step 3: Implement check-services.sh**

Create `scripts/lib/check-services.sh`:

```bash
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# check-services.sh — LaunchAgent health + auto-restart
# ═══════════════════════════════════════════════════════════════
# Sourced by sentinel-daemon.sh. Do not execute directly.
#
# Returns: 0 = all healthy, 1 = restarts performed, 2 = crash loop detected
# ═══════════════════════════════════════════════════════════════

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

    # Count lines with timestamps within the last hour
    local now one_hour_ago count
    now=$(date +%s)
    one_hour_ago=$(( now - 3600 ))
    count=0

    while IFS= read -r ts; do
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
                    sentinel_notify "Sentinel" "$service is crash-looping ($restart_count restarts/hr) — needs manual intervention" "Basso"
                    has_crash_loop=true
                    continue
                fi

                # Auto-restart if enabled
                if [[ "$AUTO_RESTART" == "true" ]]; then
                    _restart_service "$service"
                    sentinel_notify "Sentinel" "Restarted $service (was exit $exit_code)" "Glass"
                    has_restarts=true
                else
                    log_warn "$service crashed (exit $exit_code) — auto-restart disabled"
                    sentinel_notify "Sentinel" "$service crashed (exit $exit_code)" "Submarine"
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
```

**Step 4: Run test — expect pass**

Run: `bash tests/test-check-services.sh`
Expected: All PASS

**Step 5: Commit**

```bash
git add scripts/lib/check-services.sh tests/test-check-services.sh
git commit -m "feat: add service check module with auto-restart and crash loop detection"
```

---

## Task 5: Backup Check Module (lib/check-backups.sh)

**Files:**
- Create: `scripts/lib/check-backups.sh`
- Create: `tests/test-check-backups.sh`

**Step 1: Write failing tests**

Create `tests/test-check-backups.sh`:

```bash
#!/usr/bin/env bash
# Test: check-backups.sh detects stale backup channels
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-backups.sh ==="

source "$SCRIPT_DIR/../scripts/sentinel-utils.sh"
source "$SCRIPT_DIR/../config/sentinel.conf"

export SENTINEL_STATE="/tmp/sentinel-test-state-$$"
export SENTINEL_LOGS="/tmp/sentinel-test-logs-$$"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS"

NOTIFICATIONS=()
sentinel_notify() { NOTIFICATIONS+=("$1: $2"); }

# Mock for testing with a temp git repo
MOCK_REPO="/tmp/sentinel-test-repo-$$"
mkdir -p "$MOCK_REPO"
git -C "$MOCK_REPO" init -q 2>/dev/null
git -C "$MOCK_REPO" commit --allow-empty -m "test" -q 2>/dev/null

# Override repos list to use our mock
GITHUB_REPOS="$MOCK_REPO"
OPS_SYNC_STALE_MINUTES=30
GITHUB_STALE_HOURS=24

source "$SCRIPT_DIR/../scripts/lib/check-backups.sh"

# --- Test 1: Fresh repo (committed just now) ---
echo "  -- Test: fresh repo --"
NOTIFICATIONS=()
clear_cooldown "backup-github"

check_backups

assert_eq "0" "${#NOTIFICATIONS[@]}" "no alerts for fresh repo"

# --- Test 2: Check returns info about channels ---
echo "  -- Test: backup check completes --"
# Just verify the function runs without error
check_backups
assert_eq "0" "$?" "check_backups returns 0 for fresh state"

# Cleanup
rm -rf "$MOCK_REPO" "$SENTINEL_STATE" "$SENTINEL_LOGS"

test_summary
```

**Step 2: Run test — expect failure**

Run: `bash tests/test-check-backups.sh`
Expected: FAIL — module doesn't exist

**Step 3: Implement check-backups.sh**

Create `scripts/lib/check-backups.sh`:

```bash
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# check-backups.sh — Backup channel verification
# ═══════════════════════════════════════════════════════════════
# Sourced by sentinel-daemon.sh. Do not execute directly.
#
# Checks: OPS sync agent, GitHub push freshness, OPS-mini mount
# Returns: 0 = all fresh, 1 = warnings issued
# ═══════════════════════════════════════════════════════════════

# Check if OPS sync LaunchAgent has run recently
_check_ops_sync() {
    local sync_log="$SENTINEL_LOGS/ops-sync-last-run"
    local stale_seconds=$(( OPS_SYNC_STALE_MINUTES * 60 ))

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

    # Check if sync has a recent commit (use OPS repo)
    if [[ -d "/Users/curl/OPS/.git" ]]; then
        local last_commit_ts
        last_commit_ts=$(git -C "/Users/curl/OPS" log --format=%ct -1 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        local age_seconds=$(( now - last_commit_ts ))

        if (( age_seconds > stale_seconds )); then
            local age_min=$(( age_seconds / 60 ))
            log_warn "OPS sync stale: last commit ${age_min}m ago (threshold: ${OPS_SYNC_STALE_MINUTES}m)"
            if check_cooldown "backup-sync" 1800; then
                sentinel_notify "Sentinel" "OPS sync hasn't committed in ${age_min} minutes" "Submarine"
                set_cooldown "backup-sync"
            fi
            return 1
        fi
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
    if ! mount | grep -q "OPS-mini" 2>/dev/null; then
        log_warn "OPS-mini not mounted"
        if check_cooldown "backup-opsmini" 3600; then
            sentinel_notify "Sentinel" "OPS-mini disconnected — backups paused" "Submarine"
            set_cooldown "backup-opsmini"
        fi
        return 1
    fi

    # Check freshness: stat a known directory
    if [[ -d "/Volumes/OPS-mini/OPS" ]]; then
        local stale_seconds=$(( OPS_MINI_STALE_HOURS * 3600 ))
        local now
        now=$(date +%s)
        local last_mod
        last_mod=$(stat -f %m "/Volumes/OPS-mini/OPS" 2>/dev/null || echo "0")
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
```

**Step 4: Run test — expect pass**

Run: `bash tests/test-check-backups.sh`
Expected: All PASS

**Step 5: Commit**

```bash
git add scripts/lib/check-backups.sh tests/test-check-backups.sh
git commit -m "feat: add backup verification module (OPS sync, GitHub, OPS-mini)"
```

---

## Task 6: Disk Check Module (lib/check-disk.sh)

**Files:**
- Create: `scripts/lib/check-disk.sh`
- Create: `tests/test-check-disk.sh`

**Step 1: Write failing tests**

Create `tests/test-check-disk.sh`:

```bash
#!/usr/bin/env bash
# Test: check-disk.sh detects low disk space
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-disk.sh ==="

source "$SCRIPT_DIR/../scripts/sentinel-utils.sh"
source "$SCRIPT_DIR/../config/sentinel.conf"

export SENTINEL_STATE="/tmp/sentinel-test-state-$$"
export SENTINEL_LOGS="/tmp/sentinel-test-logs-$$"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS"

NOTIFICATIONS=()
sentinel_notify() { NOTIFICATIONS+=("$1: $2"); }

MOCK_FREE_GB=63
df() {
    echo "Filesystem        Size    Used   Avail Capacity iused ifree %iused  Mounted on"
    echo "/dev/disk3s1s1   228Gi    15Gi    ${MOCK_FREE_GB}Gi    20%    453k  657M    0%   /"
}

source "$SCRIPT_DIR/../scripts/lib/check-disk.sh"

# --- Test 1: Plenty of space ---
echo "  -- Test: plenty of space --"
MOCK_FREE_GB=63
NOTIFICATIONS=()
clear_cooldown "disk-warn"
clear_cooldown "disk-critical"

check_disk
assert_eq "0" "$?" "normal disk returns 0"
assert_eq "0" "${#NOTIFICATIONS[@]}" "no alerts when plenty of space"

# --- Test 2: Warning level ---
echo "  -- Test: warning level --"
MOCK_FREE_GB=8
NOTIFICATIONS=()
clear_cooldown "disk-warn"

check_disk
assert_eq "1" "$?" "warning disk returns 1"

# --- Test 3: Critical level ---
echo "  -- Test: critical level --"
MOCK_FREE_GB=3
NOTIFICATIONS=()
clear_cooldown "disk-critical"

check_disk
assert_eq "2" "$?" "critical disk returns 2"

# Cleanup
rm -rf "$SENTINEL_STATE" "$SENTINEL_LOGS"

test_summary
```

**Step 2: Run test — expect failure**

**Step 3: Implement check-disk.sh**

Create `scripts/lib/check-disk.sh`:

```bash
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# check-disk.sh — Disk free space monitoring
# ═══════════════════════════════════════════════════════════════
# Sourced by sentinel-daemon.sh. Do not execute directly.
#
# Returns: 0 = normal, 1 = warning, 2 = critical
# ═══════════════════════════════════════════════════════════════

# Get free disk space in GB for root volume
_get_free_gb() {
    df -g / 2>/dev/null | awk 'NR==2 {print $4}'
}

# Main disk check — called by sentinel-daemon.sh
check_disk() {
    local free_gb
    free_gb=$(_get_free_gb)

    # Fallback: parse from human-readable if -g not supported
    if [[ -z "$free_gb" ]] || [[ "$free_gb" == "0" ]]; then
        free_gb=$(df -h / 2>/dev/null | awk 'NR==2 {gsub(/Gi/,"",$4); print int($4)}')
    fi

    if (( free_gb < DISK_CRITICAL_GB )); then
        log_error "Disk CRITICAL: ${free_gb} GB free (threshold: ${DISK_CRITICAL_GB} GB)"
        if check_cooldown "disk-critical" 1800; then
            sentinel_notify "Sentinel" "NODE SSD critically low: ${free_gb} GB free" "Basso"
            set_cooldown "disk-critical"
        fi
        return 2
    fi

    if (( free_gb < DISK_WARNING_GB )); then
        log_warn "Disk warning: ${free_gb} GB free (threshold: ${DISK_WARNING_GB} GB)"
        if check_cooldown "disk-warn" 3600; then
            sentinel_notify "Sentinel" "NODE SSD getting low: ${free_gb} GB free" "Submarine"
            set_cooldown "disk-warn"
        fi
        return 1
    fi

    return 0
}
```

**Step 4: Run test — expect pass**

Run: `bash tests/test-check-disk.sh`
Expected: All PASS

**Step 5: Commit**

```bash
git add scripts/lib/check-disk.sh tests/test-check-disk.sh
git commit -m "feat: add disk space monitoring module"
```

---

## Task 7: File Janitor Module (lib/check-files.sh)

**Files:**
- Create: `scripts/lib/check-files.sh`
- Create: `tests/test-check-files.sh`

**Step 1: Write failing tests**

Create `tests/test-check-files.sh`:

```bash
#!/usr/bin/env bash
# Test: check-files.sh sorts files to destination
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-files.sh ==="

source "$SCRIPT_DIR/../scripts/sentinel-utils.sh"
source "$SCRIPT_DIR/../config/sentinel.conf"

export SENTINEL_STATE="/tmp/sentinel-test-state-$$"
export SENTINEL_LOGS="/tmp/sentinel-test-logs-$$"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS"

# Setup mock directories
MOCK_WATCH="/tmp/sentinel-test-watch-$$"
MOCK_DEST="/tmp/sentinel-test-dest-$$"
MOCK_QUEUE="/tmp/sentinel-test-queue-$$"
mkdir -p "$MOCK_WATCH" "$MOCK_DEST" "$MOCK_QUEUE"

JANITOR_ENABLED=true
JANITOR_WATCH_DIRS="$MOCK_WATCH"
JANITOR_DESTINATION="$MOCK_DEST"
JANITOR_FALLBACK_QUEUE="$MOCK_QUEUE"
JANITOR_DATE_PREFIX=true
JANITOR_IGNORE="*.crdownload,*.part,*.tmp"
JANITOR_DESKTOP_MAX_AGE_DAYS=7
JANITOR_DOWNLOADS_MAX_AGE_DAYS=3

# Mock lsof (nothing open)
lsof() { return 1; }

# Mock date for prefix
TODAY="2026-02-24"

NOTIFICATIONS=()
sentinel_notify() { NOTIFICATIONS+=("$1: $2"); }

source "$SCRIPT_DIR/../scripts/lib/check-files.sh"

# --- Test 1: Sort PDF to docs/ ---
echo "  -- Test: sort PDF to docs --"
touch "$MOCK_WATCH/report.pdf"
# Set modified time to now
touch -t "$(date +%Y%m%d%H%M)" "$MOCK_WATCH/report.pdf"

_sort_file "$MOCK_WATCH/report.pdf"

assert_file_exists "$MOCK_DEST/docs/${TODAY}_report.pdf" "PDF sorted to docs/"

# --- Test 2: Sort PNG to images/ ---
echo "  -- Test: sort PNG to images --"
touch "$MOCK_WATCH/screenshot.png"
touch -t "$(date +%Y%m%d%H%M)" "$MOCK_WATCH/screenshot.png"

_sort_file "$MOCK_WATCH/screenshot.png"

assert_file_exists "$MOCK_DEST/images/${TODAY}_screenshot.png" "PNG sorted to images/"

# --- Test 3: Skip in-progress download ---
echo "  -- Test: skip crdownload --"
touch "$MOCK_WATCH/bigfile.crdownload"

local should_skip
should_skip=$(_should_skip "$MOCK_WATCH/bigfile.crdownload" && echo "yes" || echo "no")
assert_eq "yes" "$should_skip" ".crdownload skipped"

# --- Test 4: Disabled janitor does nothing ---
echo "  -- Test: disabled janitor --"
JANITOR_ENABLED=false
touch "$MOCK_WATCH/should-stay.txt"

check_files
assert_file_exists "$MOCK_WATCH/should-stay.txt" "file stays when janitor disabled"
JANITOR_ENABLED=true

# Cleanup
rm -rf "$MOCK_WATCH" "$MOCK_DEST" "$MOCK_QUEUE" "$SENTINEL_STATE" "$SENTINEL_LOGS"

test_summary
```

**Step 2: Run test — expect failure**

**Step 3: Implement check-files.sh**

Create `scripts/lib/check-files.sh`:

```bash
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# check-files.sh — File Janitor (auto-sort to OPS-mini)
# ═══════════════════════════════════════════════════════════════
# Sourced by sentinel-daemon.sh. Do not execute directly.
#
# Scans watch dirs, sorts files by extension to OPS-mini.
# Falls back to local queue when OPS-mini disconnected.
# ═══════════════════════════════════════════════════════════════

# Map file extension to category
_get_category() {
    local ext="${1##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    case "$ext" in
        pdf|doc|docx|txt|md|rtf|pages)  echo "docs" ;;
        png|jpg|jpeg|gif|webp|heic|svg|ico|tiff) echo "images" ;;
        mp4|mov|mkv|avi|webm)           echo "video" ;;
        mp3|wav|flac|m4a|aac|ogg)       echo "audio" ;;
        zip|tar|gz|rar|7z|bz2)          echo "archives" ;;
        dmg|pkg)                         echo "installers" ;;
        csv|xlsx|json|xml|yaml|yml|sql)  echo "data" ;;
        py|js|ts|sh|rb|go|rs|swift)     echo "code" ;;
        *)                               echo "other" ;;
    esac
}

# Check if a file should be skipped
_should_skip() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    # Skip ignore patterns
    local IFS=','
    for pattern in $JANITOR_IGNORE; do
        pattern=$(echo "$pattern" | xargs)
        # Simple glob match
        case "$filename" in
            $pattern) return 0 ;;  # skip
        esac
    done

    # Skip files open by another process
    if lsof "$filepath" >/dev/null 2>&1; then
        return 0  # skip — file is open
    fi

    # Skip directories
    if [[ -d "$filepath" ]]; then
        return 0
    fi

    # Skip hidden files
    if [[ "$filename" == .* ]]; then
        return 0
    fi

    return 1  # don't skip
}

# Generate destination path with date prefix and collision handling
_dest_path() {
    local dest_dir="$1"
    local filename="$2"
    local base="${filename%.*}"
    local ext="${filename##*.}"

    # Date prefix
    local prefix=""
    if [[ "$JANITOR_DATE_PREFIX" == "true" ]]; then
        prefix="$(date +%Y-%m-%d)_"
    fi

    local target="${dest_dir}/${prefix}${filename}"

    # Handle collisions
    if [[ -f "$target" ]]; then
        local counter=1
        while [[ -f "${dest_dir}/${prefix}${base}-${counter}.${ext}" ]]; do
            counter=$((counter + 1))
        done
        target="${dest_dir}/${prefix}${base}-${counter}.${ext}"
    fi

    echo "$target"
}

# Sort a single file to the appropriate category
_sort_file() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    # Determine destination base
    local dest_base
    if [[ -d "$JANITOR_DESTINATION" ]] || mount | grep -q "OPS-mini" 2>/dev/null; then
        dest_base="$JANITOR_DESTINATION"
    else
        dest_base="$JANITOR_FALLBACK_QUEUE"
    fi

    local category
    category=$(_get_category "$filename")
    local dest_dir="${dest_base}/${category}"
    mkdir -p "$dest_dir"

    local target
    target=$(_dest_path "$dest_dir" "$filename")

    mv "$filepath" "$target" 2>/dev/null || {
        log_error "Failed to move $filename → $dest_dir/"
        return 1
    }

    log_info "Sorted: $filename → ${category}/"
    return 0
}

# Flush fallback queue to OPS-mini when it reconnects
_flush_queue() {
    if [[ ! -d "$JANITOR_FALLBACK_QUEUE" ]]; then
        return 0
    fi

    local queue_count
    queue_count=$(find "$JANITOR_FALLBACK_QUEUE" -type f 2>/dev/null | wc -l | xargs)

    if (( queue_count == 0 )); then
        return 0
    fi

    if [[ ! -d "$JANITOR_DESTINATION" ]]; then
        return 0  # OPS-mini still not available
    fi

    log_info "Flushing $queue_count queued files to OPS-mini"

    find "$JANITOR_FALLBACK_QUEUE" -type f 2>/dev/null | while IFS= read -r filepath; do
        _sort_file "$filepath"
    done

    # Clean up empty category dirs in queue
    find "$JANITOR_FALLBACK_QUEUE" -type d -empty -delete 2>/dev/null || true

    sentinel_notify "Sentinel" "Flushed $queue_count queued files to OPS-mini" "Glass"
}

# Main file janitor — called by sentinel-daemon.sh
check_files() {
    if [[ "$JANITOR_ENABLED" != "true" ]]; then
        return 0
    fi

    local sorted_count=0
    local IFS=','

    # Try to flush queue first (if OPS-mini just reconnected)
    _flush_queue

    for watch_dir in $JANITOR_WATCH_DIRS; do
        watch_dir=$(echo "$watch_dir" | xargs)
        [[ -z "$watch_dir" ]] && continue
        [[ ! -d "$watch_dir" ]] && continue

        # Find files (not dirs, not hidden)
        find "$watch_dir" -maxdepth 1 -type f -not -name '.*' 2>/dev/null | while IFS= read -r filepath; do
            if _should_skip "$filepath"; then
                continue
            fi

            _sort_file "$filepath" && sorted_count=$((sorted_count + 1))
        done
    done

    if (( sorted_count > 0 )); then
        log_info "File janitor: sorted $sorted_count file(s)"
    fi

    return 0
}
```

**Step 4: Run test — expect pass**

Run: `bash tests/test-check-files.sh`
Expected: All PASS

**Step 5: Commit**

```bash
git add scripts/lib/check-files.sh tests/test-check-files.sh
git commit -m "feat: add file janitor module (auto-sort to OPS-mini)"
```

---

## Task 8: Sentinel Daemon (sentinel-daemon.sh)

The orchestrator that runs all 5 phases.

**Files:**
- Create: `scripts/sentinel-daemon.sh`
- Create: `tests/test-daemon.sh`

**Step 1: Write test**

Create `tests/test-daemon.sh`:

```bash
#!/usr/bin/env bash
# Test: sentinel-daemon.sh runs one cycle without errors
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-daemon.sh ==="

# We test that the daemon can run a single cycle in test mode
export SENTINEL_TEST_MODE=true
export SENTINEL_STATE="/tmp/sentinel-test-state-$$"
export SENTINEL_LOGS="/tmp/sentinel-test-logs-$$"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS"

# Run one cycle
output=$(bash "$SCRIPT_DIR/../scripts/sentinel-daemon.sh" --once 2>&1)
exit_code=$?

assert_eq "0" "$exit_code" "daemon single cycle exits cleanly"
assert_contains "$output" "cycle" "daemon reports cycle info"
assert_file_exists "$SENTINEL_LOGS/sentinel.log" "daemon creates log file"

# Verify log has entries
log_content=$(cat "$SENTINEL_LOGS/sentinel.log")
assert_contains "$log_content" "Cycle" "log contains cycle entry"

# Cleanup
rm -rf "$SENTINEL_STATE" "$SENTINEL_LOGS"

test_summary
```

**Step 2: Run test — expect failure**

**Step 3: Implement sentinel-daemon.sh**

Create `scripts/sentinel-daemon.sh`:

```bash
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

# Source foundation
source "$SCRIPT_DIR/sentinel-utils.sh"

# Load config
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
```

**Step 4: Run test — expect pass**

Run: `bash tests/test-daemon.sh`
Expected: All PASS

**Step 5: Commit**

```bash
git add scripts/sentinel-daemon.sh tests/test-daemon.sh
git commit -m "feat: add sentinel daemon with 5-phase pipeline"
```

---

## Task 9: Live Interactive Dashboard (sentinel-status.sh)

The most complex script — a real-time TUI with keyboard controls.

**Files:**
- Create: `scripts/sentinel-status.sh`

**Step 1: Implement sentinel-status.sh**

Create `scripts/sentinel-status.sh` — this is a standalone executable (not sourced):

```bash
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
    local percent=$1 width=${2:-12}
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

_pad() {
    local str="$1" width="$2"
    printf "%-${width}s" "$str"
}

# ─── Data Collection ───

_get_memory_info() {
    local total_mb=8192  # 8 GB
    local page_size=16384
    local pages_free pages_active pages_wired
    pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
    pages_wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {gsub(/\./,"",$3); print $3}')

    local used_mb=$(( (pages_active + pages_wired) * page_size / 1024 / 1024 ))
    local free_mb=$(( pages_free * page_size / 1024 / 1024 ))
    local percent=$(( used_mb * 100 / total_mb ))

    echo "$used_mb $total_mb $percent $free_mb"
}

_get_swap_info() {
    local swap_line
    swap_line=$(sysctl vm.swapusage 2>/dev/null)
    local used total
    used=$(echo "$swap_line" | sed -n 's/.*used = \([0-9]*\)\..*/\1/p')
    total=$(echo "$swap_line" | sed -n 's/.*total = \([0-9]*\)\..*/\1/p')
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
    cores=$(sysctl -n hw.ncpu 2>/dev/null)
    local percent=$(echo "$load $cores" | awk '{printf "%d", ($1/$2)*100}')
    echo "$load $cores $percent"
}

_get_service_status_line() {
    local service="$1"
    local short_name="${service##*.}"  # com.aether.periapsis → periapsis
    local line
    line=$(launchctl list 2>/dev/null | grep "$service" || true)

    if [[ -z "$line" ]]; then
        printf "  ${RED}✗${NC} %-14s  %-6s  %-12s\n" "$short_name" "----" "NOT FOUND"
        return
    fi

    local pid exit_code
    pid=$(echo "$line" | awk '{print $1}')
    exit_code=$(echo "$line" | awk '{print $2}')

    if [[ "$pid" == "-" ]] || [[ "$exit_code" != "0" ]]; then
        printf "  ${RED}✗${NC} %-14s  %-6s  ${RED}CRASHED (exit $exit_code)${NC}\n" "$short_name" "----"
    else
        printf "  ${GREEN}●${NC} %-14s  %-6s  ${GREEN}running${NC}\n" "$short_name" "$pid"
    fi
}

_get_recent_activity() {
    local logfile="$SENTINEL_LOGS/sentinel.log"
    if [[ -f "$logfile" ]]; then
        tail -20 "$logfile" | grep -E 'WARN|ERROR|Kill|Restart|Sort|freed' | tail -4
    fi
}

# ─── Render Frame ───

_render() {
    local mem_info swap_info disk_info load_info
    read -r mem_used mem_total mem_pct mem_free <<< "$(_get_memory_info)"
    read -r swap_used swap_total swap_pct <<< "$(_get_swap_info)"
    read -r disk_used disk_total disk_pct disk_avail <<< "$(_get_disk_info)"
    read -r load_avg load_cores load_pct <<< "$(_get_load)"

    local now
    now=$(date '+%H:%M:%S')

    local cycle_num="?"
    if [[ -f "$SENTINEL_STATE/cycle-counter" ]]; then
        cycle_num=$(cat "$SENTINEL_STATE/cycle-counter")
    fi

    # Move cursor to top-left (no clear — prevents flicker)
    tput cup 0 0

    echo -e "┌─ ${BOLD}OPS SENTINEL${NC} ──────────────────── ${CYAN}$SENTINEL_MACHINE${NC} ─── $now ─┐"
    echo -e "│                                                              │"

    # Memory bar
    local mem_status=""
    if (( mem_pct >= 80 )); then mem_status="${RED}⚠${NC}"; elif (( mem_pct >= 60 )); then mem_status="${YELLOW}~${NC}"; else mem_status=" "; fi
    printf "│  MEMORY  $(_bar $mem_pct)  %4d / %4d MB     %3d%%  $mem_status │\n" "$mem_used" "$mem_total" "$mem_pct"

    # Swap bar
    local swap_status=""
    if (( swap_pct >= 80 )); then swap_status="${RED}✗${NC}"; elif (( swap_pct >= 50 )); then swap_status="${YELLOW}⚠${NC}"; else swap_status=" "; fi
    printf "│  SWAP    $(_bar $swap_pct)  %4d / %4d MB     %3d%%  $swap_status │\n" "$swap_used" "$swap_total" "$swap_pct"

    # CPU/Load bar
    printf "│  LOAD    $(_bar $load_pct)  %4s / %d cores      %3d%%    │\n" "$load_avg" "$load_cores" "$load_pct"

    # Disk bar
    printf "│  DISK    $(_bar $disk_pct)  %4d / %4d GB      %3d%%    │\n" "$disk_used" "$disk_total" "$disk_pct"

    echo -e "│                                                              │"
    echo -e "│  ${BOLD}SERVICES${NC} ───────────────────────────────────────────────── │"

    local IFS=','
    for svc in $MONITORED_SERVICES; do
        svc=$(echo "$svc" | xargs)
        printf "│"
        _get_service_status_line "$svc"
        # Pad to fill width
    done

    echo -e "│                                                              │"
    echo -e "│  ${BOLD}BACKUPS${NC} ────────────────────────────────────────────────── │"

    # OPS-mini
    if mount | grep -q "OPS-mini" 2>/dev/null; then
        printf "│  OPS-mini  ${GREEN}✓${NC} mounted"
    else
        printf "│  OPS-mini  ${RED}✗${NC} disconnected"
    fi
    echo ""

    echo -e "│                                                              │"
    echo -e "│  ${BOLD}ACTIVITY${NC} ───────────────────────────────────────────────── │"

    _get_recent_activity | while IFS= read -r line; do
        local short="${line:22:54}"  # trim timestamp prefix, cap width
        echo -e "│  $short"
    done

    echo -e "│                                                              │"
    echo -e "├─ [q] quit  [r] restart crashed  [t] triage  [k] kill ───── │"
    printf  "└──────────────────────────────────── cycle: #%-6s ────────┘\n" "$cycle_num"
}

# ─── Keyboard Handler ───

_handle_key() {
    local key="$1"
    case "$key" in
        q|Q)
            tput cnorm  # restore cursor
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
                local pid
                pid=$(echo "$line" | awk '{print $1}')
                local exit_code
                exit_code=$(echo "$line" | awk '{print $2}')
                if [[ "$pid" == "-" ]] || [[ "${exit_code:-0}" != "0" ]]; then
                    launchctl kickstart -k "gui/${uid}/${svc}" 2>/dev/null || true
                    echo "  Restarted: ${svc##*.}"
                fi
            done
            sleep 1
            ;;
        t|T)
            bash "$SCRIPT_DIR/sentinel-triage.sh"
            ;;
        k|K)
            echo -e "\n${YELLOW}Kill which process? (enter PID or name):${NC} "
            tput cnorm
            read -r target
            tput civis
            if [[ "$target" =~ ^[0-9]+$ ]]; then
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
```

**Step 2: Manual test**

Run: `bash scripts/sentinel-status.sh`
Expected: Live dashboard appears. Press `q` to quit. Verify memory/swap/disk bars update. Verify services list shows current state.

**Step 3: Commit**

```bash
git add scripts/sentinel-status.sh
git commit -m "feat: add live interactive dashboard with keyboard controls"
```

---

## Task 10: Emergency Triage Tool (sentinel-triage.sh)

**Files:**
- Create: `scripts/sentinel-triage.sh`

**Step 1: Implement sentinel-triage.sh**

Create `scripts/sentinel-triage.sh`:

```bash
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
IFS=',' read -ra tier1 <<< "$KILL_TIER_1"
for target in "${tier1[@]}"; do
    target=$(echo "$target" | xargs)
    local rss
    rss=$(ps -eo rss,comm 2>/dev/null | grep -i "$target" | awk '{sum+=$1} END {print int(sum/1024)}')
    if (( rss > 0 )); then
        echo -e "  ${RED}✗${NC} $target (~${rss} MB)"
        estimate_total=$((estimate_total + rss))
    fi
done

# Tier 2
IFS=',' read -ra tier2 <<< "$KILL_TIER_2"
for target in "${tier2[@]}"; do
    target=$(echo "$target" | xargs)
    local rss
    rss=$(ps -eo rss,comm 2>/dev/null | grep -i "$target" | awk '{sum+=$1} END {print int(sum/1024)}')
    if (( rss > 0 )); then
        echo -e "  ${RED}✗${NC} $target (~${rss} MB)"
        estimate_total=$((estimate_total + rss))
    fi
done

# Expendable bots from Tier 3
IFS=',' read -ra tier3 <<< "$KILL_TIER_3"
for target in "${tier3[@]}"; do
    target=$(echo "$target" | xargs)
    echo -e "  ${YELLOW}◼${NC} Stop: ${target##*.}"
done

echo ""
echo -e "${BOLD}Will keep:${NC}"
echo -e "  ${GREEN}●${NC} claude, Ghostty, Finder, tmux, PERIAPSIS"
echo ""
echo -e "Estimated freed: ${BOLD}~${estimate_total} MB${NC}"
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
for target in "${tier1[@]}" "${tier2[@]}"; do
    target=$(echo "$target" | xargs)
    [[ -z "$target" ]] && continue
    local rss
    rss=$(ps -eo rss,comm 2>/dev/null | grep -i "$target" | awk '{sum+=$1} END {print int(sum/1024)}')
    pkill -f "$target" 2>/dev/null || true
    freed=$((freed + rss))
    echo -e "  ${RED}✗${NC} Killed: $target (~${rss} MB)"
done

# Stop Tier 3 bots
uid=$(id -u)
for svc in "${tier3[@]}"; do
    svc=$(echo "$svc" | xargs)
    [[ -z "$svc" ]] && continue
    launchctl bootout "gui/${uid}/${svc}" 2>/dev/null || true
    echo -e "  ${YELLOW}◼${NC} Stopped: ${svc##*.}"
done

echo ""
echo -e "${GREEN}${BOLD}Triage complete.${NC} Freed ~${freed} MB."
echo "Stopped bots can be restarted with: launchctl kickstart gui/${uid}/SERVICE"

log_info "TRIAGE: freed ~${freed} MB, stopped ${#tier3[@]} bots"
sentinel_notify "Sentinel" "Triage complete — freed ~${freed} MB" "Glass"
```

**Step 2: Manual test**

Run: `bash scripts/sentinel-triage.sh`
Expected: Shows what will be killed with estimates. Asks for confirmation. Press `n` to cancel safely.

**Step 3: Commit**

```bash
git add scripts/sentinel-triage.sh
git commit -m "feat: add emergency triage tool with confirmation prompt"
```

---

## Task 11: LaunchAgent + Installer

**Files:**
- Create: `launchagents/com.ops.sentinel.plist`
- Create: `install.sh`

**Step 1: Create LaunchAgent plist**

Create `launchagents/com.ops.sentinel.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ops.sentinel</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>$HOME/.local/share/ops-sentinel/sentinel-daemon.sh</string>
    </array>

    <key>StartInterval</key>
    <integer>60</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/sentinel-daemon-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/sentinel-daemon-stderr.log</string>

    <key>KeepAlive</key>
    <false/>

    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
```

**Note:** The `StartInterval` approach runs the daemon as a one-shot every 60s (not a persistent process). This is lighter than `KeepAlive` — launchd handles scheduling. The daemon script needs to be adjusted to run `--once` mode when launched this way (since launchd calls it fresh each time). Update `sentinel-daemon.sh` ProgramArguments to use `--once` flag, OR keep it as a long-running daemon with KeepAlive. **Decision:** Use `KeepAlive` + internal sleep loop (the daemon manages its own timing). Update the plist:

```xml
    <key>KeepAlive</key>
    <true/>

    <!-- Remove StartInterval — daemon handles its own loop -->
```

**Step 2: Create installer**

Create `install.sh`:

```bash
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# OPS Sentinel Suite — Installer
# ═══════════════════════════════════════════════════════════════
# Usage:
#   ./install.sh              Install the suite
#   ./install.sh --uninstall  Remove the suite (preserves logs)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/share/ops-sentinel"
CONFIG_DIR="$HOME/.sentinel-config"
STATE_DIR="$HOME/.sentinel-state"
LOG_DIR="$HOME/.sentinel-logs"
PLIST_NAME="com.ops.sentinel.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Uninstall ───
if [[ "${1:-}" == "--uninstall" ]]; then
    echo -e "${BOLD}Uninstalling OPS Sentinel Suite...${NC}"

    # Stop daemon
    if launchctl list | grep -q "com.ops.sentinel" 2>/dev/null; then
        launchctl unload "$PLIST_DEST" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} Daemon stopped"
    fi

    # Remove LaunchAgent
    rm -f "$PLIST_DEST"
    echo -e "  ${GREEN}✓${NC} LaunchAgent removed"

    # Remove scripts (preserve config and logs)
    rm -rf "$INSTALL_DIR"
    echo -e "  ${GREEN}✓${NC} Scripts removed from $INSTALL_DIR"

    echo ""
    echo -e "${YELLOW}Preserved:${NC} $CONFIG_DIR (config), $LOG_DIR (logs), $STATE_DIR (state)"
    echo "Remove manually if desired."
    exit 0
fi

# ─── Install ───
echo -e "${BOLD}Installing OPS Sentinel Suite...${NC}"
echo ""

# 1. Create directories
echo -e "  Creating directories..."
mkdir -p "$INSTALL_DIR/lib" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
echo -e "  ${GREEN}✓${NC} $INSTALL_DIR"
echo -e "  ${GREEN}✓${NC} $CONFIG_DIR"
echo -e "  ${GREEN}✓${NC} $STATE_DIR"
echo -e "  ${GREEN}✓${NC} $LOG_DIR"

# 2. Copy scripts
echo -e "  Copying scripts..."
cp "$SCRIPT_DIR/scripts/sentinel-utils.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/sentinel-daemon.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/sentinel-status.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/sentinel-triage.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/lib/"*.sh "$INSTALL_DIR/lib/"
chmod +x "$INSTALL_DIR/sentinel-daemon.sh"
chmod +x "$INSTALL_DIR/sentinel-status.sh"
chmod +x "$INSTALL_DIR/sentinel-triage.sh"
echo -e "  ${GREEN}✓${NC} Scripts installed"

# 3. Copy config (don't overwrite existing)
if [[ ! -f "$CONFIG_DIR/sentinel.conf" ]]; then
    cp "$SCRIPT_DIR/config/sentinel.conf" "$CONFIG_DIR/"
    echo -e "  ${GREEN}✓${NC} Default config installed"
else
    echo -e "  ${YELLOW}~${NC} Config exists — preserved (update manually if needed)"
fi

# 4. Install LaunchAgent
echo -e "  Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"

# Generate plist with correct home directory
cat > "$PLIST_DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ops.sentinel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALL_DIR}/sentinel-daemon.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/sentinel-daemon-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/sentinel-daemon-stderr.log</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
PLIST

echo -e "  ${GREEN}✓${NC} LaunchAgent installed"

# 5. Add shell aliases
ZSHRC="$HOME/.zshrc"
if [[ -f "$ZSHRC" ]]; then
    if ! grep -q "sentinel-status" "$ZSHRC" 2>/dev/null; then
        echo "" >> "$ZSHRC"
        echo "# OPS Sentinel Suite" >> "$ZSHRC"
        echo "alias sentinel-status='${INSTALL_DIR}/sentinel-status.sh'" >> "$ZSHRC"
        echo "alias sentinel-triage='${INSTALL_DIR}/sentinel-triage.sh'" >> "$ZSHRC"
        echo -e "  ${GREEN}✓${NC} Shell aliases added to .zshrc"
    else
        echo -e "  ${YELLOW}~${NC} Shell aliases already in .zshrc"
    fi
fi

# 6. Start daemon
echo -e "  Starting daemon..."
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"
echo -e "  ${GREEN}✓${NC} Daemon started"

echo ""
echo -e "${GREEN}${BOLD}OPS Sentinel Suite installed successfully!${NC}"
echo ""
echo "Commands:"
echo "  sentinel-status    — Live dashboard"
echo "  sentinel-triage    — Emergency mode"
echo ""
echo "Config: $CONFIG_DIR/sentinel.conf"
echo "Logs:   $LOG_DIR/sentinel.log"
echo ""

# 7. Quick health check
echo -e "${BOLD}Quick health check:${NC}"
sleep 1
bash "$INSTALL_DIR/sentinel-daemon.sh" --once 2>/dev/null && echo -e "  ${GREEN}✓${NC} First cycle completed" || echo -e "  ${RED}✗${NC} First cycle had errors — check /tmp/sentinel-daemon-stderr.log"
```

**Step 3: Commit**

```bash
git add launchagents/ install.sh
git commit -m "feat: add LaunchAgent plist and one-command installer"
```

---

## Task 12: Update README + CHANGELOG

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Step 1: Update README.md** to reflect the new architecture (single daemon, 5 phases, 3 commands).

**Step 2: Update CHANGELOG.md** with all new components under `[1.0.0]`.

**Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: update README and CHANGELOG for v1.0.0 redesign"
```

---

## Task 13: Run Full Test Suite + Manual Verification

**Step 1: Run all tests**

Run: `bash tests/run-all.sh`
Expected: All PASS

**Step 2: Run daemon single cycle**

Run: `bash scripts/sentinel-daemon.sh --once`
Expected: Completes without errors, log file created

**Step 3: Run dashboard**

Run: `bash scripts/sentinel-status.sh`
Expected: Live dashboard appears with real data. Press `q` to exit.

**Step 4: Dry-run triage**

Run: `bash scripts/sentinel-triage.sh`
Expected: Shows kill list. Press `n` to cancel.

**Step 5: Test installer (dry run — inspect output)**

Run: `bash -x install.sh 2>&1 | head -30`
Expected: Shows each step being executed

**Step 6: Final commit + push**

```bash
git push origin docs/sentinel-suite-redesign
```

Create PR: `gh pr create --title "feat: OPS Sentinel Suite v1.0.0 redesign" --body "..."`

---

## Build Sequence Summary

| Task | Component | Depends On | ~Time |
|------|-----------|------------|-------|
| 1 | Test framework + sentinel.conf | — | 5 min |
| 2 | Update sentinel-utils.sh | Task 1 | 5 min |
| 3 | check-pressure.sh | Task 2 | 10 min |
| 4 | check-services.sh | Task 2 | 10 min |
| 5 | check-backups.sh | Task 2 | 10 min |
| 6 | check-disk.sh | Task 2 | 5 min |
| 7 | check-files.sh | Task 2 | 10 min |
| 8 | sentinel-daemon.sh | Tasks 3-7 | 10 min |
| 9 | sentinel-status.sh | Task 2 | 15 min |
| 10 | sentinel-triage.sh | Task 2 | 5 min |
| 11 | LaunchAgent + installer | Tasks 8-10 | 10 min |
| 12 | README + CHANGELOG | Tasks 1-11 | 5 min |
| 13 | Full test + verification | Tasks 1-12 | 10 min |

**Tasks 3-7 are independent** — can be built in parallel by subagents.
**Tasks 9-10 are independent** — can be built in parallel.
