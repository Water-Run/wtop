//
// Copyright (c) 2016 - 2022 Advanced Micro Devices, Inc. All rights reserved.
//
// MIT LICENSE:
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.


#ifndef TEST_ADL_SDK_H
#define TEST_ADL_SDK_H
#define ADL_MAX_PATH 256
typedef void *(__stdcall *ADL_MAIN_MALLOC_CALLBACK)(int);
typedef struct AdapterInfo
{
/// \WIN_STRUCT_MEM

/// Size of the structure.
    int iSize;
/// The ADL index handle. One GPU may be associated with one or two index handles
    int iAdapterIndex;
/// The unique device ID associated with this adapter.
    char strUDID[ADL_MAX_PATH];
/// The BUS number associated with this adapter.
    int iBusNumber;
/// The driver number associated with this adapter.
    int iDeviceNumber;
/// The function number.
    int iFunctionNumber;
/// The vendor ID associated with this adapter.
    int iVendorID;
/// Adapter name.
    char strAdapterName[ADL_MAX_PATH];
/// Display name. For example, "\\\\Display0" for Windows.
    char strDisplayName[ADL_MAX_PATH];
/// Present or not; 1 if present and 0 if not present.It the logical adapter is present, the display name such as \\\\.\\Display1 can be found from OS
    int iPresent;

#if defined (_WIN32) || defined (_WIN64)
/// \WIN_STRUCT_MEM

/// Exist or not; 1 is exist and 0 is not present.
    int iExist;
/// Driver registry path.
    char strDriverPath[ADL_MAX_PATH];
/// Driver registry path Ext for.
    char strDriverPathExt[ADL_MAX_PATH];
/// PNP string from Windows.
    char strPNPString[ADL_MAX_PATH];
/// It is generated from EnumDisplayDevices.
    int iOSDisplayIndex;

#endif /* (_WIN32) || (_WIN64) */

} AdapterInfo, *LPAdapterInfo;
typedef struct ADLPMActivity
{
/// Must be set to the size of the structure
    int iSize;
/// Current engine clock.
    int iEngineClock;
/// Current memory clock.
    int iMemoryClock;
/// Current core voltage.
    int iVddc;
/// GPU utilization.
    int iActivityPercent;
/// Performance level index.
    int iCurrentPerformanceLevel;
/// Current PCIE bus speed.
    int iCurrentBusSpeed;
/// Number of PCIE bus lanes.
    int iCurrentBusLanes;
/// Maximum number of PCIE bus lanes.
    int iMaximumBusLanes;
/// Reserved for future purposes.
    int iReserved;
} ADLPMActivity;
typedef struct ADLOD6CurrentStatus
{
    /// Current engine clock in 10 KHz.
    int     iEngineClock;
    /// Current memory clock in 10 KHz.
    int     iMemoryClock;
    /// Current GPU activity in percent.  This
    /// indicates how "busy" the GPU is.
    int     iActivityPercent;
    /// Not used.  Reserved for future use.
    int     iCurrentPerformanceLevel;
    /// Current PCI-E bus speed
    int     iCurrentBusSpeed;
    /// Current PCI-E bus # of lanes
    int     iCurrentBusLanes;
    /// Maximum possible PCI-E bus # of lanes
    int     iMaximumBusLanes;

    /// Value for future extension
    int     iExtValue;
    /// Mask for future extension
    int     iExtMask;
} ADLOD6CurrentStatus;
typedef struct ADLThermalControllerInfo
{
/// Must be set to the size of the structure
  int iSize;
/// Possible valies: \ref ADL_DL_THERMAL_DOMAIN_OTHER or \ref ADL_DL_THERMAL_DOMAIN_GPU.
  int iThermalDomain;
///    GPU 0, 1, etc.
  int iDomainIndex;
/// Possible valies: \ref ADL_DL_THERMAL_FLAG_INTERRUPT or \ref ADL_DL_THERMAL_FLAG_FANCONTROL
  int iFlags;
} ADLThermalControllerInfo;
typedef struct ADLTemperature
{
/// Must be set to the size of the structure
  int iSize;
/// Temperature in millidegrees Celsius.
  int iTemperature;
} ADLTemperature;
typedef struct ADLFanSpeedValue
{
/// Must be set to the size of the structure
  int iSize;
/// Possible valies: \ref ADL_DL_FANCTRL_SPEED_TYPE_PERCENT or \ref ADL_DL_FANCTRL_SPEED_TYPE_RPM
  int iSpeedType;
/// Fan speed value
  int iFanSpeed;
/// The only flag for now is: \ref ADL_DL_FANCTRL_FLAG_USER_DEFINED_SPEED
  int iFlags;
} ADLFanSpeedValue;
typedef struct ADLOD6FanSpeedInfo
{
    /// Contains a bitmap of the valid fan speed type flags.  Possible values: \ref ADL_OD6_FANSPEED_TYPE_PERCENT, \ref ADL_OD6_FANSPEED_TYPE_RPM, \ref ADL_OD6_FANSPEED_USER_DEFINED
    int     iSpeedType;
    /// Contains current fan speed in percent (if valid flag exists in iSpeedType)
    int     iFanSpeedPercent;
    /// Contains current fan speed in RPM (if valid flag exists in iSpeedType)
    int        iFanSpeedRPM;

    /// Value for future extension
    int     iExtValue;
    /// Mask for future extension
    int     iExtMask;
} ADLOD6FanSpeedInfo;
#endif

/* Public PMLog ABI and documented-unit sensor IDs from the same pinned SDK. */
typedef unsigned int ADL_D3DKMT_HANDLE;
typedef struct ADLSingleSensorData {int supported;int value;} ADLSingleSensorData;
typedef struct ADLPMLogDataOutput {int size;ADLSingleSensorData sensors[256];} ADLPMLogDataOutput;
enum {PMLOG_CLK_GFXCLK=1,PMLOG_CLK_MEMCLK=2,PMLOG_TEMPERATURE_EDGE=8,
 PMLOG_FAN_RPM=14,PMLOG_FAN_PERCENTAGE=15,PMLOG_INFO_ACTIVITY_GFX=19,
 PMLOG_GFX_VOLTAGE=21,PMLOG_ASIC_POWER=23,PMLOG_TEMPERATURE_HOTSPOT=27};
