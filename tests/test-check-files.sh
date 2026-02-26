#!/usr/bin/env bash
# Test: check-files.sh sorts files to destination
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-files.sh ==="

# =============================================================================
# TEST ISOLATION: temp dirs for state/logs
# =============================================================================
TEST_TMPDIR=$(mktemp -d /tmp/sentinel-files-test.XXXXXX)
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

# Setup mock directories
MOCK_WATCH="$TEST_TMPDIR/watch"
MOCK_DEST="$TEST_TMPDIR/dest"
MOCK_QUEUE="$TEST_TMPDIR/queue"
mkdir -p "$MOCK_WATCH" "$MOCK_DEST" "$MOCK_QUEUE"

JANITOR_ENABLED=true
JANITOR_WATCH_DIRS="$MOCK_WATCH"
JANITOR_DESTINATION="$MOCK_DEST"
JANITOR_FALLBACK_QUEUE="$MOCK_QUEUE"
JANITOR_DATE_PREFIX=true
JANITOR_IGNORE="*.crdownload,*.part,*.tmp"
JANITOR_DESKTOP_MAX_AGE_DAYS=7
JANITOR_DOWNLOADS_MAX_AGE_DAYS=3

# Mock lsof (nothing open by default)
lsof() { return 1; }

# Mock mount (OPS-mini available)
mount() { echo "/dev/disk4s1 on /Volumes/OPS-mini (apfs, local)"; }

# Track notifications via file (subshell-safe)
NOTIFY_LOG="$TEST_TMPDIR/notify.log"
: > "$NOTIFY_LOG"
sentinel_notify() { echo "$1: $2" >> "$NOTIFY_LOG"; }

# Today's date for prefix matching
TODAY=$(date +%Y-%m-%d)

# Source the module under test
source "$REPO_DIR/scripts/lib/check-files.sh"

# =============================================================================
# HELPER: Reset test state between test cases
# =============================================================================
reset_test_state() {
    : > "$NOTIFY_LOG"
    : > "$SENTINEL_LOGS/sentinel.log"
    JANITOR_ENABLED=true
    JANITOR_DATE_PREFIX=true
    JANITOR_DESTINATION="$MOCK_DEST"
    # Restore mock mount
    mount() { echo "/dev/disk4s1 on /Volumes/OPS-mini (apfs, local)"; }
    lsof() { return 1; }
}

# --- Test 1: Sort PDF to docs/ ---
echo ""
echo "  --- Test: sort PDF to docs ---"
reset_test_state
touch "$MOCK_WATCH/report.pdf"
_sort_file "$MOCK_WATCH/report.pdf"
assert_file_exists "$MOCK_DEST/docs/${TODAY}_report.pdf" "PDF sorted to docs/"

# --- Test 2: Sort PNG to images/ ---
echo ""
echo "  --- Test: sort PNG to images ---"
reset_test_state
touch "$MOCK_WATCH/screenshot.png"
_sort_file "$MOCK_WATCH/screenshot.png"
assert_file_exists "$MOCK_DEST/images/${TODAY}_screenshot.png" "PNG sorted to images/"

# --- Test 3: Sort MP4 to video/ ---
echo ""
echo "  --- Test: sort MP4 to video ---"
reset_test_state
touch "$MOCK_WATCH/clip.mp4"
_sort_file "$MOCK_WATCH/clip.mp4"
assert_file_exists "$MOCK_DEST/video/${TODAY}_clip.mp4" "MP4 sorted to video/"

# --- Test 4: Sort ZIP to archives/ ---
echo ""
echo "  --- Test: sort ZIP to archives ---"
reset_test_state
touch "$MOCK_WATCH/backup.zip"
_sort_file "$MOCK_WATCH/backup.zip"
assert_file_exists "$MOCK_DEST/archives/${TODAY}_backup.zip" "ZIP sorted to archives/"

