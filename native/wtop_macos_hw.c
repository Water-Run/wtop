/* macOS hardware sources: GPU, sensors, energy, CPU frequency, batteries,
 * sockets, and application groups. IOReport, IOHID events, the SMC, and the
 * process coalition query are private interfaces with no SDK header; each
 * is resolved at run time, and a missing one reports its source as
 * unavailable rather than failing the module load. */
#define _DARWIN_C_SOURCE

#include <lua.h>
#include <lauxlib.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#include "wtop_macos.h"
#ifndef WTOP_HARDWARE_WORKER
#include "wtop_hardware_worker.h"
#endif

#define MAX_PIDS 8192
#define MAX_SOCKETS 16384
#define MAX_FDS_PER_PROCESS 4096
#define MAX_COALITIONS 4096

static void integer_field(lua_State *L, const char *name, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, name);
}

static void number_field(lua_State *L, const char *name, lua_Number value) {
    lua_pushnumber(L, value);
    lua_setfield(L, -2, name);
}

static void string_field(lua_State *L, const char *name, const char *value) {
    lua_pushstring(L, value);
    lua_setfield(L, -2, name);
}

static void boolean_field(lua_State *L, const char *name, int value) {
    lua_pushboolean(L, value);
    lua_setfield(L, -2, name);
}

static int cf_text(CFTypeRef value, char *output, size_t size) {
    output[0] = 0;
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return 0;
    return CFStringGetCString((CFStringRef)value, output, (CFIndex)size,
        kCFStringEncodingUTF8) && output[0];
}

static int cf_int64(CFTypeRef value, int64_t *output) {
    return value && CFGetTypeID(value) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, output);
}

static int cf_bool(CFTypeRef value, int *output) {
    if (!value || CFGetTypeID(value) != CFBooleanGetTypeID()) return 0;
    *output = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
    return 1;
}

/* Task CPU times are Mach absolute time on Apple silicon and nanoseconds on
 * Intel; the timebase converts either to nanoseconds. */
uint64_t wtop_mach_to_ns(uint64_t value) {
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0 && mach_timebase_info(&timebase) != KERN_SUCCESS) {
        timebase.numer = 1;
        timebase.denom = 1;
    }
    if (timebase.numer == timebase.denom) return value;
    return (uint64_t)((long double)value * timebase.numer / timebase.denom);
}

/* ------------------------------------------------------------------------
 * Batteries through IOPowerSources, with cycle and design data from the
 * smart-battery service when a battery is installed. */

static void battery_details(lua_State *L) {
    io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL,
        IOServiceMatching("AppleSmartBattery"));
    CFMutableDictionaryRef properties = NULL;
    int64_t value, design = 0, maximum = 0, voltage = 0, amperage = 0;
    if (!service) return;
    if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        == KERN_SUCCESS && properties) {
        if (cf_int64(CFDictionaryGetValue(properties, CFSTR("CycleCount")), &value))
            integer_field(L, "cycle_count", value);
        (void)cf_int64(CFDictionaryGetValue(properties, CFSTR("DesignCapacity")), &design);
        if (!cf_int64(CFDictionaryGetValue(properties, CFSTR("AppleRawMaxCapacity")), &maximum))
            (void)cf_int64(CFDictionaryGetValue(properties, CFSTR("NominalChargeCapacity")),
                &maximum);
        if (design > 0 && maximum > 0)
            number_field(L, "health_percent", (double)maximum * 100 / (double)design);
        if (cf_int64(CFDictionaryGetValue(properties, CFSTR("Voltage")), &voltage)
            && voltage > 0) {
            number_field(L, "voltage_volts", voltage / 1000.0);
            if (cf_int64(CFDictionaryGetValue(properties, CFSTR("InstantAmperage")), &amperage)
                || cf_int64(CFDictionaryGetValue(properties, CFSTR("Amperage")), &amperage)) {
                /* Negative current is discharge; power is reported as a
                 * magnitude, like the Linux power_now attribute. */
                double watts = (double)(amperage < 0 ? -amperage : amperage)
                    * (double)voltage / 1e6;
                number_field(L, "power_watts", watts);
            }
            if (design > 0) number_field(L, "energy_design_watt_hours",
                (double)design * voltage / 1e6);
            if (maximum > 0) number_field(L, "energy_full_watt_hours",
                (double)maximum * voltage / 1e6);
        }
        if (cf_int64(CFDictionaryGetValue(properties, CFSTR("Temperature")), &value))
            number_field(L, "temperature_celsius", value / 100.0);
        CFRelease(properties);
    }
    IOObjectRelease(service);
}

