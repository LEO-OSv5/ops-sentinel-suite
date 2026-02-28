# Sentinel Web Dashboard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a web dashboard to the Sentinel Suite — network-accessible, full control panel, historical trends, predictions engine — served by a lightweight Python micro-server.

**Architecture:** The daemon writes `status.json` + `history.jsonl` + `actions.jsonl` each cycle. A Python stdlib HTTP server serves a single-file HTML dashboard and handles action POST requests (restart, kill, config, triage). Notifications open the dashboard URL on click.

**Tech Stack:** Bash (data writer), Python 3 stdlib `http.server` (server), vanilla HTML/CSS/JS + Chart.js CDN (dashboard)

**Design doc:** `docs/plans/2026-02-28-sentinel-web-dashboard-design.md`

**Existing test framework:** Bash-based (`tests/test-helpers.sh`), uses `assert_eq`, `assert_contains`, `assert_file_exists`, `test_summary`. All tests follow the pattern in `tests/test-check-*.sh`.

**Existing test count:** 180 tests across 8 test files. Run all: `bash tests/run-all.sh`

---

### Task 1: Config Additions

**Files:**
- Modify: `config/sentinel.conf`

**Context:** Add web dashboard configuration variables to the existing config file. These follow the same `${VAR:-default}` pattern used by all other config values.

**Step 1: Add config values**

Add to the end of `config/sentinel.conf`, before the closing comment:

```bash
# --- Web Dashboard ---
WEB_PORT="${WEB_PORT:-8888}"
WEB_TOKEN_FILE="${WEB_TOKEN_FILE:-$HOME/.sentinel-config/web.token}"
WEB_REFRESH_SECONDS="${WEB_REFRESH_SECONDS:-5}"
WEB_HISTORY_DAYS="${WEB_HISTORY_DAYS:-7}"
WEB_ACTIONS_DAYS="${WEB_ACTIONS_DAYS:-30}"
```

**Step 2: Add config test cases**

Add to the end of `tests/test-config.sh`, before `test_summary`:

```bash
# --- Web Dashboard config ---
echo "  -- Web Dashboard config --"
assert_eq "8888" "$WEB_PORT" "WEB_PORT default"
assert_eq "$HOME/.sentinel-config/web.token" "$WEB_TOKEN_FILE" "WEB_TOKEN_FILE default"
assert_eq "5" "$WEB_REFRESH_SECONDS" "WEB_REFRESH_SECONDS default"
assert_eq "7" "$WEB_HISTORY_DAYS" "WEB_HISTORY_DAYS default"
assert_eq "30" "$WEB_ACTIONS_DAYS" "WEB_ACTIONS_DAYS default"
```

**Step 3: Run tests**

Run: `bash tests/test-config.sh`
Expected: 25 tests, 0 failures (20 existing + 5 new)

**Step 4: Run full suite**

Run: `bash tests/run-all.sh`
Expected: All test files pass

**Step 5: Commit**

```bash
git add config/sentinel.conf tests/test-config.sh
git commit -m "feat(config): add web dashboard configuration variables"
```

---

### Task 2: Status JSON Writer (write-status.sh)

**Files:**
- Create: `scripts/lib/write-status.sh`
- Create: `tests/test-write-status.sh`

**Context:** This is the data layer — a sourced lib module that collects all system state and writes `status.json`. It reuses system commands like `vm_stat`, `sysctl`, `df`, `ps`, `launchctl`, and `netstat`. The daemon will call `write_status` after each cycle. All functions are prefixed with `_ws_` to avoid collisions with existing functions.

**Step 1: Write the test file**

Create `tests/test-write-status.sh`:

```bash
#!/usr/bin/env bash
# Test: write-status.sh — status.json generation
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-write-status.sh ==="

# Setup: isolated temp dirs
export SENTINEL_STATE="/tmp/sentinel-test-ws-state-$$"
export SENTINEL_LOGS="/tmp/sentinel-test-ws-logs-$$"
export SENTINEL_CONFIG="/tmp/sentinel-test-ws-config-$$"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS" "$SENTINEL_CONFIG"

# Source foundation + config
source "$SCRIPT_DIR/../scripts/sentinel-utils.sh"

# Source the module under test
source "$SCRIPT_DIR/../scripts/lib/write-status.sh"

# Safe config for testing
export MONITORED_SERVICES="com.test.one,com.test.two"
export KILL_TIER_1="ChatGPT Atlas"
export KILL_TIER_2="ollama"
export KILL_TIER_3="com.test.expendable"
export KILL_NEVER="claude,Ghostty,Finder"

# --- Test 1: write_status creates status.json ---
echo "  -- Test: status.json created --"
CYCLE_COUNT=42
PHASE1_CRITICAL=false
write_status
assert_file_exists "$SENTINEL_LOGS/status.json" "status.json created"

# --- Test 2: status.json is valid JSON ---
echo "  -- Test: valid JSON --"
json_valid="false"
if python3 -c "import json; json.load(open('$SENTINEL_LOGS/status.json'))" 2>/dev/null; then
    json_valid="true"
fi
assert_eq "true" "$json_valid" "status.json is valid JSON"

# --- Test 3: status.json contains expected fields ---
echo "  -- Test: expected fields --"
content=$(cat "$SENTINEL_LOGS/status.json")
assert_contains "$content" '"cycle"' "has cycle field"
assert_contains "$content" '"machine"' "has machine field"
assert_contains "$content" '"memory"' "has memory field"
assert_contains "$content" '"swap"' "has swap field"
assert_contains "$content" '"disk"' "has disk field"
assert_contains "$content" '"load"' "has load field"
assert_contains "$content" '"services"' "has services field"
assert_contains "$content" '"top_processes"' "has top_processes field"
assert_contains "$content" '"pressure_gate"' "has pressure_gate field"

# --- Test 4: cycle number matches ---
echo "  -- Test: cycle number --"
cycle_in_json=$(python3 -c "import json; print(json.load(open('$SENTINEL_LOGS/status.json'))['cycle'])")
assert_eq "42" "$cycle_in_json" "cycle number is 42"

# --- Test 5: pressure_gate reflects PHASE1_CRITICAL ---
echo "  -- Test: pressure gate false --"
gate_val=$(python3 -c "import json; print(json.load(open('$SENTINEL_LOGS/status.json'))['pressure_gate'])")
assert_eq "False" "$gate_val" "pressure_gate is false"

echo "  -- Test: pressure gate true --"
PHASE1_CRITICAL=true
write_status
gate_val=$(python3 -c "import json; print(json.load(open('$SENTINEL_LOGS/status.json'))['pressure_gate'])")
assert_eq "True" "$gate_val" "pressure_gate is true after PHASE1_CRITICAL"

# --- Test 6: history.jsonl appended ---
echo "  -- Test: history.jsonl --"
assert_file_exists "$SENTINEL_LOGS/history.jsonl" "history.jsonl created"
line_count=$(wc -l < "$SENTINEL_LOGS/history.jsonl" | tr -d ' ')
# We called write_status twice above
assert_eq "2" "$line_count" "history.jsonl has 2 lines after 2 writes"

# --- Test 7: history line is valid JSON ---
echo "  -- Test: history line valid JSON --"
last_line=$(tail -1 "$SENTINEL_LOGS/history.jsonl")
hist_valid="false"
if echo "$last_line" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
    hist_valid="true"
fi
assert_eq "true" "$hist_valid" "history line is valid JSON"

# --- Test 8: history line has compact fields ---
echo "  -- Test: history compact fields --"
assert_contains "$last_line" '"t"' "history has timestamp field"
assert_contains "$last_line" '"mem"' "history has mem field"
assert_contains "$last_line" '"swap"' "history has swap field"
assert_contains "$last_line" '"disk"' "history has disk field"
assert_contains "$last_line" '"load"' "history has load field"
assert_contains "$last_line" '"free_mb"' "history has free_mb field"

# --- Test 9: top_processes is an array ---
echo "  -- Test: top processes --"
tp_type=$(python3 -c "import json; d=json.load(open('$SENTINEL_LOGS/status.json')); print(type(d['top_processes']).__name__)")
assert_eq "list" "$tp_type" "top_processes is a list"

# --- Test 10: machine field matches ---
echo "  -- Test: machine field --"
machine_val=$(python3 -c "import json; print(json.load(open('$SENTINEL_LOGS/status.json'))['machine'])")
assert_eq "$SENTINEL_MACHINE" "$machine_val" "machine matches SENTINEL_MACHINE"

# Cleanup
rm -rf "$SENTINEL_STATE" "$SENTINEL_LOGS" "$SENTINEL_CONFIG"

test_summary
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-write-status.sh`
Expected: FAIL — `write-status.sh` doesn't exist yet

