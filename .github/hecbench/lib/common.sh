#!/usr/bin/env bash
# Common library for production-ready HeCBench scripts
# Provides shared logging, validation, and utility functions

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

# Colors for output (disabled if NO_COLOR is set or not a terminal)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly BLUE=$'\033[0;34m'
    readonly NC=$'\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly NC=''
fi

log_info() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*" >&2
    fi
}

# ==============================================================================
# ENVIRONMENT VARIABLE VALIDATION
# ==============================================================================

# Require ROCM_PATH to be explicitly set
require_rocm_path() {
    if [[ -z "${ROCM_PATH:-}" ]]; then
        log_error "ROCM_PATH environment variable is not set"
        echo ""
        echo "Please set ROCM_PATH before running this script:"
        echo "  export ROCM_PATH=/path/to/TheRock-dist"
        echo "  # or"
        echo "  export ROCM_PATH=/opt/rocm"
        echo ""
        echo "Then run: $SCRIPT_NAME"
        return 1
    fi

    # Strip trailing slashes to prevent double slashes in paths
    ROCM_PATH="${ROCM_PATH%/}"

    # Validate the path
    if ! validate_rocm_path "$ROCM_PATH"; then
        log_error "ROCM_PATH is set but invalid: $ROCM_PATH"
        log_error "ROCm installation must contain:"
        log_error "  - bin/hipcc (HIP compiler)"
        log_error "  - lib/ (runtime libraries)"
        return 1
    fi

    log_success "Using ROCM_PATH: $ROCM_PATH"
    return 0
}

# ==============================================================================
# VALIDATION FUNCTIONS
# ==============================================================================

# Check if a command exists
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd"
        return 1
    fi
    log_debug "Found command: $cmd"
    return 0
}

# Validate directory exists and is readable
validate_dir() {
    local dir="$1"
    local description="${2:-Directory}"

    if [[ ! -d "$dir" ]]; then
        log_error "$description not found: $dir"
        return 1
    fi

    if [[ ! -r "$dir" ]]; then
        log_error "$description not readable: $dir"
        return 1
    fi

    log_debug "Validated directory: $dir"
    return 0
}

# Validate file exists and is readable
validate_file() {
    local file="$1"
    local description="${2:-File}"

    if [[ ! -f "$file" ]]; then
        log_error "$description not found: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        log_error "$description not readable: $file"
        return 1
    fi

    log_debug "Validated file: $file"
    return 0
}

# ==============================================================================
# PATH DETECTION FUNCTIONS
# ==============================================================================

# Find ROCm installation
find_rocm() {
    # Try environment variable first
    if [[ -n "${ROCM_PATH:-}" ]]; then
        if validate_rocm_path "$ROCM_PATH"; then
            echo "$ROCM_PATH"
            return 0
        else
            log_warn "ROCM_PATH is set but invalid: $ROCM_PATH"
        fi
    fi

    # Try common installation locations
    local common_paths=(
        "/opt/rocm"
        "$HOME/rocm"
        "/usr/local/rocm"
    )

    for path in "${common_paths[@]}"; do
        if validate_rocm_path "$path"; then
            log_debug "Found ROCm at: $path"
            echo "$path"
            return 0
        fi
    done

    return 1
}

# Validate ROCm installation is complete
validate_rocm_path() {
    local path="$1"

    [[ -d "$path" ]] || return 1
    [[ -x "$path/bin/hipcc" ]] || return 1
    [[ -d "$path/lib" ]] || return 1

    return 0
}

# Find HeCBench source directory
find_hecbench_src() {
    local script_dir="$1"

    # Try environment variable first
    if [[ -n "${HECBENCH_SRC:-}" ]]; then
        if validate_hecbench_src "$HECBENCH_SRC"; then
            echo "$HECBENCH_SRC"
            return 0
        else
            log_warn "HECBENCH_SRC is set but invalid: $HECBENCH_SRC"
        fi
    fi

    # Try relative to script directory
    local relative_paths=(
        "$script_dir/../HeCBench/src"
        "$script_dir/../../HeCBench/src"
        "$script_dir/HeCBench/src"
    )

    for path in "${relative_paths[@]}"; do
        local abs_path
        abs_path=$(cd "$path" 2>/dev/null && pwd)
        if [[ -n "$abs_path" ]] && validate_hecbench_src "$abs_path"; then
            log_debug "Found HeCBench source at: $abs_path"
            echo "$abs_path"
            return 0
        fi
    done

    return 1
}

# Validate HeCBench source directory
validate_hecbench_src() {
    local path="$1"

    [[ -d "$path" ]] || return 1

    # Check for characteristic HeCBench structure (HIP directories)
    # Use a subshell to avoid pipefail issues with grep -q
    local hip_dirs
    hip_dirs=$(find "$path" -maxdepth 2 -name "*-hip" -type d 2>/dev/null | head -1)
    [[ -n "$hip_dirs" ]]
}