static int l_collect_power_supply(lua_State *L) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
    CFStringRef providing = info ? IOPSGetProvidingPowerSourceType(info) : NULL;
    int batteries = 0, on_ac = 0;
    double capacity_sum = 0;
    int charging = 0, discharging = 0;
    if (providing && CFStringCompare(providing, CFSTR(kIOPSACPowerValue), 0)
        == kCFCompareEqualTo) on_ac = 1;
    lua_createtable(L, 0, 5);
    lua_createtable(L, 1, 0);
    for (CFIndex index = 0; list && index < CFArrayGetCount(list); ++index) {
        CFDictionaryRef source = IOPSGetPowerSourceDescription(info,
            CFArrayGetValueAtIndex(list, index));
        char text[64];
        int64_t current = -1, maximum = -1, minutes = -1;
        int present = 1, is_charging = 0, charged = 0;
        if (!source || !cf_text(CFDictionaryGetValue(source, CFSTR(kIOPSTypeKey)),
            text, sizeof(text)) || strcmp(text, kIOPSInternalBatteryType) != 0) continue;
        (void)cf_bool(CFDictionaryGetValue(source, CFSTR(kIOPSIsPresentKey)), &present);
        if (!present) continue;
        ++batteries;
        lua_createtable(L, 0, 14);
        snprintf(text, sizeof(text), "BAT%d", batteries - 1);
        string_field(L, "id", text);
        if (cf_text(CFDictionaryGetValue(source, CFSTR(kIOPSNameKey)), text, sizeof(text)))
            string_field(L, "name", text);
        else string_field(L, "name", "Battery");
        string_field(L, "type", "Battery");
        boolean_field(L, "present", 1);
        (void)cf_int64(CFDictionaryGetValue(source, CFSTR(kIOPSCurrentCapacityKey)), &current);
        (void)cf_int64(CFDictionaryGetValue(source, CFSTR(kIOPSMaxCapacityKey)), &maximum);
        (void)cf_bool(CFDictionaryGetValue(source, CFSTR(kIOPSIsChargingKey)), &is_charging);
        (void)cf_bool(CFDictionaryGetValue(source, CFSTR(kIOPSIsChargedKey)), &charged);
        if (current >= 0 && maximum > 0) {
            double percent = (double)current * 100 / (double)maximum;
            number_field(L, "capacity_percent", percent);
            capacity_sum += percent;
        }
        string_field(L, "status", is_charging ? "Charging"
            : charged ? "Full" : on_ac ? "Not charging" : "Discharging");
        charging |= is_charging;
        discharging |= !on_ac;
        if (!on_ac && cf_int64(CFDictionaryGetValue(source, CFSTR(kIOPSTimeToEmptyKey)),
            &minutes) && minutes > 0)
            integer_field(L, "time_remaining_seconds", minutes * 60);
        if (is_charging && cf_int64(CFDictionaryGetValue(source,
            CFSTR(kIOPSTimeToFullChargeKey)), &minutes) && minutes > 0)
            integer_field(L, "time_to_full_seconds", minutes * 60);
        battery_details(L);
        string_field(L, "quality", current >= 0 ? "fresh" : "partial");
        string_field(L, "source", "iokit:IOPowerSources");
        lua_rawseti(L, -2, batteries);
    }
    lua_setfield(L, -2, "batteries");
    if (list) CFRelease(list);
    if (info) CFRelease(info);
    if (batteries == 0) {
        /* Desktops report like a Linux host without power-supply entries. */
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "no_power_supplies");
        return 2;
    }
    lua_createtable(L, 1, 0);
    lua_createtable(L, 0, 5);
    string_field(L, "id", "AC");
    string_field(L, "name", "AC");
    string_field(L, "type", "Mains");
    boolean_field(L, "online", on_ac);
    boolean_field(L, "present", 1);
    lua_rawseti(L, -2, 1);
    lua_setfield(L, -2, "supplies");
    lua_createtable(L, 0, 3);
    integer_field(L, "count", batteries);
    number_field(L, "capacity_percent", capacity_sum / batteries);
    string_field(L, "state", charging ? "charging" : discharging ? "discharging" : "idle");
    lua_setfield(L, -2, "summary");
    boolean_field(L, "on_ac_power", on_ac);
    return 1;
}

/* ------------------------------------------------------------------------
 * Sockets: each readable process's socket descriptors. Without root only
 * the caller's own processes are readable, and the result says so. */