**Step 3: Implement write-status.sh**

Create `scripts/lib/write-status.sh`:

```bash
#!/usr/bin/env bash
# ================================================================================
# WRITE-STATUS — Writes status.json + history.jsonl for the web dashboard
# ================================================================================
# Sourced by sentinel-daemon.sh. Do NOT execute directly.
#
# Requires (already sourced by daemon):
#   - sentinel-utils.sh  (SENTINEL_LOGS, SENTINEL_MACHINE, logging)
#   - sentinel.conf      (MONITORED_SERVICES, KILL_NEVER, thresholds)
#
# Provides:
#   write_status()       — main entry point, writes JSON files
#   record_action()      — append an action to actions.jsonl
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
# Helper: JSON-escape a string (handle quotes and backslashes)
# =============================================================================
_ws_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    echo "$s"
}

# =============================================================================
# Data collectors (self-contained, no dependency on sentinel-status.sh)
# =============================================================================

_ws_memory() {
    local total_bytes
    total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "8589934592")
    local total_mb=$(( total_bytes / 1024 / 1024 ))
    local page_size
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "16384")

    local pages_free pages_active pages_wired
    pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
    pages_wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {gsub(/\./,"",$3); print $3}')
    pages_free="${pages_free:-0}"
    pages_active="${pages_active:-0}"
    pages_wired="${pages_wired:-0}"

    local used_mb=$(( (pages_active + pages_wired) * page_size / 1024 / 1024 ))
    local free_mb=$(( pages_free * page_size / 1024 / 1024 ))
    local percent=0
    if (( total_mb > 0 )); then
        percent=$(( used_mb * 100 / total_mb ))
    fi
    echo "{\"used_mb\":$used_mb,\"total_mb\":$total_mb,\"free_mb\":$free_mb,\"percent\":$percent}"
}

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
    echo "{\"used_mb\":$used,\"total_mb\":$total,\"percent\":$percent}"
}

_ws_disk() {
    local line
    line=$(df -g / 2>/dev/null | awk 'NR==2')
    local total used avail
    total=$(echo "$line" | awk '{print $2}')
    used=$(echo "$line" | awk '{print $3}')
    avail=$(echo "$line" | awk '{print $4}')
    total="${total:-0}"; used="${used:-0}"; avail="${avail:-0}"
    local percent=0
    if (( total > 0 )); then
        percent=$(( used * 100 / total ))
    fi
    echo "{\"used_gb\":$used,\"total_gb\":$total,\"free_gb\":$avail,\"percent\":$percent}"
}

_ws_load() {
    local load_val
    load_val=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
    local cores
    cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "4")
    load_val="${load_val:-0}"
    local percent
    percent=$(awk "BEGIN {printf \"%d\", ($load_val/$cores)*100}")
    echo "{\"avg_1m\":$load_val,\"cores\":$cores,\"percent\":$percent}"
}

_ws_network() {
    # Get bytes in/out from the primary interface
    local bytes_in=0 bytes_out=0
    local iface_line
    iface_line=$(netstat -ib 2>/dev/null | grep -E "^en0\s" | head -1 || true)
    if [[ -n "$iface_line" ]]; then
        bytes_in=$(echo "$iface_line" | awk '{print $7}')
        bytes_out=$(echo "$iface_line" | awk '{print $10}')
    fi
    bytes_in="${bytes_in:-0}"; bytes_out="${bytes_out:-0}"
    echo "{\"bytes_in\":$bytes_in,\"bytes_out\":$bytes_out}"
}

_ws_services() {
    local result="["
    local first=true
    local IFS=','
    for svc in $MONITORED_SERVICES; do
        svc=$(echo "$svc" | xargs)
        [[ -z "$svc" ]] && continue

        local line pid exit_code status
        line=$(launchctl list 2>/dev/null | grep "$svc" || true)

        if [[ -z "$line" ]]; then
            pid="null"; exit_code="null"; status="not_found"
        else
            pid=$(echo "$line" | awk '{print $1}')
            exit_code=$(echo "$line" | awk '{print $2}')
            if [[ "$pid" == "-" ]] || [[ "${exit_code:-0}" != "0" ]]; then
                pid="null"; status="crashed"
            else
                status="running"
            fi
        fi

        [[ "$first" == "true" ]] && first=false || result+=","
        result+="{\"name\":\"$svc\",\"pid\":$pid,\"exit_code\":$exit_code,\"status\":\"$status\"}"
    done
    result+="]"
    echo "$result"
}

_ws_top_processes() {
    local result="["
    local first=true
    # macOS: ps -m sorts by memory, rss is in KB
    while IFS= read -r line; do
        local pid rss comm
        pid=$(echo "$line" | awk '{print $1}')
        rss=$(echo "$line" | awk '{print $2}')
        comm=$(echo "$line" | awk '{print $3}')
        [[ -z "$pid" || "$pid" == "PID" ]] && continue

        local rss_mb=$(( rss / 1024 ))
        (( rss_mb < 10 )) && continue  # skip tiny processes

        # Check if killable
        local killable="true"
        local IFS_SAVE="$IFS"
        IFS=','
        for protected in $KILL_NEVER; do
            protected=$(echo "$protected" | xargs)
            if [[ "$comm" == *"$protected"* ]]; then
                killable="false"
                break
            fi
        done
        IFS="$IFS_SAVE"

        [[ "$first" == "true" ]] && first=false || result+=","
        result+="{\"name\":\"$(_ws_escape "$comm")\",\"pid\":$pid,\"rss_mb\":$rss_mb,\"killable\":$killable}"
    done < <(ps -eo pid,rss,comm -m 2>/dev/null | head -11)
    result+="]"
    echo "$result"
}

_ws_backups() {
    local sync_status="unknown"
    if launchctl list 2>/dev/null | grep -q "com.ops.sync"; then
        sync_status="registered"
    else
        sync_status="not_registered"
    fi

    local mini_status="disconnected"
    local mini_age_hours=0
    if mount 2>/dev/null | grep -q "OPS-mini"; then
        mini_status="mounted"
        local ops_path="${OPS_MINI_PATH:-/Volumes/OPS-mini/OPS}"
        if [[ -d "$ops_path" ]]; then
            local now last_mod
            now=$(date +%s)
            last_mod=$(stat -f %m "$ops_path" 2>/dev/null || echo "$now")
            mini_age_hours=$(( (now - last_mod) / 3600 ))
        fi
    fi

    echo "{\"ops_sync\":\"$sync_status\",\"ops_mini\":\"$mini_status\",\"ops_mini_age_hours\":$mini_age_hours,\"github_stale\":[]}"
}

# =============================================================================
# write_status — Main entry point (called after each daemon cycle)
# =============================================================================
write_status() {
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local cycle="${CYCLE_COUNT:-0}"
    local machine="${SENTINEL_MACHINE:-UNKNOWN}"
    local gate="false"
    [[ "${PHASE1_CRITICAL:-false}" == "true" ]] && gate="true"

    local mem swap disk load net svcs procs backups
    mem=$(_ws_memory)
    swap=$(_ws_swap)
    disk=$(_ws_disk)
    load=$(_ws_load)
    net=$(_ws_network)
    svcs=$(_ws_services)
    procs=$(_ws_top_processes)
    backups=$(_ws_backups)

    # Write status.json (atomic: write to tmp then move)
    local status_file="$SENTINEL_LOGS/status.json"
    local tmp_file="$status_file.tmp"

    cat > "$tmp_file" <<STATUSJSON
{
  "timestamp": "$ts",
  "cycle": $cycle,
  "machine": "$machine",
  "memory": $mem,
  "swap": $swap,
  "disk": $disk,
  "load": $load,
  "network": $net,
  "services": $svcs,
  "backups": $backups,
  "top_processes": $procs,
  "pressure_gate": $gate,
  "phase1_critical": $gate,
  "predictions": {"swap_full_in_minutes": null, "disk_full_in_days": null, "suggested_kills": [], "warnings": []}
}
STATUSJSON

    mv "$tmp_file" "$status_file"

    # Append to history.jsonl (compact one-liner)
    local mem_pct swap_pct disk_pct load_pct free_mb
    mem_pct=$(echo "$mem" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['percent'])" 2>/dev/null || echo "0")
    swap_pct=$(echo "$swap" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['percent'])" 2>/dev/null || echo "0")
    disk_pct=$(echo "$disk" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['percent'])" 2>/dev/null || echo "0")
    load_pct=$(echo "$load" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['percent'])" 2>/dev/null || echo "0")
    free_mb=$(echo "$mem" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['free_mb'])" 2>/dev/null || echo "0")

    echo "{\"t\":\"$ts\",\"mem\":$mem_pct,\"swap\":$swap_pct,\"disk\":$disk_pct,\"load\":$load_pct,\"free_mb\":$free_mb}" >> "$SENTINEL_LOGS/history.jsonl"

    # Rotate history (keep WEB_HISTORY_DAYS days, ~1440 lines/day)
    local max_lines=$(( ${WEB_HISTORY_DAYS:-7} * 1440 ))
    local history_file="$SENTINEL_LOGS/history.jsonl"
    if [[ -f "$history_file" ]]; then
        local current_lines
        current_lines=$(wc -l < "$history_file" | tr -d ' ')
        if (( current_lines > max_lines )); then
            tail -n "$max_lines" "$history_file" > "$history_file.tmp" && mv "$history_file.tmp" "$history_file"
        fi
    fi
}

# =============================================================================
# record_action — Append an action to actions.jsonl
# =============================================================================
# Usage: record_action "kill" "ollama" "tier=2,freed_mb=1200,success=true"
record_action() {
    local action_type="$1"
    local target="$2"
    local extra="${3:-}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local entry="{\"t\":\"$ts\",\"type\":\"$action_type\",\"target\":\"$(_ws_escape "$target")\""
    if [[ -n "$extra" ]]; then
        # Parse comma-separated key=value pairs
        local IFS_SAVE="$IFS"
        IFS=','
        for kv in $extra; do
            local key="${kv%%=*}"
            local val="${kv#*=}"
            # Check if val is numeric
            if [[ "$val" =~ ^[0-9]+$ ]]; then
                entry+=",\"$key\":$val"
            elif [[ "$val" == "true" || "$val" == "false" ]]; then
                entry+=",\"$key\":$val"
            else
                entry+=",\"$key\":\"$(_ws_escape "$val")\""
            fi
        done
        IFS="$IFS_SAVE"
    fi
    entry+="}"

    echo "$entry" >> "$SENTINEL_LOGS/actions.jsonl"
}
```

