/* Internal frequency collector; included by the native module and its OS fixture. */
#ifndef WTOP_WINDOWS_FREQUENCY_H
#define WTOP_WINDOWS_FREQUENCY_H
#include <float.h>
#define WTOP_WINDOWS_FREQUENCY_LIMIT 512

typedef struct {
    ULONG Number;
    ULONG MaxMhz;
    ULONG CurrentMhz;
    ULONG MhzLimit;
    ULONG MaxIdleState;
    ULONG CurrentIdleState;
} processor_power_information;

typedef LONG (WINAPI *call_power_information_function)(int, PVOID, ULONG,
    PVOID, ULONG);
typedef DWORD (WINAPI *power_active_scheme_function)(HKEY, GUID **);
typedef DWORD (WINAPI *power_friendly_name_function)(HKEY, const GUID *,
    const GUID *, const GUID *, PUCHAR, LPDWORD);

static pdh_set frequency_counters;

static int processor_power(processor_power_information *values, ULONG count) {
    static int resolved = 0;
    static call_power_information_function query = NULL;
    if (!resolved) {
        HMODULE module = LoadLibraryA("powrprof.dll");
        resolved = 1;
        query = module ? (call_power_information_function)(void *)
            GetProcAddress(module, "CallNtPowerInformation") : NULL;
    }
    /* ProcessorInformation = 11 */
    return query && query(11, NULL, 0, values,
        count * (ULONG)sizeof(values[0])) == 0;
}

static int query_power_scheme(WCHAR *name, DWORD capacity) {
    static int resolved = 0;
    static power_active_scheme_function active = NULL;
    static power_friendly_name_function friendly = NULL;
    GUID *scheme = NULL;
    DWORD bytes = capacity - sizeof(WCHAR);
    if (!resolved) {
        HMODULE module = LoadLibraryA("powrprof.dll");
        resolved = 1;
        if (module) {
            active = (power_active_scheme_function)(void *)GetProcAddress(module,
                "PowerGetActiveScheme");
            friendly = (power_friendly_name_function)(void *)GetProcAddress(module,
                "PowerReadFriendlyName");
        }
    }
    if (!active || !friendly) return 0;
    DWORD status = active(NULL, &scheme);
    if (status != ERROR_SUCCESS || !scheme) {
        if (scheme) LocalFree(scheme);
        return 0;
    }
    memset(name, 0, capacity);
    status = friendly(NULL, scheme, NULL, NULL, (PUCHAR)name, &bytes);
    LocalFree(scheme);
    return status == ERROR_SUCCESS && bytes <= capacity - sizeof(WCHAR) && name[0];
}

