#!/bin/bash
set -euo pipefail

# Artifact Consolidation Script
# Purpose: Consolidate multiple artifact files into single ARTIFACTS.log per directory
# Invariants: No data loss, preserve order, append-only, delete only after verification

ARTIFACT_FILENAME="ARTIFACTS.log"

consolidate_directory() {
    local dir="$1"
    local artifacts_log="${dir}/${ARTIFACT_FILENAME}"

    echo "Processing: $dir"

    # Find all artifact files (exclude ARTIFACTS.log itself)
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$dir" -maxdepth 1 -type f \( -name "*.txt" -o -name "*.log" -o -name "*.out" -o -name "*.yaml" -o -name "*.yml" \) ! -name "$ARTIFACT_FILENAME" -print0 | sort -z)

    if [ ${#files[@]} -eq 0 ]; then
        echo "  No artifacts to consolidate"
        return 0
    fi

    echo "  Found ${#files[@]} artifact files"

    # Create or append to ARTIFACTS.log
    local temp_file="${artifacts_log}.tmp"

    # If ARTIFACTS.log exists, start from its content
    if [ -f "$artifacts_log" ]; then
        cp "$artifacts_log" "$temp_file"
    else
        touch "$temp_file"
    fi

    # Track line counts for verification
    local original_lines=0
    if [ -f "$artifacts_log" ]; then
        original_lines=$(wc -l < "$artifacts_log" || echo 0)
    fi

    local added_lines=0
    local marker_lines=0

    # Append each file with markers
    for file in "${files[@]}"; do
        local basename=$(basename "$file")
        local file_lines=$(wc -l < "$file" || echo 0)

        echo "===== BEGIN SOURCE: $basename =====" >> "$temp_file"
        cat "$file" >> "$temp_file"
        echo "===== END SOURCE: $basename =====" >> "$temp_file"
        echo "" >> "$temp_file"  # Blank line separator

        added_lines=$((added_lines + file_lines))
        marker_lines=$((marker_lines + 3))  # BEGIN + END + blank line

        echo "    Appended: $basename ($file_lines lines)"
    done

    # Verification
    local final_lines=$(wc -l < "$temp_file")
    local expected_lines=$((original_lines + added_lines + marker_lines))

    if [ "$final_lines" -ne "$expected_lines" ]; then
        echo "  ERROR: Line count mismatch!"
        echo "    Original: $original_lines"
        echo "    Added: $added_lines"
        echo "    Markers: $marker_lines"
        echo "    Expected total: $expected_lines"
        echo "    Actual: $final_lines"
        rm "$temp_file"
        return 1
    fi

    # Move temp file to final location
    mv "$temp_file" "$artifacts_log"

    echo "  ✓ Consolidated into $ARTIFACT_FILENAME"
    echo "  ✓ Verification passed (${final_lines} lines)"

    # Delete original files
    for file in "${files[@]}"; do
        rm "$file"
    done

    echo "  ✓ Deleted ${#files[@]} original artifact files"

    return 0
}

# Main execution
if [ $# -eq 0 ]; then
    echo "Usage: $0 <directory> [<directory> ...]"
    exit 2
fi

for dir in "$@"; do
    if [ ! -d "$dir" ]; then
        echo "Warning: $dir is not a directory, skipping"
        continue
    fi

    consolidate_directory "$dir"
    echo ""
done

echo "Consolidation complete"
