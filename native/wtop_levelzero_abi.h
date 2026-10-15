/* Verified complete Level Zero Sysman output layouts.
 * Original declarations: oneapi-src/level-zero v1.5.0 and v1.34.0.
 * Layout/function checks compile against independent SDK declarations.
 * MIT License
 *
 * Copyright (C) 2019-2026 Intel Corporation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 */
#ifndef WTOP_LEVELZERO_ABI_H
#define WTOP_LEVELZERO_ABI_H
#include <stdint.h>
typedef struct _wtop_zes_pci_address_t
{
    uint32_t domain;
    uint32_t bus;
    uint32_t device;
    uint32_t function;
} wtop_zes_pci_address_t;
typedef struct _wtop_zes_pci_speed_t
{
    int32_t gen;
    int32_t width;
    int64_t maxBandwidth;
} wtop_zes_pci_speed_t;
typedef struct _wtop_zes_pci_properties_t
{
    uint32_t stype;
    void* pNext;
    wtop_zes_pci_address_t address;
    wtop_zes_pci_speed_t maxSpeed;
    uint8_t haveBandwidthCounters;
    uint8_t havePacketCounters;
    uint8_t haveReplayCounters;
} wtop_zes_pci_properties_t;
typedef struct _wtop_zes_temp_properties_t
{
    uint32_t stype;
    void* pNext;
    uint32_t type;
    uint8_t onSubdevice;
    uint32_t subdeviceId;
    double maxTemperature;
    uint8_t isCriticalTempSupported;
    uint8_t isThreshold1Supported;
    uint8_t isThreshold2Supported;
} wtop_zes_temp_properties_t;
typedef struct _wtop_zes_freq_properties_t
{
    uint32_t stype;
    void* pNext;
    uint32_t type;
    uint8_t onSubdevice;
    uint32_t subdeviceId;
    uint8_t canControl;
    uint8_t isThrottleEventSupported;
    double min;
    double max;
} wtop_zes_freq_properties_t;
typedef struct _wtop_zes_freq_state_t
{
    uint32_t stype;
    const void* pNext;
    double currentVoltage;
    double request;
    double tdp;
    double efficient;
    double actual;
    uint32_t throttleReasons;
} wtop_zes_freq_state_t;
typedef struct _wtop_zes_power_properties_t
{
    uint32_t stype;
    void* pNext;
    uint8_t onSubdevice;
    uint32_t subdeviceId;
    uint8_t canControl;
    uint8_t isEnergyThresholdSupported;
    int32_t defaultLimit;
    int32_t minLimit;
    int32_t maxLimit;
} wtop_zes_power_properties_t;
typedef struct _wtop_zes_power_energy_counter_t
{
    uint64_t energy;
    uint64_t timestamp;
} wtop_zes_power_energy_counter_t;
typedef struct _wtop_zes_power_sustained_limit_t
{
    uint8_t enabled;
    int32_t power;
    int32_t interval;
} wtop_zes_power_sustained_limit_t;
typedef struct _wtop_zes_power_burst_limit_t
{
    uint8_t enabled;
    int32_t power;
} wtop_zes_power_burst_limit_t;
typedef struct _wtop_zes_power_peak_limit_t
{
    int32_t powerAC;
    int32_t powerDC;
} wtop_zes_power_peak_limit_t;
typedef struct _wtop_zes_power_limit_ext_desc_t
{
    uint32_t stype;
    const void* pNext;
    uint32_t level;
    uint32_t source;
    uint32_t limitUnit;
    uint8_t enabledStateLocked;
    uint8_t enabled;
    uint8_t intervalValueLocked;
    int32_t interval;
    uint8_t limitValueLocked;
    int32_t limit;
} wtop_zes_power_limit_ext_desc_t;
typedef struct _wtop_zes_power_ext_properties_t
{
    uint32_t stype;
    void* pNext;
    uint32_t domain;
    wtop_zes_power_limit_ext_desc_t* defaultLimit;
} wtop_zes_power_ext_properties_t;

typedef struct _wtop_ze_device_uuid_t
{
    uint8_t id[16];
} wtop_ze_device_uuid_t;
typedef struct _wtop_ze_device_properties_t
{
    uint32_t stype;
    void* pNext;
    uint32_t type;
    uint32_t vendorId;
    uint32_t deviceId;
    uint32_t flags;
    uint32_t subdeviceId;
    uint32_t coreClockRate;
    uint64_t maxMemAllocSize;
    uint32_t maxHardwareContexts;
    uint32_t maxCommandQueuePriority;
    uint32_t numThreadsPerEU;
    uint32_t physicalEUSimdWidth;
    uint32_t numEUsPerSubslice;
    uint32_t numSubslicesPerSlice;
    uint32_t numSlices;
    uint64_t timerResolution;
    uint32_t timestampValidBits;
    uint32_t kernelTimestampValidBits;
    wtop_ze_device_uuid_t uuid;
    char name[256];
} wtop_ze_device_properties_t;
typedef struct _wtop_zes_device_properties_t
{
    uint32_t stype;
    void* pNext;
    wtop_ze_device_properties_t core;
    uint32_t numSubdevices;
    char serialNumber[64];
    char boardNumber[64];
    char brandName[64];
    char modelName[64];
    char vendorName[64];
    char driverVersion[64];
} wtop_zes_device_properties_t;
#endif
