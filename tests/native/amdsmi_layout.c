/* Check sizes, alignment and every field consumed by the native wrapper.
 * With --sdk-root the right-hand types come from unmodified AMD headers. */
#include "../../native/wtop_amdsmi_abi.h"
#ifdef WTOP_AMDSMI_SDK_HEADER
#include WTOP_AMDSMI_SDK_HEADER
#else
#include "../fixtures/amdsmi/sdk.h"
#endif
#define JOIN_(a,b) a##b
#define JOIN(a,b) JOIN_(a,b)
#define LOCAL(name) JOIN(wtop_amd_##name##_, WTOP_AMDSMI_PROFILE)
#define LAYOUT(local, sdk) \
    _Static_assert(sizeof(local) == sizeof(sdk), "size: " #sdk); \
    _Static_assert(_Alignof(local) == _Alignof(sdk), "alignment: " #sdk)
#define FIELD(local, sdk, field) \
    _Static_assert(offsetof(local, field) == offsetof(sdk, field), "offset: " #sdk "." #field); \
    _Static_assert(sizeof(((local *)0)->field) == sizeof(((sdk *)0)->field), "field size: " #field)
LAYOUT(LOCAL(version), amdsmi_version_t);
FIELD(LOCAL(version), amdsmi_version_t, major);
FIELD(LOCAL(version), amdsmi_version_t, minor);
FIELD(LOCAL(version), amdsmi_version_t, release);
FIELD(LOCAL(version), amdsmi_version_t, build);
LAYOUT(wtop_amd_bdf, amdsmi_bdf_t);
FIELD(wtop_amd_bdf, amdsmi_bdf_t, as_uint);
LAYOUT(wtop_amd_activity, amdsmi_engine_usage_t);
FIELD(wtop_amd_activity, amdsmi_engine_usage_t, gfx_activity);
FIELD(wtop_amd_activity, amdsmi_engine_usage_t, umc_activity);
LAYOUT(wtop_amd_power_cap, amdsmi_power_cap_info_t);
FIELD(wtop_amd_power_cap, amdsmi_power_cap_info_t, power_cap);
LAYOUT(LOCAL(power_info), amdsmi_power_info_t);
FIELD(LOCAL(power_info), amdsmi_power_info_t, average_socket_power);
#if WTOP_AMDSMI_PROFILE != 232
FIELD(LOCAL(power_info), amdsmi_power_info_t, current_socket_power);
#endif
LAYOUT(LOCAL(asic_info), amdsmi_asic_info_t);
FIELD(LOCAL(asic_info), amdsmi_asic_info_t, market_name);
#if WTOP_AMDSMI_PROFILE != 232
LAYOUT(LOCAL(driver_info), amdsmi_driver_info_t);
FIELD(LOCAL(driver_info), amdsmi_driver_info_t, driver_version);
#endif
LAYOUT(LOCAL(clk_info), amdsmi_clk_info_t);
#if WTOP_AMDSMI_PROFILE <= 245
FIELD(LOCAL(clk_info), amdsmi_clk_info_t, cur_clk);
#else
FIELD(LOCAL(clk_info), amdsmi_clk_info_t, clk);
#endif
FIELD(LOCAL(clk_info), amdsmi_clk_info_t, max_clk);
_Static_assert(sizeof(amdsmi_status_t) == sizeof(uint32_t), "SDK status ABI");
_Static_assert(sizeof(processor_type_t) == sizeof(uint32_t), "SDK processor type ABI");
_Static_assert(sizeof(amdsmi_memory_type_t) == sizeof(uint32_t), "SDK memory type ABI");
_Static_assert(sizeof(amdsmi_clk_type_t) == sizeof(uint32_t), "SDK clock type ABI");
_Static_assert(sizeof(amdsmi_temperature_type_t) == sizeof(uint32_t), "SDK sensor type ABI");
_Static_assert(sizeof(amdsmi_temperature_metric_t) == sizeof(uint32_t), "SDK metric type ABI");
