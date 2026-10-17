/* Complete read-only ADL output layouts, from GPUOpen SDK commit
 * 84c881cb2136f04287eb3af12de00a9e2867aa9e. See licenses/AMD-ADL-MIT.txt. */
#ifndef WTOP_ADL_ABI_H
#define WTOP_ADL_ABI_H
#include <stdint.h>
_Static_assert(sizeof(int)==4,"ADL integer ABI");
typedef struct {
    int iSize;
    int iAdapterIndex;
    char strUDID[256];
    int iBusNumber;
    int iDeviceNumber;
    int iFunctionNumber;
    int iVendorID;
    char strAdapterName[256];
    char strDisplayName[256];
    int iPresent;
    int iExist;
    char strDriverPath[256];
    char strDriverPathExt[256];
    char strPNPString[256];
    int iOSDisplayIndex;

} wtop_AdapterInfo;
typedef struct {
    int iSize;
    int iEngineClock;
    int iMemoryClock;
    int iVddc;
    int iActivityPercent;
    int iCurrentPerformanceLevel;
    int iCurrentBusSpeed;
    int iCurrentBusLanes;
    int iMaximumBusLanes;
    int iReserved;
} wtop_ADLPMActivity;
typedef struct {
    int     iEngineClock;
    int     iMemoryClock;
    int     iActivityPercent;
    int     iCurrentPerformanceLevel;
    int     iCurrentBusSpeed;
    int     iCurrentBusLanes;
    int     iMaximumBusLanes;
    int     iExtValue;
    int     iExtMask;
} wtop_ADLOD6CurrentStatus;
typedef struct {
  int iSize;
  int iThermalDomain;
  int iDomainIndex;
  int iFlags;
} wtop_ADLThermalControllerInfo;
typedef struct {
  int iSize;
  int iTemperature;
} wtop_ADLTemperature;
typedef struct {
  int iSize;
  int iSpeedType;
  int iFanSpeed;
  int iFlags;
} wtop_ADLFanSpeedValue;
typedef struct {
    int     iSpeedType;
    int     iFanSpeedPercent;
    int        iFanSpeedRPM;
    int     iExtValue;
    int     iExtMask;
} wtop_ADLOD6FanSpeedInfo;
typedef uint32_t wtop_ADL_D3DKMT_HANDLE;
typedef struct { int supported, value; } wtop_ADLSingleSensorData;
typedef struct {
    int size;
    wtop_ADLSingleSensorData sensors[256];
} wtop_ADLPMLogDataOutput;
#endif
