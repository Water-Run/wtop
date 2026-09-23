/* Win32 network tables that need Vista-era declarations. Everything here is
 * resolved with GetProcAddress, so the module still loads on Windows XP and
 * each caller falls back to the XP-era table when an export is missing. */
#define WINVER 0x0600
#define _WIN32_WINNT 0x0600
#define NTDDI_VERSION 0x06000000
#define WIN32_LEAN_AND_MEAN

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>

#include "wtop_windows.h"

#define MAX_TABLE_BYTES (16 * 1024 * 1024)
#define MAX_CONNECTIONS 16384
#define MAX_OWNER_NAMES 8192

typedef DWORD (WINAPI *if_table2_function)(PMIB_IF_TABLE2 *);
typedef VOID (WINAPI *free_mib_table_function)(PVOID);
typedef DWORD (WINAPI *extended_tcp_function)(PVOID, PDWORD, BOOL, ULONG,
    TCP_TABLE_CLASS, ULONG);
typedef DWORD (WINAPI *extended_udp_function)(PVOID, PDWORD, BOOL, ULONG,
    UDP_TABLE_CLASS, ULONG);
typedef DWORD (WINAPI *tcp_table_function)(PMIB_TCPTABLE, PDWORD, BOOL);
typedef DWORD (WINAPI *udp_table_function)(PMIB_UDPTABLE, PDWORD, BOOL);

static FARPROC iphlpapi_export(const char *name) {
    HMODULE module = GetModuleHandleA("iphlpapi.dll");
    if (!module) module = LoadLibraryA("iphlpapi.dll");
    return module ? GetProcAddress(module, name) : NULL;
}

static void push_mac(lua_State *L, const UCHAR *address, ULONG length) {
    char text[3 * 32];
    ULONG index, nonzero = 0;
    if (length == 0 || length > 32) return;
    for (index = 0; index < length; ++index) {
        nonzero |= address[index];
        snprintf(text + index * 3, 4, index + 1 < length ? "%02x:" : "%02x",
            address[index]);
    }
    if (!nonzero) return;
    lua_pushstring(L, text);
    lua_setfield(L, -2, "address");
}

/* Returns 1 with the interface table pushed, or 0 when GetIfTable2 is not
 * available so the caller can use the 32-bit XP counters instead. */
int wtop_push_if_table2(lua_State *L) {
    if_table2_function get_table =
        (if_table2_function)(void *)iphlpapi_export("GetIfTable2");
    free_mib_table_function free_table =
        (free_mib_table_function)(void *)iphlpapi_export("FreeMibTable");
    PMIB_IF_TABLE2 table = NULL;
    ULONG index;
    int output_index = 1;
    if (!get_table || !free_table || get_table(&table) != NO_ERROR || !table)
        return 0;
    lua_createtable(L, 0, 2);
    lua_createtable(L, 16, 0);
    for (index = 0; index < table->NumEntries; ++index) {
        const MIB_IF_ROW2 *row = &table->Table[index];
        int up = row->OperStatus == IfOperStatusUp;
        /* Vista+ lists every NDIS filter layer, WAN miniport, and tunnel
         * pseudo-adapter as its own interface. Keep physical adapters, the
         * loopback, and software interfaces that have carried traffic. */
        if (row->InterfaceAndOperStatusFlags.FilterInterface) continue;
        if (!row->InterfaceAndOperStatusFlags.HardwareInterface
            && row->Type != IF_TYPE_SOFTWARE_LOOPBACK
            && (!up || row->InOctets + row->OutOctets == 0)) continue;
        lua_createtable(L, 0, 10);
        lua_pushinteger(L, (lua_Integer)row->InterfaceIndex);
        lua_setfield(L, -2, "id");
        wtop_push_utf8(L, row->Alias[0] ? row->Alias : row->Description);
        lua_setfield(L, -2, "name");
        wtop_push_utf8(L, row->Description);
        lua_setfield(L, -2, "description");
        lua_pushstring(L, up ? "up" : "down");
        lua_setfield(L, -2, "operstate");
        lua_pushinteger(L, (lua_Integer)row->Mtu);
        lua_setfield(L, -2, "mtu");
        lua_pushboolean(L, row->InterfaceAndOperStatusFlags.HardwareInterface);
        lua_setfield(L, -2, "hardware");
        if (row->TransmitLinkSpeed > 0 && row->TransmitLinkSpeed != (ULONG64)-1) {
            lua_pushinteger(L, (lua_Integer)(row->TransmitLinkSpeed / 1000000ULL));
            lua_setfield(L, -2, "speed_mbps");
        }
        push_mac(L, row->PhysicalAddress, row->PhysicalAddressLength);
        lua_createtable(L, 0, 6);
        lua_pushinteger(L, (lua_Integer)row->InOctets);
        lua_setfield(L, -2, "rx_bytes");
        lua_pushinteger(L, (lua_Integer)row->OutOctets);
        lua_setfield(L, -2, "tx_bytes");
        lua_pushinteger(L, (lua_Integer)row->InErrors);
        lua_setfield(L, -2, "rx_errors");
        lua_pushinteger(L, (lua_Integer)row->OutErrors);
        lua_setfield(L, -2, "tx_errors");
        lua_pushinteger(L, (lua_Integer)row->InDiscards);
        lua_setfield(L, -2, "rx_drops");
        lua_pushinteger(L, (lua_Integer)row->OutDiscards);
        lua_setfield(L, -2, "tx_drops");
        lua_setfield(L, -2, "counters");
        lua_rawseti(L, -2, output_index++);
    }
    free_table(table);
    lua_setfield(L, -2, "interfaces");
    lua_pushinteger(L, 64);
    lua_setfield(L, -2, "counter_bits");
    return 1;
}

