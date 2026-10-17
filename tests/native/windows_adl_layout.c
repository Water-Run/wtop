#include <stddef.h>
#include "../../native/wtop_adl_abi.h"
#ifdef WTOP_ADL_SDK_HEADER
#include WTOP_ADL_SDK_HEADER
#else
#include "../fixtures/adl/sdk.h"
#endif
_Static_assert(sizeof(wtop_AdapterInfo)==sizeof(AdapterInfo),"AdapterInfo size");
_Static_assert(_Alignof(wtop_AdapterInfo)==_Alignof(AdapterInfo),"AdapterInfo align");
_Static_assert(offsetof(wtop_AdapterInfo,iSize)==offsetof(AdapterInfo,iSize),"AdapterInfo.iSize");
_Static_assert(offsetof(wtop_AdapterInfo,iAdapterIndex)==offsetof(AdapterInfo,iAdapterIndex),"AdapterInfo.iAdapterIndex");
_Static_assert(offsetof(wtop_AdapterInfo,strUDID)==offsetof(AdapterInfo,strUDID),"AdapterInfo.strUDID");
_Static_assert(offsetof(wtop_AdapterInfo,iBusNumber)==offsetof(AdapterInfo,iBusNumber),"AdapterInfo.iBusNumber");
_Static_assert(offsetof(wtop_AdapterInfo,iDeviceNumber)==offsetof(AdapterInfo,iDeviceNumber),"AdapterInfo.iDeviceNumber");
_Static_assert(offsetof(wtop_AdapterInfo,iFunctionNumber)==offsetof(AdapterInfo,iFunctionNumber),"AdapterInfo.iFunctionNumber");
_Static_assert(offsetof(wtop_AdapterInfo,iVendorID)==offsetof(AdapterInfo,iVendorID),"AdapterInfo.iVendorID");
_Static_assert(offsetof(wtop_AdapterInfo,strAdapterName)==offsetof(AdapterInfo,strAdapterName),"AdapterInfo.strAdapterName");
_Static_assert(offsetof(wtop_AdapterInfo,strDisplayName)==offsetof(AdapterInfo,strDisplayName),"AdapterInfo.strDisplayName");
_Static_assert(offsetof(wtop_AdapterInfo,iPresent)==offsetof(AdapterInfo,iPresent),"AdapterInfo.iPresent");
_Static_assert(offsetof(wtop_AdapterInfo,iExist)==offsetof(AdapterInfo,iExist),"AdapterInfo.iExist");
_Static_assert(offsetof(wtop_AdapterInfo,strDriverPath)==offsetof(AdapterInfo,strDriverPath),"AdapterInfo.strDriverPath");
_Static_assert(offsetof(wtop_AdapterInfo,strDriverPathExt)==offsetof(AdapterInfo,strDriverPathExt),"AdapterInfo.strDriverPathExt");
_Static_assert(offsetof(wtop_AdapterInfo,strPNPString)==offsetof(AdapterInfo,strPNPString),"AdapterInfo.strPNPString");
_Static_assert(offsetof(wtop_AdapterInfo,iOSDisplayIndex)==offsetof(AdapterInfo,iOSDisplayIndex),"AdapterInfo.iOSDisplayIndex");
_Static_assert(sizeof(wtop_ADLPMActivity)==sizeof(ADLPMActivity),"ADLPMActivity size");
_Static_assert(_Alignof(wtop_ADLPMActivity)==_Alignof(ADLPMActivity),"ADLPMActivity align");
_Static_assert(offsetof(wtop_ADLPMActivity,iSize)==offsetof(ADLPMActivity,iSize),"ADLPMActivity.iSize");
_Static_assert(offsetof(wtop_ADLPMActivity,iEngineClock)==offsetof(ADLPMActivity,iEngineClock),"ADLPMActivity.iEngineClock");
_Static_assert(offsetof(wtop_ADLPMActivity,iMemoryClock)==offsetof(ADLPMActivity,iMemoryClock),"ADLPMActivity.iMemoryClock");
_Static_assert(offsetof(wtop_ADLPMActivity,iVddc)==offsetof(ADLPMActivity,iVddc),"ADLPMActivity.iVddc");
_Static_assert(offsetof(wtop_ADLPMActivity,iActivityPercent)==offsetof(ADLPMActivity,iActivityPercent),"ADLPMActivity.iActivityPercent");
_Static_assert(offsetof(wtop_ADLPMActivity,iCurrentPerformanceLevel)==offsetof(ADLPMActivity,iCurrentPerformanceLevel),"ADLPMActivity.iCurrentPerformanceLevel");
_Static_assert(offsetof(wtop_ADLPMActivity,iCurrentBusSpeed)==offsetof(ADLPMActivity,iCurrentBusSpeed),"ADLPMActivity.iCurrentBusSpeed");
_Static_assert(offsetof(wtop_ADLPMActivity,iCurrentBusLanes)==offsetof(ADLPMActivity,iCurrentBusLanes),"ADLPMActivity.iCurrentBusLanes");
_Static_assert(offsetof(wtop_ADLPMActivity,iMaximumBusLanes)==offsetof(ADLPMActivity,iMaximumBusLanes),"ADLPMActivity.iMaximumBusLanes");
_Static_assert(offsetof(wtop_ADLPMActivity,iReserved)==offsetof(ADLPMActivity,iReserved),"ADLPMActivity.iReserved");
_Static_assert(sizeof(wtop_ADLOD6CurrentStatus)==sizeof(ADLOD6CurrentStatus),"ADLOD6CurrentStatus size");
_Static_assert(_Alignof(wtop_ADLOD6CurrentStatus)==_Alignof(ADLOD6CurrentStatus),"ADLOD6CurrentStatus align");
_Static_assert(offsetof(wtop_ADLOD6CurrentStatus,iEngineClock)==offsetof(ADLOD6CurrentStatus,iEngineClock),"ADLOD6CurrentStatus.iEngineClock");
_Static_assert(offsetof(wtop_ADLOD6CurrentStatus,iMemoryClock)==offsetof(ADLOD6CurrentStatus,iMemoryClock),"ADLOD6CurrentStatus.iMemoryClock");
_Static_assert(offsetof(wtop_ADLOD6CurrentStatus,iActivityPercent)==offsetof(ADLOD6CurrentStatus,iActivityPercent),"ADLOD6CurrentStatus.iActivityPercent");
_Static_assert(offsetof(wtop_ADLOD6CurrentStatus,iCurrentPerformanceLevel)==offsetof(ADLOD6CurrentStatus,iCurrentPerformanceLevel),"ADLOD6CurrentStatus.iCurrentPerformanceLevel");
_Static_assert(offsetof(wtop_ADLOD6CurrentStatus,iCurrentBusSpeed)==offsetof(ADLOD6CurrentStatus,iCurrentBusSpeed),"ADLOD6CurrentStatus.iCurrentBusSpeed");
_Static_assert(offsetof(wtop_ADLOD6CurrentStatus,iCurrentBusLanes)==offsetof(ADLOD6CurrentStatus,iCurrentBusLanes),"ADLOD6CurrentStatus.iCurrentBusLanes");
_Static_assert(offsetof(wtop_ADLOD6CurrentStatus,iMaximumBusLanes)==offsetof(ADLOD6CurrentStatus,iMaximumBusLanes),"ADLOD6CurrentStatus.iMaximumBusLanes");
_Static_assert(offsetof(wtop_ADLOD6CurrentStatus,iExtValue)==offsetof(ADLOD6CurrentStatus,iExtValue),"ADLOD6CurrentStatus.iExtValue");
_Static_assert(offsetof(wtop_ADLOD6CurrentStatus,iExtMask)==offsetof(ADLOD6CurrentStatus,iExtMask),"ADLOD6CurrentStatus.iExtMask");
_Static_assert(sizeof(wtop_ADLThermalControllerInfo)==sizeof(ADLThermalControllerInfo),"ADLThermalControllerInfo size");
_Static_assert(_Alignof(wtop_ADLThermalControllerInfo)==_Alignof(ADLThermalControllerInfo),"ADLThermalControllerInfo align");
_Static_assert(offsetof(wtop_ADLThermalControllerInfo,iSize)==offsetof(ADLThermalControllerInfo,iSize),"ADLThermalControllerInfo.iSize");
_Static_assert(offsetof(wtop_ADLThermalControllerInfo,iThermalDomain)==offsetof(ADLThermalControllerInfo,iThermalDomain),"ADLThermalControllerInfo.iThermalDomain");
_Static_assert(offsetof(wtop_ADLThermalControllerInfo,iDomainIndex)==offsetof(ADLThermalControllerInfo,iDomainIndex),"ADLThermalControllerInfo.iDomainIndex");
_Static_assert(offsetof(wtop_ADLThermalControllerInfo,iFlags)==offsetof(ADLThermalControllerInfo,iFlags),"ADLThermalControllerInfo.iFlags");
_Static_assert(sizeof(wtop_ADLTemperature)==sizeof(ADLTemperature),"ADLTemperature size");
_Static_assert(_Alignof(wtop_ADLTemperature)==_Alignof(ADLTemperature),"ADLTemperature align");
_Static_assert(offsetof(wtop_ADLTemperature,iSize)==offsetof(ADLTemperature,iSize),"ADLTemperature.iSize");
_Static_assert(offsetof(wtop_ADLTemperature,iTemperature)==offsetof(ADLTemperature,iTemperature),"ADLTemperature.iTemperature");
_Static_assert(sizeof(wtop_ADLFanSpeedValue)==sizeof(ADLFanSpeedValue),"ADLFanSpeedValue size");
_Static_assert(_Alignof(wtop_ADLFanSpeedValue)==_Alignof(ADLFanSpeedValue),"ADLFanSpeedValue align");
_Static_assert(offsetof(wtop_ADLFanSpeedValue,iSize)==offsetof(ADLFanSpeedValue,iSize),"ADLFanSpeedValue.iSize");
_Static_assert(offsetof(wtop_ADLFanSpeedValue,iSpeedType)==offsetof(ADLFanSpeedValue,iSpeedType),"ADLFanSpeedValue.iSpeedType");
_Static_assert(offsetof(wtop_ADLFanSpeedValue,iFanSpeed)==offsetof(ADLFanSpeedValue,iFanSpeed),"ADLFanSpeedValue.iFanSpeed");
_Static_assert(offsetof(wtop_ADLFanSpeedValue,iFlags)==offsetof(ADLFanSpeedValue,iFlags),"ADLFanSpeedValue.iFlags");
_Static_assert(sizeof(wtop_ADLOD6FanSpeedInfo)==sizeof(ADLOD6FanSpeedInfo),"ADLOD6FanSpeedInfo size");
_Static_assert(_Alignof(wtop_ADLOD6FanSpeedInfo)==_Alignof(ADLOD6FanSpeedInfo),"ADLOD6FanSpeedInfo align");
_Static_assert(offsetof(wtop_ADLOD6FanSpeedInfo,iSpeedType)==offsetof(ADLOD6FanSpeedInfo,iSpeedType),"ADLOD6FanSpeedInfo.iSpeedType");
_Static_assert(offsetof(wtop_ADLOD6FanSpeedInfo,iFanSpeedPercent)==offsetof(ADLOD6FanSpeedInfo,iFanSpeedPercent),"ADLOD6FanSpeedInfo.iFanSpeedPercent");
_Static_assert(offsetof(wtop_ADLOD6FanSpeedInfo,iFanSpeedRPM)==offsetof(ADLOD6FanSpeedInfo,iFanSpeedRPM),"ADLOD6FanSpeedInfo.iFanSpeedRPM");
_Static_assert(offsetof(wtop_ADLOD6FanSpeedInfo,iExtValue)==offsetof(ADLOD6FanSpeedInfo,iExtValue),"ADLOD6FanSpeedInfo.iExtValue");
_Static_assert(offsetof(wtop_ADLOD6FanSpeedInfo,iExtMask)==offsetof(ADLOD6FanSpeedInfo,iExtMask),"ADLOD6FanSpeedInfo.iExtMask");