# Find MPI installation
find_mpi() {
    # Try environment variable first
    if [[ -n "${MPI_PATH:-}" ]]; then
        if validate_mpi_path "$MPI_PATH"; then
            echo "$MPI_PATH"
            return 0
        else
            log_warn "MPI_PATH is set but invalid: $MPI_PATH"
        fi
    fi

    # Try common installation locations
    local common_paths=(
        "/usr/lib/x86_64-linux-gnu/openmpi"
        "/opt/openmpi"
        "/usr/local/openmpi"
        "/opt/mpi"
    )

    for path in "${common_paths[@]}"; do
        if validate_mpi_path "$path"; then
            log_debug "Found MPI at: $path"
            echo "$path"
            return 0
        fi
    done

    return 1
}

# Validate MPI installation is complete
validate_mpi_path() {
    local path="$1"

    [[ -d "$path" ]] || return 1
    [[ -d "$path/include" ]] || return 1
    [[ -d "$path/lib" ]] || return 1

    # Check for mpi.h header
    [[ -f "$path/include/mpi.h" ]] || return 1

    return 0
}

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

# Execute command with dry-run support
execute_command() {
    local description="$1"
    shift

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] $description: $*"
        return 0
    fi

    log_debug "Executing: $*"
    "$@"
}

# Retry a command with exponential backoff
retry_command() {
    local max_attempts="$1"
    local initial_delay="$2"
    shift 2

    local attempt=1
    local delay="$initial_delay"

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "Command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        fi

        ((attempt++))
    done

    log_error "Command failed after $max_attempts attempts: $*"
    return 1
}

# Show error and help message for missing path
show_path_error() {
    local path_name="$1"
    local env_var="$2"
    local description="$3"
    shift 3
    local required_contents=("$@")

    cat >&2 <<EOF

${RED}ERROR: $description not found.${NC}

Please set the $env_var environment variable:
    export $env_var=/path/to/$path_name

Or install to a standard location:
EOF

    for location in "${required_contents[@]}"; do
        echo "    $location" >&2
    done

    cat >&2 <<EOF

$description must contain:
EOF

    case "$env_var" in
        ROCM_PATH)
            cat >&2 <<EOF
    bin/hipcc (HIP compiler)
    lib/ (runtime libraries)
EOF
            ;;
        HECBENCH_SRC)
            cat >&2 <<EOF
    *-hip/ directories (HIP benchmark sources)
EOF
            ;;
    esac
}

# Check available disk space in GB
check_disk_space() {
    local path="$1"
    local required_gb="$2"

    local available_kb
    available_kb=$(df "$path" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))

    if [[ $available_gb -lt $required_gb ]]; then
        log_error "Insufficient disk space in $path"
        log_error "Available: ${available_gb}GB, Required: ${required_gb}GB"
        return 1
    fi

    log_debug "Disk space check passed: ${available_gb}GB available"
    return 0
}

# Parse common command-line flags
parse_common_flags() {
    local script_name="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                if declare -f show_usage &>/dev/null; then
                    show_usage
                    exit 0
                else
                    log_error "show_usage function not defined"
                    exit 1
                fi
                ;;
            --dry-run)
                DRY_RUN=true
                log_info "Dry-run mode enabled"
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                log_debug "Verbose mode enabled"
                shift
                ;;
            *)
                # Return remaining args for script-specific parsing
                echo "$@"
                return 0
                ;;
        esac
    done
}

# ==============================================================================
# INTERACTIVE PROMPTS
# ==============================================================================

# Prompt user for confirmation (yes/no)
# If INTERACTIVE=false, defaults to yes without prompting
# Usage: confirm_prompt "Do you want to continue?" && echo "Confirmed"
confirm_prompt() {
    local prompt="$1"
    local default="${2:-yes}"  # yes or no

    # If not interactive, return based on default
    if [[ "${INTERACTIVE:-true}" == "false" ]]; then
        log_debug "Non-interactive mode: defaulting to '$default' for: $prompt"
        [[ "$default" == "yes" ]]
        return $?
    fi

    # Interactive mode: ask user
    local response
    if [[ "$default" == "yes" ]]; then
        echo -n "${BLUE}[?]${NC} $prompt [Y/n]: "
    else
        echo -n "${BLUE}[?]${NC} $prompt [y/N]: "
    fi
    read -r response < /dev/tty 2>/dev/null || response=""

    # Handle response
    case "${response,,}" in
        y|yes)
            return 0
            ;;
        n|no)
            return 1
            ;;
        "")
            # Use default
            [[ "$default" == "yes" ]]
            return $?
            ;;
        *)
            log_warn "Invalid response: '$response' (expected y/n)"
            confirm_prompt "$prompt" "$default"  # Retry
            return $?
            ;;
    esac
}