# --- Test 5: Sort DMG to installers/ ---
echo ""
echo "  --- Test: sort DMG to installers ---"
reset_test_state
touch "$MOCK_WATCH/app.dmg"
_sort_file "$MOCK_WATCH/app.dmg"
assert_file_exists "$MOCK_DEST/installers/${TODAY}_app.dmg" "DMG sorted to installers/"

# --- Test 6: Sort unknown ext to other/ ---
echo ""
echo "  --- Test: unknown extension goes to other ---"
reset_test_state
touch "$MOCK_WATCH/mystery.xyz"
_sort_file "$MOCK_WATCH/mystery.xyz"
assert_file_exists "$MOCK_DEST/other/${TODAY}_mystery.xyz" "unknown sorted to other/"

# --- Test 7: _get_category mapping ---
echo ""
echo "  --- Test: category mapping ---"
assert_eq "docs" "$(_get_category "report.pdf")" "pdf → docs"
assert_eq "images" "$(_get_category "photo.jpg")" "jpg → images"
assert_eq "video" "$(_get_category "movie.mkv")" "mkv → video"
assert_eq "audio" "$(_get_category "song.mp3")" "mp3 → audio"
assert_eq "archives" "$(_get_category "files.tar")" "tar → archives"
assert_eq "installers" "$(_get_category "setup.pkg")" "pkg → installers"
assert_eq "data" "$(_get_category "data.csv")" "csv → data"
assert_eq "code" "$(_get_category "script.py")" "py → code"
assert_eq "other" "$(_get_category "file.abc")" "unknown → other"

# --- Test 8: Case insensitive extensions ---
echo ""
echo "  --- Test: case insensitive ---"
assert_eq "images" "$(_get_category "PHOTO.JPG")" "JPG uppercase → images"
assert_eq "docs" "$(_get_category "README.MD")" "MD uppercase → docs"

# --- Test 9: Skip .crdownload ---
echo ""
echo "  --- Test: skip crdownload ---"
touch "$MOCK_WATCH/bigfile.crdownload"
result=0
_should_skip "$MOCK_WATCH/bigfile.crdownload" || result=$?
assert_eq "0" "$result" ".crdownload skipped"

# --- Test 10: Skip .part ---
echo ""
echo "  --- Test: skip .part ---"
touch "$MOCK_WATCH/download.part"
result=0
_should_skip "$MOCK_WATCH/download.part" || result=$?
assert_eq "0" "$result" ".part skipped"

# --- Test 11: Skip .tmp ---
echo ""
echo "  --- Test: skip .tmp ---"
touch "$MOCK_WATCH/temp.tmp"
result=0
_should_skip "$MOCK_WATCH/temp.tmp" || result=$?
assert_eq "0" "$result" ".tmp skipped"

# --- Test 12: Skip hidden files ---
echo ""
echo "  --- Test: skip hidden files ---"
touch "$MOCK_WATCH/.DS_Store"
result=0
_should_skip "$MOCK_WATCH/.DS_Store" || result=$?
assert_eq "0" "$result" "hidden file skipped"

# --- Test 13: Don't skip normal files ---
echo ""
echo "  --- Test: don't skip normal files ---"
touch "$MOCK_WATCH/normal.txt"
result=0
_should_skip "$MOCK_WATCH/normal.txt" || result=1
assert_eq "1" "$result" "normal file not skipped"

# --- Test 14: Collision handling ---
echo ""
echo "  --- Test: collision handling ---"
reset_test_state
mkdir -p "$MOCK_DEST/docs"
touch "$MOCK_DEST/docs/${TODAY}_collision.pdf"
touch "$MOCK_WATCH/collision.pdf"
_sort_file "$MOCK_WATCH/collision.pdf"
assert_file_exists "$MOCK_DEST/docs/${TODAY}_collision-1.pdf" "collision gets -1 suffix"

# --- Test 15: Double collision ---
echo ""
echo "  --- Test: double collision ---"
touch "$MOCK_WATCH/collision.pdf"
_sort_file "$MOCK_WATCH/collision.pdf"
assert_file_exists "$MOCK_DEST/docs/${TODAY}_collision-2.pdf" "double collision gets -2 suffix"