/* Open-addressing set of kernel socket handles; zero marks a free slot. */
#define SOCKET_SET_SIZE 32768

static int socket_set_insert(uint64_t *set, uint64_t handle) {
    uint64_t slot = (handle >> 4) * 0x9e3779b97f4a7c15ULL;
    if (handle == 0) return 1;
    for (int probe = 0; probe < SOCKET_SET_SIZE; ++probe) {
        uint64_t *entry = &set[(slot + (uint64_t)probe) & (SOCKET_SET_SIZE - 1)];
        if (*entry == handle) return 0;
        if (*entry == 0) {
            *entry = handle;
            return 1;
        }
    }
    return 0;
}

/* TSI_S_* numbering onto MIB_TCP_STATE, which the shared collector maps. */
static int tcp_state(int state) {
    static const int map[] = {1, 2, 3, 4, 5, 8, 6, 9, 10, 7, 11};
    return state >= 0 && state < (int)(sizeof(map) / sizeof(map[0])) ? map[state] : 0;
}

static void push_endpoint(lua_State *L, int ipv6, const struct in_sockinfo *info,
    int remote) {
    char text[INET6_ADDRSTRLEN];
    const char *address_field = remote ? "remote_address" : "local_address";
    if (ipv6) {
        const struct in6_addr *address = remote ? &info->insi_faddr.ina_6
            : &info->insi_laddr.ina_6;
        lua_pushlstring(L, (const char *)address->s6_addr, 16);
        lua_setfield(L, -2, remote ? "remote_address_bytes" : "local_address_bytes");
    } else {
        const struct in_addr *address = remote ? &info->insi_faddr.ina_46.i46a_addr4
            : &info->insi_laddr.ina_46.i46a_addr4;
        if (inet_ntop(AF_INET, address, text, sizeof(text)))
            string_field(L, address_field, text);
    }
    integer_field(L, remote ? "remote_port" : "local_port",
        ntohs((uint16_t)(remote ? info->insi_fport : info->insi_lport)));
}

static int l_collect_connections(lua_State *L) {
    pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * MAX_PIDS);
    struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc(
        sizeof(struct proc_fdinfo) * MAX_FDS_PER_PROCESS);
    uint64_t *seen = (uint64_t *)calloc(SOCKET_SET_SIZE, sizeof(uint64_t));
    int bytes, count, output = 1, seen_count = 0, denied = 0, truncated = 0;
    pid_t self = getpid();
    uid_t uid = getuid();
    if (!pids || !fds || !seen) {
        free(pids);
        free(fds);
        free(seen);
        return luaL_error(L, "out of memory collecting sockets");
    }
    bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)(sizeof(pid_t) * MAX_PIDS));
    count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    lua_createtable(L, 0, 6);
    lua_createtable(L, 64, 0);
    for (int index = 0; index < count && !truncated; ++index) {
        pid_t pid = pids[index];
        int fd_bytes, fd_count;
        char name[2 * MAXCOMLEN + 1];
        int named = 0;
        if (pid <= 0) continue;
        fd_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds,
            (int)(sizeof(struct proc_fdinfo) * MAX_FDS_PER_PROCESS));
        if (fd_bytes <= 0) {
            if (errno == EPERM || errno == EACCES) ++denied;
            continue;
        }
        fd_count = fd_bytes / (int)sizeof(struct proc_fdinfo);
        if (fd_count >= MAX_FDS_PER_PROCESS) truncated = 1;
        for (int fd = 0; fd < fd_count; ++fd) {
            struct socket_fdinfo socket_info;
            const struct in_sockinfo *in;
            int kind, ipv6;
            if (fds[fd].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            if (proc_pidfdinfo(pid, fds[fd].proc_fd, PROC_PIDFDSOCKETINFO,
                &socket_info, sizeof(socket_info)) != sizeof(socket_info)) continue;
            kind = socket_info.psi.soi_kind;
            if (kind != SOCKINFO_TCP && kind != SOCKINFO_IN) continue;
            if (socket_info.psi.soi_family != AF_INET
                && socket_info.psi.soi_family != AF_INET6) continue;
            /* A socket inherited across fork appears in every holder. */
            if (seen_count >= MAX_SOCKETS) {
                truncated = 1;
                break;
            }
            if (!socket_set_insert(seen, socket_info.psi.soi_so)) continue;
            ++seen_count;
            in = kind == SOCKINFO_TCP ? &socket_info.psi.soi_proto.pri_tcp.tcpsi_ini
                : &socket_info.psi.soi_proto.pri_in;
            ipv6 = (in->insi_vflag & INI_IPV6) != 0 && !(in->insi_vflag & INI_IPV4);
            if (!named) {
                memset(name, 0, sizeof(name));
                if (proc_name(pid, name, sizeof(name)) <= 0)
                    snprintf(name, sizeof(name), "PID %d", pid);
                named = 1;
            }
            lua_createtable(L, 0, 11);
            string_field(L, "protocol", kind == SOCKINFO_TCP ? "tcp" : "udp");
            string_field(L, "family", ipv6 ? "ipv6" : "ipv4");
            push_endpoint(L, ipv6, in, 0);
            push_endpoint(L, ipv6, in, 1);
            if (kind == SOCKINFO_TCP)
                integer_field(L, "tcp_state",
                    tcp_state(socket_info.psi.soi_proto.pri_tcp.tcpsi_state));
            integer_field(L, "pid", pid);
            string_field(L, "owner_name", name);
            lua_rawseti(L, -2, output++);
        }
    }
    lua_setfield(L, -2, "connections");
    boolean_field(L, "owners_available", 1);
    boolean_field(L, "truncated", truncated);
    integer_field(L, "denied_processes", denied);
    boolean_field(L, "privileged", uid == 0);
    integer_field(L, "scanner_pid", self);
    free(pids);
    free(fds);
    free(seen);
    return 1;
}

