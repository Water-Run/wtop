#!/bin/sh
set -eu

# Keep builds and tests from adding pressure while the current host or cgroup
# is already close to an OOM event. Thresholds can be raised by CI; bypassing
# the guard requires an explicit WTOP_SKIP_RESOURCE_CHECK=1.
wtop_profile=${1:-test}
if [ "${WTOP_SKIP_RESOURCE_CHECK:-0}" = "1" ]; then
    printf '%s\n' "wtop resource check: explicitly skipped"
    exit 0
fi

case "$wtop_profile" in
    build)
        wtop_default_available_kib=1048576
        wtop_default_swap_free_kib=262144
        wtop_default_psi_full=15
        wtop_default_load_per_cpu=3
        ;;
    test)
        wtop_default_available_kib=2097152
        wtop_default_swap_free_kib=524288
        wtop_default_psi_full=10
        wtop_default_load_per_cpu=2
        ;;
    full)
        wtop_default_available_kib=4194304
        wtop_default_swap_free_kib=1048576
        wtop_default_psi_full=5
        wtop_default_load_per_cpu=1.5
        ;;
    *)
        printf '%s\n' "wtop resource check: unknown profile: $wtop_profile" >&2
        exit 2
        ;;
esac

wtop_min_available_kib=${WTOP_MIN_AVAILABLE_KIB-$wtop_default_available_kib}
wtop_min_swap_free_kib=${WTOP_MIN_SWAP_FREE_KIB-$wtop_default_swap_free_kib}
wtop_max_psi_full=${WTOP_MAX_MEMORY_PSI_FULL_AVG10-$wtop_default_psi_full}
wtop_max_load_per_cpu=${WTOP_MAX_LOAD_PER_CPU-$wtop_default_load_per_cpu}
wtop_swap_threshold_explicit=0
if [ "${WTOP_MIN_SWAP_FREE_KIB+x}" = "x" ]; then
    wtop_swap_threshold_explicit=1
fi

case "$wtop_min_available_kib" in
    ''|*[!0-9]*)
        printf '%s\n' "wtop resource check: thresholds must be nonnegative numbers" >&2
        exit 2
        ;;
esac
case "$wtop_min_swap_free_kib" in
    ''|*[!0-9]*)
        printf '%s\n' "wtop resource check: thresholds must be nonnegative numbers" >&2
        exit 2
        ;;
esac
if ! awk -v psi="$wtop_max_psi_full" -v load_value="$wtop_max_load_per_cpu" '
    BEGIN {
        pattern = "^[0-9]+([.][0-9]+)?$"
        exit !((psi ~ pattern) && (load_value ~ pattern))
    }
' </dev/null
then
    printf '%s\n' "wtop resource check: thresholds must be nonnegative numbers" >&2
    exit 2
fi

wtop_proc_root=${WTOP_RESOURCE_PROC_ROOT:-/proc}
wtop_cgroup_root=${WTOP_RESOURCE_CGROUP_ROOT:-/sys/fs/cgroup}
case "$wtop_proc_root" in
    /*) wtop_proc_root=${wtop_proc_root%/} ;;
    *) printf '%s\n' "wtop resource check: WTOP_RESOURCE_PROC_ROOT must be absolute" >&2; exit 2 ;;
esac
case "$wtop_cgroup_root" in
    /) printf '%s\n' "wtop resource check: WTOP_RESOURCE_CGROUP_ROOT must not be /" >&2; exit 2 ;;
    /*) wtop_cgroup_root=${wtop_cgroup_root%/} ;;
    *) printf '%s\n' "wtop resource check: WTOP_RESOURCE_CGROUP_ROOT must be absolute" >&2; exit 2 ;;
esac

wtop_read_psi_full() {
    [ ! -r "$1" ] && return 0
    awk '
    $1 == "full" {
        for (field_index = 2; field_index <= NF; field_index++) {
            if ($field_index ~ /^avg10=/) {
                sub(/^avg10=/, "", $field_index)
                print $field_index
                found = 1
                exit
            }
        }
    }
    END { if (!found) exit 1 }
' "$1" 2>/dev/null
}

wtop_mem_available_kib=$(awk '$1 == "MemAvailable:" { print $2 }' "$wtop_proc_root/meminfo")
wtop_swap_total_kib=$(awk '$1 == "SwapTotal:" { print $2 }' "$wtop_proc_root/meminfo")
wtop_swap_free_kib=$(awk '$1 == "SwapFree:" { print $2 }' "$wtop_proc_root/meminfo")
wtop_load_one=$(awk '{ print $1 }' "$wtop_proc_root/loadavg")
wtop_cpu_count=${WTOP_RESOURCE_CPU_COUNT:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n')}
if ! wtop_psi_full=$(wtop_read_psi_full "$wtop_proc_root/pressure/memory"); then
    printf '%s\n' "wtop resource check: invalid host memory PSI data" >&2
    exit 2
fi
wtop_psi_full=${wtop_psi_full:-0}
wtop_mem_source=host
wtop_swap_source=host
wtop_psi_source=host

for wtop_integer in "$wtop_mem_available_kib" "$wtop_swap_total_kib" \
    "$wtop_swap_free_kib" "$wtop_cpu_count"
do
    case "$wtop_integer" in
        ''|*[!0-9]*)
            printf '%s\n' "wtop resource check: invalid procfs resource data" >&2
            exit 2
            ;;
    esac
done
if [ "$wtop_cpu_count" -eq 0 ]; then
    printf '%s\n' "wtop resource check: CPU count must be positive" >&2
    exit 2
fi
if ! awk -v psi="$wtop_psi_full" -v load_value="$wtop_load_one" '
    BEGIN {
        pattern = "^[0-9]+([.][0-9]+)?$"
        exit !((psi ~ pattern) && (load_value ~ pattern))
    }
' </dev/null
then
    printf '%s\n' "wtop resource check: invalid load or PSI data" >&2
    exit 2
fi

# cgroup v2 limits can be much smaller than host totals. Walk from the current
# process scope to the delegated root and retain the tightest remaining
# memory/swap headroom and the highest full-memory PSI value.
wtop_cgroup_relative=$(awk -F: '$1 == "0" { print $3; exit }' \
    "$wtop_proc_root/self/cgroup" 2>/dev/null || true)
wtop_cgroup_available_kib=
wtop_cgroup_swap_total_kib=
wtop_cgroup_swap_free_kib=
case "$wtop_cgroup_relative" in
    /*/../*|/..|*/..)
        wtop_cgroup_relative=
        ;;
