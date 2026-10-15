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
/* Public-header excerpts for the native fake SDK. This file deliberately
 * does not include wtop's ABI declarations. Tests may instead include a full
 * original SDK header by defining WTOP_AMDSMI_SDK_HEADER. */
#ifndef WTOP_TEST_AMDSMI_SDK_H
#define WTOP_TEST_AMDSMI_SDK_H
#include <stdint.h>
typedef uint32_t amdsmi_status_t;
typedef void *amdsmi_processor_handle;
typedef void *amdsmi_socket_handle;
typedef uint32_t processor_type_t;
typedef uint32_t amdsmi_memory_type_t;
typedef uint32_t amdsmi_temperature_type_t;
typedef uint32_t amdsmi_temperature_metric_t;
typedef uint32_t amdsmi_clk_type_t;

#if WTOP_AMDSMI_PROFILE == 232
#define AMDSMI_LIB_VERSION_YEAR 23
#define AMDSMI_LIB_VERSION_MAJOR 2
#define AMDSMI_LIB_VERSION_MINOR 0
#define AMDSMI_LIB_VERSION_RELEASE 1
typedef struct {
    uint32_t year;
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} amdsmi_version_t;
typedef union {
  struct {
    uint64_t function_number : 3;
    uint64_t device_number : 5;
    uint64_t bus_number : 8;
    uint64_t domain_number : 48;
  };
  uint64_t as_uint;
} amdsmi_bdf_t;
typedef struct {
  uint32_t gfx_activity;
  uint32_t umc_activity;
  uint32_t mm_activity;
  uint32_t reserved[13];
} amdsmi_engine_usage_t;
typedef struct {
  uint64_t power_cap;
  uint64_t default_power_cap;
  uint64_t dpm_cap;
  uint64_t min_power_cap;
  uint64_t max_power_cap;
  uint64_t reserved[3];
} amdsmi_power_cap_info_t;
typedef struct {
  uint32_t average_socket_power;
  uint32_t gfx_voltage;
  uint32_t soc_voltage;
  uint32_t mem_voltage;
  uint32_t power_limit;
  uint32_t reserved[11];
} amdsmi_power_info_t;
typedef struct {
  uint32_t cur_clk;
  uint32_t min_clk;
  uint32_t max_clk;
  uint32_t reserved[5];
} amdsmi_clk_info_t;
typedef struct {
  char  market_name[64];
  uint32_t vendor_id;
  uint32_t subvendor_id;
  uint64_t device_id;
  uint32_t rev_id;
  char asic_serial[32];
  uint32_t reserved[3];
} amdsmi_asic_info_t;

#elif WTOP_AMDSMI_PROFILE == 234
#define AMDSMI_LIB_VERSION_YEAR 23
#define AMDSMI_LIB_VERSION_MAJOR 4
#define AMDSMI_LIB_VERSION_MINOR 0
#define AMDSMI_LIB_VERSION_RELEASE 0
typedef struct {
    uint32_t year;
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} amdsmi_version_t;
typedef union {
  struct fields_ {
    uint64_t function_number : 3;
    uint64_t device_number : 5;
    uint64_t bus_number : 8;
    uint64_t domain_number : 48;
  } fields;
  uint64_t as_uint;
} amdsmi_bdf_t;
typedef struct {
  uint32_t gfx_activity;
  uint32_t umc_activity;
  uint32_t mm_activity;
  uint32_t reserved[13];
} amdsmi_engine_usage_t;
typedef struct {
  uint64_t power_cap;
  uint64_t default_power_cap;
  uint64_t dpm_cap;
  uint64_t min_power_cap;
  uint64_t max_power_cap;
  uint64_t reserved[3];
} amdsmi_power_cap_info_t;
typedef struct {
  uint32_t current_socket_power;
  uint32_t average_socket_power;
  uint32_t gfx_voltage;
  uint32_t soc_voltage;
  uint32_t mem_voltage;
  uint32_t power_limit;
  uint32_t reserved[11];
} amdsmi_power_info_t;
typedef struct {
  uint32_t cur_clk;
  uint32_t min_clk;
  uint32_t max_clk;
  uint32_t sleep_clk;
  uint32_t reserved[4];
} amdsmi_clk_info_t;
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
} amdsmi_asic_info_t;
typedef struct {
	char  driver_name[64];
	char  driver_version[64];
	char  driver_date[64];
} amdsmi_driver_info_t;

