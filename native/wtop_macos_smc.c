/* Read-only AppleSMC transport. Private ABI support is optional at runtime. */
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "wtop_macos.h"

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } smc_version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } smc_limits;
typedef struct { uint32_t data_size, data_type; uint8_t data_attributes; } smc_key_info;
typedef struct {
    uint32_t key;
    smc_version version;
    smc_limits limits;
    smc_key_info info;
    uint8_t result, status, command;
    uint32_t data32;
    uint8_t bytes[32];
} smc_message;

static io_connect_t connection;
static uint64_t epoch;
static int attempted, cleanup_registered;
static void smc_close(void) {
    if (connection) IOServiceClose(connection);
    connection = 0;
}
void wtop_smc_begin(void) { attempted = 0; }
uint64_t wtop_smc_epoch(void) { return epoch; }

static uint32_t four_cc(const char *text) {
    return ((uint32_t)(uint8_t)text[0] << 24) | ((uint32_t)(uint8_t)text[1] << 16)
        | ((uint32_t)(uint8_t)text[2] << 8) | (uint8_t)text[3];
}
static int smc_open(void) {
    if (connection) return 1;
    if (attempted) return 0;
    attempted = 1;
    io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t opened = 0;
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &opened);
    IOObjectRelease(service);
    if (status != KERN_SUCCESS || !opened) {
        if (opened) IOServiceClose(opened);
        return 0;
    }
    connection = opened;
    ++epoch;
    if (!cleanup_registered) { atexit(smc_close); cleanup_registered = 1; }
    return 1;
}
static int hex_digit(unsigned char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}
/* Numeric formats have exact declared sizes. SMC sp values carry a sign bit
 * and a magnitude; they are not a two's-complement signed integer. */
static int decode_number(uint32_t type, const uint8_t *bytes, uint32_t size, double *value) {
    double result;
    if (type == four_cc("flt ") && size == 4) {
        float number;
        memcpy(&number, bytes, sizeof(number)); result = number;
    } else if (type == four_cc("ui8 ") && size == 1) result = bytes[0];
    else if (type == four_cc("ui16") && size == 2) result = ((uint32_t)bytes[0] << 8) | bytes[1];
    else if (type == four_cc("ui32") && size == 4)
        result = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16)
            | ((uint32_t)bytes[2] << 8) | bytes[3];
    else {
        unsigned char first = (unsigned char)(type >> 24), second = (unsigned char)(type >> 16);
        int integer = hex_digit((unsigned char)(type >> 8)), fraction = hex_digit((unsigned char)type);
        int signed_value = first == 's' && second == 'p';
        if (size != 2 || (!signed_value && !(first == 'f' && second == 'p'))
            || integer < 1 || fraction < 0 || integer + fraction != (signed_value ? 15 : 16)) return 0;
        unsigned raw = ((unsigned)bytes[0] << 8) | bytes[1];
        result = (signed_value ? raw & 0x7fff : raw) / (double)(1u << fraction);
        if (signed_value && (raw & 0x8000)) result = -result;
    }
    if (!isfinite(result)) return 0;
    *value = result;
    return 1;
}
static int smc_call(const smc_message *input, smc_message *output, size_t required) {
    size_t size = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t status = IOConnectCallStructMethod(connection, 2,
        input, sizeof(*input), output, &size);
    if (status != KERN_SUCCESS) { attempted = 1; smc_close(); return 0; }
    return size >= required && size <= sizeof(*output) && output->result == 0;
}
int wtop_smc_number(const char *key, double *value) {
    smc_message input, output;
    if (!key || !value || strlen(key) != 4) return 0;
    for (unsigned i = 0; i < 4; ++i) if ((unsigned char)key[i] < 32 || (unsigned char)key[i] > 126) return 0;
    if (!smc_open()) return 0;
    memset(&input, 0, sizeof(input));
    input.key = four_cc(key); input.command = 9;
    if (!smc_call(&input, &output, offsetof(smc_message, bytes))) return 0;
    uint32_t type = output.info.data_type, size = output.info.data_size;
    if (!size || size > sizeof(output.bytes)) return 0;
    input.info.data_size = size; input.command = 5;
    if (!smc_call(&input, &output, offsetof(smc_message, bytes) + size)) return 0;
    return decode_number(type, output.bytes, size, value);
}