typedef WORD (WINAPI *frequency_groups_fn)(void);
typedef DWORD (WINAPI *frequency_active_fn)(WORD);
struct frequency_row {
    unsigned id, seen, bad, power_present;
    double base_mhz, performance;
    processor_power_information power;
};
struct frequency_capture {
    struct frequency_row rows[WTOP_WINDOWS_FREQUENCY_LIMIT];
    processor_power_information power[64];
    unsigned count;
    int partial, truncated;
    WCHAR governor[128];
    int have_governor;
};
static int frequency_name(const WCHAR *name, unsigned *group, unsigned *number) {
    unsigned values[2] = {0, 0};
    if (!name) return 0;
    if (!wcscmp(name, L"_Total")) return 2;
    for (unsigned part = 0; part < 2; ++part) {
        if (part == 1 && !wcscmp(name, L"_Total")) return 2;
        if (*name < L'0' || *name > L'9') return 0;
        do {
            values[part] = values[part] * 10 + (unsigned)(*name++ - L'0');
            if (values[part] >= 64) return 0;
        } while (*name >= L'0' && *name <= L'9');
        if (part == 0 && *name++ != L',') return 0;
    }
    if (*name) return 0;
    *group = values[0]; *number = values[1];
    return 1;
}
static int frequency_hz(double mhz, lua_Integer *hz) {
    double value = mhz * 1000000.0;
    if (!(value >= 1 && value < (double)LUA_MAXINTEGER)) return 0;
    *hz = (lua_Integer)value;
    return 1;
}
static struct frequency_row *frequency_row(struct frequency_capture *all, unsigned id) {
    for (unsigned i = 0; i < all->count; ++i) if (all->rows[i].id == id) return &all->rows[i];
    if (all->count >= WTOP_WINDOWS_FREQUENCY_LIMIT) { all->partial = all->truncated = 1; return NULL; }
    struct frequency_row *row = &all->rows[all->count++];
    row->id = id; row->base_mhz = row->performance = -1;
    return row;
}
static int frequency_order(const void *first, const void *second) {
    const struct frequency_row *a = first, *b = second;
    return (a->id > b->id) - (a->id < b->id);
}
struct frequency_topology { unsigned groups, counts[64]; };
static int frequency_group_info(struct frequency_topology *topology) {
    static int resolved;
    static frequency_groups_fn group_count;
    static frequency_active_fn active_count;
    SYSTEM_INFO system;
    memset(topology, 0, sizeof(*topology));
    GetSystemInfo(&system);
    if (!resolved) {
        HMODULE kernel = GetModuleHandleA("kernel32.dll");
        resolved = 1;
        if (kernel) {
            group_count = (frequency_groups_fn)(void *)GetProcAddress(kernel, "GetActiveProcessorGroupCount");
            active_count = (frequency_active_fn)(void *)GetProcAddress(kernel, "GetActiveProcessorCount");
        }
    }
    /* Before processor groups existed the whole system was group zero.
     * No group-qualified power-information layout is documented, so avoid
     * assigning that fallback to a guessed group on a multi-group host. */
    topology->groups = group_count ? group_count() : 1;
    if (!topology->groups || topology->groups > 64) return 0;
    for (unsigned group = 0; group < topology->groups; ++group) {
        unsigned count = active_count ? active_count((WORD)group)
            : topology->groups == 1 ? system.dwNumberOfProcessors : 0;
        if (!count || count > 64) return 0;
        topology->counts[group] = count;
    }
    return !group_count || group_count() == topology->groups;
}
static void frequency_reset_query(void) {
    if (frequency_counters.query && pdh.close_query) pdh.close_query(frequency_counters.query);
    memset(&frequency_counters, 0, sizeof(frequency_counters));
}
static int l_collect_cpufreq(lua_State *L) {
    static const WCHAR *const paths[] = {
        L"\\Processor Information(*)\\Processor Frequency",
        L"\\Processor Information(*)\\% Processor Performance",
    };
    static DWORD first_collection_tick;
    static struct frequency_topology epoch;
    static int have_epoch;
    struct frequency_topology before, after;
    int sampling_pending = 0, pdh_current = 0;
    if (!frequency_group_info(&before)) {
        frequency_reset_query(); have_epoch = 0;
        lua_pushnil(L); lua_pushliteral(L, "processor_frequency_unavailable"); return 2;
    }
    if (have_epoch && memcmp(&epoch, &before, sizeof(epoch))) frequency_reset_query();
    epoch = before; have_epoch = 1;
    struct frequency_capture *all = lua_newuserdatauv(L, sizeof(*all), 0);
    memset(all, 0, sizeof(*all));
    unsigned count = before.counts[0];
    if (before.groups == 1 && processor_power(all->power, (ULONG)count)) {
        for (unsigned i = 0; i < count; ++i) {
            const processor_power_information *power = &all->power[i];
            if (power->Number >= 64) { all->partial = 1; continue; }
            struct frequency_row *row = frequency_row(all, (unsigned)power->Number);
            if (!row) continue;
            if (row->power_present) { row->bad |= 4; all->partial = 1; continue; }
            row->power_present = 1; row->power = *power;
        }
    }
    if (pdh_set_open(&frequency_counters, paths, 2, 2)) {
        DWORD tick = GetTickCount();
        if (frequency_counters.collections == 1
            && (DWORD)(tick - first_collection_tick) < 1000) {
            sampling_pending = 1;
        } else if (pdh_set_collect(&frequency_counters)) {
            if (frequency_counters.collections == 1) {
                first_collection_tick = tick; sampling_pending = 1;
            } else pdh_current = 1;
        } else { all->partial = 1; frequency_reset_query(); }
    }
    if (pdh_current) {
        int arrays_complete = 1;
        for (unsigned counter = 0; counter < 2; ++counter) {
            DWORD items_count = 0;
            PDH_FMT_COUNTERVALUE_ITEM_W *items = pdh_items(frequency_counters.counters[counter], &items_count);
            if (!items || !items_count) { all->partial = 1; arrays_complete = 0; }
            for (DWORD i = 0; items && i < items_count; ++i) {
                unsigned group, number;
                int kind = frequency_name(items[i].szName, &group, &number);
                if (kind == 2) continue;
                if (!kind || group >= before.groups) {
                    all->partial = 1; continue;
                }
                struct frequency_row *row = frequency_row(all, group * 64 + number);
                if (!row) continue;
                unsigned bit = 1u << counter;
                if (row->seen & bit) { row->bad |= bit; all->partial = 1; }
                row->seen |= bit;
                if (!pdh_item_valid(&items[i]) || !(items[i].FmtValue.doubleValue >= 0
                    && items[i].FmtValue.doubleValue <= DBL_MAX)) {
                    row->bad |= bit; all->partial = 1; continue;
                }
                if (counter == 0) row->base_mhz = items[i].FmtValue.doubleValue;
                else row->performance = items[i].FmtValue.doubleValue;
            }
            free(items);
        }
        if (!arrays_complete) frequency_reset_query();
    }
    if (!frequency_group_info(&after) || memcmp(&before, &after, sizeof(before))) {
        frequency_reset_query(); have_epoch = 0;
        all->count = 0; all->partial = all->truncated = 0; sampling_pending = 1;
    }
    if (!all->count && !sampling_pending) {
        lua_pushnil(L); lua_pushliteral(L, "processor_frequency_unavailable"); return 2;
    }
    qsort(all->rows, all->count, sizeof(all->rows[0]), frequency_order);
    /* All OS-owned objects are released before any result-string allocation. */
    all->have_governor = query_power_scheme(all->governor, sizeof(all->governor));
    lua_createtable(L, 0, 4);
    lua_createtable(L, (int)all->count, 0);
    for (unsigned i = 0; i < all->count; ++i) {
        const struct frequency_row *row = &all->rows[i];
        lua_Integer current = 0, base = 0;
        const char *quality = "fresh", *driver = "pdh";
        if (!(row->bad & 3) && row->base_mhz > 0 && row->performance >= 0
            && frequency_hz(row->base_mhz * (row->performance / 100.0), &current)) {
            /* PDH owns the two-sample calculation. */
        } else if (row->power_present && !(row->bad & 4) && frequency_hz(row->power.CurrentMhz, &current)) {
            driver = "CallNtPowerInformation"; quality = "estimated";
        }
        char name[32]; snprintf(name, sizeof(name), "cpu%u", row->id);
        lua_createtable(L, 0, 10);
        string_field(L, "id", name); string_field(L, "policy", name);
        integer_field(L, "policy_index", row->id);
        integer_field(L, "processor_group", row->id / 64);
        integer_field(L, "processor_number", row->id % 64);
        lua_createtable(L, 1, 0); lua_pushinteger(L, row->id); lua_rawseti(L, -2, 1); lua_setfield(L, -2, "affected_cpus");
        string_field(L, "driver", driver);
        if (all->have_governor) utf8_field(L, "governor", all->governor);
        lua_createtable(L, 0, 6);
        if (current > 0) {
            integer_field(L, "current_hz", current);
            string_field(L, "current_quality", quality);
            string_field(L, "current_source", driver);
        }
        if (!(row->bad & 1) && frequency_hz(row->base_mhz, &base)) integer_field(L, "base_hz", base);
        else if (row->power_present && !(row->bad & 4) && frequency_hz(row->power.MaxMhz, &base)) integer_field(L, "base_hz", base);
        if (row->power_present && !(row->bad & 4) && row->power.MhzLimit > 0 && row->power.MhzLimit < row->power.MaxMhz)
            integer_field(L, "limit_hz", (lua_Integer)row->power.MhzLimit * 1000000);
        lua_setfield(L, -2, "frequencies");
        string_field(L, "quality", current > 0 ? quality : "unavailable");
        string_field(L, "source", driver); lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "policies");
    if (all->partial) string_field(L, "quality", "partial");
    else if (sampling_pending) string_field(L, "quality", "gap");
    if (sampling_pending) { lua_pushboolean(L, 1); lua_setfield(L, -2, "_sampling_pending"); }
    lua_pushboolean(L, all->truncated); lua_setfield(L, -2, "truncated");
    return 1;
}

#endif