_Static_assert(sizeof(wtop_ADL_D3DKMT_HANDLE)==sizeof(ADL_D3DKMT_HANDLE),"PMLog handle ABI");
_Static_assert(sizeof(ADL_D3DKMT_HANDLE)==4,"PMLog handle is 32-bit on both architectures");
_Static_assert(sizeof(wtop_ADLSingleSensorData)==sizeof(ADLSingleSensorData),"PMLog sensor ABI");
_Static_assert(_Alignof(wtop_ADLPMLogDataOutput)==_Alignof(ADLPMLogDataOutput),"PMLog output alignment");
_Static_assert(sizeof(wtop_ADLPMLogDataOutput)==sizeof(ADLPMLogDataOutput),"PMLog output ABI");
_Static_assert(sizeof(ADLPMLogDataOutput)==2052,"PMLog full fixed output");
_Static_assert(offsetof(wtop_ADLPMLogDataOutput,sensors)==offsetof(ADLPMLogDataOutput,sensors),"PMLog sensors offset");
_Static_assert(offsetof(wtop_ADLSingleSensorData,value)==offsetof(ADLSingleSensorData,value),"PMLog value offset");
_Static_assert(PMLOG_CLK_GFXCLK==1&&PMLOG_CLK_MEMCLK==2&&PMLOG_TEMPERATURE_EDGE==8,"PMLog clock/edge IDs");
_Static_assert(PMLOG_FAN_RPM==14&&PMLOG_FAN_PERCENTAGE==15&&PMLOG_INFO_ACTIVITY_GFX==19,"PMLog fan/activity IDs");
_Static_assert(PMLOG_GFX_VOLTAGE==21&&PMLOG_ASIC_POWER==23&&PMLOG_TEMPERATURE_HOTSPOT==27,"PMLog voltage/power/hotspot IDs");
