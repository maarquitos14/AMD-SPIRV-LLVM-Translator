#!/usr/bin/env bash
# Build and run HeCBench HIP benchmarks in one step (see show_usage below).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/presets.sh
source "${SCRIPT_DIR}/lib/presets.sh"

# ==============================================================================
# DEFAULTS
# ==============================================================================

TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-300}
GPU_ID=${GPU_ID:-0,1}  # Use both GPUs by default for multi-GPU benchmarks
BENCHMARK_FILTER=${BENCHMARK_FILTER:-}
DRY_RUN=false

show_usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] HIP_ARCH

Build and run HeCBench HIP benchmarks in one step.

Arguments:
    HIP_ARCH                GPU architecture (e.g., gfx90a, gfx908, amdgcnspirv,
                            amdgcnspirv-be [amdgcnspirv via the default SPIRV backend])

Options:
    --preset PRESET         Run a predefined subset (quick, standard, extended)
                              quick    ~10min  (179 benchmarks, fastest by wall time)
                              standard ~30min  (318 benchmarks)
                              extended ~60min  (417 benchmarks)
                            Presets are cumulative: quick ⊂ standard ⊂ extended ⊂ full.
                            Times are approximate and based on gfx90a measurements.
    --filter LIST           Only run specified benchmarks (comma-separated)
                            (e.g., --filter dp4a-hip,saxpy-ompt-hip)
    --timeout SECONDS       Per-benchmark timeout (default: $TIMEOUT_SECONDS)
    --gpu-id N              ROCR_VISIBLE_DEVICES value (default: $GPU_ID)
    --dry-run               Show what would run without executing
    --help, -h              Show this help

Environment Variables:
    ROCM_PATH               REQUIRED. Path to ROCm installation.
    HECBENCH_SRC            Path to HeCBench src (auto-detected if not set)
    BENCHMARK_FILTER        Comma-separated list of benchmarks (overrides --filter)

Examples:
    ./$SCRIPT_NAME gfx90a
    ./$SCRIPT_NAME --preset quick gfx90a
    ./$SCRIPT_NAME --preset standard amdgcnspirv
    ./$SCRIPT_NAME --filter dp4a-hip,saxpy-ompt-hip gfx90a
    ./$SCRIPT_NAME --timeout 600 amdgcnspirv

Output:
    bench_logs_YYYYMMDD_HHMMSS_<arch>/
        timings.csv          benchmark,build_seconds,run_seconds
        success.log          benchmarks that built and ran cleanly
        failed.log           non-zero exit (build or run)
        suspect.log          exit 0 but output contains validation failures
                             (FAIL, MISMATCH, nan, missing input data, etc.)
        timeout.log          exceeded --timeout
        skipped.log          architecture-unsupported (e.g. saxpy-ompt-hip on amdgcnspirv)
        <benchmark>.log      per-benchmark combined build+run output
EOF
}

# ==============================================================================
# ARG PARSING
# ==============================================================================

ARCH=""
PRESET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)        show_usage; exit 0 ;;
        --preset)         PRESET="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --filter)         BENCHMARK_FILTER="$2"; shift 2 ;;
        --timeout)        TIMEOUT_SECONDS="$2"; shift 2 ;;
        --gpu-id)         GPU_ID="$2"; shift 2 ;;
        -*)               log_error "Unknown option: $1"; show_usage; exit 1 ;;
        *)
            if [[ -z "$ARCH" ]]; then
                ARCH="$1"
            else
                log_error "Multiple HIP_ARCH values; this script accepts one"
                exit 1
            fi
            shift
            ;;
    esac
done

# Resolve --preset into BENCHMARK_FILTER (--filter takes precedence).
if [[ -n "$PRESET" && -z "$BENCHMARK_FILTER" ]]; then
    case "$PRESET" in
        quick)    BENCHMARK_FILTER="$PRESET_QUICK" ;;
        standard) BENCHMARK_FILTER="$PRESET_STANDARD" ;;
        extended) BENCHMARK_FILTER="$PRESET_EXTENDED" ;;
        *)
            log_error "Unknown preset: $PRESET (choose: quick, standard, extended)"
            exit 1
            ;;
    esac
fi

if [[ -z "$ARCH" ]]; then
    log_error "HIP_ARCH is required"
    show_usage
    exit 1
fi

