#!/usr/bin/env bash
# ================================================================================
# TEST: write-status.sh — JSON data writer for web dashboard
# ================================================================================
# Mocks sysctl, vm_stat, ps, df, netstat, launchctl, mount, git, stat
# to test status.json output, history.jsonl, and record_action without
# touching real system state.
# ================================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-write-status.sh ==="

# =============================================================================
# TEST ISOLATION: temp dirs for state/logs, clean between tests
# =============================================================================
TEST_TMPDIR=$(mktemp -d /tmp/sentinel-write-status-test.XXXXXX)
export SENTINEL_STATE="$TEST_TMPDIR/state"
export SENTINEL_LOGS="$TEST_TMPDIR/logs"
export SENTINEL_CONFIG="$TEST_TMPDIR/config"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS" "$SENTINEL_CONFIG"

# Source utils (sets up logging, cooldowns, etc.)
source "$REPO_DIR/scripts/sentinel-utils.sh"

# Re-point state/logs to our temp dirs (sentinel-utils.sh overwrites them)
SENTINEL_STATE="$TEST_TMPDIR/state"
SENTINEL_LOGS="$TEST_TMPDIR/logs"

# Source config (sets thresholds)
source "$REPO_DIR/config/sentinel.conf"

# Override config values for testing
MONITORED_SERVICES="com.test.one,com.test.two"
KILL_NEVER="claude,Ghostty,Finder"
WEB_HISTORY_DAYS=7
WEB_ACTIONS_DAYS=30
GITHUB_REPOS=""
OPS_MINI_PATH="$TEST_TMPDIR/nonexistent-opsmini"
OPS_MINI_STALE_HOURS=48
GITHUB_STALE_HOURS=24

# =============================================================================
# MOCK STATE VARIABLES
# =============================================================================
MOCK_TOTAL_BYTES="17179869184"
MOCK_PAGE_SIZE="16384"
MOCK_PAGES_FREE="50000"
MOCK_PAGES_ACTIVE="200000"
MOCK_PAGES_WIRED="100000"
MOCK_SWAP_USED="1024.00"
MOCK_SWAP_TOTAL="6144.00"
MOCK_DF_OUTPUT="228 167 61"
MOCK_LOADAVG="2.50"
MOCK_NCPU="8"
MOCK_NETSTAT_LINE="en0   1500  <Link#5>   a4:83:e7:00:00:00 12345678   0   87654321   0       0"
MOCK_LAUNCHCTL_OUTPUT="1234	0	com.test.one
-	78	com.test.two"
MOCK_MOUNT_OUTPUT="/dev/disk1s1 on / (apfs, local)"
MOCK_PS_OUTPUT="10001 2097152 /Applications/SomeBigApp
10002 1048576 /Applications/claude
10003  524288 /Applications/Ghostty
10004  262144 /usr/bin/someutil
10005  131072 /Applications/Finder
10006  65536 /usr/local/bin/smallapp
10007  32768 /usr/bin/tinyutil
10008  16384 /usr/sbin/daemon1
10009   8192 /usr/sbin/daemon2
10010   4096 /usr/sbin/daemon3
10011   2048 /usr/sbin/daemon4"

# =============================================================================
# MOCK FUNCTIONS — override real system commands
# =============================================================================
sysctl() {
    case "$1" in
        -n)
            case "$2" in
                hw.memsize)   echo "$MOCK_TOTAL_BYTES" ;;
                hw.pagesize)  echo "$MOCK_PAGE_SIZE" ;;
                vm.loadavg)   echo "{ $MOCK_LOADAVG 1.50 0.80 }" ;;
                hw.ncpu)      echo "$MOCK_NCPU" ;;
            esac
            ;;
        vm.swapusage)
            echo "vm.swapusage: total = ${MOCK_SWAP_TOTAL}M  used = ${MOCK_SWAP_USED}M  free = 5120.00M  (encrypted)"
            ;;
    esac
}

vm_stat() {
    cat <<VMEOF
Mach Virtual Memory Statistics: (page size of ${MOCK_PAGE_SIZE} bytes)
Pages free:                             ${MOCK_PAGES_FREE}.
Pages active:                           ${MOCK_PAGES_ACTIVE}.
Pages inactive:                         50000.
Pages speculative:                      5000.
Pages throttled:                        0.
Pages wired down:                       ${MOCK_PAGES_WIRED}.
VMEOF
}

