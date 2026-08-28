#!/usr/bin/env bash
# Rewrite HeCBench HIP Makefiles so bench.sh can build them against the staged
# ROCm/LLVM toolchain. Replaces bare "hipcc" with
#   $(HIPCC_BIN_DIR)/hipcc --offload-arch=$(HIP_ARCH) --rocm-device-lib-path=...
# and injects a $(EXTRA_CFLAGS) hook so per-benchmark flags can be passed via
# `make EXTRA_CFLAGS=...`.
#
# Uses HIP_ARCH (not ARCH) to avoid collisions with benchmarks that use ARCH for
# their own purposes (e.g. dp4a-hip uses ARCH = CDNA as a feature flag).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh" || {
    echo "ERROR: Failed to load common library" >&2
    exit 1
}

require_rocm_path || exit 1

HECBENCH_SRC=$(find_hecbench_src "$SCRIPT_DIR") || {
    log_error "Cannot find HeCBench src directory"
    exit 1
}

DEVICE_LIB_PATH="${ROCM_PATH}/amdgcn/bitcode"

# ==============================================================================
# FUNCTIONS
# ==============================================================================

find_makefiles() {
    local makefiles=()
    while IFS= read -r -d '' makefile; do
        makefiles+=("$makefile")
    done < <(find "$HECBENCH_SRC" -path "*-hip/*" -name "Makefile" -type f ! -name "*.bak*" -print0 | sort -z)

    if [[ ${#makefiles[@]} -eq 0 ]]; then
        log_error "No Makefiles found in $HECBENCH_SRC"
        return 1
    fi

    printf '%s\n' "${makefiles[@]}"
    return 0
}

uses_hipcc() {
    grep -q "\bhipcc\b" "$1"
}

# Prepend $(EXTRA_CFLAGS) to the first CFLAGS/CXXFLAGS/HIPCC_FLAGS/NVCC_FLAGS
# assignment so `make EXTRA_CFLAGS=...` reaches the few Makefiles lacking the
# conventional hook. Skips Makefiles that already have it.
inject_extra_cflags() {
    local makefile="$1"
    if grep -qE '\$\(EXTRA_CFLAGS\)|\$\{EXTRA_CFLAGS\}' "$makefile"; then
        return 0
    fi
    local var
    for var in CFLAGS CXXFLAGS HIPCC_FLAGS NVCC_FLAGS; do
        if grep -qE "^[[:space:]]*${var}[[:space:]]*[:?+]?=" "$makefile"; then
            sed -i -E "0,/^([[:space:]]*${var}[[:space:]]*[:?+]?=[[:space:]]*)/{s//\1\$(EXTRA_CFLAGS) /}" "$makefile"
        fi
    done
}

# Returns: 0 modified, 3 no hipcc usage.
modify_makefile() {
    local makefile="$1"
    local rel_path="${makefile#$HECBENCH_SRC/}"

    # Skip wrapper / pytorch Makefiles that don't compile with hipcc.
    if ! uses_hipcc "$makefile"; then
        return 3
    fi

    # Inject the $(EXTRA_CFLAGS) hook so bench.sh can pass per-arch flags.
    inject_extra_cflags "$makefile"

    # Add HIP_ARCH and HIPCC_BIN_DIR variables if not present.
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
        {
            grep -B1000 "^HIP_ARCH.*=" "$makefile" | head -n -1
            grep "^HIP_ARCH.*=" "$makefile"
            echo ""
            echo "# HIP compiler location"
            echo "HIPCC_BIN_DIR ?= $ROCM_PATH/bin"
            grep -A1000 "^HIP_ARCH.*=" "$makefile" | tail -n +2
        } > "${makefile}.tmp" && mv "${makefile}.tmp" "$makefile"
    fi

    # Escape device lib path for sed.
    local escaped_path="${DEVICE_LIB_PATH//\//\\/}"

    # Replace standalone "hipcc" (not already prefixed with a path/variable) with
    # $(HIPCC_BIN_DIR)/hipcc + offload-arch + device-lib-path.
    sed -i "s#\(^\|[^/})]\)\bhipcc\b#\1\$(HIPCC_BIN_DIR)/hipcc --offload-arch=\$(HIP_ARCH) --rocm-device-lib-path=${escaped_path}#g" "$makefile"

    # After the rewrite $(CC)/$(CXX)/$(HIPCC) expand to multi-word strings; a
    # nested-make recipe passing `<VAR>=$(CC)` unquoted would word-split. Re-quote,
    # only on recipe lines (start with TAB) so top-level assignments are untouched.
    local TAB
    TAB=$'\t'
    sed -i -E "s#^(${TAB}.*)([A-Z][A-Z_]+=)\\\$\\((CC|CXX|HIPCC)\\)#\\1\\2\"\\\$(\\3)\"#g" "$makefile"

    # Remove -save-temps flag (disk clutter).
    sed -i 's/-save-temps//g' "$makefile"

    # Rename HIP_PATH to avoid clobbering the environment variable of the same name.
    if grep -q "^HIP_PATH\s*=" "$makefile"; then
        sed -i -e 's/^\(HIP_PATH\s*=\)/HIP_SRC_PATH =/' \
               -e 's/\$(\(HIP_PATH\))/$(HIP_SRC_PATH)/g' \
               -e 's/\${\(HIP_PATH\)}/\${HIP_SRC_PATH}/g' "$makefile"
        log_success "Modified: $rel_path (renamed HIP_PATH → HIP_SRC_PATH)"
    else
        log_success "Modified: $rel_path"
    fi

    return 0
}

process_makefiles() {
    local -a makefiles
    mapfile -t makefiles < <(find_makefiles)
    if [[ ${#makefiles[@]} -eq 0 ]]; then
        return 1
    fi

    log_info "Processing ${#makefiles[@]} Makefiles..."
    echo ""

    local modified=0 no_hipcc=0 failed=0
    for makefile in "${makefiles[@]}"; do
        local rel_path="${makefile#$HECBENCH_SRC/}"
        modify_makefile "$makefile"
        case $? in
            0) modified=$((modified + 1)) ;;
            3) no_hipcc=$((no_hipcc + 1)) ;;
            *) log_error "Failed to modify: $rel_path"; failed=$((failed + 1)) ;;
        esac
    done

    echo ""
    log_info "========================================"
    log_info "Total Makefiles: ${#makefiles[@]}"
    log_success "Modified: $modified"
    log_info "No hipcc usage: $no_hipcc"
    [[ $failed -gt 0 ]] && { log_error "Failed: $failed"; return 2; }
    return 0
}

# ==============================================================================
# MAIN
# ==============================================================================

log_info "========================================"
log_info "HeCBench Makefile Modifier"
log_info "========================================"
log_info "ROCm Path:       $ROCM_PATH"
log_info "HeCBench Source: $HECBENCH_SRC"
log_info "Device Library:  $DEVICE_LIB_PATH"
[[ -d "$DEVICE_LIB_PATH" ]] || log_warn "Device library path not found: $DEVICE_LIB_PATH (builds may fail)"
echo ""

process_makefiles || exit $?

echo ""
log_success "Makefile modification complete!"
