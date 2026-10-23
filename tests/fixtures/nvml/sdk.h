/*
 * Copyright 1993-2026 NVIDIA Corporation.  All rights reserved.
 *
 * NOTICE TO USER:
 *
 * This source code is subject to NVIDIA ownership rights under U.S. and
 * international Copyright laws.  Users and possessors of this source code
 * are hereby granted a nonexclusive, royalty-free license to use this code
 * in individual and commercial software.
 *
 * NVIDIA MAKES NO REPRESENTATION ABOUT THE SUITABILITY OF THIS SOURCE
 * CODE FOR ANY PURPOSE.  IT IS PROVIDED "AS IS" WITHOUT EXPRESS OR
 * IMPLIED WARRANTY OF ANY KIND.  NVIDIA DISCLAIMS ALL WARRANTIES WITH
 * REGARD TO THIS SOURCE CODE, INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY, NONINFRINGEMENT, AND FITNESS FOR A PARTICULAR PURPOSE.
 * IN NO EVENT SHALL NVIDIA BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL,
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS,  WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
 * OR OTHER TORTIOUS ACTION,  ARISING OUT OF OR IN CONNECTION WITH THE USE
 * OR PERFORMANCE OF THIS SOURCE CODE.
 *
 * U.S. Government End Users.   This source code is a "commercial item" as
 * that term is defined at  48 C.F.R. 2.101 (OCT 1995), consisting  of
 * "commercial computer  software"  and "commercial computer software
 * documentation" as such terms are  used in 48 C.F.R. 12.212 (SEPT 1995)
 * and is provided to the U.S. Government only as a commercial end item.
 * Consistent with 48 C.F.R.12.212 and 48 C.F.R. 227.7202-1 through
 * 227.7202-4 (JUNE 1995), all U.S. Government End Users acquire the
 * source code with only those rights set forth herein.
 *
 * Any use of this source code in individual and commercial software must
 * include, in the user documentation and internal comments to the code,
 * the above Disclaimer and U.S. Government End Users Notice.
 */
/* Independent SDK declarations for the fake library. Compile with
 * WTOP_NVML_SDK_HEADER to use the original full NVIDIA header instead. */
#ifndef WTOP_TEST_NVML_SDK_H
#define WTOP_TEST_NVML_SDK_H
#include <stdint.h>
typedef unsigned int nvmlReturn_t;
typedef struct nvmlDevice_st *nvmlDevice_t;
typedef unsigned int nvmlClockType_t, nvmlTemperatureSensors_t, nvmlPstates_t, nvmlValueType_t;
typedef enum { NVML_PCIE_UTIL_TX_BYTES = 0, NVML_PCIE_UTIL_RX_BYTES = 1,
    NVML_PCIE_UTIL_COUNT } nvmlPcieUtilCounter_t;
#define NVML_DEVICE_PCI_BUS_ID_BUFFER_V2_SIZE 16
#define NVML_DEVICE_PCI_BUS_ID_BUFFER_SIZE 32

typedef struct nvmlPciInfo_st
{
    char busIdLegacy[NVML_DEVICE_PCI_BUS_ID_BUFFER_V2_SIZE];
    unsigned int domain;
    unsigned int bus;
    unsigned int device;
    unsigned int pciDeviceId;


    unsigned int pciSubSystemId;

    char busId[NVML_DEVICE_PCI_BUS_ID_BUFFER_SIZE];
} nvmlPciInfo_t;

typedef struct nvmlUtilization_st
{
    unsigned int gpu;
    unsigned int memory;
} nvmlUtilization_t;

typedef struct nvmlMemory_st
{
    unsigned long long total;
    unsigned long long free;
    unsigned long long used;

} nvmlMemory_t;

typedef struct nvmlProcessInfo_v1_st
{
    unsigned int        pid;
    unsigned long long  usedGpuMemory;


} nvmlProcessInfo_v1_t;

typedef struct nvmlProcessInfo_v2_st
{
    unsigned int        pid;
    unsigned long long  usedGpuMemory;


    unsigned int        gpuInstanceId;

    unsigned int        computeInstanceId;

} nvmlProcessInfo_v2_t, nvmlProcessInfo_t;

typedef struct nvmlProcessUtilizationSample_st
{
    unsigned int        pid;
    unsigned long long  timeStamp;
    unsigned int        smUtil;
    unsigned int        memUtil;
    unsigned int        encUtil;
    unsigned int        decUtil;
} nvmlProcessUtilizationSample_t;

typedef union nvmlValue_st
{
    double dVal;
    int siVal;
    unsigned int uiVal;
    unsigned long ulVal;
    unsigned long long ullVal;
    signed long long sllVal;
    unsigned short usVal;
}nvmlValue_t;

typedef struct nvmlFieldValue_st
{
    unsigned int fieldId;
    unsigned int scopeId;
    long long timestamp;
    long long latencyUsec;
    nvmlValueType_t valueType;
    nvmlReturn_t nvmlReturn;
    nvmlValue_t value;
} nvmlFieldValue_t;

#endif