df() {
    echo "Filesystem     1G-blocks Used Available Capacity iused     ifree %iused  Mounted on"
    echo "/dev/disk3s1s1       ${MOCK_DF_OUTPUT}    73%  453019 641022240    0%   /"
}

netstat() {
    echo "Name  Mtu   Network       Address         Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll"
    echo "$MOCK_NETSTAT_LINE"
}

launchctl() {
    if [[ "$1" == "list" ]]; then
        echo "$MOCK_LAUNCHCTL_OUTPUT"
    fi
}

mount() {
    echo "$MOCK_MOUNT_OUTPUT"
}

git() {
    echo "0"
}

stat() {
    echo "0"
}

ps() {
    if [[ "$*" == *"-eo"* ]]; then
        echo "  PID   RSS COMM"
        if [[ -n "$MOCK_PS_OUTPUT" ]]; then
            echo "$MOCK_PS_OUTPUT"
        fi
    fi
}

sentinel_notify() {
    true
}

# Export mocks
export -f sysctl vm_stat df netstat launchctl mount git stat ps sentinel_notify 2>/dev/null || true

# =============================================================================
# SOURCE THE MODULE UNDER TEST
# =============================================================================
source "$REPO_DIR/scripts/lib/write-status.sh"

# =============================================================================
# HELPER: Reset test state between test cases
# =============================================================================
reset_test_state() {
    rm -f "$SENTINEL_LOGS/status.json"
    rm -f "$SENTINEL_LOGS/history.jsonl"
    rm -f "$SENTINEL_LOGS/actions.jsonl"
    : > "$SENTINEL_LOGS/sentinel.log"
    CYCLE_COUNT=42
    PHASE1_CRITICAL="false"
    SENTINEL_MACHINE="NODE"
}

# =============================================================================
# TEST 1: write_status creates status.json
# =============================================================================
echo ""
echo "  --- Test 1: write_status creates status.json ---"
reset_test_state

write_status
assert_file_exists "$SENTINEL_LOGS/status.json" "write_status creates status.json"

# =============================================================================
# TEST 2: status.json is valid JSON
# =============================================================================
echo ""
echo "  --- Test 2: status.json is valid JSON ---"

result=0
/opt/homebrew/bin/python3 -c "import json; json.load(open('$SENTINEL_LOGS/status.json'))" 2>/dev/null || result=$?
assert_eq "0" "$result" "status.json is valid JSON"

# =============================================================================
# TEST 3: status.json has expected top-level fields
# =============================================================================
echo ""
echo "  --- Test 3: status.json has expected fields ---"

json_content=$(cat "$SENTINEL_LOGS/status.json")

assert_contains "$json_content" '"cycle"' "status.json has cycle field"
assert_contains "$json_content" '"machine"' "status.json has machine field"
assert_contains "$json_content" '"memory"' "status.json has memory field"
assert_contains "$json_content" '"swap"' "status.json has swap field"
assert_contains "$json_content" '"disk"' "status.json has disk field"
assert_contains "$json_content" '"load"' "status.json has load field"
assert_contains "$json_content" '"services"' "status.json has services field"
assert_contains "$json_content" '"top_processes"' "status.json has top_processes field"
assert_contains "$json_content" '"pressure_gate"' "status.json has pressure_gate field"

# =============================================================================
# TEST 4: cycle number matches CYCLE_COUNT
# =============================================================================
echo ""
echo "  --- Test 4: cycle matches CYCLE_COUNT ---"

cycle_val=$(/opt/homebrew/bin/python3 -c "import json; d=json.load(open('$SENTINEL_LOGS/status.json')); print(d['cycle'])" 2>/dev/null)
assert_eq "42" "$cycle_val" "cycle field matches CYCLE_COUNT=42"

# =============================================================================
# TEST 5: pressure_gate reflects PHASE1_CRITICAL (false)
# =============================================================================
echo ""
echo "  --- Test 5: pressure_gate reflects PHASE1_CRITICAL ---"

# Already tested with PHASE1_CRITICAL=false
pg_val=$(/opt/homebrew/bin/python3 -c "import json; d=json.load(open('$SENTINEL_LOGS/status.json')); print(d['pressure_gate'])" 2>/dev/null)
assert_eq "False" "$pg_val" "pressure_gate is False when PHASE1_CRITICAL=false"