**Step 4: Run tests**

Run: `bash tests/test-write-status.sh`
Expected: All tests pass (22 tests, 0 failures)

**Step 5: Add to test runner**

Add this line to `tests/run-all.sh`, before the final summary line:

```bash
run_test "test-write-status.sh"
```

**Step 6: Run full suite**

Run: `bash tests/run-all.sh`
Expected: All test files pass (now 9 test files)

**Step 7: Commit**

```bash
git add scripts/lib/write-status.sh tests/test-write-status.sh tests/run-all.sh
git commit -m "feat: add write-status.sh — JSON data writer for web dashboard"
```

---

### Task 3: Daemon Integration — Write Status After Each Cycle

**Files:**
- Modify: `scripts/sentinel-daemon.sh:38-43` (add source for write-status.sh)
- Modify: `scripts/sentinel-daemon.sh:89-93` (call write_status after log rotation)

**Context:** The daemon needs to source `write-status.sh` and call `write_status` at the end of every cycle. This generates fresh JSON data for the web dashboard to read.

**Step 1: Source write-status.sh in daemon**

In `scripts/sentinel-daemon.sh`, after line 43 (`source "$SCRIPT_DIR/lib/check-files.sh"`), add:

```bash
source "$SCRIPT_DIR/lib/write-status.sh"
```