typedef struct {
    DWORD pid;
    WCHAR name[MAX_PATH];
} owner_name;

static int owner_compare(const void *left, const void *right) {
    DWORD a = ((const owner_name *)left)->pid;
    DWORD b = ((const owner_name *)right)->pid;
    return a < b ? -1 : a > b ? 1 : 0;
}

static owner_name *owner_names(size_t *count) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W entry;
    owner_name *names;
    size_t used = 0;
    *count = 0;
    if (snapshot == INVALID_HANDLE_VALUE) return NULL;
    names = (owner_name *)malloc(sizeof(*names) * MAX_OWNER_NAMES);
    if (!names) {
        CloseHandle(snapshot);
        return NULL;
    }
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            if (used >= MAX_OWNER_NAMES) break;
            names[used].pid = entry.th32ProcessID;
            memcpy(names[used].name, entry.szExeFile, sizeof(names[used].name));
            names[used].name[MAX_PATH - 1] = 0;
            ++used;
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    qsort(names, used, sizeof(*names), owner_compare);
    *count = used;
    return names;
}

static const WCHAR *owner_lookup(const owner_name *names, size_t count, DWORD pid) {
    owner_name key;
    const owner_name *found;
    if (!names) return NULL;
    key.pid = pid;
    found = (const owner_name *)bsearch(&key, names, count, sizeof(*names),
        owner_compare);
    return found ? found->name : NULL;
}

static void *query_table(DWORD (*call)(void *, void *, PDWORD), void *context,
    DWORD *status) {
    DWORD size = 0;
    void *buffer = NULL;
    int attempt;
    *status = call(context, NULL, &size);
    /* An empty table can succeed without a buffer; hand back a zeroed one so
     * callers read dwNumEntries == 0 rather than treating it as missing. */
    if (*status == NO_ERROR) return calloc(1, 256);
    for (attempt = 0; attempt < 4; ++attempt) {
        void *grown;
        if (*status != ERROR_INSUFFICIENT_BUFFER || size == 0
            || size > MAX_TABLE_BYTES) break;
        size += 4096; /* Leave room for sockets opened between the two calls. */
        grown = realloc(buffer, size);
        if (!grown) {
            *status = ERROR_NOT_ENOUGH_MEMORY;
            break;
        }
        buffer = grown;
        *status = call(context, buffer, &size);
        if (*status == NO_ERROR) return buffer;
    }
    free(buffer);
    return NULL;
}

typedef struct {
    FARPROC function;
    ULONG family;
    int extended;
} table_request;

static DWORD call_tcp(void *context, void *buffer, PDWORD size) {
    table_request *request = (table_request *)context;
    if (request->extended)
        return ((extended_tcp_function)(void *)request->function)(buffer, size,
            FALSE, request->family, TCP_TABLE_OWNER_PID_ALL, 0);
    return ((tcp_table_function)(void *)request->function)(
        (PMIB_TCPTABLE)buffer, size, FALSE);
}