# Now test with PHASE1_CRITICAL=true
reset_test_state
PHASE1_CRITICAL="true"
write_status
pg_val=$(/opt/homebrew/bin/python3 -c "import json; d=json.load(open('$SENTINEL_LOGS/status.json')); print(d['pressure_gate'])" 2>/dev/null)
assert_eq "True" "$pg_val" "pressure_gate is True when PHASE1_CRITICAL=true"

# =============================================================================
# TEST 6: history.jsonl is created and appended (2 calls = 2 lines)
# =============================================================================
echo ""
echo "  --- Test 6: history.jsonl is created and appended ---"
reset_test_state

write_status
write_status
line_count=$(wc -l < "$SENTINEL_LOGS/history.jsonl" | tr -d ' ')
assert_eq "2" "$line_count" "history.jsonl has 2 lines after 2 write_status calls"

# =============================================================================
# TEST 7: history line is valid JSON
# =============================================================================
echo ""
echo "  --- Test 7: history line is valid JSON ---"

first_line=$(head -1 "$SENTINEL_LOGS/history.jsonl")
result=0
echo "$first_line" | /opt/homebrew/bin/python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || result=$?
assert_eq "0" "$result" "first history line is valid JSON"

# =============================================================================
# TEST 8: history has compact fields (t, mem, swap, disk, load, free_mb)
# =============================================================================
echo ""
echo "  --- Test 8: history line has compact fields ---"

assert_contains "$first_line" '"t"' "history line has t field"
assert_contains "$first_line" '"mem"' "history line has mem field"
assert_contains "$first_line" '"swap"' "history line has swap field"
assert_contains "$first_line" '"disk"' "history line has disk field"
assert_contains "$first_line" '"load"' "history line has load field"
assert_contains "$first_line" '"free_mb"' "history line has free_mb field"

# =============================================================================
# TEST 9: top_processes is an array (list type)
# =============================================================================
echo ""
echo "  --- Test 9: top_processes is an array ---"
reset_test_state
write_status

tp_type=$(/opt/homebrew/bin/python3 -c "import json; d=json.load(open('$SENTINEL_LOGS/status.json')); print(type(d['top_processes']).__name__)" 2>/dev/null)
assert_eq "list" "$tp_type" "top_processes is a list (array)"

# =============================================================================
# TEST 10: machine field matches SENTINEL_MACHINE
# =============================================================================
echo ""
echo "  --- Test 10: machine field matches SENTINEL_MACHINE ---"

machine_val=$(/opt/homebrew/bin/python3 -c "import json; d=json.load(open('$SENTINEL_LOGS/status.json')); print(d['machine'])" 2>/dev/null)
assert_eq "NODE" "$machine_val" "machine field matches SENTINEL_MACHINE=NODE"

# =============================================================================
# TEST 11: record_action creates actions.jsonl
# =============================================================================
echo ""
echo "  --- Test 11: record_action creates actions.jsonl ---"
reset_test_state

record_action "kill" "ollama" "tier=2,freed_mb=1200"
assert_file_exists "$SENTINEL_LOGS/actions.jsonl" "record_action creates actions.jsonl"

# =============================================================================
# TEST 12: record_action line is valid JSON
# =============================================================================
echo ""
echo "  --- Test 12: record_action line is valid JSON ---"

action_line=$(head -1 "$SENTINEL_LOGS/actions.jsonl")
result=0
echo "$action_line" | /opt/homebrew/bin/python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || result=$?
assert_eq "0" "$result" "action line is valid JSON"

# =============================================================================
# TEST 13: record_action has correct type and target fields
# =============================================================================
echo ""
echo "  --- Test 13: record_action has correct type and target ---"

action_type=$(/opt/homebrew/bin/python3 -c "import json; d=json.loads('''$action_line'''); print(d['type'])" 2>/dev/null)
action_target=$(/opt/homebrew/bin/python3 -c "import json; d=json.loads('''$action_line'''); print(d['target'])" 2>/dev/null)
assert_eq "kill" "$action_type" "action type is 'kill'"
assert_eq "ollama" "$action_target" "action target is 'ollama'"

# =============================================================================
# TEST 14: record_action parses key=value details correctly
# =============================================================================
echo ""
echo "  --- Test 14: record_action parses details ---"