/* ------------------------------------------------------------------------
 * Workloads: resource coalitions. launchd places each job, and each app
 * with its XPC helpers, in one coalition, the grouping Activity Monitor
 * uses. The coalition flavor of proc_pidinfo has no SDK declaration. */

#define PROC_PIDCOALITIONINFO_FLAVOR 20

typedef struct {
    uint64_t coalition_id[2];
    uint64_t reserved[3];
} coalition_info;

typedef struct {
    uint64_t id;
    pid_t leader;
    pid_t leader_parent;
    int leader_rank;
    int processes;
    int denied;
    uint64_t cpu_ns, resident, read_bytes, written_bytes;
    int has_cpu, has_io;
    char name[2 * MAXCOMLEN + 1];
} coalition_total;

static int l_collect_cgroup(lua_State *L) {
    pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * MAX_PIDS);
    coalition_total *groups = (coalition_total *)calloc(MAX_COALITIONS,
        sizeof(coalition_total));
    int bytes, count, group_count = 0, unreadable = 0, truncated = 0;
    uint64_t total_resident = 0;
    if (!pids || !groups) {
        free(pids);
        free(groups);
        return luaL_error(L, "out of memory collecting coalitions");
    }
    bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)(sizeof(pid_t) * MAX_PIDS));
    count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    for (int index = 0; index < count; ++index) {
        pid_t pid = pids[index];
        coalition_info coalition;
        struct proc_bsdinfo bsd;
        struct proc_taskinfo task;
        struct rusage_info_v2 usage;
        coalition_total *group = NULL;
        int rank;
        if (pid <= 0) continue;
        memset(&coalition, 0, sizeof(coalition));
        if (proc_pidinfo(pid, PROC_PIDCOALITIONINFO_FLAVOR, 0, &coalition,
            sizeof(coalition)) != sizeof(coalition) || coalition.coalition_id[0] == 0) {
            ++unreadable;
            continue;
        }
        for (int other = 0; other < group_count; ++other) {
            if (groups[other].id == coalition.coalition_id[0]) {
                group = &groups[other];
                break;
            }
        }
        if (!group) {
            if (group_count >= MAX_COALITIONS) {
                truncated = 1;
                continue;
            }
            group = &groups[group_count++];
            group->id = coalition.coalition_id[0];
            group->leader = -1;
            group->leader_rank = 1 << 30;
        }
        group->processes += 1;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) {
            group->denied += 1;
            continue;
        }
        /* The leader is the member launchd started; ties go to the oldest. */
        rank = bsd.pbi_ppid == 1 ? pid : (1 << 29) + pid;
        if (rank < group->leader_rank) {
            group->leader_rank = rank;
            group->leader = pid;
            group->leader_parent = (pid_t)bsd.pbi_ppid;
            memset(group->name, 0, sizeof(group->name));
            if (proc_name(pid, group->name, sizeof(group->name)) <= 0)
                snprintf(group->name, sizeof(group->name), "%s", bsd.pbi_comm);
        }
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
            group->cpu_ns += wtop_mach_to_ns(task.pti_total_user + task.pti_total_system);
            group->resident += task.pti_resident_size;
            group->has_cpu = 1;
        } else {
            group->denied += 1;
        }
        if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) == 0) {
            group->read_bytes += usage.ri_diskio_bytesread;
            group->written_bytes += usage.ri_diskio_byteswritten;
            group->has_io = 1;
        }
    }
    lua_createtable(L, 0, 6);
    string_field(L, "schema", "dev.waterrun.wtop.macos-coalitions/v1");
    string_field(L, "kind", "coalition");
    lua_createtable(L, group_count + 1, 0);
    lua_createtable(L, 0, 8);
    string_field(L, "id", "coalitions");
    string_field(L, "name", "Applications");
    integer_field(L, "depth", 0);
    boolean_field(L, "accessible", 1);
    lua_rawseti(L, -2, 1);
    for (int index = 0; index < group_count; ++index) {
        coalition_total *group = &groups[index];
        char id[48];
        lua_createtable(L, 0, 12);
        snprintf(id, sizeof(id), "coalition:%llu", (unsigned long long)group->id);
        string_field(L, "id", id);
        string_field(L, "parent_id", "coalitions");
        integer_field(L, "depth", 1);
        integer_field(L, "coalition_id", (lua_Integer)group->id);
        if (group->leader > 0) integer_field(L, "leader_pid", group->leader);
        string_field(L, "name", group->name[0] ? group->name : id);
        boolean_field(L, "accessible", group->has_cpu);
        boolean_field(L, "partial", group->denied > 0);
        lua_createtable(L, 0, 1);
        integer_field(L, "count", group->processes);
        lua_setfield(L, -2, "processes");
        if (group->has_cpu) {
            lua_createtable(L, 0, 1);
            integer_field(L, "usage_ns", (lua_Integer)group->cpu_ns);
            lua_setfield(L, -2, "raw_cpu");
            lua_createtable(L, 0, 1);
            integer_field(L, "current_bytes", (lua_Integer)group->resident);
            lua_setfield(L, -2, "memory");
            total_resident += group->resident;
        }
        if (group->has_io) {
            lua_createtable(L, 0, 2);
            integer_field(L, "rbytes", (lua_Integer)group->read_bytes);
            integer_field(L, "wbytes", (lua_Integer)group->written_bytes);
            lua_setfield(L, -2, "raw_io");
        }
        lua_rawseti(L, -2, index + 2);
    }
    /* Fill the root's totals now that every group is known. */
    lua_rawgeti(L, -1, 1);
    lua_createtable(L, 0, 1);
    integer_field(L, "count", count - unreadable);
    lua_setfield(L, -2, "processes");
    lua_createtable(L, 0, 1);
    integer_field(L, "current_bytes", (lua_Integer)total_resident);
    lua_setfield(L, -2, "memory");
    boolean_field(L, "partial", unreadable > 0);
    lua_pop(L, 1);
    lua_setfield(L, -2, "workloads");
    integer_field(L, "unreadable_processes", unreadable);
    boolean_field(L, "truncated", truncated);
    free(pids);
    free(groups);
    if (group_count == 0) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "coalition_query_unavailable");
        return 2;
    }
    return 1;
}