static DWORD call_udp(void *context, void *buffer, PDWORD size) {
    table_request *request = (table_request *)context;
    if (request->extended)
        return ((extended_udp_function)(void *)request->function)(buffer, size,
            FALSE, request->family, UDP_TABLE_OWNER_PID, 0);
    return ((udp_table_function)(void *)request->function)(
        (PMIB_UDPTABLE)buffer, size, FALSE);
}

typedef struct {
    lua_State *L;
    int index;
    int truncated;
    const owner_name *names;
    size_t name_count;
} connection_output;

static void push_ipv4(lua_State *L, const char *field, DWORD address) {
    const unsigned char *bytes = (const unsigned char *)&address;
    lua_pushfstring(L, "%d.%d.%d.%d", bytes[0], bytes[1], bytes[2], bytes[3]);
    lua_setfield(L, -2, field);
}

static void push_ipv6(lua_State *L, const char *field, const UCHAR *address) {
    lua_pushlstring(L, (const char *)address, 16);
    lua_setfield(L, -2, field);
}

static void push_port(lua_State *L, const char *field, DWORD port) {
    lua_pushinteger(L, (lua_Integer)(((port & 0xff) << 8) | ((port >> 8) & 0xff)));
    lua_setfield(L, -2, field);
}

static int begin_row(connection_output *output, const char *protocol,
    const char *family) {
    if (output->index > MAX_CONNECTIONS) {
        output->truncated = 1;
        return 0;
    }
    lua_createtable(output->L, 0, 10);
    lua_pushstring(output->L, protocol);
    lua_setfield(output->L, -2, "protocol");
    lua_pushstring(output->L, family);
    lua_setfield(output->L, -2, "family");
    return 1;
}

static void finish_row(connection_output *output, int has_pid, DWORD pid) {
    lua_State *L = output->L;
    if (has_pid && pid != 0) {
        const WCHAR *name = owner_lookup(output->names, output->name_count, pid);
        lua_pushinteger(L, (lua_Integer)pid);
        lua_setfield(L, -2, "pid");
        if (name && name[0]) {
            wtop_push_utf8(L, name);
            lua_setfield(L, -2, "owner_name");
        }
    }
    lua_rawseti(L, -2, output->index++);
}

static int collect_tcp(connection_output *output, ULONG family) {
    lua_State *L = output->L;
    table_request request;
    DWORD status, index;
    void *table;
    request.family = family;
    request.function = iphlpapi_export("GetExtendedTcpTable");
    request.extended = request.function != NULL;
    if (!request.extended) {
        if (family != AF_INET) return 0;
        request.function = iphlpapi_export("GetTcpTable");
        if (!request.function) return 0;
    }
    table = query_table(call_tcp, &request, &status);
    if (!table) return 0;
    if (family == AF_INET6) {
        PMIB_TCP6TABLE_OWNER_PID rows = (PMIB_TCP6TABLE_OWNER_PID)table;
        for (index = 0; index < rows->dwNumEntries; ++index) {
            const MIB_TCP6ROW_OWNER_PID *row = &rows->table[index];
            if (!begin_row(output, "tcp", "ipv6")) break;
            push_ipv6(L, "local_address_bytes", row->ucLocalAddr);
            push_port(L, "local_port", row->dwLocalPort);
            push_ipv6(L, "remote_address_bytes", row->ucRemoteAddr);
            push_port(L, "remote_port", row->dwRemotePort);
            lua_pushinteger(L, (lua_Integer)row->dwState);
            lua_setfield(L, -2, "tcp_state");
            finish_row(output, 1, row->dwOwningPid);
        }
    } else if (request.extended) {
        PMIB_TCPTABLE_OWNER_PID rows = (PMIB_TCPTABLE_OWNER_PID)table;
        for (index = 0; index < rows->dwNumEntries; ++index) {
            const MIB_TCPROW_OWNER_PID *row = &rows->table[index];
            if (!begin_row(output, "tcp", "ipv4")) break;
            push_ipv4(L, "local_address", row->dwLocalAddr);
            push_port(L, "local_port", row->dwLocalPort);
            push_ipv4(L, "remote_address", row->dwRemoteAddr);
            push_port(L, "remote_port", row->dwRemotePort);
            lua_pushinteger(L, (lua_Integer)row->dwState);
            lua_setfield(L, -2, "tcp_state");
            finish_row(output, 1, row->dwOwningPid);
        }
    } else {
        PMIB_TCPTABLE rows = (PMIB_TCPTABLE)table;
        for (index = 0; index < rows->dwNumEntries; ++index) {
            const MIB_TCPROW *row = &rows->table[index];
            if (!begin_row(output, "tcp", "ipv4")) break;
            push_ipv4(L, "local_address", row->dwLocalAddr);
            push_port(L, "local_port", row->dwLocalPort);
            push_ipv4(L, "remote_address", row->dwRemoteAddr);
            push_port(L, "remote_port", row->dwRemotePort);
            lua_pushinteger(L, (lua_Integer)row->dwState);
            lua_setfield(L, -2, "tcp_state");
            finish_row(output, 0, 0);
        }
    }
    free(table);
    return request.extended ? 2 : 1;
}