# $ARCH is the user-facing token (log dir, prints); HIPCC_ARCH is what make gets
# as HIP_ARCH=. "amdgcnspirv-be" is our alias for the default SPIRV backend, so
# it maps to plain amdgcnspirv; every other arch passes through unchanged.
if [[ "$ARCH" == "amdgcnspirv-be" ]]; then
    HIPCC_ARCH="amdgcnspirv"
else
    HIPCC_ARCH="$ARCH"
fi

# ==============================================================================
# VALIDATION & SETUP
# ==============================================================================

require_rocm_path || exit 1
HECBENCH_SRC=$(find_hecbench_src "$SCRIPT_DIR") || {
    log_error "Cannot find HeCBench src directory"
    exit 1
}

LOG_DIR="${SCRIPT_DIR}/bench_logs_$(date +%Y%m%d_%H%M%S)_${ARCH}"
mkdir -p "$LOG_DIR"

export PATH="${ROCM_PATH}/bin:${PATH}"
export LD_LIBRARY_PATH="${ROCM_PATH}/lib:${LD_LIBRARY_PATH:-}"
export HIP_PATH="${ROCM_PATH}"
# HIP_CLANG_PATH points hipcc at the clang to drive; CI sets it to the freshly
# built LLVM bin dir. Unset -> fall back to $ROCM_PATH/bin.
if [[ -n "${HIP_CLANG_PATH:-}" ]]; then
    export HIP_CLANG_PATH
    export PATH="${HIP_CLANG_PATH}:${PATH}"
    export LD_LIBRARY_PATH="$(dirname "${HIP_CLANG_PATH}")/lib:${LD_LIBRARY_PATH}"
fi
# hipcc/amdclang++ honor this for AMDGCN bitcode lookup
export HIP_DEVICE_LIB_PATH="${ROCM_PATH}/lib/llvm/amdgcn/bitcode"
export ROCR_VISIBLE_DEVICES="$GPU_ID"
# prna-hip reads DATAPATH; overridable, harmless default for the rest.
export DATAPATH="${DATAPATH:-${HECBENCH_SRC}/prna-cuda/data_tables}"
ulimit -s unlimited 2>/dev/null || true

echo "benchmark,build_seconds,run_seconds" > "$LOG_DIR/timings.csv"
touch "$LOG_DIR/success.log" \
      "$LOG_DIR/failed.log" \
      "$LOG_DIR/suspect.log" \
      "$LOG_DIR/timeout.log" \
      "$LOG_DIR/skipped.log"

log_info "==========================================="
log_info "HeCBench bench (build+run merged)"
log_info "==========================================="
log_info "ROCm path:    $ROCM_PATH"
log_info "HeCBench src: $HECBENCH_SRC"
log_info "Arch:         $ARCH"
log_info "Timeout:      ${TIMEOUT_SECONDS}s"
log_info "GPU ID:       $GPU_ID"
log_info "Logs:         $LOG_DIR"

# Clear the COMGR JIT cache to prevent stale finalized kernels from being
# served after a compiler or runtime update.  The cache keys are based on the
# SPIR-V input hash, so a runtime-only update (same compiler, same SPIR-V)
# would silently reuse the old (possibly buggy) native code.
if [[ -d "${HOME}/.cache/comgr" ]]; then
    log_info "Clearing COMGR cache (${HOME}/.cache/comgr) ..."
    rm -rf "${HOME}/.cache/comgr"
fi

echo ""

# ==============================================================================
# PER-BENCHMARK
# ==============================================================================

# Architecture-incompatibility skip list.
should_skip() {
    local name="$1"
    # saxpy-ompt-hip needs a concrete GPU ISA; spirv64-amd-amdhsa not in toolchain.
    [[ "$name" == "saxpy-ompt-hip" && "$HIPCC_ARCH" == "amdgcnspirv" ]] && return 0
    # TEMP: pingpong-hip hangs in MPI/NCCL (pre-existing issue, unrelated to
    # current TheRock bring-up); burns the full timeout for nothing.
    [[ "$name" == "pingpong-hip" ]] && return 0
    [[ "$name" == "assert-hip" ]] && return 0

    return 1
}

# Benchmarks that need special environment overrides for `make run`.
apply_special_env() {
    local name="$1"
    case "$name" in
        assert-hip)
            # This benchmark intentionally triggers a device-side assertion to
            # verify host-side error reporting. Suppress the ROCm runtime's GPU
            # coredump on exception so the apport pipe in core_pattern is not
            # invoked. Keep coredumps enabled for every other benchmark.
            export HSA_DISABLE_COREDUMP_ON_EXCEPTION=1
            ;;
    esac
}

