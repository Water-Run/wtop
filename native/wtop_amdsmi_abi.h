/*
 * Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
/* Complete AMD SMI output layouts, selected by the reported SDK version.
 * Derived from ROCm/amdsmi public headers; provenance and hashes are in
 * tests/fixtures/amdsmi/versions.json. No vendor implementation is bundled. */
#ifndef WTOP_AMDSMI_ABI_H
#define WTOP_AMDSMI_ABI_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint32_t year;
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} wtop_version_232;

typedef union {
  struct {
    uint64_t function_number : 3;
    uint64_t device_number : 5;
    uint64_t bus_number : 8;
    uint64_t domain_number : 48;
  };
  uint64_t as_uint;
} wtop_bdf_232;

typedef struct {
  uint32_t gfx_activity;
  uint32_t umc_activity;
  uint32_t mm_activity;
  uint32_t reserved[13];
} wtop_engine_usage_232;

typedef struct {
  uint64_t power_cap;
  uint64_t default_power_cap;
  uint64_t dpm_cap;
  uint64_t min_power_cap;
  uint64_t max_power_cap;
  uint64_t reserved[3];
} wtop_power_cap_info_232;

typedef struct {
  uint32_t average_socket_power;
  uint32_t gfx_voltage;
  uint32_t soc_voltage;
  uint32_t mem_voltage;
  uint32_t power_limit;
  uint32_t reserved[11];
} wtop_power_info_232;

typedef struct {
  uint32_t cur_clk;
  uint32_t min_clk;
  uint32_t max_clk;
  uint32_t reserved[5];
} wtop_clk_info_232;

typedef struct {
  char  market_name[64];
  uint32_t vendor_id;
  uint32_t subvendor_id;
  uint64_t device_id;
  uint32_t rev_id;
  char asic_serial[32];
  uint32_t reserved[3];
} wtop_asic_info_232;


typedef union {
  struct wtop_amd_fields_ {
    uint64_t function_number : 3;
    uint64_t device_number : 5;
    uint64_t bus_number : 8;
    uint64_t domain_number : 48;
  } fields;
  uint64_t as_uint;
} wtop_bdf_234;

typedef struct {
  uint32_t current_socket_power;
  uint32_t average_socket_power;
  uint32_t gfx_voltage;
  uint32_t soc_voltage;
  uint32_t mem_voltage;
  uint32_t power_limit;
  uint32_t reserved[11];
} wtop_power_info_234;

typedef struct {
  uint32_t cur_clk;
  uint32_t min_clk;
  uint32_t max_clk;
  uint32_t sleep_clk;
  uint32_t reserved[4];
} wtop_clk_info_234;

typedef struct {
  char  market_name[64];
  uint32_t vendor_id;
  char vendor_name[64];
  uint32_t subvendor_id;
  uint64_t device_id;
  uint32_t rev_id;
  char asic_serial[32];
  uint16_t oam_id;
  uint16_t reserved[37];
} wtop_asic_info_234;

typedef struct { char driver_version[64]; char driver_date[64]; char driver_name[64]; } wtop_driver_info_245;

typedef struct {
	char  driver_name[64];
	char  driver_version[64];
	char  driver_date[64];
} wtop_driver_info_234;

typedef struct {
  uint32_t clk;
  uint32_t min_clk;
  uint32_t max_clk;
  uint8_t clk_locked;
  uint8_t clk_deep_sleep;
  uint32_t reserved[4];
} wtop_clk_info_246;

typedef struct {
  char  market_name[256];
  uint32_t vendor_id;
  char vendor_name[64];
  uint32_t subvendor_id;
  uint64_t device_id;
  uint32_t rev_id;
  char asic_serial[32];
  uint32_t oam_id;
  uint32_t reserved[18];
} wtop_asic_info_246;

typedef struct {
  char  market_name[256];
  uint32_t vendor_id;
  char vendor_name[64];
  uint32_t subvendor_id;
  uint64_t device_id;
  uint32_t rev_id;
  char asic_serial[32];
  uint32_t oam_id;
  uint32_t num_of_compute_units;
  uint64_t target_graphics_version;
  uint32_t reserved[15];
} wtop_asic_info_251;

typedef struct {
    uint64_t socket_power;
    uint32_t current_socket_power;
    uint32_t average_socket_power;
    uint32_t gfx_voltage;
    uint32_t soc_voltage;
    uint32_t mem_voltage;
    uint32_t power_limit;
    uint32_t reserved[2];
} wtop_power_info_255;

typedef struct {
    char  market_name[256];
    uint32_t vendor_id;
    char vendor_name[256];
    uint32_t subvendor_id;
    uint64_t device_id;
    uint32_t rev_id;
    char asic_serial[256];
    uint32_t oam_id;
    uint32_t num_of_compute_units;
    uint64_t target_graphics_version;
    uint32_t reserved[22];
} wtop_asic_info_255;

typedef struct {
    char  driver_version[256];
    char  driver_date[256];
    char  driver_name[256];
} wtop_driver_info_255;

typedef struct {
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} wtop_version_260;