static const luaL_Reg hardware_functions[] = {
#ifndef WTOP_HARDWARE_WORKER
    {"hardware_worker_open", wtop_hardware_worker_open},
    {"hardware_worker_query", wtop_hardware_worker_query},
    {"hardware_worker_close", wtop_hardware_worker_close},
#endif
    {"collect_gpu", wtop_collect_gpu},
    {"collect_hwmon", wtop_collect_hwmon},
    {"collect_powercap", wtop_collect_powercap},
    {"collect_cpufreq", wtop_collect_cpufreq},
    {"collect_power_supply", l_collect_power_supply},
    {"collect_connections", l_collect_connections},
    {"collect_cgroup", l_collect_cgroup},
    {"collect_inventory", wtop_collect_inventory},
    {NULL, NULL},
};

void wtop_register_hardware(lua_State *L) {
    luaL_setfuncs(L, hardware_functions, 0);
#ifndef WTOP_HARDWARE_WORKER
    static const char *const sources[]={WTOP_HARDWARE_NAMES};
    lua_createtable(L,0,WTOP_HARDWARE_COUNT);
    for(unsigned i=0;i<WTOP_HARDWARE_COUNT;++i){lua_pushboolean(L,1);lua_setfield(L,-2,sources[i]);}
    lua_setfield(L,-2,"hardware_worker_sources");
#endif
}
