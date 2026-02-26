#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# check-files.sh — File Janitor (auto-sort to OPS-mini)
# ═══════════════════════════════════════════════════════════════
# Sourced by sentinel-daemon.sh. Do not execute directly.
#
# Scans watch dirs, sorts files by extension to OPS-mini.
# Falls back to local queue when OPS-mini disconnected.
# ═══════════════════════════════════════════════════════════════

# =============================================================================
# GUARD: Prevent direct execution
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: check-files.sh should be sourced, not executed directly."
    echo "Usage: source check-files.sh"
    exit 1
fi

# =============================================================================
# EXTENSION → CATEGORY MAPPING
# =============================================================================

# Map file extension to category
_get_category() {
    local ext="${1##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    case "$ext" in
        pdf|doc|docx|txt|md|rtf|pages)          echo "docs" ;;
        png|jpg|jpeg|gif|webp|heic|svg|ico|tiff) echo "images" ;;
        mp4|mov|mkv|avi|webm)                    echo "video" ;;
        mp3|wav|flac|m4a|aac|ogg)                echo "audio" ;;
        zip|tar|gz|rar|7z|bz2)                   echo "archives" ;;
        dmg|pkg)                                  echo "installers" ;;
        csv|xlsx|json|xml|yaml|yml|sql)           echo "data" ;;
        py|js|ts|sh|rb|go|rs|swift)              echo "code" ;;
        *)                                        echo "other" ;;
    esac
}

# =============================================================================
# SKIP LOGIC
# =============================================================================

# Check if a file should be skipped
# Returns 0 = skip, 1 = don't skip (for if-statement readability)
_should_skip() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    # Skip directories
    if [[ -d "$filepath" ]]; then
        return 0
    fi

    # Skip hidden files
    if [[ "$filename" == .* ]]; then
        return 0
    fi

    # Skip ignore patterns (glob matching)
    local saved_ifs="$IFS"
    local IFS=','
    for pattern in $JANITOR_IGNORE; do
        pattern=$(echo "$pattern" | xargs)
        # Simple glob match using case
        case "$filename" in
            $pattern) IFS="$saved_ifs"; return 0 ;;
        esac
    done
    IFS="$saved_ifs"

    # Skip files open by another process
    if lsof "$filepath" >/dev/null 2>&1; then
        return 0
    fi

    return 1  # don't skip
}

# =============================================================================
# DESTINATION PATH GENERATION
# =============================================================================

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

# =============================================================================
# FILE SORTING
# =============================================================================

# Sort a single file to the appropriate category
_sort_file() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    # Determine destination base: use primary if available, fallback otherwise
    local dest_base
    if [[ -d "$JANITOR_DESTINATION" ]] || mount 2>/dev/null | grep -q "OPS-mini"; then
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

# =============================================================================
# FALLBACK QUEUE FLUSH
# =============================================================================

# Flush fallback queue to OPS-mini when it reconnects
_flush_queue() {
    if [[ ! -d "$JANITOR_FALLBACK_QUEUE" ]]; then
        return 0
    fi

    local queue_count
    queue_count=$(find "$JANITOR_FALLBACK_QUEUE" -type f 2>/dev/null | wc -l | tr -d ' ')

    if (( queue_count == 0 )); then
        return 0
    fi

    if [[ ! -d "$JANITOR_DESTINATION" ]]; then
        return 0  # OPS-mini still not available
    fi

    log_info "Flushing $queue_count queued files to OPS-mini"

    find "$JANITOR_FALLBACK_QUEUE" -type f 2>/dev/null | while IFS= read -r filepath; do
        local filename
        filename=$(basename "$filepath")
        local category
        category=$(_get_category "$filename")
        local dest_dir="${JANITOR_DESTINATION}/${category}"
        mkdir -p "$dest_dir"
        mv "$filepath" "$dest_dir/" 2>/dev/null || true
    done

    # Clean up empty category dirs in queue
    find "$JANITOR_FALLBACK_QUEUE" -type d -empty -delete 2>/dev/null || true

    sentinel_notify "Sentinel" "Flushed $queue_count queued files to OPS-mini" "Glass"
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# Main file janitor — called by sentinel-daemon.sh
check_files() {
    if [[ "$JANITOR_ENABLED" != "true" ]]; then
        return 0
    fi

    local sorted_count=0

    # Try to flush queue first (if OPS-mini just reconnected)
    _flush_queue

    local saved_ifs="$IFS"
    local IFS=','
    for watch_dir in $JANITOR_WATCH_DIRS; do
        watch_dir=$(echo "$watch_dir" | xargs)
        [[ -z "$watch_dir" ]] && continue
        [[ ! -d "$watch_dir" ]] && continue

        # Process files in watch dir (glob avoids subshell so counter works)
        for filepath in "$watch_dir"/*; do
            [[ -e "$filepath" ]] || continue  # handle empty glob
            [[ -f "$filepath" ]] || continue
            local filename
            filename=$(basename "$filepath")

            if _should_skip "$filepath"; then
                continue
            fi

            if _sort_file "$filepath"; then
                sorted_count=$((sorted_count + 1))
            fi
        done
    done
    IFS="$saved_ifs"

    if (( sorted_count > 0 )); then
        log_info "File janitor: sorted $sorted_count file(s)"
    fi

    return 0
}
