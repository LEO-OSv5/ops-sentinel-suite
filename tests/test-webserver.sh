#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-webserver.sh ==="

# Setup
export SENTINEL_LOGS="/tmp/sentinel-test-web-$$"
export SENTINEL_CONFIG="/tmp/sentinel-test-web-config-$$"
export SENTINEL_HOME="$SCRIPT_DIR/../scripts"
mkdir -p "$SENTINEL_LOGS/alerts" "$SENTINEL_CONFIG"

echo "test-token-abc123" > "$SENTINEL_CONFIG/web.token"
export WEB_TOKEN_FILE="$SENTINEL_CONFIG/web.token"

# Mock data
cat > "$SENTINEL_LOGS/status.json" << 'JSON'
{"timestamp":"2026-02-28T00:00:00Z","cycle":100,"machine":"NODE","memory":{"used_mb":7000,"total_mb":8192,"free_mb":200,"percent":85},"swap":{"used_mb":5000,"total_mb":8192,"percent":61},"disk":{"used_gb":170,"total_gb":228,"free_gb":58,"percent":74},"load":{"avg_1m":2.5,"cores":8,"percent":31},"network":{"bytes_in":1000,"bytes_out":2000},"services":[],"backups":{},"top_processes":[],"pressure_gate":false,"phase1_critical":false,"predictions":{}}
JSON

echo '{"t":"2026-02-28T00:00:00Z","mem":85,"swap":61,"disk":74,"load":31,"free_mb":200}' > "$SENTINEL_LOGS/history.jsonl"
echo '{"t":"2026-02-28T00:01:00Z","mem":86,"swap":62,"disk":74,"load":30,"free_mb":180}' >> "$SENTINEL_LOGS/history.jsonl"

echo '{"timestamp":"2026-02-28T00:00:00Z","type":"pressure","severity":"critical","message":"test alert"}' > "$SENTINEL_LOGS/alerts/alert-2026-02-28_00-00-00.json"

echo '{"t":"2026-02-28T00:00:00Z","type":"kill","target":"ollama","tier":2,"freed_mb":1200}' > "$SENTINEL_LOGS/actions.jsonl"

# Create a minimal dashboard HTML for the root endpoint test
cat > "$SCRIPT_DIR/../scripts/sentinel-dashboard.html" << 'HTML'
<!DOCTYPE html><html><body>Token={{AUTH_TOKEN}} Port={{WEB_PORT}}</body></html>
HTML

# Start server on a test port
TEST_PORT=18889
export WEB_PORT=$TEST_PORT
SERVER_PID=""

cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    rm -rf "$SENTINEL_LOGS" "$SENTINEL_CONFIG"
    rm -f "$SCRIPT_DIR/../scripts/sentinel-dashboard.html"
}
trap cleanup EXIT

python3 "$SCRIPT_DIR/../scripts/sentinel-webserver.py" &
SERVER_PID=$!
sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "  FAIL: Server failed to start"
    exit 1
fi

BASE="http://localhost:$TEST_PORT"

# Helper: count occurrences of a pattern in a string
count_matches() {
    echo "$1" | grep -o "$2" | wc -l | tr -d ' '
}

# ── GET /api/status ──
echo "  -- Test: /api/status returns JSON --"
status_resp=$(curl -s "$BASE/api/status")
assert_contains "$status_resp" '"cycle"' "status has cycle"
assert_contains "$status_resp" '"machine"' "status has machine"

# ── GET /api/history ──
echo "  -- Test: /api/history returns data --"
hist_resp=$(curl -s "$BASE/api/history")
assert_contains "$hist_resp" '"mem"' "history has mem"
hist_count=$(count_matches "$hist_resp" '"t":')
assert_eq "2" "$hist_count" "history has 2 records"

# ── GET /api/history?hours= ──
echo "  -- Test: /api/history?hours=1 limits lines --"
hist_hours=$(curl -s "$BASE/api/history?hours=1")
hist_h_count=$(count_matches "$hist_hours" '"t":')
assert_eq "2" "$hist_h_count" "history?hours=1 returns 2 records"

# ── GET /api/alerts ──
echo "  -- Test: /api/alerts returns array --"
alerts_resp=$(curl -s "$BASE/api/alerts")
assert_contains "$alerts_resp" '"type"' "alerts has type"
assert_contains "$alerts_resp" "pressure" "alerts contains pressure alert"

# ── GET /api/actions ──
echo "  -- Test: /api/actions returns data --"
actions_resp=$(curl -s "$BASE/api/actions")
assert_contains "$actions_resp" '"kill"' "actions has kill type"
assert_contains "$actions_resp" "ollama" "actions has ollama target"

# ── GET /api/config ──
echo "  -- Test: /api/config returns config data --"
echo 'WEB_PORT="${WEB_PORT:-8888}"' > "$SENTINEL_CONFIG/sentinel.conf"
config_resp=$(curl -s "$BASE/api/config")
assert_contains "$config_resp" "WEB_PORT" "config contains WEB_PORT"
assert_contains "$config_resp" '"config"' "config wrapped in config key"

# ── GET / (dashboard) ──
echo "  -- Test: / serves dashboard with token injection --"
dash_resp=$(curl -s "$BASE/")
assert_contains "$dash_resp" "Token=test-token-abc123" "dashboard has injected token"
assert_contains "$dash_resp" "Port=$TEST_PORT" "dashboard has injected port"

# ── 404 for unknown path ──
echo "  -- Test: 404 for unknown path --"
code_404=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/nonexistent")
assert_eq "404" "$code_404" "unknown path returns 404"

# ── POST without token returns 401 ──
echo "  -- Test: POST without token returns 401 --"
code_401=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/action/restart" \
    -H "Content-Type: application/json" -d '{"service":"test"}')
assert_eq "401" "$code_401" "POST without token returns 401"

# ── POST with wrong token returns 401 ──
echo "  -- Test: POST with wrong token returns 401 --"
code_bad=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/action/restart" \
    -H "Content-Type: application/json" -H "X-Sentinel-Token: wrong-token" \
    -d '{"service":"test"}')
assert_eq "401" "$code_bad" "POST with wrong token returns 401"

# ── POST /api/action/restart with valid token ──
echo "  -- Test: POST with correct token returns ok field --"
restart_resp=$(curl -s -X POST "$BASE/api/action/restart" \
    -H "Content-Type: application/json" \
    -H "X-Sentinel-Token: test-token-abc123" \
    -d '{"service":"com.test.fake"}')
assert_contains "$restart_resp" '"ok"' "restart with token returns ok field"
assert_contains "$restart_resp" '"service"' "restart response has service field"

# ── POST /api/action/config with valid token ──
echo "  -- Test: POST config update works --"
config_update_resp=$(curl -s -X POST "$BASE/api/action/config" \
    -H "Content-Type: application/json" \
    -H "X-Sentinel-Token: test-token-abc123" \
    -d '{"key":"SWAP_CRITICAL_MB","value":"9999"}')
assert_contains "$config_update_resp" '"ok": true' "config update returns ok true"
# Verify the file was actually changed
updated_conf=$(cat "$SENTINEL_CONFIG/sentinel.conf")
assert_contains "$updated_conf" "9999" "config file updated with new value"

# ── OPTIONS (CORS preflight) ──
echo "  -- Test: OPTIONS returns CORS headers --"
cors_headers=$(curl -s -I -X OPTIONS "$BASE/api/status" 2>&1)
assert_contains "$cors_headers" "Access-Control-Allow-Origin" "OPTIONS returns CORS origin header"

test_summary
