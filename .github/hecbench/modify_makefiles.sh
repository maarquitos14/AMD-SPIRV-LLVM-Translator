#!/usr/bin/env bash
# Script: modify_makefiles.sh
# Purpose: Modify HeCBench Makefiles to add HIP architecture support
# Usage: ./modify_makefiles.sh [OPTIONS]
#
# Replaces "hipcc" with "hipcc --offload-arch=$(HIP_ARCH) --rocm-device-lib-path=..."
# This enables multi-architecture builds for AMD GPUs.
#
# Uses HIP_ARCH (not ARCH) to avoid collisions with benchmarks that use ARCH for
# their own purposes (e.g. dp4a-hip uses ARCH = CDNA as a feature flag).

set -euo pipefail

# ==============================================================================
# CONSTANTS & DEFAULTS
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
DRY_RUN=false
VERBOSE=false

# ==============================================================================
# SOURCE COMMON LIBRARY
# ==============================================================================

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh" || {
    echo "ERROR: Failed to load common library" >&2
    exit 1
}

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# REQUIRE ROCM_PATH to be explicitly set (no auto-detection)
if ! require_rocm_path; then
    exit 1
fi

# Try to find HeCBench source (auto-detect is OK for this)
if ! HECBENCH_SRC=$(find_hecbench_src "$SCRIPT_DIR"); then
    show_path_error "HeCBench" "HECBENCH_SRC" "HeCBench source directory" \
        "$SCRIPT_DIR/../HeCBench/src" "$SCRIPT_DIR/../../HeCBench/src"
    exit 1
fi

DEVICE_LIB_PATH="${ROCM_PATH}/lib/llvm/amdgcn/bitcode"

# ==============================================================================
# FUNCTIONS
# ==============================================================================

show_usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Modify HeCBench Makefiles to add HIP architecture support. Replaces 'hipcc'
with 'hipcc --offload-arch=\$(HIP_ARCH) --rocm-device-lib-path=...' to enable
multi-architecture builds.

Options:
    --dry-run       Preview changes without modifying files
    --verbose, -v   Show detailed output
    --help, -h      Show this help message

Environment Variables:
    ROCM_PATH       Path to ROCm installation (auto-detected if not set)
    HECBENCH_SRC    Path to HeCBench source (auto-detected if not set)

Examples:
    # Preview changes
    $SCRIPT_NAME --dry-run

    # Apply modifications
    $SCRIPT_NAME

    # With custom paths
    ROCM_PATH=/opt/rocm HECBENCH_SRC=/path/to/HeCBench/src $SCRIPT_NAME

Output:
    - Modified Makefiles with timestamped backups (.bak.YYYYMMDD-HHMMSS)
    - Removes -save-temps flags to reduce disk clutter
    - Renames HIP_PATH variable to HIP_SRC_PATH (avoids env var conflicts)

Exit Codes:
    0  Success
    1  Configuration or validation error
    2  Modification failed
EOF
}

validate_environment() {
    log_info "Validating environment..."

    # Validate ROCm installation
    if ! validate_dir "$ROCM_PATH" "ROCm installation"; then
        return 1
    fi

    if ! validate_rocm_path "$ROCM_PATH"; then
        log_error "Invalid ROCm installation: missing hipcc or libraries"
        return 1
    fi

    # Validate HeCBench source
    if ! validate_dir "$HECBENCH_SRC" "HeCBench source"; then
        return 1
    fi

    if ! validate_hecbench_src "$HECBENCH_SRC"; then
        log_error "Invalid HeCBench directory: no *-hip directories found"
        return 1
    fi

    # Validate device library path
    if ! validate_dir "$DEVICE_LIB_PATH" "ROCm device library"; then
        log_warn "Device library path not found: $DEVICE_LIB_PATH"
        log_warn "Builds may fail if device libraries are not accessible"
    fi

    log_success "Environment validation passed"
    return 0
}