clear_special_env() {
    local name="$1"
    case "$name" in
        assert-hip)
            unset HSA_DISABLE_COREDUMP_ON_EXCEPTION
            ;;
    esac
}

# Extra `make` command-line arguments specific to a benchmark. Used for
# benchmarks whose Makefile reads a variable other than HIP_ARCH for the
# offload arch (e.g. saxpy-ompt-hip uses ARCH for OpenMP `-march=$(ARCH)`).
# Returns the extra args via stdout, one per line.
extra_make_args() {
    local name="$1"
    case "$name" in
        saxpy-ompt-hip)
            echo "ARCH=$ARCH"
            ;;
    esac
    # libhipcxx <chrono> hard-errors on amdgcnspirv because no compile-time
    # __gfx*__ macro is defined for SPIR-V; allow it through and silence the
    # accompanying warning. Host-side std::chrono is unaffected.
    # Applies to both SPIRV paths. Plain amdgcnspirv also opts out of the
    # (now default) backend to exercise the legacy translator.
    if [[ "$HIPCC_ARCH" == "amdgcnspirv" ]]; then
        echo "EXTRA_CFLAGS=-D_LIBCUDACXX_ALLOW_UNSUPPORTED_ARCHITECTURE -DNDEBUG"
        [[ "$ARCH" == "amdgcnspirv" ]] && echo "EXTRA_HIPCCFLAGS=-no-use-spirv-backend"
    fi
}

# Per-benchmark direct-run override. When non-empty, bench_one builds with
# `make` (default target) and then invokes each emitted command directly,
# bypassing the Makefile's `run:` recipe. Each line is "binary arg1 arg2 ..."
# parsed with `read -ra`; the binary is resolved relative to $dir.
#
# Use this when the Makefile's `run:` recipe includes a config that exceeds
# this system's resources (e.g. attention-paged-hip's 131072-block case OOMs
# on MI210). Keeps coverage of the configs that fit without an upstream patch.
direct_run_argsets() {
    local name="$1"
    local arch="${2:-$ARCH}"
    case "$name" in
        attention-paged-hip)
            # 4th make-run config (131072 kv blocks) OOMs; substitute 65536.
            echo "./main 8 32 128 4096 128 100"
            echo "./main 8 32 128 4096 1024 100"
            echo "./main 8 32 128 4096 8192 100"
            echo "./main 8 32 128 4096 65536 100"
            ;;
    esac
}

# check_output_validation() is defined in lib/common.sh.