typedef union {
    struct wtop_amd_bdf_fields_ {
        uint64_t function_number : 3;
        uint64_t device_number : 5;
        uint64_t bus_number : 8;
        uint64_t domain_number : 48;
    } bdf;
    struct {
        uint64_t function_number : 3;
        uint64_t device_number : 5;
        uint64_t bus_number : 8;
        uint64_t domain_number : 48;
    };
    uint64_t as_uint;
} wtop_bdf_260;

typedef struct {
    uint64_t socket_power;
    uint32_t current_socket_power;
    uint32_t average_socket_power;
    uint64_t gfx_voltage;
    uint64_t soc_voltage;
    uint64_t mem_voltage;
    uint32_t power_limit;
    uint64_t reserved[18];
} wtop_power_info_260;

typedef struct {
    char  market_name[256];
    uint32_t vendor_id;
    char vendor_name[256];
    uint32_t subvendor_id;
    uint64_t device_id;
    uint32_t rev_id;
    char asic_serial[256];
    uint32_t oam_id;
    uint32_t num_of_compute_units;
    uint64_t target_graphics_version;
    uint32_t subsystem_id;
    uint32_t reserved[21];
} wtop_asic_info_260;
typedef wtop_version_232 wtop_amd_version_232;
typedef wtop_power_info_232 wtop_amd_power_info_232;
typedef wtop_clk_info_232 wtop_amd_clk_info_232;
typedef wtop_asic_info_232 wtop_amd_asic_info_232;
typedef wtop_version_232 wtop_amd_version_234;
typedef wtop_power_info_234 wtop_amd_power_info_234;
typedef wtop_clk_info_234 wtop_amd_clk_info_234;
typedef wtop_asic_info_234 wtop_amd_asic_info_234;
typedef wtop_driver_info_234 wtop_amd_driver_info_234;
typedef wtop_version_232 wtop_amd_version_245;
typedef wtop_power_info_234 wtop_amd_power_info_245;
typedef wtop_clk_info_234 wtop_amd_clk_info_245;
typedef wtop_asic_info_234 wtop_amd_asic_info_245;
typedef wtop_driver_info_245 wtop_amd_driver_info_245;
typedef wtop_version_232 wtop_amd_version_246;
typedef wtop_power_info_234 wtop_amd_power_info_246;
typedef wtop_clk_info_246 wtop_amd_clk_info_246;
typedef wtop_asic_info_246 wtop_amd_asic_info_246;
typedef wtop_driver_info_245 wtop_amd_driver_info_246;
typedef wtop_version_232 wtop_amd_version_251;
typedef wtop_power_info_234 wtop_amd_power_info_251;
typedef wtop_clk_info_246 wtop_amd_clk_info_251;
typedef wtop_asic_info_251 wtop_amd_asic_info_251;
typedef wtop_driver_info_245 wtop_amd_driver_info_251;
typedef wtop_version_232 wtop_amd_version_255;
typedef wtop_power_info_255 wtop_amd_power_info_255;
typedef wtop_clk_info_246 wtop_amd_clk_info_255;
typedef wtop_asic_info_255 wtop_amd_asic_info_255;
typedef wtop_driver_info_255 wtop_amd_driver_info_255;
typedef wtop_version_260 wtop_amd_version_260;
typedef wtop_power_info_260 wtop_amd_power_info_260;
typedef wtop_clk_info_246 wtop_amd_clk_info_260;
typedef wtop_asic_info_260 wtop_amd_asic_info_260;
typedef wtop_driver_info_255 wtop_amd_driver_info_260;
typedef wtop_version_260 wtop_amd_version_262;
typedef wtop_power_info_260 wtop_amd_power_info_262;
typedef wtop_clk_info_246 wtop_amd_clk_info_262;
typedef wtop_asic_info_260 wtop_amd_asic_info_262;
typedef wtop_driver_info_255 wtop_amd_driver_info_262;
typedef wtop_bdf_232 wtop_amd_bdf;
typedef wtop_engine_usage_232 wtop_amd_activity;
typedef wtop_power_cap_info_232 wtop_amd_power_cap;

_Static_assert(sizeof(wtop_amd_bdf) == 8, "AMD SMI BDF ABI");
_Static_assert(sizeof(wtop_amd_activity) == 64, "AMD SMI activity ABI");
_Static_assert(sizeof(wtop_amd_power_cap) == 64, "AMD SMI power cap ABI");
_Static_assert(sizeof(wtop_amd_power_info_232) == 64, "AMD SMI 23.2 power ABI");
_Static_assert(sizeof(wtop_amd_power_info_234) == 68, "AMD SMI 23.4 power ABI");
_Static_assert(sizeof(wtop_amd_clk_info_262) == 32, "AMD SMI clock ABI");
_Static_assert(offsetof(wtop_amd_power_info_255, average_socket_power) == 12,
    "AMD SMI 25.5 power ABI");
_Static_assert(offsetof(wtop_amd_power_info_262, gfx_voltage) == 16,
    "AMD SMI 26 power ABI");
#endif
