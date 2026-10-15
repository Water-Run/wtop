/* Independent public SDK declaration excerpts; Intel MIT notice below. */
/*
MIT License

Copyright (C) 2019-2026 Intel Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
#ifndef WTOP_TEST_LEVELZERO_SDK_H
#define WTOP_TEST_LEVELZERO_SDK_H
#include <stdint.h>
typedef uint8_t ze_bool_t;
typedef uint32_t ze_structure_type_t,zes_structure_type_t,ze_device_type_t,ze_device_property_flags_t;
typedef uint32_t zes_temp_sensors_t,zes_freq_domain_t,zes_freq_throttle_reason_flags_t;
typedef uint32_t zes_power_domain_t,zes_power_level_t,zes_power_source_t,zes_limit_unit_t;
#define ZE_MAX_DEVICE_UUID_SIZE 16
#define ZE_MAX_DEVICE_NAME 256
#define ZES_STRING_PROPERTY_SIZE 64
typedef struct _zes_pci_address_t
{
    uint32_t domain;
    uint32_t bus;
    uint32_t device;
    uint32_t function;
} zes_pci_address_t;
typedef struct _zes_pci_speed_t
{
    int32_t gen;
    int32_t width;
    int64_t maxBandwidth;
} zes_pci_speed_t;
typedef struct _zes_pci_properties_t
{
    zes_structure_type_t stype;
    void* pNext;
    zes_pci_address_t address;
    zes_pci_speed_t maxSpeed;
    ze_bool_t haveBandwidthCounters;
    ze_bool_t havePacketCounters;
    ze_bool_t haveReplayCounters;
} zes_pci_properties_t;
typedef struct _zes_temp_properties_t
{
    zes_structure_type_t stype;
    void* pNext;
    zes_temp_sensors_t type;
    ze_bool_t onSubdevice;
    uint32_t subdeviceId;
    double maxTemperature;
    ze_bool_t isCriticalTempSupported;
    ze_bool_t isThreshold1Supported;
    ze_bool_t isThreshold2Supported;
} zes_temp_properties_t;
typedef struct _zes_freq_properties_t
{
    zes_structure_type_t stype;
    void* pNext;
    zes_freq_domain_t type;
    ze_bool_t onSubdevice;
    uint32_t subdeviceId;
    ze_bool_t canControl;
    ze_bool_t isThrottleEventSupported;
    double min;
    double max;
} zes_freq_properties_t;
typedef struct _zes_freq_state_t
{
    zes_structure_type_t stype;
    const void* pNext;
    double currentVoltage;
    double request;
    double tdp;
    double efficient;
    double actual;
    zes_freq_throttle_reason_flags_t throttleReasons;
} zes_freq_state_t;
typedef struct _zes_power_properties_t
{
    zes_structure_type_t stype;
    void* pNext;
    ze_bool_t onSubdevice;
    uint32_t subdeviceId;
    ze_bool_t canControl;
    ze_bool_t isEnergyThresholdSupported;
    int32_t defaultLimit;
    int32_t minLimit;
    int32_t maxLimit;
} zes_power_properties_t;
typedef struct _zes_power_energy_counter_t
{
    uint64_t energy;
    uint64_t timestamp;
} zes_power_energy_counter_t;
typedef struct _zes_power_sustained_limit_t
{
    ze_bool_t enabled;
    int32_t power;
    int32_t interval;
} zes_power_sustained_limit_t;
typedef struct _zes_power_burst_limit_t
{
    ze_bool_t enabled;
    int32_t power;
} zes_power_burst_limit_t;
typedef struct _zes_power_peak_limit_t
{
    int32_t powerAC;
    int32_t powerDC;
} zes_power_peak_limit_t;
typedef struct _zes_power_limit_ext_desc_t
{
    zes_structure_type_t stype;
    const void* pNext;
    zes_power_level_t level;
    zes_power_source_t source;
    zes_limit_unit_t limitUnit;
    ze_bool_t enabledStateLocked;
    ze_bool_t enabled;
    ze_bool_t intervalValueLocked;
    int32_t interval;
    ze_bool_t limitValueLocked;
    int32_t limit;
} zes_power_limit_ext_desc_t;
typedef struct _zes_power_ext_properties_t
{
    zes_structure_type_t stype;
    void* pNext;
    zes_power_domain_t domain;
    zes_power_limit_ext_desc_t* defaultLimit;
} zes_power_ext_properties_t;
typedef struct _ze_device_uuid_t
{
    uint8_t id[ZE_MAX_DEVICE_UUID_SIZE];
} ze_device_uuid_t;
typedef struct _ze_device_properties_t
{
    ze_structure_type_t stype;
    void* pNext;
    ze_device_type_t type;
    uint32_t vendorId;
    uint32_t deviceId;
    ze_device_property_flags_t flags;
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
    ze_device_uuid_t uuid;
    char name[ZE_MAX_DEVICE_NAME];
} ze_device_properties_t;
typedef struct _zes_device_properties_t
{
    zes_structure_type_t stype;
    void* pNext;
    ze_device_properties_t core;
    uint32_t numSubdevices;
    char serialNumber[ZES_STRING_PROPERTY_SIZE];
    char boardNumber[ZES_STRING_PROPERTY_SIZE];
    char brandName[ZES_STRING_PROPERTY_SIZE];
    char modelName[ZES_STRING_PROPERTY_SIZE];
    char vendorName[ZES_STRING_PROPERTY_SIZE];
    char driverVersion[ZES_STRING_PROPERTY_SIZE];
} zes_device_properties_t;

typedef enum {
 ZE_RESULT_SUCCESS=0,ZE_RESULT_ERROR_DEVICE_LOST=0x70000001,
 ZE_RESULT_ERROR_INSUFFICIENT_PERMISSIONS=0x70010000,
 ZE_RESULT_ERROR_UNINITIALIZED=0x78000001,ZE_RESULT_ERROR_UNSUPPORTED_FEATURE=0x78000003
} ze_result_t;
typedef uint32_t ze_init_flags_t,zes_init_flags_t;
typedef struct _ze_driver_handle_t *ze_driver_handle_t;
typedef struct _zes_driver_handle_t *zes_driver_handle_t;
typedef struct _ze_device_handle_t *ze_device_handle_t;
typedef struct _zes_device_handle_t *zes_device_handle_t;
typedef struct _zes_temp_handle_t *zes_temp_handle_t;
typedef struct _zes_freq_handle_t *zes_freq_handle_t;
typedef struct _zes_pwr_handle_t *zes_pwr_handle_t;
ze_result_t zeInit(ze_init_flags_t flags);
ze_result_t zeDriverGet(uint32_t *,ze_driver_handle_t *);
ze_result_t zeDeviceGet(ze_driver_handle_t,uint32_t *,ze_device_handle_t *);
#ifndef WTOP_LEVELZERO_LEGACY
ze_result_t zesInit(zes_init_flags_t flags);
ze_result_t zesDriverGet(uint32_t *,zes_driver_handle_t *);
ze_result_t zesDeviceGet(zes_driver_handle_t,uint32_t *,zes_device_handle_t *);
ze_result_t zesPowerGetLimitsExt(zes_pwr_handle_t,uint32_t *,zes_power_limit_ext_desc_t *);
#endif
ze_result_t zesDeviceGetProperties(zes_device_handle_t,zes_device_properties_t *);
ze_result_t zesDevicePciGetProperties(zes_device_handle_t,zes_pci_properties_t *);
ze_result_t zesDeviceEnumTemperatureSensors(zes_device_handle_t,uint32_t *,zes_temp_handle_t *);
ze_result_t zesTemperatureGetProperties(zes_temp_handle_t,zes_temp_properties_t *);
ze_result_t zesTemperatureGetState(zes_temp_handle_t,double *);
ze_result_t zesDeviceEnumFrequencyDomains(zes_device_handle_t,uint32_t *,zes_freq_handle_t *);
ze_result_t zesFrequencyGetProperties(zes_freq_handle_t,zes_freq_properties_t *);
ze_result_t zesFrequencyGetState(zes_freq_handle_t,zes_freq_state_t *);
ze_result_t zesDeviceEnumPowerDomains(zes_device_handle_t,uint32_t *,zes_pwr_handle_t *);
ze_result_t zesDeviceGetCardPowerDomain(zes_device_handle_t,zes_pwr_handle_t *);
ze_result_t zesPowerGetProperties(zes_pwr_handle_t,zes_power_properties_t *);
ze_result_t zesPowerGetEnergyCounter(zes_pwr_handle_t,zes_power_energy_counter_t *);
ze_result_t zesPowerGetLimits(zes_pwr_handle_t,zes_power_sustained_limit_t *,zes_power_burst_limit_t *,zes_power_peak_limit_t *);
#endif
