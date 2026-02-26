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
