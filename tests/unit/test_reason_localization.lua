-- Provider reason codes shown in status lines, table quality columns and
-- inspector overlays must have a translated display form. Snapshot JSON keeps
-- the stable machine spelling; only the presentation layer localizes.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local Technical = require("wtop.i18n.technical")

-- Codes emitted by collectors and inspectors that can reach a status line,
-- a partial-row marker, or an inspector overlay. Internal-only codes that
-- never surface in the interface stay untranslated on purpose.
local interface_reasons = {
  "argv_executor_unavailable",
  "cache_value_out_of_range",
  "capacity_refresh_pending",
  "catalog_exceeds_max_bytes",
  "channel_enumeration_truncated",
  "coalition_query_unavailable",
  "collector_exception",
  "collector_returned_invalid_result",
  "content_required",
  "counter_reset",
  "cpu_performance_states_unavailable",
  "current_frequency_unavailable",
  "derived_value_out_of_range",
  "duplicate_locale",
  "estimated_available_out_of_range",
  "executor_exception",
  "file_content_not_string",
  "gpu_performance_counters_unavailable",
  "identity_collision",
  "invalid_device_path",
  "invalid_executor_result",
  "invalid_family",
  "invalid_gpu_process_scan_policy",
  "invalid_inspection_depth",
  "invalid_perf_clock",
  "invalid_perf_clock_result",
  "invalid_perf_executable",
  "invalid_perf_reader_result",
  "invalid_perf_reader_status",
  "invalid_perf_runner",
  "invalid_perf_runner_result",
  "invalid_probe_result",
  "invalid_process_system_constants",
  "invalid_result",
  "invalid_runner_options",
  "invalid_runner_policy",
  "invalid_sleep_executable",
  "invalid_smartctl_runner_status",
  "invalid_statvfs_provider",
  "ioreport_energy_model_unavailable",
  "memory_controller_pmu_not_found",
  "memory_event_open_failed",
  "memory_events_not_counted",
  "memory_events_not_supported",
  "memory_unavailable",
  "no_cpufreq_policies",
  "no_drm_card_devices",
  "device_inventory_unavailable",
  "no_device_inventory",
  "no_hwmon_devices",
  "no_power_supplies",
  "no_powercap_zones",
  "no_pressure_resources_readable",
  "no_readable_powercap_zones",
  "no_sensors",
  "no_socket_tables_available",
  "no_thermal_zones",
  "per_process_gpu_usage_unavailable",
  "perf_counter_value_out_of_range",
  "perf_event_permission_denied",
  "perf_executable_not_found",
  "perf_executable_not_runnable",
  "perf_reader_bandwidth_out_of_range",
  "perf_reader_exception",
  "perf_reader_missing_bandwidth",
  "perf_reader_unavailable",
  "perf_runner_exception",
  "perf_stat_cancelled",
  "perf_stat_invalid_counts",
  "perf_stat_output_truncated",
  "perf_stat_timeout",
  "proc_entries_not_table",
  "proc_uptime_unreadable",
  "processor_frequency_unavailable",
  "process_identity_changed",
  "process_io_unavailable",
  "query_denied",
  "safe_mode",
  "sleep_executable_not_found",
  "sleep_executable_not_runnable",
  "sleep_workload_failed",
  "smartctl_cancelled",
  "smartctl_invalid_json",
  "smartctl_output_truncated",
  "smartctl_permission_denied",
  "smartctl_timeout",
  "socket_tables_partial",
  "status_denied",
  "status_parse_error",
  "status_unavailable",
  "statvfs_skipped_budget_exhausted",
  "statvfs_skipped_potentially_blocking_filesystem",
  "supported_memory_events_not_found",
  "systemd_output_too_large",
  "systemd_unavailable_process_fallback",
  "thermal_zone_counters_unavailable",
  "times_unavailable",
  "translator_locale_mismatch",
  "unsupported_on_this_platform",
  "volume_identity_unavailable",
}

-- Codes deliberately kept machine-only: admission-budget markers exported in
-- JSON and decoder guards that never reach a status line.
local machine_only = {
  calls = true,
  time = true,
  input_buffer_limit = true,
  input_sequence_limit = true,
}

local locales = { "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR",
  "es-ES", "fr-FR", "de-DE", "pt-BR", "ru-RU" }

for _, locale in ipairs(locales) do
  local ok, module = pcall(require, "wtop.generated.locales." .. locale)
  assert(ok and type(module.messages) == "table",
    "generated catalog for " .. locale .. " must be loadable")
  local catalog = { messages = module.messages }
  for _, code in ipairs(interface_reasons) do
    assert(type(catalog.messages["reason." .. code]) == "string",
      locale .. " lacks reason." .. code)
  end
  local known = {}
  for _, code in ipairs(interface_reasons) do known[code] = true end
  for key in pairs(catalog.messages) do
    local code = key:match("^reason%.([a-z][a-z0-9_]*)$")
    if code and not known[code] and not machine_only[code] then
      error(locale .. " carries reason." .. code
        .. " which is absent from the interface inventory")
    end
  end
end

-- The presentation layer must return the translated form, not the code, and
-- must keep unknown codes readable instead of inventing a translation.
local I18n = require("wtop.i18n")
local chinese = assert(I18n.new({ locale = "zh-CN" }))
local shown = Technical.reason(chinese, "query_denied")
assert(type(shown) == "string" and shown ~= "query_denied" and #shown > 0,
  "query_denied must have a Chinese display form")
assert(Technical.state(chinese, "partial") == "部分可用",
  "state codes keep their localized display form")
assert(Technical.reason(chinese, "not_a_real_reason") == "not_a_real_reason",
  "unknown codes fall back to the raw spelling")
assert(Technical.reason(chinese, 123) == 123,
  "non-string values pass through unchanged")

print("ok: reason localization (" .. #interface_reasons .. " interface codes, "
  .. #locales .. " catalogs)")