esac
if [ -n "$wtop_cgroup_relative" ] && [ -d "$wtop_cgroup_root" ]; then
    wtop_cgroup_path="$wtop_cgroup_root$wtop_cgroup_relative"
    while [ -n "$wtop_cgroup_path" ]; do
        case "$wtop_cgroup_path" in
            "$wtop_cgroup_root"|"$wtop_cgroup_root"/*) ;;
            *) break ;;
        esac
        wtop_memory_max=$(sed -n '1p' "$wtop_cgroup_path/memory.max" 2>/dev/null || true)
        wtop_memory_current=$(sed -n '1p' "$wtop_cgroup_path/memory.current" 2>/dev/null || true)
        case "$wtop_memory_max:$wtop_memory_current" in
            [0-9]*:[0-9]*)
                if ! printf '%s\n%s\n' "$wtop_memory_max" "$wtop_memory_current" \
                    | awk 'length($0) > 19 || $0 !~ /^[0-9]+$/ { exit 1 }'
                then
                    printf '%s\n' "wtop resource check: invalid cgroup memory data" >&2
                    exit 2
                fi
                wtop_current_available_kib=$(awk \
                    -v maximum="$wtop_memory_max" -v current="$wtop_memory_current" \
                    'BEGIN { value = maximum > current ? maximum - current : 0; printf "%.0f\n", value / 1024 }')
                if [ -z "$wtop_cgroup_available_kib" ] \
                    || [ "$wtop_current_available_kib" -lt "$wtop_cgroup_available_kib" ]
                then
                    wtop_cgroup_available_kib=$wtop_current_available_kib
                fi
                ;;
        esac

        wtop_swap_max=$(sed -n '1p' "$wtop_cgroup_path/memory.swap.max" 2>/dev/null || true)
        wtop_swap_current=$(sed -n '1p' "$wtop_cgroup_path/memory.swap.current" 2>/dev/null || true)
        case "$wtop_swap_max:$wtop_swap_current" in
            [0-9]*:[0-9]*)
                if ! printf '%s\n%s\n' "$wtop_swap_max" "$wtop_swap_current" \
                    | awk 'length($0) > 19 || $0 !~ /^[0-9]+$/ { exit 1 }'
                then
                    printf '%s\n' "wtop resource check: invalid cgroup swap data" >&2
                    exit 2
                fi
                wtop_current_swap_total_kib=$(awk -v maximum="$wtop_swap_max" \
                    'BEGIN { printf "%.0f\n", maximum / 1024 }')
                wtop_current_swap_free_kib=$(awk \
                    -v maximum="$wtop_swap_max" -v current="$wtop_swap_current" \
                    'BEGIN { value = maximum > current ? maximum - current : 0; printf "%.0f\n", value / 1024 }')
                if [ -z "$wtop_cgroup_swap_total_kib" ] \
                    || [ "$wtop_current_swap_total_kib" -lt "$wtop_cgroup_swap_total_kib" ]
                then
                    wtop_cgroup_swap_total_kib=$wtop_current_swap_total_kib
                fi
                if [ -z "$wtop_cgroup_swap_free_kib" ] \
                    || [ "$wtop_current_swap_free_kib" -lt "$wtop_cgroup_swap_free_kib" ]
                then
                    wtop_cgroup_swap_free_kib=$wtop_current_swap_free_kib
                fi
                ;;
        esac

        if ! wtop_current_psi=$(wtop_read_psi_full "$wtop_cgroup_path/memory.pressure"); then
            printf '%s\n' "wtop resource check: invalid cgroup memory PSI data" >&2
            exit 2
        fi
        if [ -n "$wtop_current_psi" ] && awk -v candidate="$wtop_current_psi" \
            -v current="$wtop_psi_full" 'BEGIN { exit !(candidate > current) }'
        then
            wtop_psi_full=$wtop_current_psi
            wtop_psi_source=cgroup
        fi
        [ "$wtop_cgroup_path" = "$wtop_cgroup_root" ] && break
        wtop_cgroup_parent=${wtop_cgroup_path%/*}
        [ "$wtop_cgroup_parent" = "$wtop_cgroup_path" ] && break
        wtop_cgroup_path=$wtop_cgroup_parent
    done
fi

if [ -n "$wtop_cgroup_available_kib" ] \
    && [ "$wtop_cgroup_available_kib" -lt "$wtop_mem_available_kib" ]
then
    wtop_mem_available_kib=$wtop_cgroup_available_kib
    wtop_mem_source=cgroup
fi
if [ -n "$wtop_cgroup_swap_total_kib" ]; then
    if [ "$wtop_cgroup_swap_total_kib" -lt "$wtop_swap_total_kib" ]; then
        wtop_swap_total_kib=$wtop_cgroup_swap_total_kib
        wtop_swap_source=cgroup
    fi
    if [ "$wtop_cgroup_swap_free_kib" -lt "$wtop_swap_free_kib" ]; then
        wtop_swap_free_kib=$wtop_cgroup_swap_free_kib
        wtop_swap_source=cgroup
    fi
fi

# Defaults scale down on hosts or cgroups with a deliberately small swap
# budget. An explicit WTOP_MIN_SWAP_FREE_KIB remains an exact operator policy.
wtop_required_swap_free_kib=$wtop_min_swap_free_kib
if [ "$wtop_swap_threshold_explicit" -eq 0 ] && [ "$wtop_swap_total_kib" -gt 0 ]; then
    wtop_swap_quarter_kib=$((wtop_swap_total_kib / 4))
    if [ "$wtop_required_swap_free_kib" -gt "$wtop_swap_quarter_kib" ]; then
        wtop_required_swap_free_kib=$wtop_swap_quarter_kib
    fi
fi

printf 'wtop resource check (%s): available=%s MiB[%s] swap-free=%s/%s MiB[%s] load1=%s cpus=%s memory-full-psi10=%s%%[%s]\n' \
    "$wtop_profile" \
    "$((wtop_mem_available_kib / 1024))" \
    "$wtop_mem_source" \
    "$((wtop_swap_free_kib / 1024))" \
    "$((wtop_swap_total_kib / 1024))" \
    "$wtop_swap_source" \
    "$wtop_load_one" "$wtop_cpu_count" "$wtop_psi_full" "$wtop_psi_source"

wtop_failed=0
if [ "$wtop_mem_available_kib" -lt "$wtop_min_available_kib" ]; then
    printf 'wtop resource check: need at least %s MiB available memory\n' \
        "$((wtop_min_available_kib / 1024))" >&2
    wtop_failed=1
fi
if [ "$wtop_swap_threshold_explicit" -eq 1 ]; then
    if [ "$wtop_swap_free_kib" -lt "$wtop_required_swap_free_kib" ]; then
        printf 'wtop resource check: need at least %s MiB free swap (explicit policy)\n' \
            "$((wtop_required_swap_free_kib / 1024))" >&2
        wtop_failed=1
    fi
else
    wtop_swap_credit_kib=$wtop_swap_free_kib
    if [ "$wtop_swap_credit_kib" -gt "$wtop_required_swap_free_kib" ]; then
        wtop_swap_credit_kib=$wtop_required_swap_free_kib
    fi
    wtop_combined_available_kib=$((wtop_mem_available_kib + wtop_swap_credit_kib))
    wtop_combined_required_kib=$((wtop_min_available_kib + wtop_required_swap_free_kib))
    if [ "$wtop_combined_available_kib" -lt "$wtop_combined_required_kib" ]; then
        printf 'wtop resource check: need %s MiB combined memory/swap headroom\n' \
            "$((wtop_combined_required_kib / 1024))" >&2
        wtop_failed=1
    fi
fi
if ! awk -v value="$wtop_psi_full" -v maximum="$wtop_max_psi_full" \
    'BEGIN { exit !(value <= maximum) }'
then
    printf 'wtop resource check: memory full PSI avg10 %s exceeds %s\n' \
        "$wtop_psi_full" "$wtop_max_psi_full" >&2
    wtop_failed=1
fi
if ! awk -v load_value="$wtop_load_one" -v cpus="$wtop_cpu_count" \
    -v maximum="$wtop_max_load_per_cpu" 'BEGIN { exit !(load_value <= cpus * maximum) }'
then
    printf 'wtop resource check: load per CPU exceeds %s\n' "$wtop_max_load_per_cpu" >&2
    wtop_failed=1
fi

if [ "$wtop_failed" -ne 0 ]; then
    printf '%s\n' \
        "wtop resource check: refusing to start; wait for pressure to fall or explicitly set WTOP_SKIP_RESOURCE_CHECK=1" >&2
    exit 1
fi