find_makefiles() {
    log_info "Finding Makefiles in HIP directories..."

    local makefiles=()
    while IFS= read -r -d '' makefile; do
        makefiles+=("$makefile")
    done < <(find "$HECBENCH_SRC" -path "*-hip/*" -name "Makefile" -type f ! -name "*.bak*" -print0 | sort -z)

    if [[ ${#makefiles[@]} -eq 0 ]]; then
        log_error "No Makefiles found in $HECBENCH_SRC"
        return 1
    fi

    log_info "Found ${#makefiles[@]} Makefiles"
    printf '%s\n' "${makefiles[@]}"
    return 0
}

backup_file() {
    local file="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup="${file}.bak.${timestamp}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create backup: $backup"
        return 0
    fi

    if ! cp "$file" "$backup"; then
        log_error "Failed to create backup: $backup"
        return 1
    fi

    log_debug "Created backup: $backup"
    return 0
}

is_already_modified() {
    local makefile="$1"
    grep -q "hipcc --offload-arch" "$makefile"
}

uses_hipcc() {
    local makefile="$1"
    grep -q "\bhipcc\b" "$makefile"
}

# Inject $(EXTRA_CFLAGS) into the first matching assignment of each compile-flag
# variable that exists in the Makefile (CFLAGS, CXXFLAGS, HIPCC_FLAGS, NVCC_FLAGS).
# This lets bench.sh pass per-arch flags via `make EXTRA_CFLAGS=...` for the small
# subset of Makefiles whose CFLAGS line lacks the conventional `$(EXTRA_CFLAGS)`
# prefix that most HeCBench Makefiles already have.
#
# Idempotent: returns early if any $(EXTRA_CFLAGS)/${EXTRA_CFLAGS} reference
# is already present in the file. Patches multiple flag vars per call so a
# Makefile that uses both CFLAGS and CXXFLAGS (e.g. halo-finder-hip) gets the
# hook in both rules without needing a follow-up run.
inject_extra_cflags() {
    local makefile="$1"
    if grep -qE '\$\(EXTRA_CFLAGS\)|\$\{EXTRA_CFLAGS\}' "$makefile"; then
        return 0
    fi
    local patched=""
    local var
    for var in CFLAGS CXXFLAGS HIPCC_FLAGS NVCC_FLAGS; do
        if grep -qE "^[[:space:]]*${var}[[:space:]]*[:?+]?=" "$makefile"; then
            sed -i -E "0,/^([[:space:]]*${var}[[:space:]]*[:?+]?=[[:space:]]*)/{s//\1\$(EXTRA_CFLAGS) /}" "$makefile"
            patched="${patched}${var} "
        fi
    done
    if [[ -n "$patched" ]]; then
        log_debug "Injected \$(EXTRA_CFLAGS) into: ${makefile#$HECBENCH_SRC/} (vars: ${patched% })"
    fi
}

# Inject $(EXTRA_HIPCCFLAGS) into every rewritten hipcc invocation so bench.sh
# can pass hipcc-specific flags (e.g. -no-use-spirv-backend) without polluting
# g++ lines. Targets the `hipcc --offload-arch` pattern produced by the rewrite
# step below (or a previous run). Idempotent.
inject_extra_hipccflags() {
    local makefile="$1"
    if grep -qE '\$\(EXTRA_HIPCCFLAGS\)|\$\{EXTRA_HIPCCFLAGS\}' "$makefile"; then
        return 0
    fi
    if ! grep -q 'hipcc --offload-arch' "$makefile"; then
        return 0
    fi
    sed -i 's#\(hipcc --offload-arch=[^ ]*\)\(.*--rocm-device-lib-path=[^ ]*\)#\1\2 $(EXTRA_HIPCCFLAGS)#g' "$makefile"
    log_debug "Injected \$(EXTRA_HIPCCFLAGS) into hipcc lines: ${makefile#$HECBENCH_SRC/}"
}

modify_makefile() {
    local makefile="$1"
    local rel_path="${makefile#$HECBENCH_SRC/}"

    # Check if uses hipcc — skip wrapper / pytorch Makefiles entirely.
    if ! uses_hipcc "$makefile"; then
        log_debug "Doesn't use hipcc: $rel_path"
        return 3  # Special return code for "doesn't use hipcc"
    fi

    # Inject $(EXTRA_CFLAGS) hook independently of the hipcc-rewrite step so
    # already-rewritten Makefiles still gain it on re-run. Safe / idempotent.
    if [[ "$DRY_RUN" != "true" ]]; then
        inject_extra_cflags "$makefile"
        inject_extra_hipccflags "$makefile"
    fi

    # Check if already modified — skip the hipcc rewrite if so (the
    # inject_extra_cflags above already ran for both fresh and previously-
    # modified Makefiles).
    if is_already_modified "$makefile"; then
        log_debug "Already modified: $rel_path"
        return 2  # Special return code for "already modified"
    fi

    # Create backup
    if ! backup_file "$makefile"; then
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would modify: $rel_path"
        return 0
    fi

    # Add HIP_ARCH and HIPCC_BIN_DIR variables if not present
    if ! grep -q "^HIP_ARCH.*=" "$makefile"; then
        {
            echo "# User-configurable architecture (default: gfx906)"
            echo "HIP_ARCH ?= gfx906"
            echo ""
            echo "# HIP compiler location"
            echo "HIPCC_BIN_DIR ?= $ROCM_PATH/bin"
            echo ""
            cat "$makefile"
        } > "${makefile}.tmp" && mv "${makefile}.tmp" "$makefile"
    elif ! grep -q "^HIPCC_BIN_DIR" "$makefile"; then
        # Use printf to avoid shell expansion issues with sed
        {
            grep -B1000 "^HIP_ARCH.*=" "$makefile" | head -n -1
            grep "^HIP_ARCH.*=" "$makefile"
            echo ""
            echo "# HIP compiler location"
            echo "HIPCC_BIN_DIR ?= $ROCM_PATH/bin"
            grep -A1000 "^HIP_ARCH.*=" "$makefile" | tail -n +2
        } > "${makefile}.tmp" && mv "${makefile}.tmp" "$makefile"
    fi

    # Escape device lib path for sed
    local escaped_path="${DEVICE_LIB_PATH//\//\\/}"

    # Replace hipcc with $(HIPCC_BIN_DIR)/hipcc + flags
    # Only replace standalone "hipcc" not already prefixed with path/variable
    sed -i "s#\(^\|[^/})]\)\bhipcc\b#\1\$(HIPCC_BIN_DIR)/hipcc --offload-arch=\$(HIP_ARCH) --rocm-device-lib-path=${escaped_path} \$(EXTRA_HIPCCFLAGS)#g" "$makefile"

    # After the rewrite above, $(CC) / $(CXX) / $(HIPCC) typically expand to a
    # multi-word string. Any nested-make recipe that passes `<VAR>=$(CC)`
    # unquoted would word-split, corrupting the inner build. Re-quote such
    # assignments. Restricted to recipe lines (start with TAB) so top-level
    # Makefile assignments are not altered.
    local TAB
    TAB=$'\t'
    sed -i -E "s#^(${TAB}.*)([A-Z][A-Z_]+=)\\\$\\((CC|CXX|HIPCC)\\)#\\1\\2\"\\\$(\\3)\"#g" "$makefile"

    # Remove -save-temps flag
    sed -i 's/-save-temps//g' "$makefile"

    # Fix HIP_PATH variable name conflict
    local hip_path_renamed=false
    if grep -q "^HIP_PATH\s*=" "$makefile"; then
        sed -i -e 's/^\(HIP_PATH\s*=\)/HIP_SRC_PATH =/' \
               -e 's/\$(\(HIP_PATH\))/$(HIP_SRC_PATH)/g' \
               -e 's/\${\(HIP_PATH\)}/\${HIP_SRC_PATH}/g' "$makefile"
        hip_path_renamed=true
    fi

    # Log success with details
    if [[ "$hip_path_renamed" == "true" ]]; then
        log_success "Modified: $rel_path (renamed HIP_PATH → HIP_SRC_PATH)"
    else
        log_success "Modified: $rel_path"
    fi

    return 0
}

process_makefiles() {
    local -a makefiles

    # Get array of Makefiles
    mapfile -t makefiles < <(find_makefiles)
    if [[ ${#makefiles[@]} -eq 0 ]]; then
        return 1
    fi

    log_info "Processing ${#makefiles[@]} Makefiles..."
    echo ""

    local modified_count=0
    local skipped_already=0
    local skipped_no_hipcc=0
    local failed_count=0

    for makefile in "${makefiles[@]}"; do
        local rel_path="${makefile#$HECBENCH_SRC/}"

        modify_makefile "$makefile"
        local result=$?

        case $result in
            0)
                modified_count=$((modified_count + 1))
                ;;
            2)
                log_info "Already modified: $rel_path"
                skipped_already=$((skipped_already + 1))
                ;;
            3)
                log_info "No hipcc usage: $rel_path"
                skipped_no_hipcc=$((skipped_no_hipcc + 1))
                ;;
            *)
                log_error "Failed to modify: $rel_path"
                failed_count=$((failed_count + 1))
                ;;
        esac
    done

    echo ""
    log_info "========================================"
    log_info "Modification Summary"
    log_info "========================================"
    log_info "Total Makefiles found: ${#makefiles[@]}"
    log_success "Modified: $modified_count"
    log_info "Already modified: $skipped_already"
    log_info "No hipcc usage: $skipped_no_hipcc"

    if [[ $failed_count -gt 0 ]]; then
        log_error "Failed: $failed_count"
    fi

    # Show sample verification
    if [[ $modified_count -gt 0 ]] && [[ "$DRY_RUN" == "false" ]]; then
        echo ""
        log_info "Sample verification:"
        for makefile in "${makefiles[@]}"; do
            if compgen -G "${makefile}.bak.*" >/dev/null; then
                local backup
                backup=$(ls -t "${makefile}.bak."* | head -1)
                local rel_path="${makefile#$HECBENCH_SRC/}"
                echo "  File: $rel_path"
                echo "  Before: $(grep -m1 'hipcc' "$backup" || echo "(none)")"
                echo "  After:  $(grep -m1 'hipcc' "$makefile" || echo "(none)")"
                echo ""
                break
            fi
        done
    fi

    if [[ $failed_count -gt 0 ]]; then
        return 2
    fi

    return 0
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    # Parse arguments
    local remaining_args
    remaining_args=$(parse_common_flags "$SCRIPT_NAME" "$@")

    # No script-specific arguments expected
    if [[ -n "$remaining_args" ]]; then
        log_error "Unknown arguments: $remaining_args"
        show_usage
        exit 1
    fi

    log_info "========================================"
    log_info "HeCBench Makefile Modifier"
    log_info "========================================"
    log_info "ROCm Path: $ROCM_PATH"
    log_info "HeCBench Source: $HECBENCH_SRC"
    log_info "Device Library: $DEVICE_LIB_PATH"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY-RUN MODE: No files will be modified"
    fi
    echo ""

    # Validate environment
    if ! validate_environment; then
        exit 1
    fi
    echo ""

    # Process Makefiles
    if ! process_makefiles; then
        exit 2
    fi

    echo ""
    log_success "Makefile modification complete!"
    echo ""
}

main "$@"