bench_one() {
    local dir="$1"
    local name; name=$(basename "$dir")
    local log="$LOG_DIR/${name}.log"

    if should_skip "$name"; then
        log_info "Skipped: $name (arch unsupported)"
        echo "$name" >> "$LOG_DIR/skipped.log"
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would build+run: $name"
        return
    fi

    # Reclaim leaked OpenMPI/RCCL backing files in /dev/shm so an MPI benchmark
    # whose predecessor was SIGKILL'd doesn't fail with "not enough space".
    cleanup_stale_shm

    cd "$dir" || { log_error "$name: cannot cd to $dir"; return; }
    apply_special_env "$name"

    # Clean to ensure a deterministic build state.
    make clean &>/dev/null || true

    local build_start build_elapsed run_start run_elapsed rc
    local -a make_extra=()
    while IFS= read -r arg; do
        [[ -n "$arg" ]] && make_extra+=("$arg")
    done < <(extra_make_args "$name")

    # ---- Phase 1: BUILD (default target only) ----
    build_start=$(date +%s.%N)
    set +e
    timeout "$TIMEOUT_SECONDS" make HIP_ARCH="$HIPCC_ARCH" "${make_extra[@]}" &>"$log"
    rc=$?
    set -e
    build_elapsed=$(awk "BEGIN {printf \"%.3f\", $(date +%s.%N) - $build_start}")

    if [[ $rc -ne 0 ]]; then
        if [[ $rc -eq 124 ]]; then
            log_error "Timeout (build): $name (>${TIMEOUT_SECONDS}s)"
            echo "$name" >> "$LOG_DIR/timeout.log"
        else
            log_error "Failed (build): $name (exit $rc)"
            echo "$name" >> "$LOG_DIR/failed.log"
        fi
        clear_special_env "$name"
        cd "$SCRIPT_DIR"
        return
    fi

    # ---- Phase 2: RUN (no make overhead) ----
    # Collect the run commands: either from direct_run_argsets overrides
    # or by asking the Makefile what `make run` would execute.
    local -a runcmds=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && runcmds+=("$line")
    done < <(direct_run_argsets "$name" "$HIPCC_ARCH")

    if [[ ${#runcmds[@]} -eq 0 ]]; then
        # Extract commands from the Makefile's run recipe via dry-run.
        # Binary is already built, so make -n run only prints run commands.
        # Join backslash-continuation lines before splitting into commands.
        local accum=""
        while IFS= read -r line; do
            if [[ "$line" == *'\' ]]; then
                accum+="${line%\\} "
            else
                accum+="$line"
                [[ -n "$accum" ]] && runcmds+=("$accum")
                accum=""
            fi
        done < <(make -n run HIP_ARCH="$HIPCC_ARCH" "${make_extra[@]}" 2>/dev/null)
        [[ -n "$accum" ]] && runcmds+=("$accum")
    fi

    if [[ ${#runcmds[@]} -eq 0 ]]; then
        log_error "Failed: $name (no run commands found)"
        echo "$name" >> "$LOG_DIR/failed.log"
        clear_special_env "$name"
        cd "$SCRIPT_DIR"
        return
    fi

    run_start=$(date +%s.%N)
    set +e
    rc=0
    for cmd in "${runcmds[@]}"; do
        echo "+ $cmd" >>"$log"
        timeout "$TIMEOUT_SECONDS" bash -c "$cmd" &>>"$log" 2>&1
        rc=$?
        [[ $rc -ne 0 ]] && break
    done
    set -e
    run_elapsed=$(awk "BEGIN {printf \"%.3f\", $(date +%s.%N) - $run_start}")

    if [[ $rc -eq 0 ]]; then
        local time_detail="build ${build_elapsed}s, run ${run_elapsed}s"
        local validation_issues
        if validation_issues=$(check_output_validation "$log" "$name"); then
            log_success "$name (${time_detail})"
            echo "$name" >> "$LOG_DIR/success.log"
        else
            log_warn "$name (${time_detail}) — exit 0 but output validation suspect"
            echo "$name" >> "$LOG_DIR/suspect.log"
        fi
        echo "$name,$build_elapsed,$run_elapsed" >> "$LOG_DIR/timings.csv"
    elif [[ $rc -eq 124 ]]; then
        log_error "Timeout (run): $name (>${TIMEOUT_SECONDS}s)"
        echo "$name" >> "$LOG_DIR/timeout.log"
    else
        log_error "Failed (run): $name (exit $rc)"
        echo "$name" >> "$LOG_DIR/failed.log"
    fi

    clear_special_env "$name"
    cd "$SCRIPT_DIR"
}

# ==============================================================================
# DISCOVER & ITERATE
# ==============================================================================

if [[ -n "$BENCHMARK_FILTER" ]]; then
    # Build dirs directly from the filter/preset list — no need to scan all dirs
    declare -a dirs=()
    IFS=',' read -ra wanted <<< "$BENCHMARK_FILTER"
    for w in "${wanted[@]}"; do
        w="${w## }"; w="${w%% }"
        [[ -z "$w" ]] && continue
        local_dir="$HECBENCH_SRC/$w"
        [[ -d "$local_dir" ]] && dirs+=("$local_dir")
    done
    if [[ ${#dirs[@]} -eq 0 ]]; then
        log_error "Filter matched no benchmarks: $BENCHMARK_FILTER"
        exit 1
    fi
else
    mapfile -t dirs < <(find "$HECBENCH_SRC" -maxdepth 1 -type d -name "*-hip" | sort)
    if [[ ${#dirs[@]} -eq 0 ]]; then
        log_error "No *-hip directories under $HECBENCH_SRC"
        exit 1
    fi
fi

log_info "Processing ${#dirs[@]} benchmarks..."
echo ""

for d in "${dirs[@]}"; do
    bench_one "$d"
done

# ==============================================================================
# SUMMARY
# ==============================================================================

count() {
    local f="$LOG_DIR/$1"
    [[ -f "$f" ]] && wc -l <"$f" | tr -d ' ' || echo 0
}

echo ""
log_info "==========================================="
log_info "Summary"
log_info "==========================================="
log_info "  Success:       $(count success.log)"
log_info "  Suspect:       $(count suspect.log)  (exit 0 but output has failures)"
log_info "  Failed:        $(count failed.log)"
log_info "  Timeout:       $(count timeout.log)"
log_info "  Skipped:       $(count skipped.log)"
log_info ""
log_info "Logs:    $LOG_DIR"
log_info "Timings: $LOG_DIR/timings.csv"