#elif WTOP_AMDSMI_PROFILE == 245
#define AMDSMI_LIB_VERSION_YEAR 24
#define AMDSMI_LIB_VERSION_MAJOR 5
#define AMDSMI_LIB_VERSION_MINOR 2
#define AMDSMI_LIB_VERSION_RELEASE 0
typedef struct {
    uint32_t year;
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} amdsmi_version_t;
typedef union {
  struct fields_ {
    uint64_t function_number : 3;
    uint64_t device_number : 5;
    uint64_t bus_number : 8;
    uint64_t domain_number : 48;
  } fields;
  uint64_t as_uint;
} amdsmi_bdf_t;
typedef struct {
  uint32_t gfx_activity;
  uint32_t umc_activity;
  uint32_t mm_activity;
  uint32_t reserved[13];
} amdsmi_engine_usage_t;
typedef struct {
  uint64_t power_cap;
  uint64_t default_power_cap;
  uint64_t dpm_cap;
  uint64_t min_power_cap;
  uint64_t max_power_cap;
  uint64_t reserved[3];
} amdsmi_power_cap_info_t;
typedef struct {
  uint32_t current_socket_power;
  uint32_t average_socket_power;
  uint32_t gfx_voltage;
  uint32_t soc_voltage;
  uint32_t mem_voltage;
  uint32_t power_limit;
  uint32_t reserved[11];
} amdsmi_power_info_t;
typedef struct {
  uint32_t cur_clk;
  uint32_t min_clk;
  uint32_t max_clk;
  uint32_t sleep_clk;
  uint32_t reserved[4];
} amdsmi_clk_info_t;
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
} amdsmi_asic_info_t;
typedef struct {
  char  driver_version[64];
  char  driver_date[64];
  char  driver_name[64];
} amdsmi_driver_info_t;

#elif WTOP_AMDSMI_PROFILE == 246
#define AMDSMI_LIB_VERSION_YEAR 24
#define AMDSMI_LIB_VERSION_MAJOR 6
#define AMDSMI_LIB_VERSION_MINOR 3
#define AMDSMI_LIB_VERSION_RELEASE 0
typedef struct {
    uint32_t year;
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} amdsmi_version_t;
typedef union {
  struct {
    uint64_t function_number : 3;
    uint64_t device_number : 5;
    uint64_t bus_number : 8;
    uint64_t domain_number : 48;
  };
  uint64_t as_uint;
} amdsmi_bdf_t;
typedef struct {
  uint32_t gfx_activity;
  uint32_t umc_activity;
  uint32_t mm_activity;
  uint32_t reserved[13];
} amdsmi_engine_usage_t;
typedef struct {
  uint64_t power_cap;
  uint64_t default_power_cap;
  uint64_t dpm_cap;
  uint64_t min_power_cap;
  uint64_t max_power_cap;
  uint64_t reserved[3];
} amdsmi_power_cap_info_t;
typedef struct {
  uint32_t current_socket_power;
  uint32_t average_socket_power;
  uint32_t gfx_voltage;
  uint32_t soc_voltage;
  uint32_t mem_voltage;
  uint32_t power_limit;
  uint32_t reserved[11];
} amdsmi_power_info_t;
typedef struct {
  uint32_t clk;
  uint32_t min_clk;
  uint32_t max_clk;
  uint8_t clk_locked;
  uint8_t clk_deep_sleep;
  uint32_t reserved[4];
} amdsmi_clk_info_t;
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
} amdsmi_asic_info_t;
typedef struct {
  char  driver_version[64];
  char  driver_date[64];
  char  driver_name[64];
} amdsmi_driver_info_t;

#elif WTOP_AMDSMI_PROFILE == 251
#define AMDSMI_LIB_VERSION_YEAR 25
#define AMDSMI_LIB_VERSION_MAJOR 1
#define AMDSMI_LIB_VERSION_MINOR 0
#define AMDSMI_LIB_VERSION_RELEASE 0
typedef struct {
    uint32_t year;
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} amdsmi_version_t;
typedef union {
  struct {
    uint64_t function_number : 3;
    uint64_t device_number : 5;
    uint64_t bus_number : 8;
    uint64_t domain_number : 48;
  };
  uint64_t as_uint;
} amdsmi_bdf_t;
typedef struct {
  uint32_t gfx_activity;
  uint32_t umc_activity;
  uint32_t mm_activity;
  uint32_t reserved[13];
} amdsmi_engine_usage_t;
typedef struct {
  uint64_t power_cap;
  uint64_t default_power_cap;
  uint64_t dpm_cap;
  uint64_t min_power_cap;
  uint64_t max_power_cap;
  uint64_t reserved[3];
} amdsmi_power_cap_info_t;
typedef struct {
  uint32_t current_socket_power;
  uint32_t average_socket_power;
  uint32_t gfx_voltage;
  uint32_t soc_voltage;
  uint32_t mem_voltage;
  uint32_t power_limit;
  uint32_t reserved[11];
} amdsmi_power_info_t;
typedef struct {
  uint32_t clk;
  uint32_t min_clk;
  uint32_t max_clk;
  uint8_t clk_locked;
  uint8_t clk_deep_sleep;
  uint32_t reserved[4];
} amdsmi_clk_info_t;
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
} amdsmi_asic_info_t;
typedef struct {
  char  driver_version[64];
  char  driver_date[64];
  char  driver_name[64];
} amdsmi_driver_info_t;