# ==============================================================================
# SHARED-MEMORY (/dev/shm) HOUSEKEEPING
# ==============================================================================
# OpenMPI's vader/sm BTL and RCCL leave per-rank backing files in /dev/shm
# (e.g. vader_segment.<host>.<pid>.<key>.<rank>, nccl-XXXXXX). Normally these
# are unlinked when ranks exit cleanly, but a SIGKILL'd or timed-out run leaks
# them. On containers where /dev/shm is small (Docker default = 64 MiB), the
# leaks accumulate across runs until subsequent mpirun invocations fail with
# "not enough space for /dev/shm/...".
#
# Call this between benchmarks so every MPI/RCCL benchmark sees a clean slate.
# Scoped to the current user to avoid disturbing other tenants on shared
# systems. Silent on success; logs at debug level only.
cleanup_stale_shm() {
    [[ -d /dev/shm ]] || return 0
    local user="${USER:-$(id -un)}"
    # -user filter prevents touching other tenants' files on shared hosts.
    # 2>/dev/null swallows the harmless ENOENT when the glob has no matches.
    find /dev/shm -maxdepth 1 -user "$user" \
        \( -name 'vader_segment.*' -o -name 'nccl-*' \) \
        -delete 2>/dev/null || true
}

# ==============================================================================
# BINARY VALIDATION
# ==============================================================================

# Validate that a compiled binary actually contains the expected offload arch.
# Catches the catastrophic case where Makefiles ignore HIP_ARCH and hipcc falls
# back to the system default (e.g., building gfx90a when amdgcnspirv was requested).
#
# Usage: validate_arch <binary_path> <arch>
# Returns 0 if the binary contains the expected arch bundle, 1 otherwise.
validate_arch() {
    local binary="$1" arch="$2"
    if [[ ! -f "$binary" ]]; then
        log_error "validate_arch: binary not found: $binary"
        return 1
    fi
    case "$arch" in
        amdgcnspirv)
            grep -qa 'hip-spirv64-amd-amdhsa--amdgcnspirv' "$binary" ;;
        gfx*)
            grep -qa "hip-amdgcn-amd-amdhsa--${arch}" "$binary" ;;
        *)
            log_warn "validate_arch: unknown arch '$arch', skipping validation"
            return 0 ;;
    esac
}

# ==============================================================================
# BENCHMARK OUTPUT VALIDATION
# ==============================================================================

# Scan a benchmark's log file for validation failures that the exit code missed.
# Many HeCBench benchmarks print PASS/FAIL but exit 0 regardless.
# Returns 0 if output looks clean, 1 if suspect lines were found.
# Writes the first few suspect lines to stdout for logging.
check_output_validation() {
    local log="$1"
    local name="${2:-}"

    [[ ! -s "$log" ]] && return 0

    local hits

    hits=$(
        grep -i -E \
            -e '\bFAIL(ED)?\b' \
            -e '\bMISMATCH\b' \
            -e '\bwrong result\b' \
            -e '\bdoes not match\b' \
            -e '\bTest Failed\b' \
            -e '\bincorrect\S*:\s*[1-9]' \
            -e 'hipblas\S+ failed' \
            -e 'rocblas\S+ failed' \
            -e ':\s*nan\b' \
            -e 'No such file or directory' \
            "$log" 2>/dev/null \
        | grep -v -i \
            -e '0 .* failed' \
            -e 'fail\(ures\?\|ed\):.\?[[:space:]]*0' \
            -e '\bno fail' \
            -e '\bwithout fail' \
            -e '\bif .*fail' \
            -e '\bon fail' \
            -e '#.*fail' \
            -e 'incorrect\S*:\s*0' \
            -e 'warning:' \
            -e 'note:' \
            -e '^\s*[0-9]\+\s*|' \
            -e '^/.*\.\(cpp\|c\|h\|hpp\|cc\)\b' \
            -e '^make\[' \
            -e '^hipcc' \
            -e '^amdclang' \
            -e '\.cpp:' \
            -e '\.cu:' \
            -e '\.h:' \
            -e 'hypre_assert' \
            -e 'hypre_error' \
        || true
    )

    if [[ -n "$hits" ]]; then
        echo "$hits" | head -5
        return 1
    fi

    return 0
}

# ==============================================================================
# LIBRARY INITIALIZATION
# ==============================================================================

# This library is now loaded
readonly COMMON_LIB_LOADED=true
log_debug "Common library loaded successfully"