action_tier=$(/opt/homebrew/bin/python3 -c "import json; d=json.loads('''$action_line'''); print(d['details']['tier'])" 2>/dev/null)
action_freed=$(/opt/homebrew/bin/python3 -c "import json; d=json.loads('''$action_line'''); print(d['details']['freed_mb'])" 2>/dev/null)
assert_eq "2" "$action_tier" "action details.tier is 2"
assert_eq "1200" "$action_freed" "action details.freed_mb is 1200"

# =============================================================================
# TEST 15: _ws_memory returns valid JSON with expected fields
# =============================================================================
echo ""
echo "  --- Test 15: _ws_memory returns valid JSON ---"

mem_json=$(_ws_memory)
result=0
echo "$mem_json" | /opt/homebrew/bin/python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'used_mb' in d; assert 'total_mb' in d; assert 'free_mb' in d; assert 'percent' in d" 2>/dev/null || result=$?
assert_eq "0" "$result" "_ws_memory returns JSON with used_mb, total_mb, free_mb, percent"

# =============================================================================
# TEST 16: _ws_swap returns valid JSON with expected fields
# =============================================================================
echo ""
echo "  --- Test 16: _ws_swap returns valid JSON ---"

swap_json=$(_ws_swap)
result=0
echo "$swap_json" | /opt/homebrew/bin/python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'used_mb' in d; assert 'total_mb' in d; assert 'percent' in d" 2>/dev/null || result=$?
assert_eq "0" "$result" "_ws_swap returns JSON with used_mb, total_mb, percent"

# =============================================================================
# TEST 17: _ws_services returns array with correct count
# =============================================================================
echo ""
echo "  --- Test 17: _ws_services returns correct array ---"

svc_json=$(_ws_services)
svc_count=$(/opt/homebrew/bin/python3 -c "import json; d=json.loads('''$svc_json'''); print(len(d))" 2>/dev/null)
assert_eq "2" "$svc_count" "_ws_services returns 2 services for MONITORED_SERVICES"

# Check one is running and one is crashed
svc_status_one=$(/opt/homebrew/bin/python3 -c "import json; d=json.loads('''$svc_json'''); print(d[0]['status'])" 2>/dev/null)
svc_status_two=$(/opt/homebrew/bin/python3 -c "import json; d=json.loads('''$svc_json'''); print(d[1]['status'])" 2>/dev/null)
assert_eq "running" "$svc_status_one" "com.test.one status is running"
assert_eq "crashed" "$svc_status_two" "com.test.two status is crashed"

# =============================================================================
# TEST 18: top_processes killable flag respects KILL_NEVER
# =============================================================================
echo ""
echo "  --- Test 18: top_processes killable flag ---"
reset_test_state
write_status

# claude (pid 10002) should be killable=false, SomeBigApp (pid 10001) should be killable=true
killable_somebig=$(/opt/homebrew/bin/python3 -c "
import json
d=json.load(open('$SENTINEL_LOGS/status.json'))
for p in d['top_processes']:
    if p['name'] == 'SomeBigApp':
        print(p['killable'])
        break
" 2>/dev/null)
killable_claude=$(/opt/homebrew/bin/python3 -c "
import json
d=json.load(open('$SENTINEL_LOGS/status.json'))
for p in d['top_processes']:
    if p['name'] == 'claude':
        print(p['killable'])
        break
" 2>/dev/null)
assert_eq "True" "$killable_somebig" "SomeBigApp is killable (not in KILL_NEVER)"
assert_eq "False" "$killable_claude" "claude is not killable (in KILL_NEVER)"

# =============================================================================
# TEST 19: status.json has predictions field
# =============================================================================
echo ""
echo "  --- Test 19: status.json has predictions field ---"

pred_type=$(/opt/homebrew/bin/python3 -c "import json; d=json.load(open('$SENTINEL_LOGS/status.json')); print(type(d['predictions']).__name__)" 2>/dev/null)
assert_eq "dict" "$pred_type" "predictions is a dict"

# =============================================================================
# TEST 20: guard prevents direct execution
# =============================================================================
echo ""
echo "  --- Test 20: guard prevents direct execution ---"

guard_output=$(bash "$REPO_DIR/scripts/lib/write-status.sh" 2>&1 || true)
assert_contains "$guard_output" "ERROR" "direct execution prints ERROR"
assert_contains "$guard_output" "sourced" "direct execution mentions sourcing"

# =============================================================================
# CLEANUP
# =============================================================================
rm -rf "$TEST_TMPDIR"

echo ""
test_summary
