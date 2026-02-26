#!/usr/bin/env bash
# ================================================================================
# TEST HELPERS — Shared test utilities for OPS Sentinel Suite
# ================================================================================
# Source this in every test file. Provides assertion functions and test tracking.
# Compatible with Bash 3.2 (macOS built-in).
#
# Usage:
#   source "$SCRIPT_DIR/test-helpers.sh"
#   assert_eq "expected" "$actual" "label"
#   test_summary
# ================================================================================

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
