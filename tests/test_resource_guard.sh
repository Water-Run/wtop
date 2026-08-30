#!/bin/sh
set -eu

guard=./tools/check_resources.sh
fixture_root=$PWD/tests/fixtures/resources
proc_root=$fixture_root/proc
cgroup_root=$fixture_root/cgroup
missing_cgroup=$fixture_root/missing-cgroup

capture() {
    expected_status=$1
    shift
    set +e
    captured_output=$("$@" 2>&1)
    captured_status=$?
    set -e
    if [ "$captured_status" -ne "$expected_status" ]; then
        printf 'resource guard fixture: expected status %s, got %s\n%s\n' \
            "$expected_status" "$captured_status" "$captured_output" >&2
        exit 1
    fi
}

contains() {
    expected_text=$1
    case "$captured_output" in
        *"$expected_text"*) ;;
        *)
            printf 'resource guard fixture: missing output: %s\n%s\n' \
                "$expected_text" "$captured_output" >&2
            exit 1
            ;;
    esac
}

capture 0 env WTOP_RESOURCE_PROC_ROOT="$proc_root" \
    WTOP_RESOURCE_CGROUP_ROOT="$missing_cgroup" WTOP_RESOURCE_CPU_COUNT=4 \
    "$guard" full
contains "available=16384 MiB[host]"
contains "swap-free=7168/8192 MiB[host]"
contains "memory-full-psi10=0.25%[host]"

capture 0 env WTOP_RESOURCE_PROC_ROOT="$proc_root" \
    WTOP_RESOURCE_CGROUP_ROOT="$cgroup_root" WTOP_RESOURCE_CPU_COUNT=4 \
    "$guard" build
contains "available=2048 MiB[cgroup]"
contains "swap-free=256/2048 MiB[cgroup]"
contains "memory-full-psi10=2.50%[cgroup]"

# The test profile independently meets its 2 GiB memory floor, but still
# refuses because only 256 MiB of its default 512 MiB swap credit is free.
capture 1 env WTOP_RESOURCE_PROC_ROOT="$proc_root" \
    WTOP_RESOURCE_CGROUP_ROOT="$cgroup_root" WTOP_RESOURCE_CPU_COUNT=4 \
    "$guard" test
contains "need 2560 MiB combined memory/swap headroom"
contains "refusing to start"

capture 1 env WTOP_RESOURCE_PROC_ROOT="$proc_root" \
    WTOP_RESOURCE_CGROUP_ROOT="$cgroup_root" WTOP_RESOURCE_CPU_COUNT=4 \
    WTOP_MIN_AVAILABLE_KIB=2097153 WTOP_MIN_SWAP_FREE_KIB=0 \
    "$guard" build
contains "need at least 2048 MiB available memory"

capture 1 env WTOP_RESOURCE_PROC_ROOT="$proc_root" \
    WTOP_RESOURCE_CGROUP_ROOT="$cgroup_root" WTOP_RESOURCE_CPU_COUNT=4 \
    WTOP_MIN_SWAP_FREE_KIB=262145 "$guard" build
contains "need at least 256 MiB free swap (explicit policy)"

capture 1 env WTOP_RESOURCE_PROC_ROOT="$proc_root" \
    WTOP_RESOURCE_CGROUP_ROOT="$cgroup_root" WTOP_RESOURCE_CPU_COUNT=4 \
    WTOP_MAX_MEMORY_PSI_FULL_AVG10=2 "$guard" build
contains "memory full PSI avg10 2.50 exceeds 2"

capture 1 env WTOP_RESOURCE_PROC_ROOT="$proc_root" \
    WTOP_RESOURCE_CGROUP_ROOT="$cgroup_root" WTOP_RESOURCE_CPU_COUNT=4 \
    WTOP_MAX_LOAD_PER_CPU=0.49 "$guard" build
contains "load per CPU exceeds 0.49"

# With no swap configured, default policy accepts ample extra memory, while an
# explicit nonzero swap requirement remains exact and must fail.
capture 0 env WTOP_RESOURCE_PROC_ROOT="$fixture_root/proc-zero-swap" \
    WTOP_RESOURCE_CGROUP_ROOT="$missing_cgroup" WTOP_RESOURCE_CPU_COUNT=2 \
    "$guard" full
capture 1 env WTOP_RESOURCE_PROC_ROOT="$fixture_root/proc-zero-swap" \
    WTOP_RESOURCE_CGROUP_ROOT="$missing_cgroup" WTOP_RESOURCE_CPU_COUNT=2 \
    WTOP_MIN_SWAP_FREE_KIB=1 "$guard" full
contains "free swap (explicit policy)"

# A 256 MiB swap device scales the full-profile default to its 64 MiB quarter;
# without scaling, this fixture would fail the combined-headroom requirement.
capture 0 env WTOP_RESOURCE_PROC_ROOT="$fixture_root/proc-small-swap" \
    WTOP_RESOURCE_CGROUP_ROOT="$missing_cgroup" WTOP_RESOURCE_CPU_COUNT=2 \
    "$guard" full

capture 2 env WTOP_RESOURCE_PROC_ROOT="$fixture_root/proc-invalid-psi" \
    WTOP_RESOURCE_CGROUP_ROOT="$missing_cgroup" WTOP_RESOURCE_CPU_COUNT=2 \
    "$guard" full
contains "invalid host memory PSI data"

capture 2 env WTOP_RESOURCE_PROC_ROOT=relative \
    WTOP_RESOURCE_CGROUP_ROOT="$missing_cgroup" WTOP_RESOURCE_CPU_COUNT=2 \
    "$guard" test
contains "WTOP_RESOURCE_PROC_ROOT must be absolute"
capture 2 env WTOP_RESOURCE_PROC_ROOT="$proc_root" \
    WTOP_RESOURCE_CGROUP_ROOT="$missing_cgroup" WTOP_RESOURCE_CPU_COUNT=0 \
    "$guard" test
contains "CPU count must be positive"
capture 2 "$guard" unknown-profile
contains "unknown profile"
capture 2 env WTOP_MIN_AVAILABLE_KIB=invalid "$guard" test
contains "thresholds must be nonnegative numbers"
capture 0 env WTOP_SKIP_RESOURCE_CHECK=1 "$guard" unknown-profile
contains "explicitly skipped"
