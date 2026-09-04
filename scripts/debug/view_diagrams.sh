#!/usr/bin/env bash
set -euo pipefail

# ThreadForge Diagram Viewer Helper
# Helps view and convert Mermaid diagrams

# Resolve repo root more robustly
if [[ -n "${REPO_ROOT:-}" && -d "${REPO_ROOT:-}" ]]; then
    # Use provided REPO_ROOT
    true
else
    # Try to find repo root by looking for common markers
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    candidate="$script_dir/../.."
    if [[ -f "$candidate/README.md" && -d "$candidate/deploy" ]]; then
        REPO_ROOT="$(cd "$candidate" && pwd)"
    else
        # Fallback: try current working directory if it looks like repo root
        if [[ -f "./README.md" && -d "./deploy" ]]; then
            REPO_ROOT="$(pwd)"
        else
            # Last resort
            REPO_ROOT="$(cd "$script_dir/../.." && pwd)"
        fi
    fi
fi

show_usage() {
    cat << EOF
ThreadForge Diagram Viewer

Usage: $0 <command> [options]

Commands:
    list        List all available Mermaid diagrams
    view <name> View a specific diagram (opens in browser)
    convert     Convert diagrams to PNG/SVG (requires mmdc)
    latest      Show diagrams from latest Mermaid run

Examples:
    $0 list
    $0 view master_system
    $0 convert
    $0 latest

Requirements for conversion:
    npm install -g @mermaid-js/mermaid-cli

Diagram names:
    - master_system: Complete ThreadForge architecture
    - system_topology: Current system topology
    - identity_flow: SPIRE to workload identity path
    - forgesec_flow: ForgeSec evaluation flow
EOF
}

find_latest_audit() {
    if [[ -f "$REPO_ROOT/artifacts/mermaid/LATEST" ]]; then
        cat "$REPO_ROOT/artifacts/mermaid/LATEST"
        return
    fi
    find "$REPO_ROOT/artifacts/mermaid" -maxdepth 1 -type d -name "20*" | sort | tail -1 2>/dev/null || echo ""
}

list_diagrams() {
    local audit_dir="${1:-$(find_latest_audit)}"

    if [[ -z "$audit_dir" || ! -d "$audit_dir" ]]; then
        echo "No Mermaid directory found. Run 'make mermaids' first."
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi

    echo "Mermaid diagrams in: $audit_dir"
    echo

    local found_diagrams=false
    for diagram in "$audit_dir"/*.mmd; do
        if [[ -f "$diagram" ]]; then
            local name=$(basename "$diagram" .mmd)
            local lines=$(wc -l < "$diagram")
            echo "  $name.mmd ($lines lines)"
            found_diagrams=true
        fi
    done

    if [[ "$found_diagrams" == false ]]; then
        echo "  No .mmd files found"
    fi
}

view_diagram() {
    local name="$1"
    local audit_dir="${2:-$(find_latest_audit)}"
    local diagram_file="$audit_dir/${name}.mmd"

    if [[ ! -f "$diagram_file" ]]; then
        echo "Diagram '$name' not found in $audit_dir"
        echo "Available diagrams:"
        list_diagrams "$audit_dir"
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi

    echo "Opening $diagram_file..."

    # Try to open with VS Code if available
    if command -v code >/dev/null 2>&1; then
        code "$diagram_file"
    elif command -v open >/dev/null 2>&1; then
        # On macOS, try to open with default app
        open "$diagram_file"
    else
        echo "File: $diagram_file"
        echo "Contents:"
        echo "========"
        cat "$diagram_file"
    fi
}

convert_diagrams() {
    local audit_dir="${1:-$(find_latest_audit)}"

    if ! command -v mmdc >/dev/null 2>&1; then
        echo "mmdc (Mermaid CLI) not found."
        echo "Install with: npm install -g @mermaid-js/mermaid-cli"
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi

    echo "Converting diagrams in: $audit_dir"

    for diagram in "$audit_dir"/*.mmd; do
        if [[ -f "$diagram" ]]; then
            local name=$(basename "$diagram" .mmd)
            echo "Converting $name.mmd to PNG..."
            mmdc -i "$diagram" -o "$audit_dir/${name}.png" -t dark -b transparent
            echo "Converting $name.mmd to SVG..."
            mmdc -i "$diagram" -o "$audit_dir/${name}.svg" -t dark -b transparent
        fi
    done

    echo "Conversion complete. Files created:"
    ls -la "$audit_dir"/*.{png,svg} 2>/dev/null || echo "No converted files found"
}

main() {
    case "${1:-}" in
        list)
            list_diagrams "${2:-}"
            ;;
        view)
            if [[ -z "${2:-}" ]]; then
                echo "Error: Diagram name required"
                show_usage
                echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
            fi
            view_diagram "$2" "${3:-}"
            ;;
        convert)
            convert_diagrams "${2:-}"
            ;;
        latest)
            local latest_dir=$(find_latest_audit)
            if [[ -n "$latest_dir" ]]; then
                echo "Latest Mermaid run: $latest_dir"
                list_diagrams "$latest_dir"
            else
                echo "No Mermaid directories found"
            fi
            ;;
        *)
            show_usage
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