#elif WTOP_AMDSMI_PROFILE == 255
#define AMDSMI_LIB_VERSION_YEAR 25
#define AMDSMI_LIB_VERSION_MAJOR 25
#define AMDSMI_LIB_VERSION_MINOR 5
#define AMDSMI_LIB_VERSION_RELEASE 1
typedef struct {
    uint32_t year;
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} amdsmi_version_t;
typedef union {
    struct {
        uint64_t function_number : 3;
        uint64_t device_number : 5;
        uint64_t bus_number : 8;
        uint64_t domain_number : 48;
    };
    uint64_t as_uint;
} amdsmi_bdf_t;
typedef struct {
    uint32_t gfx_activity;
    uint32_t umc_activity;
    uint32_t mm_activity;
    uint32_t reserved[13];
} amdsmi_engine_usage_t;
typedef struct {
    uint64_t power_cap;
    uint64_t default_power_cap;
    uint64_t dpm_cap;
    uint64_t min_power_cap;
    uint64_t max_power_cap;
    uint64_t reserved[3];
} amdsmi_power_cap_info_t;
typedef struct {
    uint64_t socket_power;
    uint32_t current_socket_power;
    uint32_t average_socket_power;
    uint32_t gfx_voltage;
    uint32_t soc_voltage;
    uint32_t mem_voltage;
    uint32_t power_limit;
    uint32_t reserved[2];
} amdsmi_power_info_t;
typedef struct {
    uint32_t clk;
    uint32_t min_clk;
    uint32_t max_clk;
    uint8_t clk_locked;
    uint8_t clk_deep_sleep;
    uint32_t reserved[4];
} amdsmi_clk_info_t;
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
} amdsmi_asic_info_t;
typedef struct {
    char  driver_version[256];
    char  driver_date[256];
    char  driver_name[256];
} amdsmi_driver_info_t;

#elif WTOP_AMDSMI_PROFILE == 260
#define AMDSMI_LIB_VERSION_MAJOR 26
#define AMDSMI_LIB_VERSION_MINOR 0
#define AMDSMI_LIB_VERSION_RELEASE 2
typedef struct {
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} amdsmi_version_t;
typedef union {
    struct bdf_ {
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
} amdsmi_bdf_t;
typedef struct {
    uint32_t gfx_activity;
    uint32_t umc_activity;
    uint32_t mm_activity;
    uint32_t reserved[13];
} amdsmi_engine_usage_t;
typedef struct {
    uint64_t power_cap;
    uint64_t default_power_cap;
    uint64_t dpm_cap;
    uint64_t min_power_cap;
    uint64_t max_power_cap;
    uint64_t reserved[3];
} amdsmi_power_cap_info_t;
typedef struct {
    uint64_t socket_power;
    uint32_t current_socket_power;
    uint32_t average_socket_power;
    uint64_t gfx_voltage;
    uint64_t soc_voltage;
    uint64_t mem_voltage;
    uint32_t power_limit;
    uint64_t reserved[18];
} amdsmi_power_info_t;
typedef struct {
    uint32_t clk;
    uint32_t min_clk;
    uint32_t max_clk;
    uint8_t clk_locked;
    uint8_t clk_deep_sleep;
    uint32_t reserved[4];
} amdsmi_clk_info_t;
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
} amdsmi_asic_info_t;
typedef struct {
    char driver_version[256];
    char driver_date[256];
    char driver_name[256];
} amdsmi_driver_info_t;

#elif WTOP_AMDSMI_PROFILE == 262
#define AMDSMI_LIB_VERSION_MAJOR 26
#define AMDSMI_LIB_VERSION_MINOR 2
#define AMDSMI_LIB_VERSION_RELEASE 2
typedef struct {
    uint32_t major;
    uint32_t minor;
    uint32_t release;
    const char *build;
} amdsmi_version_t;
typedef union {
    struct bdf_ {
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
} amdsmi_bdf_t;
typedef struct {
    uint32_t gfx_activity;
    uint32_t umc_activity;
    uint32_t mm_activity;
    uint32_t reserved[13];
} amdsmi_engine_usage_t;
typedef struct {
    uint64_t power_cap;
    uint64_t default_power_cap;
    uint64_t dpm_cap;
    uint64_t min_power_cap;
    uint64_t max_power_cap;
    uint64_t reserved[3];
} amdsmi_power_cap_info_t;
typedef struct {
    uint64_t socket_power;
    uint32_t current_socket_power;
    uint32_t average_socket_power;
    uint64_t gfx_voltage;
    uint64_t soc_voltage;
    uint64_t mem_voltage;
    uint32_t power_limit;
    uint64_t reserved[18];
} amdsmi_power_info_t;
typedef struct {
    uint32_t clk;
    uint32_t min_clk;
    uint32_t max_clk;
    uint8_t clk_locked;
    uint8_t clk_deep_sleep;
    uint32_t reserved[4];
} amdsmi_clk_info_t;
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
} amdsmi_asic_info_t;
typedef struct {
    char driver_version[256];
    char driver_date[256];
    char driver_name[256];
} amdsmi_driver_info_t;

#else
#error Unknown fake AMD SMI profile
#endif
#endif