**Step 2: Call write_status at end of cycle**

In `scripts/sentinel-daemon.sh`, inside `run_cycle()`, after the log rotation line (`log_rotate ...`) and before `log_info "Cycle #${CYCLE_COUNT} complete"`, add:

```bash
    # ─── WRITE STATUS JSON (for web dashboard) ───
    write_status || true
```

**Step 3: Run daemon test**

Run: `bash tests/test-daemon.sh`
Expected: 13 tests, 0 failures (existing tests still pass — write_status writes to the test's temp SENTINEL_LOGS dir)

**Step 4: Verify status.json created during daemon test**

Add to `tests/test-daemon.sh`, after the "Test: log has cycle entries" block (around line 43), add:

```bash
# --- Test: status.json created after cycle ---
echo "  -- Test: status.json created --"
assert_file_exists "$SENTINEL_LOGS/status.json" "daemon creates status.json"

# --- Test: history.jsonl created after cycle ---
echo "  -- Test: history.jsonl created --"
assert_file_exists "$SENTINEL_LOGS/history.jsonl" "daemon creates history.jsonl"
```

**Step 5: Run daemon test again**

Run: `bash tests/test-daemon.sh`
Expected: 15 tests, 0 failures

**Step 6: Run full suite**

Run: `bash tests/run-all.sh`
Expected: All test files pass

**Step 7: Commit**

```bash
git add scripts/sentinel-daemon.sh tests/test-daemon.sh
git commit -m "feat: daemon writes status.json + history.jsonl each cycle"
```

---

### Task 4: Action Recording in Lib Modules

**Files:**
- Modify: `scripts/lib/check-pressure.sh` (record kills to actions.jsonl)
- Modify: `scripts/lib/check-services.sh` (record restarts to actions.jsonl)
- Modify: `scripts/lib/check-files.sh` (record janitor actions to actions.jsonl)

**Context:** When the daemon takes an action (kill, restart, file move), it should log to `actions.jsonl` via `record_action()` (defined in write-status.sh). This gives the dashboard an audit trail.

**Step 1: Add action recording to check-pressure.sh**

In `scripts/lib/check-pressure.sh`, after each `set_cooldown "pressure-kill"` call (there are 3 — one per tier resolution), add:

After Tier 1 resolution (around line 238-241):
```bash
            record_action "kill" "tier1" "tier=1,freed_mb=$freed_t1"
```

After Tier 1+2 resolution (around line 251-254):
```bash
            record_action "kill" "tier1+2" "tier=2,freed_mb=$(( freed_t1 + freed_t2 ))"
```

After all tiers exhausted (around line 263-266):
```bash
        record_action "kill" "all_tiers" "tier=3,freed_mb=$total_freed"
```

**Step 2: Add action recording to check-services.sh**

In `scripts/lib/check-services.sh`, after each `_restart_service` call (around line 139), add:

```bash
                    record_action "restart" "$service" "exit_code=$exit_code"
```

And after crash loop detection (around line 132), add:

```bash
                    record_action "crash_loop" "$service" "restart_count=$restart_count"
```

**Step 3: Add action recording to check-files.sh**

In `scripts/lib/check-files.sh`, in `_sort_file()`, after a successful `mv` of a file, add a counter. Then in `check_files()`, after the sorting loop, add:

Find the line in `check_files()` that logs the sorted count (look for `log_info.*sorted`), and add after it:

```bash
    if (( sorted > 0 )); then
        record_action "janitor" "sort" "files_moved=$sorted,destination=$JANITOR_DESTINATION"
    fi
```

**Step 4: Run full test suite**

Run: `bash tests/run-all.sh`
Expected: All test files pass. Note: `record_action` will fail silently in tests where write-status.sh isn't sourced — this is fine because `|| true` prevents errors in the daemon, and the function is defined only when write-status.sh is sourced.

**Important:** Since existing tests don't source write-status.sh, `record_action` won't be defined during those tests. Add this guard at the top of each record_action call:

```bash
type record_action &>/dev/null && record_action "kill" "tier1" "tier=1,freed_mb=$freed_t1"
```

This pattern (`type func &>/dev/null && func args`) checks if the function exists before calling it. Use this for ALL record_action calls added in this task.

**Step 5: Commit**

```bash
git add scripts/lib/check-pressure.sh scripts/lib/check-services.sh scripts/lib/check-files.sh
git commit -m "feat: record daemon actions to actions.jsonl for dashboard audit trail"
```

---

### Task 5: Python Web Server — Read-Only Endpoints

**Files:**
- Create: `scripts/sentinel-webserver.py`
- Create: `tests/test-webserver.sh`

**Context:** The Python server uses only stdlib (`http.server`, `json`, `os`, `subprocess`). It serves the dashboard HTML and provides JSON API endpoints. This task covers GET (read-only) endpoints. Task 6 adds POST (action) endpoints.

**Step 1: Write the test file for GET endpoints**

Create `tests/test-webserver.sh`:

```bash
#!/usr/bin/env bash
# Test: sentinel-webserver.py — HTTP API endpoints
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-webserver.sh ==="

# Setup: isolated temp dirs
export SENTINEL_LOGS="/tmp/sentinel-test-web-$$"
export SENTINEL_CONFIG="/tmp/sentinel-test-web-config-$$"
mkdir -p "$SENTINEL_LOGS/alerts" "$SENTINEL_CONFIG"

# Generate test token
echo "test-token-12345" > "$SENTINEL_CONFIG/web.token"

# Write a mock status.json
cat > "$SENTINEL_LOGS/status.json" <<'JSON'
{"timestamp":"2026-02-28T00:00:00Z","cycle":100,"machine":"NODE","memory":{"used_mb":7000,"total_mb":8192,"free_mb":200,"percent":85},"swap":{"used_mb":5000,"total_mb":8192,"percent":61},"disk":{"used_gb":170,"total_gb":228,"free_gb":58,"percent":74},"load":{"avg_1m":2.5,"cores":8,"percent":31},"network":{"bytes_in":1000,"bytes_out":2000},"services":[],"backups":{},"top_processes":[],"pressure_gate":false,"phase1_critical":false,"predictions":{}}
JSON

# Write mock history
echo '{"t":"2026-02-28T00:00:00Z","mem":85,"swap":61,"disk":74,"load":31,"free_mb":200}' > "$SENTINEL_LOGS/history.jsonl"
echo '{"t":"2026-02-28T00:01:00Z","mem":86,"swap":62,"disk":74,"load":30,"free_mb":180}' >> "$SENTINEL_LOGS/history.jsonl"

# Write mock alert
echo '{"timestamp":"2026-02-28T00:00:00Z","type":"pressure","severity":"critical","message":"test alert"}' > "$SENTINEL_LOGS/alerts/alert-2026-02-28_00-00-00.json"

# Start server in background on a random port
WEB_PORT=0  # Let OS assign port
SERVER_PID=""
cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$SENTINEL_LOGS" "$SENTINEL_CONFIG"
}
trap cleanup EXIT

# Use a fixed port for testing (check if available)
TEST_PORT=18888
export WEB_PORT=$TEST_PORT
python3 "$SCRIPT_DIR/../scripts/sentinel-webserver.py" &
SERVER_PID=$!
sleep 1

# Check server started
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "  FAIL: Server failed to start"
    exit 1
fi

BASE="http://localhost:$TEST_PORT"

# --- Test 1: Root serves HTML ---
echo "  -- Test: root serves HTML --"
root_response=$(curl -s "$BASE/" 2>/dev/null || echo "CURL_FAILED")
assert_contains "$root_response" "<!DOCTYPE html>" "root returns HTML"

# --- Test 2: /api/status returns JSON ---
echo "  -- Test: /api/status --"
status_response=$(curl -s "$BASE/api/status" 2>/dev/null)
assert_contains "$status_response" '"cycle"' "status has cycle field"
assert_contains "$status_response" '"machine"' "status has machine field"

# --- Test 3: /api/history returns JSONL ---
echo "  -- Test: /api/history --"
history_response=$(curl -s "$BASE/api/history" 2>/dev/null)
assert_contains "$history_response" '"mem"' "history has mem field"
line_count=$(echo "$history_response" | wc -l | tr -d ' ')
assert_eq "2" "$line_count" "history has 2 lines"

# --- Test 4: /api/alerts returns JSON array ---
echo "  -- Test: /api/alerts --"
alerts_response=$(curl -s "$BASE/api/alerts" 2>/dev/null)
assert_contains "$alerts_response" '"type"' "alerts has type field"

# --- Test 5: 404 for unknown paths ---
echo "  -- Test: 404 --"
status_code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/nonexistent" 2>/dev/null)
assert_eq "404" "$status_code" "unknown path returns 404"

test_summary
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-webserver.sh`
Expected: FAIL — `sentinel-webserver.py` doesn't exist yet

**Step 3: Implement the Python webserver**

Create `scripts/sentinel-webserver.py`:

```python
#!/usr/bin/env python3
"""
OPS Sentinel Suite — Web Dashboard Server

Lightweight HTTP server using only Python stdlib.
Serves the dashboard HTML and provides JSON API endpoints.

Usage:
    python3 sentinel-webserver.py

Environment:
    SENTINEL_LOGS    — Path to logs directory (default: ~/.sentinel-logs)
    SENTINEL_CONFIG  — Path to config directory (default: ~/.sentinel-config)
    WEB_PORT         — Port to listen on (default: 8888)
"""

import http.server
import json
import os
import subprocess
import sys
import glob
import time
from pathlib import Path
from urllib.parse import urlparse, parse_qs

# Paths
SENTINEL_LOGS = os.environ.get("SENTINEL_LOGS", os.path.expanduser("~/.sentinel-logs"))
SENTINEL_CONFIG = os.environ.get("SENTINEL_CONFIG", os.path.expanduser("~/.sentinel-config"))
SENTINEL_HOME = os.environ.get("SENTINEL_HOME", os.path.expanduser("~/.local/share/ops-sentinel"))
WEB_PORT = int(os.environ.get("WEB_PORT", "8888"))
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Load auth token
TOKEN_FILE = os.environ.get("WEB_TOKEN_FILE", os.path.join(SENTINEL_CONFIG, "web.token"))
AUTH_TOKEN = ""
if os.path.exists(TOKEN_FILE):
    AUTH_TOKEN = open(TOKEN_FILE).read().strip()

# Allowed local subnets for action endpoints
ALLOWED_PREFIXES = ("127.", "192.168.", "10.", "100.", "::1", "0:0:0:0:0:0:0:1")


def is_local(address):
    """Check if request is from local network."""
    return any(address.startswith(p) for p in ALLOWED_PREFIXES)


class SentinelHandler(http.server.BaseHTTPRequestHandler):
    """Handle GET and POST requests for the Sentinel dashboard."""

    def log_message(self, format, *args):
        """Suppress default request logging to avoid noise."""
        pass

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if isinstance(data, str):
            self.wfile.write(data.encode())
        else:
            self.wfile.write(json.dumps(data).encode())

    def _send_text(self, text, content_type="text/plain", status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(text.encode())

    def _send_file(self, path, content_type):
        if os.path.exists(path):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.end_headers()
            with open(path, "rb") as f:
                self.wfile.write(f.read())
        else:
            self._send_json({"error": "not found"}, 404)

    def _check_auth(self):
        """Verify auth token for action endpoints."""
        if not AUTH_TOKEN:
            return True  # No token configured = open
        token = self.headers.get("X-Sentinel-Token", "")
        return token == AUTH_TOKEN

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        params = parse_qs(parsed.query)

        if path == "" or path == "/index.html":
            # Serve dashboard HTML
            html_path = os.path.join(SCRIPT_DIR, "sentinel-dashboard.html")
            if not os.path.exists(html_path):
                html_path = os.path.join(SENTINEL_HOME, "sentinel-dashboard.html")
            if os.path.exists(html_path):
                # Inject token as meta tag for JS to read
                html = open(html_path).read()
                html = html.replace("{{AUTH_TOKEN}}", AUTH_TOKEN)
                html = html.replace("{{WEB_PORT}}", str(WEB_PORT))
                self._send_text(html, "text/html")
            else:
                self._send_text("Dashboard HTML not found. Check installation.", "text/html", 404)

        elif path == "/api/status":
            status_path = os.path.join(SENTINEL_LOGS, "status.json")
            self._send_file(status_path, "application/json")

        elif path == "/api/history":
            history_path = os.path.join(SENTINEL_LOGS, "history.jsonl")
            if os.path.exists(history_path):
                # Optional: filter by hours param
                hours = int(params.get("hours", ["0"])[0])
                if hours > 0:
                    cutoff = time.time() - (hours * 3600)
                    lines = []
                    with open(history_path) as f:
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                entry = json.loads(line)
                                # Parse ISO timestamp
                                ts = entry.get("t", "")
                                # Simple comparison: just include recent lines
                                lines.append(line)
                            except json.JSONDecodeError:
                                continue
                    # Return last N lines based on hours (1440 lines/day)
                    max_lines = hours * 60  # 1 per minute
                    self._send_text("\n".join(lines[-max_lines:]), "application/x-ndjson")
                else:
                    with open(history_path) as f:
                        self._send_text(f.read(), "application/x-ndjson")
            else:
                self._send_text("", "application/x-ndjson")

        elif path == "/api/alerts":
            alerts_dir = os.path.join(SENTINEL_LOGS, "alerts")
            alerts = []
            if os.path.isdir(alerts_dir):
                for f in sorted(glob.glob(os.path.join(alerts_dir, "alert-*.json")), reverse=True):
                    try:
                        alerts.append(json.load(open(f)))
                    except (json.JSONDecodeError, IOError):
                        # Also try .txt files — parse as plain text alert
                        pass
                # Also include .txt alerts for backward compat
                for f in sorted(glob.glob(os.path.join(alerts_dir, "alert-*.txt")), reverse=True):
                    try:
                        content = open(f).read()
                        name = os.path.basename(f)
                        # Extract timestamp from filename: alert-YYYY-MM-DD_HH-MM-SS.txt
                        ts = name.replace("alert-", "").replace(".txt", "").replace("_", "T").replace("-", ":", 2)
                        alerts.append({"timestamp": ts, "type": "alert", "severity": "info", "message": content[:200], "file": f})
                    except IOError:
                        pass
            self._send_json(alerts[:50])  # Last 50 alerts

        elif path == "/api/actions":
            actions_path = os.path.join(SENTINEL_LOGS, "actions.jsonl")
            if os.path.exists(actions_path):
                with open(actions_path) as f:
                    self._send_text(f.read(), "application/x-ndjson")
            else:
                self._send_text("", "application/x-ndjson")

        elif path == "/api/config":
            # Return current config values (read-only)
            config = {}
            config_path = os.path.join(SENTINEL_CONFIG, "sentinel.conf")
            if os.path.exists(config_path):
                with open(config_path) as f:
                    config["raw"] = f.read()
            self._send_json(config)

        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        # Auth check for all POST endpoints
        if not self._check_auth():
            self._send_json({"error": "unauthorized"}, 401)
            return

        # Local network check
        client_ip = self.client_address[0]
        if not is_local(client_ip):
            self._send_json({"error": "forbidden — local network only"}, 403)
            return

        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        body = {}
        if content_length > 0:
            raw = self.rfile.read(content_length).decode()
            try:
                body = json.loads(raw)
            except json.JSONDecodeError:
                self._send_json({"error": "invalid JSON"}, 400)
                return

        if path == "/api/action/restart":
            service = body.get("service", "")
            if not service:
                self._send_json({"error": "service required"}, 400)
                return
            uid = os.getuid()
            result = subprocess.run(
                ["launchctl", "kickstart", "-k", f"gui/{uid}/{service}"],
                capture_output=True, text=True, timeout=10
            )
            self._send_json({"ok": result.returncode == 0, "output": result.stderr or result.stdout})

        elif path == "/api/action/kill":
            target = body.get("pid") or body.get("name", "")
            if not target:
                self._send_json({"error": "pid or name required"}, 400)
                return
            if isinstance(target, int) or str(target).isdigit():
                result = subprocess.run(["kill", "-TERM", str(target)], capture_output=True, text=True)
            else:
                result = subprocess.run(["pkill", "-f", str(target)], capture_output=True, text=True)
            self._send_json({"ok": result.returncode == 0, "output": result.stderr or result.stdout})

        elif path == "/api/action/config":
            # Update a config value in sentinel.conf
            key = body.get("key", "")
            value = body.get("value", "")
            if not key:
                self._send_json({"error": "key required"}, 400)
                return
            config_path = os.path.join(SENTINEL_CONFIG, "sentinel.conf")
            if os.path.exists(config_path):
                lines = open(config_path).readlines()
                found = False
                for i, line in enumerate(lines):
                    if line.strip().startswith(f"{key}="):
                        lines[i] = f'{key}="${{{key}:-{value}}}"\n'
                        found = True
                        break
                if not found:
                    lines.append(f'{key}="${{{key}:-{value}}}"\n')
                with open(config_path, "w") as f:
                    f.writelines(lines)
                self._send_json({"ok": True})
            else:
                self._send_json({"error": "config file not found"}, 404)

        elif path == "/api/action/triage":
            # Run triage script in background
            triage_script = os.path.join(SENTINEL_HOME, "sentinel-triage.sh")
            if os.path.exists(triage_script):
                subprocess.Popen(["bash", triage_script, "--auto"], start_new_session=True)
                self._send_json({"ok": True, "message": "triage started"})
            else:
                self._send_json({"error": "triage script not found"}, 404)

        else:
            self._send_json({"error": "not found"}, 404)

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Sentinel-Token")
        self.end_headers()


def main():
    server = http.server.HTTPServer(("0.0.0.0", WEB_PORT), SentinelHandler)
    print(f"Sentinel web dashboard: http://localhost:{WEB_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
```

**Step 4: Run tests**

Run: `bash tests/test-webserver.sh`
Expected: All tests pass

**Step 5: Add to test runner**

Add to `tests/run-all.sh`:

```bash
run_test "test-webserver.sh"
```

**Step 6: Commit**

```bash
git add scripts/sentinel-webserver.py tests/test-webserver.sh tests/run-all.sh
git commit -m "feat: Python web server with read-only API + action endpoints"
```

---

### Task 6: Dashboard HTML — Single File UI

**Files:**
- Create: `scripts/sentinel-dashboard.html`

**Context:** Single HTML file with embedded CSS and JS. Uses Chart.js from CDN for time-series graphs. No build step. Clean modern + data-dense visual style. Auto-refreshes every 5 seconds by polling `/api/status`. The auth token is injected by the Python server as `{{AUTH_TOKEN}}` replacement.

**Step 1: Create the dashboard HTML**

Create `scripts/sentinel-dashboard.html`. This is a large file — the complete single-file dashboard with:

- CSS variables for theming (dark mode by default)
- CSS Grid layout matching the design wireframe
- System gauges (circular progress indicators for memory, swap, disk, CPU)
- Service status table with restart buttons
- Top processes table with kill buttons (protected processes show lock icon)
- Backup channel status indicators
- Predictions panel with warnings and suggested kills
- Chart.js time-series (memory, swap, disk, load over time)
- Time window selector (1h, 6h, 24h, 7d, All)
- Alert timeline with [View] buttons that zoom the chart
- Action audit log
- Control bar (Triage, Restart All, Config drawer)
- Config editor slide-out drawer
- Auto-refresh polling at 5-second intervals
- URL hash handling for `#alert-{timestamp}` deep links

This file will be ~600-800 lines. The implementer should build it section by section, testing each visually in the browser by running `python3 scripts/sentinel-webserver.py` and opening `http://localhost:8888`.

Key implementation notes:
- Use `fetch('/api/status')` for live data, `fetch('/api/history')` for charts
- Action buttons send `fetch('/api/action/restart', {method: 'POST', headers: {'X-Sentinel-Token': token}, body: JSON.stringify({service: name})})`
- Chart.js instance stored globally, updated on each refresh cycle
- Time window selector filters history API: `fetch('/api/history?hours=24')`
- Alert `[View]` buttons set `window.location.hash = '#alert-' + timestamp` and zoom chart
- On page load, check `window.location.hash` for deep link from notification click
- Config drawer uses `fetch('/api/config')` to load, `fetch('/api/action/config', ...)` to save
- Use CSS `color-mix()` or HSL for status colors: green (<60%), amber (60-80%), red (>80%)

**Step 2: Test manually**

Run: `python3 scripts/sentinel-webserver.py`
Open: `http://localhost:8888`
Verify: Dashboard loads, shows live data, charts render, buttons work

**Step 3: Commit**

```bash
git add scripts/sentinel-dashboard.html
git commit -m "feat: web dashboard UI — single-file HTML with charts and controls"
```

---

### Task 7: Notification Integration — Click Opens Dashboard

**Files:**
- Modify: `scripts/sentinel-utils.sh:125-170` (sentinel_notify function)

**Context:** Update `sentinel_notify()` so clicking a notification opens the web dashboard at the relevant alert, instead of opening a `.txt` file. Keep the `.txt` fallback for when the webserver isn't running.

**Step 1: Update sentinel_notify()**

Replace the `terminal-notifier` block in `sentinel_notify()`. The key change: instead of `-execute "open '$alert_file'"`, use `-open "http://localhost:${WEB_PORT:-8888}/#alert-${ts}"`. Also write a `.json` alert file alongside the `.txt` for the dashboard API to read.

After the existing `.txt` alert file write, add:

```bash
          # Also write JSON alert for dashboard API
          local json_alert="$alert_dir/alert-${ts}.json"
          local severity="info"
          if [[ "$title" == *"CRITICAL"* ]]; then severity="critical"
          elif [[ "$title" == *"Warning"* || "$title" == *"warning"* ]]; then severity="warning"
          fi
          printf '{"timestamp":"%s","type":"%s","severity":"%s","message":"%s","detail":"%s"}\n' \
              "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
              "$(_ws_escape "$title")" \
              "$severity" \
              "$(_ws_escape "$message")" \
              "$(_ws_escape "${detail:-}")" > "$json_alert"
```

Change the `-execute` line to:

```bash
          # Try dashboard URL first, fall back to .txt file
          local click_action
          if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${WEB_PORT:-8888}/api/status" 2>/dev/null | grep -q "200"; then
              click_action="-open http://localhost:${WEB_PORT:-8888}/#alert-${ts}"
          else
              click_action="-execute open '$alert_file'"
          fi
```

Then use `$click_action` in the terminal-notifier invocation.

**Note on `_ws_escape`:** This function is defined in `write-status.sh`. Since `sentinel_notify()` may be called before `write-status.sh` is sourced (e.g., from test scripts or standalone), add a local fallback:

```bash
          # JSON escape helper (local fallback if write-status.sh not sourced)
          _json_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; echo "$s"; }
```

Use `_json_esc` instead of `_ws_escape` in this function.

**Step 2: Run existing tests**

Run: `bash tests/run-all.sh`
Expected: All tests still pass (notification tests don't check click behavior)

**Step 3: Commit**

```bash
git add scripts/sentinel-utils.sh
git commit -m "feat: notification click opens web dashboard instead of text file"
```

---

### Task 8: LaunchAgent + Installer Updates

**Files:**
- Create: `launchagents/com.ops.sentinel.web.plist`
- Modify: `install.sh`

**Context:** The web server needs its own LaunchAgent (KeepAlive, like the daemon). The installer needs to: copy the webserver + dashboard, generate an auth token, install the web LaunchAgent.

**Step 1: Create the web server LaunchAgent**

Create `launchagents/com.ops.sentinel.web.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ops.sentinel.web</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/python3</string>
        <string>${INSTALL_DIR}/sentinel-webserver.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/sentinel-web-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/sentinel-web-stderr.log</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
```

**Important:** The installer must replace `${INSTALL_DIR}` with the actual path when generating the plist (same pattern as the daemon plist in install.sh).

**Step 2: Update install.sh**

Add after the existing script copy section (around line 73):

```bash
# Copy webserver + dashboard
cp "$SCRIPT_DIR/scripts/sentinel-webserver.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/sentinel-dashboard.html" "$INSTALL_DIR/"
echo -e "  ${GREEN}✓${NC} Web dashboard installed"
```

Add after the daemon LaunchAgent section:

```bash
# Install web server LaunchAgent
WEB_PLIST_NAME="com.ops.sentinel.web.plist"
WEB_PLIST_DEST="$HOME/Library/LaunchAgents/$WEB_PLIST_NAME"

cat > "$WEB_PLIST_DEST" <<WEBPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ops.sentinel.web</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/python3</string>
        <string>${INSTALL_DIR}/sentinel-webserver.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/sentinel-web-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/sentinel-web-stderr.log</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
WEBPLIST

echo -e "  ${GREEN}✓${NC} Web server LaunchAgent installed"
```

Add after the terminal-notifier check section:

```bash
# Generate web auth token if not exists
if [[ ! -f "$CONFIG_DIR/web.token" ]]; then
    python3 -c "import secrets; print(secrets.token_hex(16))" > "$CONFIG_DIR/web.token"
    chmod 600 "$CONFIG_DIR/web.token"
    echo -e "  ${GREEN}✓${NC} Web auth token generated"
else
    echo -e "  ${YELLOW}~${NC} Web auth token exists — preserved"
fi
```

Update the uninstall section to also handle the web LaunchAgent:

```bash
    # Stop web server
    if launchctl list 2>/dev/null | grep -q "com.ops.sentinel.web"; then
        launchctl unload "$HOME/Library/LaunchAgents/com.ops.sentinel.web.plist" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} Web server stopped"
    fi
    rm -f "$HOME/Library/LaunchAgents/com.ops.sentinel.web.plist"
```

Update the success message to include the dashboard URL:

```bash
echo "  sentinel-dashboard — http://localhost:8888"
```

And:

```bash
echo "To start the web dashboard:"
echo "  launchctl load ~/Library/LaunchAgents/com.ops.sentinel.web.plist"
echo "  Then open: http://localhost:8888"
```

**Step 3: Validate plist**

Run: `plutil -lint launchagents/com.ops.sentinel.web.plist`
Expected: OK

**Step 4: Commit**

```bash
git add launchagents/com.ops.sentinel.web.plist install.sh
git commit -m "feat: web server LaunchAgent + installer updates with token generation"
```

---

### Task 9: Predictions Engine

**Files:**
- Modify: `scripts/lib/write-status.sh` (add predictions calculation)

**Context:** The predictions engine reads the last 30 data points from `history.jsonl` and computes linear trends to predict when swap/disk will hit thresholds. Kill suggestions are ranked by historical effectiveness from `actions.jsonl`. This runs inside `write_status()` at the end, enriching `status.json` with predictions.

**Step 1: Add prediction tests to test-write-status.sh**

Add to `tests/test-write-status.sh`, before cleanup:

```bash
# --- Test: predictions populated ---
echo "  -- Test: predictions --"
# Write some history to enable predictions
for i in $(seq 1 30); do
    echo "{\"t\":\"2026-02-28T00:${i}:00Z\",\"mem\":$((80 + i/3)),\"swap\":$((50 + i)),\"disk\":74,\"load\":30,\"free_mb\":$((200 - i*5))}" >> "$SENTINEL_LOGS/history.jsonl"
done
CYCLE_COUNT=100
write_status
predictions=$(python3 -c "import json; d=json.load(open('$SENTINEL_LOGS/status.json')); print(json.dumps(d.get('predictions', {})))")
assert_contains "$predictions" "swap_full_in_minutes" "predictions has swap forecast"
assert_contains "$predictions" "warnings" "predictions has warnings array"
```

**Step 2: Implement predictions in write_status**

In `write_status()` in `scripts/lib/write-status.sh`, replace the static predictions line with a call to a helper function:

```bash
_ws_predictions() {
    local history_file="$SENTINEL_LOGS/history.jsonl"
    local actions_file="$SENTINEL_LOGS/actions.jsonl"

    # Default empty predictions
    local swap_forecast="null"
    local disk_forecast="null"
    local warnings="[]"
    local suggested_kills="[]"

    # Need python3 for math — use inline script
    if command -v python3 &>/dev/null && [[ -f "$history_file" ]]; then
        local result
        result=$(python3 -c "
import json, sys

history_file = '$history_file'
actions_file = '$actions_file'
swap_crit = ${SWAP_CRITICAL_MB:-4096}
disk_crit = ${DISK_CRITICAL_GB:-5}

# Read last 30 history lines
lines = []
try:
    with open(history_file) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    lines.append(json.loads(line))
                except:
                    pass
except:
    pass

lines = lines[-30:]
predictions = {'swap_full_in_minutes': None, 'disk_full_in_days': None, 'suggested_kills': [], 'warnings': []}

if len(lines) >= 5:
    # Linear regression on swap percentage
    swaps = [l.get('swap', 0) for l in lines]
    if len(swaps) >= 5:
        n = len(swaps)
        # Simple slope: (last - first) / n
        slope = (swaps[-1] - swaps[0]) / max(n, 1)  # per minute
        if slope > 0 and swaps[-1] < 100:
            mins_to_full = int((100 - swaps[-1]) / slope)
            if mins_to_full < 1440:  # Only report if < 24h
                predictions['swap_full_in_minutes'] = mins_to_full
                if mins_to_full < 60:
                    predictions['warnings'].append(f'Swap trending to full in ~{mins_to_full} min')

    # Free memory trend
    frees = [l.get('free_mb', 0) for l in lines]
    if frees and frees[-1] < 100:
        predictions['warnings'].append(f'Free memory critically low: {frees[-1]}MB')

# Kill suggestions from actions history
try:
    kills = {}
    with open(actions_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                a = json.loads(line)
                if a.get('type') == 'kill':
                    target = a.get('target', '')
                    freed = a.get('freed_mb', 0)
                    if target in kills:
                        kills[target]['count'] += 1
                        kills[target]['total_freed'] += freed
                    else:
                        kills[target] = {'count': 1, 'total_freed': freed}
            except:
                pass
    for target, data in sorted(kills.items(), key=lambda x: x[1]['total_freed'], reverse=True)[:3]:
        avg_freed = data['total_freed'] // max(data['count'], 1)
        predictions['suggested_kills'].append({
            'name': target,
            'avg_freed_mb': avg_freed,
            'reason': f'Killed {data[\"count\"]}x before, avg freed ~{avg_freed}MB'
        })
except:
    pass

print(json.dumps(predictions))
" 2>/dev/null) || result='{"swap_full_in_minutes":null,"disk_full_in_days":null,"suggested_kills":[],"warnings":[]}'
        echo "$result"
    else
        echo '{"swap_full_in_minutes":null,"disk_full_in_days":null,"suggested_kills":[],"warnings":[]}'
    fi
}
```

Then in `write_status()`, replace the static predictions line in the heredoc:

```bash
  "predictions": $(predictions_json)
```

Where `predictions_json=$(_ws_predictions)` is called before the heredoc.

**Step 3: Run tests**

Run: `bash tests/test-write-status.sh`
Expected: All tests pass including new prediction tests

**Step 4: Run full suite**

Run: `bash tests/run-all.sh`
Expected: All test files pass

**Step 5: Commit**

```bash
git add scripts/lib/write-status.sh tests/test-write-status.sh
git commit -m "feat: predictions engine — swap/disk forecasting + kill suggestions"
```

---

### Task 10: CHANGELOG + Final Verification

**Files:**
- Modify: `CHANGELOG.md`

**Step 1: Update CHANGELOG**

Add under `## [Unreleased]`:

```markdown
## [1.2.0] — 2026-02-28

### Added
- `scripts/sentinel-webserver.py` — Python stdlib HTTP server for web dashboard (GET/POST API, token auth, local subnet restriction)
- `scripts/sentinel-dashboard.html` — single-file web dashboard with Chart.js charts, service controls, process kill buttons, config editor, alert timeline
- `scripts/lib/write-status.sh` — status.json + history.jsonl + actions.jsonl writer (called each daemon cycle)
- `launchagents/com.ops.sentinel.web.plist` — KeepAlive LaunchAgent for web server
- Predictions engine: linear trend extrapolation for swap/disk + kill suggestions based on action history
- Action audit trail: all kills, restarts, and janitor actions recorded to actions.jsonl
- Web dashboard config: WEB_PORT, WEB_TOKEN_FILE, WEB_REFRESH_SECONDS, WEB_HISTORY_DAYS, WEB_ACTIONS_DAYS
- Token-based auth for action endpoints (generated at install)
- Notification click opens web dashboard at `#alert-{timestamp}` deep link

### Changed
- `sentinel-daemon.sh` — calls write_status after each cycle to generate dashboard data
- `sentinel_notify()` — clicks open web dashboard URL (falls back to .txt if server down)
- `install.sh` — installs webserver, dashboard, web LaunchAgent, generates auth token
- `check-pressure.sh`, `check-services.sh`, `check-files.sh` — record actions to actions.jsonl
```

**Step 2: Run full test suite**

Run: `bash tests/run-all.sh`
Expected: All test files pass

**Step 3: Run the webserver manually and verify dashboard**

Run: `python3 scripts/sentinel-webserver.py &`
Open: `http://localhost:8888`
Verify all sections render, data refreshes, controls work

**Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for v1.2.0 — web dashboard release"
```

**Step 5: Run install.sh and start dashboard**

```bash
./install.sh
launchctl load ~/Library/LaunchAgents/com.ops.sentinel.web.plist
open http://localhost:8888
```