# --- Test 16: Date prefix disabled ---
echo ""
echo "  --- Test: date prefix disabled ---"
reset_test_state
JANITOR_DATE_PREFIX=false
touch "$MOCK_WATCH/nodate.txt"
_sort_file "$MOCK_WATCH/nodate.txt"
assert_file_exists "$MOCK_DEST/docs/nodate.txt" "no date prefix when disabled"
JANITOR_DATE_PREFIX=true

# --- Test 17: Fallback queue when destination unavailable ---
echo ""
echo "  --- Test: fallback queue ---"
reset_test_state
# Make destination unavailable
JANITOR_DESTINATION="/tmp/sentinel-nonexistent-$$"
mount() { echo "/dev/disk1s1 on / (apfs, local)"; }

touch "$MOCK_WATCH/queued.pdf"
_sort_file "$MOCK_WATCH/queued.pdf"
assert_file_exists "$MOCK_QUEUE/docs/${TODAY}_queued.pdf" "file goes to fallback queue"

# Restore
JANITOR_DESTINATION="$MOCK_DEST"
mount() { echo "/dev/disk4s1 on /Volumes/OPS-mini (apfs, local)"; }

# --- Test 18: Disabled janitor does nothing ---
echo ""
echo "  --- Test: disabled janitor ---"
reset_test_state
JANITOR_ENABLED=false
touch "$MOCK_WATCH/should-stay.txt"
check_files
assert_file_exists "$MOCK_WATCH/should-stay.txt" "file stays when janitor disabled"
JANITOR_ENABLED=true

# --- Test 19: check_files processes watch dir ---
echo ""
echo "  --- Test: check_files full run ---"
reset_test_state
touch "$MOCK_WATCH/auto-sort.json"
check_files
assert_file_exists "$MOCK_DEST/data/${TODAY}_auto-sort.json" "check_files sorts automatically"

# --- Test 20: Skip directories ---
echo ""
echo "  --- Test: skip directories ---"
reset_test_state
mkdir -p "$MOCK_WATCH/subdir"
result=0
_should_skip "$MOCK_WATCH/subdir" || result=$?
assert_eq "0" "$result" "directory skipped"

# --- Test 21: Sort WAV to audio/ ---
echo ""
echo "  --- Test: sort WAV to audio ---"
reset_test_state
touch "$MOCK_WATCH/recording.wav"
_sort_file "$MOCK_WATCH/recording.wav"
assert_file_exists "$MOCK_DEST/audio/${TODAY}_recording.wav" "WAV sorted to audio/"

# --- Test 22: Sort CSV to data/ ---
echo ""
echo "  --- Test: sort CSV to data ---"
reset_test_state
touch "$MOCK_WATCH/export.csv"
_sort_file "$MOCK_WATCH/export.csv"
assert_file_exists "$MOCK_DEST/data/${TODAY}_export.csv" "CSV sorted to data/"

# --- Test 23: Sort PY to code/ ---
echo ""
echo "  --- Test: sort PY to code ---"
reset_test_state
touch "$MOCK_WATCH/script.py"
_sort_file "$MOCK_WATCH/script.py"
assert_file_exists "$MOCK_DEST/code/${TODAY}_script.py" "PY sorted to code/"

# --- Test 24: Skip file open by another process ---
echo ""
echo "  --- Test: skip file open by lsof ---"
reset_test_state
lsof() { return 0; }  # mock: file is open
touch "$MOCK_WATCH/locked.pdf"
result=0
_should_skip "$MOCK_WATCH/locked.pdf" || result=1
assert_eq "0" "$result" "file open by lsof is skipped"

# --- Test 25: Always returns 0 ---
echo ""
echo "  --- Test: check_files always returns 0 ---"
reset_test_state
result=0
check_files || result=$?
assert_eq "0" "$result" "check_files returns 0 (informational only)"

# =============================================================================
# CLEANUP
# =============================================================================
rm -rf "$TEST_TMPDIR"

echo ""
test_summary