static int collect_udp(connection_output *output, ULONG family) {
    lua_State *L = output->L;
    table_request request;
    DWORD status, index;
    void *table;
    request.family = family;
    request.function = iphlpapi_export("GetExtendedUdpTable");
    request.extended = request.function != NULL;
    if (!request.extended) {
        if (family != AF_INET) return 0;
        request.function = iphlpapi_export("GetUdpTable");
        if (!request.function) return 0;
    }
    table = query_table(call_udp, &request, &status);
    if (!table) return 0;
    if (family == AF_INET6) {
        PMIB_UDP6TABLE_OWNER_PID rows = (PMIB_UDP6TABLE_OWNER_PID)table;
        for (index = 0; index < rows->dwNumEntries; ++index) {
            const MIB_UDP6ROW_OWNER_PID *row = &rows->table[index];
            if (!begin_row(output, "udp", "ipv6")) break;
            push_ipv6(L, "local_address_bytes", row->ucLocalAddr);
            push_port(L, "local_port", row->dwLocalPort);
            finish_row(output, 1, row->dwOwningPid);
        }
    } else if (request.extended) {
        PMIB_UDPTABLE_OWNER_PID rows = (PMIB_UDPTABLE_OWNER_PID)table;
        for (index = 0; index < rows->dwNumEntries; ++index) {
            const MIB_UDPROW_OWNER_PID *row = &rows->table[index];
            if (!begin_row(output, "udp", "ipv4")) break;
            push_ipv4(L, "local_address", row->dwLocalAddr);
            push_port(L, "local_port", row->dwLocalPort);
            finish_row(output, 1, row->dwOwningPid);
        }
    } else {
        PMIB_UDPTABLE rows = (PMIB_UDPTABLE)table;
        for (index = 0; index < rows->dwNumEntries; ++index) {
            const MIB_UDPROW *row = &rows->table[index];
            if (!begin_row(output, "udp", "ipv4")) break;
            push_ipv4(L, "local_address", row->dwLocalAddr);
            push_port(L, "local_port", row->dwLocalPort);
            finish_row(output, 0, 0);
        }
    }
    free(table);
    return request.extended ? 2 : 1;
}

int wtop_collect_connections(lua_State *L) {
    connection_output output;
    owner_name *names;
    size_t name_count = 0;
    int tcp4, tcp6, udp4, udp6;
    names = owner_names(&name_count);
    output.L = L;
    output.index = 1;
    output.truncated = 0;
    output.names = names;
    output.name_count = name_count;
    lua_createtable(L, 0, 5);
    lua_createtable(L, 64, 0);
    tcp4 = collect_tcp(&output, AF_INET);
    tcp6 = collect_tcp(&output, AF_INET6);
    udp4 = collect_udp(&output, AF_INET);
    udp6 = collect_udp(&output, AF_INET6);
    free(names);
    lua_setfield(L, -2, "connections");
    if (!tcp4 && !udp4) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "socket tables are unavailable");
        return 2;
    }
    lua_pushboolean(L, output.truncated);
    lua_setfield(L, -2, "truncated");
    lua_pushboolean(L, tcp4 == 2 || udp4 == 2);
    lua_setfield(L, -2, "owners_available");
    lua_pushboolean(L, (tcp4 && !tcp6) || (udp4 && !udp6));
    lua_setfield(L, -2, "ipv6_unavailable");
    lua_pushinteger(L, MAX_CONNECTIONS);
    lua_setfield(L, -2, "limit");
    return 1;
}
